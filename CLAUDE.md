# CLAUDE.md

## このリポジトリについて

Google Meet の会議中に、相手からの質問を拾ってローカルのリポジトリを読み、答えを用意する macOS アプリ。仕様は README.md を参照。

## 前提

- Swift / macOS 13+ のネイティブアプリ
- project-starter（React / Expo / Next.js / Turborepo 系）の構成・規約は **適用しない**。別系統のプロジェクトとして扱う
- 現状は自分用の試作。配布・公証・話者分離モデルは対象外

## 実装方針

- Swift で新規に書くのは音声の2トラック取得と画面まわりのみ
- 文字起こしとコード参照は外部プロセスに投げる。Swift 側に抱え込まない
- 自動判断を増やさない。候補は出すだけで、実行はユーザーの操作を起点にする

## 現在地

ScreenCaptureKit の2トラック取得の検証は完了（2026-10-13, macOS 27.0）。`spikes/two-track-capture/` の実行ファイル1本で、Chrome の音声とマイクを別ファイルに書き出し、秒数が揃うこと、各トラックに入る音が分かれていることを実機で確認した。経緯と分かったことは同ディレクトリの README.md を参照。

本体の Swift Package を作成済み（2026-10-14）。spike の録音処理を `Capture` ターゲットへ移し、`swift run meet-copilot record` で同じ録音ができる形にした。実機で Chrome の音（ピーク -2.0 dBFS）とマイクが別ファイルに入り、秒数が揃う（10.50 秒ずつ）ことを確認済み。`spikes/` は残す。

- `Sources/Capture/`：2トラック録音（`TwoTrackRecorder`）と WAV 書き出し（`TrackWriter`）
- `Sources/meet-copilot/`：実行ターゲット。当面は CLI のサブコマンドのみ
- `Tests/CaptureTests/`：`TrackWriter` の単体テスト（`swift test`）

次は文字起こしの外部プロセスへの受け渡し。

未検証のまま残っている点：
- ヘッドホンなしで Meet に出たときの回り込み。相手の声がマイクに入る。対策候補は AVAudioEngine のボイス処理（`setVoiceProcessingEnabled`）

## ビルド構成

- Xcode プロジェクトは作らない。SwiftPM で組み、編集は Xcode で `Package.swift` を開けば足りる
- 当面はターミナルから `swift run` で起動する。マイク・画面収録の権限はターミナル側に付く
- .app として単体起動したくなったら、Info.plist（`NSMicrophoneUsageDescription`・bundle id）・.app へのまとめ・アドホック署名（`codesign -s -`）をスクリプトで足す。署名しないとビルドのたびに権限が外れうる
- Xcode プロジェクトが要るのは entitlements の管理・公証・アセットカタログが必要になったとき。いずれも現状は対象外
