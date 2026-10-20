import Foundation

/// 外部プロセスの終わり方。
public struct ProcessExit: Sendable {
    /// プロセスの終了コード
    public let status: Int32
    /// プロセスが途中で入力を閉じるなどして、渡せなかった入力がある
    public let inputDropped: Bool
    /// 標準出力のうち、約束の JSON として読めずに捨てた行の数
    public let undecodableLines: Int

    public var succeeded: Bool { status == 0 && !inputDropped && undecodableLines == 0 }
}

/// 外部プロセスを1つ起動し、標準入力にバイト列を流し込み、標準出力から1行1件の JSON を受け取る。
/// 文字起こし・候補抽出など、処理を外部に任せる部分の共通の土台。
///
/// - コマンドは /bin/sh -c で実行する
/// - 標準エラーはそのまま端末に出す（ログや進捗用）
/// - 標準入力への書き込みは専用のキューで行うので、呼び出し元は子プロセスが遅くても詰まらない
/// - JSON として読めない行は捨てて続きを読み、終了時に失敗として返す
public final class JSONLinesProcess<Output: Decodable & Sendable>: @unchecked Sendable {
    /// エラーメッセージに出す名前（例：「文字起こしプロセス」）
    public let name: String

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let writeQueue: DispatchQueue
    private let onOutput: @Sendable (Output) -> Void
    private let readDone = DispatchGroup()
    /// 子プロセスの終了。waitUntilExit() はバックグラウンドのスレッドから呼ぶと、終了済みでも戻らないことがある（実測）ので使わない
    private let exited = DispatchGroup()
    // 以下は writeQueue からのみ触る
    private var writeFailed = false
    // 読み取り用のスレッドからのみ触る。読み取りの終わり（readDone）を待ってから読む
    private var undecodableLines = 0

    /// - Parameters:
    ///   - name: エラーメッセージに出す名前
    ///   - command: /bin/sh -c で実行するコマンド
    ///   - environment: 現在の環境変数に足す値
    ///   - onOutput: 1件受け取るたびに呼ばれる。読み取り用のスレッドから、届いた順に呼ばれる
    public init(
        name: String,
        command: String,
        environment: [String: String] = [:],
        onOutput: @escaping @Sendable (Output) -> Void
    ) {
        self.name = name
        self.writeQueue = DispatchQueue(label: "external-process.write")
        self.onOutput = onOutput
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError
    }

    public func start() throws {
        // 子プロセスが先に終わったとき、パイプへの書き込みで SIGPIPE を受けて自分ごと落ちるのを防ぐ。
        // 無視すると書き込みは EPIPE のエラーとして返る
        signal(SIGPIPE, SIG_IGN)
        exited.enter()
        process.terminationHandler = { [exited] _ in exited.leave() }
        do {
            try process.run()
        } catch {
            exited.leave()
            throw error
        }

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

    /// 標準入力にそのまま書き込む。書き込みは呼んだ順に行われる。
    /// 一度失敗したら（子プロセスが入力を閉じたなど）以降は捨て、終了時に inputDropped として返す
    public func write(_ data: Data) {
        let input = stdinPipe.fileHandleForWriting
        writeQueue.async { [self] in
            guard !writeFailed else { return }
            do {
                try input.write(contentsOf: data)
            } catch {
                writeFailed = true
                fputs("\(name)への書き込み失敗。以降の入力は渡さない: \(error)\n", stderr)
            }
        }
    }

    /// それまでに write() したものを書き終えてから標準入力を閉じ、子プロセスの終了と出力の読み取りが終わるのを待つ。
    public func finish() async -> ProcessExit {
        let input = stdinPipe.fileHandleForWriting
        let process = self.process
        let readDone = self.readDone
        let exited = self.exited
        return await withCheckedContinuation { continuation in
            writeQueue.async { [self] in
                let inputDropped = writeFailed
                try? input.close()
                DispatchQueue.global().async {
                    exited.wait()
                    readDone.wait()
                    continuation.resume(returning: ProcessExit(
                        status: process.terminationStatus,
                        inputDropped: inputDropped,
                        undecodableLines: self.undecodableLines
                    ))
                }
            }
        }
    }

    private func handleLine(_ line: Data) {
        guard line.contains(where: { !Self.isASCIIWhitespace($0) }) else { return }
        do {
            onOutput(try JSONDecoder().decode(Output.self, from: line))
        } catch {
            // 読めない行は捨てて続きを読むが、取りこぼしとして終了時に失敗にする
            undecodableLines += 1
            fputs("\(name)の出力を読めない: \(String(decoding: line, as: UTF8.self))\n", stderr)
        }
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
