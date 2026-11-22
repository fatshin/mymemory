import Foundation

/// 端末内モデルの文脈上限 (日本語はおおむね 1 文字 1 トークン) に収まるよう、文章を区間に分ける。
/// 純粋関数にして単体テストする。
enum TextChunker {
    /// 改行を優先して区切り、1 区間が `maxChars` 文字を超えないように分ける。
    /// 改行が無い長い行は文字数で切る。空白だけの区間は返さない。
    static func split(_ text: String, maxChars: Int) -> [String] {
        precondition(maxChars > 0, "maxChars must be positive")
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Substring(line)
            while rest.count > maxChars {
                flush(&current, into: &chunks)
                let cut = rest.index(rest.startIndex, offsetBy: maxChars)
                append(String(rest[..<cut]), into: &chunks)
                rest = rest[cut...]
            }
            let piece = String(rest)
            let needed = current.isEmpty ? piece.count : current.count + 1 + piece.count
            if needed > maxChars { flush(&current, into: &chunks) }
            current = current.isEmpty ? piece : current + "\n" + piece
        }
        flush(&current, into: &chunks)
        return chunks
    }

    private static func flush(_ current: inout String, into chunks: inout [String]) {
        append(current, into: &chunks)
        current = ""
    }

    private static func append(_ piece: String, into chunks: inout [String]) {
        if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chunks.append(piece) }
    }
}

/// 要約をどこで実行するか。設定で選んだ経路を使い、使えなければもう一方を使う (外部 API は利用者のキーと送信の許可が要る)。
enum SummaryRoute: String, Equatable, CaseIterable {
    case onDevice
    case remote

    /// 利用者が選んだ経路が使えればそれを、使えなければもう一方を選ぶ。
    /// 外部 API は、キーがあり、かつ利用者が送信を明示的に許可したときだけ使える (審査ガイドライン 5.1.2(i))。
    /// どちらも使えなければ nil (呼び出し側が理由を表示する)。
    static func choose(preferred: SummaryRoute, onDeviceAvailable: Bool, hasAPIKey: Bool, remoteAllowed: Bool) -> SummaryRoute? {
        let usable = usableRoutes(onDeviceAvailable: onDeviceAvailable, hasAPIKey: hasAPIKey, remoteAllowed: remoteAllowed)
        return usable.contains(preferred) ? preferred : usable.first
    }

    /// 今使える経路 (端末内が先)。
    static func usableRoutes(onDeviceAvailable: Bool, hasAPIKey: Bool, remoteAllowed: Bool) -> [SummaryRoute] {
        (onDeviceAvailable ? [.onDevice] : []) + (hasAPIKey && remoteAllowed ? [.remote] : [])
    }
}
