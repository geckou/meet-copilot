import Foundation

/// 録音開始からの秒数を [mm:ss.s] の形にする。
func formatTime(_ seconds: Double) -> String {
    let minutes = Int(seconds) / 60
    return String(format: "%02d:%04.1f", minutes, seconds - Double(minutes * 60))
}

/// 1行1件の JSON を書き足していくファイル。transcript・candidates・answers の共通部分。
/// 書き込みに失敗しても続けるが、欠けたことは close() で失敗として返す。
final class JSONLinesFile: @unchecked Sendable {
    let url: URL
    /// エラーメッセージと概要に出す名前（例：「transcript」）
    let name: String
    private let queue: DispatchQueue
    private let handle: FileHandle
    private var count = 0
    private var writeError: Error?

    /// - Parameter appending: true なら既存の内容の後ろに書き足す。false なら空にして作り直す
    init(url: URL, name: String, appending: Bool = false) throws {
        self.url = url
        self.name = name
        self.queue = DispatchQueue(label: "jsonl.\(name)")
        if !appending || !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        self.handle = try FileHandle(forWritingTo: url)
        if appending { try handle.seekToEnd() }
    }

    /// JSON 1件（改行なし）を書き足す。呼んだ順に書かれる。
    func append(_ line: Data) {
        queue.sync {
            do {
                try handle.write(contentsOf: line + [UInt8(ascii: "\n")])
                count += 1
            } catch {
                // 端末には出ているので続けるが、ファイルが欠けたことは終了時に失敗として扱う
                if writeError == nil { writeError = error }
                fputs("\(name) の書き込み失敗: \(error)\n", stderr)
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
            var description = "[\(name)] \(count) 件, \(url.path)"
            if let writeError {
                description += "\n  書き込み失敗で欠けている: \(writeError)"
            }
            return (description, failed)
        }
    }

    /// 1行1件の JSON ファイルを読む。読めない行は飛ばす。ファイルが無ければ空。
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(T.self, from: $0) }
    }
}
