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

    /// 出力ディレクトリのうち、いちばん新しい録音。ファイル名の <日時> は時刻順に並ぶ
    static func latest(in dir: URL) -> Meeting? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let name = names.filter({ $0.hasPrefix("candidates-") && $0.hasSuffix(".jsonl") }).max() else { return nil }
        let stamp = String(name.dropFirst("candidates-".count).dropLast(".jsonl".count))
        return Meeting(
            stamp: stamp,
            candidatesURL: dir.appendingPathComponent(name),
            transcriptURL: dir.appendingPathComponent("transcript-\(stamp).jsonl"),
            answersURL: dir.appendingPathComponent("answers-\(stamp).jsonl")
        )
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
                let mark = answered.contains(key) ? " ✓" : inProgress.contains(key) ? " …調査中" : ""
                print(String(format: "%3d. ", index + 1) + "[\(formatTime(candidate.at))] \(candidate.question)\(mark)")
            }
        }
    }

    /// 番号の候補を調査プロセスに渡す形にする。範囲外なら nil
    func request(number: Int) -> AnswerRequest? {
        lock.withLock {
            guard let meeting, candidates.indices.contains(number - 1) else { return nil }
            let candidate = candidates[number - 1]
            let range = (candidate.at - Self.contextBefore)...(candidate.at + Self.contextAfter)
            let context = JSONLinesFile.read(TranscriptRow.self, from: meeting.transcriptURL)
                .filter { range.contains($0.start) }
                .map { AnswerRequest.Utterance(speaker: $0.speaker, start: $0.start, text: $0.text) }
            inProgress.insert(Self.key(candidate.at, candidate.question))
            return AnswerRequest(candidate: candidate, context: context)
        }
    }

    func receive(_ answer: Answer) {
        lock.withLock {
            let key = Self.key(answer.at, answer.question)
            inProgress.remove(key)
            answered.insert(key)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let line = try? encoder.encode(answer) { answers?.append(line) }

            let sources = answer.sources.map { source in source.line.map { "\(source.path):\($0)" } ?? source.path }
            print("\n=== 回答 [\(formatTime(answer.at))] \(answer.question)（確度: \(answer.confidence)）")
            print(answer.answer)
            if !sources.isEmpty { print("根拠: " + sources.joined(separator: ", ")) }
            print("> ", terminator: "")
            fflush(stdout)
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
    session.refresh()
    session.printList()
    while true {
        print("番号で調べる / Enter で一覧を更新 / q で終了 > ", terminator: "")
        fflush(stdout)
        guard let line = readLine()?.trimmingCharacters(in: .whitespaces), line != "q" else { break }
        session.refresh()
        if line.isEmpty {
            session.printList()
            continue
        }
        guard let number = Int(line), let request = session.request(number: number) else {
            print("一覧の番号を入れる: \(line)")
            continue
        }
        print("調査中: \(request.question)")
        answerer.ask(request)
    }

    // 受け取った問いを調べ終えてから閉じる
    print("\n調査の残りを処理中...")
    Task.detached {
        let succeeded = report(await answerer.finish(), of: "調査プロセス")
        let closed = session.close()
        exit(succeeded && closed ? 0 : 1)
    }
    dispatchMain()
}
