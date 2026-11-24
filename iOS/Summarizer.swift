import Foundation
import Security

/// 要約の入口。設定で選んだ経路 (端末内の Foundation Models か、BYOK の外部 API) を使い、使えないときはもう一方を使う。
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
    /// 選んだ送信先。変えたら送信許可を取り直す (設定画面が許可を落とす)。
    static let providerKey = "remoteProvider"
    static var provider: RemoteProvider {
        get { RemoteProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .anthropic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }
    static var keyName: String { provider.keyName }

    /// 送信先ごとのモデル名の上書き。空なら既定。
    static func modelKey(_ p: RemoteProvider) -> String { "remoteModel.\(p.rawValue)" }
    static func model(for p: RemoteProvider) -> String {
        let m = (UserDefaults.standard.string(forKey: modelKey(p)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? p.defaultModel : m
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 要約の結果と、どこで実行したか。
    struct Result {
        var text: String
        let route: SummaryRoute
        /// 結果を作った時点の送信先 (あとで送信先を変えても表記がずれないようにする)。
        var providerName = Summarizer.provider.displayName
        /// 端末内モデルで見直した (SummaryReviewer)。
        var reviewed = false
        /// 追加の指示で見出しが崩れたため、追加の指示なしで作り直した。
        var customIgnored = false
        /// 末尾の注記は「で要約)」で終える (ReflectionSections.isRouteLabel が本文と分けるため)。
        var labeled: String {
            text + "\n\n(" + (reviewed ? "見直し済み・" : "") + (route == .onDevice ? "端末内で要約" : "\(providerName) で要約") + ")"
        }
    }

    /// 要約を端末内モデルで見直す (誤字・意味の分からない項目を直し、意味をなさない項目を消す)。
    /// 端末内モデルが無い・見直せないときは元のまま返す (外部 API だけの利用者にも要約を出す)。混み合っているときは Busy を投げる。
    /// 台帳 (TodoLedger) は保存した TODO の文言を鍵にするため、保存済みの要約には使わず、初めて保存する前にだけ呼ぶ。
    static func review(_ r: Result) async throws -> Result {
        guard let text = try await SummaryReviewer.review(r.text) else { return r }
        var out = r
        out.text = text
        out.reviewed = true
        return out
    }

    /// 利用者が押した要約用。混み合っていたら少し待って 1 回だけやり直し、それでも無理なら見直さずに返す。
    static func reviewOrKeep(_ r: Result) async throws -> Result {
        do {
            return try await review(r)
        } catch is SummaryReviewer.Busy {
            try await Task.sleep(for: .seconds(3))
            do { return try await review(r) } catch is SummaryReviewer.Busy { return r }
        }
    }

    static var hasAPIKey: Bool { !(Keychain.get(keyName) ?? "").isEmpty }

    /// 外部 API への送信許可。既定は不許可。設定画面のトグルで利用者が明示的に有効にする。
    static let remoteAllowedKey = "remoteSummaryAllowed"
    /// 許可したときの送信先。許可は送信先ごとで、別の送信先には引き継がない。
    static let remoteAllowedProviderKey = "remoteSummaryAllowedProvider"
    static var remoteAllowed: Bool { isAllowed(provider) }
    static func isAllowed(_ p: RemoteProvider) -> Bool {
        UserDefaults.standard.bool(forKey: remoteAllowedKey)
            && UserDefaults.standard.string(forKey: remoteAllowedProviderKey) == p.rawValue
    }
    /// 送信先の表記。審査ガイドライン 5.1.2(i) に沿って送信先の事業者名を示す。
    static var remoteRecipient: String { provider.recipient }

    /// 要約に使う経路の選択 (設定画面)。既定は端末内。外部 API はキーと送信の許可がそろったときだけ使う。
    static let preferenceKey = "summaryPreference"
    static var preferred: SummaryRoute {
        get { SummaryRoute(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .onDevice }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey) }
    }

    /// 今使える経路 (要約ボタンを経路ごとに出すのに使う)。設定で選んだ経路を先にする。
    static func usableRoutes() -> [SummaryRoute] {
        let pref = preferred
        let usable = SummaryRoute.usableRoutes(onDeviceAvailable: OnDeviceSummarizer.isAvailable, hasAPIKey: hasAPIKey, remoteAllowed: remoteAllowed)
        return usable.filter { $0 == pref } + usable.filter { $0 != pref }
    }

    /// 押したボタンの経路が、押した時点でも使えるときだけ返す (表示が古いまま外部 API へ送らない)。
    static func confirmUsable(_ route: SummaryRoute) throws -> SummaryRoute {
        guard usableRoutes().contains(route) else {
            throw Failure(message: route == .remote
                ? "\(remoteRecipient)への送信が使えなくなりました (APIキーか送信の許可を設定で確認してください)"
                : "端末内モデルが使えなくなりました。表示を確認してもう一度押してください")
        }
        return route
    }

    /// 選んだ経路が使えればそれを、使えなければもう一方を使う。どちらも無ければ理由を返す。
    /// 端末内を選んでいてモデルが準備中なら外部 API へ切り替えず、待つよう伝える (利用者の意図しない送信を避ける)。
    static func currentRoute() throws -> SummaryRoute {
        let key = hasAPIKey, allowed = remoteAllowed, pref = preferred
        if pref == .remote, key, allowed { return .remote }
        if OnDeviceSummarizer.isPreparing {
            throw Failure(message: "端末内モデルを準備中です。しばらく待ってから再試行してください")
        }
        if let route = SummaryRoute.choose(preferred: pref, onDeviceAvailable: OnDeviceSummarizer.isAvailable,
                                           hasAPIKey: key, remoteAllowed: allowed) {
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
    /// - Parameters:
    ///   - extra: 追加の指示。nil なら設定に保存したもの (試して比べる画面だけが編集中の指示を渡す)
    ///   - base: 基本の指示。nil なら設定に保存したもの (書き換えていなければ既定)
    static func summarize(_ transcript: String, route: SummaryRoute, extra: String? = nil, base: String? = nil) async throws -> Result {
        let e = extra ?? SummaryPrompt.custom
        let b = base ?? SummaryPrompt.base.current
        let first = try await summarizeOnce(transcript, route: route, extra: e, base: b)
        // 書き換えた指示で見出しが崩れた要約は、決定事項・TODO の一覧と台帳が読めないため、既定の指示で作り直す
        let customized = !SummaryPrompt.clean(e).isEmpty || b != SummaryPrompt.final
        if !customized || SummaryPrompt.hasRequiredHeadings(first.text) { return first }
        var retry = try await summarizeOnce(transcript, route: route, extra: "", base: SummaryPrompt.final)
        retry.customIgnored = true
        return retry
    }

    private static func summarizeOnce(_ transcript: String, route: SummaryRoute, extra: String, base: String) async throws -> Result {
        switch route {
        case .onDevice:
            return Result(text: try await OnDeviceSummarizer.summarize(transcript, extra: extra, base: base), route: route)
        case .remote:
            let name = provider.displayName
            return Result(text: try await remoteSummarize(transcript, extra: extra, base: base), route: route, providerName: name)
        }
    }

    static func reflect(timeline: String, route: SummaryRoute) async throws -> Result {
        let custom = SummaryPrompt.reflectionBase
        let first = try await reflectOnce(timeline: timeline, route: route, prompt: custom.isCustomized ? custom.current : nil)
        // 書き換えた指示で見出しが崩れたら、既定の指示で作り直す (決定事項・TODO の差し替えと表示が見出しで読むため)
        guard custom.isCustomized,
              !SummaryPrompt.reflectionHeadings.allSatisfy({ SummaryPrompt.contains($0, in: first.text) }) else { return first }
        var retry = try await reflectOnce(timeline: timeline, route: route, prompt: nil)
        retry.customIgnored = true
        return retry
    }

    private static func reflectOnce(timeline: String, route: SummaryRoute, prompt: String?) async throws -> Result {
        switch route {
        case .onDevice: return Result(text: try await OnDeviceSummarizer.reflect(timeline: timeline, prompt: prompt), route: route)
        case .remote:
            let name = provider.displayName
            return Result(text: try await remoteReflect(timeline: timeline, prompt: prompt ?? SummaryPrompt.reflection),
                          route: route, providerName: name)
        }
    }

    private static func remoteSummarize(_ transcript: String, extra: String, base: String) async throws -> String {
        try await call(prompt: """
        \(SummaryPrompt.withCustom(base, extra))

        <transcript>
        \(transcript)
        </transcript>
        """)
    }

    private static func remoteReflect(timeline: String, prompt: String) async throws -> String {
        try await call(prompt: """
        \(prompt)

        <log>
        \(timeline)
        </log>
        """)
    }

    /// 送信先の実在するモデルの一覧。設定画面で利用者がボタンを押したときだけ呼ぶ (送るのは API キーだけ)。
    /// キーは保存前の入力欄の値を受け取る (Keychain に入るのは「保存」を押した後のため)。
    static func listModels(_ p: RemoteProvider, key: String) async throws -> [String] {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw Failure(message: "APIキーを入力してください") }
        var ids: [String] = []
        var page: String?
        for _ in 0..<5 {
            var req = p.listRequest(key: key, page: page)
            req.timeoutInterval = 30
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                // 応答本文は出さない (キーの一部が含まれることがあるため)
                let hint = (code == 401 || code == 403) ? " (APIキーを確認してください)" : ""
                throw Failure(message: "\(p.displayName) のモデル一覧を取得できません: HTTP \(code)\(hint)")
            }
            let r = try p.parseModels(data)
            ids += r.ids
            guard let n = r.next else { break }
            page = n
        }
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        if unique.isEmpty { throw Failure(message: "\(p.displayName) で使えるモデルが見つかりませんでした") }
        return unique
    }

    /// 保存前の疎通確認に送る文。文字起こしや個人の情報は含めない。
    static let connectionTestPrompt = "接続確認です。「OK」とだけ返してください。"

    /// 設定画面で APIキーを保存する前の疎通確認。入力欄のキーと選んだモデルで、固定の短い文 (connectionTestPrompt) だけを送る。
    /// 文字起こしは送らないため、送信の許可より前でも呼べる。成功しなければ例外を投げ、呼び出し側は保存しない。
    static func verifyConnection(_ p: RemoteProvider, key: String, model: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw Failure(message: "APIキーを入力してください") }
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let usedModel = m.isEmpty ? p.defaultModel : m
        var req = try p.request(key: key, model: usedModel, prompt: connectionTestPrompt)
        req.timeoutInterval = 30
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch let e as URLError {
            // OS の文言は使わない (URL を含むことがあり、将来キーが混ざるのを避ける)
            let why: String
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost: why = "インターネットに接続されていません"
            case .timedOut: why = "応答がありません (時間切れ)"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: why = "接続先が見つかりません"
            default: why = "通信エラー (コード \(e.code.rawValue))"
            }
            throw Failure(message: "\(p.displayName) に接続できません: \(why)")
        } catch {
            throw Failure(message: "\(p.displayName) に接続できません")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            // 応答本文は出さない (キーの一部が含まれることがあるため)
            throw Failure(message: "\(p.displayName) の接続確認に失敗: HTTP \(code)\(connectionHint(code, model: usedModel))")
        }
        do { _ = try p.parse(data) } catch {
            throw Failure(message: "\(p.displayName) の応答を読めませんでした (モデル \(usedModel) が要約に使えるか確認してください)")
        }
    }

    /// HTTP の状態から、利用者が直すべき箇所を示す。
    static func connectionHint(_ code: Int, model: String) -> String {
        switch code {
        case 401, 403: return " (APIキーを確認してください)"
        case 400, 404: return " (モデル名 \(model) を確認してください)"
        case 429: return " (利用上限か残高を確認してください)"
        default: return ""
        }
    }

    private static func call(prompt: String) async throws -> String {
        // 経路選択を通らない呼び出しがあっても、許可なしでは送らない (二重の防御)
        // 許可を確かめる相手と実際の送信先を、同じ 1 回の読み取りから取る
        let p = provider
        guard isAllowed(p) else {
            throw Failure(message: "\(p.recipient)への送信が許可されていません (設定画面)")
        }
        guard let key = Keychain.get(p.keyName), !key.isEmpty else {
            throw Failure(message: "APIキー未設定 (設定画面)")
        }
        var req = try p.request(key: key, model: model(for: p), prompt: prompt)
        req.timeoutInterval = 90
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            // 応答本文は出さない (キーの一部や送ったテキストが含まれることがあるため)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let hint = (code == 401 || code == 403) ? " (APIキーを確認してください)" : ""
            throw Failure(message: "\(p.displayName) API error: HTTP \(code)\(hint)")
        }
        return try p.parse(data)
    }
}
