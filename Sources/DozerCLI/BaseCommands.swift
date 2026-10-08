import ArgumentParser
import Foundation
import DozerKit
import DozerHost

// 596 — Dozer Base Images in the CLI: `doz base ls` (the recommended bases), `doz builder
// status|start|install` (Apple's container tool, for Dockerfile bases), and the question a Dockerfile
// sandbox asks before its first build.

/// `~/…` for a path under the home folder.
func tildePath(_ p: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
}

struct BaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "base",
        abstract: "The recommended bases a sandbox's image is made from (an image is a base × an agent).",
        subcommands: [BaseList.self])
}

struct BaseList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls",
        abstract: "List the recommended bases: the image each follows, its download, the registries its sandboxes reach, which agents' images are prepared.")
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        let rows = try decode(try await query(HostRequest(.bases), g), [BaseRow].self, g)
        if g.json { Out.json(rows); return }
        var t = [["BASE", "IMAGE", "DOWNLOAD", "FIRST PREPARE", "PREPARED", "REGISTRIES"]]
        for r in rows {
            let digest = String(r.digest.dropFirst(7).prefix(12)) + (r.pinned ? " (pin)" : "") + (r.updateAvailable == true ? " — update available" : "")
            t.append(["\(r.id) — \(r.title)", "\(r.reference) @ \(digest)", DozerImages.formatBytes(r.downloadBytes),
                      "~\(max(1, r.prepareSeconds / 60)) min", r.prepared.isEmpty ? "—" : r.prepared.joined(separator: ", "),
                      r.registries.isEmpty ? "(the agent preset's)" : r.registries.joined(separator: ", ")])
        }
        Out.stdout(Out.table(t))
        Out.stdout("\nA sandbox: doz create NAME --base BASE --agent claude-code|pi|codex|none — or --dockerfile PATH (your own; built with Apple's container build, outside Dozer's network policy).\n")
    }
}

struct BuilderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "builder",
        abstract: "Apple's container tool, which builds Dockerfile bases (installed on demand; its services started only when you say so).",
        subcommands: [BuilderStatus.self, BuilderStart.self, BuilderInstall.self])
}

struct BuilderStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Whether Apple's container tool is installed, supported and running.")
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        let s = try decode(try await query(HostRequest(.builderStatus), g), ContainerToolStatus.self, g)
        if g.json { Out.json(s); return }
        Out.stdout(s.note + "\n")
        switch s.state {
        case "missing", "unsupported": Out.stdout("\n" + s.installNote + "\n→ doz builder install\n")
        case "stopped": Out.stdout("\n" + s.startNote + "\n→ doz builder start\n")
        default: break
        }
        Out.stdout("\n" + Dockerfiles.outsidePolicyNote + "\n")
    }
}

struct BuilderStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start",
        abstract: "Start Apple's container services (container system start --enable-kernel-install) — asks first.")
    @OptionGroup var g: GlobalOptions
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false
    func run() async throws {
        let s = try decode(try await query(HostRequest(.builderStatus), g), ContainerToolStatus.self, g)
        guard s.state != "ready" else { if !g.json { Out.stdout(s.note + "\n") } else { Out.json(s) }; return }
        guard s.state == "stopped" else { throw fail(HostError(.unavailable, ContainerTool.problem(s) ?? s.note), g) }
        if !g.json { Out.stderr(s.startNote + "\n") }
        try confirm("Start Apple's container services now?", yes: yes, g)
        var r = HostRequest(.builderStart)
        r.requestedBy = "doz builder start"
        let after = try decode(try call(r, g), ContainerToolStatus.self, g)
        if g.json { Out.json(after) } else { Out.stdout(after.note + "\n") }
    }
}

struct BuilderInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install",
        abstract: "Install Apple's container tool: its signed package (pinned, sha256-checked) opened in macOS Installer — asks first; never sudo.")
    @OptionGroup var g: GlobalOptions
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false
    func run() async throws {
        let s = try decode(try await query(HostRequest(.builderStatus), g), ContainerToolStatus.self, g)
        guard s.state == "missing" || s.state == "unsupported" else {
            if g.json { Out.json(s) } else { Out.stdout(s.note + (s.state == "stopped" ? " — doz builder start\n" : "\n")) }
            return
        }
        if !g.json { Out.stderr(s.installNote + "\n") }
        try confirm("Install Apple's container tool (\(ContainerTool.package.version))?", yes: yes, g)
        var r = HostRequest(.builderInstall)
        r.requestedBy = "doz builder install"
        let after = try decode(try call(r, g), ContainerToolStatus.self, g)
        if g.json { Out.json(after) } else {
            Out.stdout("Approve it in macOS Installer; then: doz builder start\n")
            Out.stdout(after.note + "\n")
        }
    }
}

/// 596 (B7, B9): before a Dockerfile sandbox's first build — say where the build runs, and make sure
/// Apple's tool can build: on a terminal, offer to install it or start its services (the person's
/// yes is the consent); otherwise say exactly what to run. `required`: a build follows now (start/up).
func builderPreflight(_ g: GlobalOptions, required: Bool, yes: Bool = false) async throws {
    let s = try decode(try await query(HostRequest(.builderStatus), g), ContainerToolStatus.self, g)
    if !g.quiet { Out.stderr("[doz] \(Dockerfiles.outsidePolicyNote)\n") }     // stderr: --json's stdout stays JSON
    guard s.state != "ready" else { return }
    guard required else {
        if !g.json { Out.stderr("[doz] \(s.note) Its first start builds the Dockerfile: \(s.state == "stopped" ? "doz builder start" : "doz builder install") first.\n") }
        return
    }
    let tty = isatty(STDIN_FILENO) == 1 && isatty(STDERR_FILENO) == 1
    guard tty || yes else { throw fail(HostError(.unavailable, ContainerTool.problem(s) ?? s.note), g) }
    switch s.state {
    case "stopped":
        Out.stderr(s.note + "\n" + s.startNote + "\n")
        try confirm("Start Apple's container services now?", yes: yes, g)
        var r = HostRequest(.builderStart)
        r.requestedBy = "the Dockerfile's first build"
        let after = try decode(try call(r, g), ContainerToolStatus.self, g)
        guard after.state == "ready" else { throw fail(HostError(.unavailable, after.note), g) }
    default:
        Out.stderr(s.installNote + "\n")
        try confirm("Install Apple's container tool (\(ContainerTool.package.version))?", yes: yes, g)
        var r = HostRequest(.builderInstall)
        r.requestedBy = "the Dockerfile's first build"
        _ = try call(r, g)
        throw fail(HostError(.unavailable, "approve Apple's installer, then `doz builder start`, then run this again"), g)
    }
}
