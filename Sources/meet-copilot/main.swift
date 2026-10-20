// meet-copilot の本体。当面はターミナルから swift run で起動する。
//
// run: swift run meet-copilot record [--app <bundle id prefix>] [--out <dir>] [--duration <sec>] [--transcribe] [--candidates]

import Candidates
import Capture
import Foundation
import Transcription

let usage = """
usage: meet-copilot record [--app <bundle id prefix>] [--out <dir>] [--duration <sec>]
                           [--transcribe | --transcriber <command>]
                           [--candidates | --extractor <command>]

record  アプリ音声（相手）とマイク（自分）を別々の WAV に書き出す
  --app          対象アプリの bundle id 前方一致（既定: com.google.Chrome、空文字で全アプリ）
  --out          出力ディレクトリ（既定: カレントディレクトリ）
  --duration     録音秒数。省略時は Ctrl-C まで
  --transcribe   whisper.cpp（scripts/transcribe_whisper.py）で文字起こしし、transcript-<日時>.jsonl に書く
  --transcriber  文字起こしに使うコマンド（/bin/sh -c で実行）。トラックごとに1つ起動し、
                 環境変数 MEET_COPILOT_TRACK に app / mic を渡す
  --candidates   文字起こしから相手が答えを求めている箇所を claude -p（scripts/extract_candidates.py）で抜き出し、
                 candidates-<日時>.jsonl に書く。--transcribe か --transcriber が要る
  --extractor    候補の抽出に使うコマンド（/bin/sh -c で実行）
"""

/// scripts/ 以下のスクリプトを python3 で動かすコマンド。swift run で動かす前提なので、ソースの場所からリポジトリを辿る
func scriptCommand(_ name: String) -> String {
    let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let script = repo.appendingPathComponent("scripts/\(name)").path
    // シングルクォートで囲むので、パス中の ' は '\'' に置き換える
    let quoted = script.replacingOccurrences(of: "'", with: "'\\''")
    return "exec python3 '\(quoted)'"
}

struct RecordOptions {
    var bundlePrefix = "com.google.Chrome"
    var outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var duration: Double?
    var transcriber: String?
    var extractor: String?
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

/// タイマー・Ctrl-C・起動失敗・ストリーム停止のどこから終了しても、結果の表示と exit を1回にまとめる。
/// 終了コードは失敗を優先する。停止待ちの間に届いた失敗、起動の失敗、WAV の書き込み失敗、
/// 文字起こし・候補抽出プロセスの異常終了も反映する。
final class Termination: @unchecked Sendable {
    private let recorder: TwoTrackRecorder
    private let transcribers: [(Track, TranscriberProcess)]
    private let transcript: Transcript?
    private let extractor: CandidateExtractor?
    private let candidateLog: CandidateLog?
    private let lock = NSLock()
    private var exitCode: Int32 = 0
    private var finishing = false

    init(
        recorder: TwoTrackRecorder,
        transcribers: [(Track, TranscriberProcess)],
        transcript: Transcript?,
        extractor: CandidateExtractor?,
        candidateLog: CandidateLog?
    ) {
        self.recorder = recorder
        self.transcribers = transcribers
        self.transcript = transcript
        self.extractor = extractor
        self.candidateLog = candidateLog
    }

    func finish(exitCode code: Int32) {
        let first = lock.withLock {
            exitCode = max(exitCode, code)
            defer { finishing = true }
            return !finishing
        }
        guard first else { return }
        Task.detached { [self] in
            let result = await recorder.stop()
            // 録音を止めると入力が閉じられ、文字起こしプロセスは残りを処理してから終わる
            var transcriberFailed = false
            if !transcribers.isEmpty {
                print("\n文字起こしの残りを処理中...")
                for (track, transcriber) in transcribers {
                    let exit = await transcriber.finish()
                    if exit.status != 0 {
                        fputs("[\(track.rawValue)] 文字起こしプロセスが終了コード \(exit.status) で終わった\n", stderr)
                    }
                    if exit.audioDropped {
                        fputs("[\(track.rawValue)] 文字起こしプロセスに渡せなかった音声がある\n", stderr)
                    }
                    if exit.undecodableLines > 0 {
                        fputs("[\(track.rawValue)] 文字起こしプロセスの出力のうち \(exit.undecodableLines) 行を読めなかった\n", stderr)
                    }
                    if !exit.succeeded { transcriberFailed = true }
                }
            }
            // 文字起こしが出し切られてから入力を閉じ、候補抽出プロセスは残りを処理してから終わる
            var extractorFailed = false
            if let extractor {
                print("\n候補の抽出の残りを処理中...")
                let exit = await extractor.finish()
                if exit.status != 0 {
                    fputs("候補抽出プロセスが終了コード \(exit.status) で終わった\n", stderr)
                }
                if exit.inputDropped {
                    fputs("候補抽出プロセスに渡せなかった発言がある\n", stderr)
                }
                if exit.undecodableLines > 0 {
                    fputs("候補抽出プロセスの出力のうち \(exit.undecodableLines) 行を読めなかった\n", stderr)
                }
                extractorFailed = !exit.succeeded
            }
            // 起動の失敗は stop() の結果から出す。Ctrl-C で先に終了処理が始まっていても取りこぼさない
            if let startError = result.startError {
                fputs("error: \(startError)\n", stderr)
            }
            print("\n--- 結果 ---")
            print(result.app)
            print(result.mic)
            var transcriptFailed = false
            if let transcript {
                let summary = transcript.close()
                print(summary.description)
                transcriptFailed = summary.failed
            }
            var candidateLogFailed = false
            if let candidateLog {
                let summary = candidateLog.close()
                print(summary.description)
                candidateLogFailed = summary.failed
            }
            let failed = result.startError != nil || result.app.writeError != nil || result.mic.writeError != nil
                || transcriberFailed || transcriptFailed || extractorFailed || candidateLogFailed
            exit(lock.withLock { max(exitCode, failed ? 1 : 0) })
        }
    }
}

func record(_ options: RecordOptions) -> Never {
    do {
        try FileManager.default.createDirectory(at: options.outputDir, withIntermediateDirectories: true)
    } catch {
        fail("出力ディレクトリを作れない: \(error)")
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    // AVAudioFile は既存ファイルを上書きするので、同じ秒に起動しても衝突しないよう短い乱数を足す
    let suffix = UUID().uuidString.prefix(6).lowercased()
    let stamp = "\(formatter.string(from: Date()))-\(suffix)"
    let recorder = TwoTrackRecorder(
        bundlePrefix: options.bundlePrefix,
        appURL: options.outputDir.appendingPathComponent("app-\(stamp).wav"),
        micURL: options.outputDir.appendingPathComponent("mic-\(stamp).wav")
    )

    var transcribers: [(Track, TranscriberProcess)] = []
    var transcript: Transcript?
    if let command = options.transcriber {
        let output: Transcript
        do {
            output = try Transcript(url: options.outputDir.appendingPathComponent("transcript-\(stamp).jsonl"))
        } catch {
            fail("文字起こしのファイルを作れない: \(error)")
        }
        for track in [Track.app, .mic] {
            let transcriber = TranscriberProcess(
                label: track.rawValue,
                command: command,
                environment: ["MEET_COPILOT_TRACK": track.rawValue]
            ) { output.append($0, track: track) }
            do {
                try transcriber.start()
            } catch {
                fail("文字起こしプロセスを起動できない: \(error)")
            }
            transcribers.append((track, transcriber))
        }
        let byTrack = Dictionary(uniqueKeysWithValues: transcribers)
        recorder.onBuffer = { track, buffer in byTrack[track]?.append(buffer) }
        transcript = output
    }

    var extractor: CandidateExtractor?
    var candidateLog: CandidateLog?
    if let command = options.extractor, let transcript {
        let log: CandidateLog
        do {
            log = try CandidateLog(url: options.outputDir.appendingPathComponent("candidates-\(stamp).jsonl"))
        } catch {
            fail("候補のファイルを作れない: \(error)")
        }
        let process = CandidateExtractor(command: command) { log.append($0) }
        do {
            try process.start()
        } catch {
            fail("候補抽出プロセスを起動できない: \(error)")
        }
        transcript.onRecord = { process.send($0) }
        extractor = process
        candidateLog = log
    }

    let termination = Termination(
        recorder: recorder,
        transcribers: transcribers,
        transcript: transcript,
        extractor: extractor,
        candidateLog: candidateLog
    )
    @Sendable func finish(exitCode: Int32) {
        termination.finish(exitCode: exitCode)
    }

    recorder.onUnexpectedStop = { error in
        fputs("ストリームが停止した: \(error)\n", stderr)
        finish(exitCode: 1)
    }

    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { finish(exitCode: 0) }
    sigint.resume()

    Task.detached {
        do {
            let apps = try await recorder.start()
            print("対象アプリ:")
            for app in apps {
                print("  \(app.bundleIdentifier) (pid \(app.processID)) \(app.name)")
            }
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
case "-h", "--help", nil:
    print(usage)
    exit(arguments.isEmpty ? 1 : 0)
default:
    fail("不明なサブコマンド: \(arguments.first!)\n\(usage)")
}
