import Foundation
import DozerKit
import DozerHost

// 596 — Dozer Base Images in the web UI (596.01-DESIGN.md B1–B11):
//
//   · `GET /api/v1/bases` — the New Sandbox form's facts: the recommended bases (the host's `bases`,
//     field by field), Apple's container tool as Dozer sees it (`builder-status`: never starts
//     anything), and the sentence the Dockerfile card must say (B9).
//   · `POST /api/v1/dockerfile/choose` {start?} — the MAC's file picker for a Dockerfile (a fixed
//     AppleScript run by /usr/bin/osascript, `choose file`, one at a time — 409), answered with the
//     file and its folder (the build context, which the page puts in the workspace unless changed).
//     Tests never show it: DOZ_TEST_FILE_PICKER=/some/Dockerfile|cancel.
//   · Starting Apple's services and installing it are the typed actions `builder-start` /
//     `builder-install` (one HostOp each), shown only after the page has said what they do.

/// One recommended base, as the page shows it.
public struct WebBase: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var useCase: String
    public var reference: String
    public var digest: String
    public var pinned: Bool
    public var downloadBytes: Int64
    public var prepareSeconds: Int
    public var packageManager: String
    public var registries: [String]
    public var prepared: [String]
    public var updateAvailable: Bool?

    public init(_ r: BaseRow) {
        id = r.id; title = r.title; useCase = r.useCase; reference = r.reference; digest = r.digest; pinned = r.pinned
        downloadBytes = r.downloadBytes; prepareSeconds = r.prepareSeconds; packageManager = r.packageManager
        registries = r.registries; prepared = r.prepared; updateAvailable = r.updateAvailable
    }
}

/// Apple's container tool, as the page shows it (never a path: the page has no use for one).
public struct WebBuilder: Codable, Equatable, Sendable {
    public var state: String
    public var version: String?
    public var note: String
    public var supported: String
    public var startNote: String
    public var installNote: String

    public init(_ s: ContainerToolStatus) {
        state = s.state; version = s.version; note = s.note; supported = s.supported; startNote = s.startNote; installNote = s.installNote
    }
}

public struct WebBases: Codable, Equatable, Sendable {
    public var bases: [WebBase]
    public var builder: WebBuilder
    /// B9: said on the Dockerfile card, in plain words.
    public var outsidePolicy: String
    public var agents: [[String]]
    /// 597 (P4): the permission switches New Sandbox shows (and the Settings page's default) — every
    /// permission, and Standard per base (`""`: a Dockerfile's, system packages only), and the default
    /// set the setting `defaults.permissions` gives per base.
    public var permissions: [WebPermissions.Row] = WebBases.permissionRows
    public var standard: [String: [String]] = WebBases.standardByBase
    public var defaults: [String: [String]] = [:]
    /// 599e: what the Access step's `defaults.github` adds to a new sandbox's permissions (New Sandbox
    /// switches them on too) — `[]`, `["github:as-you"]` or both GitHub ids.
    public var github: [String] = []

    public static var permissionRows: [WebPermissions.Row] {
        AgentPermissions.all.map { p in
            WebPermissions.Row(id: p.id, title: p.title, summary: p.summary, on: false, locked: p.locked, warning: p.warning, group: p.group,
                               hosts: p.hosts.map { $0.host + ($0.pathPrefixes != nil ? " (the agent's own package)" : "") }, standard: false)
        }
    }
    public static var standardByBase: [String: [String]] {
        var m: [String: [String]] = ["": AgentPermissions.preset("agent", base: nil) ?? []]
        for b in BaseCatalogue.ids { m[b] = AgentPermissions.preset("agent", base: b) ?? [] }
        return m
    }

    public static let agentChoices: [[String]] = [["claude-code", "Claude Code"], ["pi", "pi"], ["none", "none — a shell only"]]
}

extension HostWebData {
    public func bases() async throws -> WebBases {
        let rows = try await query(HostRequest(.bases)).0.decode([BaseRow].self)
        let builder = try await query(HostRequest(.builderStatus)).0.decode(ContainerToolStatus.self)
        var b = WebBases(bases: rows.map(WebBase.init), builder: WebBuilder(builder), outsidePolicy: Dockerfiles.outsidePolicyNote,
                         agents: WebBases.agentChoices)
        // 597: what defaults.permissions gives a new sandbox of each base.
        let settings = DozerSettings.load()
        let words = SettingType.permissionWords(settings.string(SettingKey.permissions) ?? "standard") ?? ["standard"]
        b.defaults[""] = PermissionPolicy.names(from: words, base: nil)
        for id in BaseCatalogue.ids { b.defaults[id] = PermissionPolicy.names(from: words, base: id) }
        switch settings.string(SettingKey.defaultGithub) {
        case "read"?: b.github = [AgentPermissions.gitHubAsYou]
        case "push"?: b.github = [AgentPermissions.gitHubAsYou, AgentPermissions.gitHubPush]
        default: break
        }
        return b
    }
}

/// The Dockerfile picker's answer: the file and its folder, or cancelled.
public struct WebFileChoice: Codable, Equatable, Sendable {
    public var path: String?
    public var folder: String?
    public var cancelled: Bool
}

/// The Mac's file picker (a Dockerfile), one at a time.
public final class WebDockerfilePicker: @unchecked Sendable {
    public typealias Runner = @Sendable (_ start: String) async throws -> String?

    private let lock = NSLock()
    private var open = false
    private var run: Runner

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, run: Runner? = nil) {
        if let run { self.run = run; return }
        if let seam = environment["DOZ_TEST_FILE_PICKER"] {
            self.run = { _ in seam == "cancel" ? nil : seam }
        } else {
            self.run = Self.osascript
        }
    }

    public func setRunner(_ r: @escaping Runner) { lock.withLock { run = r } }

    public func choose(start: String) async throws -> WebFileChoice {
        let runner: Runner? = lock.withLock {
            if open { return nil }
            open = true
            return run
        }
        guard let runner else { throw WebRejection.pickerOpen }
        defer { lock.withLock { open = false } }
        guard let chosen = try await runner(start), chosen.hasPrefix("/") else { return WebFileChoice(path: nil, folder: nil, cancelled: true) }
        let p = URL(fileURLWithPath: chosen).standardizedFileURL.path
        return WebFileChoice(path: p, folder: (p as NSString).deletingLastPathComponent, cancelled: false)
    }

    /// The fixed script: the start folder is its only argument (`argv`), never part of its text.
    static let script = """
        on run argv
          activate
          try
            set f to choose file with prompt "Choose the Dockerfile — its folder is the build context (and the workspace, unless you change it)" default location (POSIX file (item 1 of argv))
            return POSIX path of f
          on error number -128
            return ""
          end try
        end run
        """

    static let osascript: Runner = { start in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script, start]
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
