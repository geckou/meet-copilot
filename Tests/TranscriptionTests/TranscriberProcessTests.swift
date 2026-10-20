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
        let exit = await transcriber.finish()

        XCTAssertTrue(exit.succeeded)
        XCTAssertEqual(collected.all.count, 1)
        XCTAssertEqual(collected.all.first?.text, "app")
        // 終了時に変換器の末尾も流すので、欠けずに 2 秒分届く
        XCTAssertEqual(collected.all.first?.end ?? 0, 2.0, accuracy: 0.002)
    }

    func testNonZeroExitIsReported() async {
        let transcriber = TranscriberProcess(label: "test", command: "cat > /dev/null; exit 3") { _ in }
        XCTAssertNoThrow(try transcriber.start())
        transcriber.append(buffer(sampleRate: 44_100, channels: 1, seconds: 0.1))
        let exit = await transcriber.finish()
        XCTAssertEqual(exit.status, 3)
        XCTAssertFalse(exit.succeeded)
    }

    /// 読めない行は捨てて続きを読み、正常終了でも失敗として返す
    func testUndecodableLinesAreReported() async {
        let collected = Collected()
        let command = #"cat > /dev/null; echo 'not json'; echo '{"start": 0}'; echo '{"start": 1, "end": 2, "text": "ok"}'"#
        let transcriber = TranscriberProcess(label: "test", command: command) { collected.append($0) }
        XCTAssertNoThrow(try transcriber.start())
        let exit = await transcriber.finish()
        XCTAssertEqual(exit.status, 0)
        XCTAssertEqual(exit.undecodableLines, 2)
        XCTAssertFalse(exit.succeeded)
        XCTAssertEqual(collected.all.map(\.text), ["ok"])
    }

    /// 途中で入力を閉じて正常終了するプロセスでも、渡せなかった音声があれば失敗として返す
    func testDroppedAudioIsReportedEvenIfProcessSucceeds() async throws {
        let transcriber = TranscriberProcess(label: "test", command: "head -c 100 > /dev/null; exit 0") { _ in }
        XCTAssertNoThrow(try transcriber.start())
        transcriber.append(buffer(sampleRate: 48_000, channels: 2, seconds: 0.1))
        // プロセスが終わってから書き込ませる
        try await Task.sleep(nanoseconds: 500_000_000)
        transcriber.append(buffer(sampleRate: 48_000, channels: 2, seconds: 0.1))
        let exit = await transcriber.finish()
        XCTAssertEqual(exit.status, 0)
        XCTAssertTrue(exit.audioDropped)
        XCTAssertFalse(exit.succeeded)
    }
}
