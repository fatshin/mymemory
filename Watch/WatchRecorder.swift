import Foundation
import AVFoundation
import HealthKit
import WatchConnectivity
import WatchKit

/// 常時録音。10分ごとにチャンク分割し、iPhoneへ transferFile。
/// バックグラウンド継続は HKWorkoutSession に依存 (PoCで実機検証必須)。
@MainActor
final class WatchRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    /// 経過時間は View 側の TimelineView が計算する(画面点灯中のみ再描画。毎秒の @Published 更新を廃止)。
    @Published var sessionStart: Date?
    @Published var chunkCount = 0
    @Published var pendingTransfers = 0
    @Published var lastError: String?

    private let chunkSeconds: TimeInterval = 600
    private var recorder: AVAudioRecorder?
    private var chunkStart = Date()
    /// チャンク分割用の単発タイマー(10分に1回だけ起床。旧: 毎秒タイマー)。
    private var chunkTimer: Timer?

    /// これ未満かつ非充電なら録音を自動停止し、残りを転送する。
    private let lowBatteryStopLevel: Float = 0.10

    /// 録音の開始に失敗・割り込みされたときの再試行 (単発タイマー)。予算の判断は RecoveryBudget (単体テスト対象)。
    private var recoveryTimer: Timer?
    private var starting = false
    private var budget = RecoveryBudget()
    private let recoveryDelay: TimeInterval = 30
    private var interruptionObserver: NSObjectProtocol?

    /// 未転送チャンクの置き場所。temporaryDirectory は OS に消されうるため Application Support に置く。
    private static var chunkDirectory: URL {
        let d = URL.applicationSupportDirectory.appendingPathComponent("Chunks", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private let healthStore = HKHealthStore()
    private var workout: HKWorkoutSession?

    private let wc = WCSession.default

    override init() {
        super.init()
        // 未有効化だと batteryLevel が常に -1 になり、電池消費の実測(Go/No-Go)が成立しない。
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        if WCSession.isSupported() {
            wc.delegate = self
            wc.activate()
        }
    }

    // MARK: - Control

    func start() {
        // 権限要求とワークアウト認可の待ち中に再タップされても、録音を二重に起動しない
        guard !isRecording, !starting else { return }
        starting = true
        lastError = nil
        // async 版: コールバックの隔離を継承する問題 (別スレッド呼び出しで実行時に落ちる) を避ける
        Task { @MainActor in
            defer { starting = false }
            guard await AVAudioApplication.requestRecordPermission() else { lastError = "マイク権限なし"; return }
            await startWorkoutKeepAlive()
            beginSession()
        }
    }

    func stop() {
        chunkTimer?.invalidate()
        chunkTimer = nil
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        if let o = interruptionObserver {
            NotificationCenter.default.removeObserver(o)
            interruptionObserver = nil
        }
        finishChunk(sendIfNonEmpty: true)
        try? AVAudioSession.sharedInstance().setActive(false)
        workout?.end()
        workout = nil
        isRecording = false
        sessionStart = nil
    }

    // MARK: - Internals

    private func startWorkoutKeepAlive() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let types: Set = [HKObjectType.workoutType()]
        do {
            try await healthStore.requestAuthorization(toShare: types, read: [])
            let cfg = HKWorkoutConfiguration()
            cfg.activityType = .other
            cfg.locationType = .indoor
            let s = try HKWorkoutSession(healthStore: healthStore, configuration: cfg)
            s.startActivity(with: Date())
            workout = s
        } catch {
            lastError = "Workout: \(error.localizedDescription)"
        }
    }

    private func beginSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            lastError = "AudioSession: \(error.localizedDescription)"
            workout?.end()
            workout = nil
            return
        }
        sessionStart = Date()
        chunkCount = 0
        budget.reset()
        isRecording = true
        observeInterruptions()
        startChunk()
    }

    /// 着信などで録音が中断されたら、そこまでを送信し、終了通知または再試行で再開する。
    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in self?.handleInterruption(typeRaw: raw) }
        }
    }

    private func handleInterruption(typeRaw: UInt?) {
        guard isRecording, let raw = typeRaw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // 割り込み中 (通話など) は長さに上限がない。予算を消費せず、終了まで再試行を続ける
            budget.interruptionBegan()
            chunkTimer?.invalidate()
            chunkTimer = nil
            finishChunk(sendIfNonEmpty: true)
            handleRecordingFailure("録音が中断されました")
        case .ended:
            budget.interruptionEnded()
            recoveryTimer?.invalidate()
            recoveryTimer = nil
            // 再試行が先に成功して録音中なら、二重に録音を始めない
            guard recorder == nil else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            startChunk()
        @unknown default:
            break
        }
    }

    /// 録音できない状態。一定間隔で再試行し、上限に達したら停止して触覚で知らせる。
    private func handleRecordingFailure(_ message: String) {
        lastError = message
        recoveryTimer?.invalidate()
        guard budget.recordFailure() == .retry else {
            stop()
            lastError = "\(message): 再開できず停止"
            WKInterfaceDevice.current().play(.failure)
            return
        }
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: recoveryDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording, self.recorder == nil else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                self.startChunk()
            }
        }
    }

    private func startChunk() {
        let url = Self.chunkDirectory
            .appendingPathComponent("chunk-\(Int(Date().timeIntervalSince1970)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.delegate = self
            guard r.record() else {
                try? FileManager.default.removeItem(at: url)
                handleRecordingFailure("record() 失敗")
                return
            }
            recorder = r
            chunkStart = Date()
            chunkTimer?.invalidate()
            chunkTimer = Timer.scheduledTimer(withTimeInterval: chunkSeconds, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.rotateChunk() }
            }
        } catch {
            handleRecordingFailure("Recorder: \(error.localizedDescription)")
        }
    }

    private func finishChunk(sendIfNonEmpty: Bool) {
        guard let r = recorder else { return }
        let url = r.url
        let duration = Date().timeIntervalSince(chunkStart)
        r.stop()
        recorder = nil
        guard sendIfNonEmpty, duration > 1 else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        chunkCount += 1
        let meta: [String: Any] = [
            TransferKey.startedAt: chunkStart.timeIntervalSince1970,
            TransferKey.duration: duration,
            TransferKey.chunkIndex: chunkCount,
            TransferKey.batteryLevel: WKInterfaceDevice.current().batteryLevel,
        ]
        if wc.activationState == .activated {
            wc.transferFile(url, metadata: meta)
            pendingTransfers = wc.outstandingFileTransfers.count
        } else {
            lastError = "WCSession未アクティブ"
        }
    }

    /// チャンク境界: 送信 -> 電池確認 -> 次チャンク開始。
    private func rotateChunk() {
        // stop() の直後に積まれていた古いタイマーの実行で、録音が再開してしまうのを防ぐ
        guard isRecording, recorder != nil else { return }
        finishChunk(sendIfNonEmpty: true)
        // チャンクを最後まで録れたときだけ失敗の連続を断つ (開始直後の異常停止の繰り返しを上限で止めるため)
        budget.recordSuccess()
        let device = WKInterfaceDevice.current()
        let charging = device.batteryState == .charging || device.batteryState == .full
        let level = device.batteryLevel
        if !charging, level >= 0, level < lowBatteryStopLevel {
            stop()
            lastError = "電池\(Int(level * 100))%のため停止"
            WKInterfaceDevice.current().play(.failure)
            return
        }
        startChunk()
    }
}

extension WatchRecorder {
    /// record() 成功後に OS が録音を止めた場合の検知。delegate は main thread とは限らないため MainActor へ移す。
    fileprivate func handleUnexpectedStop(from id: ObjectIdentifier) {
        // 既に差し替え済みの古い recorder の遅延通知では、新しい録音を止めない
        guard isRecording, let current = recorder, ObjectIdentifier(current) == id else { return }
        chunkTimer?.invalidate()
        chunkTimer = nil
        finishChunk(sendIfNonEmpty: true)
        handleRecordingFailure("録音が停止しました")
    }
}

extension WatchRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // 自分で stop() したときは flag == true。false のときだけ異常停止として扱う
        guard !flag else { return }
        let id = ObjectIdentifier(recorder)
        Task { @MainActor in self.handleUnexpectedStop(from: id) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor in self.handleUnexpectedStop(from: id) }
    }
}

extension WatchRecorder: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {}

    nonisolated func session(_ session: WCSession,
                             didFinish fileTransfer: WCSessionFileTransfer,
                             error: Error?) {
        // 転送完了したチャンクを削除 (失敗時は残す)
        if error == nil { try? FileManager.default.removeItem(at: fileTransfer.file.fileURL) }
        Task { @MainActor in
            self.pendingTransfers = WCSession.default.outstandingFileTransfers.count
            if let error { self.lastError = "転送失敗: \(error.localizedDescription)" }
        }
    }
}
