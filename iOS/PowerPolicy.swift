import Foundation

/// 文字起こしを今実行してよいかの判定。UIDevice に依存しない純粋関数にして単体テストできるようにする。
enum PowerPolicy {
    enum Charge: Equatable {
        case charging      // 充電中・満充電
        case unplugged
        case unknown       // 電池状態を取得できない
    }

    /// 非充電時に実行を許す電池残量の下限 (初期値。実機計測で見直す)。
    static let minimumLevelOnBattery: Float = 0.5

    /// - 充電中: 実行する
    /// - 非充電: 低電力モードOFF かつ 残量が下限以上のときだけ実行する (残量不明 -1 は実行しない)
    /// - 状態不明: シミュレータのみ実行する。実機では状態が確定するまで待つ (fail-closed)
    static func shouldTranscribe(charge: Charge, level: Float, lowPowerMode: Bool, isSimulator: Bool) -> Bool {
        switch charge {
        case .charging:
            return true
        case .unplugged:
            return !lowPowerMode && level >= minimumLevelOnBattery
        case .unknown:
            return isSimulator
        }
    }
}
