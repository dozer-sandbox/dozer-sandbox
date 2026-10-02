import Foundation
import XCTest
@testable import DozerCLI
@testable import DozerHost

/// The CLI's progress view holds its lines back for the first second only — by the CLOCK. A first
/// `doz exec` on an image never prepared printed nothing for 18 s and then everything at once: the
/// host's "not prepared" note and the first steps came within the first second and were held until the
/// next event, which came only when the (silent) image pull ended.
final class ProgressHoldTests: XCTestCase {
    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func write(_ s: String) { lock.withLock { text += s } }
        var value: String { lock.withLock { text } }
    }

    private func note(_ s: String) -> HostEvent { HostEvent(kind: .note, sandbox: "q1", text: s) }

    func testHeldLinesAppearAfterOneSecondWithoutAnotherEvent_plain() {
        let sink = Sink()
        let p = Progress(mode: .plain, verbose: false, quiet: false, width: 100) { sink.write($0) }
        p.handle(note("lab is not prepared in this store yet — preparing it first"))
        p.handle(HostEvent(kind: .started, sandbox: "lab", text: "docker.io/library/alpine:3.20 ready (pulled)"))
        XCTAssertEqual(sink.value, "", "a quick operation prints nothing in its first second")
        let deadline = Date().addingTimeInterval(1.6)
        while Date() < deadline, !sink.value.contains("not prepared") { usleep(20_000) }
        XCTAssertTrue(sink.value.contains("not prepared"), "the held note is shown at one second, with no further event (got \(sink.value.debugDescription))")
        p.finish()
    }

    func testAnimatedViewStartsAtOneSecondAndStreamsTransferProgress() {
        let sink = Sink()
        let p = Progress(mode: .animated, verbose: false, quiet: false, width: 100) { sink.write($0) }
        let t0 = Date()
        p.handle(note("lab is not prepared in this store yet — preparing it first"))
        p.handle(HostEvent(kind: .started, sandbox: "lab", text: "docker.io/library/alpine:3.20 ready (pulled)"))
        var firstAt: TimeInterval?
        while Date().timeIntervalSince(t0) < 1.6 {
            if firstAt == nil, sink.value.contains("not prepared") { firstAt = Date().timeIntervalSince(t0) }
            usleep(20_000)
        }
        XCTAssertNotNil(firstAt, "the first line arrives without another event")
        XCTAssertLessThan(firstAt ?? 99, 1.4, "and within about a second")
        // A pull's transfer events stream while it runs (the meter's ≤ 4 a second).
        var e = HostEvent(kind: .progress, sandbox: "lab", text: "pulling alpine:3.20", completedBytes: 1_048_576, totalBytes: 4_194_304)
        e.completedItems = 0
        e.totalItems = 1
        p.handle(e)
        usleep(250_000)
        XCTAssertTrue(sink.value.contains("pulling alpine:3.20"), "the transfer is drawn while it runs (got \(sink.value.suffix(300).debugDescription))")
        p.finish()
    }

    func testAQuickOperationStillPrintsNothing() {
        let sink = Sink()
        let p = Progress(mode: .plain, verbose: false, quiet: false, width: 100) { sink.write($0) }
        p.handle(note("woke q1"))
        usleep(200_000)
        p.finish()
        usleep(1_200_000)
        XCTAssertEqual(sink.value, "", "finished inside its first second: nothing, and nothing later")
    }

    func testQuietPrintsNothingEver() {
        let sink = Sink()
        let p = Progress(mode: .plain, verbose: false, quiet: true, width: 100) { sink.write($0) }
        p.handle(note("x"))
        usleep(1_200_000)
        p.finish()
        XCTAssertEqual(sink.value, "")
    }
}
