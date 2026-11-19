import Foundation
import SwiftData
import WatchConnectivity
import WhisperKit

/// 受信 -> 保存 -> 文字起こし(オンデバイス) の直列パイプライン。
@MainActor
final class Pipeline: NSObject, ObservableObject {
    @Published var modelStatus = "未ロード"
    @Published var busy = false

    private let context: ModelContext
    private var whisper: WhisperKit?
    private var queue: [UUID] = []

    /// 日本語向け。モデル名はWhisperKit側の対応表に依存 (要確認)。
    static let modelName = "large-v3-v20240930_626MB"

    init(context: ModelContext) {
        self.context = context
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: Receive

    fileprivate func ingest(tempURL: URL, meta: [String: Any]) {
        let startedAt = Date(timeIntervalSince1970: meta[TransferKey.startedAt] as? TimeInterval ?? Date().timeIntervalSince1970)
        let duration = meta[TransferKey.duration] as? TimeInterval ?? 0
        let battery = Double(meta[TransferKey.batteryLevel] as? Float ?? -1)
        let name = "\(Int(startedAt.timeIntervalSince1970)).m4a"
        let dest = AudioStore.directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: tempURL, to: dest) } catch { return }
        let rec = Recording(startedAt: startedAt, duration: duration, batteryLevel: battery, fileName: name)
        context.insert(rec)
        try? context.save()
        queue.append(rec.id)
        Task { await drain() }
    }

    // MARK: Transcribe

    func retry(_ rec: Recording) {
        rec.statusRaw = "pending"; rec.errorMessage = nil
        try? context.save()
        queue.append(rec.id)
        Task { await drain() }
    }

    private func loadModel() async throws -> WhisperKit {
        if let w = whisper { return w }
        modelStatus = "モデルDL/ロード中…"
        let w = try await WhisperKit(WhisperKitConfig(model: Self.modelName))
        whisper = w
        modelStatus = "準備完了"
        return w
    }

    private func drain() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        while !queue.isEmpty {
            let id = queue.removeFirst()
            let desc = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
            guard let rec = try? context.fetch(desc).first else { continue }
            rec.statusRaw = "transcribing"
            try? context.save()
            do {
                let w = try await loadModel()
                let results = try await w.transcribe(
                    audioPath: rec.fileURL.path,
                    decodeOptions: DecodingOptions(language: "ja"))
                rec.transcript = results.map(\.text).joined(separator: "\n")
                rec.statusRaw = "done"
            } catch {
                rec.statusRaw = "failed"
                rec.errorMessage = error.localizedDescription
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
        let meta = file.metadata ?? [:]
        Task { @MainActor in self.ingest(tempURL: tmp, meta: meta) }
    }
}
