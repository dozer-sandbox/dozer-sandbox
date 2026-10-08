import Foundation
import DozerKit

/// 594 (D9, owner ruling: YAML, like dbt's `dbt_project.yml`) — `doz_project.yaml`: a folder that
/// is a Dozer Sandbox project. `doz init` (and the dashboard's New Sandbox wizard, 599f) writes it;
/// `doz up` with no name, in that folder, creates, starts or wakes exactly that sandbox and attaches.
/// The folder is its /workspace.
///
/// 599f: the MODEL lives here (the host, the CLI and the web UI share it — one plan, one renderer, one
/// validator); READING the YAML stays in the CLI's commands (`DozerCLI/ProjectFile.swift`, the only
/// place Yams is imported), and the web UI is handed that parser by `doz ui`. The schema is CLOSED, as
/// doz.toml's is: an unknown key, a value of the wrong type or outside its rule is an error naming its
/// line. No anchors or aliases, no multiple documents, 64 KiB at most.
public struct DozerProject: Equatable, Sendable {
    public static let fileName = "doz_project.yaml"
    /// 599f: the other spelling, read as well (never both in one folder).
    public static let otherFileName = "doz_project.yml"
    public static let fileNames = [fileName, otherFileName]
    public static let maximumBytes = 64 << 10

    public struct Session: Equatable, Sendable {
        public var name: String
        /// nil: the image's own program (the default session), or a login shell for `shell`.
        public var command: [String]?
        public init(name: String, command: [String]?) {
            self.name = name
            self.command = command
        }
    }

    public var version = 1
    public var name: String
    public var image: String
    public var cpus: Int?
    public var memoryMiB: UInt64?
    public var network: String?
    public var account: String?
    /// What `doz up` starts, in order; the first is attached. Empty: the image's own session.
    public var sessions: [Session] = []
    public var agentPrompt: String?
    public var agentPromptMode: String?
    /// 594 W23: the agent's passwordless sudo (nil: the setting sandbox.agent_sudo decides).
    public var agentSudo: Bool?
    /// 596 (B10): the agent and the base instead of `image` — a recommended base, or a Dockerfile
    /// (a path relative to this folder, or absolute).
    public var agent: String?
    public var base: String?
    public var dockerfile: String?
    /// 599: the sandbox's own per-sandbox settings (`settingKeys`), by setting key.
    public var settings: [String: TOMLValue] = [:]
    /// 599d: `off` / `read` / `push` — "Use GitHub as you" (and "Push to GitHub") when the sandbox is made.
    public var github: String?
    /// 599f: what the agent may do — the words of the setting `defaults.permissions` (`standard`, `locked`,
    /// `open`, or changes on Standard like `+web`, `-error-reports`), for a proxied network with
    /// permissions. nil: the setting decides. When the sandbox is made.
    public var permissions: [String]?

    public init(name: String, image: String, cpus: Int? = nil, memoryMiB: UInt64? = nil, network: String? = nil, account: String? = nil) {
        self.name = name
        self.image = image
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.network = network
        self.account = account
    }

    /// 599: the project keys that are a per-sandbox setting — the key, the setting, and the commented
    /// line `doz init` writes when the file does not set it.
    public static let settingKeys: [(key: String, setting: String, comment: String)] = [
        ("clipboard", SettingKey.clipboard,
         "# clipboard: write           # a copy in the sandbox (OSC 52) reaches the Mac clipboard, with a notice; off: never. Applies now"),
        ("browser_bridge", SettingKey.browserBridge,
         "# browser_bridge: on         # xdg-open in the sandbox opens http(s) URLs in the Mac's browser (a sign-in's callback forwarded); off: never. Applies now"),
        ("open_files", SettingKey.openFiles,
         "# open_files: on             # xdg-open FILE in the sandbox opens a /workspace document in the Mac's default app, with a notice; off: never. Applies now"),
        ("ssh_agent", SettingKey.sshAgent,
         "# ssh_agent: off             # on: forward this Mac's SSH agent (keys stay on the Mac; github.com:22 only). Applies now"),
        ("tmux", SettingKey.tmux,
         "# tmux: false                # true: sessions run inside tmux (windows, panes, Ctrl-b). From the next session"),
        ("ignore_mode", SettingKey.ignoreMode,
         "# ignore_mode: lock          # what .dozignore does to the paths it lists: lock (listed, no access) or hide (not there). At the next start or wake"),
        ("workspace_view", SettingKey.workspaceView,
         "# workspace_view: on         # on: /workspace through the live view (programs keep their folder across a wake); off: shared directly. At the next start"),
    ]

    /// The keys, in the order the file lists them, with what each says.
    public static let keys: [(key: String, summary: String)] = [
        ("version", "the file's format: 1"),
        ("name", "the sandbox: 1–40 of a-z 0-9 -"),
        ("image", "claude-code, pi, codex, lab, a base × agent image (python-claude-code, …), or a template (doz image ls) — or agent + base/dockerfile"),
        ("agent", "claude-code, pi, codex or none (default claude-code)"),
        ("base", "a recommended base: node, python, go, rust, java, ruby, dotnet, debian, ubuntu, alpine (doz base ls)"),
        ("dockerfile", "your Dockerfile (./Dockerfile): built with Apple's container build — its RUN steps run OUTSIDE Dozer's network policy"),
        ("cpus", "virtual CPUs, 1–64 (default: the settings' defaults.cpus)"),
        ("memory", "guest RAM: 2G, 512M or MiB (default: per image, in the settings)"),
        ("network", "agent, bake, locked, open (proxied), nat or none (default: per image)"),
        ("permissions", "what the agent may do on a proxied network: standard, locked, open, or changes on Standard like +web,-error-reports (doz net permissions; default: the setting defaults.permissions)"),
        ("account", "default (the store's), none, or an account name (doz account ls)"),
        ("sessions", "what `doz up` starts; the first is attached (default: the image's own)"),
        ("agent_prompt", "this project's own lines for the agent's environment prompt"),
        ("agent_prompt_mode", "append (to the template, the default) or replace"),
        ("agent_sudo", "true or false: the agent's passwordless sudo in the sandbox (default: the setting sandbox.agent_sudo, true)"),
        ("github", "off, read or push: git and gh signed in as you on GitHub — the permissions \"Use GitHub as you\" / \"Push to GitHub\" (default off; when the sandbox is made — later: doz net allow NAME github:as-you)"),
    ] + settingKeys.map { k in
        (k.key, "\(DozerSettings.definition(k.setting)?.type.name ?? "a value"): this sandbox's \(k.setting) (default: the setting)")
    }

    public struct Invalid: Error, LocalizedError, Equatable {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// The project file in `directory`, if there is one: `doz_project.yaml` or `doz_project.yml`. Both
    /// at once is an error (which one is meant is not guessed).
    public static func find(in directory: URL) throws -> URL? {
        let found = fileNames.map { directory.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if found.count > 1 {
            throw Invalid(message: "\(directory.path) has both \(fileName) and \(otherFileName) — keep one (remove or rename the other)")
        }
        return found.first
    }

    /// 599d: `github:` / `--github` as permission words (nil: not off, read or push).
    public static func gitHubWords(_ v: String?) -> [String]? {
        switch v?.lowercased() {
        case nil: return []
        case "off"?: return ["-" + AgentPermissions.gitHubAsYou, "-" + AgentPermissions.gitHubPush]
        case "read"?: return ["+" + AgentPermissions.gitHubAsYou, "-" + AgentPermissions.gitHubPush]
        case "push"?: return ["+" + AgentPermissions.gitHubAsYou, "+" + AgentPermissions.gitHubPush]
        default: return nil
        }
    }

    /// 599f: the networks the permissions apply to (a proxied network whose policy is permissions).
    public static let permissionNetworks = ["agent", "locked", "open"]

    /// What is wrong with this project as a whole (beyond each key's own rule), or nil — the ONE check
    /// the parser, `doz init` and the dashboard's wizard share. `network` (nil: this project's own) is the
    /// network it will get: given the settings, the image's default when the file names none.
    public func problem(effectiveNetwork: String? = nil) -> String? {
        if !WebNameCheck.isSandboxName(name) { return "name: 1–40 of a-z 0-9 - (not starting with -)" }
        if base != nil, dockerfile != nil { return "base or dockerfile — not both" }
        if let a = agent, !["claude-code", "pi", "codex", "none"].contains(a) { return "agent: claude-code, pi, codex or none" }
        if let b = base, BaseCatalogue.base(b) == nil { return "base: \(BaseCatalogue.ids.joined(separator: ", ")) (doz base ls)" }
        if let c = cpus, !(1...64).contains(c) { return "cpus: a whole number 1–64" }
        if let m = memoryMiB, !(256...262_144).contains(m) { return "memory: 256 MiB – 256 GiB" }
        if let n = network, !["agent", "bake", "locked", "open", "nat", "none"].contains(n) { return "network: agent, bake, locked, open, nat or none" }
        if let g = github, Self.gitHubWords(g) == nil { return "github: off, read or push" }
        if let w = permissions {
            guard SettingType.permissionWords(w.joined(separator: ",")) != nil else {
                return "permissions: standard, locked, open, or permissions like +web,-error-reports (doz net permissions)"
            }
            if w.contains(where: { $0.contains("github:") }) { return "permissions: GitHub is the github key (off, read or push)" }
        }
        let net = network ?? effectiveNetwork
        if let n = net, !Self.permissionNetworks.contains(n) {
            if permissions != nil { return "permissions apply to a network with permissions (agent, locked, open) — not \(n)" }
            if let g = github, g != "off" { return "github: \(g) needs a network with permissions (agent, locked, open) — not \(n)" }
        }
        return nil
    }

    /// 596: the image agent + base name (a Dockerfile's: the agent's, the host swaps in its base).
    public var chosenImage: String {
        let a: AgentKind = switch agent ?? "claude-code" { case "pi": .pi; case "codex": .codex; case "none": .none; default: .claudeCode }
        if dockerfile != nil { return ImageChoice(base: a == .none ? "alpine" : "node", agent: a).name }
        return ImageChoice(base: base ?? "node", agent: a).name
    }

    /// The file `doz init` and the wizard write: every key listed; the ones not set are commented (their defaults).
    public func render() -> String {
        func quoted(_ s: String) -> String {
            s.range(of: "^[A-Za-z0-9._/-]+$", options: .regularExpression) != nil ? s : "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var out = """
        # doz_project.yaml — a Dozer Sandbox project (written by doz init or the dashboard's New sandbox).
        # `doz up` in this folder creates, starts or wakes the sandbox below and attaches to its first
        # session. This folder is shared at /workspace. Unknown keys are errors; a commented key takes
        # its default (doz config show).
        #
        # When a change applies — `doz up` says what differs and what it did:
        #   image (agent, base, dockerfile), cpus, memory, network nat/none: when the sandbox is MADE —
        #     doz rm NAME && doz up recreates it (this folder is kept); permissions and github too;
        #   network agent/bake/locked/open: at the next doz up, live (unless you edited the policy);
        #   account: doz account use NAME ACCOUNT (from the next session);
        #   sessions: every doz up; agent_prompt, agent_sudo: from the next session.
        version: 1
        name: \(name)

        """
        // 596 (B10): the image as agent + base/dockerfile when the file said so, else by name.
        if agent != nil || base != nil || dockerfile != nil {
            out += "agent: \(agent ?? "claude-code")               # claude-code, pi, codex or none — when made\n"
            out += base.map { "base: \($0)                   # doz base ls — when made\n" } ?? "# base: node                 # doz base ls — or dockerfile — when made\n"
            out += dockerfile.map { "dockerfile: \(quoted($0))     # built with Apple's container build, OUTSIDE Dozer's network policy — when made\n" } ?? ""
        } else {
            out += "image: \(image)                  # when made\n"
            out += "# (or: agent: claude-code|pi|codex|none with base: python … or dockerfile: ./Dockerfile — doz base ls)\n"
        }
        out += "\n"
        out += cpus.map { "cpus: \($0)                     # when made\n" } ?? "# cpus: 2                    # when made\n"
        out += memoryMiB.map { "memory: \($0 % 1024 == 0 ? "\($0 / 1024)G" : "\($0)M")                 # when made\n" } ?? "# memory: 2G                 # when made\n"
        out += network.map { "network: \($0)\n" } ?? "# network: agent\n"
        out += """
        #   agent  — proxied: Anthropic's API and sign-in, Claude Code's own hosts, GitHub, package registries
        #            (what the agent may do: its permissions, below)
        #   bake   — proxied: package registries only (what an image bake needs)
        #   locked — proxied: nothing leaves the sandbox (DNS included)
        #   open   — proxied: every host allowed, every connection still logged
        #   nat    — a real network interface (vmnet), unfiltered and unlogged
        #   none   — no network at all
        #   (proxied: no network interface; every connection judged by the policy on the Mac and logged)

        """
        out += permissions.map { "permissions: \(quoted($0.joined(separator: ",")))\n" }
            ?? "# permissions: standard      # or locked, open, or changes like +web,-error-reports (doz net permissions) — when made\n"
        out += account.map { "account: \(quoted($0))\n" } ?? "# account: default          # default (the store's), none, or an account name\n"
        if sessions.isEmpty {
            out += """
            # sessions:                 # what doz up starts; the first is attached (default: the image's own)
            #   - claude
            #   - name: server
            #     command: npm run dev

            """
        } else {
            out += "sessions:\n"
            for s in sessions {
                if let c = s.command { out += "  - name: \(s.name)\n    command: [\(c.map(quoted).joined(separator: ", "))]\n" }
                else { out += "  - \(s.name)\n" }
            }
        }
        if let a = agentPrompt {
            // `|-` when the text has no final newline: it reads back exactly (599f: every choice round-trips).
            let body = a.hasSuffix("\n") ? String(a.dropLast()) : a
            out += "agent_prompt: |\(a.hasSuffix("\n") ? "" : "-")\n" + body.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n") + "\n"
        } else {
            out += """
            # agent_prompt: |           # this project's own lines for the agent (see doz inspect NAME --prompt)
            #   The tests run with `make test`.

            """
        }
        out += agentPromptMode.map { "agent_prompt_mode: \($0)\n" } ?? "# agent_prompt_mode: append  # or replace\n"
        out += agentSudo.map { "agent_sudo: \($0)\n" }
            ?? "# agent_sudo: true           # the agent's passwordless sudo (apt-get install …); false: none. From the next session\n"
        out += github.map { "github: \($0)\n" }
            ?? "# github: off                # read: git and gh signed in as you on GitHub (read-only); push: also push. When the sandbox is made\n"
        for k in Self.settingKeys {
            out += settings[k.setting].map { "\(k.key): \($0.plain)\n" } ?? k.comment + "\n"
        }
        return out
    }

    /// The create options this project gives a new sandbox (the folder is its workspace).
    /// `settings`: a file that sets `permissions` but not `github` keeps the Access step's GitHub default
    /// (`defaults.github`, 599e) — the permissions are given on Standard, which would otherwise drop it.
    public func createOptions(folder: URL, file: URL, settings given: DozerSettings? = nil) -> CreateOptions {
        var o = CreateOptions(image: image, cpus: cpus, memoryMiB: memoryMiB, workspace: folder.path, network: network, account: account)
        o.agentPrompt = agentPrompt
        o.agentPromptMode = agentPromptMode
        o.agentSudo = agentSudo
        o.settings = settings.isEmpty ? nil : settings
        // 599f: permissions: words on Standard (a preset word replaces it); 599d: github: → its two permissions.
        var words: [String] = []
        if let p = permissions {
            words = p == ["standard"] || p == ["locked"] || p == ["open"] ? p : ["standard"] + p
        }
        var gh = github
        if gh == nil, permissions != nil {
            gh = (given ?? .load()).string(SettingKey.defaultGithub).flatMap { $0 == "off" ? nil : $0 }
        }
        words += Self.gitHubWords(gh) ?? []
        if !words.isEmpty { o.allow = words }
        o.project = file.path
        // 596 (B6): a Dockerfile relative to this folder (its folder is the build context).
        if let d = dockerfile {
            let expanded = (d as NSString).expandingTildeInPath
            o.dockerfile = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : URL(fileURLWithPath: expanded, relativeTo: folder)).standardizedFileURL.path
        }
        return o
    }

    /// A sandbox name from a folder's name: lower-cased, runs of anything else become `-`.
    public static func suggestedName(for folder: URL) -> String {
        var s = ""
        for ch in folder.lastPathComponent.lowercased() {
            if ("a"..."z").contains(ch) || ("0"..."9").contains(ch) { s.append(ch) }
            else if s.last != "-" { s.append("-") }
        }
        s = String(s.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40))
        return s.isEmpty ? "project" : s
    }

    /// 599f: the network a new sandbox of this project gets when the file names none — the image's
    /// network setting, else the image's own default (an agent image: agent; lab: bake).
    public func effectiveNetwork(settings: DozerSettings) -> String {
        if let n = network { return n }
        let section = DozerSettings.imageSection(imageSpecName: image == "lab" ? nil : image)
        return settings.string(SettingKey.network(section)) ?? (section == "lab" ? "bake" : "agent")
    }

    /// 599f: what the file sets differently from the settings' defaults is kept; a value EQUAL to its
    /// default (as the wizard and `doz init` pre-fill it) is left out, so the file follows the settings.
    /// `explicit` names the keys the person set on purpose (or the existing file set): those are kept.
    public mutating func dropDefaults(settings: DozerSettings, explicit: Set<String>) {
        let section = DozerSettings.imageSection(imageSpecName: image == "lab" ? nil : image)
        if !explicit.contains("cpus"), cpus == settings.int(SettingKey.cpus) { cpus = nil }
        if !explicit.contains("memory"), let m = memoryMiB, m == UInt64(settings.int(SettingKey.memory(section))) { memoryMiB = nil }
        if !explicit.contains("network"), network == settings.string(SettingKey.network(section)) { network = nil }
        if !explicit.contains("permissions"), let p = permissions,
           p == (SettingType.permissionWords(settings.string(SettingKey.permissions) ?? "standard") ?? ["standard"]) { permissions = nil }
        if !explicit.contains("account"), account == "default" { account = nil }
        // 599e: the GitHub default is the Access step's (defaults.github).
        if !explicit.contains("github"), github == (settings.string(SettingKey.defaultGithub) ?? "off") { github = nil }
        if !explicit.contains("agent_sudo"), agentSudo == settings.bool(SettingKey.agentSudo) { agentSudo = nil }
        for k in Self.settingKeys where !explicit.contains(k.key) {
            if let v = self.settings[k.setting], v == settings.resolve(k.setting).value { self.settings[k.setting] = nil }
        }
    }

    /// 599f: two texts line by line — each line `"  "` (both), `"- "` (only the old) or `"+ "` (only the
    /// new). For the confirmation before an existing project file is replaced.
    public static func lineDiff(old: String, new: String) -> [String] {
        let a = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let b = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard a.count * b.count <= 4_000_000 else { return a.map { "- " + $0 } + b.map { "+ " + $0 } }
        // Longest common subsequence, then walk it.
        var l = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                l[i][j] = a[i] == b[j] ? l[i + 1][j + 1] + 1 : max(l[i + 1][j], l[i][j + 1])
            }
        }
        var out: [String] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { out.append("  " + a[i]); i += 1; j += 1 }
            else if i < a.count, j == b.count || l[i + 1][j] >= l[i][j + 1] { out.append("- " + a[i]); i += 1 }
            else { out.append("+ " + b[j]); j += 1 }
        }
        return out
    }
}

/// 599f (owner: "a new wizard process for creating a purposeful sandbox that steps the user through all the
/// choices, capturing the config in a doz_project.yml"): the steps the dashboard's New Sandbox wizard and
/// `doz init` on a terminal walk, in order — one list for both. 599g: "rules" (the folder's .dozignore /
/// .dozreadonly and this sandbox's `ignore_mode`, `WorkspaceRulesGuide`).
public enum ProjectWizard {
    public static let steps: [(id: String, title: String)] = [
        ("folder", "Project folder"),
        ("image", "Agent and base"),
        ("account", "Account"),
        ("access", "Access"),
        ("rules", "Workspace rules"),
        ("permissions", "Permissions and network"),
        ("resources", "Resources"),
        ("bridges", "Bridges"),
        ("session", "Session"),
        ("review", "Review"),
    ]
}
