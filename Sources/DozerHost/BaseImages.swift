import CryptoKit
import Foundation
import DozerKit

// 596 — Dozer Base Images, the host's half: what the store knows of each base (a catalogue tag's
// digest as last resolved; a Dockerfile's last build), and the image spec a base × agent pair makes.
//
//   <store>/base-digests.json   catalogue id → the tag's digest when last asked (hourly, like 594's latest)
//   <store>/dockerfiles.json    df-<12 hex> → the Dockerfile, its folder, the last build (reference, layers)

/// A catalogue tag's digest as the store last resolved it.
public struct BaseDigestRecord: Codable, Equatable, Sendable {
    public var digest: String?
    public var checkedAt: Date?
    public var failedAt: Date?
    public var lastError: String?

    public init(digest: String? = nil, checkedAt: Date? = nil, failedAt: Date? = nil, lastError: String? = nil) {
        self.digest = digest
        self.checkedAt = checkedAt
        self.failedAt = failedAt
        self.lastError = lastError
    }
}

public enum BaseDigests {
    public static func fileURL(_ store: DozerStore) -> URL { store.root.appendingPathComponent("base-digests.json") }

    public static func all(_ store: DozerStore) -> [String: BaseDigestRecord] {
        guard let d = try? Data(contentsOf: fileURL(store)) else { return [:] }
        return (try? HostWire.decoder.decode([String: BaseDigestRecord].self, from: d)) ?? [:]
    }

    static func update(_ base: String, _ store: DozerStore, _ f: (inout BaseDigestRecord) -> Void) {
        var a = all(store)
        var r = a[base] ?? BaseDigestRecord()
        f(&r)
        a[base] = r
        try? store.ensureDirectory()
        try? HostWire.prettyEncoder.encode(a).write(to: fileURL(store), options: .atomic)
    }

    /// The digest a preparation of `base` uses: the one resolved last, else the catalogue's pin.
    public static func digest(_ base: String, _ store: DozerStore) -> String? {
        guard let c = BaseCatalogue.base(base) else { return nil }
        return all(store)[base]?.digest ?? c.pinnedDigest
    }

    /// Ask the tag's registry for its digest (at most hourly — `force` asks now); never throws: a
    /// failure is recorded and the last digest (or the pin) is used.
    @discardableResult
    public static func refresh(_ base: String, store: DozerStore, registry: NpmRegistry, now: Date = Date(), force: Bool = false) async -> String? {
        guard let c = BaseCatalogue.base(base), let lookup = registry.digest else { return nil }
        let rec = all(store)[base]
        if !force {
            if let t = rec?.checkedAt, rec?.digest != nil, now.timeIntervalSince(t) < AgentVersions.maxAge { return nil }
            if let t = rec?.failedAt, now.timeIntervalSince(t) < AgentVersions.retryAfterFailure { return rec?.lastError }
        }
        do {
            let d = try await lookup(c.reference)
            update(base, store) { $0.digest = d; $0.checkedAt = now; $0.failedAt = nil; $0.lastError = nil }
            return nil
        } catch {
            let e = HostError.from(error).message
            update(base, store) { $0.failedAt = now; $0.lastError = e }
            return e
        }
    }
}

/// 596 (B5–B8): one Dockerfile a sandbox was made from, and its last build.
public struct DockerfileRecord: Codable, Equatable, Sendable {
    /// `df-<12 hex>` — `ImageChoice.dockerfileBase(path:)`.
    public var base: String
    /// The Dockerfile (absolute) and the build context (its folder).
    public var dockerfile: String
    public var context: String
    public var builtAt: Date?
    /// The built image in the store: `dozer.local/<base>@sha256:…`.
    public var reference: String?
    /// sha256 of the built image's layers (their digests, in order) — a rebuild whose layers are the
    /// same keeps the previous reference, so nothing is re-baked (B8).
    public var layers: String?
    /// sha256 of the Dockerfile's bytes at the last build ("Dockerfile changed — rebuild available").
    public var dockerfileSHA256: String?
    /// What the image's own ENV sets (sessions do not inherit an image's config), and its PATH
    /// entries ahead of `/usr/local/bin:/usr/bin:/bin`.
    public var environment: [String: String]?
    public var path: [String]?
    public var builds: Int?
    /// The `container` that built it.
    public var builtWith: String?

    public init(base: String, dockerfile: String, context: String) {
        self.base = base
        self.dockerfile = dockerfile
        self.context = context
    }

    /// The Dockerfile no longer has the bytes it was last built from (or cannot be read).
    public var changedSinceBuild: Bool {
        guard let built = dockerfileSHA256 else { return false }
        return Dockerfiles.sha256(of: URL(fileURLWithPath: dockerfile)) != built
    }
}

public enum Dockerfiles {
    public static func fileURL(_ store: DozerStore) -> URL { store.root.appendingPathComponent("dockerfiles.json") }

    public static func all(_ store: DozerStore) -> [String: DockerfileRecord] {
        guard let d = try? Data(contentsOf: fileURL(store)) else { return [:] }
        return (try? HostWire.decoder.decode([String: DockerfileRecord].self, from: d)) ?? [:]
    }

    public static func record(_ base: String, _ store: DozerStore) -> DockerfileRecord? { all(store)[base] }

    static func save(_ r: DockerfileRecord, _ store: DozerStore) throws {
        var a = all(store)
        a[r.base] = r
        try store.ensureDirectory()
        try HostWire.prettyEncoder.encode(a).write(to: fileURL(store), options: .atomic)
    }

    public static func sha256(of url: URL) -> String? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// A Dockerfile a person names (`--dockerfile`, doz_project.yaml, the UI): absolute or `~/`, an
    /// existing regular file at most 1 MiB, never inside the store. → (the file, its folder).
    public static func validate(_ path: String, store: DozerStore) throws -> (dockerfile: String, context: String) {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw HostError(.invalid, "the Dockerfile must be an absolute path (or ~/…): \(path)") }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw HostError(.notFound, "no Dockerfile at \(url.path)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= 1 << 20 else { throw HostError(.invalid, "\(url.path) is over 1 MiB — not a Dockerfile") }
        let storePath = store.root.resolvingSymlinksInPath().path
        guard !(url.path + "/").hasPrefix(storePath + "/") else { throw HostError(.invalid, "a Dockerfile inside Dozer's store is not used") }
        return (url.path, url.deletingLastPathComponent().path)
    }

    /// Register (or re-read) the Dockerfile at `path`: its base id, recorded once (a known one keeps
    /// its build).
    @discardableResult
    public static func register(_ path: String, store: DozerStore) throws -> DockerfileRecord {
        let (file, context) = try validate(path, store: store)
        let base = ImageChoice.dockerfileBase(path: file)
        if let r = record(base, store) { return r }
        let r = DockerfileRecord(base: base, dockerfile: file, context: context)
        try save(r, store)
        return r
    }

    /// B9, said plainly wherever a Dockerfile is chosen and whenever one is built.
    public static let outsidePolicyNote =
        "Dockerfile builds run in Apple's builder (container build), OUTSIDE Dozer's network policy: its RUN steps reach the internet directly, without Dozer's proxy or allow list. The sandbox made from the image is under the policy as usual."

    /// A reference no build has made yet (a sandbox created before its Dockerfile was first built —
    /// its first start builds it and takes the result).
    public static func placeholder(_ base: String) -> String { "dozer.local/\(base)@sha256:" + String(repeating: "0", count: 64) }
    public static func isPlaceholder(_ reference: String) -> Bool { reference.hasSuffix("@sha256:" + String(repeating: "0", count: 64)) }
}

extension DozerImages {
    /// 596: a base × agent pair's spec at `release` (nil for no agent): the base as the store resolved
    /// it (a catalogue tag's digest, else its pin; a Dockerfile's last build, else a placeholder the
    /// first start replaces), Claude Code's native build on a base without Node.
    public static func compose(_ choice: ImageChoice, release: AgentRelease?, store: DozerStore,
                               purpose: AgentVersions.Purpose = .prepare) throws -> ImageSpec {
        let src = try baseSource(choice.base, store: store)
        var native: NativeClaudeBuild?
        if choice.agent == .claudeCode, !src.hasNode, let r = release {
            native = AgentVersions.knownNative(r.version, store: store)
            if native == nil {
                throw HostError(.unavailable, "Claude Code \(r.version)'s native build (for a base without Node) is not known here yet — its checksums come from downloads.claude.ai: "
                                + "try again online, or set images.claude_code_version to \(NativeClaudeBuild.pinned.version) (built in)")
            }
        }
        do {
            return try ImageComposer.spec(name: choice.name, base: src, agent: choice.agent, release: release, native: native)
        } catch let e as SandboxError {
            throw HostError.from(e)
        }
    }

    /// What a base contributes, as the store knows it now.
    public static func baseSource(_ base: String, store: DozerStore) throws -> BaseSource {
        if let c = BaseCatalogue.base(base) { return c.source(digest: BaseDigests.digest(base, store)) }
        guard ImageChoice.isDockerfileBase(base) else { throw HostError(.notFound, "no base \(base) — doz base ls") }
        guard let r = Dockerfiles.record(base, store) else {
            throw HostError(.notFound, "no Dockerfile is known for \(base) — create a sandbox with --dockerfile PATH")
        }
        return BaseSource(reference: r.reference ?? Dockerfiles.placeholder(base), packageManager: .auto, hasNode: false, musl: nil,
                          rootfsMiB: 8192, environment: r.environment ?? [:], path: r.path ?? [])
    }

    /// 596: every name `doz create --image` takes that is a base × agent pair (canonical form).
    public static func canonicalName(_ image: String) -> String {
        ImageChoice.parse(image)?.name ?? image
    }

    /// Images a preparation makes: every catalogue base × agent, and a known Dockerfile's.
    public static func isPreparable(_ image: String, store: DozerStore) -> Bool {
        guard let c = ImageChoice.parse(image), c.name == image else { return false }
        return !c.isDockerfile || Dockerfiles.record(c.base, store) != nil
    }

    /// The images this store has anything of (bakes under images/), with the two Node agent images
    /// always — for `image ls`.
    public static func composedImagesInStore(_ store: DozerStore) -> [String] {
        let dir = store.root.appendingPathComponent("images")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var out = ["claude-code", "pi", "codex"]
        for n in names.sorted() where ImageChoice.parse(n)?.name == n && n != "lab" && !out.contains(n) { out.append(n) }
        return out
    }
}

/// 596: `doz base ls` / the UI's catalogue — one row per recommended base.
public struct BaseRow: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var useCase: String
    public var reference: String
    /// The digest a preparation uses now (resolved, or the pin) and whether it is the pin.
    public var digest: String
    public var pinned: Bool
    public var checkedAt: Date?
    public var downloadBytes: Int64
    public var prepareSeconds: Int
    public var packageManager: String
    /// The registries its sandboxes may reach (B4).
    public var registries: [String]
    /// Agents whose image of this base is prepared for this build.
    public var prepared: [String]
    /// A prepared image of this base was made from an older digest than the tag's now.
    public var updateAvailable: Bool?

    public static func rows(_ store: DozerStore, prepared check: (String) -> Bool) -> [BaseRow] {
        let digests = BaseDigests.all(store)
        let settings = DozerSettings.load()
        return BaseCatalogue.all.map { b in
            let rec = digests[b.id]
            let digest = rec?.digest ?? b.pinnedDigest
            let agents = AgentKind.allCases.filter { check(ImageChoice(base: b.id, agent: $0).name) }.map(\.rawValue)
            var r = BaseRow(id: b.id, title: b.title, useCase: b.useCase, reference: b.shortReference, digest: digest, pinned: rec?.digest == nil,
                            checkedAt: rec?.checkedAt, downloadBytes: b.downloadBytes, prepareSeconds: b.prepareSeconds,
                            packageManager: b.packageManager.rawValue, registries: b.registries.map(\.host), prepared: agents)
            let stale = AgentKind.allCases.contains { a in
                let name = ImageChoice(base: b.id, agent: a).name
                guard name != "lab", let p = AgentVersions.prepared(name, store: store, settings: settings).first else { return false }
                return !p.base.hasSuffix(digest)
            }
            r.updateAvailable = stale ? true : nil
            return r
        }
    }
}
