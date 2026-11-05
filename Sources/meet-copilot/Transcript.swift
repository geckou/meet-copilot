import Candidates
import Capture
import Foundation
import Transcription

/// 2トラック分の文字起こし結果に話者ラベルを付け、端末に流しつつ JSON Lines のファイルに書き足す。
/// 時刻は録音開始（2トラックの書き込み開始）からの秒数で、2トラックで揃っている。
final class Transcript: @unchecked Sendable {
    private let file: JSONLinesFile
    private let queue = DispatchQueue(label: "transcript")
    /// 議事録を書くために手元にも残す（話者, 開始秒, 本文）
    private var lines: [(speaker: String, start: Double, text: String)] = []
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
            lines.append((speaker, utterance.start, utterance.text))

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

    /// 読む用の議事録（Markdown）。発言は時刻順に並べ、同じ話者の続く発言は1段落にまとめる
    func minutes(startedAt date: Date, candidates: [Candidate]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var text = "# 会議 \(formatter.string(from: date))\n"
        if !candidates.isEmpty {
            text += "\n## 出た問い\n\n"
            for candidate in candidates.sorted(by: { $0.at < $1.at }) {
                text += "- [\(formatTime(candidate.at))] \(candidate.question)（「\(candidate.quote)」）\n"
            }
        }
        text += "\n## 発言\n"
        // 2トラックの結果は届く順が前後するので、時刻順に並べ直す。同じ時刻なら届いた順
        let sorted = queue.sync { lines.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element) }
        if sorted.isEmpty { text += "\n（発言なし）\n" }
        var previous: String?
        for line in sorted {
            if line.speaker == previous {
                text += line.text + "\n"
            } else {
                text += "\n**\(line.speaker)**（\(formatTime(line.start))）\n" + line.text + "\n"
                previous = line.speaker
            }
        }
        return text
    }
}
