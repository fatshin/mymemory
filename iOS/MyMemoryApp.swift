import SwiftUI
import SwiftData

@main
struct MyMemoryApp: App {
    let container: ModelContainer
    @StateObject private var pipeline: Pipeline

    init() {
        let c = try! ModelContainer(for: Recording.self)
        container = c
        _pipeline = StateObject(wrappedValue: Pipeline(context: c.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(pipeline)
        }
        .modelContainer(container)
    }
}
