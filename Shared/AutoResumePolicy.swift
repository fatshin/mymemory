import Foundation

/// Watch の録音が止まった理由。自動で再開してよいかの判定に使う。
enum PauseReason: Equatable {
    case interruption    // 着信・Siri など (終了の通知を待ってから再開)
    case routeChange     // マイクの経路の変化
    case mediaReset      // 音声機能の再起動
    case engineStopped   // 通知なしでエンジンが止まっていた
    case writeFailed     // 書き込みの失敗 (容量不足など)。再開しても繰り返し失敗するため自動では再開しない

    var allowsAutoResume: Bool { self != .writeFailed }
}

/// 自動再開の回数制限。1 回の停止ごとの再試行 (`delays`) と、
/// 経路の切り替わりが続いて再開と停止を繰り返すのを防ぐ全体の上限 (`window` の間に `maxAttempts` 回まで) の 2 段。
struct AutoResumeLimiter: Equatable {
    static let delays: [TimeInterval] = [0, 2, 5]

    let maxAttempts: Int
    let window: TimeInterval
    private(set) var attempts: [Date] = []

    init(maxAttempts: Int = 5, window: TimeInterval = 10 * 60) {
        self.maxAttempts = maxAttempts
        self.window = window
    }

    /// 試してよければ記録して true。上限に達していれば false (利用者のタップを待つ)。
    mutating func allow(now: Date) -> Bool {
        attempts = attempts.filter { now.timeIntervalSince($0) < window }
        guard attempts.count < maxAttempts else { return false }
        attempts.append(now)
        return true
    }
}
