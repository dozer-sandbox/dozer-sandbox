import ArgumentParser
import Foundation
import DozerKit
import DozerHost

// 597 (P6) — the CLI speaks permissions: `doz net NAME` (the checklist), `doz net allow|deny NAME
// PERMISSION… | site:HOST…`, `doz net permissions` (every permission and its hosts). `doz net policy`
// stays for raw rules.

func printPermissions(_ r: PermissionReport) {
    Out.stdout("\(r.name): what the agent can do — \(r.preset.map { $0 == "agent" ? "Standard" : $0.capitalized } ?? "Custom")"
               + (r.base.map { " (base \($0))" } ?? "") + (r.inferred ? " — an older policy of rules, shown as permissions" : "") + "\n")
    for p in r.permissions {
        let mark = p.on ? "[x]" : "[ ]"
        let indent = p.group == "install" ? "      " : "  "
        let head = p.group == "install" ? "Install software — " + p.title : p.title
        Out.stdout("\(indent)\(mark) \(head)\(p.locked ? " (always)" : "")  — \(p.summary)\(p.warning.map { " ⚠ " + $0 } ?? "")  [\(p.id)]\n")
    }
    if !r.sites.isEmpty { Out.stdout("  sites you allowed: \(r.sites.joined(separator: ", "))\n") }
    if !r.suggestions.isEmpty {
        Out.stdout("refused lately:\n")
        for s in r.suggestions {
            Out.stdout("  the agent tried to \(s.permission != nil ? s.what : "reach " + s.what) (\(s.hosts.joined(separator: ", ")), \(s.count) time\(s.count == 1 ? "" : "s")) — doz net allow \(r.name) \(s.grant)\n")
        }
    }
}

struct NetShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "What the agent can do: its permissions as a checklist, its sites, and what it was refused lately (the default: doz net NAME).")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    func run() async throws {
        let r = try decode(try await query(HostRequest(.netPermissions, name: name), g), PermissionReport.self, g)
        if g.json { Out.json(r) } else { printPermissions(r) }
    }
}

/// allow / deny: permission ids (`install:python`, `web`, `install` = every ecosystem), `site:HOST`,
/// or a preset (`standard`, `locked`, `open`).
func changePermissions(_ name: String, grant: [String], revoke: [String], preset: String?, _ g: GlobalOptions) throws {
    var r = HostRequest(.netPolicy, name: name)
    r.grant = grant.isEmpty ? nil : grant
    r.revoke = revoke.isEmpty ? nil : revoke
    r.preset = preset
    _ = try call(r, g)
    let rep = try decode(try call(HostRequest(.netPermissions, name: name), g), PermissionReport.self, g)
    if g.json { Out.json(rep) } else { printPermissions(rep) }
}

struct NetAllow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "allow",
        abstract: "Switch permissions on (install:python, web, update, …; install = every ecosystem), allow a site (site:api.example.com), or set a preset (standard, locked, open). Live.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument(help: "Permission ids (doz net permissions), site:HOST, or standard / locked / open.") var what: [String]
    @Flag(name: [.short, .long], help: "Do not ask (Browse the web warns first).") var yes = false
    func run() async throws {
        guard !what.isEmpty else { throw ValidationError("allow what? a permission (doz net permissions) or site:HOST") }
        let presets = what.filter { ["standard", "locked", "open"].contains($0) }
        if what.contains("web") || presets.contains("open"), let w = AgentPermissions.permission("web")?.warning {
            if !g.json { Out.stderr("Browse the web: \(w)\n") }
            try confirm("Let the agent reach any website?", yes: yes, g)
        }
        // 599d: the user's GitHub login is said before it is switched on.
        if what.contains(AgentPermissions.gitHubPush) || what.contains(AgentPermissions.gitHubAsYou) {
            let push = what.contains(AgentPermissions.gitHubPush)
            if let w = AgentPermissions.permission(push ? AgentPermissions.gitHubPush : AgentPermissions.gitHubAsYou)?.warning, !g.json {
                Out.stderr("\(push ? "Push to GitHub" : "Use GitHub as you"): \(w) The token never enters the sandbox; doz net deny \(name) github:as-you revokes it at once.\n")
            }
            try confirm(push ? "Let the agent push and act on GitHub as you?" : "Sign the agent in to GitHub as you (read-only)?", yes: yes, g)
        }
        try changePermissions(name, grant: what.filter { !presets.contains($0) }, revoke: [], preset: presets.last.map { $0 == "standard" ? "agent" : $0 }, g)
    }
}

struct NetDeny: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "deny",
        abstract: "Switch permissions off (web, update, install:node, …) or deny a site (site:HOST). Live.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument(help: "Permission ids (doz net permissions) or site:HOST.") var what: [String]
    func run() async throws {
        guard !what.isEmpty else { throw ValidationError("deny what? a permission (doz net permissions) or site:HOST") }
        try changePermissions(name, grant: [], revoke: what, preset: nil, g)
    }
}

struct NetPermissionsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "permissions", abstract: "Every permission, what it means, and the hosts behind it (this doz's).")
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        if g.json { Out.json(AgentPermissions.all); return }
        var t = [["PERMISSION", "WHAT IT MEANS", "HOSTS"]]
        for p in AgentPermissions.all {
            t.append([p.id, (p.group == "install" ? "Install software — " : "") + p.title + ": " + p.summary + (p.warning.map { " ⚠ " + $0 } ?? ""),
                      p.hosts.map { $0.host + ($0.pathPrefixes != nil ? " (its own package)" : "") }.joined(separator: ", ")])
        }
        Out.stdout(Out.table(t))
        Out.stdout("\nPresets: locked (model only), standard (model, update, system + the base's packages, github, error-reports), open (everything but your GitHub login — github:as-you and github:push are only ever switched on by name).\n"
                   + "doz net allow NAME PERMISSION|site:HOST · doz net deny NAME … · doz create NAME --allow web,site:… · the setting defaults.permissions\n")
    }
}
