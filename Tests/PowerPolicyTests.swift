import XCTest

/// 文字起こしの実行条件。境界値は「ここで判断が変わる」ことを固定するために置く。
final class PowerPolicyTests: XCTestCase {
    private func run(_ charge: PowerPolicy.Charge, level: Float = 0.8,
                     lowPower: Bool = false, simulator: Bool = false) -> Bool {
        PowerPolicy.shouldTranscribe(charge: charge, level: level, lowPowerMode: lowPower, isSimulator: simulator)
    }

    func testChargingAlwaysRuns() {
        XCTAssertTrue(run(.charging, level: 0.05))
        XCTAssertTrue(run(.charging, level: 0.05, lowPower: true))
    }

    func testUnpluggedRunsOnlyAtOrAboveThresholdAndNotLowPower() {
        XCTAssertFalse(run(.unplugged, level: 0.49))
        XCTAssertTrue(run(.unplugged, level: 0.50))
        XCTAssertFalse(run(.unplugged, level: 0.90, lowPower: true))
    }

    func testUnpluggedWithUnknownLevelDoesNotRun() {
        // batteryLevel は取得できないと -1 を返す。残量不明は安全側 (実行しない)。
        XCTAssertFalse(run(.unplugged, level: -1))
    }

    func testUnknownStateRunsOnlyOnSimulator() {
        XCTAssertFalse(run(.unknown, simulator: false))
        XCTAssertTrue(run(.unknown, simulator: true))
    }
}
