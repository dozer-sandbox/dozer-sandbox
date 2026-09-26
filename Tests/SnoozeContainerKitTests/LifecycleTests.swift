import XCTest
@testable import SnoozeContainerKit

/// The lifecycle rules 576's owner smoke found, as pure data (see `LifecyclePlanner`).
final class LifecycleTests: XCTestCase {
    private func plan(_ op: LifecycleOperation, _ p: Phase) -> [LifecycleStep]? { LifecyclePlanner.plan(op, from: p) }

    /// Stop decides from the phase it was CALLED in. A paused guest cannot answer its agent and
    /// one on disk is not running, so both are revived (silently) and then stopped GRACEFULLY —
    /// never left stopped at the VZ level with the package's vminitd clients unclosed.
    func test_stopPlanDependsOnThePhaseItWasCalledIn() {
        XCTAssertEqual(plan(.shutDown, .running), [.detachSessions(.sandboxStopped), .stopContainer, .deleteSnapshot, .releaseRuntime])
        for p in [Phase.paused, .asleep, .deepAsleep] {
            XCTAssertEqual(plan(.shutDown, p), [.detachSessions(.sandboxStopped), .reviveForStop, .stopContainer, .deleteSnapshot, .releaseRuntime], "\(p)")
        }
        XCTAssertNil(plan(.shutDown, .off))
        for p in Phase.allCases {
            XCTAssertFalse(plan(.shutDown, p)?.contains(.stopVMDirect) ?? false, "stop from \(p) is always graceful")
        }
    }

    /// Owner ruling 2026-09-25: Stop KEEPS the root disk (the next Start cold-boots it); Reset to
    /// image and Delete remove it — from any phase, stopping first when something runs.
    func test_stopKeepsTheRootDiskResetAndDeleteRemoveIt() {
        for p in Phase.allCases {
            let stop = plan(.shutDown, p) ?? []
            XCTAssertFalse(stop.contains(.removeRootDisk) || stop.contains(.removeSandboxFiles), "stop from \(p) keeps the disk")
            let reset = plan(.resetToImage, p)!
            XCTAssertEqual(reset.last, .removeRootDisk, "reset from \(p)")
            XCTAssertTrue(reset.contains(.deleteSnapshot), "reset never leaves a snapshot for a disk that is gone (\(p))")
            XCTAssertEqual(plan(.delete, p)!.last, .removeSandboxFiles, "delete from \(p)")
            if p != .off {
                XCTAssertEqual(Array(reset.dropLast()), stop, "reset stops first (\(p))")
                XCTAssertEqual(Array(plan(.delete, p)!.dropLast()), stop, "delete stops first (\(p))")
            }
        }
        XCTAssertEqual(plan(.delete, .off), [.removeSandboxFiles])
        XCTAssertEqual(LifecyclePlanner.target(of: .resetToImage), .off)
        XCTAssertEqual(LifecyclePlanner.target(of: .delete), .off)
    }

    /// No stop leaves a snapshot: the next Start is a cold boot.
    func test_noStopLeavesASnapshot() {
        for p in Phase.allCases { if let s = plan(.shutDown, p) { XCTAssertTrue(s.contains(.deleteSnapshot), "\(p)") } }
    }

    /// Every stop detaches attached sessions FIRST, so no exec output reaches a connection
    /// after the VM goes down (the recycled-fd bug).
    func test_everyStopDetachesSessionsFirst() {
        for p in Phase.allCases {
            guard let steps = plan(.shutDown, p) else { continue }
            XCTAssertEqual(steps.first, .detachSessions(.sandboxStopped), "stop from \(p)")
        }
    }

    /// The snapshot is valid only while paused: every operation that ends RUNNING deletes it.
    func test_snapshotIsDeletedWheneverTheVMRunsAgain() {
        for op in LifecycleOperation.allCases where LifecyclePlanner.target(of: op) == .running {
            for p in Phase.allCases {
                guard let steps = plan(op, p) else { continue }
                XCTAssertTrue(steps.contains(.deleteSnapshot), "\(op) from \(p)")
                let resumeAt = steps.firstIndex { $0 == .resumeVM || $0 == .restoreSnapshot }!
                XCTAssertGreaterThan(steps.firstIndex(of: .deleteSnapshot)!, resumeAt, "delete only once running: \(op) from \(p)")
            }
        }
        XCTAssertTrue(plan(.shutDown, .deepAsleep)!.contains(.deleteSnapshot))
    }

    /// Wake resyncs the clock and re-mounts shares, after the restore and before the snapshot goes.
    func test_wakeRestoresThenResyncsClockAndRemountsShares() {
        XCTAssertEqual(plan(.wake, .deepAsleep), [.restoreSnapshot, .resyncClock, .remountShares, .deleteSnapshot, .returnFreeMemory, .persistState])
        XCTAssertNil(plan(.wake, .running))
    }

    /// Sleep to disk saves before it severs anything, detaches sessions before the VZ stop, and
    /// never pauses twice.
    func test_deepSleepOrdering() {
        let fromRunning = plan(.deepSleep, .running)!
        XCTAssertEqual(fromRunning, [.restoreGuestMemory, .pauseVM, .saveSnapshot, .detachSessions(.sandboxSleeping), .stopVMDirect, .persistState])
        XCTAssertEqual(plan(.deepSleep, .paused), [.saveSnapshot, .detachSessions(.sandboxSleeping), .stopVMDirect, .persistState])
        XCTAssertEqual(plan(.deepSleep, .asleep), [.detachSessions(.sandboxSleeping), .stopVMDirect, .persistState])
        XCTAssertNil(plan(.deepSleep, .deepAsleep))
    }

    func test_pauseResumeSleepAvailability() {
        XCTAssertEqual(plan(.pause, .running), [.pauseVM])
        XCTAssertNil(plan(.pause, .paused))
        XCTAssertEqual(plan(.resume, .paused), [.resumeVM, .deleteSnapshot, .persistState])
        XCTAssertEqual(plan(.resume, .asleep), [.resumeVM, .deleteSnapshot, .persistState])
        XCTAssertNil(plan(.resume, .deepAsleep), "on disk needs a wake, not a resume")
        XCTAssertEqual(plan(.sleep, .running), [.restoreGuestMemory, .pauseVM, .saveSnapshot, .persistState])
        XCTAssertEqual(plan(.sleep, .paused), [.saveSnapshot, .persistState])
        XCTAssertNil(plan(.sleep, .asleep))
    }

    /// 583: a snapshot of an inflated memory balloon does not restore — every plan that snapshots a
    /// RUNNING VM gives the guest its memory back before it pauses (from Pause, `saveSnapshot` does).
    func test_balloonDeflatedBeforeEverySnapshotOfARunningVM() {
        for op in LifecycleOperation.allCases {
            guard let steps = plan(op, .running), let save = steps.firstIndex(of: .saveSnapshot) else { continue }
            let deflate = steps.firstIndex(of: .restoreGuestMemory)
            XCTAssertNotNil(deflate, "\(op)")
            XCTAssertLessThan(deflate ?? .max, steps.firstIndex(of: .pauseVM) ?? save, "\(op): deflate while the guest runs")
        }
        XCTAssertEqual(plan(.wake, .deepAsleep)?.firstIndex(of: .returnFreeMemory).map { $0 > 0 }, true)
    }

    func test_phaseProperties() {
        XCTAssertTrue(Phase.paused.holdsRAM)
        XCTAssertFalse(Phase.deepAsleep.holdsRAM)
        XCTAssertEqual(Phase.allCases.filter(\.keepsSnapshot), [.asleep, .deepAsleep])
        XCTAssertEqual(LifecyclePlanner.target(of: .shutDown), .off)
    }
}

final class StoreLayoutTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/snooze-store")

    func test_layoutPaths() {
        let l = StoreLayout(root: root, name: "lab")
        XCTAssertEqual(l.initfs.path, "/tmp/snooze-store/initfs.ext4")
        XCTAssertEqual(l.rootfs.path, "/tmp/snooze-store/sandboxes/lab/rootfs.ext4")
        XCTAssertEqual(l.snapshot.path, "/tmp/snooze-store/sandboxes/lab/vm.state")
        XCTAssertEqual(l.persistedState.path, "/tmp/snooze-store/sandboxes/lab/sandbox.json")
        XCTAssertEqual(l.bootLog.path, "/tmp/snooze-store/sandboxes/lab/bootlog.log")
        XCTAssertEqual(l.bakeContainerID, "lab-bake")
    }

    /// A different package list or disk size is a different prepared disk — never a stale one.
    func test_goldenKeyTracksImagePackagesAndSize() {
        let a = SandboxSpec(name: "lab", storeRoot: root, bakePackages: ["bash", "ncurses"])
        var b = a; b.bakePackages = ["ncurses", "bash"]
        var c = a; c.bakePackages = ["bash"]
        var d = a; d.rootfsMiB = 2048
        var e = a; e.name = "other"
        let k = StoreLayout.goldenKey(for:)
        XCTAssertEqual(k(a), k(b), "order does not matter")
        XCTAssertNotEqual(k(a), k(c))
        XCTAssertNotEqual(k(a), k(d))
        XCTAssertEqual(k(a), k(e), "shared across sandboxes in one store")
        XCTAssertTrue(k(a).hasPrefix("alpine-3.20-"))
    }

    func test_specValidation() {
        XCTAssertNoThrow(try SandboxSpec(name: "lab-1", storeRoot: root).validate())
        XCTAssertThrowsError(try SandboxSpec(name: "Lab", storeRoot: root).validate())
        XCTAssertThrowsError(try SandboxSpec(name: "-x", storeRoot: root).validate())
        XCTAssertThrowsError(try SandboxSpec(name: "a", storeRoot: root, shares: [Share(hostPath: "/x", guestPath: "rel")]).validate())
        XCTAssertThrowsError(try SandboxSpec(name: "a", storeRoot: root, bakePackages: ["bash; rm"]).validate())
    }
}

final class PersistedSandboxTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("snooze-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// The machine identifier (and the rest of the identity) survives a round trip byte for byte —
    /// VZ refuses to restore a snapshot into a VM whose identifier differs.
    func test_machineIdentifierRoundTrip() throws {
        let spec = SandboxSpec(name: "lab", storeRoot: dir, bakePackages: ["bash"], shares: [Share(hostPath: "/tmp/w", guestPath: "/work")])
        let mid = Data((0..<48).map { _ in UInt8.random(in: 0...255) })
        let p = PersistedSandbox(spec: spec, phase: .deepAsleep, machineIdentifier: mid, macAddress: PersistedSandbox.randomMAC(),
                                 subnet: "192.168.64.1/24", shareTags: ["/work": "abc"])
        let url = StoreLayout(spec: spec).persistedState
        try p.write(to: url)
        let back = try XCTUnwrap(PersistedSandbox.read(from: url))
        XCTAssertEqual(back.machineIdentifier, mid)
        XCTAssertEqual(back.spec, spec)
        XCTAssertEqual(back.macAddress, p.macAddress)
        XCTAssertEqual(back.shareTags, ["/work": "abc"])
        XCTAssertEqual(back.phase, .deepAsleep)
    }

    func test_restorableOnlyWhenAsleepWithSnapshotAndDisk() throws {
        let spec = SandboxSpec(name: "lab", storeRoot: dir)
        let layout = StoreLayout(spec: spec)
        try FileManager.default.createDirectory(at: layout.sandboxDirectory, withIntermediateDirectories: true)
        var p = PersistedSandbox(spec: spec, phase: .deepAsleep, machineIdentifier: Data([1]), macAddress: nil, subnet: nil, shareTags: [:])
        XCTAssertFalse(p.isRestorable(layout: layout), "no files yet")
        try Data("s".utf8).write(to: layout.snapshot)
        try Data("r".utf8).write(to: layout.rootfs)
        XCTAssertTrue(p.isRestorable(layout: layout))
        p.phase = .running
        XCTAssertFalse(p.isRestorable(layout: layout), "a crash while running leaves no valid snapshot")
        p.phase = .asleep
        XCTAssertTrue(p.isRestorable(layout: layout))
        try p.write(to: layout.persistedState)
        XCTAssertNotNil(Sandbox.restorableState(for: spec))
        Sandbox.discardRestorableState(for: spec)
        XCTAssertNil(Sandbox.restorableState(for: spec))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.snapshot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.rootfs.path), "discarding the snapshot keeps the root disk")
        XCTAssertEqual(PersistedSandbox.read(from: layout.persistedState)?.phase, .off)
        XCTAssertNotNil(Sandbox.keptRootDisk(layout), "the next Start cold-boots the kept disk")
        XCTAssertEqual(PersistedSandbox.read(from: layout.persistedState)?.fsckOnNextBoot, true,
                       "583: the deep-slept VM never unmounted the disk — the cold boot runs e2fsck first")
    }

    /// 583: the first guest calls of a wake are retried on a closed/reset vsock channel — and only then.
    func test_transientGuestTransportErrors() {
        struct E: Error, CustomStringConvertible { let description: String }
        XCTAssertTrue(Sandbox.isTransientGuestTransportError(E(description: "unavailable: \"The channel was closed\"")))
        XCTAssertTrue(Sandbox.isTransientGuestTransportError(E(description: "read: Connection reset by peer")))
        XCTAssertFalse(Sandbox.isTransientGuestTransportError(E(description: "invalidArgument: \"no such file\"")))
        XCTAssertFalse(Sandbox.isTransientGuestTransportError(SandboxError.vmUnavailable))
    }

    /// 583 (582 §8: 12 of 15 cold boots of a discarded snapshot's disk failed): a kept disk is
    /// checked unless the last VM that ran it was shut down through the package.
    func test_keptDiskNeedsFsckUnlessCleanlyShutDown() {
        let spec = SandboxSpec(name: "lab", storeRoot: dir)
        var p = PersistedSandbox(spec: spec, phase: .off, machineIdentifier: Data([1]), macAddress: nil, subnet: nil, shareTags: [:])
        XCTAssertFalse(Sandbox.keptDiskNeedsFsck(p, snapshotPresent: false), "a clean Shut Down")
        XCTAssertTrue(Sandbox.keptDiskNeedsFsck(p, snapshotPresent: true), "a snapshot beside the disk: it was asleep, never unmounted")
        for phase in [Phase.running, .paused, .asleep, .deepAsleep, .booting, .failed] {
            p.phase = phase
            XCTAssertTrue(Sandbox.keptDiskNeedsFsck(p, snapshotPresent: false), "last durable phase \(phase)")
        }
        p.phase = .off
        p.fsckOnNextBoot = true
        XCTAssertTrue(Sandbox.keptDiskNeedsFsck(p, snapshotPresent: false), "an explicit mark")
    }

    func test_randomMACIsLocallyAdministeredUnicast() {
        for _ in 0..<50 {
            let mac = PersistedSandbox.randomMAC()
            let first = UInt8(mac.prefix(2), radix: 16)!
            XCTAssertEqual(first & 0x03, 0x02, mac)
            XCTAssertEqual(mac.split(separator: ":").count, 6)
        }
    }

    // MARK: the 2026-09-25 vocabulary (Pause/Suspend · Sleep · Deep Sleep/Hibernate · Wake · Shut Down · Start/Cold Boot)

    func test_wakeFromSleepResumesInPlace_andResumeStillWorksFromSleep() {
        XCTAssertEqual(LifecyclePlanner.plan(.wake, from: .asleep), [.resumeVM, .deleteSnapshot, .persistState])
        XCTAssertEqual(LifecyclePlanner.plan(.resume, from: .asleep), LifecyclePlanner.plan(.wake, from: .asleep), "resume from Sleep is the old spelling of wake")
        XCTAssertNil(LifecyclePlanner.plan(.wake, from: .running))
        XCTAssertNil(LifecyclePlanner.plan(.wake, from: .paused), "a paused sandbox resumes, it does not wake")
        XCTAssertEqual(LifecyclePlanner.target(of: .wake), .running)
        XCTAssertEqual(LifecyclePlanner.target(of: .deepSleep), .deepAsleep)
    }

    func test_phaseLabelsAreTheOwnersNames() {
        XCTAssertEqual(Phase.paused.label, "Paused")
        XCTAssertTrue(Phase.asleep.label.hasPrefix("Asleep"))
        XCTAssertTrue(Phase.deepAsleep.label.hasPrefix("Deep asleep"))
        XCTAssertEqual(Phase.off.label, "Shut down")
    }

    /// A sandbox left asleep by a build from before the rename must still decode — and wake.
    func test_oldPersistedPhasesDecode() throws {
        for (old, new) in [("pausedSaved", Phase.asleep), ("onDisk", .deepAsleep), ("hibernated", .deepAsleep),
                           ("running", .running), ("off", .off), ("paused", .paused)] {
            XCTAssertEqual(try JSONDecoder().decode(Phase.self, from: Data("\"\(old)\"".utf8)), new, old)
            XCTAssertEqual(Phase(rawValue: old), new)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(Phase.self, from: Data("\"nonsense\"".utf8)))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(Phase.deepAsleep), as: UTF8.self), "\"deepAsleep\"", "new files use the new name")
        // A whole persisted sandbox.json from before the rename.
        let spec = SandboxSpec(name: "old", storeRoot: URL(fileURLWithPath: "/tmp/old-store"))
        let p = PersistedSandbox(spec: spec, phase: .deepAsleep, machineIdentifier: Data([1, 2]), macAddress: nil, subnet: nil, shareTags: [:])
        let json = String(decoding: try JSONEncoder().encode(p), as: UTF8.self).replacingOccurrences(of: "\"deepAsleep\"", with: "\"onDisk\"")
        XCTAssertTrue(json.contains("\"onDisk\""))
        XCTAssertEqual(try JSONDecoder().decode(PersistedSandbox.self, from: Data(json.utf8)).phase, .deepAsleep)
    }

    @available(*, deprecated)
    func test_deprecatedNamesForward() {
        XCTAssertEqual(Phase.onDisk, .deepAsleep)
        XCTAssertEqual(Phase.pausedSaved, .asleep)
        XCTAssertEqual(LifecycleOperation.sleepToDisk, .deepSleep)
        XCTAssertEqual(LifecycleOperation.wakeFromDisk, .wake)
        XCTAssertEqual(LifecycleOperation.stop, .shutDown)
        XCTAssertEqual(LifecyclePlanner.plan(.sleepToDisk, from: .running), LifecyclePlanner.plan(.deepSleep, from: .running))
    }

    /// The forwarding METHODS, without a VM: each must reach the same planned operation — observed
    /// through the error an off sandbox throws (it names the operation it was asked to perform).
    @available(*, deprecated)
    func test_deprecatedMethodsForward() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fwd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sb = try Sandbox(spec: SandboxSpec(name: "fwd", storeRoot: root))
        func opName(_ body: () async throws -> Void) async -> String? {
            do { try await body(); return nil } catch SandboxError.invalidPhase(let op, _) { return op } catch { return "\(error)" }
        }
        let a = await opName { try await sb.sleepToDisk() }, b = await opName { try await sb.deepSleep() }, c = await opName { try await sb.hibernate() }
        XCTAssertEqual(a, "deepSleep"); XCTAssertEqual(b, "deepSleep"); XCTAssertEqual(c, "deepSleep")
        let w1 = await opName { try await sb.wakeFromDisk() }, w2 = await opName { try await sb.wake() }
        XCTAssertEqual(w1, "wake"); XCTAssertEqual(w2, "wake")
        let p1 = await opName { try await sb.suspend() }
        XCTAssertEqual(p1, "pause")
        // Shut Down from off: nothing to stop, refused the same way through either name.
        let s1 = await opName { try await sb.stop() }, s2 = await opName { try await sb.shutDown() }
        XCTAssertEqual(s1, "shutDown"); XCTAssertEqual(s2, "shutDown")
        let phase = await sb.phase
        XCTAssertEqual(phase, .off)
    }
}
