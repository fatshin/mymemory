# MyMemory

Apple Watch 常時録音 → iPhone でオンデバイス文字起こし(日本語, WhisperKit) → 任意でBYOK要約。個人用。

## 構成
- `Watch/` : 録音 (AVAudioRecorder, 10分チャンク, HKWorkoutSession でBG維持) → WatchConnectivity 転送
- `iOS/`   : 受信 → SwiftData保存 → WhisperKit文字起こし → Claude API要約(テキストのみ送信)
- `Shared/`: 転送メタデータキー
- `project.yml`: XcodeGen 定義

## セットアップ (Mac)
```bash
brew install xcodegen
xcodegen generate
open MyMemory.xcodeproj
```
Signing Team を両ターゲットに設定。HealthKit capability はWatchターゲットに必要。実機(iPhone+Watch)で実行。

## Phase 0: Go/No-Go PoC (最優先)
Watch単体で8時間録音を実測:
1. 電池消費 (開始/終了時 `batteryLevel` はチャンクメタに記録済)
2. バックグラウンドでの中断有無 (チャンク連番の欠番で判定)
3. 画面消灯・手首下ろし状態での継続
4. iPhone圏外時のキュー転送 → 復帰後の再送

NoGo条件: 8時間で欠番あり、または電池消費 > 60%。その場合は会議単位(手動開始)運用に縮小。

## 未検証 / 既知の未確認
- このリポジトリのコードはLinux環境で生成。**未コンパイル**。Xcodeでのビルドエラー修正が最初の作業。
- WhisperKit モデル名 (`Pipeline.modelName`)、API シグネチャはバージョン依存。
- `workout-processing` 方式のBG録音がApp Review上許容されるか未確認 (ガイドライン 2.5.4 / HealthKit用途説明)。
- 話者分離未実装。
- 録音の同意・法規: 他者音声を含む場合の運用ルール要整備。
