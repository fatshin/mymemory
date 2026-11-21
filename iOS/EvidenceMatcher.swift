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
        let q = normalize(quote), t = normalize(source)
        guard q.count >= minChars, !t.isEmpty else { return false }
        return Double(longestCommonRun(q, t)) >= Double(q.count) * minRatio
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

    /// 引用が「やる」という約束になっているか。約束の言い方があり、ぼかし・提案・仮定が無いものだけを TODO にする。
    /// 例: 「金曜までにやっておきます」「明日の午前中に送ります」「日曜までに注文しておこう」は約束。
    /// 「相談したほうがいいかもね」「数字で出せたら」「七時からです」は約束ではない。
    static func isCommitment(_ quote: String) -> Bool {
        let q = String(normalize(quote))
        let hedges = ["かも", "ほうがいい", "方がいい", "たほうが", "おいおい", "検討", "たら", "れば", "かな", "でしょう", "だろう", "ようかな", "たい", "ないと"]
        if hedges.contains(where: { q.contains($0) }) { return false }
        let commitments = ["ます", "ておく", "ておき", "とく", "ておこう", "とこう", "やる", "やろう", "しよう", "までに", "ておいて", "といて", "お願い", "わかりました", "了解", "引き受け", "担当します"]
        return commitments.contains(where: { q.contains($0) }) && !isStatement(q)
    }

    /// 「〜です」「〜でした」「〜ました」だけで終わる、事実や過去の報告 (約束ではない)。
    private static func isStatement(_ q: String) -> Bool {
        let futureMarks = ["ます", "ておく", "ておき", "とく", "ておこう", "とこう", "やる", "やろう", "しよう", "までに", "ておいて", "といて", "お願い", "わかりました", "引き受け"]
        let past = q.hasSuffix("ました") || q.hasSuffix("でした") || q.hasSuffix("です")
        guard past else { return false }
        // 過去・事実の言い方で終わっていても、途中に約束があれば約束とみなす (「わかりました、調整しておきます」)
        let body = q.hasSuffix("ました") ? String(q.dropLast(3)) : q
        return !futureMarks.contains(where: { body.contains($0) && $0 != "ます" })
    }
}
