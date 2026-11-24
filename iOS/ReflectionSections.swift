import Foundation

/// 振り返り・要約の本文を「【見出し】」ごとに分ける (表示用。モデルは呼ばない)。
/// 見出しが 1 つも無い本文は、見出しなしの 1 節として返す。
enum ReflectionSections {
    struct Section: Equatable {
        let title: String?
        let body: String
    }

    static func parse(_ text: String) -> [Section] {
        var sections: [Section] = []
        var title: String?
        var lines: [String] = []

        func flush() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if title != nil || !body.isEmpty { sections.append(Section(title: title, body: body)) }
            lines = []
        }

        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if isRouteLabel(line) { continue }
            if let heading = heading(line) {
                flush()
                title = heading.title
                if !heading.rest.isEmpty { lines.append(heading.rest) }
            } else {
                lines.append(raw)
            }
        }
        flush()
        return sections
    }

    /// 指定した見出しの下にある最初の項目 (「- 」「・」を外したもの)。「なし」は項目とみなさない。
    /// title が nil なら、見出しに関係なく本文の最初の項目を返す。
    static func firstItem(in text: String, under title: String?) -> String? {
        let sections = parse(text).filter { title == nil || $0.title == title }
        for s in sections {
            for raw in s.body.components(separatedBy: "\n") {
                let line = stripBullet(raw.trimmingCharacters(in: .whitespaces))
                if !line.isEmpty, !isNone(line) { return line }
            }
        }
        return nil
    }

    /// 行頭の「- 」「-」「・」「* 」「1. 」「1)」を外す。
    static func stripBullet(_ line: String) -> String {
        var l = line
        if let r = l.range(of: #"^([-・*•]|\d+[.)、])\s*"#, options: .regularExpression) { l.removeSubrange(r) }
        return l.trimmingCharacters(in: .whitespaces)
    }

    /// 「なし」「なし。」「(なし)」「特になし」などを空とみなす。
    static func isNone(_ line: String) -> Bool {
        let core = line.trimmingCharacters(in: CharacterSet(charactersIn: " 　。.()（）「」"))
        return ["なし", "特になし", "該当なし", "無し", "特に無し"].contains(core)
    }

    /// 要約の末尾に付ける「(端末内で要約)」「(OpenAI で要約)」などの注記。本文としては扱わない。
    static func isRouteLabel(_ line: String) -> Bool {
        line.hasPrefix("(") && line.hasSuffix("で要約)") && line.count <= 40
    }

    /// 行頭の「【…】」だけの行、または「【…】: 本文」の形を見出しとみなす。
    /// 「【重要】請求書を送る」のように見出しの後ろへ直接本文が続く行は、項目として扱う。
    private static func heading(_ line: String) -> (title: String, rest: String)? {
        guard line.hasPrefix("【"), let close = line.firstIndex(of: "】") else { return nil }
        let title = String(line[line.index(after: line.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        let rest = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { return (title, "") }
        for sep in [":", "："] where rest.hasPrefix(sep) {
            return (title, String(rest.dropFirst()).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

extension ReflectionSections {
    /// 要約の要点。見出し付きの要約では【要点】の下だけを見る (TODO などを要点として出さない)。
    /// 見出しの無い旧形式だけ、本文の最初の項目を使う。
    static func keyPoint(in text: String) -> String? {
        let sections = parse(text)
        if sections.contains(where: { $0.title != nil }) { return firstItem(in: text, under: "要点") }
        return firstItem(in: text, under: nil)
    }

    /// 【概要】の最初の 1 文 (40 字まで)。やることの出どころを示すのに使う。
    static func overviewSentence(in text: String) -> String? {
        guard let body = parse(text).first(where: { $0.title == "概要" })?.body,
              let first = body.components(separatedBy: "。").first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !first.isEmpty, !isNone(first) else { return nil }
        return first.count > 40 ? String(first.prefix(40)) + "…" : first + "。"
    }

    /// 【title】節の本文を body に置き換えた文。節が無ければ元の文を返す。注記や他の節は変えない。
    static func replacingSection(_ title: String, in text: String, with body: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // 見出しは大文字小文字と「TODO・約束」のような付記の揺れを許す
        let want = title.lowercased()
        guard let start = lines.firstIndex(where: {
            heading($0.trimmingCharacters(in: .whitespaces))?.title.lowercased().hasPrefix(want) == true
        }) else { return text }
        var end = start + 1
        while end < lines.count {
            let l = lines[end].trimmingCharacters(in: .whitespaces)
            if heading(l) != nil || isRouteLabel(l) { break }
            end += 1
        }
        // 次の節や注記の前の空行は残す
        while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        var out = lines
        out.replaceSubrange(start..<end, with: ["【\(title)】"] + body.components(separatedBy: "\n"))
        return out.joined(separator: "\n")
    }

    /// 画面で 1 行ずつ編集・削除できる項目 (節の本文の空でない行)。`editingLine` の行番号はこの並びに対応する。
    static func items(of section: Section) -> [String] {
        section.body.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// `parse(text)` の section 番目の節にある line 番目の項目を value に書き換える。value が空なら行を消す。
    /// 行頭の「- 」などの記号は元のまま残す。節の項目がすべて消えたら「- なし」を置く (見出しは一覧が読むため残す)。
    /// 他の節・注記・空行はそのまま。該当する行が無ければ元の文を返す。
    static func editingLine(in text: String, section: Int, line: Int, to value: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let firstHeading = lines.firstIndex { heading($0.trimmingCharacters(in: .whitespaces)) != nil } ?? lines.count
        let hasPreamble = lines[..<firstHeading].contains { isItemLine($0) }
        var current = hasPreamble ? 0 : -1
        var count = 0
        var target: (index: Int, isHeadingRest: Bool)?
        var sectionStart = 0, sectionEnd = lines.count
        for (i, raw) in lines.enumerated() {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if let h = heading(l) {
                if current == section { sectionEnd = i; break }
                current += 1
                count = 0
                sectionStart = i
                if !h.rest.isEmpty {
                    if current == section, count == line { target = (i, true) }
                    count += 1
                }
                continue
            }
            guard current == section, isItemLine(raw) else { continue }
            if count == line { target = (i, false) }
            count += 1
        }
        guard let t = target else { return text }
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        if t.isHeadingRest {
            let title = heading(lines[t.index].trimmingCharacters(in: .whitespaces))?.title ?? ""
            lines[t.index] = v.isEmpty ? "【\(title)】" : "【\(title)】: \(stripEditBullet(v))"
        } else if v.isEmpty {
            lines.remove(at: t.index)
            sectionEnd -= 1
        } else {
            let raw = lines[t.index]
            let prefix = raw.range(of: editBulletPattern, options: .regularExpression).map { String(raw[$0]) } ?? ""
            let body = stripEditBullet(v)
            // 記号の無い行に「【…】」や「(…で要約)」の形の文を入れると、見出し・注記と読まれて節が変わるため、記号を付ける
            let guarded = prefix.isEmpty && (body.hasPrefix("【") || isRouteLabel(body)) ? "- " : prefix
            lines[t.index] = guarded + body
        }
        // 見出しの行 (節の先頭) を除いて、項目が残っているか
        let bodyStart = current >= 0 && heading(lines[sectionStart].trimmingCharacters(in: .whitespaces)) != nil ? sectionStart + 1 : sectionStart
        let headingRest = heading(lines[sectionStart].trimmingCharacters(in: .whitespaces)).map { !$0.rest.isEmpty } ?? false
        if v.isEmpty, !headingRest, !lines[bodyStart..<max(bodyStart, sectionEnd)].contains(where: isItemLine) {
            lines.insert("- なし", at: bodyStart)
        }
        return lines.joined(separator: "\n")
    }

    /// 編集で扱う行頭の記号。数字は後ろに空白があるときだけ記号とみなす (「10.5万円」の「10.」を消さない)。
    private static let editBulletPattern = #"^\s*([-・*•]\s*|\d+[.)、]\s+)"#

    /// 編集の画面に出す、行頭の記号を外した文。
    static func stripEditBullet(_ line: String) -> String {
        var l = line.trimmingCharacters(in: .whitespaces)
        if let r = l.range(of: editBulletPattern, options: .regularExpression) { l.removeSubrange(r) }
        return l.trimmingCharacters(in: .whitespaces)
    }

    /// 項目として数える行 (空行と注記以外)。
    private static func isItemLine(_ raw: String) -> Bool {
        let l = raw.trimmingCharacters(in: .whitespaces)
        return !l.isEmpty && !isRouteLabel(l)
    }

    /// 末尾の「(OpenAI で要約)」などの注記。どこで処理したかの開示として、本文とは別に表示する。
    static func routeLabel(in text: String) -> String? {
        guard let last = text.components(separatedBy: "\n").last(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        })?.trimmingCharacters(in: .whitespaces), isRouteLabel(last) else { return nil }
        return last
    }
}

/// 生成した 1 日の振り返りを日ごとに保存する。メイン画面で、開き直さずに読めるようにする。
/// 本文は数 KB 程度で件数も日数分なので、UserDefaults に置く。
enum ReflectionStore {
    static let prefix = "reflection."

    /// 保存した振り返りと、生成した時点の録音の状態 (あとで録音が増えたかを見分けるため)。
    struct Saved: Equatable {
        let text: String
        let recordingCount: Int
        let latestStart: Date?

        /// 生成後に増えた録音の件数。生成時の情報が無い古い保存は 0 とみなす。
        func added(currentCount: Int, currentLatest: Date?) -> Int {
            guard recordingCount > 0 || latestStart != nil else { return 0 }
            if currentCount > recordingCount { return currentCount - recordingCount }
            if let c = currentLatest, let l = latestStart, c > l { return 1 }
            return 0
        }
    }

    static func key(for day: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "\(prefix)%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func load(_ day: Date, defaults: UserDefaults = .standard, calendar: Calendar = .current) -> Saved? {
        let k = key(for: day, calendar: calendar)
        if let d = defaults.dictionary(forKey: k), let text = d["text"] as? String {
            return Saved(text: text, recordingCount: d["count"] as? Int ?? 0, latestStart: d["latest"] as? Date)
        }
        // 最初の版は本文だけを保存していた
        if let text = defaults.string(forKey: k) { return Saved(text: text, recordingCount: 0, latestStart: nil) }
        return nil
    }

    static func save(_ text: String, for day: Date, recordingCount: Int, latestStart: Date?,
                     defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        var d: [String: Any] = ["text": text, "count": recordingCount]
        if let latestStart { d["latest"] = latestStart }
        defaults.set(d, forKey: key(for: day, calendar: calendar))
    }

    /// 録音が 1 件も残っていない日の振り返りを消す (録音を消したのに要約だけ残らないように)。
    static func purge(keepingDays days: [Date], defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        let keep = Set(days.map { key(for: $0, calendar: calendar) })
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(prefix) && !keep.contains(k) {
            defaults.removeObject(forKey: k)
        }
    }
}
