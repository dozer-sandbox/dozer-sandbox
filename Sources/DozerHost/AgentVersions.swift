import Foundation
import DozerKit

// 594 (owner, 2026-09-30: "if we pin a claude code build it is likely that the first-time experience
// will be that it needs to update which is not ideal. Can we install (optionally) "latest" claude code
// (default true)?"):
//
//   · `images.claude_code_version` / `images.pi_version`: `latest` (the default) or an exact version.
//   · `latest` is resolved at PREPARATION time, never at run time: one registry lookup
//     (`<registry>/<package>/latest` → version + sha512 integrity) whose answer is installed at that
//     exact version, integrity-checked in the bake. The version is in the image spec, so in the bake
//     key: an image is always one exact version, reproducible and cached.
//   · Freshness without waiting: the lookup is cached for an hour (<store>/agent-versions.json) and
//     offline-tolerant; a create uses the image ALREADY prepared (the newest for this build), and when
//     the registry has a newer one, a background preparation makes it for the next sandbox.
//   · Nothing resolved and nothing prepared, and the registry cannot be reached: a clear error that
//     names an exact version to set. An exact pin always works from what the store already has.

/// The npm registry, as far as Dozer asks it anything: one version document.
public struct NpmRegistry: Sendable {
    /// `package` at `tagOrVersion` (`latest`, or an exact version) → its version and integrity.
    public typealias Lookup = @Sendable (_ package: String, _ tagOrVersion: String) async throws -> AgentRelease
    public let lookup: Lookup?
    /// 596 (B2): Claude Code's native build at an exact version → its linux-arm64 checksums
    /// (downloads.claude.ai's manifest). nil: never asked.
    public typealias NativeLookup = @Sendable (_ version: String) async throws -> NativeClaudeBuild
    public let native: NativeLookup?
    /// 596 (B3): a catalogue base's tag → its current digest (the image's registry). nil: never asked
    /// (the catalogue's pin, or what the store resolved before).
    public typealias DigestLookup = @Sendable (_ reference: String) async throws -> String
    public let digest: DigestLookup?

    public init(lookup: Lookup?, native: NativeLookup? = nil, digest: DigestLookup? = nil) {
        self.lookup = lookup
        self.native = native
        self.digest = digest
    }

    /// No lookups at all (in-process hosts and tests): resolution uses only what the store has, then
    /// the built-in pin.
    public static let disabled = NpmRegistry(lookup: nil)

    /// 596: `<base>/<version>/manifest.json` over HTTPS (or a test server over http on loopback).
    public static func claudeDownloads(_ base: URL, timeout: TimeInterval = 10) -> NativeLookup {
        { version in
            guard AgentRelease(version: version, integrity: "sha512-A").isWellFormed,
                  let url = URL(string: base.absoluteString.hasSuffix("/") ? "\(base.absoluteString)\(version)/manifest.json" : "\(base.absoluteString)/\(version)/manifest.json") else {
                throw HostError(.invalid, "no Claude Code manifest URL for \(version)")
            }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw HostError(.failed, "downloads.claude.ai answered \((response as? HTTPURLResponse)?.statusCode ?? 0) for Claude Code \(version)'s manifest")
            }
            do { return try NativeClaudeBuild.parse(data, version: version) } catch { throw HostError(.failed, HostError.from(error).message) }
        }
    }
    public static let npmjs = URL(string: "https://registry.npmjs.org")!

    /// The registry over HTTPS (or a test server over http on loopback).
    /// At most `timeout` seconds (a create asks — it must not wait long on a network that is gone;
    /// offline usually fails at once, and a failure is not retried for 5 minutes).
    public static func http(_ base: URL, timeout: TimeInterval = 5) -> NpmRegistry {
        NpmRegistry { package, tag in
            let path = package.replacingOccurrences(of: "/", with: "%2F") + "/" + tag
            guard let url = URL(string: base.absoluteString.hasSuffix("/") ? base.absoluteString + path : base.absoluteString + "/" + path) else {
                throw HostError(.invalid, "no registry URL for \(package)")
            }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw HostError(.failed, "the npm registry answered \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(package)@\(tag)")
            }
            return try parse(data, package: package, tag: tag)
        }
    }

    /// A registry version document → the release; refuses anything malformed (the version and the
    /// integrity go into a bake script) or, for an exact version, a different one.
    public static func parse(_ data: Data, package: String, tag: String) throws -> AgentRelease {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = o["version"] as? String, let dist = o["dist"] as? [String: Any], let i = dist["integrity"] as? String else {
            throw HostError(.failed, "the npm registry's answer for \(package)@\(tag) has no version and integrity")
        }
        let r = AgentRelease(version: v, integrity: i)
        guard r.isWellFormed else { throw HostError(.failed, "the npm registry's answer for \(package)@\(tag) is not an exact version with a sha512 integrity") }
        if tag != "latest", v != tag { throw HostError(.failed, "the npm registry answered \(v) for \(package)@\(tag)") }
        return r
    }

    /// The real host's registry: `DOZ_TEST_NPM_REGISTRY` = `offline` (every lookup fails) or a URL
    /// (a stub server) — tests only; otherwise registry.npmjs.org.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> NpmRegistry {
        // 596: Claude Code's native manifests — `DOZ_TEST_CLAUDE_DOWNLOADS` = offline or a URL (tests only).
        let native: NativeLookup
        switch env["DOZ_TEST_CLAUDE_DOWNLOADS"] {
        case "offline": native = { v in throw HostError(.unavailable, "offline (DOZ_TEST_CLAUDE_DOWNLOADS): Claude Code \(v)'s manifest not looked up") }
        case let s? where !s.isEmpty && ["http", "https"].contains(URL(string: s)?.scheme ?? ""): native = claudeDownloads(URL(string: s)!)
        default: native = claudeDownloads(URL(string: NativeClaudeBuild.downloadBase)!)
        }
        // 596: base digests — `DOZ_TEST_BASE_REGISTRY` = offline (every lookup fails) or pinned (the
        // catalogue's pin is the answer — no network; tests only); otherwise the image's registry.
        let digest: DigestLookup
        switch env["DOZ_TEST_BASE_REGISTRY"] {
        case "offline": digest = { r in throw HostError(.unavailable, "offline (DOZ_TEST_BASE_REGISTRY): \(r) not resolved") }
        case "pinned":
            digest = { r in
                guard let b = BaseCatalogue.all.first(where: { $0.reference == r }) else { throw HostError(.notFound, "\(r) is not in the catalogue") }
                return b.pinnedDigest
            }
        default: digest = { r in try await RegistryDigest.resolve(r) }
        }
        switch env["DOZ_TEST_NPM_REGISTRY"] {
        case "offline":
            return NpmRegistry(lookup: { p, t in throw HostError(.unavailable, "offline (DOZ_TEST_NPM_REGISTRY): \(p)@\(t) not looked up") },
                               native: native, digest: digest)
        case let s? where !s.isEmpty:
            guard let u = URL(string: s), ["http", "https"].contains(u.scheme ?? "") else { return NpmRegistry(lookup: http(npmjs).lookup, native: native, digest: digest) }
            return NpmRegistry(lookup: http(u).lookup, native: native, digest: digest)
        default:
            return NpmRegistry(lookup: http(npmjs).lookup, native: native, digest: digest)
        }
    }
}

/// What the store knows of an agent's versions: the latest the registry said (and when), the exact
/// versions resolved before, the last failure. `<store>/agent-versions.json`.
public struct AgentVersionRecord: Codable, Equatable, Sendable {
    public var latest: AgentRelease?
    public var checkedAt: Date?
    /// When the last lookup failed, and why (offline, a registry error) — cleared by a success.
    public var failedAt: Date?
    public var lastError: String?
    public var known: [AgentRelease]
    /// 596 (Claude Code): the native builds' checksums resolved before (the newest 20).
    public var native: [NativeClaudeBuild]?

    public init(latest: AgentRelease? = nil, checkedAt: Date? = nil, failedAt: Date? = nil, lastError: String? = nil, known: [AgentRelease] = []) {
        self.latest = latest
        self.checkedAt = checkedAt
        self.failedAt = failedAt
        self.lastError = lastError
        self.known = known
    }

    mutating func remember(_ r: AgentRelease) {
        known.removeAll { $0.version == r.version }
        known.append(r)
        if known.count > 20 { known.removeFirst(known.count - 20) }
    }

    mutating func remember(_ b: NativeClaudeBuild) {
        var n = native ?? []
        n.removeAll { $0.version == b.version }
        n.append(b)
        if n.count > 20 { n.removeFirst(n.count - 20) }
        native = n
    }
}

public enum AgentVersions {
    /// How long a `latest` answer is trusted before the registry is asked again.
    public static let maxAge: TimeInterval = 3600
    /// After a failed lookup, how long before trying again (a create never waits on a dead network twice).
    public static let retryAfterFailure: TimeInterval = 300

    public static func fileURL(_ store: DozerStore) -> URL { store.root.appendingPathComponent("agent-versions.json") }

    public static func all(_ store: DozerStore) -> [String: AgentVersionRecord] {
        guard let d = try? Data(contentsOf: fileURL(store)) else { return [:] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([String: AgentVersionRecord].self, from: d)) ?? [:]
    }

    static func save(_ all: [String: AgentVersionRecord], _ store: DozerStore) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(all) else { return }
        try? d.write(to: fileURL(store), options: .atomic)
    }

    static func update(_ image: String, _ store: DozerStore, _ f: (inout AgentVersionRecord) -> Void) {
        var a = all(store)
        var r = a[image] ?? AgentVersionRecord()
        f(&r)
        a[image] = r
        save(a, store)
    }

    /// `latest` or an exact version (a malformed one is the setting's own error, reported by it).
    public static func setting(_ image: String, _ settings: DozerSettings) -> String {
        guard let k = SettingKey.agentVersion(image), let v = settings.string(k),
              v == "latest" || SettingType.isExactVersion(v) else { return "latest" }
        return v
    }

    // MARK: resolution (synchronous — only what the store has)

    /// The integrity an agent spec's install step checks.
    static func integrity(in spec: ImageSpec) -> String? {
        for s in spec.steps {
            guard let script = s.argv.last, let r = script.range(of: #"\[ "\$got" = '(sha512-[A-Za-z0-9+/=]+)' \]"#, options: .regularExpression) else { continue }
            let m = String(script[r])
            guard let a = m.range(of: "sha512-") else { continue }
            return String(m[a.lowerBound...].prefix { $0 != "'" })
        }
        return nil
    }

    /// An exact version this store can install without asking: the built-in pin, a version resolved
    /// before, or one a bake in the store recorded.
    public static func known(_ image: String, version: String, store: DozerStore) -> AgentRelease? {
        if let p = AgentImages.pinned(image), p.version == version { return p }
        if let r = all(store)[image]?.known.last(where: { $0.version == version }) { return r }
        if let r = all(store)[image]?.latest, r.version == version { return r }
        guard let proto = AgentImages.spec(image, release: AgentImages.pinned(image)!) else { return nil }
        for b in ImageBaker(storeRoot: store.root).all(proto) where b.manifest.imageSpec.agent?.version == version {
            if let i = integrity(in: b.manifest.imageSpec) { return AgentRelease(version: version, integrity: i) }
        }
        return nil
    }

    /// The kernel's and deckhold's sha256 this build bakes with (nil: the kernel is not cached yet).
    public static func buildHashes(_ store: DozerStore, _ settings: DozerSettings) -> (kernel: String, deckhold: String)? {
        let kernel = settings.string(SettingKey.kernelPath).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? KernelProvider(cacheDirectory: settings.string(SettingKey.kernelCache).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                              ?? store.layout("_").kernels).cachedKernel
        guard FileManager.default.fileExists(atPath: kernel.path), let deckhold = DeckholdBinary.locate(),
              let k = FileDigests.shared.sha256(kernel), let d = FileDigests.shared.sha256(deckhold) else { return nil }
        return (k, d)
    }

    /// The images of `image` prepared for THIS build — baked by THIS doz's recipe for their agent
    /// version (594 W28: an image baked by an older doz's recipe is not; it is `usable`), with this
    /// build's kernel and deckhold — newest version first.
    public static func prepared(_ image: String, store: DozerStore, settings: DozerSettings) -> [ImageSpec] {
        usable(image, store: store, settings: settings).filter(isCurrentRecipe)
    }

    /// 594 W28: every bake of `image` a sandbox can start from (its key is its own recipe's with this
    /// build's kernel and deckhold) — whichever doz's recipe made it — newest version first, then newest bake.
    /// 596: any base × agent image (its bakes live in images/<name>/; no agent: newest bake first).
    public static func usable(_ image: String, store: DozerStore, settings: DozerSettings) -> [ImageSpec] {
        guard let choice = ImageChoice.parse(image), choice.name == image, image != "lab",
              let (k, d) = buildHashes(store, settings) else { return [] }
        let proto = ImageSpec(name: image, base: "", steps: [], verify: [], user: "", home: "", persistDirs: [])
        return ImageBaker(storeRoot: store.root).all(proto)
            .filter { $0.manifest.key == $0.manifest.imageSpec.bakeKey(kernelSHA256: k, deckholdSHA256: d)
                && ($0.manifest.imageSpec.agent != nil) == (choice.agent != .none) }
            .sorted { a, b in
                let (x, y) = (a.manifest.imageSpec.agent?.version ?? "", b.manifest.imageSpec.agent?.version ?? "")
                return x != y ? AgentRelease.isNewer(x, than: y) : a.manifest.bakedAt > b.manifest.bakedAt
            }
            .map(\.manifest.imageSpec)
    }

    /// 594 W28: this doz's recipe for the agent release `spec` installs. 596: on the same base (a
    /// catalogue digest, or a Dockerfile's build) — `ImageComposer.recompose`.
    public static func currentRecipe(for spec: ImageSpec) -> ImageSpec? {
        ImageComposer.recompose(spec)
    }

    /// 594 W28: `spec` is exactly what THIS doz bakes for its agent release (not an older doz's recipe).
    public static func isCurrentRecipe(_ spec: ImageSpec) -> Bool { currentRecipe(for: spec) == spec }

    /// 594 W28: what THIS doz's recipe adds over `spec`'s ([] when it is this doz's).
    public static func recipeChanges(_ spec: ImageSpec) -> [String] {
        guard let now = currentRecipe(for: spec) else { return [] }
        return AgentImages.recipeChanges(from: spec, to: now)
    }

    /// 594 W28: an image's standing, for people — never a reason to rebuild by itself (owner ruling:
    /// "i dont think we should rebuild images without the user agreeing … better to warn").
    public struct Standing: Codable, Equatable, Sendable {
        /// The version a new sandbox gets now (nil: nothing baked).
        public var version: String?
        /// Baked by an older doz's recipe: what this doz's adds ("sudo", "package lists", …).
        public var olderRecipe: [String]?
        /// A newer agent release the settings want (latest from the hourly lookup, or an exact setting).
        public var available: String?

        /// "prepared by an older doz — this doz's image adds: sudo, package lists"
        public var olderRecipeLine: String? {
            olderRecipe.map { $0 == ["its recipe changed"] ? "prepared by an older doz — its recipe changed" : "prepared by an older doz — this doz's image adds: \($0.joined(separator: ", "))" }
        }
    }

    public static func standing(_ image: String, store: DozerStore, settings: DozerSettings) -> Standing {
        // 596: any base × agent image (no agent: only its recipe can be older).
        guard let choice = ImageChoice.parse(image), choice.name == image, image != "lab" else { return Standing() }
        let chosen = (try? spec(image, purpose: .create, store: store, settings: settings)) ?? nil
        let baked = chosen.flatMap { c in usable(image, store: store, settings: settings).first { $0 == c } }
        var s = Standing(version: baked?.agent?.version)
        if let b = baked, !isCurrentRecipe(b) { s.olderRecipe = recipeChanges(b) }
        if let v = s.version {
            let agent = choice.agent.rawValue
            let want = setting(agent, settings)
            if want == "latest", let l = all(store)[agent]?.latest?.version, AgentRelease.isNewer(l, than: v) { s.available = l }
            if want != "latest", want != v { s.available = want }
        }
        return s
    }

    public enum Purpose: Sendable { case create, prepare }

    /// The spec of `image` a create gets (the image ALREADY prepared — the newest for this build — so
    /// nobody waits) or a preparation makes (the version the setting names: latest as resolved, or the
    /// exact one). Only what the store has; `refresh` (async) is what asks the registry.
    /// 596: any base × agent image — the agent's version as before (the settings are per AGENT), the
    /// base as resolved (`BaseDigests`, else the catalogue's pin; a Dockerfile: its last build).
    public static func spec(_ image: String, purpose: Purpose, store: DozerStore, settings: DozerSettings) throws -> ImageSpec? {
        guard let choice = ImageChoice.parse(image), choice.name == image, image != "lab" else { return nil }
        guard choice.agent != .none else {
            if purpose == .create, let p = prepared(image, store: store, settings: settings).first { return p }
            return try DozerImages.compose(choice, release: nil, store: store, purpose: purpose)
        }
        let agent = choice.agent.rawValue
        let pin = AgentImages.pinned(agent)!
        let want = setting(agent, settings)
        let key = SettingKey.agentVersion(agent)!
        func make(_ r: AgentRelease) throws -> ImageSpec { try DozerImages.compose(choice, release: r, store: store, purpose: purpose) }
        if want != "latest" {
            if purpose == .create, let p = prepared(image, store: store, settings: settings).first(where: { $0.agent?.version == want }) { return p }
            // 594 W28: an older doz's image of that version is USED (never rebuilt without asking) — said as stale.
            if purpose == .create, let p = usable(image, store: store, settings: settings).first(where: { $0.agent?.version == want }) { return p }
            guard let r = known(agent, version: want, store: store) else {
                throw HostError(.unavailable, "\(agent) \(want) (\(key)) is not known here yet and the npm registry could not be asked — "
                                + "try again online, or set \(key) to a version this store has (\(pin.version) is built in)")
            }
            return try make(r)
        }
        if purpose == .create, let p = prepared(image, store: store, settings: settings).first { return p }
        if purpose == .create, let p = usable(image, store: store, settings: settings).first { return p }
        let rec = all(store)[agent]
        if let latest = rec?.latest { return try make(latest) }
        if let e = rec?.lastError {
            throw HostError(.unavailable, "\(agent): \(key) is latest, but the npm registry could not be reached (\(e)) and no \(image) image is prepared — "
                            + "try again online, or set an exact version: doz config set \(key) \(pin.version)")
        }
        // Never asked (an in-process host, a test): the built-in pin.
        return try make(pin)
    }

    /// 596: Claude Code's native build at `version`, as far as this store knows it (the pin, or one
    /// resolved before).
    public static func knownNative(_ version: String, store: DozerStore) -> NativeClaudeBuild? {
        if NativeClaudeBuild.pinned.version == version { return NativeClaudeBuild.pinned }
        return all(store)["claude-code"]?.native?.last { $0.version == version }
    }

    // MARK: freshness (asynchronous — the registry, at most once an hour)

    public struct Freshness: Codable, Equatable, Sendable {
        public var image: String
        /// `latest` or the exact version the setting names.
        public var setting: String
        /// The registry's latest, as last known (nil: never resolved).
        public var latest: String?
        public var checkedAt: Date?
        /// The last lookup failed (and why): the existing image is used.
        public var error: String?
        /// The registry was asked just now (not the hour-long cache).
        public var looked: Bool
        /// 596: Claude Code's native manifest could not be read (the Node images do not need it).
        public var nativeError: String? = nil
    }

    /// Ask the registry for `image`'s latest when the setting is `latest` and the last answer is older
    /// than an hour (or `force`); for an exact version not known here, ask for that version. Never
    /// throws: a failure is recorded (and returned) and the store's images are used.
    @discardableResult
    public static func refresh(_ image: String, store: DozerStore, settings: DozerSettings, registry: NpmRegistry,
                               now: Date = Date(), force: Bool = false) async -> Freshness {
        var f = await refreshPackage(image, store: store, settings: settings, registry: registry, now: now, force: force)
        // 596 (B2): Claude Code's native build at the version a preparation would make — its checksums,
        // once per version (a base without Node installs it; the Node images never ask).
        if image == "claude-code", let lookup = registry.native {
            let want = setting(image, settings)
            let target = want == "latest" ? all(store)[image]?.latest?.version : want
            if let v = target, knownNative(v, store: store) == nil {
                do {
                    let b = try await lookup(v)
                    update(image, store) { $0.remember(b) }
                } catch {
                    f.nativeError = HostError.from(error).message
                }
            }
        }
        return f
    }

    static func refreshPackage(_ image: String, store: DozerStore, settings: DozerSettings, registry: NpmRegistry,
                               now: Date, force: Bool) async -> Freshness {
        let want = setting(image, settings)
        let rec = all(store)[image]
        var f = Freshness(image: image, setting: want, latest: rec?.latest?.version, checkedAt: rec?.checkedAt, error: nil, looked: false)
        guard let package = AgentImages.package(image), let npm = registry.lookup else { return f }
        // 599i: Codex is installed from its linux-arm64 platform package — its release is the version of
        // `@openai/codex` and the integrity of `@openai/codex@<version>-linux-arm64` (the tarball a bake downloads).
        let lookup: NpmRegistry.Lookup
        if image == "codex" {
            lookup = { p, tag in
                var v = tag
                if tag == "latest" { v = try await npm(p, "latest").version }
                let platform = try await npm(p, AgentImages.codexPlatformVersion(v))
                return AgentRelease(version: v, integrity: platform.integrity)
            }
        } else {
            lookup = npm
        }
        if want != "latest" {
            guard known(image, version: want, store: store) == nil else { return f }
            do {
                let r = try await lookup(package, want)
                update(image, store) { $0.remember(r) }
                f.looked = true
            } catch {
                f.error = HostError.from(error).message
                update(image, store) { $0.failedAt = now; $0.lastError = f.error }
            }
            return f
        }
        if !force {
            if let c = rec?.checkedAt, rec?.latest != nil, now.timeIntervalSince(c) < maxAge { return f }
            if let failed = rec?.failedAt, now.timeIntervalSince(failed) < retryAfterFailure, rec?.latest != nil || rec?.lastError != nil {
                f.error = rec?.lastError
                return f
            }
        }
        do {
            let r = try await lookup(package, "latest")
            update(image, store) { $0.latest = r; $0.checkedAt = now; $0.failedAt = nil; $0.lastError = nil; $0.remember(r) }
            f.latest = r.version
            f.checkedAt = now
            f.looked = true
        } catch {
            f.error = HostError.from(error).message
            update(image, store) { $0.failedAt = now; $0.lastError = f.error }
            f.looked = true
        }
        return f
    }

    /// The prepared version that a create uses now, and the version a preparation would make — the
    /// image is BEHIND when both are known and differ (a preparation brings it up to date).
    public static func behind(_ image: String, store: DozerStore, settings: DozerSettings) -> (current: String, target: String)? {
        guard let current = (prepared(image, store: store, settings: settings).first ?? usable(image, store: store, settings: settings).first)?.agent?.version,
              let target = (try? spec(image, purpose: .prepare, store: store, settings: settings))??.agent?.version,
              target != current else { return nil }
        // An exact setting that is not the prepared one, or a newer latest.
        return setting(agentOf(image), settings) == "latest" && !AgentRelease.isNewer(target, than: current) ? nil : (current, target)
    }

    /// 596: the agent whose version settings an image follows (`python-claude-code` → `claude-code`).
    public static func agentOf(_ image: String) -> String {
        ImageChoice.parse(image).map(\.agent.rawValue) ?? image
    }
}
