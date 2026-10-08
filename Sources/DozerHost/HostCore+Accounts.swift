import Foundation
import DozerKit

/// What the host uses to reach the keychain, verify a credential and probe the Mac's Claude Code —
/// the real ones by default, fakes in tests (588).
public struct CredentialServices: Sendable {
    public var keychain: KeychainAccess
    public var verifier: AccountVerifying
    /// Where `claude` is (nil: not installed).
    public var claudeBinary: @Sendable () -> String?
    /// The home whose `.claude.json` says who is signed in.
    public var home: URL
    public var keepaliveRunner: KeepaliveRunning
    public var isClaudeRunning: @Sendable () -> Bool
    /// How often a Mac login is re-read.
    public var watchInterval: Duration
    /// 599i rc.3: the Mac's Codex home (`mac` for Codex reads its auth.json's access token) — nil: none.
    public var codexHome: @Sendable () -> URL?
    /// The Mac's `codex` (the keep-alive runs it) and how it is run.
    public var codexBinary: @Sendable () -> String?
    public var codexRunner: KeepaliveRunning

    public init(keychain: KeychainAccess, verifier: AccountVerifying, claudeBinary: @escaping @Sendable () -> String?, home: URL,
                keepaliveRunner: KeepaliveRunning, isClaudeRunning: @escaping @Sendable () -> Bool, watchInterval: Duration,
                codexHome: @escaping @Sendable () -> URL? = { nil }, codexBinary: @escaping @Sendable () -> String? = { nil },
                codexRunner: KeepaliveRunning = ProcessKeepaliveRunner()) {
        self.keychain = keychain
        self.verifier = verifier
        self.claudeBinary = claudeBinary
        self.home = home
        self.keepaliveRunner = keepaliveRunner
        self.isClaudeRunning = isClaudeRunning
        self.watchInterval = watchInterval
        self.codexHome = codexHome
        self.codexBinary = codexBinary
        self.codexRunner = codexRunner
    }

    public static var system: CredentialServices {
        CredentialServices(keychain: SystemKeychain(), verifier: AnthropicVerifier(), claudeBinary: { ClaudeLogin.resolveBinary() },
                           home: FileManager.default.homeDirectoryForCurrentUser, keepaliveRunner: ProcessKeepaliveRunner(),
                           isClaudeRunning: { ClaudeLogin.isClaudeRunning() }, watchInterval: .seconds(120),
                           codexHome: { CodexMacLogin.resolveHome() }, codexBinary: { CodexMacLogin.resolveBinary() })
    }

    /// 594, a TEST seam for real host processes (`make test-cli`, the browser probes):
    /// `DOZ_TEST_CREDENTIALS=memory` — a keychain that lives in the host's memory (never the login
    /// keychain: no item written, no prompt), a verifier that sends nothing ("unverified"), no `claude`,
    /// no keep-alive. Anything else: the real services.
    public static func forHost(environment: [String: String] = ProcessInfo.processInfo.environment) -> CredentialServices {
        guard environment["DOZ_TEST_CREDENTIALS"] == "memory" else { return .system }
        // 599i rc.3: the Mac's Codex login only from a FAKE home (DOZ_TEST_CODEX_HOME), else none; the keep-alive
        // only runs a FAKE codex (DOZ_TEST_CODEX_BIN).
        return CredentialServices(keychain: MemoryKeychain(), verifier: OfflineVerifier(), claudeBinary: { nil },
                                  home: URL(fileURLWithPath: "/var/empty"), keepaliveRunner: NoKeepalive(),
                                  isClaudeRunning: { false }, watchInterval: .seconds(3600),
                                  codexHome: { CodexMacLogin.resolveHome(environment: environment) },
                                  codexBinary: { CodexMacLogin.resolveBinary(environment: environment) })
    }
}

/// 611: the keychain the CLI's own looks at THIS Mac's Claude login use (doctor, onboard, doz ui): the login
/// keychain — except under a test seam (`DOZ_TEST_NO_MAC_LOGIN=1` or `DOZ_TEST_CREDENTIALS=memory`), where it
/// is an empty one in memory: a test never looks at the Mac's own login.
public func macLoginKeychain(_ env: [String: String] = ProcessInfo.processInfo.environment) -> any KeychainAccess {
    env["DOZ_TEST_NO_MAC_LOGIN"] == "1" || env["DOZ_TEST_CREDENTIALS"] == "memory" ? MemoryKeychain() : SystemKeychain()
}

/// 594: a keychain in this process's memory (`DOZ_TEST_CREDENTIALS=memory`).
public final class MemoryKeychain: KeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    public init() {}
    public func read(service: String, account: String?) -> KeychainRead {
        lock.withLock { items[service].map(KeychainRead.found) ?? .absent }
    }
    /// The real keychain's per-item limit (599i), so a too-long secret fails in tests as on a Mac.
    public func write(service: String, account: String, secret: String) throws {
        try Keychain.checkSecretSize(secret, service: service)
        lock.withLock { items[service] = secret }
    }
    public func delete(service: String, account: String) throws { lock.withLock { items[service] = nil } }
    public func items(servicePrefix: String) -> [KeychainItemInfo] {
        lock.withLock { items.keys.filter { $0.hasPrefix(servicePrefix) }.sorted().map { KeychainItemInfo(service: $0, account: Keychain.user, modified: nil) } }
    }
}

/// 594: sends nothing — every credential is "unverified" (the memory seam).
public struct OfflineVerifier: AccountVerifying {
    public init() {}
    public func verify(kind: AccountKind, secret: String) async -> AccountVerification { .unavailable("not checked (DOZ_TEST_CREDENTIALS=memory)") }
}

struct NoKeepalive: KeepaliveRunning {
    func run(binary: String, arguments: [String], environment: [String: String], directory: URL, timeout: TimeInterval) -> Int32 { 1 }
}

/// The account a sandbox resolves to.
enum ResolvedAccount: Equatable {
    case none
    /// It names an account the store no longer has.
    case missing(String)
    case record(AccountRecord)
}

extension HostCore {
    /// The Claude sign-in hosts a STRICT sandbox may not reach (D7): a guest `/login` cannot finish.
    static let signInHosts = ["console.anthropic.com", "platform.claude.com", "claude.ai"]
    static let signInNote = "doz key policy strict: no sign-in inside the sandbox"

    static func withoutSignInBlock(_ p: NetworkPolicy) -> NetworkPolicy {
        var q = p
        q.rules.removeAll { $0.note == signInNote }
        return q
    }

    static func withSignInBlock(_ p: NetworkPolicy, strict: Bool) -> NetworkPolicy {
        var q = withoutSignInBlock(p)
        if strict { for h in signInHosts.reversed() { q.rules.insert(EgressRule(.deny, host: h, note: signInNote), at: 0) } }
        return q
    }

    // MARK: resolving

    func resolvedAccount(_ m: Managed, _ file: AccountsFile) -> ResolvedAccount {
        guard let a = m.config.account else { return .none }
        // 599i: Codex follows the store's OpenAI default, never the Anthropic one.
        let image = m.sandbox.spec.imageSpec?.name
        let name = a == "default" ? defaultAccount(for: image, file) : a
        if name == "none" { return .none }
        // rc.3: `mac` for Codex is this Mac's Codex login.
        if name == "mac", AgentCredentials.provider(image) == "openai" { return .record(.codexMac) }
        return file.accounts.first { $0.name == name }.map(ResolvedAccount.record) ?? .missing(name)
    }

    /// 594: the store's default account and every account's kind (`mac` is always this Mac's login).
    func accountKinds() -> (String, [String: AccountKind]) {
        let file = accountStore.load()
        var k: [String: AccountKind] = ["mac": .mac]
        for a in file.accounts { k[a.name] = a.kind }
        return (file.defaultAccount, k)
    }

    /// 599i: the store's OpenAI default (nil: none).
    /// Only for a Codex image (it may read this Mac's Codex login).
    func openaiDefault(for image: String?) -> String? {
        AgentCredentials.provider(image) == "openai" ? effectiveOpenAIDefault(accountStore.load()) : nil
    }

    /// 594: an existing sandbox whose account does not fit its agent — what its page says.
    func credentialProblem(_ m: Managed) -> String? {
        guard m.sandbox.egress != nil else { return nil }
        // 599i rc.3: this Mac's Codex login that cannot be used (not signed in, the keyring, an API-key login).
        if case .record(let a) = resolvedAccount(m, accountStore.load()), a.kind == .codexMac, let p = codexMacSignInProblem() { return "Codex: " + p }
        switch resolvedAccount(m, accountStore.load()) {
        case .none: return AgentCredentials.sandboxProblem(image: m.sandbox.spec.imageSpec?.name, account: nil, missing: nil)
        case .missing(let n): return AgentCredentials.sandboxProblem(image: m.sandbox.spec.imageSpec?.name, account: nil, missing: n)
        case .record(let a): return AgentCredentials.sandboxProblem(image: m.sandbox.spec.imageSpec?.name, account: a, missing: nil)
        }
    }

    /// The account's name as `ls` shows it (`mac`, `work (default)`…); nil: none.
    func accountName(_ m: Managed) -> String? {
        guard m.sandbox.egress != nil, m.config.account != nil else { return nil }
        switch resolvedAccount(m, accountStore.load()) {
        case .none: return nil
        case .missing(let n): return n
        case .record(let a): return a.name
        }
    }

    /// Explicit, else strict for an account that is not a Mac login (D2), else allow.
    func effectivePolicy(_ m: Managed, _ file: AccountsFile) -> ForeignCredentialPolicy {
        if let p = m.config.credentialPolicy.flatMap(ForeignCredentialPolicy.init(rawValue:)) { return p }
        if case .record(let a) = resolvedAccount(m, file), a.kind != .mac { return .strict }
        return .allow
    }

    /// `ok`, `expires-soon`, `expired`, `signed-out`, `held`, `missing`, `unreadable`; nil when the
    /// sandbox has no Anthropic credential at all.
    func credentialState(_ m: Managed, binding: String?, now: Date = Date()) -> String? {
        guard let vault = m.sandbox.egress?.vault else { return nil }
        let file = accountStore.load()
        let account = resolvedAccount(m, file)
        let b: String
        switch account {
        case .record(let a): b = a.kind.binding.id
        case .missing: return "missing"
        case .none:
            guard let id = binding ?? vault.allBindings.first(where: { vault.hasSecret($0.id) })?.id else { return nil }
            b = id
        }
        if case .record(let a) = account, a.kind == .mac, let w = m.watcher, w.state != .ok, w.state != .unknown { return w.state.label }
        // 599i: a ChatGPT sign-in is read on use — its session says how it stands.
        if case .record(let a) = account, a.kind == .codexMac { return codexMacSession().state.label }
        if case .record(let a) = account, a.kind == .chatgpt {
            guard let s = chatgptSessions[a.name] else { return "unknown" }
            if s.state != .ok && s.state != .unknown { return s.state.label }
            if let exp = s.accessExpiry, exp <= now { return "expired" }
            return "ok"
        }
        guard vault.hasSecret(b) else { return vault.notice(b) == nil ? "missing" : "unavailable" }
        guard let exp = vault.expiry(b) else { return "ok" }
        if exp <= now { return "expired" }
        let soon: TimeInterval = { if case .record(let a) = account, a.kind != .mac { return 30 * 86_400 }; return 30 * 60 }()
        return exp.timeIntervalSince(now) < soon ? "expires-soon" : "ok"
    }

    // MARK: applying

    /// Once per sandbox: placeholders persisted (D8), foreign credentials noted.
    func installCredentialHooks(_ m: Managed) {
        guard let vault = m.sandbox.egress?.vault else { return }
        if let h = m.config.placeholderHashes, !h.isEmpty { vault.restorePlaceholderHashes(h) }
        let name = m.name
        vault.onPlaceholdersChanged = { [weak self] in Task { await self?.persistPlaceholders(name) } }
        vault.onForeign = { [weak self] f in Task { await self?.foreignSeen(name, f) } }
    }

    func persistPlaceholders(_ name: String) {
        guard let m = managed[name], let vault = m.sandbox.egress?.vault else { return }
        let h = vault.placeholderHashes
        let value: [String: String]? = h.isEmpty ? nil : h
        guard value != m.config.placeholderHashes else { return }
        m.config.placeholderHashes = value
        guard FileManager.default.fileExists(atPath: store.layout(name).sandboxDirectory.path) else { return }
        try? m.config.write(store.configFile(name))
    }

    func foreignSeen(_ name: String, _ f: ForeignCredential) {
        guard let m = managed[name] else { return }
        let policy = effectivePolicy(m, accountStore.load())
        note(name, "the guest used its own credential: \(f.label) — \(policy == .strict ? "refused (strict)" : "allowed and flagged (doz key policy \(name) strict refuses it)")")
    }

    func detachWatcher(_ m: Managed) {
        m.sandbox.egress?.vault.onStale = nil
        guard let w = m.watcher else { return }
        w.unsubscribe(m.name)
        m.watcher = nil
        if w.isEmpty { w.stop(); watchers[w.account] = nil }
    }

    func keepaliveConfig(_ enabled: Bool) -> KeepaliveConfig {
        KeepaliveConfig(enabled: enabled, runner: services.keepaliveRunner, isClaudeRunning: services.isClaudeRunning,
                        binary: services.claudeBinary)
    }

    /// The ONE watcher of a Mac login account.
    func watcher(for a: AccountRecord, _ file: AccountsFile) -> LoginWatcher {
        if let w = watchers[a.name] { return w }
        let home = services.home, dir = a.configDir
        let w = LoginWatcher(account: a.name, configDir: dir, keychain: services.keychain, pinned: a.identity,
                             identityReader: { ClaudeLogin.identity(configDir: dir, home: home) })
        w.keepalive = keepaliveConfig(file.keepalive)
        w.onEvent = { [weak self] s, t in Task { await self?.note(s, t) } }
        let name = a.name
        w.onIdentity = { [weak self] id in Task { await self?.pinIdentity(name, id) } }
        watchers[a.name] = w
        if !readOnly { w.start(interval: services.watchInterval) }
        return w
    }

    func pinIdentity(_ account: String, _ id: ClaudeIdentity?) {
        var f = accountStore.load()
        guard let i = f.accounts.firstIndex(where: { $0.name == account }) else { return }
        f.accounts[i].identity = id
        try? accountStore.save(f)
    }

    /// Put the sandbox's account (or none) into its vault, and its policy into its proxy.
    func applyAccount(_ m: Managed) {
        guard !readOnly, m.sandbox.egress != nil else { return }
        detachWatcher(m)
        let file = accountStore.load()
        let sb = m.sandbox
        // 599i: Codex uses OpenAI accounts only — its own path; the Anthropic bindings stay empty.
        if AgentCredentials.provider(sb.spec.imageSpec?.name) == "openai" {
            applyOpenAIAccount(m, resolvedAccount(m, file))
            applyPolicy(m, file)
            return
        }
        switch resolvedAccount(m, file) {
        case .none:
            // Only what `key set` gave it (the legacy path); nothing of an account's stays.
            for b in [CredentialBinding.anthropic, .claudeOAuth] where m.config.credentialSources[b.id] == nil {
                sb.setCredential(b, secret: nil, expiresAt: nil, environment: [:], notice: nil)
            }
        case .missing(let n):
            sb.setCredential(.anthropic, secret: nil, expiresAt: nil, environment: [:], notice: nil)
            sb.setCredential(.claudeOAuth, secret: nil, expiresAt: nil, environment: [:],
                             notice: "the account \(n) this sandbox uses no longer exists — doz account use \(m.name) ACCOUNT")
        case .record(let a) where !AgentCredentials.accepts(sb.spec.imageSpec?.name, a.kind):
            // 594: never hand an agent a credential it cannot use (a Claude subscription never reaches pi).
            let why = AgentCredentials.sandboxProblem(image: sb.spec.imageSpec?.name, account: a, missing: nil)
            sb.setCredential(.anthropic, secret: nil, expiresAt: nil, environment: [:], notice: why)
            sb.setCredential(.claudeOAuth, secret: nil, expiresAt: nil, environment: [:], notice: why)
        case .record(let a):
            let other: CredentialBinding = a.kind == .apiKey ? .claudeOAuth : .anthropic
            sb.setCredential(other, secret: nil, expiresAt: nil, environment: [:], notice: nil)
            m.config.credentialSources[CredentialBinding.anthropic.id] = nil
            m.config.credentialSources[CredentialBinding.claudeOAuth.id] = nil
            switch a.kind {
            case .mac:
                let w = watcher(for: a, file)
                m.watcher = w
                w.subscribe(m.name, sb)
                sb.egress?.vault.onStale = { [weak w] _ in w?.stale() }
            case .openaiKey, .chatgpt, .codexMac:
                break                                   // never here: an Anthropic agent does not accept them (above)
            case .setupToken, .apiKey:
                let service = a.keychainService ?? ""
                let read = services.keychain.read(service: service, account: a.adopted == true ? nil : Keychain.user)
                if let secret = read.value {
                    var env: [String: String] = [:]
                    if a.kind == .setupToken {
                        if let p = a.plan { env["CLAUDE_CODE_SUBSCRIPTION_TYPE"] = p }
                        if let t = a.tier { env["CLAUDE_CODE_RATE_LIMIT_TIER"] = t }
                    }
                    sb.setCredential(a.kind.binding, secret: secret, expiresAt: a.expiresAt, environment: env,
                                     notice: "the \(a.kind.rawValue) account \(a.name) expired — make a new token with `claude setup-token`, then: "
                                             + "doz account add \(a.name) --setup-token --force")
                } else {
                    sb.setCredential(a.kind.binding, secret: nil, expiresAt: nil, environment: [:],
                                     notice: "the keychain item \(service) of account \(a.name) is \(read == .locked ? "locked" : "missing") — "
                                             + (read == .locked ? "unlock the login keychain" : "add it again: doz account add \(a.name) --\(a.kind.rawValue) --force"))
                }
            }
        }
        applyPolicy(m, file)
    }

    /// The foreign-credential policy, its refusal text, the sign-in block (D7), fingerprint names.
    func applyPolicy(_ m: Managed, _ file: AccountsFile) {
        guard let egress = m.sandbox.egress else { return }
        let policy = effectivePolicy(m, file)
        egress.vault.foreignPolicy = policy
        let who: String = {
            switch resolvedAccount(m, file) {
            case .record(let a): return "the account \(a.name)" + (a.identity.map { " (\($0.label))" } ?? "")
            case .missing(let n): return "the account \(n)"
            case .none: return "the key doz holds for it"
            }
        }()
        egress.vault.strictNotice = "\(m.name) is pinned to \(who). It refused this request's own credential (fp {fp}) — a /login or a key "
            + "inside the sandbox. Remove it (unset CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY overrides, or delete ~/.claude/.credentials.json), "
            + "or allow it with: doz key policy \(m.name) allow"
        egress.vault.setFingerprintLabels(Dictionary(file.accounts.compactMap { a in a.fingerprint.map { ($0, a.name) } }) { a, _ in a })
        let p = Self.withSignInBlock(egress.policy, strict: policy == .strict)
        if p != egress.policy { m.sandbox.setNetworkPolicy(p) }
    }

    // MARK: operations

    func setPolicy(_ r: HostRequest) throws -> [CredentialRow] {
        let m = try get(r.name)
        guard m.sandbox.egress != nil else { throw HostError(.invalid, "\(m.name) is not proxied (network \(m.config.networkName)) — it has no credential proxy") }
        switch r.policy {
        case "allow", "strict": m.config.credentialPolicy = r.policy
        case "auto": m.config.credentialPolicy = nil
        default: throw HostError(.invalid, "which policy? allow, strict or auto")
        }
        try m.config.write(store.configFile(m.name))
        applyPolicy(m, accountStore.load())
        note(m.name, "key policy: \(effectivePolicy(m, accountStore.load()).rawValue)\(m.config.credentialPolicy == nil ? " (auto)" : "")")
        return credentials(m)
    }

    /// `account use SANDBOX NAME|default|none` (and `key set --claude-login` = `use … mac`).
    func useAccount(_ m: Managed, _ value: String) async throws -> [CredentialRow] {
        guard m.sandbox.egress != nil else {
            throw HostError(.invalid, "\(m.name) is not proxied (network \(m.config.networkName)): a credential would have to enter the sandbox — create it with a proxied network (agent, open, …)")
        }
        var file = accountStore.load()
        let target = value == "default" ? defaultAccount(for: m.sandbox.spec.imageSpec?.name, file) : value
        // 599i rc.3: `mac` for Codex is this Mac's Codex login (read-only) — usable when it is signed in.
        let codexMac = target == "mac" && AgentCredentials.provider(m.sandbox.spec.imageSpec?.name) == "openai"
        if codexMac, let p = codexMacSignInProblem() { throw HostError(.invalid, p) }
        if target != "none", !codexMac {
            guard let a = file.accounts.first(where: { $0.name == target }) else { throw HostError(.notFound, "no account \(target) (doz account ls)") }
            // 594: only an account the sandbox's agent can use.
            let image = m.sandbox.spec.imageSpec?.name
            guard AgentCredentials.accepts(image, a.kind) else {
                throw HostError(.invalid, "\(AgentImages.agentName(image ?? "") ?? "its agent") can't use the account \(a.name) (\(a.kind.label)) — \(AgentCredentials.requirement(image ?? ""))")
            }
            switch a.kind {
            case .mac:
                // E1–E4 before anything changes; then follow whoever is signed in now (D6).
                let st = await macStatus(a)
                if let p = st.problem() { throw p }
                if let i = file.accounts.firstIndex(where: { $0.name == a.name }), let id = st.identity, file.accounts[i].identity != id {
                    file.accounts[i].identity = id
                    try accountStore.save(file)
                    watchers[a.name]?.repin(id)
                }
            case .codexMac:
                break
            case .setupToken, .apiKey, .openaiKey, .chatgpt:
                let read = services.keychain.read(service: a.keychainService ?? "", account: a.adopted == true ? nil : Keychain.user)
                guard read.value != nil else {
                    throw HostError(.notFound, "the keychain item \(a.keychainService ?? "?") of account \(a.name) is \(read == .locked ? "locked" : "missing")")
                }
            }
        }
        m.config.account = value == "none" ? nil : value
        m.config.credentialSources = [:]
        try m.config.write(store.configFile(m.name))
        applyAccount(m)
        let openai = AgentCredentials.provider(m.sandbox.spec.imageSpec?.name) == "openai"
        if value == "none" {
            // Sessions still hold placeholders: tell them why their requests fail (E20), rather
            // than let the proxy stop decrypting (a TLS error in the guest).
            if openai {
                // 599i: Codex — its placeholders (in auth.json) are answered with why, never another account's.
                let why = "\(m.name) has no OpenAI account now — doz account use \(m.name) ACCOUNT (open sessions recover without a restart)"
                m.sandbox.setCredential(.openai, secret: nil, expiresAt: nil, environment: [:], notice: why)
                m.sandbox.setCredential(.chatgpt, secret: nil, expiresAt: nil, environment: [:], notice: why)
                m.sandbox.egress?.chatgptRenewal = EgressProxy.ChatGPTRenewal { body in
                    guard let t = OpenAIAccess.refreshToken(inRenewalBody: body), t.hasPrefix(CredentialVault.placeholderPrefix) else { return nil }
                    return OpenAIAccess.refreshAnswer(placeholder: t, guestIDToken: nil, problem: why)
                }
            } else {
                let why = "\(m.name) has no Anthropic account now — doz account use \(m.name) ACCOUNT (open sessions recover without a restart)"
                m.sandbox.setCredential(.anthropic, secret: nil, expiresAt: nil, environment: [:], notice: why)
                m.sandbox.setCredential(.claudeOAuth, secret: nil, expiresAt: nil, environment: [:], notice: why)
            }
        }
        try m.config.write(store.configFile(m.name))
        note(m.name, value == "none" ? "no \(openai ? "OpenAI" : "Anthropic") account (sessions get no credential)"
             : "uses the account \(target)\(value == "default" ? " (the default)" : "") — open sessions switch on their next request")
        return credentials(m)
    }

    func macStatus(_ a: AccountRecord) async -> ClaudeLoginStatus {
        let s = services, dir = a.configDir
        return await Task.detached {
            ClaudeLoginStatus.check(configDir: dir, keychain: s.keychain, probeBinary: true, home: s.home, binary: s.claudeBinary)
        }.value
    }

    func sandboxesUsing(_ name: String, _ file: AccountsFile) -> [Managed] {
        managed.values.filter { m in
            if case .record(let a) = resolvedAccount(m, file), a.name == name { return true }
            if case .missing(let n) = resolvedAccount(m, file), n == name { return true }
            return false
        }.sorted { $0.name < $1.name }
    }

    func accountRows(now: Date = Date()) async -> [AccountRow] {
        let file = accountStore.load()
        var rows: [AccountRow] = []
        for a in file.accounts {
            var state = "ok"
            var expires = a.expiresAt
            var identity = a.identity?.label
            var plan = a.plan
            switch a.kind {
            case .mac:
                if let w = watchers[a.name], w.state != .unknown {
                    state = w.state.label
                    expires = w.expiresAt
                } else {
                    let st = ClaudeLoginStatus.check(configDir: a.configDir, keychain: services.keychain, probeBinary: false, home: services.home)
                    state = st.state == .signedIn ? ((st.expiresAt.map { $0 <= now } ?? false) ? "expired" : "ok") : st.state.rawValue
                    expires = st.expiresAt
                    plan = st.subscriptionType
                    if identity == nil { identity = st.identity?.label }
                }
            case .setupToken, .apiKey, .openaiKey:
                let read = services.keychain.read(service: a.keychainService ?? "", account: a.adopted == true ? nil : Keychain.user)
                if read.value == nil { state = read == .locked ? "locked" : "missing" }
                else if let e = a.expiresAt { state = e <= now ? "expired" : (e.timeIntervalSince(now) < 30 * 86_400 ? "expires-soon" : "ok") }
            case .codexMac:
                break                                   // never in accounts.json — its row is added below
            case .chatgpt:
                // 599i: the session's state when one runs; else whether the keychain item is there.
                identity = a.email
                if !buildFlavor.chatgptSignIn { state = "unsupported" }      // 611: kept, never used, by a public build
                else if let s = chatgptSessions[a.name] {
                    state = s.state.label
                    expires = s.accessExpiry
                } else {
                    let read = services.keychain.read(service: a.keychainService ?? "", account: Keychain.user)
                    if read.value == nil { state = read == .locked ? "locked" : "missing" }
                }
            }
            let isDefault = a.kind.provider == "openai" ? effectiveOpenAIDefault(file) == a.name : file.defaultAccount == a.name
            rows.append(AccountRow(name: a.name, kind: a.kind.rawValue, plan: plan, identity: identity, expiresAt: expires,
                                   verification: a.verification, isDefault: isDefault,
                                   usedBy: sandboxesUsing(a.name, file).map(\.name), state: state,
                                   keychainService: a.kind == .mac ? ClaudeLogin.service(configDir: a.configDir) : a.keychainService,
                                   fingerprint: a.fingerprint))
        }
        if let r = codexMacRow(file, now: now) { rows.append(r) }
        return rows
    }

    func addAccount(_ r: HostRequest) async throws -> [AccountRow] {
        guard let name = r.account else { throw HostError(.invalid, "which account? (a name)") }
        try AccountStore.validateName(name)
        guard let kind = r.accountKind.flatMap(AccountKind.init(rawValue:)) else {
            throw HostError(.invalid, "which kind? --setup-token, --api-key, --claude-login, --openai-key or --chatgpt")
        }
        var file = accountStore.load()
        if file.accounts.contains(where: { $0.name == name }) {
            guard r.force == true, name != "mac" else {
                throw HostError(.exists, name == "mac" ? "mac is the built-in Mac login" : "an account \(name) exists — --force replaces it")
            }
        }
        var rec = AccountRecord(name: name, kind: kind, plan: r.plan.map { $0.lowercased() })
        var verifySecret: String?
        var chatgptTokens: ChatGPTTokens?
        switch kind {
        case .codexMac:
            throw HostError(.invalid, "this Mac's Codex login is built in — a Codex sandbox uses it as the account mac (nothing to add)")
        case .mac:
            guard let dir = r.configDir, !dir.isEmpty else {
                throw HostError(.invalid, "the Mac's default login is the built-in account mac; --config-dir names another Claude config dir")
            }
            let path = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).standardizedFileURL.path
            rec.configDir = path
            let st = await macStatus(rec)
            if let p = st.problem() { throw p }
            rec.identity = st.identity
            rec.plan = st.subscriptionType
            rec.tier = st.rateLimitTier
        case .setupToken:
            guard let raw = r.secret, let t = AccountStore.normalizeToken(raw) else {
                throw HostError(.invalid, "paste the long-lived token `claude setup-token` printed (on stdin, or at the prompt)")
            }
            guard t.hasPrefix("sk-ant-oat") else { throw HostError(.invalid, "that isn't a Claude setup token (they start sk-ant-oat…)") }
            verifySecret = t
            rec.keychainService = AccountStore.setupTokenPrefix + name
            rec.fingerprint = CredentialFingerprint.of(t)
            rec.expiresAt = Date().addingTimeInterval(AccountStore.setupTokenLifetime)
        case .apiKey:
            if let svc = r.keychainService {
                guard let k = services.keychain.read(service: svc, account: nil).value else {
                    throw HostError(.notFound, "no readable keychain item with service \(svc)")
                }
                rec.keychainService = svc
                rec.adopted = true
                verifySecret = k
            } else {
                guard let raw = r.secret, let k = AccountStore.normalizeToken(raw) else {
                    throw HostError(.invalid, "an API key (on stdin, or at the prompt), or --keychain SERVICE")
                }
                verifySecret = k
                rec.keychainService = AccountStore.apiKeyPrefix + name
            }
            rec.fingerprint = verifySecret.map(CredentialFingerprint.of)
        case .openaiKey:
            // 599i: an OpenAI API key (Codex).
            if let svc = r.keychainService {
                guard let k = services.keychain.read(service: svc, account: nil).value else {
                    throw HostError(.notFound, "no readable keychain item with service \(svc)")
                }
                rec.keychainService = svc
                rec.adopted = true
                verifySecret = k
            } else {
                guard let raw = r.secret, let k = AccountStore.normalizeToken(raw.replacingOccurrences(of: "OPENAI_API_KEY=", with: "")) else {
                    throw HostError(.invalid, "an OpenAI API key (on stdin, or at the prompt), or --keychain SERVICE")
                }
                guard k.hasPrefix("sk-") else { throw HostError(.invalid, "that isn't an OpenAI API key (they start sk-…)") }
                verifySecret = k
                rec.keychainService = AccountStore.openaiKeyPrefix + name
            }
            rec.fingerprint = verifySecret.map(CredentialFingerprint.of)
        case .chatgpt:
            // 611: a public build has no ChatGPT sign-in of its own — and takes none from an older client either.
            guard buildFlavor.chatgptSignIn else { throw HostError(.invalid, BuildFlavor.chatgptSignInMissing) }
            // 599i: the tokens of Dozer's OWN sign-in (`doz account add NAME --chatgpt` signed in on this Mac and
            // sent them here) — kept as ONE keychain item; accounts.json gets the claims that are not secrets.
            guard let raw = r.secret, let t = ChatGPTTokens.parse(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw HostError(.invalid, "a ChatGPT sign-in comes from doz account add NAME --chatgpt (it opens the browser on this Mac)")
            }
            rec.keychainService = AccountStore.chatgptPrefix + name
            rec.plan = OpenAIAccess.planType(idToken: t.idToken)
            rec.email = OpenAIAccess.email(idToken: t.idToken)
            rec.accountID = t.accountID
            rec.fingerprint = CredentialFingerprint.of(t.accessToken)
            rec.verifiedAt = Date()
            rec.verification = "verified (signed in on this Mac)"
            // Only what must persist (the refresh token, the kept claims) — the access token stays in memory.
            // A write that fails leaves no item and fails the add.
            try KeychainChunks.write(services.keychain, service: AccountStore.chatgptPrefix + name, secret: ChatGPTRecord(t).json)
            chatgptTokens = t
        }
        if let secret = verifySecret {
            if r.verify != false {
                switch await services.verifier.verify(kind: kind, secret: secret) {
                case .verified:
                    rec.verifiedAt = Date(); rec.verification = "verified"
                case .rejected(let why):
                    throw HostError(.failed, kind == .setupToken
                        ? "Claude rejected this token (\(why)) — generate a fresh one with `claude setup-token` and try again"
                        : kind == .openaiKey ? "OpenAI rejected this key (\(why))" : "Anthropic rejected this key (\(why))")
                case .unavailable(let why):
                    rec.verification = "unverified: \(why)"
                }
            } else {
                rec.verification = "unverified: --no-verify"
            }
            if rec.adopted != true, let svc = rec.keychainService {
                try services.keychain.write(service: svc, account: Keychain.user, secret: secret)
            }
        }
        file.accounts.removeAll { $0.name == name }
        file.accounts.append(rec)
        try accountStore.save(file)
        note(nil, "account \(name) added (\(kind.rawValue)\(rec.verification.map { ", \($0)" } ?? ""))")
        // 599i: a sign-in made again replaces the session's tokens (its sandboxes switch on their next request).
        if let t = chatgptTokens { chatgptSession(file.accounts.last!).adopt(t) } else { chatgptSessions[name] = nil }
        for m in sandboxesUsing(name, file) { applyAccount(m) }
        return await accountRows()
    }

    func removeAccount(_ r: HostRequest) async throws -> [AccountRow] {
        guard let name = r.account else { throw HostError(.invalid, "which account?") }
        guard name != "mac" else { throw HostError(.invalid, "mac is the built-in Mac login — it cannot be removed") }
        var file = accountStore.load()
        guard let rec = file.accounts.first(where: { $0.name == name }) else { throw HostError(.notFound, "no account \(name)") }
        let pinned = managed.values.filter { $0.config.account == name }.sorted { $0.name < $1.name }
        if !pinned.isEmpty && r.force != true {
            throw HostError(.invalid, "\(pinned.map(\.name).joined(separator: ", ")) use\(pinned.count == 1 ? "s" : "") \(name) — "
                            + "doz account use SANDBOX ACCOUNT first, or --force (they then follow the default)")
        }
        let wasDefault = file.defaultAccount == name
        let wasOpenAIDefault = file.openaiDefault == name
        file.accounts.removeAll { $0.name == name }
        if wasDefault { file.defaultAccount = "mac" }
        if wasOpenAIDefault { file.openaiDefault = nil }          // 599i: none — never an Anthropic account
        try accountStore.save(file)
        if rec.adopted != true, rec.kind != .mac, let svc = rec.keychainService,
           [AccountStore.setupTokenPrefix, AccountStore.apiKeyPrefix, AccountStore.openaiKeyPrefix, AccountStore.chatgptPrefix].contains(where: svc.hasPrefix) {
            if rec.kind == .chatgpt { KeychainChunks.remove(services.keychain, service: svc) }      // and its parts
            else { try services.keychain.delete(service: svc, account: Keychain.user) }
        }
        if let w = watchers[name] { w.stop(); watchers[name] = nil }
        chatgptSessions[name] = nil
        for m in pinned {
            m.config.account = "default"
            try? m.config.write(store.configFile(m.name))
        }
        for m in managed.values where pinned.contains(where: { $0 === m }) || ((wasDefault || wasOpenAIDefault) && m.config.account == "default") {
            applyAccount(m)
            try? m.config.write(store.configFile(m.name))
        }
        note(nil, "account \(name) removed" + (wasDefault ? " — the default is mac again" : "") + (wasOpenAIDefault ? " — Codex sandboxes that follow the default have no OpenAI account now" : ""))
        return await accountRows()
    }

    func setDefaultAccount(_ r: HostRequest) async throws -> [AccountRow] {
        guard let name = r.account else { throw HostError(.invalid, "which account? (a name, or none)") }
        var file = accountStore.load()
        guard name == "none" || file.accounts.contains(where: { $0.name == name }) else { throw HostError(.notFound, "no account \(name)") }
        // 599i: an OpenAI account is the default of Codex sandboxes; any other, of Claude Code and pi. rc.3: `--codex`
        // (`accountKind` "codex") sets the Codex default by name — `mac` (this Mac's Codex login) or none too.
        let openai = r.accountKind == "codex" || file.accounts.first { $0.name == name }?.kind.provider == "openai"
        if r.accountKind == "codex", name != "none", name != "mac", file.accounts.first(where: { $0.name == name })?.kind.provider != "openai" {
            throw HostError(.invalid, "\(name) is not an OpenAI account — Codex can use mac (this Mac's Codex login), a ChatGPT sign-in or an OpenAI key")
        }
        if openai { file.openaiDefault = name } else { file.defaultAccount = name }
        try accountStore.save(file)
        for m in managed.values where m.config.account == "default" {
            applyAccount(m)
            try? m.config.write(store.configFile(m.name))
        }
        note(nil, openai ? "the default OpenAI account (Codex) is \(name)" : "the default account is \(name)")
        return await accountRows()
    }

    func verifyAccount(_ r: HostRequest) async throws -> [AccountRow] {
        guard let name = r.account else { throw HostError(.invalid, "which account?") }
        var file = accountStore.load()
        guard let i = file.accounts.firstIndex(where: { $0.name == name }) else { throw HostError(.notFound, "no account \(name)") }
        let a = file.accounts[i]
        let secret: String?
        switch a.kind {
        case .codexMac:
            secret = nil
        case .mac:
            secret = services.keychain.read(service: ClaudeLogin.service(configDir: a.configDir), account: Keychain.user).value
                .flatMap(ClaudeLogin.parse)?.accessToken
        case .setupToken, .apiKey, .openaiKey:
            secret = services.keychain.read(service: a.keychainService ?? "", account: a.adopted == true ? nil : Keychain.user).value
        case .chatgpt:
            // 599i: a sign-in is checked by its session (renewed on this Mac when it is due).
            let s = chatgptSession(a)
            s.load()
            let problem = await Task.detached { s.ensureFresh() }.value
            file.accounts[i].verification = problem.map { "rejected: \($0)" } ?? "verified (signed in)"
            if problem == nil { file.accounts[i].verifiedAt = Date() }
            try accountStore.save(file)
            return await accountRows()
        }
        guard let secret else { throw HostError(.notFound, "account \(name) has no credential to verify (doz account ls)") }
        switch await services.verifier.verify(kind: a.kind, secret: secret) {
        case .verified: file.accounts[i].verifiedAt = Date(); file.accounts[i].verification = "verified"
        case .rejected(let why): file.accounts[i].verification = "rejected: \(why)"
        case .unavailable(let why): file.accounts[i].verification = "unverified: \(why)"
        }
        try accountStore.save(file)
        return await accountRows()
    }

    func setKeepalive(_ r: HostRequest) throws -> AccountsFile {
        guard let on = r.enabled else { throw HostError(.invalid, "on or off?") }
        var file = accountStore.load()
        file.keepalive = on
        try accountStore.save(file)
        for w in watchers.values { w.keepalive = keepaliveConfig(on) }
        note(nil, "keep-alive \(on ? "on: near expiry, while a sandbox uses a Mac login and no Claude Code runs, the host runs the Mac's claude once" : "off")")
        return file
    }
}

extension HostCore {
    /// A sandbox's credential vault (tests and the server; nil: not proxied / no such sandbox).
    public func vault(of name: String) -> CredentialVault? { managed[name]?.sandbox.egress?.vault }
    /// The sandbox's proxy policy as it applies now (with the strict sign-in block).
    public func effectiveNetworkPolicy(of name: String) -> NetworkPolicy? { managed[name]?.sandbox.egress?.policy }
    /// The watcher of a Mac-login account, when one runs.
    public func loginWatcher(_ account: String) -> LoginWatcher? { watchers[account] }
    public var loginWatcherCount: Int { watchers.count }
    public func config(of name: String) -> SandboxConfig? { managed[name]?.config }
}
