import Foundation

// Workspace rules — `.dozignore` and `.dozreadonly` at the root of a shared folder — as the Mac sees
// them. The guest's view (`dozview`, Guest/dozview/) enforces them; this is the same decision made on
// the Mac, for `doz ignore check` / `show`, the warnings at create and start, and the sandbox's facts.
//
// Owner rulings (workspace changes/599g-*): `.dozignore` SELECTS paths with Docker's `.dockerignore`
// syntax and BuildKit's walker semantics (D1: for `d`, `!d/f`, `d` the file d/f is SENT — visible);
// `workspace.ignore_mode` decides what a selected path is: `lock` (listed with no permissions, every
// access refused — the default) or `hide` (not there at all). `.dozreadonly` (same syntax) selects
// READ-ONLY paths. Implicitly read-only, before the user's lines (so `!name` re-allows them):
// doz_project.yaml, doz_project.yml, .git/hooks. Always visible and read-only: the two rule files.
// D2: on a case-insensitive Mac volume the folded rules are ALSO evaluated against the folded path, and
// a path is selected when either evaluation selects it — only ever more than Docker would.
// No rule file → no view: the share is bound as it always was.

/// What `.dozignore` does to the paths it selects.
public enum WorkspaceRuleMode: String, Sendable, Codable, CaseIterable {
    /// Listed, shown with no permissions; every open, read, write, rename, delete is refused.
    case lock
    /// Not listed; looking it up says no such file.
    case hide
}

/// What a path is in the sandbox's view.
public enum WorkspaceVerdict: String, Sendable, Codable {
    case visible
    case readOnly = "read-only"
    case locked
    case hidden
}

public struct WorkspaceRules: Sendable {
    public static let ignoreFile = ".dozignore"
    public static let readOnlyFile = ".dozreadonly"
    public static let ruleFiles = [ignoreFile, readOnlyFile]
    /// Read-only whenever a view runs, unless the user's .dozreadonly re-allows them with `!`.
    public static let implicitReadOnly = ["doz_project.yaml", "doz_project.yml", ".git/hooks"]
    /// A rule file larger than this is ignored (the guest does the same).
    public static let maximumFileBytes = 1 << 20

    /// One rule: a line of a rule file (`line` 1-based), or an implicit one (`line` nil, `file` nil).
    public struct Rule: Sendable, Equatable, Codable {
        public var file: String?
        public var line: Int?
        public var pattern: String
        public var isException: Bool { pattern.hasPrefix("!") }
        /// "`.dozignore` line 3 (`secret*`)", "always (`doz_project.yaml`)".
        public var label: String {
            guard let file, let line else { return "always read-only (`\(pattern)`)" }
            return "\(file) line \(line) (`\(pattern)`)"
        }
    }

    /// A line the rules cannot use (it is skipped; Docker would refuse the whole file).
    public struct Problem: Sendable, Equatable, Codable {
        public var file: String
        public var line: Int
        public var text: String
        public var reason: String
    }

    public let mode: WorkspaceRuleMode
    /// The Mac volume holding the folder is case-insensitive — the folded rules apply too.
    public let fold: Bool
    public let ignorePresent: Bool
    public let readOnlyPresent: Bool
    /// The usable `.dozignore` lines.
    public let ignore: [Rule]
    /// The implicit read-only rules, then the usable `.dozreadonly` lines.
    public let readOnly: [Rule]
    public let problems: [Problem]

    let ignoreSets: [RuleSet]      // [exact] or [exact, folded]
    let readOnlySets: [RuleSet]

    /// A matcher plus, for each of its patterns, the index of the rule it came from.
    struct RuleSet: Sendable {
        var matcher: DockerIgnore
        var ruleIndex: [Int]
        var folded: Bool
    }

    /// Any rule file in the folder — a view runs for it.
    public var active: Bool { ignorePresent || readOnlyPresent }

    /// Whether `folder` holds a rule file (cheap: two `stat`s).
    public static func present(in folder: URL) -> Bool {
        ruleFiles.contains { isRegularFile(folder.appendingPathComponent($0)) }
    }

    /// The Mac volume of `folder` compares names without case (every default macOS volume). Unknown → true
    /// (folding only ever hides more).
    public static func caseInsensitive(_ folder: URL) -> Bool {
        let v = try? folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
        return !(v ?? false)
    }

    /// The rules of a shared folder, read from the Mac. `fold` nil = detect from the folder's volume.
    public static func load(folder: URL, mode: WorkspaceRuleMode, fold: Bool? = nil) -> WorkspaceRules {
        func read(_ name: String) -> String? {
            let url = folder.appendingPathComponent(name)
            guard isRegularFile(url), let a = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = a[.size] as? Int, size <= maximumFileBytes,
                  let d = try? Data(contentsOf: url) else { return nil }
            return String(decoding: d, as: UTF8.self)
        }
        return WorkspaceRules(ignoreText: read(ignoreFile), readOnlyText: read(readOnlyFile), mode: mode,
                              fold: fold ?? caseInsensitive(folder))
    }

    public init(ignoreText: String?, readOnlyText: String?, mode: WorkspaceRuleMode = .lock, fold: Bool = true) {
        self.mode = mode
        self.fold = fold
        ignorePresent = ignoreText != nil
        readOnlyPresent = readOnlyText != nil
        var problems: [Problem] = []
        func rules(_ text: String?, file: String) -> [Rule] {
            DockerIgnore.parseLines(text ?? "").map { Rule(file: file, line: $0.line, pattern: $0.pattern) }
        }
        let ign = rules(ignoreText, file: Self.ignoreFile)
        let ro = Self.implicitReadOnly.map { Rule(file: nil, line: nil, pattern: $0) } + rules(readOnlyText, file: Self.readOnlyFile)
        func sets(_ all: [Rule]) -> (kept: [Rule], sets: [RuleSet]) {
            let exact = DockerIgnore.lenient(all.map(\.pattern))
            let bad = Set(exact.dropped.map(\.index))
            for d in exact.dropped {
                let r = all[d.index]
                if let f = r.file, let l = r.line { problems.append(Problem(file: f, line: l, text: r.pattern, reason: d.reason)) }
            }
            // keep the rule list aligned with the exact matcher's patterns
            let kept = all.enumerated().filter { !bad.contains($0.offset) && !$0.element.pattern.trimmingCharacters(in: .whitespaces).isEmpty }.map(\.element)
            var out = [RuleSet(matcher: exact.0, ruleIndex: Array(kept.indices), folded: false)]
            if fold {
                let f = DockerIgnore.lenient(kept.map { DozFold.foldPattern($0.pattern) })
                let fbad = Set(f.dropped.map(\.index))
                out.append(RuleSet(matcher: f.0, ruleIndex: kept.indices.filter { !fbad.contains($0) }, folded: true))
            }
            return (kept, out)
        }
        let i = sets(ign), r = sets(ro)
        ignore = i.kept; ignoreSets = i.sets
        readOnly = r.kept; readOnlySets = r.sets
        self.problems = problems
    }

    // MARK: deciding one path

    /// Why a path is what it is.
    public struct Decision: Sendable, Equatable, Codable {
        public var path: String
        public var verdict: WorkspaceVerdict
        /// The rule that decided (nil: no rule — visible, or a rule file which is always read-only).
        public var rule: Rule?
        /// The path the deciding rule matched — the path itself or the folder above it that carries it.
        public var matched: String?
        /// Only the case- and Unicode-folded comparison selected it (a Mac volume ignores case).
        public var folded: Bool
        /// A selected folder an exception re-includes from: shown, holding only what is re-included.
        public var skeleton: Bool
        /// One of the rule files themselves — always visible and read-only.
        public var ruleFile: Bool
    }

    /// The verdict for `path` (relative to the folder, `/`-separated). `isDirectory(prefix)` says
    /// whether a path is a folder (ancestors are always folders).
    public func decide(_ path: String, isDirectory: (String) -> Bool) -> Decision {
        var e = Evaluator(self)
        return e.decide(path, isDirectory: isDirectory)
    }

    /// Decide many paths quickly (a cache per folder) — the warnings run over `git ls-files`.
    public struct Evaluator {
        let rules: WorkspaceRules
        struct State {
            var cls: Int                       // 0 visible, 1 read-only, 2 selected (locked/hidden)
            var infos: [[Bool]]                // per set: ignore sets then read-only sets
            var decision: Decision
        }
        var cache: [String: State] = [:]

        public init(_ rules: WorkspaceRules) { self.rules = rules }

        public mutating func decide(_ raw: String, isDirectory: (String) -> Bool) -> Decision {
            let path = goClean(raw.hasPrefix("/") ? String(raw.drop(while: { $0 == "/" })) : raw)
            if path == "." || path.isEmpty || path.hasPrefix("../") || path == ".." {
                return Decision(path: path == "." ? "" : path, verdict: .visible, rule: nil, matched: nil, folded: false, skeleton: false, ruleFile: false)
            }
            return state(path, isDir: isDirectory(path), isDirectory: isDirectory).decision
        }

        private mutating func state(_ path: String, isDir: Bool, isDirectory: (String) -> Bool) -> State {
            if let s = cache[path] { return s }
            let parentPath = goDir(path)
            let parent: State? = parentPath == "." ? nil : state(parentPath, isDir: true, isDirectory: isDirectory)
            let s = compute(path, isDir: isDir, parent: parent)
            cache[path] = s
            return s
        }

        private func compute(_ path: String, isDir: Bool, parent: State?) -> State {
            let r = rules
            let sets = r.ignoreSets + r.readOnlySets
            let foldedPath = r.fold ? DozFold.fold(path) : path
            var infos: [[Bool]] = []
            var ign: (hit: Bool, skip: Bool, decider: (set: Int, idx: Int)?) = (false, false, nil)
            var ro: (hit: Bool, decider: (set: Int, idx: Int)?) = (false, nil)
            for (k, set) in sets.enumerated() {
                let p = set.folded ? foldedPath : path
                let res = (try? set.matcher.matchUsingParent(p, parent?.infos[k]))
                    ?? (excluded: false, info: [Bool](repeating: false, count: set.matcher.patterns.count), decider: nil)
                infos.append(res.info)
                guard res.excluded, let d = res.decider else { continue }
                if k < r.ignoreSets.count {
                    let skip = isDir && !set.matcher.mayReincludeInside(p)
                    // prefer the exact comparison's rule; a skip from either wins
                    if !ign.hit || (skip && !ign.skip) { ign.decider = (k, d) }
                    ign.hit = true; ign.skip = ign.skip || skip
                } else if !ro.hit {
                    ro = (true, (k, d))
                }
            }
            func rule(_ d: (set: Int, idx: Int)?) -> (Rule, Bool)? {
                guard let d else { return nil }
                let set = sets[d.set]
                let list = d.set < r.ignoreSets.count ? r.ignore : r.readOnly
                guard d.idx < set.ruleIndex.count else { return nil }
                return (list[set.ruleIndex[d.idx]], set.folded)
            }
            let base = Decision(path: path, verdict: .visible, rule: nil, matched: nil, folded: false, skeleton: false, ruleFile: false)
            var dec = base, cls = 0
            let selected: WorkspaceVerdict = r.mode == .hide ? .hidden : .locked
            if Self.isRuleFile(path, fold: r.fold) {
                dec.verdict = .readOnly; dec.ruleFile = true; cls = 1
            } else if let p = parent, p.cls == 2 {
                dec = p.decision; dec.path = path; dec.skeleton = false; cls = 2
            } else if (ign.hit && !isDir) || ign.skip {
                cls = 2; dec.verdict = selected
                if let (ru, f) = rule(ign.decider) { dec.rule = ru; dec.folded = f && !(exactHit(path, isDir: isDir, parent: parent, sets: r.ignoreSets.count)) }
            } else if ro.hit {
                cls = 1; dec.verdict = .readOnly
                if let (ru, f) = rule(ro.decider) { dec.rule = ru; dec.folded = f }
                dec.skeleton = false
            }
            if ign.hit && isDir && !ign.skip && cls != 2 { dec.skeleton = true }
            if dec.rule != nil && dec.matched == nil { dec.matched = matchedAt(path, dec) }
            return State(cls: cls, infos: infos, decision: dec)
        }

        /// Did the exact (unfolded) ignore comparison select this path on its own?
        private func exactHit(_ path: String, isDir: Bool, parent: State?, sets: Int) -> Bool {
            let set = rules.ignoreSets[0]
            guard let res = try? set.matcher.matchUsingParent(path, parent?.infos[0]), res.excluded else { return false }
            return !isDir || !set.matcher.mayReincludeInside(path)
        }

        /// The shortest prefix of `path` the deciding rule matches (for "carried by the folder X").
        private func matchedAt(_ path: String, _ d: Decision) -> String? {
            guard let rule = d.rule, !rule.isException else { return path }
            let pat = d.folded ? DozFold.foldPattern(rule.pattern) : rule.pattern
            guard let m = try? DockerIgnore(patterns: [pat]) else { return path }
            var prefix = ""
            for comp in path.split(separator: "/") {
                prefix = prefix.isEmpty ? String(comp) : prefix + "/" + comp
                let p = d.folded ? DozFold.fold(prefix) : prefix
                if (try? m.patterns[0].match(p)) == true { return prefix }
            }
            return path
        }

        static func isRuleFile(_ path: String, fold: Bool) -> Bool {
            fold ? ruleFiles.contains { $0.caseInsensitiveCompare(path) == .orderedSame } : ruleFiles.contains(path)
        }
    }

    static func isRegularFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// The counts a sandbox page shows.
    public var summary: WorkspaceRulesSummary {
        WorkspaceRulesSummary(mode: mode, fold: fold, ignorePatterns: ignore.count, readOnlyPatterns: readOnly.count - Self.implicitReadOnly.count,
                              ignoreFile: ignorePresent, readOnlyFile: readOnlyPresent, problems: problems.count)
    }
}

/// What a sandbox's details say about its workspace rules.
public struct WorkspaceRulesSummary: Sendable, Equatable, Codable {
    public var mode: WorkspaceRuleMode
    public var fold: Bool
    public var ignorePatterns: Int
    public var readOnlyPatterns: Int
    public var ignoreFile: Bool
    public var readOnlyFile: Bool
    public var problems: Int
    public init(mode: WorkspaceRuleMode, fold: Bool, ignorePatterns: Int, readOnlyPatterns: Int, ignoreFile: Bool, readOnlyFile: Bool, problems: Int) {
        self.mode = mode; self.fold = fold; self.ignorePatterns = ignorePatterns; self.readOnlyPatterns = readOnlyPatterns
        self.ignoreFile = ignoreFile; self.readOnlyFile = readOnlyFile; self.problems = problems
    }
}
