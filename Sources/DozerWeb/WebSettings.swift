import Foundation
import DozerHost

// 591 settings — the UI's Settings page. GET /api/v1/settings answers every setting (value, default,
// source, description; never a secret — the schema has none). POST /api/v1/settings changes ONE:
// exact Origin + CSRF (as every unsafe route), a JSON body of exactly {key, value} or {key, reset:
// true}, the key one of the CLOSED schema's, the value of the key's JSON type and in its range —
// then one write of doz.toml (atomic, 0600), and the new report. The UI never sets a host path
// (store.path, kernel.*: `doz config set`), nor a value the environment or a flag sets (it would
// not apply — the page shows those read-only).

/// One change, decoded strictly.
public struct WebSettingChange: Equatable, Sendable {
    public let key: String
    /// nil: reset (the default applies; the line is commented out again).
    public let value: TOMLValue?

    /// Throws `WebAction.Invalid` with a fixed message (the value is never echoed).
    public static func decode(_ body: Data) throws -> WebSettingChange {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        let extra = Set(d.keys).subtracting(["key", "value", "reset"])
        guard extra.isEmpty else { throw WebAction.Invalid("unexpected field(s): \(extra.sorted().joined(separator: ", ").prefix(120))") }
        guard let key = d["key"] as? String, key.utf8.count <= 64, let def = DozerSettings.definition(key) else {
            throw WebAction.Invalid("unknown setting")
        }
        switch (d["value"], d["reset"]) {
        case (nil, let r?):
            guard let n = r as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID(), n.boolValue else { throw WebAction.Invalid("reset is true") }
            return WebSettingChange(key: key, value: nil)
        case (let v?, nil):
            let typed: TOMLValue
            if let n = v as? NSNumber {
                if CFGetTypeID(n) == CFBooleanGetTypeID() {
                    typed = .bool(n.boolValue)
                } else {
                    let x = n.doubleValue
                    guard x.rounded() == x, abs(x) <= 1e9 else { throw WebAction.Invalid("\(key) is a whole number") }
                    typed = .int(Int(x))
                }
            } else if let s = v as? String {
                guard s.utf8.count <= 1024 else { throw WebAction.Invalid("the value is too long") }
                typed = .string(s)
            } else {
                throw WebAction.Invalid("the value is a boolean, a number or a string")
            }
            do { return WebSettingChange(key: key, value: try def.validate(typed)) } catch let e as SettingsError {
                throw WebAction.Invalid(e.message)
            }
        default:
            throw WebAction.Invalid("either value or reset")
        }
    }
}

/// The UI process's view of the settings file: its environment (which names the file and overrides
/// it) and its command-line flags. Writes are serialized (read, change one key, write).
public final class WebSettingsStore: @unchecked Sendable {
    public let environment: [String: String]
    public let flags: [String: TOMLValue]
    private let lock = NSLock()

    public init(environment: [String: String], flags: [String: TOMLValue] = [:]) {
        self.environment = environment
        self.flags = flags
    }

    public var current: DozerSettings { DozerSettings.load(environment: environment) }

    public func report() -> SettingsReport { current.report(flags: flags) }

    /// Apply one change: refused when the UI may not set that key, or the environment or a flag sets
    /// it here, or the file does not parse (it is the person's — never overwritten).
    public func apply(_ change: WebSettingChange) throws -> SettingsReport {
        lock.lock()
        defer { lock.unlock() }
        let s = current
        guard let d = DozerSettings.definition(change.key) else { throw WebAction.Invalid("unknown setting") }
        guard d.editableInUI else {
            throw HostError(.invalid, "\(d.key) is a host path — set it with: doz config set \(d.key) PATH")
        }
        let r = s.resolve(d.key, flag: flags[d.key])
        if r.source == .env { throw HostError(.invalidPhase, "\(d.key) is set by $\(d.environment ?? "?") in the environment of this doz ui — change it there") }
        if r.source == .flag { throw HostError(.invalidPhase, "\(d.key) is set on the command line of this doz ui") }
        if let e = s.fileError { throw HostError(.invalidPhase, "\(e) — fix it (or remove it) first; the UI does not overwrite it") }
        do {
            return try s.writing(d.key, change.value).report(flags: flags)
        } catch let e as SettingsError {
            throw HostError(.failed, e.message)
        }
    }

    /// `ui.terminals` — off, no ticket is minted.
    public var terminalsEnabled: Bool { current.bool(SettingKey.terminals) }

    /// 594 (D7): the onboarding's settings — doz.toml and the prompt template, each written only when
    /// missing (an existing file is never touched), with `defaults.image` and the account's default.
    public func writeOnboardingConfig(_ c: WebOnboardingConfig) throws -> WebOnboardingConfigResult {
        lock.lock()
        defer { lock.unlock() }
        do {
            let account = Onboarding.Account(rawValue: c.account).flatMap(Onboarding.defaultAccount(for:))
            let (s, sp) = try Onboarding.writeSettingsIfMissing(defaultImage: c.defaultImage, account: account, environment: environment)
            let (t, tp) = try Onboarding.writePromptTemplateIfMissing(environment: environment)
            return WebOnboardingConfigResult(settings: s.rawValue, settingsPath: sp, promptTemplate: t.rawValue, promptTemplatePath: tp)
        } catch let e as SettingsError {
            throw HostError(.failed, e.message)
        }
    }

    /// Where the settings file and the prompt template are, and whether they exist (the wizard says).
    public func onboardingFiles() -> (settings: String?, settingsExists: Bool, template: String?, templateExists: Bool) {
        let fm = FileManager.default
        let s = DozerSettings.fileURL(environment: environment)
        let t = AgentPrompt.userTemplateURL(environment: environment)
        return (s?.path, s.map { fm.fileExists(atPath: $0.path) } ?? false, t?.path, t.map { fm.fileExists(atPath: $0.path) } ?? false)
    }
}

/// 594: `POST /api/v1/onboarding/config`, decoded strictly: exactly {defaultImage, account}.
public struct WebOnboardingConfig: Equatable, Sendable {
    public let defaultImage: String
    public let account: String

    public static func decode(_ body: Data) throws -> WebOnboardingConfig {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        guard Set(d.keys) == ["defaultImage", "account"] else { throw WebAction.Invalid("exactly defaultImage and account") }
        guard let i = d["defaultImage"] as? String, ["lab", "claude-code", "pi"].contains(i) else {
            throw WebAction.Invalid("defaultImage: lab, claude-code or pi")
        }
        guard let a = d["account"] as? String, Onboarding.Account(rawValue: a) != nil else {
            throw WebAction.Invalid("account: \(Onboarding.Account.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return WebOnboardingConfig(defaultImage: i, account: a)
    }
}
