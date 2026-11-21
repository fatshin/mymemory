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

    // MARK: AutoStartPolicy

    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Tokyo")!; return c }
    private func at(_ day: Int, _ hour: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    /// 開いたら録音が始まる (設定 ON・止まっている・今日は利用者が止めていない)。
    func testAutoStartsWhenOpened() {
        XCTAssertTrue(AutoStartPolicy.shouldStart(enabled: true, isActive: false, isBatteryLow: false,
                                                  lastManualStop: nil, now: at(22, 9), calendar: cal))
    }

    /// 停止ボタンで止めた日は、確認のために開いても始めない。翌日はまた始める。
    func testManualStopSuppressesOnlyThatDay() {
        XCTAssertFalse(AutoStartPolicy.shouldStart(enabled: true, isActive: false, isBatteryLow: false,
                                                   lastManualStop: at(22, 9), now: at(22, 21), calendar: cal))
        XCTAssertTrue(AutoStartPolicy.shouldStart(enabled: true, isActive: false, isBatteryLow: false,
                                                  lastManualStop: at(22, 21), now: at(23, 7), calendar: cal))
    }

    /// 設定 OFF・録音中や一時停止中・電池残量が少ないときは始めない。
    func testNoAutoStartWhenDisabledActiveOrLowBattery() {
        let now = at(22, 9)
        XCTAssertFalse(AutoStartPolicy.shouldStart(enabled: false, isActive: false, isBatteryLow: false, lastManualStop: nil, now: now, calendar: cal))
        XCTAssertFalse(AutoStartPolicy.shouldStart(enabled: true, isActive: true, isBatteryLow: false, lastManualStop: nil, now: now, calendar: cal))
        XCTAssertFalse(AutoStartPolicy.shouldStart(enabled: true, isActive: false, isBatteryLow: true, lastManualStop: nil, now: now, calendar: cal))
    }
}
