import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject var recorder: WatchRecorder

    var body: some View {
        VStack(spacing: 8) {
            Text(recorder.isRecording ? "● 録音中" : "停止中")
                .font(.headline)
                .foregroundStyle(recorder.isRecording ? .red : .secondary)
            Text(recorder.elapsedText)
                .font(.system(.title2, design: .monospaced))
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
}
