import Foundation
import Combine

/// やること台帳の保存先 (UserDefaults に JSON)。画面はこれを観察し、変わったら組み直す。
@MainActor
final class TodoLedgerStore: ObservableObject {
    static let shared = TodoLedgerStore()
    static let defaultsKey = "todoLedger.v1"

    @Published private(set) var ledger: TodoLedger
    /// 変化の合図 (一覧の組み直しに使う)。
    @Published private(set) var revision = 0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var l = (defaults.data(forKey: Self.defaultsKey)).flatMap { try? JSONDecoder().decode(TodoLedger.self, from: $0) } ?? TodoLedger()
        l.purge()
        ledger = l
    }

    /// 操作し、元に戻すための操作前の記録を返す。
    @discardableResult
    func perform(_ original: String, _ change: (inout TodoLedger) -> Void) -> [TodoLedger.Entry]? {
        let previous = ledger.snapshot(for: original)
        var l = ledger
        change(&l)
        commit(l)
        return previous
    }

    /// 元に戻す。操作の直後 (after) から記録が変わっていたら、他の操作を巻き戻さないよう何もしない。
    func undo(_ original: String, previous: [TodoLedger.Entry]?, after: [TodoLedger.Entry]?) {
        guard ledger.snapshot(for: original) == after else { return }
        var l = ledger
        l.restore(original, to: previous)
        commit(l)
    }

    private func commit(_ l: TodoLedger) {
        ledger = l
        revision += 1
        if let data = try? JSONEncoder().encode(l) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// 直前の完了・削除を元に戻すための記録 (画面下に数秒出す)。
struct TodoUndo: Equatable {
    let original: String
    let previous: [TodoLedger.Entry]?
    /// 操作直後の記録。元に戻すときに、まだこの状態のままかを確かめる。
    let after: [TodoLedger.Entry]?
    let message: String

    @MainActor init(original: String, previous: [TodoLedger.Entry]?, message: String) {
        self.original = original
        self.previous = previous
        self.after = TodoLedgerStore.shared.ledger.snapshot(for: original)
        self.message = message
    }
}
