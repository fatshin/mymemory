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
