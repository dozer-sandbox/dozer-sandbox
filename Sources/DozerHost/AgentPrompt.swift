import Foundation
import DozerKit

// 594 (D15, D16) — the agent's environment prompt. Asked "what is the host path of /workspace",
// Claude in a sandbox had to read /proc/self/mountinfo to find out; it is told nothing about where
// it runs. Now, at EVERY session start, the host renders from the sandbox's CURRENT facts:
//
//   D15a  a short FACTS block — appended to the agent's system prompt: Claude Code's launcher
//         passes `/run/dozer/agent-prompt.md` with `--append-system-prompt`; pi's session gets
//         `--append-system-prompt /run/dozer/agent-prompt.md` (pi reads a file named there);
//   D15b  the `dozer` SKILL — `~/.claude/skills/dozer/SKILL.md` (pi: `~/.pi/agent/skills/dozer/`),
//         rewritten every start. Dozer owns only that directory; the agent's own memory files
//         (CLAUDE.md, AGENTS.md, APPEND_SYSTEM.md) are never touched.
//
// Three layers (D16): the built-in template < the user's template (`agent-prompt.md` beside
// doz.toml; HTML comments are dropped, and a file that is only comments is "not set") < the
// sandbox's own (`doz create --agent-prompt FILE`, `doz_project.yaml`), appended or replacing.
// `agent.prompt = false` turns both parts off. Variables are `{{name}}` from a CLOSED list; an
// unknown one is an error at render time (the session does not start, and `doz inspect` says why)
// — never silently blank.

/// What `doz inspect` (and the UI's sandbox page) show of a sandbox's environment prompt.
public struct AgentPromptReport: Codable, Equatable, Sendable {
    /// The settings' `agent.prompt`.
    public var enabled: Bool
    /// `claude-code` or `pi` (the agent that gets it).
    public var agent: String
    /// The facts block as the next session gets it (nil: off, or it does not render).
    public var text: String?
    /// Why it does not render (an unknown variable, and where).
    public var error: String?
    /// Which layers made it: `built-in`, `user template <path>`, `sandbox (append|replace)`.
    public var layers: [String]
    /// The `dozer` skill's SKILL.md as the next session gets it.
    public var skill: String?
    /// Where each part goes in the guest.
    public var promptPath: String
    public var skillPath: String
}

public struct AgentPromptError: Error, Equatable, Sendable, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

public enum AgentPrompt {
    /// Where the facts block is written in the guest (on the root disk; rewritten every session start).
    public static let guestPromptPath = "/run/dozer/agent-prompt.md"
    /// The user's template, beside doz.toml.
    public static let userTemplateName = "agent-prompt.md"

    /// The CLOSED list of variables, with what each says.
    public static let variables: [(name: String, summary: String)] = [
        ("sandbox.name", "the sandbox's name"),
        ("sandbox.image", "its image (claude-code, pi, python-claude-code, …, or a template's name)"),
        ("sandbox.base", "its base: a recommended one (Python — python:3.13-bookworm) or the user's Dockerfile"),
        ("sandbox.cpus", "its virtual CPUs"),
        ("sandbox.memory", "its memory, e.g. 2 GiB"),
        ("workspace.shared", "yes or no"),
        ("workspace.host_path", "the Mac folder shared at /workspace, or (none)"),
        ("workspace.guest_path", "/workspace"),
        ("workspace.description", "a sentence: where /workspace comes from, or that it is not shared"),
        ("network.mode", "agent, bake, locked, open, custom (proxied), nat or none"),
        ("network.allowed_hosts", "the hosts the policy allows (proxied), comma-separated"),
        ("network.description", "a sentence: how the sandbox reaches the network and what to do when refused"),
        ("network.permissions", "what the agent may and may not do, in plain words, and the permission to ask for"),
        ("account.name", "the Anthropic account the proxy injects, or none"),
        ("credentials.description", "a sentence: how credentials reach the agent"),
        ("sandbox.sudo", "yes or no: the agent has passwordless sudo (sandbox.agent_sudo)"),
        ("sandbox.timezone", "the VM's time zone, e.g. Australia/Sydney (the Mac's, by default)"),
        ("sudo.description", "a sentence: sudo, and that the network policy still applies to root"),
        ("clipboard.description", "a sentence: a copy reaches the Mac clipboard with a notice (or the bridge is off); the clipboard is never readable"),
        ("browser.description", "a sentence: xdg-open opens http(s) URLs in the Mac's browser and a sign-in's localhost callback is forwarded (or the bridge is off)"),
        ("files.description", "a sentence: xdg-open FILE opens a /workspace document on the user's Mac (which types, a named app, the notice) — or why not (isolated, off)"),
        ("mac.hostname", "the Mac's name"),
        ("dozer.version", "the doz that rendered it"),
    ]

    /// The built-in facts block (D15a): only what changes per sandbox and what the agent needs
    /// before it knows to ask. ~10 lines.
    public static let builtInTemplate = """
    # Where you are running: a Dozer Sandbox
    - You are in `{{sandbox.name}}`, a Dozer Sandbox: a Linux virtual machine (not a container) on the user's Mac ({{mac.hostname}}), run by Apple's Virtualization framework — image {{sandbox.image}} (base: {{sandbox.base}}), {{sandbox.cpus}} CPUs, {{sandbox.memory}}.
    - {{workspace.description}}
    - Network: {{network.description}}
    - Credentials: {{credentials.description}}
    - System: {{sudo.description}}
    - Time zone: {{sandbox.timezone}} (the Mac's — `date` shows the user's local time).
    - Clipboard: {{clipboard.description}}
    - Browser: {{browser.description}}
    - Files on the Mac: {{files.description}}
    - The user may pause, sleep or hibernate this VM between your turns; your processes, files and sessions survive it.
    - More — what persists (root disk, state disk, restore points), the network policy, what you cannot do from inside — is in the `dozer` skill.
    """

    /// The `dozer` skill (D15b): loaded by the agent when a question is about this machine.
    public static let skillTemplate = """
    ---
    name: dozer
    description: The Dozer Sandbox this agent runs in (sandbox {{sandbox.name}}) — what persists (root disk, state disk, restore points), the /workspace share with the user's Mac, the network policy and how the user changes it, injected credentials, sleep and hibernation, and what cannot be done from inside. Use it for any question about this machine, where files live, the network, logins or keys.
    ---

    # Dozer Sandbox — the machine you run in

    You run in **{{sandbox.name}}**, a Dozer Sandbox: a small Linux virtual machine on the user's Mac ({{mac.hostname}}), made and run by the user's `doz` tool (Dozer Sandbox {{dozer.version}}) on Apple's Virtualization framework. It is a real VM with its own kernel — not a container and not a cloud machine. Image: {{sandbox.image}} (base: {{sandbox.base}}); {{sandbox.cpus}} CPUs, {{sandbox.memory}}.

    ## Your files and the user's Mac

    - {{workspace.description}}
    - Everything else is on this VM's own disks, invisible from the Mac's Finder.

    ## What persists

    - **The root disk** (`/`, packages you install, files outside /workspace) survives stops and restarts. The user can *reset* it to the image, which discards everything installed or written on it.
    - **The state disk** holds the agent's own state (`~/.claude`, `~/.pi/agent`: logins, history, settings) and survives even a reset.
    - **Restore points** are instant copies of the disks the user takes (`doz point take {{sandbox.name}}`) and can go back to. You cannot take one yourself.

    ## The network

    {{network.description}}

    Allowed hosts: {{network.allowed_hosts}}.

    If a connection is refused, tell the user what you were doing, which host, and the permission that would allow it (by its name — "Install software: Python (PyPI)", "Browse the web", …); they decide (`doz net allow {{sandbox.name}} PERMISSION` or `site:HOST`, or the switches in `doz ui`). Do not try to get around it (other hosts, IP addresses, tunnels) — it is the user's boundary.

    ## Credentials

    {{credentials.description}}

    ## Installing software (root)

    Sudo: {{sandbox.sudo}} — {{sudo.description}}

    Root inside this VM does not widen what you can reach: the VM is the boundary, every connection still goes through the user's network policy, and no credential is in the VM to find. Packages you install live on the root disk (kept across restarts, discarded by a reset).

    ## The user's Mac: clipboard, browser and files

    {{clipboard.description}}

    {{browser.description}}

    {{files.description}}

    ## Sleep and hibernation

    Between your turns the user may pause this VM (CPU stopped, memory kept), put it to sleep (a snapshot on disk as well) or hibernate it (memory freed, the state on disk). When it wakes, your processes, open files and terminal sessions continue where they were; the clock is set again. A long gap in timestamps is normal.

    ## What you cannot do from inside

    You cannot change the network policy, take or restore a restore point, add a key or account, share another Mac folder, or change the VM's CPUs or memory — the user does these with `doz` on the Mac. Ask them when you need one, and say exactly what.
    """

    /// The file `doz onboard` writes as the user's template when there is none: every line inside
    /// an HTML comment, so it changes nothing until the user writes a template of their own.
    public static var userTemplateStarter: String {
        var s = """
        <!--
        Dozer Sandbox — your own environment prompt (agent-prompt.md)

        Everything inside an HTML comment (like this one) is ignored, so this file changes nothing
        yet: the built-in template (below, for reference) is used. Write your own text OUTSIDE a comment and
        it replaces the built-in template for every sandbox; a sandbox can still append to it or
        replace it (doz create --agent-prompt FILE, or agent_prompt in doz_project.yaml).
        It reaches Claude Code with --append-system-prompt (pi: the same) at every session start.
        Turn it off: doz config set agent.prompt false. See it for a sandbox: doz inspect NAME --prompt.

        Variables ({{name}}; an unknown one is an error, never silently blank):

        """
        for v in variables { s += "  {{\(v.name)}}  — \(v.summary)\n" }
        s += "\nThe built-in template:\n\n"
        s += builtInTemplate
        s += "\n-->\n"
        return s
    }

    /// This Mac's name, without `.local` (gethostname: no DNS lookup, unlike ProcessInfo.hostName).
    public static func macHostname() -> String {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return "" }
        let name = String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.hasSuffix(".local") ? String(name.dropLast(6)) : name
    }

    // MARK: facts

    /// The values of every variable for a sandbox, from its current record.
    public static func values(name: String, image: String, cpus: Int, memoryMiB: UInt64, workspace: String?,
                              network: NetworkMode, account: String?, version: String,
                              hostname: String = macHostname(), credentialProblem: String? = nil, agentSudo: Bool = true,
                              timeZone: String? = nil, sudoMissingFromImage: String? = nil,
                              base: String? = nil, apk: Bool = false, clipboard: Bool = true,
                              browser: Bool = true, openFiles: Bool = true, openApps: [String] = []) -> [String: String] {
        var v: [String: String] = [:]
        // 599b: workspace files opened on the Mac — said only as it is for THIS sandbox.
        let types = "html, md, pdf, images (png, jpg, gif, webp, svg), txt, log, csv, tsv, json, yaml, xml, toml"
        let apps = openApps.isEmpty
            ? "Only the file's default app is used (the user has allowed no other: bridges.open_apps)."
            : "`doz-open --app NAME FILE` (or `open -a NAME FILE`) opens it in one of the apps the user allowed: \(openApps.joined(separator: ", "))."
        v["files.description"] = workspace == nil
            ? "this sandbox is isolated (nothing on the Mac is shared), so no file of yours can be opened on the Mac — show the user the file's content instead."
            : !openFiles
            ? "opening workspace files on the user's Mac is off for this sandbox; tell the user the file's path under their shared folder instead (they can turn it on: `doz config set --sandbox \(name) sandbox.open_files on`)."
            : "`xdg-open FILE` (also `open FILE`) on a document under /workspace opens it on the user's Mac in its default app (an html page in their browser, markdown in their editor), and the user sees a notice every time. Documents only — \(types); never a folder, app, script, installer or executable file, and only files inside /workspace (a link that leads out is refused). \(apps) At most 3 files in 10 seconds; open a file only when the user would want to see it."
        // 599 (594.B2): the browser bridge.
        v["browser.description"] = browser
            ? "this VM has no browser, but `xdg-open URL` (also $BROWSER, `open`) opens an http or https URL in the user's Mac browser, and the user sees a notice. A sign-in that redirects to this VM's localhost (e.g. Claude Code's /login) completes: that port is forwarded from the Mac for up to 10 minutes. `http://localhost:PORT` of a server you run here does NOT open on the Mac — tell the user the address instead."
            : "this VM has no browser and its browser bridge is off: xdg-open does not reach the user's Mac. Print URLs for the user to open; a sign-in that redirects to this VM's localhost cannot complete — they can turn the bridge on (`doz config set --sandbox \(name) sandbox.browser_bridge on`)."
        // 599 (594.B1): the clipboard bridge — and its risk, said to the agent as to the user.
        v["clipboard.description"] = clipboard
            ? "when you copy (OSC 52 — e.g. Claude Code's copy command, or tmux/vim yanks), the text is put on the user's Mac clipboard and the user sees a notice (\"\(name) copied N chars\") every time. Copy only what the user asked for. You can never read the Mac clipboard: ask the user to paste instead."
            : "the clipboard bridge is off for this sandbox: a copy (OSC 52) does not reach the user's Mac, and you cannot read its clipboard. Show text for the user to select instead; they can turn it on (`doz config set --sandbox \(name) sandbox.clipboard write`)."
        // 594 W10: the VM follows the Mac's time zone (or the setting's).
        v["sandbox.timezone"] = timeZone ?? "UTC"
        // 596: the base the image was made from.
        v["sandbox.base"] = base ?? "Node.js (node:22-bookworm)"
        // 594 W23: the agent's passwordless sudo, and what it does not change.
        v["sandbox.sudo"] = agentSudo ? "yes" : "no"
        let install = apk ? "`sudo apk add PACKAGE`; the package index is in the image — `sudo apk update` refreshes it"
            : "`sudo apt-get install -y PACKAGE`; the package lists are in the image — `sudo apt-get update` refreshes them"
        v["sudo.description"] = agentSudo
            ? "you have passwordless sudo in this sandbox (\(install)). The network policy and the credential rules still apply to root, and the user can undo system changes with `doz reset \(name)` or a restore point."
            : "no sudo: you run as an unprivileged user and cannot install system packages. If you need one, ask the user — they can turn sudo on for this sandbox (`agent_sudo: true` in doz_project.yaml, or `doz config set sandbox.agent_sudo true`); it applies from the next session."
        // 594 W28: on, but this sandbox's system disk came from an older image that has no sudo.
        if let image = sudoMissingFromImage {
            v["sudo.description"] = "no sudo: this sandbox's system disk was made from an older \(image) image that has no sudo. If you need to install a system package, ask the user to rebuild the image (`doz image bake \(image)`) and reset this sandbox (`doz reset \(name)` — it keeps your own state and /workspace)."
        }
        v["sandbox.name"] = name
        v["sandbox.image"] = image.hasPrefix("custom:") ? String(image.dropFirst(7)) + " (a template)" : image
        v["sandbox.cpus"] = String(cpus)
        v["sandbox.memory"] = memoryMiB % 1024 == 0 ? "\(memoryMiB / 1024) GiB" : "\(memoryMiB) MiB"
        v["workspace.guest_path"] = DozerImages.workspaceGuestPath
        v["workspace.shared"] = workspace == nil ? "no" : "yes"
        v["workspace.host_path"] = workspace ?? "(none)"
        v["workspace.description"] = workspace.map {
            "/workspace is the user's Mac folder \($0), shared live: what you write there is on the Mac at once, and the other way round."
        } ?? "This sandbox is isolated (no folder is shared with the Mac): /workspace is a directory on this VM's own disk, and files there exist only inside this VM."
        v["network.mode"] = DozerImages.networkName(network)
        switch network {
        case .proxied(let p):
            // 597 (P7): what the agent may do, in plain words — and the permission to ask for.
            v["network.permissions"] = PermissionPolicy.facts(p, sandbox: name)
            let allowed = p.effectiveRules.filter { $0.action == .allow }.map(\.host)
            var unique: [String] = []
            for h in allowed where !unique.contains(h) { unique.append(h) }
            let shown = unique.prefix(40).joined(separator: ", ") + (unique.count > 40 ? ", …" : "")
            v["network.allowed_hosts"] = p.effectiveDefault == .allow ? "every host (the web is allowed — still proxied and logged)" : (unique.isEmpty ? "none" : shown)
            v["network.description"] = "this VM has no network interface; every connection goes through the Mac's proxy, which allows what the user permits and logs every connection"
                + (p.effectiveDefault == .allow ? " (the web is allowed). " : " — deny by default. ")
                + v["network.permissions"]!
        case .nat:
            v["network.permissions"] = "You may reach any host (a NAT network: nothing is filtered)."
            v["network.allowed_hosts"] = "every host (not filtered)"
            v["network.description"] = "a NAT network interface (vmnet) on the Mac; outbound connections are not filtered or logged by Dozer."
        case .none:
            v["network.permissions"] = "You may reach nothing (no network)."
            v["network.allowed_hosts"] = "none"
            v["network.description"] = "none — this VM has no network at all."
        }
        v["account.name"] = account ?? "none"
        if network.policy != nil, let problem = credentialProblem {
            // 594: only a credential this agent can use is "added for you".
            v["account.name"] = "none usable (\(account ?? "none"))"
            v["credentials.description"] = "no credential you can use is attached (\(problem)), so your requests to the model will fail. "
                + "Do not log in or ask for a key inside the sandbox — tell the user to choose an account in Dozer: `doz account use \(name) ACCOUNT` on the Mac, or the sandbox's page in `doz ui`."
        } else if network.policy != nil, let account {
            v["credentials.description"] = "the Mac's proxy adds the account's credential (\(account)) to your requests to Anthropic on the way out. The key-like values in your environment are placeholders — that is expected; never log in, and never ask the user for a key."
        } else if network.policy != nil {
            v["credentials.description"] = "no account is attached, so the proxy adds none. Do not log in or ask for a key inside the sandbox — the user attaches one with `doz account use \(name) ACCOUNT` on the Mac."
        } else {
            v["credentials.description"] = "this sandbox is not proxied, so no credential is injected; do not ask the user to paste keys into it."
        }
        v["mac.hostname"] = hostname.isEmpty ? "the user's Mac" : hostname
        v["dozer.version"] = version
        return v
    }

    // MARK: rendering

    /// `{{ name }}` → its value. Unknown names are an error, naming the variable and `source`.
    public static func render(_ template: String, _ values: [String: String], source: String) throws -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "}}") else {
                throw AgentPromptError(message: "\(source): a {{ with no }}")
            }
            let name = after[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            guard let v = values[name] else {
                throw AgentPromptError(message: "\(source): {{\(name)}} is not a variable — the variables are \(variables.map(\.name).joined(separator: ", "))")
            }
            out += v
            rest = after[close.upperBound...]
        }
        out += rest
        return out
    }

    /// A template without its HTML comments; nil when nothing else is left.
    public static func stripComments(_ text: String) -> String? {
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "<!--") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "-->") else { rest = ""; break }
            rest = rest[close.upperBound...]
        }
        out += rest
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// The user's template file (beside doz.toml).
    public static func userTemplateURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        DozerSettings.fileURL(environment: environment)?.deletingLastPathComponent().appendingPathComponent(userTemplateName)
    }

    /// The agent a sandbox runs, by its image spec (a template follows the image it was saved from).
    /// 596: whatever its base (`python-claude-code` runs claude-code).
    public static func agent(of spec: SandboxSpec) -> String? {
        switch spec.imageSpec.flatMap({ ImageChoice.parse($0.name) })?.agent {
        case .claudeCode?: "claude-code"
        case .pi?: "pi"
        default: nil
        }
    }

    /// 596: the base as the facts say it — "Python (python:3.13-bookworm)", "the user's Dockerfile
    /// /Users/…/Dockerfile (built with Apple's container build)".
    public static func baseDescription(_ config: SandboxConfig) -> (text: String, apk: Bool) {
        guard let c = config.imageChoice else { return ("Alpine (alpine:3.20)", true) }
        if let b = BaseCatalogue.base(c.base) { return ("\(b.title) (\(b.shortReference))", b.packageManager == .apk) }
        return ("the user's Dockerfile \(config.dockerfile ?? "(unknown path)") (built with Apple's container build; its own package manager)", false)
    }

    /// Where the skill goes in the guest.
    public static func skillDirectory(agent: String, home: String) -> String {
        agent == "pi" ? "\(home)/.pi/agent/skills/dozer" : "\(home)/.claude/skills/dozer"
    }

    /// The prompt and skill a sandbox gets at its next session. nil: its image runs no agent.
    public static func report(config: SandboxConfig, policy: NetworkPolicy?, account: String?, version: String,
                              settings: DozerSettings = .load(), hostname: String = macHostname(),
                              credentialProblem: String? = nil, sudoInstalled: Bool? = nil) -> AgentPromptReport? {
        guard let agent = agent(of: config.spec), let imageSpec = config.spec.imageSpec else { return nil }
        let network: NetworkMode = policy.map { .proxied($0) } ?? config.spec.network
        // 594 W28: sudo only when it is on AND the guest has it (a disk from an older image may not).
        let wanted = HostCore.agentSudo(config, settings: settings)
        // 596: the base the image was made from, and its package manager.
        let base = baseDescription(config)
        let vals = values(name: config.name, image: config.image, cpus: config.spec.cpus, memoryMiB: config.spec.memoryMiB,
                          workspace: config.workspace, network: network, account: account, version: version, hostname: hostname,
                          credentialProblem: credentialProblem, agentSudo: wanted && sudoInstalled != false,
                          timeZone: HostCore.guestTimeZone(settings: settings, environment: settings.environment)?.name,
                          sudoMissingFromImage: wanted && sudoInstalled == false ? config.spec.imageSpec?.name ?? config.image : nil,
                          base: base.text, apk: base.apk,
                          clipboard: HostCore.sandboxValue(config, SettingKey.clipboard, settings: settings) != .string("off"),
                          browser: HostCore.sandboxValue(config, SettingKey.browserBridge, settings: settings) != .string("off"),
                          openFiles: HostCore.sandboxValue(config, SettingKey.openFiles, settings: settings) != .string("off"),
                          openApps: WorkspaceFiles.appNames(settings.string(SettingKey.openApps) ?? "") ?? [])
        var r = AgentPromptReport(enabled: settings.bool(SettingKey.agentPrompt), agent: agent, text: nil, error: nil, layers: [],
                                  skill: nil, promptPath: guestPromptPath,
                                  skillPath: skillDirectory(agent: agent, home: imageSpec.home) + "/SKILL.md")
        guard r.enabled else { return r }
        var template = builtInTemplate
        var source = "the built-in template"
        r.layers = ["built-in"]
        if let url = userTemplateURL(environment: settings.environment),
           let data = FileManager.default.contents(atPath: url.path), data.count <= 64 << 10 {
            if let text = String(data: data, encoding: .utf8).flatMap(stripComments) {
                template = text
                source = url.path
                r.layers = ["user template \(url.path)"]
            }
        }
        do {
            var text = try render(template, vals, source: source)
            if let own = config.agentPrompt.flatMap(stripComments) {
                let mode = config.agentPromptMode ?? "append"
                let mine = try render(own, vals, source: "\(config.name)'s own prompt")
                text = mode == "replace" ? mine : text + "\n\n" + mine
                r.layers.append("sandbox (\(mode))")
            }
            r.text = text
            r.skill = try render(skillTemplate, vals, source: "the dozer skill")
        } catch let e as AgentPromptError {
            r.error = e.message
        } catch {
            r.error = error.localizedDescription
        }
        return r
    }

    /// The guest script (run as root, a utility exec — never a session) that writes both parts, or
    /// removes them when the prompt is off. Contents travel base64-encoded in the script.
    public static func deliveryScript(_ r: AgentPromptReport, user: String) -> String {
        let dir = (r.skillPath as NSString).deletingLastPathComponent
        let skills = (dir as NSString).deletingLastPathComponent
        guard r.enabled, let text = r.text, let skill = r.skill else {
            return "rm -f '\(guestPromptPath)'; rm -rf '\(dir)'"
        }
        let p = Data((text + "\n").utf8).base64EncodedString()
        let s = Data(skill.utf8).base64EncodedString()
        return """
        set -e
        mkdir -p /run/dozer
        printf %s '\(p)' | base64 -d > '\(guestPromptPath).tmp'
        chmod 0644 '\(guestPromptPath).tmp'
        mv -f '\(guestPromptPath).tmp' '\(guestPromptPath)'
        if [ ! -d '\(skills)' ]; then mkdir -p '\(skills)'; chown '\(user):\(user)' '\(skills)'; fi
        mkdir -p '\(dir)'
        printf %s '\(s)' | base64 -d > '\(dir)/SKILL.md'
        chown '\(user):\(user)' '\(dir)' '\(dir)/SKILL.md'
        chmod 0644 '\(dir)/SKILL.md'
        """
    }
}

extension HostCore {
    /// The prompt a sandbox's next session gets (nil: its image runs no agent).
    /// `sudoInstalled`: 594 W28 — whether the guest HAS sudo (checked at session start); the facts never
    /// claim sudo a system disk from an older image does not have. nil: not checked (`inspect --prompt`).
    func agentPromptReport(_ m: Managed, sudoInstalled: Bool? = nil) -> AgentPromptReport? {
        AgentPrompt.report(config: m.config, policy: m.sandbox.egress?.policy,
                           account: m.sandbox.egress == nil ? nil : accountName(m), version: version,
                           credentialProblem: credentialProblem(m), sudoInstalled: sudoInstalled)
    }

    /// Write (or, when off, remove) the facts file and the skill in the guest — a utility exec as
    /// root. A failure is reported and the session still starts.
    func deliverAgentPrompt(_ m: Managed, _ r: AgentPromptReport) async {
        guard let imageSpec = m.config.spec.imageSpec else { return }
        do {
            // 594 W23: the agent's sudo follows the sandbox's setting from this session on (the boot applies it too).
            let sudo = GuestCommand.agentSudoScript(user: imageSpec.user, on: Self.agentSudo(m.config))
            let res = try await m.sandbox.exec(["sh", "-c", sudo + "\n" + AgentPrompt.deliveryScript(r, user: imageSpec.user)], timeoutSeconds: 30)
            if res.exitCode != 0 {
                note(m.name, "could not write the agent prompt (exit \(res.exitCode)): \(String(decoding: res.stderr.prefix(200), as: UTF8.self))")
            }
        } catch {
            note(m.name, "could not write the agent prompt: \(error.localizedDescription)")
        }
    }

    /// `agent-prompt`: read the rendered prompt, or set / clear the sandbox's own layer.
    func agentPrompt(_ r: HostRequest) throws -> AgentPromptReport {
        let m = try get(r.name)
        if r.clearPrompt == true || r.prompt != nil || r.promptMode != nil {
            if r.clearPrompt == true {
                m.config.agentPrompt = nil
                m.config.agentPromptMode = nil
            }
            if let t = r.prompt {
                guard t.utf8.count <= SandboxConfig.maximumAgentPromptBytes else { throw HostError(.invalid, "an agent prompt is at most 16 KiB") }
                m.config.agentPrompt = t.isEmpty ? nil : t
            }
            if let mode = r.promptMode {
                guard ["append", "replace"].contains(mode) else { throw HostError(.invalid, "the agent prompt's mode is append or replace") }
                m.config.agentPromptMode = mode
            }
            try m.config.write(store.configFile(m.name))
            note(m.name, m.config.agentPrompt == nil ? "its own agent prompt cleared" : "its own agent prompt set (\(m.config.agentPromptMode ?? "append")) — from the next session")
        }
        // 594 W23: the sandbox's own choice of the agent's sudo (doz_project.yaml agent_sudo).
        if r.clearAgentSudo == true || r.agentSudo != nil {
            m.config.agentSudo = r.clearAgentSudo == true ? nil : r.agentSudo
            try m.config.write(store.configFile(m.name))
            m.sandbox.setAgentSudo(Self.agentSudo(m.config))
            note(m.name, "the agent's sudo: \(m.config.agentSudo.map { $0 ? "on" : "off" } ?? "follows sandbox.agent_sudo") — from the next session")
        }
        guard let report = agentPromptReport(m) else {
            throw HostError(.invalid, "\(m.name) runs no agent (image \(m.config.image)) — the environment prompt is for claude-code and pi sandboxes")
        }
        return report
    }
}
