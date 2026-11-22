import SwiftUI
import SwiftData

/// 録音ごとの要約から取り出した決定事項と TODO を、日付ごとに並べる (直近 90 日)。
/// 項目を押すとその録音の詳細へ移る (遷移先は RootView の navigationDestination)。
struct ActionItemsView: View {
    static let days = 90

    @Query private var recordings: [Recording]
    @State private var groups: [DayGroup] = []
    @Environment(\.modelContext) private var ctx
    @State private var editing: TodoSource?
    @State private var editText = ""
    @State private var editError: String?
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
                        NavigationLink(value: entry.id) {
                            EntryRow(entry: entry,
                                     onEdit: { i, text in editText = text; editing = .recording(entry.id, index: i, expected: text) },
                                     onRemove: { i, text in apply(.recording(entry.id, index: i, expected: text), text: nil) })
                        }
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
        .alert("やることを編集", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("やること", text: $editText, axis: .vertical)
            Button("保存") { if let e = editing { apply(e, text: editText) }; editing = nil }
            Button("キャンセル", role: .cancel) { editing = nil }
        } message: {
            Text("空にして保存すると削除します")
        }
        .alert("やることを保存できませんでした", isPresented: Binding(get: { editError != nil }, set: { if !$0 { editError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(editError ?? "") }
        // 解析は表示時と要約の増減時だけ行い、再描画のたびには行わない
        .task(id: changeKey) {
            groups = Self.group(recordings)
            loaded = true
        }
    }

    /// 元の要約の文を書き換える。一覧は要約の変化 (changeKey) で組み直される。
    private func apply(_ source: TodoSource, text: String?) {
        do { try TodoEditor.apply(source, newText: text, in: ctx) } catch { editError = error.localizedDescription }
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
    var onEdit: (Int, String) -> Void = { _, _ in }
    var onRemove: (Int, String) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.startedAt, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(entry.items.decisions.enumerated()), id: \.offset) { _, d in
                Label(d, systemImage: "checkmark.seal").font(.subheadline)
            }
            ForEach(Array(entry.items.todos.enumerated()), id: \.offset) { i, t in
                Label(t, systemImage: "circle").font(.subheadline)
                    // 長押しで完了・編集・削除 (行を押すと録音の詳細へ移る)
                    .contextMenu {
                        Button { onRemove(i, t) } label: { Label("完了", systemImage: "checkmark.circle") }
                        Button { onEdit(i, t) } label: { Label("編集", systemImage: "pencil") }
                        Button(role: .destructive) { onRemove(i, t) } label: { Label("削除", systemImage: "trash") }
                    }
            }
        }
        .padding(.vertical, 2)
    }
}
