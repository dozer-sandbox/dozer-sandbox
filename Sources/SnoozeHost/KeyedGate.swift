import Foundation

/// A FIFO mutual exclusion per key, for async code (590). An actor alone does not serialize an
/// operation that awaits — another call runs in between — so work that must not interleave for one
/// key (opening a sandbox's sessions) holds the key's gate across its awaits.
///
///     await gate.lock(key); defer { gate.unlock(key) }
///
/// Waiters are resumed in arrival order. `unlock` is synchronous, so it can sit in a `defer`.
public final class KeyedGate: @unchecked Sendable {
    private let lock = NSLock()
    /// A key is held while present; its value is the waiters in arrival order.
    private var held: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    public func lock(_ key: String) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let acquired: Bool = lock.withLock {
                if held[key] == nil {
                    held[key] = []
                    return true
                }
                held[key]!.append(c)
                return false
            }
            if acquired { c.resume() }
        }
    }

    public func unlock(_ key: String) {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            guard var waiters = held[key] else { return nil }
            if waiters.isEmpty {
                held[key] = nil
                return nil
            }
            let n = waiters.removeFirst()
            held[key] = waiters
            return n
        }
        next?.resume()
    }

    /// Whether the key is held (for tests).
    public func isHeld(_ key: String) -> Bool { lock.withLock { held[key] != nil } }
}
