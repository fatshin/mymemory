import AVFoundation
import Foundation
import Speech

/// 文字起こしに使う仕組み。既定は iOS 標準の音声認識 (認識データは iOS が管理し、アプリの更新で消えない)。
enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case apple
    case whisper

    var id: String { rawValue }
    static let key = "transcriptionEngine"

    static var current: TranscriptionEngine {
        get { TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .apple }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var displayName: String {
        switch self {
        case .apple: return "iOS 標準 (認識データは iOS が管理)"
        case .whisper: return "Whisper (約630MBのモデル)"
        }
    }
}

/// iOS 標準の音声認識 (SpeechAnalyzer + SpeechTranscriber) で、端末内で文字起こしする。
enum AppleSpeech {
    /// 日本語に対応していない、または認識データを入れられない。呼び出し側は Whisper に切り替える。
    struct Unavailable: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let locale = Locale(identifier: "ja-JP")
    /// 認識データを一度でも入れられたか (背景処理で通信を要求するかの判断に使う)。
    static let installedKey = "appleSpeechInstalled"
    static var installedOnce: Bool { UserDefaults.standard.bool(forKey: installedKey) }
    /// 1 回に渡す音声の長さ (秒)。
    private static let chunkSeconds = 10.0

    /// 日本語の文字起こしの部品。認識データが無ければ iOS に入れてもらう (初回だけ通信する)。
    static func makeTranscriber() async throws -> SpeechTranscriber {
        guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Unavailable(message: "この端末の iOS 標準の音声認識は日本語に対応していません")
        }
        let module = SpeechTranscriber(locale: loc, preset: .transcription)
        let status = await AssetInventory.status(forModules: [module])
        // 対応していなければ保留にせず Whisper へ切り替えさせる (取得を試しても失敗が続くだけ)
        if status == .unsupported { throw Unavailable(message: "この端末の iOS 標準の音声認識は日本語の文字起こしに対応していません") }
        if status != .installed {
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try await request.downloadAndInstall()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ModelLoadError(underlying: "iOS 標準の音声認識データを入れられません: \(error.localizedDescription)")
            }
        }
        UserDefaults.standard.set(true, forKey: installedKey)
        return module
    }

    /// 16kHz・モノラルの音声を文字起こしする。確定した文を、出てきた順に改行でつなぐ。
    /// - Parameter onSeconds: 確定した文の終わりの位置 (秒)。進み具合の表示に使う。
    static func transcribe(samples: [Float], sampleRate: Double = 16_000, module: SpeechTranscriber,
                           onSeconds: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw Unavailable(message: "iOS 標準の音声認識に渡す音声の形式を決められません")
        }
        let inputs = try buffers(samples, sampleRate: sampleRate, to: target).map { AnalyzerInput(buffer: $0) }
        let analyzer = SpeechAnalyzer(modules: [module])
        // 結果は解析と並行して受け取る。受け取り口は解析を始める前に取っておく (取りこぼさないように)
        let results = module.results
        let collector = Task { () throws -> [String] in
            var parts: [String] = []
            for try await r in results where r.isFinal {
                let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { parts.append(text) }
                onSeconds?(r.range.end.seconds)
            }
            return parts
        }
        do {
            let stream = AsyncStream<AnalyzerInput> { c in
                for i in inputs { c.yield(i) }
                c.finish()
            }
            if let last = try await analyzer.analyzeSequence(stream) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        try Task.checkCancellation()
        return try await collector.value.joined(separator: "\n")
    }

    /// 音声を区切り、認識に渡す形式へ変換する。
    private static func buffers(_ samples: [Float], sampleRate: Double, to target: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw Unavailable(message: "音声の形式を変換できません")
        }
        let step = Int(sampleRate * chunkSeconds)
        var out: [AVAudioPCMBuffer] = []
        var start = 0
        while start < samples.count {
            try Task.checkCancellation()
            let n = min(step, samples.count - start)
            guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(n)) else { break }
            input.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { p in
                input.floatChannelData![0].update(from: p.baseAddress! + start, count: n)
            }
            let isLast = start + n >= samples.count
            let capacity = AVAudioFrameCount(Double(n) * target.sampleRate / sampleRate) + 4_096
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { break }
            var fed = false
            var error: NSError?
            // 区切りの間は変換の状態を引き継ぎ、最後だけ終わりを伝えて残りを出し切る
            let status = converter.convert(to: output, error: &error) { _, status in
                if fed { status.pointee = isLast ? .endOfStream : .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return input
            }
            if let error { throw error }
            if status == .error { throw Unavailable(message: "音声の形式を変換できません") }
            if output.frameLength > 0 { out.append(output) }
            start += n
        }
        return out
    }
}
