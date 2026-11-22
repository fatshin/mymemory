import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject var pipeline: Pipeline
    @Query(sort: \Recording.startedAt, order: .reverse) private var recordings: [Recording]
    @State private var showSettings = false
    @State private var query = ""
    @AppStorage(OnboardingView.doneKey) private var onboardingDone = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var home: HomeSummary?
    /// 保存済みの振り返りを読み直す合図 (生成・日付の変わり目・設定を閉じたとき)。
    @State private var refreshTick = 0
    @ObservedObject private var ledgerStore = TodoLedgerStore.shared
    @State private var editingTodo: HomeSummary.Todo?
    /// 編集画面を閉じた後に開く録音 (閉じる途中の遷移は無視されることがあるため、閉じ終わってから移る)。
    @State private var pendingOpen: UUID?
    @State private var undo: TodoUndo?
    /// やることの編集画面から録音の詳細へ移るための経路。
    @State private var path = NavigationPath()

    private func startEditing(_ t: HomeSummary.Todo) { editingTodo = t }

    /// 編集画面を開いている間に要約が作り直されても、今の一覧にある同じ項目に対して操作する。
    private func current(_ t: HomeSummary.Todo) -> HomeSummary.Todo {
        home?.todos.first { $0.id == t.id } ?? t
    }

    /// 完了・削除は台帳に記録し、数秒「元に戻す」を出す。要約の本文は書き換えない。
    private func complete(_ t: HomeSummary.Todo) {
        let previous = withAnimation { ledgerStore.perform(t.original) { $0.complete(t.original, startedAt: t.time) } }
        undo = TodoUndo(original: t.original, previous: previous, message: "完了しました")
    }

    private func remove(_ t: HomeSummary.Todo) {
        let previous = withAnimation { ledgerStore.perform(t.original) { $0.delete(t.original, startedAt: t.time) } }
        undo = TodoUndo(original: t.original, previous: previous, message: "削除しました")
    }

    private var days: [(day: Date, items: [Recording])] {
        // 文字起こしと要約の両方を検索する
        let filtered = query.isEmpty ? recordings : recordings.filter {
            ($0.transcript ?? "").localizedStandardContains(query) || ($0.summary ?? "").localizedStandardContains(query)
        }
        let cal = Calendar.current
        return Dictionary(grouping: filtered) { cal.startOfDay(for: $0.startedAt) }
            .map { (day: $0.key, items: $0.value.sorted { $0.startedAt < $1.startedAt }) }
            .sorted { $0.day > $1.day }
    }

    private func allItems(on day: Date) -> [Recording] {
        recordings.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// 録音・要約・文字起こしの増減で変わる軽い値。最初の表示の組み立てはこれが変わったときだけ行う。
    private var homeKey: Int {
        var h = Hasher()
        h.combine(refreshTick)
        h.combine(ledgerStore.revision)
        h.combine(Calendar.current.startOfDay(for: Date()))
        for rec in recordings.prefix(200) {
            // 本文全体ではなく長さで変化を見る (再描画のたびに全文をハッシュしない)
            h.combine(rec.id); h.combine(rec.summary?.count); h.combine(rec.transcript?.count); h.combine(rec.statusRaw)
        }
        return h.finalize()
    }

    /// 設定を開く必要がある状態 (充電待ち、継続処理の注意)。設定アイコンに印を付ける。
    private var needsAttention: Bool {
        (pipeline.waitingForPower && pipeline.pendingCount > 0) || pipeline.continuedNote != nil
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // 最初の表示は「まとめ」と「TODO」を 1 画面で読めることを優先する。
                // 文字起こしの処理状況や充電待ちは設定画面に置く (毎回見る情報ではないため)
                if let home, query.isEmpty {
                    Section {
                        TodayCard(home: home) {
                            DayReflectionView(day: home.day, items: home.items)
                        }
                        .listRowInsets(EdgeInsets())
                    }
                    Section {
                        if home.todos.isEmpty {
                            Text(home.reflection != nil ? "この日の振り返りに、やることはありません"
                                 : recordings.contains { $0.summary != nil } ? "直近\(HomeSummary.todoDays)日の会話に、やると決めたことはありません"
                                 : "要約ができると、会話で「やる」と決めたことがここに並びます")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(home.todos) { t in
                            // 押すと編集画面 (文言の編集・完了・削除・元の会話を開く)。丸を押すと完了
                            TodoRow(todo: t) { complete(t) }
                                .contentShape(.rect)
                                .onTapGesture { startEditing(t) }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityHint("編集画面を開きます")
                                .accessibilityAction { startEditing(t) }
                            // 左へスワイプで削除・編集、右へスワイプで完了 (完了は一覧から外す)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { remove(t) } label: { Label("削除", systemImage: "trash") }
                                Button { startEditing(t) } label: { Label("編集", systemImage: "pencil") }.tint(.blue)
                            }
                            .swipeActions(edge: .leading) {
                                Button { complete(t) } label: { Label("完了", systemImage: "checkmark") }.tint(.green)
                            }
                            .contextMenu {
                                Button { complete(t) } label: { Label("完了", systemImage: "checkmark.circle") }
                                Button { startEditing(t) } label: { Label("編集", systemImage: "pencil") }
                                Button(role: .destructive) { remove(t) } label: { Label("削除", systemImage: "trash") }
                            }
                        }
                        if home.todoOverflow > 0 {
                            NavigationLink { ActionItemsView() } label: {
                                Text("ほか \(home.todoOverflow) 件").font(.callout).foregroundStyle(Theme.accentText)
                            }
                        }
                    } header: {
                        HStack {
                            Label("やること", systemImage: "checklist").font(.subheadline.bold()).foregroundStyle(.primary)
                            Spacer()
                            NavigationLink { ActionItemsView() } label: { Text("すべて").font(.caption.bold()) }
                        }
                        .textCase(nil)
                    }
                }
                ForEach(days, id: \.day) { group in
                    Section {
                        ForEach(group.items) { rec in
                            NavigationLink(value: rec.id) { Row(rec: rec, preferTranscript: !query.isEmpty) }
                        }
                    } header: {
                        HStack {
                            Text(group.day, format: .dateTime.month().day().weekday())
                                .font(.subheadline.bold()).foregroundStyle(.primary)
                            Spacer()
                            // 検索中でも 1 日分は全件を渡す (書き出しで録音が黙って欠けないように)
                            NavigationLink { DayReflectionView(day: group.day, items: allItems(on: group.day)) } label: {
                                Label("振り返り", systemImage: "sparkles").font(.caption.bold())
                            }
                            .tint(Theme.accentText)
                        }
                        .textCase(nil)
                    }
                }
            }
            .searchable(text: $query, prompt: "文字起こし・要約を検索")
            .overlay {
                if recordings.isEmpty {
                    ContentUnavailableView {
                        Label("まだ録音がありません", systemImage: "applewatch.radiowaves.left.and.right")
                    } description: {
                        Text("Apple Watch の MyMemory で録音を始めると、ここに1日の記録が並びます")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let rec = recordings.first(where: { $0.id == id }) { DetailView(rec: rec) }
            }
            // 解析は録音や要約が変わったときだけ行い、処理状況の更新による再描画のたびには行わない
            .task(id: homeKey) {
                home = HomeSummary.build(recordings: recordings, ledger: ledgerStore.ledger)
                // 読み込み前や障害で一覧が空のときに全日を消さないよう、録音があるときだけ掃除する
                if !recordings.isEmpty {
                    ReflectionStore.purge(keepingDays: Array(Set(recordings.map { Calendar.current.startOfDay(for: $0.startedAt) })))
                }
            }
            .onAppear { refreshTick += 1 }
            .onChange(of: scenePhase) { _, p in if p == .active { refreshTick += 1 } }
            .onChange(of: showSettings) { _, shown in if !shown { refreshTick += 1 } }
            // まとめカードが「今日」を名乗るので、大きなタイトルは使わず縦の余白を空ける
            .navigationTitle("MyMemory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { ActionItemsView() } label: { Image(systemName: "checklist") }
                        .accessibilityLabel("決定事項・TODO")
                }
                ToolbarItem {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape").overlay(alignment: .topTrailing) {
                            if needsAttention {
                                Circle().fill(Theme.accent).frame(width: 7, height: 7).offset(x: 3, y: -3)
                            }
                        }
                    }
                    .accessibilityLabel(needsAttention ? "設定 (文字起こしの確認があります)" : "設定")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(isPresented: .constant(!onboardingDone)) { OnboardingView() }
            .sheet(item: $editingTodo, onDismiss: {
                if let id = pendingOpen { pendingOpen = nil; path.append(id) }
            }) { t in
                TodoEditSheet(todo: t,
                              onSave: { text in
                                  let c = current(t)
                                  editingTodo = nil
                                  // 空にしたら削除 (元に戻せるよう、削除と同じ扱いにする)
                                  if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { remove(c); return }
                                  ledgerStore.perform(c.original) { $0.edit(c.original, startedAt: c.time, to: text) }
                                  undo = nil  // 編集の後に古い「元に戻す」を押して編集まで消さない
                              },
                              onComplete: { let c = current(t); editingTodo = nil; complete(c) },
                              onDelete: { let c = current(t); editingTodo = nil; remove(c) },
                              onOpen: { pendingOpen = t.recordingID; editingTodo = nil })
                    .presentationDetents([.medium, .large])
            }
            .overlay(alignment: .bottom) { UndoBanner(undo: $undo) }
        }
    }
}

/// やることの編集画面。文言を直して保存するほか、完了・削除・元の会話を開くをここから選べる。
private struct TodoEditSheet: View {
    let todo: HomeSummary.Todo
    @State private var text: String
    var onSave: (String) -> Void
    var onComplete: () -> Void
    var onDelete: () -> Void
    var onOpen: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(todo: HomeSummary.Todo, onSave: @escaping (String) -> Void, onComplete: @escaping () -> Void,
         onDelete: @escaping () -> Void, onOpen: @escaping () -> Void) {
        self.todo = todo
        _text = State(initialValue: todo.text)
        self.onSave = onSave; self.onComplete = onComplete; self.onDelete = onDelete; self.onOpen = onOpen
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("やること", text: $text, axis: .vertical)
                        .lineLimit(2...8)
                } footer: {
                    Text("空にして保存すると削除します。元の要約の文言は変えず、表示と書き出しに反映します。")
                }
                Section {
                    Button { onComplete() } label: { Label("完了にする", systemImage: "checkmark.circle") }
                    Button { onOpen() } label: { Label("元の会話を開く", systemImage: "text.bubble") }
                    Button(role: .destructive) { onDelete() } label: { Label("削除", systemImage: "trash") }
                } footer: {
                    HStack(spacing: 4) {
                        Text(todo.time, format: .dateTime.month().day().hour().minute())
                        if let c = todo.context { Text(c).lineLimit(1) }
                    }
                }
            }
            .navigationTitle("やることを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { onSave(text) }.bold() }
            }
        }
    }
}

private struct TodoRow: View {
    let todo: HomeSummary.Todo
    var onComplete: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // 丸を押すと完了 (一覧から外す)
            Button(action: onComplete) {
                Image(systemName: "circle").font(.body).foregroundStyle(Theme.accentText)
                    .frame(width: 32, height: 32).contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("完了にする")
            VStack(alignment: .leading, spacing: 2) {
                Text(todo.text).font(.callout)
                // どの会話から出たかを添える (やることの文だけでは用件が分からないことがあるため)
                HStack(spacing: 4) {
                    Text(todo.time, format: .dateTime.month().day().hour().minute())
                    if let context = todo.context { Text(context).lineLimit(1) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "pencil").font(.footnote).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}

private struct Row: View {
    let rec: Recording
    /// 検索中は、一致した本文が見えるよう文字起こしを優先する。
    var preferTranscript = false

    /// 保存値 (英語) はそのままに、表示だけ日本語にする。
    static func statusLabel(_ raw: String) -> String {
        switch raw {
        case "pending": return "待機中"
        case "transcribing": return "文字起こし中"
        case "done": return "完了"
        case "failed": return "失敗"
        default: return raw
        }
    }
    /// 一覧に出す 1 行目。要約の要点があればそれ、なければ文字起こしの冒頭。
    private var preview: String? {
        let transcript = rec.transcript.flatMap { $0.isEmpty ? nil : $0 }
        if preferTranscript, let transcript { return transcript }
        return rec.keyPoint ?? transcript
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.startedAt, format: .dateTime.hour().minute())
                    .font(.system(.title3, design: .rounded).bold()).monospacedDigit()
                Label("\(Int(rec.duration / 60))分", systemImage: "waveform")
                    .font(.caption2).foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
            .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                StatusBadge(raw: rec.statusRaw, label: Self.statusLabel(rec.statusRaw))
                if let preview {
                    Text(preview).lineLimit(2).font(.subheadline)
                } else if rec.statusRaw == "done", let e = rec.errorMessage {
                    Text(e).lineLimit(2).font(.footnote).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct DetailView: View {
    @EnvironmentObject var pipeline: Pipeline
    /// 台帳が変わったら要約の表示 (やることの完了・削除・編集) を更新する。
    @ObservedObject private var ledgerStore = TodoLedgerStore.shared
    @Environment(\.modelContext) private var ctx
    let rec: Recording
    @State private var summarizing = false
    @State private var job: Task<Void, Never>?
    /// 今使える要約の経路 (経路ごとにボタンを出し、押したほうで要約する)。
    @State private var routes: [SummaryRoute] = []
    @State private var error: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var level: AudioLevel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // やることには台帳 (完了・削除・編集) を重ねて見せる。保存している要約の本文はそのまま
                if let s = rec.summary {
                    Section("要約") {
                        Text(ledgerStore.ledger.overlay(summary: s, startedAt: rec.startedAt)).textSelection(.enabled)
                    }
                }
                if let t = rec.transcript {
                    Section {
                        Text(t).textSelection(.enabled)
                        if let raw = rec.rawTranscript {
                            DisclosureGroup("校正前の文字起こし") { Text(raw).textSelection(.enabled) }
                        }
                    } header: {
                        Text("文字起こし")
                    } footer: {
                        if rec.rawTranscript != nil { Text("誤変換を端末内で直しています。") }
                    }
                }
                // 無音などで文字が残らなかった案内 (status は done) は失敗ではないため赤にしない
                if let e = rec.errorMessage ?? error { Text(e).foregroundStyle(rec.statusRaw == "done" && error == nil ? .orange : .red) }
                // 実機での切り分け用: 音声ファイルの実際の長さと最大音量
                if let level { Text("音声: \(Int(level.duration))秒・声らしい時間 \(Int(level.voicedSeconds))秒・最大音量 \(Int(level.peakDBFS)) dBFS").font(.caption).foregroundStyle(.secondary) }
            }
            .padding()
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    // 端末内と外部 API の両方が使えるときは両方を出し、要約のたびに選べるようにする
                    ForEach(routes.isEmpty ? [nil] : routes.map(Optional.some), id: \.self) { r in
                        Button(summarizing ? "要約中…" : "要約" + routeSuffix(r)) {
                            job = Task { await summarize(route: r) }
                        }
                        .disabled(rec.transcript == nil || summarizing)
                    }
                    ShareLink(item: ExportFormatter.recording(rec.exportEntry)) {
                        Label("書き出し", systemImage: "square.and.arrow.up")
                    }
                    // 自動削除などで音声が無い録音は、文字起こしし直せない
                    if FileManager.default.fileExists(atPath: rec.fileURL.path) {
                        Button("再文字起こし") { pipeline.retry(rec) }
                        ShareLink(item: rec.fileURL) { Label("音声ファイルを共有", systemImage: "waveform") }
                    }
                    Button("削除", role: .destructive) {
                        try? FileManager.default.removeItem(at: rec.fileURL)
                        ctx.delete(rec)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear { routes = Summarizer.usableRoutes() }
        .onChange(of: scenePhase) { _, p in if p == .active { routes = Summarizer.usableRoutes() } }
        .task(id: rec.fileName) {
            let url = rec.fileURL
            level = await Task.detached(priority: .utility) { AudioLevel.measure(url) }.value
        }
        .onDisappear { job?.cancel() }  // 画面を離れたら要約を止めて電力を使わない
    }

    private func summarize(route tapped: SummaryRoute?) async {
        guard let t = rec.transcript else { return }
        summarizing = true; error = nil
        defer { summarizing = false }
        do {
            let route = try pickRoute(tapped) { routes = $0 }
            // 表示する前に端末内モデルで見直す
            let result = try await Summarizer.reviewOrKeep(Summarizer.summarize(t, route: route))
            // 削除された録音や、待つ間に文字起こし直された録音には書かない
            guard rec.isAlive, rec.transcript == t else { return }
            rec.summary = result.labeled
            try ctx.save()
            if !result.reviewed, OnDeviceSummarizer.isAvailable {
                error = "端末内モデルで見直せなかったため、見直し前の要約を表示しています"
            }
        } catch where Task.isCancelled || error is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 送信先を押す前に示す。外部 API へ送るときは必ず分かるようにする。
func routeSuffix(_ route: SummaryRoute?) -> String {
    switch route {
    case .onDevice: return " (端末内)"
    case .remote: return " (外部APIへ送信)"
    case nil: return ""
    }
}

/// 押したボタンの経路を、押した時点で使えることを確かめて返す。経路の無いボタン (nil) は理由を示して止める。
/// 使える経路が変わっていたら表示を更新する。
@MainActor
func pickRoute(_ tapped: SummaryRoute?, update: ([SummaryRoute]) -> Void) throws -> SummaryRoute {
    defer { update(Summarizer.usableRoutes()) }
    if let tapped { return try Summarizer.confirmUsable(tapped) }
    return try confirmedRoute(shown: nil) { _ in }
}

/// ボタンに表示した経路とタップ時点の経路が一致するときだけ実行する。
/// 表示が古いまま外部 API へ送ることを防ぐ。ずれていれば表示を更新して止める。
@MainActor
func confirmedRoute(shown: SummaryRoute?, update: (SummaryRoute?) -> Void) throws -> SummaryRoute {
    let now: SummaryRoute
    do { now = try Summarizer.currentRoute() } catch { update(nil); throw error }
    guard now == shown else {
        update(now)
        throw Summarizer.Failure(message: "要約の送信先が変わりました。ボタンの表示を確認してもう一度押してください")
    }
    return now
}

extension Recording {
    /// 削除済み、または保存先から外れた録音ではない。
    var isAlive: Bool { !isDeleted && modelContext != nil }

    /// 書き出しには、やること台帳を重ねた要約を使う (完了は [x]、削除は出さない、編集後の文言)。
    @MainActor var exportEntry: ExportEntry {
        ExportEntry(startedAt: startedAt, duration: duration,
                    summary: summary.map { TodoLedgerStore.shared.ledger.overlay(summary: $0, startedAt: startedAt) },
                    transcript: transcript)
    }
}

struct SettingsView: View {
    @State private var provider = Summarizer.provider
    @State private var keys: [RemoteProvider: String] = Dictionary(uniqueKeysWithValues: RemoteProvider.allCases.map { ($0, Keychain.get($0.keyName) ?? "") })
    @State private var models: [RemoteProvider: String] = Dictionary(uniqueKeysWithValues: RemoteProvider.allCases.map { ($0, UserDefaults.standard.string(forKey: Summarizer.modelKey($0)) ?? "") })
    /// 送信の許可。送信先・キーと同じく「保存」で疎通を確かめてから書く (失敗や取り消しで一部だけ残さない)。
    @State private var remoteAllowed = Summarizer.isAllowed(Summarizer.provider)
    @State private var modelLists: [RemoteProvider: [String]] = [:]
    @State private var listError: String?
    @State private var loadingList = false
    @State private var preference = Summarizer.preferred
    /// 保存前の疎通確認の状態。確認に通るまで Keychain にも UserDefaults にも書かない。
    @State private var verifying = false
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?
    @AppStorage(RetentionPolicy.key) private var retentionDays = 0
    @EnvironmentObject var pipeline: Pipeline
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                // 文字起こしの処理状況と充電待ちの操作。メイン画面からはここへ移した
                Section("文字起こし") {
                    Label(pipeline.modelStatus, systemImage: "waveform")
                    if let note = pipeline.continuedNote {
                        Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if pipeline.waitingForPower && pipeline.pendingCount > 0 {
                        Button {
                            pipeline.startNow()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("今すぐ文字起こし (\(pipeline.pendingCount)件)", systemImage: "waveform.badge.plus")
                                    .font(.body.bold())
                                Text("画面を閉じても続けて処理します。電池残量が\(Int(PowerPolicy.minimumLevelUserInitiated * 100))%以上のときに使えます")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    switch OnDeviceSummarizer.status {
                    case .available:
                        Label("端末内モデルを利用できます (通信なし)", systemImage: "iphone")
                    case .unavailable(let reason):
                        Label(reason, systemImage: "exclamationmark.triangle")
                        Text("APIキーを登録し送信を許可すると、\(Summarizer.remoteRecipient)で要約します").font(.footnote)
                    }
                    Picker("要約に使う", selection: $preference) {
                        Text("端末内 (通信なし)").tag(SummaryRoute.onDevice)
                        Text("外部API (\(provider.displayName))").tag(SummaryRoute.remote)
                    }
                    if preference == .remote, !(remoteAllowed && hasSavedKey) {
                        Text("APIキーを保存し、下の送信を許可するまでは端末内で要約します").font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("要約")
                } footer: {
                    Text("自動の要約と振り返りはここで選んだ経路を使います。両方使えるときは、録音の詳細画面と振り返りでも要約のたびに選べます。")
                }
                Section {
                    Picker("送信先", selection: $provider) {
                        ForEach(RemoteProvider.allCases) { Text($0.displayName).tag($0) }
                    }
                    // 送信先を変えたら、許可を取り直す (許可した相手と実際の送信先をずらさない)
                    .onChange(of: provider) { _, _ in remoteAllowed = false }
                    Toggle("文字起こしテキストを\(provider.recipient)に送信して要約する (文字起こしの後に自動で送信)", isOn: $remoteAllowed)
                    SecureField("\(provider.displayName) APIキー (\(provider.keyPlaceholder))", text: Binding(
                        get: { keys[provider] ?? "" }, set: { keys[provider] = $0 }))
                    Button(loadingList ? "モデル一覧を取得中…" : "使えるモデルを一覧から選ぶ") { fetchModels() }
                        .disabled(loadingList || (keys[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let list = modelLists[provider] {
                        Picker("モデル", selection: Binding(
                            get: { effectiveModel(provider) }, set: { models[provider] = $0 })) {
                            // 保存済みのモデルが一覧に無いときも、選び直すまでは表示しておく
                            if !list.contains(effectiveModel(provider)) {
                                Text("\(effectiveModel(provider)) (一覧にありません)").tag(effectiveModel(provider))
                            }
                            ForEach(list, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    if let listError { Text(listError).font(.footnote).foregroundStyle(.red) }
                    TextField("モデル名を直接入力 (空欄は \(provider.defaultModel))", text: Binding(
                        get: { models[provider] ?? "" }, set: { models[provider] = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("外部への送信 (任意・既定はオフ)")
                } footer: {
                    Text("オンにすると、「要約に使う」で外部APIを選んだとき、または端末内で要約できないときに、文字起こしテキストを\(provider.recipient)へ送ります。音声は送りません。APIキーは保存の前に、確認用の短い定型文 (文字起こしは含みません) と選んだモデル名を\(provider.recipient)へ送って接続を確かめ、成功したときだけこの端末のKeychainに保存します。送信先を変えると許可はオフに戻ります。「要約に使う」で外部APIを選んで保存すると、まだ要約の無い過去の録音も順に送ります。モデルの一覧を取得するときは、APIキーだけを\(provider.recipient)へ送ります。")
                }
                Section {
                    Picker("古い音声を自動で削除", selection: $retentionDays) {
                        ForEach(RetentionPolicy.choices, id: \.self) { d in
                            Text(d == 0 ? "しない" : "\(d)日より前").tag(d)
                        }
                    }
                    .onChange(of: retentionDays) { _, _ in pipeline.pruneOldAudio() }
                } header: {
                    Text("プライバシーと容量")
                } footer: {
                    Text("録音と文字起こしはこの端末内に保存します。自動削除で消すのは文字起こし済みの音声だけで、文字起こしと要約は残ります。録音は詳細画面のメニューから個別に削除できます。")
                }
                Section {
                    NavigationLink { PromptLabView() } label: {
                        Label("要約の指示をカスタマイズ・比べる", systemImage: "text.badge.star")
                    }
                    Link("プライバシーポリシー", destination: AppLinks.privacy)
                }
            }
            .navigationTitle("設定")
            // 確認中に送信先や許可を変えて、確かめていない組み合わせを保存しない
            .disabled(verifying)
            .toolbar {
                Button(verifying ? "接続を確認中…" : "保存") { save() }
                    .disabled(verifying)
            }
            .interactiveDismissDisabled(verifying)
            .onDisappear { saveTask?.cancel() }
            .alert("保存できません", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text((saveError ?? "") + "\nAPIキーとモデル名は保存していません。")
            }
        }
    }

    private var hasSavedKey: Bool { !(Keychain.get(provider.keyName) ?? "").isEmpty }

    private static func trimmed(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    /// キーかモデルを変えた送信先は、入力値で疎通を確かめてから保存する。1 つでも失敗したら何も書かず、画面も閉じない。
    /// 空にしたキーは削除なので確かめない。
    private func save() {
        let toVerify = RemoteProvider.allCases.filter { p in
            let k = Self.trimmed(keys[p]), m = Self.trimmed(models[p])
            return !k.isEmpty && (k != Self.trimmed(Keychain.get(p.keyName))
                                  || m != Self.trimmed(UserDefaults.standard.string(forKey: Summarizer.modelKey(p))))
        }
        let keysNow = keys, modelsNow = models, providerNow = provider, preferenceNow = preference, allowedNow = remoteAllowed
        verifying = true
        saveError = nil
        saveTask = Task {
            defer { verifying = false }
            for p in toVerify {
                do {
                    try await Summarizer.verifyConnection(p, key: keysNow[p] ?? "", model: modelsNow[p] ?? "")
                } catch is CancellationError {
                    return
                } catch {
                    saveError = error.localizedDescription
                    return
                }
            }
            guard !Task.isCancelled else { return }
            Summarizer.provider = providerNow
            Summarizer.preferred = preferenceNow
            // 許可した相手を記録する (Summarizer は記録した相手にしか送らない)
            UserDefaults.standard.set(allowedNow, forKey: Summarizer.remoteAllowedKey)
            UserDefaults.standard.set(allowedNow ? providerNow.rawValue : nil, forKey: Summarizer.remoteAllowedProviderKey)
            for p in RemoteProvider.allCases {
                Keychain.set(Self.trimmed(keysNow[p]), for: p.keyName)
                UserDefaults.standard.set(Self.trimmed(modelsNow[p]), forKey: Summarizer.modelKey(p))
            }
            dismiss()
        }
    }

    private func effectiveModel(_ p: RemoteProvider) -> String {
        let m = (models[p] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? p.defaultModel : m
    }

    /// 入力欄のキー (保存前) で、送信先の実在するモデルを取得する。
    private func fetchModels() {
        let p = provider, key = keys[p] ?? ""
        loadingList = true
        listError = nil
        Task {
            do {
                let list = try await Summarizer.listModels(p, key: key)
                modelLists[p] = list
                // 既定のモデルが実在しなければ、一覧の先頭 (新しいもの) を選んでおく
                if (models[p] ?? "").isEmpty, !list.contains(p.defaultModel), let first = list.first { models[p] = first }
            } catch {
                listError = error.localizedDescription
            }
            loadingList = false
        }
    }
}

/// 1日分の文字起こしを時系列に連結し、日次リフレクションを生成 (ライフログ補完の中核)。
struct DayReflectionView: View {
    @Environment(\.modelContext) private var ctx
    let day: Date
    let items: [Recording]
    @State private var text: String?
    @State private var loading = false
    @State private var progress: String?
    @State private var job: Task<Void, Never>?
    @State private var routes: [SummaryRoute] = []
    @State private var error: String?
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var ledgerStore = TodoLedgerStore.shared

    /// 振り返りの【TODO】は言い回しが変わり台帳と照合できないため、その日の録音のやること (台帳適用後) に差し替える。
    private func dayReflectionText(_ text: String) -> String {
        let todos = HomeSummary.openTodos(from: items, ledger: ledgerStore.ledger)
        let body = todos.isEmpty ? "- なし" : todos.map { "- " + $0.text }.joined(separator: "\n")
        return ReflectionSections.replacingSection("TODO", in: text, with: body)
    }

    private var timeline: String {
        items.compactMap { r in
            guard let t = r.transcript, !t.isEmpty else { return nil }
            return "[\(r.startedAt.formatted(date: .omitted, time: .shortened))] \(t)"
        }.joined(separator: "\n\n")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let progress, loading { Text(progress).font(.caption).foregroundStyle(.secondary) }
                if let text { ReflectionCards(text: dayReflectionText(text)) }
                if let error { Text(error).foregroundStyle(.red) }
                VStack(alignment: .leading, spacing: 8) {
                    Label("タイムライン", systemImage: "list.bullet.rectangle").font(.headline)
                    Text(timeline.isEmpty ? "文字起こしなし" : timeline).font(.footnote).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }.padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(day.formatted(date: .abbreviated, time: .omitted))
        .toolbar {
            ShareLink(item: MarkdownFile(name: ExportFormatter.fileName(for: day),
                                         text: ExportFormatter.day(day, entries: items.map(\.exportEntry), reflection: text.map(dayReflectionText))),
                      preview: SharePreview(ExportFormatter.fileName(for: day))) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("1日分を書き出し")
            // 端末内と外部 API の両方が使えるときは、生成のたびに選べるようメニューにする
            if routes.count > 1 {
                Menu(loading ? "生成中…" : "振り返り生成") {
                    ForEach(routes, id: \.self) { r in
                        Button("振り返り生成" + routeSuffix(r)) { job = Task { await run(route: r) } }
                    }
                }
                .disabled(loading || timeline.isEmpty)
            } else {
                Button(loading ? "生成中…" : "振り返り生成" + routeSuffix(routes.first)) { job = Task { await run(route: routes.first) } }
                    .disabled(loading || timeline.isEmpty)
            }
        }
        .onAppear {
            routes = Summarizer.usableRoutes()
            if text == nil { text = ReflectionStore.load(day)?.text }
        }
        .onChange(of: scenePhase) { _, p in if p == .active { routes = Summarizer.usableRoutes() } }
        .onDisappear { job?.cancel() }  // 画面を離れたら残りの録音の要約を止める
    }

    /// 録音ごとの要約を再利用し、無い録音だけをその場で要約して保存してから、1 日分を束ねる。
    /// 毎回すべての文字起こしを要約し直すより、電力と時間を抑えられる。
    private func run(route tapped: SummaryRoute?) async {
        loading = true; error = nil
        defer { loading = false; progress = nil }
        do {
            // 経路は開始時に 1 回だけ決める。途中で端末内と外部 API が混ざらないようにする
            let route = try pickRoute(tapped) { routes = $0 }
            let targets = items.filter { !($0.transcript ?? "").isEmpty }
            var lines: [String] = []
            var failed = 0
            var saveError: String?
            for (i, r) in targets.enumerated() {
                try Task.checkCancellation()
                let s: String
                if let saved = r.summary {
                    s = Self.stripRouteLabel(saved)
                } else if let t = r.transcript {
                    progress = "録音を要約中 \(i + 1) / \(targets.count)"
                    do {
                        let result = try await Summarizer.reviewOrKeep(Summarizer.summarize(t, route: route))
                        s = result.text
                        // 削除された録音や、待つ間に文字起こし直された録音には保存しない
                        if r.isAlive, r.transcript == t {
                            r.summary = result.labeled
                            do { try ctx.save() } catch { saveError = error.localizedDescription }
                        }
                    } catch where Task.isCancelled || error is CancellationError {
                        throw CancellationError()
                    } catch {
                        // 1 本が要約できなくても 1 日分は作る。失敗分は保存せず、次回また試す
                        s = "(この録音は要約できませんでした)"
                        failed += 1
                    }
                } else {
                    continue
                }
                guard r.isAlive else { continue }
                lines.append("[\(r.startedAt.formatted(date: .omitted, time: .shortened))] \(s)")
            }
            try Task.checkCancellation()
            // 全部失敗した日は中身のない振り返りを出さない (通信断・キー無効など)
            if !lines.isEmpty, failed == lines.count {
                throw Summarizer.Failure(message: "録音をひとつも要約できませんでした。通信やAPIキー、端末内モデルの状態を確認してください")
            }
            if let saveError { self.error = "要約の保存に失敗: \(saveError)" }
            progress = "1日分をまとめています"
            let result = try await Summarizer.reflect(timeline: lines.joined(separator: "\n"), route: route).labeled
            text = result
            ReflectionStore.save(result, for: day, recordingCount: items.count, latestStart: items.map(\.startedAt).max())
        } catch where Task.isCancelled || error is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 保存済み要約の末尾にある「(端末内で要約)」などの注記を、束ねる前に外す。
    static func stripRouteLabel(_ s: String) -> String {
        // 送信先ごとに注記が変わる (「(OpenAI で要約)」など) ため、最終行の形で判定する
        guard let r = s.range(of: "\n\n", options: .backwards),
              ReflectionSections.isRouteLabel(String(s[r.upperBound...])) else { return s }
        return String(s[..<r.lowerBound])
    }
}
