import Foundation
import AVFoundation
import CoreML
import SwiftData
import UIKit
import WatchConnectivity
import WhisperKit

/// 受信 -> 保存 -> 文字起こし(オンデバイス) の直列パイプライン。
@MainActor
final class Pipeline: NSObject, ObservableObject {
    @Published var modelStatus = "未ロード"
    @Published var busy = false
    /// 処理待ちの録音数 (処理中の 1 件は含まない)。
    @Published private(set) var pendingCount = 0
    /// 充電待ち (非充電・残量不足) で止まっている。「今すぐ文字起こし」を出す条件。
    @Published private(set) var waitingForPower = false
    /// 背景継続を始められなかったときの理由 (前面実行に切り替えたことを伝える)。
    @Published private(set) var continuedNote: String?
    /// 継続タスクの起動ハンドラを登録できたか (App.init が設定する)。
    var continuedRegistered = false

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
    private var queue: [UUID] = [] { didSet { pendingCount = queue.count } }
    /// 利用者が「今すぐ」と押した時点の録音だけ、電力条件を緩める。drain が終わる、または継続タスクが失効したら必ず空にする。
    private var userRun = UserRunScope()
    /// 継続タスクの起動ハンドラが呼ばれたか (申請が黙って失敗していないかの確認に使う)。
    private var continuedStarted = false
    /// 継続タスクへ進捗 (音声の秒数) を報告する先。継続タスクが動いている間だけ持つ。
    private var progressSink: Progress?
    /// 自動要約の失敗回数 (録音ごと、アプリ起動中だけ保持) と、最後に自動要約を始めた時刻。
    private var autoSummaryFailures: [UUID: Int] = [:]
    private var lastAutoSummaryRun: Date?
    /// 見直し (端末内モデル) が混雑で止まった録音の要約。外部 API へ送り直さないよう、見直せるまで持っておく (アプリを終えたら消える)。
    private var awaitingReview: [UUID: (transcript: String, draft: Summarizer.Result)] = [:]
    private var runFinishedSeconds: Double = 0
    private var currentFileSeconds: Double = 0
    /// 実行中の drain。前面・通知・バックグラウンドのどこから呼んでも 1 本だけ動く。
    private var drainTask: Task<Void, Never>?
    /// 自動要約は文字起こしとは別に動かす (外部 API の待ちで文字起こしと「今すぐ文字起こし」を止めない)。
    private var summaryTask: Task<Void, Never>?
    private var summaryToken = UUID()

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
        pruneOldAudio()
    }

    /// 設定で選んだ日数より古い、文字起こし済みの録音の音声ファイルだけを消す (既定は消さない)。
    func pruneOldAudio(now: Date = Date()) {
        let days = RetentionPolicy.days
        guard days > 0 else { return }
        let desc = FetchDescriptor<Recording>(predicate: #Predicate { $0.statusRaw == "done" })
        let recs = (try? context.fetch(desc)) ?? []
        let items = recs.map { RetentionPolicy.Item(id: $0.id, startedAt: $0.startedAt, transcribed: !($0.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        let ids = Set(RetentionPolicy.audioToDelete(items, now: now, days: days))
        for rec in recs where ids.contains(rec.id) {
            try? FileManager.default.removeItem(at: rec.fileURL)
        }
    }

    // MARK: Power policy (省電力)

    /// 文字起こしは電力を最も使う処理。判定は PowerPolicy (単体テスト対象) に委ねる。
    private func currentCharge() -> PowerPolicy.Charge {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        switch device.batteryState {
        case .charging, .full: return .charging
        case .unplugged: return .unplugged
        default: return .unknown
        }
    }

    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private func canTranscribeNow(userInitiated: Bool) -> Bool {
        let device = UIDevice.current
        let charge = currentCharge()
        return PowerPolicy.shouldTranscribe(
            charge: charge,
            level: device.batteryLevel,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isSimulator: isSimulator,
            userInitiated: userInitiated)
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
        // 保留が無くても、要約の無い文字起こしがあれば自動要約のために処理を始める
        if !queue.isEmpty || hasUnsummarized() { startDrain() }
    }

    private func hasUnsummarized() -> Bool {
        var d = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.statusRaw == "done" && $0.summary == nil && $0.transcript != nil && $0.transcript != "" })
        d.fetchLimit = 1
        return ((try? context.fetchCount(d)) ?? 0) > 0
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

    nonisolated static func audioDuration(_ url: URL) -> TimeInterval {
        guard let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0 else { return 0 }
        return Double(f.length) / f.fileFormat.sampleRate
    }

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
        // 文字起こしを優先する。文字起こす録音があるときだけ、走っている自動要約を止めて後で始め直す
        // (要約だけの drain で止めると、外部 API の結果を捨てて送り直すことになる)
        if !queue.isEmpty { stopSummaryBacklog() }
        let task = Task { @MainActor [self] in
            await runDrain()
            drainTask = nil
            if !Task.isCancelled { startSummaryBacklog() }
            // 次の通常の drain には明示操作の緩和を引き継がない (非充電のまま走り続けるのを防ぐ)
            userRun.clear()
            if queue.isEmpty { continuedNote = nil }
        }
        drainTask = task
        return task
    }

    /// 利用者の「今すぐ文字起こし」。画面を閉じても続くよう継続タスクを申請し、前面でもすぐ処理を始める。
    /// 申請できない (シミュレータ・即時実行不可・識別子未登録) ときは、理由を残して前面実行にとどめる。
    func startNow() {
        guard waitingForPower, !userRun.isActive, !queue.isEmpty else { return }
        // 残量が下限未満なら、申請もせず理由を示す (申請だけ通って即停止し、Live Activity が失敗表示になるのを避ける)
        guard canTranscribeNow(userInitiated: true) else {
            modelStatus = "電池残量が\(Int(PowerPolicy.minimumLevelUserInitiated * 100))%未満のため開始できません (\(queue.count)件保留)"
            return
        }
        userRun.begin(queue)
        runFinishedSeconds = 0
        continuedNote = nil
        continuedStarted = false
        if !continuedRegistered {
            continuedNote = "背景で続ける設定が無効なため、画面を開いたまま処理します"
        } else if !modelOnDisk {
            // モデルの取得中は進捗を報告できず、OS に停止とみなされて失効するため申請しない
            continuedNote = "初回は文字起こし用のモデルを取得するため、画面を開いたまま処理します"
        } else if let reason = BackgroundTranscribe.submitContinued(pending: queue.count) {
            continuedNote = "背景実行を開始できないため、画面を開いたまま処理します (\(reason))"
        } else {
            // 同期の申請は即時実行不可を返さない場合がある。起動ハンドラが来なければ、画面を閉じると止まると伝える
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.userRun.isActive, !self.continuedStarted, self.continuedNote == nil else { return }
                self.continuedNote = "背景実行が始まっていない可能性があります。完了まで画面を開いたままにしてください"
            }
        }
        startDrain()
    }

    /// 継続タスクの実行。新しい drain は作らず、前面で始めた共有 drain に乗る。
    /// 失効 (利用者が Live Activity で中止した場合を含む) では drain を取り消し、明示操作の緩和を落とし、
    /// 通常の背景処理を再申請する。
    func runContinued(_ handle: TaskHandle) {
        continuedStarted = true
        progressSink = handle.progress
        handle.progress?.totalUnitCount = max(1, Int64(runFinishedSeconds + pendingSeconds()))
        reportProgress()
        let task = startDrain()
        handle.setExpirationHandler { [weak self] in
            task.cancel()
            Task { @MainActor in
                self?.userRun.clear()
                BackgroundTranscribe.schedule(needsNetwork: !(self?.modelOnDisk ?? false))
            }
            // 推論が取り消しにすぐ応じない場合に備え、猶予後に必ず完了を通知する
            Task {
                try? await Task.sleep(for: .seconds(2))
                handle.complete(success: false)
            }
        }
        Task { @MainActor in
            await task.value
            // 後続の継続タスクが設定した進捗先を消さない
            if progressSink === handle.progress { progressSink = nil }
            let finished = !task.isCancelled && queue.isEmpty
            handle.complete(success: finished)
            // 継続タスクの中では要約しないため、終わってから始める (前面にいるときだけ動く)
            startSummaryBacklog()
            // 中止・失効で止まった場合も、保留があれば通常の電力判定をやり直し、状態表示とボタンを更新する
            if !queue.isEmpty { startDrain() }
        }
    }

    /// 処理待ち (処理中を含む) の録音の合計秒数。継続タスクの進捗の分母。
    private func pendingSeconds() -> Double {
        let desc = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.statusRaw == "pending" || $0.statusRaw == "transcribing" })
        return ((try? context.fetch(desc)) ?? []).reduce(0) { $0 + max(0, $1.duration) }
    }

    private func reportProgress(windowIndex: Int = 0) {
        guard let sink = progressSink else { return }
        let done = ContinuedProgress.completedUnits(
            finishedSeconds: runFinishedSeconds, windowIndex: windowIndex, fileSeconds: currentFileSeconds)
        sink.totalUnitCount = max(sink.totalUnitCount, done, 1)
        sink.completedUnitCount = done
    }

    /// OS が外部電源接続中に起動するバックグラウンド実行。
    /// 前面で既に動いている drain があれば、それの終了を待つ (即完了して OS にサスペンドされるのを防ぐ)。
    /// 時間切れでは drain を取り消し、中断した録音を pending に戻す後始末を待ってから完了を通知する。
    func runBackground(_ handle: TaskHandle) {
        let task = startDrain()
        handle.setExpirationHandler { [weak self] in
            // 継続タスクが実際に同じ drain を進めている間だけ、処理タスクの失効で取り消さない
            // (「今すぐ」を押しても継続タスクが始まっていなければ、失効時に取り消して pending に戻す)
            Task { @MainActor in
                if self?.progressSink == nil { task.cancel() }
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
        waitingForPower = false
        defer { busy = false }
        // 実行中にアプリが停止しても夜間の充電時に OS が再開できるよう、保留があるあいだ常に申請しておく
        if !queue.isEmpty { BackgroundTranscribe.schedule(needsNetwork: !modelOnDisk) }
        while !queue.isEmpty, !Task.isCancelled {
            if modelLoadFailures >= Self.maxModelLoadFailures { return }
            let forced = userRun.covers(queue.first)
            guard canTranscribeNow(userInitiated: forced) else {
                waitingForPower = true
                modelStatus = forced
                    ? "電池残量が\(Int(PowerPolicy.minimumLevelUserInitiated * 100))%未満のため停止 (\(queue.count)件保留)"
                    : "充電待ち (\(queue.count)件保留)"
                BackgroundTranscribe.schedule(needsNetwork: !modelOnDisk)
                // 文字起こしは充電待ちでも、済んだ分の要約は外部 API なら進められる (drain の後に別のタスクで行う)
                return
            }
            // 継続タスクの進捗の分母は、新しく届いた録音も含めて取り直す
            if let sink = progressSink {
                sink.totalUnitCount = max(1, Int64(runFinishedSeconds + pendingSeconds()))
            }
            let id = queue.removeFirst()
            defer { userRun.finish(id) }
            let desc = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
            // pending 以外 (完了済み・処理中・失敗確定) は二重処理しない
            guard let rec = try? context.fetch(desc).first, rec.statusRaw == "pending" else { continue }
            rec.statusRaw = "transcribing"
            rec.attempts += 1
            try? context.save()
            do {
                if !modelLoaded { modelStatus = "モデルDL/ロード中…" }
                currentFileSeconds = rec.duration > 0 ? rec.duration : Self.audioDuration(rec.fileURL)
                reportProgress()
                // 進捗の更新は軽く保つ (ウィンドウが変わったときだけ MainActor へ戻す)
                let result = try await transcriber.transcribe(audioPath: rec.fileURL.path) { [weak self] window in
                    Task { @MainActor in self?.reportProgress(windowIndex: window) }
                }
                if !result.skippedSilent {
                    modelLoaded = true
                    modelLoadFailures = 0
                    modelStatus = "準備完了"
                }
                var text = result.text
                var raw: String?
                var proofreadDone = false
                if !text.isEmpty, canProofreadNow {
                    modelStatus = "文字起こしを校正中…"
                    let fileEnd = Int.max / 64  // 進捗は録音の終わりまで (校正中も継続タスクへ更新を送る)
                    // 校正は必須ではない。時間切れで取り消されたら、終わった文字起こしを捨てずに保存し、校正は後で行う
                    if let proofread = try? await Proofreader.proofread(text, onChunk: { [weak self] in
                        Task { @MainActor in self?.reportProgress(windowIndex: fileEnd) }
                    }) {
                        proofreadDone = true
                        if proofread != text {
                            raw = text
                            text = proofread
                        }
                    }
                    modelStatus = "準備完了"
                }
                rec.transcript = text
                rec.rawTranscript = raw
                rec.needsProofread = !text.isEmpty && !proofreadDone
                // 文字が残らなかった理由を見えるようにする (文字起こしに成功した見た目にしない)
                rec.errorMessage = result.text.isEmpty ? result.emptyReason : nil
                rec.summary = nil  // 文字起こし直したら古い要約は使わない (振り返りで再利用されるため)
                rec.statusRaw = "done"
                runFinishedSeconds += currentFileSeconds
                currentFileSeconds = 0
                reportProgress()
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
        if !Task.isCancelled { await proofreadBacklog() }
    }

    /// 前面にいるときだけ始める。背景タスクは drain が終わると OS に完了を伝えるため、その後の通信は途中で止められ、
    /// 失敗として数えられて自動要約の対象から外れてしまう。背景で済んだ録音は、次に開いたときに要約する。
    func startSummaryBacklog() {
        guard summaryTask == nil, drainTask == nil, progressSink == nil, UIApplication.shared.applicationState == .active else { return }
        let token = UUID()
        summaryToken = token
        summaryTask = Task { @MainActor [self] in
            await summarizeBacklog()
            if summaryToken == token { summaryTask = nil }
        }
    }

    /// 止めた分は間隔を待たずに、次の drain の後で始め直せるようにする。
    private func stopSummaryBacklog() {
        guard let t = summaryTask else { return }
        t.cancel()
        if modelStatus.hasPrefix("要約を作成中") { modelStatus = "準備完了" }
        summaryTask = nil
        summaryToken = UUID()
        lastAutoSummaryRun = nil
    }

    /// 校正してよい状態か (外部電源につながっていて、端末内モデルが使える)。
    private var canProofreadNow: Bool {
        PowerPolicy.shouldProofread(charge: currentCharge(), isSimulator: isSimulator) && OnDeviceSummarizer.isAvailable
    }

    /// 1 回の処理で後から校正する録音の上限。
    static let proofreadBacklogLimit = 10

    /// 電池で処理した・時間切れで中断した録音を、充電中に校正する。要約より先に行い、要約は校正後の文から作る。
    /// 校正を待つ間に要約された録音は、校正しない (要約と文字起こしをずらさない)。
    /// 継続タスク (利用者の「今すぐ」) の中では行わない (進捗が動かず、OS に止められるおそれがあるため)。
    private func proofreadBacklog() async {
        guard progressSink == nil, canProofreadNow else { return }
        var d = FetchDescriptor<Recording>(
            // 要約済みの録音は対象外 (校正で文が変わると要約の根拠とずれる。要約には利用者の TODO の完了・編集が入っているため消さない)
            predicate: #Predicate { $0.needsProofread && $0.statusRaw == "done" && $0.summary == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        d.fetchLimit = Self.proofreadBacklogLimit
        guard let recs = try? context.fetch(d), !recs.isEmpty else { return }
        defer { if modelStatus.hasPrefix("文字起こしを校正中") { modelStatus = "準備完了" } }
        for (i, rec) in recs.enumerated() {
            guard !Task.isCancelled, canProofreadNow else { return }
            guard rec.isAlive else { continue }
            guard let t = rec.transcript, !t.isEmpty else { rec.needsProofread = false; continue }
            modelStatus = "文字起こしを校正中 \(i + 1) / \(recs.count)"
            guard let fixed = try? await Proofreader.proofread(t) else { return }  // 取り消し・一時的な失敗: 校正待ちのまま次の機会に回す
            // 待つ間に削除・文字起こし直しされた録音には上書きしない
            guard rec.isAlive, rec.transcript == t, rec.summary == nil else { continue }
            if fixed != t {
                rec.rawTranscript = t
                rec.transcript = fixed
            }
            rec.needsProofread = false
            try? context.save()
        }
    }

    /// 1 回の処理で自動要約する録音の上限 (外部 API の呼び出し回数と時間を抑える)。
    static let autoSummaryLimit = 20

    /// 自動要約に続けて失敗した録音は、アプリを再起動するまで自動では試さない (外部 API への再送を繰り返さない)。
    static let autoSummaryMaxFailures = 2
    /// 電源の通知のたびに走らないよう、自動要約の開始に間隔を空ける。
    static let autoSummaryInterval: TimeInterval = 120

    /// 文字起こし済みで要約の無い録音を、新しい順に要約して保存する (最初の画面とやることの一覧に使う)。
    /// 外部 API は利用者が送信を許可したときだけ (Summarizer が経路を決める)。端末内モデルは電力を使うため充電中だけ。
    /// 画面を閉じても続く継続タスクの中では行わない (進捗を送れず、OS に止められるのを避ける)。
    private func summarizeBacklog() async {
        guard progressSink == nil else { return }
        if let last = lastAutoSummaryRun, Date().timeIntervalSince(last) < Self.autoSummaryInterval { return }
        guard let firstRoute = try? Summarizer.currentRoute(), autoSummaryPowerOK(firstRoute) else { return }
        lastAutoSummaryRun = Date()
        var d = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.statusRaw == "done" && $0.summary == nil && $0.transcript != nil && $0.transcript != "" },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        d.fetchLimit = Self.autoSummaryLimit
        guard let recs = try? context.fetch(d) else { return }
        let targets = recs.filter { (autoSummaryFailures[$0.id] ?? 0) < Self.autoSummaryMaxFailures }
        guard !targets.isEmpty else { return }
        // 中断・取り消しでも「要約を作成中」の表示を残さない (「充電待ち」などの表示に戻す)
        let statusBefore = modelStatus
        // 取り消された古い要約は表示に触れない (文字起こしの表示を上書きしない)
        defer { if !Task.isCancelled, modelStatus.hasPrefix("要約を作成中") { modelStatus = statusBefore } }
        // 削除・要約済み・対象外になった録音の持ち越しは捨てる (文字起こしをメモリに残さない)
        let ids = Set(targets.map(\.id))
        awaitingReview = awaitingReview.filter { ids.contains($0.key) }
        var consecutiveFailures = 0, consecutiveBusy = 0
        for (i, rec) in targets.enumerated() {
            if Task.isCancelled || !rec.isAlive { continue }
            // 端末内モデルが混み続けるときは、残りを次の機会に回す
            if consecutiveBusy >= 3 { return }
            // 許可の取り消し・送信先の切り替え・充電の抜き差しを 1 件ごとに反映する
            guard let route = try? Summarizer.currentRoute(), route == firstRoute, autoSummaryPowerOK(route) else { return }
            guard let t = rec.transcript, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard !Task.isCancelled else { return }
            modelStatus = "要約を作成中 \(i + 1) / \(targets.count)"
            do {
                let draft: Summarizer.Result
                if let held = awaitingReview[rec.id], held.transcript == t {
                    draft = held.draft
                } else {
                    // 雑音や断片だけの録音は要約しない (外部 API へも送らない)。判定できなければ要約する
                    if try await SummaryReviewer.isMeaningful(t) == false {
                        if rec.isAlive, rec.transcript == t, rec.summary == nil {
                            rec.summary = SummaryReviewGuard.notMeaningfulSummary  // 要約はしていないため「で要約」の注記は付けない
                            try? context.save()
                        }
                        continue
                    }
                    draft = try await Summarizer.summarize(t, route: route)
                }
                // 表示する前に端末内モデルで見直す。混雑で見直せなければ、要約を持ったまま次の機会に回す
                let result: Summarizer.Result
                do {
                    result = try await Summarizer.review(draft)
                } catch is SummaryReviewer.Busy {
                    awaitingReview[rec.id] = (t, draft)
                    consecutiveBusy += 1
                    continue
                }
                awaitingReview[rec.id] = nil
                consecutiveFailures = 0
                consecutiveBusy = 0
                // 待つ間に削除・文字起こし直し・手動要約された録音には上書きしない
                if rec.isAlive, rec.transcript == t, rec.summary == nil {
                    rec.summary = result.labeled
                    try? context.save()
                }
            } catch is SummaryReviewer.Busy {
                consecutiveBusy += 1  // 意味の判定が混雑で止まった。この録音は外部 API へ送らずに次の機会に回す
            } catch {
                if Task.isCancelled { return }
                autoSummaryFailures[rec.id, default: 0] += 1
                consecutiveFailures += 1
                // 続けて失敗するのは通信断・キー無効などの共通の原因が多い。残りは次回に回す
                if consecutiveFailures >= 2 { return }
            }
        }
    }

    /// 端末内モデルは充電中だけ。外部 API は端末の負荷が小さいので電源を問わない (送信の許可は経路の判定で確認済み)。
    private func autoSummaryPowerOK(_ route: SummaryRoute) -> Bool {
        route == .remote || PowerPolicy.shouldProofread(charge: currentCharge(), isSimulator: isSimulator)
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

    /// メル計算は既定で GPU を使うが、背景では GPU を使えない (専用 entitlement が必要で、非対応の端末もある)。
    /// 計算が軽いメルだけ CPU に固定し、重いエンコーダ・デコーダは既定 (ANE) のままにする。
    private static let computeOptions = ModelComputeOptions(melCompute: .cpuOnly)

    struct Output: Sendable {
        let text: String
        let level: AudioLevel?
        /// 無音と判定して Whisper を呼ばなかった。
        let skippedSilent: Bool

        var emptyReason: String {
            let db = level.map { " (最大音量 \(Int($0.peakDBFS)) dBFS)" } ?? ""
            return skippedSilent ? "無音と判定したため文字起こししていません\(db)" : "音声を言葉として認識できませんでした\(db)"
        }
    }

    /// 句読点のある日本語を出すよう、書き方の手本として Whisper に渡す文。
    /// 無音区間で手本をそのまま出すことがあるため、TranscriptCleaner.hallucinations にも入れている。
    static let promptText = "以下は、日本語の会話の書き起こしです。"
    private var cachedPromptTokens: [Int]?

    private func promptTokens(_ w: WhisperKit) -> [Int]? {
        if let cachedPromptTokens { return cachedPromptTokens }
        guard let tokens = w.tokenizer?.encode(text: Self.promptText), !tokens.isEmpty else { return nil }
        cachedPromptTokens = tokens
        return tokens
    }

    /// - Parameter onWindow: 30 秒ウィンドウが進むたびに、処理中のウィンドウ番号 (0 始まり) を渡す。
    @concurrent
    func transcribe(audioPath: String, onWindow: (@Sendable (Int) -> Void)? = nil) async throws -> Output {
        // 無音ならモデルを読み込まずに終える (Whisper は無音から定型文を作るうえ、電力も使う)
        let level = AudioLevel.measure(URL(fileURLWithPath: audioPath))
        if let level, level.isSilent { return Output(text: "", level: level, skippedSilent: true) }
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
                    created = try await WhisperKit(WhisperKitConfig(
                        modelFolder: saved, computeOptions: Self.computeOptions, load: false, download: false))
                } else {
                    created = try await WhisperKit(WhisperKitConfig(
                        model: Pipeline.modelName, computeOptions: Self.computeOptions))
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
        var lastWindow = -1
        let results = try await w.transcribe(
            audioPath: audioPath,
            decodeOptions: DecodingOptions(language: "ja", skipSpecialTokens: true, promptTokens: promptTokens(w))
        ) { progress in
            if progress.windowId != lastWindow {
                lastWindow = progress.windowId
                onWindow?(progress.windowId)
            }
            return nil  // 続行 (取り消しは Task の取り消しで効く)
        }
        let segments = results.flatMap(\.segments).map {
            TranscriptCleaner.Segment(text: $0.text)
        }
        return Output(text: TranscriptCleaner.clean(segments), level: level, skippedSilent: false)
    }
}

/// モデルの取得・ロードに失敗した。録音そのものの失敗とは区別して、保留として扱う。
struct ModelLoadError: Error, LocalizedError {
    let underlying: String
    var errorDescription: String? { "モデルを取得できません: \(underlying)" }
}
