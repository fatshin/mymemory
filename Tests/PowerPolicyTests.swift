import XCTest

/// 文字起こしの実行条件。境界値は「ここで判断が変わる」ことを固定するために置く。
final class PowerPolicyTests: XCTestCase {
    private func run(_ charge: PowerPolicy.Charge, level: Float = 0.8,
                     lowPower: Bool = false, simulator: Bool = false, userInitiated: Bool = false) -> Bool {
        PowerPolicy.shouldTranscribe(charge: charge, level: level, lowPowerMode: lowPower,
                                     isSimulator: simulator, userInitiated: userInitiated)
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

    func testUserInitiatedIgnoresThresholdAndLowPowerButKeepsFloor() {
        // 利用者の明示操作は、50% の閾値と低電力モードを越えて実行する
        XCTAssertTrue(run(.unplugged, level: 0.20, userInitiated: true))
        XCTAssertTrue(run(.unplugged, level: 0.30, lowPower: true, userInitiated: true))
        // ただし 20% 未満は実行しない (電池切れで Watch の転送を受けられなくなるのを避ける)
        XCTAssertFalse(run(.unplugged, level: 0.19, userInitiated: true))
        XCTAssertFalse(run(.unplugged, level: -1, userInitiated: true))
    }

    func testUserInitiatedDoesNotChangeChargingOrUnknownRules() {
        XCTAssertTrue(run(.charging, level: 0.05, userInitiated: true))
        XCTAssertFalse(run(.unknown, simulator: false, userInitiated: true))
        XCTAssertTrue(run(.unknown, simulator: true, userInitiated: true))
    }

    func testUserRunScopeCoversOnlyRecordingsQueuedAtTapTime() {
        let a = UUID(), b = UUID(), late = UUID()
        var scope = UserRunScope()
        XCTAssertFalse(scope.isActive)
        scope.begin([a, b])
        XCTAssertTrue(scope.covers(a))
        XCTAssertFalse(scope.covers(late), "押した後に届いた録音は緩和しない")
        XCTAssertFalse(scope.covers(nil))
        scope.finish(a)
        XCTAssertFalse(scope.covers(a))
        XCTAssertTrue(scope.isActive)
        scope.clear()
        XCTAssertFalse(scope.isActive)
        XCTAssertFalse(scope.covers(b))
    }

    /// 校正は必須ではないので、電池で動いているときは利用者の操作があっても行わない。
    func testProofreadOnlyOnExternalPower() {
        XCTAssertTrue(PowerPolicy.shouldProofread(charge: .charging, isSimulator: false))
        XCTAssertFalse(PowerPolicy.shouldProofread(charge: .unplugged, isSimulator: false))
        XCTAssertFalse(PowerPolicy.shouldProofread(charge: .unknown, isSimulator: false))
        XCTAssertTrue(PowerPolicy.shouldProofread(charge: .unknown, isSimulator: true))
    }
}
