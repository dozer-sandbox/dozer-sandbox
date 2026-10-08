import Darwin
import Foundation
import DozerKit

// 599i rc.3 (owner: "the least amount of setup for the user if they already have codex installed and logged
// in") — the account `mac` for Codex: THIS Mac's own Codex login, as `mac` is this Mac's Claude login (588's
// rules are the template).
//
//   · Dozer READS ONLY the access token (and the id_token claims / account id the guest's auth.json needs) from
//     `$CODEX_HOME/auth.json` (else `~/.codex/auth.json` — Codex's FILE store). It never uses, holds or writes the
//     refresh token, and never writes CODEX_HOME: the Mac's Codex stays the one refresher (a second refresher would
//     spend its single-use refresh token and sign the Mac out).
//   · Re-read on use: the file's inode/size/mtime is the vault provider's "version", so a refresh the Mac's Codex
//     did reaches every sandbox at its next request.
//   · Staleness (Codex 0.160.1): access tokens live ~1 h; Codex refreshes when the token is within 5 minutes of
//     expiry, whenever it asks for its auth (`login/src/auth/manager.rs` `auth()` → `should_refresh_proactively`).
//     The Codex app's background server lists models every 4½ minutes (`app-server/src/models_refresh_worker.rs`),
//     which asks for the auth — so while the app (or any codex session) runs, the login stays fresh. With nothing
//     running it expires; the proxy then answers with Dozer's message, never another account.
//   · Keep-alive (opt-in, `codex.keep_alive`): when the token is within Codex's window and a sandbox used it
//     recently, run the Mac's OWN `codex doctor` once — it asks for the auth (its websocket check, `cli/src/
//     doctor.rs`), which refreshes; no model is called.
//   · The keyring store (`cli_auth_credentials_store = "keyring"`, or "auto" with no auth.json) is not supported
//     yet — said plainly. An API-key login on the Mac is not used as `mac` (add the key as an openai-key account).
//
// Tests never read the real ~/.codex: `DOZ_TEST_CODEX_HOME` names a fake one; under the memory credential seam
// without it there is no Mac Codex login; and inside XCTest without it the process stops (`resolveHome`).

/// What `mac` (for Codex) reads, as data — never the refresh token.
public struct CodexMacToken: Equatable, Sendable, CustomStringConvertible {
    public var accessToken: String
    public var accountID: String?
    /// `OpenAIAccess.keptClaims` of the Mac's id_token.
    public var claims: String
    public var expiresAt: Date? { OpenAIAccess.expiry(accessToken) }
    public var description: String { "CodexMacToken(<redacted>, account \(accountID ?? "?"))" }
}

public enum CodexMacLoginState: Equatable, Sendable {
    case ok, expired, signedOut
    /// The Mac's Codex keeps its login in the keyring — not supported yet.
    case keyring
    /// The Mac's Codex uses an API key, not a ChatGPT sign-in.
    case apiKey
    case unreadable(String)

    public var label: String {
        switch self {
        case .ok: "ok"
        case .expired: "expired"
        case .signedOut: "signed-out"
        case .keyring: "keyring (not supported)"
        case .apiKey: "api-key login"
        case .unreadable: "unreadable"
        }
    }
}

public enum CodexMacLogin {
    /// The Mac's Codex home: `DOZ_TEST_CODEX_HOME` (tests), else `$CODEX_HOME`, else `~/.codex`. nil: none to read
    /// (the memory credential seam without a fake home). Inside XCTest without a fake home: a hard stop — a test
    /// must never resolve the real ~/.codex.
    public static func resolveHome(environment env: [String: String] = ProcessInfo.processInfo.environment,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        if let t = env["DOZ_TEST_CODEX_HOME"], !t.isEmpty { return URL(fileURLWithPath: t) }
        if env["DOZ_TEST_CREDENTIALS"] == "memory" { return nil }
        if NSClassFromString("XCTestCase") != nil {
            fatalError("a test resolved the Mac's real Codex home — set DOZ_TEST_CODEX_HOME (599i: tests never read ~/.codex)")
        }
        let resolved: URL
        if let c = env["CODEX_HOME"], !c.isEmpty { resolved = URL(fileURLWithPath: (c as NSString).expandingTildeInPath) }
        else { resolved = home.appendingPathComponent(".codex") }
        // 611: a guarded test run (DOZ_TEST_GUARD=1) never reads this Mac's real ~/.codex, wherever it came from.
        TestSafety.enforce(TestSafety.codexHomeViolation(resolved), env: env)
        return resolved
    }

    /// The file's identity — the vault's provider "version" (a refresh rewrites it: new inode or mtime).
    public static func fileVersion(_ codexHome: URL?) -> String {
        guard let h = codexHome else { return "none" }
        var st = stat()
        guard stat(h.appendingPathComponent("auth.json").path, &st) == 0 else { return "absent" }
        return "\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
    }

    /// Read the Mac's login: the access token and what the guest needs. The JSON is parsed and only those fields
    /// are taken; the refresh token is never copied out of the parse.
    public static func read(_ codexHome: URL?, now: Date = Date()) -> (token: CodexMacToken?, state: CodexMacLoginState) {
        guard let h = codexHome else { return (nil, .signedOut) }
        let file = h.appendingPathComponent("auth.json")
        guard let d = FileManager.default.contents(atPath: file.path) else {
            return (nil, usesKeyring(h) ? .keyring : .signedOut)
        }
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return (nil, .unreadable("auth.json is not JSON")) }
        let mode = o["auth_mode"] as? String
        let tokens = o["tokens"] as? [String: Any]
        if mode == "apikey" || (tokens == nil && o["OPENAI_API_KEY"] is String) { return (nil, .apiKey) }
        guard let access = tokens?["access_token"] as? String, !access.isEmpty else { return (nil, .signedOut) }
        let id = tokens?["id_token"] as? String ?? ""
        let account = (tokens?["account_id"] as? String) ?? OpenAIAccess.accountID(idToken: id)
        let t = CodexMacToken(accessToken: access, accountID: account, claims: OpenAIAccess.keptClaims(idToken: id))
        if let e = t.expiresAt, e <= now { return (t, .expired) }
        return (t, .ok)
    }

    /// `cli_auth_credentials_store = "keyring"` (or "auto") in the Mac's config.toml — one key read, nothing else.
    static func usesKeyring(_ h: URL) -> Bool {
        guard let text = try? String(contentsOf: h.appendingPathComponent("config.toml"), encoding: .utf8) else { return false }
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("cli_auth_credentials_store") else { continue }
            return l.contains("\"keyring\"") || l.contains("\"auto\"")
        }
        return false
    }

    /// The Mac's `codex` (`DOZ_TEST_CODEX_BIN` in tests).
    public static func resolveBinary(environment env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let t = env["DOZ_TEST_CODEX_BIN"], !t.isEmpty { return FileManager.default.isExecutableFile(atPath: t) ? t : nil }
        if env["DOZ_TEST_CREDENTIALS"] == "memory" { return nil }
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        dirs += (env["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.map { $0 + "/codex" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The keep-alive's command: no model call — `codex doctor` asks for the auth, which refreshes it.
    public static let keepaliveArguments = ["doctor"]
}

/// ONE reader of the Mac's Codex login per host, for every Codex sandbox that uses `mac`.
public final class CodexMacSession: @unchecked Sendable {
    /// Codex refreshes within 5 minutes of expiry; the keep-alive runs inside that window (with a margin).
    public static let keepaliveWindow: TimeInterval = 270
    public static let recentUse: TimeInterval = 900

    public let codexHome: URL?
    let runner: KeepaliveRunning
    let binary: @Sendable () -> String?
    let keepaliveEnabled: @Sendable () -> Bool
    private let lock = NSLock()
    private var cache: (version: String, token: CodexMacToken?, state: CodexMacLoginState)?
    private var lastKeepaliveFor: Date?
    private var task: Task<Void, Never>?
    private var _lastUse: Date?
    public var onNote: (@Sendable (String) -> Void)?

    public init(codexHome: URL?, runner: KeepaliveRunning = ProcessKeepaliveRunner(),
                binary: @escaping @Sendable () -> String? = { CodexMacLogin.resolveBinary() },
                keepaliveEnabled: @escaping @Sendable () -> Bool) {
        self.codexHome = codexHome
        self.runner = runner
        self.binary = binary
        self.keepaliveEnabled = keepaliveEnabled
    }

    /// The login now (re-read when the file changed).
    public func current(now: Date = Date()) -> (token: CodexMacToken?, state: CodexMacLoginState) {
        let v = CodexMacLogin.fileVersion(codexHome)
        lock.lock()
        if let c = cache, c.version == v {
            lock.unlock()
            if c.state == .ok, let e = c.token?.expiresAt, e <= now { return (c.token, .expired) }
            return (c.token, c.state)
        }
        lock.unlock()
        let r = CodexMacLogin.read(codexHome, now: now)
        lock.withLock { cache = (v, r.token, r.state) }
        return r
    }

    public var state: CodexMacLoginState { current().state }
    public var accessExpiry: Date? { current().token?.expiresAt }
    public var accountID: String? { current().token?.accountID }
    public var guestIDToken: String? { current().token.map { OpenAIAccess.idToken(claims: $0.claims) } }
    /// The vault provider's version: the file's identity.
    public var version: String { CodexMacLogin.fileVersion(codexHome) }

    /// Why `mac` cannot be used now — the proxy's text, never another account. nil: usable.
    public func problem(now: Date = Date()) -> String? {
        switch current(now: now).state {
        case .ok: return nil
        case .expired: return "your Mac's Codex login has expired — run codex on the Mac (any command that talks to OpenAI), or turn on the keep-alive: doz config set codex.keep_alive true"
        case .signedOut: return "this Mac's Codex is not signed in — run codex login on the Mac, or choose another account: doz account use NAME ACCOUNT"
        case .keyring: return "this Mac's Codex keeps its login in the keyring (cli_auth_credentials_store), which Dozer cannot read yet — use doz account add NAME --chatgpt instead"
        case .apiKey: return "this Mac's Codex uses an API key, not a ChatGPT sign-in — add the key as an account: doz account add NAME --openai-key"
        case .unreadable(let why): return "Dozer could not read this Mac's Codex login (\(why))"
        }
    }

    /// The vault's provider read: the access token, or why not (a stale one: the keep-alive, when on, runs first).
    public func read(now: Date = Date()) -> CredentialVault.SecretRead {
        lock.withLock { _lastUse = now }
        if current(now: now).state == .expired { keepaliveIfDue(now: now) }
        let c = current(now: Date())
        guard c.state == .ok, let t = c.token else { return (nil, "Dozer: " + (problem() ?? "no Codex login on this Mac")) }
        return (t.accessToken, nil)
    }

    /// Codex's own renewal in the guest: the same placeholder back — the Mac renews, never Dozer.
    public func renewalAnswer(placeholder: String) -> [UInt8] {
        _ = read()
        return OpenAIAccess.refreshAnswer(placeholder: placeholder, guestIDToken: guestIDToken, problem: problem())
    }

    /// Poll every minute while sandboxes use `mac`: the keep-alive when it is due.
    public func start(interval: Duration = .seconds(60)) {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                self.keepaliveIfDue()
            }
        }
    }

    public func stop() { lock.lock(); task?.cancel(); task = nil; lock.unlock() }

    /// The Mac's own `codex doctor` once, when the access token is within Codex's refresh window (or past it), a
    /// sandbox used it recently, the setting is on, and it has not already run for this expiry.
    @discardableResult
    public func keepaliveIfDue(now: Date = Date()) -> Bool {
        guard keepaliveEnabled() else { return false }
        let c = current(now: now)
        guard let exp = c.token?.expiresAt, c.state == .ok || c.state == .expired, exp.timeIntervalSince(now) <= Self.keepaliveWindow else { return false }
        lock.lock()
        let used = _lastUse.map { now.timeIntervalSince($0) <= Self.recentUse } ?? false
        guard used, lastKeepaliveFor != exp else { lock.unlock(); return false }
        lastKeepaliveFor = exp
        lock.unlock()
        guard let bin = binary() else {
            onNote?("Codex keep-alive skipped — the codex command isn't installed on this Mac")
            return false
        }
        onNote?("Codex keep-alive — this Mac's Codex login expires \(CredentialVaultClock.hm(exp)) and a sandbox is using it: running the Mac's codex doctor once (no model call)")
        var env: [String: String] = [:]
        for k in ["PATH", "HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL", "CODEX_HOME"] { if let v = ProcessInfo.processInfo.environment[k] { env[k] = v } }
        if let h = codexHome { env["CODEX_HOME"] = h.path }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-keepalive")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let code = runner.run(binary: bin, arguments: CodexMacLogin.keepaliveArguments, environment: env, directory: dir, timeout: 90)
        let after = current(now: Date())
        onNote?("Codex keep-alive finished (exit \(code)); this Mac's Codex login " + (after.state == .ok ? "is ok" + (after.token?.expiresAt.map { " until \(CredentialVaultClock.hm($0))" } ?? "") : "is \(after.state.label)"))
        return true
    }
}

extension HostCore {
    /// The ONE reader of this Mac's Codex login (keep-alive setting read at each look).
    func codexMacSession() -> CodexMacSession {
        if let s = codexMacReader { return s }
        let env = ProcessInfo.processInfo.environment
        let s = CodexMacSession(codexHome: services.codexHome(), runner: services.codexRunner, binary: services.codexBinary,
                                keepaliveEnabled: { DozerSettings.load(environment: env).bool(SettingKey.codexKeepAlive) })
        s.onNote = { [weak self] t in Task { await self?.note(nil, t) } }
        codexMacReader = s
        return s
    }

    /// Whether this Mac has a Codex login `mac` can use (signed in, even if the access token has expired).
    func codexMacSignedIn() -> Bool {
        let st = codexMacSession().state
        return st == .ok || st == .expired
    }

    /// Why `mac` cannot be chosen for Codex (nil: it can — an expired token is chosen; the proxy then says so).
    func codexMacSignInProblem() -> String? {
        codexMacSignedIn() ? nil : codexMacSession().problem()
    }

    /// The store's OpenAI default: the one chosen, else `mac` when this Mac's Codex is signed in, else none.
    func effectiveOpenAIDefault(_ file: AccountsFile) -> String? {
        if let d = file.openaiDefault { return d }
        return codexMacSignedIn() ? "mac" : nil
    }

    /// The default account that applies to a sandbox of `image` (Codex: the OpenAI default above).
    func defaultAccount(for image: String?, _ file: AccountsFile) -> String {
        AgentCredentials.provider(image) == "openai" ? (effectiveOpenAIDefault(file) ?? "none") : file.defaultAccount
    }

    /// `account ls`'s row for this Mac's Codex login — only when there is one to speak of (never a token).
    func codexMacRow(_ file: AccountsFile, now: Date = Date()) -> AccountRow? {
        let s = codexMacSession()
        let c = s.current(now: now)
        if c.state == .signedOut { return nil }
        let id = c.token.map { OpenAIAccess.idToken(claims: $0.claims) }
        return AccountRow(name: "mac", kind: AccountKind.codexMac.rawValue, plan: id.flatMap(OpenAIAccess.planType(idToken:)),
                          identity: id.flatMap(OpenAIAccess.email(idToken:)), expiresAt: c.token?.expiresAt,
                          verification: "this Mac's Codex login (read-only — the Mac's Codex renews it)",
                          isDefault: effectiveOpenAIDefault(file) == "mac",
                          usedBy: managed.values.filter { m in if case .record(let a) = resolvedAccount(m, file), a.kind == .codexMac { return true }; return false }
                            .map(\.name).sorted(),
                          state: c.state.label, keychainService: nil, fingerprint: c.token.map { CredentialFingerprint.of($0.accessToken) })
    }
}

/// 611: the test guard's decision about the Mac's Codex home (kept here — the one file that names it).
extension TestSafety {
    /// Why reading `codexHome` is refused (nil: allowed). The Mac's real `~/.codex`.
    public static func codexHomeViolation(_ codexHome: URL, home: URL = realHome) -> String? {
        let real = home.appendingPathComponent(".codex").standardizedFileURL.path
        guard codexHome.standardizedFileURL.path == real || codexHome.resolvingSymlinksInPath().path == real else { return nil }
        return "a test resolved this Mac's real Codex home (\(real)) — set DOZ_TEST_CODEX_HOME to a scratch folder"
    }

}
