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

    /// 小さく録れた声は持ち上げて Whisper へ渡す (-30 dBFS の声が -6 dBFS 前後になる)。
    func testQuietAudioIsBoostedToTarget() {
        let amp: Float = 0.0316  // -30 dBFS
        let quiet = (0..<16_000).map { amp * sin(Float($0) * 2 * .pi * 300 / 16_000) }
        let g = AudioGain.gain(for: quiet)
        XCTAssertEqual(g, AudioGain.targetPeak / amp, accuracy: 1.0)
        let out = AudioGain.normalized(quiet)
        XCTAssertEqual(out.map(abs).max()!, AudioGain.targetPeak, accuracy: 0.02)
    }

    /// クリック音 1 回では倍率を決めない (大きな 1 サンプルがあっても、小さい声を持ち上げる)。
    func testSingleClickDoesNotBlockBoost() {
        var quiet = (0..<16_000).map { 0.01 * sin(Float($0) * 2 * .pi * 300 / 16_000) }
        quiet[500] = 0.9
        XCTAssertGreaterThan(AudioGain.gain(for: quiet), 20)
        // 持ち上げてもクリックは ±1 に収める
        XCTAssertLessThanOrEqual(AudioGain.normalized(quiet).map(abs).max()!, 1)
    }

    /// 十分な音量は下げない。雑音だけの録音も +30 dB を超えて持ち上げない。完全な無音はそのまま。
    func testGainBounds() {
        let loud = (0..<16_000).map { 0.8 * sin(Float($0) * 2 * .pi * 300 / 16_000) }
        XCTAssertEqual(AudioGain.gain(for: loud), 1)
        XCTAssertEqual(AudioGain.normalized(loud), loud)
        let faint = (0..<16_000).map { 0.0001 * sin(Float($0) * 2 * .pi * 300 / 16_000) }
        XCTAssertEqual(AudioGain.gain(for: faint), AudioGain.maxGain)
        XCTAssertEqual(AudioGain.gain(for: [Float](repeating: 0, count: 100)), 1)
        XCTAssertEqual(AudioGain.gain(for: []), 1)
    }

    /// 雑音から出た「以上で終わります。」だけの区間は捨て、会話の中の文は残す。
    func testClosingPhraseHallucinationIsRemoved() {
        XCTAssertEqual(TranscriptCleaner.clean([.init(text: "以上で終わります。")]), "")
        XCTAssertEqual(TranscriptCleaner.clean([.init(text: "今日の議題は以上で終わりますか")]), "今日の議題は以上で終わりますか")
    }

    /// 録音全体が小さくても、周りの雑音より 10 dB 以上大きい区間は声とみなす (袖の下の Watch で録った会話を捨てない)。
    func testQuietSpeechAboveNoiseFloorIsVoiced() {
        // 雑音 -72 dBFS が 9 分半、小さい声 -56 dBFS が 30 秒 (100ms 窓で 300 個)
        let windows = [Float](repeating: -72, count: 5_700) + [Float](repeating: -56, count: 300)
        XCTAssertEqual(AudioLevel.voicedWindows(windows), 300)
    }

    /// 雑音だけの録音は、多少の揺れがあっても声とみなさない。
    func testSteadyNoiseIsNotVoiced() {
        let windows = (0..<6_000).map { Float(-70 + ($0 % 7)) }  // -70〜-64 dBFS の揺れ
        XCTAssertEqual(AudioLevel.voicedWindows(windows), 0)
    }

    /// とても小さい区間 (-65 dBFS 以下) は、雑音より大きくても声とみなさない。完全な無音・空も 0。
    func testVeryFaintIsNotVoiced() {
        let windows = [Float](repeating: -120, count: 5_000) + [Float](repeating: -80, count: 1_000)
        XCTAssertEqual(AudioLevel.voicedWindows(windows), 0)
        XCTAssertEqual(AudioLevel.voicedWindows([]), 0)
    }

    /// 一定の大きな音 (雑音の基準と同じ大きさ) は、固定の閾値で声とみなす。
    func testLoudSteadySoundIsVoiced() {
        XCTAssertEqual(AudioLevel.voicedWindows([Float](repeating: -20, count: 50)), 50)
    }

    /// 雑音の中の一瞬の音 (0.2 秒以下の衣擦れ・足音) は、いくつあっても声と数えない。0.3 秒以上続けば数える。
    func testIsolatedBumpsAreNotVoiced() {
        var windows = [Float](repeating: -72, count: 6_000)
        for start in stride(from: 100, to: 5_900, by: 50) { windows[start] = -55; windows[start + 1] = -55 }
        XCTAssertEqual(AudioLevel.voicedWindows(windows), 0)
        windows[3_000] = -55; windows[3_001] = -55; windows[3_002] = -55
        XCTAssertEqual(AudioLevel.voicedWindows(windows), 3)
        // 録音の終わりまで続く声も数える
        var tail = [Float](repeating: -72, count: 100)
        tail += [Float](repeating: -56, count: 5)
        XCTAssertEqual(AudioLevel.voicedWindows(tail), 5)
    }
}
