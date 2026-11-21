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

    /// 利用者の明示操作 (「今すぐ文字起こし」) で非充電のまま実行するときの下限。
    /// 電池切れで Watch からの転送を受けられなくなる事態を避けるため、操作があっても 0 にはしない。
    static let minimumLevelUserInitiated: Float = 0.2

    /// - 充電中: 実行する
    /// - 非充電: 低電力モードOFF かつ 残量が下限以上のときだけ実行する (残量不明 -1 は実行しない)
    /// - 状態不明: シミュレータのみ実行する。実機では状態が確定するまで待つ (fail-closed)
    /// - 利用者の明示操作 (`userInitiated`): 非充電でも、低電力モードに関係なく残量が 20% 以上なら実行する
    static func shouldTranscribe(charge: Charge, level: Float, lowPowerMode: Bool, isSimulator: Bool,
                                 userInitiated: Bool = false) -> Bool {
        switch charge {
        case .charging:
            return true
        case .unplugged:
            if userInitiated { return level >= minimumLevelUserInitiated }
            return !lowPowerMode && level >= minimumLevelOnBattery
        case .unknown:
            return isSimulator
        }
    }

    /// 文字起こしの校正 (端末内モデル) は、外部電源につながっているときだけ行う。
    /// 校正は必須ではないため、利用者の明示操作でも電池では行わない。
    static func shouldProofread(charge: Charge, isSimulator: Bool) -> Bool {
        charge == .charging || (charge == .unknown && isSimulator)
    }
}

/// 利用者が「今すぐ」と押した時点の録音だけを、電力条件の緩和対象にする。
/// 実行中に Watch から届いた新しい録音は対象外で、通常の電力判定に戻る (非充電のまま走り続けない)。
struct UserRunScope: Equatable {
    private(set) var ids: Set<UUID> = []

    var isActive: Bool { !ids.isEmpty }
    mutating func begin(_ queued: [UUID]) { ids = Set(queued) }
    func covers(_ id: UUID?) -> Bool { id.map(ids.contains) ?? false }
    mutating func finish(_ id: UUID) { ids.remove(id) }
    mutating func clear() { ids.removeAll() }
}
