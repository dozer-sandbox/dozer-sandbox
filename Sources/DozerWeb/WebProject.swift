import CryptoKit
import Foundation
import DozerKit
import DozerHost

// 599f (owner, 2026-10-02: "a new wizard process for creating a purposeful sandbox that steps the user
// through all the choices, capturing the config in a doz_project.yml in the project / working dir"):
//
//   · `POST /api/v1/project/open` {folder} — changes nothing: the folder (normalized; whether it exists),
//     its project file (doz_project.yaml or .yml — both is an error) read into the wizard's form, or the
//     defaults; the steps (`ProjectWizard.steps`, the same list `doz init` walks); 599g: its rule files.
//   · `POST /api/v1/project/preview` {folder, form, explicit} — changes nothing: the EXACT file the wizard
//     will write (`DozerProject.render`, read back by the CLI's own parser — one validator), the file there
//     now and the line diff, and the digest a write must name to replace it.
//   · `POST /api/v1/project/write` {folder, form, explicit, replace?} — makes the folder (as a workspace
//     is made) and writes the file; an existing file only when `replace` is its digest (the page showed the
//     diff and the person confirmed) — anything else is 409.
//   · the action `project-create` {folder} — the sandbox the folder's project file describes, made with
//     the options `doz up` would give it (`DozerProject.createOptions`).
//
// The YAML is READ by the CLI's parser (Yams stays in the CLI's commands): `doz ui` installs it here.

/// Reads a project file's text (`DozerCLI`'s parser): the text and the file's name (for its messages).
public typealias WebProjectParser = @Sendable (_ text: String, _ file: String) throws -> DozerProject

public enum WebProjectFiles {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: WebProjectParser?

    /// `doz ui` (and tests) install the parser before serving.
    public static func install(_ p: @escaping WebProjectParser) { lock.withLock { installed = p } }

    static func parse(_ text: String, file: String) throws -> DozerProject {
        guard let p = lock.withLock({ installed }) else { throw HostError(.unavailable, "this doz ui cannot read project files") }
        return try p(text, file)
    }

    /// The folder's project file and its text (nil: none). Both spellings → Invalid.
    static func existing(_ folder: String) throws -> (url: URL, text: String)? {
        guard let u = try DozerProject.find(in: URL(fileURLWithPath: folder)) else { return nil }
        guard let d = FileManager.default.contents(atPath: u.path), d.count <= DozerProject.maximumBytes,
              let t = String(data: d, encoding: .utf8) else { throw HostError(.invalid, "\(u.path) cannot be read (UTF-8, at most 64 KiB)") }
        return (u, t)
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The wizard's choices, as the page sends and gets them (plain values; every one optional but the name
/// and the image). Decoded strictly.
public struct WebProjectForm: Codable, Equatable, Sendable {
    public struct Session: Codable, Equatable, Sendable {
        public var name: String
        public var command: [String]?
    }
    public var name: String
    public var image: String
    public var agent: String?
    public var base: String?
    public var dockerfile: String?
    public var account: String?
    public var github: String?
    public var sshAgent: String?
    public var network: String?
    public var permissions: String?
    public var cpus: Int?
    public var memory: String?
    public var clipboard: String?
    public var browserBridge: String?
    public var openFiles: String?
    public var tmux: Bool?
    public var ignoreMode: String?
    /// 608: `workspace_view` — kept through the dashboard (no control of its own in the wizard).
    public var workspaceView: String?
    public var agentSudo: Bool?
    public var agentPrompt: String?
    public var agentPromptMode: String?
    public var sessions: [Session]?

    static let settingFields: [(field: String, setting: String)] = [
        ("sshAgent", SettingKey.sshAgent), ("clipboard", SettingKey.clipboard), ("browserBridge", SettingKey.browserBridge),
        ("openFiles", SettingKey.openFiles), ("tmux", SettingKey.tmux), ("ignoreMode", SettingKey.ignoreMode),
        ("workspaceView", SettingKey.workspaceView),
    ]

    public init(_ p: DozerProject) {
        name = p.name
        image = p.image
        agent = p.agent
        base = p.base
        dockerfile = p.dockerfile
        account = p.account
        github = p.github
        network = p.network
        permissions = p.permissions?.joined(separator: ",")
        cpus = p.cpus
        memory = p.memoryMiB.map { $0 % 1024 == 0 ? "\($0 / 1024)G" : "\($0)M" }
        sshAgent = p.settings[SettingKey.sshAgent]?.plain
        clipboard = p.settings[SettingKey.clipboard]?.plain
        browserBridge = p.settings[SettingKey.browserBridge]?.plain
        openFiles = p.settings[SettingKey.openFiles]?.plain
        if case .bool(let b)? = p.settings[SettingKey.tmux] { tmux = b }
        ignoreMode = p.settings[SettingKey.ignoreMode]?.plain
        workspaceView = p.settings[SettingKey.workspaceView]?.plain
        agentSudo = p.agentSudo
        agentPrompt = p.agentPrompt
        agentPromptMode = p.agentPromptMode
        sessions = p.sessions.isEmpty ? nil : p.sessions.map { Session(name: $0.name, command: $0.command) }
    }

    /// The project these choices make (each value checked by its own rule; the whole by the parser).
    public func project() throws -> DozerProject {
        func invalid(_ m: String) -> WebAction.Invalid { WebAction.Invalid(m) }
        var p = DozerProject(name: name, image: image)
        if agent != nil || base != nil || dockerfile != nil {
            p.agent = agent
            p.base = base
            p.dockerfile = dockerfile
            p.image = p.chosenImage
        }
        p.account = account
        p.github = github
        p.network = network
        if let w = permissions {
            guard let words = SettingType.permissionWords(w) else { throw invalid("permissions: standard, locked, open, or changes like +web,-error-reports") }
            p.permissions = words
        }
        p.cpus = cpus
        if let m = memory {
            guard let v = DozerImages.parseMemory(m) else { throw invalid("memory: a size like 2G or 512M") }
            p.memoryMiB = v
        }
        for (field, key) in [("sshAgent", sshAgent), ("clipboard", clipboard), ("browserBridge", browserBridge), ("openFiles", openFiles),
                             ("ignoreMode", ignoreMode), ("workspaceView", workspaceView)] {
            guard let v = key, let s = Self.settingFields.first(where: { $0.field == field }), let d = DozerSettings.definition(s.setting) else { continue }
            do { p.settings[s.setting] = try d.parse(v) } catch let e as SettingsError { throw invalid("\(field): \(e.message)") }
        }
        if let t = tmux { p.settings[SettingKey.tmux] = .bool(t) }
        p.agentSudo = agentSudo
        p.agentPrompt = agentPrompt
        p.agentPromptMode = agentPromptMode
        p.sessions = (sessions ?? []).map { DozerProject.Session(name: $0.name, command: $0.command) }
        return p
    }
}

/// What `open` answers.
public struct WebProjectOpen: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable { public var id: String; public var title: String }
    public var folder: String
    public var exists: Bool
    /// The project file there (its name), and its text.
    public var file: String?
    public var text: String?
    /// The form: from the file, or the defaults (a name from the folder's, `defaults.image`).
    public var form: WebProjectForm
    /// The form's keys the file sets (kept as set, even when equal to a default).
    public var explicit: [String]
    /// Why the folder cannot be used, or its file not read (the wizard says it and stops).
    public var error: String?
    public var steps: [Step]
    /// `defaults.projects_dir`, expanded.
    public var projectsDir: String
    /// 599g: the folder's .dozignore / .dozreadonly (empty: none, or a folder not made yet), and the words of the
    /// Workspace rules step.
    public var rules: [WebRuleFile] = []
    public var rulesGuide = WebRulesGuide()
}

/// What `preview` and `write` answer.
public struct WebProjectPreview: Codable, Equatable, Sendable {
    public var folder: String
    /// The file it writes (an existing one keeps its spelling).
    public var path: String
    public var text: String
    /// The file there now, the diff (`"  "`, `"- "`, `"+ "` lines), and its digest — `write`'s `replace`.
    public var existing: String?
    public var diff: [String]?
    public var replace: String?
    public var written: Bool?
}

/// The bodies, decoded strictly.
struct WebProjectRequest {
    var folder: String
    var form: WebProjectForm?
    var explicit: Set<String> = []
    var replace: String?

    static let explicitKeys: Set<String> = Set<String>(["cpus", "memory", "network", "permissions", "account", "github", "agent_sudo", "image"])
        .union(DozerProject.settingKeys.map(\.key))

    static func decode(_ body: Data, allowed: Set<String>) throws -> WebProjectRequest {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        guard Set(d.keys).isSubset(of: allowed) else { throw WebAction.Invalid("only " + allowed.sorted().joined(separator: ", ")) }
        guard let f = d["folder"] as? String, f.count <= 1024, !f.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw WebAction.Invalid("folder: a path (one line)")
        }
        var r = WebProjectRequest(folder: f)
        if let form = d["form"] {
            guard let fd = form as? [String: Any] else { throw WebAction.Invalid("form: an object") }
            let known: Set<String> = ["name", "image", "agent", "base", "dockerfile", "account", "github", "sshAgent", "network", "permissions", "cpus",
                                      "memory", "clipboard", "browserBridge", "openFiles", "tmux", "ignoreMode", "workspaceView", "agentSudo", "agentPrompt", "agentPromptMode", "sessions"]
            let unknown = Set(fd.keys).subtracting(known)
            guard unknown.isEmpty else { throw WebAction.Invalid("form: no \(unknown.sorted().joined(separator: ", "))") }
            do { r.form = try JSONDecoder().decode(WebProjectForm.self, from: JSONSerialization.data(withJSONObject: fd)) } catch {
                throw WebAction.Invalid("form: \(error.localizedDescription)")
            }
        }
        if let e = d["explicit"] {
            guard let a = e as? [String], a.count <= 32, Set(a).isSubset(of: explicitKeys) else { throw WebAction.Invalid("explicit: the file's keys") }
            r.explicit = Set(a)
        }
        if let rep = d["replace"], !(rep is NSNull) {
            guard let s = rep as? String, s.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw WebAction.Invalid("replace: a digest") }
            r.replace = s
        }
        return r
    }

    /// The folder, normalized (absolute or ~/…; links in the existing part resolved).
    func normalizedFolder() throws -> String { try Workspace.normalize(folder) }
}

enum WebProject {
    static func open(_ q: WebProjectRequest, settings: DozerSettings, store: String) -> WebProjectOpen {
        let projects = (Workspace.defaultPath(name: "x", settings: settings) as NSString).deletingLastPathComponent
        let steps = ProjectWizard.steps.map { WebProjectOpen.Step(id: $0.id, title: $0.title) }
        let image = settings.string(SettingKey.defaultImage) ?? "lab"
        var out = WebProjectOpen(folder: q.folder, exists: false, file: nil, text: nil,
                                 form: WebProjectForm(DozerProject(name: "project", image: image)), explicit: [], error: nil, steps: steps,
                                 projectsDir: projects)
        let folder: String
        do { folder = try q.normalizedFolder() } catch { out.error = HostError.from(error).message; return out }
        out.folder = folder
        out.form = WebProjectForm(DozerProject(name: DozerProject.suggestedName(for: URL(fileURLWithPath: folder)), image: image))
        if let why = Workspace.refusal(folder, store: DozerStore(root: URL(fileURLWithPath: store))) { out.error = why; return out }
        var isDir: ObjCBool = false
        out.exists = FileManager.default.fileExists(atPath: folder, isDirectory: &isDir) && isDir.boolValue
        if out.exists { out.rules = WorkspaceRulesGuide.folderFiles(URL(fileURLWithPath: folder)).map(WebRuleFile.init) }
        do {
            guard let (url, text) = try WebProjectFiles.existing(folder) else { return out }
            out.file = url.lastPathComponent
            out.text = text
            let p = try WebProjectFiles.parse(text, file: url.lastPathComponent)
            out.form = WebProjectForm(p)
            var e: [String] = []
            if p.cpus != nil { e.append("cpus") }
            if p.memoryMiB != nil { e.append("memory") }
            if p.network != nil { e.append("network") }
            if p.permissions != nil { e.append("permissions") }
            if p.account != nil { e.append("account") }
            if p.github != nil { e.append("github") }
            if p.agentSudo != nil { e.append("agent_sudo") }
            for k in DozerProject.settingKeys where p.settings[k.setting] != nil { e.append(k.key) }
            out.explicit = e
        } catch {
            out.error = (error as? DozerProject.Invalid)?.message ?? HostError.from(error).message
        }
        return out
    }

    /// The file the form makes, checked as `doz init` checks it, and what is there now.
    static func preview(_ q: WebProjectRequest, settings: DozerSettings, store: String, taken: Set<String>) throws -> (WebProjectPreview, DozerProject) {
        guard let form = q.form else { throw WebAction.Invalid("form: required") }
        let folder = try q.normalizedFolder()
        if let why = Workspace.refusal(folder, store: DozerStore(root: URL(fileURLWithPath: store))) { throw HostError(.invalid, why) }
        var p = try form.project()
        p.dropDefaults(settings: settings, explicit: q.explicit)
        if let why = p.problem(effectiveNetwork: p.effectiveNetwork(settings: settings)) { throw HostError(.invalid, why) }
        let existing = try WebProjectFiles.existing(folder)
        if taken.contains(p.name) {
            throw HostError(.exists, "a sandbox named \(p.name) exists — pick another name (doz up in its folder attaches to it)")
        }
        let text = p.render()
        // The CLI's own parser reads it back: what the review shows is what `doz up` will read.
        let back: DozerProject
        do { back = try WebProjectFiles.parse(text, file: existing?.url.lastPathComponent ?? DozerProject.fileName) } catch let e as DozerProject.Invalid {
            throw HostError(.invalid, e.message)
        }
        let path = existing?.url.path ?? (folder as NSString).appendingPathComponent(DozerProject.fileName)
        var out = WebProjectPreview(folder: folder, path: path, text: text)
        if let e = existing {
            out.existing = e.text
            out.diff = DozerProject.lineDiff(old: e.text, new: text)
            out.replace = WebProjectFiles.digest(e.text)
        }
        return (out, back)
    }

    static func write(_ q: WebProjectRequest, settings: DozerSettings, store: String, taken: Set<String>) throws -> WebProjectPreview {
        var (out, _) = try preview(q, settings: settings, store: store, taken: taken)
        if let have = out.replace, have != q.replace {
            throw HostError(.exists, "\(out.path) exists — confirm replacing it (the page shows what changes)")
        }
        if out.existing == out.text { out.written = false; return out }
        let prepared = try Workspace.prepare(out.folder, store: DozerStore(root: URL(fileURLWithPath: store)))
        do { try Data(out.text.utf8).write(to: URL(fileURLWithPath: out.path), options: .atomic) } catch {
            Workspace.undo(prepared)
            throw HostError(.failed, "could not write \(out.path): \(error.localizedDescription)")
        }
        out.written = true
        return out
    }

    /// The action `project-create`: the sandbox the folder's file describes, as `doz up` makes it.
    static func createAction(folder raw: String, settings: DozerSettings? = nil) throws -> WebAction {
        let folder = try Workspace.normalize(raw)
        guard let (url, text) = try WebProjectFiles.existing(folder) else { throw HostError(.notFound, "\(folder) has no \(DozerProject.fileName)") }
        let p: DozerProject
        do { p = try WebProjectFiles.parse(text, file: url.lastPathComponent) } catch let e as DozerProject.Invalid { throw HostError(.invalid, e.message) }
        return .create(name: p.name, options: p.createOptions(folder: URL(fileURLWithPath: folder), file: url, settings: settings))
    }
}
