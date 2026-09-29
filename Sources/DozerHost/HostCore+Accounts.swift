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

    public init(keychain: KeychainAccess, verifier: AccountVerifying, claudeBinary: @escaping @Sendable () -> String?, home: URL,
                keepaliveRunner: KeepaliveRunning, isClaudeRunning: @escaping @Sendable () -> Bool, watchInterval: Duration) {
        self.keychain = keychain
        self.verifier = verifier
        self.claudeBinary = claudeBinary
        self.home = home
        self.keepaliveRunner = keepaliveRunner
        self.isClaudeRunning = isClaudeRunning
        self.watchInterval = watchInterval
    }

    public static var system: CredentialServices {
        CredentialServices(keychain: SystemKeychain(), verifier: AnthropicVerifier(), claudeBinary: { ClaudeLogin.resolveBinary() },
                           home: FileManager.default.homeDirectoryForCurrentUser, keepaliveRunner: ProcessKeepaliveRunner(),
                           isClaudeRunning: { ClaudeLogin.isClaudeRunning() }, watchInterval: .seconds(120))
    }
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
        let name = a == "default" ? file.defaultAccount : a
        if name == "none" { return .none }
        return file.accounts.first { $0.name == name }.map(ResolvedAccount.record) ?? .missing(name)
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
        let target = value == "default" ? file.defaultAccount : value
        if target != "none" {
            guard let a = file.accounts.first(where: { $0.name == target }) else { throw HostError(.notFound, "no account \(target) (doz account ls)") }
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
            case .setupToken, .apiKey:
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
        if value == "none" {
            // Sessions still hold placeholders: tell them why their requests fail (E20), rather
            // than let the proxy stop decrypting (a TLS error in the guest).
            let why = "\(m.name) has no Anthropic account now — doz account use \(m.name) ACCOUNT (open sessions recover without a restart)"
            m.sandbox.setCredential(.anthropic, secret: nil, expiresAt: nil, environment: [:], notice: why)
            m.sandbox.setCredential(.claudeOAuth, secret: nil, expiresAt: nil, environment: [:], notice: why)
        }
        try m.config.write(store.configFile(m.name))
        note(m.name, value == "none" ? "no Anthropic account (sessions get no credential)"
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
            case .setupToken, .apiKey:
                let read = services.keychain.read(service: a.keychainService ?? "", account: a.adopted == true ? nil : Keychain.user)
                if read.value == nil { state = read == .locked ? "locked" : "missing" }
                else if let e = a.expiresAt { state = e <= now ? "expired" : (e.timeIntervalSince(now) < 30 * 86_400 ? "expires-soon" : "ok") }
            }
            rows.append(AccountRow(name: a.name, kind: a.kind.rawValue, plan: plan, identity: identity, expiresAt: expires,
                                   verification: a.verification, isDefault: file.defaultAccount == a.name,
                                   usedBy: sandboxesUsing(a.name, file).map(\.name), state: state,
                                   keychainService: a.kind == .mac ? ClaudeLogin.service(configDir: a.configDir) : a.keychainService,
                                   fingerprint: a.fingerprint))
        }
        return rows
    }

    func addAccount(_ r: HostRequest) async throws -> [AccountRow] {
        guard let name = r.account else { throw HostError(.invalid, "which account? (a name)") }
        try AccountStore.validateName(name)
        guard let kind = r.accountKind.flatMap(AccountKind.init(rawValue:)) else {
            throw HostError(.invalid, "which kind? --setup-token, --api-key or --claude-login")
        }
        var file = accountStore.load()
        if file.accounts.contains(where: { $0.name == name }) {
            guard r.force == true, name != "mac" else {
                throw HostError(.exists, name == "mac" ? "mac is the built-in Mac login" : "an account \(name) exists — --force replaces it")
            }
        }
        var rec = AccountRecord(name: name, kind: kind, plan: r.plan.map { $0.lowercased() })
        var verifySecret: String?
        switch kind {
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
        }
        if let secret = verifySecret {
            if r.verify != false {
                switch await services.verifier.verify(kind: kind, secret: secret) {
                case .verified:
                    rec.verifiedAt = Date(); rec.verification = "verified"
                case .rejected(let why):
                    throw HostError(.failed, kind == .setupToken
                        ? "Claude rejected this token (\(why)) — generate a fresh one with `claude setup-token` and try again"
                        : "Anthropic rejected this key (\(why))")
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
        file.accounts.removeAll { $0.name == name }
        if wasDefault { file.defaultAccount = "mac" }
        try accountStore.save(file)
        if rec.adopted != true, rec.kind != .mac, let svc = rec.keychainService,
           svc.hasPrefix(AccountStore.setupTokenPrefix) || svc.hasPrefix(AccountStore.apiKeyPrefix) {
            try services.keychain.delete(service: svc, account: Keychain.user)
        }
        if let w = watchers[name] { w.stop(); watchers[name] = nil }
        for m in pinned {
            m.config.account = "default"
            try? m.config.write(store.configFile(m.name))
        }
        for m in managed.values where pinned.contains(where: { $0 === m }) || (wasDefault && m.config.account == "default") {
            applyAccount(m)
            try? m.config.write(store.configFile(m.name))
        }
        note(nil, "account \(name) removed" + (wasDefault ? " — the default is mac again" : ""))
        return await accountRows()
    }

    func setDefaultAccount(_ r: HostRequest) async throws -> [AccountRow] {
        guard let name = r.account else { throw HostError(.invalid, "which account? (a name, or none)") }
        var file = accountStore.load()
        guard name == "none" || file.accounts.contains(where: { $0.name == name }) else { throw HostError(.notFound, "no account \(name)") }
        file.defaultAccount = name
        try accountStore.save(file)
        for m in managed.values where m.config.account == "default" {
            applyAccount(m)
            try? m.config.write(store.configFile(m.name))
        }
        note(nil, "the default account is \(name)")
        return await accountRows()
    }

    func verifyAccount(_ r: HostRequest) async throws -> [AccountRow] {
        guard let name = r.account else { throw HostError(.invalid, "which account?") }
        var file = accountStore.load()
        guard let i = file.accounts.firstIndex(where: { $0.name == name }) else { throw HostError(.notFound, "no account \(name)") }
        let a = file.accounts[i]
        let secret: String?
        switch a.kind {
        case .mac:
            secret = services.keychain.read(service: ClaudeLogin.service(configDir: a.configDir), account: Keychain.user).value
                .flatMap(ClaudeLogin.parse)?.accessToken
        case .setupToken, .apiKey:
            secret = services.keychain.read(service: a.keychainService ?? "", account: a.adopted == true ? nil : Keychain.user).value
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
