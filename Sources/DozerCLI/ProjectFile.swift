import Foundation
import Yams
import DozerKit
import DozerHost

/// 594 (D9) — READING `doz_project.yaml` (or, 599f, `doz_project.yml`). The model, the renderer and the
/// whole-project check are `DozerHost.DozerProject` (shared with the dashboard's wizard, which `doz ui`
/// hands this parser); Yams stays in the CLI's commands. The schema is CLOSED: an unknown key, a value of
/// the wrong type or outside its rule is an error naming its line. No anchors or aliases, no multiple
/// documents, 64 KiB at most.
extension DozerProject {
    /// The project file in `directory`, if there is one (`find(in:)`; both spellings at once → Invalid).
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
        guard text.utf8.count <= maximumBytes else { throw Invalid(message: "\(file) is over 64 KiB") }
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
                    throw bad(v, "image: claude-code, pi, codex, lab, a base × agent image or a template's name (a Dockerfile: dockerfile: ./Dockerfile)")
                }
                image = s
            case "agent":
                let s = try scalarString(v, key)
                guard ["claude-code", "pi", "codex", "none"].contains(s) else { throw bad(v, "agent: claude-code, pi, codex or none") }
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
            case "permissions":
                // 599f: a string (`standard`, `+web,-error-reports`) or a list of words.
                let words: [String]
                switch v {
                case .scalar(let s): words = s.string.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                case .sequence(let seq): words = try seq.map { try scalarString($0, "a permission") }
                default: throw bad(v, "permissions: words like standard or +web,-error-reports")
                }
                guard SettingType.permissionWords(words.joined(separator: ",")) != nil else {
                    throw bad(v, "permissions: standard, locked, open, or permissions like +web,-error-reports (doz net permissions)")
                }
                p.permissions = words
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
            case "github":
                // YAML reads `off` as a boolean false.
                let s = v.bool == false ? "off" : try scalarString(v, key)
                guard ["off", "read", "push"].contains(s) else { throw bad(v, "github: off, read or push") }
                p.github = s
            default:
                // 599: a per-sandbox setting, checked against the setting's own type.
                if let sk = settingKeys.first(where: { $0.key == key }), let d = DozerSettings.definition(sk.setting) {
                    let text: String
                    // YAML reads `off` as a boolean: only a boolean setting takes it as one (`clipboard: off` is the choice).
                    if d.type == .bool, let b = v.bool { text = b ? "true" : "false" } else { text = try scalarString(v, key) }
                    do { p.settings[sk.setting] = try d.parse(text) } catch let e as SettingsError {
                        throw bad(v, "\(key): \(e.message.replacingOccurrences(of: sk.setting, with: key))")
                    }
                }
            }
        }
        guard let name else { throw bad(root, "name is required (the sandbox's name)") }
        // 596: image, or agent + base/dockerfile (base and dockerfile are one choice).
        let chosen = p.agent != nil || p.base != nil || p.dockerfile != nil
        if image != nil, chosen { throw bad(root, "image, or agent/base/dockerfile — not both") }
        if p.base != nil, p.dockerfile != nil { throw bad(root, "base or dockerfile — not both") }
        guard let image = image ?? (chosen ? p.chosenImage : nil) else {
            throw bad(root, "image is required (claude-code, pi, codex, lab or a template) — or agent with base or dockerfile")
        }
        p.name = name
        p.image = image
        // 599f: the whole-project check the wizard and doz init share (what the file says by itself).
        if let why = p.problem() { throw bad(root, why) }
        return p
    }
}

/// The library's sandbox-name rule, for the CLI's own checks.
enum WebNameRule {
    static func isSandboxName(_ s: String) -> Bool {
        (1...40).contains(s.count) && s.first != "-" && s.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}
