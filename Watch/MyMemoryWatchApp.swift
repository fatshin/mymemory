import SwiftUI

@main
struct MyMemoryWatchApp: App {
    @StateObject private var recorder = WatchRecorder()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(recorder)
        }
    }
}
