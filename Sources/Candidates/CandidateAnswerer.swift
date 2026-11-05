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

    /// 問いを出した録音（ファイル名の <日時>）。答えにそのまま返してもらい、保存先を決める
    public let meeting: String
    public let at: Double
    public let question: String
    public let quote: String
    public let context: [Utterance]

    public init(meeting: String, candidate: Candidate, context: [Utterance]) {
        self.meeting = meeting
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

    /// 問いを出した録音。古い answers ファイルの行には無い
    public let meeting: String?
    public let at: Double
    public let question: String
    /// 会議でそのまま口にできる形の答え
    public let answer: String
    /// high：コードで直接確かめた、medium：強く推定できる、low：見つからない・判断できない
    public let confidence: String
    public let sources: [Source]
}

/// 調べられなかった問い1件。
public struct AnswerFailure: Sendable, Codable {
    public let meeting: String?
    public let at: Double
    public let question: String
    public let error: String
}

/// 調査プロセスの出力1行。`error` があれば失敗、無ければ答え。
public enum AnswerResult: Sendable, Decodable {
    case answered(Answer)
    case failed(AnswerFailure)

    public init(from decoder: Decoder) throws {
        if let failure = try? AnswerFailure(from: decoder) {
            self = .failed(failure)
        } else {
            self = .answered(try Answer(from: decoder))
        }
    }
}

/// 外部の調査プロセスを1つ起動し、問いを渡して答えを受け取る。
///
/// 受け渡しの約束:
/// - 標準入力：問い1件につき1行の JSON（`AnswerRequest`）。`{"meeting", "at", "question", "quote", "context": [{"speaker", "start", "text"}]}`。
///   終わるときに閉じられる。閉じられたら受け取った分を処理して終了する
/// - 標準出力：問い1件につき1行の JSON。`meeting`・`at`・`question` は問いのものをそのまま返す
///   - 答え（`Answer`）：`{"meeting", "at", "question", "answer", "confidence", "sources": [{"path", "line"}]}`
///   - 調べられなかったとき（`AnswerFailure`）：`{"meeting", "at", "question", "error"}`
/// - 標準エラー：そのまま端末に出す。ログや進捗用
/// - コマンドは /bin/sh -c で実行する
public final class CandidateAnswerer: @unchecked Sendable {
    private let process: JSONLinesProcess<AnswerResult>

    /// - Parameters:
    ///   - command: /bin/sh -c で実行するコマンド
    ///   - onAnswer: 1件受け取るたびに呼ばれる。読み取り用のスレッドから呼ばれる
    public init(command: String, onAnswer: @escaping @Sendable (AnswerResult) -> Void) {
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

    /// 調査プロセスが終わるのを待つ。標準入力は閉じない
    public func waitForExit() async {
        await process.waitForExit()
    }

    /// 標準入力を閉じ、受け取った問いの処理と出力の読み取りが終わるのを待つ。
    public func finish() async -> ProcessExit {
        await process.finish()
    }
}
