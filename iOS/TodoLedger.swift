import Foundation

/// やることの状態 (完了・削除・編集) を、要約の本文とは別に持つ台帳。
/// 本文は生成されたまま保ち、表示と書き出しのたびに台帳を重ねる。
/// - 鍵は正規化した文言。同じ文言なら録音をまたいで同じ項目として扱う。
/// - 記録ごとに「どの録音まで効くか」(scopeAt) を持つ。操作した時点までに始まった録音にだけ効かせ、
///   後日の会話で同じ約束をしたら新しい項目として出す。後日の項目を操作すると、別の記録として残す。
/// - 要約を作り直しても、同じ文言が出れば状態と編集が戻る。
struct TodoLedger: Codable, Equatable {
    enum Status: String, Codable { case completed, deleted }

    struct Entry: Codable, Equatable, Identifiable {
        var id: String { TodoLedger.key(original) + "|\(scopeAt.timeIntervalSince1970)" }
        /// 要約に書かれていた元の文言 (編集しても変えない)。
        var original: String
        /// 編集後の文言。編集していなければ nil。
        var edited: String?
        /// nil は未完了 (編集だけした項目)。
        var status: Status?
        /// この時刻までに始まった録音の項目に効く (前の記録が効く録音は除く)。作ったときに決め、操作しても変えない。
        var scopeAt: Date
        /// 最後に操作した日時 (掃除に使う)。
        var changedAt: Date
        var completedAt: Date?

        var display: String { edited ?? original }
    }

    /// 表示する 1 件の状態。
    enum Resolved: Equatable {
        case open(String)
        case completed(String, at: Date)
        case deleted
    }

    /// 完了・削除の履歴を残す日数。
    static let retentionDays = 180
    /// 編集だけの記録を残す日数 (要約の作り直し後も編集を保つため、完了より長く残す)。
    static let editRetentionDays = 400

    /// 鍵ごとの記録 (scopeAt の昇順)。
    private(set) var entries: [String: [Entry]] = [:]

    /// 空白と、意味を変えない句読点・括弧を除き、全角英数を半角に、英字を小文字にそろえる。
    /// 数字に挟まれた「.」「:」「-」「/」と記号 (¥、% など) は残す (「3.5時間」と「35時間」を同じにしない)。
    static func key(_ text: String) -> String {
        let half = Array((text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text).lowercased())
        let numeric: Set<Character> = [".", ":", "-", "/", ","]
        let drop: Set<Character> = ["。", "、", "「", "」", "『", "』", "(", ")", "（", "）", "[", "]", "【", "】",
                                    "・", "!", "?", ";", "\"", "'", "…", "〜", "~",
                                    "｡", "､", "｢", "｣", "･"]  // 半角に変えた後の句読点・括弧
        var out = ""
        for (i, c) in half.enumerated() {
            if c.isWhitespace { continue }
            let between = i > 0 && i + 1 < half.count && half[i - 1].isNumber && half[i + 1].isNumber
            if numeric.contains(c) { if between { out.append(c) }; continue }
            if drop.contains(c) { continue }
            out.append(c)
        }
        return out
    }

    /// 項目 (startedAt に始まった録音のもの) に効く記録。
    private func index(for key: String, startedAt: Date) -> Int? {
        entries[key]?.firstIndex { startedAt <= $0.scopeAt }
    }

    /// 元に戻すための、その文言の記録すべて。
    func snapshot(for original: String) -> [Entry]? { entries[Self.key(original)] }

    func resolve(_ original: String, startedAt: Date) -> Resolved {
        let k = Self.key(original)
        guard let i = index(for: k, startedAt: startedAt), let e = entries[k]?[i] else { return .open(original) }
        switch e.status {
        case .deleted: return .deleted
        case .completed: return .completed(e.display, at: e.completedAt ?? e.changedAt)
        case nil: return .open(e.display)
        }
    }

    mutating func complete(_ original: String, startedAt: Date, now: Date = Date()) {
        update(original, startedAt: startedAt, now: now) { $0.status = .completed; $0.completedAt = now }
    }

    mutating func delete(_ original: String, startedAt: Date, now: Date = Date()) {
        update(original, startedAt: startedAt, now: now) { $0.status = .deleted; $0.completedAt = nil }
    }

    /// 未完了に戻す。編集した文言は残す。
    mutating func reopen(_ original: String, startedAt: Date, now: Date = Date()) {
        update(original, startedAt: startedAt, now: now) { $0.status = nil; $0.completedAt = nil }
    }

    /// 空の文言への編集は削除として扱う。元の文言に戻したら編集を消す。
    mutating func edit(_ original: String, startedAt: Date, to text: String, now: Date = Date()) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        if t.isEmpty { delete(original, startedAt: startedAt, now: now); return }
        update(original, startedAt: startedAt, now: now) { $0.edited = (t == $0.original) ? nil : t }
    }

    /// 元に戻す (操作前の記録をそのまま戻す。記録が無かったなら台帳から消す)。
    mutating func restore(_ original: String, to previous: [Entry]?) {
        entries[Self.key(original)] = previous
    }

    /// 完了・削除は retentionDays、編集だけの記録は editRetentionDays を過ぎたら期限切れ。
    /// 同じ文言の記録がすべて期限切れなら消す。一部だけなら、期限切れの記録を「何もしない印」に変えて残す
    /// (消すと、その記録が効いていた古い録音が後の記録の状態を引き継いでしまうため)。
    mutating func purge(now: Date = Date()) {
        let cal = Calendar(identifier: .gregorian)
        guard let done = cal.date(byAdding: .day, value: -Self.retentionDays, to: now),
              let edits = cal.date(byAdding: .day, value: -Self.editRetentionDays, to: now) else { return }
        func expired(_ e: Entry) -> Bool { e.changedAt < (e.status == nil ? edits : done) }
        entries = entries.compactMapValues { list in
            if list.allSatisfy(expired) { return nil }
            return list.map { e in
                guard expired(e) else { return e }
                var n = e
                n.status = nil; n.edited = nil; n.completedAt = nil
                return n
            }
        }
    }

    /// 完了した項目を新しい順に。
    var completed: [Entry] {
        entries.values.flatMap { $0 }.filter { $0.status == .completed }
            .sorted { ($0.completedAt ?? $0.changedAt) > ($1.completedAt ?? $1.changedAt) }
    }

    /// 決定事項も同じ台帳で削除・編集する。決定事項は会議ごとのものなので、鍵に録音を含める
    /// (同じ文言でも別の録音の決定事項や、同じ文言の TODO には効かせない)。
    static func decisionOriginal(_ text: String, recording: UUID) -> String { "決定事項|\(recording.uuidString)|" + text }

    /// 決定事項の表示。消していれば nil、編集していれば編集後の文言。
    func resolveDecision(_ text: String, recording: UUID, startedAt: Date) -> String? {
        let original = Self.decisionOriginal(text, recording: recording)
        switch resolve(original, startedAt: startedAt) {
        case .deleted: return nil
        case .open(let s), .completed(let s, _): return s == original ? text : s
        }
    }

    /// 1 日の録音ごとの決定事項に台帳 (削除・編集) を重ね、同じ文言は 1 つにまとめる (録音の時刻順、録音の中は書かれた順)。
    func dayDecisions(_ recordings: [(id: UUID, startedAt: Date, summary: String?)]) -> [String] {
        var seen = Set<String>()
        return recordings.sorted { $0.startedAt < $1.startedAt }.flatMap { r in
            (r.summary.map { SummarySections.parse($0).decisions } ?? []).compactMap { d -> String? in
                guard let shown = resolveDecision(d, recording: r.id, startedAt: r.startedAt),
                      seen.insert(Self.key(shown)).inserted else { return nil }
                return shown
            }
        }
    }

    /// 要約の【決定事項】【TODO】に台帳を重ねた文 (完了は「[x] 」を付け、削除は消し、編集後の文言にする)。
    /// 決定事項は録音 (recording) が分かるときだけ重ねる。
    func overlay(summary: String, startedAt: Date, recording: UUID? = nil) -> String {
        SummarySections.mapItems(in: summary, sections: recording == nil ? [.todos] : [.decisions, .todos]) { section, _, t in
            if section == .decisions, let recording { return resolveDecision(t, recording: recording, startedAt: startedAt) }
            switch resolve(t, startedAt: startedAt) {
            case .open(let s): return s
            case .completed(let s, _): return "[x] " + s
            case .deleted: return nil
            }
        }
    }

    /// 項目に効く記録を変える。効く記録が無ければ、その項目までを範囲にした新しい記録を作る
    /// (時計のずれで未来の日時になった録音にも効くよう、範囲は操作時刻と開始時刻の遅いほう)。
    private mutating func update(_ original: String, startedAt: Date, now: Date, _ change: (inout Entry) -> Void) {
        let k = Self.key(original)
        var list = entries[k] ?? []
        if let i = index(for: k, startedAt: startedAt) {
            change(&list[i])
            list[i].changedAt = now
        } else {
            var e = Entry(original: original, edited: nil, status: nil, scopeAt: max(now, startedAt), changedAt: now, completedAt: nil)
            change(&e)
            list.append(e)
            list.sort { $0.scopeAt < $1.scopeAt }
        }
        entries[k] = list
    }
}
