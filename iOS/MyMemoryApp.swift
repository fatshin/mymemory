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
        // アプリを開いたら (起動時も含む)、保留の文字起こしと要約を自動で進める。背景に回ったら充電中だけに戻す
        // 通知センターの出し入れ (inactive) では切り替えない
        .onChange(of: scenePhase, initial: true) { _, p in
            if p == .active { pipeline.setForeground(true) } else if p == .background { pipeline.setForeground(false) }
        }
    }
}
