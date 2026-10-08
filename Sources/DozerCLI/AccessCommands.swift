import ArgumentParser
import Darwin
import Foundation
import DozerKit
import DozerHost

// 599e — the Access step (owner, 2026-10-02: "github access on or off would be a pusposeful choice … a general
// 'Access' step in the onboarding where the credentials get confirmed (with the option to skip the
// confirmation if there is an issue so the onboarding doesnt get blocked)"). `doz onboard` runs it after the
// Claude account; `doz access` shows and confirms again; `doz access set` changes a choice.

/// The GitHub and SSH choices of the Access step (the Claude account is chosen by its own questions).
struct AccessChoices: Equatable {
    var github: String          // off · read · push
    var githubSource: String    // gh · key
    var ssh: String             // off · on
}

/// Choose (or take the flags), set a key when one is given, CONFIRM each credential live, and on a failure
/// offer Skip (keep the choice, not confirmed) · Turn it off · Check again. Never blocks: off a terminal (or
/// `--yes`) a failure is skipped with a note.
struct AccessStep {
    let g: GlobalOptions
    let asker: Asker
    let talk: Bool
    var githubFlag: String?
    var sourceFlag: String?
    var sshFlag: String?
    /// A GitHub token to set as the default key (already read — never printed).
    var githubKey: String?
    /// Confirm the Claude account too (false: "decide later").
    var checkClaude = true
    /// 599f: whose choice it is — "new sandboxes" (onboarding) or "this sandbox" (`doz init`, a project).
    var subject = "new sandboxes"
    /// 599f: ask where the token comes from (a setting of the Mac's — not a project's: `doz init` does not ask).
    var askSource = true
    /// 599f: the choices before the questions (a project file's), else the settings'.
    var start: AccessChoices?

    func say(_ s: String) { if talk { Out.stdout(s + "\n") } }

    /// The choices: the flags, else the questions (on a terminal), else the settings as they are.
    func choose() -> AccessChoices {
        let s = DozerSettings.load()
        var c = AccessChoices(github: githubFlag ?? start?.github ?? s.string(SettingKey.defaultGithub) ?? "off",
                              githubSource: sourceFlag ?? start?.githubSource ?? s.string(SettingKey.githubCredentials).flatMap { $0 == "off" ? "gh" : $0 } ?? "gh",
                              ssh: sshFlag ?? start?.ssh ?? s.string(SettingKey.sshAgent) ?? "off")
        if githubFlag == nil {
            let opts = ["off", "read", "push"]
            let i = asker.choose("  GitHub as you — should git and gh in \(subject) be signed in to GitHub as you? (the token stays on this Mac)",
                                 ["Off — not signed in as you (public repositories still work)",
                                  "Read-only — clone and read your private repositories, issues and pull requests; no push",
                                  "Read and push — also push and change things on GitHub as you"],
                                 preferred: opts.firstIndex(of: c.github) ?? 0)
            c.github = opts[i]
        }
        if c.github != "off", sourceFlag == nil, askSource {
            let i = asker.choose("  Where the GitHub token comes from:",
                                 ["This Mac's gh login (gh auth token — gh auth logout ends it)",
                                  "A token you give Dozer (best: a fine-grained token limited to some repositories)"],
                                 preferred: c.githubSource == "key" ? 1 : 0)
            c.githubSource = i == 1 ? "key" : "gh"
        }
        if sshFlag == nil {
            let i = asker.choose("  SSH agent forwarding — let ssh and git over SSH in \(subject == "new sandboxes" ? "sandboxes" : subject) ask this Mac's ssh-agent to sign? (github.com only; keys stay on the Mac)",
                                 ["Off", "On"], preferred: c.ssh == "on" ? 1 : 0)
            c.ssh = i == 1 ? "on" : "off"
        }
        return c
    }

    /// Confirm the choices (and, when asked, the Claude account); a failure → Skip / Turn it off / Check again.
    /// Returns the choices as they end (a credential turned off here is off) and the last report.
    func confirm(_ start: AccessChoices) throws -> (AccessChoices, AccessReport) {
        var c = start
        if let key = githubKey {
            var r = HostRequest(.accessGithubKey)
            r.secret = key
            _ = try call(r, g)
            say("  a default GitHub key is set (held in the login keychain as doz-github — never in a sandbox)")
        }
        func check(_ items: [String]) throws -> AccessReport {
            var r = HostRequest(.access)
            r.check = true
            r.items = items
            r.accessChoices = ["github": c.github, "githubSource": c.githubSource, "ssh": c.ssh]
            return try decode(try call(r, g), AccessReport.self, g)
        }
        var items = (checkClaude ? ["claude"] : []) + ["github", "ssh"]
        var report = try check(items)
        var shown = Set<String>()
        while true {
            for it in report.items where items.contains(it.id) && !shown.contains(it.id) { say(Self.line(it)); shown.insert(it.id) }
            let failed = report.items.filter { items.contains($0.id) && $0.state == "failed" }
            guard let f = failed.first else { break }
            if !asker.interactive {
                say("    skipped — kept, not confirmed (onboarding goes on; check again later: doz access)")
                items.removeAll { $0 == f.id }
                continue
            }
            let canTurnOff = f.id != "claude"
            let opts = ["Skip — keep \(f.title) on, not confirmed (doz access checks again later)"]
                + (canTurnOff ? ["Turn \(f.title) off"] : []) + ["Check again"]
            let i = asker.choose("  \(f.title) is not confirmed: \(f.detail)", opts, preferred: 0)
            if i == 0 {
                items.removeAll { $0 == f.id }
            } else if canTurnOff && i == 1 {
                if f.id == "github" { c.github = "off" } else { c.ssh = "off" }
                shown.remove(f.id)
                report = try check([f.id])
                items = items.filter { $0 != f.id }
                for it in report.items where it.id == f.id { say(Self.line(it)) }
            } else {
                shown.remove(f.id)
                report = try check(items)
            }
        }
        return (c, report)
    }

    static func mark(_ state: String) -> String {
        switch state { case "confirmed": "✓"; case "failed": "✗"; case "off": "—"; default: "?" }
    }

    static func line(_ it: AccessItem) -> String {
        let choice = it.choice + (it.id == "github" && it.choice != "off" ? " (\(it.source == "key" ? "a key" : "gh login"))" : "")
        let state = it.state == "failed" ? "not confirmed — \(it.detail)" : it.state == "confirmed" ? "confirmed — \(it.detail)" : it.state == "off" ? "off" : it.detail
        return "  \(mark(it.state)) \(it.title.padding(toLength: 21, withPad: " ", startingAt: 0)) \(choice.padding(toLength: 16, withPad: " ", startingAt: 0)) \(state)\n      \(it.consequence)"
    }
}

/// Read a GitHub token: stdin (`fromStdin`) or a no-echo prompt on a terminal; nil when neither.
func readGitHubToken(fromStdin: Bool) -> String? {
    if fromStdin {
        let s = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
    guard isatty(STDIN_FILENO) != 0 else { return nil }
    var buf = [CChar](repeating: 0, count: 4096)
    guard let p = readpassphrase("  GitHub token (not echoed): ", &buf, buf.count, 0) else { return nil }
    let s = String(cString: p).trimmingCharacters(in: .whitespacesAndNewlines)
    memset(&buf, 0, buf.count)
    return s.isEmpty ? nil : s
}

// MARK: doz access

struct AccessCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "access",
        abstract: "Every credential sandboxes can use — the Claude account, GitHub as you, the SSH agent — confirmed live; set a choice.",
        subcommands: [AccessShow.self, AccessSet.self], defaultSubcommand: AccessShow.self)
}

struct AccessShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show",
        abstract: "Show each credential choice and confirm it works now (the default: doz access).")
    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "Only show the last confirmation (looks in the store; checks nothing, starts no host).") var noCheck = false

    func run() async throws {
        var r = HostRequest(.access)
        r.check = !noCheck
        let report = try decode(try noCheck ? await query(r, g) : call(r, g), AccessReport.self, g)
        if g.json { Out.json(report); return }
        for it in report.items { Out.stdout(AccessStep.line(it) + "\n") }
        if report.githubKeySet { Out.stdout("\n  a default GitHub key is set (github.credentials = key uses it)\n") }
        Out.stdout("\nChange: doz access set --github off|read|push [--github-source gh|key] [--ssh-agent on|off] · the Claude account: doz account default NAME\n")
    }
}

struct AccessSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set",
        abstract: "Change an Access choice (the defaults for new sandboxes) and confirm it — failures are said, never blocking.")
    @OptionGroup var g: GlobalOptions
    @Option(name: .long, help: "off, read or push: new sandboxes signed in to GitHub as you (the setting defaults.github).") var github: String?
    @Option(name: .long, help: "gh (this Mac's gh login) or key (a token you give: --github-key) — the setting github.credentials.") var githubSource: String?
    @Flag(name: .long, help: "Set the default GitHub token: pasted at a no-echo prompt (or read from stdin off a terminal). Held in the login keychain (doz-github), never in a sandbox.") var githubKey = false
    @Flag(name: .long, help: "Forget the default GitHub token.") var removeGithubKey = false
    @Option(name: .long, help: "on or off: forward this Mac's ssh-agent into sandboxes (github.com only) — the setting sandbox.ssh_agent.") var sshAgent: String?
    @Flag(name: .long, help: "Do not confirm (only set).") var noCheck = false

    func validate() throws {
        if let v = github, !["off", "read", "push"].contains(v) { throw ValidationError("--github: off, read or push") }
        if let v = githubSource, !["gh", "key"].contains(v) { throw ValidationError("--github-source: gh or key") }
        if let v = sshAgent, !["on", "off"].contains(v) { throw ValidationError("--ssh-agent: on or off") }
        if githubKey && removeGithubKey { throw ValidationError("--github-key or --remove-github-key, not both") }
        if github == nil && githubSource == nil && sshAgent == nil && !githubKey && !removeGithubKey {
            throw ValidationError("set what? --github, --github-source, --github-key, --remove-github-key or --ssh-agent")
        }
    }

    func run() async throws {
        if removeGithubKey {
            var r = HostRequest(.accessGithubKey)
            r.clearSetting = true
            _ = try call(r, g)
            if !g.json { Out.stdout("the default GitHub key is removed\n") }
        }
        var key: String?
        if githubKey {
            guard let k = readGitHubToken(fromStdin: isatty(STDIN_FILENO) == 0) else {
                throw fail(HostError(.invalid, "no token read (paste it at the prompt, or pipe it: doz access set --github-key < token.txt)"), g)
            }
            key = k
        }
        let done: [String]
        do { done = try Access.write(github: github, githubSource: githubSource ?? (key != nil ? "key" : nil), ssh: sshAgent) } catch {
            throw fail(HostError(.invalid, "\(error)"), g)
        }
        if !g.json { for d in done { Out.stdout("set \(d)\n") } }
        var step = AccessStep(g: g, asker: Asker(yes: true, json: g.json), talk: !g.json)
        step.githubKey = key
        step.checkClaude = false
        if noCheck {
            if let key {
                var r = HostRequest(.accessGithubKey)
                r.secret = key
                _ = try call(r, g)
            }
            return
        }
        let s = DozerSettings.load()
        let (_, report) = try step.confirm(AccessChoices(github: s.string(SettingKey.defaultGithub) ?? "off",
                                                         githubSource: s.string(SettingKey.githubCredentials) ?? "gh",
                                                         ssh: s.string(SettingKey.sshAgent) ?? "off"))
        if g.json { Out.json(report) }
    }
}
