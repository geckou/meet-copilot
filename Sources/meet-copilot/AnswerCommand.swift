import Candidates
import ExternalProcess
import Foundation

struct AnswerOptions {
    var repos: [String] = []
    var outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var answerer: String?
}

func parseAnswerOptions(_ arguments: ArraySlice<String>) -> AnswerOptions {
    var options = AnswerOptions()
    var args = arguments.makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--repo":
            guard let v = args.next(), !v.isEmpty else { fail("--repo に値がない") }
            let path = URL(fileURLWithPath: (v as NSString).expandingTildeInPath).standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                fail("--repo がディレクトリでない: \(v)")
            }
            options.repos.append(path)
        case "--out":
            guard let v = args.next() else { fail("--out に値がない") }
            options.outputDir = URL(fileURLWithPath: v)
        case "--answerer":
            guard let v = args.next(), !v.isEmpty else { fail("--answerer に値がない") }
            options.answerer = v
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            fail("不明な引数: \(arg)\n\(usage)")
        }
    }
    if options.repos.isEmpty, options.answerer == nil {
        fail("--repo が要る")
    }
    return options
}

/// transcript-<日時>.jsonl の1行。前後のやり取りとして渡す分だけ読む。
private struct TranscriptRow: Decodable {
    let speaker: String
    let start: Double
    let text: String
}

/// 録音1回分（同じ <日時> の candidates / transcript / answers）のファイル。
private struct Meeting {
    let stamp: String
    let candidatesURL: URL
    let transcriptURL: URL
    let answersURL: URL

    /// 出力ディレクトリのうち、いちばん新しい録音。<日時> は「秒までの日時-ランダムな接尾辞」なので、
    /// 秒までの日時で比べ、同じ秒ならファイルの作成日時で比べる
    static func latest(in dir: URL) -> Meeting? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let secondPrefix = "candidates-yyyyMMdd-HHmmss".count
        func created(_ name: String) -> Date {
            let path = dir.appendingPathComponent(name).path
            return (try? FileManager.default.attributesOfItem(atPath: path)[.creationDate] as? Date) ?? .distantPast
        }
        let candidateFiles = names.filter { $0.hasPrefix("candidates-") && $0.hasSuffix(".jsonl") }
        guard let name = candidateFiles.max(by: { a, b in
            let (secondA, secondB) = (a.prefix(secondPrefix), b.prefix(secondPrefix))
            if secondA != secondB { return secondA < secondB }
            return (created(a), a) < (created(b), b)
        }) else { return nil }
        let stamp = String(name.dropFirst("candidates-".count).dropLast(".jsonl".count))
        return Meeting(
            stamp: stamp,
            candidatesURL: dir.appendingPathComponent(name),
            transcriptURL: dir.appendingPathComponent("transcript-\(stamp).jsonl"),
            answersURL: answersURL(in: dir, stamp: stamp)
        )
    }

    static func answersURL(in dir: URL, stamp: String) -> URL {
        dir.appendingPathComponent("answers-\(stamp).jsonl")
    }
}

/// 候補を一覧し、選ばれたものだけを調査プロセスに渡して答えを出す。調べに行くのは必ずユーザーの操作が起点。
private final class AnswerSession: @unchecked Sendable {
    /// 候補の前後のやり取りとして渡す範囲（候補の発言の開始からの秒数）
    static let contextBefore: Double = 120
    static let contextAfter: Double = 30

    private let outputDir: URL
    private let lock = NSLock()
    // 以下は lock の中で触る
    private var meeting: Meeting?
    private var answers: JSONLinesFile?
    private var candidates: [Candidate] = []
    private var answered: Set<String> = []
    private var inProgress: Set<String> = []
    private var failed: Set<String> = []
    private var answersFailed = false

    init(outputDir: URL) {
        self.outputDir = outputDir
    }

    private static func key(_ at: Double, _ question: String) -> String { "\(at)\u{1F}\(question)" }

    /// いちばん新しい録音の候補を読み直す。新しい録音が始まっていれば、そちらに切り替える
    func refresh() {
        lock.withLock {
            guard let latest = Meeting.latest(in: outputDir) else { return }
            if latest.stamp != meeting?.stamp {
                closeAnswers()
                do {
                    answers = try JSONLinesFile(url: latest.answersURL, name: "answers", appending: true)
                } catch {
                    fputs("answers のファイルを開けない: \(error)\n", stderr)
                    answers = nil
                    answersFailed = true
                }
                meeting = latest
                answered = Set(JSONLinesFile.read(Answer.self, from: latest.answersURL).map { Self.key($0.at, $0.question) })
                inProgress = []
                failed = []
            }
            candidates = JSONLinesFile.read(Candidate.self, from: latest.candidatesURL)
        }
    }

    func printList() {
        lock.withLock {
            guard let meeting else {
                print("\n候補のファイル（candidates-*.jsonl）がまだない: \(outputDir.path)")
                return
            }
            print("\n--- 候補（\(meeting.stamp)）---")
            if candidates.isEmpty { print("  まだない") }
            for (index, candidate) in candidates.enumerated() {
                let key = Self.key(candidate.at, candidate.question)
                let mark = answered.contains(key) ? " ✓"
                    : inProgress.contains(key) ? " …調査中"
                    : failed.contains(key) ? " ✗ 失敗" : ""
                print(String(format: "%3d. ", index + 1) + "[\(formatTime(candidate.at))] \(candidate.question)\(mark)")
            }
        }
    }

    enum Selection {
        case request(AnswerRequest)
        /// 調べている途中。同じ問いを二重に渡さない
        case inProgress(String)
        case outOfRange
    }

    /// 番号の候補を調査プロセスに渡す形にする。番号は最後に表示した一覧のもの
    func select(number: Int) -> Selection {
        lock.withLock {
            guard let meeting, candidates.indices.contains(number - 1) else { return .outOfRange }
            let candidate = candidates[number - 1]
            let key = Self.key(candidate.at, candidate.question)
            if inProgress.contains(key) { return .inProgress(candidate.question) }
            let range = (candidate.at - Self.contextBefore)...(candidate.at + Self.contextAfter)
            let context = JSONLinesFile.read(TranscriptRow.self, from: meeting.transcriptURL)
                .filter { range.contains($0.start) }
                .map { AnswerRequest.Utterance(speaker: $0.speaker, start: $0.start, text: $0.text) }
            inProgress.insert(key)
            failed.remove(key)
            return .request(AnswerRequest(meeting: meeting.stamp, candidate: candidate, context: context))
        }
    }

    func receive(_ result: AnswerResult) {
        lock.withLock {
            switch result {
            case .answered(let answer):
                let key = Self.key(answer.at, answer.question)
                // 調べている間に録音が切り替わっていたら、問いを出した録音のファイルに書く
                let current = answer.meeting == nil || answer.meeting == meeting?.stamp
                if current {
                    inProgress.remove(key)
                    answered.insert(key)
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                if let line = try? encoder.encode(answer) {
                    if current {
                        answers?.append(line)
                    } else if let stamp = answer.meeting {
                        appendAnswer(line, toMeeting: stamp)
                    }
                }

                let sources = answer.sources.map { source in source.line.map { "\(source.path):\($0)" } ?? source.path }
                print("\n=== 回答 [\(formatTime(answer.at))] \(answer.question)（確度: \(answer.confidence)）"
                    + (current ? "" : "（録音 \(answer.meeting ?? "")）"))
                print(answer.answer)
                if !sources.isEmpty { print("根拠: " + sources.joined(separator: ", ")) }
            case .failed(let failure):
                let key = Self.key(failure.at, failure.question)
                let current = failure.meeting == nil || failure.meeting == meeting?.stamp
                if current {
                    inProgress.remove(key)
                    failed.insert(key)
                }
                print("\n=== 調査失敗 [\(formatTime(failure.at))] \(failure.question)"
                    + (current ? "" : "（録音 \(failure.meeting ?? "")）"))
                print(failure.error)
            }
            print("> ", terminator: "")
            fflush(stdout)
        }
    }

    /// いま開いていない録音の answers ファイルに1件書き足す
    private func appendAnswer(_ line: Data, toMeeting stamp: String) {
        do {
            let file = try JSONLinesFile(url: Meeting.answersURL(in: outputDir, stamp: stamp), name: "answers", appending: true)
            file.append(line)
            let summary = file.close()
            if summary.failed {
                fputs(summary.description + "\n", stderr)
                answersFailed = true
            }
        } catch {
            fputs("answers のファイルを開けない: \(error)\n", stderr)
            answersFailed = true
        }
    }

    /// answers のファイルを閉じる。書き込みに失敗していれば false
    func close() -> Bool {
        lock.withLock {
            closeAnswers()
            return !answersFailed
        }
    }

    private func closeAnswers() {
        guard let answers else { return }
        let summary = answers.close()
        print(summary.description)
        if summary.failed { answersFailed = true }
        self.answers = nil
    }
}

func answer(_ options: AnswerOptions) -> Never {
    let command = options.answerer
        ?? ([scriptCommand("answer_question.py")] + options.repos.flatMap { ["--repo", shellQuote($0)] }).joined(separator: " ")
    let session = AnswerSession(outputDir: options.outputDir)
    let answerer = CandidateAnswerer(command: command) { session.receive($0) }
    do {
        try answerer.start()
    } catch {
        fail("調査プロセスを起動できない: \(error)")
    }

    if !options.repos.isEmpty {
        print("調べる対象: " + options.repos.joined(separator: ", "))
    }

    // q・入力の終わり・Ctrl-C・調査プロセスの終了のどれでも、受け取った問いを調べ終えてから閉じる。
    // 問いの送信も finishing の中で行い、終了処理が始まった後は新しい問いを渡さない
    let finishing = NSLock()
    nonisolated(unsafe) var finished = false
    @Sendable func finish(exitCode: Int32 = 0) {
        guard finishing.withLock({ defer { finished = true }; return !finished }) else { return }
        print("\n調査の残りを処理中...")
        Task.detached {
            let succeeded = report(await answerer.finish(), of: "調査プロセス")
            let closed = session.close()
            exit(succeeded && closed ? exitCode : 1)
        }
    }

    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { finish() }
    sigint.resume()

    // 調査プロセスが先に終わったら（claude が見つからないなど）、問いを受けても答えは返らないので終える
    Task.detached {
        await answerer.waitForExit()
        let unexpected = finishing.withLock { !finished }
        if unexpected { fputs("\n調査プロセスが終了した\n", stderr) }
        DispatchQueue.main.async { finish(exitCode: unexpected ? 1 : 0) }
    }

    // 入力待ちで止まるので別スレッドで読む。メインは Ctrl-C を受けるために空けておく
    Thread.detachNewThread {
        session.refresh()
        session.printList()
        while true {
            print("番号で調べる / Enter で一覧を更新 / q で終了 > ", terminator: "")
            fflush(stdout)
            guard let line = readLine()?.trimmingCharacters(in: .whitespaces), line != "q" else { break }
            // 一覧の更新と録音の切り替えは Enter のときだけ。番号は表示済みの一覧で解決する
            if line.isEmpty {
                session.refresh()
                session.printList()
                continue
            }
            let accepted = finishing.withLock {
                guard !finished else { return false }
                switch Int(line).map(session.select(number:)) ?? .outOfRange {
                case .request(let request):
                    print("調査中: \(request.question)")
                    answerer.ask(request)
                case .inProgress(let question):
                    print("まだ調査中: \(question)")
                case .outOfRange:
                    print("一覧の番号を入れる: \(line)")
                }
                return true
            }
            if !accepted {
                print("終了処理中のため受け付けない: \(line)")
                return
            }
        }
        DispatchQueue.main.async { finish() }
    }

    withExtendedLifetime(sigint) { dispatchMain() }
}
