# meet-copilot

Google Meet の会議中、自分が把握していない実装について相手から質問されたときに、ローカルのリポジトリを読んで答えを用意してくれる macOS アプリ。

発端は議事録アプリだったが、本質は「会議に一緒に参加して、隣で調べてくれる存在」。議事録生成は副産物として後から足す。

## 解決したいこと

- 会議中に「あそこって今どういう実装になってる？」と聞かれて即答できない
- その場で調べようとすると会話が止まる
- 手を止めてタイプする余裕がない

## 動作の流れ

1. 手動で録音開始（自動検知は後回し）
2. マイク（自分）とアプリ音声（相手）を **別トラック** で録る
3. それぞれ streaming で文字起こし、話者ラベル付きでログに流す
4. 直近のやり取りを塊で LLM に投げ、相手が答えを求めている箇所を **候補として並べる**
5. 候補を押したときだけ、ローカルのリポジトリを読みに行って答えを出す
6. 議事録・文字起こしの生成が終わったら音声ファイルを削除する

## 設計上の判断

### 候補は出すだけ、調べには行かない

自動で調べに行く判断は精度が出ないうえ、会議中に走らせる回数が読めない。候補を並べるだけなら、外れた候補が混ざっても無害で、実行回数はこちらが制御できる。

### 候補の抽出は単語ではなく文脈で

固有名詞の抽出ではなく、直近のやり取りを塊で見て「答えが必要になっている箇所」を探す。判定材料:

- 疑問形で終わっている発言
- 自分が答えに詰まっている、間が空いている
- 「どうなってましたっけ」のような確認要求

### 2トラック録音が前提

上記の判定には、相手が聞いてきたのか自分が話しているのかの区別が要る。話者分離のモデルは使わず、マイク＝自分、アプリ音声＝相手として別トラックで録ることで解決する。

### まず「溜める」だけ、会話中に割り込まない

会話中に「今の件はこうです」と出す形は、出すタイミングの判定が難しく、外したときのコストが高い。まずは黙って溜めて一覧に並べる形で作り、溜まったものを見て「これは会話中に欲しかった」があるか確かめてから判断する。

## 技術構成

| 要素 | 手段 |
| --- | --- |
| 音声キャプチャ | ScreenCaptureKit（macOS 13+）でアプリ音声、別途マイク |
| 文字起こし | streaming 前提のモデル（whisper.cpp をそのまま使うなら streaming 対応が必要） |
| 候補抽出 | LLM |
| コード参照 | ローカルに clone 済みのリポジトリが前提 |
| UI | ログと候補一覧。メニューバー常駐 |

Swift で新規に書くのは音声の2トラック取得と画面まわりのみ。文字起こしとコード参照は外部に投げる。

なお本リポジトリは Swift の macOS アプリであり、project-starter（React/Expo/Next 系）の構成・規約は適用しない。

## 前提・制約

- 画面収録権限が必須（音声だけでも要求される）。削除の有無とは無関係
- 対象リポジトリはローカルに持っていることが前提
- 音声ファイルは議事録・文字起こしの生成が終わった時点で削除する。残すのは文字起こしと議事録のみ
- ただし会話は常時 LLM に流れるため、「データが残らない」とは言えない
- Meet 側に「録音中」の表示は出ない。相手への説明は運用で担保する必要がある

## 未確定

- 会議開始の自動検知を入れるか（Workspace Events API で conference.started の購読は可能だが、Pub/Sub 経由でサーバーに飛ぶ設計。ローカルで音の発生を見る方法もある）
- 文字起こしをローカルで回すかクラウドに投げるか
- 会話中の割り込み表示を入れるかどうか
- 議事録生成を足すかどうか

## 実行

macOS 13 以降、Xcode が必要。

```sh
swift run meet-copilot record --duration 30 --out ./recordings
```

- オプションは `spikes/two-track-capture` と同じ（`--app` / `--out` / `--duration`）
- 権限はターミナル側に付く。初回はマイクと画面収録の許可が要り、画面収録の許可後はターミナルの再起動が要る
- テストは `swift test`

### 文字起こし（whisper.cpp）

初回のみ whisper.cpp とモデル（large-v3-turbo、約1.6GB）を入れる。

```sh
brew install whisper-cpp
mkdir -p models
curl -fL -o models/ggml-large-v3-turbo.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

```sh
swift run meet-copilot record --transcribe --out ./recordings
```

- 発話ごとに `[01:23.4] 相手: ...` の形で端末に流れ、`transcript-<日時>.jsonl` に書き足される。時刻は録音開始からの秒数で、2トラックで揃っている
- トラックごとに `scripts/transcribe_whisper.py` が1つずつ起動し、それぞれが whisper-server を空きポートで立てる。音量で発話を区切り、区切りごとに whisper に送るので、話し終わりから結果まで1秒前後遅れる
- 文字起こしの仕組みは `--transcriber <command>` で差し替えられる。受け渡しの約束（標準入力に 16kHz・モノラル・16bit の生 PCM、標準出力に1行1件の JSON）は `Sources/Transcription/TranscriberProcess.swift` の冒頭を参照

### 候補の抽出（claude -p）

```sh
swift run meet-copilot record --transcribe --candidates --out ./recordings
```

- 相手の発言が来て 2 秒新しい発言がなければ、直近 3 分のやり取りを `claude -p`（ツールなし）に渡し、相手が答えを求めている箇所を抜き出す
- 候補は `[候補 01:23] 問い` と根拠の発言の形で端末に流れ、`candidates-<日時>.jsonl` に書き足される
- 抽出は1回ずつ順に行い、実行中に来た発言は次の回にまとめる。既に出した候補は渡して重複を避ける
- Claude Code にログイン済みであることが前提。利用枠は Claude Code のものを使う
- スクリプト単体の確認：`python3 scripts/extract_candidates.py < scripts/testdata/conversation.jsonl`
- 抽出の仕組みは `--extractor <command>` で差し替えられる。受け渡しの約束は `Sources/Candidates/CandidateExtractor.swift` の冒頭を参照

### 候補を調べる（claude -p）

録音とは別のターミナルで動かす。

```sh
swift run meet-copilot answer --repo ~/path/to/repo --out ./recordings
```

- `--out` の中でいちばん新しい `candidates-<日時>.jsonl` の候補を番号付きで並べる。Enter で一覧を更新、番号で調べる、`q` で終了
- 選んだ候補だけ、前後 2 分半のやり取りを添えて `claude -p` に渡す。ツールは Read / Grep / Glob のみ（読み取りだけ）で、1つ目の `--repo` を作業ディレクトリ、残りを `--add-dir` にする
- 答えは会議でそのまま言える 2〜4 文と、根拠のファイル・行、確度（high / medium / low）。端末に出し、`answers-<日時>.jsonl` に書き足す。調べ終えた候補には ✓ が付く
- 調べる仕組みは `--answerer <command>` で差し替えられる。受け渡しの約束は `Sources/Candidates/CandidateAnswerer.swift` の冒頭を参照

## 最初のタスク

ScreenCaptureKit の2トラック取得の検証。Swift の実行ファイル1本で、アプリ音声とマイクを別ファイルに書き出すところまで。ここが通れば残りは繋ぎ込み。
