import ContainerizationOCI
import CryptoKit
import Foundation

// 596 — Dozer Base Images (owner ruling 2026-09-30, B1–B11 as recommended). A sandbox's image is
// two independent choices: the AGENT (Claude Code · pi · none) and the BASE (a recommended catalogue
// entry, or the user's Dockerfile). The image Dozer prepares is base + the dev baseline + the agent,
// named `<base>-<agent>` (`python-claude-code`, `go-pi`, `debian` for no agent) — except the three
// images that existed before, whose names and specs are unchanged: `claude-code` (Node · Claude
// Code), `pi` (Node · pi) and `lab` (Alpine · none).

/// How a base installs packages (the baseline and the agent's prerequisites).
public enum PackageManager: String, Sendable, Codable, Equatable {
    case apt, apk
    /// A Dockerfile's base: unknown until it runs — the bake script looks (`apt-get`, else `apk`).
    case auto
}

/// A host a base's language registry answers on — added to the sandbox's network policy when that
/// base is chosen (B4: the agent installs what a project needs).
public struct RegistryHost: Sendable, Codable, Equatable {
    public var host: String
    public var note: String
    public init(_ host: String, _ note: String) {
        self.host = host
        self.note = note
    }
}

/// 596 (B3): one recommended base — an official image, linux/arm64, the FULL variant for a language
/// toolchain (agents compile native dependencies). The tag is followed: resolved to a digest at
/// preparation (the pin below until then), with "update available" when the tag has moved.
public struct CatalogueBase: Sendable, Codable, Equatable {
    /// `[a-z0-9]`, the image-name prefix: `node`, `python`, `go`, …
    public var id: String
    /// "Python", as a card's title.
    public var title: String
    /// What it is for, one line.
    public var useCase: String
    /// The tag followed (`docker.io/library/python:3.13-bookworm`).
    public var reference: String
    /// The built-in pin: the tag's digest when this catalogue was written (596 probe
    /// `catalogue-digests.sh`, 2026-10-01; Node keeps the pre-596 pin, so its images' keys are unchanged).
    public var pinnedDigest: String
    public var packageManager: PackageManager
    /// Node is in the base (the Node agent images install with npm; pi needs no Node of its own).
    public var hasNode: Bool
    /// musl libc (Alpine): Claude Code's `linux-arm64-musl` build.
    public var musl: Bool
    /// The language's package registries (B4).
    public var registries: [RegistryHost]
    /// The linux/arm64 download (compressed layers, bytes — the probe's) and a first-prepare
    /// estimate (seconds, on a fast line), for the card.
    public var downloadBytes: Int64
    public var prepareSeconds: Int
    /// The baked disk's capacity (apparent — APFS allocates only what is written).
    public var rootfsMiB: UInt64
    /// What the image's own ENV sets that a session needs (sessions do not inherit the image config),
    /// and PATH entries ahead of `/usr/local/bin:/usr/bin:/bin`.
    public var environment: [String: String]
    public var path: [String]
    /// A credential-free check that the toolchain answers, run as the agent in every bake.
    public var toolchain: VerifyCheck?

    /// `docker.io/library/python` — the reference without its tag.
    public var repository: String {
        guard let slash = reference.lastIndex(of: "/"), let colon = reference[slash...].lastIndex(of: ":") else { return reference }
        return String(reference[..<colon])
    }
    /// `repository@digest`.
    public func reference(digest: String) -> String { "\(repository)@\(digest)" }
    public var pinnedReference: String { reference(digest: pinnedDigest) }
    /// The short form a person reads (`python:3.13-bookworm`, `mcr.microsoft.com/dotnet/sdk:9.0`).
    public var shortReference: String {
        reference.hasPrefix("docker.io/library/") ? String(reference.dropFirst("docker.io/library/".count)) : reference
    }
}

public enum BaseCatalogue {
    /// The catalogue's version (it ships inside DozerKit; a remote catalogue is later — B3).
    public static let version = 1

    /// B3's table, in the order a card grid shows it.
    public static let all: [CatalogueBase] = [
        CatalogueBase(id: "node", title: "Node.js", useCase: "JavaScript and TypeScript — Node 22 LTS",
                      reference: "docker.io/library/node:22-bookworm",
                      pinnedDigest: "sha256:d649c27dae7ba0137b3cef5dd75baa422c08dc3d9e3fc0c23dfb172dc3cc6436",
                      packageManager: .apt, hasNode: true, musl: false, registries: [],
                      downloadBytes: 399_778_410, prepareSeconds: 150, rootfsMiB: 4096, environment: [:], path: [],
                      toolchain: VerifyCheck(["node", "--version"], expect: "v22.")),
        CatalogueBase(id: "python", title: "Python", useCase: "Python 3.13 with pip",
                      reference: "docker.io/library/python:3.13-bookworm",
                      pinnedDigest: "sha256:227b6570d6ee07061ae6ca2eb04dedfb6d2b34045835f343065b9869e4d427ea",
                      packageManager: .apt, hasNode: false, musl: false, registries: [],
                      downloadBytes: 373_153_717, prepareSeconds: 150, rootfsMiB: 4096,
                      environment: ["PYTHONUNBUFFERED": "1"], path: [],
                      toolchain: VerifyCheck(["python3", "--version"], expect: "Python 3.13")),
        CatalogueBase(id: "go", title: "Go", useCase: "Go 1.25",
                      reference: "docker.io/library/golang:1.25-bookworm",
                      pinnedDigest: "sha256:3b4a11519ad929d1e1d261a12cff056f0c85b735253d7d861346b9c6f8b36437",
                      packageManager: .apt, hasNode: false, musl: false,
                      registries: [RegistryHost("proxy.golang.org", "Go modules"), RegistryHost("sum.golang.org", "Go checksums"),
                                   RegistryHost("storage.googleapis.com", "Go module downloads")],
                      downloadBytes: 280_862_728, prepareSeconds: 140, rootfsMiB: 4096,
                      environment: ["GOPATH": "/go"], path: ["/go/bin", "/usr/local/go/bin"],
                      toolchain: VerifyCheck(["go", "version"], expect: "go1.25")),
        CatalogueBase(id: "rust", title: "Rust", useCase: "Rust stable with cargo",
                      reference: "docker.io/library/rust:1-bookworm",
                      pinnedDigest: "sha256:93ce27a88655056a51dbdd8f5f2d7ddc071c7b0070fb288a37b5a285fc83971e",
                      packageManager: .apt, hasNode: false, musl: false,
                      registries: [RegistryHost("crates.io", "Rust crates"), RegistryHost("index.crates.io", "Rust crates"),
                                   RegistryHost("static.crates.io", "Rust crates"), RegistryHost("static.rust-lang.org", "rustup")],
                      downloadBytes: 522_035_583, prepareSeconds: 190, rootfsMiB: 6144,
                      environment: ["CARGO_HOME": "/usr/local/cargo", "RUSTUP_HOME": "/usr/local/rustup"], path: ["/usr/local/cargo/bin"],
                      toolchain: VerifyCheck(["cargo", "--version"], expect: "cargo 1.")),
        CatalogueBase(id: "java", title: "Java", useCase: "Java 21 (Eclipse Temurin JDK)",
                      reference: "docker.io/library/eclipse-temurin:21-jdk",
                      pinnedDigest: "sha256:4d06038800655fe1211760cd561de70ef2ed7a47f5d69255e9834414602b7026",
                      packageManager: .apt, hasNode: false, musl: false,
                      registries: [RegistryHost("repo.maven.apache.org", "Maven Central"), RegistryHost("repo1.maven.org", "Maven Central"),
                                   RegistryHost("services.gradle.org", "Gradle"), RegistryHost("downloads.gradle.org", "Gradle"),
                                   RegistryHost("plugins.gradle.org", "Gradle plugins")],
                      downloadBytes: 221_099_686, prepareSeconds: 120, rootfsMiB: 4096,
                      environment: ["JAVA_HOME": "/opt/java/openjdk"], path: ["/opt/java/openjdk/bin"],
                      toolchain: VerifyCheck(["java", "-version"], expect: "\"21.")),
        CatalogueBase(id: "ruby", title: "Ruby", useCase: "Ruby 3.4 with Bundler",
                      reference: "docker.io/library/ruby:3.4-bookworm",
                      pinnedDigest: "sha256:246b2dc3f6e40bba3af18503c22997a34dbb27c9f97e198dde6dd727895115c5",
                      packageManager: .apt, hasNode: false, musl: false,
                      registries: [RegistryHost("rubygems.org", "RubyGems"), RegistryHost("index.rubygems.org", "RubyGems")],
                      downloadBytes: 381_438_914, prepareSeconds: 150, rootfsMiB: 4096,
                      environment: ["GEM_HOME": "/usr/local/bundle", "BUNDLE_SILENCE_ROOT_WARNING": "1", "BUNDLE_APP_CONFIG": "/usr/local/bundle"],
                      path: ["/usr/local/bundle/bin"],
                      toolchain: VerifyCheck(["ruby", "--version"], expect: "ruby 3.4")),
        CatalogueBase(id: "dotnet", title: ".NET", useCase: ".NET 9 SDK",
                      reference: "mcr.microsoft.com/dotnet/sdk:9.0",
                      pinnedDigest: "sha256:01fabc4758d1d74e39eda700c8463dae6241a61481f973683692ddcb59a5eeb7",
                      packageManager: .apt, hasNode: false, musl: false,
                      registries: [RegistryHost("api.nuget.org", "NuGet"), RegistryHost("globalcdn.nuget.org", "NuGet")],
                      downloadBytes: 330_508_041, prepareSeconds: 160, rootfsMiB: 4096,
                      environment: ["DOTNET_CLI_TELEMETRY_OPTOUT": "1", "DOTNET_NOLOGO": "1", "DOTNET_ROOT": "/usr/share/dotnet"], path: [],
                      toolchain: VerifyCheck(["dotnet", "--version"], expect: "9.")),
        CatalogueBase(id: "debian", title: "Debian", useCase: "General purpose — Debian 12",
                      reference: "docker.io/library/debian:bookworm",
                      pinnedDigest: "sha256:f37a335e82bca302e955fa39f9dfe28f1be618f016f8a2b56318e5a5111afc26",
                      packageManager: .apt, hasNode: false, musl: false, registries: [],
                      downloadBytes: 48_389_910, prepareSeconds: 80, rootfsMiB: 4096, environment: [:], path: [], toolchain: nil),
        CatalogueBase(id: "ubuntu", title: "Ubuntu", useCase: "General purpose — Ubuntu 24.04 LTS",
                      reference: "docker.io/library/ubuntu:24.04",
                      pinnedDigest: "sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3",
                      packageManager: .apt, hasNode: false, musl: false, registries: [],
                      downloadBytes: 28_941_580, prepareSeconds: 80, rootfsMiB: 4096, environment: [:], path: [], toolchain: nil),
        CatalogueBase(id: "alpine", title: "Alpine", useCase: "Tiny — Alpine 3.20 (musl)",
                      reference: "docker.io/library/alpine:3.20",
                      pinnedDigest: "sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc",
                      packageManager: .apk, hasNode: false, musl: true, registries: [],
                      downloadBytes: 4_092_319, prepareSeconds: 40, rootfsMiB: 2048, environment: [:], path: [], toolchain: nil),
    ]

    public static func base(_ id: String) -> CatalogueBase? { all.first { $0.id == id } }
    public static var ids: [String] { all.map(\.id) }
}

/// 596 (B1): the agent a sandbox runs.
public enum AgentKind: String, Sendable, Codable, CaseIterable, Equatable {
    case claudeCode = "claude-code"
    case pi
    case none
    /// 599i: the OpenAI Codex CLI (last, so `allCases` keeps its earlier order).
    case codex

    public var title: String {
        switch self { case .claudeCode: "Claude Code"; case .pi: "pi"; case .none: "none"; case .codex: "Codex" }
    }
}

/// 596: which image a name means — its base (a catalogue id, or `df-<12 hex>` for a Dockerfile) and
/// its agent. `claude-code`, `pi` and `lab` keep their names (Node · Claude Code, Node · pi,
/// Alpine · none); every other pair is `<base>-<agent>`, or `<base>` alone with no agent.
public struct ImageChoice: Sendable, Equatable, Hashable {
    public var base: String
    public var agent: AgentKind

    public init(base: String, agent: AgentKind) {
        self.base = base
        self.agent = agent
    }

    /// The image's name in the store (`images/<name>/`), in settings and in `doz.json`.
    public var name: String {
        switch (base, agent) {
        case ("node", .claudeCode): "claude-code"
        case ("node", .pi): "pi"
        case ("node", .codex): "codex"
        case ("alpine", .none): "lab"
        case (_, .none): base
        default: "\(base)-\(agent.rawValue)"
        }
    }

    public var isDockerfile: Bool { Self.isDockerfileBase(base) }

    /// "Python · Claude Code", "Alpine · none", "Dockerfile · pi".
    public var title: String {
        let b = BaseCatalogue.base(base)?.title ?? (isDockerfile ? "Dockerfile" : base)
        return "\(b) · \(agent.title)"
    }

    /// The pair a name means (nil: not a base × agent name — a template, or unknown). Accepts the
    /// long forms of the three old names too (`node-claude-code`, `alpine`).
    public static func parse(_ name: String) -> ImageChoice? {
        switch name {
        case "claude-code": return ImageChoice(base: "node", agent: .claudeCode)
        case "pi": return ImageChoice(base: "node", agent: .pi)
        case "codex": return ImageChoice(base: "node", agent: .codex)
        case "lab": return ImageChoice(base: "alpine", agent: .none)
        default: break
        }
        for a in [AgentKind.claudeCode, .pi, .codex] where name.hasSuffix("-" + a.rawValue) {
            let b = String(name.dropLast(a.rawValue.count + 1))
            if isBase(b) { return ImageChoice(base: b, agent: a) }
        }
        return isBase(name) ? ImageChoice(base: name, agent: .none) : nil
    }

    static func isBase(_ b: String) -> Bool { BaseCatalogue.base(b) != nil || isDockerfileBase(b) }

    /// `df-` + 12 lower-case hex.
    public static func isDockerfileBase(_ b: String) -> Bool {
        b.count == 15 && b.hasPrefix("df-") && b.dropFirst(3).allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// A Dockerfile's base id: `df-` + the first 12 hex of sha256(its absolute, standardized path).
    public static func dockerfileBase(path: String) -> String {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        return "df-" + SHA256.hash(data: Data(p.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12)
    }
}

/// 596 (B2): Claude Code's standalone native build at one version — the sha256 of each linux-arm64
/// binary, from `downloads.claude.ai/claude-code-releases/<version>/manifest.json`, resolved on the
/// Mac at preparation and checked in the bake.
public struct NativeClaudeBuild: Sendable, Codable, Equatable, Hashable {
    public var version: String
    /// `linux-arm64` and `linux-arm64-musl` → 64 hex.
    public var sha256: [String: String]

    public init(version: String, sha256: [String: String]) {
        self.version = version
        self.sha256 = sha256
    }

    public static let platforms = ["linux-arm64", "linux-arm64-musl"]
    public static let downloadBase = "https://downloads.claude.ai/claude-code-releases"

    /// Safe to put in a bake script: an exact version, and 64 hex for both platforms.
    public var isWellFormed: Bool {
        AgentRelease(version: version, integrity: "sha512-A").isWellFormed
            && Self.platforms.allSatisfy { p in sha256[p].map { $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } } ?? false }
    }

    /// The build for Claude Code 2.1.227 (the npm pin, `AgentImages.claudeCodePinned`) — the 596
    /// probe `claude-native.sh`, 2026-10-01.
    public static let pinned = NativeClaudeBuild(version: "2.1.227", sha256: [
        "linux-arm64": "db47335532cbcab67a4b3ab16d8f3f77976bf85d53c7d79f8296538aa22bfce6",
        "linux-arm64-musl": "8284d20a5d61e71502e69836b1598ba03f688f4d8de6c22105055fbf0af118f6",
    ])

    /// A manifest document → the build (refuses anything malformed: it goes into a bake script).
    public static func parse(_ data: Data, version: String) throws -> NativeClaudeBuild {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = o["version"] as? String, v == version, let platforms = o["platforms"] as? [String: Any] else {
            throw SandboxError.invalidSpec("Claude Code's native manifest for \(version) has no version or platforms")
        }
        var sums: [String: String] = [:]
        for p in Self.platforms {
            guard let e = platforms[p] as? [String: Any], let c = e["checksum"] as? String else { continue }
            sums[p] = c.lowercased()
        }
        let b = NativeClaudeBuild(version: v, sha256: sums)
        guard b.isWellFormed else { throw SandboxError.invalidSpec("Claude Code's native manifest for \(version) lacks a linux-arm64 checksum") }
        return b
    }
}

/// 596 (B2): the Node pi runs on, on a base without Node — Node's official linux-arm64 tarball,
/// pinned and checksum-verified, unpacked under `/opt/node` (596 probe `pins.sh`).
public enum NodeRuntime {
    public static let version = "22.23.3"
    public static let sha256 = "a44aeb94849a299b22df10b9e622ec2f605c2183501bc40590705131de7c740f"
    public static var url: String { "https://nodejs.org/dist/v\(version)/node-v\(version)-linux-arm64.tar.xz" }
}

/// 596: what a base contributes to an image spec — resolved (a digest-pinned reference) and described.
public struct BaseSource: Sendable, Equatable {
    public var reference: String
    public var packageManager: PackageManager
    public var hasNode: Bool
    /// true / false; nil (a Dockerfile): the bake looks for musl's loader.
    public var musl: Bool?
    public var rootfsMiB: UInt64
    public var environment: [String: String]
    public var path: [String]
    public var toolchain: VerifyCheck?
    /// The catalogue's Node base (the old images' recipe applies to it unchanged).
    public var isCatalogueNode: Bool

    public init(reference: String, packageManager: PackageManager, hasNode: Bool, musl: Bool?, rootfsMiB: UInt64,
                environment: [String: String] = [:], path: [String] = [], toolchain: VerifyCheck? = nil, isCatalogueNode: Bool = false) {
        self.reference = reference
        self.packageManager = packageManager
        self.hasNode = hasNode
        self.musl = musl
        self.rootfsMiB = rootfsMiB
        self.environment = environment
        self.path = path
        self.toolchain = toolchain
        self.isCatalogueNode = isCatalogueNode
    }
}

extension CatalogueBase {
    /// This base at `digest` (nil: the pin).
    public func source(digest: String? = nil) -> BaseSource {
        BaseSource(reference: reference(digest: digest ?? pinnedDigest), packageManager: packageManager, hasNode: hasNode, musl: musl,
                   rootfsMiB: rootfsMiB, environment: environment, path: path, toolchain: toolchain, isCatalogueNode: id == "node")
    }
}

/// 596: base + the dev baseline + the agent → the image spec. The Node · Claude Code and Node · pi
/// images are exactly `AgentImages.claudeCode` / `.pi` (on the resolved Node base); every other pair
/// is composed here from the same parts.
public enum ImageComposer {
    public static let user = "agent"
    public static let home = "/home/agent"

    /// `name` — `ImageChoice.name`. `release` — the agent's npm version (Claude Code's native build
    /// uses the same version, `native` its checksums). `release`/`native` are ignored for no agent.
    public static func spec(name: String, base: BaseSource, agent: AgentKind, release: AgentRelease?, native: NativeClaudeBuild?) throws -> ImageSpec {
        if base.isCatalogueNode, let release {
            switch agent {
            case .claudeCode: return AgentImages.claudeCode(release, base: base.reference)
            case .pi: return AgentImages.pi(release, base: base.reference)
            case .none, .codex: break          // 599i: Codex has no pre-596 Node image — composed below
            }
        }
        var steps = [createUser(base.packageManager), baseline(base.packageManager)]
        var verify = baselineVerify(base.packageManager)
        if let t = base.toolchain { verify.insert(t, at: 0) }
        let path = ([home + "/.local/bin"] + base.path + ["/usr/local/bin", "/usr/bin", "/bin"]).joined(separator: ":")
        var env = base.environment.merging(["PATH": path]) { _, b in b }
        var persist: [String] = []
        var hosts: [String] = []
        var agentPackage: AgentPackage?
        switch agent {
        case .none:
            break
        case .claudeCode:
            guard let release else { throw SandboxError.invalidSpec("Claude Code needs a version") }
            if base.hasNode {
                steps.append(AgentImages.npmInstall(AgentImages.claudeCodePackage, version: release.version, integrity: release.integrity))
                steps.append(AgentImages.claudeLauncher)
            } else {
                guard let native, native.version == release.version, native.isWellFormed else {
                    throw SandboxError.invalidSpec("Claude Code \(release.version)'s native build has no known checksums")
                }
                steps.append(nativeClaude(native, musl: base.musl))
                steps.append(AgentImages.claudeLauncherNative)
                hosts.append("downloads.claude.ai")
                if base.musl != false { env["USE_BUILTIN_RIPGREP"] = "0" }
            }
            verify.insert(contentsOf: [VerifyCheck(["claude", "--version"], expect: release.version),
                                       VerifyCheck(["sh", "-c", "test -x /home/agent/.local/bin/claude && echo launcher-ok"], expect: "launcher-ok")], at: 0)
            persist = ["~/.claude"]
            env.merge(["CLAUDE_CONFIG_DIR": home + "/.claude", "DISABLE_AUTOUPDATER": "1", "DISABLE_UPDATES": "1"]) { _, b in b }
            agentPackage = AgentPackage(package: AgentImages.claudeCodePackage, version: release.version)
        case .pi:
            guard let release else { throw SandboxError.invalidSpec("pi needs a version") }
            var install = AgentImages.npmInstall(AgentImages.piPackage, version: release.version, integrity: release.integrity, extraArgs: ["--ignore-scripts"])
            if !base.hasNode {
                steps.append(nodeForPi(base.packageManager))
                install.environment["PATH"] = "/opt/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                steps.append(install)
                steps.append(piWrapper)
                if base.packageManager != .apk { hosts.append("nodejs.org") }
            } else {
                steps.append(install)
            }
            verify.insert(VerifyCheck(["pi", "--version"], expect: release.version), at: 0)
            persist = ["~/.pi/agent"]
            env["PI_CODING_AGENT_DIR"] = home + "/.pi/agent"
            agentPackage = AgentPackage(package: AgentImages.piPackage, version: release.version)
        case .codex:
            // 599i: one recipe on every base — the static musl binary from the registry's linux-arm64 tarball.
            guard let release else { throw SandboxError.invalidSpec("Codex needs a version") }
            steps.append(AgentImages.codexInstall(release))
            steps.append(AgentImages.codexLauncher)
            verify.insert(contentsOf: [VerifyCheck(["codex", "--version"], expect: "codex-cli " + release.version),
                                       VerifyCheck(["sh", "-c", "test -x /home/agent/.local/bin/codex && echo launcher-ok"], expect: "launcher-ok")], at: 0)
            persist = ["~/.codex"]
            env["CODEX_HOME"] = home + "/.codex"
            agentPackage = AgentPackage(package: AgentImages.codexPackage, version: release.version)
        }
        var s = ImageSpec(name: name, base: base.reference, steps: steps, verify: verify, user: user, home: home,
                          persistDirs: persist, sessionEnvironment: env, rootfsMiB: base.rootfsMiB)
        s.agent = agentPackage
        s.bakeHosts = hosts.isEmpty ? nil : hosts
        try s.validate()
        return s
    }

    // MARK: this build's recipe for an image (594 W28)

    /// The keys `spec(…)` itself adds to a session's environment (the rest come from the base).
    static let composerKeys: Set<String> = ["PATH", "CLAUDE_CONFIG_DIR", "DISABLE_AUTOUPDATER", "DISABLE_UPDATES", "PI_CODING_AGENT_DIR", "USE_BUILTIN_RIPGREP",
                                            "CODEX_HOME"]

    /// 594 W28 × 596: what THIS build bakes for what `spec` installs — the same base (its digest, or a
    /// Dockerfile's build as the spec describes it), the same agent release (its npm integrity or its
    /// native checksums, read from the spec's own steps) — composed again. Equal to `spec` when this
    /// build's recipe made it. nil: not a base × agent image, or its release cannot be read.
    public static func recompose(_ spec: ImageSpec) -> ImageSpec? {
        guard let choice = ImageChoice.parse(spec.name), choice.name == spec.name, spec.name != "lab" else { return nil }
        var release: AgentRelease?
        var native: NativeClaudeBuild?
        if choice.agent != .none {
            guard let v = spec.agent?.version else { return nil }
            let npm = npmIntegrity(in: spec)
            native = nativeBuild(in: spec, version: v)
            guard npm != nil || native != nil else { return nil }
            release = AgentRelease(version: v, integrity: npm ?? "sha512-A")
        }
        let src: BaseSource
        if let c = BaseCatalogue.base(choice.base) {
            guard let at = spec.base.firstIndex(of: "@") else { return nil }
            src = c.source(digest: String(spec.base[spec.base.index(after: at)...]))
        } else {
            let path = (spec.sessionEnvironment["PATH"] ?? "").split(separator: ":").map(String.init)
            let extra = path.dropFirst().prefix { $0 != "/usr/local/bin" }
            src = BaseSource(reference: spec.base, packageManager: .auto, hasNode: false, musl: nil, rootfsMiB: spec.rootfsMiB,
                             environment: spec.sessionEnvironment.filter { !composerKeys.contains($0.key) }, path: Array(extra))
        }
        return try? Self.spec(name: spec.name, base: src, agent: choice.agent, release: release, native: native)
    }

    /// The sha512 integrity an npm install step checks.
    public static func npmIntegrity(in spec: ImageSpec) -> String? {
        for s in spec.steps {
            guard let script = s.argv.last, let r = script.range(of: #"\[ "\$got" = '(sha512-[A-Za-z0-9+/=]+)' \]"#, options: .regularExpression) else { continue }
            let m = String(script[r])
            guard let a = m.range(of: "sha512-") else { continue }
            return String(m[a.lowerBound...].prefix { $0 != "'" })
        }
        return nil
    }

    /// The native build's checksums its install step checks (one platform's may be absent — the
    /// other is then used for it: a step for a known libc names only its own).
    static func nativeBuild(in spec: ImageSpec, version: String) -> NativeClaudeBuild? {
        var sums: [String: String] = [:]
        for s in spec.steps where s.name.hasPrefix("install Claude Code \(version) (native build") {
            let script = s.argv.last ?? ""
            for p in NativeClaudeBuild.platforms {
                if let r = script.range(of: "platform=\(p); want='[0-9a-f]{64}'", options: .regularExpression) {
                    sums[p] = String(script[r].suffix(65).dropLast())
                }
            }
        }
        guard let any = sums.values.first else { return nil }
        for p in NativeClaudeBuild.platforms where sums[p] == nil { sums[p] = any }
        return NativeClaudeBuild(version: version, sha256: sums)
    }

    // MARK: the parts

    /// The `agent` account (uid 1001) and /workspace — `useradd` (Debian, Ubuntu) or BusyBox's
    /// `adduser` (Alpine; its password field set to `*`, not `!` — a LOCKED account is refused by sudo).
    static func createUser(_ pm: PackageManager) -> BakeStep {
        switch pm {
        case .apt: return AgentImages.createAgent
        case .apk: return shStep("create the agent user", apkUser + "\nmkdir -p /workspace && chown agent:agent /workspace", network: false)
        case .auto:
            return shStep("create the agent user", """
                if command -v useradd >/dev/null 2>&1; then
                  id agent >/dev/null 2>&1 || useradd -m -s /bin/bash -u 1001 agent
                else
                \(apkUser)
                fi
                mkdir -p /workspace && chown agent:agent /workspace
                """, network: false)
        }
    }

    /// A POSIX `sh` step — for what runs before the baseline has installed bash (Alpine has none; a
    /// Dockerfile's base may not either). BusyBox ash and dash both take `-eu`.
    static func shStep(_ name: String, _ script: String, network: Bool = true) -> BakeStep {
        var s = BakeStep(name, argv: ["sh", "-eu", "-c", script])
        s.needsNetwork = network
        return s
    }

    static let apkUser = """
        id agent >/dev/null 2>&1 || adduser -D -s /bin/bash -u 1001 agent
        sed -i 's/^agent:!:/agent:*:/' /etc/shadow
        """

    /// 596: the dev baseline on Alpine — the 591 tools under apk's names (`bash` for sessions, `libgcc`
    /// and `libstdc++` for Claude Code's musl build, `shadow` for `useradd`), apk's index kept (W23:
    /// `sudo apk add` works at once).
    public static let apkBaselinePackages = ["bash", "procps", "git", "less", "jq", "unzip", "openssh-client", "ca-certificates",
                                             "curl", "vim", "ripgrep", "fd", "python3", "sudo", "ncurses", "coreutils",
                                             "findutils", "libgcc", "libstdc++", "shadow", "tzdata", "xz",
                                             // 599 (sessions.tmux) — and the baseline's verify asks for it on every base.
                                             "tmux"]

    static func baseline(_ pm: PackageManager) -> BakeStep {
        switch pm {
        case .apt: return AgentImages.devBaseline
        case .apk: return shStep("install the developer baseline (\(apkBaselinePackages.joined(separator: " ")))", apkBaselineScript)
        case .auto:
            return shStep("install the developer baseline (apt or apk)", """
                if command -v apt-get >/dev/null 2>&1; then
                \(AgentImages.devBaseline.argv.last!)
                elif command -v apk >/dev/null 2>&1; then
                \(apkBaselineScript)
                else
                  echo "doz: this base has neither apt-get nor apk — Dozer's baseline needs one of them" >&2; exit 1
                fi
                """)
        }
    }

    static var apkBaselineScript: String {
        """
        apk update
        apk add \(apkBaselinePackages.joined(separator: " "))
        """
    }

    static func baselineVerify(_ pm: PackageManager) -> [VerifyCheck] {
        switch pm {
        case .apt: return AgentImages.devBaselineVerify
        case .apk:
            return Array(AgentImages.devBaselineVerify.prefix(2)) + [
                VerifyCheck(["sh", "-c", "/sbin/apk search -e make | grep -q '^make-' && echo apk-index-ok"], expect: "apk-index-ok")]
        case .auto:
            return Array(AgentImages.devBaselineVerify.prefix(2))
        }
    }

    /// Claude Code's native build: downloaded from downloads.claude.ai, its sha256 checked against
    /// the manifest's (resolved on the Mac — in the script, so in the bake key), installed as
    /// `/usr/local/bin/claude` (the launcher runs it). `musl` nil: the bake looks for musl's loader.
    static func nativeClaude(_ b: NativeClaudeBuild, musl: Bool?) -> BakeStep {
        let glibc = b.sha256["linux-arm64"]!, muslSum = b.sha256["linux-arm64-musl"]!
        let pick: String = switch musl {
        case true?: "platform=linux-arm64-musl; want='\(muslSum)'"
        case false?: "platform=linux-arm64; want='\(glibc)'"
        case nil: """
            if [ -e /lib/ld-musl-aarch64.so.1 ]; then platform=linux-arm64-musl; want='\(muslSum)'; else platform=linux-arm64; want='\(glibc)'; fi
            """
        }
        return BakeStep.script("install Claude Code \(b.version) (native build, checksum-verified)", """
            \(pick)
            tmp=$(mktemp)
            curl -fsSL --retry 3 -o "$tmp" '\(NativeClaudeBuild.downloadBase)/\(b.version)/'"$platform"'/claude'
            got=$(sha256sum "$tmp" | cut -d' ' -f1)
            [ "$got" = "$want" ] || { echo "checksum mismatch for Claude Code \(b.version) $platform: $got" >&2; rm -f "$tmp"; exit 1; }
            install -m 0755 "$tmp" /usr/local/bin/claude
            rm -f "$tmp"
            echo "Claude Code \(b.version) ($platform) installed, sha256 $got"
            """)
    }

    /// pi's Node on a base without it: Node's official tarball under /opt/node (checksum-verified) —
    /// on Alpine, Alpine's own `nodejs`/`npm` (Node publishes no musl arm64 build), linked there too.
    static func nodeForPi(_ pm: PackageManager) -> BakeStep {
        let tarball = """
            command -v xz >/dev/null 2>&1 || { export DEBIAN_FRONTEND=noninteractive; apt-get install -y --no-install-recommends -o Dpkg::Use-Pty=0 xz-utils; }
            cd "$(mktemp -d)"
            curl -fsSL --retry 3 -o node.tar.xz '\(NodeRuntime.url)'
            got=$(sha256sum node.tar.xz | cut -d' ' -f1)
            [ "$got" = '\(NodeRuntime.sha256)' ] || { echo "checksum mismatch for Node \(NodeRuntime.version): $got" >&2; exit 1; }
            mkdir -p /opt/node && tar -xJf node.tar.xz -C /opt/node --strip-components=1 --no-same-owner
            rm -f node.tar.xz
            /opt/node/bin/node --version
            """
        let apk = """
            apk add nodejs npm
            mkdir -p /opt/node/bin /opt/node/lib
            ln -sf "$(command -v node)" /opt/node/bin/node
            ln -sf "$(command -v npm)" /opt/node/bin/npm
            npm config set prefix /opt/node --global
            /opt/node/bin/node --version
            """
        switch pm {
        case .apt: return BakeStep.script("install Node \(NodeRuntime.version) for pi (/opt/node, checksum-verified)", tarball)
        case .apk: return BakeStep.script("install Node for pi (Alpine's nodejs, /opt/node)", apk)
        case .auto:
            return BakeStep.script("install Node for pi (/opt/node)", """
                if command -v apk >/dev/null 2>&1; then
                \(apk)
                else
                \(tarball)
                fi
                """)
        }
    }

    /// `/usr/local/bin/pi`: pi with /opt/node first on its PATH — Node is pi's, not on the sessions' PATH.
    static let piWrapper = BakeStep.script("install the pi wrapper (/usr/local/bin/pi)", """
        test -x /opt/node/bin/pi
        cat > /usr/local/bin/pi <<'SH'
        #!/bin/sh
        # doz: pi runs on the Node under /opt/node (the base has none of its own).
        PATH=/opt/node/bin:$PATH exec /opt/node/bin/pi "$@"
        SH
        chmod 0755 /usr/local/bin/pi
        """, needsNetworkFalse: ())
}

/// 596: a tag's current digest, asked of its registry (the index's — never a layer). The host asks
/// at preparation time and hourly after, like 594's `latest` (`BaseDigests` in DozerHost).
public enum RegistryDigest {
    public static func resolve(_ reference: String) async throws -> String {
        let ref = try Reference.parse(reference)
        guard let tag = ref.tag else { throw SandboxError.invalidSpec("\(reference) names no tag") }
        let client = try RegistryClient(reference: reference)
        let d = try await client.resolve(name: ref.path, tag: tag)
        guard d.digest.hasPrefix("sha256:"), d.digest.count == 71 else { throw SandboxError.invalidSpec("\(reference) resolved to \(d.digest)") }
        return d.digest
    }
}
