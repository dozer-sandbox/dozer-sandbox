import ArgumentParser
import Foundation
import DozerKit
import DozerHost

/// What `create` and `up` take to make a sandbox.
struct CreateArguments: ParsableArguments {
    @Option(name: .long, help: "lab (Alpine + bash), claude-code, pi, or a custom image (doz image ls).")
    var image: String?

    @Option(name: .long, help: "Virtual CPUs (default 2).")
    var cpus: Int?

    @Option(name: .long, help: "Guest RAM: 2G, 512M, 2048 (MiB). Default 1G for lab, 2G for an agent image.")
    var memory: String?

    @Option(name: .long, help: "A folder of this Mac shared at /workspace (made when it does not exist).")
    var workspace: String?

    @Flag(name: .long, help: "Share no folder: /workspace is private to the sandbox (the default without --workspace, said by a note; this says it on purpose).")
    var isolated = false

    @Option(name: .long, help: "agent, bake, locked, open (proxied: no network interface, every connection through the Mac's policy and log), nat or none. Default: agent for an agent image, bake for lab.")
    var network: String?

    @Option(name: .long, help: "vmnet subnet for --network nat (default: a free one, picked for you).")
    var subnet: String?

    @Option(name: .long, help: "The Anthropic account a proxied sandbox uses (doz account ls), or none. Default: follow the store's default account.")
    var account: String?

    @Option(name: .long, help: "A file whose text is this sandbox's own part of the agent's environment prompt (claude-code, pi); {{variables}} as in agent-prompt.md.")
    var agentPrompt: String?

    @Option(name: .long, help: "With --agent-prompt: append (default) to the template, or replace it.")
    var agentPromptMode: String?

    func options(defaultImage: String? = nil) throws -> CreateOptions {
        guard let img = image ?? defaultImage else { throw ValidationError("--image is required: lab, claude-code, pi or a custom image") }
        var mem: UInt64?
        if let m = memory {
            guard let v = DozerImages.parseMemory(m) else { throw ValidationError("--memory: \(m) is not a size (2G, 512M, 2048)") }
            mem = v
        }
        if let c = cpus, c < 1 { throw ValidationError("--cpus must be at least 1") }
        if isolated && workspace != nil { throw ValidationError("--isolated or --workspace, not both") }
        var o = CreateOptions(image: img, cpus: cpus, memoryMiB: mem, workspace: absoluteWorkspace, network: network, subnet: subnet, account: account)
        o.isolated = isolated ? true : nil
        try applyPrompt(to: &o)
        return o
    }

    /// 594: a relative --workspace is this command's working folder's (the host takes absolute paths only).
    var absoluteWorkspace: String? {
        guard let w = workspace else { return nil }
        let expanded = (w as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path
    }

    /// 594: `--agent-prompt FILE` (≤ 16 KiB of UTF-8) and its mode.
    func applyPrompt(to o: inout CreateOptions) throws {
        if let mode = agentPromptMode {
            guard ["append", "replace"].contains(mode) else { throw ValidationError("--agent-prompt-mode: append or replace") }
            guard agentPrompt != nil else { throw ValidationError("--agent-prompt-mode goes with --agent-prompt FILE") }
            o.agentPromptMode = mode
        }
        if let f = agentPrompt {
            let path = (f as NSString).expandingTildeInPath
            guard let d = FileManager.default.contents(atPath: path) else { throw ValidationError("--agent-prompt: \(f) cannot be read") }
            guard d.count <= SandboxConfig.maximumAgentPromptBytes, let text = String(data: d, encoding: .utf8) else {
                throw ValidationError("--agent-prompt: at most 16 KiB of UTF-8 text")
            }
            o.agentPrompt = text
        }
    }

    var givenAny: Bool {
        image != nil || cpus != nil || memory != nil || workspace != nil || network != nil || subnet != nil || account != nil || agentPrompt != nil || isolated
    }
}

/// 594: a workspace made by this create is said; an isolated sandbox is said — unless asked for with
/// --isolated (D17; owner: one word, "isolated").
func noteWorkspace(_ info: SandboxInfo, isolatedAsked: Bool, _ g: GlobalOptions) {
    guard !g.json, !g.quiet else { return }
    if info.workspaceCreated == true, let w = info.workspace {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        Out.stderr("[doz] created \(w.hasPrefix(home + "/") ? "~" + w.dropFirst(home.count) : Substring(w))\n")
    }
    if info.workspace == nil, !isolatedAsked {
        Out.stderr("[doz] \(Workspace.isolatedNote) — --workspace DIR shares a folder (--isolated says it on purpose)\n")
    }
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
                       + (info.workspace.map { ", /workspace = \($0)" } ?? ", isolated") + "\n")
        }
        noteWorkspace(info, isolatedAsked: create.isolated, g)
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

struct Hibernate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "hibernate",
        abstract: "Hibernate: snapshot to disk and stop the VM — RAM returned; sessions come back on wake.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    func run() async throws { _ = try lifecycle(.hibernate, name, g) }
}

struct Wake: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Wake from sleep or hibernation (~0.3 s), sessions and pids where they were.")
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
        discussion: """
        Attaches to the image's session (claude, pi, or a bash shell), opening it when it is not running. Ctrl-] detaches; \
        the session keeps running. With no NAME, in a folder with doz_project.yaml (doz init): that project's sandbox — \
        the folder is its /workspace, and its sessions start (the first is attached).
        """)

    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox (default: the one doz_project.yaml in this folder names).") var name: String?
    @OptionGroup var create: CreateArguments
    @Option(name: .long, help: "The session to attach to (default: the image's own).") var session: String?
    @Flag(name: [.short, .customLong("detach")], help: "Do not attach.") var detach = false
    @Option(name: .long, help: "The key that detaches: ctrl-] (default), ctrl-<letter>, or none.") var detachKey = "ctrl-]"
    @Argument(parsing: .postTerminator, help: "A program for a NEW session instead of the default one.") var command: [String] = []

    func run() async throws {
        let key = try parseDetachKey(detachKey)
        // 594 (D9): no name — the project in this folder.
        var project: DozerProject?
        var projectFile: URL?
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        if name == nil {
            guard let f = DozerProject.find(in: folder) else {
                throw fail(HostError(.invalid, "which sandbox? doz up NAME — or run it in a folder with \(DozerProject.fileName) (doz init makes one)"), g)
            }
            do { project = try DozerProject.load(f) } catch { throw fail(HostError(.invalid, error.localizedDescription), g) }
            projectFile = f
        }
        let name = self.name ?? project!.name
        // Create when missing.
        let probe = try rawCall(HostRequest(.inspect, name: name), g)
        if probe.ok != true, let e = probe.error, e.code != .notFound { throw fail(e, g) }
        let exists = probe.ok == true
        if !exists {
            var r = HostRequest(.create, name: name)
            if let project, let projectFile {
                var o = project.createOptions(folder: folder, file: projectFile)
                // Options given here win over the file's.
                if let i = create.image { o.image = i }
                if let c = create.cpus { o.cpus = c }
                if let m = create.memory {
                    guard let v = DozerImages.parseMemory(m) else { throw ValidationError("--memory: \(m) is not a size (2G, 512M, 2048)") }
                    o.memoryMiB = v
                }
                if let n = create.network { o.network = n }
                if let a = create.account { o.account = a }
                if let s = create.subnet { o.subnet = s }
                if create.isolated && create.workspace != nil { throw ValidationError("--isolated or --workspace, not both") }
                if let w = create.absoluteWorkspace { o.workspace = w }
                if create.isolated { o.workspace = nil; o.isolated = true }
                try create.applyPrompt(to: &o)
                r.create = o
            } else {
                r.create = try create.options(defaultImage: DozerSettings.load().string(SettingKey.defaultImage) ?? "lab")
            }
            let info = try decode(try call(r, g), SandboxInfo.self, g)
            if !g.json && !g.quiet {
                Out.stderr("[doz] created \(name)" + (projectFile.map { " from \($0.path)" } ?? "") + (info.workspace.map { " — /workspace = \($0)" } ?? "") + "\n")
            }
            noteWorkspace(info, isolatedAsked: create.isolated, g)
        } else {
            if create.givenAny && !g.quiet {
                Out.stderr("[doz] \(name) exists — its image and settings are kept (the options apply only to a new sandbox)\n")
            }
            if let project, let projectFile { try syncProject(project, file: projectFile, name: name) }
        }
        let started = try decode(try call(HostRequest(.start, name: name), g), LifecycleResult.self, g)
        var open = HostRequest(.openSession, name: name)
        open.session = session
        open.argv = command.isEmpty ? nil : command
        // 594: a project's sessions — every one but the first starts detached; the first is attached.
        if let project, session == nil, command.isEmpty, let first = project.sessions.first {
            for s in project.sessions.dropFirst() {
                var o = HostRequest(.openSession, name: name)
                o.session = s.name
                o.argv = s.command
                let opened = try decode(try call(o, g), SessionOpened.self, g)
                if !g.json && !g.quiet && opened.created { Out.stderr("[doz] started session \(s.name)\n") }
            }
            open.session = first.name
            open.argv = first.command
        }
        let size = terminalSize()
        open.cols = size.cols
        open.rows = size.rows
        let opened = try decode(try call(open, g), SessionOpened.self, g)
        if g.json || detach {
            if g.json { Out.json(["name": .string(name), "session": .string(opened.session), "phase": .string(started.phase),
                                  "created": .bool(!exists), "sessionCreated": .bool(opened.created),
                                  "milliseconds": .number(started.milliseconds)] as [String: JSONValue]) }
            else { Out.stdout("\(name) is \(Out.phaseLabel(started.phase)); session \(opened.session)\(opened.created ? " started" : "") — doz attach \(name) \(opened.session)\n") }
            return
        }
        if !g.quiet {
            let how = started.changed ? String(format: "%@ in %.0f ms", started.phaseBefore == "off" ? "started" : "woke", started.milliseconds) : "running"
            Out.stderr("[doz] \(name) \(how) — attaching to \(opened.session)\(key.map { " (\(describeKey($0)) detaches)" } ?? "")\n")
        }
        AttachClient.run(store: g.dozerStore, sandbox: name, session: opened.session, wake: true, detachKey: key, quiet: g.quiet)
    }

    /// An existing project sandbox: its project's own prompt is kept in step with the file (it applies
    /// from the next session); one made from another folder is said.
    func syncProject(_ project: DozerProject, file: URL, name: String) throws {
        guard let cfg = SandboxConfig.read(g.dozerStore.configFile(name)) else { return }
        if let made = cfg.project, made != file.path, !g.quiet {
            Out.stderr("[doz] \(name) was made from \(made), not this folder's \(DozerProject.fileName) — using it anyway\n")
        }
        let mode = project.agentPrompt == nil ? nil : (project.agentPromptMode ?? "append")
        guard cfg.agentPrompt != project.agentPrompt || (cfg.agentPrompt != nil && (cfg.agentPromptMode ?? "append") != mode) else { return }
        var r = HostRequest(.agentPrompt, name: name)
        if let p = project.agentPrompt {
            r.prompt = p
            r.promptMode = mode
        } else {
            r.clearPrompt = true
        }
        _ = try call(r, g)
        if !g.quiet && !g.json { Out.stderr("[doz] agent_prompt changed in \(DozerProject.fileName) — it applies from the next session\n") }
    }
}
