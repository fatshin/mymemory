import SwiftUI
import SwiftData

/// 要約への追加の指示を書き、同じ録音で「今の指示」と「編集中の指示」の要約を並べて比べる画面。
/// 比べた要約は保存しない (録音の要約と、やること台帳は変えない)。
struct PromptLabView: View {
    @Query private var recordings: [Recording]
    @State private var draft = SummaryPrompt.custom
    @State private var saved = SummaryPrompt.custom
    @State private var selected: UUID?
    @State private var route: SummaryRoute?
    @State private var routes: [SummaryRoute] = []
    @State private var running = false
    @State private var progress: String?
    @State private var resultA: Trial?
    @State private var resultB: Trial?
    @State private var error: String?
    @State private var job: Task<Void, Never>?

    struct Trial {
        let text: String
        let stats: SummaryPrompt.Stats
        let seconds: Double
        let customIgnored: Bool
        let instruction: String
    }

    init() {
        var d = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.transcript != nil && $0.transcript != "" },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        d.fetchLimit = 30
        _recordings = Query(d)
    }

    var body: some View {
        Form {
            Section {
                TextField("例: TODO には期限が無くても担当者を必ず書く。要点は数字を優先して残す。", text: $draft, axis: .vertical)
                    .lineLimit(4...12)
                HStack {
                    let n = draft.trimmingCharacters(in: .whitespacesAndNewlines).count
                    Text(n > SummaryPrompt.customMaxChars ? "\(n) / \(SummaryPrompt.customMaxChars) 字 (超えた分は使いません)" : "\(n) / \(SummaryPrompt.customMaxChars) 字")
                        .font(.caption).foregroundStyle(n > SummaryPrompt.customMaxChars ? .orange : .secondary)
                    Spacer()
                    if SummaryPrompt.clean(draft) != saved { Text("未保存").font(.caption.bold()).foregroundStyle(.orange) }
                }
                Button("この指示を保存") {
                    SummaryPrompt.custom = draft
                    saved = SummaryPrompt.custom
                    draft = saved
                }
                .disabled(SummaryPrompt.clean(draft) == saved)
                Button("既定に戻す (追加の指示なし)", role: .destructive) {
                    SummaryPrompt.custom = ""
                    saved = ""
                    draft = ""
                }
                .disabled(saved.isEmpty && draft.isEmpty)
            } header: {
                Text("要約への追加の指示")
            } footer: {
                Text("基本の指示の後ろに付けて、これから作る要約 (自動・手動とも) に使います。見出し (【概要】【要点】【決定事項】【TODO】) と箇条書きの形は変えられません。見出しが崩れた要約は、追加の指示なしで作り直します。作成済みの要約は変わりません。")
            }

            Section("基本の指示 (変更できません)") {
                DisclosureGroup("内容を見る") {
                    Text(SummaryPrompt.final).font(.caption).textSelection(.enabled)
                }
            }

            Section {
                Picker("録音", selection: $selected) {
                    Text("選んでください").tag(UUID?.none)
                    ForEach(recordings) { r in
                        Text(r.startedAt.formatted(.dateTime.month().day().hour().minute()) + "  " + String((r.transcript ?? "").prefix(16)))
                            .tag(UUID?.some(r.id))
                    }
                }
                if routes.count > 1 {
                    Picker("要約先", selection: $route) {
                        ForEach(routes, id: \.self) { r in Text(r == .onDevice ? "端末内" : "外部API (\(Summarizer.provider.displayName))").tag(SummaryRoute?.some(r)) }
                    }
                }
                Button(running ? (progress ?? "比べています…") : "今の指示と編集中の指示で比べる" + routeSuffix(route)) {
                    running = true  // 二度押しで 2 回走らせない
                    job = Task { await compare() }
                }
                .disabled(running || selected == nil || route == nil)
                if running { Button("中止", role: .cancel) { job?.cancel() } }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            } header: {
                Text("試して比べる")
            } footer: {
                Text("同じ録音を 2 回要約して並べます (結果は保存しません)。見直しは行わず、指示の違いだけを比べます。外部APIを選ぶと文字起こしを 2 回送信します。")
            }

            if let a = resultA, let b = resultB {
                Section("比較") {
                    StatsRow(title: "項目数 (要点 / 決定 / TODO)",
                             a: "\(a.stats.keyPoints) / \(a.stats.decisions) / \(a.stats.todos)",
                             b: "\(b.stats.keyPoints) / \(b.stats.decisions) / \(b.stats.todos)")
                    StatsRow(title: "文字数", a: "\(a.stats.chars)", b: "\(b.stats.chars)")
                    StatsRow(title: "かかった時間", a: String(format: "%.1f秒", a.seconds), b: String(format: "%.1f秒", b.seconds))
                }
                TrialSection(title: "A: 今の指示", trial: a)
                TrialSection(title: "B: 編集中の指示", trial: b)
            }
        }
        .navigationTitle("要約の指示")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            routes = Summarizer.usableRoutes()
            if route == nil || !routes.contains(route!) { route = routes.first }
            if selected == nil { selected = recordings.first?.id }
        }
        .onDisappear { job?.cancel() }
    }

    private func compare() async {
        running = true; error = nil; resultA = nil; resultB = nil
        defer { running = false; progress = nil }
        guard let id = selected, let rec = recordings.first(where: { $0.id == id }), let t = rec.transcript, !t.isEmpty else {
            error = "録音が見つかりません。選び直してください"
            selected = recordings.first?.id
            return
        }
        // 比べている間に編集しても、比べる指示は押した時点のものに固定する
        let instructionA = saved, instructionB = SummaryPrompt.clean(draft)
        do {
            let r = try Summarizer.confirmUsable(route ?? .onDevice)
            progress = "A: 今の指示で要約中…"
            let a = try await trial(t, route: r, extra: instructionA)
            progress = "B: 編集中の指示で要約中…"
            let b = try await trial(t, route: r, extra: instructionB)
            resultA = a; resultB = b
        } catch where Task.isCancelled || error is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
            routes = Summarizer.usableRoutes()
        }
    }

    private func trial(_ t: String, route: SummaryRoute, extra: String) async throws -> Trial {
        let start = Date()
        let r = try await Summarizer.summarize(t, route: route, extra: extra)
        return Trial(text: r.labeled, stats: SummaryPrompt.stats(r.text), seconds: Date().timeIntervalSince(start),
                     customIgnored: r.customIgnored, instruction: extra)
    }
}

private struct TrialSection: View {
    let title: String
    let trial: PromptLabView.Trial

    var body: some View {
        Section {
            if trial.customIgnored {
                Label("追加の指示で見出しが崩れたため、追加の指示なしで作り直した結果です", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Text(trial.text).font(.callout).textSelection(.enabled)
        } header: {
            Text(title + (trial.instruction.isEmpty ? " (追加なし)" : ""))
        } footer: {
            if !trial.instruction.isEmpty { Text("指示: " + trial.instruction).lineLimit(3) }
        }
    }
}

private struct StatsRow: View {
    let title: String
    let a: String
    let b: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("A  " + a).font(.callout.monospacedDigit())
                Spacer()
                Text("B  " + b).font(.callout.monospacedDigit()).foregroundStyle(a == b ? .primary : Theme.accentText)
            }
        }
    }
}
