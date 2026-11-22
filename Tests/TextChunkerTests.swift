import XCTest

/// 端末内モデルの文脈上限を超えないことと、分割で文章が欠けないことを固定する。
/// ここが崩れると、上限超過エラーか要約の欠落が実機でだけ起きる。
final class TextChunkerTests: XCTestCase {
    func testEmptyAndWhitespaceOnlyProduceNoChunks() {
        XCTAssertEqual(TextChunker.split("", maxChars: 10), [])
        XCTAssertEqual(TextChunker.split(" \n\n  \n", maxChars: 10), [])
    }

    func testTextAtExactLimitStaysOneChunk() {
        let text = String(repeating: "あ", count: 10)
        XCTAssertEqual(TextChunker.split(text, maxChars: 10), [text])
    }

    func testLongLineWithoutNewlineIsCutByCharacterCount() {
        let text = String(repeating: "い", count: 25)
        let chunks = TextChunker.split(text, maxChars: 10)
        XCTAssertEqual(chunks.map(\.count), [10, 10, 5])
        XCTAssertEqual(chunks.joined(), text)
    }

    func testPrefersNewlineBoundaries() {
        let text = "あいうえお\nかきくけこ\nさしすせそ"
        // 2 行 (5+1+5=11 文字) は 11 文字に収まり、3 行目で区切る
        XCTAssertEqual(TextChunker.split(text, maxChars: 11), ["あいうえお\nかきくけこ", "さしすせそ"])
    }

    func testNoChunkExceedsLimitAndNoTextIsLost() {
        let lines = (0..<200).map { i in String(repeating: "語", count: (i * 7) % 37 + 1) }
        let text = lines.joined(separator: "\n")
        let chunks = TextChunker.split(text, maxChars: 50)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 50 })
        let kept = chunks.joined().filter { $0 != "\n" }
        XCTAssertEqual(kept, text.filter { $0 != "\n" })
    }
}

/// 利用者が選んだ経路を優先し、使えないときだけもう一方へ移る方針を固定する。
final class SummaryRouteTests: XCTestCase {
    func testPreferredOnDeviceWinsEvenWithAPIKeyAndPermission() {
        XCTAssertEqual(SummaryRoute.choose(preferred: .onDevice, onDeviceAvailable: true, hasAPIKey: true, remoteAllowed: true), .onDevice)
        XCTAssertEqual(SummaryRoute.choose(preferred: .onDevice, onDeviceAvailable: true, hasAPIKey: false, remoteAllowed: false), .onDevice)
    }

    /// 外部 API を選んだら、端末内モデルが使える端末でも外部 API で要約する (以前は端末内が常に勝ち、送信されなかった)。
    func testPreferredRemoteIsUsedEvenWhenOnDeviceIsAvailable() {
        XCTAssertEqual(SummaryRoute.choose(preferred: .remote, onDeviceAvailable: true, hasAPIKey: true, remoteAllowed: true), .remote)
    }

    /// 外部 API を選んでもキーか許可が無ければ、送らずに端末内へ戻る。
    func testPreferredRemoteFallsBackToOnDeviceWithoutKeyOrPermission() {
        XCTAssertEqual(SummaryRoute.choose(preferred: .remote, onDeviceAvailable: true, hasAPIKey: true, remoteAllowed: false), .onDevice)
        XCTAssertEqual(SummaryRoute.choose(preferred: .remote, onDeviceAvailable: true, hasAPIKey: false, remoteAllowed: true), .onDevice)
    }

    func testFallsBackToRemoteOnlyWithKeyAndPermission() {
        XCTAssertEqual(SummaryRoute.choose(preferred: .onDevice, onDeviceAvailable: false, hasAPIKey: true, remoteAllowed: true), .remote)
    }

    /// 審査ガイドライン 5.1.2(i): キーがあっても、利用者が許可していなければ外部へ送らない。
    func testNeverSendsWithoutExplicitPermission() {
        for p in SummaryRoute.allCases {
            XCTAssertNil(SummaryRoute.choose(preferred: p, onDeviceAvailable: false, hasAPIKey: true, remoteAllowed: false))
        }
        XCTAssertEqual(SummaryRoute.usableRoutes(onDeviceAvailable: true, hasAPIKey: true, remoteAllowed: false), [.onDevice])
    }

    func testNoRouteWhenNeitherIsAvailable() {
        for p in SummaryRoute.allCases {
            XCTAssertNil(SummaryRoute.choose(preferred: p, onDeviceAvailable: false, hasAPIKey: false, remoteAllowed: true))
            XCTAssertNil(SummaryRoute.choose(preferred: p, onDeviceAvailable: false, hasAPIKey: false, remoteAllowed: false))
        }
    }

    func testUsableRoutesListsBothWhenReady() {
        XCTAssertEqual(SummaryRoute.usableRoutes(onDeviceAvailable: true, hasAPIKey: true, remoteAllowed: true), [.onDevice, .remote])
    }
}
