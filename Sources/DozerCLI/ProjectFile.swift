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

    /// The keys, in the order the file lists them, with what each says.
    static let keys: [(key: String, summary: String)] = [
        ("version", "the file's format: 1"),
        ("name", "the sandbox: 1–40 of a-z 0-9 -"),
        ("image", "claude-code, pi, lab, or a template (doz image ls)"),
        ("cpus", "virtual CPUs, 1–64 (default: the settings' defaults.cpus)"),
        ("memory", "guest RAM: 2G, 512M or MiB (default: per image, in the settings)"),
        ("network", "agent, bake, locked, open (proxied), nat or none (default: per image)"),
        ("account", "default (the store's), none, or an account name (doz account ls)"),
        ("sessions", "what `doz up` starts; the first is attached (default: the image's own)"),
        ("agent_prompt", "this project's own lines for the agent's environment prompt"),
        ("agent_prompt_mode", "append (to the template, the default) or replace"),
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
                    throw bad(v, "image: claude-code, pi, lab or a template's name (an image from a Dockerfile is not supported yet)")
                }
                image = s
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
            default:
                break
            }
        }
        guard let name else { throw bad(root, "name is required (the sandbox's name)") }
        guard let image else { throw bad(root, "image is required (claude-code, pi, lab or a template)") }
        p.name = name
        p.image = image
        return p
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
        # its default (doz config show). An image from a Dockerfile is not supported yet.
        version: 1
        name: \(name)
        image: \(image)

        """
        out += cpus.map { "cpus: \($0)\n" } ?? "# cpus: 2\n"
        out += memoryMiB.map { "memory: \($0 % 1024 == 0 ? "\($0 / 1024)G" : "\($0)M")\n" } ?? "# memory: 2G\n"
        out += network.map { "network: \($0)\n" } ?? "# network: agent            # agent, bake, locked, open (proxied), nat or none\n"
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
        return out
    }

    /// The create options this project gives a new sandbox (the folder is its workspace).
    func createOptions(folder: URL, file: URL) -> CreateOptions {
        var o = CreateOptions(image: image, cpus: cpus, memoryMiB: memoryMiB, workspace: folder.path, network: network, account: account)
        o.agentPrompt = agentPrompt
        o.agentPromptMode = agentPromptMode
        o.project = file.path
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
