import SwiftUI

/// 初回起動時の説明と同意。常時録音アプリとして、録音・保存先・送信の有無を最初に明示する。
struct OnboardingView: View {
    static let doneKey = "onboardingDone"
    @AppStorage(OnboardingView.doneKey) private var done = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("MyMemory へようこそ").font(.largeTitle.bold())
                item("applewatch", "Apple Watch で録音します",
                     "録音中は Watch の画面に表示されます。いつでも停止できます。")
                item("person.2", "周りの人への配慮",
                     "会話を録音する場合は、相手の同意を得てください。録音が禁止された場所では使わないでください。")
                item("iphone", "文字起こしと要約は原則として端末内で行います",
                     "音声と文字起こしはこの iPhone に保存します。音声を外部へ送ることはありません。")
                item("network", "外部への送信は任意です",
                     "設定で許可した場合に限り、要約に外部APIを選んだとき、または端末内で要約できないときに、文字起こしテキストを\(Summarizer.remoteRecipient)へ送ります。既定はオフです。")
                item("trash", "いつでも削除できます",
                     "録音は録音の詳細画面のメニューから削除できます。アプリを削除すると、録音と文字起こしはすべて消えます。")
                Button {
                    done = true
                } label: {
                    Text("同意して始める").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
            }
            .padding()
        }
        .interactiveDismissDisabled()
    }

    private func item(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).frame(width: 32).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
