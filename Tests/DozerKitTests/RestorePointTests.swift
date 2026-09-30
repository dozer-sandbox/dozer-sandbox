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

    /// 594 W25: a name is stored exactly as given, up to 64 characters — never cut; a longer one is
    /// refused with the limit; a point is found by its id, its name, or an unambiguous prefix of either.
    func test_namesAreNeverCutAndPointsAreFoundByNameIdOrPrefix() async throws {
        let sb = try Sandbox(spec: spec)
        let long = "before-experiment-with-a-long-name"
        let a = try await sb.takeRestorePoint(name: long)
        XCTAssertEqual(sb.restorePoints().first?.name, long, "stored as typed")
        let max = String(repeating: "x", count: RestorePoint.maximumNameLength)
        let b = try await sb.takeRestorePoint(name: max)
        XCTAssertEqual(b.name.count, 64)
        do { _ = try await sb.takeRestorePoint(name: max + "y"); XCTFail("65 characters") } catch {
            XCTAssertTrue("\(error)".contains("at most 64 characters (this one has 65)"), "\(error)")
        }
        XCTAssertNotNil(RestorePoint.nameProblem(""))
        XCTAssertNotNil(RestorePoint.nameProblem("a\u{1B}[31m"))
        XCTAssertNil(RestorePoint.nameProblem("before experiment (1)"))
        let c = try await sb.takeRestorePoint(name: "before-deploy")
        let all = sb.restorePoints()
        // (Compared by id: a point read back from meta.json has its date rounded by the encoding.)
        XCTAssertEqual(try RestorePoint.resolve(long, in: all).id, a.id, "the exact name")
        XCTAssertEqual(try RestorePoint.resolve(c.id, in: all).id, c.id, "the id")
        XCTAssertEqual(try RestorePoint.resolve("before-exp", in: all).id, a.id, "a unique prefix of a name")
        XCTAssertEqual(try RestorePoint.resolve(String(c.id.dropLast(2)), in: all).id, c.id, "a unique prefix of an id")
        XCTAssertThrowsError(try RestorePoint.resolve("before-", in: all)) { e in
            guard case .ambiguous(let hits)? = e as? RestorePoint.LookupError else { return XCTFail("\(e)") }
            XCTAssertEqual(hits.map(\.id), [a.id, c.id])
        }
        XCTAssertThrowsError(try RestorePoint.resolve("nothing", in: all)) { XCTAssertEqual($0 as? RestorePoint.LookupError, .notFound) }
        // A point stored with a cut name (before 594 W25) is found by that stored name.
        var old = a
        old.id = "rp-old"
        old.name = "before-experimen"
        XCTAssertEqual(try RestorePoint.resolve("before-experimen", in: all + [old]).id, "rp-old", "an exact name wins over a prefix")
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

    /// 593: a template is the ROOT disk only — never the state disk (the agent's logins and history).
    func test_aTemplateNeverHoldsTheStateDisk() async throws {
        let sb = try Sandbox(spec: spec)
        try Data("logins".utf8).write(to: layout.stateDisk)
        let rp = try await sb.takeRestorePoint(name: "with-state")
        XCTAssertTrue(rp.hasStateDisk)
        for img in [try sb.saveAsImage(rp.id, name: "tpl-point"), try sb.saveAsImage(nil, name: "tpl-disk")] {
            let files = try FileManager.default.contentsOfDirectory(atPath: layout.customImageDirectory(img.key).path).sorted()
            XCTAssertEqual(files, ["image.json", "root.ext4"], "\(img.key): no state disk in a template")
        }
    }

    /// 593: duplicate — the root cloned, the spec the caller's, the state disk fresh unless copied.
    func test_duplicateClonesTheRootAndStartsTheStateFresh() async throws {
        let sb = try Sandbox(spec: spec)
        try Data("logins".utf8).write(to: layout.stateDisk)
        var s = spec!
        s.name = "lab-dup"
        s.cpus = 4
        s.memoryMiB = 3072
        s.shares = [Share(hostPath: dir.path, guestPath: "/workspace")]
        try sb.duplicate(from: nil, as: s, copyState: false)
        let nl = StoreLayout(spec: s)
        XCTAssertEqual(String(decoding: try Data(contentsOf: nl.rootfs), as: UTF8.self), "v1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: nl.stateDisk.path), "a fresh state disk: made empty on the first boot")
        let p = try XCTUnwrap(PersistedSandbox.read(from: nl.persistedState))
        XCTAssertEqual(p.phase, .off)
        XCTAssertEqual(p.rootImage, "alpine-3.20-abc", "the lineage follows the source's image")
        XCTAssertNotNil(Sandbox.keptRootDisk(nl))
        XCTAssertThrowsError(try sb.duplicate(from: nil, as: s, copyState: false), "a name in use is refused")

        // With the state copied, from a restore point.
        let rp = try await sb.takeRestorePoint(name: "p")
        s.name = "lab-dup2"
        try sb.duplicate(from: rp.id, as: s, copyState: true)
        let nl2 = StoreLayout(spec: s)
        XCTAssertEqual(String(decoding: try Data(contentsOf: nl2.stateDisk), as: UTF8.self), "logins")
        XCTAssertEqual(PersistedSandbox.read(from: nl2.persistedState)?.restorePoint, rp.id)

        // The current disk of a sandbox that is not stopped on disk is refused (the host goes through a point).
        var live = try XCTUnwrap(PersistedSandbox.read(from: layout.persistedState))
        live.phase = .running
        try live.write(to: layout.persistedState)
        s.name = "lab-dup3"
        XCTAssertThrowsError(try sb.duplicate(from: nil, as: s, copyState: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: StoreLayout(spec: s).sandboxDirectory.path), "nothing left behind")
        s.name = "lab"
        XCTAssertThrowsError(try sb.duplicate(from: rp.id, as: s, copyState: false), "not onto itself")
    }

    func test_restorePointIDsSortByTime() {
        let a = RestorePoint.newID(at: Date(timeIntervalSince1970: 1_000_000))
        let b = RestorePoint.newID(at: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertLessThan(a, b)
        XCTAssertTrue(a.hasPrefix("rp-19700112-"))
    }
}
