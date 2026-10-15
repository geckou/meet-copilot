import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

public struct CaptureError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// stop() の結果。
public struct RecordingResult: Sendable {
    public let app: TrackSummary
    public let mic: TrackSummary
    /// start() が失敗していればそのエラー。起動途中に stop() した場合も含めてここに残る
    public let startError: String?
}

/// 録音するトラック。app はアプリ音声（相手）、mic はマイク（自分）。
public enum Track: String, Sendable {
    case app
    case mic
}

/// 音声を取る対象として選ばれたアプリ。
public struct CapturedApp: Sendable {
    public let bundleIdentifier: String
    public let processID: pid_t
    public let name: String
}

/// ScreenCaptureKit で指定アプリの音声（相手）を、AVAudioEngine でマイク（自分）を取り、
/// 別々の WAV ファイルに書き出す。両方が動き出してから書き始め、停止処理の前に書き込みを止めて
/// 2トラックの秒数を揃える。
///
/// 1インスタンスにつき start() / stop() を1回ずつ使う。
public final class TwoTrackRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// 録音中にストリームが外部要因で止まったときに呼ばれる。start() の前に設定する。
    /// ここから stop() を呼んでファイルを閉じる。
    public var onUnexpectedStop: (@Sendable (Error) -> Void)?

    /// ファイルに書き込むのと同じバッファを受け取る。2トラックとも同じ時点から届くので、
    /// 届いたフレーム数から録音開始からの時刻が揃って出せる。start() の前に設定する。
    /// 音声スレッドから同期で呼ばれる。バッファは呼び出し後に使い回されうるので、保持せずにその場で使う
    public var onBuffer: (@Sendable (Track, AVAudioPCMBuffer) -> Void)?

    private let bundlePrefix: String
    private let appWriter: TrackWriter
    private let micWriter: TrackWriter
    private let engine = AVAudioEngine()
    private let sampleQueue = DispatchQueue(label: "sck.samples")
    private let lock = NSLock()
    private var stream: SCStream?
    private var tapInstalled = false
    private var startTask: Task<[CapturedApp], Error>?
    private var stopTask: Task<RecordingResult, Never>?

    /// - Parameter bundlePrefix: 対象アプリの bundle id 前方一致。空文字で全アプリ
    public init(bundlePrefix: String, appURL: URL, micURL: URL) {
        self.bundlePrefix = bundlePrefix
        self.appWriter = TrackWriter(name: "app", url: appURL)
        self.micWriter = TrackWriter(name: "mic", url: micURL)
    }

    /// 権限を確認して録音を始める。返り値は音声を取る対象のアプリ。
    public func start() async throws -> [CapturedApp] {
        let task = try lock.withLock {
            guard startTask == nil, stopTask == nil else { throw CaptureError("start() は1回だけ呼べる") }
            let task = Task { try await self.performStart() }
            startTask = task
            return task
        }
        return try await task.value
    }

    /// 止めてファイルを閉じる。起動途中なら起動が終わるのを待ってから止める。
    /// 2回目以降の呼び出しは1回目と同じ結果を返す。
    @discardableResult
    public func stop() async -> RecordingResult {
        let task = lock.withLock {
            if let stopTask { return stopTask }
            // 停止処理にかかる時間の分だけ片方が長くなるのを防ぐため、先に両方の書き込みを止める
            appWriter.disarm()
            micWriter.disarm()
            let task = Task { await self.performStop() }
            stopTask = task
            return task
        }
        return await task.value
    }

    private func performStart() async throws -> [CapturedApp] {
        try await requestMicrophoneAccess()
        try requestScreenCaptureAccess()

        if let onBuffer {
            appWriter.onAccepted = { onBuffer(.app, $0) }
            micWriter.onAccepted = { onBuffer(.mic, $0) }
        }

        // --- アプリ音声（ScreenCaptureKit）---
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let apps = content.applications.filter {
            bundlePrefix.isEmpty || $0.bundleIdentifier.hasPrefix(bundlePrefix)
        }
        guard !apps.isEmpty else {
            let ids = content.applications.map(\.bundleIdentifier).sorted().joined(separator: "\n  ")
            throw CaptureError("'\(bundlePrefix)' に一致するアプリがない。起動中のアプリ:\n  \(ids)")
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
        lock.withLock { tapInstalled = true }
        try engine.start()

        try await stream.startCapture()
        lock.withLock { self.stream = stream }

        // 両方が動き出してから書き始める。起動にかかる時間の分だけ片方が長くなるのを防ぐ。
        // 起動中に stop() されていれば disarm 済みなので書き込みは再開しない
        appWriter.arm()
        micWriter.arm()

        return apps.map {
            CapturedApp(bundleIdentifier: $0.bundleIdentifier, processID: $0.processID, name: $0.applicationName)
        }
    }

    private func performStop() async -> RecordingResult {
        // 起動途中で止めると後始末の対象が揃わないので、起動の成否が出るまで待つ
        var startError: String?
        do {
            _ = try await lock.withLock({ startTask })?.value
        } catch {
            startError = "\(error)"
        }

        let (stream, tapInstalled) = lock.withLock { (self.stream, self.tapInstalled) }
        if let stream {
            do { try await stream.stopCapture() } catch { fputs("stopCapture 失敗: \(error)\n", stderr) }
        }
        // 起動途中のエラーで止める場合、タップが無いまま removeTap すると例外になる
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
        return RecordingResult(app: appWriter.close(), mic: micWriter.close(), startError: startError)
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        appWriter.write(buffer)
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onUnexpectedStop?(error)
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
