import BackgroundTasks
import Foundation

/// 外部電源接続中に OS が起動する文字起こしタスク。
/// 実行時刻は OS 任せ (主に夜間の充電中)。時間切れで中断されても、未完了分は次回へ持ち越す。
enum BackgroundTranscribe {
    static let identifier = "com.fatshin.mymemory.transcribe"
    /// 利用者の操作で開始する継続タスク (画面を閉じても続く)。plist の識別子と一致させる。
    static let continuedIdentifier = "com.fatshin.mymemory.continued.transcribe"

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

    /// 継続タスクの起動ハンドラを登録する。戻り値が false なら識別子が plist に無く、継続タスクは使えない
    /// (その場合は前面実行にとどめる)。登録の制約と隔離の扱いは `register` と同じ。
    nonisolated static func registerContinued(pipeline: Pipeline) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: continuedIdentifier, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            let handle = TaskHandle(task, progress: task.progress)
            Task { @MainActor in pipeline.runContinued(handle) }
        }
    }

    /// 利用者の操作 (ボタン) の直後に呼ぶ。即時に実行できなければ待たせず失敗させ、理由を返す
    /// (待機列に入れたままだと、利用者がアプリを閉じたときに取り消されるため)。成功なら nil。
    static func submitContinued(pending: Int) -> String? {
        let request = BGContinuedProcessingTaskRequest(
            identifier: continuedIdentifier,
            title: "文字起こし",
            subtitle: "\(pending)件の録音を端末内で処理しています")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return nil
        } catch {
            return error.localizedDescription
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

/// BGTask (処理タスク・継続タスク共通) の完了通知を 1 回に限定するラッパー。
/// 時間切れと正常終了が競合しても setTaskCompleted を二重に呼ばない。
final class TaskHandle: @unchecked Sendable {
    private let task: BGTask
    /// 継続タスクのときだけ持つ。OS はここへ報告された進捗で、止まったタスクを強制終了する。
    let progress: Progress?
    private let lock = NSLock()
    private var completed = false

    init(_ task: BGTask, progress: Progress? = nil) {
        self.task = task
        self.progress = progress
    }

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
