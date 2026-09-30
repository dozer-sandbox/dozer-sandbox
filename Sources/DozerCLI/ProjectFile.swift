import Foundation
import Yams
import DozerKit
import DozerHost

/// 594 (D9, owner ruling: YAML, like dbt's `dbt_project.yml`) — `doz_project.yaml`: a folder that
/// is a Dozer Sandbox project. `doz init` writes it; `doz up` with no name, in that folder, creates,
/// starts or wakes exactly that sandbox and attaches. The folder is its /workspace.
///
/// The schema is CLOSED, as doz.toml's is: an unknown key, a value of the wrong type or outside its
/// rule is an error naming its line. No anchors or aliases, no multiple documents, 64 KiB at most.
/// 594 accepts image NAMES only (an image from a Dockerfile is 595's).
struct DozerProject: Equatable {
    static let fileName = "doz_project.yaml"
    static let maximumBytes = 64 << 10

    struct Session: Equatable {
        var name: String
        /// nil: the image's own program (the default session), or a login shell for `shell`.
        var command: [String]?
    }

    var version = 1
    var name: String
    var image: String
    var cpus: Int?
    var memoryMiB: UInt64?
    var network: String?
    var account: String?
    /// What `doz up` starts, in order; the first is attached. Empty: the image's own session.
    var sessions: [Session] = []
    var agentPrompt: String?
    var agentPromptMode: String?
    /// 594 W23: the agent's passwordless sudo (nil: the setting sandbox.agent_sudo decides).
    var agentSudo: Bool?
    /// 596 (B10): the agent and the base instead of `image` — a recommended base, or a Dockerfile
    /// (a path relative to this folder, or absolute).
    var agent: String?
    var base: String?
    var dockerfile: String?

    /// The keys, in the order the file lists them, with what each says.
    static let keys: [(key: String, summary: String)] = [
        ("version", "the file's format: 1"),
        ("name", "the sandbox: 1–40 of a-z 0-9 -"),
        ("image", "claude-code, pi, lab, a base × agent image (python-claude-code, …), or a template (doz image ls) — or agent + base/dockerfile"),
        ("agent", "claude-code, pi or none (596; default claude-code)"),
        ("base", "a recommended base: node, python, go, rust, java, ruby, dotnet, debian, ubuntu, alpine (doz base ls)"),
        ("dockerfile", "your Dockerfile (./Dockerfile): built with Apple's container build — its RUN steps run OUTSIDE Dozer's network policy"),
        ("cpus", "virtual CPUs, 1–64 (default: the settings' defaults.cpus)"),
        ("memory", "guest RAM: 2G, 512M or MiB (default: per image, in the settings)"),
        ("network", "agent, bake, locked, open (proxied), nat or none (default: per image)"),
        ("account", "default (the store's), none, or an account name (doz account ls)"),
        ("sessions", "what `doz up` starts; the first is attached (default: the image's own)"),
        ("agent_prompt", "this project's own lines for the agent's environment prompt"),
        ("agent_prompt_mode", "append (to the template, the default) or replace"),
        ("agent_sudo", "true or false: the agent's passwordless sudo in the sandbox (default: the setting sandbox.agent_sudo, true)"),
    ]

    struct Invalid: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// The project file in `directory`, if there is one.
    static func find(in directory: URL) -> URL? {
        let u = directory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func load(_ url: URL) throws -> DozerProject {
        guard let data = FileManager.default.contents(atPath: url.path) else { throw Invalid(message: "\(url.path) cannot be read") }
        guard data.count <= maximumBytes else { throw Invalid(message: "\(url.path) is over 64 KiB") }
        guard let text = String(data: data, encoding: .utf8) else { throw Invalid(message: "\(url.path) is not UTF-8") }
        return try parse(text, file: url.lastPathComponent)
    }

    /// Parse and check a project file's text.
    static func parse(_ text: String, file: String = fileName) throws -> DozerProject {
        func bad(_ node: Node?, _ what: String) -> Invalid {
            Invalid(message: "\(file)" + (node?.mark.map { " line \($0.line)" } ?? "") + ": " + what)
        }
        // The parser stays alive while the tree is checked: it holds the anchors a node names.
        let parser: Parser
        let root: Node?
        do {
            parser = try Parser(yaml: text)
            root = try parser.singleRoot()
        } catch YamlError.duplicatedKeysInMapping(let keys, _) {
            throw Invalid(message: "\(file): \(keys.joined(separator: ", ")) is given twice")
        } catch {
            let text = String(describing: error)
            if text.contains("expected a single document") { throw Invalid(message: "\(file): one YAML document only") }
            throw Invalid(message: "\(file) is not valid YAML: \(text.split(separator: "\n").first ?? "")")
        }
        defer { withExtendedLifetime(parser) {} }
        guard let root, case .mapping(let map) = root else { throw bad(root, "the file is a mapping of keys (name: …, image: …)") }

        // No anchors or aliases (an alias is a copy of an anchored node: refusing the anchor, top-down,
        // refuses every alias before an expansion is walked).
        func noAnchors(_ n: Node) throws {
            switch n {
            case .alias: throw bad(n, "anchors and aliases are not allowed")
            case .scalar(let s): if s.anchor != nil { throw bad(n, "anchors and aliases are not allowed") }
            case .mapping(let m):
                if m.anchor != nil { throw bad(n, "anchors and aliases are not allowed") }
                for (k, v) in m { try noAnchors(k); try noAnchors(v) }
            case .sequence(let s):
                if s.anchor != nil { throw bad(n, "anchors and aliases are not allowed") }
                for x in s { try noAnchors(x) }
            }
        }
        try noAnchors(root)

        func scalarString(_ n: Node, _ key: String) throws -> String {
            guard case .scalar(let s) = n else { throw bad(n, "\(key) is a single value") }
            return s.string
        }
        func checkSession(_ s: String, _ n: Node) throws {
            do { try GuestCommand.validateSessionName(s) } catch { throw bad(n, "a session's name: 1–64 of letters, digits . _ - (not starting with .)") }
        }

        var seen: Set<String> = []
        var name: String?, image: String?
        var p = DozerProject(name: "", image: "")
        for (k, v) in map {
            guard case .scalar(let ks) = k else { throw bad(k, "a key is a plain name") }
            let key = ks.string
            guard keys.contains(where: { $0.key == key }) else {
                throw bad(k, "unknown key \(key) — the keys are \(keys.map(\.key).joined(separator: ", "))")
            }
            guard seen.insert(key).inserted else { throw bad(k, "\(key) is given twice") }
            if case .scalar = v, v.null != nil, key != "name", key != "image" { continue }    // `key:` with nothing = the default
            switch key {
            case "version":
                guard v.int == 1 else { throw bad(v, "version is 1") }
            case "name":
                let s = try scalarString(v, key)
                guard WebNameRule.isSandboxName(s) else { throw bad(v, "name: 1–40 of a-z 0-9 - (not starting with -)") }
                name = s
            case "image":
                let s = try scalarString(v, key)
                guard s.range(of: "^(custom:)?[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil else {
                    throw bad(v, "image: claude-code, pi, lab, a base × agent image or a template's name (a Dockerfile: dockerfile: ./Dockerfile)")
                }
                image = s
            case "agent":
                let s = try scalarString(v, key)
                guard ["claude-code", "pi", "none"].contains(s) else { throw bad(v, "agent: claude-code, pi or none") }
                p.agent = s
            case "base":
                let s = try scalarString(v, key)
                guard BaseCatalogue.base(s) != nil else { throw bad(v, "base: \(BaseCatalogue.ids.joined(separator: ", ")) (doz base ls)") }
                p.base = s
            case "dockerfile":
                let s = try scalarString(v, key)
                guard !s.isEmpty, s.count <= 1024, !s.contains("\0") else { throw bad(v, "dockerfile: a path (./Dockerfile)") }
                p.dockerfile = s
            case "cpus":
                guard let n = v.int, (1...64).contains(n) else { throw bad(v, "cpus: a whole number 1–64") }
                p.cpus = n
            case "memory":
                let s = try scalarString(v, key)
                guard let m = DozerImages.parseMemory(s), (256...262_144).contains(m) else { throw bad(v, "memory: a size like 2G, 512M or 2048 (MiB), 256 MiB – 256 GiB") }
                p.memoryMiB = m
            case "network":
                let s = try scalarString(v, key)
                guard ["agent", "bake", "locked", "open", "nat", "none"].contains(s) else { throw bad(v, "network: agent, bake, locked, open, nat or none") }
                p.network = s
            case "account":
                let s = try scalarString(v, key)
                guard s == "default" || s == "none" || s.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil else {
                    throw bad(v, "account: default, none or an account name")
                }
                p.account = s
            case "sessions":
                guard case .sequence(let seq) = v else { throw bad(v, "sessions is a list") }
                guard seq.count <= 16 else { throw bad(v, "sessions: at most 16") }
                for item in seq {
                    switch item {
                    case .scalar(let s):
                        try checkSession(s.string, item)
                        p.sessions.append(Session(name: s.string, command: nil))
                    case .mapping(let m):
                        var sn: String?, cmd: [String]?
                        for (sk, sv) in m {
                            let skey = (sk.scalar?.string) ?? ""
                            switch skey {
                            case "name": sn = try scalarString(sv, "a session's name")
                            case "command":
                                switch sv {
                                case .scalar(let s): cmd = s.string.split(whereSeparator: \.isWhitespace).map(String.init)
                                case .sequence(let args): cmd = try args.map { try scalarString($0, "a command's argument") }
                                default: throw bad(sv, "command: a string (split on spaces — no shell) or a list of arguments")
                                }
                                guard let c = cmd, (1...64).contains(c.count) else { throw bad(sv, "command: 1–64 arguments") }
                            default: throw bad(sk, "a session has name and command — not \(skey)")
                            }
                        }
                        guard let sn else { throw bad(item, "a session needs a name") }
                        try checkSession(sn, item)
                        p.sessions.append(Session(name: sn, command: cmd))
                    default:
                        throw bad(item, "a session is a name, or {name, command}")
                    }
                }
                guard Set(p.sessions.map(\.name)).count == p.sessions.count else { throw bad(v, "sessions: each name once") }
            case "agent_prompt":
                let s = try scalarString(v, key)
                guard s.utf8.count <= SandboxConfig.maximumAgentPromptBytes else { throw bad(v, "agent_prompt: at most 16 KiB") }
                p.agentPrompt = s
            case "agent_prompt_mode":
                let s = try scalarString(v, key)
                guard ["append", "replace"].contains(s) else { throw bad(v, "agent_prompt_mode: append or replace") }
                p.agentPromptMode = s
            case "agent_sudo":
                guard let b = v.bool else { throw bad(v, "agent_sudo: true or false") }
                p.agentSudo = b
            default:
                break
            }
        }
        guard let name else { throw bad(root, "name is required (the sandbox's name)") }
        // 596: image, or agent + base/dockerfile (base and dockerfile are one choice).
        let chosen = p.agent != nil || p.base != nil || p.dockerfile != nil
        if image != nil, chosen { throw bad(root, "image, or agent/base/dockerfile — not both") }
        if p.base != nil, p.dockerfile != nil { throw bad(root, "base or dockerfile — not both") }
        guard let image = image ?? (chosen ? p.chosenImage : nil) else {
            throw bad(root, "image is required (claude-code, pi, lab or a template) — or agent with base or dockerfile")
        }
        p.name = name
        p.image = image
        return p
    }

    /// 596: the image agent + base name (a Dockerfile's: the agent's, the host swaps in its base).
    var chosenImage: String {
        let a: AgentKind = switch agent ?? "claude-code" { case "pi": .pi; case "none": .none; default: .claudeCode }
        if dockerfile != nil { return ImageChoice(base: a == .none ? "alpine" : "node", agent: a).name }
        return ImageChoice(base: base ?? "node", agent: a).name
    }

    /// The file `doz init` writes: every key listed; the ones not set are commented (their defaults).
    func render() -> String {
        func quoted(_ s: String) -> String {
            s.range(of: "^[A-Za-z0-9._/-]+$", options: .regularExpression) != nil ? s : "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var out = """
        # doz_project.yaml — a Dozer Sandbox project (written by doz init).
        # `doz up` in this folder creates, starts or wakes the sandbox below and attaches to its first
        # session. This folder is shared at /workspace. Unknown keys are errors; a commented key takes
        # its default (doz config show).
        #
        # When a change applies (594 W12) — `doz up` says what differs and what it did:
        #   image (agent, base, dockerfile), cpus, memory, network nat/none: when the sandbox is MADE —
        #     doz rm NAME && doz up recreates it (this folder is kept);
        #   network agent/bake/locked/open: at the next doz up, live (unless you edited the policy);
        #   account: doz account use NAME ACCOUNT (from the next session);
        #   sessions: every doz up; agent_prompt, agent_sudo: from the next session.
        version: 1
        name: \(name)

        """
        // 596 (B10): the image as agent + base/dockerfile when the file said so, else by name.
        if agent != nil || base != nil || dockerfile != nil {
            out += "agent: \(agent ?? "claude-code")               # claude-code, pi or none — when made\n"
            out += base.map { "base: \($0)                   # doz base ls — when made\n" } ?? "# base: node                 # doz base ls — or dockerfile — when made\n"
            out += dockerfile.map { "dockerfile: \(quoted($0))     # built with Apple's container build, OUTSIDE Dozer's network policy — when made\n" } ?? ""
        } else {
            out += "image: \(image)                  # when made\n"
            out += "# (or: agent: claude-code|pi|none with base: python … or dockerfile: ./Dockerfile — doz base ls)\n"
        }
        out += "\n"
        out += cpus.map { "cpus: \($0)                     # when made\n" } ?? "# cpus: 2                    # when made\n"
        out += memoryMiB.map { "memory: \($0 % 1024 == 0 ? "\($0 / 1024)G" : "\($0)M")                 # when made\n" } ?? "# memory: 2G                 # when made\n"
        out += network.map { "network: \($0)\n" } ?? "# network: agent\n"
        out += """
        #   agent  — proxied: Anthropic's API and sign-in, Claude Code's own hosts, GitHub, package registries
        #   bake   — proxied: package registries only (what an image bake needs)
        #   locked — proxied: nothing leaves the sandbox (DNS included)
        #   open   — proxied: every host allowed, every connection still logged
        #   nat    — a real network interface (vmnet), unfiltered and unlogged
        #   none   — no network at all
        #   (proxied: no network interface; every connection judged by the policy on the Mac and logged)

        """
        out += account.map { "account: \(quoted($0))\n" } ?? "# account: default          # default (the store's), none, or an account name\n"
        if sessions.isEmpty {
            out += """
            # sessions:                 # what doz up starts; the first is attached (default: the image's own)
            #   - claude
            #   - name: server
            #     command: npm run dev

            """
        } else {
            out += "sessions:\n"
            for s in sessions {
                if let c = s.command { out += "  - name: \(s.name)\n    command: [\(c.map(quoted).joined(separator: ", "))]\n" }
                else { out += "  - \(s.name)\n" }
            }
        }
        if let a = agentPrompt {
            out += "agent_prompt: |\n" + a.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n") + "\n"
        } else {
            out += """
            # agent_prompt: |           # this project's own lines for the agent (see doz inspect NAME --prompt)
            #   The tests run with `make test`.

            """
        }
        out += agentPromptMode.map { "agent_prompt_mode: \($0)\n" } ?? "# agent_prompt_mode: append  # or replace\n"
        out += agentSudo.map { "agent_sudo: \($0)\n" }
            ?? "# agent_sudo: true           # the agent's passwordless sudo (apt-get install …); false: none. From the next session\n"
        return out
    }

    /// The create options this project gives a new sandbox (the folder is its workspace).
    func createOptions(folder: URL, file: URL) -> CreateOptions {
        var o = CreateOptions(image: image, cpus: cpus, memoryMiB: memoryMiB, workspace: folder.path, network: network, account: account)
        o.agentPrompt = agentPrompt
        o.agentPromptMode = agentPromptMode
        o.agentSudo = agentSudo
        o.project = file.path
        // 596 (B6): a Dockerfile relative to this folder (its folder is the build context).
        if let d = dockerfile {
            let expanded = (d as NSString).expandingTildeInPath
            o.dockerfile = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : URL(fileURLWithPath: expanded, relativeTo: folder)).standardizedFileURL.path
        }
        return o
    }

    /// A sandbox name from a folder's name: lower-cased, runs of anything else become `-`.
    static func suggestedName(for folder: URL) -> String {
        var s = ""
        for ch in folder.lastPathComponent.lowercased() {
            if ("a"..."z").contains(ch) || ("0"..."9").contains(ch) { s.append(ch) }
            else if s.last != "-" { s.append("-") }
        }
        s = String(s.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40))
        return s.isEmpty ? "project" : s
    }
}

/// The library's sandbox-name rule, for the CLI's own checks.
enum WebNameRule {
    static func isSandboxName(_ s: String) -> Bool {
        (1...40).contains(s.count) && s.first != "-" && s.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}
