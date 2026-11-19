import XCTest

/// 起動時の再キュー方針。同じ録音で落ち続けるループを断つ境界を固定する。
final class RetryPolicyTests: XCTestCase {
    func testRequeuesBelowTheLimit() {
        XCTAssertEqual(RetryPolicy.onRelaunch(attempts: 0), .requeue)
        XCTAssertEqual(RetryPolicy.onRelaunch(attempts: RetryPolicy.maxAttempts - 1), .requeue)
    }

    func testFailsAtAndAboveTheLimit() {
        XCTAssertEqual(RetryPolicy.onRelaunch(attempts: RetryPolicy.maxAttempts), .fail)
        XCTAssertEqual(RetryPolicy.onRelaunch(attempts: RetryPolicy.maxAttempts + 3), .fail)
    }
}
