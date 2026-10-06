import Foundation
import DozerKit

// 599i — the Mac's side of an OpenAI account for Codex.
//
//   chatgpt     Dozer's OWN ChatGPT sign-in (`doz account add NAME --chatgpt`): its tokens are ONE keychain
//               item, `doz-chatgpt:NAME` (JSON, written on `security -i`'s stdin); `ChatGPTSession` (one per
//               account, shared by all its sandboxes) gives the proxy the access token and renews it ON THE
//               MAC with the refresh token only Dozer holds. Refresh tokens rotate and are single-use, so
//               this sign-in is never the Mac's own Codex login: Dozer never reads or writes ~/.codex.
//   openai-key  an OpenAI API key in `doz-openai:NAME` (checked with GET api.openai.com/v1/models).
//
// No silent fallback: a sign-in that cannot be used (signed out, the keychain item missing or locked)
// is the proxy's 401 with what to do — never another account's token or an API key.
//
// Test seam: DOZ_TEST_OPENAI_UPSTREAM=host:port + DOZ_TEST_OPENAI_CA=<pem> — the sign-in's exchange, the
// refresh, the key check and the proxy's OpenAI leg go to a fake OpenAI, trusting ONLY that CA.

public enum OpenAISeam {
    /// The fake OpenAI (both variables, a readable CA) — or nil (the real one).
    public static func upstream(environment env: [String: String] = ProcessInfo.processInfo.environment) -> EgressProxy.UpstreamOverride? {
        guard let u = env["DOZ_TEST_OPENAI_UPSTREAM"], !u.isEmpty, let caPath = env["DOZ_TEST_OPENAI_CA"],
              let pem = try? String(contentsOfFile: caPath, encoding: .utf8) else { return nil }
        let parts = u.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
        return EgressProxy.UpstreamOverride(host: String(parts[0]), port: port, anchorsPEM: pem)
    }
}

/// One ChatGPT account's sign-in in the host: the tokens (from the keychain), their renewal, and what
/// the proxy needs — the access token for a request, Codex's renewal answer, the guest's id_token.
public final class ChatGPTSession: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case unknown, ok
        /// The keychain item is gone / the keychain is locked.
        case missing, locked
        /// The sign-in has ended (OpenAI refused the refresh token): sign in again.
        case signedOut(String)
        /// The last refresh could not reach OpenAI (the access token may still work until it expires).
        case unavailable(String)

        public var label: String {
            switch self {
            case .unknown, .ok: "ok"
            case .missing: "missing"
            case .locked: "locked"
            case .signedOut: "signed-out"
            case .unavailable: "unavailable"
            }
        }
    }

    /// Refresh when the access token's `exp` is this close (Codex's own window, `manager.rs:204`).
    public static let refreshWindow: TimeInterval = 5 * 60
    /// After a refresh that could not reach OpenAI, wait this long before trying again.
    public static let retryAfter: TimeInterval = 30

    public let account: String
    public let service: String
    let keychain: KeychainAccess
    let refresher: @Sendable (ChatGPTTokens) -> OpenAIAccess.RefreshResult
    private let lock = NSLock()
    /// Held while a refresh runs: one at a time (a second caller waits, then sees the renewed tokens).
    private let refreshing = NSLock()
    private var tokens: ChatGPTTokens?
    private var _state: State = .unknown
    private var stale = false
    private var lastFailure: Date?
    private var _generation = 0
    private var _lastRefresh: Date?
    /// Notes for the host log / viewers (never a token).
    public var onNote: (@Sendable (String) -> Void)?

    public init(account: String, service: String, keychain: KeychainAccess,
                refresher: @escaping @Sendable (ChatGPTTokens) -> OpenAIAccess.RefreshResult) {
        self.account = account
        self.service = service
        self.keychain = keychain
        self.refresher = refresher
    }

    public var state: State { lock.withLock { _state } }
    /// Changes whenever the tokens do (the vault drops its cached read at once).
    public var generation: Int { lock.withLock { _generation } }
    public var lastRefresh: Date? { lock.withLock { _lastRefresh } }
    public var accessExpiry: Date? { lock.withLock { tokens.flatMap { OpenAIAccess.expiry($0.accessToken) } } }
    public var accountID: String? { lock.withLock { tokens?.accountID } }
    /// The id_token the GUEST gets: the real claims, not the signature.
    public var guestIDToken: String? { lock.withLock { tokens.flatMap { OpenAIAccess.guestIDToken($0.idToken) } } }

    /// (Re-)read the keychain item. Called when the account is applied and after it was added again.
    public func load() {
        let r = keychain.read(service: service, account: Keychain.user)
        lock.withLock {
            switch r {
            case .found(let s):
                if let t = ChatGPTTokens.parse(s) { tokens = t; _state = .ok } else { tokens = nil; _state = .signedOut("the keychain item holds no sign-in") }
            case .locked: _state = tokens == nil ? .locked : _state
            case .absent, .failed: tokens = nil; _state = .missing
            }
            stale = false
            lastFailure = nil
            _generation += 1
        }
    }

    /// An upstream 401 to a request that carried the access token: renew before the next use.
    public func markStale() { lock.withLock { stale = true; _generation += 1 } }

    /// Why this sign-in cannot be used now (the proxy's 401 text), nil when it can.
    public func problem(_ name: String? = nil) -> String? {
        let n = name ?? account
        switch state {
        case .unknown, .ok, .unavailable: return lock.withLock { tokens == nil } ? "the ChatGPT sign-in of account \(n) is not loaded" : nil
        case .missing: return "the keychain item \(service) of account \(n) is missing — sign in again on this Mac: doz account add \(n) --chatgpt --force"
        case .locked: return "the login keychain is locked — unlock it on this Mac (account \(n))"
        case .signedOut(let why): return "the ChatGPT sign-in of account \(n) has ended (\(why)) — sign in again on this Mac: doz account add \(n) --chatgpt --force"
        }
    }

    /// Renew when the access token is about to expire or was refused (`force`: now). Blocking — it runs on a
    /// proxy thread or a detached task, never on the host actor. Returns the problem, nil when usable.
    @discardableResult
    public func ensureFresh(now: Date = Date(), force: Bool = false) -> String? {
        func needs() -> Bool {
            lock.withLock {
                guard let t = tokens, case .ok = _state else {
                    if case .unavailable = _state, tokens != nil { return lastFailure.map { now.timeIntervalSince($0) >= Self.retryAfter } ?? true }
                    return false
                }
                if force || stale { return true }
                guard let exp = OpenAIAccess.expiry(t.accessToken) else { return false }
                return exp.timeIntervalSince(now) < Self.refreshWindow
            }
        }
        guard needs() else { return problem() }
        refreshing.lock()
        defer { refreshing.unlock() }
        guard needs(), let current = lock.withLock({ tokens }) else { return problem() }   // another caller renewed it meanwhile
        switch refresher(current) {
        case .renewed(let n):
            // The ROTATED refresh token is kept before the new access token is used: the old one is spent.
            var kept = true
            do { try keychain.write(service: service, account: Keychain.user, secret: n.json) } catch { kept = false }
            lock.withLock {
                tokens = n
                _state = .ok
                stale = false
                lastFailure = nil
                _lastRefresh = now
                _generation += 1
            }
            onNote?("the ChatGPT sign-in of account \(account) was renewed on this Mac"
                    + (kept ? "" : " — but the keychain could not keep the new refresh token (it is held in memory until the host stops)"))
            return nil
        case .signedOut(let why):
            lock.withLock { _state = .signedOut(why); _generation += 1 }
            onNote?("the ChatGPT sign-in of account \(account) has ended (\(why)) — doz account add \(account) --chatgpt --force")
            return problem()
        case .unavailable(let why):
            lock.withLock { _state = .unavailable(why); lastFailure = now }
            onNote?("could not renew the ChatGPT sign-in of account \(account) (\(why)) — retrying on the next request")
            // An access token that has not expired still works.
            if let exp = accessExpiry, exp > now { return nil }
            return "the ChatGPT sign-in of account \(account) could not be renewed (\(why)) — check this Mac's network; Dozer tries again on the next request"
        }
    }

    /// The access token for a request now (the vault's provider read): renewed first when needed.
    public func read(now: Date = Date()) -> CredentialVault.SecretRead {
        if let p = ensureFresh(now: now) { return (nil, "Dozer: " + p) }
        guard let t = lock.withLock({ tokens }) else { return (nil, "Dozer: " + (problem() ?? "no ChatGPT sign-in")) }
        if let exp = OpenAIAccess.expiry(t.accessToken), exp <= now {
            return (nil, "Dozer: the ChatGPT sign-in of account \(account) expired and could not be renewed — check this Mac's network")
        }
        return (t.accessToken, nil)
    }

    /// The proxy's answer to Codex's own renewal (its refresh token is a placeholder): renew on the Mac if
    /// needed, then the same placeholder back with the id_token's claims — or 401 with why.
    public func renewalAnswer(placeholder: String, now: Date = Date()) -> [UInt8] {
        let p = ensureFresh(now: now)
        return OpenAIAccess.refreshAnswer(placeholder: placeholder, guestIDToken: guestIDToken, problem: p)
    }
}

extension HostCore {
    /// The ONE session of a ChatGPT account (created, loaded from the keychain, on first use).
    func chatgptSession(_ a: AccountRecord) -> ChatGPTSession {
        if let s = chatgptSessions[a.name] { return s }
        let override = OpenAISeam.upstream()
        let s = ChatGPTSession(account: a.name, service: a.keychainService ?? AccountStore.chatgptPrefix + a.name, keychain: services.keychain,
                               refresher: { OpenAIAccess.refresh($0, override: override) })
        s.onNote = { [weak self] t in Task { await self?.note(nil, t) } }
        s.load()
        chatgptSessions[a.name] = s
        return s
    }

    /// 599i: put an OpenAI account (or none) into a Codex sandbox's vault and proxy.
    func applyOpenAIAccount(_ m: Managed, _ resolved: ResolvedAccount) {
        guard let egress = m.sandbox.egress else { return }
        let sb = m.sandbox
        egress.openaiUpstreamForTests = OpenAISeam.upstream()
        func clearChatGPT(_ notice: String?) {
            egress.chatgptRenewal = nil
            if let notice {
                egress.vault.remove(CredentialBinding.chatgpt.id)
                sb.setCredential(.chatgpt, secret: nil, expiresAt: nil, environment: [:], notice: notice)
            } else {
                egress.vault.remove(CredentialBinding.chatgpt.id)
            }
        }
        switch resolved {
        case .none:
            clearChatGPT(nil)
            if m.config.credentialSources[CredentialBinding.openai.id] == nil { sb.setCredential(.openai, secret: nil, expiresAt: nil, environment: [:], notice: nil) }
        case .missing(let n):
            let why = "the account \(n) this sandbox uses no longer exists — doz account use \(m.name) ACCOUNT"
            clearChatGPT(why)
            sb.setCredential(.openai, secret: nil, expiresAt: nil, environment: [:], notice: why)
        case .record(let a) where !AgentCredentials.accepts(sb.spec.imageSpec?.name, a.kind):
            let why = AgentCredentials.sandboxProblem(image: sb.spec.imageSpec?.name, account: a, missing: nil)
            clearChatGPT(why)
            sb.setCredential(.openai, secret: nil, expiresAt: nil, environment: [:], notice: why)
        case .record(let a):
            m.config.credentialSources[CredentialBinding.openai.id] = nil
            if a.kind == .chatgpt {
                sb.setCredential(.openai, secret: nil, expiresAt: nil, environment: [:], notice: nil)
                let s = chatgptSession(a)
                let vault = egress.vault
                vault.setProvider(.chatgpt, ttl: 60, version: { [weak s] in "\(s?.generation ?? -1)" }, read: { [weak s] in
                    s?.read() ?? (nil, "Dozer: the ChatGPT sign-in is not loaded")
                })
                vault.onStale = { [weak s] id in
                    guard id == CredentialBinding.chatgpt.id else { return }
                    s?.markStale()
                }
                egress.chatgptRenewal = EgressProxy.ChatGPTRenewal { [weak s, weak vault] body in
                    guard let t = OpenAIAccess.refreshToken(inRenewalBody: body), t.hasPrefix(CredentialVault.placeholderPrefix) else { return nil }
                    guard let vault, vault.binding(ofPlaceholder: t) == CredentialBinding.chatgpt.id, let s else {
                        return OpenAIAccess.refreshAnswer(placeholder: t, guestIDToken: nil,
                                                          problem: "this renewal carried a placeholder that is not this sandbox's ChatGPT sign-in")
                    }
                    return s.renewalAnswer(placeholder: t)
                }
            } else {
                clearChatGPT(nil)
                let read = services.keychain.read(service: a.keychainService ?? "", account: a.adopted == true ? nil : Keychain.user)
                if let secret = read.value {
                    sb.setCredential(.openai, secret: secret, expiresAt: nil, environment: [:],
                                     notice: "the OpenAI key of account \(a.name) is not available — doz account add \(a.name) --openai-key --force")
                } else {
                    sb.setCredential(.openai, secret: nil, expiresAt: nil, environment: [:],
                                     notice: "the keychain item \(a.keychainService ?? "?") of account \(a.name) is \(read == .locked ? "locked" : "missing") — "
                                             + (read == .locked ? "unlock the login keychain" : "add it again: doz account add \(a.name) --openai-key --force"))
                }
            }
        }
    }

    /// 599i: the guest's `~/.codex/auth.json` for this session start — placeholders only (a ChatGPT
    /// sign-in: one placeholder for both tokens, the id_token's claims under a fake signature, the account
    /// id, last_refresh now; an API key: its placeholder). No OpenAI account: a file Dozer wrote is removed
    /// (a person's own in-sandbox login is left alone). nil: not a Codex sandbox.
    func codexAuthScript(_ m: Managed) -> String? {
        guard m.config.imageChoice?.agent == .codex, let imageSpec = m.config.spec.imageSpec, let egress = m.sandbox.egress else { return nil }
        let home = imageSpec.sessionEnvironment["CODEX_HOME"] ?? imageSpec.home + "/.codex"
        let file = home + "/auth.json"
        let user = imageSpec.user
        var data: Data?
        if case .record(let a) = resolvedAccount(m, accountStore.load()), AgentCredentials.accepts(imageSpec.name, a.kind) {
            defer { if data == nil { HostLog.line("\(m.name): Codex's auth.json left as it is (the account \(a.name) has no usable credential now)") } }
            switch a.kind {
            case .chatgpt:
                if let s = chatgptSessions[a.name], let id = s.guestIDToken, let t = egress.vault.mintForFile(CredentialBinding.chatgpt.id) {
                    data = OpenAIAccess.guestAuthJSON(placeholder: t, guestIDToken: id, accountID: s.accountID)
                }
            case .openaiKey:
                if let t = egress.vault.mintForFile(CredentialBinding.openai.id) { data = OpenAIAccess.guestAPIKeyAuthJSON(placeholder: t) }
            default: break
            }
            // An account whose credential cannot be used now: its placeholders already in the guest are answered
            // by the proxy with why — the file is left as it is.
            guard data != nil else { return nil }
        }
        guard let data else {
            // Only a file Dozer wrote (it holds a Dozer placeholder) is removed.
            return "if [ -f '\(file)' ] && grep -q '\(CredentialVault.placeholderPrefix)' '\(file)'; then rm -f '\(file)'; fi"
        }
        let b = data.base64EncodedString()
        return """
        set -e
        if [ ! -d '\(home)' ]; then mkdir -p '\(home)'; chown '\(user):\(user)' '\(home)'; chmod 0700 '\(home)'; fi
        printf %s '\(b)' | base64 -d > '\(file).doz-tmp'
        chown '\(user):\(user)' '\(file).doz-tmp'
        chmod 0600 '\(file).doz-tmp'
        mv -f '\(file).doz-tmp' '\(file)'
        """
    }

    /// Write (or remove) the guest's auth.json — a root utility exec at session start. A failure is a note.
    func deliverCodexAuth(_ m: Managed) async {
        guard let script = codexAuthScript(m) else { return }
        do {
            let r = try await m.sandbox.exec(["sh", "-c", script], timeoutSeconds: 30)
            if r.exitCode != 0 { note(m.name, "could not write Codex's credentials (exit \(r.exitCode))") }
        } catch {
            note(m.name, "could not write Codex's credentials: \(error.localizedDescription)")
        }
    }
}
