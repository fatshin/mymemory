import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject var pipeline: Pipeline
    @Query(sort: \Recording.startedAt, order: .reverse) private var recordings: [Recording]
    @State private var showSettings = false
    @State private var query = ""

    private var days: [(day: Date, items: [Recording])] {
        let filtered = query.isEmpty ? recordings : recordings.filter { ($0.transcript ?? "").localizedStandardContains(query) }
        let cal = Calendar.current
        return Dictionary(grouping: filtered) { cal.startOfDay(for: $0.startedAt) }
            .map { (day: $0.key, items: $0.value.sorted { $0.startedAt < $1.startedAt }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(days, id: \.day) { group in
                    Section {
                        ForEach(group.items) { rec in
                            NavigationLink(value: rec.id) { Row(rec: rec) }
                        }
                    } header: {
                        HStack {
                            Text(group.day, format: .dateTime.year().month().day().weekday())
                            Spacer()
                            NavigationLink("振り返り") { DayReflectionView(day: group.day, items: group.items) }
                                .font(.caption)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "文字起こしを検索")
            .overlay { if recordings.isEmpty { ContentUnavailableView("録音なし", systemImage: "applewatch", description: Text("Watchで録音を開始")) } }
            .navigationDestination(for: UUID.self) { id in
                if let rec = recordings.first(where: { $0.id == id }) { DetailView(rec: rec) }
            }
            .navigationTitle("MyMemory")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Text(pipeline.modelStatus).font(.caption2) }
                ToolbarItem { Button { showSettings = true } label: { Image(systemName: "gearshape") } }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
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
    @State private var error: String?

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
                    Button("要約 (外部API)") { Task { await summarize() } }
                        .disabled(rec.transcript == nil || summarizing)
                    Button("再文字起こし") { pipeline.retry(rec) }
                    Button("削除", role: .destructive) {
                        try? FileManager.default.removeItem(at: rec.fileURL)
                        ctx.delete(rec)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private func summarize() async {
        guard let t = rec.transcript else { return }
        summarizing = true; defer { summarizing = false }
        do { rec.summary = try await Summarizer.summarize(t); try? ctx.save() }
        catch { self.error = error.localizedDescription }
    }
}

struct SettingsView: View {
    @State private var key = Keychain.get(Summarizer.keyName) ?? ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Anthropic APIキー (BYOK / 端末Keychainのみ保存)") {
                    SecureField("sk-ant-…", text: $key)
                }
                Section { Text("送信されるのは文字起こしテキストのみ。音声は端末外へ出ない。").font(.footnote) }
            }
            .navigationTitle("設定")
            .toolbar { Button("保存") { Keychain.set(key, for: Summarizer.keyName); dismiss() } }
        }
    }
}

/// 1日分の文字起こしを時系列に連結し、日次リフレクションを生成 (ライフログ補完の中核)。
struct DayReflectionView: View {
    let day: Date
    let items: [Recording]
    @State private var text: String?
    @State private var loading = false
    @State private var error: String?

    private var timeline: String {
        items.compactMap { r in
            guard let t = r.transcript, !t.isEmpty else { return nil }
            return "[\(r.startedAt.formatted(date: .omitted, time: .shortened))] \(t)"
        }.joined(separator: "\n\n")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let text { Text(text).textSelection(.enabled) }
                if let error { Text(error).foregroundStyle(.red) }
                Section("タイムライン") { Text(timeline.isEmpty ? "文字起こしなし" : timeline).font(.footnote).textSelection(.enabled) }
            }.padding()
        }
        .navigationTitle(day.formatted(date: .abbreviated, time: .omitted))
        .toolbar {
            Button(loading ? "生成中…" : "振り返り生成") { Task { await run() } }
                .disabled(loading || timeline.isEmpty)
        }
    }

    private func run() async {
        loading = true; defer { loading = false }
        do { text = try await Summarizer.reflect(timeline: timeline) }
        catch { self.error = error.localizedDescription }
    }
}
