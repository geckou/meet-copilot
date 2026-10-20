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

    func testUndecodableLinesAreReported() async {
        let collected = Collected()
        let command = #"cat > /dev/null; echo 'oops'; echo '{"at": 1, "question": "q", "quote": "x"}'"#
        let extractor = CandidateExtractor(command: command) { collected.append($0) }
        XCTAssertNoThrow(try extractor.start())
        let exit = await extractor.finish()
        XCTAssertEqual(exit.status, 0)
        XCTAssertEqual(exit.undecodableLines, 1)
        XCTAssertFalse(exit.succeeded)
        XCTAssertEqual(collected.all.count, 1)
    }
}
