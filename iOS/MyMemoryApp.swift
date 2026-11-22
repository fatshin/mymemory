import SwiftUI
import SwiftData

@main
struct MyMemoryApp: App {
    let container: ModelContainer
    @StateObject private var pipeline: Pipeline
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let c = try! ModelContainer(for: Recording.self)
        container = c
        let p = Pipeline(context: c.mainContext)
        _pipeline = StateObject(wrappedValue: p)
        // アプリ起動の完了前に登録する必要がある
        BackgroundTranscribe.register(pipeline: p)
        p.continuedRegistered = BackgroundTranscribe.registerContinued(pipeline: p)
        MarkdownFile.removeLeftovers()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(pipeline)
                .tint(Theme.accent)
        }
        .modelContainer(container)
        // 背景で文字起こしだけ済んだ録音は、前面に戻ったときに自動要約する (文字起こし中は drain の後に始まる)
        .onChange(of: scenePhase) { _, p in if p == .active { pipeline.startSummaryBacklog() } }
    }
}
