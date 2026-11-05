import Candidates
import Foundation

/// 抽出された候補を端末に流しつつ JSON Lines のファイルに書き足す。
final class CandidateLog: @unchecked Sendable {
    private let file: JSONLinesFile
    private let queue = DispatchQueue(label: "candidates")
    private var received: [Candidate] = []

    /// これまでに届いた候補（議事録用）
    var candidates: [Candidate] { queue.sync { received } }

    init(url: URL) throws {
        file = try JSONLinesFile(url: url, name: "candidates")
    }

    func append(_ candidate: Candidate) {
        queue.sync {
            print("[候補 \(formatTime(candidate.at))] \(candidate.question)\n    「\(candidate.quote)」")
            received.append(candidate)
            guard let line = try? JSONLinesFile.encode(candidate) else { return }
            file.append(line)
        }
    }

    /// ファイルを閉じて概要を返す。書き込みに1回でも失敗していれば failed になる。
    func close() -> (description: String, failed: Bool) {
        file.close()
    }
}
