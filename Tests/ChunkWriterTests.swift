import XCTest
import AVFoundation

/// Watch の録音を区切る部分。実機でしか起きないと見なされがちな 3 つの不具合
/// (サンプルレートの不一致、閉じる前の送信による壊れたファイル、区切りでの欠落) をここで固定する。
final class ChunkWriterTests: XCTestCase {
    private var dir: URL!
    private let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ]

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 48 kHz の正弦波 (マイク入力を想定)
    private func buffer(frames: AVAudioFrameCount, rate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        b.frameLength = frames
        let p = b.floatChannelData![0]
        for i in 0..<Int(frames) { p[i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / Float(rate)) }
        return b
    }

    func testRotatesByFrameCountAndProducesReadableFiles() throws {
        let box = ChunkBox()
        let writer = ChunkWriter(directory: dir, chunkSeconds: 1, settings: settings) { box.add($0) }
        // 4800 フレーム (0.1 秒) を 25 回 = 2.5 秒
        for _ in 0..<25 { try writer.append(buffer(frames: 4_800)) }
        if let last = writer.finish() { box.add(last) }

        let chunks = box.all
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.map(\.duration), [1.0, 1.0, 0.5])
        XCTAssertEqual(Set(chunks.map(\.url)).count, 3, "区間ごとに別ファイル")

        // 閉じたファイルは読み直せる (途中までのファイルではない)
        var total = 0.0
        for c in chunks {
            let f = try AVAudioFile(forReading: c.url)
            XCTAssertEqual(f.fileFormat.sampleRate, 16_000)
            total += Double(f.length) / f.fileFormat.sampleRate
        }
        XCTAssertEqual(total, 2.5, accuracy: 0.15, "区切りで音声が欠けない (AAC の前後の余白分だけ誤差を許す)")
    }

    /// 書き出した音声の中身が無音になっていない (長さだけでなく音量も残る)。
    /// 文字起こしが「ご視聴ありがとうございました」だけになる不具合の切り分け用: 変換で音が消えていないことを固定する。
    func testConvertedAudioKeepsSignalLevel() throws {
        for rate in [48_000.0, 16_000.0] {
            let box = ChunkBox()
            let writer = ChunkWriter(directory: dir, chunkSeconds: 60, settings: settings) { box.add($0) }
            // tap と同じ 4096 フレームずつ、10 秒以上
            let frames = AVAudioFrameCount(4_096)
            for _ in 0..<Int(rate * 10 / Double(frames)) { try writer.append(buffer(frames: frames, rate: rate)) }
            let chunk = try XCTUnwrap(writer.finish())
            let f = try AVAudioFile(forReading: chunk.url)
            let read = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)))
            try f.read(into: read)
            XCTAssertEqual(Double(read.frameLength) / f.processingFormat.sampleRate, 10, accuracy: 0.3, "rate \(rate)")
            let p = read.floatChannelData![0]
            var sum: Float = 0
            // AAC の先頭の余白を避けて中央 5 秒で測る
            let start = Int(f.processingFormat.sampleRate * 2.5), end = Int(f.processingFormat.sampleRate * 7.5)
            for i in start..<end { sum += p[i] * p[i] }
            let rms = (sum / Float(end - start)).squareRoot()
            // 振幅 0.2 の正弦波の RMS は約 0.141
            XCTAssertGreaterThan(rms, 0.1, "rate \(rate): 音量が消えている")
            try? FileManager.default.removeItem(at: chunk.url)
        }
    }

    /// 停止後に遅れて届いた入力で、新しいファイルを作らない (送られないまま残るため)。
    func testAppendAfterFinishIsIgnored() throws {
        let box = ChunkBox()
        let writer = ChunkWriter(directory: dir, chunkSeconds: 1, settings: settings) { box.add($0) }
        try writer.append(buffer(frames: 4_800))
        XCTAssertNotNil(writer.finish())
        try writer.append(buffer(frames: 4_800))
        XCTAssertNil(writer.finish())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 1)
    }

    func testFinishWithoutAudioReturnsNil() {
        let writer = ChunkWriter(directory: dir, chunkSeconds: 1, settings: settings) { _ in }
        XCTAssertNil(writer.finish())
    }

    func testBoundaryRule() {
        XCTAssertFalse(ChunkBoundary.shouldRotate(framesInChunk: 0, sampleRate: 48_000, chunkSeconds: 600))
        XCTAssertFalse(ChunkBoundary.shouldRotate(framesInChunk: 28_799_999, sampleRate: 48_000, chunkSeconds: 600))
        XCTAssertTrue(ChunkBoundary.shouldRotate(framesInChunk: 28_800_000, sampleRate: 48_000, chunkSeconds: 600))
    }
}

private final class ChunkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [FinishedChunk] = []
    func add(_ c: FinishedChunk) { lock.lock(); items.append(c); lock.unlock() }
    var all: [FinishedChunk] { lock.lock(); defer { lock.unlock() }; return items }
}
