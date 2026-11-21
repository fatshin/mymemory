import Foundation

/// 保存済みの要約から「決定事項」と「TODO」を取り出す (モデルを呼ばない)。
/// 見出しはモデル任せで揺れるため、装飾を除いた見出し語の完全一致で判定する。見出しが無い要約からは何も取り出さない。
enum SummarySections {
    struct Items: Equatable {
        var decisions: [String] = []
        var todos: [String] = []
        var isEmpty: Bool { decisions.isEmpty && todos.isEmpty }
    }

    private enum Section { case decisions, todos, other }

    /// 見出し語。比べる行と同じ正規化 (全角→半角で「・」も半角になる) をかけたものをキーにする。
    private static let headingWords: [String: Section] = {
        let words: [String: Section] = [
            "決定事項": .decisions, "決定": .decisions, "重要な会話・決定": .decisions,
            "todo": .todos, "todo・約束": .todos,
            "概要": .other, "要点": .other, "気づき": .other, "1日の流れ": .other,
        ]
        return Dictionary(uniqueKeysWithValues: words.map { (normalize($0.key).lowercased(), $0.value) })
    }()

    static func parse(_ text: String) -> Items {
        var items = Items()
        var section: Section?
        var lastWasItem = false
        var itemsInSection = 0

        func add(_ raw: String) {
            let t = cleanItem(raw)
            guard !t.isEmpty, !isNone(t) else { return }
            switch section {
            case .decisions: items.decisions.append(t)
            case .todos: items.todos.append(t)
            default: return
            }
            lastWasItem = true
            itemsInSection += 1
        }

        let unified = text.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in unified.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { lastWasItem = false; continue }
            // 区切り線 (---、***) は無視する
            if line.allSatisfy({ "-*_=ー─".contains($0) }) { continue }

            if let h = heading(line) {
                section = h.0
                lastWasItem = false
                itemsInSection = 0
                if !h.1.isEmpty { add(stripBullet(h.1) ?? h.1) }
                continue
            }
            guard section == .decisions || section == .todos else { continue }
            if let body = stripBullet(line) {
                add(body)
            } else if lastWasItem, rawLine.first?.isWhitespace == true {
                // 字下げされた行は直前の項目の折り返しとしてつなげる
                appendToLast(cleanItem(line), in: section, items: &items)
            } else if itemsInSection == 0 {
                // 記号のない項目は節の最初だけ拾う (末尾の締めの文を TODO に混ぜない)
                add(line)
            }
        }
        return items
    }

    // MARK: - 見出し

    /// 見出し行なら (節, 同じ行に続く残り) を返す。
    private static func heading(_ line: String) -> (Section, String)? {
        let n = normalize(line)
        // 【…】で始まる行: 括弧の中が見出し語。知らない語は、行がそこで終わるか区切りが続くときだけ見出しとする
        // (「【重要】請求書を送る」のような項目を見出しと誤認しない)
        if n.hasPrefix("【"), let close = n.firstIndex(of: "】") {
            let word = stripDecoration(String(n[n.index(after: n.startIndex)..<close]))
            let rest = String(n[n.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            if let s = headingWords[word.lowercased()] { return (s, rest) }
            if rest.isEmpty || [":", "："].contains(where: rest.hasPrefix) { return (.other, "") }
            return nil
        }
        let core = stripDecoration(n)
        if let s = headingWords[core.lowercased()] { return (s, "") }
        // 「TODO: 資料送付」のように見出し語の後に区切りがあり、残りが続く形
        for sep in [":", "："] {
            if let r = core.range(of: sep) {
                let word = String(core[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                if let s = headingWords[word.lowercased()] {
                    return (s, String(core[r.upperBound...]).trimmingCharacters(in: .whitespaces))
                }
            }
        }
        // Markdown の見出し (「# 」「## 」) は、知らない語でも節を抜ける。「#3 の件」は見出しにしない
        if n.range(of: #"^#+\s"#, options: .regularExpression) != nil { return (.other, "") }
        return nil
    }

    /// 全角英数を半角にし、太字の ** を除く。
    private static func normalize(_ s: String) -> String {
        let half = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        return half.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// 見出しの装飾 (#、【】、(数字)、数字.、末尾の : ) を除く。
    private static func stripDecoration(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix("#") { t.removeFirst() }
        t = t.replacingOccurrences(of: "【", with: "").replacingOccurrences(of: "】", with: "")
        t = t.replacingOccurrences(of: #"^\s*[\(（]\s*\d+\s*[\)）]\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^\s*\d+\s*[\.．]\s*"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespaces)
        while let last = t.last, last == ":" || last == "：" { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 項目

    /// 箇条書きの記号で始まる行なら、記号を除いた本文を返す。
    private static func stripBullet(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        for mark in ["- ", "-", "・", "• ", "•", "* "] where t.hasPrefix(mark) {
            return String(t.dropFirst(mark.count))
        }
        // 番号の後ろに空白を必須にする (「10.5万円」を「5万円」に切り詰めない)
        if let r = t.range(of: #"^\d+[\.\)．）]\s+"#, options: .regularExpression) {
            return String(t[r.upperBound...])
        }
        return nil
    }

    private static func cleanItem(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// 「なし」「特になし」「(なし)」「決定事項なし」などを捨てる。
    private static func isNone(_ s: String) -> Bool {
        var t = s
        for ch in ["。", "、", ".", "(", ")", "（", "）", " ", "　"] { t = t.replacingOccurrences(of: ch, with: "") }
        for w in ["特に", "決定事項", "TODO", "ToDo", "todo"] { t = t.replacingOccurrences(of: w, with: "") }
        return t.isEmpty || t == "なし" || t == "該当なし" || t == "はなし"
    }

    private static func appendToLast(_ s: String, in section: Section?, items: inout Items) {
        guard !s.isEmpty else { return }
        switch section {
        case .decisions where !items.decisions.isEmpty: items.decisions[items.decisions.count - 1] += " " + s
        case .todos where !items.todos.isEmpty: items.todos[items.todos.count - 1] += " " + s
        default: break
        }
    }
}
