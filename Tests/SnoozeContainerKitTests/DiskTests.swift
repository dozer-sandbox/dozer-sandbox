import ContainerizationArchive
import ContainerizationEXT4
import Darwin
import Foundation
import SystemPackage
import XCTest
@testable import SnoozeContainerKit

/// 587: real ext4 disks made on the host (Containerization's formatter — no VM), in a scratch
/// directory on the test host's APFS volume.
final class DiskTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snooze-disktests-\(UUID().uuidString.prefix(8))")
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

    static func random(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }

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

    func test_rangeAlgebra() {
        let a: [(Int64, Int64)] = [(0, 10), (20, 10)], b: [(Int64, Int64)] = [(5, 20)]
        XCTAssertEqual(DiskAccounting.intersect(a, b).map { [$0.0, $0.1] }, [[5, 5], [20, 5]])
        XCTAssertEqual(DiskAccounting.subtract(a, b).map { [$0.0, $0.1] }, [[0, 5], [25, 5]])
        XCTAssertEqual(DiskAccounting.complement(a, size: 40).map { [$0.0, $0.1] }, [[10, 10], [30, 10]])
        XCTAssertEqual(DiskAccounting.merge([(10, 5), (0, 10), (12, 1)]).map { [$0.0, $0.1] }, [[0, 15]])
    }
}
