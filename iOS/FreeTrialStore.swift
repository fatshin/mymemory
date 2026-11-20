import Foundation
import Security

/// 無料体験の開始日を Keychain に保存する。Keychain の項目はアプリを削除しても残るため、入れ直しで体験が再開しない。
/// 読み取りに失敗したとき (ロック中のバックグラウンド起動など) は何も書かない。
/// 「無い」と確定したときだけ新しく作る (失敗を「無い」と取り違えて体験をやり直させない)。
enum FreeTrialStore {
    private static let account = "free_trial_started_at"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
    }

    /// 起動時に呼ぶ。
    static func ensureStarted(now: Date = Date()) {
        switch read() {
        case .found(let start) where start > now:
            // 開始日が未来 (時計を進めて起動した後に戻した等) なら今に直し、体験が 30 日を超えて延びないようにする
            if update(now) { FreeTrial.cachedStart = now }
        case .found(let start):
            FreeTrial.cachedStart = start
        case .notFound:
            // Keychain の保存が以前失敗していた場合は、UserDefaults に残る日付を引き継ぐ
            create(FreeTrial.cachedStart ?? now)
        case .unavailable:
            // 読めないときは触らない。判定は UserDefaults の値 (無ければ 1 日の無料枠) で行われる
            break
        }
    }

    private enum ReadResult { case found(Date), notFound, unavailable }

    private static func read() -> ReadResult {
        var q = baseQuery
        q[kSecReturnData as String] = true
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let d = out as? Data, let s = String(data: d, encoding: .utf8),
                  let t = TimeInterval(s), t > 0 else { return .unavailable }
            return .found(Date(timeIntervalSince1970: t))
        case errSecItemNotFound:
            return .notFound
        default:
            return .unavailable
        }
    }

    private static func update(_ start: Date) -> Bool {
        let attrs: [String: Any] = [kSecValueData as String: Data(String(start.timeIntervalSince1970).utf8)]
        return SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary) == errSecSuccess
    }

    /// 追加だけ行う (既存の項目を消さない)。重複なら保存済みの値を読み直す。
    private static func create(_ start: Date) {
        var add = baseQuery
        add[kSecValueData as String] = Data(String(start.timeIntervalSince1970).utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        switch SecItemAdd(add as CFDictionary, nil) {
        case errSecSuccess:
            FreeTrial.cachedStart = start
        case errSecDuplicateItem:
            if case .found(let saved) = read() { FreeTrial.cachedStart = saved }
        default:
            break
        }
    }
}
