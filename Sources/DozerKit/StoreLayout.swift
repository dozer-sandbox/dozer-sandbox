import CryptoKit
import Foundation

/// Where everything lives under a spec's `storeRoot`. One place, so the layout is a unit test.
///
///     <storeRoot>/                        the Containerization image store (content/, …)
///     <storeRoot>/initfs.ext4             the guest init disk (vminitd), built once
///     <storeRoot>/kernels/vmlinux-…       the pinned Linux kernel, fetched + verified once
///     <storeRoot>/golden/<key>.ext4       prepared root disks: image + baked packages, one per key
///     <storeRoot>/containers/<name>-bake  scratch for a bake (removed afterwards)
///     <storeRoot>/sandboxes/<name>/
///         rootfs.ext4                     this sandbox's root disk: an APFS clone of a golden disk
///         bootlog.log                     the guest serial console
///         vm.state                        the snapshot (exists only while asleep)
///         sandbox.json                    PersistedSandbox: what a new process needs to restore
///         state.ext4                      image sandboxes: the persist dirs (survives Stop and re-bakes)
///         screens/NAME.{vt,txt,json}      593: each session's last saved screen (`SavedScreens`)
///     <storeRoot>/images/<name>/<key12>/  baked image disks (see ImageBaker)
public struct StoreLayout: Sendable, Equatable {
    public let root: URL
    public let name: String

    public init(root: URL, name: String) {
        self.root = root
        self.name = name
    }

    public init(spec: SandboxSpec) { self.init(root: spec.storeRoot, name: spec.name) }

    public var initfs: URL { root.appendingPathComponent("initfs.ext4") }
    /// The default kernel cache (`SandboxSpec.kernelCacheDirectory` overrides it).
    public var kernels: URL { root.appendingPathComponent("kernels") }
    public var goldenDirectory: URL { root.appendingPathComponent("golden") }
    public var sandboxDirectory: URL { root.appendingPathComponent("sandboxes/\(name)") }
    public var rootfs: URL { sandboxDirectory.appendingPathComponent("rootfs.ext4") }
    public var bootLog: URL { sandboxDirectory.appendingPathComponent("bootlog.log") }
    public var snapshot: URL { sandboxDirectory.appendingPathComponent("vm.state") }
    public var persistedState: URL { sandboxDirectory.appendingPathComponent("sandbox.json") }
    /// The per-sandbox STATE disk of an image sandbox (created empty once; Stop keeps it).
    public var stateDisk: URL { sandboxDirectory.appendingPathComponent("state.ext4") }
    /// 593: the sessions' saved screens (`SavedScreens`) — deleted with the sandbox and on reset.
    public var screensDirectory: URL { sandboxDirectory.appendingPathComponent("screens") }
    public var bakeContainerID: String { "\(name)-bake" }

    /// The prepared disk for this image + package set + size. A different package list or disk
    /// size is a different disk, so changing the spec never boots a stale one.
    public func golden(for spec: SandboxSpec) -> URL {
        goldenDirectory.appendingPathComponent("\(StoreLayout.goldenKey(for: spec)).ext4")
    }

    /// 587: a journaled prepared disk (`spec.journalMiB`) has its own key; a journal-less one keeps
    /// the pre-587 key, because it is the same kind of disk.
    public static func goldenKey(for spec: SandboxSpec) -> String {
        var parts = [spec.image, spec.bakePackages.sorted().joined(separator: ","), String(spec.rootfsMiB)]
        if let j = spec.journalMiB { parts.append("journal:\(j)MiB+trim") }
        let material = parts.joined(separator: "|")
        let digest = SHA256.hash(data: Data(material.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let slug = spec.image.split(separator: "/").last.map(String.init)?
            .replacingOccurrences(of: ":", with: "-") ?? "image"
        return "\(slug)-\(hex.prefix(12))"
    }
}

/// What a sandbox persists so a NEW process can rebuild the identical VM and restore its
/// snapshot (576.02: VZ refuses a snapshot whose machine identifier differs, so it is pinned;
/// the NIC's MAC address and the vmnet subnet are pinned for the same reason).
public struct PersistedSandbox: Codable, Sendable, Equatable {
    public var spec: SandboxSpec
    /// The last durable phase: `running`, `asleep`, `hibernated`, or `off` (shut down; the root
    /// disk is kept for the next Start).
    public var phase: Phase
    /// `VZGenericMachineIdentifier.dataRepresentation`.
    public var machineIdentifier: Data
    /// Locally administered unicast MAC, `aa:bb:…`; nil without networking.
    public var macAddress: String?
    /// The vmnet subnet the NIC was addressed from (CIDR), reused on restore.
    public var subnet: String?
    /// virtio-fs tag per share guest path, as the package attached them.
    public var shareTags: [String: String]
    public var savedAt: Date
    /// Which prepared/baked disk the root disk was cloned from (nil: unknown / older record).
    public var rootImage: String?
    /// The restore point the root disk descends from (after a revert or a fork), if any.
    public var restorePoint: String?
    /// The disk came from a copy taken while its VM ran (no journal): e2fsck it before the next boot.
    public var fsckOnNextBoot: Bool?
    /// 583: the VM has a virtio memory balloon (every VM a 583+ build boots). nil or false: an
    /// older record, whose snapshot must be restored into a VM without one.
    public var memoryBalloon: Bool?
    /// 587: the root / state disk has an ext4 journal (read from its superblock at boot). A journaled
    /// disk that was not cleanly unmounted is replayed by the kernel, not e2fsck'd. nil: an older
    /// record — treated as no journal.
    public var rootJournaled: Bool?
    public var stateJournaled: Bool?
    /// 587: what the guest's file systems held (`df` used, MiB) at the last Stop or Hibernate —
    /// `DiskAccounting`'s garbage is the host file's allocation beyond it.
    public var guestUsedMiB: Double?
    public var stateGuestUsedMiB: Double?
    /// 591: the exact VM the sandbox runs in — recorded when the VM is built, persisted with every
    /// sleep, and compared before a snapshot is restored (`VMLayout`). nil: an older record (a wake is
    /// best effort, as before).
    public var vmLayout: VMLayout?

    public init(spec: SandboxSpec, phase: Phase, machineIdentifier: Data, macAddress: String?, subnet: String?,
                shareTags: [String: String], savedAt: Date = Date()) {
        self.spec = spec
        self.phase = phase
        self.machineIdentifier = machineIdentifier
        self.macAddress = macAddress
        self.subnet = subnet
        self.shareTags = shareTags
        self.savedAt = savedAt
    }

    public func write(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) -> PersistedSandbox? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(PersistedSandbox.self, from: d)
    }

    /// True when this record describes a sandbox a new process can restore: asleep with its
    /// snapshot and root disk still on disk.
    public func isRestorable(layout: StoreLayout, fileManager: FileManager = .default) -> Bool {
        phase.keepsSnapshot
            && fileManager.fileExists(atPath: layout.snapshot.path)
            && fileManager.fileExists(atPath: layout.rootfs.path)
    }

    /// A random locally-administered unicast MAC address.
    public static func randomMAC() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] & 0xFC) | 0x02
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
