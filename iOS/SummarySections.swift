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
        for f in scan(lines(of: text)) {
            switch f.section {
            case .decisions: items.decisions.append(f.text)
            case .todos: items.todos.append(f.text)
            case .other: break
            }
        }
        return items
    }

    // MARK: - 編集

    /// index 番目の TODO を newText に置き換える (nil なら削除)。index は parse(text).todos の並び。
    /// 節の TODO が無くなったら「- なし」を残し、見出しだけの節にしない。範囲外なら元の文を返す。
    /// expected を渡すと、index の項目の文言が一致するときだけ書き換える (一致しなければ同じ文言の最初の項目を探す)。
    /// 画面の表示が古いまま操作されても、別の項目を消さないため。
    static func editingTodo(in text: String, at index: Int, expected: String? = nil, to newText: String?) -> String {
        var ls = lines(of: text)
        let todos = scan(ls).filter { $0.section == .todos }
        let resolved: Int?
        if let expected {
            resolved = todos.indices.contains(index) && todos[index].text == expected
                ? index : todos.firstIndex { $0.text == expected }
        } else {
            resolved = todos.indices.contains(index) ? index : nil
        }
        guard let resolved else { return text }
        let target = todos[resolved]
        let replacement = newText?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        var newLines: [String]
        if let replacement, !replacement.isEmpty {
            // 見出しと同じ行にあった項目は、見出しを残して項目だけ差し替える
            newLines = [(target.headingPrefix.map { $0 + "\n" } ?? "") + "- " + replacement]
        } else {
            let sectionEmpty = todos.filter { $0.sectionStart == target.sectionStart }.count == 1
            newLines = [target.headingPrefix, sectionEmpty ? "- なし" : nil].compactMap { $0 }
        }
        newLines = newLines.flatMap { $0.components(separatedBy: "\n") }
        ls.replaceSubrange(target.lines, with: newLines)
        return ls.joined(separator: "\n")
    }

    // MARK: - 走査

    private struct Found {
        let section: Section
        var text: String
        /// 項目が占める行 (折り返しを含む)。
        var lines: ClosedRange<Int>
        /// 見出しと同じ行にあった項目なら、その見出し部分。
        let headingPrefix: String?
        /// 項目が属する節の見出しの行。
        let sectionStart: Int
    }

    private static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
    }

    private static func scan(_ lines: [String]) -> [Found] {
        var found: [Found] = []
        var section: Section?
        var sectionStart = -1
        var lastWasItem = false
        var itemsInSection = 0

        func add(_ raw: String, at i: Int, headingPrefix: String? = nil) {
            let t = cleanItem(raw)
            guard !t.isEmpty, !isNone(t), let section, section != .other else { return }
            found.append(Found(section: section, text: t, lines: i...i, headingPrefix: headingPrefix, sectionStart: sectionStart))
            lastWasItem = true
            itemsInSection += 1
        }

        for (i, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { lastWasItem = false; continue }
            // 末尾の「(端末内で要約)」などの注記は項目ではない
            if ReflectionSections.isRouteLabel(line) { continue }
            // 区切り線 (---、***) は無視する
            if line.allSatisfy({ "-*_=ー─".contains($0) }) { continue }

            if let h = heading(line) {
                section = h.0
                sectionStart = i
                lastWasItem = false
                itemsInSection = 0
                if !h.1.isEmpty {
                    // 見出しは正規化した文字で判定するため、原文と一致しないときは標準の見出しに置き換える (見出しを消さない)
                    let prefix = line.hasSuffix(h.1)
                        ? String(line.dropLast(h.1.count)).trimmingCharacters(in: .whitespaces)
                        : (h.0 == .todos ? "【TODO】" : h.0 == .decisions ? "【決定事項】" : nil)
                    add(stripBullet(h.1) ?? h.1, at: i, headingPrefix: prefix)
                }
                continue
            }
            guard section == .decisions || section == .todos else { continue }
            if let body = stripBullet(line) {
                add(body, at: i)
            } else if lastWasItem, rawLine.first?.isWhitespace == true, let last = found.indices.last {
                // 字下げされた行は直前の項目の折り返しとしてつなげる
                let s = cleanItem(line)
                if !s.isEmpty {
                    found[last].text += " " + s
                    found[last].lines = found[last].lines.lowerBound...i
                }
            } else if itemsInSection == 0 {
                // 記号のない項目は節の最初だけ拾う (末尾の締めの文を TODO に混ぜない)
                add(line, at: i)
            }
        }
        return found
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
}
