import XCTest

/// TODO に残すかどうかの判定。会話に無い TODO や、約束ではない発言を一覧に出さないための関門。
final class EvidenceMatcherTests: XCTestCase {
    private let source = "私の方でB社に正式に申し込みの連絡します。今週の金曜までにやっておきます。デザインの人にも相談したほうがいいかもね。"

    /// 引用は句読点や言い回しの小さな違いがあっても、元の発言にあれば根拠ありとする。
    func testQuoteFoundDespitePunctuation() {
        XCTAssertTrue(EvidenceMatcher.isSupported(quote: "今週の金曜までにやっておきます", in: source))
        XCTAssertTrue(EvidenceMatcher.isSupported(quote: "B社に正式に申し込みの連絡します、", in: source))
    }

    /// 会話に無い引用 (モデルが作った発言) は根拠なしとする。
    func testInventedQuoteRejected() {
        XCTAssertFalse(EvidenceMatcher.isSupported(quote: "月曜日の午前中までに完成させます", in: source))
        XCTAssertFalse(EvidenceMatcher.isSupported(quote: "はい", in: source), "短すぎる引用は根拠にならない")
    }

    /// 約束の言い方だけを TODO にする。ぼかし・提案・事実の報告は除く。
    func testCommitmentDetection() {
        for q in ["今週の金曜までにやっておきます", "明日の午前中に送ります", "日曜までに注文しておこう", "わかりました、日程調整しておきます", "明日送りますね", "私が払います", "予約を入れます", "明日までにやる予定です", "やりますー"] {
            XCTAssertTrue(EvidenceMatcher.isCommitment(q), q)
        }
        for q in ["デザインの人にも相談したほうがいいかもね", "駅前の居酒屋です。七時からです", "数字で出せたら説得力あるし", "三社とも取りました", "お願いしていいかな", "七時から始まります", "送ってもらえますか", "金曜までに送りました", "金曜までに送りましたよ", "金曜までに送れる？", "分かります", "助かります", "違います", "お世話になっております", "来週は出張の予定です", "送りますよね"] {
            XCTAssertFalse(EvidenceMatcher.isCommitment(q), q)
        }
    }

    /// 約束の判定はモデルが書いた引用ではなく、元の文で行う (引用に「やります」を足して約束に見せる捏造を防ぐ)。
    func testCommitmentIsJudgedOnSourceSentence() {
        let src = "来週の資料の件どうしようか。明日の午前中に送ります。"
        let said = EvidenceMatcher.sourceSentence(for: "来週の資料の件やります", in: src)
        XCTAssertEqual(said, "来週の資料の件どうしようか")
        XCTAssertFalse(EvidenceMatcher.isCommitment(said ?? ""))
        XCTAssertEqual(EvidenceMatcher.sourceSentence(for: "明日の午前中に送ります", in: src), "明日の午前中に送ります")
    }

    /// 引用が 2 文にまたがっても元の文を見つけ、最後の文で約束と判定する。
    func testQuoteSpanningTwoSentences() {
        let src = "はい。じゃあ私の方でB社に正式に申し込みの連絡します。今週の金曜までにやっておきます。お願いします。"
        let said = EvidenceMatcher.sourceSentence(for: "B社に正式に申し込みの連絡します。今週の金曜までにやっておきます", in: src)
        XCTAssertEqual(said, "じゃあ私の方でB社に正式に申し込みの連絡します。今週の金曜までにやっておきます")
        XCTAssertTrue(EvidenceMatcher.isCommitment(said ?? ""))
    }
}
