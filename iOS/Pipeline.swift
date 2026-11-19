import Foundation
import SwiftData
import UIKit
import WatchConnectivity
import WhisperKit

/// 受信 -> 保存 -> 文字起こし(オンデバイス) の直列パイプライン。
@MainActor
final class Pipeline: NSObject, ObservableObject {
    @Published var modelStatus = "未ロード"
    @Published var busy = false

    private let context: ModelContext
    private let transcriber = Transcriber()
    private var modelLoaded = false
    /// 一度でもモデルを取得・ロードできたか。再起動後も保持し、取得済みなら BG 起動で通信を要求しない。
    nonisolated private static let modelFolderKey = "modelFolderRelative"
    /// コンテナのパスはアプリ更新で変わりうるため、Documents からの相対パスで保存する。
    nonisolated static func savedModelFolder() -> String? {
        guard let rel = UserDefaults.standard.string(forKey: modelFolderKey) else { return nil }
        let path = URL.documentsDirectory.appending(path: rel).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
    private var modelOnDisk: Bool { Self.savedModelFolder() != nil }
    /// モデル取得失敗の連続回数。上限で自動再試行を止め、通知のたびの再ダウンロードを防ぐ。
    private var modelLoadFailures = 0
    private static let maxModelLoadFailures = 3
    private var queue: [UUID] = []
    /// 実行中の drain。前面・通知・バックグラウンドのどこから呼んでも 1 本だけ動く。
    private var drainTask: Task<Void, Never>?

    /// 日本語向け。モデル名はWhisperKit側の対応表に依存 (要確認)。
    static let modelName = "large-v3-v20240930_626MB"

    init(context: ModelContext) {
        self.context = context
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        enqueueUnfinished()
        observePowerState()
    }

    // MARK: Power policy (省電力)

    /// 文字起こしは電力を最も使う処理。判定は PowerPolicy (単体テスト対象) に委ねる。
    private func canTranscribeNow() -> Bool {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let charge: PowerPolicy.Charge
        switch device.batteryState {
        case .charging, .full: charge = .charging
        case .unplugged: charge = .unplugged
        default: charge = .unknown
        }
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif
        return PowerPolicy.shouldTranscribe(
            charge: charge,
            level: device.batteryLevel,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isSimulator: isSimulator)
    }

    /// 充電開始・電池残量・低電力モードの変化で、保留中の文字起こしを再開する。
    private func observePowerState() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let names: [Notification.Name] = [
            UIDevice.batteryStateDidChangeNotification,
            UIDevice.batteryLevelDidChangeNotification,
            .NSProcessInfoPowerStateDidChange,
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.startDrain() }
            }
        }
    }

    /// 再起動後も、未完了(pending/transcribing)の録音をキューへ戻す。
    /// 試行回数が上限に達した録音は failed にして、起動のたびに落ちるループを断つ。
    private func enqueueUnfinished() {
        let desc = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.statusRaw == "pending" || $0.statusRaw == "transcribing" },
            sortBy: [SortDescriptor(\.startedAt)])
        for rec in (try? context.fetch(desc)) ?? [] {
            switch RetryPolicy.onRelaunch(attempts: rec.attempts) {
            case .fail:
                rec.statusRaw = "failed"
                rec.errorMessage = "処理が\(RetryPolicy.maxAttempts)回中断したため停止 (再文字起こしで再試行できます)"
            case .requeue:
                rec.statusRaw = "pending"
                enqueue(rec.id)
            }
        }
        try? context.save()
        if !queue.isEmpty { startDrain() }
    }

    private func enqueue(_ id: UUID) {
        if !queue.contains(id) { queue.append(id) }
    }

    // MARK: Receive

    fileprivate func ingest(tempURL: URL, startedAtEpoch: TimeInterval, duration: TimeInterval, battery: Double) {
        let startedAt = Date(timeIntervalSince1970: startedAtEpoch)
        let name = "\(Int(startedAt.timeIntervalSince1970)).m4a"

        // 同じチャンクの二重配信は破棄する (Recording の重複とファイル上書きを防ぐ)
        let dup = FetchDescriptor<Recording>(predicate: #Predicate { $0.fileName == name })
        if let existing = try? context.fetch(dup), !existing.isEmpty {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        let dest = AudioStore.directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: tempURL, to: dest) } catch { return }
        let rec = Recording(startedAt: startedAt, duration: duration, batteryLevel: battery, fileName: name)
        context.insert(rec)
        try? context.save()
        enqueue(rec.id)
        modelLoadFailures = 0
        startDrain()
    }

    // MARK: Transcribe

    func retry(_ rec: Recording) {
        rec.statusRaw = "pending"; rec.errorMessage = nil; rec.attempts = 0
        modelLoadFailures = 0
        try? context.save()
        enqueue(rec.id)
        startDrain()
    }

    /// 実行中の drain があればそれを返し、無ければ開始する。
    @discardableResult
    private func startDrain() -> Task<Void, Never> {
        if let running = drainTask { return running }
        let task = Task { @MainActor [self] in
            await runDrain()
            drainTask = nil
        }
        drainTask = task
        return task
    }

    /// OS が外部電源接続中に起動するバックグラウンド実行。
    /// 前面で既に動いている drain があれば、それの終了を待つ (即完了して OS にサスペンドされるのを防ぐ)。
    /// 時間切れでは drain を取り消し、中断した録音を pending に戻す後始末を待ってから完了を通知する。
    func runBackground(_ handle: TaskHandle) {
        let task = startDrain()
        handle.setExpirationHandler { [weak self] in
            task.cancel()
            Task { @MainActor in
                BackgroundTranscribe.schedule(needsNetwork: !(self?.modelOnDisk ?? false))
            }
            // 推論がキャンセルにすぐ応じない場合に備え、猶予後に必ず完了を通知する
            Task {
                try? await Task.sleep(for: .seconds(2))
                handle.complete(success: false)
            }
        }
        Task { @MainActor in
            await task.value
            handle.complete(success: !task.isCancelled)
        }
    }

    private func runDrain() async {
        busy = true
        defer { busy = false }
        // 実行中にアプリが停止しても夜間の充電時に OS が再開できるよう、保留があるあいだ常に申請しておく
        if !queue.isEmpty { BackgroundTranscribe.schedule(needsNetwork: !modelOnDisk) }
        while !queue.isEmpty, !Task.isCancelled {
            if modelLoadFailures >= Self.maxModelLoadFailures { return }
            guard canTranscribeNow() else {
                modelStatus = "充電待ち (\(queue.count)件保留)"
                BackgroundTranscribe.schedule(needsNetwork: !modelOnDisk)
                return
            }
            let id = queue.removeFirst()
            let desc = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
            // pending 以外 (完了済み・処理中・失敗確定) は二重処理しない
            guard let rec = try? context.fetch(desc).first, rec.statusRaw == "pending" else { continue }
            rec.statusRaw = "transcribing"
            rec.attempts += 1
            try? context.save()
            do {
                if !modelLoaded { modelStatus = "モデルDL/ロード中…" }
                let text = try await transcriber.transcribe(audioPath: rec.fileURL.path)
                modelLoaded = true
                modelLoadFailures = 0
                modelStatus = "準備完了"
                rec.transcript = text
                rec.statusRaw = "done"
            } catch is ModelLoadError where Task.isCancelled {
                // 時間切れ中の取得・ロード中断は失敗ではない
                rec.statusRaw = "pending"
                rec.attempts -= 1
                queue.insert(rec.id, at: 0)
            } catch is ModelLoadError {
                // モデルを取得できない (主に初回の通信不通)。録音の失敗ではないので、全件を failed にせず保留に戻す
                rec.statusRaw = "pending"
                rec.attempts -= 1
                queue.insert(rec.id, at: 0)
                modelLoadFailures += 1
                try? context.save()
                if modelLoadFailures >= Self.maxModelLoadFailures {
                    // 恒久的な失敗 (モデル名不一致・容量不足) で再試行を続けない。手動の再文字起こしかアプリ再起動で再開
                    modelStatus = "モデル取得に失敗 (再文字起こしで再試行)"
                } else {
                    modelStatus = "モデル取得待ち"
                    BackgroundTranscribe.schedule(needsNetwork: true)
                }
                return
            } catch {
                if Task.isCancelled {
                    // 時間切れによる中断は失敗ではない。試行回数を戻して先頭へ戻す
                    rec.statusRaw = "pending"
                    rec.attempts -= 1
                    queue.insert(rec.id, at: 0)
                } else {
                    rec.statusRaw = "failed"
                    rec.errorMessage = error.localizedDescription
                }
            }
            try? context.save()
        }
    }
}

extension Pipeline: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // file.fileURL はコールバック後に消える → 同期的に退避
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try? FileManager.default.copyItem(at: file.fileURL, to: tmp)
        // [String: Any] は Sendable でないため、ここで Sendable なプリミティブへ取り出す
        let meta = file.metadata ?? [:]
        let startedAtEpoch = meta[TransferKey.startedAt] as? TimeInterval ?? Date().timeIntervalSince1970
        let duration = meta[TransferKey.duration] as? TimeInterval ?? 0
        let battery = Double(meta[TransferKey.batteryLevel] as? Float ?? -1)
        Task { @MainActor in
            self.ingest(tempURL: tmp, startedAtEpoch: startedAtEpoch, duration: duration, battery: battery)
        }
    }
}

/// WhisperKit(非Sendable)を保持し、MainActorとの間では Sendable な値(パス/文字列)のみを受け渡す。
/// 呼び出しは Pipeline の drainTask が直列化するため同時アクセスは発生しない (その前提で @unchecked Sendable)。
final class Transcriber: @unchecked Sendable {
    private var whisper: WhisperKit?

    @concurrent
    func transcribe(audioPath: String) async throws -> String {
        let w: WhisperKit
        if let loaded = whisper {
            w = loaded
        } else {
            do {
                // init は取得のみ。CoreML のロードも同じ do 内で行い、失敗を ModelLoadError に含める
                // 取得済みならフォルダを直接指定して通信なしで初期化する (init の取得処理は常に通信する)
                let saved = Pipeline.savedModelFolder()
                let created: WhisperKit
                if let saved {
                    created = try await WhisperKit(WhisperKitConfig(modelFolder: saved, load: false, download: false))
                } else {
                    created = try await WhisperKit(WhisperKitConfig(model: Pipeline.modelName))
                }
                try await created.loadModels()
                if let folder = created.modelFolder {
                    let docs = URL.documentsDirectory.path
                    if folder.path.hasPrefix(docs) {
                        UserDefaults.standard.set(String(folder.path.dropFirst(docs.count)), forKey: "modelFolderRelative")
                    }
                }
                w = created
            } catch {
                throw ModelLoadError(underlying: error.localizedDescription)
            }
            whisper = w
        }
        // chunkingStrategy: .vad は無音を捨てず、長尺音声を無音境界で分割するだけ (公式README)。
        // 推論量は減らず並列度が上がるため使わない。
        let results = try await w.transcribe(
            audioPath: audioPath,
            decodeOptions: DecodingOptions(language: "ja"))
        return results.map(\.text).joined(separator: "\n")
    }
}

/// モデルの取得・ロードに失敗した。録音そのものの失敗とは区別して、保留として扱う。
struct ModelLoadError: Error, LocalizedError {
    let underlying: String
    var errorDescription: String? { "モデルを取得できません: \(underlying)" }
}
