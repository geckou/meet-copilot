import ExternalProcess
import Foundation

/// 調べる問い1件。候補と、その前後のやり取り。
public struct AnswerRequest: Sendable, Encodable {
    public struct Utterance: Sendable, Codable {
        public let speaker: String
        public let start: Double
        public let text: String

        public init(speaker: String, start: Double, text: String) {
            self.speaker = speaker
            self.start = start
            self.text = text
        }
    }

    public let at: Double
    public let question: String
    public let quote: String
    public let context: [Utterance]

    public init(candidate: Candidate, context: [Utterance]) {
        self.at = candidate.at
        self.question = candidate.question
        self.quote = candidate.quote
        self.context = context
    }
}

/// 調べた答え1件。
public struct Answer: Sendable, Codable {
    public struct Source: Sendable, Codable {
        /// リポジトリからの相対パス
        public let path: String
        public let line: Int?
    }

    public let at: Double
    public let question: String
    /// 会議でそのまま口にできる形の答え
    public let answer: String
    /// high：コードで直接確かめた、medium：強く推定できる、low：見つからない・判断できない
    public let confidence: String
    public let sources: [Source]
}

/// 外部の調査プロセスを1つ起動し、問いを渡して答えを受け取る。
///
/// 受け渡しの約束（調べる仕組みを差し替えるときもこれを守る）:
/// - 標準入力：問い1件につき1行の JSON（`AnswerRequest`）。`{"at", "question", "quote", "context": [{"speaker", "start", "text"}]}`。
///   終わるときに閉じられる。閉じられたら受け取った分を処理して終了する
/// - 標準出力：答え1件につき1行の JSON（`Answer`）。`{"at", "question", "answer", "confidence", "sources": [{"path", "line"}]}`
/// - 標準エラー：そのまま端末に出す。ログや進捗用
/// - コマンドは /bin/sh -c で実行する
public final class CandidateAnswerer: @unchecked Sendable {
    private let process: JSONLinesProcess<Answer>

    /// - Parameters:
    ///   - command: /bin/sh -c で実行するコマンド
    ///   - onAnswer: 1件受け取るたびに呼ばれる。読み取り用のスレッドから呼ばれる
    public init(command: String, onAnswer: @escaping @Sendable (Answer) -> Void) {
        process = JSONLinesProcess(name: "調査プロセス", command: command, onOutput: onAnswer)
    }

    public func start() throws {
        try process.start()
    }

    /// 問いを1件渡す。書き込みは別キューで行うので、呼び出し元は詰まらない
    public func ask(_ request: AnswerRequest) {
        guard let line = try? JSONEncoder().encode(request) else { return }
        process.write(line + [UInt8(ascii: "\n")])
    }

    /// 標準入力を閉じ、受け取った問いの処理と出力の読み取りが終わるのを待つ。
    public func finish() async -> ProcessExit {
        await process.finish()
    }
}
