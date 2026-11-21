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
