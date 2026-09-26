import Containerization
import ContainerizationExtras
import ContainerizationOCI
import Darwin
import Foundation

/// What a bake recorded, next to the disk.
public struct ImageManifest: Sendable, Codable, Equatable {
    public var key: String
    public var recipe: ImageRecipe
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

/// Builds and caches baked root disks:
///
///     <storeRoot>/images/<name>/<key12>/root.ext4       read-only (0444) — sandboxes APFS-clone it
///     <storeRoot>/images/<name>/<key12>/manifest.json   key, recipe, timings, sizes, verify output
///     <storeRoot>/images/<name>/<key12>.lock            serialises concurrent bakes of one key
///
/// Bake = pull the digest-pinned base (once per store) → flatten it to ext4 → boot it → run the
/// steps → verify (credential-free) → `sync` → clean stop → move into place atomically. A failed
/// bake leaves nothing in the cache.
public struct ImageBaker: Sendable {
    public var storeRoot: URL

    public init(storeRoot: URL) { self.storeRoot = storeRoot }

    public func imageDirectory(_ recipe: ImageRecipe) -> URL {
        storeRoot.appendingPathComponent("images/\(recipe.name)")
    }

    public func location(_ recipe: ImageRecipe, key: String) -> URL {
        imageDirectory(recipe).appendingPathComponent(String(key.prefix(12)))
    }

    /// The cached disk for this key, if a complete bake is there.
    public func cached(_ recipe: ImageRecipe, key: String) -> BakedImage? {
        let dir = location(recipe, key: key)
        let root = dir.appendingPathComponent("root.ext4")
        guard FileManager.default.fileExists(atPath: root.path),
              let d = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let m = try? Self.decoder.decode(ImageManifest.self, from: d), m.key == key
        else { return nil }
        return BakedImage(root: root, manifest: m)
    }

    /// Every bake of this recipe name in the store (for a UI, and for pruning).
    public func all(_ recipe: ImageRecipe) -> [BakedImage] {
        let dir = imageDirectory(recipe)
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

    /// The baked disk for `recipe`: a cache hit, or a bake.
    public func ensure(_ recipe: ImageRecipe, inputs: BakeInputs,
                       events: @escaping @Sendable (SandboxEvent) -> Void = { _ in }) async throws -> BakedImage {
        try recipe.validate()
        let key = recipe.bakeKey(kernelSHA256: inputs.kernelSHA256, deckholdSHA256: inputs.deckholdSHA256)
        if let hit = cached(recipe, key: key) {
            events(.note("image \(recipe.name) \(key.prefix(12)) ready (cached; baked \(hit.manifest.bakedAt.formatted(date: .abbreviated, time: .shortened)), \(Self.mib(hit.manifest.allocatedBytes)) MiB allocated)"))
            return hit
        }
        try FileManager.default.createDirectory(at: imageDirectory(recipe), withIntermediateDirectories: true)
        let lock = try await FileLock.acquire(imageDirectory(recipe).appendingPathComponent("\(key.prefix(12)).lock"),
                                              waiting: { events(.note("another bake of \(recipe.name) is running — waiting for it")) })
        defer { lock.release() }
        if let hit = cached(recipe, key: key) { return hit }         // it finished while we waited
        return try await bake(recipe, key: key, inputs: inputs, events: events)
    }

    private func bake(_ recipe: ImageRecipe, key: String, inputs: BakeInputs,
                      events: @escaping @Sendable (SandboxEvent) -> Void) async throws -> BakedImage {
        let fm = FileManager.default
        var timings: [ImageManifest.TimedStep] = []
        func timed<T>(_ label: String, _ body: () async throws -> T) async throws -> T {
            let t0 = ContinuousClock.now
            let v = try await body()
            let ms = milliseconds(since: t0)
            timings.append(.init(step: label, milliseconds: ms))
            events(.step(label, milliseconds: ms))
            return v
        }
        events(.note("baking image \(recipe.name) \(key.prefix(12)) from \(recipe.base) (one-time per recipe, needs network)…"))
        let store = try ImageStore(path: storeRoot)
        // 583: a NAT bake gets a free subnet of its own, never vmnet's default.
        let bakeNet = inputs.egress == nil ? try SubnetPool.makeNetwork() : nil
        defer { if let bakeNet { SubnetPool.release(bakeNet.subnet.description) } }
        var mgr = try await ContainerManager(kernel: inputs.kernel, initfsReference: inputs.initfsReference,
                                             imageStore: store, network: bakeNet)
        let hadBase = (try? await store.get(reference: recipe.base, pull: false)) != nil
        let image = try await timed("base \(hadBase ? "ready (cached)" : "pulled") — \(recipe.base.split(separator: "@").first ?? "")") {
            try await store.get(reference: recipe.base, pull: true)
        }
        let id = "bake-\(recipe.name)"
        try? mgr.delete(id)
        let staging = imageDirectory(recipe).appendingPathComponent("\(key.prefix(12)).partial-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: staging) }
        let proxied = inputs.egress != nil
        let dns = proxied ? ["127.0.0.1"] : inputs.dnsServers
        let cpus = inputs.cpus, mem = inputs.memoryMiB
        let proxy = try inputs.egress.map { try EgressProxy(policy: $0, ca: nil, log: inputs.egressLog ?? ConnectionLog()) }
        let c = try await timed("flattened the base to one ext4 disk (\(recipe.rootfsMiB) MiB capacity)") {
            try await mgr.create(id, image: image, rootfsSizeInBytes: recipe.rootfsMiB * 1_048_576, readOnly: false,
                                 networking: !proxied,
                                 vm: VMResources(cpus: cpus, memoryInBytes: mem * 1_048_576 + VMResources.guestMemoryOverhead)) { cfg in
                cfg.cpus = cpus
                cfg.memoryInBytes = mem * 1_048_576
                cfg.process.arguments = ["sleep", "infinity"]
                cfg.dns = DNS(nameservers: dns)
            }
        }
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
            for step in recipe.steps {
                let r = try await timed("step: \(step.name)") {
                    try await Sandbox.exec(on: c, step.argv,
                                           environment: BakeEnvironment.scrubbed(step.environment.merging(Self.userEnv(step.user, recipe)) { a, _ in a }.merging(netEnv) { a, _ in a }),
                                           workingDirectory: "/", privileged: false, timeout: step.timeoutSeconds, user: step.user)
                }
                guard r.exitCode == 0 else {
                    throw SandboxError.commandFailed(command: "bake step \(step.name)", exitCode: r.exitCode, output: r.output + r.errorOutput)
                }
            }
            for check in recipe.verify {
                let r = try await timed("verify: \(check.argv.joined(separator: " "))") {
                    try await Sandbox.exec(on: c, check.argv,
                                           environment: BakeEnvironment.scrubbed(recipe.sessionEnvironment.merging(Self.userEnv(recipe.user, recipe)) { a, _ in a }),
                                           workingDirectory: recipe.home, privileged: false, timeout: 120, user: recipe.user)
                }
                let out = (r.output + r.errorOutput).trimmingCharacters(in: .whitespacesAndNewlines)
                guard r.exitCode == 0, check.expect.map({ out.contains($0) }) ?? true else {
                    throw SandboxError.commandFailed(command: "verify \(check.argv.joined(separator: " "))", exitCode: r.exitCode, output: out)
                }
                verifyOutput.append(out)
                events(.note("verify: \(check.argv.joined(separator: " ")) → \(out.prefix(120))"))
            }
            _ = try await Sandbox.exec(on: c, ["sync"], environment: [:], workingDirectory: "/", privileged: false, timeout: 60, user: nil)
            try await timed("stopped the bake VM cleanly") { try await c.stop() }
        } catch {
            try? await c.stop()
            try? mgr.delete(id)
            events(.note("bake of \(recipe.name) FAILED: \(error.localizedDescription) — nothing was cached"))
            throw error
        }

        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let root = staging.appendingPathComponent("root.ext4")
        try fm.moveItem(at: storeRoot.appendingPathComponent("containers/\(id)/rootfs.ext4"), to: root)
        try? mgr.delete(id)
        let (apparent, allocated) = Self.sizes(root)
        chmod(root.path, 0o444)
        let manifest = ImageManifest(key: key, recipe: recipe, kernelSHA256: inputs.kernelSHA256,
                                     deckholdSHA256: inputs.deckholdSHA256, bakedAt: Date(), timings: timings,
                                     apparentBytes: apparent, allocatedBytes: allocated, verifyOutput: verifyOutput)
        try Self.encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))
        let final = location(recipe, key: key)
        try? fm.removeItem(at: final)
        guard rename(staging.path, final.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        events(.note(String(format: "baked image %@ %@ in %.1f s — disk %d MiB apparent, %d MiB allocated",
                            recipe.name, String(key.prefix(12)), manifest.totalMilliseconds / 1000, Self.mib(apparent), Self.mib(allocated))))
        return BakedImage(root: final.appendingPathComponent("root.ext4"), manifest: manifest)
    }

    static func userEnv(_ user: String?, _ recipe: ImageRecipe) -> [String: String] {
        guard let user, user != "root" else { return [:] }
        return ["HOME": user == recipe.user ? recipe.home : "/home/\(user)", "USER": user]
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
