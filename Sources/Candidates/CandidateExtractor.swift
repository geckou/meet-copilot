import ExternalProcess
import Foundation

/// 候補抽出プロセスが返す1件分の候補。
public struct Candidate: Sendable, Codable, Equatable {
    /// 根拠になった相手の発言の開始時刻（録音開始からの秒数）
    public let at: Double
    /// 調べる人が単独で読んで分かる形の問い
    public let question: String
    /// 根拠になった相手の発言
    public let quote: String
}

/// 外部の候補抽出プロセスを1つ起動し、文字起こしの結果を流し込んで候補を受け取る。
///
/// 受け渡しの約束（抽出の仕組みを差し替えるときもこれを守る）:
/// - 標準入力：文字起こし1件につき1行の JSON。transcript-<日時>.jsonl の行と同じ形
///   （`{"speaker", "track", "start", "end", "text"}`）。録音を止めて文字起こしが終わると閉じられる。
///   閉じられたら残りを処理して終了する
/// - 標準出力：候補1件につき1行の JSON。`{"at": 秒, "question": "...", "quote": "..."}`
/// - 標準エラー：そのまま端末に出す。ログや進捗用
/// - コマンドは /bin/sh -c で実行する
public final class CandidateExtractor: @unchecked Sendable {
    private let process: JSONLinesProcess<Candidate>

    /// - Parameters:
    ///   - command: /bin/sh -c で実行するコマンド
    ///   - onCandidate: 1件受け取るたびに呼ばれる。読み取り用のスレッドから呼ばれる
    public init(command: String, onCandidate: @escaping @Sendable (Candidate) -> Void) {
        process = JSONLinesProcess(name: "候補抽出プロセス", command: command, onOutput: onCandidate)
    }

    public func start() throws {
        try process.start()
    }

    /// 文字起こし1件分の JSON（改行なし）を渡す。書き込みは別キューで行うので、呼び出し元は詰まらない
    public func send(_ line: Data) {
        process.write(line + [UInt8(ascii: "\n")])
    }

    /// 標準入力を閉じ、残りの処理と出力の読み取りが終わるのを待つ。
    public func finish() async -> ProcessExit {
        await process.finish()
    }
}
