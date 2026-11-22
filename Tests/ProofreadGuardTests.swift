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
        let text = "佐藤さんに日程超生をお願いした。らいしゅうの会議は契約は二年縛り。"
        let fixes: [ProofreadGuard.Fix] = [
            .init(wrong: "日程超生", right: "日程調整"),
            .init(wrong: "らいしゅう", right: "来週」}]}```json"),
            .init(wrong: "二年縛り", right: "2年間の縛り"),
            .init(wrong: "見つもり", right: "見積もり"),
        ]
        XCTAssertEqual(ProofreadGuard.apply(fixes, to: text), "佐藤さんに日程調整をお願いした。らいしゅうの会議は契約は二年縛り。")
    }

    /// 読みが完全に同じ直し (同じ音の字の取り違え) だけを当てる。読みが 1 字でも違えば意味が変わりうるので当てない。
    func testOnlySameReadingFixesAreSafe() {
        XCTAssertTrue(ProofreadGuard.isSafe(wrong: "説明かい", right: "説明会"))
        XCTAssertTrue(ProofreadGuard.isSafe(wrong: "けいやくしょ", right: "契約書"))
        XCTAssertTrue(ProofreadGuard.isSafe(wrong: "らいしゅう", right: "来週"))
        XCTAssertTrue(ProofreadGuard.isSafe(wrong: "日程超生", right: "日程調整"))
        XCTAssertFalse(ProofreadGuard.isSafe(wrong: "わ", right: "は"), "1 字の語は直さない")
        XCTAssertFalse(ProofreadGuard.isSafe(wrong: "上がる", right: "下がる"))
        XCTAssertFalse(ProofreadGuard.isSafe(wrong: "しない", right: "市内"), "否定を消す直しは当てない")
        XCTAssertFalse(ProofreadGuard.isSafe(wrong: "かのう", right: "不可能"), "読みが違う否定は当てない")
        XCTAssertFalse(ProofreadGuard.isSafe(wrong: "せず", right: "背酢"), "「ず」の否定を消す直しは当てない")
        XCTAssertFalse(ProofreadGuard.isSafe(wrong: "やっておく？", right: "やっておく"), "問いを言い切りにする直しは当てない")
        XCTAssertFalse(ProofreadGuard.isSafe(wrong: "加藤さん", right: "佐藤さん"))
        XCTAssertFalse(ProofreadGuard.isSafe(wrong: "送ります", right: "送りません"))
        XCTAssertFalse(ProofreadGuard.isSafe(wrong: "三時から", right: "二時から"))
        XCTAssertFalse(ProofreadGuard.isSafe(wrong: "二年か", right: "二年ですね"))
        XCTAssertFalse(ProofreadGuard.isSafe(wrong: "予約シス", right: "予約システム"))
        XCTAssertFalse(ProofreadGuard.isSafe(wrong: "二割減らす方向で進める", right: "増やす方向で決めた"))
    }

    /// 本文に何度も現れる語は直さない (正しい語の一部を巻き添えで壊さない)。
    func testSkipsFixWhenWrongAppearsMoreThanOnce() {
        let text = "会議しつの予約と、しつもんの回答"
        XCTAssertEqual(ProofreadGuard.apply([.init(wrong: "しつ", right: "室")], to: text), text)
    }

    /// 短いメモでも、読みが同じかな→漢字の直しは当てる (全体の文字数が大きく減っても捨てない)。
    func testShortMemoKanaToKanji() {
        XCTAssertEqual(ProofreadGuard.apply([.init(wrong: "けいやくしょ", right: "契約書")], to: "けいやくしょ"), "契約書")
    }
}
