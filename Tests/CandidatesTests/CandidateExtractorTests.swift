import XCTest
@testable import Candidates

final class CandidateExtractorTests: XCTestCase {
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Candidate] = []
        func append(_ c: Candidate) { lock.withLock { items.append(c) } }
        var all: [Candidate] { lock.withLock { items } }
    }

    /// 受け取った発言の数と最後の発言を候補として返すだけのコマンドで、受け渡しの形を確かめる
    func testSendsLinesAndReadsCandidates() async {
        let script = """
        exec python3 -c 'import sys, json; lines = [json.loads(l) for l in sys.stdin]; \\
        print(json.dumps({"at": lines[-1]["start"], "question": str(len(lines)), "quote": lines[-1]["text"]}))'
        """
        let collected = Collected()
        let extractor = CandidateExtractor(command: script) { collected.append($0) }
        XCTAssertNoThrow(try extractor.start())
        extractor.send(Data(#"{"speaker":"自分","start":0,"end":1,"text":"はい"}"#.utf8))
        extractor.send(Data(#"{"speaker":"相手","start":3,"end":5,"text":"認証どうなってる？"}"#.utf8))
        let exit = await extractor.finish()

        XCTAssertTrue(exit.succeeded)
        XCTAssertEqual(collected.all, [Candidate(at: 3, question: "2", quote: "認証どうなってる？")])
    }

    /// 問いが1行の JSON で渡り、答えの JSON が読まれる
    func testAnswererSendsRequestAndReadsAnswer() async {
        let script = """
        exec python3 -c 'import sys, json; r = json.loads(sys.stdin.readline()); \\
        print(json.dumps({"at": r["at"], "question": r["question"], "answer": str(len(r["context"])), \\
        "confidence": "high", "sources": [{"path": "a.swift", "line": 3}]}))'
        """
        let answers = AnswerBox()
        let answerer = CandidateAnswerer(command: script) { answers.set($0) }
        XCTAssertNoThrow(try answerer.start())
        let candidate = Candidate(at: 7, question: "期限は？", quote: "期限どれくらい？")
        answerer.ask(AnswerRequest(candidate: candidate, context: [
            .init(speaker: "相手", start: 7, text: "期限どれくらい？"),
            .init(speaker: "自分", start: 9, text: "確認します"),
        ]))
        let exit = await answerer.finish()

        XCTAssertTrue(exit.succeeded)
        XCTAssertEqual(answers.value?.question, "期限は？")
        XCTAssertEqual(answers.value?.answer, "2")
        XCTAssertEqual(answers.value?.sources.first?.line, 3)
    }

    private final class AnswerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: Answer?
        func set(_ a: Answer) { lock.withLock { answer = a } }
        var value: Answer? { lock.withLock { answer } }
    }
}
