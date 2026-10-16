import Foundation

// 617.11 (owner: "i tried fabric and it just gave me a terminal. I think whats missing for trys is our companion guide"):
// a recipe's GUIDE (`com.dozersandbox/guide@1`) — what the tool is in one or two sentences, the first steps (each a
// command a person can copy or run), tips, and its docs. Dozer adds the facts of the sandbox (the version, the key and
// model, the network, the folder) — never the recipe. The FIRST step is the recipe's own check turn (or what that turn
// proves), so the first thing a person runs is known to work; `make recipe-check` runs every step that is not an edit.
// docs/recipes/RECIPE-FORMAT.md, "The guide".

extension AgentRecipe {
    /// guide@1.
    public struct Guide: Codable, Sendable, Equatable {
        /// One or two sentences: what it is, and whether it is a chat, an agent's own screen, or a tool that answers in the
        /// shell and exits.
        public var intro: String
        public var steps: [Step]
        /// Short tips; `code` in backquotes.
        public var tips: [String]?
        /// Its own documentation (https).
        public var docs: String?
        /// 617 (owner, 2026-10-15): one short line `doz try` says FIRST — what the person meets at the tool's first start
        /// that Dozer leaves to them (Antigravity CLI's Terms of Service, accepted by the person, never by Dozer).
        public var notice: String? = nil

        public struct Step: Codable, Sendable, Equatable {
            public var text: String
            public var command: String?
            /// The person changes the command first: the page types it and never presses Enter.
            public var edit: Bool?
            public init(text: String, command: String? = nil, edit: Bool? = nil) { self.text = text; self.command = command; self.edit = edit }
        }

        public init(intro: String, steps: [Step], tips: [String]? = nil, docs: String? = nil, notice: String? = nil) {
            self.intro = intro; self.steps = steps; self.tips = tips; self.docs = docs; self.notice = notice
        }

        /// The check turn's step: the first with a command (a step before it only says something — Antigravity's terms).
        public var checkStep: Step? { steps.first { $0.command != nil } }

        public static let maximumSteps = 8, maximumTips = 6
        public static let maximumIntro = 400, maximumText = 200, maximumCommand = 300, maximumTip = 240
        /// Commands a step may start with besides the tool's own: plain shell builtins and readers.
        public static let shellWords: Set<String> = ["echo", "printf", "cat", "ls", "cd", "mkdir", "head", "tail", "export"]
    }

    /// The words a guide's command may start with: its program, its session's command, its short name, the shell's own.
    public var guideWords: Set<String> {
        var w = Guide.shellWords
        w.insert(install.binary)
        if let c = launch.command.first { w.insert(c) }
        w.insert(shortName)
        return w
    }

    /// The command a guide's first step must be: the check turn as a person types it — `sh -c X` is X, and a
    /// `${{ dozer.model }}` / `${{ dozer.base_url }}` is the variable models@1 sets to it (`"$DOZ_MODEL"`).
    func guideMatchesCheck(_ command: String) -> Bool {
        guard let c = smoke else { return false }
        if c.argv.count == 3, c.argv[0] == "sh", c.argv[1] == "-c" {
            return Self.squeezed(command) == Self.squeezed(c.argv[2])
        }
        guard let words = Self.shellWords(command), words.count == c.argv.count else { return false }
        // The variables a template may be written as (models@1's env set exactly to it).
        var vars: [String: Set<String>] = [:]
        for e in (models?.shapes?.map(\.env) ?? []) + (models?.native?.map(\.env) ?? []) {
            for (k, v) in e {
                if v == "{model}" { vars["${{ dozer.model }}", default: []].insert("$" + k) }
                if v == "{base_url}" { vars["${{ dozer.base_url }}", default: []].insert("$" + k) }
            }
        }
        for (a, w) in zip(c.argv, words) where a != w {
            if let allowed = vars[a], allowed.contains(w) { continue }
            // 618: a template inside a word (Droid's `custom:${{ dozer.model }}`) — the same word with the variable.
            let inside = vars.contains { t, names in a.contains(t) && names.contains { a.replacingOccurrences(of: t, with: $0) == w } }
            guard inside else { return false }
        }
        return true
    }

    static func squeezed(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// A command's words as the shell splits them (plain words, '…' and "…"; a backslash escapes the next character
    /// outside single quotes). nil: an unfinished quote.
    public static func shellWords(_ s: String) -> [String]? {
        var out: [String] = [], cur = "", inWord = false
        var it = Array(s), i = 0
        while i < it.count {
            let ch = it[i]
            switch ch {
            case " ", "\t":
                if inWord { out.append(cur); cur = ""; inWord = false }
            case "'":
                inWord = true
                guard let j = it[(i + 1)...].firstIndex(of: "'") else { return nil }
                cur += String(it[(i + 1)..<j]); i = j
            case "\"":
                inWord = true
                var j = i + 1
                while j < it.count, it[j] != "\"" {
                    if it[j] == "\\", j + 1 < it.count { j += 1 }
                    cur.append(it[j]); j += 1
                }
                guard j < it.count else { return nil }
                i = j
            case "\\":
                inWord = true
                if i + 1 < it.count { i += 1; cur.append(it[i]) }
            default:
                inWord = true
                cur.append(ch)
            }
            i += 1
        }
        if inWord { out.append(cur) }
        it = []
        return out
    }

    /// guide@1's rules (from `validate()`).
    func validateGuide(_ bad: (String) -> SandboxError) throws {
        guard let g = guide else { return }
        func plain(_ s: String, _ max: Int) -> Bool {
            !s.trimmingCharacters(in: .whitespaces).isEmpty && s.count <= max && !s.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
        guard plain(g.intro, Guide.maximumIntro) else { throw bad("guide intro: one or two sentences (at most \(Guide.maximumIntro) characters)") }
        guard !g.steps.isEmpty, g.steps.count <= Guide.maximumSteps else { throw bad("guide steps: 1 to \(Guide.maximumSteps)") }
        guard (g.tips ?? []).count <= Guide.maximumTips else { throw bad("guide tips: at most \(Guide.maximumTips)") }
        for t in g.tips ?? [] where !plain(t, Guide.maximumTip) || t.filter({ $0 == "`" }).count % 2 == 1 {
            throw bad("guide tip: at most \(Guide.maximumTip) characters, `code` closed")
        }
        if let d = g.docs, !(d.hasPrefix("https://") && URL(string: d)?.host != nil) { throw bad("guide docs: an https URL") }
        let words = guideWords
        for (i, s) in g.steps.enumerated() {
            guard plain(s.text, Guide.maximumText), s.text.filter({ $0 == "`" }).count % 2 == 0 else {
                throw bad("guide step \(i + 1): its text at most \(Guide.maximumText) characters, `code` closed")
            }
            if s.edit == true, s.command == nil { throw bad("guide step \(i + 1): edit is for a command") }
            guard let c = s.command else { continue }
            guard plain(c, Guide.maximumCommand), let w = Self.shellWords(c), let first = w.first else {
                throw bad("guide step \(i + 1): one line, at most \(Guide.maximumCommand) characters, its quotes closed")
            }
            guard words.contains(first) else {
                throw bad("guide step \(i + 1): a command starts with \(install.binary) (or \(words.subtracting([install.binary]).sorted().joined(separator: ", ")))")
            }
        }
        // 617 (owner, 2026-10-15): a step without a command may come first (what the person meets at the first start);
        // the first step WITH a command is the check turn.
        guard let step = g.checkStep, let first = step.command, step.edit != true, guideMatchesCheck(first) else {
            throw bad("guide: the first step with a command is the check turn as a person types it (launch@1 check)")
        }
        if let n = g.notice, !plain(n, Guide.maximumText) { throw bad("guide notice: one line, at most \(Guide.maximumText) characters") }
    }
}

extension AgentRecipe.Install {
    /// 617.11: a file set the tool needs beside its program (Fabric's patterns), from a pinned archive — sha256-checked
    /// in the bake, one folder of it unpacked to `to`, owned by root and read-only to the agent.
    public struct Extra: Codable, Sendable, Equatable {
        /// https, a `.tar.gz`; `{version}` in it.
        public var url: String
        public var sha256: String
        /// The folder inside the archive (`{version}` in it).
        public var path: String
        /// Where it goes: under `/opt/<id>/`.
        public var to: String
        public var what: String
        public init(url: String, sha256: String, path: String, to: String, what: String) {
            self.url = url; self.sha256 = sha256; self.path = path; self.to = to; self.what = what
        }
    }
}

extension AgentRecipe {
    func validateExtras(_ bad: (String) -> SandboxError) throws {
        for e in install.extras ?? [] {
            // Plain characters only: the url, the folder and what it is go into the bake script.
            guard e.url.range(of: #"^https://[A-Za-z0-9.-]+/[A-Za-z0-9._/{}~+-]+$"#, options: .regularExpression) != nil,
                  e.what.range(of: #"^[A-Za-z0-9 ._-]+$"#, options: .regularExpression) != nil,
                  let u = URL(string: e.url), u.scheme == "https", let h = u.host, AgentRecipes.isExactHost(h), e.url.hasSuffix(".tar.gz") || e.url.contains("/tar.gz/"),
                  e.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  !e.path.hasPrefix("/"), !e.path.split(separator: "/").contains(".."), e.path.range(of: #"^[A-Za-z0-9._/{}-]+$"#, options: .regularExpression) != nil,
                  e.to.hasPrefix("/opt/\(id)/"), !e.to.split(separator: "/").contains(".."), e.to.range(of: #"^[a-z0-9._/-]+$"#, options: .regularExpression) != nil,
                  !e.what.isEmpty else {
                throw bad("install extra \(e.url): an https .tar.gz, its sha256, a folder in it, a place under /opt/\(id)/, what it is")
            }
        }
    }

    /// The hosts the bake reaches for its extras.
    var extraHosts: [String] { (install.extras ?? []).compactMap { URL(string: $0.url)?.host } }
}
