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
    @Published var elapsedText = "00:00:00"
    @Published var chunkCount = 0
    @Published var pendingTransfers = 0
    @Published var lastError: String?

    private let chunkSeconds: TimeInterval = 600
    private var recorder: AVAudioRecorder?
    private var chunkStart = Date()
    private var sessionStart = Date()
    private var tickTimer: Timer?

    private let healthStore = HKHealthStore()
    private var workout: HKWorkoutSession?

    private let wc = WCSession.default

    override init() {
        super.init()
        if WCSession.isSupported() {
            wc.delegate = self
            wc.activate()
        }
    }

    // MARK: - Control

    func start() {
        lastError = nil
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else { self.lastError = "マイク権限なし"; return }
                await self.startWorkoutKeepAlive()
                self.beginSession()
            }
        }
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        finishChunk(sendIfNonEmpty: true)
        workout?.end()
        workout = nil
        isRecording = false
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
            return
        }
        sessionStart = Date()
        chunkCount = 0
        isRecording = true
        startChunk()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func startChunk() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunk-\(Int(Date().timeIntervalSince1970)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            guard r.record() else { lastError = "record() 失敗"; return }
            recorder = r
            chunkStart = Date()
        } catch {
            lastError = "Recorder: \(error.localizedDescription)"
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

    private func tick() {
        let e = Int(Date().timeIntervalSince(sessionStart))
        elapsedText = String(format: "%02d:%02d:%02d", e / 3600, (e % 3600) / 60, e % 60)
        if Date().timeIntervalSince(chunkStart) >= chunkSeconds {
            finishChunk(sendIfNonEmpty: true)
            startChunk()
        }
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
