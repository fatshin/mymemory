import XCTest

/// 端末内モデルの見直しは、項目を増やさず、事実を作らず、見出しと注記を壊さないときだけ当たることを固定する。
final class SummaryReviewGuardTests: XCTestCase {
    let summary = """
        【概要】
        山田さんとB社の見積もりについて話した。

        【要点】
        - B社の見積もりは予算内
        - あーえっとその

        【決定事項】
        - B社に発注する

        【TODO】
        - 送る
        - 経理に請求書を回す
        """

    func testItemsAreNumberedAcrossSectionsInOrder() {
        let items = SummarySections.reviewItems(in: summary)
        XCTAssertEqual(items.map(\.text), ["B社の見積もりは予算内", "あーえっとその", "B社に発注する", "送る", "経理に請求書を回す"])
        XCTAssertEqual(items.map(\.section), [.keyPoints, .keyPoints, .decisions, .todos, .todos])
        // 要点は決定事項・TODO の一覧には出さない
        XCTAssertEqual(SummarySections.parse(summary).decisions, ["B社に発注する"])
    }

    /// 意味の分からない TODO を補い、断片を消す。他の項目と見出しはそのまま。
    func testFixAndDropAreApplied() {
        let out = SummaryReviewGuard.apply(
            verdicts: [1: .drop, 3: .fix("B社向けの見積書を山田さんに送る")], overview: nil, to: summary)
        let items = SummarySections.reviewItems(in: out).map(\.text)
        XCTAssertEqual(items, ["B社の見積もりは予算内", "B社に発注する", "B社向けの見積書を山田さんに送る", "経理に請求書を回す"])
        XCTAssertTrue(out.contains("【要点】") && out.contains("【決定事項】") && out.contains("【TODO】"))
    }

    /// モデルが項目の半分を超えて消そうとしたら、消す判定は当てない (中身を失わない)。
    func testTooManyDropsAreIgnored() {
        let out = SummaryReviewGuard.apply(verdicts: [0: .drop, 1: .drop, 2: .drop], overview: nil, to: summary)
        XCTAssertEqual(SummarySections.reviewItems(in: out).count, 5)
    }

    /// 1 件だけの節 (決定事項・TODO など) は、消す判定が出ても消さない。2 件の節は 1 件まで消せる。
    func testDropsAreLimitedPerSection() {
        let s = "【要点】\n- うー\n- B社の見積もりは予算内\n\n【決定事項】\n- B社に発注する\n\n【TODO】\n- 経理に請求書を回す"
        let out = SummaryReviewGuard.apply(verdicts: [0: .drop, 2: .drop, 3: .drop], overview: nil, to: s)
        XCTAssertEqual(SummarySections.reviewItems(in: out).map(\.text), ["B社の見積もりは予算内", "B社に発注する", "経理に請求書を回す"])
    }

    /// 変わらない項目は元の行 (番号付きの記号など) のまま残す。
    func testUnchangedItemsKeepTheirOriginalLines() {
        let s = "【決定事項】\n1. B社に発注する\n\n【TODO】\n- 送る\n- 経理に請求書を回す"
        let out = SummaryReviewGuard.apply(verdicts: [1: .fix("B社への見積書を送る")], overview: nil, to: s)
        XCTAssertTrue(out.contains("1. B社に発注する"))
        XCTAssertTrue(out.contains("- B社への見積書を送る"))
    }

    /// 元に無い数字・否定を持ち込む直しや、別の文への書き換えは当てない。
    func testUnsafeFixesAreRejected() {
        XCTAssertFalse(SummaryReviewGuard.acceptFix(original: "見積書を送る", fixed: "見積書を3日までに送る"))
        XCTAssertFalse(SummaryReviewGuard.acceptFix(original: "見積書を送る", fixed: "見積書を送らない"))
        XCTAssertFalse(SummaryReviewGuard.acceptFix(original: "見積書を送る", fixed: "来週の会議の議題を決める"))
        XCTAssertFalse(SummaryReviewGuard.acceptFix(original: "見積書を送る", fixed: "【TODO】見積書を送る"))
        XCTAssertFalse(SummaryReviewGuard.acceptFix(original: "見積書を送る", fixed: "なし"))
        // 漢数字・日時の語で期限を変えない
        XCTAssertFalse(SummaryReviewGuard.acceptFix(original: "来週火曜に資料を提出する", fixed: "今週火曜に資料を提出する"))
        XCTAssertFalse(SummaryReviewGuard.acceptFix(original: "三日に資料を提出する", fixed: "五日に資料を提出する"))
        XCTAssertFalse(SummaryReviewGuard.acceptFix(original: "見積書を送る", fixed: String(repeating: "見積書を送る", count: 30)))
    }

    func testSafeFixesAreAccepted() {
        XCTAssertTrue(SummaryReviewGuard.acceptFix(original: "送る", fixed: "B社向けの見積書を山田さんに送る"))
        XCTAssertTrue(SummaryReviewGuard.acceptFix(original: "会議しつを予約する", fixed: "会議室を予約する"))
        XCTAssertTrue(SummaryReviewGuard.acceptFix(original: "3日までに見積書を送る", fixed: "3日までにB社へ見積書を送る"))
        XCTAssertEqual(SummaryReviewGuard.numbers(in: "１０日と3.5万円"), ["10", "3", "5"])
    }

    /// 概要は誤字の直しだけを当て、書き換え (長さや中身が大きく変わるもの) は当てない。
    func testOverviewOnlyTakesSmallCorrections() {
        let fixed = SummaryReviewGuard.apply(verdicts: [:], overview: "山田さんとB社の見積もりについて話した。", to:
            summary.replacingOccurrences(of: "見積もりについて", with: "見積もりについって"))
        XCTAssertTrue(fixed.contains("山田さんとB社の見積もりについて話した。"))
        let rewritten = SummaryReviewGuard.apply(verdicts: [:], overview: "今日は天気が良く散歩をした。", to: summary)
        XCTAssertEqual(rewritten, summary)
    }

    /// 見直し済みの注記も「で要約)」で終わり、本文や TODO と取り違えない。
    func testReviewedRouteLabelStillParsesAsLabel() {
        let labeled = summary + "\n\n(見直し済み・Google Gemini で要約)"
        XCTAssertTrue(ReflectionSections.isRouteLabel("(見直し済み・Google Gemini で要約)"))
        XCTAssertTrue(ReflectionSections.isRouteLabel("(見直し済み・端末内で要約)"))
        XCTAssertEqual(ReflectionSections.routeLabel(in: labeled), "(見直し済み・Google Gemini で要約)")
        XCTAssertEqual(SummarySections.parse(labeled).todos, ["送る", "経理に請求書を回す"])
    }

    /// 意味の無い録音に保存する要約は、要点・決定事項・TODO を持たない。
    func testNotMeaningfulSummaryHasNoItems() {
        XCTAssertTrue(SummarySections.reviewItems(in: SummaryReviewGuard.notMeaningfulSummary).isEmpty)
        XCTAssertNil(ReflectionSections.keyPoint(in: SummaryReviewGuard.notMeaningfulSummary))
    }
}
