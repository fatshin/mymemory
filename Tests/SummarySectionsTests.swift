import XCTest

final class SummarySectionsTests: XCTestCase {
    /// 指示文どおりの新形式。一覧に出す前提の基本形。
    func testFixedHeadings() {
        let s = """
        【要点】
        - 価格の方針を話した
        【決定事項】
        - 月額480円で出す
        【TODO】
        - 審査用の画像を撮る (担当: 本人、期限: 金曜)
        """
        let r = SummarySections.parse(s)
        XCTAssertEqual(r.decisions, ["月額480円で出す"])
        XCTAssertEqual(r.todos, ["審査用の画像を撮る (担当: 本人、期限: 金曜)"])
    }

    /// 既存の要約 (旧形式) も一覧に出す。
    func testLegacyNumberedHeadings() {
        let s = """
        (1)要点
        ・打ち合わせの日程
        (2)決定事項
        ・来週火曜に再訪
        (3)TODO
        ・議事録を送る
        """
        let r = SummarySections.parse(s)
        XCTAssertEqual(r.decisions, ["来週火曜に再訪"])
        XCTAssertEqual(r.todos, ["議事録を送る"])
    }

    /// モデルが Markdown の見出しや太字、全角英字で書いても読める。
    func testMarkdownAndFullwidthVariants() {
        let s = """
        ## **決定事項**
        * A案で進める
        ### ＴＯＤＯ：
        1. 見積もりを出す
        2) 日程を押さえる
        """
        let r = SummarySections.parse(s)
        XCTAssertEqual(r.decisions, ["A案で進める"])
        XCTAssertEqual(r.todos, ["見積もりを出す", "日程を押さえる"])
    }

    /// 「なし」の揺れは項目にしない (空の TODO を一覧に出さない)。
    func testNoneVariantsAreDropped() {
        let s = """
        【決定事項】
        - なし。
        - (特になし)
        【TODO】
        - TODOなし
        - 該当なし
        """
        XCTAssertTrue(SummarySections.parse(s).isEmpty)
    }

    /// 見出しと同じ行に項目が続く形。
    func testInlineItemAfterHeading() {
        let s = """
        【TODO】- 資料を送る
        決定事項: 契約は来月
        """
        let r = SummarySections.parse(s)
        XCTAssertEqual(r.todos, ["資料を送る"])
        XCTAssertEqual(r.decisions, ["契約は来月"])
    }

    /// 見出し語を含むだけの項目を見出しと誤認しない (項目が消えない)。
    func testItemContainingHeadingWordIsNotHeading() {
        let s = """
        【要点】
        - TODO管理の方法を議論
        【決定事項】
        * 価格を決定
        1. TODOは週次で見直す
        """
        let r = SummarySections.parse(s)
        XCTAssertEqual(r.decisions, ["価格を決定", "TODOは週次で見直す"])
        XCTAssertEqual(r.todos, [])
    }

    /// 次の見出し (気づき・要点) で節を抜け、別の節の項目を混ぜない。継続行は直前の項目につなげる。
    func testSectionEndsAndContinuationLines() {
        let s = """
        【TODO】
        - 請求書を送る
          先方の経理宛て
        【気づき】
        - 朝は集中できる
        """
        let r = SummarySections.parse(s)
        XCTAssertEqual(r.todos, ["請求書を送る 先方の経理宛て"])
    }

    /// 見出しの無い自由文からは何も取り出さない (誤抽出より取りこぼしを選ぶ)。
    func testNoHeadingsYieldsNothing() {
        XCTAssertTrue(SummarySections.parse("- 雑談のみ\n- 決定はなかった").isEmpty)
    }

    /// 1 日の振り返りの見出し「重要な会話・決定」「TODO・約束」も読める。
    func testReflectionHeadings() {
        let s = """
        (2)重要な会話・決定
        - 引っ越しは3月
        (3)TODO・約束
        - 母に電話する
        """
        let r = SummarySections.parse(s)
        XCTAssertEqual(r.decisions, ["引っ越しは3月"])
        XCTAssertEqual(r.todos, ["母に電話する"])
    }

    /// 括弧付きの強調や番号を含む項目を、見出しや番号と誤認しない (独立レビューの指摘)。
    func testBracketEmphasisAndDecimalsStayItems() {
        let s = """
        【TODO】
        【重要】請求書を送る
        #3 の件を確認
        ---
        """
        XCTAssertEqual(SummarySections.parse(s).todos, ["【重要】請求書を送る"])
        let d = SummarySections.parse("【決定事項】\n- 10.5万円で契約\n10.5万円は税込").decisions
        XCTAssertEqual(d, ["10.5万円で契約"])
    }

    /// 節の末尾の締めの文 (字下げなし) は直前の TODO に混ぜない。CRLF でも同じ結果になる。
    func testTrailingProseIsNotMergedAndCRLF() {
        let s = "【TODO】\r\n- 資料を送る\r\n以上です。"
        XCTAssertEqual(SummarySections.parse(s).todos, ["資料を送る"])
    }

    /// 空文字や「決定事項はなし」は何も返さない。
    func testEmptyAndNoneWithParticle() {
        XCTAssertTrue(SummarySections.parse("").isEmpty)
        XCTAssertTrue(SummarySections.parse("【決定事項】\n- 決定事項はなし").isEmpty)
    }

    /// 1日の振り返りの形式。【気づき】の分析が TODO に混ざらない。
    func testDayReflectionHeadings() {
        let s = """
        【1日の流れ】
        - 朝: 田中さんと価格の相談
        【決定事項】
        - 月額480円で出す
        【TODO】
        - 審査用の画像を撮る (本人 / 金曜)
        【気づき】
        - 価格の話が3回出た (9:05, 13:10, 17:40)。次は結論を先に決めるとよい
        """
        let r = SummarySections.parse(s)
        XCTAssertEqual(r.decisions, ["月額480円で出す"])
        XCTAssertEqual(r.todos, ["審査用の画像を撮る (本人 / 金曜)"])
    }

    /// 先頭の【概要】の文章は、決定事項にも TODO にも混ぜない (一覧が意味不明になるため)。
    func testOverviewParagraphIsNotAnItem() {
        let s = """
        【概要】
        予約システムについて話し、B社に決めた。来週から準備を始める。

        【要点】
        - B社は初期費用がかからない
        【決定事項】
        - B社に決めた
        【TODO】
        - 田中: B社に申し込む (金曜)
        """
        let r = SummarySections.parse(s)
        XCTAssertEqual(r.decisions, ["B社に決めた"])
        XCTAssertEqual(r.todos, ["田中: B社に申し込む (金曜)"])
    }
}
