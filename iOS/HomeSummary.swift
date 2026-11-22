import Foundation

/// メイン画面の最初の表示に出す中身。録音と保存済みの振り返りから組み立てる (モデルは呼ばない)。
/// 今日の録音が無いとき (朝など) は、録音のある直近の日を「昨日」などとして出す。
struct HomeSummary {
    struct Point: Identifiable {
        let id: UUID
        let time: Date
        let text: String
    }

    struct Todo: Identifiable {
        let id: String
        let recordingID: UUID?
        let time: Date?
        let text: String
        /// 編集・削除で書き換える元。
        let source: TodoSource
        /// どの会話から出たやることか (元の要約の概要の 1 文目)。
        var context: String? = nil
    }

    static let todoDays = 7
    static let todoLimit = 5
    static let pointLimit = 4

    let day: Date
    let dayLabel: String
    let items: [Recording]
    let totalMinutes: Int
    let reflection: ReflectionStore.Saved?
    /// 振り返りを作ったあとに増えた録音の件数。
    let addedSinceReflection: Int
    let points: [Point]
    let todos: [Todo]
    let todoOverflow: Int
    let decisions: [String]

    static func build(recordings: [Recording], now: Date = Date(), calendar: Calendar = .current) -> HomeSummary? {
        // recordings は新しい順。今日が無ければ、録音のある直近の日を出す
        guard let latest = recordings.first else { return nil }
        let today = calendar.startOfDay(for: now)
        let day = calendar.isDate(latest.startedAt, inSameDayAs: now) ? today : calendar.startOfDay(for: latest.startedAt)
        let items = recordings.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
            .sorted { $0.startedAt < $1.startedAt }

        let label: String
        if day == today { label = "今日" }
        else if let y = calendar.date(byAdding: .day, value: -1, to: today), day == y { label = "昨日" }
        else { label = day.formatted(.dateTime.month().day()) }

        let saved = ReflectionStore.load(day, calendar: calendar)
        let added = saved?.added(currentCount: items.count, currentLatest: items.last?.startedAt) ?? 0

        // 要約が無い録音は文字起こしの冒頭を出す (要約は利用者が作ったときだけできるため)
        let points = items.compactMap { r -> Point? in
            if let k = r.keyPoint { return Point(id: r.id, time: r.startedAt, text: k) }
            guard let t = r.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return Point(id: r.id, time: r.startedAt, text: String(t.prefix(60)))
        }

        var todos: [Todo] = []
        var decisions: [String] = []
        if let saved {
            // 振り返りの TODO は、優先順・重複除去・済んだものの除外を済ませてある
            let parsed = SummarySections.parse(saved.text)
            todos = parsed.todos.enumerated().map {
                Todo(id: "r-\($0.offset)-\($0.element)", recordingID: nil, time: nil, text: $0.element,
                     source: .reflection(day: day, index: $0.offset, expected: $0.element))
            }
            decisions = parsed.decisions
        } else {
            let cutoff = calendar.date(byAdding: .day, value: -todoDays, to: today) ?? .distantPast
            var seen = Set<String>()
            for rec in recordings where rec.startedAt >= cutoff {
                guard let s = rec.summary else { continue }
                let parsed = SummarySections.parse(s)
                let context = ReflectionSections.overviewSentence(in: s)
                for (i, t) in parsed.todos.enumerated() where seen.insert(t).inserted {
                    todos.append(Todo(id: "\(rec.id)-\(i)-\(t)", recordingID: rec.id, time: rec.startedAt, text: t,
                                      source: .recording(rec.id, index: i, expected: t), context: context))
                }
            }
            // 決定事項は表示する日のもの (7日より前の日を表示していても拾う)
            for rec in items { if let s = rec.summary { decisions += SummarySections.parse(s).decisions } }
        }

        return HomeSummary(day: day, dayLabel: label, items: items,
                           totalMinutes: Int(items.reduce(0) { $0 + $1.duration } / 60),
                           reflection: saved, addedSinceReflection: added,
                           points: Array(points.prefix(pointLimit)),
                           todos: Array(todos.prefix(todoLimit)), todoOverflow: max(0, todos.count - todoLimit),
                           decisions: decisions)
    }
}

extension Recording {
    /// 要約の【要点】の最初の項目。旧形式の要約は本文の最初の項目。注記や「なし」は除く。
    var keyPoint: String? { summary.flatMap(ReflectionSections.keyPoint(in:)) }
}
