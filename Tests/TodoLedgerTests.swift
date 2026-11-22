import XCTest

/// やること台帳。要約の本文を書き換えずに、完了・削除・編集を録音や作り直しをまたいで保つ。
final class TodoLedgerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    /// 空白・句読点・全角の違いは同じ項目とみなす (要約の作り直しで細部が揺れても状態を保つ)。
    /// 数字の区切りは残す (「3.5時間」と「35時間」、「10:30」と「1030」を同じにしない)。
    func testKeyNormalizes() {
        XCTAssertEqual(TodoLedger.key("田中さん: Ｂ社に 見積書を送る。"), TodoLedger.key("田中さん：B社に見積書を送る"))
        XCTAssertNotEqual(TodoLedger.key("見積書を送る"), TodoLedger.key("請求書を送る"))
        XCTAssertNotEqual(TodoLedger.key("3.5時間で終える"), TodoLedger.key("35時間で終える"))
        XCTAssertNotEqual(TodoLedger.key("10:30に電話する"), TodoLedger.key("1030に電話する"))
    }

    /// 完了は履歴に残り、同じ文言の別の録音の項目もまとめて完了になる。
    func testCompleteAppliesAcrossRecordingsAndKeepsHistory() {
        var l = TodoLedger()
        l.complete("見積書を送る", startedAt: at(5), now: at(10))
        XCTAssertEqual(l.resolve("見積書を送る", startedAt: at(0)), .completed("見積書を送る", at: at(10)))
        XCTAssertEqual(l.resolve("見積書を送る。", startedAt: at(5)), .completed("見積書を送る", at: at(10)))
        XCTAssertEqual(l.completed.map(\.original), ["見積書を送る"])
    }

    /// 操作より後に始まった録音の同じ約束は、新しい項目として出す。
    func testLaterRecordingIsNotAffected() {
        var l = TodoLedger()
        l.complete("定例の会議室を予約する", startedAt: at(0), now: at(10))
        XCTAssertEqual(l.resolve("定例の会議室を予約する", startedAt: at(60)), .open("定例の会議室を予約する"))
    }

    /// 後日の項目を編集しても、前に完了した状態を持ち込まない。前の録音の完了も変えない。
    func testOperatingOnLaterItemCreatesSeparateRecord() {
        var l = TodoLedger()
        l.complete("予約する", startedAt: at(0), now: at(10))
        l.edit("予約する", startedAt: at(60), to: "来週の会議室を予約する", now: at(70))
        XCTAssertEqual(l.resolve("予約する", startedAt: at(60)), .open("来週の会議室を予約する"))
        XCTAssertEqual(l.resolve("予約する", startedAt: at(0)), .completed("予約する", at: at(10)))
        // 前の記録の未完了戻しや編集で、範囲が後の録音へ広がらない
        l.reopen("予約する", startedAt: at(0), now: at(200))
        XCTAssertEqual(l.resolve("予約する", startedAt: at(60)), .open("来週の会議室を予約する"))
        // 編集 (70分) より後に始まった録音は新しい項目
        XCTAssertEqual(l.resolve("予約する", startedAt: at(150)), .open("予約する"))
    }

    /// 時計のずれで未来の日時になった録音でも、操作が効く。
    func testFutureDatedRecording() {
        var l = TodoLedger()
        l.complete("送る", startedAt: at(1000), now: at(10))
        XCTAssertEqual(l.resolve("送る", startedAt: at(1000)), .completed("送る", at: at(10)))
    }

    func testEditDeleteReopenAndUndo() {
        var l = TodoLedger()
        l.edit("送る", startedAt: at(0), to: "B社に見積書を送る", now: at(1))
        XCTAssertEqual(l.resolve("送る", startedAt: at(0)), .open("B社に見積書を送る"))
        let before = l.snapshot(for: "送る")
        l.delete("送る", startedAt: at(0), now: at(2))
        XCTAssertEqual(l.resolve("送る", startedAt: at(0)), .deleted)
        l.restore("送る", to: before)
        XCTAssertEqual(l.resolve("送る", startedAt: at(0)), .open("B社に見積書を送る"))
        l.complete("送る", startedAt: at(0), now: at(3)); l.reopen("送る", startedAt: at(0), now: at(4))
        XCTAssertEqual(l.resolve("送る", startedAt: at(0)), .open("B社に見積書を送る"))
        // 空への編集は削除、元の文言への編集は編集の取り消し
        l.edit("送る", startedAt: at(0), to: "送る", now: at(5))
        XCTAssertEqual(l.resolve("送る", startedAt: at(0)), .open("送る"))
        l.edit("送る", startedAt: at(0), to: "  ", now: at(6))
        XCTAssertEqual(l.resolve("送る", startedAt: at(0)), .deleted)
    }

    /// 台帳に無い項目は元に戻すと記録ごと消える。
    func testUndoOfFirstActionRemovesEntry() {
        var l = TodoLedger()
        let before = l.snapshot(for: "A")
        l.complete("A", startedAt: at(0), now: at(1))
        l.restore("A", to: before)
        XCTAssertEqual(l, TodoLedger())
    }

    /// 完了・削除は 180 日、編集だけの記録は 400 日で消す。
    func testPurge() {
        var l = TodoLedger()
        let day = 60.0 * 24
        l.complete("古い", startedAt: at(0), now: at(0))
        l.edit("編集だけ", startedAt: at(0), to: "直した", now: at(0))
        l.complete("新しい", startedAt: at(0), now: at(day * 200))
        l.purge(now: at(day * 200))
        XCTAssertNil(l.snapshot(for: "古い"))
        XCTAssertNotNil(l.snapshot(for: "編集だけ"))
        XCTAssertNotNil(l.snapshot(for: "新しい"))
        l.purge(now: at(day * 500))
        XCTAssertNil(l.snapshot(for: "編集だけ"))
    }

    func testJSONRoundTrip() throws {
        var l = TodoLedger()
        l.complete("A", startedAt: at(0), now: at(1)); l.edit("B", startedAt: at(0), to: "B2", now: at(2))
        let back = try JSONDecoder().decode(TodoLedger.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(back, l)
    }

    /// 要約への重ね合わせ: 完了は [x]、削除は消す、編集後の文言、他の節は変えない。
    func testOverlay() {
        var l = TodoLedger()
        l.complete("A を送る", startedAt: at(0), now: at(1))
        l.delete("B を予約する", startedAt: at(0), now: at(1))
        l.edit("C を買う", startedAt: at(0), to: "C を2つ買う", now: at(1))
        let out = l.overlay(summary: "【決定事項】\n- 決めた\n【TODO】\n- A を送る\n- B を予約する\n- C を買う", startedAt: at(0))
        XCTAssertEqual(SummarySections.parse(out).todos, ["[x] A を送る", "C を2つ買う"])
        XCTAssertEqual(SummarySections.parse(out).decisions, ["決めた"])
    }
}

final class TodoLedgerPurgeScopeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ days: Double) -> Date { t0.addingTimeInterval(days * 86_400) }

    /// 古い記録だけが期限切れのとき、その記録の録音が後の記録の状態を引き継がない。
    func testPartialPurgeKeepsScopeBoundary() {
        var l = TodoLedger()
        l.complete("送る", startedAt: at(0), now: at(1))      // 古い録音で完了
        l.delete("送る", startedAt: at(100), now: at(150))   // 後の録音で削除
        l.purge(now: at(200))
        XCTAssertEqual(l.resolve("送る", startedAt: at(0)), .open("送る"))
        XCTAssertEqual(l.resolve("送る", startedAt: at(100)), .deleted)
    }
}
