import XCTest

final class ContinuedProgressTests: XCTestCase {
    func testNoWindowCountsOnlyFinishedFiles() {
        XCTAssertEqual(ContinuedProgress.completedUnits(finishedSeconds: 600, windowIndex: 0, fileSeconds: 600), 600)
    }

    func testWindowAddsThirtySecondsEach() {
        XCTAssertEqual(ContinuedProgress.completedUnits(finishedSeconds: 600, windowIndex: 4, fileSeconds: 600), 720)
    }

    func testCurrentFileProgressNeverExceedsItsLength() {
        // 最終ウィンドウが 30 秒に満たない録音でも、合計が録音の長さを超えない
        XCTAssertEqual(ContinuedProgress.completedUnits(finishedSeconds: 0, windowIndex: 3, fileSeconds: 70), 70)
    }

    func testUnknownFileLengthIgnoresWindows() {
        XCTAssertEqual(ContinuedProgress.completedUnits(finishedSeconds: 100, windowIndex: 5, fileSeconds: 0), 100)
    }

    func testNegativeInputsAreClamped() {
        XCTAssertEqual(ContinuedProgress.completedUnits(finishedSeconds: -5, windowIndex: 0, fileSeconds: 10), 0)
    }
}
