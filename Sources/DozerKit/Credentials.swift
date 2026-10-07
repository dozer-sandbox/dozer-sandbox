import CryptoKit
import Foundation

// Feature 580 Phase 2 — credentials that never enter the sandbox.
//
// A binding says: this secret is for requests to THIS host, in THIS header. The guest gets only a
// placeholder (`doz_cred_…`, the right shape for an SDK that insists on a key, and no power
// anywhere); the host proxy decrypts TLS for bound hosts only, and on each request:
//   - a header carrying a placeholder minted for this host   → the real secret is swapped in;
//   - no auth header at all                                   → the secret is injected (Omnigent's
//                                                               default "swap-on-access" mode);
//   - a placeholder minted for ANOTHER host, or unknown       → 403 and a log entry (leak guard);
//   - a real-looking credential the tool supplied itself      → (588) classified by kind and
//                                                               fingerprint: passed through and
//                                                               flagged, or (strict) refused — and
//                                                               NEVER gets our secret injected beside it.
// The secret lives only in the host process (never written to disk, never in the guest).

/// Where a secret goes on the wire.
public enum CredentialHeader: Sendable, Codable, Equatable {
    /// `x-api-key: <secret>` (Anthropic).
    case apiKey(name: String)
    /// `Authorization: Bearer <secret>`.
    case bearer

    public static let xAPIKey = CredentialHeader.apiKey(name: "x-api-key")

    public var headerName: String {
        switch self {
        case .apiKey(let name): name.lowercased()
        case .bearer: "authorization"
        }
    }

    /// The header value for `secret`.
    public func value(_ secret: String) -> String {
        switch self {
        case .apiKey: secret
        case .bearer: "Bearer \(secret)"
        }
    }
}

/// A secret's binding: which host(s) it may be sent to, in which header, and which guest
/// environment variable carries its placeholder.
public struct CredentialBinding: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    /// Exact host names the secret is for (the proxy decrypts TLS for these, and only these).
    public var hosts: [String]
    public var header: CredentialHeader
    /// The guest environment variable a session gets the placeholder in, e.g. `ANTHROPIC_API_KEY`.
    public var environmentVariable: String?
    /// 599d: more variables that carry the SAME placeholder (`GITHUB_TOKEN` beside `GH_TOKEN`).
    /// Optional: a record written before 599d decodes without it.
    public var alsoEnvironmentVariables: [String]?
    /// 599d: true — the secret is only ever SWAPPED for a placeholder the request carries, never added
    /// to a request without one (GitHub: an anonymous clone stays anonymous unless git asked for a login).
    public var swapOnly: Bool?

    public init(id: String, hosts: [String], header: CredentialHeader, environmentVariable: String? = nil,
                alsoEnvironmentVariables: [String]? = nil, swapOnly: Bool? = nil) {
        self.id = id
        self.hosts = hosts.map { $0.lowercased() }
        self.header = header
        self.environmentVariable = environmentVariable
        self.alsoEnvironmentVariables = alsoEnvironmentVariables
        self.swapOnly = swapOnly
    }

    /// 599d: the user's GitHub login ("Use GitHub as you"): `GH_TOKEN`/`GITHUB_TOKEN` for `gh`, and git's
    /// credential helper (`git-credential-doz`) answers with the same placeholder as git's Basic password.
    /// The proxy swaps it on these hosts only — in `Authorization: Bearer|token …` AND inside
    /// `Authorization: Basic base64(user:…)` (decoded, swapped, re-encoded) — and never adds it.
    public static let github = CredentialBinding(id: "github", hosts: GitHubAccess.credentialHosts, header: .bearer,
                                                 environmentVariable: "GH_TOKEN", alsoEnvironmentVariables: ["GITHUB_TOKEN"],
                                                 swapOnly: true)

    /// Every variable a session gets this binding's placeholder in.
    public var placeholderVariables: [String] { (environmentVariable.map { [$0] } ?? []) + (alsoEnvironmentVariables ?? []) }

    /// Anthropic's API key: `x-api-key` on api.anthropic.com, `ANTHROPIC_API_KEY` in the guest.
    public static let anthropic = CredentialBinding(id: "anthropic", hosts: ["api.anthropic.com"], header: .xAPIKey,
                                                    environmentVariable: "ANTHROPIC_API_KEY")

    /// A Claude subscription login: an OAuth ACCESS token, `Authorization: Bearer` on
    /// api.anthropic.com, `CLAUDE_CODE_OAUTH_TOKEN` in the guest. Only the access token is ever
    /// held — never the refresh token, which the Mac's own Claude Code keeps using (a sandbox that
    /// refreshed it would sign the Mac out).
    public static let claudeOAuth = CredentialBinding(id: "claude-oauth", hosts: ["api.anthropic.com"], header: .bearer,
                                                      environmentVariable: "CLAUDE_CODE_OAUTH_TOKEN")

    /// 599i: an OpenAI API key (Codex): `Authorization: Bearer` on api.openai.com, `OPENAI_API_KEY` in the
    /// guest (and in Codex's auth.json, written at each session start).
    public static let openai = CredentialBinding(id: "openai", hosts: OpenAIAccess.apiHosts, header: .bearer,
                                                 environmentVariable: "OPENAI_API_KEY")

    /// 599i: a ChatGPT plan through Dozer's own sign-in: the ACCESS token, `Authorization: Bearer` on
    /// chatgpt.com — swap-only (only ever in place of the placeholder Codex's auth.json holds; no
    /// variable). auth.openai.com is covered so the proxy decrypts it: Codex's own refresh request is
    /// answered there by the proxy and never forwarded (`EgressProxy.chatgptRenewal`).
    public static let chatgpt = CredentialBinding(id: "chatgpt", hosts: OpenAIAccess.chatgptHosts + [OpenAIAccess.authHost], header: .bearer,
                                                  swapOnly: true)

    public func covers(_ host: String) -> Bool { hosts.contains(host.lowercased()) }
}

/// What the proxy does with a credential the guest supplied itself (588) — a real-looking key or
/// token in an auth header that doz never issued (a guest `/login`, a pasted key).
public enum ForeignCredentialPolicy: String, Sendable, Codable, CaseIterable {
    /// Pass it through, and flag it (log verdict, a sighting with a fingerprint).
    case allow
    /// Refuse it (403 with an explanation): the sandbox is pinned to the credential doz holds.
    case strict
}

/// A credential the guest used that doz never issued. Never the value: its kind, the prefix up
/// to its version (`sk-ant-oat01`), and the first 12 hex of its sha256.
public struct ForeignCredential: Sendable, Codable, Equatable {
    /// `oauth`, `api-key`, `admin-key` or `other`.
    public var kind: String
    public var prefix: String
    public var fingerprint: String
    /// The header it came in (`authorization`, `x-api-key`).
    public var header: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var requests: Int
    /// When it is also a credential doz holds under a name (an account), that name.
    public var matches: String?

    public init(kind: String, prefix: String, fingerprint: String, header: String, firstSeen: Date, lastSeen: Date,
                requests: Int, matches: String? = nil) {
        self.kind = kind
        self.prefix = prefix
        self.fingerprint = fingerprint
        self.header = header
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.requests = requests
        self.matches = matches
    }

    /// `own credential (oauth sk-ant-oat01…, fp ab12cd34ef56)`.
    public var label: String {
        "own credential (\(kind) \(prefix)…, fp \(fingerprint)\(matches.map { " — same as account \($0)" } ?? ""))"
    }
}

/// Fingerprints and kinds of credential values (never the value itself).
public enum CredentialFingerprint {
    /// First 12 hex of sha256 of the value (without a `Bearer ` scheme).
    public static func of(_ value: String) -> String {
        let v = bare(value)
        return SHA256.hash(data: Data(v.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// sha256 hex of a placeholder (what is persisted so a new host knows it — never the placeholder).
    public static func placeholderHash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func bare(_ value: String) -> String {
        let t = value.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("bearer ") { return String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        return t
    }

    /// `oauth` / `api-key` / `admin-key` / `other`.
    public static func kind(_ value: String) -> String {
        let v = bare(value)
        if v.hasPrefix("sk-ant-oat") { return "oauth" }
        if v.hasPrefix("sk-ant-api") { return "api-key" }
        if v.hasPrefix("sk-ant-admin") { return "admin-key" }
        return "other"
    }

    /// The value up to its version (`sk-ant-oat01`), at most 13 characters; `?` for anything else.
    public static func prefix(_ value: String) -> String {
        let v = bare(value)
        guard v.hasPrefix("sk-") else { return "?" }
        let parts = v.split(separator: "-", maxSplits: 3, omittingEmptySubsequences: false)
        return String(parts.prefix(3).joined(separator: "-").prefix(13))
    }
}

/// The host-side vault: secrets (memory only), bindings, and the placeholders minted for them.
///
/// **Placeholder lifecycle.** Each `mint` returns a NEW token for one binding — one per session
/// start — so a token is never shared between sessions or sandboxes, and `revokeAll` (on stop)
/// kills every token at once. A token is reusable for that session's requests (an SDK sends its
/// key on every request); "single-use" here means single ISSUE, never reused or re-issued.
///
/// **588.** A placeholder's sha256 can be handed to a NEW vault (`restorePlaceholderHashes`) so a
/// session that survived a host restart keeps working; a secret can carry an expiry, a notice
/// (why it is missing — the proxy's 401 text) and non-secret session variables; a credential the
/// guest supplied itself is classified, flagged or (strict) refused, and never gets our secret
/// injected beside it.
public final class CredentialVault: @unchecked Sendable {
    public static let placeholderPrefix = "doz_cred_"

    private let lock = NSLock()
    private var bindings: [String: CredentialBinding] = [:]
    private var secrets: [String: String] = [:]
    /// token → binding id
    private var placeholders: [String: String] = [:]
    /// sha256(token) → binding id: placeholders a previous host minted (588, D8).
    private var restoredHashes: [String: String] = [:]
    private var expiries: [String: Date] = [:]
    private var notices: [String: String] = [:]
    private var extras: [String: [String: String]] = [:]
    private var lastUse: [String: Date] = [:]
    private var sightings: [String: ForeignCredential] = [:]
    private var labels: [String: String] = [:]
    private var _policy: ForeignCredentialPolicy = .allow
    private var _strictNotice: String?

    /// Called (from a proxy thread, never under the vault's lock) when a secret about to be used
    /// has expired, or the upstream answered 401 to a request that carried it: the owner re-reads
    /// its source and `set`s the secret again (or not). Then the request is decided again.
    public var onStale: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onStale }
        set { lock.lock(); _onStale = newValue; lock.unlock() }
    }
    private var _onStale: (@Sendable (String) -> Void)?
    /// The first sighting of each foreign credential (by fingerprint).
    public var onForeign: (@Sendable (ForeignCredential) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onForeign }
        set { lock.lock(); _onForeign = newValue; lock.unlock() }
    }
    private var _onForeign: (@Sendable (ForeignCredential) -> Void)?
    /// Placeholders were minted or revoked (the owner persists `placeholderHashes`).
    public var onPlaceholdersChanged: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onPlaceholders }
        set { lock.lock(); _onPlaceholders = newValue; lock.unlock() }
    }
    private var _onPlaceholders: (@Sendable () -> Void)?
    /// 599d: a request used binding `id`'s secret (swapped or injected) — the owner tells the user on
    /// first use. Called on a proxy thread, never under the vault's lock.
    public var onUse: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onUse }
        set { lock.lock(); _onUse = newValue; lock.unlock() }
    }
    private var _onUse: (@Sendable (String) -> Void)?

    /// 599d: a secret READ ON USE from its source (the Mac's `gh auth token`, a keychain item), kept in
    /// memory for `ttl` seconds, then read again on the next request that needs it. Never persisted.
    public typealias SecretRead = (secret: String?, notice: String?)
    private var providers: [String: (ttl: TimeInterval, version: (@Sendable () -> String)?, read: @Sendable () -> SecretRead)] = [:]
    private var fetchedAt: [String: Date] = [:]
    private var fetchedVersion: [String: String] = [:]

    public init() {}

    /// 599d: bind `binding` to a source read on use (see `SecretRead`); any secret held before is dropped.
    /// `version` (cheap, asked on every request that needs it): when it changes — the user chose another
    /// source — the cached read is dropped at once, not after `ttl`.
    public func setProvider(_ binding: CredentialBinding, ttl: TimeInterval, version: (@Sendable () -> String)? = nil,
                            read: @escaping @Sendable () -> SecretRead) {
        lock.lock(); defer { lock.unlock() }
        bindings[binding.id] = binding
        providers[binding.id] = (ttl, version, read)
        fetchedAt[binding.id] = nil
        fetchedVersion[binding.id] = nil
        secrets[binding.id] = nil
        notices[binding.id] = nil
    }

    /// Whether sessions get a placeholder for `id`: it holds a secret, or reads one on use.
    public func issuesPlaceholder(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return secrets[id] != nil || providers[id] != nil
    }

    /// Read the providers of `host`'s bindings whose secret is missing or older than their ttl — OUTSIDE
    /// the lock (a source may be a process).
    func refreshProviders(host: String, now: Date = Date()) {
        lock.lock()
        let mine = providers.filter { id, _ in bindings[id]?.covers(host) == true }
        let fetched = fetchedAt, versions = fetchedVersion
        lock.unlock()
        for (id, p) in mine {
            let version = p.version?() ?? ""
            let stale = fetched[id].map { now.timeIntervalSince($0) >= p.ttl } ?? true
            guard stale || versions[id] != version else { continue }
            let r = p.read()
            lock.lock()
            if providers[id] != nil {
                secrets[id] = r.secret.flatMap { $0.isEmpty ? nil : $0 }
                notices[id] = secrets[id] == nil ? r.notice : nil
                fetchedAt[id] = now
                fetchedVersion[id] = version
            }
            lock.unlock()
        }
    }

    /// Forget the cached reads (the next request reads its source again).
    public func expireProviders() {
        lock.lock(); fetchedAt.removeAll(); lock.unlock()
    }

    public func set(_ binding: CredentialBinding, secret: String?) {
        lock.lock(); defer { lock.unlock() }
        bindings[binding.id] = binding
        secrets[binding.id] = secret.flatMap { $0.isEmpty ? nil : $0 }
        if secrets[binding.id] != nil { notices[binding.id] = nil }
    }

    /// A secret with its expiry, the non-secret variables a session gets beside its placeholder
    /// (e.g. `CLAUDE_CODE_SUBSCRIPTION_TYPE`), and — when there is no secret — why (`notice`: the
    /// proxy answers a request that needs it with 401 and this text).
    public func set(_ binding: CredentialBinding, secret: String?, expiresAt: Date?, environment: [String: String] = [:],
                    notice: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        bindings[binding.id] = binding
        secrets[binding.id] = secret.flatMap { $0.isEmpty ? nil : $0 }
        expiries[binding.id] = expiresAt
        extras[binding.id] = environment.isEmpty ? nil : environment
        notices[binding.id] = notice
    }

    public func remove(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        bindings[id] = nil
        secrets[id] = nil
        expiries[id] = nil
        extras[id] = nil
        notices[id] = nil
        providers[id] = nil
        fetchedAt[id] = nil
        fetchedVersion[id] = nil
        placeholders = placeholders.filter { $0.value != id }
        restoredHashes = restoredHashes.filter { $0.value != id }
    }

    public var allBindings: [CredentialBinding] {
        lock.lock(); defer { lock.unlock() }
        return bindings.values.sorted { $0.id < $1.id }
    }

    public func hasSecret(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return secrets[id] != nil }
    public func expiry(_ id: String) -> Date? { lock.lock(); defer { lock.unlock() }; return expiries[id] }
    public func notice(_ id: String) -> String? { lock.lock(); defer { lock.unlock() }; return notices[id] }
    /// When a request last used binding `id`'s secret (swapped or injected).
    public func lastUsed(_ id: String) -> Date? { lock.lock(); defer { lock.unlock() }; return lastUse[id] }
    /// The non-secret session variables of binding `id` (when it holds a secret).
    public func sessionExtras(_ id: String) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return secrets[id] == nil ? [:] : (extras[id] ?? [:])
    }

    /// What the proxy does with a credential the guest supplied itself, and (strict) what the
    /// refusal says (`{fp}` is replaced by the credential's fingerprint).
    public var foreignPolicy: ForeignCredentialPolicy {
        get { lock.lock(); defer { lock.unlock() }; return _policy }
        set { lock.lock(); _policy = newValue; lock.unlock() }
    }
    public var strictNotice: String? {
        get { lock.lock(); defer { lock.unlock() }; return _strictNotice }
        set { lock.lock(); _strictNotice = newValue; lock.unlock() }
    }

    /// Names for fingerprints of credentials the owner holds (the log says "same as account X").
    public func setFingerprintLabels(_ l: [String: String]) { lock.lock(); labels = l; lock.unlock() }

    /// Every foreign credential seen since this vault was made, oldest first.
    public var foreignSightings: [ForeignCredential] {
        lock.lock(); defer { lock.unlock() }
        return sightings.values.sorted { $0.firstSeen < $1.firstSeen }
    }

    /// Hosts whose TLS the proxy must decrypt (a binding with a secret covers them).
    public var boundHosts: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(bindings.values.filter { secrets[$0.id] != nil || notices[$0.id] != nil || providers[$0.id] != nil }.flatMap(\.hosts))
    }

    /// A fresh placeholder for binding `id` (nil if there is no such binding).
    public func mint(_ id: String) -> String? {
        lock.lock()
        guard bindings[id] != nil else { lock.unlock(); return nil }
        var raw = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytesShim.fill(&raw)
        let token = Self.placeholderPrefix + raw.map { String(format: "%02x", $0) }.joined()
        placeholders[token] = id
        let cb = _onPlaceholders
        lock.unlock()
        cb?()
        return token
    }

    /// The environment a session gets: one fresh placeholder per binding that names a variable,
    /// plus each binding's non-secret session variables.
    public func sessionEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        // Only bindings that hold a secret (as `Sandbox.guestEnvironment` does): a placeholder with
        // nothing behind it would only be refused, and it would steer a tool that prefers one
        // variable (Claude Code: ANTHROPIC_API_KEY over CLAUDE_CODE_OAUTH_TOKEN) the wrong way.
        for b in allBindings where issuesPlaceholder(b.id) {
            if !b.placeholderVariables.isEmpty, let t = mint(b.id) { for v in b.placeholderVariables { env[v] = t } }
            env.merge(sessionExtras(b.id)) { a, _ in a }
        }
        return env
    }

    public func revokeAll() {
        lock.lock()
        placeholders.removeAll()
        restoredHashes.removeAll()
        let cb = _onPlaceholders
        lock.unlock()
        cb?()
    }

    public var livePlaceholderCount: Int { lock.lock(); defer { lock.unlock() }; return placeholders.count + restoredHashes.count }

    /// sha256(placeholder) → binding id, for every live placeholder (what a new host needs).
    public var placeholderHashes: [String: String] {
        lock.lock(); defer { lock.unlock() }
        var out = restoredHashes
        for (t, b) in placeholders { out[CredentialFingerprint.placeholderHash(t)] = b }
        return out
    }

    /// Placeholders a previous vault minted, by hash: they are honoured as if minted here.
    public func restorePlaceholderHashes(_ hashes: [String: String]) {
        lock.lock(); restoredHashes.merge(hashes) { a, _ in a }; lock.unlock()
    }

    /// The upstream answered 401 to a request that carried binding `id`'s secret: re-read it.
    public func upstreamRejected(_ id: String) {
        let cb = onStale
        cb?(id)
    }

    /// 599i: the binding a placeholder was minted for (nil: unknown or revoked).
    public func binding(ofPlaceholder t: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return bindingFor(token: t)
    }

    /// 599i: one fresh placeholder for `id` whose binding issues one (holds a secret, reads one on use, or
    /// says why it has none) — for a placeholder that goes into a FILE in the guest (Codex's auth.json),
    /// not a variable.
    public func mintForFile(_ id: String) -> String? {
        lock.lock()
        let ok = bindings[id] != nil && (secrets[id] != nil || providers[id] != nil || notices[id] != nil)
        lock.unlock()
        return ok ? mint(id) : nil
    }

    private func bindingFor(token t: String) -> String? {
        placeholders[t] ?? restoredHashes[CredentialFingerprint.placeholderHash(t)]
    }

    /// What to do with one request's headers, bound for `host`. Pure but for the sightings and the
    /// last-use times it records: returns the decision and the rewritten head (byte-for-byte
    /// identical except for the one header value it changes). `inject: false` — the connection
    /// has carried the guest's own credential — never adds our secret to a request without one.
    public func rewrite(head: [UInt8], host: String, inject: Bool = true, now: Date = Date()) -> CredentialDecision {
        refreshProviders(host: host.lowercased(), now: now)
        var d = decide(head: head, host: host, inject: inject, now: now, staleCheck: true)
        if case .stale(let id) = d {
            onStale?(id)
            d = decide(head: head, host: host, inject: inject, now: now, staleCheck: false)
        }
        let out = d.publicDecision
        if case .foreign(_, let f) = out, f.requests == 1, let cb = onForeign { cb(f) }
        switch out {
        case .swapped(_, let b), .injected(_, let b): onUse?(b)
        default: break
        }
        return out
    }

    /// Every placeholder a request head carries — in clear, or inside an authorization field's Basic login.
    public static func placeholders(inHead head: [UInt8]) -> [String] {
        var text = String(decoding: head, as: UTF8.self)
        for f in HTTPHead(head)?.fields ?? [] where f.name == "authorization" || f.name == "proxy-authorization" {
            if let d = basicDecoded(String(decoding: head[f.valueRange], as: UTF8.self)) { text += "\n" + d }
        }
        return placeholderTokens(in: text)
    }

    /// 599d: `Basic base64(user:password)` → `user:password` (nil: not Basic, or not decodable).
    static func basicDecoded(_ value: String) -> String? {
        let t = value.trimmingCharacters(in: .whitespaces)
        guard t.count > 6, t.prefix(6).lowercased() == "basic " else { return nil }
        var b = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        let r = b.utf8.count % 4
        if r == 1 { return nil }
        if r > 0 { b += String(repeating: "=", count: 4 - r) }
        guard let d = Data(base64Encoded: b), let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }

    /// 599d: the text a placeholder may hide in, per field: the value, and — for an authorization
    /// field in Basic — its decoded `user:password` too (git's way of sending a login).
    static func searchable(_ value: String, field name: String) -> String {
        guard name == "authorization" || name == "proxy-authorization", let d = basicDecoded(value) else { return value }
        return value + "\n" + d
    }

    private enum Internal {
        case decided(CredentialDecision)
        case stale(String)
        var publicDecision: CredentialDecision {
            switch self {
            case .decided(let d): d
            case .stale: .passThrough([])   // never returned: `rewrite` decides again
            }
        }
    }

    private func decide(head: [UInt8], host: String, inject: Bool, now: Date, staleCheck: Bool) -> Internal {
        lock.lock(); defer { lock.unlock() }
        let h = host.lowercased()
        let parsed = HTTPHead(head)
        // Every placeholder anywhere in the head is checked, not only in the bound header — 599d: and
        // inside an authorization field's Basic `user:password` (git's login), decoded.
        var text = String(decoding: head, as: UTF8.self)
        for f in parsed?.fields ?? [] where f.name == "authorization" || f.name == "proxy-authorization" {
            if let d = Self.basicDecoded(String(decoding: head[f.valueRange], as: UTF8.self)) { text += "\n" + d }
        }
        let tokens = Self.placeholderTokens(in: text)
        for t in tokens {
            guard let bid = bindingFor(token: t) else { return .decided(.reject("an unknown or revoked credential placeholder")) }
            guard let b = bindings[bid], b.covers(h) else {
                return .decided(.reject("a credential placeholder for \(bindings[bid]?.hosts.joined(separator: ",") ?? bid), sent to \(h)"))
            }
            if secrets[bid] == nil {
                if let n = notices[bid] { return .decided(.refuse(401, n)) }
                return .decided(.reject("a placeholder for \(bid), which has no secret on this Mac right now"))
            }
        }
        // The binding is the one whose placeholder the request carries; with none, the first
        // bound one for this host (injection). Two bindings can cover one host — an Anthropic API
        // key and a Claude subscription login — so "first for the host" alone would be arbitrary.
        let carried = tokens.lazy.compactMap { self.bindingFor(token: $0) }.compactMap { self.bindings[$0] }
            .first { $0.covers(h) && self.secrets[$0.id] != nil }
        let forHost = bindings.values.filter { $0.covers(h) }.sorted { $0.id < $1.id }
        // 588: EVERY auth header any binding of this host uses (plus Authorization) counts as "a
        // credential is present" — a guest `x-api-key` must never get our bearer token beside it.
        var authHeaders = Set(forHost.map(\.header.headerName))
        if !forHost.isEmpty { authHeaders.insert("authorization") }
        let present = (parsed?.fields ?? []).filter { authHeaders.contains($0.name) }
        let foreignField = present.first { f in
            let value = Self.searchable(String(decoding: head[f.valueRange], as: UTF8.self), field: f.name)
            return !value.isEmpty && !tokens.contains { value.contains($0) }
        }
        if let f = foreignField, carried == nil {
            let value = String(decoding: head[f.valueRange], as: UTF8.self)
            let fp = CredentialFingerprint.of(value)
            var s = sightings[fp] ?? ForeignCredential(kind: CredentialFingerprint.kind(value), prefix: CredentialFingerprint.prefix(value),
                                                         fingerprint: fp, header: f.name, firstSeen: now, lastSeen: now, requests: 0,
                                                         matches: labels[fp])
            s.lastSeen = now
            s.requests += 1
            sightings[fp] = s
            // 599d: "strict" pins the sandbox to the ANTHROPIC credential doz holds; a guest's own GitHub
            // token (a swap-only binding's host) is only flagged.
            if _policy == .strict, forHost.contains(where: { $0.swapOnly != true }) {
                let msg = (_strictNotice ?? "this sandbox is pinned to the credential doz holds for it; it refused the request's own credential (fp {fp})")
                    .replacingOccurrences(of: "{fp}", with: fp)
                return .decided(.refuse(403, msg))
            }
            return .decided(.foreign(head, s))
        }
        // 599d: a swap-only binding (GitHub) is never added to a request that does not carry its placeholder.
        let binding = carried ?? (present.isEmpty && inject ? forHost.first { secrets[$0.id] != nil && $0.swapOnly != true } : nil)
        guard let binding, let secret = secrets[binding.id] else {
            // Nothing to do — but a request with no credential while the credential is unavailable
            // gets the reason, not a confusing upstream 401.
            if present.isEmpty, inject, let b = forHost.first(where: { notices[$0.id] != nil && $0.swapOnly != true }), let n = notices[b.id] {
                return .decided(.refuse(401, n))
            }
            return .decided(.passThrough(head))
        }
        lastUse[binding.id] = now          // "a sandbox is using it" — also when it has expired (the keep-alive)
        if let exp = expiries[binding.id], exp <= now {
            if staleCheck, _onStale != nil { return .stale(binding.id) }
            return .decided(.refuse(401, notices[binding.id]
                ?? "the credential doz holds for this sandbox (\(binding.id)) expired at \(Self.clock(exp)) and has not been renewed"))
        }
        let name = binding.header.headerName
        if let field = parsed?.field(named: name) {
            let value = String(decoding: head[field.valueRange], as: UTF8.self)
            guard let t = tokens.first(where: { Self.searchable(value, field: name).contains($0) }), bindingFor(token: t) == binding.id else {
                return .decided(.passThrough(head))
            }
            let newValue: [UInt8]
            if value.contains(t) {
                newValue = Array(value.replacingOccurrences(of: t, with: secret).utf8)
            } else if let decoded = Self.basicDecoded(value) {
                // 599d: git's Basic login — decode, swap, re-encode.
                newValue = Array(("Basic " + Data(decoded.replacingOccurrences(of: t, with: secret).utf8).base64EncodedString()).utf8)
            } else {
                return .decided(.passThrough(head))
            }
            var out = head
            out.replaceSubrange(field.valueRange, with: newValue)
            return .decided(.swapped(out, binding: binding.id))
        }
        guard let parsed else { return .decided(.passThrough(head)) }
        // The placeholder rode in another header than the binding's (e.g. a Bearer placeholder
        // for an x-api-key binding): replace that header's value and name.
        if let f = present.first(where: { f in tokens.contains { String(decoding: head[f.valueRange], as: UTF8.self).contains($0) } }) {
            var out = head
            out.replaceSubrange(f.nameRange.lowerBound..<f.valueRange.upperBound,
                                with: Array("\(Self.canonical(name)): \(binding.header.value(secret))".utf8))
            return .decided(.swapped(out, binding: binding.id))
        }
        var out = head
        out.insert(contentsOf: Array("\(Self.canonical(name)): \(binding.header.value(secret))\r\n".utf8), at: parsed.endOfFields)
        return .decided(.injected(out, binding: binding.id))
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func canonical(_ name: String) -> String {
        name == "authorization" ? "Authorization" : name
    }

    static func placeholderTokens(in s: String) -> [String] {
        var out: [String] = []
        var rest = Substring(s)
        while let r = rest.range(of: placeholderPrefix) {
            let tail = rest[r.upperBound...].prefix { $0.isHexDigit }
            out.append(placeholderPrefix + tail)
            rest = rest[r.upperBound...]
        }
        return out
    }
}

/// What `CredentialVault.rewrite(head:host:)` decided to do with one HTTP request's head bytes.
public enum CredentialDecision: Sendable, Equatable {
    case passThrough([UInt8])
    case swapped([UInt8], binding: String)
    case injected([UInt8], binding: String)
    /// A credential the guest supplied itself, passed through and flagged (588).
    case foreign([UInt8], ForeignCredential)
    /// 403, plain text: a placeholder where it must not be (the leak guard).
    case reject(String)
    /// The proxy answers itself, with an Anthropic-shaped JSON error (Claude Code shows its
    /// message): 401 when our credential is unavailable or expired, 403 for a strict refusal.
    case refuse(Int, String)

    public var head: [UInt8]? {
        switch self {
        case .passThrough(let h), .swapped(let h, _), .injected(let h, _), .foreign(let h, _): h
        case .reject, .refuse: nil
        }
    }
}

/// `SecRandomCopyBytes` without importing Security into this file's API surface.
enum SecRandomCopyBytesShim {
    static func fill(_ bytes: inout [UInt8]) -> Bool {
        var g = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &g) }
        return true
    }
}

/// A minimal, byte-exact view of an HTTP/1.x request head (request line + fields + CRLF CRLF).
struct HTTPHead {
    struct Field { var name: String; var nameRange: Range<Int>; var valueRange: Range<Int> }
    var method: String
    var target: String
    var version: String
    var fields: [Field]
    /// Index where the terminating empty line starts (insert new fields here).
    var endOfFields: Int
    let bytes: [UInt8]

    init?(_ b: [UInt8]) {
        bytes = b
        guard let firstEnd = Self.crlf(b, from: 0) else { return nil }
        let line = String(decoding: b[0..<firstEnd], as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false)
        guard line.count == 3 else { return nil }
        method = String(line[0]); target = String(line[1]); version = String(line[2])
        var i = firstEnd + 2
        var fs: [Field] = []
        while true {
            guard let e = Self.crlf(b, from: i) else { return nil }
            if e == i { endOfFields = i; break }
            guard let colon = b[i..<e].firstIndex(of: UInt8(ascii: ":")) else { return nil }
            var vs = colon + 1
            while vs < e, b[vs] == 32 || b[vs] == 9 { vs += 1 }
            var ve = e
            while ve > vs, b[ve - 1] == 32 || b[ve - 1] == 9 { ve -= 1 }
            fs.append(Field(name: String(decoding: b[i..<colon], as: UTF8.self).lowercased(), nameRange: i..<colon, valueRange: vs..<ve))
            i = e + 2
        }
        fields = fs
    }

    func field(named n: String) -> Field? { fields.first { $0.name == n } }
    func value(_ n: String) -> String? { field(named: n).map { String(decoding: bytes[$0.valueRange], as: UTF8.self) } }

    /// The path without its query string (the audit log never records parameter values).
    var pathOnly: String {
        let p = target.hasPrefix("http://") || target.hasPrefix("https://") ? (URL(string: target)?.path ?? "/") : target
        return String(p.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "/")
    }

    static func crlf(_ b: [UInt8], from: Int) -> Int? {
        var i = from
        while i + 1 < b.count {
            if b[i] == 13 && b[i + 1] == 10 { return i }
            i += 1
        }
        return nil
    }
}
