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

/// 候補抽出プロセスの終わり方。
public struct ExtractorExit: Sendable {
    public let status: Int32
    /// プロセスが途中で入力を閉じるなどして、渡せなかった発言がある
    public let inputDropped: Bool
    /// 標準出力のうち、約束の JSON として読めずに捨てた行の数
    public let undecodableLines: Int

    public var succeeded: Bool { status == 0 && !inputDropped && undecodableLines == 0 }
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
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let writeQueue = DispatchQueue(label: "candidates.write")
    private let onCandidate: @Sendable (Candidate) -> Void
    private let readDone = DispatchGroup()
    // 以下は writeQueue からのみ触る
    private var writeFailed = false
    // 読み取り用のスレッドからのみ触る。読み取りの終わり（readDone）を待ってから読む
    private var undecodableLines = 0

    /// - Parameters:
    ///   - command: /bin/sh -c で実行するコマンド
    ///   - onCandidate: 1件受け取るたびに呼ばれる。読み取り用のスレッドから呼ばれる
    public init(command: String, onCandidate: @escaping @Sendable (Candidate) -> Void) {
        self.onCandidate = onCandidate
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError
    }

    public func start() throws {
        // 子プロセスが先に終わったとき、パイプへの書き込みで SIGPIPE を受けて自分ごと落ちるのを防ぐ
        signal(SIGPIPE, SIG_IGN)
        try process.run()

        readDone.enter()
        let handle = stdoutPipe.fileHandleForReading
        Thread.detachNewThread { [self] in
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = pending[pending.startIndex..<newline]
                    pending.removeSubrange(pending.startIndex...newline)
                    handleLine(line)
                }
            }
            if !pending.isEmpty { handleLine(pending) }
            readDone.leave()
        }
    }

    /// 文字起こし1件分の JSON（改行なし）を渡す。書き込みは別キューで行うので、呼び出し元は詰まらない
    public func send(_ line: Data) {
        var data = line
        data.append(UInt8(ascii: "\n"))
        let input = stdinPipe.fileHandleForWriting
        writeQueue.async { [self] in
            guard !writeFailed else { return }
            do {
                try input.write(contentsOf: data)
            } catch {
                writeFailed = true
                fputs("候補抽出プロセスへの書き込み失敗。以降の発言は渡さない: \(error)\n", stderr)
            }
        }
    }

    /// 標準入力を閉じ、残りの処理と出力の読み取りが終わるのを待つ。
    public func finish() async -> ExtractorExit {
        let input = stdinPipe.fileHandleForWriting
        let process = self.process
        let readDone = self.readDone
        return await withCheckedContinuation { continuation in
            writeQueue.async { [self] in
                let inputDropped = writeFailed
                try? input.close()
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    readDone.wait()
                    continuation.resume(returning: ExtractorExit(
                        status: process.terminationStatus,
                        inputDropped: inputDropped,
                        undecodableLines: self.undecodableLines
                    ))
                }
            }
        }
    }

    private func handleLine(_ line: Data) {
        guard line.contains(where: { !(($0 == 0x20) || ($0 == 0x09) || ($0 == 0x0A) || ($0 == 0x0D)) }) else { return }
        do {
            onCandidate(try JSONDecoder().decode(Candidate.self, from: line))
        } catch {
            // 読めない行は捨てて続きを読むが、取りこぼしとして終了時に失敗にする
            undecodableLines += 1
            fputs("候補抽出プロセスの出力を読めない: \(String(decoding: line, as: UTF8.self))\n", stderr)
        }
    }
}
