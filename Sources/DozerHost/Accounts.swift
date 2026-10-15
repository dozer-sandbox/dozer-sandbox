import Foundation
import DozerKit

// 588 — named Anthropic credentials the host holds for its sandboxes (the multi-account model).
//
//   mac          the Mac's own Claude Code login (one per Claude config dir; `mac` is built in).
//                Read-only for doz; renewed by the Mac's Claude Code.
//   setup-token  a `claude setup-token` token (1 year, user:inference, no refresh token), kept in
//                the login keychain as `doz-claude:<name>`.
//   api-key      an Anthropic API key, in `doz-anthropic:<name>` (or an item the user names).
//
// `<store>/accounts.json` holds the metadata — names, kinds, keychain service names, plans,
// identities, fingerprints, dates, the store's default account and the keep-alive switch — and
// NEVER a secret. A sandbox follows the store default or pins one account; there is no silent
// fallback to another account or to an API key.

public enum AccountKind: String, Codable, Sendable, CaseIterable {
    case mac
    case setupToken = "setup-token"
    case apiKey = "api-key"
    /// 599i: an OpenAI API key (`doz-openai:NAME`) — Codex.
    case openaiKey = "openai-key"
    /// 599i: a ChatGPT plan through Dozer's OWN sign-in on this Mac (`doz account add NAME --chatgpt`):
    /// the tokens in `doz-chatgpt:NAME`, refreshed by the host — never the Mac's own ~/.codex login.
    case chatgpt
    /// 599i rc.3: THIS Mac's own Codex login, read-only (the account `mac` of a Codex sandbox) — never written.
    case codexMac = "codex-mac"
    /// 617: an API key of a key provider (`AccountRecord.provider`: xai, google) in `doz-<provider>:NAME`.
    case key

    /// The vault binding its secret goes in (a `key` account's is its provider's — `AccountRecord.binding`).
    public var binding: CredentialBinding {
        switch self {
        case .apiKey: .anthropic
        case .mac, .setupToken: .claudeOAuth
        case .openaiKey: .openai
        case .chatgpt, .codexMac: .chatgpt
        case .key: CredentialBinding(id: "key:?", hosts: [], header: .bearer)       // never used: see AccountRecord.binding
        }
    }

    /// 599i: whose credential it is — `anthropic` (Claude Code, pi) or `openai` (Codex). 617: `key` — its record's provider.
    public var provider: String {
        switch self {
        case .openaiKey, .chatgpt, .codexMac: "openai"
        case .key: "key"
        default: "anthropic"
        }
    }
}

public struct AccountRecord: Codable, Equatable, Sendable {
    public var name: String
    public var kind: AccountKind
    /// setup-token / api-key: the keychain item holding the secret.
    public var keychainService: String?
    /// The item was the user's before doz knew it (`--keychain SERVICE`): never deleted by doz.
    public var adopted: Bool?
    /// mac: the Claude config dir (nil: the default one).
    public var configDir: String?
    /// `max`, `pro`, `team`, `enterprise` — the guest's CLAUDE_CODE_SUBSCRIPTION_TYPE.
    public var plan: String?
    public var tier: String?
    /// mac: the identity sandboxes follow (a different account signing in on the Mac holds them).
    public var identity: ClaudeIdentity?
    /// First 12 hex of the secret's sha256 (so the log can recognise it in a guest's hands).
    public var fingerprint: String?
    public var addedAt: Date
    public var expiresAt: Date?
    public var verifiedAt: Date?
    /// `verified`, `rejected: …`, `unverified: …`.
    public var verification: String?
    /// 599i: a ChatGPT sign-in's email and account id (from its id_token's claims) — not secrets.
    public var email: String?
    public var accountID: String?
    /// 617: a `key` account's key provider (`xai`, `google`, `custom`) — nil for every other kind (and in every older file).
    public var provider: String?
    /// 617 (§7): where the key is read from — nil = the keychain item `keychainService` (every older record).
    public var source: SecretSource?
    /// 617: the allow-listed, non-secret tool variables its source runs with (`OP_ACCOUNT`, `AWS_PROFILE`, …).
    public var sourceEnv: [String: String]?
    /// 617: how long a value read from its source is kept in the host's memory (default 3300 s).
    public var ttlSeconds: Int?
    /// 617 (D6): a custom key — the hosts it may go to and how (never a secret).
    public var custom: CustomKey?

    /// The source in effect (a record without one: its keychain item).
    public var effectiveSource: SecretSource? { source ?? keychainService.map { .keychain(service: $0) } }

    /// Read on use from a tool (1Password, AWS, a command) rather than the keychain.
    public var readsOnUse: Bool { source.map { !$0.isKeychain } ?? false }

    /// 617: whose credential it is — the provider of a `key` account, the kind's otherwise.
    public var providerID: String { kind == .key ? (provider ?? "") : kind.provider }

    /// 617: as a person reads it ("an xAI API key").
    public var label: String {
        if let c = custom { return c.label }
        guard kind == .key, let p = provider.flatMap({ KeyProviders.provider($0) }) else { return kind.label }
        return "a \(p.title) key"
    }

    /// 617: the vault binding its secret goes in.
    public var binding: CredentialBinding {
        guard kind == .key else { return kind.binding }
        if let c = custom { return c.binding(account: name) }
        return provider.flatMap { KeyProviders.provider($0) }?.binding ?? kind.binding
    }

    public init(name: String, kind: AccountKind, keychainService: String? = nil, adopted: Bool? = nil, configDir: String? = nil,
                plan: String? = nil, tier: String? = nil, identity: ClaudeIdentity? = nil, fingerprint: String? = nil,
                addedAt: Date = Date(), expiresAt: Date? = nil, verifiedAt: Date? = nil, verification: String? = nil) {
        self.name = name
        self.kind = kind
        self.keychainService = keychainService
        self.adopted = adopted
        self.configDir = configDir
        self.plan = plan
        self.tier = tier
        self.identity = identity
        self.fingerprint = fingerprint
        self.addedAt = addedAt
        self.expiresAt = expiresAt
        self.verifiedAt = verifiedAt
        self.verification = verification
    }

    /// The built-in Mac login.
    public static let mac = AccountRecord(name: "mac", kind: .mac, addedAt: Date(timeIntervalSince1970: 0))
    /// 599i rc.3: `mac` for a Codex sandbox — this Mac's Codex login (never in accounts.json).
    public static let codexMac = AccountRecord(name: "mac", kind: .codexMac, addedAt: Date(timeIntervalSince1970: 0))
}

/// 617 (D6): a custom key's binding — like Docker's `set-custom`: the exact hosts it may go to, the header and its
/// format, the variable its placeholder is in. Swap-only (never added to a request without its placeholder), and only
/// ever on hosts the sandbox's policy allows on purpose (`--allow site:HOST`).
public struct CustomKey: Codable, Equatable, Sendable {
    public var hosts: [String]
    /// `authorization` (with `Bearer %s`), or any header name (with `%s`).
    public var header: String
    public var format: String
    public var env: String

    public init(hosts: [String], header: String, format: String, env: String) {
        self.hosts = hosts.map { $0.lowercased() }
        self.header = header.lowercased()
        self.format = format
        self.env = env
    }

    public func binding(account: String) -> CredentialBinding {
        let h: CredentialHeader = format == "Bearer %s" ? .bearer : .apiKey(name: header)
        return CredentialBinding(id: "custom:" + account, hosts: hosts, header: h, environmentVariable: env, swapOnly: true)
    }

    public func validate() throws {
        guard !hosts.isEmpty, hosts.count <= 8 else { throw HostError(.invalid, "a custom key needs --host (1–8 exact hosts)") }
        for h in hosts where h.range(of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#, options: .regularExpression) == nil {
            throw HostError(.invalid, "--host \(h): an exact host name like api.example.com")
        }
        for h in hosts where KeyProviders.owning(host: h) != nil || GitHubAccess.credentialHosts.contains(h) || OpenAIAccess.isOpenAIHost(h) {
            throw HostError(.invalid, "--host \(h) is a host Dozer already holds keys for — use that account kind instead")
        }
        guard env.range(of: "^[A-Z][A-Z0-9_]{1,63}$", options: .regularExpression) != nil, !env.hasPrefix("DOZ_") else {
            throw HostError(.invalid, "--env-var: an upper-case variable name like EXAMPLE_API_KEY")
        }
        guard ["%s", "Bearer %s"].contains(format) else { throw HostError(.invalid, "--format: %s (the key as it is) or use --bearer") }
        if format == "Bearer %s", header != "authorization" { throw HostError(.invalid, "--bearer goes in the Authorization header") }
        guard header.range(of: "^[a-z][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
              !["host", "cookie", "content-length", "transfer-encoding", "connection"].contains(header) else {
            throw HostError(.invalid, "--header: a header name like x-api-key")
        }
    }

    /// "a custom key for api.example.com".
    public var label: String { "a custom key for \(hosts.joined(separator: ", "))" }
}

public struct AccountsFile: Codable, Equatable, Sendable {
    public var version = 1
    /// The account a sandbox that follows the default uses (`none`: no credential).
    public var defaultAccount: String = "mac"
    /// D3: run the Mac's own `claude` near expiry while a sandbox uses the Mac login (off by default).
    public var keepalive: Bool = false
    public var accounts: [AccountRecord] = []
    /// 599i: the OpenAI account Codex sandboxes that follow the default use (nil: none — never an
    /// Anthropic account). `doz account default NAME` with an OpenAI account sets it.
    public var openaiDefault: String?
    /// 617: each key provider's default account (`xai` → `work-xai`); nil — none chosen.
    public var providerDefaults: [String: String]?

    public init() {}

    /// 599i: the default account that applies to a sandbox of `image` (Codex: the OpenAI one; 617: a key agent: its
    /// provider's).
    public func defaultAccount(for image: String?) -> String {
        AgentCredentials.defaultAccount(for: image, anthropic: defaultAccount, openai: openaiDefault, providers: providerDefaults ?? [:],
                                        kinds: Dictionary(accounts.map { ($0.name, $0.kind) }) { a, _ in a })
    }
}

/// `<store>/accounts.json`.
public struct AccountStore: Sendable {
    public let url: URL
    /// 591: the keep-alive of a store that has no accounts.json yet (the settings' `host.keepalive`);
    /// once a store saved its own choice (`doz account keepalive`), that wins.
    public let newStoreKeepalive: Bool
    /// 594: the default account of a store with no accounts.json yet (the settings' `defaults.account`).
    public let newStoreDefault: String
    public init(store: DozerStore, newStoreKeepalive: Bool = false, newStoreDefault: String = "mac") {
        url = store.root.appendingPathComponent("accounts.json")
        self.newStoreKeepalive = newStoreKeepalive
        self.newStoreDefault = newStoreDefault
    }

    /// The store's accounts, with the settings' `host.keepalive` and `defaults.account` for a store
    /// that has not chosen.
    public init(store: DozerStore, settings: DozerSettings) {
        self.init(store: store, newStoreKeepalive: settings.bool(SettingKey.keepalive),
                  newStoreDefault: settings.string(SettingKey.defaultAccount) ?? "mac")
    }

    public static let reserved: Set<String> = ["default", "none"]
    public static let setupTokenPrefix = "doz-claude:"
    public static let apiKeyPrefix = "doz-anthropic:"
    /// 599i: an OpenAI API key, and a ChatGPT sign-in's tokens (a JSON document, never on disk).
    public static let openaiKeyPrefix = "doz-openai:"
    public static let chatgptPrefix = "doz-chatgpt:"
    /// 617: a key provider's key: `doz-xai:NAME`, `doz-google:NAME`.
    public static func keyPrefix(_ provider: String) -> String { "doz-\(provider):" }

    /// 617: a keychain item Dozer made for an account (and so may delete): one of the prefixes above.
    public static func isDozItem(_ service: String) -> Bool {
        [setupTokenPrefix, apiKeyPrefix, openaiKeyPrefix, chatgptPrefix, keyPrefix("custom")].contains(where: service.hasPrefix)
            || KeyProviders.all.filter { $0.builtinBinding == nil }.contains { service.hasPrefix(keyPrefix($0.id)) }
    }
    /// A setup token lives one year (`claude setup-token`: 31 536 000 s).
    public static let setupTokenLifetime: TimeInterval = 31_536_000

    public func load() -> AccountsFile {
        var fresh = AccountsFile()
        if !FileManager.default.fileExists(atPath: url.path) {
            fresh.keepalive = newStoreKeepalive
            fresh.defaultAccount = newStoreDefault
        }
        var f = (try? Data(contentsOf: url)).flatMap { try? HostWire.decoder.decode(AccountsFile.self, from: $0) } ?? fresh
        if !f.accounts.contains(where: { $0.name == "mac" }) { f.accounts.insert(.mac, at: 0) }
        return f
    }

    public func save(_ f: AccountsFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try HostWire.prettyEncoder.encode(f).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func validateName(_ n: String) throws {
        guard n.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil else {
            throw HostError(.invalid, "an account name is 1–40 characters of a-z 0-9 - (got \(n))")
        }
        guard !reserved.contains(n) else { throw HostError(.invalid, "\(n) is reserved — pick another account name") }
    }

    /// A pasted setup token: `CLAUDE_CODE_OAUTH_TOKEN=` and quotes removed, and any whitespace a
    /// terminal wrapped into it (a token has none) — the same normalisation an earlier project's login import used.
    public static func normalizeToken(_ raw: String) -> String? {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for assignment in ["CLAUDE_CODE_OAUTH_TOKEN=", "ANTHROPIC_API_KEY="] {
            if let r = v.range(of: assignment) { v = String(v[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if v.count >= 2, (v.first == "\"" && v.last == "\"") || (v.first == "'" && v.last == "'") { v.removeFirst(); v.removeLast() }
        let compact = String(v.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
        return compact.count >= 20 ? compact : nil
    }
}

extension HostRequest {
    /// The request `doz account add` sends — the ONE path a secret takes into an account (594: `doz
    /// onboard`'s account step and the web UI's masked field build it here too). The host keeps the
    /// secret in the login keychain (`doz-claude:NAME` / `doz-anthropic:NAME`) after one check request.
    public static func accountAdd(name: String, kind: AccountKind, plan: String?, secret: String?, verify: Bool = true, force: Bool = false,
                                  configDir: String? = nil, keychain: String? = nil) -> HostRequest {
        var r = HostRequest(.accountAdd)
        r.account = name
        r.accountKind = kind.rawValue
        r.plan = plan
        r.configDir = configDir
        r.keychainService = keychain
        r.verify = verify
        r.force = force
        r.secret = secret
        return r
    }

    /// 617: a key of a key provider (`--provider xai|google`) — the same one path.
    public static func keyAccountAdd(name: String, provider: String, secret: String?, verify: Bool = true, force: Bool = false,
                                     keychain: String? = nil) -> HostRequest {
        var r = accountAdd(name: name, kind: .key, plan: nil, secret: secret, verify: verify, force: force, keychain: keychain)
        r.provider = provider
        return r
    }

    /// The request `doz key set NAME --anthropic` sends — the ONE path a sandbox's own key takes (594:
    /// the web UI's masked field builds it here too). The host holds it in memory (a stdin/prompt/browser
    /// key lasts while the host runs), gives the guest a placeholder, and forgets the other credential.
    public static func keySet(name: String, secret: String, source: String) -> HostRequest {
        var r = HostRequest(.keySet, name: name)
        r.binding = CredentialBinding.anthropic.id
        r.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        r.source = source
        return r
    }
}

/// `account ls` — never a secret.
public struct AccountRow: Codable, Equatable, Sendable {
    public var name: String
    public var kind: String
    public var plan: String?
    public var identity: String?
    public var expiresAt: Date?
    public var verification: String?
    public var isDefault: Bool
    public var usedBy: [String]
    /// `ok`, `expires-soon`, `expired`, `signed-out`, `missing`, `locked`, `rejected` (its provider refused it at the
    /// last check), `unavailable` (its source could not be read), `unchecked` (read on use, not read yet)…
    public var state: String

    /// 617: a key's state once its last check is known — a key the provider REFUSED (`verification` "rejected: …") is
    /// `rejected`, never `ok`. A state that already says the key cannot be used (missing, locked, expired, unavailable)
    /// is kept: that is the first thing to fix. Never checked stays as it is (`ok` from the keychain, `unchecked`).
    public static func keyState(_ state: String, verification: String?) -> String {
        guard verification?.hasPrefix("rejected") == true, ["ok", "expires-soon", "unchecked"].contains(state) else { return state }
        return "rejected"
    }
    public var keychainService: String?
    public var fingerprint: String?
    /// 617: whose key it is (`anthropic`, `openai`, `xai`, `google`, `custom`).
    public var provider: String?
    /// 617 (§7): where its key is read from, as a person reads it ("1Password: op://Dev/xai/credential") — never a value.
    public var sourceLabel: String?
    /// 617: the last read from that source: `ok`, `failed`, or `unchecked` (not read since this host started).
    public var sourceState: String?
    /// 617: why the last read failed (the proxy's 401 says the same) — the cause and the fix, never a value.
    public var sourceProblem: String?
    /// 617 (D6): a custom key's hosts.
    public var hosts: [String]?
    /// 617: when `verification` was decided — history ("last verified 12 Oct 16:21"), not a live state.
    public var verifiedAt: Date? = nil
}

// MARK: verification

public enum AccountVerification: Equatable, Sendable {
    case verified
    /// The API said 401/403: the credential is bad.
    case rejected(String)
    /// Network, 5xx, quota — says nothing about the credential.
    case unavailable(String)
}

public protocol AccountVerifying: Sendable {
    func verify(kind: AccountKind, secret: String) async -> AccountVerification
    /// 617: with a `key` account's provider.
    func verify(kind: AccountKind, secret: String, provider: String?) async -> AccountVerification
}

extension AccountVerifying {
    public func verify(kind: AccountKind, secret: String, provider: String?) async -> AccountVerification {
        await verify(kind: kind, secret: secret)
    }
}

/// 617 TEST SEAM: `DOZ_TEST_PROVIDER_UPSTREAM=host:port` + `DOZ_TEST_PROVIDER_CA=<pem>` — the key providers' hosts (the
/// proxy's leg, the key check) go to a fake provider, trusting ONLY that CA.
public enum ProviderSeam {
    public static func upstream(environment env: [String: String] = ProcessInfo.processInfo.environment) -> EgressProxy.UpstreamOverride? {
        guard let u = env["DOZ_TEST_PROVIDER_UPSTREAM"], !u.isEmpty, let caPath = env["DOZ_TEST_PROVIDER_CA"],
              let pem = try? String(contentsOfFile: caPath, encoding: .utf8) else { return nil }
        let parts = u.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
        return EgressProxy.UpstreamOverride(host: String(parts[0]), port: port, anchorsPEM: pem)
    }

    /// 617 PROFILING SEAM: `DOZ_TEST_PROFILE_NETWORK=1` — every allowed HTTPS request is decrypted and logged.
    public static func profiling(environment env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        env["DOZ_TEST_PROFILE_NETWORK"] == "1"
    }

    /// 617: more hosts the seam sends to the fake (`DOZ_TEST_PROVIDER_HOSTS=a.example,b.example`) — only with the seam set.
    public static func extraHosts(environment env: [String: String] = ProcessInfo.processInfo.environment) -> Set<String> {
        guard upstream(environment: env) != nil, let s = env["DOZ_TEST_PROVIDER_HOSTS"] else { return [] }
        return Set(s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }

    /// 617: a key provider's check, over the proxy's leg (the seam's fake in tests).
    static func check(provider: String?, secret: String) async -> AccountVerification {
        if provider == "custom" { return .unavailable("a custom key has no check") }
        guard let p = provider.flatMap({ KeyProviders.provider($0) }) else { return .unavailable("no provider") }
        let override = upstream()
        return await Task.detached {
            switch p.checkKey(secret, override: override) {
            case .success(let r) where r.good: return AccountVerification.verified
            case .success(let r): return .rejected("HTTP \(r.status) from \(p.check.flatMap { URL(string: $0.url)?.host } ?? p.title)")
            case .failure(let f): return .unavailable(f.reason)
            }
        }.value
    }
}

/// One minimal request, from the host, to api.anthropic.com only: `POST /v1/messages`, haiku,
/// `max_tokens: 1`, the credential in its header. 200 verified · 401/403 rejected · else unavailable.
/// 617: and a key provider's own check (`KeyProvider.check`: xAI `GET /v1/api-key`, Google `GET /v1beta/models`).
public struct AnthropicVerifier: AccountVerifying {
    public init() {}

    public func verify(kind: AccountKind, secret: String, provider: String?) async -> AccountVerification {
        if kind == .key { return await ProviderSeam.check(provider: provider, secret: secret) }
        return await verify(kind: kind, secret: secret)
    }

    public func verify(kind: AccountKind, secret: String) async -> AccountVerification {
        // 599i: an OpenAI key — one GET api.openai.com/v1/models (over the proxy's leg; the test seam's CA in tests).
        if kind == .openaiKey {
            let override = OpenAISeam.upstream()
            return await Task.detached {
                switch OpenAIAccess.checkKey(secret, override: override) {
                case .success(true): return AccountVerification.verified
                case .success(false): return .rejected("HTTP 401")
                case .failure(let f): return .unavailable(f.reason)
                }
            }.value
        }
        if kind == .chatgpt { return .verified }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if kind == .apiKey {
            req.setValue(secret, forHTTPHeaderField: "x-api-key")
        } else {
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        }
        req.httpBody = Data(#"{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}"#.utf8)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let msg = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
            switch code {
            case 200: return .verified
            case 401, 403: return .rejected(msg ?? "HTTP \(code)")
            default: return .unavailable("HTTP \(code)" + (msg.map { ": \($0)" } ?? ""))
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}
