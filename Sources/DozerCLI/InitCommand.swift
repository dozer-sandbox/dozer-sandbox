import ArgumentParser
import Foundation
import DozerKit
import DozerHost

/// 594 (D9) — `doz init`: make a folder a project (write `doz_project.yaml`). 599f (owner: "a new wizard
/// process for creating a purposeful sandbox that steps the user through all the choices, capturing the
/// config in a doz_project.yml in the project / working dir"): on a terminal it walks the dashboard's New
/// Sandbox wizard's steps (`ProjectWizard.steps`) — each question pre-filled from the settings, or from the
/// folder's existing project file — shows the file, and writes it (an existing one only after its diff
/// and a yes). `--yes` (or `--json`, or no terminal) asks nothing and takes every default.
struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Make a folder a Dozer Sandbox project: write doz_project.yaml there (onboarding this Mac first if it never was). Then: doz up.",
        discussion: """
        The folder is shared at /workspace. On a terminal it walks the steps of the dashboard's New sandbox wizard — folder and \
        name, agent and base, account, access (GitHub, SSH agent), workspace rules (.dozignore, .dozreadonly), permissions and \
        network, resources, bridges, session — each \
        with its default (Enter keeps it), then shows the file before writing it. A folder that has a project file already starts \
        from it, and is replaced only after you have seen the difference. --yes, --json or no terminal ask nothing.
        """)

    @OptionGroup var g: GlobalOptions
    @Argument(help: "The folder (default: the current one; made when missing).") var directory: String?
    @Option(name: .long, help: "The sandbox's name (default: from the folder's name).") var name: String?
    @Option(name: .long, help: "claude-code, pi, codex, lab, a base × agent image or a template (default: the settings' defaults.image).") var image: String?
    @Option(name: .long, help: "Virtual CPUs.") var cpus: Int?
    @Option(name: .long, help: "Guest RAM: 2G, 512M, 2048 (MiB).") var memory: String?
    @Option(name: .long, help: "agent, bake, locked, open, nat or none.") var network: String?
    // `--permissions -error-reports`: the value may start with a dash.
    @Option(name: .long, parsing: .unconditional, help: "What the agent may do: standard, locked, open, or changes like +web,-error-reports.") var permissions: String?
    @Option(name: .long, help: "default, none or an account name.") var account: String?
    @Option(name: .long, help: "off, read or push: git and gh signed in as you on GitHub.") var github: String?
    @Option(name: .long, help: "on or off: forward this Mac's SSH agent.") var sshAgent: String?
    @Option(name: .long, help: "write or off: a copy in the sandbox reaches the Mac clipboard.") var clipboard: String?
    @Option(name: .long, help: "on or off: xdg-open URLs open in the Mac's browser.") var browserBridge: String?
    @Option(name: .long, help: "on or off: xdg-open FILE opens a workspace document on the Mac.") var openFiles: String?
    @Flag(inversion: .prefixedNo, help: "Run its sessions inside tmux.") var tmux: Bool?
    @Option(name: .long, help: "lock or hide: what a .dozignore in the folder does to the paths it lists — lock: listed but unreadable; hide: not there.") var ignoreMode: String?
    @Flag(inversion: .prefixedNo, help: "The agent's passwordless sudo.") var agentSudo: Bool?
    @Flag(name: [.short, .long], help: "Accept every default; ask nothing.") var yes = false
    @Flag(name: .long, help: "Replace an existing project file without asking.") var force = false

    func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let folder = (directory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, relativeTo: cwd) } ?? cwd).standardizedFileURL
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: folder.path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw fail(HostError(.invalid, "\(folder.path) is not a folder"), g) }
        } else {
            do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
                throw fail(HostError(.failed, "could not make \(folder.path): \(error.localizedDescription)"), g)
            }
            if !g.json { Out.stdout("made \(folder.path)\n") }
        }
        let asker = Asker(yes: yes, json: g.json)
        // 599f: an existing project file (either spelling — both is an error) pre-fills the questions.
        let existingURL: URL?
        do { existingURL = try DozerProject.find(in: folder) } catch { throw fail(HostError(.invalid, error.localizedDescription), g) }
        var existing: DozerProject?
        var existingText: String?
        if let u = existingURL {
            guard force || asker.interactive else {
                throw fail(HostError(.exists, "\(u.path) exists — doz up there uses it (--force rewrites it; on a terminal doz init starts from it)"), g)
            }
            existingText = try? String(contentsOf: u, encoding: .utf8)
            existing = try? DozerProject.load(u)
            if existing == nil, !force { throw fail(HostError(.invalid, "\(u.path) does not read — fix it, or --force replaces it"), g) }
        }
        let file = existingURL ?? folder.appendingPathComponent(DozerProject.fileName)
        // D1: a project needs an onboarded Mac.
        var onboarded: OnboardReport?
        if OnboardingRecord.read(g.dozerStore) == nil {
            if !g.json { Out.stdout("this Mac has not been onboarded yet — onboarding first\n\n") }
            onboarded = try await OnboardingFlow(g: g, asker: asker, imagesFlag: nil, accountFlag: nil, talk: !g.json).run()
            if !g.json { Out.stdout("\n") }
        }
        var p = try ask(folder: folder, existing: existing, asker: asker)
        if AgentImages.credentials(p.image) != nil || ImageChoice.parse(p.image)?.agent == .pi {
            let net = p.effectiveNetwork(settings: .load())
            if net != "nat", net != "none" {
                // 594: the agent's credential prerequisite — checked (and on a terminal met) now, not at `doz up`.
                let a = try preflightAgentAccount(image: p.image, network: net, account: p.account, g)
                if a != p.account { p.account = a }
            }
        }
        let text = p.render()
        do { _ = try DozerProject.parse(text) } catch { throw fail(HostError(.invalid, error.localizedDescription), g) }   // our own file must read back
        if asker.interactive {
            Out.stdout("\n— \(ProjectWizard.steps.last!.title): \(file.path)\n\n" + text + "\n")
            if let old = existingText, old != text {
                Out.stdout("Compared with the file there now (- there now, + to be written):\n")
                for l in DozerProject.lineDiff(old: old, new: text) where !l.hasPrefix("  ") { Out.stdout("  " + l + "\n") }
                guard asker.yesNo("Replace \(file.lastPathComponent) with this?", default: false) else {
                    Out.stdout("nothing written\n")
                    return
                }
            } else if existingText == nil, !asker.yesNo("Write \(file.lastPathComponent)?", default: true) {
                Out.stdout("nothing written\n")
                return
            }
        }
        if existingText != text {
            do { try Data(text.utf8).write(to: file, options: .atomic) } catch {
                throw fail(HostError(.failed, "could not write \(file.path): \(error.localizedDescription)"), g)
            }
        }
        // 594 W28: the image the project names is out of date — said now; `doz up` asks (or --rebuild).
        let rows = (try? decode(try await query(HostRequest(.imageList), g), [ImageRow].self, g)) ?? []
        let standing = rows.first(where: { $0.name == p.image && $0.baked })?.standing
        if g.json {
            var j: [String: JSONValue] = ["project": .string(file.path), "name": .string(p.name), "image": .string(p.image), "workspace": .string(folder.path),
                                          "onboarded": .bool(onboarded != nil || OnboardingRecord.read(g.dozerStore) != nil)]
            if let s = standing { j["imageNotice"] = .string(s) }
            Out.json(j)
        } else {
            Out.stdout("wrote \(file.path) — sandbox \(p.name), image \(p.image), /workspace = \(folder.path)\n")
            if let s = standing { Out.stdout("note: the \(p.image) image is out of date: \(s)\n  doz up asks whether to rebuild it first (doz up --rebuild, or --use-current)\n") }
            let cwdPath = cwd.standardizedFileURL.path
            Out.stdout("next: \(folder.path == cwdPath ? "" : "cd \(shellQuoted(folder.path)) && ")doz up\n")
        }
    }

    /// The steps, in `ProjectWizard.steps`' order: a flag answers its question; on a terminal the rest are
    /// asked (Enter keeps the default — the existing file's value, else the setting's); else defaults.
    func ask(folder: URL, existing: DozerProject?, asker: Asker) throws -> DozerProject {
        let settings = DozerSettings.load()
        var explicit = Set<String>()
        func step(_ id: String) {
            guard asker.interactive, let i = ProjectWizard.steps.firstIndex(where: { $0.id == id }) else { return }
            Out.stdout("\n— Step \(i + 1) of \(ProjectWizard.steps.count): \(ProjectWizard.steps[i].title)\n")
        }
        func invalid(_ m: String) -> ExitCode { fail(HostError(.invalid, m), g) }

        // 1. Folder and name.
        step("folder")
        if asker.interactive { Out.stdout("  folder: \(folder.path) — shared at /workspace\n") }
        let sandbox = name ?? asker.text("Sandbox name", default: existing?.name ?? DozerProject.suggestedName(for: folder)) {
            WebNameRule.isSandboxName($0) ? nil : "1–40 of a-z 0-9 - (not starting with -)"
        }
        guard WebNameRule.isSandboxName(sandbox) else { throw invalid("--name: 1–40 of a-z 0-9 -") }

        // 2. Agent and base.
        step("image")
        let img: String
        var p: DozerProject
        if let image {
            img = image
            p = existing ?? DozerProject(name: sandbox, image: img)
            p.agent = nil; p.base = nil; p.dockerfile = nil
            p.name = sandbox
            p.image = img
        } else if let e = existing, asker.interactive == false || e.agent != nil || e.base != nil || e.dockerfile != nil {
            p = e
            p.name = sandbox
            img = e.image
        } else {
            let def = existing?.image ?? settings.string(SettingKey.defaultImage) ?? "claude-code"
            img = asker.text("Image — claude-code, pi, codex, lab, a base × agent image (python-claude-code, go-codex, …; doz base ls) or a template", default: def) {
                $0.range(of: "^(custom:)?[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil ? nil : "an image name"
            }
            p = existing ?? DozerProject(name: sandbox, image: img)
            if existing != nil { p.agent = nil; p.base = nil; p.dockerfile = nil }
            p.name = sandbox
            p.image = img
        }
        if let e = existing {
            // What the existing file set stays set (unless answered differently below).
            if e.cpus != nil { explicit.insert("cpus") }
            if e.memoryMiB != nil { explicit.insert("memory") }
            if e.network != nil { explicit.insert("network") }
            if e.permissions != nil { explicit.insert("permissions") }
            if e.account != nil { explicit.insert("account") }
            if e.github != nil { explicit.insert("github") }
            if e.agentSudo != nil { explicit.insert("agent_sudo") }
            for k in DozerProject.settingKeys where e.settings[k.setting] != nil { explicit.insert(k.key) }
        }
        let section = DozerSettings.imageSection(imageSpecName: img == "lab" ? nil : img)

        // 3. Account (the agent's credential prerequisite is checked after the questions).
        step("account")
        if AgentImages.credentials(img) != nil || ImageChoice.parse(img)?.agent != nil && ImageChoice.parse(img)?.agent != AgentKind.none {
            if let a = account { p.account = a; explicit.insert("account") }
            else if asker.interactive {
                let a = asker.text("Account — default (the store's), none, or an account name (doz account ls)", default: p.account ?? "default") {
                    $0 == "default" || $0 == "none" || $0.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil ? nil : "default, none or an account name"
                }
                p.account = a
            }
        } else if asker.interactive {
            Out.stdout("  \(img) runs no agent: no account\n")
        }

        // 4. Access: GitHub, the SSH agent — `doz onboard`'s Access step (599e), for this sandbox: the same
        // questions and flags (--github, --ssh-agent), each choice confirmed live on a terminal (Skip / Turn it off /
        // Check again — never blocking). Where the token comes from is the Mac's (github.credentials, doz access set).
        step("access")
        if let gh = github, !["off", "read", "push"].contains(gh) { throw invalid("--github: off, read or push") }
        if let s = sshAgent, !["on", "off"].contains(s) { throw invalid("--ssh-agent: on or off") }
        var access = AccessStep(g: g, asker: asker, talk: asker.interactive, githubFlag: github, sourceFlag: nil, sshFlag: sshAgent)
        access.checkClaude = false
        access.subject = "this sandbox"
        access.askSource = false
        if p.github != nil || p.settings[SettingKey.sshAgent] != nil {
            access.start = AccessChoices(github: p.github ?? settings.string(SettingKey.defaultGithub) ?? "off",
                                         githubSource: settings.string(SettingKey.githubCredentials).flatMap { $0 == "off" ? "gh" : $0 } ?? "gh",
                                         ssh: p.settings[SettingKey.sshAgent]?.plain ?? settings.string(SettingKey.sshAgent) ?? "off")
        }
        var chosen = access.choose()
        if asker.interactive, chosen.github != "off" || chosen.ssh == "on" {
            chosen = try access.confirm(chosen).0
        }
        p.github = chosen.github
        p.settings[SettingKey.sshAgent] = .string(chosen.ssh)
        if github != nil { explicit.insert("github") }
        if sshAgent != nil { explicit.insert("ssh_agent") }

        // 5. Workspace rules (599g, owner A2): what .dozignore / .dozreadonly do, what this folder has, and this
        // sandbox's mode (the flag, else asked on a terminal; Enter keeps the file's, else the setting's).
        step("rules")
        if let m = ignoreMode, !["lock", "hide"].contains(m) { throw invalid("--ignore-mode: lock or hide") }
        let rulesCurrent = (p.settings[SettingKey.ignoreMode] ?? settings.resolve(SettingKey.ignoreMode).value).plain
        if let m = RulesStep(asker: asker, talk: asker.interactive, flag: ignoreMode, current: rulesCurrent, folder: folder).run() {
            p.settings[SettingKey.ignoreMode] = .string(m)
            if ignoreMode != nil { explicit.insert("ignore_mode") }
        }

        // 6. Permissions and network.
        step("permissions")
        if let n = network {
            guard ["agent", "bake", "locked", "open", "nat", "none"].contains(n) else { throw invalid("--network: agent, bake, locked, open, nat or none") }
            p.network = n
            explicit.insert("network")
        } else if asker.interactive {
            let nets = ["agent", "bake", "locked", "open", "nat", "none"]
            let current = p.effectiveNetwork(settings: settings)
            let i = asker.choose("Network", ["agent — proxied: what the agent may do is its permissions", "bake — proxied: package registries only",
                                             "locked — proxied: its AI model only", "open — proxied: every host, still logged",
                                             "nat — a real network interface, unfiltered", "none — no network"],
                                 preferred: nets.firstIndex(of: current) ?? 0)
            p.network = nets[i]
        }
        if DozerProject.permissionNetworks.contains(p.effectiveNetwork(settings: settings)) {
            if let w = permissions {
                guard let words = SettingType.permissionWords(w) else { throw invalid("--permissions: standard, locked, open, or changes like +web,-error-reports") }
                p.permissions = words
                explicit.insert("permissions")
            } else if asker.interactive {
                let def = (p.permissions ?? SettingType.permissionWords(settings.string(SettingKey.permissions) ?? "standard") ?? ["standard"]).joined(separator: ",")
                let w = asker.text("What the agent may do — standard, locked, open, or changes like +web,-error-reports (doz net permissions)", default: def) {
                    SettingType.permissionWords($0) == nil ? "standard, locked, open, or permission ids with + or -" : nil
                }
                p.permissions = SettingType.permissionWords(w)
            }
        } else if permissions != nil {
            throw invalid("--permissions: for a network with permissions (agent, locked, open)")
        }

        // 7. Resources.
        step("resources")
        if let c = cpus { p.cpus = c; explicit.insert("cpus") }
        else if asker.interactive {
            let c = asker.text("Virtual CPUs", default: String(p.cpus ?? settings.int(SettingKey.cpus))) { Int($0).map { (1...64).contains($0) } == true ? nil : "1–64" }
            p.cpus = Int(c)
        }
        let memDefault = p.memoryMiB ?? UInt64(settings.int(SettingKey.memory(section)))
        if let m = memory {
            guard let v = DozerImages.parseMemory(m) else { throw invalid("--memory: \(m) is not a size (2G, 512M, 2048)") }
            p.memoryMiB = v
            explicit.insert("memory")
        } else if asker.interactive {
            let m = asker.text("Memory (2G, 512M, 2048 MiB)", default: memDefault % 1024 == 0 ? "\(memDefault / 1024)G" : "\(memDefault)M") {
                DozerImages.parseMemory($0).map { (256...262_144).contains($0) } == true ? nil : "a size like 2G or 512M (256 MiB – 256 GiB)"
            }
            p.memoryMiB = DozerImages.parseMemory(m)
        }
        if asker.interactive { Out.stdout("  disk: the image's own (it is not set per sandbox)\n") }

        // 8. Bridges.
        step("bridges")
        try setting(&p, SettingKey.clipboard, "clipboard", flag: clipboard, explicit: &explicit, asker: asker, settings: settings,
                    question: "A copy in the sandbox reaches the Mac clipboard", options: ["write", "off"])
        try setting(&p, SettingKey.browserBridge, "browser_bridge", flag: browserBridge, explicit: &explicit, asker: asker, settings: settings,
                    question: "Links opened in the sandbox open in the Mac's browser", options: ["on", "off"])
        try setting(&p, SettingKey.openFiles, "open_files", flag: openFiles, explicit: &explicit, asker: asker, settings: settings,
                    question: "Workspace documents opened in the sandbox open on the Mac", options: ["on", "off"])

        // 9. Session.
        step("session")
        try setting(&p, SettingKey.tmux, "tmux", flag: tmux.map { $0 ? "true" : "false" }, explicit: &explicit, asker: asker, settings: settings,
                    question: "Run its sessions inside tmux", options: ["false", "true"])
        if let s = agentSudo { p.agentSudo = s; explicit.insert("agent_sudo") }
        else if asker.interactive {
            p.agentSudo = asker.yesNo("The agent has passwordless sudo", default: p.agentSudo ?? settings.bool(SettingKey.agentSudo))
        }

        step("review")
        p.dropDefaults(settings: settings, explicit: explicit)
        if let why = p.problem(effectiveNetwork: p.effectiveNetwork(settings: settings)) { throw invalid(why) }
        return p
    }

    /// One per-sandbox setting: the flag, else the question (the default: the file's value, else the setting's).
    func setting(_ p: inout DozerProject, _ key: String, _ projectKey: String, flag: String?, explicit: inout Set<String>, asker: Asker,
                 settings: DozerSettings, question: String, options: [String]) throws {
        guard let d = DozerSettings.definition(key) else { return }
        if let f = flag {
            do { p.settings[key] = try d.parse(f) } catch let e as SettingsError { throw fail(HostError(.invalid, "--\(projectKey.replacingOccurrences(of: "_", with: "-")): \(e.message)"), g) }
            explicit.insert(projectKey)
            return
        }
        guard asker.interactive else { return }
        let current = (p.settings[key] ?? settings.resolve(key).value).plain
        let i = asker.choose(question, options, preferred: options.firstIndex(of: current) ?? 0)
        p.settings[key] = try? d.parse(options[i])
    }
}
