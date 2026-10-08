import ContainerizationArchive
import ContainerizationEXT4
import Darwin
import Foundation
import SystemPackage
import XCTest
@testable import DozerKit

/// 587: real ext4 disks made on the host (Containerization's formatter — no VM), in a scratch
/// directory on the test host's APFS volume.
final class DiskTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("doz-disktests-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// An ext4 disk of `mib` MiB with `files` (path → bytes) on it.
    static func makeDisk(_ url: URL, mib: UInt64 = 64, journalMiB: Int? = nil, files: [String: Data] = [:]) throws {
        let f = try EXT4.Formatter(FilePath(url.path), minDiskSize: mib * 1_048_576, journal: journalMiB.map { EXT4.JournalConfig(size: UInt64($0) * 1_048_576, defaultMode: .ordered) })
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            let s = InputStream(data: data)
            s.open()
            defer { s.close() }
            try f.create(path: FilePath(path), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: s)
        }
        try f.close()
    }

    static func random(_ n: Int) -> Data {
        var d = Data(count: n)
        d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, n) }
        return d
    }

    func test_inspectorReadsJournalAndState() throws {
        let plain = dir.appendingPathComponent("plain.ext4"), journaled = dir.appendingPathComponent("j.ext4")
        try Self.makeDisk(plain)
        try Self.makeDisk(journaled, journalMiB: 4)
        let p = try EXT4Inspector(plain), j = try EXT4Inspector(journaled)
        XCTAssertFalse(p.hasJournal)
        XCTAssertTrue(j.hasJournal)
        XCTAssertTrue(p.isClean && j.isClean, "a freshly formatted disk is clean")
        XCTAssertEqual(p.blockSize, 4096)
        XCTAssertFalse(EXT4Inspector.hasJournal(dir.appendingPathComponent("missing")))
        let notExt4 = dir.appendingPathComponent("zeros")
        try Data(count: 8192).write(to: notExt4)
        XCTAssertThrowsError(try EXT4Inspector(notExt4))
    }

    /// The bitmap walk agrees with the superblock's own free count, and no free range overlaps a
    /// block holding a file's data.
    func test_freeRangesMatchTheSuperblockAndSpareTheData() throws {
        let disk = dir.appendingPathComponent("d.ext4")
        let payload = Self.random(3 << 20)
        try Self.makeDisk(disk, mib: 256, journalMiB: 8, files: ["/a.bin": payload, "/b.txt": Data("hello".utf8)])
        let i = try EXT4Inspector(disk)
        let free = try i.freeRanges()
        let freeBytes = free.reduce(0) { $0 + $1.1 }
        XCTAssertEqual(freeBytes, i.freeBlocksCount * i.blockSize, "bitmaps and the superblock agree")
        XCTAssertGreaterThan(freeBytes, 200 << 20)
        XCTAssertEqual(i.usedBytes + freeBytes, i.capacityBytes)
        for k in 1..<free.count { XCTAssertLessThan(free[k - 1].0 + free[k - 1].1, free[k].0, "sorted, merged, disjoint") }
        // Punch every free range out of a copy: the in-use blocks read exactly as before.
        let copy = dir.appendingPathComponent("copy.ext4")
        XCTAssertEqual(copyfile(disk.path, copy.path, nil, copyfile_flags_t(COPYFILE_DATA)), 0)
        try DiskAccounting.punchHoles(copy, free)
        XCTAssertTrue(try DiskAccounting.identical(disk, copy, over: DiskAccounting.complement(free, size: i.capacityBytes)))
        XCTAssertEqual(try DiskAccounting.garbage(of: copy), 0)
    }

    /// Clones share, writes un-share, and the sweep agrees with APFS's private size — the 586 Q5
    /// method, on the test host's volume.
    func test_accountingMatchesAPFS() throws {
        let a = dir.appendingPathComponent("a.bin"), b = dir.appendingPathComponent("b.bin")
        try Self.random(8 << 20).write(to: a)
        XCTAssertEqual(clonefile(a.path, b.path, 0), 0)
        var v = try DiskAccounting.share([a, b])
        XCTAssertEqual(v.unique, [0, 0])
        XCTAssertEqual(v.shared(0, 1), 8 << 20)
        let h = try FileHandle(forWritingTo: b)
        try h.seek(toOffset: 1 << 20)
        try h.write(contentsOf: Self.random(2 << 20))
        try h.synchronize()
        try h.close()
        v = try DiskAccounting.share([a, b])
        XCTAssertEqual(v.unique[1], 2 << 20)
        XCTAssertEqual(v.unique[0], 2 << 20, "the source's rewritten-in-the-clone blocks are now its own")
        XCTAssertEqual(v.shared(0, 1), 6 << 20)
        XCTAssertEqual(v.union, 10 << 20)
        for (i, u) in [a, b].enumerated() {
            if let p = DiskAccounting.privateSize(u) { XCTAssertEqual(p, v.unique[i], "PRIVATESIZE agrees (\(u.lastPathComponent))") }
        }
    }

    /// Blocks a file system freed but whose data is still in the file are garbage; the content
    /// delta against a parent finds rewritten-but-identical blocks.
    func test_garbageAndContentDelta() throws {
        let parent = dir.appendingPathComponent("parent.ext4")
        try Self.makeDisk(parent, mib: 64, files: ["/keep.bin": Self.random(4 << 20)])
        let child = dir.appendingPathComponent("child.ext4")
        XCTAssertEqual(clonefile(parent.path, child.path, 0), 0)
        let i = try EXT4Inspector(child)
        let free = try i.freeRanges()
        // Garbage: write data into 2 MiB of free blocks (as a deleted file leaves it).
        let g = free.first { $0.1 >= 2 << 20 }!
        let fh = try FileHandle(forWritingTo: child)
        try fh.seek(toOffset: UInt64(g.0))
        try fh.write(contentsOf: Self.random(2 << 20))
        // Lost identical sharing: rewrite 1 MiB of in-use blocks with the same bytes.
        let used = DiskAccounting.complement(free, size: i.capacityBytes)
        let u = used.first { $0.1 >= 1 << 20 && $0.0 > 0 }!
        let pf = try FileHandle(forReadingFrom: parent)
        try pf.seek(toOffset: UInt64(u.0))
        let same = try pf.read(upToCount: 1 << 20)!
        try fh.seek(toOffset: UInt64(u.0))
        try fh.write(contentsOf: same)
        try fh.synchronize()
        try fh.close()
        // The formatter itself leaves a little data in free blocks (the parent's own garbage).
        let expected = DiskAccounting.total(DiskAccounting.merge(try DiskAccounting.garbageRanges(of: parent) + [(g.0, 2 << 20)]))
        // (APFS may allocate a few neighbouring blocks of the write's allocation unit too.)
        let got = try DiskAccounting.garbage(of: child)
        XCTAssertGreaterThanOrEqual(got, expected)
        XCTAssertLessThanOrEqual(got, expected + (64 << 10))
        XCTAssertGreaterThanOrEqual(expected, 2 << 20)
        let delta = DiskAccounting.blockDelta(child: try DiskAccounting.extents(of: child), parent: try DiskAccounting.extents(of: parent))
        let inUse = DiskAccounting.subtract(delta.differ, free)
        let c = try DiskAccounting.contentRuns(child: child, parent: parent, ranges: inUse)
        // APFS un-shares a whole allocation unit around a write, so a few KiB beyond the MiB count too.
        XCTAssertGreaterThanOrEqual(c.identical, 1 << 20, "1 MiB rewritten with identical bytes")
        XCTAssertLessThanOrEqual(c.identical, (1 << 20) + (64 << 10))
        XCTAssertTrue(c.runs.isEmpty)
    }

    /// 586's thresholds, at, just below and just above each edge (strict "greater than").
    func test_adviceThresholds() {
        let MiB: Int64 = 1 << 20
        func act(_ alloc: Int64, _ g: Int64, _ lost: Int64?, _ img: Int64?) -> [MaintenanceAction] {
            MaintenanceAdvice.actions(allocated: alloc, garbage: g, lostSharing: lost, imageBytes: img).actions
        }
        // garbage > 25 % of the allocation
        XCTAssertEqual(act(400 * MiB, 100 * MiB, nil, nil), [], "at 25 %")
        XCTAssertEqual(act(400 * MiB, 100 * MiB - 1, nil, nil), [], "below 25 %")
        XCTAssertEqual(act(400 * MiB, 100 * MiB + 1, nil, nil), [.reclaim], "above 25 %")
        // garbage > 512 MiB (on a disk where that is < 25 %)
        XCTAssertEqual(act(4096 * MiB, 512 * MiB, nil, nil), [], "at 512 MiB")
        XCTAssertEqual(act(4096 * MiB, 512 * MiB - 1, nil, nil), [], "below 512 MiB")
        XCTAssertEqual(act(4096 * MiB, 512 * MiB + 1, nil, nil), [.reclaim], "above 512 MiB")
        // lost identical sharing > 64 MiB (on an image where that is < 10 %)
        XCTAssertEqual(act(1, 0, 64 * MiB, 1000 * MiB), [], "at 64 MiB")
        XCTAssertEqual(act(1, 0, 64 * MiB - 1, 1000 * MiB), [], "below 64 MiB")
        XCTAssertEqual(act(1, 0, 64 * MiB + 1, 1000 * MiB), [.rederive], "above 64 MiB")
        // lost identical sharing > 10 % of the image
        XCTAssertEqual(act(1, 0, 50 * MiB, 500 * MiB), [], "at 10 %")
        XCTAssertEqual(act(1, 0, 50 * MiB - 1, 500 * MiB), [], "below 10 %")
        XCTAssertEqual(act(1, 0, 50 * MiB + 1, 500 * MiB), [.rederive], "above 10 %")
        // both, and neither without an image
        XCTAssertEqual(act(400 * MiB, 200 * MiB, 100 * MiB, 500 * MiB), [.reclaim, .rederive])
        XCTAssertEqual(act(400 * MiB, 0, nil, nil), [])
    }

    /// The same rules through `Sandbox.maintenanceAdvice()`, on synthetic disks: a prepared disk
    /// with a file on it, and a sandbox root cloned from it, then dirtied on the host.
    func test_adviceOnSyntheticDisks() async throws {
        let store = dir.appendingPathComponent("store")
        let spec = SandboxSpec(name: "syn", storeRoot: store)
        let layout = StoreLayout(spec: spec)
        try FileManager.default.createDirectory(at: layout.goldenDirectory, withIntermediateDirectories: true)
        let goldenKey = "synthetic-000000000000"
        let golden = layout.goldenDirectory.appendingPathComponent("\(goldenKey).ext4")
        try Self.makeDisk(golden, mib: 256, files: ["/payload.bin": Self.random(64 << 20)])
        let imageBytes = ImageBaker.sizes(golden).allocated

        func sandbox(garbageMiB: Int, identicalMiB: Int) async throws -> MaintenanceAdvice {
            try? FileManager.default.removeItem(at: layout.sandboxDirectory)
            try FileManager.default.createDirectory(at: layout.sandboxDirectory, withIntermediateDirectories: true)
            XCTAssertEqual(clonefile(golden.path, layout.rootfs.path, 0), 0)
            let i = try EXT4Inspector(layout.rootfs)
            let free = try i.freeRanges()
            // In-use blocks that hold data in the image (the payload), not holes.
            let used = DiskAccounting.intersect(DiskAccounting.complement(free, size: i.capacityBytes),
                                                DiskAccounting.merge(try DiskAccounting.extents(of: golden).map { ($0.logical, $0.length) }))
            let fh = try FileHandle(forWritingTo: layout.rootfs)
            if garbageMiB > 0, let g = free.first(where: { $0.1 >= Int64(garbageMiB) << 20 }) {
                try fh.seek(toOffset: UInt64(g.0))
                try fh.write(contentsOf: Self.random(garbageMiB << 20))
            }
            if identicalMiB > 0 {
                let r = try XCTUnwrap(used.first(where: { $0.1 >= Int64(identicalMiB + 1) << 20 }),
                                      "in-use data ranges: \(used.map { "\($0.0 >> 20)+\($0.1 >> 10)K" })")
                let u = (r.0 + (1 << 20), Int64(identicalMiB) << 20)
                let pf = try FileHandle(forReadingFrom: golden)
                try pf.seek(toOffset: UInt64(u.0))
                let same = try pf.read(upToCount: identicalMiB << 20)!
                try fh.seek(toOffset: UInt64(u.0))
                try fh.write(contentsOf: same)
            }
            try fh.synchronize()
            try fh.close()
            var p = PersistedSandbox(spec: spec, phase: .off, machineIdentifier: Data([1]), macAddress: nil, subnet: nil, shareTags: [:])
            p.rootImage = goldenKey
            try p.write(to: layout.persistedState)
            return try await Sandbox(spec: spec).maintenanceAdvice()
        }
        let clean = try await sandbox(garbageMiB: 0, identicalMiB: 0)
        XCTAssertEqual(clean.actions, [], clean.reasons.joined(separator: "; "))
        XCTAssertEqual(clean.lostSharingBytes, 0)
        let below = try await sandbox(garbageMiB: 8, identicalMiB: 4)       // 8 of ~72 MiB; 4 of ~64 MiB
        XCTAssertEqual(below.actions, [], below.reasons.joined(separator: "; "))
        let above = try await sandbox(garbageMiB: 40, identicalMiB: 16)     // 40 of ~104 MiB; 16 of ~64 MiB
        XCTAssertEqual(above.actions, [.reclaim, .rederive], above.reasons.joined(separator: "; "))
        XCTAssertGreaterThanOrEqual(above.lostSharingBytes ?? 0, 16 << 20)
        XCTAssertEqual(above.imageBytes, imageBytes)
        // reclaim() (host only): the garbage goes, every in-use block reads the same.
        let before = layout.sandboxDirectory.appendingPathComponent("before.ext4")
        XCTAssertEqual(copyfile(layout.rootfs.path, before.path, nil, copyfile_flags_t(COPYFILE_DATA)), 0)
        let r = try await Sandbox(spec: spec).reclaim()
        XCTAssertEqual(r.first?.garbageAfter, 0)
        XCTAssertGreaterThanOrEqual(r.first?.garbageBefore ?? 0, 40 << 20)
        XCTAssertLessThanOrEqual(r.first!.allocatedAfter, r.first!.allocatedBefore - (40 << 20))
        let i = try EXT4Inspector(layout.rootfs)
        XCTAssertTrue(try DiskAccounting.identical(before, layout.rootfs, over: DiskAccounting.complement(try i.freeRanges(), size: i.capacityBytes)))
        let after = try await Sandbox(spec: spec).maintenanceAdvice()
        XCTAssertEqual(after.actions, [.rederive], "reclaimed: only the lost sharing is left")
        // A disk that was not cleanly unmounted is refused.
        var p = PersistedSandbox.read(from: layout.persistedState)!
        p.fsckOnNextBoot = true
        try p.write(to: layout.persistedState)
        do { _ = try await Sandbox(spec: spec).maintenanceAdvice(); XCTFail("an unclean disk must be refused") } catch {}
    }

    func test_rangeAlgebra() {
        let a: [(Int64, Int64)] = [(0, 10), (20, 10)], b: [(Int64, Int64)] = [(5, 20)]
        XCTAssertEqual(DiskAccounting.intersect(a, b).map { [$0.0, $0.1] }, [[5, 5], [20, 5]])
        XCTAssertEqual(DiskAccounting.subtract(a, b).map { [$0.0, $0.1] }, [[0, 5], [25, 5]])
        XCTAssertEqual(DiskAccounting.complement(a, size: 40).map { [$0.0, $0.1] }, [[10, 10], [30, 10]])
        XCTAssertEqual(DiskAccounting.merge([(10, 5), (0, 10), (12, 1)]).map { [$0.0, $0.1] }, [[0, 15]])
    }
}
