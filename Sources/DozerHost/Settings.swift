import Darwin
import Foundation
import DozerKit

// 591 settings (owner request): ONE closed, typed schema of every user-facing setting, a TOML file
// generated from it (`${XDG_CONFIG_HOME:-~/.config}/dozer-sandbox/doz.toml` — the product is
// Dozer Sandbox since 592), and one resolution rule everywhere:
//
//     a command-line flag  >  its environment variable  >  the file  >  the default
//
// and every value knows which of the four it came from. The file lists every setting, each with a
// `# description` and a commented `# key = <default>`; only the values a person set are uncommented.
// It is written whole (from the schema, never edited in place), atomically, 0600 in a 0700 directory.
// An unknown key or a value of the wrong type is a WARNING (that line is ignored, the default applies),
// never a crash; a file that does not parse is ignored whole, with its error, and is not overwritten.
//
// What is deliberately NOT a setting (`DozerSettings.notSettable`): the web UI's security limits
// (session and link lifetimes, body and connection caps, the Host/Origin/CSRF checks, the CSP), the
// terminal's (one-use tickets, the paste cap and confirmation), the guest-binary overrides, and any
// credential. `ui.terminals` can only take something away (browser terminals off).

/// A setting's type — closed; every value is validated against it before it is used or written.
public enum SettingType: Sendable, Equatable {
    case bool
    case int(ClosedRange<Int>)
    case choice([String])
    /// A host path; `""` = automatic. Never editable from the web UI (it names no host path).
    case path
    /// An IPv4 CIDR for vmnet (`192.168.64.0/24`); `""` = a free one.
    case subnet
    /// 594: a package version — `latest` (resolved when an image is prepared) or an exact `1.2.3`.
    case version
    /// 594 W10: `mac` (follow this Mac's zone) or an IANA zone name (`Australia/Sydney`).
    case timeZone
    /// 597: a preset (`standard`, `locked`, `open`), or permission ids separated by commas, each
    /// optionally `+`/`-` on the Standard set (`+web`, `-error-reports`, `install:python`).
    case permissions

    /// 597: a permissions setting's words, checked (nil: not a valid value).
    public static func permissionWords(_ s: String) -> [String]? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if ["standard", "locked", "open"].contains(t) { return [t] }
        let words = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 32 else { return nil }
        for w in words {
            let id = (w.hasPrefix("+") || w.hasPrefix("-")) ? String(w.dropFirst()) : w
            guard AgentPermissions.isValid(id) else { return nil }
        }
        return words
    }

    /// 599 (594.B4): a terminal title — text with `{sandbox}` `{session}` `{image}` `{time}` `{phase}`
    /// (a closed set), ≤ 120 characters, no control character; `""` = leave the title alone.
    case titleTemplate
    /// 599b: Mac app names, comma-separated (`Typora, Visual Studio Code`) — `WorkspaceFiles.appNames`;
    /// `""` = none.
    case appList
    /// 606: where `doz serve` listens — `lan`, `loopback`, or the Mac's addresses separated by commas.
    case serveBind
    /// 606: external origins, comma-separated (`https://doz.home.example`); `""` = none.
    case originList
    /// 606: addresses or networks, comma-separated (`127.0.0.1, 192.168.1.0/24, fd00::/8`); `""` = none.
    case addressList

    /// The variables a title may use.
    public static let titleVariables = ["sandbox", "session", "image", "time", "phase"]

    /// Why `s` is not a title template, or nil.
    public static func titleTemplateProblem(_ s: String) -> String? {
        guard s.count <= 120 else { return "at most 120 characters" }
        guard !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value) }) else {
            return "no control characters"
        }
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { return "a { without its }" }
            let name = String(rest[rest.index(after: open)..<close])
            guard titleVariables.contains(name) else { return "{\(name)} is not a variable (they are {\(titleVariables.joined(separator: "} {"))})" }
            rest = rest[rest.index(after: close)...]
        }
        return rest.contains("}") ? "a } without its {" : nil
    }

    /// An IANA zone name this Mac knows (plain characters only — it becomes a guest file's content).
    public static func isTimeZoneName(_ s: String) -> Bool {
        s.count <= 64 && s.range(of: #"^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$"#, options: .regularExpression) != nil
            && TimeZone(identifier: s) != nil
    }

    public var name: String {
        switch self {
        case .bool: "boolean"
        case .int(let r): "integer \(r.lowerBound)–\(r.upperBound)"
        case .choice(let c): c.joined(separator: " | ")
        case .path: "path (\"\" = automatic)"
        case .subnet: "IPv4 subnet, a.b.c.d/nn (\"\" = a free one)"
        case .version: "latest, or an exact version like 2.1.227"
        case .timeZone: "mac, or a time zone like Australia/Sydney"
        case .permissions: "standard | locked | open, or permissions like +web,-error-reports (doz net permissions)"
        case .titleTemplate: "a title with {sandbox} {session} {image} {time} {phase} (\"\" = leave the title alone)"
        case .appList: "app names, comma-separated, like \"Typora, Visual Studio Code\" (\"\" = none)"
        case .serveBind: "lan | loopback | the Mac's addresses, comma-separated"
        case .originList: "origins like https://doz.home.example, comma-separated (\"\" = none)"
        case .addressList: "addresses or networks like 127.0.0.1, 192.168.1.0/24, comma-separated (\"\" = none)"
        }
    }

    /// `1.2.3`, optionally `-pre.1` / `+build` — what npm publishes (never a range).
    public static func isExactVersion(_ s: String) -> Bool {
        s.count <= 64 && s.range(of: #"^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil
    }
}

/// Where an effective value came from.
public enum SettingSource: String, Codable, Sendable {
    case flag, env, file
    case `default`
}

/// When a changed value takes effect.
public enum SettingApplies: String, Codable, Sendable, CaseIterable {
    case now = "now"
    case nextCommand = "next-command"
    case nextCreate = "next-create"
    case nextSession = "next-session"
    case hostRestart = "host-restart"
    case newStore = "new-store"
    case nextBoot = "next-boot"
    /// 594 W10: at each sandbox's next start or wake.
    case nextStartOrWake = "next-start-or-wake"
    /// 605: when doz ui starts again (`doz ui restart`).
    case uiRestart = "ui-restart"
    /// 606: when doz serve starts again.
    case serveRestart = "serve-restart"
    /// 608: at each sandbox's next start (a cold boot — never under running programs).
    case nextStart = "next-start"

    public var note: String {
        switch self {
        case .now: "applies at once (the UI re-reads it)"
        case .nextCommand: "applies to the next doz command (a running doz ui keeps its store)"
        case .nextCreate: "applies to sandboxes created from now on (the host reads it at create)"
        case .nextSession: "applies to sessions opened from now on"
        case .hostRestart: "applies after doz host stop (the next host reads it)"
        case .newStore: "the choice for a store that has not made one (doz account keepalive wins)"
        case .nextBoot: "applies when the next boot of a sandbox is kept"
        case .nextStartOrWake: "applies at each sandbox's next start or wake"
        case .uiRestart: "applies when doz ui starts again (doz ui restart)"
        case .serveRestart: "applies when doz serve starts again"
        case .nextStart: "applies at each sandbox's next start (a running one keeps what it has)"
        }
    }
}

public struct SettingDefinition: Sendable {
    public let section: String
    public let name: String
    public let type: SettingType
    public let defaultValue: TOMLValue
    public let summary: String
    /// The environment variable that overrides the file (nil: none).
    public let environment: String?
    /// The command-line flag that overrides both, as a person types it (nil: none).
    public let flag: String?
    public let applies: SettingApplies
    /// False: the web UI shows it read-only (host paths — the UI never names one).
    public let editableInUI: Bool

    public var key: String { "\(section).\(name)" }

    init(_ section: String, _ name: String, _ type: SettingType, _ defaultValue: TOMLValue, _ summary: String,
         env: String? = nil, flag: String? = nil, applies: SettingApplies, ui: Bool = true) {
        self.section = section
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
        self.summary = summary
        environment = env
        self.flag = flag
        self.applies = applies
        editableInUI = ui
    }

    /// Check a typed value (from the file, the UI or the CLI). Throws a message that never echoes
    /// more than the value's type.
    public func validate(_ v: TOMLValue) throws -> TOMLValue {
        switch (type, v) {
        case (.bool, .bool): return v
        case (.int(let r), .int(let i)):
            guard r.contains(i) else { throw SettingsError("\(key) is \(r.lowerBound)–\(r.upperBound)") }
            // 605: a fixed dashboard port is an unprivileged one (0 = automatic).
            if key == SettingKey.uiPort, (1...1023).contains(i) { throw SettingsError("\(key) is 0 (automatic) or a port 1024–65535") }
            return v
        case (.choice(let c), .string(let s)):
            guard c.contains(s) else { throw SettingsError("\(key) is one of \(c.joined(separator: ", "))") }
            return v
        case (.path, .string(let s)):
            guard s.utf8.count <= 1024, !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                throw SettingsError("\(key) is a path (at most 1024 bytes, no control characters)")
            }
            guard s.isEmpty || s.hasPrefix("/") || s.hasPrefix("~") else { throw SettingsError("\(key) is an absolute path (or ~/…), or \"\"") }
            return v
        case (.subnet, .string(let s)):
            guard s.isEmpty || Self.isSubnet(s) else { throw SettingsError("\(key) is an IPv4 subnet like 192.168.64.0/24, or \"\"") }
            return v
        case (.version, .string(let s)):
            guard s == "latest" || SettingType.isExactVersion(s) else { throw SettingsError("\(key) is latest, or an exact version like 2.1.227") }
            return v
        case (.timeZone, .string(let s)):
            guard s == "mac" || SettingType.isTimeZoneName(s) else { throw SettingsError("\(key) is mac, or a time zone like Australia/Sydney") }
            return v
        case (.permissions, .string(let s)):
            guard SettingType.permissionWords(s) != nil else { throw SettingsError("\(key) is standard, locked, open, or permissions like +web,-error-reports (doz net permissions)") }
            return v
        case (.titleTemplate, .string(let s)):
            if let why = SettingType.titleTemplateProblem(s) { throw SettingsError("\(key): \(why)") }
            return v
        case (.serveBind, .string(let s)):
            guard ServeSettingValues.isBind(s) else { throw SettingsError("\(key) is lan, loopback, or the Mac's own addresses separated by commas (no wildcard, no link-local address)") }
            return v
        case (.originList, .string(let s)):
            guard ServeSettingValues.isOriginList(s) else { throw SettingsError("\(key) is origins like https://doz.home.example (no path), separated by commas, or \"\"") }
            return v
        case (.addressList, .string(let s)):
            guard ServeSettingValues.isAddressList(s) else { throw SettingsError("\(key) is addresses or networks like 127.0.0.1 or 192.168.1.0/24, separated by commas, or \"\"") }
            return v
        case (.appList, .string(let s)):
            guard WorkspaceFiles.appNames(s) != nil else {
                throw SettingsError("\(key) is app names separated by commas (at most 16, each 1–64 characters, no / or ;), or \"\"")
            }
            return v
        default:
            throw SettingsError("\(key) is a \(type.name), not a \(v.typeName)")
        }
    }

    /// A value as a person types it (`doz config set`, an environment variable) → typed + checked.
    public func parse(_ text: String) throws -> TOMLValue {
        let t = text.trimmingCharacters(in: .whitespaces)
        switch type {
        case .bool:
            switch t.lowercased() {
            case "true", "on", "yes", "1": return .bool(true)
            case "false", "off", "no", "0": return .bool(false)
            default: throw SettingsError("\(key) is true or false")
            }
        case .int:
            guard let i = Int(t) else { throw SettingsError("\(key) is a whole number") }
            return try validate(.int(i))
        case .choice, .path, .subnet, .version, .timeZone, .permissions, .appList, .serveBind, .originList, .addressList:
            return try validate(.string(t))
        case .titleTemplate:
            return try validate(.string(text))          // its spaces are its own
        }
    }

    static func isSubnet(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let bits = Int(parts[1]), (8...30).contains(bits) else { return false }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { o in
            !o.isEmpty && o.count <= 3 && o.allSatisfy(\.isASCII) && Int(o).map { (0...255).contains($0) } == true
        }
    }
}

public struct SettingsError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A setting's effective value and where it came from.
public struct ResolvedSetting: Sendable {
    public let definition: SettingDefinition
    public let value: TOMLValue
    public let source: SettingSource
    /// What the file sets, when it sets a valid value (even when a flag or the environment wins).
    public let fileValue: TOMLValue?
    public var key: String { definition.key }
}

/// One setting as `doz config show --json` and the UI's Settings page see it. Never a secret:
/// the schema has none.
public struct SettingRow: Codable, Equatable, Sendable {
    public var key: String
    public var section: String
    public var name: String
    public var value: TOMLValue
    public var defaultValue: TOMLValue
    public var source: SettingSource
    public var fileValue: TOMLValue?
    /// bool · int · choice · path · subnet
    public var type: String
    public var typeName: String
    public var choices: [String]?
    public var min: Int?
    public var max: Int?
    public var description: String
    public var environment: String?
    public var flag: String?
    public var applies: SettingApplies
    public var appliesNote: String
    /// The UI may change it: not a host path, not set by the environment or a flag, the file parses.
    public var editable: Bool
    /// Why it is read-only in the UI, when it is.
    public var note: String?
}

public struct SettingsReport: Codable, Equatable, Sendable {
    public var path: String?
    public var exists: Bool
    public var warnings: [String]
    public var error: String?
    public var settings: [SettingRow]
    public var notSettable: [String]
}

/// The names of the settings, for the code that reads them.
public enum SettingKey {
    public static let bootViewOnStart = "ui.boot_view_on_start"
    public static let confirmShutdown = "ui.confirm_shutdown"
    public static let splitDefault = "ui.split_default"
    public static let terminals = "ui.terminals"
    /// 599 (594.B4): the terminal title template.
    public static let terminalTitle = "ui.terminal_title"
    public static let terminalFontSize = "ui.terminal_font_size"
    public static let theme = "ui.theme"
    public static let detailsOpen = "ui.details_open"
    public static let gridLiveTiles = "ui.grid_live_tiles"
    public static let gridTileSize = "ui.grid_tile_size"
    public static let progress = "ui.progress"
    public static let idleTimeout = "host.idle_timeout_minutes"
    public static let screenCapture = "host.screen_capture_minutes"
    public static let bootLogsKept = "host.boot_logs_kept"
    public static let keepalive = "host.keepalive"
    public static let storePath = "store.path"
    public static let claudePermissions = "claude.permissions"
    public static let cpus = "defaults.cpus"
    public static let natSubnet = "defaults.nat_subnet"
    /// 594: the image `doz up`/`doz init`/the UI's create form use when none is named; the account
    /// a store that has not chosen one defaults to (`doz account default` wins once it has).
    public static let defaultImage = "defaults.image"
    public static let defaultAccount = "defaults.account"
    /// 594 (D16): the environment prompt (the facts block and the dozer skill) — on, or off.
    public static let agentPrompt = "agent.prompt"
    /// 594 W23: the agent's passwordless sudo inside its sandbox (default on).
    public static let agentSudo = "sandbox.agent_sudo"
    /// 594 W10: the sandboxes' time zone (`mac` or an IANA name).
    public static let timeZone = "sandbox.timezone"
    /// 597: the permissions of a new proxied sandbox.
    public static let permissions = "defaults.permissions"
    /// 599 (594.B1): the clipboard bridge — `write` or `off`.
    public static let clipboard = "sandbox.clipboard"
    /// 599 (594.B2): the browser bridge (open a URL on the Mac; a sign-in's callback) — `on` or `off`.
    public static let browserBridge = "sandbox.browser_bridge"
    /// 599 (594.B3): new sessions run inside tmux.
    public static let tmux = "sessions.tmux"
    /// 599b: the file bridge — a /workspace document opened on the Mac — `on` or `off`.
    public static let openFiles = "sandbox.open_files"
    /// 599b: the apps a sandbox may name to open a workspace file in (`doz-open --app NAME`).
    public static let openApps = "bridges.open_apps"
    /// 599d: where "Use GitHub as you" gets the user's token — `gh` (the Mac's gh login), `key` (only a
    /// token given with `doz key set NAME --github`), `off`.
    public static let githubCredentials = "github.credentials"
    /// 599d (G4): forward the Mac's SSH agent into the sandbox — `off` or `on` (per sandbox).
    public static let sshAgent = "sandbox.ssh_agent"
    /// 599g: what a workspace's `.dozignore` does to the paths it selects — `lock` or `hide` (per sandbox).
    public static let ignoreMode = "workspace.ignore_mode"
    /// 608: every share through the live view (on) or the plain share without rules (off).
    public static let workspaceView = "workspace.view"
    /// 599e: "Use GitHub as you" for NEW sandboxes — `off`, `read` or `push` (the Access step's choice).
    public static let defaultGithub = "defaults.github"
    /// 594 (owner ruling): the web UI may take an API key or a setup token (a masked field).
    public static let allowSecretEntry = "ui.allow_secret_entry"
    /// 594 W19 (owner: "a new web page opening up every time i run doz ui"): when `doz ui` opens a tab.
    public static let openBrowser = "ui.open_browser"
    /// 605 (owner Q10): the loopback port `doz ui` listens on — 0 = automatic (the last one, when free).
    public static let uiPort = "ui.port"
    /// 606: `doz serve`, the dashboard for the other browsers of the LAN.
    public static let servePort = "serve.port"
    public static let serveBind = "serve.bind"
    public static let servePublicOrigins = "serve.public_origins"
    public static let serveTrustedProxies = "serve.trusted_proxies"
    public static let serveAdvertise = "serve.advertise"
    /// 594: where the UI's new sandboxes get their workspace by default (`<projects_dir>/<name>`).
    public static let projectsDir = "defaults.projects_dir"
    public static let kernelPath = "kernel.path"
    public static let kernelCache = "kernel.cache"
    /// 595 (R4): Clean up removes a prepared image no sandbox was created from in this many days.
    public static let resourcesUnusedDays = "resources.clean_unused_days"
    /// 611: updates — off | notify | auto, and the channel (stable | beta | canary).
    public static let updatesMode = "updates.mode"
    public static let updatesChannel = "updates.channel"
    /// Anonymous usage statistics of an official build (on by default; a build from the repository sends nothing).
    public static let sendUsageStats = "telemetry.send_anonymous_usage_stats"
    /// `images.<lab|claude-code|pi>.memory_mib` / `.network`.
    public static func memory(_ image: String) -> String { "images.\(image).memory_mib" }
    public static func network(_ image: String) -> String { "images.\(image).network" }
    /// 594 (owner: "install (optionally) latest claude code (default true)"): the agent's version an
    /// image is prepared with — `latest` (resolved at preparation time) or an exact one.
    public static let claudeCodeVersion = "images.claude_code_version"
    public static let piVersion = "images.pi_version"
    /// 599i: Codex — its version, and whether its approvals and own sandbox are skipped (the VM is the sandbox).
    public static let codexVersion = "images.codex_version"
    public static let codexPermissions = "codex.permissions"
    /// rc.3: run the Mac's own codex near its login's expiry while a sandbox uses it (`mac` for Codex).
    public static let codexKeepAlive = "codex.keep_alive"
    public static func agentVersion(_ image: String) -> String? {
        switch image { case "claude-code": claudeCodeVersion; case "pi": piVersion; case "codex": codexVersion; default: nil }
    }
}

public struct DozerSettings: Sendable {
    public static let directoryName = "dozer-sandbox"
    public static let fileName = "doz.toml"

    // MARK: the schema

    static let networks = ["agent", "bake", "locked", "open", "nat", "none"]

    /// Every setting, in file order. CLOSED: a key not here is unknown everywhere (file, CLI, UI).
    public static let schema: [SettingDefinition] = {
        var s: [SettingDefinition] = [
            .init("ui", "boot_view_on_start", .bool, .bool(true),
                  "Start opens a terminal on the boot sequence (the kernel console) until the sandbox is up; false: Start just starts it.",
                  applies: .now),
            .init("ui", "confirm_shutdown", .bool, .bool(true),
                  "Shut Down asks first (its dialog's \"don't ask again\" sets this to false). Reset and Remove always ask for the name.",
                  applies: .now),
            .init("ui", "split_default", .choice(["shell", "watch", "attach", "dialog"]), .string("shell"),
                  "What a terminal's Split opens: shell (a new shell session), watch (a read-only view of the left terminal's session), attach (a second, shared view of it), dialog (choose each time).",
                  applies: .now),
            .init("ui", "terminals", .bool, .bool(true),
                  "Terminals in the browser. false: the UI opens none and refuses a terminal ticket (Terminal.app still works).",
                  applies: .now),
            .init("ui", "terminal_title", .titleTemplate, .string("{sandbox} · {session} · {time}"),
                  "The title doz attach gives your terminal (window or tab) while attached, and a doz ui terminal's tab: {sandbox} {session} {image} {time} (this Mac's, HH:MM, refreshed each minute) {phase}. The terminal's own title comes back when you detach (where the terminal keeps a title stack: iTerm2, Ghostty, kitty, xterm). While doz sets it, a session's own title is not shown; \"\" leaves the title to the session.",
                  applies: .now),
            .init("ui", "terminal_font_size", .int(9...32), .int(13),
                  "The browser terminal's font size, in points (a terminal opened from now on).",
                  applies: .now),
            .init("ui", "theme", .choice(["auto", "light", "dark"]), .string("auto"),
                  "The UI's colours: auto follows macOS.",
                  applies: .now),
            .init("ui", "details_open", .bool, .bool(true),
                  "A sandbox's page shows its details panel (sessions, restore points, network, keys) beside the terminals; false: collapsed.",
                  applies: .now),
            .init("ui", "allow_secret_entry", .bool, .bool(true),
                  "The web UI takes an Anthropic API key or a Claude setup token in a masked field — an account (the setup wizard, Accounts & keys: stored exactly as doz account add stores it, the login keychain) or a sandbox's own key (its page: exactly as doz key set does, held by the host) — sent once, in a request body. false: the pages show the command instead. The UI can turn this off, never on.",
                  applies: .now),
            .init("ui", "open_browser", .choice(["auto", "always", "never"]), .string("auto"),
                  "When doz ui opens a browser tab: auto (only when no page of this store's UI is open — an open page reconnects by itself instead), always (every start), never (it prints the address; doz ui link opens a page). --open and --no-open override it.",
                  applies: .nextCommand),
            .init("ui", "port", .int(0...65_535), .int(0),
                  "The port doz ui listens on, always on 127.0.0.1 (this Mac only): 0 = automatic (the port this store's last doz ui had, when it is free — else one the system picks, and doz ui says so), or a fixed port 1024–65535 (doz ui refuses to start, naming the program, when another holds it). An installed dashboard app belongs to one port: keep it fixed for one.",
                  env: "DOZ_UI_PORT", flag: "--port N", applies: .uiRestart),
            .init("ui", "grid_live_tiles", .int(1...12), .int(8),
                  "All sessions: at most this many tiles show their session live at once (each is a terminal engine and a socket); the rest say so.",
                  applies: .now),
            .init("ui", "grid_tile_size", .choice(["small", "medium", "large"]), .string("medium"),
                  "All sessions: the size of a tile.",
                  applies: .now),
            .init("ui", "progress", .choice(["animated", "plain"]), .string("animated"),
                  "How a start, wake or bake shows its progress — in the web UI's boot view and in the CLI on a terminal: animated (a spinner on the step under way, download bars, the output's last lines) or plain (one line per step, and a summary line per download). Not a terminal, --json or NO_COLOR: always plain.",
                  env: "DOZ_PROGRESS", flag: "--progress auto|plain", applies: .now),
            // 606: doz serve. Read-only in the web UI (they decide who reaches the dashboard): doz config set on the Mac.
            .init("serve", "port", .int(1024...65_535), .int(7443),
                  "The port doz serve listens on — the dashboard for the other browsers of your network. It stays the same (an installed app and a bookmark belong to it): when another program holds it, doz serve refuses and names it.",
                  env: "DOZ_SERVE_PORT", flag: "doz serve --port N", applies: .serveRestart, ui: false),
            .init("serve", "bind", .serveBind, .string("lan"),
                  "Where doz serve listens: lan (every network interface of this Mac and Tailscale — never a sandbox's network), loopback (127.0.0.1 and ::1 only: for a reverse proxy on this Mac), or this Mac's own addresses separated by commas (for a reverse proxy elsewhere on your network).",
                  env: "DOZ_SERVE_BIND", flag: "doz serve --bind lan|loopback|ADDRESSES", applies: .serveRestart, ui: false),
            .init("serve", "public_origins", .originList, .string(""),
                  "The addresses your reverse proxy serves the dashboard at, like https://doz.home.example (comma-separated). A browser may use one only through a proxy listed in serve.trusted_proxies. Over https, keys and tokens may be typed in the dashboard; over plain http they never are.",
                  applies: .serveRestart, ui: false),
            .init("serve", "trusted_proxies", .addressList, .string(""),
                  "The reverse proxies whose X-Forwarded-Proto, X-Forwarded-Host and X-Forwarded-For doz serve believes — their addresses or networks, comma-separated (a proxy on this Mac: 127.0.0.1, ::1). From anyone else those headers are ignored.",
                  applies: .serveRestart, ui: false),
            .init("serve", "advertise", .bool, .bool(true),
                  "Announce doz serve on your network with Bonjour (\"Dozer on <this Mac>\", http://<this Mac>.local:<port>), so other Macs and phones can find it.",
                  applies: .serveRestart, ui: false),
            .init("host", "idle_timeout_minutes", .int(0...10_080), .int(5),
                  "Minutes with nothing running before the host exits; 0 = never.",
                  env: "DOZ_HOST_IDLE", flag: "doz host start --idle-timeout", applies: .hostRestart),
            .init("host", "screen_capture_minutes", .int(0...1440), .int(5),
                  "Every this many minutes, save the screen of each running sandbox's sessions that printed something since (what a sleep or hibernation falls back on); 0 = only when it pauses, sleeps or hibernates.",
                  env: "DOZ_SCREEN_CAPTURE", applies: .hostRestart),
            .init("host", "boot_logs_kept", .int(1...50), .int(BootLogs.defaultKept),
                  "How many boots of each sandbox to keep (its steps and kernel console — the web UI's Boot log, doz console --boot N); the oldest goes.",
                  env: "DOZ_BOOT_LOGS", applies: .nextBoot),
            .init("host", "keepalive", .bool, .bool(false),
                  "Near a Mac login's expiry, while a sandbox uses it and no Claude Code runs, the host runs the Mac's claude once to renew it.",
                  applies: .newStore),
            .init("store", "path", .path, .string("~/Library/Application Support/dozer-sandbox"),
                  "The store: images, kernels, sandboxes and the host's files.",
                  env: "DOZ_STORE", flag: "--store", applies: .nextCommand, ui: false),
            .init("claude", "permissions", .choice(["skip", "ask"]), .string("skip"),
                  "Claude Code in a claude-code sandbox: skip its permission prompts (the sandbox is the boundary), or ask as on a Mac.",
                  flag: "-e DOZ_CLAUDE_PERMISSIONS=… on run/exec", applies: .nextSession),
            .init("codex", "permissions", .choice(["skip", "ask"]), .string("skip"),
                  "Codex in a codex sandbox: skip its approvals and its own Linux sandbox (the VM is the boundary), or ask as on a Mac.",
                  flag: "-e DOZ_CODEX_PERMISSIONS=… on run/exec", applies: .nextSession),
            .init("codex", "keep_alive", .bool, .bool(false),
                  "Codex sandboxes on the account mac (this Mac's own Codex login): when its access token is about to expire and a sandbox used it in the last 15 minutes, run this Mac's codex doctor once — no model call — which renews the login the way Codex itself does. Off: the login renews only while Codex (the app or a codex session) runs on this Mac; when it has expired, Codex in a sandbox says so.",
                  applies: .now),
            .init("defaults", "cpus", .int(1...64), .int(2),
                  "CPUs of a new sandbox.",
                  flag: "doz create --cpus", applies: .nextCreate),
            .init("defaults", "nat_subnet", .subnet, .string(""),
                  "The vmnet subnet of a new --network nat sandbox.",
                  env: "DOZ_SUBNET", flag: "doz create --subnet", applies: .nextCreate),
            .init("defaults", "image", .choice(["lab", "claude-code", "pi", "codex"]), .string("lab"),
                  "The image of a new sandbox when none is named (doz up NAME, doz init, the UI's New sandbox). doz onboard writes the one you chose.",
                  flag: "doz create --image", applies: .nextCreate),
            .init("defaults", "projects_dir", .path, .string("~/dozer-sandbox-workspaces"),
                  "The base folder of new sandboxes' workspaces: the web UI's New sandbox and Quick add, and doz new, share <projects_dir>/<sandbox name> (created when missing, like any workspace). doz create is isolated unless --workspace; doz init uses the folder it runs in. In the web UI, Settings › Choose… sets it with the Mac's folder picker.",
                  applies: .nextCreate, ui: false),
            .init("defaults", "account", .choice(["mac", "none"]), .string("mac"),
                  "The Anthropic account of a store that has not chosen one: mac (this Mac's Claude Code login) or none. doz account default decides for a store once it has.",
                  applies: .newStore),
            .init("agent", "prompt", .bool, .bool(true),
                  "Tell the agent where it runs: a short facts block appended to its system prompt (the sandbox, its /workspace share, the network, credentials) and the dozer skill, written at every session start. Your own template: agent-prompt.md beside this file.",
                  applies: .nextSession),
            // 611: updates — the feed is updates.dozersandbox.com/v1/feed.json (signed; Distribution in Updates.swift).
            .init("updates", "mode", .choice(["off", "notify", "auto"]), .string("notify"),
                  "Updates: notify (at most once a day, and when doz ui opens, look for a newer doz and say how to upgrade — one line on a terminal, a banner on the dashboard), auto (also install it: brew upgrade, or the signed download for a tarball install — only while no sandbox runs and no session is attached, else it notifies; then: restart to apply, doz host restart), or off (never look). Never a downgrade; a feed that does not verify is ignored.",
                  env: "DOZ_UPDATES", applies: .nextCommand),
            .init("updates", "channel", .choice(["stable", "beta", "canary"]), .string("stable"),
                  "Which releases you are offered: stable, beta (beta and stable) or canary (every build, first). A Homebrew install's own formula (doz, doz-beta, doz-canary) decides while this is not set; doz upgrade --channel switches both.",
                  applies: .nextCommand),
            // Anonymous usage statistics (Usage.swift): the off switch — with DO_NOT_TRACK and the flags, checked before anything is recorded.
            .init("telemetry", "send_anonymous_usage_stats", .bool, .bool(true),
                  "Official builds send anonymous usage statistics: at most once a day, counts and ranges about how Dozer itself is used (commands by name, failures by exit code, which agents, bases and network presets new sandboxes use, setup sizes as ranges, start and wake times rounded to 50 ms, this Mac's macOS version, chip family, memory and cores as ranges) with a random install id — never a name, path, host, command argument, file or anything from inside a sandbox. false (or DO_NOT_TRACK=1, or --no-send-anonymous-usage-stats on one command) sends nothing and records nothing. doz telemetry show prints exactly what would be sent. Builds from the open-source repository send nothing whatever this says.",
                  env: "DOZ_SEND_ANONYMOUS_USAGE_STATS", flag: "--no-send-anonymous-usage-stats / --send-anonymous-usage-stats", applies: .nextCommand),
            .init("resources", "clean_unused_days", .int(1...3650), .int(30),
                  "Clean up (the Resources page, doz resources clean) removes a prepared image no sandbox was created from in this many days; it is prepared again when next needed.",
                  applies: .now),
            .init("sandbox", "agent_sudo", .bool, .bool(true),
                  "The agent (the image's user in claude-code and pi sandboxes) has passwordless sudo inside its sandbox, so it can install system packages (sudo apt-get install …). The VM, the network policy and the absent credentials are the boundary — root inside reaches no more than the agent does. Applied at every boot and every agent session start (no image is rebuilt); a sandbox's own choice (doz create --no-agent-sudo, agent_sudo in doz_project.yaml) wins over this.",
                  flag: "doz create --no-agent-sudo / --agent-sudo", applies: .nextSession),
            .init("sandbox", "timezone", .timeZone, .string("mac"),
                  "The sandboxes' time zone: mac (this Mac's, read again at every boot and wake — a laptop that travels while a sandbox sleeps is followed) or a zone like Australia/Sydney. Written to the guest's /etc/localtime; the agent's facts say it.",
                  applies: .nextStartOrWake),
            // 597 (P4): what a new proxied sandbox's agent may do.
            .init("defaults", "permissions", .permissions, .string("standard"),
                  "What a new sandbox's agent may do (its network, as permissions — doz net permissions): standard (talk to its AI model, update itself, install system packages and its base's language packages, use GitHub, send error reports), locked (its AI model only), open (everything, the web included), or standard with changes like +web,-error-reports. Stored by name: a Dozer update that adds a host to a permission reaches every sandbox that has it.",
                  flag: "doz create --allow / --network", applies: .nextCreate),
            .init("sandbox", "clipboard", .choice(["write", "off"]), .string("write"),
                  "The clipboard bridge: a program in a sandbox that copies (OSC 52 — Claude Code, vim, tmux) puts the text on this Mac's clipboard, and every copy shows a notice (SANDBOX copied N chars) in doz attach and doz ui. At most 1 MiB a copy and 10 copies in 10 s. A sandbox can never READ the Mac clipboard. The risk: an agent could put a command there for you to paste — off turns the bridge off (copies are dropped, and said). A sandbox's own choice (doz config set --sandbox NAME, clipboard in doz_project.yaml) wins over this.",
                  flag: "doz create --clipboard write|off", applies: .now),
            .init("sandbox", "browser_bridge", .choice(["on", "off"]), .string("on"),
                  "The browser bridge: xdg-open (and $BROWSER, open, sensible-browser) in a sandbox opens an http or https URL in this Mac's default browser, with a notice every time (at most 3 in 10 s). A sign-in whose redirect is the sandbox's localhost (Claude Code's /login) gets that port forwarded from the Mac into the sandbox for up to 10 minutes, so the login completes. Never file: or other schemes, never the Mac's own localhost. off: nothing opens (said). A sandbox's own choice (doz config set --sandbox NAME, browser_bridge in doz_project.yaml) wins over this.",
                  flag: "doz create --browser-bridge on|off", applies: .now),
            .init("sandbox", "open_files", .choice(["on", "off"]), .string("on"),
                  "Open workspace files on this Mac: xdg-open PATH (and open PATH, doz-open PATH) in a sandbox opens a document from its /workspace in the Mac's default app — an html page in your browser, markdown in your editor — or a folder (the workspace itself, open .) in the Finder, and doz-open --reveal PATH shows a file selected in its folder; a notice every time (at most 3 in 10 s). Only the shared folder's own files (a link or .. that leads out is refused), only documents (html, md, pdf, images, txt, csv, json, yaml, xml…) — never an app or package folder, a script, an installer or an executable. An isolated sandbox has no file to open. An app other than the default only when it is in bridges.open_apps. off: nothing opens (said). A sandbox's own choice (doz config set --sandbox NAME, open_files in doz_project.yaml) wins over this.",
                  flag: "doz create --open-files on|off", applies: .now),
            .init("sessions", "tmux", .bool, .bool(false),
                  "Run each new session inside tmux (within Dozer's own session holder, so saved screens, sleep and wake, browser terminals and Ctrl-] detach keep working): tmux's windows, panes and copy mode, its status bar and prefix key (Ctrl-b). tmux takes the mouse, and the kitty keyboard protocol and modifyOtherKeys do not fully pass through it; the session's exit code is tmux's. Needs tmux in the image (the built-in images this doz prepares have it; on an image an older doz prepared the session runs without it, and says so). A sandbox's own choice (doz create --tmux, tmux: true in doz_project.yaml, doz config set --sandbox) wins over this.",
                  flag: "doz create --tmux / --no-tmux", applies: .nextSession),
            .init("bridges", "open_apps", .appList, .string(""),
                  "The Mac apps a sandbox may name to open a workspace file in (doz-open --app NAME FILE, or open -a NAME FILE in the sandbox), comma-separated — e.g. \"Typora, Visual Studio Code\". Empty: a file opens only in its default app, and naming an app is refused. Never a path, only an app's name. For every sandbox.",
                  applies: .now),
            .init("sandbox", "ssh_agent", .choice(["off", "on"]), .string("off"),
                  "Forward this Mac's SSH agent into the sandbox (proxied sandboxes): ssh and git over SSH there can ask your agent to sign — your keys never enter the sandbox — and only github.com:22 is reachable over SSH. A notice on first use. While it is on, the agent can authenticate as you to github.com. A sandbox's own choice (doz create --ssh-agent on, ssh_agent in doz_project.yaml, doz config set --sandbox NAME) wins over this.",
                  flag: "doz create --ssh-agent on|off", applies: .now),
            .init("workspace", "ignore_mode", .choice(["lock", "hide"]), .string("lock"),
                  "What a .dozignore at the root of a sandbox's workspace folder does to the paths it lists (Docker's .dockerignore syntax): lock (they stay listed, shown with no permissions, and every read, write, rename or delete of them is refused — so a program that bumps into one by name sees why) or hide (they are not there at all). A .dozreadonly beside it (same syntax) makes paths visible but read-only; doz_project.yaml, .git/hooks and the two rule files are read-only too. Without either file the folder is shared as it is. A convenience mask, not a security boundary: root in the sandbox can get around it. A sandbox's own choice (doz create --ignore-mode, ignore_mode in doz_project.yaml, doz config set --sandbox NAME) wins over this.",
                  flag: "doz create --ignore-mode lock|hide", applies: .nextStartOrWake),
            .init("workspace", "view", .choice(["on", "off"]), .string("on"),
                  "How a sandbox's workspace folder reaches it. on: through Dozer's live view of the folder, so a program working in /workspace (an agent, a shell) keeps its folder when the sandbox wakes from hibernation or after a host restart. The view costs a little: the first scan of a big folder after a start or a wake is slower (e.g. git status on a large repository, or find), later ones are about as fast as without it. off: the folder is shared directly (a little faster) — but a program working inside /workspace loses its folder at such a wake and must be restarted (Codex says \"invalid cwd\"). A folder with a .dozignore or .dozreadonly always uses the view. Changes take effect at the sandbox's next start. A sandbox's own choice (doz create --workspace-view, workspace_view in doz_project.yaml, doz config set --sandbox NAME) wins over this.",
                  flag: "doz create --workspace-view on|off", applies: .nextStart),
            .init("defaults", "github", .choice(["off", "read", "push"]), .string("off"),
                  "\"Use GitHub as you\" for new sandboxes: off, read (git and gh signed in as you on GitHub, read-only) or push (also push and make changes) — the Access step's choice (doz access set --github). A sandbox can differ: doz create --github, github: in doz_project.yaml, or its permissions later (doz net allow|deny NAME github:as-you). Proxied sandboxes only.",
                  flag: "doz create --github off|read|push", applies: .nextCreate),
            .init("github", "credentials", .choice(["gh", "key", "off"]), .string("gh"),
                  "Where \"Use GitHub as you\" (a permission, off by default) gets your GitHub login: gh (this Mac's gh login, read when used — gh auth token — and kept in memory a few minutes, never written anywhere; gh auth logout revokes it), key (only a token you give a sandbox with doz key set NAME --github — a fine-grained token limited to some repositories is best), or off (never, even with the permission on). The sandbox only ever sees a placeholder; Dozer's proxy puts the real token in on the way to GitHub.",
                  applies: .now),
        ]
        s.append(.init("images", "claude_code_version", .version, .string("latest"),
                       "The Claude Code the claude-code image is prepared with: latest (asked of the npm registry when the image is prepared, then installed at that exact version, integrity-checked; a newer one is only said — doz image bake claude-code rebuilds when you choose) or an exact version like 2.1.227. A sandbox keeps the version it was created with; doz reset NAME moves it to the image's current one.",
                       applies: .nextCreate))
        s.append(.init("images", "pi_version", .version, .string("latest"),
                       "The pi coding agent the pi image is prepared with: latest or an exact version, as images.claude_code_version.",
                       applies: .nextCreate))
        s.append(.init("images", "codex_version", .version, .string("latest"),
                       "The OpenAI Codex CLI the codex image (and every base's Codex image) is prepared with: latest or an exact version like 0.160.1, as images.claude_code_version.",
                       applies: .nextCreate))
        for (image, memory, network) in [("lab", 1024, "bake"), ("claude-code", 2048, "agent"), ("pi", 2048, "agent"), ("codex", 2048, "agent")] {
            s.append(.init("images.\(image)", "memory_mib", .int(256...262_144), .int(memory),
                           "Memory (MiB) of a new \(image) sandbox (a custom image follows the image it was saved from).",
                           flag: "doz create --memory", applies: .nextCreate))
            s.append(.init("images.\(image)", "network", .choice(networks), .string(network),
                           "The network of a new \(image) sandbox: agent, bake, locked, open (proxied presets), nat or none.",
                           flag: "doz create --network", applies: .nextCreate))
        }
        s.append(.init("kernel", "path", .path, .string(""),
                       "An explicit Linux kernel for new sandboxes (\"\": the pinned kernel, fetched into the cache).",
                       env: "DOZ_KERNEL", applies: .nextCreate, ui: false))
        s.append(.init("kernel", "cache", .path, .string(""),
                       "Where the pinned kernel is cached (\"\": the store's own); share one between stores.",
                       env: "DOZ_KERNEL_CACHE", applies: .nextCreate, ui: false))
        return s
    }()

    public static func definition(_ key: String) -> SettingDefinition? { schema.first { $0.key == key } }

    /// 599: the settings a sandbox can also have its own value of (`doz config set --sandbox NAME KEY V`,
    /// `doz create`, `doz_project.yaml`) — the sandbox's value wins over the file's.
    public static let perSandbox: [String] = [SettingKey.clipboard, SettingKey.browserBridge, SettingKey.openFiles, SettingKey.sshAgent,
                                              SettingKey.tmux, SettingKey.agentSudo, SettingKey.ignoreMode,
                                              SettingKey.workspaceView]

    /// What cannot be set here, by design, and why — printed in the file and the docs.
    public static let notSettable: [String] = [
        "the web UI's limits: session lifetime (14 days unused), link lifetime (5 min), request body, connection and stream caps",
        "the web UI's checks: exact Host, Origin + CSRF on every change, the Content-Security-Policy",
        "the browser terminal's safety: one-use 30 s tickets, the 1 MiB paste cap and the unsafe-paste confirmation",
        "the guest binaries (DOZ_DECKHOLD / DOZ_DOZNET are developer overrides, environment only)",
        "credentials: keys and tokens live in the Keychain or the host's memory, never in this file (ui.allow_secret_entry only decides whether the web UI may take one)",
    ]

    // MARK: the file

    /// `${XDG_CONFIG_HOME:-$HOME/.config}/dozer-sandbox/doz.toml`. XDG_CONFIG_HOME counts only when
    /// absolute (the XDG rule). Nil when neither is set (then there is no file: defaults only).
    public static func fileURL(environment env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let base: URL
        if let x = env["XDG_CONFIG_HOME"], x.hasPrefix("/") {
            base = URL(fileURLWithPath: x, isDirectory: true)
        } else if let h = env["HOME"], h.hasPrefix("/") {
            base = URL(fileURLWithPath: h, isDirectory: true).appendingPathComponent(".config", isDirectory: true)
        } else {
            return nil
        }
        return base.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent(fileName)
    }

    public let url: URL?
    public let environment: [String: String]
    /// The file's valid, known values (key → value).
    public let fileValues: [String: TOMLValue]
    /// Keys the schema does not know, kept as they were when the file is rewritten.
    public let unknown: [TOMLEntry]
    public let warnings: [String]
    /// The file did not parse: none of it applies, and it is not overwritten.
    public let fileError: String?
    public let fileExists: Bool

    /// Read the file named by `environment` (defaults only when there is none).
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> DozerSettings {
        let url = fileURL(environment: environment)
        guard let url else { return DozerSettings(text: nil, url: nil, environment: environment) }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return DozerSettings(text: nil, url: url, environment: environment) }
        guard (st.st_mode & S_IFMT) == S_IFREG || (st.st_mode & S_IFMT) == S_IFLNK else {
            return DozerSettings(text: nil, url: url, environment: environment, readError: "\(url.path) is not a file")
        }
        guard st.st_size <= off_t(TOML.maximumBytes), let data = FileManager.default.contents(atPath: url.path) else {
            return DozerSettings(text: nil, url: url, environment: environment, readError: "\(url.path) could not be read (or is over 64 KiB)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return DozerSettings(text: nil, url: url, environment: environment, readError: "\(url.path) is not UTF-8")
        }
        return DozerSettings(text: text, url: url, environment: environment)
    }

    /// From a file's text (nil: no file).
    public init(text: String?, url: URL? = nil, environment: [String: String] = [:], readError: String? = nil) {
        self.url = url
        self.environment = environment
        var values: [String: TOMLValue] = [:]
        var unknown: [TOMLEntry] = []
        var warnings: [String] = []
        var fileError = readError
        if let text {
            do {
                for e in try TOML.parse(text) {
                    guard let d = Self.definition(e.path) else {
                        unknown.append(e)
                        warnings.append("line \(e.line): unknown setting \(e.path) — ignored")
                        continue
                    }
                    do { values[d.key] = try d.validate(e.value) } catch let err as SettingsError {
                        warnings.append("line \(e.line): \(err.message) — ignored, the default applies")
                    } catch {}
                }
            } catch let e as TOMLError {
                fileError = "\(url?.lastPathComponent ?? Self.fileName) \(e.description)"
            } catch {
                fileError = "\(error)"
            }
        }
        if let fileError {
            values = [:]
            unknown = []
            warnings.insert("\(fileError) — the file is ignored until it is fixed (or removed)", at: 0)
        }
        fileValues = values
        self.unknown = unknown
        self.warnings = warnings
        self.fileError = fileError
        fileExists = text != nil || readError != nil
    }

    // MARK: resolution

    /// A setting's effective value: `flag`, else its environment variable, else the file, else the default.
    /// An environment value that does not parse is skipped (as if unset). A fractional environment
    /// value of an integer setting (`DOZ_HOST_IDLE=0.5`) is kept as its text — the host reads it so.
    public func resolve(_ key: String, flag: TOMLValue? = nil) -> ResolvedSetting {
        guard let d = Self.definition(key) else { preconditionFailure("unknown setting \(key)") }
        let file = fileValues[key]
        if let flag { return ResolvedSetting(definition: d, value: flag, source: .flag, fileValue: file) }
        if let name = d.environment, let raw = environment[name], !raw.isEmpty {
            if let v = try? d.parse(raw) { return ResolvedSetting(definition: d, value: v, source: .env, fileValue: file) }
            if case .int = d.type, let x = Double(raw), x >= 0 {
                return ResolvedSetting(definition: d, value: .string(raw), source: .env, fileValue: file)
            }
        }
        if let file { return ResolvedSetting(definition: d, value: file, source: .file, fileValue: file) }
        return ResolvedSetting(definition: d, value: d.defaultValue, source: .default, fileValue: nil)
    }

    /// Every setting, resolved, in file order.
    public var all: [ResolvedSetting] { Self.schema.map { resolve($0.key) } }

    public func bool(_ key: String) -> Bool {
        if case .bool(let b) = resolve(key).value { return b }
        if case .bool(let b) = Self.definition(key)?.defaultValue { return b }
        return false
    }

    public func int(_ key: String) -> Int {
        let r = resolve(key)
        if case .int(let i) = r.value { return i }
        if case .string(let s) = r.value, let x = Double(s) { return Int(x) }
        if case .int(let i) = r.definition.defaultValue { return i }
        return 0
    }

    /// A string setting; nil when empty (`""` = automatic).
    public func string(_ key: String) -> String? {
        if case .string(let s) = resolve(key).value, !s.isEmpty { return s }
        return nil
    }

    /// The host's idle timeout in minutes: `--idle-timeout`, else `$DOZ_HOST_IDLE` (fractions
    /// allowed, as always), else the file, else 5.
    public func idleTimeoutMinutes(flag: Double?) -> Double {
        if let flag { return flag }
        if let raw = environment["DOZ_HOST_IDLE"], let x = Double(raw), x >= 0 { return x }
        return Double(int(SettingKey.idleTimeout))
    }

    /// The images section a sandbox's defaults come from: its imageSpec's (a custom image follows the
    /// image it was saved from), `lab` without one.
    /// 596: a base × agent image follows its AGENT's section (`python-pi` → `pi`; no agent → `claude-code`'s
    /// memory and network — a toolchain wants more than the lab's 1 GiB).
    public static func imageSection(imageSpecName: String?) -> String {
        switch imageSpecName {
        case nil: "lab"
        case "claude-code": "claude-code"
        case "pi": "pi"
        case "codex": "codex"
        case let n?: ImageChoice.parse(n)?.agent == .pi ? "pi" : ImageChoice.parse(n)?.agent == .codex ? "codex" : "claude-code"
        }
    }

    // MARK: reporting (doz config show --json, the UI's Settings page)

    /// Every setting with its value, default, source and description. `flags`: the values this
    /// process was given on its command line (only `store.path` can be: `--store`).
    public func report(flags: [String: TOMLValue] = [:]) -> SettingsReport {
        let rows = Self.schema.map { d -> SettingRow in
            let r = resolve(d.key, flag: flags[d.key])
            var kind = "string", choices: [String]?, lo: Int?, hi: Int?
            switch d.type {
            case .bool: kind = "bool"
            case .int(let range): kind = "int"; lo = range.lowerBound; hi = range.upperBound
            case .choice(let c): kind = "choice"; choices = c
            case .path: kind = "path"
            case .subnet: kind = "subnet"
            case .version: kind = "version"
            case .timeZone: kind = "timezone"
            case .permissions: kind = "permissions"
            case .titleTemplate: kind = "template"
            case .appList: kind = "apps"
            case .serveBind: kind = "bind"
            case .originList: kind = "origins"
            case .addressList: kind = "addresses"
            }
            var note: String?
            switch r.source {
            case .env: note = "set by $\(d.environment ?? "?") in this process's environment — change it there (the file's value, if any, is overridden)"
            case .flag: note = "set on this process's command line (\(d.flag ?? "a flag"))"
            case .file, .default: break
            }
            if !d.editableInUI, note == nil {
                // 599c: the projects folder has the web UI's Choose… (the Mac's folder picker) too.
                note = d.key == SettingKey.projectsDir
                    ? "a host path — Choose… (this Mac's folder picker), or doz config set \(d.key) PATH"
                    : d.section == "serve" ? "who reaches the dashboard is set on the Mac: doz config set \(d.key) VALUE"
                    : "a host path — set it with: doz config set \(d.key) PATH"
            }
            if fileError != nil, note == nil { note = "the settings file does not parse — fix it (or remove it) first" }
            return SettingRow(key: d.key, section: d.section, name: d.name, value: r.value, defaultValue: d.defaultValue,
                              source: r.source, fileValue: r.fileValue, type: kind, typeName: d.type.name, choices: choices,
                              min: lo, max: hi, description: d.summary, environment: d.environment, flag: d.flag,
                              applies: d.applies, appliesNote: d.applies.note,
                              editable: d.editableInUI && r.source != .env && r.source != .flag && fileError == nil, note: note)
        }
        return SettingsReport(path: url?.path, exists: fileExists, warnings: warnings, error: fileError, settings: rows,
                              notSettable: Self.notSettable)
    }

    // MARK: writing

    /// Set (`value`) or clear (nil) one key and write the file. Refuses an unknown key, a bad value,
    /// or a file that does not parse (it is the person's, and would be lost).
    @discardableResult
    public func writing(_ key: String, _ value: TOMLValue?) throws -> DozerSettings {
        guard let d = Self.definition(key) else { throw SettingsError("unknown setting \(key) — doz config show lists them") }
        var values = fileValues
        if let value { values[key] = try d.validate(value) } else { values[key] = nil }
        return try writingAll(values)
    }

    /// Write the file as the schema generates it, with these values (and the unknown keys kept).
    @discardableResult
    public func writingAll(_ values: [String: TOMLValue]) throws -> DozerSettings {
        guard let url else { throw SettingsError("no settings file: neither XDG_CONFIG_HOME nor HOME is set") }
        if let fileError { throw SettingsError("\(fileError) — fix it or remove it first; it was not changed") }
        try Self.writeAtomically(Self.render(values: values, unknown: unknown), to: url)
        return Self.load(environment: environment)
    }

    /// The file's text: a header, then every section and setting of the schema, each with its
    /// description and its default commented out, unless `values` sets it.
    public static func render(values: [String: TOMLValue], unknown: [TOMLEntry] = []) -> String {
        var out = """
        # Dozer Sandbox settings (doz.toml)
        #
        # Every setting is listed with its default, commented out: `# key = default`. Uncomment a line
        # to set it. `doz config set KEY VALUE` and the UI's Settings page write this file for you;
        # they regenerate it from the settings list, so comments you add are not kept.
        #
        # Precedence: a command-line flag, then the environment variable named, then this file, then
        # the default. `doz config show` prints every value and where it came from.
        #
        # Not settable, by design:

        """
        for n in notSettable { out += "#   - \(n)\n" }
        var sections: [String] = []
        for d in schema where !sections.contains(d.section) { sections.append(d.section) }
        for section in sections {
            out += "\n[\(section)]\n"
            for d in schema where d.section == section {
                out += "\n" + wrapComment(d.summary)
                var facts: [String] = [d.type.name]
                if let e = d.environment { facts.append("env \(e)") }
                if let f = d.flag { facts.append("flag \(f)") }
                facts.append(d.applies.note)
                out += "# (\(facts.joined(separator: "; ")))\n"
                if let v = values[d.key] {
                    out += "\(d.name) = \(TOML.render(v))\n"
                } else {
                    out += "# \(d.name) = \(TOML.render(d.defaultValue))\n"
                }
            }
            let extra = unknown.filter { $0.section == section }
            if !extra.isEmpty {
                out += "\n# not known to this version (kept as they were):\n"
                for e in extra { out += "\(e.key) = \(TOML.render(e.value))\n" }
            }
        }
        var others: [String] = []
        for e in unknown where !sections.contains(e.section) && !others.contains(e.section) { others.append(e.section) }
        for section in others {
            // A top-level unknown key cannot follow a section header; it becomes [unknown].
            let header = section.isEmpty ? "unknown" : section
            out += "\n# not known to this version (kept as they were):\n[\(header)]\n"
            for e in unknown where e.section == section { out += "\(e.key) = \(TOML.render(e.value))\n" }
        }
        return out
    }

    static func wrapComment(_ text: String, width: Int = 98) -> String {
        var lines: [String] = []
        var line = "#"
        for word in text.split(separator: " ") {
            if line.count + 1 + word.count > width, line != "#" {
                lines.append(line)
                line = "#"
            }
            line += " " + word
        }
        lines.append(line)
        return lines.joined(separator: "\n") + "\n"
    }

    /// temp file (0600, O_EXCL) in the same directory → fsync → rename; the directory is 0700.
    static func writeAtomically(_ text: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw SettingsError("could not create \(dir.path): \(error.localizedDescription)")
        }
        guard chmod(dir.path, 0o700) == 0 else { throw SettingsError("could not make \(dir.path) private (0700)") }
        let tmp = dir.appendingPathComponent(".\(fileName).\(getpid()).\(UInt32.random(in: .min ... .max)).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SettingsError("could not write in \(dir.path): \(String(cString: strerror(errno)))") }
        var ok = fchmod(fd, 0o600) == 0
        let bytes = Array(text.utf8)
        var written = 0
        while ok, written < bytes.count {
            let n = bytes[written...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { ok = false } else { written += n }
        }
        ok = ok && fsync(fd) == 0
        ok = close(fd) == 0 && ok
        guard ok, rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw SettingsError("could not write \(url.path): \(String(cString: strerror(errno)))")
        }
    }
}
