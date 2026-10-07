import Darwin
import Foundation
import DozerKit

// 594 (owner, 2026-09-29: "i dont want the user to have to create the path first"; "pick a default
// location ~/Developer/dozer-sandbox-projects/[SANDBOX-NAME] and … a better default name"):
//
//   · A workspace folder that does not exist is CREATED — everywhere (the UI's forms, `doz create/up/
//     duplicate --workspace`) — `mkdir -p` with the user's own permissions, at create time, before the
//     VM is configured; and removed again only if Dozer made it, it is still empty, and the create failed.
//   · Refused, never created: an existing FILE; `/` or the home folder itself; a relative path. And a
//     folder that would have to be created inside the store, or under a system location (/System, /usr,
//     /bin, /sbin, /private/var, /Library, …). (An EXISTING folder there is shared as before.)
//   · A new sandbox's defaults (the UI): its name from the image — claude-sandbox, pi-sandbox,
//     lab-sandbox; taken → -2, -3, … — and its folder `<defaults.projects_dir>/<name>`.
//   · No workspace is "isolated": nothing on the Mac is shared; /workspace is private to the sandbox.

public enum Workspace {
    /// Where a folder is never created (resolved; /var, /etc and /tmp are links into /private).
    public static let systemPrefixes = ["/System", "/usr", "/bin", "/sbin", "/private/var", "/private/etc", "/Library", "/Applications",
                                        "/cores", "/dev", "/opt", "/Volumes"]

    public struct Prepared: Equatable, Sendable {
        public var path: String
        /// Dozer made it now (and the folders `created` lists, outermost first).
        public var created: Bool { !createdDirectories.isEmpty }
        public var createdDirectories: [String]
    }

    public static func home() -> String {
        (try? normalize(FileManager.default.homeDirectoryForCurrentUser.path)) ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// `~/…` expanded, `.`/`..` removed, links in the existing part resolved (so /tmp → /private/tmp).
    /// A relative path is refused (the CLI makes one absolute against its own working folder first).
    public static func normalize(_ raw: String) throws -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw HostError(.invalid, "the workspace is empty") }
        let expanded = (t as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw HostError(.invalid, "the workspace is an absolute path (or ~/…) — not \(t)") }
        let std = URL(fileURLWithPath: expanded).standardizedFileURL
        // Resolve links in the part that exists; keep the rest as typed.
        var existing = std, rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        // realpath(3), not URL.resolvingSymlinksInPath (which turns /private/tmp back into /tmp — and a
        // system prefix check must see /private/var for /var).
        // (Nor URL.standardized after it, which does the same.)
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        var out = realpath(existing.path, &buf).map { String(cString: $0) } ?? existing.path
        for r in rest { out = (out == "/" ? "" : out) + "/" + r }
        return out
    }

    /// Why `path` (normalized) may not be a workspace, or — when it does not exist — may not be made.
    /// nil: it may.
    public static func refusal(_ path: String, store: DozerStore?) -> String? {
        let home = home()
        if path == "/" { return "the workspace cannot be / (the whole Mac)" }
        if path == home { return "the workspace cannot be your home folder itself — pick a folder in it" }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            guard isDir.boolValue else { return "\(path) is a file, not a folder" }
            guard access(path, R_OK | X_OK) == 0 else { return "\(path) is not readable by you" }
            return nil                                            // an existing folder: shared as before
        }
        // Never MADE: inside the store, or under a system location.
        if let store {
            let root = (try? normalize(store.root.path)) ?? store.root.standardizedFileURL.path
            if path == root || path.hasPrefix(root + "/") { return "\(path) is inside the store — Dozer does not make a workspace there" }
        }
        for p in systemPrefixes where path == p || path.hasPrefix(p + "/") {
            return "\(path) is under \(p), a system location — Dozer does not make a workspace there"
        }
        return nil
    }

    /// The workspace as it will be shared: normalized, checked, and made (`mkdir -p`) when missing.
    public static func prepare(_ raw: String, store: DozerStore?) throws -> Prepared {
        let path = try normalize(raw)
        if let why = refusal(path, store: store) { throw HostError(.invalid, why) }
        var missing: [String] = []
        var u = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: u.path), u.path != "/" {
            missing.insert(u.path, at: 0)
            u = u.deletingLastPathComponent()
        }
        guard !missing.isEmpty else { return Prepared(path: path, createdDirectories: []) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else {
            throw HostError(.invalid, "\(u.path) is a file, not a folder")
        }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            undo(Prepared(path: path, createdDirectories: missing))
            throw HostError(.failed, "could not create \(path): \(error.localizedDescription)")
        }
        return Prepared(path: path, createdDirectories: missing)
    }

    /// Nothing half-made: the folders `prepare` made, innermost first, each only while still empty.
    public static func undo(_ p: Prepared) {
        for d in p.createdDirectories.reversed() {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? ["?"]
            guard items.isEmpty else { return }
            rmdir(d)
        }
    }

    // MARK: defaults (the UI's forms)

    /// claude-code → claude-sandbox, pi → pi-sandbox, lab → lab-sandbox; a template → <name>-sandbox.
    public static func baseName(image: String) -> String {
        switch image {
        case "claude-code": return "claude-sandbox"
        case "pi": return "pi-sandbox"
        case "lab": return "lab-sandbox"
        case "codex": return "codex-sandbox"          // 599i
        // 596: base × agent — python-claude-sandbox, go-pi-sandbox, debian-sandbox, dockerfile-claude-sandbox.
        case let n where ImageChoice.parse(n)?.name == n:
            let c = ImageChoice.parse(n)!
            let agent = switch c.agent { case .claudeCode: "-claude"; case .pi: "-pi"; case .codex: "-codex"; case .none: "" }
            return (c.isDockerfile ? "dockerfile" : c.base) + agent + "-sandbox"
        default:
            let n = image.hasPrefix("custom:") ? String(image.dropFirst(7)) : image
            let base = String(n.prefix(32)) + "-sandbox"
            return WebNameCheck.isSandboxName(base) ? base : "sandbox"
        }
    }

    /// The base name, or the first of -2, -3, … not taken (by a sandbox, or by a folder under `projects`
    /// that is not empty — a new sandbox's default folder is its own).
    public static func suggestedName(image: String, taken: Set<String>, projects: String? = nil) -> String {
        let base = baseName(image: image)
        func free(_ n: String) -> Bool {
            if taken.contains(n) { return false }
            if let projects {
                let d = (projects as NSString).appendingPathComponent(n)
                if let items = try? FileManager.default.contentsOfDirectory(atPath: d), !items.isEmpty { return false }
            }
            return true
        }
        if free(base) { return base }
        var i = 2
        while !free("\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }

    /// `<projects_dir>/<name>` (the setting, `~` expanded).
    public static func defaultPath(name: String, settings: DozerSettings = .load()) -> String {
        let dir = settings.string(SettingKey.projectsDir) ?? "~/Developer/dozer-sandbox-projects"
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent(name).standardizedFileURL.path
    }

    /// The word, everywhere, for a sandbox with no workspace.
    public static let isolatedNote = "isolated: nothing on this Mac is shared; /workspace is private to the sandbox"
}

/// The library's sandbox-name rule, for the host's defaults.
enum WebNameCheck {
    static func isSandboxName(_ s: String) -> Bool {
        (1...40).contains(s.count) && s.first != "-" && s.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}
