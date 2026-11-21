import Foundation
import FoundationModels

/// 端末内モデルの要約を型で受け取る。自由な文章で出させると、小さなモデルは断片の羅列や会話に無い TODO を作りやすいため。
/// TODO は根拠となる発言の引用も出させ、引用が文字起こしに見つからないものは捨てる (EvidenceMatcher)。
@Generable
struct RecordingDigest {
    @Guide(description: "誰と何について話し、何が決まり、次に何をするかを2〜4文の自然な日本語の文章で。箇条書きにしない")
    var overview: String
    @Guide(description: "大事な内容。主語と対象を補い、それだけで意味が通る日本語の1文にする。単語や名詞の並びにしない", .maximumCount(5))
    var keyPoints: [String]
    @Guide(description: "話し合いの中ではっきり決まった方針や選択 (例: B社に決めた)。これからやる作業や予定は含めない (TODO に書く)。日本語の1文。無ければ空", .maximumCount(5))
    var decisions: [String]
    @Guide(description: "誰かが「やります」「やっておきます」「〜までに〜します」とはっきり言った具体的な行動を、入力の前から順にすべて。独り言で自分がやると決めたこと (「〜しておこう」) も含める。検討・提案・おいおい・かもしれない・推測は含めない。無ければ空", .maximumCount(8))
    var todos: [DigestTodo]
}

@Generable
struct DigestTodo {
    @Guide(description: "やると言った人の名前。分からなければ空文字")
    var owner: String
    @Guide(description: "やることを、あとから一覧だけを読んでも分かるように、何の件で・誰に・何をどうするかを補って「〜する」で終わる日本語で。例: B社向けの見積書を山田さんにメールで送る。「送る」「確認する」「対応する」だけにしない")
    var action: String
    @Guide(description: "期限。発言に無ければ空文字。発言に無い期限を作らない")
    var due: String
    @Guide(description: "その行動をやると言った発言を、入力からそのまま抜き出したもの")
    var quote: String
}

extension RecordingDigest {
    func rendered(source: String) -> String {
        DigestRenderer.render(overview: overview, keyPoints: keyPoints, decisions: decisions, todos: todos, source: source)
    }
}

/// 保存する文章の形 (見出しは SummarySections が読む)。TODO は根拠と約束を確かめたものだけ残す。
enum DigestRenderer {
    static func render(overview: String, keyPoints: [String], decisions: [String], todos: [DigestTodo], source: String) -> String {
        func list(_ xs: [String]) -> String {
            let items = xs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return items.isEmpty ? "- なし" : items.map { "- " + $0 }.joined(separator: "\n")
        }
        return """
        【概要】
        \(overview.trimmingCharacters(in: .whitespacesAndNewlines))

        【要点】
        \(list(keyPoints))

        【決定事項】
        \(list(decisions))

        【TODO】
        \(list(DigestTodo.verified(todos, source: source).map(\.line)))
        """
    }
}

extension DigestTodo {
    /// 根拠の引用が文字起こしにあり、引用が約束の言い方になっているものだけ残す。
    /// 同じ行動、または同じ発言を根拠にした言い換えは 1 件にまとめる。
    /// 担当の名前が文字起こしに無ければ空にする (小さなモデルは担当を取り違えやすいため)。
    static func verified(_ todos: [DigestTodo], source: String) -> [DigestTodo] {
        var seen = Set<String>(), seenQuotes = Set<String>()
        return todos.compactMap { t in
            let action = t.action.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !action.isEmpty,
                  EvidenceMatcher.isSupported(quote: t.quote, in: source),
                  EvidenceMatcher.isCommitment(t.quote),
                  seen.insert(String(EvidenceMatcher.normalize(action))).inserted,
                  seenQuotes.insert(String(EvidenceMatcher.normalize(t.quote))).inserted else { return nil }
            var v = t
            v.action = action
            let owner = t.owner.trimmingCharacters(in: .whitespacesAndNewlines)
            v.owner = (!owner.isEmpty && source.contains(owner.replacingOccurrences(of: "さん", with: ""))) ? owner : ""
            // 期限は発言にあるものだけ (「金曜」のような短い語は、そのまま含まれるかで見る)
            let due = t.due.trimmingCharacters(in: .whitespacesAndNewlines)
            let nd = EvidenceMatcher.normalize(due)
            let dueFound = nd.count < EvidenceMatcher.minChars
                ? (!nd.isEmpty && String(EvidenceMatcher.normalize(source)).contains(String(nd)))
                : EvidenceMatcher.isSupported(quote: due, in: source)
            v.due = dueFound ? due : ""
            return v
        }
    }

    /// 「担当: 行動 (期限)」。担当・期限が無ければ省く。
    var line: String {
        (owner.isEmpty ? "" : owner + ": ") + action + (due.isEmpty ? "" : " (" + due + ")")
    }
}
