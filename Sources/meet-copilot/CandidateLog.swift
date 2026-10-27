import Candidates
import Foundation

/// 抽出された候補を端末に流しつつ JSON Lines のファイルに書き足す。
final class CandidateLog: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "candidates")
    private let handle: FileHandle
    private var count = 0
    private var writeError: Error?

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    func append(_ candidate: Candidate) {
        queue.sync {
            print("[候補 \(formatTime(candidate.at))] \(candidate.question)\n    「\(candidate.quote)」")
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                try handle.write(contentsOf: try encoder.encode(candidate) + [UInt8(ascii: "\n")])
                count += 1
            } catch {
                // 端末には出ているので続けるが、ファイルが欠けたことは終了時に失敗として扱う
                if writeError == nil { writeError = error }
                fputs("候補の書き込み失敗: \(error)\n", stderr)
            }
        }
    }

    /// ファイルを閉じて概要を返す。書き込みに1回でも失敗していれば failed になる。
    func close() -> (description: String, failed: Bool) {
        queue.sync {
            var failed = writeError != nil
            do {
                try handle.close()
            } catch {
                if writeError == nil { writeError = error }
                failed = true
            }
            var description = "[candidates] \(count) 件, \(url.path)"
            if let writeError {
                description += "\n  書き込み失敗で欠けている: \(writeError)"
            }
            return (description, failed)
        }
    }
}
