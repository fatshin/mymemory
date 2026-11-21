import Foundation

/// 継続タスクの進捗 (音声の秒数) を求める純粋関数。単体テストできるよう UIKit・BackgroundTasks に依存させない。
enum ContinuedProgress {
    /// WhisperKit が音声を処理する 1 ウィンドウの長さ (秒)。
    static let windowSeconds: Double = 30

    /// - Parameters:
    ///   - finishedSeconds: 処理を終えた録音の長さの合計
    ///   - windowIndex: 処理中の録音で、いま処理しているウィンドウの番号 (0 始まり)
    ///   - fileSeconds: 処理中の録音の長さ。0 以下なら途中経過は数えない
    /// - Returns: 進捗の完了単位。処理中の録音は、ウィンドウの手前までを数え、録音の長さを超えない。
    static func completedUnits(finishedSeconds: Double, windowIndex: Int, fileSeconds: Double) -> Int64 {
        guard fileSeconds > 0, windowIndex > 0 else { return Int64(max(0, finishedSeconds)) }
        let within = min(Double(windowIndex) * windowSeconds, fileSeconds)
        return Int64(max(0, finishedSeconds) + within)
    }
}
