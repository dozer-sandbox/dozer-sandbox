import ArgumentParser
import Foundation
import DozerKit
import DozerHost

// 599g — `doz ignore check|show`: workspace rules (.dozignore / .dozreadonly) explained from the Mac. No VM
// is needed to say which line decides a path; `show` also says whether the sandbox's view runs now.

struct IgnoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ignore",
        abstract: "Workspace rules: what a .dozignore / .dozreadonly in a sandbox's workspace folder does, and why.",
        discussion: """
        A .dozignore at the root of a sandbox's workspace folder (Docker's .dockerignore syntax: one pattern a \
        line, anchored at the root, ** for any depth, !pattern re-includes, the last matching line wins) \
        selects paths: with workspace.ignore_mode lock (the default) they stay listed with no permissions \
        and every read, write, rename or delete is refused; with hide they are not there at all. A \
        .dozreadonly (same syntax) makes paths visible but read-only. doz_project.yaml, doz_project.yml, \
        .git/hooks and the two rule files are read-only too. Names are compared case-insensitively when \
        the Mac volume is. Without either file the folder is shared as it is. Changes on the Mac apply in \
        the sandbox within a second. Not a security boundary: root in the sandbox can get around it.
        """,
        subcommands: [IgnoreCheck.self, IgnoreShow.self])
}

struct IgnoreCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "check",
        abstract: "Which rule decides each path — locked, hidden, read-only or visible — and from which line of which file.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox.") var name: String
    @Argument(help: "Paths: relative to the workspace, /workspace/…, or the Mac path inside the folder.") var paths: [String]

    func run() async throws {
        var r = HostRequest(.workspaceRules, name: name)
        r.paths = paths
        let rep = try decode(try await query(r, g), WorkspaceRulesReport.self, g)
        if g.json { Out.json(rep); return }
        if !rep.active {
            Out.stdout("\(rep.sandbox) has no .dozignore or .dozreadonly in \(rep.workspace ?? "its folder") — every path is visible and writable as on the Mac.\n")
            return
        }
        var rows: [[String]] = [["PATH", "IN THE SANDBOX", "WHY"]]
        for c in rep.checks ?? [] { rows.append([c.path.isEmpty ? "." : c.path, c.verdict.rawValue, IgnoreText.why(c, mode: rep.mode)]) }
        Out.stdout(Out.table(rows))
        Out.stdout("\n" + IgnoreText.footer(rep) + "\n")
    }
}

struct IgnoreShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show",
        abstract: "A sandbox's workspace rules: every pattern with its line, the mode, warnings, and whether the view runs in the sandbox.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox.") var name: String

    func run() async throws {
        var r = HostRequest(.workspaceRules, name: name)
        r.warnings = true
        let rep = try decode(try await query(r, g), WorkspaceRulesReport.self, g)
        if g.json { Out.json(rep); return }
        guard let w = rep.workspace else {
            Out.stdout("\(rep.sandbox) is isolated — no folder of this Mac is shared, so there is nothing to rule.\n")
            return
        }
        guard rep.active else {
            Out.stdout("\(rep.sandbox) shares \(w) at \(rep.guestPath) as it is — no .dozignore or .dozreadonly there.\n")
            return
        }
        Out.stdout("Workspace rules of \(rep.sandbox) — \(w) at \(rep.guestPath)\n\n")
        let user = rep.ignore
        Out.stdout(".dozignore — the paths it lists are \(rep.mode == "hide" ? "HIDDEN (not there)" : "LOCKED (listed, every access refused)")"
                   + " · workspace.ignore_mode = \(rep.mode) (\(IgnoreText.source(rep.modeSource)))\n")
        if user.isEmpty { Out.stdout("  (no .dozignore, or no pattern in it)\n") }
        for rule in user { Out.stdout(String(format: "  %4d  %@\n", rule.line ?? 0, rule.pattern)) }
        Out.stdout("\n.dozreadonly — visible, every change refused\n")
        Out.stdout("  always  \(WorkspaceRules.implicitReadOnly.joined(separator: ", ")) (a `!` line re-allows one), and .dozignore, .dozreadonly\n")
        for rule in rep.readOnly where rule.file != nil { Out.stdout(String(format: "  %4d  %@\n", rule.line ?? 0, rule.pattern)) }
        for p in rep.problems { Out.stdout("  \(p.file) line \(p.line): `\(p.text)` — \(p.reason), skipped\n") }
        Out.stdout("\n" + IgnoreText.footer(rep) + "\n")
        if let warnings = rep.warnings, !warnings.isEmpty {
            Out.stdout("\nWarnings:\n")
            for x in warnings { Out.stdout("  ! \(x)\n") }
        }
    }
}

enum IgnoreText {
    static func source(_ s: String) -> String {
        switch s {
        case "sandbox": "this sandbox's own choice"
        case "file": "the settings file"
        case "env": "the environment"
        case "flag": "a flag"
        default: "the default"
        }
    }

    static func why(_ c: WorkspaceRules.Decision, mode: String) -> String {
        if c.ruleFile { return "a rule file — always visible and read-only" }
        guard let rule = c.rule else {
            return c.skeleton ? "a folder .dozignore selects, shown for what a ! line re-includes in it" : "no rule"
        }
        var s = rule.file == nil ? "always read-only (`\(rule.pattern)`)" : rule.label
        if let m = c.matched, m != c.path { s += " — through \(m)" }
        if c.folded { s += ", matched case-insensitively" }
        if c.skeleton { s += "; its re-included contents are shown" }
        return s
    }

    static func footer(_ rep: WorkspaceRulesReport) -> String {
        var lines: [String] = []
        if rep.caseInsensitive { lines.append("Names are compared without case or Unicode form, as the Mac volume does (only ever selecting more than Docker would).") }
        switch rep.view {
        case "running":
            var s = "In the sandbox: the view is running"
            if let st = rep.viewState {
                var bits: [String] = []
                if let r = st["requests"] { bits.append("\(r) requests") }
                if let r = st["restarts"], r != "0" { bits.append("restarted \(r)×") }
                if let d = st["dropped"], d != "0" { bits.append("\(d) line(s) skipped") }
                if !bits.isEmpty { s += " (" + bits.joined(separator: ", ") + ")" }
            }
            lines.append(s + ". A change on the Mac applies within a second.")
        case "pending": lines.append("In the sandbox: not yet — the rules apply from its next session or wake.")
        case "failed": lines.append("In the sandbox: the view is NOT running — \(rep.guestPath) is empty there until the next wake or start.")
        case "off": lines.append("In the sandbox: the folder is shared as it is.")
        default: lines.append("In the sandbox: the rules apply when it runs.")
        }
        lines.append("A convenience mask, not a security boundary: root in the sandbox can get around it.")
        return lines.joined(separator: "\n")
    }
}

/// At create / up / start: the rules in force and what they might break — on stderr, never fatal, never
/// with --json or -q.
func noteWorkspaceRules(_ name: String, _ g: GlobalOptions) async {
    guard !g.json, !g.quiet else { return }
    var r = HostRequest(.workspaceRules, name: name)
    r.warnings = true
    guard let v = try? await query(r, g), let rep = try? v.decode(WorkspaceRulesReport.self), rep.active else { return }
    let user = rep.readOnly.filter { $0.file != nil }.count
    Out.stderr("[doz] workspace rules: .dozignore \(rep.ignore.count) pattern\(rep.ignore.count == 1 ? "" : "s") (\(rep.mode)), .dozreadonly \(user) — doz ignore show \(name)\n")
    for w in rep.warnings ?? [] { Out.stderr("[doz] warning: \(w)\n") }
}
