import SwiftUI
import SwiftData

@main
struct MyMemoryApp: App {
    let container: ModelContainer
    @StateObject private var pipeline: Pipeline
    @StateObject private var store: Store

    init() {
        let c = try! ModelContainer(for: Recording.self)
        container = c
        let p = Pipeline(context: c.mainContext)
        _pipeline = StateObject(wrappedValue: p)
        let s = Store()
        // 購入・復元・更新で有料になったら、無料枠で止めていた文字起こしを再開する
        s.onBecamePro = { [weak p] in p?.resumeAfterPurchase() }
        _store = StateObject(wrappedValue: s)
        // アプリ起動の完了前に登録する必要がある
        BackgroundTranscribe.register(pipeline: p)
        MarkdownFile.removeLeftovers()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(pipeline)
                .environmentObject(store)
        }
        .modelContainer(container)
    }
}
