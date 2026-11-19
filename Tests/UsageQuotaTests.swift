import XCTest

/// 課金の判定。間違えると「払っている人の文字起こしが止まる」か「無料で無制限に使える」になる。
final class UsageQuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFreeUserStopsAtLimitButFinishesOneRecording() {
        XCTAssertTrue(UsageQuota.canTranscribe(isPro: false, used: 0, limit: 1800))
        XCTAssertTrue(UsageQuota.canTranscribe(isPro: false, used: 1799, limit: 1800))
        XCTAssertFalse(UsageQuota.canTranscribe(isPro: false, used: 1800, limit: 1800))
    }

    func testProIsNeverLimited() {
        XCTAssertTrue(UsageQuota.canTranscribe(isPro: true, used: 1_000_000, limit: 1800))
    }

    func testUsageResetsOnNewDay() {
        let q = UsageQuota(day: "2026-11-20", usedSeconds: 1800)
        XCTAssertEqual(q.used(today: "2026-11-20"), 1800)
        XCTAssertEqual(q.used(today: "2026-11-21"), 0)
        XCTAssertEqual(q.adding(600, today: "2026-11-21"), UsageQuota(day: "2026-11-21", usedSeconds: 600))
        XCTAssertEqual(q.adding(600, today: "2026-11-20").usedSeconds, 2400)
    }

    func testDayKeyUsesGivenCalendarTimeZone() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // 2027-01-15 08:00 UTC は東京で 17:00
        XCTAssertEqual(UsageQuota.dayKey(now, calendar: cal), "2027-01-15")
    }

    /// 期限の直後でも猶予内は有料のまま (更新の確認が遅れても止めない)。
    func testProWithinRenewalGrace() {
        let expired = now.addingTimeInterval(-3600)
        XCTAssertTrue(Entitlement.isPro(expiresAt: expired, now: now, grace: 3 * 24 * 3600))
        XCTAssertFalse(Entitlement.isPro(expiresAt: now.addingTimeInterval(-4 * 24 * 3600), now: now, grace: 3 * 24 * 3600))
        XCTAssertFalse(Entitlement.isPro(expiresAt: nil, now: now))
    }

    /// 取引一覧が一時的に空でも、切れていない期限は消さない。
    func testEmptyRefreshKeepsUnexpiredCache() {
        let future = now.addingTimeInterval(86_400)
        XCTAssertEqual(Entitlement.merged(cached: future, fromEntitlements: nil, now: now, grace: 3 * 86_400), future)
        // 期限直後で更新が未同期でも、猶予の間は消さない
        let justExpired = now.addingTimeInterval(-1)
        XCTAssertEqual(Entitlement.merged(cached: justExpired, fromEntitlements: nil, now: now, grace: 3 * 86_400), justExpired)
        XCTAssertNil(Entitlement.merged(cached: now.addingTimeInterval(-4 * 86_400), fromEntitlements: nil, now: now, grace: 3 * 86_400))
        let renewed = now.addingTimeInterval(30 * 86_400)
        XCTAssertEqual(Entitlement.merged(cached: future, fromEntitlements: renewed, now: now), renewed)
    }
}
