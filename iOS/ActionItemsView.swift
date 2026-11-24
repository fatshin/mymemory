import SwiftUI
import SwiftData

/// 録音ごとの要約から取り出した決定事項と TODO を、日付ごとに並べる (直近 90 日)。
/// やること台帳 (TODO は完了・削除・編集、決定事項は削除・編集) を重ねる。完了した項目は打ち消し線で残し、先頭の「完了」節にも集める。
/// 項目は 1 行ずつ並べ、押すと編集、スワイプで削除・完了。録音の時刻の行を押すと詳細へ移る (遷移先は RootView の navigationDestination)。
struct ActionItemsView: View {
    static let days = 90

    @Query private var recordings: [Recording]
    @State private var groups: [DayGroup] = []
    @ObservedObject private var ledgerStore = TodoLedgerStore.shared
    @State private var editing: Todo?
    @State private var undo: TodoUndo?
    @State private var showCompleted = false
    @State private var loaded = false

    /// 一覧の 1 項目 (TODO か決定事項)。original は台帳の鍵にする文言 (決定事項は印付き)。
    struct Todo: Identifiable, Equatable {
        var id: String { original }
        let original: String
        let startedAt: Date
        let display: String
        let completed: Bool
        var isDecision = false
    }

    struct Entry: Identifiable {
        let id: UUID
        let startedAt: Date
        let decisions: [Todo]
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
                        // 時刻の行だけが録音の詳細へのリンク。項目の行は押すと編集する
                        NavigationLink(value: entry.id) {
                            Label {
                                Text(entry.startedAt, format: .dateTime.hour().minute())
                            } icon: {
                                Image(systemName: "text.bubble")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityHint("元の会話を開きます")
                        ForEach(entry.decisions + entry.todos) { t in
                            Button { editing = t } label: { ItemRow(item: t).contentShape(.rect) }
                                .buttonStyle(.plain)
                                .accessibilityHint("編集します")
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) { remove(t) } label: { Label("削除", systemImage: "trash") }
                                    Button { editing = t } label: { Label("編集", systemImage: "pencil") }.tint(.blue)
                                }
                                .swipeActions(edge: .leading) {
                                    if !t.isDecision {
                                        if t.completed {
                                            Button { reopen(t) } label: { Label("未完了に戻す", systemImage: "arrow.uturn.backward") }
                                        } else {
                                            Button { complete(t) } label: { Label("完了", systemImage: "checkmark") }.tint(.green)
                                        }
                                    }
                                }
                                .contextMenu {
                                    if !t.isDecision {
                                        if t.completed {
                                            Button { reopen(t) } label: { Label("未完了に戻す", systemImage: "arrow.uturn.backward") }
                                        } else {
                                            Button { complete(t) } label: { Label("完了", systemImage: "checkmark.circle") }
                                        }
                                    }
                                    Button { editing = t } label: { Label("編集", systemImage: "pencil") }
                                    Button(role: .destructive) { remove(t) } label: { Label("削除", systemImage: "trash") }
                                }
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
        .sheet(item: $editing) { t in
            ItemEditSheet(item: t,
                          onSave: { text in
                              editing = nil
                              // 空にしたら削除 (元に戻せるよう、削除と同じ扱いにする)
                              if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { remove(t); return }
                              ledgerStore.perform(t.original) { $0.edit(t.original, startedAt: t.startedAt, to: text) }
                              undo = nil  // 編集の後に古い「元に戻す」を押して編集まで消さない
                          },
                          onComplete: { editing = nil; complete(t) },
                          onReopen: { editing = nil; reopen(t) },
                          onDelete: { editing = nil; remove(t) })
                .presentationDetents([.medium, .large])
        }
        // 解析は表示時と、要約や台帳が変わったときだけ行い、再描画のたびには行わない
        .task(id: changeKey) {
            groups = Self.group(recordings, ledger: ledgerStore.ledger)
            loaded = true
        }
    }

    private func complete(_ t: Todo) { act(t, "完了しました") { $0.complete(t.original, startedAt: t.startedAt) } }
    private func remove(_ t: Todo) { act(t, "削除しました") { $0.delete(t.original, startedAt: t.startedAt) } }
    private func reopen(_ t: Todo) {
        ledgerStore.perform(t.original) { $0.reopen(t.original, startedAt: t.startedAt) }
        undo = nil
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
            // 決定事項は録音ごとに出し、削除・編集もその録音の項目にだけ効かせる。消したものは出さない
            var seenDecisions = Set<String>()  // 同じ録音で同じ文言が 2 回出たら 1 つにする (行の識別子を重ねない)
            let decisions = items.decisions.compactMap { d -> Todo? in
                guard seenDecisions.insert(TodoLedger.key(d)).inserted,
                      let shown = ledger.resolveDecision(d, recording: rec.id, startedAt: rec.startedAt) else { return nil }
                return Todo(original: TodoLedger.decisionOriginal(d, recording: rec.id), startedAt: rec.startedAt, display: shown,
                            completed: false, isDecision: true)
            }
            guard !decisions.isEmpty || !todos.isEmpty else { return nil }
            return Entry(id: rec.id, startedAt: rec.startedAt, decisions: decisions, todos: todos)
        }
        let byDay = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.startedAt) }
        return byDay.keys.sorted(by: >).map { DayGroup(day: $0, entries: byDay[$0] ?? []) }
    }
}

private struct ItemRow: View {
    let item: ActionItemsView.Todo

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label {
                Text(item.display).strikethrough(item.completed).foregroundStyle(item.completed ? .secondary : .primary)
            } icon: {
                Image(systemName: item.isDecision ? "checkmark.seal" : (item.completed ? "checkmark.circle.fill" : "circle"))
            }
            .font(.subheadline)
            Spacer(minLength: 4)
            Image(systemName: "pencil").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel((item.isDecision ? "決定事項 " : (item.completed ? "完了した TODO " : "TODO ")) + item.display)
    }
}

/// 一覧の項目の編集画面。文言を直して保存するほか、完了 (TODO だけ)・削除をここから選べる。
private struct ItemEditSheet: View {
    let item: ActionItemsView.Todo
    @State private var text: String
    var onSave: (String) -> Void
    var onComplete: () -> Void
    var onReopen: () -> Void
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(item: ActionItemsView.Todo, onSave: @escaping (String) -> Void, onComplete: @escaping () -> Void,
         onReopen: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.item = item
        _text = State(initialValue: item.display)
        self.onSave = onSave; self.onComplete = onComplete; self.onReopen = onReopen; self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(item.isDecision ? "決定事項" : "やること", text: $text, axis: .vertical)
                        .lineLimit(2...8)
                } footer: {
                    Text("空にして保存すると削除します。元の要約の文言は変えず、表示と書き出しに反映します。")
                }
                Section {
                    if !item.isDecision {
                        if item.completed {
                            Button { onReopen() } label: { Label("未完了に戻す", systemImage: "arrow.uturn.backward") }
                        } else {
                            Button { onComplete() } label: { Label("完了にする", systemImage: "checkmark.circle") }
                        }
                    }
                    Button(role: .destructive) { onDelete() } label: { Label("削除", systemImage: "trash") }
                } footer: {
                    Text(item.startedAt, format: .dateTime.month().day().hour().minute())
                }
            }
            .navigationTitle(item.isDecision ? "決定事項を編集" : "やることを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { onSave(text) }.bold() }
            }
        }
    }
}
