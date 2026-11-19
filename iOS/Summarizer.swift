import Foundation
import Security

/// 要約の入口。端末内 (Foundation Models) を優先し、使えないときだけ BYOK の外部 API を使う。
/// 外部 API へ送るのは文字起こしテキストのみ (音声は送らない)。
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

    /// 要約の結果と、どこで実行したか。
    struct Result {
        let text: String
        let route: SummaryRoute
        var labeled: String { text + "\n\n(" + (route == .onDevice ? "端末内で要約" : "外部APIで要約") + ")" }
    }

    static var hasAPIKey: Bool { !(Keychain.get(keyName) ?? "").isEmpty }

    /// 外部 API への送信許可。既定は不許可。設定画面のトグルで利用者が明示的に有効にする。
    static let remoteAllowedKey = "remoteSummaryAllowed"
    static var remoteAllowed: Bool { UserDefaults.standard.bool(forKey: remoteAllowedKey) }
    /// 送信先の表記。審査ガイドライン 5.1.2(i) に沿って送信先の事業者名を示す。
    static let remoteRecipient = "Anthropic の API"

    /// 端末内が使えれば端末内、使えなければ API キーで外部 API。どちらも無ければ理由を返す。
    /// 端末内モデルが準備中なら外部 API へ切り替えず、待つよう伝える (利用者の意図しない送信を避ける)。
    static func currentRoute() throws -> SummaryRoute {
        if OnDeviceSummarizer.isPreparing {
            throw Failure(message: "端末内モデルを準備中です。しばらく待ってから再試行してください")
        }
        let onDevice = OnDeviceSummarizer.isAvailable
        if onDevice { return .onDevice }
        let key = hasAPIKey, allowed = remoteAllowed
        if let route = SummaryRoute.choose(onDeviceAvailable: onDevice, hasAPIKey: key, remoteAllowed: allowed) {
            return route
        }
        if case .unavailable(let reason) = OnDeviceSummarizer.status {
            if key && !allowed {
                throw Failure(message: "\(reason)。\(remoteRecipient)で要約する場合は、設定で送信を許可してください")
            }
            throw Failure(message: "\(reason)。\(remoteRecipient)で要約する場合は、設定でAPIキーを登録し送信を許可してください")
        }
        throw Failure(message: "要約を実行できません")
    }

    /// 経路は呼び出し側で事前に決めて渡す。ボタンに表示した経路と実際の送信先を一致させるため。
    static func summarize(_ transcript: String, route: SummaryRoute) async throws -> Result {
        switch route {
        case .onDevice: return Result(text: try await OnDeviceSummarizer.summarize(transcript), route: route)
        case .remote: return Result(text: try await remoteSummarize(transcript), route: route)
        }
    }

    static func reflect(timeline: String, route: SummaryRoute) async throws -> Result {
        switch route {
        case .onDevice: return Result(text: try await OnDeviceSummarizer.reflect(timeline: timeline), route: route)
        case .remote: return Result(text: try await remoteReflect(timeline: timeline), route: route)
        }
    }

    private static func remoteSummarize(_ transcript: String) async throws -> String {
        try await call(prompt: """
        以下は会話の文字起こし。誤認識を考慮し、(1)要点3〜5個 (2)決定事項 (3)TODO(担当・期限が分かれば付記) を日本語の箇条書きで出力。推測は「推測」と明記。

        \(transcript)
        """)
    }

    private static func remoteReflect(timeline: String) async throws -> String {
        try await call(prompt: """
        以下は1日の音声ログ(時刻付き文字起こし)。日本語で出力: (1)1日の流れを時系列で簡潔に (2)重要な会話・決定 (3)TODO・約束 (4)気づき。誤認識を考慮し、推測は「推測」と明記。

        \(timeline)
        """)
    }

    private static func call(prompt: String) async throws -> String {
        // 経路選択を通らない呼び出しがあっても、許可なしでは送らない (二重の防御)
        guard remoteAllowed else {
            throw Failure(message: "\(remoteRecipient)への送信が許可されていません (設定画面)")
        }
        guard let key = Keychain.get(keyName), !key.isEmpty else {
            throw Failure(message: "APIキー未設定 (設定画面)")
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
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
