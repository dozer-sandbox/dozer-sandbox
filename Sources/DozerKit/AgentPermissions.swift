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
    /// 617: why the agent calls it (a recipe's host beside its model's API) — the plan says it, host by host.
    public var reason: String? = nil

    public init(_ host: String, ports: [UInt16]? = [443], pathPrefixes: [String]? = nil, reason: String? = nil) {
        self.reason = reason
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
    /// 617: hosts the agent this permission belongs to is known to call that Dozer keeps out — denied before
    /// anything else in a sandbox that has it (a recipe's `excluded`). nil for every other permission.
    public var denies: [String]?
    /// 617: never shown as a switch (an agent's own update hosts, folded into "Update itself").
    public var hidden: Bool?

    public init(id: String, title: String, summary: String, phrase: String, hosts: [PermissionHost], locked: Bool,
                warning: String? = nil, group: String? = nil, denies: [String]? = nil, hidden: Bool? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.phrase = phrase
        self.hosts = hosts
        self.locked = locked
        self.warning = warning
        self.group = group
        self.denies = denies
        self.hidden = hidden
    }
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

    /// P1's table, in the order the page lists it (Install software's sub-switches after "update"). 617: with every
    /// recipe agent's own model permission after "Talk to OpenAI", and its hidden `update:<id>` at the end.
    public static var all: [AgentPermission] {
        let g = AgentRecipes.generation
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = cache, c.generation == g { return c.all }
        var a = basePermissions
        let recipes = AgentRecipes.all.filter { !$0.isBuiltin }
        a.insert(contentsOf: recipes.compactMap(modelPermission), at: 2)
        a += recipes.compactMap(updatePermission)
        a += AgentRecipes.all.compactMap(vendorPermission)
        a += AgentRecipes.all.compactMap(sourcesPermission)
        cache = (g, a)
        return a
    }
    nonisolated(unsafe) private static var cache: (generation: Int, all: [AgentPermission])?
    private static let cacheLock = NSLock()

    /// 617: a recipe agent's own model permission ("Talk to xAI"): its hosts and paths, and the hosts it keeps out.
    static func modelPermission(_ r: AgentRecipe) -> AgentPermission? {
        let m = r.network.model
        guard m.shared != true, let hosts = m.hosts else { return nil }
        return AgentPermission(id: m.id, title: m.title ?? "Talk to its AI model",
                               summary: m.summary ?? "\(r.title)'s model — needed for \(r.title) to work.",
                               phrase: m.phrase ?? "talk to your AI model",
                               hosts: hosts.map { PermissionHost($0.host, pathPrefixes: $0.conditions, reason: $0.reason) }, locked: false,
                               denies: r.network.excluded.isEmpty && (r.network.quiet ?? []).isEmpty ? nil
                                   : r.network.excluded + (r.network.quiet ?? []).map(\.host))
    }

    /// 617 (D4): a recipe agent's own update hosts — on only beside "Update itself", only in its sandbox.
    static func updatePermission(_ r: AgentRecipe) -> AgentPermission? {
        guard !r.isBuiltin, !r.network.update.isEmpty else { return nil }
        return AgentPermission(id: "update:" + r.id, title: "Update \(r.title)", summary: "Get new versions of \(r.title).", phrase: "update yourself",
                               hosts: r.network.update.map { PermissionHost($0.host, pathPrefixes: $0.conditions, reason: $0.reason) }, locked: false, hidden: true)
    }

    /// 617 (owner: a fresh try shows no refusal): what an agent calls on its own vendor's sites at a normal start —
    /// every agent's, the built-in three's too; hidden, added at create (`agentPermissions`), always on in its sandbox.
    static func vendorPermission(_ r: AgentRecipe) -> AgentPermission? {
        guard let v = r.network.vendor, !v.isEmpty else { return nil }
        return AgentPermission(id: "vendor:" + r.id, title: "\(r.title)'s own sites", summary: "What \(r.title) reads from its maker when it starts.",
                               phrase: "read what your maker publishes for you at start-up",
                               hosts: v.map { PermissionHost($0.host, pathPrefixes: $0.conditions, reason: $0.reason) }, locked: false, hidden: true)
    }

    /// 618: a built-in agent's other model sources (pi on OpenAI, xAI, Google AI, OpenRouter, Vercel AI Gateway) — its
    /// shared model permission is Anthropic's; hidden, added at create (`agentPermissions`), always on in its sandbox, like
    /// Codex's "Talk to OpenAI". The key still goes only to the source its account names.
    static func sourcesPermission(_ r: AgentRecipe) -> AgentPermission? {
        guard r.isBuiltin, r.models != nil else { return nil }
        let shared = Set(basePermissions.first { $0.id == "model" }?.hosts.map(\.host) ?? [])
        let hosts = r.offeredSources.flatMap(ModelSources.hosts).filter { !shared.contains($0) }
        guard !hosts.isEmpty else { return nil }
        return AgentPermission(id: "sources:" + r.id, title: "\(r.title)'s other model providers",
                               summary: "The providers and gateways \(r.title) can use besides Anthropic — the key goes only to the one its account names.",
                               phrase: "talk to your AI model's provider", hosts: hosts.map { PermissionHost($0) }, locked: false, hidden: true)
    }

    /// The table before 617 — what every recipe is checked against (an excluded host is in none of these).
    public static let basePermissions: [AgentPermission] = {
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
    /// 599i: Codex's; 617: and every recipe agent's own (`model:xai`, `model:google`).
    static var agentModelPermissions: Set<String> { Set([openAIModel]).union(recipeModelPermissions) }

    /// 617 (D5): the model permissions of recipe agents — a sandbox that has one has NO Anthropic `model` (its Locked
    /// reaches only its own model). Codex keeps today's shape (`model` + "Talk to OpenAI").
    static var recipeModelPermissions: Set<String> {
        Set(AgentRecipes.all.filter { !$0.isBuiltin && $0.network.model.shared != true }.map(\.network.model.id))
    }

    /// 599i: the permissions an agent always has (Codex: "Talk to OpenAI"); none for Claude Code and pi. 617: a recipe
    /// agent's own model permission, and its hidden `update:<id>` when it has update hosts.
    public static func agentPermissions(_ agent: AgentKind?) -> [String] {
        let vendor = agent?.recipe.flatMap { ($0.network.vendor ?? []).isEmpty ? nil : ["vendor:" + $0.id] } ?? []
        if agent == .codex { return [openAIModel] + vendor }
        // 618: pi's other model sources (hidden).
        if let r = agent?.recipe, r.isBuiltin { return vendor + (sourcesPermission(r).map { [$0.id] } ?? []) }
        guard let r = agent?.recipe, !r.isBuiltin else { return vendor }
        var out: [String] = []
        if r.network.model.shared != true { out.append(r.network.model.id) }
        if !r.network.update.isEmpty { out.append("update:" + r.id) }
        return out + vendor
    }

    /// 617: an agent's own vendor sites (`vendor:<id>`).
    public static func isAgentVendor(_ id: String) -> Bool { id.hasPrefix("vendor:") }

    /// 599i: whether `id` is an agent's own model permission (shown only where it is on).
    public static func isAgentModel(_ id: String) -> Bool { agentModelPermissions.contains(id) }

    /// 617: an agent's own update hosts (`update:<id>` — never a switch of its own).
    public static func isAgentUpdate(_ id: String) -> Bool { id.hasPrefix("update:") }

    /// 617: a permission only an agent has (its model, its update hosts): never in a preset, never inferred or suggested.
    public static func isAgentOwn(_ id: String) -> Bool { isAgentModel(id) || isAgentUpdate(id) || isAgentVendor(id) || isAgentSources(id) }

    /// 618: a built-in agent's other model sources (`sources:pi`).
    public static func isAgentSources(_ id: String) -> Bool { id.hasPrefix("sources:") }

    /// 617 (D5): whether `names` carry a recipe agent's own model (then Anthropic's `model` is not theirs).
    public static func hasOwnModel(_ names: [String]) -> Bool { !recipeModelPermissions.isDisjoint(with: names) }

    /// 617: the hosts kept out of a sandbox with these permissions (its agent's `excluded`), whatever else is on.
    public static func excludedHosts(_ names: [String]) -> [String] {
        let set = Set(names)
        return all.filter { set.contains($0.id) }.flatMap { $0.denies ?? [] }
    }

    /// 617: the hosts an agent with these permissions is EXPECTED to be refused (its recipe's `quiet` list) — logged, not counted.
    public static func quietHosts(_ names: [String]) -> [String] {
        let set = Set(names)
        return AgentRecipes.all.filter { r in set.contains(r.network.model.id) || set.contains("vendor:" + r.id) }
            .flatMap { ($0.network.quiet ?? []).map(\.host) }
    }

    /// 617: the deny rules for `excludedHosts` — evaluated before the user's own rules and every permission.
    public static func exclusions(for names: [String]) -> [EgressRule] {
        let set = Set(names)
        var out: [EgressRule] = []
        for p in all where set.contains(p.id) {
            let agent = AgentRecipes.all.first { $0.network.model.id == p.id }?.title ?? "this agent"
            for h in p.denies ?? [] {
                out.append(EgressRule(.deny, host: h, note: "kept out of \(agent)'s sandbox", id: stableID(p.id + "|deny", h)))
            }
        }
        return out
    }

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
        case "open": return all.map(\.id).filter { !identityPermissions.contains($0) && !isAgentOwn($0) }
        default: return nil
        }
    }

    /// 617 (D5): the preset for an AGENT — a recipe agent with its own model has no Anthropic `model` in it (its
    /// Locked is only its own model, which `agentPermissions` adds); the built-in three get exactly `preset(_:base:)`.
    public static func preset(_ name: String, base: String?, agent: AgentKind?) -> [String]? {
        guard let p = preset(name, base: base) else { return nil }
        guard let r = agent?.recipe, !r.isBuiltin, r.network.model.shared != true else { return p }
        return p.filter { $0 != "model" }
    }

    /// Which preset `names` is for `base` (nil: Custom).
    public static func presetName(_ names: [String], base: String?) -> String? {
        // 599d: the user's GitHub login is beside the preset, not part of it (a preset + "as you" is still that preset).
        let rest = Set(names).subtracting(identityPermissions).filter { !isAgentOwn($0) }
        // 617 (D5): a recipe agent's sandbox has no Anthropic `model` — its presets are the same without it.
        let own = hasOwnModel(names)
        for p in ["locked", "agent", "open"] {
            var want = Set(preset(p, base: base) ?? [])
            if own { want.remove("model") }
            if want == rest { return p }
        }
        return nil
    }

    /// Canonical order, locked ones forced on, unknown names dropped. 617 (D5): with a recipe agent's own model,
    /// Anthropic's `model` is neither forced on nor kept.
    public static func normalized(_ names: [String]) -> [String] {
        var set = Set(names)
        // 599d: "Push to GitHub" is a step of "Use GitHub as you" — never on without it.
        if !set.contains(gitHubAsYou) { set.remove(gitHubPush) }
        let own = hasOwnModel(names)
        if own { set.remove("model") }
        return all.filter { ($0.locked && !(own && $0.id == "model")) || set.contains($0.id) }.map(\.id)
    }

    /// The rules the names allow, in the catalogue's order (the user's own rules come before these). 617: an agent's
    /// own update hosts only beside "Update itself" (D4).
    public static func rules(for names: [String]) -> [EgressRule] {
        let set = Set(names)
        let chosen = all.filter { set.contains($0.id) && $0.id != "web" && !(isAgentUpdate($0.id) && !set.contains("update")) }
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
        let candidates = all.filter { $0.id != "web" && $0.group != "github" && !isAgentOwn($0.id) }
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
        // 617: a recipe agent's excluded hosts first — kept out whatever else is chosen (none for the built-in three).
        return AgentPermissions.exclusions(for: names) + rules + AgentPermissions.rules(for: names)
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
