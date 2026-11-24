import Foundation
import AVFoundation

/// 音声ファイルの長さ・最大音量・声らしい時間。無音の判定と、実機での切り分け (詳細画面の表示) に使う。
struct AudioLevel: Equatable, Sendable {
    let duration: TimeInterval
    /// 最大振幅 (dBFS)。完全な無音は -120。表示用 (クリック音 1 回でも上がるため判定には使わない)。
    let peakDBFS: Float
    /// 100ms ごとの RMS が `voicedThresholdDBFS` を超えた時間の合計 (秒)。
    let voicedSeconds: TimeInterval

    /// 100ms の RMS がこれを超えれば、声 (または何かの音) がある区間とみなす。静かな場所の小声を捨てないよう低めにとる。
    static let voicedThresholdDBFS: Float = -50
    /// 録音全体が小さい (Watch が袖の下・離れた所にある) ときは、周りの雑音より `aboveFloorDB` 大きい区間も声とみなす。
    /// 雑音の大きさは 100ms ごとの RMS の下から `floorQuantile` の位置。これより小さい区間は声とみなさない (`minVoicedDBFS`)。
    static let aboveFloorDB: Float = 10
    static let floorQuantile = 0.2
    static let minVoicedDBFS: Float = -65
    /// 雑音との差だけで声とみなすのは、この数以上続いた窓だけ (衣擦れ・足音・ドアのような一瞬の音を声と数えない)。
    static let minRelativeRun = 3
    /// 声らしい時間がこれ未満なら無音とみなし、文字起こしをしない
    /// (WhisperKit 0.18.0 は「発話なし」の確率を計算せず常に 0 のため、無音から定型文を作る。電力も使わない)。
    static let minVoicedSeconds: TimeInterval = 1.0

    var isSilent: Bool { voicedSeconds < Self.minVoicedSeconds }

    static func dbfs(peak: Float) -> Float { peak > 0 ? max(-120, 20 * log10(peak)) : -120 }

    /// 声らしい区間の数。窓ごとの RMS (dBFS) を受け取り、固定の閾値か、雑音より十分大きい区間を数える。
    static func voicedWindows(_ rmsDB: [Float]) -> Int {
        guard !rmsDB.isEmpty else { return 0 }
        let floor = rmsDB.sorted()[min(rmsDB.count - 1, Int(Double(rmsDB.count) * floorQuantile))]
        let relative = max(minVoicedDBFS, floor + aboveFloorDB)
        var count = 0, run = 0
        for v in rmsDB + [-Float.infinity] {  // 末尾の番兵で最後の連続を締める
            if v > voicedThresholdDBFS {
                count += 1
                if run >= minRelativeRun { count += run }
                run = 0
            } else if v > relative {
                run += 1
            } else {
                if run >= minRelativeRun { count += run }
                run = 0
            }
        }
        return count
    }

    /// ファイルを 100ms ずつ読んで、最大振幅と声らしい時間を求める。読めなければ nil。
    static func measure(_ url: URL) -> AudioLevel? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let format = f.processingFormat
        let window = AVAudioFrameCount(max(1, format.sampleRate / 10))
        guard format.sampleRate > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: window) else { return nil }
        var peak: Float = 0
        var rmsDB: [Float] = []
        var frames: [Int] = []
        while f.framePosition < f.length {
            do { try f.read(into: buf, frameCount: window) } catch { break }
            let n = Int(buf.frameLength)
            guard n > 0, let data = buf.floatChannelData else { break }
            let p = data[0]  // 録音はモノラル。複数チャンネルでも先頭で判定する
            var sum: Float = 0
            for i in 0..<n { let v = p[i]; peak = max(peak, abs(v)); sum += v * v }
            rmsDB.append(dbfs(peak: (sum / Float(n)).squareRoot()))
            frames.append(n)
        }
        // 窓はほぼ同じ長さ (最後だけ短い) のため、声らしい窓の数に窓の長さを掛けて秒にする
        let voiced = voicedWindows(rmsDB)
        let perWindow = frames.isEmpty ? 0 : Double(frames.reduce(0, +)) / Double(frames.count)
        return AudioLevel(duration: Double(f.length) / format.sampleRate, peakDBFS: dbfs(peak: peak),
                          voicedSeconds: Double(voiced) * perWindow / format.sampleRate)
    }
}

/// Whisper へ渡す前に、小さく録れた音声を持ち上げる。Watch を袖の下や離れた所に置くと声が小さく録れ、
/// そのままでは Whisper が言葉として認識できない (最大 -18 dBFS 程度でも空の結果になる)。
/// 最大振幅はクリック音 1 回で決まるため、上位 0.1% を除いた振幅を基準にする。持ち上げるだけで下げない。
enum AudioGain {
    /// 持ち上げた後の基準振幅 (-6 dBFS)。
    static let targetPeak: Float = 0.5
    /// 持ち上げの上限 (+30 dB)。雑音だけの録音を際限なく大きくしない。
    static let maxGain: Float = 31.6
    /// 基準にする振幅の位置 (大きい方から 0.1% を外れ値として除く)。
    static let robustQuantile = 0.999

    /// 掛ける倍率 (1 以上 maxGain 以下)。完全な無音は 1。
    static func gain(for samples: [Float]) -> Float {
        let peak = robustPeak(samples)
        guard peak > 0 else { return 1 }
        return min(maxGain, max(1, targetPeak / peak))
    }

    /// 倍率を掛けて ±1 に収めた音声。倍率が 1 なら元のまま返す。
    static func normalized(_ samples: [Float]) -> [Float] {
        let g = gain(for: samples)
        guard g > 1 else { return samples }
        return samples.map { max(-1, min(1, $0 * g)) }
    }

    /// 振幅の上位 (1 - robustQuantile) を除いた最大値。0.1 dB 刻みの度数分布で求める (並べ替えない)。
    static func robustPeak(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let bins = 1_200  // -120 dB から 0 dB まで
        var hist = [Int](repeating: 0, count: bins)
        for v in samples {
            let a = abs(v)
            guard a > 0 else { continue }
            let db = 20 * log10(min(a, 1))
            hist[max(0, min(bins - 1, Int((db + 120) * 10)))] += 1
        }
        var above = Int(Double(samples.count) * (1 - robustQuantile))
        for i in stride(from: bins - 1, through: 0, by: -1) {
            above -= hist[i]
            if above < 0 { return pow(10, (Float(i) / 10 - 120) / 20) }
        }
        return 0
    }
}

/// Whisper の出力から、無音や雑音から作られた定型文を取り除く。
enum TranscriptCleaner {
    /// 注意: WhisperKit 0.18.0 は区間の「発話なし」の確率を計算せず常に 0 を返す (TextDecoder.swift の TODO)。
    /// そのため区間の判定には使わず、文面だけで判断する。
    struct Segment: Equatable {
        let text: String
    }

    /// 同じ文がこの回数以上続いたら 1 つにまとめる (「はい」「はい」のような普通の繰り返しは残す)。
    static let repeatCollapseCount = 3

    /// 無音・雑音から作られやすい定型文 (動画の字幕に多い言い回し)。区間がこれだけでできているときに限って捨てる。
    static let hallucinations = [
        "ご視聴ありがとうございました", "ご視聴ありがとうございます",
        "チャンネル登録よろしくお願いします", "チャンネル登録お願いします", "チャンネル登録をお願いします",
        "高評価よろしくお願いします", "次の動画でお会いしましょう", "最後までご視聴いただきありがとうございました",
        // Whisper に渡す書き方の手本 (Transcriber.promptText)。無音区間で手本をそのまま出すことがある
        "以下は日本語の会話の書き起こしです",
        // 雑音だけの区間から出た実例 (2026-11-23 の録音)
        "以上で終わります",
    ]

    static func clean(_ segments: [Segment]) -> String {
        let texts = segments
            .map { stripSpecialTokens($0.text).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isOnlyHallucination($0) }
        // 同じ文が 3 回以上続く部分 (無音・雑音での繰り返し) だけを 1 つにまとめる
        var out: [String] = []
        var i = 0
        while i < texts.count {
            var j = i
            while j + 1 < texts.count, texts[j + 1] == texts[i] { j += 1 }
            let run = j - i + 1
            out.append(contentsOf: run >= repeatCollapseCount ? [texts[i]] : Array(texts[i...j]))
            i = j + 1
        }
        return out.joined(separator: "\n")
    }

    private static func stripSpecialTokens(_ s: String) -> String {
        s.replacingOccurrences(of: #"<\|[^|>]*\|>"#, with: "", options: .regularExpression)
    }

    /// 句読点と空白を除き、定型文をすべて取り除いた残りが空なら true。
    static func isOnlyHallucination(_ s: String) -> Bool {
        var t = s
        for ch in ["。", "、", "！", "!", "？", "?", "・", " ", "　", ".", ","] { t = t.replacingOccurrences(of: ch, with: "") }
        guard !t.isEmpty else { return true }
        // 長い言い回しから先に除く (短い方が長い方の一部を食わないように)
        for h in hallucinations.sorted(by: { $0.count > $1.count }) { t = t.replacingOccurrences(of: h, with: "") }
        return t.isEmpty
    }
}
