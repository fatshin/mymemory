# MyMemory

Apple Watch で録音 → iPhone で端末内の文字起こし (日本語, WhisperKit) → 端末内の要約 (Foundation Models)。外部 API での要約は、利用者が設定で許可したときだけ使う。

## 構成
- `Watch/` : 録音 (AVAudioEngine を止めずに 10 分ごとにファイルを切り替え、`UIBackgroundModes: audio` で画面消灯中も継続) → WatchConnectivity 転送
- `iOS/`   : 受信 → SwiftData 保存 → WhisperKit 文字起こし → 要約 (端末内を優先。外部 API は明示的な許可 + API キーがあるときだけ、テキストのみ送信)。決定事項・TODO の一覧 (要約から抽出)、書き出し (Markdown)、初回同意、課金 (StoreKit 2)、古い音声の自動削除 (任意)
- `Shared/`: 転送メタデータキー、録音の区切り (`ChunkWriter`)
- `StoreKit/MyMemory.storekit`: シミュレータで購入を試すためのローカル設定
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
- 話者分離未実装。
- 録音の同意: 初回起動時に周りの人への配慮を案内する。法的な運用ルールは利用者の責任。

## 省電力の方針
- Watch: タイマーを使わず、入力のフレーム数で 10 分ごとに区切る。電池 10% 未満 (非充電) で最終チャンクを送信して停止。
- iPhone: 文字起こしは充電中、または低電力モードOFFかつ残量50%以上のときだけ実行。外部電源接続中に OS が起動するバックグラウンド処理でも実行。
- 詳細・根拠・未検証事項は `specs/features/power-saving/plan.md` (ローカル保持)。

## 課金
- 月額サブスクリプション `com.fatshin.mymemory.pro.monthly` (480 円、日本)。初回起動から 30 日間は文字起こし無制限 (購入・登録なし、開始日は Keychain に保存し入れ直しで再開しない)。その後の無料は文字起こし 1 日 30 分。値は `iOS/UsageQuota.swift` の `PlanConfig` に集約。
- プライバシーポリシー: https://fatshin.github.io/mymemory-legal/

## TestFlight
GitHub Secrets に `TEAM_ID` / `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_P8_BASE64` を登録し、Actions の `TestFlight` を手動実行する。ビルド番号は実行番号で自動採番。
