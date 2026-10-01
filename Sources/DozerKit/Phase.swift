import Foundation

/// Where a sandbox is in its life — the owner's vocabulary (2026-09-25):
///
///     Start (Cold Boot) ─▶ running ─ Pause (Suspend) ─▶ paused ─ Resume ─▶ running
///                          running ─ Sleep ───────────▶ asleep ─ Wake ───▶ running   RAM kept, snapshot on disk
///                          running ─ Hibernate ───────▶ hibernated ─ Wake ─▶ running   RAM freed
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
    /// Hibernated: saved to disk and the VM stopped — RAM returned. Wake restores it in ~0.35 s.
    case hibernated
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
        case .hibernated: "Hibernated — RAM freed"
        case .failed: "Failed"
        }
    }

    /// The VM holds host RAM in this phase.
    public var holdsRAM: Bool { [.booting, .running, .paused, .asleep].contains(self) }
    /// A snapshot on disk is valid (and needed) only in these phases; every other phase deletes it.
    public var keepsSnapshot: Bool { self == .asleep || self == .hibernated }

    /// Decodes today's names AND the names persisted before the 2026-09-25 rename (`pausedSaved`,
    /// `onDisk`) — a sandbox left hibernated by an older build must still wake.
    public init?(rawValue: String) {
        switch rawValue {
        case "off": self = .off
        case "booting": self = .booting
        case "running": self = .running
        case "paused": self = .paused
        case "asleep", "pausedSaved": self = .asleep
        // The ONE compatibility shim of the 593 rename to Hibernate (owner ruling 2026-09-29, no
        // aliases anywhere else): a record persisted as "deepAsleep" still decodes, so a store
        // written before the rename still loads.
        case "hibernated", "onDisk", "deepAsleep": self = .hibernated
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
        case .hibernated: "hibernated"
        case .failed: "failed"
        }
    }

    @available(*, deprecated, renamed: "asleep")
    public static var pausedSaved: Phase { .asleep }
    @available(*, deprecated, renamed: "hibernated")
    public static var onDisk: Phase { .hibernated }
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
    /// Pause (alias Suspend) → Resume. Sleep → Wake. Hibernate → Wake.
    /// Shut Down → Start (alias Cold Boot; `start()` is not a planned operation — it boots).
    case pause, resume, sleep, hibernate, wake, shutDown
    /// Shut down (if needed), then discard the root disk: the next Start clones the prepared/baked disk.
    case resetToImage
    /// Shut down (if needed), then remove everything the sandbox has on disk.
    case delete

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
    /// VZ `stop` directly on the virtual machine — Hibernate only: it keeps the container's
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
    /// 594 W34: best effort, never fails the operation — one root exec of `GuestCommand.guestFixes`
    /// (debconf, /etc/hosts, the open-URL shim, the time zone, the agent's sudo): what a fresh boot
    /// applies, for a sandbox that is only ever woken. A failure is noted.
    case applyGuestFixes
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
    /// 587: best effort, never fails the operation — `sync` in the guest (so a discarded hibernation
    /// loses nothing written before it) and record what its file systems hold (`df`), for
    /// `DiskAccounting`'s garbage. Before a hibernation's pause, and before a Stop's graceful stop.
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
    /// 593: best effort, never fails the operation, bounded (`SavedScreens.totalBudgetSeconds`) — save
    /// every session's screen while the guest can still answer: the FIRST step of pausing, sleeping or
    /// hibernating a RUNNING sandbox (the phases one wakes back into). A failed capture keeps the
    /// previous file.
    case captureScreens
    /// 593: delete the saved screens — shut down, reset: the sessions they showed are gone (owner,
    /// 2026-09-30: a shut-down sandbox shows no session screens).
    case removeSavedScreens
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
        case .hibernate: .hibernated
        case .wake: .running
        case .shutDown, .resetToImage, .delete: .off
        }
    }

    /// The steps `op` runs from `phase`, or nil when `op` is not allowed there.
    /// `phase` MUST be the phase the caller observed when the operation was requested.
    public static func plan(_ op: LifecycleOperation, from phase: Phase) -> [LifecycleStep]? {
        switch (op, phase) {
        case (.pause, .running):
            return [.captureScreens, .pauseVM]
        case (.resume, .paused):
            // Resume from Pause (~1 ms): no guest call. The snapshot is valid only while paused:
            // running again invalidates it.
            return [.resumeVM, .deleteSnapshot, .persistState]
        case (.resume, .asleep), (.wake, .asleep):
            // Wake from Sleep (resume in place); `resume` from Sleep is the pre-rename spelling and
            // still works. W34: a wake applies the guest fixes.
            return [.resumeVM, .applyGuestFixes, .deleteSnapshot, .persistState]
        case (.sleep, .running):
            return [.captureScreens, .restoreGuestMemory, .pauseVM, .saveSnapshot, .persistState]
        case (.sleep, .paused):
            return [.saveSnapshot, .persistState]
        case (.hibernate, .running):
            // 587: the guest syncs first — a hibernation may be discarded, and what the guest had not
            // written back would be lost with it (586: the last ~5 s, journal or not).
            return [.captureScreens, .restoreGuestMemory, .syncGuest, .pauseVM, .saveSnapshot, .detachSessions(.sandboxSleeping), .stopVMDirect, .persistState]
        case (.hibernate, .paused):
            return [.saveSnapshot, .detachSessions(.sandboxSleeping), .stopVMDirect, .persistState]
        case (.hibernate, .asleep):
            return [.detachSessions(.sandboxSleeping), .stopVMDirect, .persistState]
        case (.wake, .hibernated):
            return [.restoreSnapshot, .resyncClock, .applyGuestFixes, .remountShares, .deleteSnapshot, .returnFreeMemory, .persistState]
        case (.shutDown, _):
            // 593 (owner, 2026-09-30): no capture — the sessions end with the VM, and every saved screen
            // goes with them. From off there is nothing to stop and nothing changes.
            guard let steps = stopSteps(from: phase) else { return nil }
            return steps + [.removeSavedScreens]
        case (.resetToImage, _):
            // No capture: the saved screens are deleted with the disk (S6).
            return (stopSteps(from: phase) ?? [.deleteSnapshot]) + [.removeRootDisk, .removeSavedScreens]
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
        case .asleep, .hibernated:
            // One on disk has no VM running at all. (Its disk usage was recorded when it slept.)
            return [.detachSessions(.sandboxStopped), .reviveForStop, .stopContainer, .deleteSnapshot, .releaseRuntime]
        case .off:
            return nil
        }
    }
}
