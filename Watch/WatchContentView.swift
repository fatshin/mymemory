import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject var recorder: WatchRecorder
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(WatchRecorder.autoStartKey) private var autoStart = true

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(statusText)
                    .font(.headline)
                    .foregroundStyle(recorder.isRecording ? .red : (recorder.isPaused ? .orange : .secondary))
                // 画面点灯中だけ1秒更新。消灯・低頻度時は描画しない。
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsedText(at: context.date))
                        .font(.system(.title2, design: .monospaced))
                }
                if recorder.isPaused {
                    Button("再開") { recorder.resume() }
                        .tint(.green)
                    Button("停止") { recorder.userStop() }
                        .tint(.red)
                } else {
                    Button(recorder.isRecording ? "停止" : "開始") {
                        recorder.isRecording ? recorder.userStop() : recorder.start()
                    }
                    .tint(recorder.isRecording ? .red : .green)
                }
                // 実機確認用の記録: 送った区間数・未送信・最後に送った時刻
                Text("送信 \(recorder.chunkCount) / 未送信 \(recorder.pendingTransfers)")
                    .font(.caption2)
                if let at = recorder.lastChunkAt {
                    Text("最終送信 \(at.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let err = recorder.lastError {
                    Text(err).font(.caption2).foregroundStyle(.orange)
                }
                Toggle("開いたら自動で録音", isOn: $autoStart)
                    .font(.caption2)
                Text("停止ボタンで止めた日は、開いても自動では始めません")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        // initial: true で起動直後 (OS に終了されたあとの再起動を含む) にも判定する
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            recorder.checkEngine()  // 中断からの再開を先に試す
            recorder.autoStartIfNeeded()
        }
    }

    private var statusText: String {
        if recorder.isRecording { return "● 録音中" }
        if recorder.isPaused { return "一時停止中" }
        return "停止中"
    }

    private func elapsedText(at now: Date) -> String {
        guard let start = recorder.sessionStart else { return "00:00:00" }
        let e = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", e / 3600, (e % 3600) / 60, e % 60)
    }
}
