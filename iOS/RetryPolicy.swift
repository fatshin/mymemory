import Foundation

/// 文字起こしの再試行方針。UIKit/WhisperKit に依存しない純粋関数で、単体テストできる。
enum RetryPolicy {
    /// 同じ録音で処理が中断・失敗し続けたときの打ち切り回数。
    /// OS による中断 (時間切れ・強制終了) も数えるため、少し余裕を持たせる。
    static let maxAttempts = 5

    enum Action: Equatable {
        case requeue   // 保留へ戻して再処理する
        case fail      // failed にして、利用者の再文字起こしに任せる
    }

    /// 起動時に未完了 (pending/transcribing) だった録音の扱い。
    /// 上限に達していれば、起動のたびに同じ録音で落ちるループを断つ。
    static func onRelaunch(attempts: Int) -> Action {
        attempts >= maxAttempts ? .fail : .requeue
    }
}
