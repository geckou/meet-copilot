import AVFoundation
import ExternalProcess
import Foundation

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

    private let process: JSONLinesProcess<Utterance>
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true
    )!
    // append() を呼ぶ音声スレッドからのみ触る。finish() は append() が止まってから呼ばれる
    private var converter: AVAudioConverter?

    /// - Parameters:
    ///   - command: /bin/sh -c で実行するコマンド
    ///   - environment: 現在の環境変数に足す値
    ///   - onUtterance: 1件受け取るたびに呼ばれる。読み取り用のスレッドから呼ばれる
    public init(
        command: String,
        environment: [String: String] = [:],
        onUtterance: @escaping @Sendable (Utterance) -> Void
    ) {
        process = JSONLinesProcess(
            name: "文字起こしプロセス", command: command, environment: environment, onOutput: onUtterance
        )
    }

    public func start() throws {
        try process.start()
    }

    /// 録音のバッファを 16kHz・モノラル・16bit に変換して標準入力に流す。
    /// 音声スレッドから同期で呼ぶ。書き込みは別キューで行うので、子プロセスが遅くてもここは詰まらない
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = convert(buffer), !data.isEmpty else { return }
        process.write(data)
    }

    /// 変換器に残っている末尾を流してから標準入力を閉じ、残りの処理と出力の読み取りが終わるのを待つ。
    /// append() がもう呼ばれない状態（録音を止めた後）で呼ぶ。
    public func finish() async -> ProcessExit {
        if let converter, let tail = drain(converter), !tail.isEmpty {
            process.write(tail)
        }
        return await process.finish()
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
