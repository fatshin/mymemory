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
    var summary: String?
    var statusRaw: String         // pending / transcribing / done / failed
    var errorMessage: String?

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
