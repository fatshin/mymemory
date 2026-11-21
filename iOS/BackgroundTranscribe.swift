import BackgroundTasks
import Foundation

/// 外部電源接続中に OS が起動する文字起こしタスク。
/// 実行時刻は OS 任せ (主に夜間の充電中)。時間切れで中断されても、未完了分は次回へ持ち越す。
enum BackgroundTranscribe {
    static let identifier = "com.fatshin.mymemory.transcribe"

    /// アプリ起動の完了前に登録する必要がある (App.init で呼ぶ)。
    /// nonisolated: launchHandler は OS のバックグラウンドキューで呼ばれる。
    /// MainActor 隔離を継承すると Swift 6 の実行時検査で落ちるため、隔離は Task 内で戻す。
    nonisolated static func register(pipeline: Pipeline) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            let handle = TaskHandle(task)
            Task { @MainActor in pipeline.runBackground(handle) }
        }
    }

    /// 保留分があるときに呼ぶ。同一 identifier の再申請は置き換えられる。
    /// モデル未取得 (初回) のときだけ通信を要求する。取得済みなら通信なしで実行できる。
    /// - Parameter earliest: これより前には起こさない。
    static func schedule(needsNetwork: Bool, earliest: Date? = nil) {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = needsNetwork
        request.earliestBeginDate = earliest
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// BGProcessingTask の完了通知を 1 回に限定するラッパー。
/// 時間切れと正常終了が競合しても setTaskCompleted を二重に呼ばない。
final class TaskHandle: @unchecked Sendable {
    private let task: BGProcessingTask
    private let lock = NSLock()
    private var completed = false

    init(_ task: BGProcessingTask) { self.task = task }

    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        task.expirationHandler = handler
    }

    func complete(success: Bool) {
        lock.lock()
        let first = !completed
        completed = true
        lock.unlock()
        if first { task.setTaskCompleted(success: success) }
    }
}
