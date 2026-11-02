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

文字起こしは whisper.cpp（ローカル）に決定（2026-10-15）。`record --transcribe` でトラックごとに外部プロセス（`scripts/transcribe_whisper.py`）を起動し、音声を標準入力に流して結果を JSON Lines で受け取る。

- `Sources/ExternalProcess/`：外部プロセスとの受け渡しの共通部分（`JSONLinesProcess`）。起動、標準入力への書き込み、1行1件の JSON の読み取り、終了待ち、失敗の集計。外部に処理を任せる部分を足すときはこれを使う
- `Sources/Transcription/`：文字起こしプロセスとの受け渡し（`TranscriberProcess`）。16kHz・モノラル・16bit への変換もここ
- `scripts/transcribe_whisper.py`：音量で発話を区切って whisper-server に送る。標準ライブラリのみ
- モデルは `models/`（git 管理外）

候補の抽出は `claude -p`（ツールなし、`--json-schema` で出力を固定）に決定（2026-10-20）。`record --candidates` で外部プロセス（`scripts/extract_candidates.py`）を起動し、文字起こしを1行ずつ渡して候補を JSON Lines で受け取る。

- `Sources/Candidates/`：候補抽出プロセスとの受け渡し（`CandidateExtractor`）
- `scripts/extract_candidates.py`：相手の発言が落ち着いたら直近のやり取りを claude -p に渡す。標準ライブラリのみ
- `scripts/claude_cli.py`：scripts/ から claude -p を呼ぶ共通部分（claude の場所の解決、呼び出し、MCP を読まない、結果の取り出し）。claude -p を使うスクリプトはこれを使う

候補を選んだら調べる部分（README の 5）を追加（2026-10-27）。`answer --repo <path>` を録音とは別のターミナルで動かし、選んだ候補だけ外部プロセス（`scripts/answer_question.py`）に渡す。claude -p には読み取り用のツール（Read / Grep / Glob）だけを渡す。

- `Sources/Candidates/CandidateAnswerer.swift`：調査プロセスとの受け渡し
- `Sources/meet-copilot/AnswerCommand.swift`：候補の一覧と番号での選択。答えは answers-<日時>.jsonl
- `Sources/meet-copilot/JSONLinesFile.swift`：transcript / candidates / answers の JSON Lines ファイルの書き足しと読み込みの共通部分

実機で分かったこと（2026-10-20）：
- Meet の相手側音声は発言の合間がほぼ無音（-88 dBFS）で、音量による区切りが効く。話し終わりから約1秒で結果が出る
- BGM が途切れない音声（動画など）では区切れず、最大 15 秒まで溜まる
- 「もしもし」程度の短い発言は、whisper が「お疲れ様でした」「そうですね」など言っていない文に置き換えることが多い

未検証のまま残っている点：
- ヘッドホンなしで Meet に出たときの回り込み。相手の声がマイクに入る。対策候補は AVAudioEngine のボイス処理（`setVoiceProcessingEnabled`）
- 長めの文（質問）での文字起こし精度。静かな環境で確かめる

## ビルド構成

- Xcode プロジェクトは作らない。SwiftPM で組み、編集は Xcode で `Package.swift` を開けば足りる
- 当面はターミナルから `swift run` で起動する。マイク・画面収録の権限はターミナル側に付く
- .app として単体起動したくなったら、Info.plist（`NSMicrophoneUsageDescription`・bundle id）・.app へのまとめ・アドホック署名（`codesign -s -`）をスクリプトで足す。署名しないとビルドのたびに権限が外れうる
- Xcode プロジェクトが要るのは entitlements の管理・公証・アセットカタログが必要になったとき。いずれも現状は対象外
