import ContainerizationExtras
import Foundation
import XCTest
@testable import DozerKit

/// 593: a bake's live output and a pull's progress — inert, capped, and at most 4 events a second.
final class ProgressTests: XCTestCase {
    final class Clock: @unchecked Sendable {
        var t = Date(timeIntervalSince1970: 1_000_000)
        func now() -> Date { t }
    }
    final class Sink<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func add(_ x: T) { lock.withLock { items.append(x) } }
        var all: [T] { lock.withLock { items } }
    }

    func testGuestTextIsMadeInert() {
        XCTAssertEqual(InertText.line("plain npm line"), "plain npm line")
        XCTAssertEqual(InertText.line("\u{1B}[31mred\u{1B}[0m text"), "red text", "SGR removed")
        XCTAssertEqual(InertText.line("\u{1B}]8;;http://x\u{07}link\u{1B}]8;;\u{07}"), "link", "OSC 8 removed (its parameters are not text)")
        XCTAssertEqual(InertText.line("\u{1B}]52;c;aGVsbG8=\u{07}after"), "after", "OSC 52 removed")
        XCTAssertEqual(InertText.line("a\u{0}b\u{7F}c\u{9B}d\te"), "abcd e")
        XCTAssertEqual(InertText.line("progress 10%\rprogress 50%\rprogress 90%"), "progress 90%", "a \\r redraw: what it shows now")
        let long = InertText.line(Substring(String(repeating: "x", count: 500)))
        XCTAssertEqual(long.count, 201)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testTheTailIsRateLimitedAndKeepsTheLatestLine() {
        let clock = Clock(), sink = Sink<String>()
        let tail = OutputTail(perSecond: 4, now: { clock.now() }, emit: { sink.add($0) })
        tail.add(Data("added 1 package\nadded 2 packages\n".utf8))
        XCTAssertEqual(sink.all, ["added 2 packages"], "the newest complete line")
        clock.t += 0.1
        tail.add(Data("added 3 packages\n".utf8))
        clock.t += 0.1
        tail.add(Data("added 4 packages\n\n  \n".utf8))
        XCTAssertEqual(sink.all.count, 1, "within 250 ms: held back")
        clock.t += 0.1
        tail.add(Data("added 5 pack".utf8))
        XCTAssertEqual(sink.all.last, "added 4 packages", "a quarter second on: the newest complete line (blank ones dropped)")
        clock.t += 1
        tail.add(Data("ages\nnpm \u{1B}[33mWARN\u{1B}[0m deprecated".utf8))
        XCTAssertEqual(sink.all.last, "added 5 packages")
        tail.flush()
        XCTAssertEqual(sink.all.last, "npm WARN deprecated", "flush sends what is left, inert")
        XCTAssertFalse(sink.all.joined().contains("\u{1B}"))
        // 20 lines in one second → at most 4 events.
        let clock2 = Clock(), sink2 = Sink<String>()
        let t2 = OutputTail(perSecond: 4, now: { clock2.now() }, emit: { sink2.add($0) })
        for i in 0..<20 { t2.add(Data("line \(i)\n".utf8)); clock2.t += 0.05 }
        XCTAssertLessThanOrEqual(sink2.all.count, 4)
    }

    func testAPullIsCountedInBytesAndLayersAndReportedAtMost4ASecond() async {
        let clock = Clock(), sink = Sink<SandboxEvent>()
        let m = PullMeter(label: "pulling node@1a2b3c4d5e6f", now: { clock.now() }, events: { sink.add($0) })
        m.add([.addTotalSize(142_000_000), .addTotalItems(5)])
        m.add([.addSize(10_000_000)])
        clock.t += 0.3
        m.add([.addSize(40_000_000), .addItems(1)])
        m.finish()
        XCTAssertEqual(sink.all.count, 3, "the first, one a quarter second on, and the last")
        XCTAssertEqual(sink.all.last, .transfer("pulling node@1a2b3c4d5e6f", completedBytes: 50_000_000, totalBytes: 142_000_000, completedItems: 1, totalItems: 5))
    }

    func testAReferenceIsShortForPeople() {
        let digest = String(repeating: "ab", count: 32)
        XCTAssertEqual(ImageBaker.shortReference("docker.io/library/node@sha256:" + digest), "node@abababababab")
        XCTAssertEqual(ImageBaker.shortReference("docker.io/library/alpine:3.20"), "alpine:3.20")
    }
}
