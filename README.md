# MyMemory

Apple Watch で録音 → iPhone で端末内の文字起こし (日本語, WhisperKit) → 端末内の要約 (Foundation Models)。外部 API での要約は、利用者が設定で許可したときだけ使う。

## 構成
- `Watch/` : 録音 (AVAudioEngine を止めずに 10 分ごとにファイルを切り替え、`UIBackgroundModes: audio` で画面消灯中も継続) → WatchConnectivity 転送
- `iOS/`   : 受信 → SwiftData 保存 → WhisperKit 文字起こし → 要約 (既定は端末内。設定と要約のたびに端末内か外部 API かを選べる。外部 API は明示的な許可 + 疎通確認済みの API キーがあるときだけ、テキストのみ送信)。決定事項・TODO の一覧 (要約から抽出)、書き出し (Markdown)、初回同意、古い音声の自動削除 (任意)
- `Shared/`: 転送メタデータキー、録音の区切り (`ChunkWriter`)
- `project.yml`: XcodeGen 定義

## セットアップ (Mac)
```bash
brew install xcodegen
xcodegen generate
open MyMemory.xcodeproj
```
Signing Team を両ターゲットに設定。HealthKit は使わない。実機 (iPhone + Watch) で実行。iOS は 26.0 以上 (端末内要約に Foundation Models を使うため)。

## Phase 0: Go/No-Go PoC (最優先)
Watch単体で8時間録音を実測:
1. 電池消費 (各チャンク終了時の `batteryLevel` をチャンクメタに記録。Watch 起動時に電池監視を有効化)
2. バックグラウンドでの中断有無 (隣り合うチャンクの `startedAt + duration` と次の `startedAt` が5秒超ずれたら欠番。`chunkCount` は録音開始のたびに0へ戻るため使わない)
3. 画面消灯・手首下ろし状態での継続
4. iPhone圏外時のキュー転送 → 復帰後の再送

NoGo条件: 8時間で欠番あり、または電池消費 > 60%。その場合は会議単位(手動開始)運用に縮小。

## 未検証 / 既知の未確認
- Xcode 27.2 で iOS Simulator 向けビルド (Watch 含む) と単体テストは成功。**実機 (iPhone + Watch) での検証は未実施**。CI は `macos-26` (Xcode 26.6) で未確認。
- WhisperKit は 0.18.0 に固定 (`project.yml`)。モデル名 (`Pipeline.modelName`)、API シグネチャはバージョン依存。1.x への移行は破壊的変更を伴う。
- Watch のバックグラウンド録音は、前面で利用者が開始した録音を `audio` のバックグラウンド実行で継続する方式。Apple の公式ドキュメントでは watchOS の `audio` は再生用と書かれており、録音の継続は実機で確認が必要。中断 (着信・Siri)・経路の変化の後は自動で再開を試す (10 分に 5 回まで。バックグラウンドで開始を拒否されたら、画面を開いたときに再開するか、タップで再開)。
- 端末内要約は Apple Intelligence 対応端末のみ。日本語の要約品質は未計測。
- WhisperKit 0.18.0 は区間の「発話なし」の確率を計算しない (常に 0)。無音から「ご視聴ありがとうございました」などの定型文が出るため、文字起こしの前に音量で無音を判定して飛ばし (声らしい時間が 1 秒未満)、定型文だけの区間と 3 回以上の繰り返しを取り除く (`iOS/TranscriptCleaner.swift`)。詳細画面に音声の長さ・声らしい時間・最大音量と、音声ファイルの共有ボタンがある (実機での切り分け用)。
- 話者分離未実装。
- 録音の同意: 初回起動時に周りの人への配慮を案内する。法的な運用ルールは利用者の責任。

## 省電力の方針
- Watch: タイマーを使わず、入力のフレーム数で 10 分ごとに区切る。電池 10% 未満 (非充電) で最終チャンクを送信して停止。
- iPhone: 文字起こしは充電中、または低電力モードOFFかつ残量50%以上のときだけ実行。外部電源接続中に OS が起動するバックグラウンド処理でも実行。
- iPhone: 充電待ちで保留中は、一覧の「今すぐ文字起こし」で利用者が明示的に実行できる (残量20%以上なら低電力モードでも可)。iOS 26 の継続タスク (`BGContinuedProcessingTask`) として申請するため、画面を閉じても続く。申請できないときは理由を表示し、画面を開いたまま処理する。背景では GPU を使えないため、メル計算だけ CPU に固定している (`Transcriber.computeOptions`)。実機での継続動作は未確認。
- 詳細・根拠・未検証事項は `specs/features/power-saving/plan.md` (ローカル保持)。

## 課金
- 無料。アプリ内課金はなく、文字起こしの時間制限もない。
- プライバシーポリシー: https://fatshin.github.io/mymemory-legal/

## TestFlight
GitHub Secrets に `TEAM_ID` / `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_P8_BASE64` を登録し、Actions の `TestFlight` を手動実行する。ビルド番号は実行番号で自動採番。
