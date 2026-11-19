import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject var recorder: WatchRecorder

    var body: some View {
        VStack(spacing: 8) {
            Text(recorder.isRecording ? "● 録音中" : "停止中")
                .font(.headline)
                .foregroundStyle(recorder.isRecording ? .red : .secondary)
            // 画面点灯中だけ1秒更新。消灯・低頻度時は描画しない。
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(elapsedText(at: context.date))
                    .font(.system(.title2, design: .monospaced))
            }
            Text("チャンク \(recorder.chunkCount) / 未送信 \(recorder.pendingTransfers)")
                .font(.caption2)
            Button(recorder.isRecording ? "停止" : "開始") {
                recorder.isRecording ? recorder.stop() : recorder.start()
            }
            .tint(recorder.isRecording ? .red : .green)
            if let err = recorder.lastError {
                Text(err).font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private func elapsedText(at now: Date) -> String {
        guard let start = recorder.sessionStart else { return "00:00:00" }
        let e = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", e / 3600, (e % 3600) / 60, e % 60)
    }
}
