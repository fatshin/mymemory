import Foundation

/// 外部 API の送信先。要求の組み立てと応答の読み取りは純粋関数にして、通信なしで単体テストする。
/// 送るのは文字起こしテキストだけ (音声は送らない)。
enum RemoteProvider: String, CaseIterable, Identifiable, Sendable {
    case anthropic, openAI, gemini, ollamaCloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .gemini: "Google Gemini"
        case .ollamaCloud: "Ollama Cloud"
        }
    }

    /// 審査ガイドライン 5.1.2(i) に沿って、送信先の事業者名を画面に示すための表記。
    var recipient: String {
        switch self {
        case .anthropic: "Anthropic の API"
        case .openAI: "OpenAI の API"
        case .gemini: "Google の Gemini API"
        case .ollamaCloud: "Ollama Cloud"
        }
    }

    /// Keychain の項目名。Anthropic は従来の名前のまま (保存済みのキーを引き継ぐ)。
    var keyName: String {
        switch self {
        case .anthropic: "anthropic_api_key"
        case .openAI: "openai_api_key"
        case .gemini: "gemini_api_key"
        case .ollamaCloud: "ollama_api_key"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .openAI: "sk-…"
        case .gemini: "AIza…"
        case .ollamaCloud: "Ollama APIキー"
        }
    }

    /// 既定のモデル。各社とも入れ替わりが速いため、設定画面で上書きできる。
    var defaultModel: String {
        switch self {
        case .anthropic: "claude-haiku-5-5"
        case .openAI: "gpt-6.1-terra"
        case .gemini: "gemini-3.8-flash"
        case .ollamaCloud: "gpt-oss:120b"
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 推論モデルは思考分も上限に数えるため、要約本文が空にならないよう余裕を持たせる。
    private static let maxTokens = 4000

    /// モデル名は URL の一部にもなるため、使える文字を絞る (パスの書き換えを防ぐ)。
    static func isValidModel(_ model: String) -> Bool {
        guard !model.isEmpty, model.count <= 100 else { return false }
        return model.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0)) }
    }

    func request(key: String, model: String, prompt: String) throws -> URLRequest {
        guard Self.isValidModel(model) else { throw Failure(message: "モデル名が正しくありません: \(model)") }
        let url: URL
        var headers: [String: String] = ["content-type": "application/json"]
        let body: [String: Any]
        let messages: [[String: String]] = [["role": "user", "content": prompt]]
        switch self {
        case .anthropic:
            url = URL(string: "https://api.anthropic.com/v1/messages")!
            headers["x-api-key"] = key
            headers["anthropic-version"] = "2023-06-01"
            body = ["model": model, "max_tokens": 1500, "messages": messages]
        case .openAI:
            url = URL(string: "https://api.openai.com/v1/chat/completions")!
            headers["authorization"] = "Bearer \(key)"
            // max_tokens は非推奨で、推論モデルでは使えない (公式リファレンス)
            body = ["model": model, "max_completion_tokens": Self.maxTokens, "messages": messages]
        case .gemini:
            url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
            headers["x-goog-api-key"] = key
            body = ["contents": [["parts": [["text": prompt]]]],
                    "generationConfig": ["maxOutputTokens": Self.maxTokens]]
        case .ollamaCloud:
            url = URL(string: "https://ollama.com/api/chat")!
            headers["authorization"] = "Bearer \(key)"
            body = ["model": model, "messages": messages, "stream": false]
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: モデル一覧 (設定画面で実在するモデルから選ぶ。送るのは API キーだけで、文字起こしは送らない)

    /// 一覧の 1 ページ。`next` があれば続きがある (Anthropic は after_id、Gemini は pageToken に渡す)。
    struct ModelPage: Equatable {
        let ids: [String]
        let next: String?
    }

    func listRequest(key: String, page: String? = nil) -> URLRequest {
        var c: URLComponents
        var headers: [String: String] = [:]
        switch self {
        case .anthropic:
            // 既定は 20 件 (最大 1000 件。公式リファレンス)
            c = URLComponents(string: "https://api.anthropic.com/v1/models")!
            c.queryItems = [URLQueryItem(name: "limit", value: "1000")] + (page.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
            headers["x-api-key"] = key
            headers["anthropic-version"] = "2023-06-01"
        case .openAI:
            c = URLComponents(string: "https://api.openai.com/v1/models")!
            headers["authorization"] = "Bearer \(key)"
        case .gemini:
            c = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            c.queryItems = [URLQueryItem(name: "pageSize", value: "1000")] + (page.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            headers["x-goog-api-key"] = key
        case .ollamaCloud:
            c = URLComponents(string: "https://ollama.com/api/tags")!
            headers["authorization"] = "Bearer \(key)"
        }
        var req = URLRequest(url: c.url!)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    /// 一覧の応答を読む。要約の要求に使えない ID (URL に載せられない文字を含むものなど) は出さない。
    func parseModels(_ data: Data) throws -> ModelPage {
        let ids: [String]
        var next: String?
        switch self {
        case .anthropic:
            struct R: Decodable { struct M: Decodable { let id: String }; let data: [M]; let has_more: Bool?; let last_id: String? }
            let r = try JSONDecoder().decode(R.self, from: data)
            ids = r.data.map(\.id)  // 新しい順で返る
            next = (r.has_more ?? false) ? r.last_id : nil
        case .openAI:
            struct R: Decodable { struct M: Decodable { let id: String; let created: Int? }; let data: [M] }
            let r = try JSONDecoder().decode(R.self, from: data)
            ids = r.data.filter { Self.isOpenAIChatModel($0.id) }
                .sorted { ($0.created ?? 0) > ($1.created ?? 0) }.map(\.id)
        case .gemini:
            struct R: Decodable {
                struct M: Decodable { let name: String; let supportedGenerationMethods: [String]? }
                let models: [M]?; let nextPageToken: String?
            }
            let r = try JSONDecoder().decode(R.self, from: data)
            // name は "models/gemini-…"。要約の URL に二重に付かないよう先頭を外す
            ids = (r.models ?? []).filter { $0.supportedGenerationMethods?.contains("generateContent") ?? false }
                .map { $0.name.hasPrefix("models/") ? String($0.name.dropFirst(7)) : $0.name }
            next = (r.nextPageToken?.isEmpty ?? true) ? nil : r.nextPageToken
        case .ollamaCloud:
            struct R: Decodable { struct M: Decodable { let name: String?; let model: String? }; let models: [M]? }
            ids = (try JSONDecoder().decode(R.self, from: data).models ?? []).compactMap { $0.model ?? $0.name }
        }
        return ModelPage(ids: ids.filter(Self.isValidModel), next: next)
    }

    /// OpenAI の一覧には埋め込み・音声・画像用も含まれるため、文章の生成に使うものだけ残す。
    /// 一覧の応答には用途が載っていないので、ID の名前からの推定 (外れたら手入力で指定できる)。
    static func isOpenAIChatModel(_ id: String) -> Bool {
        let s = id.lowercased()
        let family = s.hasPrefix("gpt-") || s.hasPrefix("chatgpt-") || (s.first == "o" && s.dropFirst().first?.isNumber == true)
        let excluded = ["embedding", "tts", "whisper", "dall-e", "image", "audio", "realtime", "transcribe", "moderation", "search", "instruct"]
        return family && !excluded.contains { s.contains($0) }
    }

    func parse(_ data: Data) throws -> String {
        let text: String
        switch self {
        case .anthropic:
            struct R: Decodable { struct C: Decodable { let text: String? }; let content: [C] }
            text = try JSONDecoder().decode(R.self, from: data).content.compactMap(\.text).joined()
        case .openAI:
            struct R: Decodable { struct C: Decodable { struct M: Decodable { let content: String? }; let message: M }; let choices: [C] }
            text = try JSONDecoder().decode(R.self, from: data).choices.first?.message.content ?? ""
        case .gemini:
            struct R: Decodable {
                struct C: Decodable { struct Ct: Decodable { struct P: Decodable { let text: String? }; let parts: [P]? }; let content: Ct? }
                let candidates: [C]?
            }
            let r = try JSONDecoder().decode(R.self, from: data)
            text = (r.candidates?.first?.content?.parts ?? []).compactMap(\.text).joined()
        case .ollamaCloud:
            struct R: Decodable { struct M: Decodable { let content: String? }; let message: M? }
            text = try JSONDecoder().decode(R.self, from: data).message?.content ?? ""
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "\(displayName) の応答に要約が含まれていません (モデル名や上限を確認してください)")
        }
        return text
    }
}
