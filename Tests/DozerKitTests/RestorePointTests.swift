import Foundation
import XCTest
@testable import DozerKit

/// Restore points with the sandbox STOPPED are pure file operations (APFS clones), so the whole
/// take / revert / fork / delete / save-as-image cycle is testable without a VM.
final class RestorePointTests: XCTestCase {
    private var dir: URL!
    private var spec: SandboxSpec!
    private var layout: StoreLayout!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-rp-\(UUID().uuidString)")
        spec = SandboxSpec(name: "lab", storeRoot: dir)
        layout = StoreLayout(spec: spec)
        try FileManager.default.createDirectory(at: layout.sandboxDirectory, withIntermediateDirectories: true)
        try disk("v1")
        var p = PersistedSandbox(spec: spec, phase: .off, machineIdentifier: Data([1]), macAddress: nil, subnet: nil, shareTags: [:])
        p.rootImage = "alpine-3.20-abc"
        try p.write(to: layout.persistedState)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func disk(_ content: String) throws { try Data(content.utf8).write(to: layout.rootfs) }
    private func rootContent() throws -> String { String(decoding: try Data(contentsOf: layout.rootfs), as: UTF8.self) }

    func test_takeRevertCycleWhileStopped() async throws {
        let sb = try Sandbox(spec: spec)
        let rp1 = try await sb.takeRestorePoint(name: "one", note: "first")
        XCTAssertEqual(rp1.takenWhile, .stopped)
        XCTAssertFalse(rp1.needsFsck)
        XCTAssertEqual(rp1.sourceImage, "alpine-3.20-abc")
        XCTAssertTrue(rp1.id.hasPrefix("rp-"))
        try disk("v2")
        let rp2 = try await sb.takeRestorePoint(name: "two")
        try disk("v3")

        try await sb.revert(to: rp1.id)
        XCTAssertEqual(try rootContent(), "v1", "reverted to one")
        let auto = try XCTUnwrap(sb.restorePoints().first { $0.automatic })
        XCTAssertEqual(auto.name, "before revert to one")
        let p = try XCTUnwrap(PersistedSandbox.read(from: layout.persistedState))
        XCTAssertEqual(p.restorePoint, rp1.id)
        XCTAssertEqual(p.phase, .off)
        XCTAssertNil(p.fsckOnNextBoot, "a stopped copy needs no fsck")

        try await sb.revert(to: auto.id, takeBeforeRevert: false)
        XCTAssertEqual(try rootContent(), "v3", "the automatic point kept the disk from before the revert")
        try await sb.revert(to: rp2.id, takeBeforeRevert: false)
        XCTAssertEqual(try rootContent(), "v2", "any point, in any order")
        XCTAssertEqual(sb.restorePoints().map(\.name), ["one", "two", "before revert to one"])
    }

    /// A restore point taken from a running VM marks the disk it is reverted to for e2fsck.
    func test_runningPointsMarkTheNextBootForFsck() async throws {
        let sb = try Sandbox(spec: spec)
        let rp = try await sb.takeRestorePoint(name: "x")
        var meta = rp
        meta.takenWhile = .running
        try ImageBaker.encoder.encode(meta).write(to: layout.restorePointDirectory(rp.id).appendingPathComponent("meta.json"))
        try await sb.revert(to: rp.id, takeBeforeRevert: false)
        XCTAssertEqual(PersistedSandbox.read(from: layout.persistedState)?.fsckOnNextBoot, true)
    }

    func test_deleteInAnyOrderAndChains() async throws {
        let sb = try Sandbox(spec: spec)
        let a = try await sb.takeRestorePoint(name: "a")
        try await sb.revert(to: a.id, takeBeforeRevert: false)       // the disk now descends from a
        let b = try await sb.takeRestorePoint(name: "b")
        XCTAssertEqual(b.parent, a.id)
        try await sb.revert(to: b.id, takeBeforeRevert: false)
        let c = try await sb.takeRestorePoint(name: "c")
        XCTAssertEqual(layout.restorePointChain(from: c.id), [c.id, b.id, a.id])
        try sb.deleteRestorePoint(b.id)                             // the middle one
        XCTAssertEqual(sb.restorePoints().map(\.id), [a.id, c.id])
        XCTAssertEqual(layout.restorePointChain(from: c.id), [c.id, b.id], "a deleted link ends the walk")
        try await sb.revert(to: a.id, takeBeforeRevert: false)
        XCTAssertEqual(try rootContent(), "v1", "the others are intact")
        XCTAssertThrowsError(try sb.deleteRestorePoint(b.id))
        do { try await sb.revert(to: "rp-nope"); XCTFail() } catch let e as SandboxError { XCTAssertEqual(e, .restorePointNotFound("rp-nope")) }
    }

    func test_forkMakesAnIndependentSandbox() async throws {
        let sb = try Sandbox(spec: spec)
        try Data("state".utf8).write(to: layout.stateDisk)
        let rp = try await sb.takeRestorePoint(name: "base")
        XCTAssertTrue(rp.hasStateDisk)
        let forkSpec = try sb.fork(rp.id, as: "lab-fork")
        let fl = StoreLayout(spec: forkSpec)
        XCTAssertEqual(String(decoding: try Data(contentsOf: fl.rootfs), as: UTF8.self), "v1")
        XCTAssertEqual(String(decoding: try Data(contentsOf: fl.stateDisk), as: UTF8.self), "state")
        XCTAssertEqual(PersistedSandbox.read(from: fl.persistedState)?.restorePoint, rp.id)
        XCTAssertNotNil(Sandbox.keptRootDisk(fl), "its first Start cold-boots the forked disk")
        try Data("changed".utf8).write(to: fl.rootfs)
        XCTAssertEqual(try rootContent(), "v1", "clones: the original is untouched")
        XCTAssertThrowsError(try sb.fork(rp.id, as: "lab-fork"), "a name in use is refused")
    }

    func test_saveAsCustomImageRecordsProvenance() async throws {
        let sb = try Sandbox(spec: spec)
        let rp = try await sb.takeRestorePoint(name: "good", note: "works")
        let img = try sb.saveAsImage(rp.id, name: "my-image", note: "for later")
        XCTAssertEqual(img.origin, "custom")
        XCTAssertEqual(img.fromSandbox, "lab")
        XCTAssertEqual(img.baseImage, "alpine-3.20-abc")
        XCTAssertEqual(img.restorePointChain, [rp.id])
        XCTAssertFalse(img.needsFsck)
        let root = layout.customImageDirectory(img.key).appendingPathComponent("root.ext4")
        XCTAssertEqual(String(decoding: try Data(contentsOf: root), as: UTF8.self), "v1")
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: root.path), "a custom image is read-only")
        XCTAssertEqual(layout.customImages().map(\.key), [img.key])
        let disk = try sb.saveAsImage(nil, name: "my-image", note: "the stopped disk")
        XCTAssertTrue(disk.key.hasPrefix("my-image/disk-"))
        XCTAssertEqual(layout.customImages().count, 2)
        XCTAssertThrowsError(try sb.saveAsImage(rp.id, name: "Bad Name"))
        try Sandbox.deleteCustomImage(img.key, storeRoot: dir)
        XCTAssertEqual(layout.customImages().map(\.key), [disk.key])
    }

    func test_restorePointIDsSortByTime() {
        let a = RestorePoint.newID(at: Date(timeIntervalSince1970: 1_000_000))
        let b = RestorePoint.newID(at: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertLessThan(a, b)
        XCTAssertTrue(a.hasPrefix("rp-19700112-"))
    }
}
