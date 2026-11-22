import Foundation
import SwiftData

@Model
final class Recording {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var duration: TimeInterval
    var batteryLevel: Double
    var fileName: String          // Documents/Audio/<fileName>
    var transcript: String?
    /// 校正する前の文字起こし (Whisper の出力そのまま)。校正しなかった録音では nil。
    var rawTranscript: String?
    /// 校正がまだ済んでいない (電池で処理した・時間切れで中断した)。次に充電しているときに校正する。
    var needsProofread: Bool = false
    var summary: String?
    var statusRaw: String         // pending / transcribing / done / failed
    var errorMessage: String?
    /// 文字起こしの試行回数。起動のたびに同じ録音で落ちるループを防ぐための上限判定に使う。
    var attempts: Int = 0

    init(startedAt: Date, duration: TimeInterval, batteryLevel: Double, fileName: String) {
        self.id = UUID()
        self.startedAt = startedAt
        self.duration = duration
        self.batteryLevel = batteryLevel
        self.fileName = fileName
        self.statusRaw = "pending"
    }

    var fileURL: URL { AudioStore.directory.appendingPathComponent(fileName) }
}

enum AudioStore {
    static var directory: URL {
        let d = URL.documentsDirectory.appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: d, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return d
    }
}
