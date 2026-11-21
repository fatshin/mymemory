import Foundation

/// 校正結果を採用してよいかの判定。端末内モデルが要約・省略・追記をしたら、元の文字起こしを残す。
/// FoundationModels に依存しない純粋関数にして単体テストする。
enum ProofreadGuard {
    /// 端末内モデルが挙げた直し 1 件。
    struct Fix: Equatable {
        let wrong: String
        let right: String
    }

    /// 直しのうち確かなものだけを本文に当てる。モデルは本文を書き直さず、直す箇所だけを挙げる (要約や言い換えを防ぐ)。
    /// - 誤りとされた部分が本文にそのまま 1 回だけあり、12 字以内で、直した語と字の半分以上が共通すること
    /// - 直した語が記号やモデルの書式を含まず、長さが大きく変わらないこと
    /// - 漢数字を算用数字にするような書き方の変更や、丁寧語への言い換えはしない
    static func apply(_ fixes: [Fix], to text: String) -> String {
        var out = text
        for f in fixes {
            let right = f.right.trimmingCharacters(in: CharacterSet(charactersIn: "「」『』\"' \u{3000}"))
            // 区間に 1 回だけ現れる語に限る (「しつ」を直すと「しつもん」まで壊れるような巻き添えを防ぐ)
            guard isSafe(wrong: f.wrong, right: right), out.components(separatedBy: f.wrong).count == 2 else { continue }
            out = out.replacingOccurrences(of: f.wrong, with: right)
        }
        return accept(original: text, corrected: out) ? out : text
    }

    static func isSafe(wrong: String, right: String) -> Bool {
        guard (2...maxFixChars).contains(wrong.count), !right.isEmpty, wrong != right else { return false }
        // 誤変換の直しは元の字を一部残す (「日程超生」→「日程調整」)。まったく別の言葉への置き換えは当てない
        guard overlap(EvidenceMatcher.normalize(wrong), EvidenceMatcher.normalize(right)) >= minFixOverlap else { return false }
        guard abs(right.count - wrong.count) <= max(2, wrong.count / 2) else { return false }
        let forbidden = CharacterSet(charactersIn: "{}[]<>`\"\\|\n\r")
        guard right.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return false }
        let asciiDigits = CharacterSet(charactersIn: "0123456789")
        let addsDigits = right.unicodeScalars.contains(where: asciiDigits.contains)
            && !wrong.unicodeScalars.contains(where: asciiDigits.contains)
        guard !addsDigits else { return false }
        // 話し言葉の口調は変えない (「二年か」→「二年ですね」のような直しは誤変換の修正ではない)
        return !politeEndings.contains { right.contains($0) && !wrong.contains($0) }
    }

    private static let politeEndings = ["です", "ます", "でした", "ました", "ください"]

    /// 校正で許す文字数の増減 (句読点の追加と誤変換の直しなら、この幅に収まる)。
    static let maxLengthChange = 0.3
    /// 校正後の文字が、元の文字とこの割合以上で一致していること (別の文章に書き換えていない)。
    static let minOverlap = 0.6
    /// 直し 1 件で置き換える語の長さの上限。文ごとの書き換えを防ぐ。
    static let maxFixChars = 12
    /// 直し 1 件の前後で共通に残る字の割合の下限。
    static let minFixOverlap = 0.5

    static func accept(original: String, corrected: String) -> Bool {
        let a = EvidenceMatcher.normalize(original)
        let b = EvidenceMatcher.normalize(corrected)
        guard !a.isEmpty, !b.isEmpty else { return false }
        let ratio = Double(b.count) / Double(a.count)
        guard abs(ratio - 1) <= maxLengthChange else { return false }
        return overlap(a, b) >= minOverlap
    }

    /// 2 つの文字列の最長共通部分列の長さを、長い方の長さで割った値。誤変換の直しは共通部分を大きく崩さない。
    static func overlap(_ x: [Character], _ y: [Character]) -> Double {
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: y.count + 1)
        var cur = prev
        for i in 1...x.count {
            for j in 1...y.count {
                cur[j] = x[i - 1] == y[j - 1] ? prev[j - 1] + 1 : max(prev[j], cur[j - 1])
            }
            swap(&prev, &cur)
        }
        return Double(prev[y.count]) / Double(max(x.count, y.count))
    }
}
