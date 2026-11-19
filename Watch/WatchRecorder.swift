import Foundation
import AVFoundation
import WatchConnectivity
import WatchKit

/// 常時録音。10 分ごとに区切って iPhone へ transferFile する。
/// バックグラウンドの継続は音声のバックグラウンド実行 (UIBackgroundModes: audio) に頼る。
/// watchOS では「録音は前面での利用者の操作で始める必要があり、始めた後はバックグラウンドでも続けられる。
/// バックグラウンドでの再開はできない」(Apple の回答) ため、区切りでもエンジンを止めず、
/// 中断されたら一時停止にして、利用者のタップで再開する。
@MainActor
final class WatchRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    /// 着信などで止まり、利用者の再開を待っている。
    @Published var isPaused = false
    /// 経過時間は View 側の TimelineView が計算する (画面点灯中のみ再描画)。
    @Published var sessionStart: Date?
    @Published var chunkCount = 0
    @Published var pendingTransfers = 0
    /// 実機確認用: 最後に区間を送った時刻。
    @Published var lastChunkAt: Date?
    @Published var lastError: String?

    private let chunkSeconds: TimeInterval = 600
    /// これ未満かつ非充電なら録音を自動停止し、残りを転送する。
    private let lowBatteryStopLevel: Float = 0.10

    private var engine: AVAudioEngine?
    private var writer: ChunkWriter?
    private var starting = false
    private var observers: [NSObjectProtocol] = []
    /// 今のエンジンだけの経路変化を監視する (他のエンジンの通知で止めない)。
    private var engineObserver: NSObjectProtocol?
    /// 送信を依頼したファイル名。送り直しで同じファイルを二重に送らないために使う (失敗時に外す)。
    private var sentNames = Set<String>()

    /// 16 kHz・モノラルの AAC。iPhone 側の文字起こしに十分で、転送量と電力を抑える。
    private static let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ]

    /// 未転送チャンクの置き場所。temporaryDirectory は OS に消されうるため Application Support に置く。
    private static var chunkDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Chunks", isDirectory: true)
    }

    private let wc = WCSession.default

    override init() {
        super.init()
        // 未有効化だと batteryLevel が常に -1 になり、電池消費の実測が成立しない。
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        if WCSession.isSupported() {
            wc.delegate = self
            wc.activate()
        }
    }

    // MARK: - Control (すべて利用者の操作から呼ぶ)

    func start() {
        // 権限要求の待ち中に再タップされても、録音を二重に起動しない
        guard !isRecording, !isPaused, !starting else { return }
        starting = true
        lastError = nil
        // async 版: コールバックの隔離を継承する問題 (別スレッド呼び出しで実行時に落ちる) を避ける
        Task { @MainActor in
            defer { starting = false }
            guard await AVAudioApplication.requestRecordPermission() else { lastError = "マイク権限なし"; return }
            guard startCapture() else { return }
            sessionStart = Date()
            chunkCount = 0
            observeAudioSession()
        }
    }

    /// 中断後の再開。前面でのタップからだけ呼ぶ (バックグラウンドでは再開できないため)。
    func resume() {
        guard isPaused, !starting else { return }
        lastError = nil
        if startCapture() { isPaused = false }
    }

    func stop() {
        guard isRecording || isPaused else { return }
        stopCapture()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false
        isPaused = false
        sessionStart = nil
    }

    // MARK: - Capture

    private func startCapture() -> Bool {
        let engine = AVAudioEngine()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                lastError = "マイク入力を取得できません"
                return false
            }
            let writer = ChunkWriter(directory: Self.chunkDirectory, chunkSeconds: chunkSeconds,
                                     settings: Self.audioSettings) { [weak self] chunk in
                Task { @MainActor in self?.chunkFinished(chunk) }
            }
            let onError: @Sendable (String) -> Void = { [weak self] message in
                Task { @MainActor in self?.pauseCapture("録音に失敗: \(message)") }
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: format,
                             block: Self.makeTap(writer: writer, onError: onError))
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.writer = writer
            engineObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.pauseCapture("音声の経路が変わりました") }
            }
            isRecording = true
            return true
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            lastError = "録音を開始できません: \(error.localizedDescription)"
            return false
        }
    }

    /// tap は音声スレッドで呼ばれる。MainActor の隔離を継承させないよう、nonisolated で作る。
    nonisolated private static func makeTap(writer: ChunkWriter,
                                            onError: @escaping @Sendable (String) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            do { try writer.append(buffer) } catch { onError(error.localizedDescription) }
        }
    }

    /// 順序が重要: tap を外す → エンジンを止める → 最後の区間を閉じる → 送る。
    private func stopCapture() {
        if let o = engineObserver { NotificationCenter.default.removeObserver(o) }
        engineObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if let last = writer?.finish() { send(last) }
        writer = nil
    }

    /// 中断・失敗時。そこまでを送り、利用者の再開を待つ。
    private func pauseCapture(_ message: String) {
        guard isRecording else { return }
        stopCapture()
        isRecording = false
        isPaused = true
        lastError = "\(message)。タップで再開"
        WKInterfaceDevice.current().play(.notification)
    }

    /// 着信・Siri などの中断と、マイクの経路の変化を監視する。
    private func observeAudioSession() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in self?.handleInterruption(typeRaw: raw) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pauseCapture("音声機能が再起動されました") }
        })
    }

    /// 通知なしでエンジンが止まっていないかを、前面に来たときに確かめる。
    func checkEngine() {
        if isRecording, engine?.isRunning != true { pauseCapture("録音が止まっていました") }
        resendLeftovers()
    }

    private func handleInterruption(typeRaw: UInt?) {
        guard let raw = typeRaw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            pauseCapture("通話などで録音が中断されました")
        case .ended:
            // 自動では再開しない (利用者の操作が必要)。終わったことだけを触覚で知らせる
            if isPaused { WKInterfaceDevice.current().play(.directionUp) }
        @unknown default:
            break
        }
    }

    // MARK: - Chunks

    /// 区切りで閉じた区間を送り、電池を確認する。
    private func chunkFinished(_ chunk: FinishedChunk) {
        send(chunk)
        guard isRecording else { return }
        let device = WKInterfaceDevice.current()
        let charging = device.batteryState == .charging || device.batteryState == .full
        let level = device.batteryLevel
        if !charging, level >= 0, level < lowBatteryStopLevel {
            stop()
            lastError = "電池\(Int(level * 100))%のため停止"
            device.play(.failure)
        }
    }

    /// 送れずに残った区間 (WCSession 未有効・転送失敗) を送り直す。転送中のものは除く。
    func resendLeftovers() {
        guard wc.activationState == .activated else { return }
        let inFlight = Set(wc.outstandingFileTransfers.map { $0.file.fileURL.lastPathComponent })
        let current = writerFileName
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Self.chunkDirectory, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "m4a"
            && !inFlight.contains(url.lastPathComponent) && !sentNames.contains(url.lastPathComponent)
            && url.lastPathComponent != current {
            guard let stamp = Double(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "chunk-", with: "")) else { continue }
            guard let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0 else {
                // 強制終了などで完成しなかったファイル。十分古ければ消す (毎回開き直さない)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, Date().timeIntervalSince(modified) > 20 * 60 { try? FileManager.default.removeItem(at: url) }
                continue
            }
            // 旧版のファイル名は秒単位
            let startedAt = stamp > 100_000_000_000 ? stamp / 1000 : stamp
            sentNames.insert(url.lastPathComponent)
            let meta: [String: Any] = [
                TransferKey.startedAt: startedAt,
                TransferKey.duration: Double(f.length) / f.fileFormat.sampleRate,
                TransferKey.chunkIndex: 0,
                TransferKey.batteryLevel: WKInterfaceDevice.current().batteryLevel,
            ]
            wc.transferFile(url, metadata: meta)
        }
        pendingTransfers = wc.outstandingFileTransfers.count
    }

    /// 書き込み中のファイル名 (送り直しの対象から外す)。
    private var writerFileName: String? { writer?.currentFileName }

    private func send(_ chunk: FinishedChunk) {
        guard chunk.duration > 1 else {
            try? FileManager.default.removeItem(at: chunk.url)
            return
        }
        chunkCount += 1
        lastChunkAt = Date()
        sentNames.insert(chunk.url.lastPathComponent)
        let meta: [String: Any] = [
            TransferKey.startedAt: chunk.startedAt.timeIntervalSince1970,
            TransferKey.duration: chunk.duration,
            TransferKey.chunkIndex: chunkCount,
            TransferKey.batteryLevel: WKInterfaceDevice.current().batteryLevel,
        ]
        if wc.activationState == .activated {
            wc.transferFile(chunk.url, metadata: meta)
            pendingTransfers = wc.outstandingFileTransfers.count
        } else {
            lastError = "WCSession未アクティブ"
        }
    }
}

extension WatchRecorder: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in self.resendLeftovers() }
    }

    nonisolated func session(_ session: WCSession,
                             didFinish fileTransfer: WCSessionFileTransfer,
                             error: Error?) {
        // 転送完了したチャンクを削除 (失敗時は残す)
        if error == nil { try? FileManager.default.removeItem(at: fileTransfer.file.fileURL) }
        let name = fileTransfer.file.fileURL.lastPathComponent
        let failed = error != nil
        Task { @MainActor in
            // 失敗したものは送り直しの対象に戻す
            if failed { self.sentNames.remove(name) }
            self.pendingTransfers = WCSession.default.outstandingFileTransfers.count
            if let error { self.lastError = "転送失敗: \(error.localizedDescription)" }
        }
    }
}
