import ArgumentParser
import Foundation
import SnoozeContainerKit
import SnoozeHost

/// What `create` and `up` take to make a sandbox.
struct CreateArguments: ParsableArguments {
    @Option(name: .long, help: "lab (Alpine + bash), claude-code, pi, or a custom image (snooze image ls).")
    var image: String?

    @Option(name: .long, help: "Virtual CPUs (default 2).")
    var cpus: Int?

    @Option(name: .long, help: "Guest RAM: 2G, 512M, 2048 (MiB). Default 1G for lab, 2G for an agent image.")
    var memory: String?

    @Option(name: .long, help: "A folder of this Mac shared at /workspace.")
    var workspace: String?

    @Option(name: .long, help: "agent, bake, locked, open (proxied: no network interface, every connection through the Mac's policy and log), nat or none. Default: agent for an agent image, bake for lab.")
    var network: String?

    @Option(name: .long, help: "vmnet subnet for --network nat (default: a free one, picked for you).")
    var subnet: String?

    func options(defaultImage: String? = nil) throws -> CreateOptions {
        guard let img = image ?? defaultImage else { throw ValidationError("--image is required: lab, claude-code, pi or a custom image") }
        var mem: UInt64?
        if let m = memory {
            guard let v = SnoozeImages.parseMemory(m) else { throw ValidationError("--memory: \(m) is not a size (2G, 512M, 2048)") }
            mem = v
        }
        if let c = cpus, c < 1 { throw ValidationError("--cpus must be at least 1") }
        return CreateOptions(image: img, cpus: cpus, memoryMiB: mem, workspace: workspace, network: network, subnet: subnet)
    }

    var givenAny: Bool { image != nil || cpus != nil || memory != nil || workspace != nil || network != nil || subnet != nil }
}

struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a sandbox (it stays off until start or up).")

    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox's name: 1–40 characters of a-z 0-9 -.") var name: String
    @OptionGroup var create: CreateArguments

    func run() async throws {
        var r = HostRequest(.create, name: name)
        r.create = try create.options()
        let v = try call(r, g)
        let info = try decode(v, SandboxInfo.self, g)
        if g.json { Out.json(info) } else {
            Out.stdout("created \(info.name): \(info.image), \(info.cpus) CPUs, \(Out.mib(info.memoryMiB)), network \(info.network)"
                       + (info.workspace.map { ", /workspace = \($0)" } ?? "") + "\n")
        }
    }
}

/// One lifecycle operation, printed.
func lifecycle(_ op: HostOp, _ name: String, _ g: GlobalOptions) throws -> LifecycleResult {
    let v = try call(HostRequest(op, name: name), g)
    let r = try decode(v, LifecycleResult.self, g)
    if g.json { Out.json(r) } else {
        let what = Out.phaseLabel(r.phase)
        if !r.changed {
            Out.stdout("\(r.name) is already \(what)\n")
        } else if op == .rm {
            Out.stdout(String(format: "removed %@ (%.0f ms)\n", r.name, r.milliseconds))
        } else {
            var line = String(format: "%@: %@ → %@ in %.0f ms", r.name, Out.phaseLabel(r.phaseBefore), what, r.milliseconds)
            if let i = r.info { line += " · RAM held \(Out.mib(i.ramHeldMiB))" }
            Out.stdout(line + "\n")
        }
    }
    return r
}

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Boot a sandbox — or wake it, if it is asleep; resume it if paused.", aliases: ["cold-boot"])
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    func run() async throws { _ = try lifecycle(.start, name, g) }
}

struct Pause: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pause: guest CPU to 0 in ~1 ms, RAM kept.", aliases: ["suspend"])
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    func run() async throws { _ = try lifecycle(.pause, name, g) }
}

struct Resume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resume after pause (from sleep it wakes).")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    func run() async throws { _ = try lifecycle(.resume, name, g) }
}

struct SleepCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sleep",
        abstract: "Sleep: pause + snapshot to disk; RAM kept, and it survives a host crash.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    func run() async throws { _ = try lifecycle(.sleep, name, g) }
}

struct DeepSleep: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "deep-sleep",
        abstract: "Deep sleep: snapshot to disk and stop the VM — RAM returned; sessions come back on wake.", aliases: ["hibernate"])
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    func run() async throws { _ = try lifecycle(.deepSleep, name, g) }
}

struct Wake: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Wake from sleep or deep sleep (~0.3 s), sessions and pids where they were.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    func run() async throws { _ = try lifecycle(.wake, name, g) }
}

struct Shutdown: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Shut down: a cold stop that keeps the disk; running programs end.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false
    func run() async throws {
        try confirm("Shut down \(name)? Its running programs end (the disk is kept).", yes: yes, g)
        _ = try lifecycle(.shutdown, name, g)
    }
}

struct Reset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Reset to the image: shut down and discard the disk (restore points and the state disk stay).")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false
    func run() async throws {
        try confirm("Reset \(name) to its image? Everything installed or written on its disk is discarded.", yes: yes, g)
        _ = try lifecycle(.reset, name, g)
    }
}

struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove a sandbox and everything it has on disk.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false
    func run() async throws {
        try confirm("Remove \(name) and everything it has on disk (disks, restore points, state)?", yes: yes, g)
        _ = try lifecycle(.rm, name, g)
    }
}

struct Up: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create the sandbox if it is missing, start or wake it, then attach (vagrant up / compose up).",
        discussion: "Attaches to the image's session (claude, pi, or a bash shell), opening it when it is not running. Ctrl-] detaches; the session keeps running.")

    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @OptionGroup var create: CreateArguments
    @Option(name: .long, help: "The session to attach to (default: the image's own).") var session: String?
    @Flag(name: [.short, .customLong("detach")], help: "Do not attach.") var detach = false
    @Option(name: .long, help: "The key that detaches: ctrl-] (default), ctrl-<letter>, or none.") var detachKey = "ctrl-]"
    @Argument(parsing: .postTerminator, help: "A program for a NEW session instead of the default one.") var command: [String] = []

    func run() async throws {
        let key = try parseDetachKey(detachKey)
        // Create when missing.
        let probe = try rawCall(HostRequest(.inspect, name: name), g)
        if probe.ok != true, let e = probe.error, e.code != .notFound { throw fail(e, g) }
        let exists = probe.ok == true
        if !exists {
            var r = HostRequest(.create, name: name)
            r.create = try create.options(defaultImage: "lab")
            _ = try call(r, g)
            if !g.json && !g.quiet { Out.stderr("[snooze] created \(name)\n") }
        } else if create.givenAny && !g.quiet {
            Out.stderr("[snooze] \(name) exists — its image and settings are kept (the options apply only to a new sandbox)\n")
        }
        let started = try decode(try call(HostRequest(.start, name: name), g), LifecycleResult.self, g)
        var open = HostRequest(.openSession, name: name)
        open.session = session
        open.argv = command.isEmpty ? nil : command
        let size = terminalSize()
        open.cols = size.cols
        open.rows = size.rows
        let opened = try decode(try call(open, g), SessionOpened.self, g)
        if g.json || detach {
            if g.json { Out.json(["name": .string(name), "session": .string(opened.session), "phase": .string(started.phase),
                                  "created": .bool(!exists), "sessionCreated": .bool(opened.created),
                                  "milliseconds": .number(started.milliseconds)] as [String: JSONValue]) }
            else { Out.stdout("\(name) is \(Out.phaseLabel(started.phase)); session \(opened.session)\(opened.created ? " started" : "") — snooze attach \(name) \(opened.session)\n") }
            return
        }
        if !g.quiet {
            let how = started.changed ? String(format: "%@ in %.0f ms", started.phaseBefore == "off" ? "started" : "woke", started.milliseconds) : "running"
            Out.stderr("[snooze] \(name) \(how) — attaching to \(opened.session)\(key.map { " (\(describeKey($0)) detaches)" } ?? "")\n")
        }
        AttachClient.run(store: g.snoozeStore, sandbox: name, session: opened.session, wake: true, detachKey: key, quiet: g.quiet)
    }
}
