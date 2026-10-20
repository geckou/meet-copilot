import AVFoundation
import Foundation

/// 文字起こしプロセスの終わり方。
public struct TranscriberExit: Sendable {
    /// プロセスの終了コード
    public let status: Int32
    /// プロセスが途中で入力を閉じるなどして、渡せなかった音声がある
    public let audioDropped: Bool

    public var succeeded: Bool { status == 0 && !audioDropped }
}

/// 文字起こしプロセスが返す1件分の発話。時刻はそのプロセスに流し始めた時点からの秒数。
public struct Utterance: Sendable, Decodable {
    public let start: Double
    public let end: Double
    public let text: String
}

/// 外部の文字起こしプロセスを1つ起動し、音声を流し込んで結果を受け取る。
///
/// 受け渡しの約束（文字起こしの仕組みを差し替えるときもこれを守る）:
/// - 標準入力：16kHz・モノラル・16bit 符号付き・リトルエンディアンの生 PCM。録音中は途切れなく流れ続け、
///   録音を止めると閉じられる。閉じられたら残りを処理して終了する
/// - 標準出力：1行1件の JSON。`{"start": 秒, "end": 秒, "text": "..."}`。時刻は流し始めからの秒数
/// - 標準エラー：そのまま端末に出す。ログや進捗用
/// - コマンドは /bin/sh -c で実行する
public final class TranscriberProcess: @unchecked Sendable {
    public static let sampleRate: Double = 16_000

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let writeQueue: DispatchQueue
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true
    )!
    private let onUtterance: @Sendable (Utterance) -> Void
    private let readDone = DispatchGroup()
    // 以下は append() を呼ぶ音声スレッドからのみ触る
    private var converter: AVAudioConverter?
    // 以下は writeQueue からのみ触る
    private var writeFailed = false

    /// - Parameters:
    ///   - command: /bin/sh -c で実行するコマンド
    ///   - environment: 現在の環境変数に足す値
    ///   - onUtterance: 1件受け取るたびに呼ばれる。読み取り用のスレッドから呼ばれる
    public init(
        label: String,
        command: String,
        environment: [String: String] = [:],
        onUtterance: @escaping @Sendable (Utterance) -> Void
    ) {
        self.writeQueue = DispatchQueue(label: "transcriber.\(label).write")
        self.onUtterance = onUtterance
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

    /// 録音のバッファを 16kHz・モノラル・16bit に変換して標準入力に流す。
    /// 音声スレッドから同期で呼ぶ。書き込みは別キューで行うので、子プロセスが遅くてもここは詰まらない
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = convert(buffer), !data.isEmpty else { return }
        enqueue(data)
    }

    private func enqueue(_ data: Data) {
        let input = stdinPipe.fileHandleForWriting
        writeQueue.async { [self] in
            guard !writeFailed else { return }
            do {
                try input.write(contentsOf: data)
            } catch {
                writeFailed = true
                fputs("文字起こしプロセスへの書き込み失敗。以降の音声は渡さない: \(error)\n", stderr)
            }
        }
    }

    /// 変換器に残っている末尾を流してから標準入力を閉じ、残りの処理と出力の読み取りが終わるのを待つ。
    /// append() がもう呼ばれない状態（録音を止めた後）で呼ぶ。
    public func finish() async -> TranscriberExit {
        if let converter, let tail = drain(converter), !tail.isEmpty {
            enqueue(tail)
        }
        let input = stdinPipe.fileHandleForWriting
        let process = self.process
        let readDone = self.readDone
        return await withCheckedContinuation { continuation in
            writeQueue.async { [self] in
                let audioDropped = writeFailed
                try? input.close()
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    readDone.wait()
                    continuation.resume(returning: TranscriberExit(
                        status: process.terminationStatus, audioDropped: audioDropped
                    ))
                }
            }
        }
    }

    private func handleLine(_ line: Data) {
        guard line.contains(where: { !$0.isASCIIWhitespace }) else { return }
        do {
            onUtterance(try JSONDecoder().decode(Utterance.self, from: line))
        } catch {
            fputs("文字起こしプロセスの出力を読めない: \(String(decoding: line, as: UTF8.self))\n", stderr)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        var head = Data()
        if converter == nil || converter?.inputFormat != buffer.format {
            // 入力形式が変わったら、前の変換器の末尾を流してから作り直す
            if let converter, let tail = drain(converter) { head = tail }
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            // 2ch→1ch で片方を捨てずに混ぜる
            converter?.downmix = true
        }
        guard let converter else { return nil }

        // 容量が変換後ぴったりだと入力を一部しか消費せず、残りが失われる（実測）。余裕を持たせる
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio * 2).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        // サンプルレート変換は前後のバッファをまたいで状態を持つので、終端扱いにせず .noDataNow で返す
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let samples = output.int16ChannelData else {
            fputs("文字起こし用の変換失敗: \(error.map { "\($0)" } ?? "unknown")\n", stderr)
            return head.isEmpty ? nil : head
        }
        return head + Data(bytes: samples[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }

    /// 変換器の中に残っている末尾（サンプルレート変換の遅延分）を出し切る。以降その変換器は使えない
    private func drain(_ converter: AVAudioConverter) -> Data? {
        var result = Data()
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { return nil }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard status != .error, let samples = output.int16ChannelData else {
                fputs("文字起こし用の変換失敗: \(error.map { "\($0)" } ?? "unknown")\n", stderr)
                return result
            }
            result.append(Data(bytes: samples[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size))
            if status == .endOfStream || output.frameLength == 0 { return result }
        }
    }
}

private extension UInt8 {
    var isASCIIWhitespace: Bool { self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D }
}
