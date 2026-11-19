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

/// 端末内を最優先し、通信と API キーは端末内が使えないときだけ使う方針を固定する。
final class SummaryRouteTests: XCTestCase {
    func testOnDeviceWinsEvenWithAPIKey() {
        XCTAssertEqual(SummaryRoute.choose(onDeviceAvailable: true, hasAPIKey: true), .onDevice)
        XCTAssertEqual(SummaryRoute.choose(onDeviceAvailable: true, hasAPIKey: false), .onDevice)
    }

    func testFallsBackToRemoteOnlyWithKey() {
        XCTAssertEqual(SummaryRoute.choose(onDeviceAvailable: false, hasAPIKey: true), .remote)
    }

    func testNoRouteWhenNeitherIsAvailable() {
        XCTAssertNil(SummaryRoute.choose(onDeviceAvailable: false, hasAPIKey: false))
    }
}
