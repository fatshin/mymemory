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
        for q in ["今週の金曜までにやっておきます", "明日の午前中に送ります", "日曜までに注文しておこう", "わかりました、日程調整しておきます"] {
            XCTAssertTrue(EvidenceMatcher.isCommitment(q), q)
        }
        for q in ["デザインの人にも相談したほうがいいかもね", "駅前の居酒屋です。七時からです", "数字で出せたら説得力あるし", "三社とも取りました", "お願いしていいかな"] {
            XCTAssertFalse(EvidenceMatcher.isCommitment(q), q)
        }
    }
}
