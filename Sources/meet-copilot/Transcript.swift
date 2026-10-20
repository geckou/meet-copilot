import Capture
import Foundation
import Transcription

/// 2トラック分の文字起こし結果に話者ラベルを付け、端末に流しつつ JSON Lines のファイルに書き足す。
/// 時刻は録音開始（2トラックの書き込み開始）からの秒数で、2トラックで揃っている。
final class Transcript: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "transcript")
    private let handle: FileHandle
    private var count = 0
    private var writeError: Error?

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    static func speaker(of track: Track) -> String {
        switch track {
        case .app: return "相手"
        case .mic: return "自分"
        }
    }

    func append(_ utterance: Utterance, track: Track) {
        queue.sync {
            let speaker = Self.speaker(of: track)
            let minutes = Int(utterance.start) / 60
            let seconds = utterance.start - Double(minutes * 60)
            print(String(format: "[%02d:%04.1f] %@: %@", minutes, seconds, speaker, utterance.text))

            let record: [String: Any] = [
                "track": track.rawValue,
                "speaker": speaker,
                "start": utterance.start,
                "end": utterance.end,
                "text": utterance.text,
            ]
            do {
                var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
                line.append(UInt8(ascii: "\n"))
                try handle.write(contentsOf: line)
                count += 1
            } catch {
                // 端末には出ているので続けるが、ファイルが欠けたことは終了時に失敗として扱う
                if writeError == nil { writeError = error }
                fputs("文字起こしの書き込み失敗: \(error)\n", stderr)
            }
        }
    }

    /// ファイルを閉じて概要を返す。書き込みに1回でも失敗していれば failed になる。
    func close() -> (description: String, failed: Bool) {
        queue.sync {
            var failed = writeError != nil
            do {
                try handle.close()
            } catch {
                if writeError == nil { writeError = error }
                failed = true
            }
            var description = "[transcript] \(count) 件, \(url.path)"
            if let writeError {
                description += "\n  書き込み失敗で欠けている: \(writeError)"
            }
            return (description, failed)
        }
    }
}
