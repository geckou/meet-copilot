import Candidates
import Capture
import ExternalProcess
import Foundation
import Transcription

struct SessionError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// 録音1回分。2トラック録音・文字起こし・候補抽出をつなぎ、止めるときの後片付けをまとめる。
/// record コマンドと UI の両方から使う。
///
/// stop() は何度呼んでも後片付けは1回で、結果も同じものを返す。
/// 文字起こしするときは、keepAudio でない限り WAV を消す。失敗があっても消す。残すのは文字起こしと候補だけ。
final class RecordingSession: @unchecked Sendable {
    /// 出力ファイル名の <日時>
    let stamp: String
    let outputDir: URL
    private let minutesDir: URL
    private let startedAt = Date()

    private let recorder: TwoTrackRecorder
    private let keepAudio: Bool
    private let transcribers: [(Track, TranscriberProcess)]
    private let transcript: Transcript?
    private let extractor: CandidateExtractor?
    private let candidateLog: CandidateLog?
    private let lock = NSLock()
    private var stopTask: Task<Bool, Never>?

    /// - Parameters:
    ///   - onUtterance: 文字起こし1件ごとに呼ばれる。文字起こしプロセスの読み取り用スレッドから呼ばれる
    ///   - onCandidate: 候補1件ごとに呼ばれる。候補抽出プロセスの読み取り用スレッドから呼ばれる
    init(
        options: RecordOptions,
        onUtterance: @escaping @Sendable (Track, Utterance) -> Void = { _, _ in },
        onCandidate: @escaping @Sendable (Candidate) -> Void = { _ in }
    ) throws {
        do {
            try FileManager.default.createDirectory(at: options.outputDir, withIntermediateDirectories: true)
        } catch {
            throw SessionError("出力ディレクトリを作れない: \(error)")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        // AVAudioFile は既存ファイルを上書きするので、同じ秒に起動しても衝突しないよう短い乱数を足す
        let suffix = UUID().uuidString.prefix(6).lowercased()
        let stamp = "\(formatter.string(from: startedAt))-\(suffix)"
        self.stamp = stamp
        self.outputDir = options.outputDir
        self.minutesDir = options.minutesDir ?? options.outputDir
        self.keepAudio = options.keepAudio
        let recorder = TwoTrackRecorder(
            bundlePrefix: options.bundlePrefix,
            appURL: options.outputDir.appendingPathComponent("app-\(stamp).wav"),
            micURL: options.outputDir.appendingPathComponent("mic-\(stamp).wav"),
            voiceProcessing: options.voiceProcessing
        )
        self.recorder = recorder

        // 途中で失敗したら、それまでに起動したプロセスの入力を閉じて終わらせ、開いたファイルを閉じる。
        // UI は失敗しても動き続けるので、残すと開始を押し直すたびにプロセスが溜まる
        var rollbacks: [@Sendable () async -> Void] = []
        func failure(_ message: String) -> SessionError {
            let pending = rollbacks
            Task.detached { for rollback in pending.reversed() { await rollback() } }
            return SessionError(message)
        }

        var transcribers: [(Track, TranscriberProcess)] = []
        var transcript: Transcript?
        if let command = options.transcriber {
            let output: Transcript
            do {
                output = try Transcript(url: options.outputDir.appendingPathComponent("transcript-\(stamp).jsonl"))
            } catch {
                throw failure("文字起こしのファイルを作れない: \(error)")
            }
            rollbacks.append { _ = output.close() }
            for track in [Track.app, .mic] {
                let transcriber = TranscriberProcess(
                    command: command,
                    environment: ["MEET_COPILOT_TRACK": track.rawValue]
                ) { utterance in
                    output.append(utterance, track: track)
                    onUtterance(track, utterance)
                }
                do {
                    try transcriber.start()
                } catch {
                    throw failure("文字起こしプロセスを起動できない: \(error)")
                }
                rollbacks.append { _ = await transcriber.finish() }
                transcribers.append((track, transcriber))
            }
            let byTrack = Dictionary(uniqueKeysWithValues: transcribers)
            recorder.onBuffer = { track, buffer in byTrack[track]?.append(buffer) }
            transcript = output
        }
        self.transcribers = transcribers
        self.transcript = transcript

        var extractor: CandidateExtractor?
        var candidateLog: CandidateLog?
        if let command = options.extractor, let transcript {
            let log: CandidateLog
            do {
                log = try CandidateLog(url: options.outputDir.appendingPathComponent("candidates-\(stamp).jsonl"))
            } catch {
                throw failure("候補のファイルを作れない: \(error)")
            }
            rollbacks.append { _ = log.close() }
            let process = CandidateExtractor(command: command) { candidate in
                log.append(candidate)
                onCandidate(candidate)
            }
            do {
                try process.start()
            } catch {
                throw failure("候補抽出プロセスを起動できない: \(error)")
            }
            transcript.onRecord = { process.send($0) }
            extractor = process
            candidateLog = log
        }
        self.extractor = extractor
        self.candidateLog = candidateLog
    }

    /// ストリームが途中で止まったときに呼ばれる
    var onUnexpectedStop: (@Sendable (Error) -> Void)? {
        get { recorder.onUnexpectedStop }
        set { recorder.onUnexpectedStop = newValue }
    }

    /// 録音を始め、音声を取っているアプリを端末に出して返す
    func start() async throws -> [CapturedApp] {
        let apps = try await recorder.start()
        print("対象アプリ:")
        for app in apps {
            print("  \(app.bundleIdentifier) (pid \(app.processID)) \(app.name)")
        }
        return apps
    }

    /// 録音を止め、文字起こし・候補抽出の残りを処理してファイルを閉じる。すべて成功なら true。
    /// 停止待ちの間に届いた失敗、起動の失敗、WAV の書き込み失敗、各プロセスの異常終了も反映する。
    func stop() async -> Bool {
        let task = lock.withLock {
            if let stopTask { return stopTask }
            let task = Task.detached { [self] in await cleanUp() }
            stopTask = task
            return task
        }
        return await task.value
    }

    private func cleanUp() async -> Bool {
        let result = await recorder.stop()
        // 録音を止めると入力が閉じられ、文字起こしプロセスは残りを処理してから終わる
        var transcriberFailed = false
        if !transcribers.isEmpty {
            print("\n文字起こしの残りを処理中...")
            for (track, transcriber) in transcribers {
                let exit = await transcriber.finish()
                if !report(exit, of: "[\(track.rawValue)] 文字起こしプロセス") { transcriberFailed = true }
                // Swift 側の変換で流せなかった音声があれば、文字起こしは欠けている
                if transcriber.conversionFailed {
                    fputs("[\(track.rawValue)] 文字起こし用の変換に失敗した音声がある\n", stderr)
                    transcriberFailed = true
                }
            }
        }
        // 文字起こしが出し切られてから入力を閉じ、候補抽出プロセスは残りを処理してから終わる
        var extractorFailed = false
        if let extractor {
            print("\n候補の抽出の残りを処理中...")
            extractorFailed = !report(await extractor.finish(), of: "候補抽出プロセス")
        }
        // 起動の失敗は stop() の結果から出す。先に停止が始まっていても取りこぼさない
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
        // 読む用の議事録。中身は transcript / candidates と同じなので、書けなくても音声の扱いは変えない
        var minutesFailed = false
        if let transcript {
            let url = minutesDir.appendingPathComponent("minutes-\(stamp).md")
            do {
                try FileManager.default.createDirectory(at: minutesDir, withIntermediateDirectories: true)
                try transcript.minutes(startedAt: startedAt, candidates: candidateLog?.candidates ?? [])
                    .write(to: url, atomically: true, encoding: .utf8)
                print("[議事録] \(url.path)")
            } catch {
                fputs("議事録を書けない: \(url.path): \(error)\n", stderr)
                minutesFailed = true
            }
        }
        var deleteFailed = false
        // 文字起こしに失敗があっても消す。残すのは --keep-audio を付けたときだけ。
        // 存在を確かめてから消すと、確かめられないだけのファイルを見逃すので、両方消しに行き、無かったときだけ無視する
        if transcript != nil, !keepAudio {
            var deleted = 0
            for url in [result.app.url, result.mic.url] {
                do {
                    try FileManager.default.removeItem(at: url)
                    deleted += 1
                } catch CocoaError.fileNoSuchFile {
                    continue
                } catch {
                    fputs("音声を消せない: \(url.path): \(error)\n", stderr)
                    deleteFailed = true
                }
            }
            if deleted > 0, !deleteFailed { print("音声を消した（残すときは --keep-audio）") }
        }
        let failed = result.startError != nil || result.app.writeError != nil || result.mic.writeError != nil
            || transcriberFailed || transcriptFailed || extractorFailed || candidateLogFailed || minutesFailed || deleteFailed
        return !failed
    }
}
