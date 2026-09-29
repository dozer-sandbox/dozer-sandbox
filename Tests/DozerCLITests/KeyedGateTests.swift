import Foundation
import DozerHost
import XCTest

/// 590: the owner's two clicks on "open session" while a sandbox booted started two `deckhold
/// serve`s; one failed "Address in use". `HostCore.openSession` now holds a per-sandbox gate across
/// its awaits. These pin the gate, and the check-then-serve pattern it protects.
final class KeyedGateTests: XCTestCase {
    /// A stand-in for the guest: a session table, and a `serve` that fails when the name is taken
    /// (as deckhold does), with awaits in between like the real exec.
    actor FakeGuest {
        var sessions: Set<String> = []
        var serves = 0
        func list() async -> Set<String> {
            try? await Task.sleep(for: .milliseconds(Int.random(in: 1...5)))
            return sessions
        }
        func serve(_ name: String) async throws {
            try? await Task.sleep(for: .milliseconds(Int.random(in: 5...15)))
            serves += 1
            guard sessions.insert(name).inserted else { throw POSIXError(.EADDRINUSE) }
        }
    }

    /// HostCore.openSession's shape: look, then serve if missing — under the gate.
    static func open(_ guest: FakeGuest, _ gate: KeyedGate, gated: Bool) async throws -> Bool {
        if gated { await gate.lock("sb") }
        defer { if gated { gate.unlock("sb") } }
        if await guest.list().contains("claude") { return false }
        try await guest.serve("claude")
        return true
    }

    func testConcurrentOpensWithoutTheGateRace() async throws {
        // The bug, reproduced: without the gate several opens serve, and the extra ones fail.
        let guest = FakeGuest(), gate = KeyedGate()
        let failures = await withTaskGroup(of: Bool.self) { g in
            for _ in 0..<8 { g.addTask { (try? await Self.open(guest, gate, gated: false)) == nil } }
            return await g.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        let serves = await guest.serves
        XCTAssertGreaterThan(serves, 1, "the race needs no VM to show")
        XCTAssertGreaterThan(failures, 0)
    }

    func testConcurrentOpensUnderTheGateServeOnceAndAllSucceed() async throws {
        let guest = FakeGuest(), gate = KeyedGate()
        let results = try await withThrowingTaskGroup(of: Bool.self) { g in
            for _ in 0..<16 { g.addTask { try await Self.open(guest, gate, gated: true) } }
            return try await g.reduce(into: [Bool]()) { $0.append($1) }
        }
        let serves = await guest.serves
        XCTAssertEqual(serves, 1, "exactly one serve")
        XCTAssertEqual(results.filter { $0 }.count, 1, "one created it; the other fifteen found it running")
        XCTAssertFalse(gate.isHeld("sb"))
    }

    func testTheGateIsExclusiveFIFOAndPerKey() async throws {
        let gate = KeyedGate()
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var inside = 0, most = 0, order: [Int] = []
        }
        let box = Box()
        await gate.lock("a")
        let waiters = (0..<5).map { i in
            Task {
                await gate.lock("a")
                box.lock.withLock { box.inside += 1; box.most = max(box.most, box.inside); box.order.append(i) }
                try? await Task.sleep(for: .milliseconds(2))
                box.lock.withLock { box.inside -= 1 }
                gate.unlock("a")
            }
        }
        // Another key is not blocked by "a".
        await gate.lock("b")
        gate.unlock("b")
        try await Task.sleep(for: .milliseconds(50))
        gate.unlock("a")
        for w in waiters { await w.value }
        XCTAssertEqual(box.most, 1)
        XCTAssertEqual(box.order.count, 5)
        XCTAssertFalse(gate.isHeld("a"))
    }
}
