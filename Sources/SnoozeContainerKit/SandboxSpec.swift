import Foundation

/// Everything that decides what a sandbox IS. Two sandboxes built from equal specs are
/// interchangeable, and a sandbox restored after a crash is rebuilt from the spec it persisted —
/// so every field here is a VM input, and nothing here is a host app's brand or storage choice
/// beyond `storeRoot`, which the host passes in.
public struct SandboxSpec: Sendable, Codable, Equatable {
    /// The sandbox's name: the container id, and the directory under `storeRoot/sandboxes/`.
    /// `[a-z0-9-]`, 1–40 characters (validated by `validate()`).
    public var name: String
    /// Where images, the guest init disk, prepared ("golden") disks and per-sandbox state live.
    /// A host app passes its own storage root; tests pass a scratch directory.
    public var storeRoot: URL
    /// OCI image the root disk is unpacked from.
    public var image: String
    /// The guest init image (vminitd). Tied to the Containerization version.
    public var initfsReference: String
    /// An explicit Linux kernel to boot, used as given. nil (the default): the library's own
    /// pinned kernel (`KernelArtifact.recommended`), fetched once into `kernelCacheDirectory`.
    public var kernelPath: String?
    /// Where the pinned kernel is cached. nil: `<storeRoot>/kernels`. Point several stores (or
    /// CI runs) at one directory to download the ~600 MB release archive only once.
    public var kernelCacheDirectory: URL?
    public var cpus: Int
    /// Guest RAM, MiB (the package adds its own small overhead on top).
    public var memoryMiB: UInt64
    /// Size of the root disk, MiB.
    public var rootfsMiB: UInt64
    /// Alpine packages baked into the prepared disk once per store (`apk add`), e.g. `bash`.
    /// Every start then boots from an APFS clone of that disk (~0 ms) instead of installing.
    public var bakePackages: [String]
    /// Host directories shared into the guest (virtio-fs). Re-mounted on every wake.
    public var shares: [Share]
    /// A NAT network interface (vmnet shared mode). Needed for anything that talks to the
    /// internet, including the one-time package bake.
    public var networking: Bool
    public var dnsServers: [String]

    public init(
        name: String,
        storeRoot: URL,
        image: String = "docker.io/library/alpine:3.20",
        initfsReference: String = "ghcr.io/apple/containerization/vminit:0.47.0",
        kernelPath: String? = nil,
        kernelCacheDirectory: URL? = nil,
        cpus: Int = 2,
        memoryMiB: UInt64 = 1024,
        rootfsMiB: UInt64 = 1024,
        bakePackages: [String] = [],
        shares: [Share] = [],
        networking: Bool = true,
        dnsServers: [String] = ["1.1.1.1", "8.8.8.8"]
    ) {
        self.name = name
        self.storeRoot = storeRoot
        self.image = image
        self.initfsReference = initfsReference
        self.kernelPath = kernelPath
        self.kernelCacheDirectory = kernelCacheDirectory
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.rootfsMiB = rootfsMiB
        self.bakePackages = bakePackages
        self.shares = shares
        self.networking = networking
        self.dnsServers = dnsServers
    }

    /// Throws `SandboxError.invalidSpec` for a spec that would fail later in a less obvious way.
    public func validate() throws {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard (1...40).contains(name.count), name.allSatisfy(allowed.contains), name.first != "-" else {
            throw SandboxError.invalidSpec("name must be 1–40 characters of [a-z0-9-], got \"\(name)\"")
        }
        guard cpus >= 1 else { throw SandboxError.invalidSpec("cpus must be ≥ 1") }
        guard memoryMiB >= 128 else { throw SandboxError.invalidSpec("memoryMiB must be ≥ 128") }
        guard rootfsMiB >= 256 else { throw SandboxError.invalidSpec("rootfsMiB must be ≥ 256") }
        for s in shares {
            guard s.guestPath.hasPrefix("/"), !s.guestPath.contains("'") else {
                throw SandboxError.invalidSpec("share guest path must be absolute and quote-free: \(s.guestPath)")
            }
        }
        for p in bakePackages where !p.allSatisfy({ $0.isLetter || $0.isNumber || "+-._".contains($0) }) {
            throw SandboxError.invalidSpec("bad package name \(p)")
        }
    }
}

/// A host directory shared into the guest at `guestPath`.
public struct Share: Sendable, Codable, Equatable {
    public var hostPath: String
    public var guestPath: String
    public init(hostPath: String, guestPath: String) {
        self.hostPath = hostPath
        self.guestPath = guestPath
    }
}

/// A terminal size in character cells.
public struct TermSize: Sendable, Codable, Equatable, CustomStringConvertible {
    public var cols: UInt16
    public var rows: UInt16
    public init(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
    }
    public static let standard = TermSize(cols: 80, rows: 24)
    public var description: String { "\(cols)×\(rows)" }
}
