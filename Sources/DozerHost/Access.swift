import Foundation
import DozerKit

// 599e (owner, 2026-10-02: "github access on or off would be a pusposeful choice from the user either as a
// default or per-sandbox. I think we need to: add it as part of a general 'Access' step in the onboarding
// where the credentials get confirmed (with the option to skip the confirmation if there is an issue so the
// onboarding doesnt get blocked)"): every credential choice in ONE place — the Claude account, GitHub as
// you, the SSH agent — each CONFIRMED live, the result kept in `<store>/access.json` (never a secret).
//
//   Claude   the store's default account: a Mac login → signed in?; a key / token → the account check that
//            already exists (`services.verifier`: one minimal request to Anthropic); none → off.
//   GitHub   `defaults.github` (off/read/push) with `github.credentials` (gh/key): the real token read the
//            way sandboxes get it, then `GET https://api.github.com/user` over the proxy's own TLS leg
//            (`GitHubAccess.confirm`) → "signed in as LOGIN" + scopes, or how many repositories it sees.
//   SSH      `sandbox.ssh_agent`: the Mac's agent asked for its keys (what `ssh-add -l` shows).
//
// A failure never blocks: the choice is KEPT and shown as not confirmed, with the reason (the owner said
// skip; turning it off is the person's own next choice). Seams: as 599d (DOZ_TEST_GH, DOZ_TEST_GITHUB_UPSTREAM
// + DOZ_TEST_GITHUB_CA, DOZ_TEST_SSH_AUTH_SOCK, DOZ_TEST_CREDENTIALS=memory).

/// One credential in the Access step.
public struct AccessItem: Codable, Equatable, Sendable {
    /// `claude`, `github`, `ssh`.
    public var id: String
    public var title: String
    /// What is chosen: an account name / `none`; `off` · `read` · `push`; `off` · `on`.
    public var choice: String
    /// GitHub: `gh` or `key` (where the token comes from).
    public var source: String?
    /// `confirmed`, `failed` (the choice is kept, not confirmed), `off`, `unchecked`.
    public var state: String
    /// What the check found, or why it failed — never a secret.
    public var detail: String
    public var checkedAt: Date?
    /// The plain-language consequence of the choice (what it means for the agent).
    public var consequence: String

    public init(id: String, title: String, choice: String, source: String? = nil, state: String, detail: String,
                checkedAt: Date? = nil, consequence: String) {
        self.id = id; self.title = title; self.choice = choice; self.source = source; self.state = state
        self.detail = detail; self.checkedAt = checkedAt; self.consequence = consequence
    }
}

public struct AccessReport: Codable, Equatable, Sendable {
    public var items: [AccessItem]
    /// A default GitHub key is held (for `github.credentials = key`).
    public var githubKeySet: Bool
    /// What each choice means, in plain language (`github` → `off|read|push`, `ssh` → `off|on`) — the page
    /// shows the line for what is selected before anything is checked.
    public var consequences: [String: [String: String]]
    public init(items: [AccessItem], githubKeySet: Bool) {
        self.items = items; self.githubKeySet = githubKeySet
        consequences = ["github": Dictionary(uniqueKeysWithValues: ["off", "read", "push"].map { ($0, Access.consequence("github", $0)) }),
                        "ssh": Dictionary(uniqueKeysWithValues: ["off", "on"].map { ($0, Access.consequence("ssh", $0)) }),
                        "claude": ["none": Access.consequence("claude", "none"), "account": Access.consequence("claude", "account")]]
    }
}

/// The last check of each credential (`<store>/access.json`): state, detail, when — and the choice it was for,
/// so a changed choice shows as unchecked rather than as an old answer.
public struct AccessRecord: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var choice: String
        public var source: String?
        public var state: String
        public var detail: String
        public var at: Date
    }
    public var entries: [String: Entry] = [:]

    public static func load(_ url: URL) -> AccessRecord {
        guard let d = try? Data(contentsOf: url), let r = try? HostWire.decoder.decode(AccessRecord.self, from: d) else { return AccessRecord() }
        return r
    }
    public func write(_ url: URL) throws {
        try HostWire.prettyEncoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum Access {
    /// The keychain item of the default GitHub key.
    public static let githubKeyService = "doz-github"
    public static let ids = ["claude", "github", "ssh"]

    public static func consequence(_ id: String, _ choice: String) -> String {
        switch (id, choice) {
        case ("claude", "none"): return "The agent has no Claude account until you give a sandbox one (claude-code needs one to answer)."
        case ("claude", _): return "Sandboxes use this account; the proxy adds it to the agent's requests — it never enters a sandbox."
        case ("github", "read"): return "git and gh in new sandboxes are signed in as you on GitHub, read-only: the agent can read everything your login can. The token stays on this Mac."
        case ("github", "push"): return "git and gh in new sandboxes are signed in as you on GitHub and can push and change things as you. The token stays on this Mac."
        case ("github", _): return "New sandboxes are not signed in to GitHub as you (public repositories still work)."
        case ("ssh", "on"): return "ssh and git over SSH in sandboxes can ask your Mac's ssh-agent to sign (github.com only) — your keys never leave the Mac."
        default: return "Your ssh-agent is not forwarded into sandboxes."
        }
    }

    /// Write the Access choices into the settings file (only those given; each checked by its setting).
    /// Returns what was set, as `key = value` lines.
    @discardableResult
    public static func write(github: String?, githubSource: String?, ssh: String?,
                             environment: [String: String] = ProcessInfo.processInfo.environment) throws -> [String] {
        var settings = DozerSettings.load(environment: environment)
        var done: [String] = []
        for (key, value) in [(SettingKey.defaultGithub, github), (SettingKey.githubCredentials, githubSource), (SettingKey.sshAgent, ssh)] {
            guard let value else { continue }
            guard let d = DozerSettings.definition(key) else { continue }
            let v = try d.parse(value)
            if settings.resolve(key).value == v, settings.fileValues[key] != nil { continue }
            settings = try settings.writing(key, v)
            done.append("\(key) = \(value)")
        }
        return done
    }

    /// The GitHub token for a check, as a NEW sandbox would get it: the default key (`key`) or the Mac's gh.
    static func githubToken(source: String, keychain: KeychainAccess, environment: [String: String]) -> CredentialVault.SecretRead {
        switch source {
        case "off": return (nil, "github.credentials is off on this Mac")
        case "key":
            if let s = keychain.read(service: githubKeyService, account: Keychain.user).value { return (s, nil) }
            return (nil, "no GitHub key is set — doz access set --github-key (or the Access step)")
        default:
            let r = GitHubLogin.ghToken(environment: environment)
            return (r.secret, r.notice.map { $0.replacingOccurrences(of: "Dozer: \"Use GitHub as you\" is on, but ", with: "") })
        }
    }
}

extension HostCore {
    var accessRecordURL: URL { store.root.appendingPathComponent("access.json") }

    /// `access`: the report (from the record), after a live check of `items` (nil: all) when `check`.
    func access(_ r: HostRequest, environment env: [String: String] = ProcessInfo.processInfo.environment) async throws -> AccessReport {
        let settings = DozerSettings.load(environment: env)
        let file = accountStore.load()
        // The choices, as they are now.
        let claudeChoice = file.defaultAccount
        let given = r.accessChoices ?? [:]
        for (k, v) in given {
            let ok: [String: [String]] = ["github": ["off", "read", "push"], "githubSource": ["gh", "key", "off"], "ssh": ["off", "on"]]
            guard ok[k]?.contains(v) == true else { throw HostError(.invalid, "access: \(k) is one of \(ok[k]?.joined(separator: ", ") ?? "github, githubSource, ssh")") }
        }
        let github = given["github"] ?? settings.string(SettingKey.defaultGithub) ?? "off"
        let source = given["githubSource"] ?? settings.string(SettingKey.githubCredentials) ?? "gh"
        let ssh = given["ssh"] ?? settings.string(SettingKey.sshAgent) ?? "off"
        let choices: [String: (choice: String, source: String?)] = ["claude": (claudeChoice, nil), "github": (github, source), "ssh": (ssh, nil)]
        var record = AccessRecord.load(accessRecordURL)
        if r.check == true {
            let wanted = Set(r.items ?? Access.ids)
            for id in Access.ids where wanted.contains(id) {
                let c = choices[id]!
                let (state, detail) = await confirm(id, choice: c.choice, source: c.source, file: file, environment: env)
                record.entries[id] = .init(choice: c.choice, source: c.source, state: state, detail: detail, at: Date())
                note(nil, "access: \(id) (\(c.choice)\(c.source.map { ", \($0)" } ?? "")) — \(state): \(detail)")
            }
            if !readOnly { try? record.write(accessRecordURL) }
        }
        let items = Access.ids.map { id -> AccessItem in
            let c = choices[id]!
            let off = (id == "claude" && c.choice == "none") || (id != "claude" && c.choice == "off")
            let title = ["claude": "Claude account", "github": "GitHub as you", "ssh": "SSH agent forwarding"][id]!
            if off {
                return AccessItem(id: id, title: title, choice: c.choice, source: c.source, state: "off", detail: "off — nothing to confirm",
                                  consequence: Access.consequence(id, c.choice))
            }
            // An answer counts only for the choice it was given for.
            if let e = record.entries[id], e.choice == c.choice, e.source == c.source {
                return AccessItem(id: id, title: title, choice: c.choice, source: c.source, state: e.state, detail: e.detail, checkedAt: e.at,
                                  consequence: Access.consequence(id, c.choice))
            }
            return AccessItem(id: id, title: title, choice: c.choice, source: c.source, state: "unchecked", detail: "not checked yet",
                              consequence: Access.consequence(id, c.choice))
        }
        let keySet = services.keychain.read(service: Access.githubKeyService, account: Keychain.user).value != nil
        return AccessReport(items: items, githubKeySet: keySet)
    }

    /// One live check: (`confirmed` | `failed` | `off`, what it found).
    func confirm(_ id: String, choice: String, source: String?, file: AccountsFile, environment env: [String: String]) async -> (String, String) {
        switch id {
        case "claude":
            guard choice != "none" else { return ("off", "no account") }
            if let a = file.accounts.first(where: { $0.name == choice }), a.kind != .mac {
                let read = services.keychain.read(service: a.keychainService ?? "", account: a.adopted == true ? nil : Keychain.user)
                guard let secret = read.value else {
                    return ("failed", "the keychain item \(a.keychainService ?? "?") is \(read == .locked ? "locked" : "missing")")
                }
                switch await services.verifier.verify(kind: a.kind, secret: secret) {
                case .verified: return ("confirmed", "\(a.name) (\(a.kind.rawValue)) — Anthropic accepted it")
                case .rejected(let why): return ("failed", "Anthropic refused \(a.name): \(why)")
                case .unavailable(let why): return ("failed", "\(a.name) could not be checked: \(why)")
                }
            }
            let configDir = file.accounts.first(where: { $0.name == choice })?.configDir
            let st = ClaudeLoginStatus.check(configDir: configDir, keychain: services.keychain, probeBinary: false, home: services.home)
            if st.state == .signedIn {
                if let e = st.expiresAt, e <= Date() { return ("failed", "this Mac's Claude login has expired — open Claude Code on the Mac to renew it") }
                return ("confirmed", "this Mac's Claude Code login" + (st.identity.map { " (\($0.label))" } ?? "") + (st.subscriptionType.map { ", \($0)" } ?? ""))
            }
            return ("failed", "Claude Code is not signed in on this Mac (\(st.state.rawValue)) — run claude on the Mac and /login")
        case "github":
            guard choice != "off" else { return ("off", "off") }
            let t = Access.githubToken(source: source ?? "gh", keychain: services.keychain, environment: env)
            guard let token = t.secret else { return ("failed", t.notice ?? "no GitHub token") }
            let override = GitHubLogin.testUpstream(environment: env)
            let result = await Task.detached { GitHubAccess.confirm(token: token, override: override) }.value
            switch result {
            case .success(let who): return ("confirmed", who.summary + " (from \(source == "key" ? "your key" : "this Mac's gh login"))")
            case .failure(let f): return ("failed", f.reason)
            }
        default:
            guard choice == "on" else { return ("off", "off") }
            guard let sock = GitHubLogin.agentSocket(environment: env) else {
                return ("failed", "this Mac has no ssh-agent to forward (SSH_AUTH_SOCK is not set or not a socket)")
            }
            switch SSHAgentRelay.listKeys(socket: sock) {
            case .success(let keys) where keys.isEmpty: return ("failed", "the ssh-agent has no keys — ssh-add on the Mac")
            case .success(let keys):
                return ("confirmed", "the ssh-agent has \(keys.count) key\(keys.count == 1 ? "" : "s")" + (keys.isEmpty ? "" : ": " + keys.prefix(3).joined(separator: ", ")))
            case .failure(let f): return ("failed", f.reason)
            }
        }
    }

    /// `access-github-key`: set or remove the default GitHub key (the login keychain; never echoed).
    func setAccessGithubKey(_ r: HostRequest) throws -> AccessReport {
        if r.clearSetting == true {
            try? services.keychain.delete(service: Access.githubKeyService, account: Keychain.user)
            note(nil, "access: the default GitHub key was removed")
        } else {
            guard let s = r.secret?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, !s.contains(where: { $0.isWhitespace }),
                  s.utf8.count <= 4096 else {
                throw HostError(.invalid, "an empty (or not one-word) GitHub token")
            }
            try services.keychain.write(service: Access.githubKeyService, account: Keychain.user, secret: s)
            note(nil, "access: a default GitHub key was set (keychain \(Access.githubKeyService); the sandboxes of github.credentials = key use it)")
        }
        var record = AccessRecord.load(accessRecordURL)
        record.entries["github"] = nil                    // a new key: the last answer no longer applies
        try? record.write(accessRecordURL)
        for m in managed.values { applyGitHub(m) }        // a sandbox reading the default key reads it again
        let report = AccessReport(items: [], githubKeySet: services.keychain.read(service: Access.githubKeyService, account: Keychain.user).value != nil)
        return report
    }
}
