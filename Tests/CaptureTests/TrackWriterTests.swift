import AVFoundation
import XCTest
@testable import Capture

final class TrackWriterTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func buffer(frames: AVAudioFrameCount, amplitude: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<2 {
            for i in 0..<Int(frames) { buffer.floatChannelData![ch][i] = amplitude }
        }
        return buffer
    }

    func testDropsBuffersBeforeArmAndAfterDisarm() throws {
        let writer = TrackWriter(name: "t", url: dir.appendingPathComponent("t.wav"))
        writer.write(buffer(frames: 4800, amplitude: 1.0))
        writer.arm()
        writer.write(buffer(frames: 48_000, amplitude: 0.5))
        writer.disarm()
        writer.write(buffer(frames: 4800, amplitude: 1.0))
        let summary = writer.close()

        XCTAssertEqual(summary.seconds, 1.0, accuracy: 0.001)
        XCTAssertEqual(summary.peakDBFS, 20 * log10(0.5), accuracy: 0.01)
        let file = try AVAudioFile(forReading: summary.url)
        XCTAssertEqual(file.length, 48_000)
    }

    func testArmAfterDisarmDoesNotResume() {
        let writer = TrackWriter(name: "t", url: dir.appendingPathComponent("t.wav"))
        writer.disarm()
        writer.arm()
        writer.write(buffer(frames: 4800, amplitude: 0.5))
        let summary = writer.close()

        XCTAssertNil(summary.inputFormat)
        XCTAssertFalse(FileManager.default.fileExists(atPath: summary.url.path))
    }
}
