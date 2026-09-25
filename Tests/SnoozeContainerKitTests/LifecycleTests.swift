import XCTest
@testable import SnoozeContainerKit

/// The lifecycle rules 576's owner smoke found, as pure data (see `LifecyclePlanner`).
final class LifecycleTests: XCTestCase {
    private func plan(_ op: LifecycleOperation, _ p: Phase) -> [LifecycleStep]? { LifecyclePlanner.plan(op, from: p) }

    /// Stop decides from the phase it was CALLED in. A paused guest cannot answer its agent and
    /// one on disk is not running, so both are revived (silently) and then stopped GRACEFULLY —
    /// never left stopped at the VZ level with the package's vminitd clients unclosed.
    func test_stopPlanDependsOnThePhaseItWasCalledIn() {
        XCTAssertEqual(plan(.stop, .running), [.detachSessions(.sandboxStopped), .stopContainer, .deleteSnapshot, .removeRuntimeFiles])
        for p in [Phase.paused, .pausedSaved, .onDisk] {
            XCTAssertEqual(plan(.stop, p), [.detachSessions(.sandboxStopped), .reviveForStop, .stopContainer, .deleteSnapshot, .removeRuntimeFiles], "\(p)")
        }
        XCTAssertNil(plan(.stop, .off))
        for p in Phase.allCases {
            XCTAssertFalse(plan(.stop, p)?.contains(.stopVMDirect) ?? false, "stop from \(p) is always graceful")
        }
    }

    /// Every stop detaches attached sessions FIRST, so no exec output reaches a connection
    /// after the VM goes down (the recycled-fd bug).
    func test_everyStopDetachesSessionsFirst() {
        for p in Phase.allCases {
            guard let steps = plan(.stop, p) else { continue }
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
        XCTAssertTrue(plan(.stop, .onDisk)!.contains(.deleteSnapshot))
    }

    /// Wake resyncs the clock and re-mounts shares, after the restore and before the snapshot goes.
    func test_wakeRestoresThenResyncsClockAndRemountsShares() {
        XCTAssertEqual(plan(.wakeFromDisk, .onDisk), [.restoreSnapshot, .resyncClock, .remountShares, .deleteSnapshot, .persistState])
        XCTAssertNil(plan(.wakeFromDisk, .running))
    }

    /// Sleep to disk saves before it severs anything, detaches sessions before the VZ stop, and
    /// never pauses twice.
    func test_sleepToDiskOrdering() {
        let fromRunning = plan(.sleepToDisk, .running)!
        XCTAssertEqual(fromRunning, [.pauseVM, .saveSnapshot, .detachSessions(.sandboxSleeping), .stopVMDirect, .persistState])
        XCTAssertEqual(plan(.sleepToDisk, .paused), [.saveSnapshot, .detachSessions(.sandboxSleeping), .stopVMDirect, .persistState])
        XCTAssertEqual(plan(.sleepToDisk, .pausedSaved), [.detachSessions(.sandboxSleeping), .stopVMDirect, .persistState])
        XCTAssertNil(plan(.sleepToDisk, .onDisk))
    }

    func test_pauseResumeSleepAvailability() {
        XCTAssertEqual(plan(.pause, .running), [.pauseVM])
        XCTAssertNil(plan(.pause, .paused))
        XCTAssertEqual(plan(.resume, .paused), [.resumeVM, .deleteSnapshot, .persistState])
        XCTAssertEqual(plan(.resume, .pausedSaved), [.resumeVM, .deleteSnapshot, .persistState])
        XCTAssertNil(plan(.resume, .onDisk), "on disk needs a wake, not a resume")
        XCTAssertEqual(plan(.sleep, .running), [.pauseVM, .saveSnapshot, .persistState])
        XCTAssertEqual(plan(.sleep, .paused), [.saveSnapshot, .persistState])
        XCTAssertNil(plan(.sleep, .pausedSaved))
    }

    func test_phaseProperties() {
        XCTAssertTrue(Phase.paused.holdsRAM)
        XCTAssertFalse(Phase.onDisk.holdsRAM)
        XCTAssertEqual(Phase.allCases.filter(\.keepsSnapshot), [.pausedSaved, .onDisk])
        XCTAssertEqual(LifecyclePlanner.target(of: .stop), .off)
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
        let p = PersistedSandbox(spec: spec, phase: .onDisk, machineIdentifier: mid, macAddress: PersistedSandbox.randomMAC(),
                                 subnet: "192.168.64.1/24", shareTags: ["/work": "abc"])
        let url = StoreLayout(spec: spec).persistedState
        try p.write(to: url)
        let back = try XCTUnwrap(PersistedSandbox.read(from: url))
        XCTAssertEqual(back.machineIdentifier, mid)
        XCTAssertEqual(back.spec, spec)
        XCTAssertEqual(back.macAddress, p.macAddress)
        XCTAssertEqual(back.shareTags, ["/work": "abc"])
        XCTAssertEqual(back.phase, .onDisk)
    }

    func test_restorableOnlyWhenAsleepWithSnapshotAndDisk() throws {
        let spec = SandboxSpec(name: "lab", storeRoot: dir)
        let layout = StoreLayout(spec: spec)
        try FileManager.default.createDirectory(at: layout.sandboxDirectory, withIntermediateDirectories: true)
        var p = PersistedSandbox(spec: spec, phase: .onDisk, machineIdentifier: Data([1]), macAddress: nil, subnet: nil, shareTags: [:])
        XCTAssertFalse(p.isRestorable(layout: layout), "no files yet")
        try Data("s".utf8).write(to: layout.snapshot)
        try Data("r".utf8).write(to: layout.rootfs)
        XCTAssertTrue(p.isRestorable(layout: layout))
        p.phase = .running
        XCTAssertFalse(p.isRestorable(layout: layout), "a crash while running leaves no valid snapshot")
        p.phase = .pausedSaved
        XCTAssertTrue(p.isRestorable(layout: layout))
        try p.write(to: layout.persistedState)
        XCTAssertNotNil(Sandbox.restorableState(for: spec))
        Sandbox.discardRestorableState(for: spec)
        XCTAssertNil(Sandbox.restorableState(for: spec))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.snapshot.path))
    }

    func test_randomMACIsLocallyAdministeredUnicast() {
        for _ in 0..<50 {
            let mac = PersistedSandbox.randomMAC()
            let first = UInt8(mac.prefix(2), radix: 16)!
            XCTAssertEqual(first & 0x03, 0x02, mac)
            XCTAssertEqual(mac.split(separator: ":").count, 6)
        }
    }
}
