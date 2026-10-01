import Foundation
import DozerKit
import DozerHost

// 594 (owner, 2026-09-29): "need an easier way to pick a workspace folder ; and it should pick a
// default location ~/Developer/dozer-sandbox-projects/[SANDBOX-NAME] and also pick a better default
// name for the sandbox like "claude-sandbox""; "i dont want the user to have to create the path first".
//
//   · `POST /api/v1/workspace/check` {image?, name?, path?} — changes nothing: the new sandbox's
//     suggested name (from the image; -2, -3 when taken), its default folder (<defaults.projects_dir>/
//     <name>), and for a typed path whether it exists, will be created, or is refused (and why).
//   · `POST /api/v1/workspace/choose` {start?} — the MAC's folder picker (a fixed AppleScript run by
//     /usr/bin/osascript: `choose folder`, New Folder allowed, brought to the front), opened where the
//     field points (its nearest existing folder) or at the projects folder. One at a time — a second
//     is refused (409). The request's path is an ARGUMENT of the fixed script, never code; the answer is
//     a path string or "cancelled". Tests never show it: DOZ_TEST_FOLDER_PICKER=/some/path|cancel.

/// The check's question, decoded strictly: at most {image, name, path}.
public struct WebWorkspaceQuery: Equatable, Sendable {
    public var image: String?
    public var name: String?
    public var path: String?

    public static func decode(_ body: Data) throws -> WebWorkspaceQuery {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        guard Set(d.keys).isSubset(of: ["image", "name", "path"]) else { throw WebAction.Invalid("only image, name and path") }
        func text(_ k: String, max: Int) throws -> String? {
            guard let v = d[k], !(v is NSNull) else { return nil }
            guard let s = v as? String, s.count <= max, !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
                throw WebAction.Invalid("\(k): one line of at most \(max) characters")
            }
            return s
        }
        var q = WebWorkspaceQuery()
        q.image = try text("image", max: 64)
        if let i = q.image, i.range(of: #"^(custom:)?[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) == nil {
            throw WebAction.Invalid("image: an image name")
        }
        q.name = try text("name", max: 40)
        q.path = try text("path", max: 1024)
        return q
    }
}

/// The check's answer.
public struct WebWorkspaceCheck: Codable, Equatable, Sendable {
    /// The new sandbox's suggested name (for `image`, not taken).
    public var suggestedName: String
    /// `<projects_dir>/<name>` — `name` when given, else the suggested one.
    public var defaultPath: String
    /// `defaults.projects_dir`, expanded.
    public var projectsDir: String
    /// The typed path, normalized (nil when none was given).
    public var path: String?
    public var exists: Bool?
    /// It does not exist and would be made at create time.
    public var willCreate: Bool?
    /// Why it cannot be the workspace (nothing is made).
    public var error: String?

    public static func check(_ q: WebWorkspaceQuery, taken: Set<String>, settings: DozerSettings, store: String) -> WebWorkspaceCheck {
        let projects = Workspace.defaultPath(name: "x", settings: settings)
        let projectsDir = (projects as NSString).deletingLastPathComponent
        let suggested = Workspace.suggestedName(image: q.image ?? settings.string(SettingKey.defaultImage) ?? "claude-code",
                                                taken: taken, projects: projectsDir)
        let name = q.name.flatMap { $0.isEmpty ? nil : $0 } ?? suggested
        var r = WebWorkspaceCheck(suggestedName: suggested, defaultPath: (projectsDir as NSString).appendingPathComponent(name), projectsDir: projectsDir)
        guard let raw = q.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return r }
        guard raw.hasPrefix("/") || raw.hasPrefix("~/") || raw == "~" else {
            r.error = "an absolute path (/…) or ~/… — not a relative one"
            return r
        }
        do {
            let p = try Workspace.normalize(raw)
            r.path = p
            if let why = Workspace.refusal(p, store: DozerStore(root: URL(fileURLWithPath: store))) { r.error = why; return r }
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
            r.exists = exists
            r.willCreate = exists ? nil : true
        } catch {
            r.error = HostError.from(error).message
        }
        return r
    }
}

/// The picker's answer: a folder, or cancelled.
public struct WebFolderChoice: Codable, Equatable, Sendable {
    public var path: String?
    public var cancelled: Bool
}

/// The Mac's folder picker, one at a time.
public final class WebFolderPicker: @unchecked Sendable {
    public typealias Runner = @Sendable (_ start: String) async throws -> String?

    private let lock = NSLock()
    private var open = false
    /// nil: the Mac's dialog (osascript), with the prompt of the call.
    private var run: Runner?

    /// The dialog's prompts — fixed texts, chosen by the route (never the request's words).
    public static let workspacePrompt = "Choose the folder to share at /workspace"
    /// 599c: the Settings page's Choose… for `defaults.projects_dir`.
    public static let projectsPrompt = "Choose the folder where new sandboxes get their workspace folders"

    /// `run` shows the picker at `start` and returns the chosen folder (nil: cancelled). The default:
    /// the environment's test seam when set, else osascript.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment, run: Runner? = nil) {
        if let run { self.run = run; return }
        if let seam = environment["DOZ_TEST_FOLDER_PICKER"] {
            self.run = { _ in seam == "cancel" ? nil : seam }
        }
    }

    /// Tests: what "showing the picker" does.
    public func setRunner(_ r: @escaping Runner) { lock.withLock { run = r } }

    public var isOpen: Bool { lock.withLock { open } }

    /// The body, strictly: at most {start} (an absolute path or ~/…; it need not exist).
    public static func decodeStart(_ body: Data) throws -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        guard Set(d.keys).isSubset(of: ["start"]) else { throw WebAction.Invalid("only start") }
        guard let v = d["start"], !(v is NSNull) else { return nil }
        guard let s = v as? String, s.count <= 1024, !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw WebAction.Invalid("start: one line of at most 1024 characters")
        }
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        guard t.hasPrefix("/") || t.hasPrefix("~/") else { throw WebAction.Invalid("start: an absolute path or ~/…") }
        return t
    }

    /// Where the picker opens: the nearest existing folder of `start`, else of the projects folder,
    /// else the home folder.
    public static func startFolder(_ start: String?, projectsDir: String) -> String {
        for candidate in [start, projectsDir].compactMap({ $0 }) {
            guard var u = try? URL(fileURLWithPath: Workspace.normalize(candidate)) else { continue }
            while u.path != "/" {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { return u.path }
                u = u.deletingLastPathComponent()
            }
        }
        return Workspace.home()
    }

    public func choose(start: String, prompt: String = WebFolderPicker.workspacePrompt) async throws -> WebFolderChoice {
        let runner: Runner? = lock.withLock {
            if open { return nil }
            open = true
            return run ?? { s in try await Self.osascript(s, prompt) }
        }
        guard let runner else { throw WebRejection.pickerOpen }
        defer { lock.withLock { open = false } }
        let chosen = try await runner(start)
        guard let chosen, !chosen.isEmpty else { return WebFolderChoice(path: nil, cancelled: true) }
        var p = chosen
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return WebFolderChoice(path: p, cancelled: false)
    }

    /// The fixed script: the start folder and the prompt (one of the fixed prompts above) are its
    /// arguments (`argv`), never part of its text.
    static let script = """
        on run argv
          activate
          try
            set f to choose folder with prompt (item 2 of argv) default location (POSIX file (item 1 of argv))
            return POSIX path of f
          on error number -128
            return ""
          end try
        end run
        """

    /// At most 10 minutes open; then it is closed as cancelled.
    static func osascript(_ start: String, _ prompt: String) async throws -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script, start, prompt]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(600)
        while p.isRunning {
            if Date() > deadline { p.terminate(); break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .newlines)
        guard p.terminationReason == .exit, p.terminationStatus == 0, text.hasPrefix("/") else { return nil }
        return text
    }
}
