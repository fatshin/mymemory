import Foundation

/// 古い音声ファイルの自動削除 (利用者が設定で選んだときだけ。既定はしない)。
/// 文字起こしと要約は残し、端末の容量を占める音声だけを消す。文字起こしが終わっていない録音は消さない。
enum RetentionPolicy {
    static let key = "audioRetentionDays"
    /// 選べる日数。0 は「削除しない」。
    static let choices = [0, 30, 90, 180]

    struct Item: Equatable {
        let id: UUID
        let startedAt: Date
        let transcribed: Bool
    }

    /// 削除してよい録音。日数が 0 以下なら何も消さない。
    static func audioToDelete(_ items: [Item], now: Date, days: Int) -> [UUID] {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return items.filter { $0.transcribed && $0.startedAt < cutoff }.map(\.id)
    }

    static var days: Int { UserDefaults.standard.integer(forKey: key) }
}
