import Darwin
import Foundation

/// 587: what the library needs to know about an ext4 disk IMAGE FILE on the host, read straight
/// from its superblock and block bitmaps — no VM, no mount, ~1 ms. Read-only.
///
/// - `hasJournal` decides e2fsck vs journal replay after an unclean stop;
/// - `isClean` (no journal recovery pending, and the "valid" state bit) gates maintenance;
/// - `freeRanges()` is ext4's free-block list (what `dumpe2fs` prints as "Free blocks"), as byte
///   ranges of the file — what `reclaim()` punches out and `rederive()` skips.
///
/// Only a disk nothing has mounted is read reliably: a running (or hibernated) guest keeps newer
/// bitmaps in its memory.
public struct EXT4Inspector: Sendable {
    public let url: URL
    public let blockSize: Int64
    public let blocksCount: Int64
    public let freeBlocksCount: Int64
    public let firstDataBlock: Int64
    public let blocksPerGroup: Int64
    public let featureCompat: UInt32
    public let featureIncompat: UInt32
    public let featureRoCompat: UInt32
    public let state: UInt16
    let descriptorSize: Int

    static let superblockOffset: Int64 = 1024
    static let magic: UInt16 = 0xEF53
    static let compatHasJournal: UInt32 = 0x4
    static let incompatRecover: UInt32 = 0x4
    static let incompat64Bit: UInt32 = 0x80
    static let roCompatGdtCsum: UInt32 = 0x10
    static let roCompatBigalloc: UInt32 = 0x200
    static let roCompatMetadataCsum: UInt32 = 0x400
    static let groupFlagBlockUninit: UInt16 = 0x2

    public enum InspectError: Error, LocalizedError, Equatable {
        case unreadable(String)
        case notExt4(String)
        case unsupported(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable(let s): "cannot read \(s)"
            case .notExt4(let s): "\(s) is not an ext4 file system"
            case .unsupported(let s): "unsupported ext4 layout: \(s)"
            }
        }
    }

    public init(_ url: URL) throws {
        self.url = url
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw InspectError.unreadable(url.path) }
        defer { close(fd) }
        var sb = [UInt8](repeating: 0, count: 1024)
        guard sb.withUnsafeMutableBytes({ pread(fd, $0.baseAddress!, 1024, off_t(Self.superblockOffset)) }) == 1024 else {
            throw InspectError.unreadable(url.path)
        }
        func u16(_ o: Int) -> UInt16 { UInt16(sb[o]) | UInt16(sb[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
        guard u16(0x38) == Self.magic else { throw InspectError.notExt4(url.path) }
        featureCompat = u32(0x5C)
        featureIncompat = u32(0x60)
        featureRoCompat = u32(0x64)
        let is64 = featureIncompat & Self.incompat64Bit != 0
        blockSize = Int64(1024) << Int64(u32(0x18))
        blocksCount = Int64(u32(0x04)) | (is64 ? Int64(u32(0x150)) << 32 : 0)
        freeBlocksCount = Int64(u32(0x0C)) | (is64 ? Int64(u32(0x158)) << 32 : 0)
        firstDataBlock = Int64(u32(0x14))
        blocksPerGroup = Int64(u32(0x20))
        state = u16(0x3A)
        descriptorSize = is64 ? max(32, Int(u16(0xFE))) : 32
        guard blocksPerGroup > 0, blockSize >= 1024, blockSize <= 65536 else { throw InspectError.notExt4(url.path) }
    }

    /// `has_journal`.
    public var hasJournal: Bool { featureCompat & Self.compatHasJournal != 0 }
    /// A journal recovery is pending (`needs_recovery`): the disk was not cleanly unmounted.
    public var needsRecovery: Bool { featureIncompat & Self.incompatRecover != 0 }
    /// Cleanly unmounted: the "valid" state bit set and no journal recovery pending. (A journal-less
    /// ext4 clears the bit while mounted; a journaled one sets `needs_recovery` instead.)
    public var isClean: Bool { state & 1 != 0 && !needsRecovery }
    /// Blocks in use, as the file system counts them (all of its metadata included), bytes — from
    /// the superblock's free count, which is exact on a cleanly unmounted disk.
    public var usedBytes: Int64 { (blocksCount - freeBlocksCount) * blockSize }
    public var capacityBytes: Int64 { blocksCount * blockSize }

    /// True when `url` is an ext4 disk with a journal (false for anything unreadable).
    public static func hasJournal(_ url: URL) -> Bool { (try? EXT4Inspector(url))?.hasJournal ?? false }

    /// ext4's free blocks, as sorted, merged byte ranges (offset, length) of the image file. Groups
    /// whose bitmap was never initialised (`BLOCK_UNINIT`) are left out: nothing was ever allocated
    /// in them, so there is nothing to punch or skip — leaving them out is the safe side.
    public func freeRanges() throws -> [(Int64, Int64)] {
        guard featureRoCompat & Self.roCompatBigalloc == 0 else { throw InspectError.unsupported("bigalloc") }
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw InspectError.unreadable(url.path) }
        defer { close(fd) }
        let groups = Int((blocksCount - firstDataBlock + blocksPerGroup - 1) / blocksPerGroup)
        let gdtOffset = (firstDataBlock + 1) * blockSize
        let gdtBytes = groups * descriptorSize
        var gdt = [UInt8](repeating: 0, count: gdtBytes)
        guard gdt.withUnsafeMutableBytes({ pread(fd, $0.baseAddress!, gdtBytes, off_t(gdtOffset)) }) == gdtBytes else {
            throw InspectError.unreadable("\(url.path) group descriptors")
        }
        let checksummed = featureRoCompat & (Self.roCompatGdtCsum | Self.roCompatMetadataCsum) != 0
        var out: [(Int64, Int64)] = []
        func add(_ block: Int64, _ count: Int64) {
            let off = block * blockSize, len = count * blockSize
            if let last = out.last, last.0 + last.1 == off { out[out.count - 1].1 += len } else { out.append((off, len)) }
        }
        var bitmap = [UInt8](repeating: 0, count: Int(blockSize))
        for g in 0..<groups {
            let d = g * descriptorSize
            func u16(_ o: Int) -> UInt16 { UInt16(gdt[d + o]) | UInt16(gdt[d + o + 1]) << 8 }
            func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
            if checksummed, u16(0x12) & Self.groupFlagBlockUninit != 0 { continue }
            let bitmapBlock = Int64(u32(0x00)) | (descriptorSize >= 64 ? Int64(u32(0x20)) << 32 : 0)
            guard bitmapBlock > 0, bitmapBlock < blocksCount else { throw InspectError.unsupported("group \(g) bitmap at block \(bitmapBlock)") }
            guard bitmap.withUnsafeMutableBytes({ pread(fd, $0.baseAddress!, Int(blockSize), off_t(bitmapBlock * blockSize)) }) == Int(blockSize) else {
                throw InspectError.unreadable("\(url.path) block bitmap of group \(g)")
            }
            let first = firstDataBlock + Int64(g) * blocksPerGroup
            let n = min(blocksPerGroup, blocksCount - first)
            var i: Int64 = 0
            while i < n {
                let byte = bitmap[Int(i >> 3)]
                if byte == 0xFF, i & 7 == 0 { i += 8; continue }
                if byte == 0, i & 7 == 0, i + 8 <= n {
                    // a run of free blocks: extend over whole zero bytes
                    var j = i
                    while j + 8 <= n, bitmap[Int(j >> 3)] == 0 { j += 8 }
                    add(first + i, j - i)
                    i = j
                    continue
                }
                if byte & (1 << UInt8(i & 7)) == 0 { add(first + i, 1) }
                i += 1
            }
        }
        return out
    }
}
