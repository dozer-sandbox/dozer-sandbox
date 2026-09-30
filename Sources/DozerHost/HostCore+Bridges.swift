import Foundation

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
        case .openURL, .openTooLong:
            return nil
        }
    }

    static func chars(_ data: Data) -> String {
        let n = String(decoding: data, as: UTF8.self).count
        return n == 1 ? "1 char" : "\(n) chars"
    }

    static func size(_ bytes: Int) -> String {
        bytes >= 1 << 20 ? String(format: "%.1f MiB", Double(bytes) / Double(1 << 20)) : "\(bytes / 1024) KiB"
    }
}
