import Foundation

/// 610 (590.B3): the cold starts under way, per sandbox — from the moment `start` decides to boot an off
/// (or failed) sandbox, through its image's preparation (minutes on a first start: pull, bake), to the boot's
/// end. Until 610 an `open-session` that arrived meanwhile (the dashboard's, `doz attach`'s) saw the sandbox
/// still OFF and failed "… is off". Now `HostCore.ensureRunning` JOINS the start: it waits for its end, then
/// opens — or fails with the start's own reason. A second `start` joins the first rather than booting twice.
///
/// Like `KeyedGate`: a lock, not the actor, so a waiter never depends on the actor's re-entrancy; the outcome
/// is handed to every waiter, then the key is free again.
public final class ColdStarts: @unchecked Sendable {
    private let lock = NSLock()
    /// A key is present while its start runs; its value is the waiters in arrival order.
    private var running: [String: [CheckedContinuation<Void, Error>]] = [:]

    public init() {}

    /// Mark `key`'s cold start as under way. False when one already is (the caller joins that one instead).
    public func begin(_ key: String) -> Bool {
        lock.withLock {
            guard running[key] == nil else { return false }
            running[key] = []
            return true
        }
    }

    /// Whether `key` has a cold start under way.
    public func isRunning(_ key: String) -> Bool { lock.withLock { running[key] != nil } }

    /// Wait for `key`'s cold start to end: returns when it succeeded (or when none runs), throws its error.
    /// Returns at once when none is under way.
    public func wait(_ key: String) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let queued: Bool = lock.withLock {
                guard running[key] != nil else { return false }
                running[key]!.append(c)
                return true
            }
            if !queued { c.resume() }
        }
    }

    /// The start ended: every waiter gets its outcome, and the key is free.
    public func finish(_ key: String, error: Error?) {
        let waiters: [CheckedContinuation<Void, Error>] = lock.withLock {
            let w = running[key] ?? []
            running[key] = nil
            return w
        }
        for c in waiters {
            if let error { c.resume(throwing: error) } else { c.resume() }
        }
    }
}
