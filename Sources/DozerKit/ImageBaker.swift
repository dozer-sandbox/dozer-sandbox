import Containerization
import ContainerizationExtras
import ContainerizationOCI
import Darwin
import Foundation

/// What a bake recorded, next to the disk.
public struct ImageManifest: Sendable, Codable, Equatable {
    public var key: String
    public var imageSpec: ImageSpec
    public var kernelSHA256: String
    public var deckholdSHA256: String
    public var bakedAt: Date
    /// Step label → milliseconds, in order.
    public var timings: [TimedStep]
    /// The disk's capacity (what `ls -l` shows) and what it really occupies on APFS.
    public var apparentBytes: Int64
    public var allocatedBytes: Int64
    /// Output of each verification command.
    public var verifyOutput: [String]
    /// 587: what the bake's final `fstrim /` returned to the Mac, bytes (nil: a pre-587 bake).
    public var trimmedBytes: Int64?
    /// 587: the disk's ext4 journal, MiB (nil: none, or a pre-587 bake).
    public var journalMiB: Int?
    /// 587: the key of the base disk this image was baked on (`<store>/images/bases/<key12>/`) —
    /// its lineage parent. nil: a pre-587 bake, flattened on its own. The image never depends on
    /// the parent FILE: deleting or re-deriving the base leaves it (and its sandboxes) as they are.
    public var parent: String?

    public init(key: String, imageSpec: ImageSpec, kernelSHA256: String, deckholdSHA256: String, bakedAt: Date,
                timings: [TimedStep], apparentBytes: Int64, allocatedBytes: Int64, verifyOutput: [String]) {
        self.key = key
        self.imageSpec = imageSpec
        self.kernelSHA256 = kernelSHA256
        self.deckholdSHA256 = deckholdSHA256
        self.bakedAt = bakedAt
        self.timings = timings
        self.apparentBytes = apparentBytes
        self.allocatedBytes = allocatedBytes
        self.verifyOutput = verifyOutput
    }

    public struct TimedStep: Sendable, Codable, Equatable {
        public var step: String
        public var milliseconds: Double
    }

    public var totalMilliseconds: Double { timings.reduce(0) { $0 + $1.milliseconds } }
}

/// A baked disk ready to clone.
public struct BakedImage: Sendable, Equatable {
    public var root: URL
    public var manifest: ImageManifest
    public var key: String { manifest.key }
}

/// 587: what a base disk recorded, next to it.
public struct BaseManifest: Sendable, Codable, Equatable {
    public var key: String
    /// The OCI reference it was flattened from (`repo@sha256:…`) and its digest.
    public var reference: String
    public var digest: String
    public var capacityMiB: UInt64
    public var journalMiB: Int?
    public var formatterVersion: String
    public var flattenedAt: Date
    public var flattenMilliseconds: Double
    public var apparentBytes: Int64
    public var allocatedBytes: Int64
}

/// 587: a flattened OCI base, cloned by every bake on it.
public struct BaseDisk: Sendable, Equatable {
    public var root: URL
    public var manifest: BaseManifest
    public var key: String { manifest.key }
}

/// Builds and caches baked root disks, as a clone tree (587):
///
///     <storeRoot>/images/bases/<key12>/root.ext4        an OCI base flattened ONCE (0444)
///     <storeRoot>/images/bases/<key12>/manifest.json    digest, capacity, journal, formatter version
///     <storeRoot>/images/bases/<key12>.lock             serialises concurrent flattens of one base
///     <storeRoot>/images/<name>/<key12>/root.ext4       read-only (0444) — sandboxes APFS-clone it
///     <storeRoot>/images/<name>/<key12>/manifest.json   key, parent (the base key), imageSpec, timings, sizes, verify output
///     <storeRoot>/images/<name>/<key12>.lock            serialises concurrent bakes of one key
///
/// Bake = pull the digest-pinned base (once per store) → flatten it to ext4 (once per base key) →
/// APFS-clone the base → boot the clone → run the steps → verify (credential-free) → `fstrim` →
/// clean stop → move into place atomically. A failed bake leaves nothing in the cache. Every image
/// on one base shares the base's blocks (586: ~255 MiB each for the `node` base), and a re-bake
/// skips the flatten (586: ~50 s → ~15–17 s).
public struct ImageBaker: Sendable {
    public var storeRoot: URL

    /// The EXT4 formatter a base disk was made with: a different one is a different base.
    public static let formatterVersion = "containerization-0.47.0/EXT4Unpacker"
    /// 587: the image layout generation, part of every bake key (clone of a base + trim).
    public static let lineageFormat = "587-base-clone-v1"
    /// 594 (D12): how many layers a base pull downloads at once. Containerization's default is 3;
    /// the value kept is the faster of 3 and 6 as measured on fresh stores (594.02-RESULTS.md,
    /// `doz-vmtest pullbench`). Not a key input — it changes how the bytes arrive, not what they are.
    public static let pullConcurrency = 3

    public init(storeRoot: URL) { self.storeRoot = storeRoot }

    public var basesDirectory: URL { storeRoot.appendingPathComponent("images/bases") }

    public func baseLocation(_ key: String) -> URL { basesDirectory.appendingPathComponent(String(key.prefix(12))) }

    /// The base disk for this key, if a complete flatten is there.
    public func cachedBase(_ key: String) -> BaseDisk? {
        let dir = baseLocation(key)
        let root = dir.appendingPathComponent("root.ext4")
        guard FileManager.default.fileExists(atPath: root.path),
              let d = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let m = try? Self.decoder.decode(BaseManifest.self, from: d), m.key == key
        else { return nil }
        return BaseDisk(root: root, manifest: m)
    }

    /// Every base disk in the store.
    public func allBases() -> [BaseDisk] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: basesDirectory.path)) ?? []
        return names.compactMap { n -> BaseDisk? in
            let d = basesDirectory.appendingPathComponent(n)
            guard let data = try? Data(contentsOf: d.appendingPathComponent("manifest.json")),
                  let m = try? Self.decoder.decode(BaseManifest.self, from: data) else { return nil }
            return BaseDisk(root: d.appendingPathComponent("root.ext4"), manifest: m)
        }.sorted { $0.manifest.flattenedAt > $1.manifest.flattenedAt }
    }

    /// Delete a base disk. Images baked on it — and their sandboxes — are unaffected (each is its
    /// own APFS clone); only the next bake on this base flattens it again.
    public func deleteBase(_ key: String) throws {
        try FileManager.default.removeItem(at: baseLocation(key))
    }

    /// The base disk for `imageSpec`: a cache hit, or a flatten (once per key, under a lock, so
    /// concurrent bakes of one base wait instead of flattening twice).
    public func ensureBase(_ imageSpec: ImageSpec, image: Containerization.Image,
                           events: @escaping @Sendable (SandboxEvent) -> Void = { _ in }) async throws -> BaseDisk {
        let key = imageSpec.baseKey
        if let hit = cachedBase(key) { return hit }
        let fm = FileManager.default
        try fm.createDirectory(at: basesDirectory, withIntermediateDirectories: true)
        let lock = try await FileLock.acquire(basesDirectory.appendingPathComponent("\(key.prefix(12)).lock"),
                                              waiting: { events(.note("another flatten of this base is running — waiting for it")) })
        defer { lock.release() }
        if let hit = cachedBase(key) { return hit }
        let staging = basesDirectory.appendingPathComponent("\(key.prefix(12)).partial-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let root = staging.appendingPathComponent("root.ext4")
        let t0 = ContinuousClock.now
        _ = try await EXT4Unpacker(capacityInBytes: imageSpec.rootfsMiB * 1_048_576, journal: imageSpec.journalConfig)
            .unpack(image, for: .current, at: root)
        let ms = milliseconds(since: t0)
        let (apparent, allocated) = Self.sizes(root)
        chmod(root.path, 0o444)
        let m = BaseManifest(key: key, reference: imageSpec.base, digest: imageSpec.base.split(separator: "@").last.map(String.init) ?? "",
                             capacityMiB: imageSpec.rootfsMiB, journalMiB: imageSpec.journalMiB, formatterVersion: Self.formatterVersion,
                             flattenedAt: Date(), flattenMilliseconds: ms, apparentBytes: apparent, allocatedBytes: allocated)
        try Self.encoder.encode(m).write(to: staging.appendingPathComponent("manifest.json"))
        let final = baseLocation(key)
        try? fm.removeItem(at: final)
        guard rename(staging.path, final.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        events(.step("flattened the base \(imageSpec.base.split(separator: "@").first ?? "") once (\(imageSpec.rootfsMiB) MiB\(imageSpec.journalMiB.map { ", \($0) MiB journal" } ?? ", no journal"); \(Self.mib(allocated)) MiB) — base \(key.prefix(12))",
                     milliseconds: ms))
        return BaseDisk(root: final.appendingPathComponent("root.ext4"), manifest: m)
    }

    public func imageDirectory(_ imageSpec: ImageSpec) -> URL {
        storeRoot.appendingPathComponent("images/\(imageSpec.name)")
    }

    public func location(_ imageSpec: ImageSpec, key: String) -> URL {
        imageDirectory(imageSpec).appendingPathComponent(String(key.prefix(12)))
    }

    /// The cached disk for this key, if a complete bake is there.
    public func cached(_ imageSpec: ImageSpec, key: String) -> BakedImage? {
        let dir = location(imageSpec, key: key)
        let root = dir.appendingPathComponent("root.ext4")
        guard FileManager.default.fileExists(atPath: root.path),
              let d = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let m = try? Self.decoder.decode(ImageManifest.self, from: d), m.key == key
        else { return nil }
        return BakedImage(root: root, manifest: m)
    }

    /// Every bake of this imageSpec name in the store (for a UI, and for pruning).
    public func all(_ imageSpec: ImageSpec) -> [BakedImage] {
        let dir = imageDirectory(imageSpec)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { n -> BakedImage? in
            let d = dir.appendingPathComponent(n)
            guard let data = try? Data(contentsOf: d.appendingPathComponent("manifest.json")),
                  let m = try? Self.decoder.decode(ImageManifest.self, from: data) else { return nil }
            return BakedImage(root: d.appendingPathComponent("root.ext4"), manifest: m)
        }.sorted { $0.manifest.bakedAt > $1.manifest.bakedAt }
    }

    public struct BakeInputs: Sendable {
        public var kernel: Kernel
        public var kernelSHA256: String
        public var deckholdSHA256: String
        public var initfsReference: String
        public var dnsServers: [String]
        public var cpus: Int
        public var memoryMiB: UInt64
        /// 580: bake with NO network interface, through the host proxy under this policy (usually
        /// `NetworkPolicy.bake`: package registries only). nil: a vmnet NAT interface, as before.
        /// Not part of the bake key — it changes what the bake may reach, not what it installs.
        public var egress: NetworkPolicy?
        /// Where a proxied bake's connections are logged (nil: a private log, summarised in events).
        public var egressLog: ConnectionLog?
        public init(kernel: Kernel, kernelSHA256: String, deckholdSHA256: String, initfsReference: String,
                    dnsServers: [String], cpus: Int = 4, memoryMiB: UInt64 = 2048, egress: NetworkPolicy? = nil,
                    egressLog: ConnectionLog? = nil) {
            self.egress = egress
            self.egressLog = egressLog
            self.kernel = kernel
            self.kernelSHA256 = kernelSHA256
            self.deckholdSHA256 = deckholdSHA256
            self.initfsReference = initfsReference
            self.dnsServers = dnsServers
            self.cpus = cpus
            self.memoryMiB = memoryMiB
        }
    }

    /// The baked disk for `imageSpec`: a cache hit, or a bake.
    public func ensure(_ imageSpec: ImageSpec, inputs: BakeInputs,
                       events: @escaping @Sendable (SandboxEvent) -> Void = { _ in }) async throws -> BakedImage {
        try imageSpec.validate()
        let key = imageSpec.bakeKey(kernelSHA256: inputs.kernelSHA256, deckholdSHA256: inputs.deckholdSHA256)
        if let hit = cached(imageSpec, key: key) {
            events(.note("image \(imageSpec.name) \(key.prefix(12)) ready (cached; baked \(hit.manifest.bakedAt.formatted(date: .abbreviated, time: .shortened)), \(Self.mib(hit.manifest.allocatedBytes)) MiB allocated)"))
            return hit
        }
        try FileManager.default.createDirectory(at: imageDirectory(imageSpec), withIntermediateDirectories: true)
        let lock = try await FileLock.acquire(imageDirectory(imageSpec).appendingPathComponent("\(key.prefix(12)).lock"),
                                              waiting: { events(.note("another bake of \(imageSpec.name) is running — waiting for it")) })
        defer { lock.release() }
        if let hit = cached(imageSpec, key: key) { return hit }         // it finished while we waited
        return try await bake(imageSpec, key: key, inputs: inputs, events: events)
    }

    private func bake(_ imageSpec: ImageSpec, key: String, inputs: BakeInputs,
                      events: @escaping @Sendable (SandboxEvent) -> Void) async throws -> BakedImage {
        let fm = FileManager.default
        var timings: [ImageManifest.TimedStep] = []
        func timed<T>(_ label: String, _ body: () async throws -> T) async throws -> T {
            let t0 = ContinuousClock.now
            events(.stepStarted(label))
            do {
                let v = try await body()
                let ms = milliseconds(since: t0)
                timings.append(.init(step: label, milliseconds: ms))
                events(.step(label, milliseconds: ms))
                return v
            } catch {
                events(.stepFailed(label, milliseconds: milliseconds(since: t0), error: error.localizedDescription))
                throw error
            }
        }
        events(.note("baking image \(imageSpec.name) \(key.prefix(12)) from \(imageSpec.base) (one-time per image spec, needs network)…"))
        let store = try ImageStore(path: storeRoot)
        // 583: a NAT bake gets a free subnet of its own, never vmnet's default.
        let bakeNet = inputs.egress == nil ? try SubnetPool.makeNetwork() : nil
        defer { if let bakeNet { SubnetPool.release(bakeNet.subnet.description) } }
        var mgr = try await ContainerManager(kernel: inputs.kernel, initfsReference: inputs.initfsReference,
                                             imageStore: store, network: bakeNet)
        let cachedImage = try? await store.get(reference: imageSpec.base, pull: false)
        let baseName = imageSpec.base.split(separator: "@").first.map(String.init) ?? imageSpec.base
        let image = try await timed(cachedImage != nil ? "base image \(baseName) (cached)" : "pulled the base image \(baseName)") {
            if let cachedImage { return cachedImage }
            return try await Self.pull(imageSpec.base, store: store, events: events)
        }
        let id = "bake-\(imageSpec.name)"
        try? mgr.delete(id)
        let staging = imageDirectory(imageSpec).appendingPathComponent("\(key.prefix(12)).partial-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let root = staging.appendingPathComponent("root.ext4")
        let proxied = inputs.egress != nil
        let dns = proxied ? ["127.0.0.1"] : inputs.dnsServers
        let cpus = inputs.cpus, mem = inputs.memoryMiB
        let proxy = try inputs.egress.map { try EgressProxy(policy: $0, ca: nil, log: inputs.egressLog ?? ConnectionLog()) }
        // 587: the base is flattened once per base key; this bake starts from an APFS clone of it.
        let hadBaseDisk = cachedBase(imageSpec.baseKey) != nil
        let base = try await timed(hadBaseDisk ? "base disk ready (cached, \(imageSpec.baseKey.prefix(12)))" : "base disk flattened (\(imageSpec.baseKey.prefix(12)))") {
            try await ensureBase(imageSpec, image: image, events: events)
        }
        try await timed("cloned the base disk (APFS clone)") {
            guard clonefile(base.root.path, root.path, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            chmod(root.path, 0o644)
        }
        // The VM boots the staging disk itself; `create(rootfs:)` does not make the container's
        // directory (586), so it is made here.
        try? fm.removeItem(at: storeRoot.appendingPathComponent("containers/\(id)"))
        try fm.createDirectory(at: storeRoot.appendingPathComponent("containers/\(id)"), withIntermediateDirectories: true)
        let c = try await mgr.create(id, image: image, rootfs: .block(format: "ext4", source: root.path, destination: "/"),
                                     networking: !proxied,
                                     vm: VMResources(cpus: cpus, memoryInBytes: mem * 1_048_576 + VMResources.guestMemoryOverhead)) { cfg in
            cfg.cpus = cpus
            cfg.memoryInBytes = mem * 1_048_576
            cfg.process.arguments = ["sleep", "infinity"]
            cfg.dns = DNS(nameservers: dns)
        }
        var trimmed: Int64 = 0
        var verifyOutput: [String] = []
        do {
            try await timed("booted the bake VM") { try await c.create(); try await c.start() }
            if let proxy {
                try await timed("bake network: no interface, via the Mac's proxy (\(proxy.policy.preset ?? "custom") policy)") {
                    try await c.withVirtualMachineInstance { i in
                        guard let v = vzInstance(of: i) else { throw SandboxError.vmUnavailable }
                        try proxy.listen(on: v)
                    }
                    try await Sandbox.startEgressShim(on: c, caFile: nil)
                }
            }
            defer {
                if let proxy {
                    proxy.stopListening()
                    let denied = proxy.log.records.filter { $0.verdict == .denied }
                    events(.note("bake network: \(proxy.log.totalCount) connection(s), \(denied.count) denied"
                                 + (denied.isEmpty ? "" : " (" + Set(denied.map(\.target)).sorted().prefix(8).joined(separator: ", ") + ")")))
                }
            }
            let netEnv = proxy?.guestEnvironment ?? [:]
            for step in imageSpec.steps {
                // 594: a cancelled preparation stops between steps (the one under way runs to its end).
                try Task.checkCancellation()
                // 593: the step's own output, live — a tail of it, as inert text, at most 4 lines a second.
                let tail = OutputTail { events(.output($0)) }
                let r = try await timed("step: \(step.name)") {
                    try await Sandbox.exec(on: c, step.argv,
                                           environment: BakeEnvironment.scrubbed(step.environment.merging(Self.userEnv(step.user, imageSpec)) { a, _ in a }.merging(netEnv) { a, _ in a }),
                                           workingDirectory: "/", privileged: false, timeout: step.timeoutSeconds, user: step.user,
                                           onOutput: { tail.add($0) })
                }
                tail.flush()
                guard r.exitCode == 0 else {
                    throw SandboxError.commandFailed(command: "bake step \(step.name)", exitCode: r.exitCode, output: r.output + r.errorOutput)
                }
            }
            for check in imageSpec.verify {
                // 594 W8: ONE line per check — "✓ verify: claude --version → 2.1.285 (169 ms)" — the step
                // ends with its output (a view ends "verify: X" by "verify: X → …"), no second line.
                let label = "verify: \(check.argv.joined(separator: " "))"
                let t0 = ContinuousClock.now
                events(.stepStarted(label))
                let r: ExecResult
                do {
                    r = try await Sandbox.exec(on: c, check.argv,
                                               environment: BakeEnvironment.scrubbed(imageSpec.sessionEnvironment.merging(Self.userEnv(imageSpec.user, imageSpec)) { a, _ in a }),
                                               workingDirectory: imageSpec.home, privileged: false, timeout: 120, user: imageSpec.user)
                } catch {
                    events(.stepFailed(label, milliseconds: milliseconds(since: t0), error: error.localizedDescription))
                    throw error
                }
                let ms = milliseconds(since: t0)
                let out = (r.output + r.errorOutput).trimmingCharacters(in: .whitespacesAndNewlines)
                guard r.exitCode == 0, check.expect.map({ out.contains($0) }) ?? true else {
                    events(.stepFailed(label, milliseconds: ms, error: "exit \(r.exitCode): \(out.prefix(200))"))
                    throw SandboxError.commandFailed(command: "verify \(check.argv.joined(separator: " "))", exitCode: r.exitCode, output: out)
                }
                timings.append(.init(step: label, milliseconds: ms))
                verifyOutput.append(out)
                let shown = out.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(120)
                events(.step("\(label) → \(shown)", milliseconds: ms))
            }
            // 587: trim as the last step (586: −11 % for 56 ms) — the install's own deleted files
            // (npm's tarball and cache) would otherwise stay in the image, and in every clone of it.
            let before = try await Self.settledAllocation(c, root)
            let tr = try await timed("trimmed the disk (fstrim /)") {
                try await Sandbox.exec(on: c, ["sh", "-c", GuestCommand.trimRoot], environment: [:], workingDirectory: "/",
                                       privileged: true, timeout: 120, user: nil)
            }
            try await timed("stopped the bake VM cleanly") { try await c.stop() }
            trimmed = max(0, before - Self.sizes(root).allocated)
            events(.note("fstrim: \((tr.output + tr.errorOutput).trimmingCharacters(in: .whitespacesAndNewlines)) — \(Self.mib(trimmed)) MiB returned to the Mac"))
        } catch {
            // 594: in a task of its own — a CANCELLED bake (its preparation was cancelled) must still
            // stop its VM cleanly; calls made in the cancelled task could refuse to run.
            let cm = mgr
            await Task { var m = cm; try? await c.stop(); try? m.delete(id) }.value
            events(.note("bake of \(imageSpec.name) \(error is CancellationError ? "cancelled" : "FAILED: \(error.localizedDescription)") — nothing was cached"))
            throw error
        }

        try? mgr.delete(id)
        let (apparent, allocated) = Self.sizes(root)
        chmod(root.path, 0o444)
        var manifest = ImageManifest(key: key, imageSpec: imageSpec, kernelSHA256: inputs.kernelSHA256,
                                     deckholdSHA256: inputs.deckholdSHA256, bakedAt: Date(), timings: timings,
                                     apparentBytes: apparent, allocatedBytes: allocated, verifyOutput: verifyOutput)
        manifest.trimmedBytes = trimmed
        manifest.journalMiB = imageSpec.journalMiB
        manifest.parent = base.key
        try Self.encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))
        let final = location(imageSpec, key: key)
        try? fm.removeItem(at: final)
        guard rename(staging.path, final.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        events(.note(String(format: "baked image %@ %@ in %.1f s — disk %d MiB apparent, %d MiB allocated",
                            imageSpec.name, String(key.prefix(12)), manifest.totalMilliseconds / 1000, Self.mib(apparent), Self.mib(allocated))))
        return BakedImage(root: final.appendingPathComponent("root.ext4"), manifest: manifest)
    }

    /// What a running VM's disk file really holds: the guest syncs, then the host flushes the file
    /// (APFS allocates written data when it is flushed), then its allocation is read.
    static func settledAllocation(_ c: LinuxContainer, _ disk: URL) async throws -> Int64 {
        _ = try await Sandbox.exec(on: c, ["sync"], environment: [:], workingDirectory: "/", privileged: false, timeout: 60, user: nil)
        let fd = open(disk.path, O_RDONLY)
        if fd >= 0 { fsync(fd); close(fd) }
        return sizes(disk).allocated
    }

    static func userEnv(_ user: String?, _ imageSpec: ImageSpec) -> [String: String] {
        guard let user, user != "root" else { return [:] }
        return ["HOME": user == imageSpec.user ? imageSpec.home : "/home/\(user)", "USER": user]
    }

    /// Apparent (capacity) and allocated bytes of a file.
    public static func sizes(_ url: URL) -> (apparent: Int64, allocated: Int64) {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return (0, 0) }
        return (Int64(st.st_size), Int64(st.st_blocks) * 512)
    }

    static func mib(_ bytes: Int64) -> Int { Int(bytes / 1_048_576) }

    /// ISO 8601 WITH fractional seconds: restore points taken within one second must still sort
    /// in the order they were taken. The decoder also reads the plain form older files used.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
        }
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let v = try? Date(s, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) { return v }
            if let v = try? Date(s, strategy: .iso8601) { return v }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "not an ISO 8601 date: \(s)"))
        }
        return d
    }()
}

/// An advisory `flock` on a file, polled (never blocking a cooperative thread).
final class FileLock: @unchecked Sendable {
    private let fd: Int32
    private init(fd: Int32) { self.fd = fd }

    static func acquire(_ url: URL, waiting: @Sendable () -> Void) async throws -> FileLock {
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var told = false
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if !told { waiting(); told = true }
            try await Task.sleep(for: .milliseconds(500))
        }
        return FileLock(fd: fd)
    }

    func release() { flock(fd, LOCK_UN); close(fd) }
}
