import Foundation
import AVFoundation

/// 書き終えた 1 区間。送信は呼び出し側が行う (ファイルは閉じた後なので、そのまま送ってよい)。
struct FinishedChunk: Sendable, Equatable {
    let url: URL
    let startedAt: Date
    let duration: TimeInterval
}

/// 区切りの判定。入力のフレーム数で数えるため、タイマーとスレッドの競合が起きない。
enum ChunkBoundary {
    static func shouldRotate(framesInChunk: AVAudioFramePosition, sampleRate: Double, chunkSeconds: TimeInterval) -> Bool {
        framesInChunk > 0 && Double(framesInChunk) >= sampleRate * chunkSeconds
    }
}

/// マイク入力 (tap) を区間ごとの m4a に書く。録音エンジンは止めず、書き込み先だけを切り替える。
/// watchOS ではバックグラウンドで録音を再開できないため (Apple の回答)、区切りで録音を止めない。
/// tap のスレッドから呼ばれるため、状態はすべてロックで守る。
final class ChunkWriter: @unchecked Sendable {
    enum WriterError: LocalizedError {
        case converterUnavailable
        case conversionFailed(String)
        var errorDescription: String? {
            switch self {
            case .converterUnavailable: return "音声形式の変換を準備できません"
            case .conversionFailed(let m): return "音声形式の変換に失敗: \(m)"
            }
        }
    }

    private let lock = NSLock()
    private let directory: URL
    private let chunkSeconds: TimeInterval
    private let settings: [String: Any]
    private let now: @Sendable () -> Date
    private let onChunk: @Sendable (FinishedChunk) -> Void

    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var framesInChunk: AVAudioFramePosition = 0
    private var inputRate: Double = 0
    private var chunkStart = Date()
    /// 停止後に届いた tap の残りで新しいファイルを開かないための印。
    private var sealed = false

    /// - Parameters:
    ///   - onChunk: 区切りで閉じた区間を渡す。tap のスレッドから呼ばれる。
    init(directory: URL, chunkSeconds: TimeInterval, settings: [String: Any],
         now: @escaping @Sendable () -> Date = { Date() },
         onChunk: @escaping @Sendable (FinishedChunk) -> Void) {
        self.directory = directory
        self.chunkSeconds = chunkSeconds
        self.settings = settings
        self.now = now
        self.onChunk = onChunk
    }

    /// 入力を書き込む。区切りに達していれば、先に今の区間を閉じて次の区間を始める。
    func append(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock(); defer { lock.unlock() }
        guard !sealed else { return }
        let rate = buffer.format.sampleRate
        if file != nil, ChunkBoundary.shouldRotate(framesInChunk: framesInChunk, sampleRate: inputRate,
                                                   chunkSeconds: chunkSeconds) {
            if let done = closeLocked() { onChunk(done) }
        }
        if file == nil { try openLocked(inputRate: rate) }
        guard let file else { return }
        let out = try convertLocked(buffer, to: file.processingFormat)
        try file.write(from: out)
        framesInChunk += AVAudioFramePosition(buffer.frameLength)
    }

    /// 書き込み中のファイル名。書いていなければ nil。
    var currentFileName: String? {
        lock.lock(); defer { lock.unlock() }
        return file?.url.lastPathComponent
    }

    /// 今の区間を閉じて返す (停止・中断時)。以後の書き込みは無視する。書き込みが無ければ nil。
    func finish() -> FinishedChunk? {
        lock.lock(); defer { lock.unlock() }
        sealed = true
        return closeLocked()
    }

    // MARK: - ロック内でだけ呼ぶ

    private func openLocked(inputRate: Double) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let start = now()
        // 同じ秒に区切りが重なっても上書きしないよう、ミリ秒まで付ける
        let url = directory.appendingPathComponent("chunk-\(Int(start.timeIntervalSince1970 * 1000)).m4a")
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
        self.inputRate = inputRate
        framesInChunk = 0
        chunkStart = start
    }

    private func closeLocked() -> FinishedChunk? {
        guard let f = file else { return nil }
        let url = f.url
        let frames = framesInChunk
        // AAC の m4a は閉じたときに完成する。閉じる前に送ると途中までのファイルになる
        f.close()
        file = nil
        framesInChunk = 0
        guard frames > 0, inputRate > 0 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return FinishedChunk(url: url, startedAt: chunkStart, duration: Double(frames) / inputRate)
    }

    /// マイクの形式 (例: 48 kHz) をファイルの形式 (16 kHz・モノラル) に変換する。
    private func convertLocked(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        if converter == nil || converterInput != buffer.format {
            guard let c = AVAudioConverter(from: buffer.format, to: format) else { throw WriterError.converterUnavailable }
            converter = c
            converterInput = buffer.format
        }
        guard let converter else { throw WriterError.converterUnavailable }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw WriterError.converterUnavailable
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                // 続きのデータはまだ無い (次の tap で来る)。変換器の内部状態は保ったまま返す
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw WriterError.conversionFailed(error?.localizedDescription ?? "unknown") }
        return out
    }
}
