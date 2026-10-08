import Foundation
import DozerKit
import XCTest
@testable import DozerHost

/// 610 (590.B3): an `open-session` (the dashboard's, `doz attach`'s, `doz run`'s) that arrives while a sandbox's
/// FIRST start is still preparing its image used to run while the sandbox was still off and fail "… is off". It
/// now JOINS the start: it waits for its end and then opens — or fails with the start's own reason. No VM here:
/// the preparation is a stand-in held by a gate, and made to fail, so the start never boots.
final class ColdStartJoinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-unit-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: the gate itself

    func testWaitersGetTheStartsOutcomeAndTheKeyIsFreeAgain() async throws {
        let g = ColdStarts()
        try await g.wait("a")                              // none under way: at once
        XCTAssertTrue(g.begin("a"))
        XCTAssertFalse(g.begin("a"), "one cold start per sandbox — a second joins")
        XCTAssertTrue(g.begin("b"), "per sandbox")
        let w1 = Task { try await g.wait("a") }
        let w2 = Task { try await g.wait("a") }
        try await Task.sleep(for: .milliseconds(50))
        g.finish("a", error: HostError(.failed, "a did not start — no network"))
        for w in [w1, w2] {
            do { try await w.value; XCTFail("a waiter of a failed start must fail") } catch {
                XCTAssertEqual((error as? HostError)?.message, "a did not start — no network")
            }
        }
        XCTAssertFalse(g.isRunning("a"))
        XCTAssertTrue(g.isRunning("b"))
        let w3 = Task { try await g.wait("b") }
        try await Task.sleep(for: .milliseconds(50))
        g.finish("b", error: nil)
        try await w3.value                                 // succeeded: returns
        XCTAssertTrue(g.begin("a"), "free again")
    }

    // MARK: through the host

    final class Gate: @unchecked Sendable {
        let lock = NSLock()
        var released = false
        var runs = 0
        var isReleased: Bool { lock.withLock { released } }
    }

    final class Done: @unchecked Sendable {
        let lock = NSLock()
        var at: [String: Date] = [:]
        func mark(_ k: String) { lock.withLock { at[k] = Date() } }
        func when(_ k: String) -> Date? { lock.withLock { at[k] } }
    }

    func testAnOpenDuringAFirstStartsPreparationJoinsItAndFailsWithItsReason() async throws {
        let store = DozerStore(root: root)
        let core = HostCore(store: store, readOnly: false, version: "test")
        let gate = Gate()
        await core.setPreparationRunner({ _, _, _ in
            gate.lock.withLock { gate.runs += 1 }
            while !gate.isReleased { try await Task.sleep(for: .milliseconds(20)) }
            throw HostError(.failed, "no network")
        }, prepared: { _, _ in false })
        var c = HostRequest(.create, name: "x")
        c.create = CreateOptions(image: "lab")
        let made = await core.handle(c)
        XCTAssertNil(made.error, "\(String(describing: made.error))")

        let done = Done()
        // The dashboard's Start, then — while its image is being prepared — two opens of the session (the web
        // action sends no `start`), a `doz attach`-style open, and a second Start.
        let start = Task { () -> HostMessage in let m = await core.handle(HostRequest(.start, name: "x")); done.mark("start"); return m }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(core.coldStarts.isRunning("x"), "the cold start is recorded from its preparation on")
        let open1 = Task { () -> HostMessage in let m = await core.handle(HostRequest(.openSession, name: "x")); done.mark("open1"); return m }
        let open2 = Task { () -> HostMessage in
            var r = HostRequest(.openSession, name: "x"); r.session = "shell"
            let m = await core.handle(r); done.mark("open2"); return m
        }
        let start2 = Task { () -> HostMessage in let m = await core.handle(HostRequest(.start, name: "x")); done.mark("start2"); return m }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(done.when("open1"), "an open during the start's preparation WAITS (it answered \"is off\" before 610)")
        XCTAssertNil(done.when("open2"))
        XCTAssertNil(done.when("start2"), "a second start joins the first")

        gate.lock.withLock { gate.released = true }
        let s = await start.value
        XCTAssertNotNil(s.error)
        for (label, t) in [("open1", open1), ("open2", open2), ("start2", start2)] {
            let m = await t.value
            XCTAssertNotNil(m.error, "\(label) fails with the start")
            XCTAssertTrue(m.error?.message.hasPrefix("x did not start — ") == true, "\(label): \(m.error?.message ?? "nil")")
            XCTAssertTrue(m.error?.message.contains("no network") == true, "\(label): the start's own reason — \(m.error?.message ?? "nil")")
            XCTAssertFalse(m.error?.message.contains("is off") == true, "\(label): never \"is off\"")
            XCTAssertGreaterThanOrEqual(done.when(label)!, done.when("start")!.addingTimeInterval(-0.05), "\(label) ended with the start, not before")
        }
        XCTAssertEqual(gate.lock.withLock { gate.runs }, 1, "one preparation for the start and everything that joined it")
        XCTAssertFalse(core.coldStarts.isRunning("x"), "the key is free once the start ended")

        // With no start under way an open of an off sandbox is refused at once, as before (it never starts one
        // unless asked — `doz run` asks).
        let t0 = Date()
        let off = await core.handle(HostRequest(.openSession, name: "x"))
        XCTAssertTrue(off.error?.message.contains("doz start x") == true, "\(off.error?.message ?? "nil")")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
    }
}
