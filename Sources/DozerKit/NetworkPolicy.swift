import Foundation

// Feature 580 — the egress policy of a PROXIED sandbox (`SandboxSpec.network = .proxied(policy)`).
//
// A proxied sandbox's VM has no network interface. Every outbound connection, and every DNS
// question, arrives at the host proxy (`EgressProxy`) over vsock and is judged here, on the Mac,
// where root in the guest cannot reach. Default deny; rules are checked IN ORDER and the first
// that matches decides.

/// How a sandbox reaches the network.
public enum NetworkMode: Sendable, Codable, Equatable {
    /// No network at all: only `lo`, and no proxy.
    case none
    /// A vmnet NAT interface (shared mode): the guest reaches anything the Mac can. The explicit
    /// opt-out from policy, kept for comparison and for hosts that need it.
    case nat
    /// No network interface; everything goes through the host proxy under `NetworkPolicy`.
    case proxied(NetworkPolicy)

    public var policy: NetworkPolicy? { if case .proxied(let p) = self { return p }; return nil }
}

/// One sandbox's egress policy.
public struct NetworkPolicy: Sendable, Codable, Equatable {
    public enum Action: String, Sendable, Codable, CaseIterable { case allow, deny }

    /// What happens when no rule matches. `deny` everywhere except the `open` preset.
    public var defaultAction: Action
    /// Checked in order; the first match decides.
    public var rules: [EgressRule]
    /// The preset this policy was made from, for display ("agent", "bake", …); nil once edited
    /// into something no preset describes.
    public var preset: String?
    /// 597 (P5): the permissions it has, BY NAME (`AgentPermissions`) — their hosts come from the
    /// running build at every evaluation; `rules` are then the user's own (they come first). nil: a
    /// policy of rules only (every policy before 597, and `bake`).
    public var permissions: [String]?

    public init(defaultAction: Action = .deny, rules: [EgressRule] = [], preset: String? = nil) {
        self.defaultAction = defaultAction
        self.rules = rules
        self.preset = preset
    }

    // MARK: presets

    /// Nothing leaves the sandbox (DNS included).
    public static let locked = NetworkPolicy(defaultAction: .deny, rules: [], preset: "locked")

    /// Package registries only — what a bake needs, and nothing else.
    public static let bake = NetworkPolicy(defaultAction: .deny, rules: registryRules, preset: "bake")

    /// An agent: its model API and login, what Claude Code itself reaches (updates, error reporting,
    /// GitHub for git and its plugin marketplace), plus the package registries.
    public static let agent = NetworkPolicy(defaultAction: .deny, rules: agentAPIRules + claudeCodeRules + gitHubRules + registryRules,
                                            preset: "agent")

    /// Everything allowed — but still proxied, DNS answered on the Mac, and every connection logged.
    public static let open = NetworkPolicy(defaultAction: .allow, rules: [], preset: "open")

    public static let presets: [String: NetworkPolicy] = ["locked": locked, "bake": bake, "agent": agent, "open": open]

    /// 596: the bake preset plus an image spec's own bake hosts (HTTPS only) — still "bake".
    public static func bake(adding hosts: [String]?) -> NetworkPolicy {
        var p = bake
        for h in hosts ?? [] where !p.rules.contains(where: { $0.host == h.lowercased() }) {
            p.rules.append(EgressRule(host: h, ports: [443], note: "this image's bake"))
        }
        return p
    }

    /// 596 (B4): a sandbox's policy with its base's language registries allowed (HTTPS) — appended
    /// after the preset's rules, keeping the preset's name (the preset, for that base). `locked`
    /// and `open` are left as they are (nothing, and everything).
    public func adding(registries: [RegistryHost]) -> NetworkPolicy {
        guard defaultAction == .deny, preset != "locked" else { return self }
        var p = self
        for r in registries where !p.rules.contains(where: { $0.host == r.host.lowercased() }) {
            p.rules.append(EgressRule(host: r.host, ports: [443], note: r.note))
        }
        return p
    }

    /// Anthropic's API and the sign-in hosts Claude Code uses.
    public static let agentAPIRules: [EgressRule] = [
        EgressRule(host: "api.anthropic.com", note: "Claude API"),
        EgressRule(host: "statsig.anthropic.com", note: "Claude Code feature flags"),
        EgressRule(host: "console.anthropic.com", note: "Claude sign-in"),
        EgressRule(host: "platform.claude.com", note: "Claude sign-in"),
        EgressRule(host: "claude.ai", note: "Claude sign-in"),
    ]

    /// 594 (owner: "there are some legit requests that should be allowed"): what Claude Code reaches on
    /// its own, measured in a claude-sandbox's net log and read from Claude Code 2.1.227's binary.
    /// Exact hosts only — never `*.datadoghq.com`: Claude Code's two Datadog intakes are both US5.
    public static let claudeCodeRules: [EgressRule] = [
        EgressRule(host: "downloads.claude.ai", ports: [443], note: "Claude Code updates"),
        EgressRule(host: "http-intake.logs.us5.datadoghq.com", ports: [443], note: "Claude Code error reporting"),
        EgressRule(host: "browser-intake-us5-datadoghq.com", ports: [443], note: "Claude Code error reporting"),
        // 594 (the owner's pi-sandbox net log): pi's own version check, install report and model catalog.
        EgressRule(host: "pi.dev", ports: [443], note: "pi updates"),
    ]

    /// GitHub over HTTPS: git, and Claude Code's official plugin marketplace (fetched at startup).
    public static let gitHubRules: [EgressRule] = [
        EgressRule(host: "github.com", ports: [443], note: "GitHub (git, Claude Code plugins)"),
        EgressRule(host: "raw.githubusercontent.com", ports: [443], note: "GitHub (git, Claude Code plugins)"),
        EgressRule(host: "codeload.github.com", ports: [443], note: "GitHub (git, Claude Code plugins)"),
        EgressRule(host: "objects.githubusercontent.com", ports: [443], note: "GitHub (git, Claude Code plugins)"),
    ]

    /// npm, Debian/Ubuntu apt, Alpine apk, PyPI.
    public static let registryRules: [EgressRule] = [
        EgressRule(host: "registry.npmjs.org", note: "npm"),
        EgressRule(host: "deb.debian.org", ports: [80, 443], note: "apt"),
        EgressRule(host: "security.debian.org", ports: [80, 443], note: "apt"),
        EgressRule(host: "*.ubuntu.com", ports: [80, 443], note: "apt"),
        EgressRule(host: "dl-cdn.alpinelinux.org", ports: [80, 443], note: "apk"),
        EgressRule(host: "pypi.org", note: "pip"),
        EgressRule(host: "files.pythonhosted.org", note: "pip"),
    ]

    // MARK: evaluation

    /// The verdict for a connection to `host:port` (a name, or an IP literal). `method`/`path` are
    /// known only for requests the proxy can read (plain HTTP, and hosts it decrypts); a rule with
    /// a method or path condition never matches when they are unknown.
    public func evaluate(host: String, port: UInt16, method: String? = nil, path: String? = nil) -> Verdict {
        let rules = effectiveRules, defaultAction = effectiveDefault
        for (i, r) in rules.enumerated() where r.matches(host: host, port: port) {
            if r.hasHTTPConditions {
                guard let method, let path else { continue }
                guard r.matchesRequest(method: method, path: path) else { continue }
            }
            return Verdict(action: r.action, rule: r.label, ruleIndex: i)
        }
        return Verdict(action: defaultAction, rule: "default \(defaultAction.rawValue)", ruleIndex: nil)
    }

    /// The verdict for a CONNECTION, before any request is seen. A host that only HTTP-conditioned
    /// rules could allow is let through as `inspect`: the proxy must decrypt it and judge each request.
    public func evaluateConnection(host: String, port: UInt16) -> ConnectionVerdict {
        let rules = effectiveRules, defaultAction = effectiveDefault
        for (i, r) in rules.enumerated() where r.matches(host: host, port: port) {
            if r.hasHTTPConditions {
                if r.action == .allow { return ConnectionVerdict(kind: .inspect, rule: r.label, ruleIndex: i) }
                continue                              // a conditional deny: requests decide
            }
            return ConnectionVerdict(kind: r.action == .allow ? .allow : .deny, rule: r.label, ruleIndex: i)
        }
        // A conditional deny ahead of an allowing default also needs every request judged.
        if defaultAction == .allow, rules.contains(where: { $0.hasHTTPConditions && $0.action == .deny && $0.matches(host: host, port: port) }) {
            return ConnectionVerdict(kind: .inspect, rule: "default allow", ruleIndex: nil)
        }
        return ConnectionVerdict(kind: defaultAction == .allow ? .allow : .deny, rule: "default \(defaultAction.rawValue)", ruleIndex: nil)
    }

    /// Whether a DNS question for `name` is answered: when a connection to it could be allowed on
    /// ANY port. (Docker gates DNS too: a denied name does not even resolve.)
    public func allowsName(_ name: String) -> Bool {
        for r in effectiveRules where r.matchesName(name) {
            if r.action == .allow { return true }
            if !r.hasHTTPConditions && r.ports == nil { return false }
        }
        return effectiveDefault == .allow
    }

    /// Add `allow host` ahead of every other rule (the "allow this host" button).
    public mutating func allow(host: String, note: String = "allowed from the log") {
        rules.removeAll { $0.host.lowercased() == host.lowercased() && $0.action == .deny && !$0.hasHTTPConditions && $0.ports == nil }
        if evaluateConnection(host: host, port: 443).kind == .allow, evaluateConnection(host: host, port: 80).kind == .allow { return }
        rules.insert(EgressRule(host: host, note: note), at: 0)
        preset = nil
    }

    public struct Verdict: Sendable, Equatable {
        public var action: Action
        public var rule: String
        public var ruleIndex: Int?
    }

    public struct ConnectionVerdict: Sendable, Equatable {
        public enum Kind: String, Sendable { case allow, deny, inspect }
        public var kind: Kind
        public var rule: String
        public var ruleIndex: Int?
    }
}

/// One egress rule. `host` is an exact name (`api.github.com`), a wildcard (`*.npmjs.org` —
/// subdomains only, not the apex), an IPv4 CIDR or address (`10.0.0.0/8`, `1.2.3.4`; matched
/// only against IP-literal destinations), or `*` (anything).
public struct EgressRule: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var action: NetworkPolicy.Action
    public var host: String
    /// nil: any port.
    public var ports: [UInt16]?
    /// HTTP conditions (only enforceable where the proxy reads requests — see `evaluate`).
    /// nil: any method / any path. Methods are upper-case; paths are prefixes (`/repos/`).
    public var methods: [String]?
    public var pathPrefixes: [String]?
    public var note: String

    public init(_ action: NetworkPolicy.Action = .allow, host: String, ports: [UInt16]? = nil,
                methods: [String]? = nil, pathPrefixes: [String]? = nil, note: String = "", id: UUID = UUID()) {
        self.id = id
        self.action = action
        self.host = host.lowercased()
        self.ports = ports
        self.methods = methods?.map { $0.uppercased() }
        self.pathPrefixes = pathPrefixes
        self.note = note
    }

    public var hasHTTPConditions: Bool { methods != nil || pathPrefixes != nil }

    /// A one-line description, used as the log's "rule" column.
    public var label: String {
        var s = "\(action.rawValue) \(host)"
        if let ports { s += ":" + ports.map(String.init).joined(separator: ",") }
        if let methods { s += " " + methods.joined(separator: "|") }
        if let pathPrefixes { s += " " + pathPrefixes.map { $0 + "*" }.joined(separator: " ") }
        return s
    }

    public func matches(host target: String, port: UInt16) -> Bool {
        if let ports, !ports.contains(port) { return false }
        return matchesName(target)
    }

    func matchesName(_ target: String) -> Bool {
        let t = target.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if host == "*" { return true }
        if let cidr = IPv4CIDR(host) {
            guard let ip = IPv4CIDR.parseAddress(t) else { return false }
            return cidr.contains(ip)
        }
        if host.hasPrefix("*.") { return t.hasSuffix(String(host.dropFirst(1))) && t.count > host.count - 1 }
        return t == host
    }

    func matchesRequest(method: String, path: String) -> Bool {
        if let methods, !methods.contains(method.uppercased()) { return false }
        if let pathPrefixes, !pathPrefixes.contains(where: { path.hasPrefix($0) }) { return false }
        return true
    }
}

/// An IPv4 network (`10.0.0.0/8`) or a single address (`/32`).
struct IPv4CIDR: Equatable {
    var base: UInt32
    var bits: Int

    init?(_ s: String) {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let a = Self.parseAddress(String(parts[0])) else { return nil }
        let b = parts.count == 2 ? Int(parts[1]) : 32
        guard let b, (0...32).contains(b) else { return nil }
        bits = b
        base = a & Self.mask(b)
    }

    static func mask(_ bits: Int) -> UInt32 { bits == 0 ? 0 : UInt32.max << UInt32(32 - bits) }

    func contains(_ ip: UInt32) -> Bool { ip & Self.mask(bits) == base }

    static func parseAddress(_ s: String) -> UInt32? {
        let o = s.split(separator: ".", omittingEmptySubsequences: false)
        guard o.count == 4 else { return nil }
        var v: UInt32 = 0
        for x in o {
            guard !x.isEmpty, x.count <= 3, x.allSatisfy(\.isNumber), let n = UInt32(x), n <= 255 else { return nil }
            v = v << 8 | n
        }
        return v
    }
}
