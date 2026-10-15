import AVFoundation
import Foundation

/// 1トラック分の書き出し結果。
public struct TrackSummary: Sendable, CustomStringConvertible {
    public let name: String
    public let url: URL
    /// 最初のバッファの形式。何も書き込まれていなければ nil
    public let inputFormat: String?
    public let seconds: Double
    public let peakDBFS: Float
    /// 書き込み失敗で途中から捨てた場合のエラー
    public let writeError: String?

    public var description: String {
        guard let inputFormat else {
            if let writeError {
                return "[\(name)] ファイルを作れなかった: \(url.path)\n  \(writeError)"
            }
            return "[\(name)] 何も書き込まれていない（ファイル未作成）"
        }
        var line = String(format: "[%@] %.2f 秒, ピーク %.1f dBFS, %@", name, seconds, peakDBFS, url.path)
        line += "\n  入力形式: \(inputFormat)"
        if let writeError {
            line += "\n  書き込み失敗で途中から捨てた: \(writeError)"
        }
        return line
    }
}

/// 最初のバッファの形式で WAV（16bit PCM）を開き、以降のバッファを書き足す。
/// 2トラックの長さを揃えるため、arm() されるまでのバッファと disarm() 以降のバッファは捨てる。
final class TrackWriter: @unchecked Sendable {
    let name: String
    let url: URL
    private let queue: DispatchQueue
    private var file: AVAudioFile?
    private var armed = false
    private var closed = false
    private var inputFormat: AVAudioFormat?
    private var framesWritten: AVAudioFramePosition = 0
    private var peak: Float = 0
    private var writeError: Error?
    /// 書き込み対象になったバッファ（arm 〜 disarm の間）を受け取る。書き込みより先に同期で呼ぶ。
    /// バッファは呼び出し後に使い回されうるので、保持せずにその場で使う
    var onAccepted: ((AVAudioPCMBuffer) -> Void)?

    init(name: String, url: URL) {
        self.name = name
        self.url = url
        self.queue = DispatchQueue(label: "writer.\(name)")
    }

    /// 呼び出し元がバッファを使い回す可能性があるので同期で書く。
    func write(_ buffer: AVAudioPCMBuffer) {
        queue.sync {
            guard armed, !closed, buffer.frameLength > 0 else { return }
            onAccepted?(buffer)
            do {
                if file == nil {
                    let format = buffer.format
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: format.sampleRate,
                        AVNumberOfChannelsKey: format.channelCount,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: false,
                    ]
                    file = try AVAudioFile(
                        forWriting: url,
                        settings: settings,
                        commonFormat: format.commonFormat,
                        interleaved: format.isInterleaved
                    )
                    inputFormat = format
                }
                try file?.write(from: buffer)
                framesWritten += AVAudioFramePosition(buffer.frameLength)
                peak = max(peak, Self.peak(of: buffer))
            } catch {
                // ディスク不足などは続けても失敗し続けるので、最初の1回だけ記録して以降は捨てる
                writeError = error
                closed = true
            }
        }
    }

    /// 以降のバッファを書き込む。disarm() 後に呼んでも再開しない。
    func arm() {
        queue.sync { armed = true }
    }

    /// 以降のバッファを捨てる。ファイルは close() まで開いたまま。
    func disarm() {
        queue.sync { closed = true }
    }

    /// ファイルを閉じて概要を返す。
    func close() -> TrackSummary {
        queue.sync {
            closed = true
            file = nil // AVAudioFile は解放時に閉じられる
            let sampleRate = inputFormat?.sampleRate ?? 0
            return TrackSummary(
                name: name,
                url: url,
                inputFormat: inputFormat.map { "\($0)" },
                seconds: sampleRate > 0 ? Double(framesWritten) / sampleRate : 0,
                peakDBFS: peak > 0 ? 20 * log10(peak) : -.infinity,
                writeError: writeError.map { "\($0)" }
            )
        }
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        let stride = buffer.stride
        var result: Float = 0
        for ch in 0..<Int(buffer.format.channelCount) {
            let data = channels[ch]
            for i in 0..<frames {
                result = max(result, abs(data[i * stride]))
            }
        }
        return result
    }
}
