import Foundation
import StoreKit

/// 購読状態を端末内の取引から確認し、有効期限を保存する。購入と復元の画面は SubscriptionStoreView に任せる。
@MainActor
final class Store: ObservableObject {
    @Published private(set) var isPro = Entitlement.isProNow
    /// 有料になったとき (購入・復元・更新) に呼ぶ。止めていた文字起こしを再開するため。
    var onBecamePro: (() -> Void)?
    private var updates: Task<Void, Never>?

    init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
        Task { await refresh() }
    }

    /// 端末内の有効な取引から期限を更新する。
    func refresh() async {
        var latest: Date?
        for await result in Transaction.currentEntitlements {
            // 署名を検証できた、取り消されていない取引だけを有効とする
            guard case .verified(let t) = result, t.productID == PlanConfig.proMonthlyID,
                  t.revocationDate == nil else { continue }
            let expiry = t.expirationDate ?? .distantFuture
            latest = max(latest ?? .distantPast, expiry)
        }
        var cached = Entitlement.cachedExpiry
        // 返金・取り消しの通知を取りこぼしても、最新の取引が取り消されていれば有料を外す
        if let last = await Transaction.latest(for: PlanConfig.proMonthlyID),
           case .verified(let t) = last, t.revocationDate != nil {
            cached = nil
        }
        Entitlement.cachedExpiry = Entitlement.merged(cached: cached, fromEntitlements: latest, now: Date())
        publish()
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let t) = result else { return }
        if t.productID == PlanConfig.proMonthlyID, t.revocationDate != nil {
            // 返金・取り消しは、保存済みの期限も消す
            Entitlement.cachedExpiry = nil
        }
        await t.finish()
        await refresh()
    }

    private func publish() {
        let was = isPro
        isPro = Entitlement.isProNow
        if isPro && !was { onBecamePro?() }
    }
}
