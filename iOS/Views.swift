import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject var pipeline: Pipeline
    @Query(sort: \Recording.startedAt, order: .reverse) private var recordings: [Recording]
    @State private var showSettings = false
    @State private var showPaywall = false
    @EnvironmentObject var store: Store
    @State private var query = ""
    @AppStorage(OnboardingView.doneKey) private var onboardingDone = false

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

    var body: some View {
        NavigationStack {
            List {
                if pipeline.quotaHeld > 0 && !store.isPro {
                    Section {
                        Button {
                            showPaywall = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("今日の無料枠 (\(Int(PlanConfig.freeDailySeconds / 60))分) を使い切りました").font(.subheadline.bold())
                                Text("\(pipeline.quotaHeld)件の録音は消えずに残り、明日またはProで文字起こしされます").font(.caption)
                            }
                        }
                    }
                }
                ForEach(days, id: \.day) { group in
                    Section {
                        ForEach(group.items) { rec in
                            NavigationLink(value: rec.id) { Row(rec: rec) }
                        }
                    } header: {
                        HStack {
                            Text(group.day, format: .dateTime.year().month().day().weekday())
                            Spacer()
                            // 検索中でも 1 日分は全件を渡す (書き出しで録音が黙って欠けないように)
                            NavigationLink("振り返り") { DayReflectionView(day: group.day, items: allItems(on: group.day)) }
                                .font(.caption)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "文字起こし・要約を検索")
            .overlay { if recordings.isEmpty { ContentUnavailableView("録音なし", systemImage: "applewatch", description: Text("Watchで録音を開始")) } }
            .navigationDestination(for: UUID.self) { id in
                if let rec = recordings.first(where: { $0.id == id }) { DetailView(rec: rec) }
            }
            .navigationTitle("MyMemory")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Text(pipeline.modelStatus).font(.caption2) }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { ActionItemsView() } label: { Image(systemName: "checklist") }
                        .accessibilityLabel("決定事項・TODO")
                }
                ToolbarItem { Button { showSettings = true } label: { Image(systemName: "gearshape") } }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .fullScreenCover(isPresented: .constant(!onboardingDone)) { OnboardingView() }
        }
    }
}

private struct Row: View {
    let rec: Recording
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(rec.startedAt, format: .dateTime.month().day().hour().minute()).font(.headline)
                Spacer()
                Text(rec.statusRaw).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(Int(rec.duration / 60))分").font(.caption)
            if let t = rec.transcript { Text(t).lineLimit(2).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

struct DetailView: View {
    @EnvironmentObject var pipeline: Pipeline
    @Environment(\.modelContext) private var ctx
    let rec: Recording
    @State private var summarizing = false
    @State private var job: Task<Void, Never>?
    @State private var shownRoute: SummaryRoute?
    @State private var error: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let s = rec.summary { Section("要約") { Text(s).textSelection(.enabled) } }
                if let t = rec.transcript { Section("文字起こし") { Text(t).textSelection(.enabled) } }
                if let e = rec.errorMessage ?? error { Text(e).foregroundStyle(.red) }
            }
            .padding()
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button(summarizing ? "要約中…" : "要約" + routeSuffix(shownRoute)) {
                        job = Task { await summarize() }
                    }
                    .disabled(rec.transcript == nil || summarizing)
                    ShareLink(item: ExportFormatter.recording(rec.exportEntry)) {
                        Label("書き出し", systemImage: "square.and.arrow.up")
                    }
                    // 自動削除などで音声が無い録音は、文字起こしし直せない
                    if FileManager.default.fileExists(atPath: rec.fileURL.path) {
                        Button("再文字起こし") { pipeline.retry(rec) }
                    }
                    Button("削除", role: .destructive) {
                        try? FileManager.default.removeItem(at: rec.fileURL)
                        ctx.delete(rec)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear { shownRoute = try? Summarizer.currentRoute() }
        .onChange(of: scenePhase) { _, p in if p == .active { shownRoute = try? Summarizer.currentRoute() } }
        .onDisappear { job?.cancel() }  // 画面を離れたら要約を止めて電力を使わない
    }

    private func summarize() async {
        guard let t = rec.transcript else { return }
        summarizing = true; error = nil
        defer { summarizing = false }
        do {
            let route = try confirmedRoute(shown: shownRoute) { shownRoute = $0 }
            let result = try await Summarizer.summarize(t, route: route)
            // 削除された録音や、待つ間に文字起こし直された録音には書かない
            guard rec.isAlive, rec.transcript == t else { return }
            rec.summary = result.labeled
            try ctx.save()
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

    var exportEntry: ExportEntry {
        ExportEntry(startedAt: startedAt, duration: duration, summary: summary, transcript: transcript)
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var showPaywall = false
    @State private var key = Keychain.get(Summarizer.keyName) ?? ""
    @AppStorage(Summarizer.remoteAllowedKey) private var remoteAllowed = false
    @AppStorage(RetentionPolicy.key) private var retentionDays = 0
    @EnvironmentObject var pipeline: Pipeline
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("MyMemory Pro") {
                    if store.isPro {
                        Label("Pro を利用中 (文字起こしの時間制限なし)", systemImage: "checkmark.seal")
                    } else {
                        Text("無料プラン: 文字起こしは1日\(Int(PlanConfig.freeDailySeconds / 60))分まで").font(.footnote)
                        Button("Pro にする / 購入を復元") { showPaywall = true }
                    }
                }
                Section("要約") {
                    switch OnDeviceSummarizer.status {
                    case .available:
                        Label("端末内で要約 (通信なし)", systemImage: "iphone")
                    case .unavailable(let reason):
                        Label(reason, systemImage: "exclamationmark.triangle")
                        Text("APIキーを登録し送信を許可すると、\(Summarizer.remoteRecipient)で要約します").font(.footnote)
                    }
                }
                Section {
                    Toggle("文字起こしテキストを\(Summarizer.remoteRecipient)に送信して要約する", isOn: $remoteAllowed)
                    SecureField("Anthropic APIキー (sk-ant-…)", text: $key)
                } header: {
                    Text("外部への送信 (任意・既定はオフ)")
                } footer: {
                    Text("オンにすると、端末内で要約できないときに限り、文字起こしテキストを\(Summarizer.remoteRecipient)へ送ります。音声は送りません。APIキーはこの端末のKeychainにのみ保存します。")
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
            }
            .navigationTitle("設定")
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .toolbar { Button("保存") { Keychain.set(key, for: Summarizer.keyName); dismiss() } }
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
    @State private var shownRoute: SummaryRoute?
    @State private var error: String?
    @Environment(\.scenePhase) private var scenePhase

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
                if let text { Text(text).textSelection(.enabled) }
                if let error { Text(error).foregroundStyle(.red) }
                Section("タイムライン") { Text(timeline.isEmpty ? "文字起こしなし" : timeline).font(.footnote).textSelection(.enabled) }
            }.padding()
        }
        .navigationTitle(day.formatted(date: .abbreviated, time: .omitted))
        .toolbar {
            ShareLink(item: MarkdownFile(name: ExportFormatter.fileName(for: day),
                                         text: ExportFormatter.day(day, entries: items.map(\.exportEntry), reflection: text)),
                      preview: SharePreview(ExportFormatter.fileName(for: day))) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("1日分を書き出し")
            Button(loading ? "生成中…" : "振り返り生成" + routeSuffix(shownRoute)) { job = Task { await run() } }
                .disabled(loading || timeline.isEmpty)
        }
        .onAppear { shownRoute = try? Summarizer.currentRoute() }
        .onChange(of: scenePhase) { _, p in if p == .active { shownRoute = try? Summarizer.currentRoute() } }
        .onDisappear { job?.cancel() }  // 画面を離れたら残りの録音の要約を止める
    }

    /// 録音ごとの要約を再利用し、無い録音だけをその場で要約して保存してから、1 日分を束ねる。
    /// 毎回すべての文字起こしを要約し直すより、電力と時間を抑えられる。
    private func run() async {
        loading = true; error = nil
        defer { loading = false; progress = nil }
        do {
            // 経路は開始時に 1 回だけ決める。途中で端末内と外部 API が混ざらないようにする
            let route = try confirmedRoute(shown: shownRoute) { shownRoute = $0 }
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
                        let result = try await Summarizer.summarize(t, route: route)
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
            text = try await Summarizer.reflect(timeline: lines.joined(separator: "\n"), route: route).labeled
        } catch where Task.isCancelled || error is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 保存済み要約の末尾にある「(端末内で要約)」などの注記を、束ねる前に外す。
    static func stripRouteLabel(_ s: String) -> String {
        for label in ["\n\n(端末内で要約)", "\n\n(外部APIで要約)"] where s.hasSuffix(label) {
            return String(s.dropLast(label.count))
        }
        return s
    }
}
