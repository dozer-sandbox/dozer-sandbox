import Foundation

/// Where a sandbox is in its life — the owner's vocabulary (2026-09-25):
///
///     Start (Cold Boot) ─▶ running ─ Pause (Suspend) ─▶ paused ─ Resume ─▶ running
///                          running ─ Sleep ───────────▶ asleep ─ Wake ───▶ running   RAM kept, snapshot on disk
///                          running ─ Deep Sleep (Hibernate) ─▶ deepAsleep ─ Wake ─▶ running   RAM freed
///                          any ─ Shut Down ─▶ off (the disk is kept; running programs end)
public enum Phase: String, Sendable, Codable, CaseIterable {
    /// Shut down: no VM. `start()` (`coldBoot()`) boots the kept disk.
    case off
    /// `start()` is running: images, the prepared disk, VM boot.
    case booting
    case running
    /// Paused (suspended): guest CPU at 0, RAM still held. Resumes in ~1 ms.
    case paused
    /// Asleep: paused AND its full state saved to disk — crash-safe; RAM still held. Wake resumes in place.
    case asleep
    /// Deep asleep (hibernated): saved to disk and the VM stopped — RAM returned. Wake restores it in ~0.35 s.
    case deepAsleep
    /// `start()` failed. `start()` again, or `shutDown()` to clean up.
    case failed

    /// A human label.
    public var label: String {
        switch self {
        case .off: "Shut down"
        case .booting: "Booting"
        case .running: "Running"
        case .paused: "Paused"
        case .asleep: "Asleep — RAM kept, snapshot on disk"
        case .deepAsleep: "Deep asleep — RAM freed"
        case .failed: "Failed"
        }
    }

    /// The VM holds host RAM in this phase.
    public var holdsRAM: Bool { [.booting, .running, .paused, .asleep].contains(self) }
    /// A snapshot on disk is valid (and needed) only in these phases; every other phase deletes it.
    public var keepsSnapshot: Bool { self == .asleep || self == .deepAsleep }

    /// Decodes today's names AND the names persisted before the 2026-09-25 rename (`pausedSaved`,
    /// `onDisk`) — a sandbox left deep asleep by an older build must still wake.
    public init?(rawValue: String) {
        switch rawValue {
        case "off": self = .off
        case "booting": self = .booting
        case "running": self = .running
        case "paused": self = .paused
        case "asleep", "pausedSaved": self = .asleep
        case "deepAsleep", "onDisk", "hibernated": self = .deepAsleep
        case "failed": self = .failed
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .off: "off"
        case .booting: "booting"
        case .running: "running"
        case .paused: "paused"
        case .asleep: "asleep"
        case .deepAsleep: "deepAsleep"
        case .failed: "failed"
        }
    }

    @available(*, deprecated, renamed: "asleep")
    public static var pausedSaved: Phase { .asleep }
    @available(*, deprecated, renamed: "deepAsleep")
    public static var onDisk: Phase { .deepAsleep }
}

/// The lifecycle operations, and — as pure data — the steps each performs from a given phase.
///
/// The planner exists so every invariant 576's owner smoke found the hard way is a UNIT test,
/// not a VM test: Stop decides from the phase it was called in (the POC once read it after
/// going busy and skipped stopping the VM); a paused VM's agent cannot answer, so Stop brings it
/// back first (578: stopping it at the VZ level instead leaves the package's vminitd clients
/// unclosed, and their deallocation is a fatal error); the snapshot is deleted the moment the VM
/// runs again; attached sessions are detached before anything severs their exec stdio.
public enum LifecycleOperation: String, Sendable, CaseIterable {
    /// Pause (alias Suspend) → Resume. Sleep → Wake. Deep Sleep (alias Hibernate) → Wake.
    /// Shut Down → Start (alias Cold Boot; `start()` is not a planned operation — it boots).
    case pause, resume, sleep, deepSleep, wake, shutDown
    /// Shut down (if needed), then discard the root disk: the next Start clones the prepared/baked disk.
    case resetToImage
    /// Shut down (if needed), then remove everything the sandbox has on disk.
    case delete

    @available(*, deprecated, renamed: "deepSleep") public static var sleepToDisk: Self { .deepSleep }
    @available(*, deprecated, renamed: "wake") public static var wakeFromDisk: Self { .wake }
    @available(*, deprecated, renamed: "shutDown") public static var stop: Self { .shutDown }
}

/// One step of a lifecycle operation, as data (`LifecyclePlanner`) — so the invariants above are
/// unit tests, not prose.
public enum LifecycleStep: Equatable, Sendable {
    /// VZ pause through the instance (also pauses the package's time syncer).
    case pauseVM
    /// VZ resume through the instance.
    case resumeVM
    /// VZ `saveMachineStateTo` — the snapshot.
    case saveSnapshot
    /// Tell every attached session connection it is detached, with this reason, BEFORE its exec
    /// stdio is severed — so nothing is written into a connection that is going away.
    case detachSessions(DetachReason)
    /// VZ `stop` directly on the virtual machine — Deep Sleep only: it keeps the container's
    /// objects for the wake.
    case stopVMDirect
    /// Shut Down only: make the VM runnable again WITHOUT reporting a phase change — resume a paused
    /// VM, restore + resume one on disk — so the graceful stop below can reach its agent.
    case reviveForStop
    /// `LinuxContainer.stop()` — graceful: kills the guest, deletes every process (closing each
    /// vminitd client) and stops the VM through the instance (closing its time-sync client and
    /// event loops). Falls back to a VZ-level stop if it fails.
    case stopContainer
    /// VZ `restoreMachineStateFrom` + resume.
    case restoreSnapshot
    /// Set the guest clock from the host's (a restored guest believes no time passed).
    case resyncClock
    /// Re-mount every virtio-fs share (virtio-fs does not survive a VM stop).
    case remountShares
    /// Delete the snapshot file: it is valid only while the VM is paused.
    case deleteSnapshot
    /// 583: best effort, never fails the operation — inflate the memory balloon over the guest's free
    /// pages (and keep it inflated), so the host drops the RAM a restore faulted in but the guest
    /// never touched (`Sandbox.returnFreeMemory()`).
    case returnFreeMemory
    /// 583: deflate the balloon before the VM is paused for a snapshot — a snapshot of an inflated
    /// balloon does not restore.
    case restoreGuestMemory
    /// 587: best effort, never fails the operation — `sync` in the guest (so a discarded Deep Sleep
    /// loses nothing written before it) and record what its file systems hold (`df`), for
    /// `DiskAccounting`'s garbage. Before a Deep Sleep's pause, and before a Stop's graceful stop.
    case syncGuest
    /// Drop the in-memory VM objects and the network lease, and persist the phase as off (shut
    /// down). The ROOT DISK STAYS: the next Start (Cold Boot) boots it (owner ruling 2026-09-25 — "Stop destroys the VM"
    /// was the 578 smoke finding: anything `apk add`ed vanished).
    case releaseRuntime
    /// Discard the root disk (and the identity persisted with it) — Reset to image.
    case removeRootDisk
    /// Remove the sandbox's whole directory — Delete sandbox.
    case removeSandboxFiles
    /// Write the persisted state (phase + identity), so a new process can restore.
    case persistState
}

/// Turns a `LifecycleOperation` into the ordered `LifecycleStep`s it takes, and the `Phase` it
/// leaves the sandbox in when it succeeds.
public enum LifecyclePlanner {
    /// The phase an operation leaves the sandbox in when it succeeds.
    public static func target(of op: LifecycleOperation) -> Phase {
        switch op {
        case .pause: .paused
        case .resume: .running
        case .sleep: .asleep
        case .deepSleep: .deepAsleep
        case .wake: .running
        case .shutDown, .resetToImage, .delete: .off
        }
    }

    /// The steps `op` runs from `phase`, or nil when `op` is not allowed there.
    /// `phase` MUST be the phase the caller observed when the operation was requested.
    public static func plan(_ op: LifecycleOperation, from phase: Phase) -> [LifecycleStep]? {
        switch (op, phase) {
        case (.pause, .running):
            return [.pauseVM]
        case (.resume, .paused), (.resume, .asleep), (.wake, .asleep):
            // Resume from Pause; Wake from Sleep (resume in place). `resume` from Sleep is the
            // pre-rename spelling and still works. The snapshot is valid only while paused:
            // running again invalidates it.
            return [.resumeVM, .deleteSnapshot, .persistState]
        case (.sleep, .running):
            return [.restoreGuestMemory, .pauseVM, .saveSnapshot, .persistState]
        case (.sleep, .paused):
            return [.saveSnapshot, .persistState]
        case (.deepSleep, .running):
            // 587: the guest syncs first — a Deep Sleep may be discarded, and what the guest had not
            // written back would be lost with it (586: the last ~5 s, journal or not).
            return [.restoreGuestMemory, .syncGuest, .pauseVM, .saveSnapshot, .detachSessions(.sandboxSleeping), .stopVMDirect, .persistState]
        case (.deepSleep, .paused):
            return [.saveSnapshot, .detachSessions(.sandboxSleeping), .stopVMDirect, .persistState]
        case (.deepSleep, .asleep):
            return [.detachSessions(.sandboxSleeping), .stopVMDirect, .persistState]
        case (.wake, .deepAsleep):
            return [.restoreSnapshot, .resyncClock, .remountShares, .deleteSnapshot, .returnFreeMemory, .persistState]
        case (.shutDown, _):
            return stopSteps(from: phase)
        case (.resetToImage, _):
            return (stopSteps(from: phase) ?? [.deleteSnapshot]) + [.removeRootDisk]
        case (.delete, _):
            return (stopSteps(from: phase) ?? []) + [.removeSandboxFiles]
        default:
            return nil
        }
    }

    /// Shut Down from `phase`, or nil when there is nothing running to stop. Every variant keeps the
    /// root disk; none leaves a snapshot behind (so the next Start is a cold boot and a stale
    /// snapshot is never restored onto a disk that has moved on).
    static func stopSteps(from phase: Phase) -> [LifecycleStep]? {
        switch phase {
        case .running:
            return [.detachSessions(.sandboxStopped), .syncGuest, .stopContainer, .deleteSnapshot, .releaseRuntime]
        case .failed, .booting:
            return [.detachSessions(.sandboxStopped), .stopContainer, .deleteSnapshot, .releaseRuntime]
        case .paused:
            // A paused guest cannot answer its agent: resume it first.
            return [.detachSessions(.sandboxStopped), .reviveForStop, .syncGuest, .stopContainer, .deleteSnapshot, .releaseRuntime]
        case .asleep, .deepAsleep:
            // One on disk has no VM running at all. (Its disk usage was recorded when it slept.)
            return [.detachSessions(.sandboxStopped), .reviveForStop, .stopContainer, .deleteSnapshot, .releaseRuntime]
        case .off:
            return nil
        }
    }
}
