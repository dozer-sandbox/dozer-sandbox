import ContainerizationEXT4
import CryptoKit
import Foundation

/// How to build a baked root disk: a digest-pinned OCI base (read once, flattened to ext4 — no
/// layers kept, no Dockerfile, no BuildKit), install steps run INSIDE a VM booted from it, and a
/// credential-free verification. The result is a read-only disk every sandbox APFS-clones as its
/// root. Library-native: it knows nothing of any host app's imageSpec format.
public struct ImageSpec: Sendable, Codable, Equatable {
    /// `[a-z0-9-]`, the cache directory name.
    public var name: String
    /// The OCI base, WITH a digest (`repo@sha256:…`), so the flattened disk is reproducible.
    public var base: String
    /// Run in order, as root unless a step says otherwise.
    public var steps: [BakeStep]
    /// Credential-free checks run as `user` after the steps; every one must exit 0, and its output
    /// must contain `expect` when set. The output is recorded in the manifest.
    public var verify: [VerifyCheck]
    /// The account agent sessions run as (created by a step), and its home.
    public var user: String
    public var home: String
    /// Directories (under `home` or absolute) kept on the sandbox's STATE disk, so they survive
    /// Stop → Start and a re-bake of the image.
    public var persistDirs: [String]
    /// Environment every session of this image gets (e.g. PATH, CLAUDE_CONFIG_DIR).
    public var sessionEnvironment: [String: String]
    /// Where sessions start (the workspace share).
    public var workdir: String
    /// Capacity of the baked disk (apparent size; APFS only allocates what is written).
    public var rootfsMiB: UInt64
    /// 587: the ext4 journal of the baked disk (and of every sandbox's state disk), MiB. Default 16
    /// (586: the smallest size, the fastest for `fsync`, and it removes e2fsck from the discard →
    /// cold boot path). nil: no journal — a disk not cleanly unmounted is e2fsck'd before it boots,
    /// as before 587. Part of the base key and the bake key. A record written before 587 has no
    /// value here, and decodes as nil: its disks have no journal.
    public var journalMiB: Int?
    /// 594: the agent this image installs, at the exact version (the npm package and version; its
    /// integrity is in the install step). nil for an image with no agent. Part of the bake key.
    public var agent: AgentPackage?
    /// 596: hosts a bake of this spec reaches beyond the bake preset's package registries (HTTPS):
    /// `downloads.claude.ai` for Claude Code's native build, `nodejs.org` for pi's Node. nil (every
    /// spec before 596, and the two Node agent images): none — and then absent from the canonical
    /// JSON, so their bake keys are unchanged. Part of the bake key (a different reach is a
    /// different recipe).
    public var bakeHosts: [String]?

    public init(name: String, base: String, steps: [BakeStep], verify: [VerifyCheck], user: String, home: String,
                persistDirs: [String], sessionEnvironment: [String: String] = [:], workdir: String = "/workspace",
                rootfsMiB: UInt64 = 4096, journalMiB: Int? = 16) {
        self.name = name
        self.base = base
        self.steps = steps
        self.verify = verify
        self.user = user
        self.home = home
        self.persistDirs = persistDirs
        self.sessionEnvironment = sessionEnvironment
        self.workdir = workdir
        self.rootfsMiB = rootfsMiB
        self.journalMiB = journalMiB
    }

    /// ImageSpec names the store keeps for itself under `<store>/images/`.
    public static let reservedNames: Set<String> = ["bases", "custom"]

    public func validate() throws {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard (1...40).contains(name.count), name.allSatisfy(allowed.contains) else {
            throw SandboxError.invalidSpec("image name must be 1–40 characters of [a-z0-9-], got \"\(name)\"")
        }
        guard !Self.reservedNames.contains(name) else {
            throw SandboxError.invalidSpec("image name \"\(name)\" is reserved (images/\(name)/ is the store's own)")
        }
        if let j = journalMiB {
            guard (4...1024).contains(j) else { throw SandboxError.invalidSpec("journalMiB must be 4–1024 (or nil for none), got \(j)") }
            guard UInt64(j) * 8 <= rootfsMiB else { throw SandboxError.invalidSpec("journalMiB \(j) is too large for a \(rootfsMiB) MiB disk") }
        }
        guard base.contains("@sha256:") else { throw SandboxError.invalidSpec("image base must be digest-pinned (…@sha256:…): \(base)") }
        guard !user.isEmpty, home.hasPrefix("/"), workdir.hasPrefix("/") else { throw SandboxError.invalidSpec("image user/home/workdir") }
        for d in persistDirs where !(d.hasPrefix("/") || d.hasPrefix("~/")) || d.contains("'") {
            throw SandboxError.invalidSpec("persist dir must be absolute or ~/…, quote-free: \(d)")
        }
        if let a = agent {
            guard AgentRelease(version: a.version, integrity: "sha512-A").isWellFormed,
                  a.package.range(of: #"^(@[a-z0-9-]+/)?[a-z0-9._-]+$"#, options: .regularExpression) != nil else {
                throw SandboxError.invalidSpec("agent package/version: \(a.package)@\(a.version)")
            }
        }
        for h in bakeHosts ?? [] where h.range(of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#, options: .regularExpression) == nil {
            throw SandboxError.invalidSpec("bake host must be an exact host name: \(h)")
        }
        for k in (steps.flatMap { $0.environment.keys }) + Array(sessionEnvironment.keys) where BakeEnvironment.isCredential(k) {
            throw SandboxError.invalidSpec("credential \(k) must never be part of an image spec — pass it to openSession")
        }
    }

    /// `persistDirs` as absolute guest paths.
    public var resolvedPersistDirs: [String] {
        persistDirs.map { $0.hasPrefix("~/") ? home + "/" + $0.dropFirst(2) : $0 }
    }

    /// Canonical JSON (sorted keys) — the bake key's input, so reordering a dictionary never
    /// changes the key but changing any value does.
    public var canonicalJSON: Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)) ?? Data()
    }

    /// sha256(canonical imageSpec + kernel sha256 + deckhold sha256 + the lineage format). The imageSpec
    /// carries `journalMiB`; the lineage format (587: baked on a clone of a base disk, trimmed at
    /// the end) is in every key, so a pre-587 store re-bakes each image once.
    public func bakeKey(kernelSHA256: String, deckholdSHA256: String) -> String {
        var h = SHA256()
        h.update(data: canonicalJSON)
        h.update(data: Data("\nkernel:\(kernelSHA256)\ndeckhold:\(deckholdSHA256)".utf8))
        h.update(data: Data("\nlineage:\(ImageBaker.lineageFormat)".utf8))
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 587: the key of the base disk this imageSpec's bakes clone — the base's OCI digest, the
    /// capacity, the journal size and the formatter version. ImageSpecs that agree on all four share
    /// one base disk (the two agent imageSpecs do).
    public var baseKey: String {
        let digest = base.split(separator: "@").last.map(String.init) ?? base
        let material = "doz-base|\(digest)|capacity:\(rootfsMiB)MiB|journal:\(journalMiB.map { "\($0)MiB" } ?? "none")|formatter:\(ImageBaker.formatterVersion)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The journal as Containerization's formatter takes it.
    var journalConfig: EXT4.JournalConfig? { Self.journalConfig(journalMiB) }

    static func journalConfig(_ mib: Int?) -> EXT4.JournalConfig? {
        mib.map { EXT4.JournalConfig(size: UInt64($0) * 1_048_576, defaultMode: .ordered) }
    }
}

/// One command an image bake runs inside the VM, in order (`ImageSpec.steps`).
public struct BakeStep: Sendable, Codable, Equatable {
    public var name: String
    public var argv: [String]
    public var environment: [String: String]
    /// nil = root.
    public var user: String?
    public var needsNetwork: Bool
    public var timeoutSeconds: Int64

    public init(_ name: String, argv: [String], environment: [String: String] = [:], user: String? = nil,
                needsNetwork: Bool = true, timeoutSeconds: Int64 = 900) {
        self.name = name
        self.argv = argv
        self.environment = environment
        self.user = user
        self.needsNetwork = needsNetwork
        self.timeoutSeconds = timeoutSeconds
    }

    /// A bash script step (bake steps are not sessions, so a shell is fine here).
    public static func script(_ name: String, _ script: String, environment: [String: String] = [:], user: String? = nil,
                              timeoutSeconds: Int64 = 900) -> BakeStep {
        BakeStep(name, argv: ["bash", "-euo", "pipefail", "-c", script], environment: environment, user: user,
                 timeoutSeconds: timeoutSeconds)
    }
}

/// A credential-free command a bake runs after its steps, to confirm the result (`ImageSpec.verify`).
public struct VerifyCheck: Sendable, Codable, Equatable {
    public var argv: [String]
    public var expect: String?
    public init(_ argv: [String], expect: String? = nil) {
        self.argv = argv
        self.expect = expect
    }
}

/// The bake environment is built from the imageSpec alone and SCRUBBED: nothing that looks like a
/// credential ever reaches a bake (and so never a baked disk).
public enum BakeEnvironment {
    public static func isCredential(_ key: String) -> Bool {
        let k = key.uppercased()
        return k.hasSuffix("_API_KEY") || k.hasSuffix("_TOKEN") || k.hasSuffix("_SECRET") || k.contains("PASSWORD")
            || k == "ANTHROPIC_API_KEY" || k == "ANTHROPIC_AUTH_TOKEN"
    }

    public static func scrubbed(_ env: [String: String]) -> [String: String] { env.filter { !isCredential($0.key) } }
}

// MARK: - The two agent imageSpecs

/// 594: one provider's credentials an agent can use: the kinds of account (`mac`, `setup-token`,
/// `api-key` for Anthropic).
public struct AgentCredentialSupport: Sendable, Codable, Equatable, Hashable {
    public var provider: String
    public var accountKinds: [String]
    public init(provider: String, accountKinds: [String]) {
        self.provider = provider
        self.accountKinds = accountKinds
    }
}

/// 594: an agent's npm package at one exact version.
public struct AgentPackage: Sendable, Codable, Equatable, Hashable {
    public var package: String
    public var version: String
    /// 617: a recipe agent's sha512 integrity (what its install step checks), so `recompose` reads its release from
    /// data. nil for the three built-in agents — and then ABSENT from the canonical JSON, so their bake keys are
    /// unchanged (RecipePinTests).
    public var integrity: String?
    public init(package: String, version: String, integrity: String? = nil) {
        self.package = package
        self.version = version
        self.integrity = integrity
    }
}

/// 594: one published version of an agent: its version and the registry's sha512 integrity for its
/// tarball (`sha512-…`, as npm's `dist.integrity`).
public struct AgentRelease: Sendable, Codable, Equatable, Hashable {
    public var version: String
    public var integrity: String
    public init(version: String, integrity: String) {
        self.version = version
        self.integrity = integrity
    }

    /// Safe to put in a bake script: an exact version (`1.2.3`, `-pre`, `+build`) and a sha512 SRI
    /// integrity — nothing a registry answer could use to break out of the script's quotes.
    public var isWellFormed: Bool {
        version.count <= 64 && integrity.count <= 200
            // 617: a PyPI release may have two parts (llm 0.36).
            && version.range(of: #"^\d+\.\d+(\.\d+)?([-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil
            && integrity.range(of: #"^sha512-[A-Za-z0-9+/]+={0,2}$"#, options: .regularExpression) != nil
    }

    /// Numeric `major.minor.patch` order; a pre-release sorts before its release.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> ([Int], String?) {
            let core = v.split(separator: "+").first.map(String.init) ?? v
            let pre = core.split(separator: "-", maxSplits: 1)
            let nums = pre[0].split(separator: ".").map { Int($0) ?? 0 }
            return (nums, pre.count > 1 ? String(pre[1]) : nil)
        }
        let (x, xp) = parts(a), (y, yp) = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        switch (xp, yp) {
        case (nil, .some): return true
        case (.some(let p), .some(let q)): return p > q
        default: return false
        }
    }
}

/// Pinned values copied (by hand, values only) from the DeckStack official imageSpecs
/// `claude-code` 2.1.227 and `pi-coding-agent` 0.84.1 — no code or type is shared with them.
/// 594: these are the DEFAULT pins; `images.claude_code_version` / `images.pi_version` = latest (the
/// default setting) prepares the registry's latest instead, at its exact version and integrity.
public enum AgentImages {
    public static let claudeCodePackage = "@anthropic-ai/claude-code"
    public static let piPackage = "@earendil-works/pi-coding-agent"
    public static let claudeCodePinned = AgentRelease(version: "2.1.227",
        integrity: "sha512-D0YP8GFwPaP/9eObEuP5LRO5+9QSD9CLa6K26whNzXxpxz3pFqPS3nn7l1/MLmSWy32wBP2IKQzkRB3mumUKUQ==")
    public static let piPinned = AgentRelease(version: "0.84.1",
        integrity: "sha512-ncAqFrG+iybuPGOhMiZoEHkEzTpJgz3guYD32pD+M7ucc0WeHmauP6wa7qwP8V/KWvsZDVNa5XGsdZ7fkC7w7A==")

    /// 594 (owner: "creating a Pi sandbox should have pre-requisites for things like API key"): the
    /// credentials each agent can use, per provider — the kinds of Dozer account (`mac` = this Mac's
    /// Claude login, `setup-token`, `api-key`). Claude Code: any Anthropic account. pi: an Anthropic
    /// API key only (it reads ANTHROPIC_API_KEY — the proxy's placeholder); a Claude subscription is
    /// never given to it. Other providers can be added per agent later. nil: no agent (the lab).
    /// 596: by the image's AGENT, whatever its base (`python-pi` is pi's).
    /// 617: from the agent's recipe (Claude Code: any Anthropic account; pi: an Anthropic API key only; Codex: an OpenAI
    /// account — this Mac's Codex login first, the least setup; Gemini CLI / Grok Build: a key of their provider).
    public static func credentials(_ image: String) -> [AgentCredentialSupport]? {
        guard let r = ImageChoice.parse(image)?.agent.recipe else { return nil }
        return r.credentials.map { AgentCredentialSupport(provider: $0.provider, accountKinds: $0.accounts) }
    }

    /// The agent's name as a person reads it (596: any image of that agent).
    public static func agentName(_ image: String) -> String? {
        ImageChoice.parse(image)?.agent.recipe?.title
    }

    /// The npm package of an agent image (nil: not an agent image). By the agent's own name only (`codex`, `gemini`).
    public static func package(_ image: String) -> String? {
        AgentRecipes.recipe(image)?.install.package
    }
    /// The release an agent's recipe pins (the built-in three: the constants below, which their recipes repeat).
    public static func pinned(_ image: String) -> AgentRelease? {
        switch image {
        case "claude-code": claudeCodePinned
        case "pi": piPinned
        case "codex": codexPinned
        default: AgentRecipes.recipe(image)?.pinnedRelease
        }
    }
    /// The agent image's spec at `release` (617: a recipe agent's on its default base).
    public static func spec(_ image: String, release: AgentRelease) -> ImageSpec? {
        switch image {
        case "claude-code": return claudeCode(release)
        case "pi": return pi(release)
        case "codex": return try? ImageComposer.spec(name: "codex", base: BaseCatalogue.base("node")!.source(), agent: .codex, release: release, native: nil)
        default:
            guard let r = AgentRecipes.recipe(image), !r.isBuiltin, let a = AgentKind(rawValue: r.id), let b = BaseCatalogue.base(r.defaultBase) else { return nil }
            return try? ImageComposer.spec(name: r.id, base: b.source(), agent: a, release: release, native: nil)
        }
    }

    // MARK: 617 — an agent from its recipe

    /// A recipe agent's install steps on `base`, and the hosts its bake reaches beyond the registries.
    static func recipeInstall(_ r: AgentRecipe, _ release: AgentRelease, base: BaseSource) -> (steps: [BakeStep], bakeHosts: [String]) {
        var steps: [BakeStep] = []
        var hosts: [String] = []
        // A Dockerfile's base: its libc is known only in the bake.
        if base.musl == nil, !r.platforms.musl {
            steps.append(BakeStep.script("check \(r.title) can run here (glibc)", """
                if [ -e /lib/ld-musl-aarch64.so.1 ]; then echo "doz: \(r.muslRefusal)" >&2; exit 1; fi
                echo glibc
                """, needsNetworkFalse: ()))
        }
        switch r.install.kind {
        case "npm":
            var install = npmInstall(r.install.package!, version: release.version, integrity: release.integrity, extraArgs: r.install.npmArgs ?? [])
            if let n = r.install.needsNode.flatMap(Int.init), n > NodeRuntime.major {
                // 617: a newer Node than the bases' (OpenClaw: ≥ 24) — Dozer's Node 24 under /opt/node, on any glibc base.
                steps.append(ImageComposer.node24Runtime(for: r.title))
                install.environment["PATH"] = "/opt/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                steps.append(install)
                steps.append(ImageComposer.nodeWrapper(r.install.binary))
                hosts.append("nodejs.org")
            } else if base.hasNode {
                steps.append(install)
            } else {
                steps.append(ImageComposer.nodeRuntime(base.packageManager, for: r.title))
                install.environment["PATH"] = "/opt/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                steps.append(install)
                steps.append(ImageComposer.nodeWrapper(r.install.binary))
                if base.packageManager != .apk { hosts.append("nodejs.org") }
            }
        case "manifest-binary":
            steps.append(manifestBinaryInstall(r, release))
        case "pypi":
            steps.append(pythonRuntime(for: r.title))
            steps.append(pypiInstall(r, release))
            hosts += PythonRuntime.bakeHosts + ["pypi.org", "files.pythonhosted.org"]
        case "release-binary":
            steps.append(releaseBinaryInstall(r, release))
        default:            // npm-platform-binary (validated)
            steps.append(platformBinaryInstall(r, release, base: base))
        }
        // 617.11: the file sets it needs beside its program (Fabric's patterns), each sha256-checked here.
        for e in r.install.extras ?? [] {
            steps.append(extraInstall(r, e, release))
            if let h = URL(string: e.url)?.host, !hosts.contains(h) { hosts.append(h) }
        }
        return (steps, hosts)
    }

    /// 617.11: one folder of a pinned archive (`{version}` = the release), unpacked to `to` (under /opt/<id>), root's,
    /// read-only to the agent. A recipe without extras never reaches this (its bake key is unchanged).
    static func extraInstall(_ r: AgentRecipe, _ e: AgentRecipe.Install.Extra, _ release: AgentRelease) -> BakeStep {
        let v = release.version.split(separator: "+").first.map(String.init) ?? release.version
        let url = e.url.replacingOccurrences(of: "{version}", with: v), path = e.path.replacingOccurrences(of: "{version}", with: v)
        let depth = path.split(separator: "/").count
        // Every recipe string is in single quotes (a quote in it closed and escaped): nothing in it is run.
        let quoted = { (x: String) in "'" + x.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return BakeStep.script("install \(r.title)'s \(e.what) (\(v), checksum-verified)", """
            label=\(quoted(r.title + "'s " + e.what))
            cd "$(mktemp -d)"
            curl -fsSL --retry 3 -o extra.tar.gz \(quoted(url))
            got=$(sha256sum extra.tar.gz | cut -d' ' -f1)
            [ "$got" = \(quoted(e.sha256)) ] || { echo "checksum mismatch for $label: $got" >&2; exit 1; }
            rm -rf '\(e.to)'
            mkdir -p '\(e.to)'
            tar -xzf extra.tar.gz -C '\(e.to)' --strip-components=\(depth) --no-same-owner \(quoted(path))
            rm -f extra.tar.gz
            chown -R root:root '\(e.to)'
            chmod -R a+rX,go-w '\(e.to)'
            echo "$label: $(find '\(e.to)' -type f | wc -l) files in \(e.to)"
            """)
    }

    /// 617: the archive a manifest-binary release is (its url with `{build}` = `<version>-<build>`).
    public static func manifestArchiveURL(_ r: AgentRecipe, _ release: AgentRelease) -> String? {
        guard let u = r.install.url, release.version.contains("+") else { return nil }
        return u.replacingOccurrences(of: "{build}", with: release.version.replacingOccurrences(of: "+", with: "-"))
    }

    /// 617: an agent's program from its vendor's own release archive (Antigravity CLI: a tar.gz on Google's storage),
    /// its sha512 checked against the release's integrity (read from the vendor's manifest on the Mac — in the script, so
    /// in the bake key), installed under /opt/<id> and linked as /usr/local/bin/<binary>.
    static func manifestBinaryInstall(_ r: AgentRecipe, _ release: AgentRelease) -> BakeStep {
        let bin = r.install.binary, payload = r.install.payload!, dest = "/opt/\(r.id)/\(bin)"
        let url = manifestArchiveURL(r, release) ?? ""
        return BakeStep.script("install \(r.title) \(release.version) (linux-arm64, integrity-pinned)", """
            cd "$(mktemp -d)"
            curl -fsSL --retry 3 -o pkg.tgz '\(url)'
            got="sha512-$(python3 -c 'h=__import__("hashlib").sha512(open(__import__("sys").argv[1],"rb").read()).digest(); print(__import__("base64").b64encode(h).decode(), end="")' pkg.tgz)"
            [ "$got" = '\(release.integrity)' ] || { echo "integrity mismatch for \(r.title) \(release.version): $got" >&2; exit 1; }
            mkdir x && tar -xzf pkg.tgz -C x
            src=x/\(payload)
            test -f "$src"
            rm -rf /opt/\(r.id)
            mkdir -p /opt/\(r.id)
            cp "$src" \(dest)
            chmod 0755 \(dest)
            chown -R root:root /opt/\(r.id)
            ln -sf \(dest) /usr/local/bin/\(bin)
            rm -rf x pkg.tgz
            echo "\(r.title) \(release.version) (linux-arm64) installed under /opt/\(r.id), sha256 $(sha256sum \(dest) | cut -d' ' -f1)"
            """)
    }

    /// 617: the sha512 check every pinned download gets, in npm's integrity form (python3 — the dev baseline has it).
    static func sha512Check(_ file: String, _ integrity: String, what: String) -> String {
        """
        got="sha512-$(python3 -c 'h=__import__("hashlib").sha512(open(__import__("sys").argv[1],"rb").read()).digest(); print(__import__("base64").b64encode(h).decode(), end="")' "\(file)")"
        [ "$got" = '\(integrity)' ] || { echo "integrity mismatch for \(what): $got" >&2; exit 1; }
        """
    }

    /// 617: Dozer's pinned Python (`PythonRuntime`) under /opt/python, for a pypi recipe's venv.
    static func pythonRuntime(for agent: String) -> BakeStep {
        BakeStep.script("install Python \(PythonRuntime.version) for \(agent) (/opt/python, checksum-verified)", """
            cd "$(mktemp -d)"
            curl -fsSL --retry 3 -o python.tar.gz '\(PythonRuntime.url)'
            got=$(sha256sum python.tar.gz | cut -d' ' -f1)
            [ "$got" = '\(PythonRuntime.sha256)' ] || { echo "checksum mismatch for Python \(PythonRuntime.version): $got" >&2; exit 1; }
            rm -rf /opt/python
            mkdir -p /opt/python && tar -xzf python.tar.gz -C /opt/python --strip-components=1 --no-same-owner
            rm -f python.tar.gz
            chown -R root:root /opt/python
            /opt/python/bin/python3 --version
            """)
    }

    /// 617: a Python tool from PyPI — every distribution in the recipe's requirements, hash-checked by pip
    /// (`--require-hashes`, nothing else installed: `--no-deps`), the package's own file also against the sha512
    /// integrity; in its own venv (/opt/<id>/venv) on Dozer's Python, the program linked as /usr/local/bin/<binary>.
    static func pypiInstall(_ r: AgentRecipe, _ release: AgentRelease) -> BakeStep {
        let venv = "/opt/\(r.id)/venv", bin = r.install.binary
        let main = AgentRecipe.Install.wheelName(r.install.package ?? r.id) + "-" + release.version
        let pip = "\(venv)/bin/pip --disable-pip-version-check --no-input"
        return BakeStep.script("install \(r.title) \(release.version) (PyPI, every distribution hash-pinned)", """
            cd "$(mktemp -d)"
            cat > requirements.txt <<'REQ'
            \((r.install.requirements ?? []).joined(separator: "\n"))
            REQ
            rm -rf /opt/\(r.id)
            mkdir -p /opt/\(r.id)
            /opt/python/bin/python3 -m venv \(venv)
            \(pip) download --no-deps --require-hashes -d dist -r requirements.txt
            main=$(ls dist | grep -i '^\(main)[-.]' | head -n 1)
            test -n "$main"
            \(sha512Check("dist/$main", release.integrity, what: "\(r.install.package ?? r.id) \(release.version)"))
            \(pip) install --no-index --find-links dist --no-deps --require-hashes -r requirements.txt
            chown -R root:root /opt/\(r.id)
            ln -sf \(venv)/bin/\(bin) /usr/local/bin/\(bin)
            rm -rf dist requirements.txt
            echo "\(r.title) \(release.version) installed under \(venv), \((r.install.requirements ?? []).count) distributions"
            """, timeoutSeconds: 1800)
    }

    /// 617: one program from a release download (`url`, `{version}` in it): a tar.gz or zip unpacked and its `payload`
    /// taken, or the download itself; sha512-checked against the integrity; under /opt/<id>, linked as /usr/local/bin/<binary>.
    static func releaseBinaryInstall(_ r: AgentRecipe, _ release: AgentRelease) -> BakeStep {
        let bin = r.install.binary, dest = "/opt/\(r.id)/\(bin)"
        let url = (r.install.url ?? "").replacingOccurrences(of: "{version}", with: String(release.version.split(separator: "+")[0]))
        let unpack: String
        switch r.install.archive {
        case "tar.gz": unpack = "mkdir x && tar -xzf dl -C x --no-same-owner\nsrc=x/\(r.install.payload!)"
        case "zip": unpack = "mkdir x && python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' dl x\nsrc=x/\(r.install.payload!)"
        default: unpack = "src=dl"
        }
        return BakeStep.script("install \(r.title) \(release.version) (linux-arm64 release, integrity-pinned)", """
            cd "$(mktemp -d)"
            curl -fsSL --retry 3 -o dl '\(url)'
            \(sha512Check("dl", release.integrity, what: "\(r.title) \(release.version)"))
            \(unpack)
            test -f "$src"
            rm -rf /opt/\(r.id)
            mkdir -p /opt/\(r.id)
            cp "$src" \(dest)
            chmod 0755 \(dest)
            chown -R root:root /opt/\(r.id)
            ln -sf \(dest) /usr/local/bin/\(bin)
            rm -rf x dl
            echo "\(r.title) \(release.version) (linux-arm64) installed under /opt/\(r.id), sha256 $(sha256sum \(dest) | cut -d' ' -f1)"
            """)
    }

    /// The registry's tarball URL of `package` at `version` (`@scope/name` → `…/@scope/name/-/name-<version>.tgz`).
    static func tarballURL(_ package: String, _ version: String) -> String {
        let short = package.split(separator: "/").last.map(String.init) ?? package
        return "https://registry.npmjs.org/\(package)/-/\(short)-\(version).tgz"
    }

    /// 617: an agent's program from the npm registry's linux-arm64 PLATFORM package at the agent's version (Grok Build:
    /// `@xai-official/grok-linux-arm64`), its sha512 checked against the release's integrity (resolved on the Mac — in
    /// the script, so in the bake key; the check line has npm installs' shape, so the integrity reads back), the
    /// payload decompressed when it is (brotli: Node's zlib where the base has Node, else the distribution's `brotli`),
    /// installed under /opt/<id> and linked as /usr/local/bin/<binary>.
    static func platformBinaryInstall(_ r: AgentRecipe, _ release: AgentRelease, base: BaseSource) -> BakeStep {
        let pkg = r.install.platformPackage!, bin = r.install.binary, payload = r.install.payload!
        let dest = "/opt/\(r.id)/\(bin)"
        let place: String
        if r.install.compression == "brotli" {
            let node = #"node -e 'const z=require("zlib"),f=require("fs");f.writeFileSync(process.argv[2],z.brotliDecompressSync(f.readFileSync(process.argv[1])))' "$src" "$dst""#
            let apt = "export DEBIAN_FRONTEND=noninteractive; apt-get install -y --no-install-recommends -o Dpkg::Use-Pty=0 brotli\nbrotli -d -f -o \"$dst\" \"$src\""
            let apk = "apk add brotli\nbrotli -d -f -o \"$dst\" \"$src\""
            if base.hasNode {
                place = node
            } else {
                switch base.packageManager {
                case .apt: place = apt
                case .apk: place = apk
                case .auto:
                    place = """
                        if command -v node >/dev/null 2>&1; then
                        \(node)
                        elif command -v apt-get >/dev/null 2>&1; then
                        \(apt)
                        else
                        \(apk)
                        fi
                        """
                }
            }
        } else {
            place = "cp \"$src\" \"$dst\""
        }
        return BakeStep.script("install \(r.title) \(release.version) (linux-arm64, integrity-pinned)", """
            cd "$(mktemp -d)"
            curl -fsSL --retry 3 -o pkg.tgz '\(tarballURL(pkg, release.version))'
            got="sha512-$(python3 -c 'h=__import__("hashlib").sha512(open(__import__("sys").argv[1],"rb").read()).digest(); print(__import__("base64").b64encode(h).decode(), end="")' pkg.tgz)"
            [ "$got" = '\(release.integrity)' ] || { echo "integrity mismatch for \(pkg)@\(release.version): $got" >&2; exit 1; }
            tar -xzf pkg.tgz
            src=package/\(payload)
            test -f "$src"
            rm -rf /opt/\(r.id)
            mkdir -p /opt/\(r.id)
            dst=\(dest)
            \(place)
            chmod 0755 "$dst"
            chown -R root:root /opt/\(r.id)
            ln -sf "$dst" /usr/local/bin/\(bin)
            rm -rf package pkg.tgz
            echo "\(r.title) \(release.version) (linux-arm64) installed under /opt/\(r.id), sha256 $(sha256sum "$dst" | cut -d' ' -f1)"
            """)
    }

    /// 617: a recipe agent starts ready to work, like Claude Code and Codex: `~/.local/bin/<binary>` (first on the
    /// agent's PATH) exports the recipe's environment; runs the recipe's first arguments that need nothing (its
    /// `--version`, `login`, `mcp` …) as they are; otherwise writes the recipe's first-run settings that are NOT there
    /// yet (a person's own choice is kept; python3, an atomic 0600 replace) and puts the recipe's approval-off
    /// arguments first — unless `DOZ_<ID>_PERMISSIONS=ask` (the setting `<id>.permissions`) or root. It names no
    /// credential (ImageSpecTests). `DOZ_<ID>_LAUNCHER_ECHO=1` prints the command it would run instead (the VM suite).
    static func recipeLauncher(_ r: AgentRecipe) -> BakeStep {
        BakeStep.script("install the doz \(r.install.binary) launcher", recipeLauncherScript(r), needsNetworkFalse: ())
    }

    static func shellQuoted(_ s: String) -> String { "'" + s + "'" }       // recipe strings hold no quote (validated)

    static func recipeLauncherScript(_ r: AgentRecipe) -> String {
        let bin = r.install.binary, setup = "/usr/local/lib/dozer/\(r.id)-setup.py"
        let echoVar = r.permissionsVariable.replacingOccurrences(of: "_PERMISSIONS", with: "_LAUNCHER_ECHO")
        var sh = """
            #!/bin/sh
            # doz: \(r.title) with its first-run settings in place and, by default, its approval prompts off.
            mode=skip
            [ "${\(r.permissionsVariable):-skip}" = ask ] && mode=ask
            [ "$(id -u)" = 0 ] && mode=ask

            """
        for (k, v) in r.launch.env.sorted(by: { $0.key < $1.key }) { sh += "export \(k)=\(shellQuoted(v))\n" }
        if !r.launch.passthrough.isEmpty {
            sh += "case \"$1\" in\n  \(r.launch.passthrough.joined(separator: "|"))) exec /usr/local/bin/\(bin) \"$@\" ;;\nesac\n"
        }
        if r.launch.firstRun?.isEmpty == false {
            sh += "python3 \(setup) || echo \"doz: could not pre-seed \(r.title)'s settings\" >&2\n"
        }
        if !r.launch.noPromptsArgs.isEmpty {
            sh += "[ \"$mode\" = skip ] && set -- \(r.launch.noPromptsArgs.map(shellQuoted).joined(separator: " ")) \"$@\"\n"
        }
        for (k, v) in (r.launch.noPromptsEnv ?? [:]).sorted(by: { $0.key < $1.key }) {
            sh += "[ \"$mode\" = skip ] && export \(k)=\(shellQuoted(v))\n"
        }
        sh += """
            if [ "${\(echoVar):-}" = 1 ]; then printf '%s\\n' /usr/local/bin/\(bin) "$@"; exit 0; fi
            exec /usr/local/bin/\(bin) "$@"
            """
        var script = "mkdir -p /usr/local/lib/dozer /home/agent/.local/bin\n"
        if let merges = r.launch.firstRun, !merges.isEmpty {
            script += "cat > \(setup) <<'PY'\n\(recipeSetupPython(merges))\nPY\n"
        }
        script += "cat > /home/agent/.local/bin/\(bin) <<'SH'\n\(sh)\nSH\n"
        script += "chmod 0755 /home/agent/.local/bin/\(bin) /usr/local/lib/dozer\n"
        if r.launch.firstRun?.isEmpty == false { script += "chmod 0644 \(setup)\n" }
        script += "chown -R agent:agent /home/agent/.local"
        return script
    }

    /// 617: the dotenv merge (a recipe whose first-run file is `…/.env` — Fabric); only in such a recipe's helper, so the
    /// other recipes' launchers (and bake keys) are unchanged. KEY=value lines; a key already there (set or commented
    /// out by the person) is kept; the file is made when missing even with nothing to add.
    static let dotenvPython = #"""
        def merge_env(f, keys):
            try:
                with open(f, encoding='utf-8') as h: text = h.read()
            except FileNotFoundError:
                text = None
            lines = text.split('\n') if text else []
            while lines and lines[-1] == '': lines.pop()
            have = set(l.split('=', 1)[0].strip().lstrip('#').strip() for l in lines if '=' in l)
            add = [k + '=' + str(v) for k, v in sorted(keys.items()) if k not in have]
            if add or text is None: put(f, '\n'.join(lines + add) + '\n')

        """#

    /// 617: a first-run TOML key with no table (ZeroClaw's `schema_version`) — written above the first table, only when
    /// absent; emitted only into such a recipe's helper (the other launchers and bake keys are unchanged).
    /// 617: a first-run YAML file (Goose's `~/.config/goose/config.yaml`) — emitted only into such a recipe's helper (the
    /// other launchers and bake keys are unchanged).
    static func hasYAML(_ merges: [AgentRecipe.FirstRun]) -> Bool {
        merges.contains { $0.file.hasSuffix(".yaml") || $0.file.hasSuffix(".yml") }
    }

    /// Top-level `KEY: value` lines (a JSON scalar is a YAML scalar), each added only when no line of the file starts with
    /// that key — a person's own value, or a key they commented out, is kept; the file is made when missing. No YAML parser
    /// in the guest: anything the file says otherwise is left as it is.
    static let yamlTopPython = #"""
        def merge_yaml(f, keys):
            try:
                with open(f, encoding='utf-8') as h: text = h.read()
            except FileNotFoundError:
                text = None
            lines = text.split('\n') if text else []
            while lines and lines[-1] == '': lines.pop()
            have = set(l.lstrip('#').strip().split(':', 1)[0].strip() for l in lines if ':' in l and not l.startswith((' ', '\t', '-')))
            add = [k + ': ' + json.dumps(v) for k, v in sorted(keys.items()) if k not in have]
            if add or text is None: put(f, '\n'.join(lines + add) + '\n')

        """#

    /// 617: a TOML key with a segment in double quotes (Open Interpreter's `projects."/workspace".trust_level`) — the
    /// quoted-key merge is emitted only into such a recipe's helper (the other launchers and bake keys are unchanged).
    static func hasQuotedTOML(_ merges: [AgentRecipe.FirstRun]) -> Bool {
        merges.contains { $0.file.hasSuffix(".toml") && $0.set.keys.contains { $0.contains("\"") } }
    }

    /// merge_toml again, its keys split into segments where a segment in double quotes is one key: the header keeps the
    /// quotes (`[projects."/workspace"]`), the parsed file is looked up without them.
    static let tomlQuotedPython = #"""
        def toml_parts(k):
            return __import__('re').findall(r'"[^"]*"|[^.]+', k)
        def merge_toml(f, keys):
            try:
                with open(f, encoding='utf-8') as h: text = h.read()
            except FileNotFoundError:
                text = ''
            try:
                cfg = __import__('tomllib').loads(text)
            except Exception:
                return
            lines = text.split('\n') if text else []
            while lines and lines[-1] == '': lines.pop()
            changed = False
            for k, v in sorted(keys.items()):
                parts = toml_parts(k)
                table, key = parts[:-1], parts[-1]
                d = cfg
                for p in table:
                    d = d.get(p.strip('"')) if isinstance(d, dict) else None
                if isinstance(d, dict) and key.strip('"') in d: continue
                header = '[' + '.'.join(table) + ']'
                at = next((i for i, l in enumerate(lines) if l.strip() == header), None)
                if at is None:
                    if d is not None: continue
                    if lines: lines.append('')
                    lines += [header, key + ' = ' + toml_value(v)]
                else:
                    lines.insert(at + 1, key + ' = ' + toml_value(v))
                t = cfg
                for p in table: t = t.setdefault(p.strip('"'), {})
                t[key.strip('"')] = v
                changed = True
            if changed: put(f, '\n'.join(lines) + '\n')

        """#

    static func hasTopLevelTOML(_ merges: [AgentRecipe.FirstRun]) -> Bool {
        merges.contains { $0.file.hasSuffix(".toml") && $0.set.keys.contains { !$0.contains(".") } }
    }

    static let tomlTopPython = #"""
        def merge_toml_top(f, keys):
            try:
                with open(f, encoding='utf-8') as h: text = h.read()
            except FileNotFoundError:
                text = ''
            try:
                cfg = __import__('tomllib').loads(text)
            except Exception:
                return
            add = [k + ' = ' + toml_value(v) for k, v in sorted(keys.items()) if k not in cfg]
            if add: put(f, '\n'.join(add) + ('\n' + text if text else '\n'))
        for m in MERGES:
            if m['file'].endswith('.toml'):
                top = {k: v for k, v in m['set'].items() if '.' not in k}
                if top:
                    g = os.path.join(home, m['file'][2:]) if m['file'].startswith('~/') else m['file']
                    merge_toml_top(g, top)
                    m['set'] = {k: v for k, v in m['set'].items() if '.' in k}

        """#

    /// The launcher's helper: each first-run file's keys that are absent are set (JSON: nested objects; TOML: under
    /// their table, a table the file defines some other way is left alone); a file that does not parse is left as it is.
    static func recipeSetupPython(_ merges: [AgentRecipe.FirstRun]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = String(decoding: (try? enc.encode(merges)) ?? Data("[]".utf8), as: UTF8.self)
        return #"""
            json, os, sys = __import__('json'), __import__('os'), __import__('sys')   # (no line starts with an import: the audit reads Swift's)
            MERGES = json.loads(r'''\#(data)''')
            home = os.environ.get('HOME') or '/home/agent'
            def put(f, text):
                os.makedirs(os.path.dirname(f), exist_ok=True)
                t = f + '.doz-tmp'
                with os.fdopen(os.open(t, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w', encoding='utf-8') as h: h.write(text)
                os.replace(t, f)
            def merge_json(f, keys):
                try:
                    with open(f, encoding='utf-8') as h: c = json.load(h)
                except FileNotFoundError:
                    c = {}
                except Exception:
                    return
                if not isinstance(c, dict): return
                changed = False
                for k, v in sorted(keys.items()):
                    parts, d = k.split('.'), c
                    for p in parts[:-1]:
                        if p not in d:
                            d[p] = {}
                            changed = True
                        d = d[p] if isinstance(d[p], dict) else None
                        if d is None: break
                    if d is not None and parts[-1] not in d:
                        d[parts[-1]] = v
                        changed = True
                if changed: put(f, json.dumps(c, indent=2) + '\n')
            def toml_value(v):
                if isinstance(v, bool): return 'true' if v else 'false'
                if isinstance(v, (int, float)): return str(int(v)) if float(v).is_integer() else str(v)
                return json.dumps(v)
            def merge_toml(f, keys):
                try:
                    with open(f, encoding='utf-8') as h: text = h.read()
                except FileNotFoundError:
                    text = ''
                try:
                    cfg = __import__('tomllib').loads(text)
                except Exception:
                    return
                lines = text.split('\n') if text else []
                while lines and lines[-1] == '': lines.pop()
                changed = False
                for k, v in sorted(keys.items()):
                    parts = k.split('.')
                    table, key = parts[:-1], parts[-1]
                    d = cfg
                    for p in table:
                        d = d.get(p) if isinstance(d, dict) else None
                    if isinstance(d, dict) and key in d: continue
                    header = '[' + '.'.join(table) + ']'
                    at = next((i for i, l in enumerate(lines) if l.strip() == header), None)
                    if at is None:
                        if d is not None: continue
                        if lines: lines.append('')
                        lines += [header, key + ' = ' + toml_value(v)]
                    else:
                        lines.insert(at + 1, key + ' = ' + toml_value(v))
                    t = cfg
                    for p in table: t = t.setdefault(p, {})
                    t[key] = v
                    changed = True
                if changed: put(f, '\n'.join(lines) + '\n')
            \#(merges.contains { $0.file.hasSuffix("/.env") } ? dotenvPython : "")\#(Self.hasYAML(merges) ? yamlTopPython : "")\#(Self.hasQuotedTOML(merges) ? tomlQuotedPython : "")\#(Self.hasTopLevelTOML(merges) ? tomlTopPython : "")for m in MERGES:
                f = m['file']
                f = os.path.join(home, f[2:]) if f.startswith('~/') else f
                (\#(merges.contains { $0.format != nil } ? "merge_json if m.get('format') == 'json' else " : "")merge_toml if f.endswith('.toml') else \#(merges.contains { $0.file.hasSuffix("/.env") } ? "merge_env if f.endswith('/.env') else " : "")\#(Self.hasYAML(merges) ? "merge_yaml if f.endswith(('.yaml', '.yml')) else " : "")merge_json)(f, m['set'])
            """#
    }

    // MARK: 599i — Codex

    /// 599i: the OpenAI Codex CLI. Its npm package is a Node wrapper; the program is the linux-arm64
    /// platform package (a static musl binary), which Dozer installs directly on every base.
    public static let codexPackage = "@openai/codex"
    /// 599i: Codex 0.160.1 — the version installed on the owner's Mac at the probe (2026-10-06). The
    /// integrity is the LINUX-ARM64 platform tarball's (`@openai/codex@0.160.1-linux-arm64`), the one
    /// a bake downloads; the version is the main package's.
    public static let codexPinned = AgentRelease(version: "0.160.1",
        integrity: "sha512-JLyjBlmjPvwTaicHemw+y5xQSz3Uja2r7F/xkvS8gFufTA2g132Ak+0fo35xnJ/k2uc9fTtjm0LrsEGI78L6Ng==")
    /// The platform package's version for a Codex version (`0.160.1-linux-arm64`).
    public static func codexPlatformVersion(_ version: String) -> String { version + "-linux-arm64" }

    /// 599i: Codex from the registry's linux-arm64 tarball, its sha512 checked against `r.integrity`
    /// (resolved on the Mac — in the script, so in the bake key), unpacked under /opt/codex; on a musl base
    /// the bundled glibc `rg` is removed so the baseline's ripgrep is used. The check line has npm installs'
    /// shape, so `ImageComposer.npmIntegrity` reads it back.
    static func codexInstall(_ r: AgentRelease) -> BakeStep {
        let pv = codexPlatformVersion(r.version)
        return BakeStep.script("install Codex \(r.version) (linux-arm64, integrity-pinned)", """
            cd "$(mktemp -d)"
            curl -fsSL --retry 3 -o codex.tgz 'https://registry.npmjs.org/\(codexPackage)/-/codex-\(pv).tgz'
            got="sha512-$(python3 -c 'h=__import__("hashlib").sha512(open(__import__("sys").argv[1],"rb").read()).digest(); print(__import__("base64").b64encode(h).decode(), end="")' codex.tgz)"
            [ "$got" = '\(r.integrity)' ] || { echo "integrity mismatch for \(codexPackage)@\(pv): $got" >&2; exit 1; }
            tar -xzf codex.tgz
            rm -rf /opt/codex
            mv package /opt/codex
            chown -R root:root /opt/codex
            t=/opt/codex/vendor/aarch64-unknown-linux-musl
            test -x "$t/bin/codex"
            if [ -e /lib/ld-musl-aarch64.so.1 ]; then rm -f "$t/codex-path/rg"; fi
            ln -sf "$t/bin/codex" /usr/local/bin/codex
            rm -f codex.tgz
            echo "Codex \(r.version) (linux-arm64) installed under /opt/codex"
            """)
    }

    /// 599i: Codex in a sandbox starts ready to work, like Claude Code (585): `~/.local/bin/codex` (first on
    /// the agent's PATH) marks the working folder trusted in `$CODEX_HOME/config.toml` (only when the folder
    /// has no entry — a person's own choice is kept), then runs `/usr/local/bin/codex` with
    /// `--dangerously-bypass-approvals-and-sandbox` (the VM, the proxy and the vault are the boundary, so
    /// its approvals and its own Linux sandbox only get in the way), the update check off, its credentials
    /// read from auth.json (which the host writes — placeholders only), and the sandbox's facts as a developer
    /// message. `DOZ_CODEX_PERMISSIONS=ask` (the setting codex.permissions) and root keep its approvals.
    static let codexLauncher = BakeStep.script("install the doz codex launcher", codexLauncherScript, needsNetworkFalse: ())

    static let codexLauncherScript = """
        mkdir -p /usr/local/lib/dozer /home/agent/.local/bin
        cat > /usr/local/lib/dozer/codex-setup.py <<'PY'
        \(codexSetupPython)
        PY
        cat > /home/agent/.local/bin/codex <<'SH'
        #!/bin/sh
        # doz: Codex with its first-run setup done and, by default, its approvals and own sandbox off.
        mode=skip
        [ "${DOZ_CODEX_PERMISSIONS:-skip}" = ask ] && mode=ask
        [ "$(id -u)" = 0 ] && mode=ask
        # The host writes the credentials (placeholders) and the facts at every session start.
        common="-c check_for_update_on_startup=false -c cli_auth_credentials_store=file"
        p=/run/dozer/agent-prompt.md
        dev=
        if [ -s "$p" ]; then
          case " $* " in
            *developer_instructions*) ;;
            *) dev=$(python3 /usr/local/lib/dozer/codex-setup.py prompt "$p") || dev= ;;
          esac
        fi
        trust() { python3 /usr/local/lib/dozer/codex-setup.py trust || echo "doz: could not pre-seed Codex's setup" >&2; }
        agent() {
          trust
          if [ "$mode" = skip ]; then
            set -- --dangerously-bypass-approvals-and-sandbox -c notice.hide_full_access_warning=true "$@"
          fi
          if [ -n "$dev" ]; then set -- -c "developer_instructions=$dev" "$@"; fi
          # shellcheck disable=SC2086
          exec /usr/local/bin/codex $common "$@"
        }
        case "$1" in
          exec|e|resume|fork)
            sub=$1; shift
            trust
            if [ "$mode" = skip ]; then set -- --dangerously-bypass-approvals-and-sandbox "$@"; fi
            if [ -n "$dev" ]; then set -- -c "developer_instructions=$dev" "$@"; fi
            # shellcheck disable=SC2086
            exec /usr/local/bin/codex $common "$sub" "$@" ;;
          review)
            trust
            # shellcheck disable=SC2086
            exec /usr/local/bin/codex $common "$@" ;;
          agents|login|logout|mcp|plugin|app-server|remote-control|app|completion|update|doctor|sandbox|debug|apply|a|queue|archive|delete|migrate-rollouts|unarchive|cloud|exec-server|features|help|--help|-h|--version|-V)
            exec /usr/local/bin/codex "$@" ;;
          *) agent "$@" ;;
        esac
        SH
        chmod 0755 /home/agent/.local/bin/codex /usr/local/lib/dozer
        chmod 0644 /usr/local/lib/dozer/codex-setup.py
        chown -R agent:agent /home/agent/.local
        """

    /// 599i: the launcher's helper (python3 — every base's baseline has it): `trust` marks the working
    /// folder trusted in `$CODEX_HOME/config.toml` when it has no entry there (appended; a config Dozer cannot
    /// read is left alone); `prompt FILE` prints the file as a TOML basic string for `-c developer_instructions=`.
    static let codexSetupPython = #"""
        json, os, sys = __import__('json'), __import__('os'), __import__('sys')   # (no line starts with an import: the audit reads Swift's)
        def toml_string(text):
            return json.dumps(text.replace('\x7f', ''), ensure_ascii=False)
        if len(sys.argv) > 2 and sys.argv[1] == 'prompt':
            with open(sys.argv[2], encoding='utf-8', errors='replace') as h: text = h.read().strip()
            if text: sys.stdout.write(toml_string(text))
            sys.exit(0)
        home = os.environ.get('CODEX_HOME') or os.path.join(os.environ['HOME'], '.codex')
        os.makedirs(home, exist_ok=True)
        f = os.path.join(home, 'config.toml')
        cwd = os.getcwd()
        try:
            with open(f, encoding='utf-8') as h: text = h.read()
        except FileNotFoundError:
            text = ''
        try:
            cfg = __import__('tomllib').loads(text)
        except Exception:
            sys.exit(0)
        if cwd in (cfg.get('projects') or {}):
            sys.exit(0)
        add = ('' if text.endswith('\n') or not text else '\n') + '\n[projects.' + toml_string(cwd) + ']\ntrust_level = "trusted"\n'
        t = f + '.doz-tmp'
        with os.fdopen(os.open(t, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w', encoding='utf-8') as h: h.write(text + add)
        os.replace(t, f)
        """#

    /// The imageSpecs' digest-pinned Debian `node` base (glibc).
    public static let nodeBase = "docker.io/library/node@sha256:d649c27dae7ba0137b3cef5dd75baa422c08dc3d9e3fc0c23dfb172dc3cc6436"

    /// Create the `agent` account (uid 1001; the base's `node` user keeps 1000) and /workspace.
    static let createAgent = BakeStep.script("create the agent user", """
        id agent >/dev/null 2>&1 || useradd -m -s /bin/bash -u 1001 agent
        mkdir -p /workspace && chown agent:agent /workspace
        """, needsNetworkFalse: ())

    /// `npm pack` the pinned version, check the tarball's sha512 against the pinned integrity,
    /// then install exactly that tarball globally.
    /// Claude Code in a sandbox starts ready to work (owner ruling, 585): `~/.local/bin/claude` (first
    /// on the agent's PATH) marks the first-run setup done for THIS session — onboarding, this
    /// session's API-key placeholder (minted per session, so it is approved per session), trust for
    /// the working folder — then runs the real `/usr/local/bin/claude` with
    /// `--dangerously-skip-permissions`: the VM, the proxy and the vault are the boundary, so its
    /// own prompts only get in the way. `DOZ_CLAUDE_PERMISSIONS=ask` keeps them; root always
    /// keeps them (Claude Code refuses the flag as root). Only the keys named below are written.
    static let claudeLauncher = BakeStep.script("install the doz claude launcher", launcherScript(.node), needsNetworkFalse: ())

    /// 596: the same launcher for Claude Code's NATIVE build on a base without Node — its first-run
    /// setup in python3 (every base's baseline has it), writing exactly the keys the Node one writes.
    static let claudeLauncherNative = BakeStep.script("install the doz claude launcher", launcherScript(.python), needsNetworkFalse: ())

    enum LauncherSetup { case node, python }

    /// The launcher step's script. `.node` is byte-for-byte the 585/594 script (the Node images' bake
    /// keys depend on it — `BaseImagesTests.test_nodeImagesAreByteIdentical`).
    static func launcherScript(_ setup: LauncherSetup) -> String {
        let (file, marker, source, run): (String, String, String, String) = switch setup {
        case .node: ("claude-setup.js", "JS", claudeSetupJS, "node")
        case .python: ("claude-setup.py", "PY", claudeSetupPython, "python3")
        }
        return """
        mkdir -p /usr/local/lib/dozer /home/agent/.local/bin
        cat > /usr/local/lib/dozer/\(file) <<'\(marker)'
        \(source)
        \(marker)
        cat > /home/agent/.local/bin/claude <<'SH'
        #!/bin/sh
        # doz: Claude Code with its first-run setup done and, by default, its permission prompts off.
        mode=skip
        [ "${DOZ_CLAUDE_PERMISSIONS:-skip}" = ask ] && mode=ask
        [ "$(id -u)" = 0 ] && mode=ask
        \(run) /usr/local/lib/dozer/\(file) "$mode" || echo "doz: could not pre-seed Claude Code's setup" >&2
        # 594: the sandbox's facts, which the host writes at every session start, are appended to
        # Claude Code's system prompt — not for a subcommand, nor when the caller gives a prompt.
        p=/run/dozer/agent-prompt.md
        if [ -s "$p" ]; then
          case "$1" in
            mcp|plugin|plugins|setup-token|doctor|update|upgrade|install|config|migrate-installer|auth|agents) ;;
            *) case " $* " in
                 *" --append-system-prompt"*|*" --system-prompt"*) ;;
                 *) set -- --append-system-prompt "$(cat "$p")" "$@" ;;
               esac ;;
          esac
        fi
        [ "$mode" = skip ] && exec /usr/local/bin/claude --dangerously-skip-permissions "$@"
        exec /usr/local/bin/claude "$@"
        SH
        chmod 0755 /home/agent/.local/bin/claude /usr/local/lib/dozer
        chmod 0644 /usr/local/lib/dozer/\(file)
        chown -R agent:agent /home/agent/.local
        """
    }

    /// 596: `claude-setup.js`, in python3 — the same keys, the same atomic 0600 writes.
    static let claudeSetupPython = """
        json, os, sys = __import__('json'), __import__('os'), __import__('sys')   # (no line starts with an import: the audit reads Swift's)
        d = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.join(os.environ['HOME'], '.claude')
        def read(f):
            try:
                with open(f) as h: return json.load(h)
            except Exception: return {}
        def put(f, obj):
            t = f + '.doz-tmp'
            with os.fdopen(os.open(t, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w') as h: json.dump(obj, h, indent=2)
            os.replace(t, f)
        os.makedirs(d, exist_ok=True)
        f = os.path.join(d, '.claude.json'); c = read(f)
        c['hasCompletedOnboarding'] = True
        key = os.environ.get('ANTHROPIC' + '_API_KEY')   # spelled apart: no image spec names a credential (ImageSpecTests)
        if key:
            r = c.setdefault('customApiKeyResponses', {'approved': [], 'rejected': []}); tail = key[-20:]
            r['approved'] = ([x for x in (r.get('approved') or []) if x != tail] + [tail])[-50:]
            r['rejected'] = [x for x in (r.get('rejected') or []) if x != tail]
        c.setdefault('projects', {}).setdefault(os.getcwd(), {})['hasTrustDialogAccepted'] = True
        put(f, c)
        if len(sys.argv) > 1 and sys.argv[1] == 'skip':
            sf = os.path.join(d, 'settings.json'); s = read(sf)
            if s.get('skipDangerousModePermissionPrompt') is not True:
                s['skipDangerousModePermissionPrompt'] = True; put(sf, s)
        """

    static let claudeSetupJS = """
        const fs = require('fs'), path = require('path');
        const dir = process.env.CLAUDE_CONFIG_DIR || path.join(process.env.HOME, '.claude');
        const put = (f, obj) => { fs.writeFileSync(f + '.doz-tmp', JSON.stringify(obj, null, 2), { mode: 0o600 }); fs.renameSync(f + '.doz-tmp', f); };
        const read = f => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return {}; } };
        fs.mkdirSync(dir, { recursive: true });
        const file = path.join(dir, '.claude.json'), c = read(file);
        c.hasCompletedOnboarding = true;
        const key = process.env['ANTHROPIC' + '_API_KEY'];   // spelled apart: no image spec names a credential (ImageSpecTests)
        if (key) {
          const r = (c.customApiKeyResponses ??= { approved: [], rejected: [] }), tail = key.slice(-20);
          r.approved = [...(r.approved || []).filter(x => x !== tail), tail].slice(-50);
          r.rejected = (r.rejected || []).filter(x => x !== tail);
        }
        ((c.projects ??= {})[process.cwd()] ??= {}).hasTrustDialogAccepted = true;
        put(file, c);
        if (process.argv[2] === 'skip') {
          const sf = path.join(dir, 'settings.json'), s = read(sf);
          if (s.skipDangerousModePermissionPrompt !== true) { s.skipDangerousModePermissionPrompt = true; put(sf, s); }
        }
        """

    /// The tools an interactive developer shell (and an agent) expects, which Debian's `-slim`
    /// base leaves out (owner, 591: "top/ps: command not found"; git was missing too). Installed
    /// from Debian's signed archive through the bake proxy. The same list for every agent image:
    /// it is the class baseline until base-layer images (one baked "dev base" that agent images
    /// clone) replace it.
    /// 594 (owner: pi printed "fd not found. Downloading... Failed to download fd"): `fd-find` too —
    /// pi (like many agents) wants `fd` and `rg` and downloads them from GitHub when they are missing.
    /// Debian names it `fdfind`; `/usr/local/bin/fd` is linked to it.
    /// 594 W23 (owner ruling 2026-09-30: "yes, passwordless sudo by default"): `sudo` too — the agent
    /// gets passwordless sudo at boot unless the sandbox's `agent_sudo` is off (the drop-in is written
    /// per boot, never baked: `GuestCommand.agentSudoScript`).
    public static let devBaselinePackages = ["procps", "git", "less", "jq", "unzip", "openssh-client",
                                             "ca-certificates", "curl", "vim-tiny", "ripgrep", "fd-find", "python3", "sudo", "apt-utils",
                                             // 599 (594.B3): sessions.tmux runs a session inside tmux.
                                             "tmux"]

    /// 594 W23: apt's package lists are KEPT in the image (they were deleted, so even root needed
    /// `apt-get update` before `apt-get install` worked). ~20–50 MB of the root disk, an APFS clone
    /// shared by every sandbox of the image — cheaper than every sandbox fetching them on first boot,
    /// and an install then works offline-first. They age with the image; `apt-get update` refreshes them.
    static let devBaseline = olderRecipeForTests ? olderDevBaseline : BakeStep.script("install the developer baseline (\(devBaselinePackages.joined(separator: " ")))", """
        export DEBIAN_FRONTEND=noninteractive
        # 594 (owner: "more progress detail"): apt's own lines (Get:, Unpacking, Setting up) are the
        # live tail the preparation card and the CLI show while this step runs — not silenced.
        apt-get update
        # 594 W24: apt-utils FIRST — without it every install (here and the agent's `sudo apt-get
        # install` later) says "debconf: delaying package configuration, since apt-utils is not installed".
        apt-get install -y --no-install-recommends -o Dpkg::Use-Pty=0 apt-utils
        apt-get install -y --no-install-recommends -o Dpkg::Use-Pty=0 \(devBaselinePackages.filter { $0 != "apt-utils" }.joined(separator: " "))
        ln -sf /usr/bin/fdfind /usr/local/bin/fd
        apt-get clean
        """)

    /// 594 W28: a TEST seam — `DOZ_TEST_OLDER_RECIPE=1` makes this process bake the agent images the
    /// way 0.12.0-rc.1 did (no sudo, no apt-utils, package lists deleted), so a test can hold an image
    /// "prepared by an older doz" and check it is named as such — and never rebuilt without asking.
    static let olderRecipeForTests = ProcessInfo.processInfo.environment["DOZ_TEST_OLDER_RECIPE"] == "1"
    static let olderDevBaselinePackages = devBaselinePackages.filter { $0 != "sudo" && $0 != "apt-utils" && $0 != "tmux" }
    static let olderDevBaseline = BakeStep.script("install the developer baseline (\(olderDevBaselinePackages.joined(separator: " ")))", """
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends -o Dpkg::Use-Pty=0 \(olderDevBaselinePackages.joined(separator: " "))
        ln -sf /usr/bin/fdfind /usr/local/bin/fd
        rm -rf /var/lib/apt/lists/*
        """)

    /// 594 W28: what THIS doz's recipe (`new`) has that an image baked by an older one (`old`) lacks,
    /// in people's words — "sudo", "package lists", a step's name — or ["its recipe changed"] when the
    /// difference is elsewhere; [] when they are the same recipe.
    public static func recipeChanges(from old: ImageSpec, to new: ImageSpec) -> [String] {
        guard old != new else { return [] }
        func baseline(_ s: ImageSpec) -> (packages: [String], deletesLists: Bool)? {
            guard let step = s.steps.first(where: { $0.name.hasPrefix("install the developer baseline (") }) else { return nil }
            let inside = step.name.dropFirst("install the developer baseline (".count).dropLast()
            return (inside.split(separator: " ").map(String.init), (step.argv.last ?? "").contains("rm -rf /var/lib/apt/lists"))
        }
        var out: [String] = []
        if let o = baseline(old), let n = baseline(new) {
            out += n.packages.filter { !o.packages.contains($0) }
            if o.deletesLists && !n.deletesLists { out.append("package lists") }
        }
        let oldSteps = Set(old.steps.map(\.name))
        for s in new.steps where !oldSteps.contains(s.name) && !s.name.hasPrefix("install the developer baseline (") && !s.name.hasPrefix("npm install ") {
            out.append(s.name)
        }
        return out.isEmpty ? ["its recipe changed"] : out
    }

    /// What the baseline must provide, checked after every agent bake. 594 W23: sudo, a sudoers
    /// drop-in `visudo -cf` accepts, and package lists apt can install from.
    static let devBaselineVerify: [VerifyCheck] = olderRecipeForTests ? olderDevBaselineVerify : [
        VerifyCheck(["sh", "-c", "for t in ps top git less jq unzip ssh curl vi rg fd python3 sudo tmux; do command -v $t >/dev/null || { echo missing $t; exit 1; }; done; echo baseline-ok"],
                    expect: "baseline-ok"),
        // The boot writes the rule only after /usr/sbin/visudo accepts it (as root: /etc/sudoers is 0440).
        VerifyCheck(["sh", "-c", "test -x /usr/bin/sudo && test -x /usr/sbin/visudo && test -d /etc/sudoers.d && echo sudoers-ok"],
                    expect: "sudoers-ok"),
        VerifyCheck(["sh", "-c", "apt-cache policy cowsay | grep -q Candidate: && ! apt-cache policy cowsay | grep -q 'Candidate: (none)' && echo apt-lists-ok"],
                    expect: "apt-lists-ok"),
    ]
    static let olderDevBaselineVerify: [VerifyCheck] = [
        VerifyCheck(["sh", "-c", "for t in ps top git less jq unzip ssh curl vi rg fd python3; do command -v $t >/dev/null || { echo missing $t; exit 1; }; done; echo baseline-ok"],
                    expect: "baseline-ok"),
    ]

    static func npmInstall(_ package: String, version: String, integrity: String, extraArgs: [String] = []) -> BakeStep {
        let extra = extraArgs.joined(separator: " ")
        return BakeStep.script("npm install \(package)@\(version) (integrity-pinned)", """
            cd "$(mktemp -d)"
            npm pack --silent '\(package)@\(version)' >/dev/null
            tgz=$(ls *.tgz)
            got="sha512-$(node -e 'process.stdout.write(require("crypto").createHash("sha512").update(require("fs").readFileSync(process.argv[1])).digest("base64"))' "$tgz")"
            [ "$got" = '\(integrity)' ] || { echo "integrity mismatch for \(package)@\(version): $got" >&2; exit 1; }
            npm install -g --no-fund --no-audit \(extra) "./$tgz"
            npm cache clean --force >/dev/null 2>&1 || true
            """, environment: ["NPM_CONFIG_UPDATE_NOTIFIER": "false"])
    }

    /// The claude-code image at the pinned version.
    public static let claudeCode = claudeCode(claudeCodePinned)

    /// 596: `base` — the Node base as resolved at preparation (the tag `node:22-bookworm` followed);
    /// the built-in pin by default, which keeps this spec, and its bake key, exactly as before 596.
    public static func claudeCode(_ r: AgentRelease, base: String = nodeBase) -> ImageSpec {
        var s = ImageSpec(
            name: "claude-code",
            base: base,
            steps: [createAgent, devBaseline,
                    npmInstall(claudeCodePackage, version: r.version, integrity: r.integrity),
                    claudeLauncher],
            verify: [VerifyCheck(["claude", "--version"], expect: r.version),
                     VerifyCheck(["sh", "-c", "test -x /home/agent/.local/bin/claude && echo launcher-ok"], expect: "launcher-ok")]
                + devBaselineVerify,
            user: "agent", home: "/home/agent",
            // CLAUDE_CONFIG_DIR puts .claude.json INSIDE ~/.claude, so one directory holds all state.
            persistDirs: ["~/.claude"],
            // 594: Claude Code never updates itself in a sandbox (it could not write /usr/local, and a
            // sandbox keeps the version it was made with; a new image brings the new one). Its binary
            // honours both: DISABLE_AUTOUPDATER (the background updater) and DISABLE_UPDATES (every
            // update path, `claude update` included).
            sessionEnvironment: ["CLAUDE_CONFIG_DIR": "/home/agent/.claude", "DISABLE_AUTOUPDATER": "1", "DISABLE_UPDATES": "1",
                                 "PATH": "/home/agent/.local/bin:/usr/local/bin:/usr/bin:/bin"],
            rootfsMiB: 4096)
        s.agent = AgentPackage(package: claudeCodePackage, version: r.version)
        return s
    }

    /// The pi image at the pinned version.
    public static let pi = pi(piPinned)

    public static func pi(_ r: AgentRelease, base: String = nodeBase) -> ImageSpec {
        var s = ImageSpec(
            name: "pi",
            base: base,
            steps: [createAgent, devBaseline,
                    npmInstall(piPackage, version: r.version, integrity: r.integrity, extraArgs: ["--ignore-scripts"])],
            verify: [VerifyCheck(["pi", "--version"], expect: r.version)] + devBaselineVerify,
            user: "agent", home: "/home/agent",
            persistDirs: ["~/.pi/agent"],
            sessionEnvironment: ["PI_CODING_AGENT_DIR": "/home/agent/.pi/agent",
                                 "PATH": "/home/agent/.local/bin:/usr/local/bin:/usr/bin:/bin"],
            rootfsMiB: 4096)
        s.agent = AgentPackage(package: piPackage, version: r.version)
        return s
    }
}

extension BakeStep {
    static func script(_ name: String, _ script: String, needsNetworkFalse: Void) -> BakeStep {
        var s = BakeStep.script(name, script)
        s.needsNetwork = false
        return s
    }
}
