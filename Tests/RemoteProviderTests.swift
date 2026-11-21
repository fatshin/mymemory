import XCTest

/// 送信先ごとの要求と応答。公式ドキュメントの形式から外れると、通信前にここで落ちる。
final class RemoteProviderTests: XCTestCase {
    private func json(_ req: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(req.httpBody)) as? [String: Any])
    }

    func testAnthropicRequest() throws {
        let r = try RemoteProvider.anthropic.request(key: "K", model: "m", prompt: "p")
        XCTAssertEqual(r.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-api-key"), "K")
        XCTAssertEqual(r.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testOpenAIUsesBearerAndMaxCompletionTokens() throws {
        let r = try RemoteProvider.openAI.request(key: "K", model: "m", prompt: "p")
        XCTAssertEqual(r.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(r.value(forHTTPHeaderField: "authorization"), "Bearer K")
        let b = try json(r)
        XCTAssertNotNil(b["max_completion_tokens"])
        XCTAssertNil(b["max_tokens"], "max_tokens は推論モデルで拒否される")
    }

    func testGeminiPutsKeyInHeaderNotUrl() throws {
        let r = try RemoteProvider.gemini.request(key: "SECRET", model: "gemini-3.8-flash", prompt: "p")
        XCTAssertEqual(r.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent")
        XCTAssertFalse(r.url!.absoluteString.contains("SECRET"), "キーを URL に載せない (ログに残るため)")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-goog-api-key"), "SECRET")
    }

    func testOllamaCloudDisablesStreaming() throws {
        let r = try RemoteProvider.ollamaCloud.request(key: "K", model: "gpt-oss:120b", prompt: "p")
        XCTAssertEqual(r.url?.absoluteString, "https://ollama.com/api/chat")
        XCTAssertEqual(r.value(forHTTPHeaderField: "authorization"), "Bearer K")
        XCTAssertEqual(try json(r)["stream"] as? Bool, false)
    }

    func testModelNameCannotRewriteUrlPath() {
        for bad in ["", "a/b", "m?x=1", "m#f", "m:generateContent/../x", "日本語", "a b"] {
            XCTAssertThrowsError(try RemoteProvider.gemini.request(key: "K", model: bad, prompt: "p"), bad)
        }
        XCTAssertNoThrow(try RemoteProvider.ollamaCloud.request(key: "K", model: "gpt-oss:120b", prompt: "p"))
    }

    func testParse() throws {
        let a = #"{"content":[{"type":"text","text":"A1"},{"type":"text","text":"A2"}]}"#
        XCTAssertEqual(try RemoteProvider.anthropic.parse(Data(a.utf8)), "A1A2")
        let o = #"{"choices":[{"message":{"role":"assistant","content":"O"}}]}"#
        XCTAssertEqual(try RemoteProvider.openAI.parse(Data(o.utf8)), "O")
        let g = #"{"candidates":[{"content":{"parts":[{"text":"G1"},{"text":"G2"}],"role":"model"}}]}"#
        XCTAssertEqual(try RemoteProvider.gemini.parse(Data(g.utf8)), "G1G2")
        let l = #"{"model":"x","message":{"role":"assistant","content":"L"},"done":true}"#
        XCTAssertEqual(try RemoteProvider.ollamaCloud.parse(Data(l.utf8)), "L")
    }

    func testEmptyOrBlockedResponsesFailLoudly() {
        // Gemini は安全性ブロックや上限切れで candidates / parts が欠ける
        XCTAssertThrowsError(try RemoteProvider.gemini.parse(Data(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#.utf8)))
        XCTAssertThrowsError(try RemoteProvider.gemini.parse(Data(#"{"candidates":[{"finishReason":"MAX_TOKENS","content":{"role":"model"}}]}"#.utf8)))
        XCTAssertThrowsError(try RemoteProvider.openAI.parse(Data(#"{"choices":[{"message":{"content":null}}]}"#.utf8)))
        XCTAssertThrowsError(try RemoteProvider.ollamaCloud.parse(Data(#"{"message":{"content":"  "}}"#.utf8)))
    }

    func testAnthropicKeepsLegacyKeychainName() {
        XCTAssertEqual(RemoteProvider.anthropic.keyName, "anthropic_api_key")
        XCTAssertEqual(Set(RemoteProvider.allCases.map(\.keyName)).count, RemoteProvider.allCases.count)
    }
}
