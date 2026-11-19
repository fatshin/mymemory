import Foundation

/// 録音を続けられない状態 (開始失敗・割り込み) からの再試行予算。純粋な値型で、単体テストできる。
struct RecoveryBudget: Equatable {
    enum Decision: Equatable {
        case retry     // 一定時間後に再試行する
        case giveUp    // 録音を停止し、利用者へ知らせる
    }

    let maxConsecutiveFailures: Int
    private(set) var failures = 0
    private(set) var interrupted = false

    init(maxConsecutiveFailures: Int = 5) {
        self.maxConsecutiveFailures = maxConsecutiveFailures
    }

    mutating func interruptionBegan() { interrupted = true }

    /// 割り込みの終了。予算を満額に戻す。
    mutating func interruptionEnded() {
        interrupted = false
        failures = 0
    }

    /// 録音の開始に成功した。
    mutating func recordSuccess() {
        interrupted = false
        failures = 0
    }

    mutating func reset() {
        interrupted = false
        failures = 0
    }

    /// 割り込み中 (通話など) は長さに上限がないため、失敗しても予算を消費せず再試行を続ける。
    /// それ以外は、最初の失敗を含めて `maxConsecutiveFailures` 回目の失敗で諦める。
    mutating func recordFailure() -> Decision {
        if interrupted { return .retry }
        failures += 1
        return failures >= maxConsecutiveFailures ? .giveUp : .retry
    }
}
