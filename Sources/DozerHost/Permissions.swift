import Foundation
import DozerKit

// 597 — Dozer Agent Permissions in the host: what a sandbox's agent may do, as a checklist (P1), its
// presets (P2), suggestions from denied connections (P3), edits by permission or site (P6), the
// default for new sandboxes (P4), and the plain words of the facts block (P7). The definitions live
// in the library (`AgentPermissions`); a policy stores their NAMES (P5).

/// One permission as a client shows it.
public struct PermissionRow: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var summary: String
    public var on: Bool
    public var locked: Bool
    public var warning: String?
    /// `install` for the per-ecosystem sub-switches.
    public var group: String?
    /// The hosts behind it (this build's), for "details".
    public var hosts: [String]
    /// Default on for this sandbox's base (Standard).
    public var standard: Bool
}

/// P3: the agent was refused something a permission (or a site) would allow.
public struct PermissionSuggestion: Codable, Equatable, Sendable {
    /// A permission id, or nil for an unknown host ("Allow this site").
    public var permission: String?
    /// "install Python packages (PyPI)" / the host.
    public var what: String
    public var hosts: [String]
    public var count: Int
    /// What to send: `install:python`, or `site:api.example.com`.
    public var grant: String
}

/// A sandbox's permissions: the checklist, the preset (nil: Custom), its own sites, suggestions.
public struct PermissionReport: Codable, Equatable, Sendable {
    public var name: String
    public var base: String?
    /// `locked` · `agent` (Standard) · `open`; nil: Custom.
    public var preset: String?
    public var permissions: [PermissionRow]
    public var sites: [String]
    public var denied: [String]
    public var suggestions: [PermissionSuggestion]
    /// A pre-597 policy of rules, shown as the permissions it amounts to (stored as names at its first change).
    public var inferred: Bool
}

public enum PermissionPolicy {
    /// A catalogue base id for a sandbox's image (nil: a Dockerfile's, a template of one, the lab).
    public static func base(of config: SandboxConfig) -> String? {
        config.imageChoice.flatMap { BaseCatalogue.base($0.base) != nil ? $0.base : nil }
    }

    /// The names a setting's words (or `--allow`'s) give, from Standard for `base`: `standard` / `locked`
    /// / `open`, a list of ids (`+id` adds, `-id` removes; a bare id adds).
    public static func names(from words: [String], base: String?, start: [String]? = nil) -> [String] {
        var set = Set(start ?? AgentPermissions.preset("agent", base: base) ?? [])
        for w in words {
            switch w {
            case "standard": set = Set(AgentPermissions.preset("agent", base: base) ?? [])
            case "locked", "open": set = Set(AgentPermissions.preset(w, base: base) ?? [])
            default:
                if w.hasPrefix("-") { set.remove(String(w.dropFirst())) } else { set.insert(w.hasPrefix("+") ? String(w.dropFirst()) : w) }
            }
        }
        return AgentPermissions.normalized(Array(set))
    }

    /// A pre-597 policy of rules as the permissions it allows (every host of a permission allowed by
    /// it), and the rules no permission covers (kept as the user's own). Behaviour is kept: what it
    /// allowed stays allowed.
    public static func inferred(_ p: NetworkPolicy) -> (names: [String], rules: [EgressRule]) {
        if let names = p.permissions { return (names, p.rules) }
        var names: [String] = []
        // 599d: never inferred — the user's GitHub login is only ever on because it was switched on by name.
        for perm in AgentPermissions.all where perm.id != "web" && perm.group != "github" && !AgentPermissions.isAgentModel(perm.id) {
            let covered = perm.hosts.allSatisfy { h in
                let host = h.host.hasPrefix("*.") ? "x" + h.host.dropFirst(1) : h.host
                return p.evaluateConnection(host: host, port: h.ports?.first ?? 443).kind != .deny
            }
            if covered || perm.locked { names.append(perm.id) }
        }
        if p.defaultAction == .allow { names.append("web") }
        let hostsOf = Set(AgentPermissions.all.filter { names.contains($0.id) }.flatMap { $0.hosts.map(\.host) })
        let rest = p.rules.filter { !($0.action == .allow && hostsOf.contains($0.host)) }
        return (AgentPermissions.normalized(names), rest)
    }

    /// The same policy as permissions (a pre-597 one converted; a permissions one as it is).
    public static func asPermissions(_ p: NetworkPolicy, base: String?) -> NetworkPolicy {
        guard p.permissions == nil else { return p }
        let (names, rest) = inferred(p)
        var q = NetworkPolicy.permissions(names, preset: AgentPermissions.presetName(names, base: base))
        q.rules = rest
        return q
    }

    /// P6: grants and revokes — permission ids, or `site:HOST` (allowed first; revoked = denied).
    /// "model" cannot be revoked (the agent could not work). The preset is re-derived for `base`.
    /// 599i: `agent` — the sandbox's agent: its own model permission ("Talk to OpenAI" for Codex) is kept
    /// and cannot be revoked.
    public static func edited(_ current: NetworkPolicy, grant: [String], revoke: [String], base: String?, agent: AgentKind? = nil) throws -> NetworkPolicy {
        var p = asPermissions(current, base: base)
        var names = Set(p.permissions ?? [])
        for g in grant {
            if g.hasPrefix("site:") {
                let host = try site(g)
                p.rules.removeAll { $0.host == host && $0.action == .deny && !$0.hasHTTPConditions }
                if !p.rules.contains(where: { $0.host == host && $0.action == .allow && $0.ports == nil && !$0.hasHTTPConditions }) {
                    p.rules.insert(EgressRule(host: host, note: "site you allowed"), at: 0)
                }
            } else if g == "install" {
                for e in AgentPermissions.ecosystems { names.insert("install:" + e.id) }
            } else {
                guard AgentPermissions.isValid(g) else { throw HostError(.invalid, "no permission \(g) — doz net permissions lists them (or site:HOST)") }
                names.insert(g)
                // 599d: "Push to GitHub" is a step of "Use GitHub as you" — granting it grants both.
                if g == AgentPermissions.gitHubPush { names.insert(AgentPermissions.gitHubAsYou) }
            }
        }
        for r in revoke {
            if r.hasPrefix("site:") {
                let host = try site(r)
                p.rules.removeAll { $0.host == host && !$0.hasHTTPConditions }
                p.rules.insert(EgressRule(.deny, host: host, note: "site you denied"), at: 0)
            } else if r == "install" {
                for e in AgentPermissions.ecosystems { names.remove("install:" + e.id) }
            } else {
                guard let perm = AgentPermissions.permission(r) else { throw HostError(.invalid, "no permission \(r) — doz net permissions lists them (or site:HOST)") }
                guard !perm.locked else { throw HostError(.invalid, "\(perm.title) cannot be switched off — the agent needs it to work (use --network locked for nothing else)") }
                guard !AgentPermissions.agentPermissions(agent).contains(r) else {
                    throw HostError(.invalid, "\(perm.title) cannot be switched off — \(agent?.title ?? "the agent") needs it to work")
                }
                names.remove(r)
            }
        }
        let n = AgentPermissions.normalized(Array(names) + AgentPermissions.agentPermissions(agent))
        p.permissions = n
        p.preset = p.rules.isEmpty ? AgentPermissions.presetName(n, base: base) : nil
        return p
    }

    static func site(_ s: String) throws -> String {
        let host = String(s.dropFirst(5)).lowercased()
        guard host.range(of: #"^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#, options: .regularExpression) != nil,
              host.count <= 253 else { throw HostError(.invalid, "site: a host name like api.example.com (or *.example.com)") }
        return host
    }

    /// The checklist, the preset, the sites and the suggestions from `log` (denied connections).
    public static func report(name: String, policy: NetworkPolicy, base: String?, log: [ConnectionRecord]) -> PermissionReport {
        let inferredMode = policy.permissions == nil
        let (names, own) = inferred(policy)
        let standard = Set(AgentPermissions.preset("agent", base: base) ?? [])
        // 599i: an agent's own model permission is listed only where it is on (a Codex sandbox).
        let rows = AgentPermissions.all.filter { !AgentPermissions.isAgentModel($0.id) || names.contains($0.id) }.map { p in
            PermissionRow(id: p.id, title: p.title, summary: p.summary, on: names.contains(p.id),
                          locked: p.locked || AgentPermissions.isAgentModel(p.id), warning: p.warning,
                          group: p.group, hosts: p.hosts.map { h in h.host + (h.pathPrefixes != nil ? " (the agent's own package)" : "") },
                          standard: standard.contains(p.id) || AgentPermissions.isAgentModel(p.id))
        }
        var tmp = policy
        tmp.permissions = names
        tmp.rules = own
        let sites = own.filter { $0.action == .allow && !$0.hasHTTPConditions }.map(\.host)
        let deniedRecs = log.filter { $0.verdict == .denied }
        var byGrant: [String: PermissionSuggestion] = [:]
        var order: [String] = []
        for r in deniedRecs {
            let host = r.host.lowercased()
            let grant: String, what: String, perm: String?
            if let p = AgentPermissions.permission(forHost: host) {
                guard !names.contains(p.id) else { continue }       // on, but a rule of the user's denied it
                grant = p.id; what = p.phrase; perm = p.id
            } else {
                grant = "site:" + host; what = host; perm = nil
            }
            if byGrant[grant] == nil { order.append(grant); byGrant[grant] = PermissionSuggestion(permission: perm, what: what, hosts: [], count: 0, grant: grant) }
            if !byGrant[grant]!.hosts.contains(host) { byGrant[grant]!.hosts.append(host) }
            byGrant[grant]!.count += 1
        }
        return PermissionReport(name: name, base: base, preset: inferredMode ? AgentPermissions.presetName(names, base: base) : policy.preset,
                                permissions: rows, sites: sites, denied: Array(Set(deniedRecs.map(\.host))).sorted(),
                                suggestions: order.prefix(12).compactMap { byGrant[$0] }, inferred: inferredMode)
    }

    /// P7: the facts block's line — "You may talk to your AI model, update yourself, …; you may not
    /// browse the web (any site), sign in …. A refused action needs the user to switch its permission
    /// on — ask for it by name (e.g. "Browse the web": doz net allow NAME web)."
    public static func facts(_ policy: NetworkPolicy, sandbox: String) -> String {
        let (names, own) = inferred(policy)
        let on = AgentPermissions.all.filter { names.contains($0.id) }.map(\.phrase)
        let off = AgentPermissions.all.filter { !names.contains($0.id) && !AgentPermissions.isAgentModel($0.id) }
        var s = "You may " + list(on) + "."
        let sites = own.filter { $0.action == .allow && !$0.hasHTTPConditions }.map(\.host)
        if !sites.isEmpty { s += " Sites the user allowed: " + sites.prefix(20).joined(separator: ", ") + "." }
        if !off.isEmpty {
            s += " You may not " + list(off.map(\.phrase)) + "."
            s += " A refused connection needs the user to switch its permission on — ask for it by its name, e.g. \"\(off[0].title)\" (`doz net allow \(sandbox) \(off[0].id)`), or a site (`doz net allow \(sandbox) site:HOST`); do not try to get around it."
        }
        return s
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return "nothing"
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}
