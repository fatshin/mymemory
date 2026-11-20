import Foundation

/// 料金まわりの設定。値を変えるときはここだけを直す。
enum PlanConfig {
    /// 自動更新の月額サブスクリプション。App Store Connect の商品 ID と一致させる。
    static let proMonthlyID = "com.fatshin.mymemory.pro.monthly"
    /// 無料で文字起こしできる 1 日あたりの長さ。
    static let freeDailySeconds: TimeInterval = 30 * 60
    /// 初回起動から文字起こしを無制限に使える日数 (購入なし・登録なし)。過ぎたら 1 日の無料枠に戻る。
    static let freeTrialDays = 30
    /// 有効期限を過ぎても有料として扱う猶予。更新の確認が通信不通で遅れても、払っている人を止めないため。
    static let renewalGrace: TimeInterval = 3 * 24 * 3600
    /// 利用規約 (Apple の標準 EULA)。
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    /// プライバシーポリシーの公開 URL (原稿は docs/privacy-policy.md)。
    static let privacyURL: URL? = URL(string: "https://fatshin.github.io/mymemory-legal/")
}

/// 有料かどうかの判定。最後に確認できた有効期限だけで決める (起動直後やバックグラウンドでも同期的に読める)。
enum Entitlement {
    static func isPro(expiresAt: Date?, now: Date, grace: TimeInterval = PlanConfig.renewalGrace) -> Bool {
        guard let expiresAt else { return false }
        return now < expiresAt.addingTimeInterval(grace)
    }

    /// 端末内の取引一覧で更新するときの新しい期限。
    /// 一覧が空でも、期限と猶予の間は保存済みの期限を消さない (更新が届くのが遅れても払っている人を止めないため)。
    /// 返金・取り消しは `Transaction.updates` の取り消しで別に消す。
    static func merged(cached: Date?, fromEntitlements latest: Date?, now: Date,
                       grace: TimeInterval = PlanConfig.renewalGrace) -> Date? {
        if let latest { return latest }
        // 期限を過ぎても猶予の間は残す (更新が端末に届くのが遅れても止めない)
        guard let cached, now < cached.addingTimeInterval(grace) else { return nil }
        return cached
    }

    private static let key = "proExpiresAt"
    static var cachedExpiry: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: key)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            if let newValue { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    static var isProNow: Bool { isPro(expiresAt: cachedExpiry, now: Date()) }
}

/// 初回起動からの無料体験。開始日は Keychain に保存し (アプリを入れ直しても再開しない)、
/// 同期的に読めるよう UserDefaults にも写す。Keychain との同期は `FreeTrialStore` (アプリ側) が行う。
enum FreeTrial {
    static let defaultsKey = "freeTrialStartedAt"

    /// 体験の終わり。日数は 24 時間単位で数える (夏時間・時差の変更で残り日数がずれないように)。
    /// 開始日が未来になっている場合 (時計の変更) は、起動時に `FreeTrialStore` が今へ書き直す。
    static func endDate(startedAt: Date?, now: Date, days: Int = PlanConfig.freeTrialDays) -> Date? {
        guard let startedAt else { return nil }
        return startedAt.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    static func isActive(startedAt: Date?, now: Date, days: Int = PlanConfig.freeTrialDays) -> Bool {
        guard let end = endDate(startedAt: startedAt, now: now, days: days) else { return false }
        return now < end
    }

    /// 残り日数 (切り上げ)。体験中でなければ 0。
    static func daysLeft(startedAt: Date?, now: Date, days: Int = PlanConfig.freeTrialDays) -> Int {
        guard let end = endDate(startedAt: startedAt, now: now, days: days), now < end else { return 0 }
        return min(days, Int((end.timeIntervalSince(now) / 86_400).rounded(.up)))
    }

    static var cachedStart: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: defaultsKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            if let newValue { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        }
    }

    static var isActiveNow: Bool { isActive(startedAt: cachedStart, now: Date()) }
}

/// 無料枠の使用量。端末の日付ごとに数え、文字起こしに成功した分だけ足す。
struct UsageQuota: Equatable, Codable {
    var day: String
    var usedSeconds: TimeInterval

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 今日の使用量。日付が変わっていれば 0。
    func used(today: String) -> TimeInterval { day == today ? usedSeconds : 0 }

    func adding(_ seconds: TimeInterval, today: String) -> UsageQuota {
        UsageQuota(day: today, usedSeconds: used(today: today) + max(0, seconds))
    }

    /// 上限に達する前なら 1 本は最後まで処理する (録音を途中で切らない)。
    /// そのため 1 日の処理量は上限を最大で録音 1 本分 (10 分) 超えうる。残りは翌日に回る。
    static func canTranscribe(isPro: Bool, used: TimeInterval, limit: TimeInterval = PlanConfig.freeDailySeconds) -> Bool {
        isPro || used < limit
    }

    // MARK: - 保存

    private static let key = "usageQuota"
    static var stored: UsageQuota {
        get {
            guard let d = UserDefaults.standard.data(forKey: key),
                  let q = try? JSONDecoder().decode(UsageQuota.self, from: d) else { return UsageQuota(day: "", usedSeconds: 0) }
            return q
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    /// 今いま文字起こしを始めてよいか (Pipeline とバックグラウンドから同期的に呼ぶ)。
    static func allowsNow(now: Date = Date()) -> Bool {
        canTranscribe(isPro: Entitlement.isProNow || FreeTrial.isActive(startedAt: FreeTrial.cachedStart, now: now),
                      used: stored.used(today: dayKey(now)))
    }

    static func record(_ seconds: TimeInterval, now: Date = Date()) {
        // 体験中の分は無料枠に数えない (体験が終わった日に、その日の無料枠が最初から使えるように)
        guard !FreeTrial.isActive(startedAt: FreeTrial.cachedStart, now: now) else { return }
        stored = stored.adding(seconds, today: dayKey(now))
    }

    /// 次の日付の変わり目 (無料枠が戻る時刻)。
    static func nextReset(after now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(24 * 3600)
    }
}
