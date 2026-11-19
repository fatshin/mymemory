import Foundation
import FoundationModels

/// Foundation Models による端末内要約。通信も API キーも使わない。
/// 文脈上限 (4,096 トークン、日本語はおおむね 1 文字 1 トークン) のため、区間に分けて要約してから束ねる。
enum OnDeviceSummarizer {
    /// 1 区間の入力文字数。指示文と出力の分を残す。
    static let chunkChars = 1_800
    /// 束ねる段数の上限。長い日でも収まるよう段ごとに出力を短くする。
    static let maxLevels = 5

    enum Status: Equatable {
        case available
        case unavailable(String)
    }

    static var status: Status {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale(Locale(identifier: "ja_JP"))
                ? .available
                : .unavailable("端末内モデルが日本語に未対応")
        case .unavailable(.deviceNotEligible):
            return .unavailable("この端末は Apple Intelligence に未対応")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("設定で Apple Intelligence を有効にしてください")
        case .unavailable(.modelNotReady):
            return .unavailable("端末内モデルを準備中 (しばらく待って再試行)")
        case .unavailable:
            return .unavailable("端末内モデルを利用できません")
        }
    }

    static var isAvailable: Bool { status == .available }

    /// 一時的に使えないだけ (モデルのダウンロード中など)。この間は外部 API へ切り替えない。
    static var isPreparing: Bool {
        if case .unavailable(.modelNotReady) = SystemLanguageModel.default.availability { return true }
        return false
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 1 本の録音 (10 分程度) の要約。
    static func summarize(_ transcript: String) async throws -> String {
        try await mapReduce(
            transcript,
            chunkInstruction: "会話の文字起こしの一部。誤認識を考慮し、要点・決定事項・TODO を日本語の箇条書きで短くまとめる。推測は「推測」と明記する。",
            mergeInstruction: "同じ会話の部分要約の集まり。重複を除き、日本語で次の形式だけで出力する。【要点】の下に3〜5個、【決定事項】の下に決まったこと、【TODO】の下にやること(担当・期限が分かれば付記)を、それぞれ「- 」で始まる箇条書きで書く。該当がなければ「- なし」と書く。推測は「推測」と明記する。")
    }

    /// 1 日分 (録音ごとの要約を時刻付きで並べたもの) の振り返り。
    static func reflect(timeline: String) async throws -> String {
        try await mapReduce(
            timeline,
            chunkInstruction: "1日の音声ログの一部 (時刻付きの要約)。時刻を残して、出来事・決定・TODO を日本語の箇条書きで短くまとめる。",
            mergeInstruction: "1日の音声ログの部分まとめ。日本語で (1)1日の流れを時系列で簡潔に (2)重要な会話・決定 (3)TODO・約束 (4)気づき を出力する。推測は「推測」と明記する。")
    }

    /// 区間ごとに要約し、1 区間に収まるまで束ねる。
    /// 安全判定などで要約できない区間は飛ばし、全体を失敗にしない。
    private static func mapReduce(_ text: String, chunkInstruction: String, mergeInstruction: String) async throws -> String {
        guard isAvailable else {
            if case .unavailable(let reason) = status { throw Failure(message: reason) }
            throw Failure(message: "端末内モデルを利用できません")
        }
        var current = text
        for level in 0..<maxLevels {
            try Task.checkCancellation()
            let chunks = TextChunker.split(current, maxChars: chunkChars)
            if chunks.isEmpty { throw Failure(message: "要約する文字起こしがありません") }
            // 段を上がるほど出力を短くし、束ねた結果が次の段で 1 区間に収まるようにする
            let maxTokens = max(200, 700 - level * 120)
            // 拒否を要約として返すと保存されて二度と作り直されないため、例外にする
            if chunks.count == 1 {
                guard let s = try await respondSkippingRefusal(
                    instruction: mergeInstruction, input: chunks[0], maxTokens: 900) else {
                    throw Failure(message: "端末内モデルの安全判定により要約できませんでした")
                }
                return s
            }
            var parts: [String] = []
            var refused = 0
            for chunk in chunks {
                try Task.checkCancellation()
                if let s = try await respondSkippingRefusal(
                    instruction: chunkInstruction, input: chunk, maxTokens: maxTokens) {
                    parts.append(s)
                } else {
                    refused += 1
                    parts.append("(この区間は要約できませんでした)")
                }
            }
            if refused == chunks.count {
                throw Failure(message: "端末内モデルの安全判定により要約できませんでした")
            }
            current = parts.joined(separator: "\n")
        }
        throw Failure(message: "内容が長すぎて端末内で要約しきれませんでした")
    }

    /// 1 区間を新しいセッションで要約する。
    /// 上限超過なら半分に分けて 1 回だけ再試行し、安全判定・拒否なら nil を返す。
    private static func respondSkippingRefusal(instruction: String, input: String, maxTokens: Int) async throws -> String? {
        do {
            return try await respond(instruction: instruction, input: input, maxTokens: maxTokens)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                let half = TextChunker.split(input, maxChars: max(200, input.count / 2))
                var out: [String] = []
                for h in half {
                    try Task.checkCancellation()
                    do {
                        out.append(try await respond(instruction: instruction, input: h, maxTokens: maxTokens / 2))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // 半分でも収まらない・拒否された区間は飛ばす (他の区間の要約は残す)
                    }
                }
                return out.isEmpty ? nil : out.joined(separator: "\n")
            case .guardrailViolation, .refusal:
                return nil
            case .unsupportedLanguageOrLocale:
                throw Failure(message: "端末内モデルが日本語に未対応")
            case .assetsUnavailable:
                throw Failure(message: "端末内モデルを準備中 (しばらく待って再試行)")
            default:
                throw Failure(message: "端末内要約に失敗: \(error.localizedDescription)")
            }
        }
    }

    private static func respond(instruction: String, input: String, maxTokens: Int) async throws -> String {
        let session = LanguageModelSession(instructions: instruction)
        let response = try await session.respond(
            to: input,
            options: GenerationOptions(maximumResponseTokens: maxTokens))
        return response.content
    }
}
