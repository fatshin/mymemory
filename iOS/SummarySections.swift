import Foundation

/// 保存済みの要約から「決定事項」と「TODO」を取り出す (モデルを呼ばない)。
/// 見出しはモデル任せで揺れるため、装飾を除いた見出し語の完全一致で判定する。見出しが無い要約からは何も取り出さない。
enum SummarySections {
    struct Items: Equatable {
        var decisions: [String] = []
        var todos: [String] = []
        var isEmpty: Bool { decisions.isEmpty && todos.isEmpty }
    }

    /// 項目を拾う節。要点は parse では返さず、見直し (SummaryReviewGuard) でだけ使う。
    enum Section: Equatable { case keyPoints, decisions, todos, other }

    /// 見出し語。比べる行と同じ正規化 (全角→半角で「・」も半角になる) をかけたものをキーにする。
    private static let headingWords: [String: Section] = {
        let words: [String: Section] = [
            "決定事項": .decisions, "決定": .decisions, "重要な会話・決定": .decisions,
            "todo": .todos, "todo・約束": .todos,
            "概要": .other, "要点": .keyPoints, "気づき": .other, "1日の流れ": .other,
        ]
        return Dictionary(uniqueKeysWithValues: words.map { (normalize($0.key).lowercased(), $0.value) })
    }()

    static func parse(_ text: String) -> Items {
        var items = Items()
        for f in scan(lines(of: text)) {
            switch f.section {
            case .decisions: items.decisions.append(f.text)
            case .todos: items.todos.append(f.text)
            case .keyPoints, .other: break
            }
        }
        return items
    }

    // MARK: - 重ね合わせ

    /// TODO の各項目を transform で置き換えた文を返す (nil を返した項目は消す)。他の節・注記・行は変えない。
    /// 節の TODO がすべて消えたら「- なし」を残す。要約の本文 (正本) は書き換えず、表示と書き出しの直前に使う。
    static func mapTodos(in text: String, _ transform: (String) -> String?) -> String {
        mapItems(in: text, sections: [.todos]) { _, _, t in transform(t) }
    }

    /// 要点・決定事項・TODO の項目を、出てくる順に (節, 本文) で返す。番号は mapItems の index と同じ。
    static func reviewItems(in text: String) -> [(section: Section, text: String)] {
        scan(lines(of: text)).filter { $0.section != .other }.map { ($0.section, $0.text) }
    }

    /// 指定した節の項目を transform で置き換えた文を返す (nil を返した項目は消す)。index は節をまたいだ通し番号。
    /// 他の節・注記・行は変えない。節の項目がすべて消えたら「- なし」を残す。
    static func mapItems(in text: String, sections: Set<Section>, _ transform: (Section, Int, String) -> String?) -> String {
        var ls = lines(of: text)
        let todos = scan(ls).filter { sections.contains($0.section) }
        guard !todos.isEmpty else { return text }
        var remaining: [Int: Int] = [:]  // 節の見出し行 → 残る項目数
        let results = todos.enumerated().map { transform($0.element.section, $0.offset, $0.element.text) }
        for (t, r) in zip(todos, results) where r != nil { remaining[t.sectionStart, default: 0] += 1 }
        // 後ろから置き換えて、前の項目の行番号をずらさない
        for (t, r) in zip(todos, results).reversed() {
            if r == t.text { continue }  // 変わらない項目は元の行 (記号・折り返し) のまま残す
            var newLines: [String]
            if let r {
                let item = "- " + r.replacingOccurrences(of: "\n", with: " ")
                newLines = t.headingPrefix.map { [$0, item] } ?? [item]
            } else {
                let isLastOfSection = remaining[t.sectionStart, default: 0] == 0
                    && todos.last(where: { $0.sectionStart == t.sectionStart })?.lines == t.lines
                newLines = [t.headingPrefix, isLastOfSection ? "- なし" : nil].compactMap { $0 }
            }
            ls.replaceSubrange(t.lines, with: newLines)
        }
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
                        : (h.0 == .todos ? "【TODO】" : h.0 == .decisions ? "【決定事項】" : h.0 == .keyPoints ? "【要点】" : nil)
                    add(stripBullet(h.1) ?? h.1, at: i, headingPrefix: prefix)
                }
                continue
            }
            guard let section, section != .other else { continue }
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
