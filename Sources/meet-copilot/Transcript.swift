import Capture
import Foundation
import Transcription

/// 2トラック分の文字起こし結果に話者ラベルを付け、端末に流しつつ JSON Lines のファイルに書き足す。
/// 時刻は録音開始（2トラックの書き込み開始）からの秒数で、2トラックで揃っている。
final class Transcript: @unchecked Sendable {
    private let file: JSONLinesFile
    private let queue = DispatchQueue(label: "transcript")
    /// 1件ごとに、ファイルに書くのと同じ JSON（改行なし）を受け取る。届いた順に、同期で呼ばれる
    var onRecord: ((Data) -> Void)?

    init(url: URL) throws {
        file = try JSONLinesFile(url: url, name: "transcript")
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
            print("[\(formatTime(utterance.start))] \(speaker): \(utterance.text)")

            let record: [String: Any] = [
                "track": track.rawValue,
                "speaker": speaker,
                "start": utterance.start,
                "end": utterance.end,
                "text": utterance.text,
            ]
            guard let line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]) else {
                return
            }
            onRecord?(line)
            file.append(line)
        }
    }

    /// ファイルを閉じて概要を返す。書き込みに1回でも失敗していれば failed になる。
    func close() -> (description: String, failed: Bool) {
        file.close()
    }
}
