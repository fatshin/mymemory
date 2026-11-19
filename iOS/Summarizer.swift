import Foundation
import Security

/// BYOK: 文字起こしテキストのみ送信 (音声は送らない)。
enum Keychain {
    static func set(_ value: String, for key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

enum Summarizer {
    static let keyName = "anthropic_api_key"
    static let model = "claude-haiku-5-5"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func summarize(_ transcript: String) async throws -> String {
        guard let key = Keychain.get(keyName), !key.isEmpty else {
            throw Failure(message: "APIキー未設定 (設定画面)")
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let prompt = """
        以下は会話の文字起こし。誤認識を考慮し、(1)要点3〜5個 (2)決定事項 (3)TODO(担当・期限が分かれば付記) を日本語の箇条書きで出力。推測は「推測」と明記。

        \(transcript)
        """
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1500,
            "messages": [["role": "user", "content": prompt]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure(message: "API error: \(String(data: data, encoding: .utf8) ?? "")")
        }
        struct R: Decodable { struct C: Decodable { let text: String? }; let content: [C] }
        let r = try JSONDecoder().decode(R.self, from: data)
        return r.content.compactMap(\.text).joined()
    }
}
