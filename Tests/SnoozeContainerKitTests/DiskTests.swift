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
    }
}
