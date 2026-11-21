import XCTest
import AVFoundation

final class TranscriptCleanerTests: XCTestCase {
    private func seg(_ t: String) -> TranscriptCleaner.Segment { .init(text: t) }

    /// 実機で起きた症状: 定型文だけの区間が続く。何も残さない (誤った要約や TODO を作らない)。
    func testRepeatedThanksForWatchingIsDropped() {
        let r = TranscriptCleaner.clean([
            seg("ご視聴ありがとうございましたありがとうございました。ご視聴ありがとうございました"),
            seg("ご視聴ありがとうございましたご視聴ありがとうございました"),
        ])
        // 「ありがとうございました」単体は定型文ではないので、混ざった区間は残す (会話を捨てない)
        XCTAssertEqual(r, "ご視聴ありがとうございましたありがとうございました。ご視聴ありがとうございました")
        XCTAssertEqual(TranscriptCleaner.clean([seg("ご視聴ありがとうございました。"), seg("ご視聴ありがとうございました")]), "")
    }

    /// 普通の 2 回の繰り返し (相づち) は残し、3 回以上続く繰り返しだけを 1 つにまとめる。
    func testOnlyLongRepeatsAreCollapsed() {
        XCTAssertEqual(TranscriptCleaner.clean([seg("はい"), seg("はい"), seg("では始めます")]), "はい\nはい\nでは始めます")
        XCTAssertEqual(TranscriptCleaner.clean([seg("あ"), seg("あ"), seg("あ"), seg("あ"), seg("終わり")]), "あ\n終わり")
    }

    /// 本物の会話の中の「ご視聴ありがとうございました」は残る (区間全体が定型文のときだけ捨てる)。
    func testRealSpeechContainingPhraseIsKept() {
        XCTAssertEqual(TranscriptCleaner.clean([seg("昨日の配信、ご視聴ありがとうございましたって言ってたね")]),
                       "昨日の配信、ご視聴ありがとうございましたって言ってたね")
    }

    /// 特殊トークンは取り除く。
    func testConsecutiveDuplicatesAndSpecialTokens() {
        let r = TranscriptCleaner.clean([seg("<|0.00|>資料を送ります<|2.00|>"), seg("よろしく")])
        XCTAssertEqual(r, "資料を送ります\nよろしく")
    }

    /// 無音の判定は声らしい時間で行う (クリック音 1 回の大きな最大音量では無音を覆さない)。
    func testSilenceUsesVoicedTimeNotPeak() {
        XCTAssertTrue(AudioLevel(duration: 600, peakDBFS: -3, voicedSeconds: 0.2).isSilent)
        XCTAssertFalse(AudioLevel(duration: 600, peakDBFS: -40, voicedSeconds: 3).isSilent)
    }

    /// ファイルから音量を測れる (録音側の書き出しと同じ形式)。
    func testMeasureReadsFileLevel() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        for (amp, silent) in [(Float(0), true), (Float(0.2), false)] {
            let w = ChunkWriter(directory: dir, chunkSeconds: 60, settings: settings) { _ in }
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            for _ in 0..<60 {
                let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4_096)!
                b.frameLength = 4_096
                for i in 0..<4_096 { b.floatChannelData![0][i] = amp * sin(Float(i) * 2 * .pi * 440 / 48_000) }
                try w.append(b)
            }
            let c = try XCTUnwrap(w.finish())
            let level = try XCTUnwrap(AudioLevel.measure(c.url))
            XCTAssertEqual(level.isSilent, silent, "amp \(amp): \(level.peakDBFS) dBFS, voiced \(level.voicedSeconds)s")
            XCTAssertEqual(level.duration, 5.12, accuracy: 0.2)
        }
    }

    /// Whisper に渡した書き方の手本が無音区間でそのまま出ても、文字起こしに残さない。
    func testPromptEchoIsRemoved() {
        let out = TranscriptCleaner.clean([.init(text: "以下は、日本語の会話の書き起こしです。"), .init(text: "明日の会議は十時からです。")])
        XCTAssertEqual(out, "明日の会議は十時からです。")
    }
}
