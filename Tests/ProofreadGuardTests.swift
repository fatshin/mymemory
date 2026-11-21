import XCTest

/// 校正結果の採用判定。端末内モデルが要約・省略・書き換えをしたら元の文字起こしを残すための関門。
final class ProofreadGuardTests: XCTestCase {
    private let original = "えーと来週の会議わ十時からで資料は田中さんが用意してくれることになりました"

    /// 誤変換の修正と句読点の追加だけなら採用する。
    func testAcceptsTypoFixAndPunctuation() {
        XCTAssertTrue(ProofreadGuard.accept(
            original: original, corrected: "えーと、来週の会議は十時からで、資料は田中さんが用意してくれることになりました。"))
    }

    /// 要約して短くしたら採用しない (話した内容が消えるため)。
    func testRejectsSummary() {
        XCTAssertFalse(ProofreadGuard.accept(original: original, corrected: "会議は十時から。資料は田中さん。"))
    }

    /// 長さが近くても、別の文章に書き換えたら採用しない。
    func testRejectsRewrite() {
        XCTAssertFalse(ProofreadGuard.accept(
            original: original, corrected: "次週のミーティングは午前中に開催し、配布物の準備を田中氏が担当する予定です"))
    }

    /// 空の出力や、モデルの前置き付きで大きく伸びた出力は採用しない。
    func testRejectsEmptyAndPadded() {
        XCTAssertFalse(ProofreadGuard.accept(original: original, corrected: ""))
        XCTAssertFalse(ProofreadGuard.accept(
            original: original, corrected: "以下が校正した文章です。誤変換を直し句読点を補いました。" + original + "以上です。ご確認ください。"))
    }

    /// 本文にある誤変換だけを直し、本文に無い語の直しやモデルの書式が混ざった直しは捨てる。
    func testApplyKeepsOnlySafeFixes() {
        let text = "新しい予約シス天の件で、佐藤さんに日程超生をお願いした。契約は二年縛り。"
        let fixes: [ProofreadGuard.Fix] = [
            .init(wrong: "予約シス天", right: "予約システム"),
            .init(wrong: "日程超生", right: "日程調整」}]}```json"),
            .init(wrong: "二年縛り", right: "2年間の縛り"),
            .init(wrong: "見つもり", right: "見積もり"),
        ]
        XCTAssertEqual(ProofreadGuard.apply(fixes, to: text), "新しい予約システムの件で、佐藤さんに日程超生をお願いした。契約は二年縛り。")
    }

    /// 1 文字の語や、長さが大きく変わる直しは当てない (別の語への置き換えを防ぐ)。
    func testRejectsShortOrLongReplacements() {
        XCTAssertFalse(ProofreadGuard.isSafe(wrong: "わ", right: "は"))
        XCTAssertFalse(ProofreadGuard.isSafe(wrong: "会議", right: "来週の定例の打ち合わせ"))
        XCTAssertTrue(ProofreadGuard.isSafe(wrong: "説明かい", right: "説明会"))
        XCTAssertFalse(ProofreadGuard.isSafe(wrong: "二年か", right: "二年ですね"), "口調を変える直しは当てない")
    }
}
