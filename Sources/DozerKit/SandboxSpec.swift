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
    /// A NAT network interface (vmnet shared mode). Set from `network` (true only for `.nat`);
    /// kept as its own field because older persisted specs carry only this.
    public var networking: Bool
    /// 580: how the sandbox reaches the network. nil (older specs): `.nat` if `networking`, else `.none`.
    public var networkMode: NetworkMode?
    public var dnsServers: [String]
    /// The vmnet subnet (CIDR, e.g. `192.168.201.0/24`). nil: vmnet's default. Two PROCESSES that
    /// each take the default can get the SAME subnet and the same guest addresses, and the NAT then
    /// drops one of them (578/579: a test run beside a running SandboxLab lost its network) — a host
    /// that runs beside others should pick its own.
    public var subnet: String?
    /// A baked image to boot instead of `image` + `bakePackages`: its read-only baked disk is
    /// APFS-cloned as the root, and a per-sandbox STATE disk (`stateDiskMiB`, created empty once,
    /// never cloned, never deleted by Stop) holds the imageSpec's `persistDirs`.
    public var imageSpec: ImageSpec?
    public var stateDiskMiB: UInt64
    /// Start from a CUSTOM image (`CustomImage.key`, saved from a restore point) instead of the
    /// prepared disk or the imageSpec's bake. `imageSpec` should be the custom image's imageSpec, if it has one.
    public var customImage: String?
    /// 587: the ext4 journal of the PREPARED disk (the lab's `image` + `bakePackages` sandbox), MiB.
    /// Default 16; nil: no journal (a disk that was not cleanly unmounted is e2fsck'd before it
    /// boots, as before 587). Part of the prepared disk's key. An image sandbox's root and state
    /// disks take `imageSpec.journalMiB` instead. A spec persisted before 587 decodes as nil.
    public var journalMiB: Int?
    /// EXPERIMENTAL (604): an audio sandbox — its VM gets a virtio-snd device (the Mac's microphone and speakers)
    /// and boots the sound kernel (`SoundKernel`, from the kernel cache). nil (every other sandbox, and every spec
    /// persisted before): no device, the pinned kernel — and the spec encodes exactly as before (an absent key).
    public var audio: Bool?

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
        dnsServers: [String] = ["1.1.1.1", "8.8.8.8"],
        subnet: String? = nil,
        imageSpec: ImageSpec? = nil,
        stateDiskMiB: UInt64 = 2048,
        customImage: String? = nil,
        network: NetworkMode? = nil,
        journalMiB: Int? = 16
    ) {
        self.journalMiB = journalMiB
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
        self.subnet = subnet
        self.imageSpec = imageSpec
        self.stateDiskMiB = stateDiskMiB
        self.customImage = customImage
        if let network { self.network = network }
    }

    /// How the sandbox reaches the network: `.proxied(policy)` — no network interface, everything
    /// through the host's `EgressProxy` — `.nat` (a vmnet interface, no policy) or `.none`.
    public var network: NetworkMode {
        get { networkMode ?? (networking ? .nat : .none) }
        set {
            networkMode = newValue
            networking = newValue == .nat
        }
    }

    /// True when the sandbox has no NIC and talks to the network through the host proxy.
    public var isProxied: Bool { network.policy != nil }

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
        if networkMode != nil, networking != (network == .nat) {
            throw SandboxError.invalidSpec("networking must match network (\(network))")
        }
        if let imageSpec {
            try imageSpec.validate()
            guard stateDiskMiB >= 64 else { throw SandboxError.invalidSpec("stateDiskMiB must be ≥ 64") }
            guard !shares.contains(where: { $0.guestPath == "/state" }) else { throw SandboxError.invalidSpec("/state is the state disk") }
        }
        if let j = journalMiB {
            guard (4...1024).contains(j), UInt64(j) * 8 <= rootfsMiB else {
                throw SandboxError.invalidSpec("journalMiB must be 4–1024 and at most an eighth of rootfsMiB (or nil for none), got \(j)")
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
