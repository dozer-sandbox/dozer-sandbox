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

    /// 605: an integer setting as this process sees it — its flag first (`doz ui --port`), then the
    /// environment, the file, the default.
    public func int(_ key: String) -> Int {
        if case .int(let i)? = flags[key] { return i }
        return current.int(key)
    }

    /// 606: a string setting as this process sees it — its flag first (`doz serve --bind`), then the rest.
    public func string(_ key: String) -> String? {
        if case .string(let v)? = flags[key] { return v.isEmpty ? nil : v }
        return current.string(key)
    }

    public func report() -> SettingsReport { current.report(flags: flags) }

    /// Apply one change: refused when the UI may not set that key, or the environment or a flag sets
    /// it here, or the file does not parse (it is the person's — never overwritten).
    public func apply(_ change: WebSettingChange) throws -> SettingsReport {
        lock.lock()
        defer { lock.unlock() }
        let s = current
        guard let d = DozerSettings.definition(change.key) else { throw WebAction.Invalid("unknown setting") }
        guard d.editableInUI else {
            // 606: who may reach the dashboard is decided on the Mac, never from a browser.
            if d.section == "serve" { throw HostError(.invalid, "\(d.key) decides who reaches the dashboard — set it on the Mac: doz config set \(d.key) VALUE") }
            throw HostError(.invalid, "\(d.key) is a host path — set it with: doz config set \(d.key) PATH")
        }
        let r = s.resolve(d.key, flag: flags[d.key])
        if r.source == .env { throw HostError(.invalidPhase, "\(d.key) is set by $\(d.environment ?? "?") in the environment of this doz ui — change it there") }
        if r.source == .flag { throw HostError(.invalidPhase, "\(d.key) is set on the command line of this doz ui") }
        if let e = s.fileError { throw HostError(.invalidPhase, "\(e) — fix it (or remove it) first; the UI does not overwrite it") }
        // 594: the browser can take secret entry away, never grant it (a reset would grant it: the default is on).
        if d.key == SettingKey.allowSecretEntry, change.value != .bool(false), s.resolve(d.key).value == .bool(false) {
            throw HostError(.invalid, "\(d.key) can be turned on only from a terminal: doz config set \(d.key) true")
        }
        do {
            return try s.writing(d.key, change.value).report(flags: flags)
        } catch let e as SettingsError {
            throw HostError(.failed, e.message)
        }
    }

    /// 599c: a host path the SERVER chose (the Mac's folder picker) — never one the browser sent. The
    /// same refusals as `apply` for the environment, a flag and an unreadable file.
    func applyHostPath(_ key: String, _ path: String) throws -> SettingsReport {
        lock.lock()
        defer { lock.unlock() }
        let s = current
        guard let d = DozerSettings.definition(key), d.type == .path else { throw WebAction.Invalid("unknown setting") }
        let r = s.resolve(d.key, flag: flags[d.key])
        if r.source == .env { throw HostError(.invalidPhase, "\(d.key) is set by $\(d.environment ?? "?") in the environment of this doz ui — change it there") }
        if r.source == .flag { throw HostError(.invalidPhase, "\(d.key) is set on the command line of this doz ui") }
        if let e = s.fileError { throw HostError(.invalidPhase, "\(e) — fix it (or remove it) first; the UI does not overwrite it") }
        do {
            return try s.writing(d.key, .string(path)).report(flags: flags)
        } catch let e as SettingsError {
            throw HostError(.failed, e.message)
        }
    }

    /// `ui.terminals` — off, no ticket is minted.
    public var terminalsEnabled: Bool { current.bool(SettingKey.terminals) }

    /// 594: `ui.allow_secret_entry` — off, the account route refuses and the page shows the CLI command.
    public var secretEntryAllowed: Bool { current.bool(SettingKey.allowSecretEntry) }

    /// 594 (D7): the onboarding's settings — doz.toml and the prompt template, each written only when
    /// missing (an existing file is never touched), with `defaults.image` and the account's default.
    public func writeOnboardingConfig(_ c: WebOnboardingConfig) throws -> WebOnboardingConfigResult {
        lock.lock()
        defer { lock.unlock() }
        do {
            let account = Onboarding.Account(rawValue: c.account).flatMap(Onboarding.defaultAccount(for:))
            let (s, sp) = try Onboarding.writeSettingsIfMissing(defaultImage: c.defaultImage, account: account, environment: environment)
            let (t, tp) = try Onboarding.writePromptTemplateIfMissing(environment: environment)
            // 599e: the Access step's choices — the defaults for new sandboxes (even into a file that was kept).
            var accessSet: [String]?
            if let a = c.access, s != .unavailable {
                do {
                    accessSet = try Access.write(github: a.github, githubSource: a.github == "off" ? nil : a.githubSource, ssh: a.ssh, environment: environment)
                } catch { throw HostError(.invalid, "\(error)") }
            }
            // 599g: the Workspace rules step's default mode (chosen in the step), likewise.
            var rulesSet: [String]?
            if let m = c.ignoreMode, s != .unavailable { rulesSet = try Onboarding.writeIgnoreMode(m, environment: environment) }
            return WebOnboardingConfigResult(settings: s.rawValue, settingsPath: sp, promptTemplate: t.rawValue, promptTemplatePath: tp, accessSet: accessSet,
                                             rulesSet: rulesSet)
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

/// 594 (owner ruling): `POST /api/v1/accounts`, decoded STRICTLY: {name, kind, secret, plan?}. The
/// secret is checked for shape only; no message ever echoes it (nor any value). Its description is
/// redacted, so no interpolation can print it.
public struct WebAccountAdd: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let name: String
    public let kind: AccountKind
    public let plan: String?
    public let secret: String

    public var description: String { "WebAccountAdd(\(name), \(kind.rawValue), secret: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["name": name, "kind": kind.rawValue, "secret": "<redacted>"]) }

    public static func decode(_ body: Data) throws -> WebAccountAdd {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        let keys = Set(d.keys)
        guard keys.isSuperset(of: ["name", "kind", "secret"]), keys.isSubset(of: ["name", "kind", "secret", "plan"]) else {
            throw WebAction.Invalid("exactly name, kind, secret (and plan for a setup token)")
        }
        guard let name = d["name"] as? String, name.count <= 40, (try? AccountStore.validateName(name)) != nil else {
            throw WebAction.Invalid("name: an account name, 1–40 of a-z 0-9 - (not default or none)")
        }
        // 599i: an OpenAI key too. A ChatGPT sign-in is never typed: it is Dozer's own browser sign-in (the CLI).
        guard let k = d["kind"] as? String, let kind = AccountKind(rawValue: k), [.apiKey, .setupToken, .openaiKey].contains(kind) else {
            throw WebAction.Invalid("kind: api-key, setup-token or openai-key")
        }
        var plan: String?
        if let p = d["plan"], !(p is NSNull) {
            guard kind == .setupToken, let s = p as? String, ["max", "pro", "team", "enterprise"].contains(s) else {
                throw WebAction.Invalid("plan: max, pro, team or enterprise — for a setup token")
            }
            plan = s
        }
        guard let secret = d["secret"] as? String, WebSecretText.valid(secret) else {
            throw WebAction.Invalid("secret: the key or token as it was printed (20–4096 characters)")
        }
        return WebAccountAdd(name: name, kind: kind, plan: plan, secret: secret)
    }

    /// Any text with the secret (and its whitespace-free form) replaced — for an error message.
    public func scrub(_ text: String) -> String { WebSecretText.scrub(text, secret) }
}

/// 594: the secret-entry routes' shared rules.
public enum WebSecretText {
    /// `text` with `secret` — as typed, trimmed, and normalised — replaced by "…".
    public static func scrub(_ text: String, _ secret: String) -> String {
        var out = text
        for s in Set([secret, secret.trimmingCharacters(in: .whitespacesAndNewlines),
                      AccountStore.normalizeToken(secret) ?? ""]) where s.count >= 8 {
            out = out.replacingOccurrences(of: s, with: "…")
        }
        return out
    }

    /// The shape a pasted key or token must have (never echoed when it does not).
    static func valid(_ s: String) -> Bool {
        (20...4096).contains(s.utf8.count) && !s.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" })
    }
}

/// 594 (owner ruling): `POST /api/v1/sandboxes/{name}/key`, decoded STRICTLY: exactly {secret} — a
/// sandbox's own Anthropic key, what `doz key set NAME --anthropic` sets (the sandbox comes from the
/// path). Redacted description; no message echoes the value.
public struct WebKeySet: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let sandbox: String
    public let secret: String

    public var description: String { "WebKeySet(\(sandbox), secret: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["sandbox": sandbox, "secret": "<redacted>"]) }

    public static func decode(_ body: Data, sandbox: String) throws -> WebKeySet {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        guard Set(d.keys) == ["secret"] else { throw WebAction.Invalid("exactly secret") }
        guard let s = d["secret"] as? String, WebSecretText.valid(s), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebAction.Invalid("secret: the key as it was printed (20–4096 characters)")
        }
        return WebKeySet(sandbox: sandbox, secret: s)
    }

    public func scrub(_ text: String) -> String { WebSecretText.scrub(text, secret) }
}

/// 599e: the Access choices (each optional) — `{github?: off|read|push, githubSource?: gh|key, ssh?: off|on}`.
public struct WebAccessChoices: Equatable, Sendable {
    public var github: String?
    public var githubSource: String?
    public var ssh: String?

    public init(github: String? = nil, githubSource: String? = nil, ssh: String? = nil) {
        self.github = github; self.githubSource = githubSource; self.ssh = ssh
    }

    static let allowed: [String: [String]] = ["github": ["off", "read", "push"], "githubSource": ["gh", "key"], "ssh": ["off", "on"]]

    public static func decode(_ any: Any?) throws -> WebAccessChoices {
        guard let d = any as? [String: Any] else { throw WebAction.Invalid("choices: an object") }
        guard Set(d.keys).isSubset(of: Set(allowed.keys)) else { throw WebAction.Invalid("choices: github, githubSource, ssh") }
        var c = WebAccessChoices()
        for (k, v) in d {
            guard let s = v as? String, allowed[k]!.contains(s) else { throw WebAction.Invalid("\(k): \(allowed[k]!.joined(separator: ", "))") }
            switch k { case "github": c.github = s; case "githubSource": c.githubSource = s; default: c.ssh = s }
        }
        return c
    }

    /// For the host request (only those given).
    public var dictionary: [String: String] {
        var d: [String: String] = [:]
        if let github { d["github"] = github }
        if let githubSource { d["githubSource"] = githubSource }
        if let ssh { d["ssh"] = ssh }
        return d
    }
}

/// 599e: `POST /api/v1/access/check`, decoded strictly: {items?: [claude|github|ssh], choices?}.
public struct WebAccessCheck: Equatable, Sendable {
    public var items: [String]?
    public var choices: WebAccessChoices?

    public static func decode(_ body: Data) throws -> WebAccessCheck {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        guard Set(d.keys).isSubset(of: ["items", "choices"]) else { throw WebAction.Invalid("items and choices only") }
        var c = WebAccessCheck()
        if let i = d["items"] {
            guard let a = i as? [String], !a.isEmpty, a.count <= 3, Set(a).isSubset(of: ["claude", "github", "ssh"]) else {
                throw WebAction.Invalid("items: some of claude, github, ssh")
            }
            c.items = a
        }
        if d["choices"] != nil { c.choices = try WebAccessChoices.decode(d["choices"]) }
        return c
    }
}

/// 599e: `POST /api/v1/access/github-key`, decoded strictly: exactly {secret} or exactly {remove: true}.
/// Redacted description; no message echoes the value.
public struct WebAccessGitHubKey: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// nil: remove the default key.
    public let secret: String?

    public var description: String { secret == nil ? "WebAccessGitHubKey(remove)" : "WebAccessGitHubKey(secret: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["secret": secret == nil ? "nil" : "<redacted>"]) }

    public static func decode(_ body: Data) throws -> WebAccessGitHubKey {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        if Set(d.keys) == ["remove"] {
            guard d["remove"] as? Bool == true else { throw WebAction.Invalid("remove: true") }
            return WebAccessGitHubKey(secret: nil)
        }
        guard Set(d.keys) == ["secret"] else { throw WebAction.Invalid("exactly secret (or remove)") }
        guard let s = d["secret"] as? String, WebSecretText.valid(s), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).contains(where: { $0.isWhitespace }) else {
            throw WebAction.Invalid("secret: the token as GitHub printed it (one word, 20–4096 characters)")
        }
        return WebAccessGitHubKey(secret: s)
    }

    public func scrub(_ text: String) -> String { secret.map { WebSecretText.scrub(text, $0) } ?? text }
}

/// 594: `POST /api/v1/onboarding/config`, decoded strictly: exactly {defaultImage, account} — and (599e)
/// optionally `access` (the Access step's choices, written as the defaults for new sandboxes), and (599g)
/// `ignoreMode` (the Workspace rules step's: `lock` or `hide`, the default `workspace.ignore_mode`).
public struct WebOnboardingConfig: Equatable, Sendable {
    public let defaultImage: String
    public let account: String
    public var access: WebAccessChoices? = nil
    public var ignoreMode: String? = nil

    public static func decode(_ body: Data) throws -> WebOnboardingConfig {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        guard Set(d.keys).isSuperset(of: ["defaultImage", "account"]), Set(d.keys).isSubset(of: ["defaultImage", "account", "access", "ignoreMode"]) else {
            throw WebAction.Invalid("exactly defaultImage and account (and access, ignoreMode)")
        }
        guard let i = d["defaultImage"] as? String, ["lab", "claude-code", "pi", "codex"].contains(i) else {
            throw WebAction.Invalid("defaultImage: lab, claude-code, pi or codex")
        }
        guard let a = d["account"] as? String, Onboarding.Account(rawValue: a) != nil else {
            throw WebAction.Invalid("account: \(Onboarding.Account.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        var c = WebOnboardingConfig(defaultImage: i, account: a)
        if d["access"] != nil { c.access = try WebAccessChoices.decode(d["access"]) }
        if let m = d["ignoreMode"] {
            guard let v = m as? String, ["lock", "hide"].contains(v) else { throw WebAction.Invalid("ignoreMode: lock or hide") }
            c.ignoreMode = v
        }
        return c
    }
}

/// `POST /api/v1/signup`, decoded STRICTLY: exactly {email, interests} — the source is the server's (the setup wizard),
/// never the body's. A refusal never echoes the email (and `SignupRequest`'s description is redacted).
public enum WebSignup {
    public static let failure = "the sign-up could not be sent — try again later, or at \(Usage.signupPage)"

    public static func decode(_ body: Data) throws -> SignupRequest {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        guard Set(d.keys) == ["email", "interests"] else { throw WebAction.Invalid("exactly email and interests") }
        guard let email = d["email"] as? String, SignupRequest.emailProblem(email.trimmingCharacters(in: .whitespacesAndNewlines)) == nil else {
            throw WebAction.Invalid("email: an email address (name@example.com)")
        }
        guard let list = d["interests"] as? [Any], list.count <= 3, let interests = list as? [String] else {
            throw WebAction.Invalid("interests: a list of release-news, early-access, support")
        }
        do { return try SignupRequest.make(email: email, interests: interests, source: "onboarding-web") } catch {
            throw WebAction.Invalid("interests: at least one of release-news, early-access, support (each once)")
        }
    }
}
