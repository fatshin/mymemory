import SwiftUI
import SwiftData

/// 録音ごとの要約から取り出した決定事項と TODO を、日付ごとに並べる (直近 90 日)。
/// TODO にはやること台帳 (完了・削除・編集) を重ねる。完了した項目は打ち消し線で残し、先頭の「完了」節にも集める。
/// 項目を押すとその録音の詳細へ移る (遷移先は RootView の navigationDestination)。
struct ActionItemsView: View {
    static let days = 90

    @Query private var recordings: [Recording]
    @State private var groups: [DayGroup] = []
    @ObservedObject private var ledgerStore = TodoLedgerStore.shared
    @State private var editing: Todo?
    @State private var editText = ""
    @State private var undo: TodoUndo?
    @State private var showCompleted = false
    @State private var loaded = false

    struct Todo: Identifiable, Equatable {
        var id: String { original }
        let original: String
        let startedAt: Date
        let display: String
        let completed: Bool
    }

    struct Entry: Identifiable {
        let id: UUID
        let startedAt: Date
        let decisions: [String]
        let todos: [Todo]
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
            let completed = ledgerStore.ledger.completed
            if !completed.isEmpty {
                Section(isExpanded: $showCompleted) {
                    ForEach(completed) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.display).strikethrough().foregroundStyle(.secondary)
                            if let at = e.completedAt {
                                Text(at, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button { ledgerStore.perform(e.original) { $0.reopen(e.original, startedAt: e.scopeAt) }; undo = nil } label: {
                                Label("未完了に戻す", systemImage: "arrow.uturn.backward")
                            }
                        }
                        .contextMenu {
                            Button { ledgerStore.perform(e.original) { $0.reopen(e.original, startedAt: e.scopeAt) }; undo = nil } label: {
                                Label("未完了に戻す", systemImage: "arrow.uturn.backward")
                            }
                        }
                    }
                } header: {
                    Text("完了 (\(completed.count))")
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        NavigationLink(value: entry.id) {
                            EntryRow(entry: entry,
                                     onComplete: { t in act(t, "完了しました") { $0.complete(t.original, startedAt: t.startedAt) } },
                                     onReopen: { t in ledgerStore.perform(t.original) { $0.reopen(t.original, startedAt: t.startedAt) }; undo = nil },
                                     onEdit: { t in editText = t.display; editing = t },
                                     onRemove: { t in act(t, "削除しました") { $0.delete(t.original, startedAt: t.startedAt) } })
                        }
                    }
                } header: {
                    Text(group.day, format: .dateTime.year().month().day().weekday())
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if loaded && groups.isEmpty && ledgerStore.ledger.completed.isEmpty {
                ContentUnavailableView("決定事項・TODO なし", systemImage: "checklist",
                                       description: Text("直近\(Self.days)日の要約に、決定事項や TODO が見つかりません"))
            }
        }
        .overlay(alignment: .bottom) { UndoBanner(undo: $undo) }
        .navigationTitle("決定事項・TODO")
        .alert("やることを編集", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("やること", text: $editText, axis: .vertical)
            Button("保存") {
                if let t = editing {
                    ledgerStore.perform(t.original) { $0.edit(t.original, startedAt: t.startedAt, to: editText) }
                    undo = nil  // 編集の後に古い「元に戻す」を押して編集まで消さない
                }
                editing = nil
            }
            Button("キャンセル", role: .cancel) { editing = nil }
        } message: {
            Text("空にして保存すると削除します")
        }
        // 解析は表示時と、要約や台帳が変わったときだけ行い、再描画のたびには行わない
        .task(id: changeKey) {
            groups = Self.group(recordings, ledger: ledgerStore.ledger)
            loaded = true
        }
    }

    private func act(_ t: Todo, _ message: String, _ change: (inout TodoLedger) -> Void) {
        let previous = withAnimation { ledgerStore.perform(t.original, change) }
        undo = TodoUndo(original: t.original, previous: previous, message: message)
    }

    /// 要約の追加・作り直しと、台帳の変化で変わる軽い値 (解析をやり直す合図)。
    private var changeKey: Int {
        var h = Hasher()
        h.combine(ledgerStore.revision)
        for rec in recordings { h.combine(rec.id); h.combine(rec.summary) }
        return h.finalize()
    }

    /// 削除した項目は出さない。同じ文言は 1 か所 (最初に出た録音) にまとめる。
    static func group(_ recs: [Recording], ledger: TodoLedger, calendar: Calendar = .current) -> [DayGroup] {
        var seen = Set<String>()
        let entries = recs.compactMap { rec -> Entry? in
            guard let s = rec.summary else { return nil }
            let items = SummarySections.parse(s)
            let todos = items.todos.compactMap { t -> Todo? in
                // 同じ文言は、同じ状態のものだけ 1 か所にまとめる (効く記録が違えば別の項目)
                switch ledger.resolve(t, startedAt: rec.startedAt) {
                case .open(let d):
                    guard seen.insert("o|" + TodoLedger.key(t)).inserted else { return nil }
                    return Todo(original: t, startedAt: rec.startedAt, display: d, completed: false)
                case .completed(let d, let at):
                    guard seen.insert("c|\(at.timeIntervalSince1970)|" + TodoLedger.key(t)).inserted else { return nil }
                    return Todo(original: t, startedAt: rec.startedAt, display: d, completed: true)
                case .deleted: return nil
                }
            }
            guard !items.decisions.isEmpty || !todos.isEmpty else { return nil }
            return Entry(id: rec.id, startedAt: rec.startedAt, decisions: items.decisions, todos: todos)
        }
        let byDay = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.startedAt) }
        return byDay.keys.sorted(by: >).map { DayGroup(day: $0, entries: byDay[$0] ?? []) }
    }
}

private struct EntryRow: View {
    let entry: ActionItemsView.Entry
    var onComplete: (ActionItemsView.Todo) -> Void
    var onReopen: (ActionItemsView.Todo) -> Void
    var onEdit: (ActionItemsView.Todo) -> Void
    var onRemove: (ActionItemsView.Todo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.startedAt, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(entry.decisions.enumerated()), id: \.offset) { _, d in
                Label(d, systemImage: "checkmark.seal").font(.subheadline)
            }
            ForEach(entry.todos) { t in
                Label {
                    Text(t.display).strikethrough(t.completed).foregroundStyle(t.completed ? .secondary : .primary)
                } icon: {
                    Image(systemName: t.completed ? "checkmark.circle.fill" : "circle")
                }
                .font(.subheadline)
                // 長押しで完了・編集・削除 (行を押すと録音の詳細へ移る)
                .contextMenu {
                    if t.completed {
                        Button { onReopen(t) } label: { Label("未完了に戻す", systemImage: "arrow.uturn.backward") }
                    } else {
                        Button { onComplete(t) } label: { Label("完了", systemImage: "checkmark.circle") }
                    }
                    Button { onEdit(t) } label: { Label("編集", systemImage: "pencil") }
                    Button(role: .destructive) { onRemove(t) } label: { Label("削除", systemImage: "trash") }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
