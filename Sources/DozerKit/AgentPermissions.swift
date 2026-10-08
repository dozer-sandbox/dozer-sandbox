import Foundation

// 597 — Dozer Agent Permissions (owner ruling 2026-09-30, P1–P7 as recommended). A proxied sandbox's
// network answers "what may the agent do?": a short list of plain-language permissions, each a named
// group of host rules. A policy STORES THE NAMES (`NetworkPolicy.permissions`) plus the user's own
// rules; the hosts behind a name come from THIS build (`AgentPermissions.all`) every time the policy is
// evaluated — so when an agent starts using a new host, a Dozer update reaches every sandbox that has
// the permission, with no per-sandbox edit (P5; the 2026-09-29 agent-preset incident). The user's own
// rules (allow/deny a host) come first, so they win over permissions.

/// One host (or pattern) a permission allows.
public struct PermissionHost: Sendable, Equatable, Codable {
    public var host: String
    public var ports: [UInt16]?
    /// HTTP conditions (the proxy decrypts to judge them): methods, path prefixes.
    public var pathPrefixes: [String]?

    public init(_ host: String, ports: [UInt16]? = [443], pathPrefixes: [String]? = nil) {
        self.host = host
        self.ports = ports
        self.pathPrefixes = pathPrefixes
    }
}

/// 597 (P1): one thing the agent may do.
public struct AgentPermission: Sendable, Equatable, Codable {
    /// `model`, `sign-in`, `update`, `install:system`, `install:python`, …, `github`, `error-reports`, `web`.
    public var id: String
    /// "Talk to its AI model" — what the switch says.
    public var title: String
    /// "Needed for the agent to work." — the line under it.
    public var summary: String
    /// For the facts block: "talk to your AI model" (P7).
    public var phrase: String
    public var hosts: [PermissionHost]
    /// Always on (the switch cannot be turned off).
    public var locked: Bool
    /// Said before it is switched on.
    public var warning: String?
    /// `install` for the per-ecosystem sub-switches.
    public var group: String?
}

public enum AgentPermissions {
    /// The "Install software" sub-switches: ecosystem → its registries, and the catalogue bases whose
    /// Standard set turns it on (596).
    public static let ecosystems: [(id: String, title: String, phrase: String, hosts: [PermissionHost], bases: [String])] = [
        ("system", "System packages (apt / apk)", "system packages (apt/apk)", [
            PermissionHost("deb.debian.org", ports: [80, 443]), PermissionHost("security.debian.org", ports: [80, 443]),
            PermissionHost("*.ubuntu.com", ports: [80, 443]), PermissionHost("dl-cdn.alpinelinux.org", ports: [80, 443])], []),
        ("node", "Node (npm)", "npm packages", [PermissionHost("registry.npmjs.org")], ["node"]),
        ("python", "Python (PyPI)", "Python packages (PyPI)", [PermissionHost("pypi.org"), PermissionHost("files.pythonhosted.org")], ["python"]),
        ("go", "Go (modules)", "Go modules", [PermissionHost("proxy.golang.org"), PermissionHost("sum.golang.org"), PermissionHost("storage.googleapis.com")], ["go"]),
        ("rust", "Rust (crates.io)", "Rust crates", [PermissionHost("crates.io"), PermissionHost("index.crates.io"), PermissionHost("static.crates.io"),
                                                    PermissionHost("static.rust-lang.org")], ["rust"]),
        ("java", "Java (Maven, Gradle)", "Java packages (Maven, Gradle)", [PermissionHost("repo.maven.apache.org"), PermissionHost("repo1.maven.org"),
                                                                        PermissionHost("services.gradle.org"), PermissionHost("downloads.gradle.org"),
                                                                        PermissionHost("plugins.gradle.org")], ["java"]),
        ("ruby", "Ruby (RubyGems)", "Ruby gems", [PermissionHost("rubygems.org"), PermissionHost("index.rubygems.org")], ["ruby"]),
        ("dotnet", ".NET (NuGet)", ".NET packages (NuGet)", [PermissionHost("api.nuget.org"), PermissionHost("globalcdn.nuget.org")], ["dotnet"]),
    ]

    /// P1's table, in the order the page lists it (Install software's sub-switches after "update").
    public static let all: [AgentPermission] = {
        var a: [AgentPermission] = [
            AgentPermission(id: "model", title: "Talk to its AI model", summary: "Needed for the agent to work.", phrase: "talk to your AI model",
                            hosts: [PermissionHost("api.anthropic.com", ports: nil), PermissionHost("statsig.anthropic.com", ports: nil)], locked: true),
            // 599i: Codex's model (OpenAI) — only ever on in a Codex sandbox, where it cannot be switched off.
            AgentPermission(id: openAIModel, title: "Talk to OpenAI", summary: "Codex's model and its usage limits (OpenAI) — needed for Codex to work.",
                            phrase: "talk to your AI model (OpenAI)",
                            hosts: [PermissionHost("chatgpt.com"), PermissionHost("api.openai.com"), PermissionHost("ab.chatgpt.com")], locked: false),
            AgentPermission(id: "sign-in", title: "Sign in", summary: "Only for signing in inside the sandbox — Dozer's proxy already supplies the credential.",
                            phrase: "sign in to Claude inside the sandbox",
                            hosts: [PermissionHost("console.anthropic.com", ports: nil), PermissionHost("claude.ai", ports: nil), PermissionHost("platform.claude.com", ports: nil)],
                            locked: false),
            AgentPermission(id: "update", title: "Update itself", summary: "Get new versions of Claude Code / pi.", phrase: "update yourself",
                            hosts: [PermissionHost("downloads.claude.ai"), PermissionHost("pi.dev"),
                                    // npm: only the agents' own packages (the proxy reads the path).
                                    PermissionHost("registry.npmjs.org", pathPrefixes: ["/@anthropic-ai/claude-code", "/@anthropic-ai%2fclaude-code", "/@anthropic-ai%2Fclaude-code",
                                                                                       "/@earendil-works/pi-coding-agent", "/@earendil-works%2fpi-coding-agent", "/@earendil-works%2Fpi-coding-agent"])],
                            locked: false),
        ]
        for e in ecosystems {
            a.append(AgentPermission(id: "install:" + e.id, title: e.title, summary: "Install " + e.phrase + " for your project.", phrase: "install " + e.phrase,
                                     hosts: e.hosts, locked: false, group: "install"))
        }
        a += [
            AgentPermission(id: "github", title: "Use GitHub", summary: "Clone and fetch code; Claude Code plugins.", phrase: "use GitHub (clone, fetch, plugins)",
                            hosts: ["github.com", "raw.githubusercontent.com", "codeload.github.com", "objects.githubusercontent.com"].map { PermissionHost($0) }, locked: false),
            // 599d: the user's own GitHub login, through the proxy (the token never enters the sandbox).
            AgentPermission(id: gitHubAsYou, title: "Use GitHub as you",
                            summary: "git and gh are signed in as you on github.com (your Mac's gh login, or a token you add) — read-only: clone and fetch your private repositories, read issues and pull requests.",
                            phrase: "use GitHub signed in as the user (read-only)",
                            hosts: GitHubAccess.credentialHosts.map { PermissionHost($0) }, locked: false,
                            warning: "The agent can read everything your login can on GitHub.", group: "github"),
            AgentPermission(id: gitHubPush, title: "Push to GitHub",
                            summary: "Also push commits and change things on GitHub as you (open pull requests, comment, create issues) — within what your token may do.",
                            phrase: "push and make changes on GitHub as the user",
                            hosts: [], locked: false,
                            warning: "The agent can push and act on GitHub as you.", group: "github"),
            AgentPermission(id: "error-reports", title: "Send error reports", summary: "Let the agent report its own crashes to its maker.",
                            phrase: "send your own error reports",
                            hosts: [PermissionHost("http-intake.logs.us5.datadoghq.com"), PermissionHost("browser-intake-us5-datadoghq.com")], locked: false),
            AgentPermission(id: "web", title: "Browse the web", summary: "Read any website.", phrase: "browse the web (any site)",
                            hosts: [PermissionHost("*", ports: nil)], locked: false,
                            warning: "The agent could send your code anywhere — use with care."),
        ]
        return a
    }()

    /// Test seam: hosts added to a permission as a later Dozer would (P5's "an update adds a host").
    nonisolated(unsafe) static var addedForTests: [String: [PermissionHost]] = [:]

    public static func permission(_ id: String) -> AgentPermission? { all.first { $0.id == id } }

    /// 599d: "Use GitHub as you" and "Push to GitHub" (which needs it). Off in EVERY preset — Open
    /// included: Open is about the network, these are the user's identity; each is turned on by name.
    /// 599i: "Talk to OpenAI" — the model permission of an agent other than Claude Code / pi. Never part of
    /// a preset (Open included): it is added for the agent that needs it (`agentPermissions`), kept across
    /// preset changes, never inferred, never suggested, and not listed in another agent's checklist or facts.
    public static let openAIModel = "model:openai"
    static let agentModelPermissions: Set<String> = [openAIModel]

    /// 599i: the permissions an agent always has (Codex: "Talk to OpenAI"); none for Claude Code and pi.
    public static func agentPermissions(_ agent: AgentKind?) -> [String] {
        agent == .codex ? [openAIModel] : []
    }

    /// 599i: whether `id` is an agent's own model permission (shown only where it is on).
    public static func isAgentModel(_ id: String) -> Bool { agentModelPermissions.contains(id) }

    public static let gitHubAsYou = "github:as-you"
    public static let gitHubPush = "github:push"
    static let identityPermissions: Set<String> = [gitHubAsYou, gitHubPush]

    /// The GitHub mode `names` give: nil (off), read, or push (push needs "as you").
    public static func gitHubMode(_ names: [String]?) -> GitHubAccess.Mode? {
        guard let names, names.contains(gitHubAsYou) else { return nil }
        return names.contains(gitHubPush) ? .push : .read
    }

    public static func isValid(_ id: String) -> Bool { permission(id) != nil }

    /// The ecosystems a base installs from by default (system packages always).
    public static func installDefaults(base: String?) -> [String] {
        ["install:system"] + ecosystems.filter { e in base.map { e.bases.contains($0) } ?? false }.map { "install:" + $0.id }
    }

    /// P2's presets for a base: Locked (the model only), Standard (the defaults), Open (everything).
    public static func preset(_ name: String, base: String?) -> [String]? {
        switch name {
        case "locked": return ["model"]
        case "agent", "standard": return ["model", "update"] + installDefaults(base: base) + ["github", "error-reports"]
        case "open": return all.map(\.id).filter { !identityPermissions.contains($0) && !agentModelPermissions.contains($0) }
        default: return nil
        }
    }

    /// Which preset `names` is for `base` (nil: Custom).
    public static func presetName(_ names: [String], base: String?) -> String? {
        // 599d: the user's GitHub login is beside the preset, not part of it (a preset + "as you" is still that preset).
        let rest = Set(names).subtracting(identityPermissions).subtracting(agentModelPermissions)
        for p in ["locked", "agent", "open"] where Set(preset(p, base: base) ?? []) == rest { return p }
        return nil
    }

    /// Canonical order, locked ones forced on, unknown names dropped.
    public static func normalized(_ names: [String]) -> [String] {
        var set = Set(names)
        // 599d: "Push to GitHub" is a step of "Use GitHub as you" — never on without it.
        if !set.contains(gitHubAsYou) { set.remove(gitHubPush) }
        return all.filter { $0.locked || set.contains($0.id) }.map(\.id)
    }

    /// The rules the names allow, in the catalogue's order (the user's own rules come before these).
    public static func rules(for names: [String]) -> [EgressRule] {
        let set = Set(names)
        let chosen = all.filter { set.contains($0.id) && $0.id != "web" }
        // A host another permission allows whole (npm with Install: Node) needs no path condition —
        // which would otherwise make the proxy decrypt every npm connection.
        let whole = Set(chosen.flatMap { p in (p.hosts + (addedForTests[p.id] ?? [])).filter { $0.pathPrefixes == nil }.map(\.host) })
        var out: [EgressRule] = []
        for p in chosen {
            for h in p.hosts + (addedForTests[p.id] ?? []) where h.pathPrefixes == nil || !whole.contains(h.host) {
                out.append(EgressRule(.allow, host: h.host, ports: h.ports, pathPrefixes: h.pathPrefixes, note: "permission: \(p.title)",
                                      id: stableID(p.id, h.host)))
            }
        }
        return out
    }

    /// The permission a host belongs to (a denied connection → "Allow <permission>", P3). The most
    /// specific: an exact host before a pattern; "Update itself" is not offered for npm (Install is).
    public static func permission(forHost host: String) -> AgentPermission? {
        let h = host.lowercased()
        // 599d: a denied host never suggests the user's own GitHub login (that is switched on deliberately).
        let candidates = all.filter { $0.id != "web" && $0.group != "github" && !agentModelPermissions.contains($0.id) }
        for p in candidates {
            for ph in p.hosts where ph.host == h && ph.pathPrefixes == nil { return p }
        }
        for p in candidates {
            for ph in p.hosts where ph.host.hasPrefix("*.") && h.hasSuffix(String(ph.host.dropFirst(1))) { return p }
        }
        return nil
    }

    /// A rule's id from its permission and host — the same every time (the log's rule labels stay stable).
    static func stableID(_ permission: String, _ host: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in Array((permission + "|" + host).utf8).enumerated() { bytes[i % 16] = bytes[i % 16] &* 31 &+ b }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

extension NetworkPolicy {
    /// 597: a policy made of permissions (their names) for a base — the user's own rules empty.
    public static func permissions(_ names: [String], preset: String? = nil) -> NetworkPolicy {
        var p = NetworkPolicy(defaultAction: .deny, rules: [], preset: preset)
        p.permissions = AgentPermissions.normalized(names)
        return p
    }

    /// 597 (P5): what is evaluated — the user's own rules first (they win), then the hosts behind each
    /// permission as THIS build defines them. A pre-597 policy (no permissions): its rules.
    public var effectiveRules: [EgressRule] {
        guard let names = permissions else { return rules }
        return rules + AgentPermissions.rules(for: names)
    }

    /// "Browse the web" is an allowing default.
    public var effectiveDefault: Action {
        guard let names = permissions else { return defaultAction }
        return names.contains("web") ? .allow : .deny
    }

    /// The user's own sites (allow rules they added, not a permission's).
    public var sites: [String] {
        rules.filter { $0.action == .allow && !$0.hasHTTPConditions && $0.ports == nil }.map(\.host)
    }
}
