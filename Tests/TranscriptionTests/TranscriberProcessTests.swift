import AVFoundation
import XCTest
@testable import Transcription

final class TranscriberProcessTests: XCTestCase {
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Utterance] = []
        func append(_ u: Utterance) { lock.withLock { items.append(u) } }
        var all: [Utterance] { lock.withLock { items } }
    }

    private func buffer(sampleRate: Double, channels: AVAudioChannelCount, seconds: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<Int(channels) {
            for i in 0..<Int(frames) { buffer.floatChannelData![ch][i] = 0.25 }
        }
        return buffer
    }

    /// 標準入力のバイト数を秒数にして返すだけのコマンドで、変換後の長さと受け渡しの形を確かめる
    func testConvertsTo16kMonoAndReadsJSONLines() async {
        let script = """
        exec python3 -c 'import sys, json, os; n = len(sys.stdin.buffer.read()); \
        print(json.dumps({"start": 0, "end": n / 32000, "text": os.environ["MEET_COPILOT_TRACK"]}))'
        """
        let collected = Collected()
        let transcriber = TranscriberProcess(
            label: "test", command: script, environment: ["MEET_COPILOT_TRACK": "app"]
        ) { collected.append($0) }
        XCTAssertNoThrow(try transcriber.start())

        // 48kHz・2ch を 0.5 秒ずつ 4 回（計 2 秒）
        for _ in 0..<4 {
            transcriber.append(buffer(sampleRate: 48_000, channels: 2, seconds: 0.5))
        }
        let status = await transcriber.finish()

        XCTAssertEqual(status, 0)
        XCTAssertEqual(collected.all.count, 1)
        XCTAssertEqual(collected.all.first?.text, "app")
        // サンプルレート変換の遅延（実測 約 37ms、累積しない）の分だけ末尾が欠ける
        XCTAssertEqual(collected.all.first?.end ?? 0, 2.0, accuracy: 0.05)
    }

    func testNonZeroExitIsReported() async {
        let transcriber = TranscriberProcess(label: "test", command: "cat > /dev/null; exit 3") { _ in }
        XCTAssertNoThrow(try transcriber.start())
        transcriber.append(buffer(sampleRate: 44_100, channels: 1, seconds: 0.1))
        let status = await transcriber.finish()
        XCTAssertEqual(status, 3)
    }
}
