import XCTest
@testable import ExternalProcess

final class JSONLinesProcessTests: XCTestCase {
    private struct Item: Decodable, Sendable, Equatable {
        let n: Int
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Item] = []
        func append(_ item: Item) { lock.withLock { items.append(item) } }
        var all: [Item] { lock.withLock { items } }
    }

    /// 書いたバイト列がそのまま届き、出力が届いた順に読まれる
    func testWritesInputAndReadsLinesInOrder() async {
        let collected = Collected()
        let command = #"exec python3 -c 'import sys; [print("{\"n\": %d}" % int(l)) for l in sys.stdin]'"#
        let process = JSONLinesProcess<Item>(name: "テスト", command: command) { collected.append($0) }
        XCTAssertNoThrow(try process.start())
        for n in 1...3 { process.write(Data("\(n)\n".utf8)) }
        let exit = await process.finish()

        XCTAssertTrue(exit.succeeded)
        XCTAssertEqual(collected.all, [Item(n: 1), Item(n: 2), Item(n: 3)])
    }

    func testNonZeroExitIsReported() async {
        let process = JSONLinesProcess<Item>(name: "テスト", command: "cat > /dev/null; exit 3") { _ in }
        XCTAssertNoThrow(try process.start())
        process.write(Data("x".utf8))
        let exit = await process.finish()
        XCTAssertEqual(exit.status, 3)
        XCTAssertFalse(exit.succeeded)
    }

    /// 読めない行は捨てて続きを読み、正常終了でも失敗として返す
    func testUndecodableLinesAreReported() async {
        let collected = Collected()
        let command = #"cat > /dev/null; echo 'not json'; echo '{"m": 0}'; echo; echo '{"n": 1}'"#
        let process = JSONLinesProcess<Item>(name: "テスト", command: command) { collected.append($0) }
        XCTAssertNoThrow(try process.start())
        let exit = await process.finish()
        XCTAssertEqual(exit.status, 0)
        XCTAssertEqual(exit.undecodableLines, 2)
        XCTAssertFalse(exit.succeeded)
        XCTAssertEqual(collected.all, [Item(n: 1)])
    }

    /// 途中で入力を閉じて正常終了するプロセスでも、渡せなかった入力があれば失敗として返す
    func testDroppedInputIsReportedEvenIfProcessSucceeds() async throws {
        let process = JSONLinesProcess<Item>(name: "テスト", command: "head -c 1 > /dev/null; exit 0") { _ in }
        XCTAssertNoThrow(try process.start())
        process.write(Data("a".utf8))
        // プロセスが終わってから書き込ませる
        try await Task.sleep(nanoseconds: 500_000_000)
        process.write(Data(repeating: 0, count: 100_000))
        let exit = await process.finish()
        XCTAssertEqual(exit.status, 0)
        XCTAssertTrue(exit.inputDropped)
        XCTAssertFalse(exit.succeeded)
    }
}
