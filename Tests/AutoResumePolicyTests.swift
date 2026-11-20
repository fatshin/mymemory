import XCTest

final class AutoResumePolicyTests: XCTestCase {
    /// 書き込みの失敗 (容量不足など) は自動で再開しない。繰り返し失敗して電池を減らすため。
    func testWriteFailureIsNotAutoResumed() {
        XCTAssertFalse(PauseReason.writeFailed.allowsAutoResume)
        for r in [PauseReason.interruption, .routeChange, .mediaReset, .engineStopped] {
            XCTAssertTrue(r.allowsAutoResume, "\(r)")
        }
    }

    /// 経路の切り替わりが続いても、10 分間に 5 回で打ち切る (再開と停止の繰り返しで電池を減らさない)。
    func testLimiterCapsAttemptsInWindow() {
        var l = AutoResumeLimiter(maxAttempts: 5, window: 600)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<5 { XCTAssertTrue(l.allow(now: t0.addingTimeInterval(Double(i)))) }
        XCTAssertFalse(l.allow(now: t0.addingTimeInterval(10)))
        // 窓を過ぎれば再び試せる (長い録音の途中で起きた別の中断は自動で戻す)
        XCTAssertTrue(l.allow(now: t0.addingTimeInterval(601)))
    }

    /// 1 回の停止につき、すぐ・2 秒後・5 秒後の 3 回まで。
    func testPerPauseDelays() {
        XCTAssertEqual(AutoResumeLimiter.delays, [0, 2, 5])
    }
}
