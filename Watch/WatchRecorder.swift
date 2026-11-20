import Foundation
import AVFoundation
import WatchConnectivity
import WatchKit

/// 常時録音。10 分ごとに区切って iPhone へ transferFile する。
/// バックグラウンドの継続は音声のバックグラウンド実行 (UIBackgroundModes: audio) に頼る。
/// watchOS では「録音は前面での利用者の操作で始める必要があり、始めた後はバックグラウンドでも続けられる。
/// バックグラウンドでの再開はできない」(Apple の回答) ため、区切りでもエンジンを止めず、
/// 中断されたら一時停止にし、中断が終われば自動で再開する (できなければ利用者のタップを待つ)。
@MainActor
final class WatchRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    /// 着信などで止まっている (自動再開を待っているか、利用者のタップを待っている)。
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
    /// 止まった理由 (自動で再開してよいかの判定に使う)。
    private var pauseReason: PauseReason?
    private var resumeLimiter = AutoResumeLimiter()
    private var autoResumeTask: Task<Void, Never>?
    /// 録音を始めるたびに増やす。古いエンジンの通知が遅れて届いても、新しい録音を止めないために使う。
    private var captureGeneration = 0

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

    /// 中断後の再開。利用者のタップと自動再開の両方から呼ぶ。成功したら true。
    @discardableResult
    func resume() -> Bool {
        guard isPaused, !starting else { return false }
        lastError = nil
        guard startCapture() else { return false }
        isPaused = false
        pauseReason = nil
        autoResumeTask?.cancel()
        autoResumeTask = nil
        return true
    }

    func stop() {
        guard isRecording || isPaused else { return }
        autoResumeTask?.cancel()
        autoResumeTask = nil
        pauseReason = nil
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
        captureGeneration += 1
        let generation = captureGeneration
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
                Task { @MainActor in
                    self?.pauseCapture("録音に失敗: \(message)", reason: .writeFailed, generation: generation)
                }
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: format,
                             block: Self.makeTap(writer: writer, onError: onError))
            // 開始の途中で起きた経路変化も取りこぼさないよう、開始より前に購読する
            engineObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.pauseCapture("音声の経路が変わりました", reason: .routeChange, generation: generation)
                }
            }
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.writer = writer
            isRecording = true
            return true
        } catch {
            if let o = engineObserver { NotificationCenter.default.removeObserver(o) }
            engineObserver = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            // 実機確認用: バックグラウンドからの開始を拒否されたか (コード) を残す
            lastError = "録音を開始できません (\((error as NSError).code)): \(error.localizedDescription)"
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

    /// 中断・失敗時。そこまでを送る。中断以外の自動再開できる理由なら、すぐに再開を試す
    /// (中断は終了の通知を待つ。届かなくても前面に来たときに再開する)。
    private func pauseCapture(_ message: String, reason: PauseReason, generation: Int? = nil) {
        guard isRecording else { return }
        // 前のエンジンの通知が遅れて届いた場合は無視する
        if let generation, generation != captureGeneration { return }
        stopCapture()
        isRecording = false
        isPaused = true
        pauseReason = reason
        lastError = reason.allowsAutoResume ? "\(message)。自動で再開します" : "\(message)。タップで再開"
        WKInterfaceDevice.current().play(.notification)
        // 中断は終了の通知を待つ。エンジン停止は前面に来たとき (checkEngine) にその場で再開する
        if reason == .routeChange || reason == .mediaReset { scheduleAutoResume() }
    }

    /// すぐ・2 秒後・5 秒後に再開を試す。全体の上限 (10 分に 5 回) に達したら、利用者のタップを待つ。
    private func scheduleAutoResume() {
        autoResumeTask?.cancel()
        autoResumeTask = Task { @MainActor [weak self] in
            for delay in AutoResumeLimiter.delays {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard let self, !Task.isCancelled, self.isPaused else { return }
                guard !self.isBatteryLow else {
                    self.lastError = "電池が少ないため再開しません。タップで再開"
                    return
                }
                guard self.resumeLimiter.allow(now: Date()) else {
                    self.lastError = "自動再開の上限に達しました。タップで再開"
                    WKInterfaceDevice.current().play(.notification)
                    return
                }
                if self.resume() {
                    WKInterfaceDevice.current().play(.directionUp)
                    return
                }
                // バックグラウンドで開始を拒否されたなら、待っても変わらないため残りの再試行をやめる (電力と回数の節約)
                if WKApplication.shared().applicationState != .active { break }
            }
            // 3 回とも失敗 (バックグラウンドからの開始を拒否された等)。理由は resume が lastError に残している
            guard let self, self.isPaused else { return }
            self.lastError = (self.lastError ?? "録音を再開できません") + "。タップで再開"
            WKInterfaceDevice.current().play(.notification)
        }
    }

    /// 着信・Siri などの中断と、マイクの経路の変化を監視する。
    private func observeAudioSession() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in self?.handleInterruption(typeRaw: raw, optionsRaw: options) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pauseCapture("音声機能が再起動されました", reason: .mediaReset) }
        })
    }

    /// 通知なしでエンジンが止まっていないかを、前面に来たときに確かめる。
    /// 前面に来たときは、止まっていれば (自動再開できる理由なら) その場で再開する。
    /// 中断の終了の通知は届く保証がないため、ここを主な再開の経路とする。
    func checkEngine() {
        if isRecording, engine?.isRunning != true { pauseCapture("録音が止まっていました", reason: .engineStopped) }
        if isPaused, pauseReason?.allowsAutoResume == true, !isBatteryLow, resume() {
            WKInterfaceDevice.current().play(.directionUp)
        }
        resendLeftovers()
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let raw = typeRaw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if isPaused {
                // 別の理由で止まって再開を待っている間に中断が始まった: 中断の終了まで再試行しない
                autoResumeTask?.cancel()
                autoResumeTask = nil
                if pauseReason?.allowsAutoResume == true { pauseReason = .interruption }
            } else {
                pauseCapture("通話などで録音が中断されました", reason: .interruption)
            }
        case .ended:
            guard isPaused, pauseReason?.allowsAutoResume == true else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
            if options.contains(.shouldResume) {
                scheduleAutoResume()
            } else {
                // 割り込んだ側がまだ音声を使っている。前面に来たとき (checkEngine) に再開する
                lastError = "中断が終わりました。画面を開くと再開します"
            }
        @unknown default:
            break
        }
    }

    /// 非充電で電池が停止の基準を下回っている (自動では再開しない)。
    private var isBatteryLow: Bool {
        let device = WKInterfaceDevice.current()
        let charging = device.batteryState == .charging || device.batteryState == .full
        return !charging && device.batteryLevel >= 0 && device.batteryLevel < lowBatteryStopLevel
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
