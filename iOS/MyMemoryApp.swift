import SwiftUI
import SwiftData

@main
struct MyMemoryApp: App {
    let container: ModelContainer
    @StateObject private var pipeline: Pipeline

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
    }
}
