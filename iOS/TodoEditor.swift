import Foundation
import SwiftData

/// やることの出どころ。編集・削除は、元の要約 (録音ごと) か、その日の振り返りの文を書き換えて行う。
/// index は SummarySections.parse(元の文).todos の並び。
/// expected は表示していた文言。書き換え時に一致を確かめ、表示が古くても別の項目を消さない。
enum TodoSource: Hashable {
    case recording(UUID, index: Int, expected: String)
    case reflection(day: Date, index: Int, expected: String)
}

@MainActor
enum TodoEditor {
    /// newText が nil なら削除 (完了も削除として扱う)。書き換えた元が見つからなければ何もしない。
    static func apply(_ source: TodoSource, newText: String?, in context: ModelContext) throws {
        switch source {
        case .recording(let id, let index, let expected):
            let d = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
            guard let rec = try context.fetch(d).first, let summary = rec.summary else { return }
            let edited = SummarySections.editingTodo(in: summary, at: index, expected: expected, to: newText)
            guard edited != summary else { return }
            rec.summary = edited
            do { try context.save() } catch {
                context.rollback()  // 保存に失敗したら画面上の変更も戻す
                throw error
            }
        case .reflection(let day, let index, let expected):
            guard let saved = ReflectionStore.load(day) else { return }
            let edited = SummarySections.editingTodo(in: saved.text, at: index, expected: expected, to: newText)
            guard edited != saved.text else { return }
            ReflectionStore.save(edited, for: day, recordingCount: saved.recordingCount, latestStart: saved.latestStart)
        }
    }
}
