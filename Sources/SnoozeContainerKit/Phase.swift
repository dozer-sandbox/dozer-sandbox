import Foundation

/// Where a sandbox is in its life. The 576.03 sleep design, one case per state a user can see.
public enum Phase: String, Sendable, Codable, CaseIterable {
    /// No VM. `start()` makes one.
    case off
    /// `start()` is running: images, the prepared disk, VM boot.
    case booting
    case running
    /// VZ-paused: guest CPU at 0, RAM still held. Resumes in ~1 ms.
    case paused
    /// Paused AND its full state saved to disk — crash insurance; RAM still held.
    case pausedSaved
    /// Saved to disk and the VM stopped: RAM returned. Wake restores it in ~0.35 s.
    case onDisk
    /// `start()` failed. `start()` again, or `stop()` to clean up.
    case failed

    /// A human label, as the 576 POC shows it.
    public var label: String {
        switch self {
        case .off: "Off"
        case .booting: "Booting"
        case .running: "Running"
        case .paused: "Asleep — in memory"
        case .pausedSaved: "Asleep — in memory + snapshot on disk"
        case .onDisk: "Asleep — on disk, RAM freed"
        case .failed: "Failed"
        }
    }

    /// The VM holds host RAM in this phase.
    public var holdsRAM: Bool { [.booting, .running, .paused, .pausedSaved].contains(self) }
    /// A snapshot on disk is valid (and needed) only in these phases; every other phase deletes it.
    public var keepsSnapshot: Bool { self == .pausedSaved || self == .onDisk }
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
    case pause, resume, sleep, sleepToDisk, wakeFromDisk, stop
}

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
    /// VZ `stop` directly on the virtual machine — sleep to disk only: it keeps the container's
    /// objects for the wake.
    case stopVMDirect
    /// Stop only: make the VM runnable again WITHOUT reporting a phase change — resume a paused
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
    /// Remove the container's runtime files (root disk clone, persisted state).
    case removeRuntimeFiles
    /// Write the persisted state (phase + identity), so a new process can restore.
    case persistState
}

public enum LifecyclePlanner {
    /// The phase an operation leaves the sandbox in when it succeeds.
    public static func target(of op: LifecycleOperation) -> Phase {
        switch op {
        case .pause: .paused
        case .resume: .running
        case .sleep: .pausedSaved
        case .sleepToDisk: .onDisk
        case .wakeFromDisk: .running
        case .stop: .off
        }
    }

    /// The steps `op` runs from `phase`, or nil when `op` is not allowed there.
    /// `phase` MUST be the phase the caller observed when the operation was requested.
    public static func plan(_ op: LifecycleOperation, from phase: Phase) -> [LifecycleStep]? {
        switch (op, phase) {
        case (.pause, .running):
            return [.pauseVM]
        case (.resume, .paused), (.resume, .pausedSaved):
            // The snapshot is only valid while paused: running again invalidates it.
            return [.resumeVM, .deleteSnapshot, .persistState]
        case (.sleep, .running):
            return [.pauseVM, .saveSnapshot, .persistState]
        case (.sleep, .paused):
            return [.saveSnapshot, .persistState]
        case (.sleepToDisk, .running):
            return [.pauseVM, .saveSnapshot, .detachSessions(.sandboxSleeping), .stopVMDirect, .persistState]
        case (.sleepToDisk, .paused):
            return [.saveSnapshot, .detachSessions(.sandboxSleeping), .stopVMDirect, .persistState]
        case (.sleepToDisk, .pausedSaved):
            return [.detachSessions(.sandboxSleeping), .stopVMDirect, .persistState]
        case (.wakeFromDisk, .onDisk):
            return [.restoreSnapshot, .resyncClock, .remountShares, .deleteSnapshot, .persistState]
        case (.stop, .running), (.stop, .failed), (.stop, .booting):
            return [.detachSessions(.sandboxStopped), .stopContainer, .deleteSnapshot, .removeRuntimeFiles]
        case (.stop, .paused), (.stop, .pausedSaved), (.stop, .onDisk):
            // A paused guest cannot answer its agent; one on disk has no VM running at all.
            return [.detachSessions(.sandboxStopped), .reviveForStop, .stopContainer, .deleteSnapshot, .removeRuntimeFiles]
        default:
            return nil
        }
    }
}
