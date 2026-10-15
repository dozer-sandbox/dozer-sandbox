import ArgumentParser
import Foundation
import DozerKit
import DozerHost

// 617 (RP-1, owner: "web port forwarding first") — `doz ports` and `doz open`: a sandbox's web ports on this Mac's
// loopback. A recipe's own ports are forwarded while the sandbox runs; `doz ports add` adds any other (a dev server).

struct PortsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ports",
        abstract: "A sandbox's web ports on this Mac: list them, add one, remove one.",
        discussion: """
        A forward makes a port a program listens on inside the sandbox (its own localhost) reachable on this Mac \
        at 127.0.0.1 — never on the network. It listens while the sandbox runs and closes when it stops, sleeps or \
        hibernates; it comes back by itself at the next start or wake. The Mac port is the sandbox's when it is free \
        (and 1024 or above); otherwise another is picked, and said. The forward is inbound only: it lets this Mac \
        reach the program, never the program reach anything, and no key passes through it. An image's recipe can \
        declare its own ports (its Open buttons); `doz ports add` adds any other, kept until removed.
        """,
        subcommands: [PortsList.self, PortsAdd.self, PortsRemove.self],
        defaultSubcommand: PortsList.self)
}

enum PortsText {
    static func wakeHint(_ a: PortsAnswer) -> String {
        ["asleep", "hibernated", "paused"].contains(a.phase) ? "doz wake \(a.sandbox)" : "doz start \(a.sandbox)"
    }

    static func print(_ a: PortsAnswer) {
        if let n = a.note { Out.stdout(n + "\n") }
        guard !a.ports.isEmpty else {
            Out.stdout("\(a.sandbox) forwards no ports. Add one with doz ports add \(a.sandbox) PORT.\n")
            return
        }
        var rows: [[String]] = [["PORT", "TITLE", "ON THIS MAC", "STATE", "FROM"]]
        for p in a.ports {
            let mac = p.url ?? p.macPort.map { "127.0.0.1:\($0)" } ?? "—"
            var state = p.state
            if p.state == "failed", let why = p.why { state += ": \(why)" }
            if p.moved == true, p.state == "listening" { state += " (moved: \(p.port) was taken)" }
            rows.append([String(p.port), p.title, mac, state, p.origin == "recipe" ? "recipe" : "added"])
        }
        Out.stdout(Out.table(rows))
        if a.phase != "running" { Out.stdout("\n\(a.sandbox) is \(a.phase) — its ports listen while it runs (\(PortsText.wakeHint(a))).\n") }
        for p in a.ports where p.auth == "token" { Out.stdout("\n\(p.title) asks for a token: \(p.tokenHint ?? "see its output").\n") }
    }
}

struct PortsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls",
        abstract: "The sandbox's forwarded ports: the guest port, its URL on this Mac, and whether it listens.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox.") var name: String

    func run() async throws {
        let a = try decode(try await query(HostRequest(.ports, name: name), g), PortsAnswer.self, g)
        if g.json { Out.json(a); return }
        PortsText.print(a)
    }
}

struct PortsAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add",
        abstract: "Forward another port of the sandbox to this Mac (a dev server, a web UI you started) — kept until removed.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox.") var name: String
    @Argument(help: "The port the program listens on inside the sandbox.") var port: Int
    @Option(name: .long, help: "What to call it (default: port N).") var title: String?
    @Option(name: .long, help: "The path doz open opens (default /).") var path: String?

    func run() async throws {
        var r = HostRequest(.ports, name: name)
        r.portAdd = PortForwardEntry(port: port, title: title, path: path)
        let a = try decode(try await query(r, g), PortsAnswer.self, g)
        if g.json { Out.json(a); return }
        PortsText.print(a)
    }
}

struct PortsRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm",
        abstract: "Stop forwarding a port you added (a recipe's own ports stay).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox.") var name: String
    @Argument(help: "The port inside the sandbox.") var port: Int

    func run() async throws {
        var r = HostRequest(.ports, name: name)
        r.portRemove = port
        let a = try decode(try await query(r, g), PortsAnswer.self, g)
        if g.json { Out.json(a); return }
        PortsText.print(a)
    }
}

struct OpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open",
        abstract: "Open a sandbox's web port in this Mac's browser (its first web port, or PORT).",
        discussion: """
        Opens the forward's URL (http://127.0.0.1:MACPORT/PATH). It starts nothing: a sandbox that is not running \
        says so (its ports listen while it runs). --print prints the URL instead.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox.") var name: String
    @Argument(help: "The port inside the sandbox (default: its first web port).") var port: Int?
    @Flag(name: .long, help: "Print the URL instead of opening it.") var print = false

    func run() async throws {
        let a = try decode(try await query(HostRequest(.ports, name: name), g), PortsAnswer.self, g)
        let web = a.ports.filter { $0.protocol == "http" }
        guard !web.isEmpty else { throw HostError(.notFound, "\(name) forwards no web port — doz ports add \(name) PORT") }
        let row: PortForwardRow
        if let port {
            guard let r = web.first(where: { $0.port == port }) else {
                throw HostError(.notFound, "\(name) forwards no web port \(port) (\(web.map { String($0.port) }.joined(separator: ", ")))")
            }
            row = r
        } else {
            row = web[0]
        }
        guard a.phase == "running" else { throw HostError(.invalidPhase, "\(name) is \(a.phase) — its ports listen while it runs (\(PortsText.wakeHint(a)))") }
        guard let s = row.url, let url = URL(string: s) else {
            throw HostError(.unavailable, "\(row.title) (port \(row.port)) is not listening: \(row.why ?? row.state)")
        }
        if g.json { Out.json(row); if !print { _ = BrowserBridge.open(url, callback: nil) }; return }
        if print { Out.stdout(s + "\n"); return }
        guard BrowserBridge.open(url, callback: nil) else { throw HostError(.failed, "this Mac could not open \(s)") }
        Out.stdout("opened \(row.title) — \(s)\n")
        if row.auth == "token" { Out.stdout("it asks for a token: \(row.tokenHint ?? "see its output")\n") }
    }
}
