import Foundation
import DozerKit

// 599g — workspace rules on the host: what `doz ignore check|show`, the sandbox page and the warnings at
// create/up/start say. The rules are read from the Mac folder (`WorkspaceRules`, DozerKit) — no VM is
// needed to explain them; only "is the view running in the guest" asks the guest, and only from a host
// whose sandbox runs.

/// What `SandboxInfo` carries: the rules' shape and whether the guest serves them.
public struct WorkspaceRulesInfo: Codable, Equatable, Sendable {
    public var mode: String
    public var ignorePatterns: Int
    public var readOnlyPatterns: Int
    public var ignoreFile: Bool
    public var readOnlyFile: Bool
    public var problems: Int
    /// The Mac volume is case-insensitive: names are compared folded (case and Unicode form).
    public var caseInsensitive: Bool
    /// `running` (the guest serves the view now), `pending` (it runs, without the view yet — at its next
    /// session or wake), `stopped` (the sandbox is not running — at its next start or wake).
    public var view: String

    /// One line for `doz ls --long`, `inspect` and the sandbox page.
    public var line: String {
        var parts: [String] = []
        if ignoreFile { parts.append(".dozignore: \(ignorePatterns) pattern\(ignorePatterns == 1 ? "" : "s") (\(mode))") }
        if readOnlyFile { parts.append(".dozreadonly: \(readOnlyPatterns) pattern\(readOnlyPatterns == 1 ? "" : "s")") }
        if problems > 0 { parts.append("\(problems) line\(problems == 1 ? "" : "s") skipped") }
        let v = view == "running" ? "in force" : view == "pending" ? "from its next session or wake" : "when it runs"
        return parts.joined(separator: " · ") + " — " + v
    }
}

/// `workspace-rules`: everything about one sandbox's rules.
public struct WorkspaceRulesReport: Codable, Equatable, Sendable {
    public var sandbox: String
    /// The Mac folder shared at `guestPath` (nil: isolated — nothing to rule).
    public var workspace: String?
    public var guestPath: String
    /// A rule file is in the folder.
    public var active: Bool
    public var mode: String
    /// Where the mode comes from: `sandbox` (its own choice), `flag`, `env`, `file` or `default`.
    public var modeSource: String
    public var caseInsensitive: Bool
    public var ignore: [WorkspaceRules.Rule]
    public var readOnly: [WorkspaceRules.Rule]
    public var problems: [WorkspaceRules.Problem]
    /// See `WorkspaceRulesInfo.view`; `failed` when the guest has a view that does not run.
    public var view: String
    /// The guest daemon's own state (requests, restarts, rules it holds…) when it runs.
    public var viewState: [String: String]?
    public var checks: [WorkspaceRules.Decision]?
    public var warnings: [String]?
}

extension HostCore {
    /// 608: `workspace.view` for a sandbox (its own value wins) — on unless it says off.
    static func workspaceViewOn(_ cfg: SandboxConfig, settings: @autoclosure () -> DozerSettings = .load()) -> Bool {
        sandboxValue(cfg, SettingKey.workspaceView, settings: settings()) != .string("off")
    }

    /// 608: `SandboxInfo.workspaceView` — pure, so it is unit-tested.
    static func workspaceViewState(running: Bool, workspace: Bool, active: [WorkspaceViewConfig], fallbacks: Set<String>, viewOn: Bool) -> String? {
        guard running, workspace else { return nil }
        if !active.isEmpty { return active.contains { !$0.isPassthrough } ? "rules" : "live" }
        if !fallbacks.isEmpty { return "fallback" }
        return viewOn ? "next-start" : "direct"
    }

    /// The mode for a sandbox and where it comes from.
    static func ruleMode(_ cfg: SandboxConfig, settings: DozerSettings = .load()) -> (mode: WorkspaceRuleMode, source: String) {
        if case .string(let s)? = cfg.settings?[SettingKey.ignoreMode], let m = WorkspaceRuleMode(rawValue: s) { return (m, "sandbox") }
        let r = settings.resolve(SettingKey.ignoreMode)
        if case .string(let s) = r.value, let m = WorkspaceRuleMode(rawValue: s) { return (m, r.source.rawValue) }
        return (.lock, "default")
    }

    /// The rules of a sandbox's workspace folder (nil: isolated, or no rule file there).
    func workspaceRules(_ m: Managed) -> WorkspaceRules? {
        guard let w = m.config.workspace else { return nil }
        let folder = URL(fileURLWithPath: w)
        guard WorkspaceRules.present(in: folder) else { return nil }
        return WorkspaceRules.load(folder: folder, mode: Self.ruleMode(m.config).mode)
    }

    func workspaceRulesInfo(_ m: Managed, phase: Phase) -> WorkspaceRulesInfo? {
        guard let rules = workspaceRules(m) else { return nil }
        let sum = rules.summary
        let view = phase != .running ? "stopped" : m.sandbox.activeViews.isEmpty ? "pending" : "running"
        return WorkspaceRulesInfo(mode: sum.mode.rawValue, ignorePatterns: sum.ignorePatterns, readOnlyPatterns: sum.readOnlyPatterns,
                                  ignoreFile: sum.ignoreFile, readOnlyFile: sum.readOnlyFile, problems: sum.problems,
                                  caseInsensitive: sum.fold, view: view)
    }

    func workspaceRulesReport(_ r: HostRequest) async throws -> WorkspaceRulesReport {
        let m = try get(r.name)
        let (mode, source) = Self.ruleMode(m.config)
        let guestPath = DozerImages.workspaceGuestPath
        var rep = WorkspaceRulesReport(sandbox: m.name, workspace: m.config.workspace, guestPath: guestPath, active: false,
                                       mode: mode.rawValue, modeSource: source, caseInsensitive: true, ignore: [], readOnly: [],
                                       problems: [], view: "stopped")
        guard let w = m.config.workspace else {
            if r.paths?.isEmpty == false { throw HostError(.invalid, "\(m.name) is isolated — no folder of this Mac is shared, so no rule applies") }
            return rep
        }
        let folder = URL(fileURLWithPath: w)
        let rules = WorkspaceRules.load(folder: folder, mode: mode)
        rep.active = rules.active
        rep.caseInsensitive = rules.fold
        rep.ignore = rules.ignore
        rep.readOnly = rules.readOnly
        rep.problems = rules.problems
        let phase = await effectivePhase(m)
        if phase == .running, !readOnly {
            let guest = await m.sandbox.workspaceViewReport()
            if let mine = guest.first(where: { $0.status.state != .off }) {
                rep.view = mine.status.state == .failed ? "failed" : "running"
                rep.viewState = mine.state.isEmpty ? nil : mine.state
            } else {
                rep.view = rules.active ? "pending" : "off"
            }
        } else if phase == .running {
            rep.view = rules.active ? "pending" : "off"
        } else if !rules.active {
            rep.view = "off"
        }
        if let paths = r.paths, !paths.isEmpty {
            var e = WorkspaceRules.Evaluator(rules)
            rep.checks = try paths.map { p in
                let rel = try Self.relativeWorkspacePath(p, folder: folder, guestPath: guestPath)
                return e.decide(rel) { prefix in
                    var isDir: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: folder.appendingPathComponent(prefix).path, isDirectory: &isDir)
                    return exists ? isDir.boolValue : prefix != rel || p.hasSuffix("/")
                }
            }
        }
        if r.warnings == true, rules.active { rep.warnings = WorkspaceWarnings.compute(folder: folder, rules: rules) }
        return rep
    }

    /// A path a person typed → relative to the workspace folder: `/workspace/a/b`, the Mac's
    /// `/Users/…/project/a/b` (inside the folder), or `a/b` as it is.
    static func relativeWorkspacePath(_ p: String, folder: URL, guestPath: String) throws -> String {
        var s = p
        if s == guestPath || s.hasPrefix(guestPath + "/") { s = String(s.dropFirst(guestPath.count)) }
        else if s.hasPrefix("/") || s.hasPrefix("~") {
            let abs = URL(fileURLWithPath: (s as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
            let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
            guard abs == root || abs.hasPrefix(root + "/") else {
                throw HostError(.invalid, "\(p) is not inside the workspace folder \(folder.path)")
            }
            s = String(abs.dropFirst(root.count))
        }
        while s.hasPrefix("/") { s.removeFirst() }
        while s.hasPrefix("./") { s.removeFirst(2) }
        if s.split(separator: "/").contains("..") { throw HostError(.invalid, "\(p): a path inside the workspace, without ..") }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

/// The warnings at create / up / start and in `doz ignore show` — never fatal.
public enum WorkspaceWarnings {
    /// At most this many tracked files are looked at (a moment on any repository).
    public static let trackedLimit = 200_000
    /// At most this many entries of the folder are walked for the "anchored at the root" warning.
    public static let walkLimit = 20_000

    public static func compute(folder: URL, rules: WorkspaceRules, gitFiles: [String]? = nil) -> [String] {
        var out: [String] = []
        for p in rules.problems {
            out.append("\(p.file) line \(p.line) (`\(p.text)`) is not a valid pattern (\(p.reason)) — it is skipped")
        }
        var e = WorkspaceRules.Evaluator(rules)
        func isDir(_ rel: String) -> Bool {
            var d: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder.appendingPathComponent(rel).path, isDirectory: &d) && d.boolValue
        }
        let gitDir = folder.appendingPathComponent(".git")
        let hasGit = FileManager.default.fileExists(atPath: gitDir.path)
        if hasGit {
            let d = e.decide(".git") { _ in true }
            if d.verdict == .locked || d.verdict == .hidden {
                out.append("`.git` is \(d.verdict.rawValue) by \(d.rule?.label ?? "the rules") — git cannot work in the sandbox")
            } else if d.verdict == .readOnly, d.rule?.file != nil {
                out.append("`.git` is read-only by \(d.rule!.label) — git status works in the sandbox, but commit, fetch and checkout fail")
            }
        }
        let tracked = gitFiles ?? (hasGit ? gitLsFiles(folder) : nil) ?? []
        var blocked: [String] = [], ro: [String] = []
        for f in tracked.prefix(trackedLimit) {
            let d = e.decide(f) { $0 != f }
            switch d.verdict {
            case .locked, .hidden: blocked.append(f)
            case .readOnly where d.rule?.file != nil && !d.ruleFile: ro.append(f)
            default: break
            }
        }
        func examples(_ v: [String]) -> String { v.prefix(3).joined(separator: ", ") + (v.count > 3 ? ", …" : "") }
        if !blocked.isEmpty {
            let what = rules.mode == .hide ? "hidden" : "locked"
            out.append("\(blocked.count) git-tracked file\(blocked.count == 1 ? " is" : "s are") \(what) by .dozignore (\(examples(blocked))): git status in the sandbox shows \(blocked.count == 1 ? "it" : "them") as deleted, and git commit -a or git add -A there would record \(blocked.count == 1 ? "its" : "their") deletion")
        }
        if !ro.isEmpty {
            out.append("\(ro.count) git-tracked file\(ro.count == 1 ? " is" : "s are") read-only by .dozreadonly (\(examples(ro))): a checkout, pull or merge in the sandbox that changes \(ro.count == 1 ? "it" : "them") fails")
        }
        out += anchoredWarnings(folder: folder, rules: rules, tracked: tracked, evaluator: &e, isDir: isDir)
        return out
    }

    /// Docker's patterns are anchored at the root (unlike .gitignore): `node_modules` hides only the top one.
    static func anchoredWarnings(folder: URL, rules: WorkspaceRules, tracked: [String], evaluator e: inout WorkspaceRules.Evaluator,
                                 isDir: (String) -> Bool) -> [String] {
        let candidates = (rules.ignore + rules.readOnly).filter { r in
            r.file != nil && !r.isException && !r.pattern.contains("/") && !r.pattern.hasPrefix("**")
        }
        guard !candidates.isEmpty else { return [] }
        // The paths below the top: tracked files and their folders, then a bounded walk of the folder.
        var deep = Set<String>()
        for f in tracked.prefix(trackedLimit) {
            let comps = f.split(separator: "/")
            guard comps.count >= 2 else { continue }
            for i in 2...comps.count { deep.insert(comps[..<i].joined(separator: "/")) }
        }
        if let en = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) {
            var n = 0
            let root = folder.standardizedFileURL.path
            for case let url as URL in en {
                n += 1
                if n > walkLimit { break }
                if url.lastPathComponent == ".git" { en.skipDescendants(); continue }
                let rel = String(url.standardizedFileURL.path.dropFirst(root.count + 1))
                if rel.contains("/") { deep.insert(rel) }
                if en.level > 6 { en.skipDescendants() }
            }
        }
        var out: [String] = []
        for r in candidates {
            guard let m = try? DockerIgnore(patterns: [r.pattern]), let pat = m.patterns.first else { continue }
            let file = r.file ?? WorkspaceRules.ignoreFile
            let isIgnore = file == WorkspaceRules.ignoreFile
            let hit = deep.sorted().first { path in
                guard let last = path.split(separator: "/").last, (try? pat.match(String(last))) == true else { return false }
                let d = e.decide(path, isDirectory: isDir)
                // already covered by another rule: no warning
                return isIgnore ? !(d.verdict == .locked || d.verdict == .hidden) : d.verdict != .readOnly
            }
            if let hit {
                out.append("`\(r.pattern)` (\(file) line \(r.line ?? 0)) matches only at the top of the workspace — these rules are Docker's, anchored at the root (unlike .gitignore); write `**/\(r.pattern)` to match it at any depth (it also exists at \(hit))")
            }
        }
        return out
    }

    /// `git ls-files -z` in the folder, read-only — nil when git is not there (never the Xcode install
    /// dialog: /usr/bin/git only when the developer tools are installed) or it fails.
    static func gitLsFiles(_ folder: URL) -> [String]? {
        guard let git = gitPath() else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", folder.path, "ls-files", "-z"]
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    static func gitPath() -> String? {
        let fm = FileManager.default
        for p in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: p) { return p }
        // /usr/bin/git is a shim that opens the developer tools' installer when they are missing.
        if fm.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git") || developerDirectory() != nil { return "/usr/bin/git" }
        return nil
    }

    static func developerDirectory() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !s.isEmpty && FileManager.default.fileExists(atPath: s + "/usr/bin/git") ? s : nil
    }
}
