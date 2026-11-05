# meet-copilot

Google Meet の会議中、自分が把握していない実装について相手から質問されたときに、ローカルのリポジトリを読んで答えを用意してくれる macOS アプリ。

発端は議事録アプリだったが、本質は「会議に一緒に参加して、隣で調べてくれる存在」。議事録は文字起こしの副産物として停止時に書く。

自分用の試作。配布・公証・話者分離モデルは対象外。

## 解決したいこと

- 会議中に「あそこって今どういう実装になってる？」と聞かれて即答できない
- その場で調べようとすると会話が止まる
- 手を止めてタイプする余裕がない

## 動作の流れ

1. 手動で録音開始（自動検知は後回し）
2. マイク（自分）とアプリ音声（相手）を **別トラック** で録る
3. それぞれ発話ごとに文字起こしし、話者ラベル付きでログに流す
4. 相手の発言が落ち着いたら直近のやり取りを LLM に渡し、調べれば答えられる問いを **候補として並べる**
5. 候補を押したときだけ、ローカルのリポジトリ（未選択なら Web）を調べて答えを出す
6. 録音を止めたら議事録を書く。音声はファイルに残さない

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
| 音声キャプチャ | ScreenCaptureKit（macOS 13+）でアプリ音声、AVAudioEngine でマイク（ボイス処理あり） |
| 文字起こし | whisper.cpp（ローカル、large-v3-turbo）。音量で発話を区切って whisper-server に送る。whisper-server は2トラックで1つを共有 |
| 候補抽出 | `claude -p`（sonnet、ツールなし） |
| 調査 | `claude -p`（sonnet）。リポジトリは Read / Grep / Glob のみ、Web は WebSearch / WebFetch のみ |
| UI | SwiftUI の `MenuBarExtra`。CLI（`record` / `answer`）もある |

Swift で新規に書くのは音声の2トラック取得と画面まわりのみ。文字起こし・候補抽出・調査は外部プロセス（`scripts/`）に任せ、JSON Lines で受け渡す。

| 場所 | 内容 |
| --- | --- |
| `Sources/Capture/` | 2トラック録音と WAV 書き出し |
| `Sources/ExternalProcess/` | 外部プロセスとの受け渡しの共通部分 |
| `Sources/Transcription/` | 文字起こしプロセスとの受け渡し。16kHz・モノラル・16bit への変換 |
| `Sources/Candidates/` | 候補抽出・調査プロセスとの受け渡し |
| `Sources/meet-copilot/` | 実行ターゲット。CLI のサブコマンド、録音のつなぎ（`RecordingSession`）、UI |
| `scripts/` | 外部プロセスの本体（Python、標準ライブラリのみ） |
| `spikes/two-track-capture/` | 2トラック取得の検証（経緯は同ディレクトリの README） |

## 前提・制約

- 画面収録権限が必須（音声だけでも要求される）。削除の有無とは無関係
- 権限は起動したターミナルに付く。.app にはまとめていない
- リポジトリを調べるときは、対象をローカルに持っていることが前提
- Claude Code にログイン済みであることが前提。利用枠は Claude Code のものを使う
- 音声は whisper.cpp でローカルに処理し、このマシンの外には出さない。文字起こしのうち直近のやり取りは常時 `claude -p` に渡るため、「データが残らない」とは言えない
- 文字起こしするときは、WAV を書かない（`--keep-audio` を除く）。残るのは文字起こし・候補・答えの JSON Lines と議事録
- `claude -p` にはユーザー全体の設定（`~/.claude/CLAUDE.md` など）を読ませない。リポジトリを調べるときは、そのリポジトリの CLAUDE.md は読む
- Meet 側に「録音中」の表示は出ない。相手への説明は運用で担保する必要がある

## 未検証

- ヘッドホンなしで Meet に出たときの回り込みの対策。スピーカーで短く試した範囲（相手の発言 3 件）では、相手の文は「自分」の行に現れなかった。実際の会議では未確認で、効かなければ、相手と重なった「自分」の行を除く案に切り替える
- whisper-server の共有による遅延。両トラックが重なっても欠けずに文字起こしされるが、実際の会議での遅れは未確認
- 長めの文（質問）での文字起こし精度

## 未確定

- 会議開始の自動検知を入れるか（Workspace Events API で conference.started の購読は可能だが、Pub/Sub 経由でサーバーに飛ぶ設計。ローカルで音の発生を見る方法もある）
- 会話中の割り込み表示を入れるかどうか

## 実行

macOS 13 以降、Xcode が必要。テストは `swift test`。

初回はマイクと画面収録の許可が要る。許可する対象は実行元のターミナルで、画面収録の許可後はターミナルの再起動が要る。

### 準備

whisper.cpp とモデル（large-v3-turbo、約1.6GB）を入れる。Claude Code にログインしておく。

```sh
brew install whisper-cpp
mkdir -p models
curl -fL -o models/ggml-large-v3-turbo.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

### メニューバーから使う

```sh
swift run meet-copilot ui --out ./recordings
```

- メニューバーに常駐し、1つの画面で録音の開始・停止、文字起こし、候補の一覧、候補を押したときの調査を扱う。`record --transcribe --candidates` と `answer` をまとめたもの
- 調べるリポジトリは画面の「選ぶ...」で指定する（次回も覚えている）。未選択か「外す」を押した状態なら Web で調べる
- 停止すると、読む用の議事録 `minutes-<日時>.md` を書く。出た問いの一覧と、時刻順の発言（同じ話者が続く分は1段落）
- 議事録の保存先は画面下の「変更...」で選ぶ（次回も覚えている。録音していないときだけ）。選んでいなければ `--out`
- `transcript` / `candidates` / `answers` の JSON Lines は機械用で、議事録とは分けて `--out` に置く。WAV は書かない（UI には残す設定がない）
- 上の準備が要る
- ヘッドホンなしでも相手の声が「自分」に入りにくいよう、マイクに macOS のボイス処理（エコー除去）をかける。CLI の `record` で切るときは `--no-voice-processing`
- 終了は画面の「終了」かターミナルの Ctrl-C。録音中なら止めてから終わる。調べている途中の問いは待たない

### 録音だけ（record）

```sh
swift run meet-copilot record --duration 30 --out ./recordings
```

- アプリ音声（`app-<日時>.wav`）とマイク（`mic-<日時>.wav`）を別ファイルに書く
- `--app` は対象アプリの bundle id 前方一致（既定 `com.google.Chrome`、空文字で全アプリ）、`--out` は出力先、`--duration` は録音秒数（省略時は Ctrl-C まで）

### 文字起こし（whisper.cpp）

```sh
swift run meet-copilot record --transcribe --out ./recordings
```

- 発話ごとに `[01:23.4] 相手: ...` の形で端末に流れ、`transcript-<日時>.jsonl` に書き足される。時刻は録音開始からの秒数で、2トラックで揃っている
- 録音を止めて文字起こしの残りを処理したら、議事録 `minutes-<日時>.md` を書く。失敗があれば終了コード 1 で伝える
- 音声はファイルに書かず、文字起こしにだけ流す。WAV も残すときは `--keep-audio`
- トラックごとに `scripts/transcribe_whisper.py` が1つずつ起動し、音量で発話を区切って whisper に送る。話し終わりから結果まで1秒前後遅れる
- whisper-server は管理役のプロセス（`transcribe_whisper.py --serve`）が空きポートで1つだけ立て、両トラックで共有する。whisper は1件ずつ処理するので、両トラックの発話が重なると片方は待つ
- 受け渡しの約束（標準入力に 16kHz・モノラル・16bit の生 PCM、標準出力に1行1件の JSON）は `Sources/Transcription/TranscriberProcess.swift` の冒頭を参照

### 候補の抽出（claude -p）

```sh
swift run meet-copilot record --transcribe --candidates --out ./recordings
```

- 相手の発言（9 文字以上）が来て 2 秒新しい発言がなければ、直近 3 分のやり取りを `claude -p`（ツールなし）に渡し、相手の問いのうち調べれば答えられるものを抜き出す。判断や意見を求める問い、本人にしか分からない問いは出さない。相槌のような短い発言だけでは呼ばず、次に呼ぶときのやり取りに含める
- 候補は `[候補 01:23] 問い` と根拠の発言の形で端末に流れ、`candidates-<日時>.jsonl` に書き足される
- 抽出は1回ずつ順に行い、実行中に来た発言は次の回にまとめる。既に出した候補は渡して重複を避け、同じ発言からの候補は1つだけ通す
- スクリプト単体の確認：`python3 scripts/extract_candidates.py < scripts/testdata/conversation.jsonl`
- 受け渡しの約束は `Sources/Candidates/CandidateExtractor.swift` の冒頭を参照

### 候補を調べる（claude -p）

録音とは別のターミナルで動かす。

```sh
swift run meet-copilot answer --repo ~/path/to/repo --out ./recordings
```

- `--out` の中でいちばん新しい `candidates-<日時>.jsonl` の候補を番号付きで並べる。Enter で一覧を更新（新しい録音が始まっていれば切り替え）、番号で調べる（番号は表示中の一覧のもの）、`q` か Ctrl-C で終了。終了時は調べている途中の問いを待つ
- 選んだ候補だけ、前後のやり取り（根拠の発言の 120 秒前〜30 秒後）を添えて `claude -p` に渡す。ツールは Read / Grep / Glob のみ（読み取りだけ）で、1つ目の `--repo` を作業ディレクトリ、残りを `--add-dir` にする
- `--repo` を省くと Web で調べる。ツールは WebSearch / WebFetch のみで、空の一時ディレクトリで動かす。根拠には URL が入る。検索語として問いの内容が検索に渡る
- 答えは会議でそのまま言える 2〜3 文（120 字程度）と、根拠のファイル・行、確度（high / medium / low）。端末に出し、`answers-<日時>.jsonl` に書き足す。調べ終えた候補には ✓、調べられなかった候補には ✗ が付く。調べている間に録音が切り替わっても、答えは問いを出した録音の answers に入る
- 受け渡しの約束は `Sources/Candidates/CandidateAnswerer.swift` の冒頭を参照
