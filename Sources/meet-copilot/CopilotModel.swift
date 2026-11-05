import AppKit
import Candidates
import Capture
import Foundation
import Transcription

/// UI の状態。録音（RecordingSession）と調査（CandidateAnswerer）をつなぐ。
/// 調べに行くのは候補の「調べる」を押したときだけ。
@MainActor
final class CopilotModel: ObservableObject {
    enum State {
        case idle, starting, recording, stopping
    }

    struct Line: Identifiable {
        let id = UUID()
        let speaker: String
        let start: Double
        let text: String
    }

    enum AnswerStatus {
        case none
        case inProgress
        case answered(Answer)
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let meeting: String
        /// 録音の保存先。答えも同じ場所の answers-<日時>.jsonl に書く
        let dir: URL
        let candidate: Candidate
        var status: AnswerStatus = .none
    }

    @Published private(set) var state: State = .idle
    /// 相手側の音声を取っているアプリの名前（録音中のみ）
    @Published private(set) var capturedApps: [String] = []
    @Published private(set) var lines: [Line] = []
    @Published private(set) var items: [Item] = []
    @Published var message: String?
    @Published private(set) var repoPath: String?

    /// 議事録の保存先。録音していないときだけ変えられる
    @Published private(set) var minutesDir: URL
    /// 録音・文字起こし・候補・答えのファイル（機械用）の置き場所
    let outputDir: URL
    private var session: RecordingSession?
    private var answerer: CandidateAnswerer?
    /// answerer が調べている対象。nil は Web
    private var answererRepo: String??

    private static let repoKey = "repoPath"
    private static let minutesDirKey = "minutesDir"

    /// - Parameter outputDir: 機械用のファイルの置き場所。議事録の保存先を画面で選んでいなければ議事録もここ
    init(outputDir: URL) {
        self.outputDir = outputDir
        minutesDir = UserDefaults.standard.string(forKey: Self.minutesDirKey).map { URL(fileURLWithPath: $0) } ?? outputDir
        repoPath = UserDefaults.standard.string(forKey: Self.repoKey)
    }

    // MARK: 録音

    func start() {
        guard state == .idle else { return }
        var options = RecordOptions()
        options.outputDir = outputDir
        options.minutesDir = minutesDir
        options.transcriber = scriptCommand("transcribe_whisper.py")
        options.extractor = scriptCommand("extract_candidates.py")

        // 読み取り用スレッドから届いた順に、メインで反映する
        let session: RecordingSession
        do {
            session = try RecordingSession(
                options: options,
                onUtterance: { [weak self] track, utterance in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.add(utterance, track: track) }
                    }
                },
                onCandidate: { [weak self] candidate in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.add(candidate) }
                    }
                }
            )
        } catch {
            message = "\(error)"
            return
        }
        session.onUnexpectedStop = { [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.message = "録音が止まった: \(error)"
                    self?.stop()
                }
            }
        }

        lines = []
        items = []
        message = nil
        self.session = session
        state = .starting
        Task {
            do {
                let apps = try await session.start()
                if state == .starting {
                    // Chrome は補助プロセスごとに並ぶので、名前で1つにまとめる
                    capturedApps = apps.map(\.name).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
                    state = .recording
                }
            } catch {
                message = "録音を開始できない: \(error)"
                stop()
            }
        }
    }

    func stop() {
        guard let session, state == .starting || state == .recording else { return }
        state = .stopping
        Task {
            let succeeded = await session.stop()
            self.session = nil
            capturedApps = []
            state = .idle
            if !succeeded, message == nil {
                message = "停止時に失敗があった。詳しくは起動したターミナルの出力を参照"
            }
        }
    }

    private func add(_ utterance: Utterance, track: Track) {
        let line = Line(speaker: Transcript.speaker(of: track), start: utterance.start, text: utterance.text)
        // 2トラックの結果は届く順が前後するので、時刻順の位置に入れる
        let index = lines.lastIndex { $0.start <= line.start }.map { $0 + 1 } ?? 0
        lines.insert(line, at: index)
    }

    private func add(_ candidate: Candidate) {
        guard let session else { return }
        items.append(Item(meeting: session.stamp, dir: session.outputDir, candidate: candidate))
    }

    // MARK: 調べる

    func chooseRepo() {
        guard let url = chooseDirectory(prompt: "このリポジトリを調べる") else { return }
        repoPath = url.path
        UserDefaults.standard.set(repoPath, forKey: Self.repoKey)
    }

    /// リポジトリの選択を外し、Web で調べるようにする
    func clearRepo() {
        repoPath = nil
        UserDefaults.standard.removeObject(forKey: Self.repoKey)
    }

    func ask(_ id: Item.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if case .inProgress = items[index].status { return }
        // リポジトリが未選択なら Web で調べる
        guard let answerer = answerer(for: repoPath) else { return }
        let item = items[index]
        let transcript = lines.map { AnswerRequest.Utterance(speaker: $0.speaker, start: $0.start, text: $0.text) }
        items[index].status = .inProgress
        answerer.ask(makeAnswerRequest(meeting: item.meeting, candidate: item.candidate, transcript: transcript))
    }

    /// repo（nil なら Web）を調べる調査プロセス。repo が変わったら起動し直す。前のプロセスは受け取った問いを調べ終えてから閉じる
    private func answerer(for repo: String?) -> CandidateAnswerer? {
        if let answerer, answererRepo == repo { return answerer }
        if let old = answerer {
            Task.detached { _ = report(await old.finish(), of: "調査プロセス") }
        }
        let answerer = CandidateAnswerer(command: answererCommand(repos: repo.map { [$0] } ?? [])) { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(result) }
            }
        }
        do {
            try answerer.start()
        } catch {
            message = "調査プロセスを起動できない: \(error)"
            return nil
        }
        self.answerer = answerer
        answererRepo = repo
        // 先に終わったら（claude が見つからないなど）、調べている途中の候補を失敗にする。次に押したときに起動し直す
        Task.detached { [weak self] in
            await answerer.waitForExit()
            await self?.answererExited(answerer)
        }
        return answerer
    }

    private func answererExited(_ exited: CandidateAnswerer) {
        guard answerer === exited else { return }
        answerer = nil
        answererRepo = nil
        for index in items.indices {
            if case .inProgress = items[index].status {
                items[index].status = .failed("調査プロセスが終了した。起動したターミナルの出力を参照")
            }
        }
    }

    private func receive(_ result: AnswerResult) {
        switch result {
        case .answered(let answer):
            guard let index = index(meeting: answer.meeting, at: answer.at, question: answer.question) else { return }
            if let meeting = answer.meeting, !appendAnswer(answer, toMeeting: meeting, in: items[index].dir) {
                message = "答えをファイルに書けなかった"
            }
            items[index].status = .answered(answer)
        case .failed(let failure):
            guard let index = index(meeting: failure.meeting, at: failure.at, question: failure.question) else { return }
            items[index].status = .failed(failure.error)
        }
    }

    private func index(meeting: String?, at: Double, question: String) -> Int? {
        items.firstIndex { $0.meeting == meeting && $0.candidate.at == at && $0.candidate.question == question }
    }

    // MARK: 終了

    /// 録音中なら止めてから終わる。調べている途中の問いは待たない
    func quit() {
        guard let session else {
            NSApp.terminate(nil)
            return
        }
        state = .stopping
        Task {
            _ = await session.stop()
            NSApp.terminate(nil)
        }
    }

    // MARK: 保存先

    func chooseMinutesDir() {
        guard state == .idle, let url = chooseDirectory(prompt: "ここに議事録を保存する") else { return }
        minutesDir = url
        UserDefaults.standard.set(url.path, forKey: Self.minutesDirKey)
    }

    private func chooseDirectory(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        // メニューバーの画面は通常のウインドウより上の階層にある。キーウインドウにならないこともあるので、
        // 表示中のウインドウでいちばん上の階層より上に選択画面を出す
        if let top = NSApp.windows.filter({ $0.isVisible && $0 !== panel }).map(\.level.rawValue).max(),
           top >= panel.level.rawValue {
            panel.level = NSWindow.Level(rawValue: top + 1)
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.standardizedFileURL
    }

    func openMinutesDir() {
        try? FileManager.default.createDirectory(at: minutesDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(minutesDir)
    }
}
