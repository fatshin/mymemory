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
        var id: String { TodoLedger.key(original) }
        let recordingID: UUID
        let time: Date
        /// 表示する文言 (台帳で編集していれば編集後)。
        let text: String
        /// 要約に書かれていた元の文言 (台帳の鍵)。
        let original: String
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

    /// 録音ごとの要約から未完了のやることを集める (recordings の並び順)。台帳を重ね、同じ文言は 1 件にまとめる。
    /// やることの出どころは録音の要約に一本化する (振り返りは言い回しを変えるため、文言で状態を照合できない)。
    static func openTodos(from recordings: [Recording], ledger: TodoLedger) -> [Todo] {
        var seen = Set<String>()
        var todos: [Todo] = []
        for rec in recordings {
            guard let s = rec.summary else { continue }
            let context = ReflectionSections.overviewSentence(in: s)
            for t in SummarySections.parse(s).todos {
                // 未完了のものだけで重複をまとめる (新しい録音が完了でも、別に効く古い未完了は出す)
                guard case .open(let display) = ledger.resolve(t, startedAt: rec.startedAt),
                      seen.insert(TodoLedger.key(t)).inserted else { continue }
                todos.append(Todo(recordingID: rec.id, time: rec.startedAt, text: display, original: t, context: context))
            }
        }
        return todos
    }

    /// 録音ごとの決定事項に台帳 (削除・編集) を重ね、同じ文言は 1 つにまとめる (時刻順)。
    static func dayDecisions(from recordings: [Recording], ledger: TodoLedger) -> [String] {
        ledger.dayDecisions(recordings.map { (id: $0.id, startedAt: $0.startedAt, summary: $0.summary) })
    }

    static func build(recordings: [Recording], ledger: TodoLedger, now: Date = Date(), calendar: Calendar = .current) -> HomeSummary? {
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

        let cutoff = calendar.date(byAdding: .day, value: -todoDays, to: today) ?? .distantPast
        let todos = openTodos(from: recordings.filter { $0.startedAt >= cutoff }, ledger: ledger)
        // 決定事項は表示する日の録音のもの (振り返りがあっても、一覧で消した・直した結果を出すため録音から取る)
        let decisions = dayDecisions(from: items, ledger: ledger)

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
