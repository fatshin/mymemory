import SwiftUI
import UIKit

/// アプリ全体の色と、メイン画面・振り返りで使う小さな部品。
/// ガラス効果は操作部品にだけ使い、文字を読む面は不透明のままにする。
enum Theme {
    /// 温かい琥珀色。ボタンの塗りに使う (上に白文字を載せる)。
    /// ライトでは白文字が 4.5:1 を超える濃さ、ダークでは少し明るくして沈まないようにする。
    static let accent = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.80, green: 0.42, blue: 0.16, alpha: 1)
            : UIColor(red: 0.70, green: 0.35, blue: 0.10, alpha: 1)
    })
    /// 背景の上に置く文字・アイコン用の琥珀色。ダークでは明るくして読めるようにする。
    static let accentText = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 1.00, green: 0.70, blue: 0.42, alpha: 1)
            : UIColor(red: 0.62, green: 0.30, blue: 0.08, alpha: 1)
    })

    static func statusColor(_ raw: String) -> Color {
        switch raw {
        case "done": return .green
        case "transcribing": return accentText
        case "failed": return .red
        default: return .secondary
        }
    }

    /// 振り返り・要約の見出しごとのアイコン。知らない見出しは汎用のアイコンにする。
    static func icon(forSection title: String?) -> String {
        switch title {
        case "1日の流れ": return "clock"
        case "概要": return "text.alignleft"
        case "要点": return "text.bubble"
        case "決定事項": return "checkmark.seal"
        case "TODO": return "checklist"
        case "気づき": return "lightbulb"
        default: return "doc.text"
        }
    }
}

/// 状態を色付きの小さな丸と文字で示す。
struct StatusBadge: View {
    let raw: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Theme.statusColor(raw)).frame(width: 7, height: 7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// メイン画面の先頭に置く「今日のまとめ」。
/// 振り返りを生成済みなら 1日の流れと気づきを、未生成なら録音ごとの要点を時刻付きで出す。
/// メイン画面の先頭に置くまとめ。利用者の状態に合わせて中身と操作を 1 つに絞る。
/// - 振り返りあり: 1日の流れ (3行まで) と気づき (2行まで)
/// - 振り返りなし: 録音ごとの要点を時刻付きで (4件まで)
struct TodayCard<Destination: View>: View {
    let home: HomeSummary
    @ViewBuilder let destination: () -> Destination

    private var reflectionParts: [(title: String, body: String, lines: Int)] {
        guard let text = home.reflection?.text else { return [] }
        let sections = ReflectionSections.parse(text)
        return [("1日の流れ", 3), ("気づき", 2)].compactMap { title, lines in
            sections.first { $0.title == title }.map { (title, $0.body, lines) }
        }
    }

    private var buttonLabel: String {
        if home.reflection == nil { return "\(home.dayLabel)を振り返る" }
        return home.addedSinceReflection > 0 ? "振り返りを作り直す" : "振り返りを開く"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(home.dayLabel).font(.title2.bold())
                Text(home.day, format: .dateTime.month().day().weekday())
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("\(home.items.count)件・\(home.totalMinutes)分")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }

            if !reflectionParts.isEmpty {
                ForEach(reflectionParts, id: \.title) { part in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(part.title, systemImage: Theme.icon(forSection: part.title))
                            .font(.subheadline.bold()).foregroundStyle(Theme.accentText)
                        Text(part.body).font(.callout).lineLimit(part.lines)
                    }
                }
                // どこで要約したかの開示 (送信先の事業者名)。本文を出す画面では必ず添える
                if let label = home.reflection.flatMap({ ReflectionSections.routeLabel(in: $0.text) }) {
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                }
                if home.addedSinceReflection > 0 {
                    Label("振り返りのあとに \(home.addedSinceReflection) 件の録音が増えています", systemImage: "arrow.clockwise")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !home.points.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(home.points) { p in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(p.time, format: .dateTime.hour().minute())
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .leading)
                            Text(p.text).font(.callout).lineLimit(2)
                        }
                    }
                }
            } else {
                Text("文字起こしが終わると、ここに要点が並びます")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if !home.decisions.isEmpty {
                // 決定事項は別の節にせず 1 行で示す (同じ重さの塊を増やさない)
                Label {
                    Text("決定 \(home.decisions.count)件: \(home.decisions[0])").lineLimit(1)
                } icon: {
                    Image(systemName: Theme.icon(forSection: "決定事項")).foregroundStyle(Theme.accentText)
                }
                .font(.footnote)
            }

            NavigationLink(destination: destination) {
                Label(buttonLabel, systemImage: "sparkles")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.accent, in: .capsule)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }
}

/// 振り返りの本文を見出しごとのカードで表示する。見出しが無い本文はそのまま 1 枚にする。
struct ReflectionCards: View {
    let text: String
    /// 渡すと、節の項目を 1 行ずつ押して編集できる (節の番号, 項目の番号, 項目の文)。
    var onTapItem: ((Int, Int, String) -> Void)? = nil
    /// 押して編集させない節 (別の画面の一覧から作る節)。その節には編集できる場所の案内を出す。
    var lockedSections: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(ReflectionSections.parse(text).enumerated()), id: \.offset) { si, s in
                VStack(alignment: .leading, spacing: 8) {
                    if let title = s.title {
                        Label(title, systemImage: Theme.icon(forSection: title))
                            .font(.headline).foregroundStyle(Theme.accentText)
                    }
                    if let onTapItem, lockNote(s.title) == nil {
                        ForEach(Array(ReflectionSections.items(of: s).enumerated()), id: \.offset) { li, item in
                            Button { onTapItem(si, li, item) } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item).font(.callout).multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "pencil").font(.caption).foregroundStyle(.tertiary)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("押すと編集・削除できます")
                        }
                    } else {
                        Text(s.body).font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if onTapItem != nil, let note = lockNote(s.title) {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
            }
            // どこで要約したか (端末内・送信先の事業者) の開示。本文の節とは別に必ず出す
            if let label = ReflectionSections.routeLabel(in: text) {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }

    /// 見出しの付記の揺れ (「TODO・約束」など) を許して、編集させない節かを調べる。
    private func lockNote(_ title: String?) -> String? {
        guard let t = title?.lowercased() else { return nil }
        return lockedSections.first { t.hasPrefix($0.key.lowercased()) }?.value
    }
}

/// 振り返りの 1 項目を直す・消す画面。
struct ReflectionItemSheet: View {
    @State private var text: String
    var onSave: (String) -> Void
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(item: String, onSave: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        _text = State(initialValue: ReflectionSections.stripEditBullet(item))
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("内容", text: $text, axis: .vertical).lineLimit(2...10)
                } footer: {
                    Text("空にして保存すると削除します。振り返りを生成し直すと、編集した内容は新しい振り返りに置き換わります。")
                }
                Section {
                    Button(role: .destructive) { onDelete() } label: { Label("この項目を削除", systemImage: "trash") }
                }
            }
            .navigationTitle("振り返りを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { onSave(text) }.bold() }
            }
        }
    }
}

/// 完了・削除の直後に数秒出す「元に戻す」。
struct UndoBanner: View {
    @Binding var undo: TodoUndo?
    @ObservedObject private var store = TodoLedgerStore.shared

    var body: some View {
        if let u = undo {
            HStack {
                Text(u.message).font(.subheadline)
                Spacer()
                Button("元に戻す") {
                    withAnimation { store.undo(u.original, previous: u.previous, after: u.after) }
                    undo = nil
                }
                .font(.subheadline.bold())
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.regularMaterial, in: .capsule)
            .padding(.horizontal, 16).padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            // 操作が続いたら新しい記録に置き換わる。4 秒たって同じ記録のままなら消す
            .task(id: u) {
                try? await Task.sleep(for: .seconds(4))
                if undo == u { withAnimation { undo = nil } }
            }
        }
    }
}
