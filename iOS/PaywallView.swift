import SwiftUI
import StoreKit

/// 購入画面。価格・期間・自動更新・購入の復元の表示は SubscriptionStoreView が行う (審査ガイドライン 3.1.2)。
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: Store

    var body: some View {
        // シートで開くと SubscriptionStoreView が自前の閉じるボタン (×) を出すため、独自のボタンは置かない
        SubscriptionStoreView(productIDs: [PlanConfig.proMonthlyID]) {
            VStack(alignment: .leading, spacing: 12) {
                Text("MyMemory Pro").font(.largeTitle.bold())
                Label("文字起こしの時間制限なし (無料は1日\(Int(PlanConfig.freeDailySeconds / 60))分まで)", systemImage: "waveform")
                Label("無料枠を超えて残っている録音も、翌日を待たずに文字起こし", systemImage: "tray.full")
                Text("サブスクリプションは期間終了の24時間前までに解約しない限り自動で更新されます。解約は設定アプリの「サブスクリプション」から行えます。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
        }
        .storeButton(.visible, for: .restorePurchases)
        .subscriptionStorePolicyDestination(url: PlanConfig.termsURL, for: .termsOfService)
        .modifier(PrivacyPolicyLink())
        // この修飾子を付けると購入の取引は Transaction.updates に流れないため、ここで完了処理と状態の更新を行う
        .onInAppPurchaseCompletion { _, result in
            guard case .success(.success(let verification)) = result else { return }
            if case .verified(let transaction) = verification { await transaction.finish() }
            await store.refresh()
            dismiss()
        }
        // 「購入を復元」の後にも状態を取り直す
        .onDisappear { Task { await store.refresh() } }
    }
}

/// プライバシーポリシーの URL を公開したら、購入画面にリンクを出す。
private struct PrivacyPolicyLink: ViewModifier {
    func body(content: Content) -> some View {
        if let url = PlanConfig.privacyURL {
            content.subscriptionStorePolicyDestination(url: url, for: .privacyPolicy)
        } else {
            content
        }
    }
}
