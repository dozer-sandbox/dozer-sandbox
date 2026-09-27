import Containerization
import Darwin
import Foundation

/// 587: disk maintenance for a STOPPED sandbox — 586's two remedies and its thresholds.
///
/// - `reclaim()` punches out of the host files the blocks ext4 says are free (garbage: what the
///   guest deleted and the host still stores). 586 Q4: ~0.1 s; the disk boots identically.
/// - `rederive()` rebuilds the root disk as a fresh clone of its image plus only the blocks whose
///   CONTENT differs, skipping ext4-free blocks (586 Q2c b″): sharing with the image goes back up
///   (rewritten-but-identical blocks are shared again) and the garbage goes. ~1.3 s per GiB.
/// - `maintenanceAdvice()` says which of them is worth running (`MaintenanceAdvice.thresholds`).
///
/// Fragmentation never triggers anything (586 Q2b/Q2c: 1000 extents per GiB cost no boot, wake or
/// read time on the SSD). A running, paused or sleeping sandbox refuses with `invalidPhase`; a disk
/// that was not cleanly unmounted refuses too (start it and shut it down first).

/// One of the two remedies `maintenanceAdvice()` can recommend for a stopped sandbox's disks.
public enum MaintenanceAction: String, Sendable, Codable, Equatable {
    case reclaim
    case rederive
}

/// What `maintenanceAdvice()` found for one sandbox's disks, and why (`reasons`).
public struct MaintenanceAdvice: Sendable, Equatable {
    /// 586's thresholds (constants): garbage > 25 % of the allocation or > 512 MiB → reclaim; lost
    /// identical sharing > 64 MiB or > 10 % of the image → re-derive. Each is a strict "greater than".
    public enum thresholds {
        public static let garbageFraction = 0.25
        public static let garbageBytes: Int64 = 512 << 20
        public static let lostSharingBytes: Int64 = 64 << 20
        public static let lostSharingFraction = 0.10
    }

    /// What to run, in order (empty: nothing is worth doing).
    public var actions: [MaintenanceAction]
    /// Root + state disks: what the host files hold, and the part of it ext4 considers free.
    public var allocatedBytes: Int64
    public var garbageBytes: Int64
    /// Root-disk blocks rewritten with the image's own bytes — sharing lost for nothing (nil: the
    /// image is not in the store, so there is nothing to compare with).
    public var lostSharingBytes: Int64?
    /// The image's allocation (the base of the 10 % rule).
    public var imageBytes: Int64?
    public var extentsPerGiB: Double
    /// One line per rule, fired or not.
    public var reasons: [String]
    public var milliseconds: Double

    /// The rules, as a pure function.
    public static func actions(allocated: Int64, garbage: Int64, lostSharing: Int64?, imageBytes: Int64?) -> (actions: [MaintenanceAction], reasons: [String]) {
        var a: [MaintenanceAction] = []
        var why: [String] = []
        let frac = allocated > 0 ? Double(garbage) / Double(allocated) : 0
        if frac > thresholds.garbageFraction || garbage > thresholds.garbageBytes {
            a.append(.reclaim)
            why.append(String(format: "reclaim: garbage %.1f MiB = %.1f %% of %.1f MiB (> 25 %% or > 512 MiB)", mib(garbage), frac * 100, mib(allocated)))
        } else {
            why.append(String(format: "no reclaim: garbage %.1f MiB = %.1f %% (≤ 25 %% and ≤ 512 MiB)", mib(garbage), frac * 100))
        }
        if let lost = lostSharing {
            let lf = (imageBytes ?? 0) > 0 ? Double(lost) / Double(imageBytes!) : 0
            if lost > thresholds.lostSharingBytes || lf > thresholds.lostSharingFraction {
                a.append(.rederive)
                why.append(String(format: "re-derive: %.1f MiB of the image rewritten with identical bytes = %.1f %% of it (> 64 MiB or > 10 %%)", mib(lost), lf * 100))
            } else {
                why.append(String(format: "no re-derive: %.1f MiB of lost identical sharing = %.1f %% (≤ 64 MiB and ≤ 10 %%)", mib(lost), lf * 100))
            }
        } else {
            why.append("no re-derive: the image this disk came from is not in the store")
        }
        return (a, why)
    }

    static func mib(_ b: Int64) -> Double { Double(b) / 1_048_576 }
}

/// What `reclaim()` did to one disk: its allocation and garbage before and after.
public struct ReclaimResult: Sendable, Equatable {
    public var disk: String
    public var allocatedBefore: Int64
    public var allocatedAfter: Int64
    public var garbageBefore: Int64
    public var garbageAfter: Int64
    public var punchedRanges: Int
    public var milliseconds: Double
}

/// What `rederive()` did: the root disk's allocation, sharing with its image, and garbage, before
/// and after.
public struct RederiveResult: Sendable, Equatable {
    public var allocatedBefore: Int64
    public var allocatedAfter: Int64
    public var sharedWithImageBefore: Int64
    public var sharedWithImageAfter: Int64
    public var garbageBefore: Int64
    public var garbageAfter: Int64
    /// Bytes written into the fresh clone (content that differs from the image) and zeroed.
    public var writtenBytes: Int64
    public var zeroedBytes: Int64
    /// Blocks the old disk had rewritten with the image's own bytes, shared again now.
    public var identicalBytes: Int64
    /// The `e2fsck -fn` of the new disk before it replaced the old one.
    public var fsckReport: String
    public var milliseconds: Double
}

/// One disk's `e2fsck -fn` result, from `checkDisks()`.
public struct DiskCheck: Sendable, Equatable {
    public var disk: String
    /// `e2fsck -fn` exited 0.
    public var clean: Bool
    public var exitCode: Int32
    public var report: String
}

/// Where a test makes `rederive()` fail part-way ("after-write", "before-swap").
@_spi(Testing) public enum MaintenanceFaults {
    nonisolated(unsafe) public static var failAt: String?
    static func check(_ point: String) throws {
        if failAt == point { throw SandboxError.commandFailed(command: "rederive (injected failure at \(point))", exitCode: -1, output: "") }
    }
}

extension Sandbox {
    /// What maintenance is worth running on this stopped sandbox's disks (read-only).
    public func maintenanceAdvice() async throws -> MaintenanceAdvice {
        await acquire(); defer { release() }
        try maintenanceGate("maintenance advice")
        let t0 = ContinuousClock.now
        var allocated: Int64 = 0, garbage: Int64 = 0
        for disk in disks {
            allocated += ImageBaker.sizes(disk).allocated
            garbage += try DiskAccounting.garbage(of: disk)
        }
        let childExt = try DiskAccounting.extents(of: layout.rootfs)
        var lost: Int64?, imageBytes: Int64?
        if let image = rootImageDisk {
            let free = try EXT4Inspector(layout.rootfs).freeRanges()
            let delta = DiskAccounting.blockDelta(child: childExt, parent: try DiskAccounting.extents(of: image))
            lost = try DiskAccounting.contentRuns(child: layout.rootfs, parent: image, ranges: DiskAccounting.subtract(delta.differ, free)).identical
            imageBytes = ImageBaker.sizes(image).allocated
        }
        let data = childExt.reduce(Int64(0)) { $0 + $1.length }
        let (a, why) = MaintenanceAdvice.actions(allocated: allocated, garbage: garbage, lostSharing: lost, imageBytes: imageBytes)
        let advice = MaintenanceAdvice(actions: a, allocatedBytes: allocated, garbageBytes: garbage, lostSharingBytes: lost, imageBytes: imageBytes,
                                       extentsPerGiB: data > 0 ? Double(childExt.count) / (Double(data) / 1_073_741_824) : 0,
                                       reasons: why, milliseconds: milliseconds(since: t0))
        broadcaster.yield(.step("maintenance advice: \(a.isEmpty ? "nothing to do" : a.map(\.rawValue).joined(separator: " + ")) — " + why.joined(separator: "; "),
                                milliseconds: advice.milliseconds))
        return advice
    }

    /// Punch ext4's free blocks out of the root and state disks' host files (586 Q4's host-side
    /// reclaim: the free list from the disk's own bitmaps, then `F_PUNCHHOLE`). Only blocks ext4
    /// does not use are touched, so the guest sees exactly the same file system.
    public func reclaim() async throws -> [ReclaimResult] {
        await acquire(); defer { release() }
        try maintenanceGate("reclaim")
        setBusy(true); defer { setBusy(false) }
        var out: [ReclaimResult] = []
        for disk in disks {
            let t0 = ContinuousClock.now
            let before = ImageBaker.sizes(disk).allocated
            let ranges = try DiskAccounting.garbageRanges(of: disk)
            let n = try DiskAccounting.punchHoles(disk, ranges)
            let r = ReclaimResult(disk: disk.lastPathComponent, allocatedBefore: before, allocatedAfter: ImageBaker.sizes(disk).allocated,
                                  garbageBefore: DiskAccounting.total(ranges), garbageAfter: try DiskAccounting.garbage(of: disk),
                                  punchedRanges: n, milliseconds: milliseconds(since: t0))
            broadcaster.yield(.step(String(format: "reclaimed %@: punched %d free range(s), %.1f → %.1f MiB allocated (garbage %.1f → %.1f MiB)",
                                           disk.lastPathComponent, n, MaintenanceAdvice.mib(r.allocatedBefore), MaintenanceAdvice.mib(r.allocatedAfter),
                                           MaintenanceAdvice.mib(r.garbageBefore), MaintenanceAdvice.mib(r.garbageAfter)),
                                    milliseconds: r.milliseconds))
            out.append(r)
        }
        return out
    }

    /// Rebuild the root disk as a clone of its image plus only the 4 KiB blocks whose content
    /// differs, skipping ext4-free blocks (586 Q2c b″). The new disk is built beside the old one,
    /// checked (every in-use block reads the same, when `verify`; then `e2fsck -fn` clean), and only
    /// then renamed over it — a failure anywhere leaves the original disk in place. The state disk
    /// and the restore points are untouched.
    public func rederive(verify: Bool = true) async throws -> RederiveResult {
        await acquire(); defer { release() }
        try maintenanceGate("re-derive")
        guard let image = rootImageDisk else {
            throw SandboxError.invalidSpec("re-derive needs the image this disk came from (\(persistedRecord?.rootImage ?? "unknown")) — it is not in the store")
        }
        setBusy(true); defer { setBusy(false) }
        let t0 = ContinuousClock.now
        let fm = FileManager.default
        let old = layout.rootfs
        let tmp = layout.sandboxDirectory.appendingPathComponent("rootfs.rederive.ext4")
        try? fm.removeItem(at: tmp)
        var keepTmp = false
        defer { if !keepTmp { try? fm.removeItem(at: tmp) } }

        let inspector = try EXT4Inspector(old)
        let free = try inspector.freeRanges()
        let oldExt = try DiskAccounting.extents(of: old), imgExt = try DiskAccounting.extents(of: image)
        let before = try DiskAccounting.share([image, old])
        let garbageBefore = try DiskAccounting.garbage(of: old, extents: oldExt)
        let allocatedBefore = ImageBaker.sizes(old).allocated

        let (written, zeroed, identical): (Int64, Int64, Int64) = try await timed("re-derive: cloned the image and wrote only the blocks that differ") {
            guard clonefile(image.path, tmp.path, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            chmod(tmp.path, 0o644)
            let size = ImageBaker.sizes(old).apparent
            guard truncate(tmp.path, off_t(size)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let delta = DiskAccounting.blockDelta(child: oldExt, parent: imgExt)
            let content = try DiskAccounting.contentRuns(child: old, parent: image, ranges: DiskAccounting.subtract(delta.differ, free))
            let w = try DiskAccounting.copyRanges(old, tmp, content.runs)
            // The image has data where the old disk has a hole (zeros) that ext4 uses: zero it.
            let holes = DiskAccounting.intersect(DiskAccounting.subtract(delta.holedInChild, free), [(0, size)])
            try DiskAccounting.punchHoles(tmp, holes)
            return (w, DiskAccounting.total(holes), content.identical)
        }
        try MaintenanceFaults.check("after-write")
        if verify {
            try await timed("re-derive: every block ext4 uses reads the same on the new disk") {
                let used = DiskAccounting.complement(free, size: inspector.capacityBytes)
                guard try DiskAccounting.identical(old, tmp, over: used) else {
                    throw SandboxError.commandFailed(command: "re-derive verification", exitCode: 1, output: "the rebuilt disk differs from the old one — the old disk is kept")
                }
            }
        }
        let helper = try await fsckHelper()
        let (code, report) = try await timed("re-derive: e2fsck -fn of the new disk") { try await helper.checkReadOnly(tmp) }
        guard code == 0 else {
            throw SandboxError.commandFailed(command: "e2fsck -fn of the re-derived disk", exitCode: code, output: report + " — the old disk is kept")
        }
        try MaintenanceFaults.check("before-swap")
        try await timed("re-derive: the new disk replaced the old one (atomic rename)") {
            guard rename(tmp.path, old.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        keepTmp = true
        let after = try DiskAccounting.share([image, old])
        let r = RederiveResult(allocatedBefore: allocatedBefore, allocatedAfter: ImageBaker.sizes(old).allocated,
                               sharedWithImageBefore: before.shared(0, 1), sharedWithImageAfter: after.shared(0, 1),
                               garbageBefore: garbageBefore, garbageAfter: try DiskAccounting.garbage(of: old),
                               writtenBytes: written, zeroedBytes: zeroed, identicalBytes: identical,
                               fsckReport: report.split(separator: "\n").suffix(3).joined(separator: " · "), milliseconds: milliseconds(since: t0))
        broadcaster.yield(.step(String(format: "re-derived the root disk: shared with the image %.1f → %.1f MiB, garbage %.1f → %.1f MiB, allocated %.1f → %.1f MiB (wrote %.1f MiB)",
                                       MaintenanceAdvice.mib(r.sharedWithImageBefore), MaintenanceAdvice.mib(r.sharedWithImageAfter),
                                       MaintenanceAdvice.mib(r.garbageBefore), MaintenanceAdvice.mib(r.garbageAfter),
                                       MaintenanceAdvice.mib(r.allocatedBefore), MaintenanceAdvice.mib(r.allocatedAfter), MaintenanceAdvice.mib(r.writtenBytes)),
                                milliseconds: r.milliseconds))
        return r
    }

    /// `e2fsck -fn` (read-only) on this stopped sandbox's root and state disks, in the helper VM.
    public func checkDisks() async throws -> [DiskCheck] {
        await acquire(); defer { release() }
        guard phase == .off else { throw SandboxError.invalidPhase(operation: "check the disks", phase: phase) }
        let helper = try await fsckHelper()
        var out: [DiskCheck] = []
        for disk in disks {
            let (code, report) = try await timed("e2fsck -fn \(disk.lastPathComponent)") { try await helper.checkReadOnly(disk) }
            out.append(DiskCheck(disk: disk.lastPathComponent, clean: code == 0, exitCode: code, report: report))
        }
        return out
    }

    // MARK: helpers

    /// The root disk, then the state disk (if any).
    nonisolated var disks: [URL] {
        [layout.rootfs, layout.stateDisk].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    nonisolated var persistedRecord: PersistedSandbox? { PersistedSandbox.read(from: layout.persistedState) }

    /// The disk of the image the root disk was cloned from, if it is still in the store.
    nonisolated var rootImageDisk: URL? { persistedRecord?.rootImage.flatMap(layout.imageDisk(forKey:)) }

    /// Maintenance needs a stopped sandbox whose disks were cleanly unmounted.
    func maintenanceGate(_ what: String) throws {
        guard phase == .off, !busy else { throw SandboxError.invalidPhase(operation: what, phase: phase) }
        guard FileManager.default.fileExists(atPath: layout.rootfs.path) else {
            throw SandboxError.invalidSpec("\(what): there is no root disk yet")
        }
        if let p = persistedRecord {
            guard p.phase == .off, !FileManager.default.fileExists(atPath: layout.snapshot.path) else {
                throw SandboxError.invalidSpec("\(what): the sandbox is asleep in a snapshot (\(p.phase.rawValue)) — wake it and shut it down first")
            }
            guard p.fsckOnNextBoot != true else {
                throw SandboxError.invalidSpec("\(what): the disk was not cleanly unmounted — start the sandbox and shut it down first")
            }
        }
        for disk in disks {
            let i = try EXT4Inspector(disk)
            guard i.isClean else {
                throw SandboxError.invalidSpec("\(what): \(disk.lastPathComponent) was not cleanly unmounted\(i.needsRecovery ? " (journal recovery pending)" : "") — start the sandbox and shut it down first")
            }
        }
    }

    func fsckHelper() async throws -> FsckHelper {
        let kernelURL = try await kernelProvider.resolve(override: spec.kernelPath)
        let broadcaster = self.broadcaster
        return FsckHelper(storeRoot: spec.storeRoot, kernel: Kernel(path: kernelURL, platform: .linuxArm), initfsReference: spec.initfsReference,
                          dnsServers: spec.dnsServers, events: { broadcaster.yield($0) })
    }
}
