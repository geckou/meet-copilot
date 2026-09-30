// 2トラック取得の検証用。
// ScreenCaptureKit で指定アプリ（既定: Chrome）の音声を、AVAudioEngine でマイクを取り、
// それぞれ別の WAV ファイルに書き出す。
//
// build: swiftc -O main.swift -o two-track-capture
// run:   ./two-track-capture [--app <bundle id prefix>] [--out <dir>] [--duration <sec>]

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

let usage = """
usage: two-track-capture [--app <bundle id prefix>] [--out <dir>] [--duration <sec>]
  --app       対象アプリの bundle id 前方一致（既定: com.google.Chrome、空文字で全アプリ）
  --out       出力ディレクトリ（既定: カレントディレクトリ）
  --duration  録音秒数。省略時は Ctrl-C まで
"""

struct Options {
    var bundlePrefix = "com.google.Chrome"
    var outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var duration: Double?
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--app":
            guard let v = args.next() else { fail("--app に値がない") }
            options.bundlePrefix = v
        case "--out":
            guard let v = args.next() else { fail("--out に値がない") }
            options.outputDir = URL(fileURLWithPath: v)
        case "--duration":
            guard let v = args.next(), let d = Double(v), d > 0 else { fail("--duration は正の数") }
            options.duration = d
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            fail("不明な引数: \(arg)\n\(usage)")
        }
    }
    return options
}

func fail(_ message: String) -> Never {
    fputs("error: \(message)\n", stderr)
    exit(1)
}

struct CaptureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - 1トラック分の書き出し

/// 最初のバッファの形式で WAV（16bit PCM）を開き、以降のバッファを書き足す。
final class TrackWriter: @unchecked Sendable {
    let name: String
    let url: URL
    private let queue: DispatchQueue
    private var file: AVAudioFile?
    private var closed = false
    private var sampleRate: Double = 0
    private var framesWritten: AVAudioFramePosition = 0
    private var peak: Float = 0

    init(name: String, url: URL) {
        self.name = name
        self.url = url
        self.queue = DispatchQueue(label: "writer.\(name)")
    }

    /// 呼び出し元がバッファを使い回す可能性があるので同期で書く。
    func write(_ buffer: AVAudioPCMBuffer) {
        queue.sync {
            guard !closed, buffer.frameLength > 0 else { return }
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
                    sampleRate = format.sampleRate
                    print("[\(name)] 入力形式: \(format) -> \(url.path)")
                }
                try file?.write(from: buffer)
                framesWritten += AVAudioFramePosition(buffer.frameLength)
                peak = max(peak, Self.peak(of: buffer))
            } catch {
                fputs("[\(name)] 書き込み失敗: \(error)\n", stderr)
            }
        }
    }

    /// ファイルを閉じて概要を返す。
    func close() -> String {
        queue.sync {
            closed = true
            file = nil // AVAudioFile は解放時に閉じられる
            guard sampleRate > 0 else {
                return "[\(name)] 何も書き込まれていない（ファイル未作成）"
            }
            let seconds = Double(framesWritten) / sampleRate
            let peakDB = peak > 0 ? 20 * log10(peak) : -.infinity
            return String(format: "[%@] %.2f 秒, ピーク %.1f dBFS, %@", name, seconds, peakDB, url.path)
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

// MARK: - 録音本体

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let options: Options
    private let appWriter: TrackWriter
    private let micWriter: TrackWriter
    private let engine = AVAudioEngine()
    private let sampleQueue = DispatchQueue(label: "sck.samples")
    private let lock = NSLock()
    private var stream: SCStream?
    private var stopped = false

    init(options: Options, appURL: URL, micURL: URL) {
        self.options = options
        self.appWriter = TrackWriter(name: "app", url: appURL)
        self.micWriter = TrackWriter(name: "mic", url: micURL)
    }

    func start() async throws {
        try await requestMicrophoneAccess()
        try requestScreenCaptureAccess()

        // --- アプリ音声（ScreenCaptureKit）---
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let apps = content.applications.filter {
            options.bundlePrefix.isEmpty || $0.bundleIdentifier.hasPrefix(options.bundlePrefix)
        }
        guard !apps.isEmpty else {
            let ids = content.applications.map(\.bundleIdentifier).sorted().joined(separator: "\n  ")
            throw CaptureError("'\(options.bundlePrefix)' に一致するアプリがない。起動中のアプリ:\n  \(ids)")
        }
        print("対象アプリ:")
        for app in apps {
            print("  \(app.bundleIdentifier) (pid \(app.processID)) \(app.applicationName)")
        }
        guard let display = content.displays.first else {
            throw CaptureError("ディスプレイが見つからない")
        }

        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // 映像は使わないので最小にする
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        // 映像出力を登録しないと "stream output NOT found" のログが大量に出るので、受けて捨てる
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)

        // --- マイク（AVAudioEngine）---
        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            throw CaptureError("マイク入力の形式が取れない: \(micFormat)")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [micWriter] buffer, _ in
            micWriter.write(buffer)
        }
        try engine.start()

        try await stream.startCapture()
        let stoppedDuringStart = lock.withLock {
            self.stream = stream
            return stopped
        }
        if stoppedDuringStart {
            // 起動中に Ctrl-C された場合。shutdown 側は stream を知らないのでここで止める
            try? await stream.stopCapture()
        }
    }

    /// 止めてファイルを閉じてから終了する。2回目以降の呼び出しは無視する。
    func shutdown(exitCode: Int32) {
        lock.lock()
        let already = stopped
        stopped = true
        let stream = self.stream
        lock.unlock()
        if already { return }

        Task.detached { [self] in
            if let stream {
                do { try await stream.stopCapture() } catch { fputs("stopCapture 失敗: \(error)\n", stderr) }
            }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            print("\n--- 結果 ---")
            print(appWriter.close())
            print(micWriter.close())
            exit(exitCode)
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        appWriter.write(buffer)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("ストリームが停止した: \(error)\n", stderr)
        shutdown(exitCode: 1)
    }

    // MARK: helpers

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            fputs("[app] PCM 変換失敗: \(status)\n", stderr)
            return nil
        }
        return buffer
    }

    private func requestMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            throw CaptureError("マイクの権限が拒否された")
        default:
            throw CaptureError("マイクの権限がない。システム設定 > プライバシーとセキュリティ > マイク で実行元のターミナルを許可する")
        }
    }

    private func requestScreenCaptureAccess() throws {
        if CGPreflightScreenCaptureAccess() { return }
        CGRequestScreenCaptureAccess()
        throw CaptureError("画面収録の権限がない。システム設定 > プライバシーとセキュリティ > 画面収録 で実行元のターミナルを許可し、ターミナルを再起動する")
    }
}

// MARK: - main

func main() -> Never {
    let options = parseOptions()
    do {
        try FileManager.default.createDirectory(at: options.outputDir, withIntermediateDirectories: true)
    } catch {
        fail("出力ディレクトリを作れない: \(error)")
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let stamp = formatter.string(from: Date())
    let recorder = Recorder(
        options: options,
        appURL: options.outputDir.appendingPathComponent("app-\(stamp).wav"),
        micURL: options.outputDir.appendingPathComponent("mic-\(stamp).wav")
    )

    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { recorder.shutdown(exitCode: 0) }
    sigint.resume()

    Task.detached {
        do {
            try await recorder.start()
        } catch {
            fputs("error: \(error)\n", stderr)
            recorder.shutdown(exitCode: 1)
            return
        }
        if let duration = options.duration {
            print("録音中... \(duration) 秒で止まる（Ctrl-C でも止まる）")
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            recorder.shutdown(exitCode: 0)
        } else {
            print("録音中... Ctrl-C で止める")
        }
    }

    withExtendedLifetime(sigint) { dispatchMain() }
}

main()
