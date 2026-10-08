import XCTest
@testable import DozerKit

/// `SessionConnection` without a VM: the transport side is driven by hand.
final class SessionConnectionTests: XCTestCase {
    private func drain(_ s: AsyncStream<SessionOutput>) async -> [SessionOutput] {
        var out: [SessionOutput] = []
        for await o in s { out.append(o) }
        return out
    }

    private func drainInput(_ c: SessionConnection) async -> [Data] {
        var out: [Data] = []
        for await d in c.input { out.append(d) }
        return out
    }

    func test_helloIsTheFirstFrameThenDataAndResize() async {
        let c = SessionConnection(session: "deck", size: TermSize(cols: 100, rows: 30))
        c.send(Data("m".utf8))
        c.resize(TermSize(cols: 80, rows: 24))
        c.close()
        let frames = await drainInput(c)
        XCTAssertEqual(frames, [DeckholdFrame.hello(TermSize(cols: 100, rows: 30)).encoded,
                                DeckholdFrame.data(Data("m".utf8)).encoded,
                                DeckholdFrame.resize(TermSize(cols: 80, rows: 24)).encoded])
    }

    func test_snapshotDataThenExitEndsTheConnection() async {
        let c = SessionConnection(session: "deck", size: .standard)
        let closes = Counter()
        c.setOnClose { _ in closes.bump() }
        // Frames split across writes, as a vsock stream delivers them.
        let wire = DeckholdFrame.snapshot(Data("screen".utf8)).encoded + DeckholdFrame.output(Data("x".utf8)).encoded
            + DeckholdFrame.exit(3).encoded + DeckholdFrame.output(Data("after".utf8)).encoded
        c.receive(wire.prefix(7))
        c.receive(wire.dropFirst(7))
        let out = await drain(c.output)
        XCTAssertEqual(out, [.snapshot(Data("screen".utf8)), .data(Data("x".utf8)), .ended(exitCode: 3)])
        XCTAssertTrue(c.isClosed)
        XCTAssertEqual(c.finalOutput, .ended(exitCode: 3))
        XCTAssertEqual(closes.value, 1)
    }

    func test_noSessionEndsWithNilCode() async {
        let c = SessionConnection(session: "nope", size: .standard)
        c.receive(Data([0x4E, 0, 0, 0, 0]))
        let out = await drain(c.output)
        XCTAssertEqual(out, [.ended(exitCode: nil)])
    }

    /// The 576 Stop bug, as a unit: once a connection is closed, bytes still arriving from its
    /// exec are dropped and nothing more is sent — whatever path closed it.
    func test_nothingIsDeliveredOrSentAfterClose() async {
        let c = SessionConnection(session: "deck", size: .standard)
        c.receive(DeckholdFrame.output(Data("before".utf8)).encoded)
        c.detach(.sandboxStopped)
        c.receive(DeckholdFrame.output(Data("LEAK".utf8)).encoded)
        c.send(Data("typed after stop".utf8))
        c.detach(.transportLost)          // a second close is a no-op
        c.close()
        let out = await drain(c.output)
        XCTAssertEqual(out, [.data(Data("before".utf8)), .detached(.sandboxStopped)])
        let sent = await drainInput(c)
        XCTAssertEqual(sent, [DeckholdFrame.hello(.standard).encoded], "only the HELLO went out")
    }

    func test_garbageFromTheTransportDetachesAsLost() async {
        let c = SessionConnection(session: "deck", size: .standard)
        c.receive(Data([0x7A, 0, 0, 0, 0]))
        let out = await drain(c.output)
        XCTAssertEqual(out, [.detached(.transportLost)])
    }

    func test_connectionsAreIdentifiedByObjectNotByAnythingReusable() {
        let a = SessionConnection(session: "deck", size: .standard)
        let b = SessionConnection(session: "deck", size: .standard)
        XCTAssertNotEqual(a.id, b.id)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
