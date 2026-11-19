import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject var pipeline: Pipeline
    @Query(sort: \Recording.startedAt, order: .reverse) private var recordings: [Recording]
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List(recordings) { rec in
                NavigationLink(value: rec.id) { Row(rec: rec) }
            }
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
