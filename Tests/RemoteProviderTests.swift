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

    // MARK: モデル一覧

    /// Anthropic は既定 20 件しか返さないため、上限 1000 件を指定し、続きは after_id で取る。
    func testAnthropicListPagesWithAfterId() throws {
        let r = RemoteProvider.anthropic.listRequest(key: "K", page: "m-last")
        XCTAssertEqual(r.url?.absoluteString, "https://api.anthropic.com/v1/models?limit=1000&after_id=m-last")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-api-key"), "K")
        let page = try RemoteProvider.anthropic.parseModels(Data(#"{"data":[{"id":"a-2"},{"id":"a-1"}],"has_more":true,"last_id":"a-1"}"#.utf8))
        XCTAssertEqual(page, .init(ids: ["a-2", "a-1"], next: "a-1"))
    }

    /// OpenAI の一覧から、要約に使えない埋め込み・音声・画像用を除き、新しい順に並べる。
    func testOpenAIListKeepsOnlyChatModelsNewestFirst() throws {
        let body = #"{"data":[{"id":"text-embedding-3-small","created":5},{"id":"gpt-old","created":1},{"id":"gpt-new","created":9},{"id":"whisper-1","created":7},{"id":"o9-mini","created":3},{"id":"gpt-image-2","created":8}]}"#
        XCTAssertEqual(try RemoteProvider.openAI.parseModels(Data(body.utf8)).ids, ["gpt-new", "o9-mini", "gpt-old"])
    }

    /// Gemini は文章生成 (generateContent) に使えるものだけ残し、"models/" を外す (要約の URL に二重に付けない)。
    func testGeminiListStripsPrefixAndFiltersMethods() throws {
        let body = #"{"models":[{"name":"models/gemini-x","supportedGenerationMethods":["generateContent"]},{"name":"models/embed-y","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"T"}"#
        XCTAssertEqual(try RemoteProvider.gemini.parseModels(Data(body.utf8)), .init(ids: ["gemini-x"], next: "T"))
        XCTAssertFalse(RemoteProvider.gemini.listRequest(key: "SECRET").url!.absoluteString.contains("SECRET"))
    }

    /// URL に載せられない ID は一覧に出さない (選んでも要約の要求で拒否されるため)。
    func testListDropsInvalidIds() throws {
        let body = #"{"models":[{"name":"gpt-oss:120b"},{"name":"../evil"}]}"#
        XCTAssertEqual(try RemoteProvider.ollamaCloud.parseModels(Data(body.utf8)).ids, ["gpt-oss:120b"])
    }
}
