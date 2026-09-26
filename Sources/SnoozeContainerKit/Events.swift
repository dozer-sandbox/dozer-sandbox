import Foundation

public enum SandboxError: Error, LocalizedError, Equatable {
    case invalidSpec(String)
    /// `op` is not allowed in `phase` (see `LifecyclePlanner`).
    case invalidPhase(operation: String, phase: Phase)
    /// Sessions and exec need a running sandbox.
    case notRunning(Phase)
    case deckholdMissing
    case invalidSessionName(String)
    case commandFailed(command: String, exitCode: Int32, output: String)
    case noSnapshot
    case vmUnavailable
    case timedOut(String)
    case restorePointNotFound(String)
    case alreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSpec(let s): "invalid sandbox spec: \(s)"
        case .invalidPhase(let op, let phase): "\(op) is not possible while the sandbox is \(phase.label.lowercased())"
        case .notRunning(let phase): "the sandbox is not running (\(phase.label.lowercased()))"
        case .deckholdMissing: "the deckhold guest binary is missing from SnoozeContainerKit's resources"
        case .invalidSessionName(let n): "session names are 1–64 characters of [A-Za-z0-9._-], got \"\(n)\""
        case .commandFailed(let c, let code, let out): "`\(c)` exited \(code): \(out.suffix(400))"
        case .noSnapshot: "there is no snapshot to restore"
        case .vmUnavailable: "the virtual machine is not available"
        case .timedOut(let what): "timed out: \(what)"
        case .restorePointNotFound(let id): "no restore point \(id)"
        case .alreadyExists(let what): "\(what) already exists"
        }
    }
}

/// What a sandbox reports while it works — the timed step log the SandboxLab event log shows.
public enum SandboxEvent: Sendable, Equatable {
    case phase(Phase)
    /// A step finished, and how long it took.
    case step(String, milliseconds: Double)
    /// Anything else worth a line in a log.
    case note(String)
    /// A long transfer's progress (the one-time kernel download).
    case progress(String, completedBytes: Int64, totalBytes: Int64?)
    /// The readouts changed (RAM held, snapshot size, busy).
    case status(SandboxStatus)
}

public struct SandboxStatus: Sendable, Equatable {
    public var phase: Phase
    /// A lifecycle operation is in progress.
    public var busy: Bool
    /// Guest RAM the VM currently holds on the host, MiB (0 when on disk or off).
    public var ramHeldMiB: UInt64
    /// Size of the snapshot on disk, bytes (0 when there is none).
    public var snapshotBytes: Int
    public init(phase: Phase, busy: Bool, ramHeldMiB: UInt64, snapshotBytes: Int) {
        self.phase = phase
        self.busy = busy
        self.ramHeldMiB = ramHeldMiB
        self.snapshotBytes = snapshotBytes
    }
}

/// A multi-subscriber event fan-out: every `subscribe()` gets its own stream.
final class EventBroadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    func subscribe() -> AsyncStream<Element> {
        let (stream, cont) = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(1000))
        let id = UUID()
        lock.lock(); continuations[id] = cont; lock.unlock()
        cont.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.continuations.removeValue(forKey: id); self.lock.unlock()
        }
        return stream
    }

    func yield(_ e: Element) {
        lock.lock(); let cs = Array(continuations.values); lock.unlock()
        for c in cs { c.yield(e) }
    }

    func finish() {
        lock.lock(); let cs = Array(continuations.values); continuations.removeAll(); lock.unlock()
        for c in cs { c.finish() }
    }
}

/// What `Sandbox.returnFreeMemory()` did (583).
public struct MemoryReturn: Sendable, Equatable {
    /// Guest RAM this call handed back to the Mac (what the balloon had filled when it returned), MiB.
    public var returnedMiB: UInt64
    /// Guest RAM the balloon holds for the Mac in all, now, MiB.
    public var heldMiB: UInt64
    /// The guest's free memory before, MiB.
    public var guestFreeMiB: UInt64
    public var milliseconds: Double
    public init(returnedMiB: UInt64, heldMiB: UInt64, guestFreeMiB: UInt64, milliseconds: Double) {
        self.returnedMiB = returnedMiB
        self.heldMiB = heldMiB
        self.guestFreeMiB = guestFreeMiB
        self.milliseconds = milliseconds
    }
}
