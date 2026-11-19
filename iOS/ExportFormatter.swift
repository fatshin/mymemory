import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// 書き出し 1 件分。SwiftData のモデルに依存させず、単体テストできるようにする。
struct ExportEntry: Equatable {
    let startedAt: Date
    let duration: TimeInterval
    let summary: String?
    let transcript: String?
}

/// 1 日分・1 録音分を Markdown にする。メモアプリやファイルにそのまま渡せる形にする。
enum ExportFormatter {
    static func day(_ day: Date, entries: [ExportEntry], reflection: String?,
                    locale: Locale = Locale(identifier: "ja_JP"), timeZone: TimeZone = .current) -> String {
        let dateStyle = Date.FormatStyle(date: .complete, time: .omitted, locale: locale, timeZone: timeZone)
        var out = "# \(day.formatted(dateStyle))\n"
        if let reflection, !reflection.isEmpty {
            out += "\n## 振り返り\n\n\(reflection)\n"
        }
        for e in entries.sorted(by: { $0.startedAt < $1.startedAt }) {
            out += "\n" + section(e, level: 2, locale: locale, timeZone: timeZone)
        }
        return out
    }

    static func recording(_ e: ExportEntry,
                          locale: Locale = Locale(identifier: "ja_JP"), timeZone: TimeZone = .current) -> String {
        section(e, level: 1, locale: locale, timeZone: timeZone, withDate: true)
    }

    private static func section(_ e: ExportEntry, level: Int, locale: Locale, timeZone: TimeZone,
                                withDate: Bool = false) -> String {
        let style = Date.FormatStyle(date: withDate ? .numeric : .omitted, time: .shortened,
                                     locale: locale, timeZone: timeZone)
        let h = String(repeating: "#", count: level)
        let minutes = max(0, Int((e.duration / 60).rounded()))
        var out = "\(h) \(e.startedAt.formatted(style)) (\(minutes)分)\n"
        if let s = e.summary, !s.isEmpty { out += "\n\(h)# 要約\n\n\(s)\n" }
        if let t = e.transcript, !t.isEmpty { out += "\n\(h)# 文字起こし\n\n\(t)\n" }
        if (e.summary ?? "").isEmpty && (e.transcript ?? "").isEmpty { out += "\n(文字起こしなし)\n" }
        return out
    }

    /// ファイル名に使えない文字を除く。
    static func fileName(for day: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: day)
        return String(format: "MyMemory-%04d-%02d-%02d.md", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// 共有シートへ .md ファイルとして渡す (長い 1 日分でもファイルやメモに保存しやすい)。
struct MarkdownFile: Transferable {
    let name: String
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { file in
            try? FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            let url = exportDirectory.appendingPathComponent(file.name)
            try Data(file.text.utf8).write(to: url, options: [.atomic, .completeFileProtection])
            return SentTransferredFile(url)
        }
        .suggestedFileName { $0.name }
    }

    /// 書き出し用の一時フォルダ。文字起こしの平文が残らないよう、起動時に消す。
    static var exportDirectory: URL { URL.temporaryDirectory.appendingPathComponent("Export", isDirectory: true) }

    static func removeLeftovers() {
        try? FileManager.default.removeItem(at: exportDirectory)
    }
}
