import XCTest

/// 録音の回復予算。「通話が長くても録音を諦めない」「通常の失敗は5回目で諦める」を固定する。
final class RecoveryBudgetTests: XCTestCase {
    func testGivesUpOnFifthConsecutiveFailureIncludingTheFirst() {
        var budget = RecoveryBudget(maxConsecutiveFailures: 5)
        for _ in 1...4 { XCTAssertEqual(budget.recordFailure(), .retry) }
        XCTAssertEqual(budget.recordFailure(), .giveUp)
    }

    func testSuccessResetsTheBudget() {
        var budget = RecoveryBudget(maxConsecutiveFailures: 3)
        _ = budget.recordFailure()
        _ = budget.recordFailure()
        budget.recordSuccess()
        XCTAssertEqual(budget.recordFailure(), .retry)
        XCTAssertEqual(budget.recordFailure(), .retry)
        XCTAssertEqual(budget.recordFailure(), .giveUp)
    }

    func testFailuresDuringAnInterruptionNeverGiveUp() {
        // 通話などの割り込みは長さに上限がない。何度失敗しても再試行を続ける。
        var budget = RecoveryBudget(maxConsecutiveFailures: 3)
        budget.interruptionBegan()
        for _ in 1...100 { XCTAssertEqual(budget.recordFailure(), .retry) }
    }

    func testBudgetIsFullAgainAfterTheInterruptionEnds() {
        var budget = RecoveryBudget(maxConsecutiveFailures: 3)
        _ = budget.recordFailure()
        _ = budget.recordFailure()
        budget.interruptionBegan()
        budget.interruptionEnded()
        XCTAssertEqual(budget.recordFailure(), .retry)
        XCTAssertEqual(budget.recordFailure(), .retry)
        XCTAssertEqual(budget.recordFailure(), .giveUp)
    }

    func testSuccessDuringAnInterruptionClearsTheInterruptedFlag() {
        // 通話中に録音が再開できた後は、通常の失敗として予算を消費する。
        var budget = RecoveryBudget(maxConsecutiveFailures: 2)
        budget.interruptionBegan()
        budget.recordSuccess()
        XCTAssertEqual(budget.recordFailure(), .retry)
        XCTAssertEqual(budget.recordFailure(), .giveUp)
    }
}
