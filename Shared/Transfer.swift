import Foundation

/// Watch -> iPhone 転送メタデータ。transferFile の metadata に載せる。
enum TransferKey {
    static let startedAt = "startedAt"      // TimeInterval since 1970
    static let duration = "duration"        // seconds
    static let chunkIndex = "chunkIndex"
    static let batteryLevel = "battery"     // 0...1
}
