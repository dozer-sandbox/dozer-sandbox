import ArgumentParser
import Foundation
import DozerKit
import DozerHost

/// What `create` and `up` take to make a sandbox.
struct CreateArguments: ParsableArguments {
    @Option(name: .long, help: "lab (Alpine + bash), claude-code, pi, codex, a base × agent image (python-claude-code, go-codex, go, …), or a template (doz image ls). Shorthand for --agent/--base.")
    var image: String?

    @Option(name: .long, help: "The agent — claude-code, pi, codex (OpenAI Codex) or none (a shell only). Default claude-code.")
    var agent: String?

    @Option(name: .long, help: "A recommended base (doz base ls): node, python, go, rust, java, ruby, dotnet, debian, ubuntu, alpine. Default node.")
    var base: String?

    @Option(name: .long, help: "Your own Dockerfile as the base, built with Apple's container build (installed on demand; its RUN steps run OUTSIDE Dozer's network policy). The workspace defaults to its folder.")
    var dockerfile: String?

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

    @Flag(inversion: .prefixedNo, help: "The agent (claude-code, pi) has passwordless sudo inside the sandbox (default: the setting sandbox.agent_sudo, on). Applied at every boot and session start.")
    var agentSudo: Bool?

    @Option(name: .long, help: "write or off: a copy in this sandbox (OSC 52) reaches the Mac clipboard, with a notice every time (default: the setting sandbox.clipboard, write).")
    var clipboard: String?

    @Option(name: .long, help: "on or off: xdg-open in this sandbox opens http(s) URLs in the Mac's browser, a sign-in's localhost callback forwarded (default: the setting sandbox.browser_bridge, on).")
    var browserBridge: String?

    @Option(name: .long, help: "on or off: xdg-open PATH in this sandbox opens a document from its /workspace in the Mac's default app (or an app in bridges.open_apps), or a folder in the Finder, with a notice every time (default: the setting sandbox.open_files, on).")
    var openFiles: String?

    @Option(name: .long, help: "off, read or push: git and gh in this sandbox are signed in as you on GitHub (your Mac's gh login, or doz key set NAME --github) — read-only, or also push and make changes. The token never enters the sandbox. Proxied sandboxes only; the permissions \"Use GitHub as you\" and \"Push to GitHub\" (default: off).")
    var github: String?

    @Option(name: .long, help: "on or off: forward this Mac's SSH agent into the sandbox (your keys stay on the Mac; github.com:22 only). Proxied sandboxes only (default: the setting sandbox.ssh_agent, off).")
    var sshAgent: String?

    @Flag(inversion: .prefixedNo, help: "Run this sandbox's sessions inside tmux (its windows, panes, copy mode; Ctrl-b) — default: the setting sessions.tmux, off.")
    var tmux: Bool?

    @Option(name: .long, help: "lock or hide: what a .dozignore in the workspace folder does to the paths it lists — lock (listed, every access refused) or hide (not there). Not a security boundary (default: the setting workspace.ignore_mode, lock).")
    var ignoreMode: String?
    @Option(name: .long, help: "on or off: /workspace through Dozer's live view of the folder, so programs working there keep their folder across a wake from hibernation or a host restart (on, the default: the setting workspace.view), or shared directly — a little faster, but such a wake cuts them off.")
    var workspaceView: String?

    @Flag(name: .long, help: "When the image is out of date (an older doz's recipe, or a newer agent release): rebuild it first (~2 min, needs network; existing sandboxes are not affected).")
    var rebuild = false

    // `--allow -error-reports`: the value may start with a dash.
    @Option(name: .long, parsing: .unconditionalSingleValue, help: "What the agent may do, on top of the default (defaults.permissions): permissions (doz net permissions), -PERMISSION to remove, site:HOST, or standard/locked/open. Comma-separated or repeated.")
    var allow: [String] = []

    @Flag(name: .long, help: "When the image is out of date: use it as it is (the default off a terminal; said as a warning).")
    var useCurrent = false

    // EXPERIMENTAL (604): an audio sandbox.
    @Flag(name: .long, help: ArgumentHelp("EXPERIMENTAL: give the sandbox the Mac's microphone and speakers (a sound device and its own kernel; doz-sound inside to record and play). macOS asks about the microphone for the app that started doz.",
                                          visibility: BuildFlavor.current.isPublic ? .hidden : .default))
    var audio = false

    /// 596 (B10): the image `--agent`/`--base`/`--dockerfile` name (nil: none of them given).
    /// `--image claude-code` stays the shorthand for `--agent claude-code --base node`.
    func chosenImage() throws -> String? {
        guard agent != nil || base != nil || dockerfile != nil else { return nil }
        guard image == nil else { throw ValidationError("--image, or --agent/--base/--dockerfile — not both") }
        let a: AgentKind
        switch agent ?? "claude-code" {
        case "claude-code", "claude": a = .claudeCode
        case "pi": a = .pi
        case "codex": a = .codex
        case "none", "shell": a = .none
        case let x: throw ValidationError("--agent: claude-code, pi, codex or none — not \(x)")
        }
        if dockerfile != nil {
            guard base == nil else { throw ValidationError("--base or --dockerfile — not both") }
            // The host names the image by the Dockerfile's own base id; this carries the agent.
            return ImageChoice(base: a == .none ? "alpine" : "node", agent: a).name
        }
        let b = base ?? "node"
        guard BaseCatalogue.base(b) != nil else {
            throw ValidationError("--base: \(BaseCatalogue.ids.joined(separator: ", ")) (doz base ls) — or --dockerfile PATH — not \(b)")
        }
        return ImageChoice(base: b, agent: a).name
    }

    /// 596: `--dockerfile` as an absolute path (a relative one is this command's working folder's).
    var absoluteDockerfile: String? {
        guard let d = dockerfile else { return nil }
        let expanded = (d as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL.path }
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path
    }

    func options(defaultImage: String? = nil) throws -> CreateOptions {
        guard let img = try chosenImage() ?? image ?? defaultImage else {
            throw ValidationError("--image (or --agent/--base/--dockerfile) is required: lab, claude-code, pi, codex, a base × agent image or a template")
        }
        var mem: UInt64?
        if let m = memory {
            guard let v = DozerImages.parseMemory(m) else { throw ValidationError("--memory: \(m) is not a size (2G, 512M, 2048)") }
            mem = v
        }
        if let c = cpus, c < 1 { throw ValidationError("--cpus must be at least 1") }
        if isolated && workspace != nil { throw ValidationError("--isolated or --workspace, not both") }
        if rebuild && useCurrent { throw ValidationError("--rebuild or --use-current, not both") }
        var o = CreateOptions(image: img, cpus: cpus, memoryMiB: mem, workspace: absoluteWorkspace, network: network, subnet: subnet, account: account)
        o.isolated = isolated ? true : nil
        o.agentSudo = agentSudo
        if audio, BuildFlavor.current.isPublic { throw ValidationError(BuildFlavor.audioMissing) }   // 611
        o.audio = audio ? true : nil
        // 597 (P6): --allow web,site:api.example.com,-error-reports
        var words = allow.flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }.filter { !$0.isEmpty }
        // 599d: --github read|push|off is the same as allowing (or not) its two permissions.
        words += try Self.githubWords(github, flag: "--github")
        if !words.isEmpty { o.allow = words }
        if let df = absoluteDockerfile {
            guard FileManager.default.fileExists(atPath: df) else { throw ValidationError("--dockerfile: no file at \(df)") }
            o.dockerfile = df
            // B6: the Dockerfile's folder is the build context — and the workspace, unless one is given.
            if o.workspace == nil, !isolated { o.workspace = (df as NSString).deletingLastPathComponent }
        }
        try applyPrompt(to: &o)
        o.settings = try sandboxSettings()
        return o
    }

    /// 599d: `off` / `read` / `push` → permission words for `--allow` (and `github:` in doz_project.yaml).
    static func githubWords(_ v: String?, flag: String) throws -> [String] {
        guard let w = DozerProject.gitHubWords(v) else { throw ValidationError("\(flag): off, read or push") }
        return w
    }

    /// 599: the per-sandbox settings given as flags (nil: none).
    func sandboxSettings() throws -> [String: TOMLValue]? {
        var s: [String: TOMLValue] = [:]
        func take(_ key: String, _ text: String?, _ flag: String) throws {
            guard let text, let d = DozerSettings.definition(key) else { return }
            do { s[key] = try d.parse(text) } catch let e as SettingsError { throw ValidationError("\(flag): \(e.message)") }
        }
        try take(SettingKey.clipboard, clipboard, "--clipboard")
        try take(SettingKey.browserBridge, browserBridge, "--browser-bridge")
        try take(SettingKey.openFiles, openFiles, "--open-files")
        try take(SettingKey.sshAgent, sshAgent, "--ssh-agent")
        if let tmux { s[SettingKey.tmux] = .bool(tmux) }
        try take(SettingKey.ignoreMode, ignoreMode, "--ignore-mode")
        try take(SettingKey.workspaceView, workspaceView, "--workspace-view")
        return s.isEmpty ? nil : s
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
        image != nil || cpus != nil || memory != nil || workspace != nil || network != nil || subnet != nil || account != nil || agentPrompt != nil || isolated || agentSudo != nil
            || agent != nil || base != nil || dockerfile != nil || !allow.isEmpty
            || clipboard != nil || browserBridge != nil || openFiles != nil || tmux != nil || github != nil || sshAgent != nil
            || ignoreMode != nil || workspaceView != nil
    }
}

/// 594 W28 (owner ruling: "i dont think we should rebuild images without the user agreeing (and
/// understanding the consequences) … better to warn"): before a create, an out-of-date image is said —
/// and the user chooses: `--rebuild` (the image is rebuilt first; existing sandboxes are not affected)
/// or `--use-current`; on a terminal the question is asked (default: use the current image); off one,
/// or with --json, the current image is used with a warning. Returns the notice when the current
/// (out-of-date) image is used.
func chooseImage(_ o: inout CreateOptions, rebuild: Bool, useCurrent: Bool, _ g: GlobalOptions) async throws -> String? {
    // 596: any base × agent image (a Dockerfile's is rebuilt when its Dockerfile changes — said on its page).
    guard DozerImages.builtIn.contains(o.image) || ImageChoice.parse(o.image) != nil, o.dockerfile == nil else { return nil }
    if rebuild { o.rebuild = true; return nil }
    let rows = (try? decode(try await query(HostRequest(.imageList), g), [ImageRow].self, g)) ?? []
    guard let row = rows.first(where: { $0.name == o.image }), row.baked, let standing = row.standing else { return nil }
    let missing = row.olderRecipe.map { $0 == ["its recipe changed"] ? "" : " (missing: \($0.joined(separator: ", ")))" } ?? ""
    let asker = Asker(yes: false, json: g.json)
    if !useCurrent, asker.interactive {
        Out.stderr("[doz] the \(o.image) image is out of date: \(standing)\n")
        let yes = asker.yesNo("Rebuild it first (~2 min, needs network; existing sandboxes are NOT affected)? No: use the current image\(missing)",
                                default: false)
        if yes { o.rebuild = true; return nil }
    }
    let notice = "used the current \(o.image) image\(missing): \(standing)"
    if !g.json && !g.quiet { Out.stderr("[doz] warning: \(notice)\n") }
    return notice
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
    @Flag(name: .long, help: "Start it too.") var start = false
    @Flag(name: .long, help: "Prepare its image now (download and bake it once, with progress), so its first start does not wait; the sandbox stays off. Ctrl-C stops watching: the preparation goes on.")
    var prepare = false

    func run() async throws {
        var r = HostRequest(.create, name: name)
        var o = try create.options()
        if prepare { o.prepare = true }
        try preflightAgentAccount(&o, g)          // 594: pi needs an API-key account — before anything is made
        // 596 (B7, B9): a Dockerfile base — where it is built, and Apple's tool ready before a start builds it.
        if o.dockerfile != nil { try await builderPreflight(g, required: start) }
        let notice = try await chooseImage(&o, rebuild: create.rebuild, useCurrent: create.useCurrent, g)
        r.create = o
        let v = prepare
            ? try followingCall(r, g, detached: "\(name) is created; its image's preparation goes on in the host — doz onboard --status watches it, doz onboard --cancel stops it")
            : try call(r, g)
        var info = try decode(v, SandboxInfo.self, g)
        info.imageNotice = notice
        if !g.json {
            Out.stdout("created \(info.name): \(info.image), \(info.cpus) CPUs, \(Out.mib(info.memoryMiB)), network \(info.network)"
                       + (info.workspace.map { ", /workspace = \($0)" } ?? ", isolated") + "\n")
        }
        if !g.json, let p = info.imagePreparation {
            Out.stdout(p == "prepared" ? "prepared its image (\(info.image)) — its first start boots at once\n"
                                       : "its image (\(info.image)) is ready — nothing to prepare\n")
        }
        noteWorkspace(info, isolatedAsked: create.isolated, g)
        await noteWorkspaceRules(name, g)                                       // 599g
        if start {
            let s = try decode(try call(HostRequest(.start, name: name), g), LifecycleResult.self, g)
            if let i = s.info { info = i }
            if !g.json { Out.stdout("started \(name) in \(String(format: "%.1f", s.milliseconds / 1000)) s\n") }
        }
        if g.json { Out.json(info) }
    }
}

/// 599c (owner: "a "Quick Add" sandbox that picks defaults for workspace name etc and opens it
/// immediately"): the shortest way in — every default, created, started and attached. Each flag
/// changes just that one thing; `doz create`/`doz up` take everything else.
struct New: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The quickest way in: a new sandbox with every default — created, started and attached.",
        discussion: """
        The image is the setting defaults.image; the name is the image's (claude-sandbox, then claude-sandbox-2, …); its \
        workspace is <defaults.projects_dir>/<name>, made now; the account and permissions are the defaults. It prints what \
        it chose. Each flag changes just that one thing — doz create and doz up take every other option.
        """)

    @OptionGroup var g: GlobalOptions
    @Option(name: .long, help: "The image (default: the setting defaults.image).") var image: String?
    @Option(name: .long, help: "The name (default: the image's — claude-sandbox, claude-sandbox-2, …).") var name: String?
    @Flag(name: .long, help: "Share no folder: /workspace is private to the sandbox.") var isolated = false
    @Flag(name: [.short, .customLong("detach")], help: "Create and start it, but do not attach.") var detach = false

    func run() async throws {
        let rows = try decode(try await query(HostRequest(.ls), g), [SandboxInfo].self, g)
        let plan: QuickAddPlan
        do {
            plan = try QuickAdd.plan(image: image, name: name, isolated: isolated, taken: Set(rows.map(\.name)), settings: .load())
        } catch let e as HostError {
            throw fail(e, g)
        }
        if !g.json { Out.stdout(plan.line() + "\n") }
        var o = CreateOptions(image: plan.image, workspace: plan.workspace)
        o.isolated = isolated ? true : nil
        do {
            try preflightAgentAccount(&o, g)      // pi needs an API-key account: offered on a terminal, else the next step
        } catch {
            if !g.json {
                Out.stderr("[doz] doz new uses the store's default account: doz account default NAME makes one the default "
                           + "— or doz create NAME --image \(plan.image) --account NAME --start\n")
            }
            throw error
        }
        let notice = try await chooseImage(&o, rebuild: false, useCurrent: false, g)
        var r = HostRequest(.create, name: plan.name)
        r.create = o
        let info = try decode(try call(r, g), SandboxInfo.self, g)
        noteWorkspace(info, isolatedAsked: isolated, g)
        let started = try decode(try call(HostRequest(.start, name: plan.name), g), LifecycleResult.self, g)
        var open = HostRequest(.openSession, name: plan.name)
        let size = terminalSize()
        open.cols = size.cols
        open.rows = size.rows
        let opened = try decode(try call(open, g), SessionOpened.self, g)
        if !g.json, let n = opened.notice { Out.stderr("[doz] \(n)\n") }
        if g.json {
            var out: [String: JSONValue] = ["name": .string(plan.name), "image": .string(plan.image), "phase": .string(started.phase),
                                            "session": .string(opened.session), "milliseconds": .number(started.milliseconds)]
            out["workspace"] = info.workspace.map(JSONValue.string) ?? .null
            if let notice { out["imageNotice"] = .string(notice) }
            Out.json(out)
            return
        }
        if detach {
            Out.stdout("\(plan.name) is \(Out.phaseLabel(started.phase)); session \(opened.session)\(opened.created ? " started" : "") — "
                       + "\(reattachCommand(sandbox: plan.name, session: opened.session, defaultSession: opened.defaultSession))\n")
            return
        }
        let key = try parseDetachKey("ctrl-]")
        if !g.quiet {
            Out.stderr(String(format: "[doz] %@ started in %.0f ms — attaching to %@", plan.name, started.milliseconds, opened.session)
                       + (key.map { " (\(describeKey($0)): the menu · twice: detach)" } ?? "") + "\n")
        }
        AttachClient.run(store: g.dozerStore, sandbox: plan.name, session: opened.session, wake: true, detachKey: key, quiet: g.quiet)
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
    func run() async throws {
        await noteWorkspaceRules(name, g)                                       // 599g
        _ = try lifecycle(.start, name, g)
    }
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
        try await requireSandbox(name, g)   // 594 W26: never a question about a sandbox that is not there
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
        try await requireSandbox(name, g)
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
        try await requireSandbox(name, g)
        try confirm("Remove \(name) and everything it has on disk (disks, restore points, state)?", yes: yes, g)
        _ = try lifecycle(.rm, name, g)
    }
}

struct Up: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create the sandbox if it is missing, start or wake it, then attach (vagrant up / compose up).",
        discussion: """
        Attaches to the image's session (claude, pi, or a bash shell), opening it when it is not running. Ctrl-] opens a menu \
        (detach · next · prev · sessions), Ctrl-] twice detaches; the session keeps running. With no NAME, in a folder with doz_project.yaml (doz init): that project's sandbox — \
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
            let found: URL?
            do { found = try DozerProject.find(in: folder) } catch { throw fail(HostError(.invalid, error.localizedDescription), g) }
            guard let f = found else {
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
                if let i = create.image { o.image = i; o.dockerfile = nil }
                // 596: --agent/--base/--dockerfile win over the file's image too.
                if let i = try create.chosenImage() { o.image = i; o.dockerfile = create.absoluteDockerfile }
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
                if let s = create.agentSudo { o.agentSudo = s }
                let allowWords = create.allow.flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }.filter { !$0.isEmpty }
                    + (try CreateArguments.githubWords(create.github, flag: "--github"))   // 599d
                if !allowWords.isEmpty { o.allow = (o.allow ?? []) + allowWords }       // 597 (the file's github: first, the flags after)
                if let s = try create.sandboxSettings() { o.settings = (o.settings ?? [:]).merging(s) { _, flag in flag } }
                try create.applyPrompt(to: &o)
                // 594: doz_project.yaml's image and account are checked like any create.
                try preflightAgentAccount(&o, g)
                if create.rebuild && create.useCurrent { throw ValidationError("--rebuild or --use-current, not both") }
                _ = try await chooseImage(&o, rebuild: create.rebuild, useCurrent: create.useCurrent, g)
                r.create = o
            } else {
                var o = try create.options(defaultImage: DozerSettings.load().string(SettingKey.defaultImage) ?? "lab")
                try preflightAgentAccount(&o, g)
                _ = try await chooseImage(&o, rebuild: create.rebuild, useCurrent: create.useCurrent, g)
                r.create = o
            }
            // 596 (B7, B9): `up` starts it at once — a Dockerfile base needs Apple's tool ready first.
            if r.create?.dockerfile != nil { try await builderPreflight(g, required: true) }
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
        await noteWorkspaceRules(name, g)                                       // 599g
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
                if !g.json && !g.quiet && opened.created { Out.stderr("[doz] started session \(s.name)\(opened.tmux == true ? " (in tmux)" : "")\n") }
                if !g.json, let n = opened.notice { Out.stderr("[doz] \(n)\n") }
            }
            open.session = first.name
            open.argv = first.command
        }
        let size = terminalSize()
        open.cols = size.cols
        open.rows = size.rows
        let opened = try decode(try call(open, g), SessionOpened.self, g)
        if !g.json, let n = opened.notice { Out.stderr("[doz] \(n)\n") }
        if g.json || detach {
            if g.json { Out.json(["name": .string(name), "session": .string(opened.session), "phase": .string(started.phase),
                                  "created": .bool(!exists), "sessionCreated": .bool(opened.created),
                                  "milliseconds": .number(started.milliseconds)] as [String: JSONValue]) }
            else { Out.stdout("\(name) is \(Out.phaseLabel(started.phase)); session \(opened.session)\(opened.created ? " started" : "") — \(reattachCommand(sandbox: name, session: opened.session, defaultSession: opened.defaultSession))\n") }
            return
        }
        if !g.quiet {
            let how = started.changed ? String(format: "%@ in %.0f ms", started.phaseBefore == "off" ? "started" : "woke", started.milliseconds) : "running"
            Out.stderr("[doz] \(name) \(how) — attaching to \(opened.session)\(key.map { " (\(describeKey($0)): the menu · twice: detach)" } ?? "")\n")
        }
        AttachClient.run(store: g.dozerStore, sandbox: name, session: opened.session, wake: true, detachKey: key, quiet: g.quiet)
    }

    /// An existing project sandbox: its project's own prompt is kept in step with the file (it applies
    /// from the next session); one made from another folder is said.
    /// 594 W12: each key of doz_project.yaml that differs from the existing sandbox, with when it
    /// applies. cpus, memory and image are the VM's make-up: only a new sandbox gets them. A proxied
    /// network's preset is applied now (live) unless the policy was edited since; nat/none are the VM's
    /// network device (a new sandbox). The account applies from the next session (`doz account use`).
    func projectDifferences(_ project: DozerProject, cfg: SandboxConfig, name: String) throws -> [String] {
        var out: [String] = []
        let remake = "applies only when the sandbox is made — doz rm \(name) && doz up recreates it (this folder, its /workspace, is kept)"
        if let c = project.cpus, c != cfg.spec.cpus { out.append("cpus \(cfg.spec.cpus) → \(c) in \(DozerProject.fileName): \(remake)") }
        if let m = project.memoryMiB, m != cfg.spec.memoryMiB {
            out.append("memory \(Out.mib(cfg.spec.memoryMiB)) → \(Out.mib(m)) in \(DozerProject.fileName): \(remake)")
        }
        if project.image != cfg.image { out.append("image \(cfg.image) → \(project.image) in \(DozerProject.fileName): \(remake)") }
        if let want = project.network, want != cfg.networkName {
            let presets = ["agent", "bake", "locked", "open"]
            if presets.contains(want), cfg.spec.network.policy != nil {
                var q = HostRequest(.netPolicy, name: name)
                let live = try? decode(try call(q, g), NetworkPolicy.self, g)
                if let now = live?.preset, now != want {
                    q.preset = want
                    _ = try call(q, g)
                    out.append("network \(now) → \(want) in \(DozerProject.fileName): applied now (live — the next connection is judged by it)")
                } else if live?.preset == nil {
                    out.append("network: \(DozerProject.fileName) says \(want), but \(name)'s policy was edited — kept; doz net policy \(name) --preset \(want) replaces it")
                }
            } else {
                out.append("network \(cfg.networkName) → \(want) in \(DozerProject.fileName): nat and none are the VM's network device — \(remake)")
            }
        }
        if let a = project.account, a != (cfg.account ?? "none") {
            out.append("account \(cfg.account ?? "none") → \(a) in \(DozerProject.fileName): doz account use \(name) \(a) applies it (from the next session)")
        }
        return out
    }

    func syncProject(_ project: DozerProject, file: URL, name: String) throws {
        guard let cfg = SandboxConfig.read(g.dozerStore.configFile(name)) else { return }
        if let made = cfg.project, made != file.path, !g.quiet {
            Out.stderr("[doz] \(name) was made from \(made), not this folder's \(DozerProject.fileName) — using it anyway\n")
        }
        // 594 W12: what the file says differently from the sandbox, and WHEN that applies — said, and
        // applied where it can be now (a proxied network's preset, live).
        for line in try projectDifferences(project, cfg: cfg, name: name) where !g.quiet && !g.json {
            Out.stderr("[doz] \(line)\n")
        }
        // 594 W23: agent_sudo changed in the file → the sandbox's own choice follows it.
        if cfg.agentSudo != project.agentSudo {
            var s = HostRequest(.agentPrompt, name: name)
            if let v = project.agentSudo { s.agentSudo = v } else { s.clearAgentSudo = true }
            _ = try call(s, g)
            if !g.quiet && !g.json {
                Out.stderr("[doz] agent_sudo \(project.agentSudo.map { $0 ? "true" : "false" } ?? "removed (the setting sandbox.agent_sudo decides)") in \(DozerProject.fileName) — it applies from the next session\n")
            }
        }
        // 599: a per-sandbox setting changed in the file → the sandbox's own value follows it.
        for k in DozerProject.settingKeys where cfg.settings?[k.setting] != project.settings[k.setting] {
            var s = HostRequest(.sandboxSettings, name: name)
            s.setting = k.setting
            if let v = project.settings[k.setting] { s.settingValue = v } else { s.clearSetting = true }
            _ = try call(s, g)
            if !g.quiet && !g.json {
                let applies = DozerSettings.definition(k.setting)?.applies.note ?? ""
                Out.stderr("[doz] \(k.key) \(project.settings[k.setting].map(\.plain) ?? "removed (the setting \(k.setting) decides)") in \(DozerProject.fileName) — \(applies)\n")
            }
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
