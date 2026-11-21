import Foundation

/// 要約が挙げた根拠の引用が、元の文字起こしに本当にあるかを確かめる (モデルを呼ばない純粋関数)。
/// 句読点・空白・記号は無視し、引用の一定割合以上が元の文に連続して現れれば「ある」とみなす。
enum EvidenceMatcher {
    /// 連続して一致した長さが、引用の長さに対してこの割合以上なら根拠ありとする。
    static let minRatio = 0.6
    /// 短すぎる引用 (「はい」など) は根拠にならない。
    static let minChars = 4

    static func normalize(_ s: String) -> [Character] {
        let folded = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        return folded.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
    }

    static func isSupported(quote: String, in source: String) -> Bool {
        sourceSentence(for: quote, in: source) != nil
    }

    /// 引用に最もよく一致する、元の文字起こしの文 (連続する 3 文まで)。一致が足りなければ nil。
    /// 約束かどうかはモデルが書いた引用ではなく、この元の文で判定する (引用に足された語で約束に見せないため)。
    /// 一致の長さが同じなら短い方を選ぶ (無関係な隣の文を判定に混ぜない)。
    static func sourceSentence(for quote: String, in source: String) -> String? {
        let q = normalize(quote)
        guard q.count >= minChars else { return nil }
        let all = sentences(source)
        var best: (run: Int, length: Int, text: String)?
        for start in all.indices {
            for end in start..<min(start + maxWindowSentences, all.count) {
                let text = all[start...end].joined(separator: "。")
                let t = normalize(text)
                guard !t.isEmpty else { continue }
                let run = longestCommonRun(q, t)
                if run > (best?.run ?? 0) || (run == best?.run && t.count < (best?.length ?? .max)) {
                    best = (run, t.count, text)
                }
            }
        }
        guard let best, Double(best.run) >= Double(q.count) * minRatio else { return nil }
        return best.text
    }

    /// 引用が複数の文にまたがるとき (「連絡します。金曜までにやっておきます」) に見る文の数。
    static let maxWindowSentences = 3

    static func sentences(_ text: String) -> [String] {
        text.split(whereSeparator: { "。！？!?\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 最長共通部分文字列の長さ (動的計画法、1 行分の記憶)。引用は短いので計算量は小さい。
    static func longestCommonRun(_ a: [Character], _ b: [Character]) -> Int {
        var prev = [Int](repeating: 0, count: b.count + 1)
        var best = 0
        for i in 1...a.count {
            var cur = [Int](repeating: 0, count: b.count + 1)
            for j in 1...b.count where a[i - 1] == b[j - 1] {
                cur[j] = prev[j - 1] + 1
                best = max(best, cur[j])
            }
            prev = cur
        }
        return best
    }

    /// 発言が「やる」という約束になっているか。約束の言い方があり、ぼかし・提案・仮定が無いものだけを TODO にする。
    /// 判定は最後の文の、最後の節で行う (「わかりました、日程調整しておきます」は約束、「すみません、それ私です」は約束ではない)。
    /// 例: 「金曜までにやっておきます」「明日の午前中に送ります」「日曜までに注文しておこう」は約束。
    /// 「相談したほうがいいかもね」「七時から始まります」「送ってもらえますか」「金曜までに送りました」は約束ではない。
    static func isCommitment(_ text: String) -> Bool {
        // 複数の文なら最後の文 (約束を言い切る文) で判定する
        let sentence = sentences(text).last ?? text
        let whole = String(normalize(sentence))
        let hedges = ["かも", "ほうがいい", "方がいい", "たほうが", "おいおい", "検討", "たら", "れば", "かな", "でしょう", "だろう", "ようかな", "ようか", "ろうか", "たい", "ないと"]
        if hedges.contains(where: { whole.contains($0) }) { return false }
        let lastClause = sentence.split(whereSeparator: { "、,，".contains($0) }).last.map(String.init) ?? sentence
        let last = String(normalize(lastClause))
        // 問いかけ・過去の報告・事実の説明・否定で終わる節は約束ではない
        let nonPromiseEndings = ["ますか", "ました", "でした", "です", "ません", "だった"]
        if nonPromiseEndings.contains(where: { last.hasSuffix($0) }) { return false }
        let commitments = ["ておく", "ておき", "とく", "ておこう", "とこう", "やる", "やろう", "しよう", "までに", "ておいて", "といて", "お願いします", "引き受け", "担当します"]
        if commitments.contains(where: { last.contains($0) }) { return true }
        // 「〜します」「〜送ります」のような意思の「ます」だけを約束とみなす (「始まります」「あります」は予定や事実)
        let nonVolitional = ["まります", "なります", "あります", "います", "れます", "かります", "思います"]
        return last.hasSuffix("ます") && !nonVolitional.contains(where: { last.hasSuffix($0) })
    }
}
