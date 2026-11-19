import SwiftUI
import SwiftData

/// 録音ごとの要約から取り出した決定事項と TODO を、日付ごとに並べる (直近 90 日)。
/// 項目を押すとその録音の詳細へ移る (遷移先は RootView の navigationDestination)。
struct ActionItemsView: View {
    static let days = 90

    @Query private var recordings: [Recording]
    @State private var groups: [DayGroup] = []
    @State private var loaded = false

    struct Entry: Identifiable {
        let id: UUID
        let startedAt: Date
        let items: SummarySections.Items
    }

    struct DayGroup: Identifiable {
        let day: Date
        let entries: [Entry]
        var id: Date { day }
    }

    init() {
        // 日付の境目で揃える (親の再描画で init が走っても条件が変わらず、取り直しが起きない)
        let today = Calendar.current.startOfDay(for: Date())
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.days, to: today) ?? .distantPast
        var d = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.summary != nil && $0.startedAt >= cutoff },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        // 文字起こし本文は読まない (一覧に要るのは要約と時刻だけ)
        d.propertiesToFetch = [\.id, \.startedAt, \.summary]
        _recordings = Query(d)
    }

    var body: some View {
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        NavigationLink(value: entry.id) { EntryRow(entry: entry) }
                    }
                } header: {
                    Text(group.day, format: .dateTime.year().month().day().weekday())
                }
            }
        }
        .overlay {
            if loaded && groups.isEmpty {
                ContentUnavailableView("決定事項・TODO なし", systemImage: "checklist",
                                       description: Text("直近\(Self.days)日の要約に、決定事項や TODO が見つかりません"))
            }
        }
        .navigationTitle("決定事項・TODO")
        // 解析は表示時と要約の増減時だけ行い、再描画のたびには行わない
        .task(id: changeKey) {
            groups = Self.group(recordings)
            loaded = true
        }
    }

    /// 要約の追加・作り直しで変わる軽い値 (解析をやり直す合図)。
    private var changeKey: Int {
        var h = Hasher()
        for rec in recordings { h.combine(rec.id); h.combine(rec.summary) }
        return h.finalize()
    }

    static func group(_ recs: [Recording], calendar: Calendar = .current) -> [DayGroup] {
        let entries = recs.compactMap { rec -> Entry? in
            guard let s = rec.summary else { return nil }
            let items = SummarySections.parse(s)
            return items.isEmpty ? nil : Entry(id: rec.id, startedAt: rec.startedAt, items: items)
        }
        let byDay = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.startedAt) }
        return byDay.keys.sorted(by: >).map { DayGroup(day: $0, entries: byDay[$0] ?? []) }
    }
}

private struct EntryRow: View {
    let entry: ActionItemsView.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.startedAt, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(entry.items.decisions.enumerated()), id: \.offset) { _, d in
                Label(d, systemImage: "checkmark.seal").font(.subheadline)
            }
            ForEach(Array(entry.items.todos.enumerated()), id: \.offset) { _, t in
                Label(t, systemImage: "circle").font(.subheadline)
            }
        }
        .padding(.vertical, 2)
    }
}
