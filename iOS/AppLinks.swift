import Foundation

/// アプリ内から開く外部ページ。
enum AppLinks {
    /// プライバシーポリシーの公開 URL (原稿は docs/privacy-policy.md)。審査 5.1.1(i) によりアプリ内にもリンクを置く。
    static let privacy = URL(string: "https://fatshin.github.io/mymemory-legal/")!
}
