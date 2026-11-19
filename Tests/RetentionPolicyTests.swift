import XCTest

/// 利用者のデータを消す処理。消してはいけないもの (既定・未文字起こし・期限内) を消さないことを固定する。
final class RetentionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func item(daysAgo: Double, transcribed: Bool = true) -> RetentionPolicy.Item {
        .init(id: UUID(), startedAt: now.addingTimeInterval(-daysAgo * 86_400), transcribed: transcribed)
    }

    func testDefaultDeletesNothing() {
        XCTAssertEqual(RetentionPolicy.audioToDelete([item(daysAgo: 1000)], now: now, days: 0), [])
    }

    func testDeletesOnlyOlderThanCutoff() {
        let old = item(daysAgo: 31), recent = item(daysAgo: 29)
        XCTAssertEqual(RetentionPolicy.audioToDelete([old, recent], now: now, days: 30), [old.id])
    }

    func testNeverDeletesUntranscribedAudio() {
        let pending = item(daysAgo: 400, transcribed: false)
        XCTAssertEqual(RetentionPolicy.audioToDelete([pending], now: now, days: 30), [])
    }
}
