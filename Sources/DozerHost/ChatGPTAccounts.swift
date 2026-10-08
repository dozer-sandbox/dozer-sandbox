import CryptoKit
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

/// One ChatGPT account's sign-in in the host: what the keychain keeps (`ChatGPTRecord`: the refresh token, the
/// kept claims), the access token in MEMORY only, their renewal, and what the proxy needs — the access token for
/// a request, Codex's renewal answer, the guest's id_token.
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
    private var record: ChatGPTRecord?
    /// The access token — memory only, never written anywhere.
    private var access: String?
    private var _state: State = .unknown
    private var stale = false
    private var lastFailure: Date?
    private var _generation = 0
    private var _lastRefresh: Date?
    /// The keychain could not keep the rotated refresh token (the item was removed rather than left stale).
    private var _notKept = false
    /// 611: set by a public build — this account is never used, and every read says why.
    public var unsupported: String? {
        get { lock.withLock { _unsupported } }
        set { lock.withLock { _unsupported = newValue } }
    }
    private var _unsupported: String?
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
    public var accessExpiry: Date? { lock.withLock { access.flatMap { OpenAIAccess.expiry($0) } } }
    public var accountID: String? { lock.withLock { record?.accountID } }
    public var notKept: Bool { lock.withLock { _notKept } }
    /// The id_token the GUEST gets: the kept claims, not a signature.
    public var guestIDToken: String? { lock.withLock { record?.idToken } }

    /// A sign-in just made (`account add`): the access token in memory, the record as kept.
    public func adopt(_ t: ChatGPTTokens) {
        lock.withLock {
            record = ChatGPTRecord(t)
            access = t.accessToken
            _state = .ok
            stale = false
            lastFailure = nil
            _notKept = false
            _generation += 1
        }
    }

    /// (Re-)read the keychain item. The access token in memory is kept when the refresh token is the same
    /// (a re-read changes nothing); otherwise the next use renews it.
    public func load() {
        let r = KeychainChunks.read(keychain, service: service)
        lock.withLock {
            switch r {
            case .found(let s):
                if let rec = ChatGPTRecord.parse(s) {
                    if rec.refreshToken != record?.refreshToken { access = nil }
                    record = rec
                    _state = .ok
                } else { record = nil; access = nil; _state = .signedOut("the keychain item holds no sign-in") }
            case .locked: if record == nil { _state = .locked }
            case .absent, .failed:
                // Kept in memory after a failed rotation write: still usable until the host stops.
                if !_notKept { record = nil; access = nil; _state = .missing }
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
        if let u = unsupported { return u }
        switch state {
        case .unknown, .ok, .unavailable: return lock.withLock { record == nil } ? "the ChatGPT sign-in of account \(n) is not loaded" : nil
        case .missing: return "the keychain item \(service) of account \(n) is missing — sign in again on this Mac: doz account add \(n) --chatgpt --force"
        case .locked: return "the login keychain is locked — unlock it on this Mac (account \(n))"
        case .signedOut(let why): return "the ChatGPT sign-in of account \(n) has ended (\(why)) — sign in again on this Mac: doz account add \(n) --chatgpt --force"
        }
    }

    /// Renew when there is no access token (a new host), it is about to expire, or it was refused (`force`: now).
    /// Blocking — a proxy thread or a detached task, never the host actor. Returns the problem, nil when usable.
    @discardableResult
    public func ensureFresh(now: Date = Date(), force: Bool = false) -> String? {
        func needs() -> Bool {
            lock.withLock {
                guard record != nil else { return false }
                switch _state {
                case .ok: break
                case .unavailable: return lastFailure.map { now.timeIntervalSince($0) >= Self.retryAfter } ?? true
                default: return false
                }
                guard let a = access else { return true }
                if force || stale { return true }
                guard let exp = OpenAIAccess.expiry(a) else { return false }
                return exp.timeIntervalSince(now) < Self.refreshWindow
            }
        }
        if unsupported != nil { return problem() }       // 611: a public build never renews it
        guard needs() else { return problem() }
        refreshing.lock()
        defer { refreshing.unlock() }
        guard needs(), let rec = lock.withLock({ record }) else { return problem() }   // another caller renewed it meanwhile
        let current = ChatGPTTokens(idToken: rec.idToken, accessToken: lock.withLock { access } ?? "", refreshToken: rec.refreshToken, accountID: rec.accountID)
        switch refresher(current) {
        case .renewed(let n):
            // The ROTATED refresh token is kept before the new access token is used: the old one is spent. A
            // write that fails leaves NO item (never a spent token to try later): the sign-in then lives in this
            // host's memory only, and the next host asks to sign in again.
            let kept = ChatGPTRecord(n)
            var ok = true
            do { try KeychainChunks.write(keychain, service: service, secret: kept.json) } catch { ok = false; KeychainChunks.remove(keychain, service: service) }
            lock.withLock {
                record = kept
                access = n.accessToken
                _state = .ok
                stale = false
                lastFailure = nil
                _lastRefresh = now
                _notKept = !ok
                _generation += 1
            }
            onNote?("the ChatGPT sign-in of account \(account) was renewed on this Mac"
                    + (ok ? "" : " — but the keychain could not keep the new refresh token: it is held in memory until the host stops (then: doz account add \(account) --chatgpt --force)"))
            return nil
        case .signedOut(let why):
            lock.withLock { _state = .signedOut(why); access = nil; _generation += 1 }
            onNote?("the ChatGPT sign-in of account \(account) has ended (\(why)) — doz account add \(account) --chatgpt --force")
            return problem()
        case .unavailable(let why):
            lock.withLock { _state = .unavailable(why); lastFailure = now }
            onNote?("could not renew the ChatGPT sign-in of account \(account) (\(why)) — retrying on the next request")
            if let exp = accessExpiry, exp > now { return nil }
            return "the ChatGPT sign-in of account \(account) could not be renewed (\(why)) — check this Mac's network; Dozer tries again on the next request"
        }
    }

    /// The access token for a request now (the vault's provider read): renewed first when needed.
    public func read(now: Date = Date()) -> CredentialVault.SecretRead {
        if let p = ensureFresh(now: now) { return (nil, "Dozer: " + p) }
        guard let a = lock.withLock({ access }) else { return (nil, "Dozer: " + (problem() ?? "no ChatGPT sign-in")) }
        if let exp = OpenAIAccess.expiry(a), exp <= now {
            return (nil, "Dozer: the ChatGPT sign-in of account \(account) expired and could not be renewed — check this Mac's network")
        }
        return (a, nil)
    }

    /// The proxy's answer to Codex's own renewal (its refresh token is a placeholder): renew on the Mac if
    /// needed, then the same placeholder back with the kept claims — or 401 with why.
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
        if !buildFlavor.chatgptSignIn { s.unsupported = BuildFlavor.chatgptAccountUnsupported(a.name) }   // 611
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
        case .record(let a) where a.kind == .codexMac:
            // 599i rc.3: this Mac's own Codex login — its access token read on use (the file's identity is the
            // provider's version: a refresh the Mac did reaches the next request); the Mac renews, never Dozer.
            m.config.credentialSources[CredentialBinding.openai.id] = nil
            sb.setCredential(.openai, secret: nil, expiresAt: nil, environment: [:], notice: nil)
            let s = codexMacSession()
            let vault = egress.vault
            vault.setProvider(.chatgpt, ttl: 30, version: { [weak s] in s?.version ?? "" }, read: { [weak s] in
                s?.read() ?? (nil, "Dozer: this Mac's Codex login is not loaded")
            })
            vault.onStale = { _ in }
            egress.chatgptRenewal = EgressProxy.ChatGPTRenewal { [weak s, weak vault] body in
                guard let t = OpenAIAccess.refreshToken(inRenewalBody: body), t.hasPrefix(CredentialVault.placeholderPrefix) else { return nil }
                guard let vault, vault.binding(ofPlaceholder: t) == CredentialBinding.chatgpt.id, let s else {
                    return OpenAIAccess.refreshAnswer(placeholder: t, guestIDToken: nil,
                                                      problem: "this renewal carried a placeholder that is not this sandbox's")
                }
                return s.renewalAnswer(placeholder: t)
            }
            s.start()
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
            case .codexMac:
                let s = codexMacSession()
                if let id = s.guestIDToken, let t = egress.vault.mintForFile(CredentialBinding.chatgpt.id) {
                    data = OpenAIAccess.guestAuthJSON(placeholder: t, guestIDToken: id, accountID: s.accountID)
                }
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

// MARK: - what the keychain keeps of a sign-in (599i rc.2)

/// A secret longer than one keychain item can hold (`Keychain.maximumSecretBytes`), kept as numbered items:
/// `SERVICE#1…#n` hold the parts and `SERVICE` itself a header `doz-chunks:n:<sha256 hex>`, written LAST — so a
/// reader never takes a half-written set for a secret (the digest must match the joined parts). A secret that
/// fits is one item, as before. Any failed write removes everything it may have touched: never a partial secret.
public enum KeychainChunks {
    public static let headerPrefix = "doz-chunks:"
    public static let maximumParts = 8

    static func part(_ service: String, _ i: Int) -> String { "\(service)#\(i)" }

    static func digest(_ s: String) -> String { SHA256Hex.of(s) }

    public static func write(_ k: KeychainAccess, service: String, secret: String) throws {
        let bytes = Array(secret.utf8)
        if bytes.count <= Keychain.maximumSecretBytes, !secret.hasPrefix(headerPrefix) {
            do { try k.write(service: service, account: Keychain.user, secret: secret) } catch { remove(k, service: service); throw error }
            for i in 1...maximumParts { try? k.delete(service: part(service, i), account: Keychain.user) }
            return
        }
        let size = Keychain.maximumSecretBytes
        let n = (bytes.count + size - 1) / size
        guard n <= maximumParts else {
            throw HostError(.invalid, "the secret for \(service) is \(bytes.count) bytes — more than \(maximumParts) keychain items can hold; nothing written")
        }
        do {
            for i in 0..<n {
                let slice = String(decoding: bytes[(i * size)..<min(bytes.count, (i + 1) * size)], as: UTF8.self)
                try k.write(service: part(service, i + 1), account: Keychain.user, secret: slice)
            }
            for i in (n + 1)...maximumParts where n < maximumParts { try? k.delete(service: part(service, i), account: Keychain.user) }
            try k.write(service: service, account: Keychain.user, secret: "\(headerPrefix)\(n):\(digest(secret))")
        } catch {
            remove(k, service: service)
            throw error
        }
    }

    public static func read(_ k: KeychainAccess, service: String) -> KeychainRead {
        let head = k.read(service: service, account: Keychain.user)
        guard case .found(let h) = head, h.hasPrefix(headerPrefix) else { return head }
        let fields = h.dropFirst(headerPrefix.count).split(separator: ":")
        guard fields.count == 2, let n = Int(fields[0]), (1...maximumParts).contains(n) else { return .failed }
        var joined = ""
        for i in 1...n {
            switch k.read(service: part(service, i), account: Keychain.user) {
            case .found(let p): joined += p
            case .locked: return .locked
            default: return .failed
            }
        }
        return digest(joined) == String(fields[1]) ? .found(joined) : .failed
    }

    /// The item and every part.
    public static func remove(_ k: KeychainAccess, service: String) {
        try? k.delete(service: service, account: Keychain.user)
        for i in 1...maximumParts { try? k.delete(service: part(service, i), account: Keychain.user) }
    }
}

enum SHA256Hex {
    static func of(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
}

/// What Dozer KEEPS of a ChatGPT sign-in (`doz-chatgpt:NAME`): the refresh token (it rotates — written after
/// every renewal), the account id, and the few id_token claims the guest's auth.json needs. The access token
/// lives only in the host's memory (renewed on a host's first use and near expiry); the signed id_token is
/// never kept. Small by design (a real sign-in's tokens are ~4 KB; this is a few hundred bytes plus the
/// refresh token) — and chunked by `KeychainChunks` if a refresh token is ever long.
public struct ChatGPTRecord: Codable, Equatable, Sendable, CustomStringConvertible {
    public var version = 2
    public var refreshToken: String
    public var accountID: String?
    /// The kept claims as base64url JSON (`OpenAIAccess.keptClaims`).
    public var claims: String

    enum CodingKeys: String, CodingKey { case version = "v", refreshToken = "refresh_token", accountID = "account_id", claims }

    public init(refreshToken: String, accountID: String?, claims: String) {
        self.refreshToken = refreshToken
        self.accountID = accountID
        self.claims = claims
    }

    public init(_ t: ChatGPTTokens) {
        self.init(refreshToken: t.refreshToken, accountID: t.accountID, claims: OpenAIAccess.keptClaims(idToken: t.idToken))
    }

    public var description: String { "ChatGPTRecord(<redacted>, account \(accountID ?? "?"))" }

    public var json: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// The kept record — or (an rc.1 item) the whole tokens, slimmed.
    public static func parse(_ s: String) -> ChatGPTRecord? {
        if let d = s.data(using: .utf8), let r = try? JSONDecoder().decode(ChatGPTRecord.self, from: d), !r.refreshToken.isEmpty { return r }
        return ChatGPTTokens.parse(s).map(ChatGPTRecord.init)
    }

    /// An id_token carrying only the kept claims (an unsigned stand-in — for the guest and as a refresh's previous).
    public var idToken: String { OpenAIAccess.idToken(claims: claims) }
}
