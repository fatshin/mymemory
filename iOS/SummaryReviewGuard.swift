import Foundation

/// 端末内モデルによる要約の見直しを、要約へ当ててよいかの判定と適用。FoundationModels に依存しない純粋関数にして単体テストする。
/// モデルには本文を自由に書き直させず、既存の項目ごとに「残す・直す・消す」を判定させる。
/// - 項目は増やさない。見出しと末尾の注記は変えない。
/// - 直しは、元の項目の文字の大半を残し、元に無い数字・否定を持ち込まないものだけ当てる (事実を作らせない)。
/// - 消す判定は節ごとに項目の半分まで。超えたらその節の消す判定は捨てる (モデルの暴走で中身を失わない)。
enum SummaryReviewGuard {
    enum Verdict: Equatable {
        case keep
        case fix(String)
        case drop
    }

    /// 直した 1 項目の文字数の上限。
    static let maxItemChars = 120
    /// 直した文が、元の項目の文字をこの割合以上 (順序どおり) 含むこと。言葉を補うのはよいが、別の文に書き換えない。
    static let minRetained = 0.6

    /// 意味のある内容が無いと判定した録音に保存する要約 (外部 API へは送らない)。詳細画面から要約し直せる。
    static let notMeaningfulSummary = """
        【概要】
        意味のある会話や内容は見つかりませんでした (雑音や言葉の断片だけの録音と判定しました)。必要なら詳細画面から要約し直せます。

        【要点】
        - なし

        【決定事項】
        - なし

        【TODO】
        - なし
        """

    /// 見直しの判定を要約に当てる。verdicts のキーは SummarySections.reviewItems の番号 (0 始まり)。
    /// overview は直した概要 (nil なら変えない)。概要は ProofreadGuard.accept に通るときだけ置き換える。
    static func apply(verdicts: [Int: Verdict], overview: String?, to summary: String) -> String {
        let items = SummarySections.reviewItems(in: summary)
        // 消す判定は節ごとに、その節の項目の半分までに限る (1 件だけの節は消さない)
        var count: [SummarySections.Section: Int] = [:], drops: [SummarySections.Section: Int] = [:]
        for (i, it) in items.enumerated() {
            count[it.section, default: 0] += 1
            if verdicts[i] == .drop { drops[it.section, default: 0] += 1 }
        }
        let dropOK = Set(count.keys.filter { (drops[$0] ?? 0) * 2 <= count[$0]! })
        var out = summary
        if !items.isEmpty, !verdicts.isEmpty {
            out = SummarySections.mapItems(in: summary, sections: [.keyPoints, .decisions, .todos]) { section, i, text in
                switch verdicts[i] {
                case .drop?: return dropOK.contains(section) ? nil : text
                case .fix(let fixed)?: return acceptFix(original: text, fixed: fixed) ? clean(fixed) : text
                case .keep?, nil: return text
                }
            }
        }
        if let overview, let current = currentOverview(in: out) {
            let fixed = overview.trimmingCharacters(in: .whitespacesAndNewlines)
            if fixed != current, ProofreadGuard.accept(original: current, corrected: fixed), !fixed.contains("【") {
                out = ReflectionSections.replacingSection("概要", in: out, with: fixed)
            }
        }
        return out
    }

    /// 直しを当ててよいか。
    static func acceptFix(original: String, fixed: String) -> Bool {
        let f = clean(fixed)
        guard !f.isEmpty, f != original, f.count <= maxItemChars, f.count <= original.count * 2 + 20,
              !ReflectionSections.isNone(f) else { return false }
        let forbidden = CharacterSet(charactersIn: "{}[]<>`|【】\n\r")
        guard f.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return false }
        // 否定の有無を変えない (「送る」→「送らない」)
        guard ProofreadGuard.negations(original) == ProofreadGuard.negations(f) else { return false }
        // 元に無い数字 (日付・金額・人数) を持ち込まない
        guard Set(numbers(in: f)).isSubset(of: Set(numbers(in: original))) else { return false }
        // 元に無い漢数字・日時の語 (来週・明日・午後など) を持ち込まない (期限を変えない)
        guard timeWords(in: f).isSubset(of: timeWords(in: original)) else { return false }
        let a = EvidenceMatcher.normalize(original), b = EvidenceMatcher.normalize(f)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return Double(lcs(a, b)) / Double(a.count) >= minRetained
    }

    /// 箇条書きの記号と前後の空白を外す。
    static func clean(_ s: String) -> String {
        ReflectionSections.stripBullet(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 【概要】の本文。
    static func currentOverview(in summary: String) -> String? {
        ReflectionSections.parse(summary).first(where: { $0.title == "概要" })?.body
    }

    /// 数字の並び (全角は半角にそろえる)。
    static func numbers(in s: String) -> [String] {
        let half = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        var out: [String] = [], cur = ""
        for c in half {
            if c.isASCII, c.isNumber { cur.append(c) } else if !cur.isEmpty { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// 期限や数量を表す語。直しでこれが増えたら、事実を作ったとみなす。
    static let timeWordList = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "百", "千", "万", "億", "半",
                               "今日", "明日", "明後日", "あした", "あさって", "昨日", "今週", "来週", "再来週", "先週",
                               "今月", "来月", "先月", "今年", "来年", "午前", "午後", "朝", "昼", "夕方", "夜",
                               "月曜", "火曜", "水曜", "木曜", "金曜", "土曜", "日曜", "週末", "月末", "年内", "期限", "まで"]
    static func timeWords(in s: String) -> Set<String> { Set(timeWordList.filter { s.contains($0) }) }

    /// 最長共通部分列の長さ。
    private static func lcs(_ x: [Character], _ y: [Character]) -> Int {
        var prev = [Int](repeating: 0, count: y.count + 1), cur = prev
        for i in 1...x.count {
            for j in 1...y.count {
                cur[j] = x[i - 1] == y[j - 1] ? prev[j - 1] + 1 : max(prev[j], cur[j - 1])
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}
