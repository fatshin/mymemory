import XCTest

final class FreeTrialTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func day(_ n: Double) -> Date { start.addingTimeInterval(n * 86_400) }

    /// 開始日が無い (まだ確定していない) ときは体験中として扱わない (無料枠の判定に戻す)。
    func testNoStartMeansNoTrial() {
        XCTAssertFalse(FreeTrial.isActive(startedAt: nil, now: start))
        XCTAssertEqual(FreeTrial.daysLeft(startedAt: nil, now: start), 0)
    }

    /// 30 日間は無制限、31 日目からは 1 日の無料枠に戻る。
    func testThirtyDayWindow() {
        XCTAssertTrue(FreeTrial.isActive(startedAt: start, now: start, days: 30))
        XCTAssertTrue(FreeTrial.isActive(startedAt: start, now: day(29.9), days: 30))
        XCTAssertFalse(FreeTrial.isActive(startedAt: start, now: day(30), days: 30))
        XCTAssertFalse(FreeTrial.isActive(startedAt: start, now: day(45), days: 30))
    }

    /// 残り日数は切り上げ (最終日も「あと1日」と出す)。
    func testDaysLeftRoundsUp() {
        XCTAssertEqual(FreeTrial.daysLeft(startedAt: start, now: start, days: 30), 30)
        XCTAssertEqual(FreeTrial.daysLeft(startedAt: start, now: day(29.5), days: 30), 1)
        XCTAssertEqual(FreeTrial.daysLeft(startedAt: start, now: day(31), days: 30), 0)
    }

    /// 体験中は無料枠を使い切っていても文字起こしできる (allowsNow の判定に合わせた組み合わせ)。
    func testTrialOverridesDailyLimit() {
        let inTrial = FreeTrial.isActive(startedAt: start, now: day(10), days: 30)
        XCTAssertTrue(UsageQuota.canTranscribe(isPro: inTrial, used: 3600, limit: 1800))
        let after = FreeTrial.isActive(startedAt: start, now: day(31), days: 30)
        XCTAssertFalse(UsageQuota.canTranscribe(isPro: after, used: 3600, limit: 1800))
    }

    /// 開始日が未来でも、表示する残り日数は 30 日を超えない (保存値の書き直しは起動時に行う)。
    func testDaysLeftNeverExceedsTrialLength() {
        XCTAssertEqual(FreeTrial.daysLeft(startedAt: day(100), now: start, days: 30), 30)
        XCTAssertFalse(FreeTrial.isActive(startedAt: day(100), now: day(130), days: 30))
    }
}
