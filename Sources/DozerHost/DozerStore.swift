import Darwin
import Foundation
import DozerKit

/// The CLI's store: ONE directory holds the library's store (images, kernels, sandboxes) and the
/// host's files beside it.
///
///     <store>/host.sock        the host's socket (0600)
///     <store>/host.lock        flock'd by the running host for its whole life — "is a host up?"
///     <store>/host.pid         the running host's pid
///     <store>/host.log         the host's stdout/stderr (appended)
///     <store>/metrics.sqlite   lifecycle metrics (the SandboxLab schema)
///     <store>/sandboxes/<name>/doz.json   what `doz create` said (SandboxConfig)
///     <store>/sandboxes/<name>/terminal-layout.json   593: the web UI's panes (TerminalLayout)
///     …and everything `StoreLayout` documents.
public struct DozerStore: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root.standardizedFileURL }

    /// `--store`, else `$DOZ_STORE`, else the settings file's `store.path`, else
    /// `~/Library/Application Support/dozer-sandbox`.
    public static func resolve(_ option: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> DozerStore {
        if let o = option, !o.isEmpty { return DozerStore(root: URL(fileURLWithPath: (o as NSString).expandingTildeInPath)) }
        if let e = environment["DOZ_STORE"], !e.isEmpty { return DozerStore(root: URL(fileURLWithPath: (e as NSString).expandingTildeInPath)) }
        if let f = DozerSettings.load(environment: environment).fileValues[SettingKey.storePath], case .string(let p) = f, !p.isEmpty {
            return DozerStore(root: URL(fileURLWithPath: (p as NSString).expandingTildeInPath))
        }
        return DozerStore(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/dozer-sandbox"))
    }

    public var socket: URL { root.appendingPathComponent("host.sock") }
    public var lockFile: URL { root.appendingPathComponent("host.lock") }
    public var pidFile: URL { root.appendingPathComponent("host.pid") }
    public var logFile: URL { root.appendingPathComponent("host.log") }
    public var metrics: URL { root.appendingPathComponent("metrics.sqlite") }
    public var sandboxesDirectory: URL { root.appendingPathComponent("sandboxes") }

    public func layout(_ name: String) -> StoreLayout { StoreLayout(root: root, name: name) }
    public func configFile(_ name: String) -> URL { layout(name).sandboxDirectory.appendingPathComponent("doz.json") }
    /// 593 §9 (S1): the web UI's terminal layout for the sandbox (`TerminalLayout`, 0600).
    public func terminalLayoutFile(_ name: String) -> URL { layout(name).sandboxDirectory.appendingPathComponent("terminal-layout.json") }

    /// The names of the sandboxes `doz create` made in this store.
    public func sandboxNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sandboxesDirectory.path)) ?? []
        return names.filter { FileManager.default.fileExists(atPath: configFile($0).path) }.sorted()
    }

    /// `sun_path` holds 104 bytes on macOS.
    public var socketPathFits: Bool { socket.path.utf8.count < 104 }

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// True while a host holds the store's lock. Probed by taking the lock and letting go at once.
    public func hostIsRunning() -> Bool {
        let fd = open(lockFile.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// The pid the running host wrote (nil when none is recorded).
    public func hostPID() -> Int32? {
        guard let s = try? String(contentsOf: pidFile, encoding: .utf8) else { return nil }
        return Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Sandboxes whose last durable phase says a VM was live when its host went away (a crash):
    /// only a host can recover them (restore what was asleep, e2fsck what died), so a read-only
    /// command starts one rather than answer from the disk.
    public func needsRecovery() -> [String] {
        sandboxNames().filter { name in
            guard let p = PersistedSandbox.read(from: layout(name).persistedState) else { return false }
            return p.phase != .off && p.phase != .hibernated
        }
    }
}

/// What `doz create` records for a sandbox (`<sandbox>/doz.json`). The spec is the
/// library's; the rest is the CLI's own: which image it was made from, its network preset, where
/// its credentials come from (never the secret), and what happened to it.
public struct SandboxConfig: Codable, Equatable, Sendable {
    public var name: String
    /// `lab`, `claude-code`, `pi`, or `custom:<name>`.
    public var image: String
    public var spec: SandboxSpec
    public var workspace: String?
    public var createdAt: Date
    /// binding id → `stdin` / `keychain:<service>`.
    public var credentialSources: [String: String]
    /// The previous host died while this sandbox ran (cleared by the next start).
    public var diedWithHostAt: Date?
    /// 588: the Anthropic account — `default` (follow the store's default account), a name
    /// (pinned), or nil (none: only a key given with `key set`).
    public var account: String?
    /// 588: `allow` or `strict` for a credential the guest supplies itself; nil: automatic
    /// (strict when the account is not a Mac login, allow otherwise).
    public var credentialPolicy: String?
    /// 588 (D8): sha256 of every live placeholder → its binding, so a session that survives a host
    /// restart keeps working. Never a placeholder, never a secret.
    public var placeholderHashes: [String: String]?
    /// 594 (D16): the sandbox's own layer of the environment prompt, and `append` (default) or `replace`.
    public var agentPrompt: String?
    public var agentPromptMode: String?
    /// 594 (D9): the `doz_project.yaml` it was made from.
    public var project: String?
    /// 594 W23: the agent's passwordless sudo — true/false chosen for this sandbox, nil: follow the
    /// setting `sandbox.agent_sudo` (default on). Applied at every boot and agent session start.
    public var agentSudo: Bool?
    /// 599: this sandbox's own values of the per-sandbox settings (`DozerSettings.perSandbox`: the
    /// clipboard and browser bridges, tmux) — a key absent follows the setting. (`sandbox.agent_sudo`
    /// keeps its own field above.)
    public var settings: [String: TOMLValue]?

    public init(name: String, image: String, spec: SandboxSpec, workspace: String?, createdAt: Date = Date(),
                credentialSources: [String: String] = [:], diedWithHostAt: Date? = nil) {
        self.name = name
        self.image = image
        self.spec = spec
        self.workspace = workspace
        self.createdAt = createdAt
        self.credentialSources = credentialSources
        self.diedWithHostAt = diedWithHostAt
    }

    public static func read(_ url: URL) -> SandboxConfig? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? HostWire.decoder.decode(SandboxConfig.self, from: d)
    }

    public func write(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try HostWire.prettyEncoder.encode(self).write(to: url, options: .atomic)
    }

    /// Where a sandbox's own environment prompt (D16) is kept at most: 16 KiB.
    public static let maximumAgentPromptBytes = 16 << 10

    /// The session `up` and `attach` use when none is named, and what it runs.
    public var defaultSession: (name: String, argv: [String]) {
        switch spec.imageSpec?.name {
        case "claude-code": ("claude", ["claude"])
        case "pi": ("pi", ["pi"])
        default: ("shell", ["bash", "-l"])
        }
    }

    /// The network, as the CLI names it.
    public var networkName: String { DozerImages.networkName(spec.network) }
}

/// The images a sandbox can be created from, and the specs they make.
public enum DozerImages {
    public static let builtIn = ["lab", "claude-code", "pi"]
    /// The lab's apk packages (Alpine 3.20).
    public static let labPackages = ["bash", "ncurses", "fd"]

    /// Where a workspace is shared in the guest.
    public static let workspaceGuestPath = "/workspace"

    public static func imageSpec(_ image: String) -> ImageSpec? {
        switch image {
        case "claude-code": AgentImages.claudeCode
        case "pi": AgentImages.pi
        default: nil
        }
    }

    /// `agent` for an agent image, `bake` (package registries only) for the lab.
    public static func defaultNetwork(_ image: String, imageSpec: ImageSpec?) -> String {
        imageSpec == nil ? "bake" : "agent"
    }

    public static func networkMode(_ name: String) throws -> NetworkMode {
        switch name {
        case "nat": return .nat
        case "none": return .none
        default:
            guard let p = NetworkPolicy.presets[name] else {
                throw HostError(.invalid, "unknown network \(name) — agent, bake, locked, open (proxied), nat or none")
            }
            return .proxied(p)
        }
    }

    public static func networkName(_ mode: NetworkMode) -> String {
        switch mode {
        case .nat: "nat"
        case .none: "none"
        case .proxied(let p): p.preset ?? "custom"
        }
    }

    /// The spec `doz create` makes. What the options leave out comes from the settings (591):
    /// `environment` names the settings file and overrides it — the kernel (`DOZ_KERNEL`,
    /// `DOZ_KERNEL_CACHE`), a default NAT subnet (`DOZ_SUBNET`) — then `doz.toml`
    /// (`defaults.cpus`, `images.<image>.memory_mib` / `.network`, …), then the defaults.
    /// 594: `purpose` — an agent image's version: a create gets the image already prepared (the newest
    /// for this build), a preparation the version the settings name (`AgentVersions.spec`).
    public static func spec(name: String, options o: CreateOptions, store: DozerStore,
                            environment env: [String: String] = ProcessInfo.processInfo.environment,
                            purpose: AgentVersions.Purpose = .create) throws -> (SandboxSpec, String) {
        let settings = DozerSettings.load(environment: env)
        let kernelPath = settings.string(SettingKey.kernelPath).map { ($0 as NSString).expandingTildeInPath }
        let kernelCache = settings.string(SettingKey.kernelCache).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        var shares: [Share] = []
        if let ws = o.workspace {
            let path = URL(fileURLWithPath: (ws as NSString).expandingTildeInPath).standardizedFileURL.path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                throw HostError(.invalid, "the workspace \(path) is not a directory")
            }
            shares.append(Share(hostPath: path, guestPath: workspaceGuestPath))
        }
        var imageSpec = try AgentVersions.spec(o.image, purpose: purpose, store: store, settings: settings) ?? imageSpec(o.image)
        var customKey: String?
        var imageName = o.image
        if imageSpec == nil, o.image != "lab" {
            let customName = o.image.hasPrefix("custom:") ? String(o.image.dropFirst(7)) : o.image
            guard let c = store.layout("_").customImages().first(where: { $0.name == customName || $0.key == customName }) else {
                throw HostError(.notFound, "no image \(o.image) — lab, claude-code, pi, or a custom image (doz image ls)")
            }
            customKey = c.key
            imageSpec = c.imageSpec
            imageName = "custom:\(c.name)"
        }
        let section = DozerSettings.imageSection(imageSpecName: imageSpec?.name)
        let network = try networkMode(o.network ?? settings.string(SettingKey.network(section)) ?? defaultNetwork(o.image, imageSpec: imageSpec))
        let subnet = o.subnet ?? settings.string(SettingKey.natSubnet)
        var spec = SandboxSpec(name: name, storeRoot: store.root, kernelPath: kernelPath, kernelCacheDirectory: kernelCache,
                               cpus: o.cpus ?? settings.int(SettingKey.cpus),
                               memoryMiB: o.memoryMiB ?? UInt64(settings.int(SettingKey.memory(section))), rootfsMiB: 1024,
                               // 594: fd, as in the agent images (tools an agent looks for).
                               bakePackages: imageSpec == nil && customKey == nil ? DozerImages.labPackages : [],
                               shares: shares, subnet: network == .nat ? subnet : nil,
                               imageSpec: imageSpec, customImage: customKey)
        spec.network = network
        try spec.validate()
        return (spec, imageName)
    }

    /// `2G`, `512M`, `1.5g`, `2048` (MiB) → MiB.
    public static func parseMemory(_ s: String) -> UInt64? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        var number = t
        var scale = 1.0
        for (suffix, f) in [("gib", 1024.0), ("gb", 1024.0), ("g", 1024.0), ("mib", 1.0), ("mb", 1.0), ("m", 1.0)] where t.hasSuffix(suffix) {
            number = String(t.dropLast(suffix.count))
            scale = f
            break
        }
        guard let v = Double(number), v > 0 else { return nil }
        let mib = v * scale
        guard mib.rounded() == mib || scale > 1 else { return nil }
        return UInt64(mib.rounded())
    }

    /// Bytes as `1.2 GiB` / `340 MiB` / `12 KiB`.
    public static func formatBytes(_ b: Int64) -> String {
        let d = Double(b)
        if d >= 1_073_741_824 { return String(format: "%.1f GiB", d / 1_073_741_824) }
        if d >= 1_048_576 { return String(format: "%.0f MiB", d / 1_048_576) }
        if d >= 1024 { return String(format: "%.0f KiB", d / 1024) }
        return "\(b) B"
    }

    /// A session name from a program: `/usr/bin/top` → `top`; anything outside [A-Za-z0-9._-] dropped.
    public static func sessionName(for argv: [String]) -> String {
        let base = (argv.first.map { ($0 as NSString).lastPathComponent } ?? "cmd")
        let kept = String(base.filter { $0.isLetter || $0.isNumber || "._-".contains($0) }.prefix(40))
        return kept.isEmpty || kept.first == "." ? "cmd" : kept
    }
}

/// Allocated bytes of a file, or of everything under a directory (sparse disks count what they
/// hold, not their size).
func allocatedBytes(_ dir: URL) -> Int64 {
    var st = stat()
    guard lstat(dir.path, &st) == 0 else { return 0 }
    if (st.st_mode & S_IFMT) == S_IFREG { return Int64(st.st_blocks) * 512 }
    guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return 0 }
    var total: Int64 = 0
    for case let u as URL in e {
        var st = stat()
        if lstat(u.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG { total += Int64(st.st_blocks) * 512 }
    }
    return total
}
