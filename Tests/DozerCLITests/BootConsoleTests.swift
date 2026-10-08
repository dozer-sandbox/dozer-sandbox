import Foundation
import XCTest
@testable import DozerCLI
@testable import DozerHost

/// 591 — the boot console as a stream of lines (`doz console --follow`, the `console` host op,
/// the web UI's boot view).
final class BootConsoleTests: XCTestCase {
    var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("bootlog-\(UUID().uuidString).log")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    func append(_ s: String) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(s.utf8))
        try fh.close()
    }

    func testEachLineOnceAPartialLineWaitsAndCRIsDropped() throws {
        var t = BootConsoleTail(url: url)
        XCTAssertEqual(t.poll(), [], "no file yet")
        try append("[    0.000000] Linux version 6.18\r\n[    0.1] init")
        XCTAssertEqual(t.poll(), ["[    0.000000] Linux version 6.18"])
        XCTAssertEqual(t.poll(), [])
        try append("ial\nvminitd: ready\n")
        XCTAssertEqual(t.poll(), ["[    0.1] initial", "vminitd: ready"])
    }

    func testAColdBootsRecreatedLogStartsOver() throws {
        var t = BootConsoleTail(url: url)
        try append("old boot line one\nold boot line two\n")
        XCTAssertEqual(t.poll().count, 2)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(t.poll(), [])
        try append("new\n")
        XCTAssertEqual(t.poll(), ["new"], "a shorter (recreated) file is read from its first byte")
    }

    func testReplayIsTheNewestTailAndLinesAreCapped() throws {
        let long = String(repeating: "x", count: 5000)
        try append(String(repeating: "filler line\n", count: 30_000) + long + "\nlast\n")
        var t = BootConsoleTail(url: url)
        let lines = t.poll()
        XCTAssertLessThanOrEqual(lines.reduce(0) { $0 + $1.utf8.count + 1 }, BootConsoleTail.replayBytes)
        XCTAssertEqual(lines.last, "last")
        XCTAssertTrue(lines.allSatisfy { $0.utf8.count <= BootConsoleTail.maximumLineBytes })
        XCTAssertEqual(lines.first, "filler line", "the partial first line of the tail is dropped")
        XCTAssertEqual(BootConsoleTail.lines(of: url).last, "last")
    }

    func testTheCLINeverPrintsTheGuestsControlCharacters() {
        XCTAssertEqual(Console.printable("ok\u{1B}]52;c;cHduZWQ=\u{07}\u{9B}2J\tx"), "ok?]52;c;cHduZWQ=??2J\tx")
    }
}
