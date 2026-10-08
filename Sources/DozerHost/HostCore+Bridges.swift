import Foundation
import DozerKit

// 599 — the session bridges' decisions (the scanner is `SessionBridge.swift`; the relay calls `bridge`),
// and the per-sandbox settings that steer them (`sandbox-settings`, `doz config set --sandbox NAME`).

/// One per-sandbox setting of a sandbox: its effective value and where it came from.
public struct SandboxSettingRow: Codable, Equatable, Sendable {
    public var key: String
    public var value: TOMLValue
    /// `sandbox` (its own choice) or the setting's source: `file`, `env`, `default`.
    public var source: String
    /// The sandbox's own value (nil: it follows the setting).
    public var sandboxValue: TOMLValue?
    /// What the setting alone says.
    public var settingValue: TOMLValue
    public var typeName: String
    public var description: String
}

public struct SandboxSettingsReport: Codable, Equatable, Sendable {
    public var sandbox: String
    public var settings: [SandboxSettingRow]
    /// Set when this request changed one: what it did, in words.
    public var changed: String?
}

extension HostCore {
    // MARK: per-sandbox settings

    /// Values for `CreateOptions.settings`: only per-sandbox keys (not `sandbox.agent_sudo`, which has
    /// its own field), each checked against its type.
    static func checkedSandboxSettings(_ s: [String: TOMLValue]) throws -> [String: TOMLValue] {
        var out: [String: TOMLValue] = [:]
        for (k, v) in s {
            guard k != SettingKey.agentSudo, DozerSettings.perSandbox.contains(k), let d = DozerSettings.definition(k) else {
                throw HostError(.invalid, "\(k) is not a per-sandbox setting (they are: \(DozerSettings.perSandbox.joined(separator: ", ")))")
            }
            do { out[k] = try d.validate(v) } catch { throw HostError(.invalid, "\(error)") }
        }
        return out
    }

    /// A per-sandbox setting's value for this sandbox: its own, else the setting's.
    static func sandboxValue(_ cfg: SandboxConfig, _ key: String, settings: @autoclosure () -> DozerSettings = .load()) -> TOMLValue {
        if key == SettingKey.agentSudo, let own = cfg.agentSudo { return .bool(own) }
        if let own = cfg.settings?[key] { return own }
        return settings().resolve(key).value
    }

    func sandboxSettings(_ r: HostRequest) throws -> SandboxSettingsReport {
        let m = try get(r.name)
        var changed: String?
        if let key = r.setting {
            guard DozerSettings.perSandbox.contains(key), let d = DozerSettings.definition(key) else {
                throw HostError(.invalid, "\(key) is not a per-sandbox setting (they are: \(DozerSettings.perSandbox.joined(separator: ", ")))")
            }
            if r.clearSetting == true {
                if key == SettingKey.agentSudo { m.config.agentSudo = nil } else { m.config.settings?[key] = nil }
                if m.config.settings?.isEmpty == true { m.config.settings = nil }
                changed = "\(key) follows the setting again"
            } else {
                guard let raw = r.settingValue else { throw HostError(.invalid, "\(key): which value? (or clear it)") }
                let v: TOMLValue
                do {
                    // A person's text (`off`, `true`) is parsed as the CLI would; a typed value is checked.
                    if case .string(let t) = raw { v = try d.parse(t) } else { v = try d.validate(raw) }
                } catch { throw HostError(.invalid, "\(error)") }
                if key == SettingKey.agentSudo, case .bool(let b) = v { m.config.agentSudo = b } else { m.config.settings = (m.config.settings ?? [:]).merging([key: v]) { _, n in n } }
                changed = "\(key) = \(v.plain) for \(m.name)"
            }
            if !readOnly {
                try m.config.write(store.configFile(m.name))
                if key == SettingKey.agentSudo { m.sandbox.setAgentSudo(Self.agentSudo(m.config)) }
                if key == SettingKey.sshAgent { applyGitHub(m) }          // 599d: on/off at once
                if key == SettingKey.tmux { applyToolInputs(m) }         // 599h: tmux joins the tools layer
                note(m.name, "\(changed ?? key) — \(d.applies.note)")
            }
        }
        let settings = DozerSettings.load()
        let rows = DozerSettings.perSandbox.compactMap { key -> SandboxSettingRow? in
            guard let d = DozerSettings.definition(key) else { return nil }
            let s = settings.resolve(key)
            let own: TOMLValue? = key == SettingKey.agentSudo ? m.config.agentSudo.map { .bool($0) } : m.config.settings?[key]
            return SandboxSettingRow(key: key, value: own ?? s.value, source: own != nil ? "sandbox" : s.source.rawValue,
                                     sandboxValue: own, settingValue: s.value, typeName: d.type.name, description: d.summary)
        }
        return SandboxSettingsReport(sandbox: m.name, settings: rows, changed: changed)
    }

    /// The per-sandbox value, by sandbox name (nil: no such sandbox).
    func sandboxValue(named name: String, _ key: String) -> TOMLValue? {
        guard let m = managed[name] else { return nil }
        return Self.sandboxValue(m.config, key)
    }

    // MARK: the bridges

    /// What the host does about one bridge event from `session`'s output (read by the attach relay):
    /// the notice for the viewer, or nil. Never on the actor while it acts (the pasteboard, the browser).
    public nonisolated func bridge(_ e: BridgeEvent, sandbox: String, session: String) async -> BridgeNotice? {
        switch e {
        case .copyRead:
            // Never answered. Logged once per session, so a program that keeps asking does not flood the log.
            if bridgeState.firstRead("\(sandbox)/\(session)") {
                await note(sandbox, "the \(session) session asked to READ the Mac clipboard (OSC 52) — refused: a sandbox never reads it")
            }
            return nil
        case .copyTooLarge(let n):
            return BridgeNotice("clipboard-refused", "\(sandbox) tried to copy \(Self.size(n * 3 / 4)) — over the 1 MiB limit, not copied")
        case .copy(let data):
            let choice = await sandboxValue(named: sandbox, SettingKey.clipboard)
            if choice == .string("off") {
                return BridgeNotice("clipboard-off", "\(sandbox) tried to copy \(Self.chars(data)) — its clipboard bridge is off (sandbox.clipboard)")
            }
            // Two viewers of one session read the same copy: the host copies once, both are told.
            let state = bridgeState
            let (n, fresh) = state.once("copy/\(sandbox)/\(data.hashValue)", within: 2) {
                guard state.copies.allow(sandbox) else {
                    return BridgeNotice("clipboard-refused", "\(sandbox) copied too often — \(Self.chars(data)) not copied (at most 10 copies in 10 s)")
                }
                return MacPasteboard.write(data)
                    ? BridgeNotice("clipboard", "\(sandbox) copied \(Self.chars(data))")
                    : BridgeNotice("clipboard-refused", "\(sandbox) copied \(Self.chars(data)), but the Mac clipboard could not be set")
            }
            if fresh, n.kind == "clipboard" { await note(sandbox, "the \(session) session copied \(Self.chars(data)) to the Mac clipboard") }
            return n
        case .openTooLong:
            return BridgeNotice("open-refused", "\(sandbox) asked to open a URL or file longer than 2048 bytes — not opened")
        case .openURL(let raw):
            return await openURL(raw, sandbox: sandbox, session: session)
        case .openFile(let path, let app):
            return await openFile(path, app: app, sandbox: sandbox, session: session)
        case .revealFile(let path):
            return await openFile(path, app: nil, reveal: true, sandbox: sandbox, session: session)
        }
    }

    /// 599b: a /workspace file → the Mac's default app (or an app the user listed). `WorkspaceFiles`
    /// decides (the setting, isolation, the app, the path resolved on the Mac, the type and content);
    /// here: the rate limit, acting once for two viewers, the notice and the log line.
    /// A folder opens in the Finder; `reveal` shows a file selected in its folder.
    nonisolated func openFile(_ guestPath: String, app: String?, reveal: Bool = false, sandbox: String, session: String) async -> BridgeNotice {
        let enabled = await sandboxValue(named: sandbox, SettingKey.openFiles) != .string("off")
        let workspace = await workspaceHostPath(of: sandbox)
        let allowed = WorkspaceFiles.appNames(DozerSettings.load().string(SettingKey.openApps) ?? "") ?? []
        let asked = WorkspaceFiles.shownRequest(guestPath)
        let inApp = app.map { " in " + String($0.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.prefix(64)) } ?? ""
        let verb = reveal ? "show" : "open"
        switch WorkspaceFiles.decide(guestPath: guestPath, app: app, reveal: reveal, workspace: workspace, enabled: enabled, allowedApps: allowed) {
        case .refused(let kind, let why):
            // Said to the viewer only (as the browser bridge's refusals): a program that keeps asking
            // must not grow the host log.
            return BridgeNotice(kind, "\(sandbox) asked to \(verb) \(asked)\(inApp) — \(why)")
        case .open(let macPath, let shown, let listed, let how):
            let state = bridgeState
            let (n, fresh) = state.once("file/\(sandbox)/\(how.rawValue)/\(macPath)/\(listed ?? "")", within: 10) {
                guard state.fileOpens.allow(sandbox) else {
                    return BridgeNotice("file-refused", "\(sandbox) asked to \(verb) too many files — \(shown) not opened (at most \(WorkspaceFiles.rateCount) in \(Int(WorkspaceFiles.rateWindow)) s)")
                }
                guard WorkspaceFiles.open(macPath, app: listed, how: how) else {
                    return BridgeNotice("file-refused", "\(sandbox) asked to \(verb) \(shown)\(inApp), but this Mac could not open it")
                }
                switch how {
                case .finder: return BridgeNotice("file", "\(sandbox) opened \(shown) in the Finder")
                case .reveal: return BridgeNotice("file", "\(sandbox) showed \(shown) in the Finder")
                case .app: return BridgeNotice("file", "\(sandbox) opened \(shown) in \(listed ?? MacDefaultApp.name(forFile: macPath) ?? "its default app")")
                }
            }
            if fresh {
                let place = shown == "the workspace" ? "/workspace" : "/workspace/\(shown)"
                await note(sandbox, "the \(session) session asked for \(place): \(n.text)")
            }
            return n
        }
    }

    /// 599b: the Mac folder actually shared at /workspace (from the sandbox's spec — never a guest's word).
    func workspaceHostPath(of name: String) -> String? {
        managed[name]?.config.spec.shares.first { $0.guestPath == DozerImages.workspaceGuestPath }?.hostPath
    }

    /// 599 (594.B2): the guest's xdg-open → the Mac's default browser, and a sign-in's localhost callback
    /// forwarded into the sandbox.
    nonisolated func openURL(_ raw: String, sandbox: String, session: String) async -> BridgeNotice {
        let url: URL
        switch BrowserBridge.check(raw) {
        case .refused(let why): return BridgeNotice("open-refused", "\(sandbox) asked to open a URL — refused: \(why)")
        case .open(let u): url = u
        }
        let shown = BrowserBridge.shown(url)
        if await sandboxValue(named: sandbox, SettingKey.browserBridge) == .string("off") {
            return BridgeNotice("open-off", "\(sandbox) asked to open \(shown) — its browser bridge is off (sandbox.browser_bridge)")
        }
        let target = await sandboxObject(named: sandbox)
        let state = bridgeState
        let (n, fresh) = state.once("open/\(sandbox)/\(url.absoluteString)", within: 10) {
            guard state.opens.allow(sandbox) else {
                return BridgeNotice("open-refused", "\(sandbox) asked to open too many URLs — \(shown) not opened (at most 3 in 10 s)")
            }
            // A sign-in whose redirect is this sandbox's localhost: forward the Mac's port there first.
            var kind = "open", tail = "", follow: (host: String, port: Int, path: String)?
            let cb = BrowserBridge.callback(in: url)
            if let cb, let target {
                state.forward(of: sandbox)?.stop("replaced by a new sign-in")
                do {
                    let f = try LoopbackForward(sandbox: sandbox, port: cb.port,
                                                openStream: { try await target.openGuestStream([GuestCommand.deckholdPath, "connect", "-p", String(cb.port)]) },
                                                onEnd: { [weak self] f, why in
                                                    state.forwardEnded(f)
                                                    Task { await self?.note(sandbox, "the sign-in callback forward localhost:\(f.port) ended (\(why))") }
                                                })
                    _ = state.setForward(f, for: sandbox)
                    f.start()
                    kind = "oauth"
                    follow = cb
                    tail = " · sign-in callback localhost:\(cb.port) forwarded (\(Int(BrowserBridge.forwardSeconds / 60)) min)"
                } catch {
                    kind = "oauth-refused"
                    tail = " · localhost:\(cb.port) is in use on this Mac — the sign-in cannot return to the sandbox"
                }
            }
            guard BrowserBridge.open(url, callback: follow) else {
                return BridgeNotice("open-refused", "\(sandbox) asked to open \(shown), but this Mac could not open it")
            }
            return BridgeNotice(kind, "\(sandbox) opened \(shown)" + (tail.isEmpty ? " in your browser" : tail))
        }
        // The log names the page, never the query (a sign-in's state and challenge).
        if fresh { await note(sandbox, "the \(session) session asked for \(shown): \(n.text)") }
        return n
    }

    func sandboxObject(named name: String) -> Sandbox? { managed[name]?.sandbox }

    /// 599 (594.B4): the image a sandbox was made from, as a title shows it (`claude-code`, a template's name).
    func imageName(of name: String) -> String? {
        guard let i = managed[name]?.config.image else { return nil }
        return i.hasPrefix("custom:") ? String(i.dropFirst(7)) : i
    }

    static func chars(_ data: Data) -> String {
        let n = String(decoding: data, as: UTF8.self).count
        return n == 1 ? "1 char" : "\(n) chars"
    }

    static func size(_ bytes: Int) -> String {
        bytes >= 1 << 20 ? String(format: "%.1f MiB", Double(bytes) / Double(1 << 20)) : "\(bytes / 1024) KiB"
    }
}
