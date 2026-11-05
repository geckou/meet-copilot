// meet-copilot の本体。当面はターミナルから swift run で起動する。
//
// run: swift run meet-copilot record [--app <bundle id prefix>] [--out <dir>] [--duration <sec>] [--transcribe] [--candidates] [--keep-audio]
//      swift run meet-copilot answer [--repo <path>...] [--out <dir>]
//      swift run meet-copilot ui [--out <dir>]

import Candidates
import Capture
import ExternalProcess
import Foundation
import Transcription

let usage = """
usage: meet-copilot record [--app <bundle id prefix>] [--out <dir>] [--duration <sec>]
                           [--transcribe | --transcriber <command>]
                           [--candidates | --extractor <command>] [--keep-audio]
       meet-copilot answer [--repo <path>...] [--out <dir>] [--answerer <command>]
       meet-copilot ui [--out <dir>]

record  アプリ音声（相手）とマイク（自分）を別々の WAV に書き出す
  --app          対象アプリの bundle id 前方一致（既定: com.google.Chrome、空文字で全アプリ）
  --out          出力ディレクトリ（既定: カレントディレクトリ）
  --duration     録音秒数。省略時は Ctrl-C まで
  --transcribe   whisper.cpp（scripts/transcribe_whisper.py）で文字起こしし、transcript-<日時>.jsonl に書く。
                 停止時に読む用の議事録 minutes-<日時>.md も書く
  --transcriber  文字起こしに使うコマンド（/bin/sh -c で実行）。トラックごとに1つ起動し、
                 環境変数 MEET_COPILOT_TRACK に app / mic を渡す
  --candidates   文字起こしから相手が答えを求めている箇所を claude -p（scripts/extract_candidates.py）で抜き出し、
                 candidates-<日時>.jsonl に書く。--transcribe か --transcriber が要る
  --extractor    候補の抽出に使うコマンド（/bin/sh -c で実行）
  --keep-audio   WAV を消さない。文字起こしするときは、停止時に WAV を消すのが既定（文字起こしに失敗があっても消す）

answer  record の候補を一覧し、選んだ候補だけローカルのリポジトリ（--repo が無ければ Web）を
        claude -p（scripts/answer_question.py）で調べて答える。
        record とは別のターミナルで動かす。答えは answers-<日時>.jsonl に書き足す
  --repo         調べるリポジトリ。複数指定できる。1つ目を claude の作業ディレクトリにする。省略時は Web で調べる
  --out          record の出力ディレクトリ（既定: カレントディレクトリ）。いちばん新しい candidates-<日時>.jsonl を使う
  --answerer     調べるのに使うコマンド（/bin/sh -c で実行）。指定したときは --repo を渡さない

ui      メニューバーに常駐し、録音・文字起こし・候補・調査を1画面で扱う。record --transcribe --candidates と answer をまとめたもの
  --out          録音・文字起こし・候補・答えのファイルの置き場所（既定: カレントディレクトリ）。
                 議事録は画面で選んだ保存先に書く（選んでいなければここ）
"""

/// シェルのシングルクォートで囲む。中の ' は '\'' に置き換える
func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// scripts/ 以下のスクリプトを python3 で動かすコマンド。swift run で動かす前提なので、ソースの場所からリポジトリを辿る
func scriptCommand(_ name: String) -> String {
    let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return "exec python3 " + shellQuote(repo.appendingPathComponent("scripts/\(name)").path)
}

struct RecordOptions {
    var bundlePrefix = "com.google.Chrome"
    var outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var duration: Double?
    var transcriber: String?
    var extractor: String?
    var keepAudio = false
    /// 議事録（minutes-<日時>.md）の置き場所。nil なら outputDir
    var minutesDir: URL?
}

func fail(_ message: String) -> Never {
    fputs("error: \(message)\n", stderr)
    exit(1)
}

func parseRecordOptions(_ arguments: ArraySlice<String>) -> RecordOptions {
    var options = RecordOptions()
    var args = arguments.makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--app":
            guard let v = args.next() else { fail("--app に値がない") }
            options.bundlePrefix = v
        case "--out":
            guard let v = args.next() else { fail("--out に値がない") }
            options.outputDir = URL(fileURLWithPath: v)
        case "--duration":
            // ナノ秒の UInt64 に変換するので、inf や大きすぎる値はここで弾く
            guard let v = args.next(), let d = Double(v), d > 0, d.isFinite,
                  d * 1_000_000_000 < Double(UInt64.max) else { fail("--duration は正の数") }
            options.duration = d
        case "--transcribe":
            options.transcriber = scriptCommand("transcribe_whisper.py")
        case "--transcriber":
            guard let v = args.next(), !v.isEmpty else { fail("--transcriber に値がない") }
            options.transcriber = v
        case "--candidates":
            options.extractor = scriptCommand("extract_candidates.py")
        case "--extractor":
            guard let v = args.next(), !v.isEmpty else { fail("--extractor に値がない") }
            options.extractor = v
        case "--keep-audio":
            options.keepAudio = true
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            fail("不明な引数: \(arg)\n\(usage)")
        }
    }
    if options.extractor != nil, options.transcriber == nil {
        fail("--candidates / --extractor には --transcribe か --transcriber が要る")
    }
    return options
}

/// 外部プロセスの終わり方のうち、失敗に当たるものを端末に出す。成功なら true。
func report(_ exit: ProcessExit, of name: String) -> Bool {
    if exit.status != 0 {
        fputs("\(name)が終了コード \(exit.status) で終わった\n", stderr)
    }
    if exit.inputDropped {
        fputs("\(name)に渡せなかった入力がある\n", stderr)
    }
    if exit.undecodableLines > 0 {
        fputs("\(name)の出力のうち \(exit.undecodableLines) 行を読めなかった\n", stderr)
    }
    return exit.succeeded
}

/// タイマー・Ctrl-C・起動失敗・ストリーム停止のどこから終了しても、結果の表示と exit を1回にまとめる。
/// 終了コードは失敗を優先する。後片付けと失敗の集計は RecordingSession.stop() に任せる。
final class Termination: @unchecked Sendable {
    private let session: RecordingSession
    private let lock = NSLock()
    private var exitCode: Int32 = 0
    private var finishing = false

    init(session: RecordingSession) {
        self.session = session
    }

    func finish(exitCode code: Int32) {
        let first = lock.withLock {
            exitCode = max(exitCode, code)
            defer { finishing = true }
            return !finishing
        }
        guard first else { return }
        Task.detached { [self] in
            let succeeded = await session.stop()
            exit(lock.withLock { max(exitCode, succeeded ? 0 : 1) })
        }
    }
}

func record(_ options: RecordOptions) -> Never {
    let session: RecordingSession
    do {
        session = try RecordingSession(options: options)
    } catch {
        fail("\(error)")
    }
    let termination = Termination(session: session)
    @Sendable func finish(exitCode: Int32) {
        termination.finish(exitCode: exitCode)
    }

    session.onUnexpectedStop = { error in
        fputs("ストリームが停止した: \(error)\n", stderr)
        finish(exitCode: 1)
    }

    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { finish(exitCode: 0) }
    sigint.resume()

    Task.detached {
        do {
            _ = try await session.start()
        } catch {
            // エラーの表示は終了処理で stop() の結果から出す
            finish(exitCode: 1)
            return
        }
        if let duration = options.duration {
            print("録音中... \(duration) 秒で止まる（Ctrl-C でも止まる）")
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            finish(exitCode: 0)
        } else {
            print("録音中... Ctrl-C で止める")
        }
    }

    withExtendedLifetime(sigint) { dispatchMain() }
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "record":
    record(parseRecordOptions(arguments.dropFirst()))
case "answer":
    answer(parseAnswerOptions(arguments.dropFirst()))
case "ui":
    var args = arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--out":
            guard let v = args.next() else { fail("--out に値がない") }
            CopilotApp.outputDir = URL(fileURLWithPath: v).standardizedFileURL
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            fail("不明な引数: \(arg)\n\(usage)")
        }
    }
    CopilotApp.main()
case "-h", "--help", nil:
    print(usage)
    exit(arguments.isEmpty ? 1 : 0)
default:
    fail("不明なサブコマンド: \(arguments.first!)\n\(usage)")
}
