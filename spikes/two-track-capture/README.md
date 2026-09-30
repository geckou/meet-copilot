# two-track-capture

ScreenCaptureKit でアプリ音声（既定: Chrome）、AVAudioEngine でマイクを取り、別々の WAV に書き出す検証用の実行ファイル。

## 実行

macOS 13 以降。Xcode か Command Line Tools が必要。

```sh
cd spikes/two-track-capture
swiftc -O main.swift -o two-track-capture
./two-track-capture --duration 30 --out ./out
```

- 初回はマイクと画面収録の権限を求められる。許可する対象は実行元のターミナル
- 画面収録を許可した後はターミナルの再起動が要る
- 出力は `app-<日時>.wav` と `mic-<日時>.wav`。終了時に秒数とピークレベルを表示する

オプション:

| 引数 | 内容 |
| --- | --- |
| `--app <prefix>` | 対象アプリの bundle id 前方一致。既定は `com.google.Chrome`。空文字で全アプリ |
| `--out <dir>` | 出力先。既定はカレントディレクトリ |
| `--duration <sec>` | 録音秒数。省略時は Ctrl-C まで |

## 確認すること

1. 2つのファイルができて、秒数がほぼ揃っている
2. app 側に Chrome の音（Meet の相手、または YouTube など）だけが入っている
3. mic 側に自分の声だけが入っている。スピーカーだと相手の声がマイクに回り込むので、ヘッドホンで確認する
4. app 側が無音（ピークが -inf）なら、Chrome の音声がヘルパープロセスから出ていて前方一致で拾えていない可能性がある。起動時に表示される「対象アプリ」を確認し、`--app ""` で全アプリにして音が入るか比べる
