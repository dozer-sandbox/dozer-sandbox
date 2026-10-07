import Foundation
import DozerKit

/// Runs the Mac's own `claude` once (the keep-alive, 588 D3). A fake in tests.
public protocol KeepaliveRunning: Sendable {
    func run(binary: String, arguments: [String], environment: [String: String], directory: URL, timeout: TimeInterval) -> Int32
}

public struct ProcessKeepaliveRunner: KeepaliveRunning {
    public init() {}
    public func run(binary: String, arguments: [String], environment: [String: String], directory: URL, timeout: TimeInterval) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = arguments
        p.environment = environment
        p.currentDirectoryURL = directory
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return -2 }
        return p.terminationStatus
    }
}

/// How the keep-alive decides and acts (injected so tests use a fake runner and fake probes).
public struct KeepaliveConfig: Sendable {
    public var enabled: Bool
    public var runner: KeepaliveRunning
    public var isClaudeRunning: @Sendable () -> Bool
    public var binary: @Sendable () -> String?
    /// Run when the access token expires within this long (or already has)…
    public var window: TimeInterval = 600
    /// …and a sandbox used it within this long.
    public var recentUse: TimeInterval = 900

    public init(enabled: Bool, runner: KeepaliveRunning = ProcessKeepaliveRunner(),
                isClaudeRunning: @escaping @Sendable () -> Bool = { ClaudeLogin.isClaudeRunning() },
                binary: @escaping @Sendable () -> String? = { ClaudeLogin.resolveBinary() }) {
        self.enabled = enabled
        self.runner = runner
        self.isClaudeRunning = isClaudeRunning
        self.binary = binary
    }

    /// The one command: the Mac's Claude Code, one tiny non-interactive turn. Its normal startup
    /// renews the login under Claude Code's own lock — doz never touches the refresh token.
    public static let arguments = ["-p", "ok", "--model", "haiku", "--max-turns", "1", "--no-session-persistence"]
}

/// ONE watcher per Mac Claude login (keychain item), fanned out to every sandbox that uses it
/// (588: one `security` read per interval however many sandboxes follow it).
///
/// It follows the Mac: a renewed access token goes to every subscriber's vault; an expired one
/// stays (the proxy answers 401 with how to renew it); a Mac sign-out clears it at once (D5); a
/// different account signing in on the Mac HOLDS every subscriber (D6) until `account use … mac`
/// follows it; a locked or unreadable keychain keeps the last token and warns.
public final class LoginWatcher: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case unknown, ok, expired, signedOut, accountChanged, unreadable
        public var label: String {
            switch self {
            case .unknown: "unknown"
            case .ok: "ok"
            case .expired: "expired"
            case .signedOut: "signed-out"
            case .accountChanged: "held"
            case .unreadable: "unreadable"
            }
        }
    }

    public let account: String
    public let configDir: String?
    public let service: String
    let keychain: KeychainAccess
    let identityReader: @Sendable () -> ClaudeIdentity?

    private let lock = NSLock()
    private var _pinned: ClaudeIdentity?
    private var _seen: ClaudeIdentity?
    private var token: ClaudeLoginToken?
    private var _state: State = .unknown
    private var warnedUnreadable = false
    private var subscribers: [String: Sandbox] = [:]
    private var _reads = 0
    private var lastKeepaliveFor: Date?
    private var _keepalive: KeepaliveConfig?
    private var task: Task<Void, Never>?

    /// (sandbox or nil for the host, text) — the host turns these into events.
    public var onEvent: @Sendable (String?, String) -> Void = { _, _ in }
    /// The first identity seen while none is pinned (the host records it in accounts.json).
    public var onIdentity: @Sendable (ClaudeIdentity) -> Void = { _ in }

    public init(account: String, configDir: String?, keychain: KeychainAccess, pinned: ClaudeIdentity?,
                identityReader: (@Sendable () -> ClaudeIdentity?)? = nil) {
        self.account = account
        self.configDir = configDir
        self.service = ClaudeLogin.service(configDir: configDir)
        self.keychain = keychain
        self._pinned = pinned
        self.identityReader = identityReader ?? { ClaudeLogin.identity(configDir: configDir) }
    }

    public var state: State { lock.lock(); defer { lock.unlock() }; return _state }
    public var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }
    public var expiresAt: Date? { lock.lock(); defer { lock.unlock() }; return token?.expiresAt }
    public var subscriberNames: [String] { lock.lock(); defer { lock.unlock() }; return subscribers.keys.sorted() }
    public var seenIdentity: ClaudeIdentity? { lock.lock(); defer { lock.unlock() }; return _seen }
    public var keepalive: KeepaliveConfig? {
        get { lock.lock(); defer { lock.unlock() }; return _keepalive }
        set { lock.lock(); _keepalive = newValue; lock.unlock() }
    }

    /// Follow whoever is signed in on the Mac now (the one-command follow after a hold).
    public func repin(_ identity: ClaudeIdentity?) {
        lock.lock(); _pinned = identity; lock.unlock()
        readNow()
    }

    public func subscribe(_ name: String, _ sandbox: Sandbox) {
        lock.lock()
        subscribers[name] = sandbox
        let first = _state == .unknown
        lock.unlock()
        if first { readNow() } else { lock.lock(); apply(name, sandbox); lock.unlock() }
    }

    public func unsubscribe(_ name: String) {
        lock.lock(); subscribers[name] = nil; lock.unlock()
    }

    public var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return subscribers.isEmpty }

    /// Poll every `interval` (ContinuousClock: it counts across Mac sleep, so a wake reads soon).
    public func start(interval: Duration = .seconds(120)) {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    public func stop() { lock.lock(); task?.cancel(); task = nil; lock.unlock() }

    /// One poll: read, fan out, and the keep-alive when it is due.
    public func tick(now: Date = Date()) {
        readNow(now: now)
        keepaliveIfDue(now: now)
    }

    /// A proxy found the token expired or had it refused upstream: read now; still expired → the
    /// keep-alive (when enabled) runs off the proxy's thread.
    public func stale(now: Date = Date()) {
        readNow(now: now)
        if state == .expired, keepalive?.enabled == true {
            DispatchQueue.global().async { [weak self] in self?.keepaliveIfDue(now: Date()) }
        }
    }

    /// Read the keychain item once and fan out whatever changed.
    public func readNow(now: Date = Date()) {
        let r = keychain.read(service: service, account: Keychain.user)
        let identity: ClaudeIdentity? = { if case .found = r { return identityReader() }; return nil }()
        var events: [(String?, String)] = []
        var newIdentity: ClaudeIdentity?
        lock.lock()
        _reads += 1
        HostLog.line("\(account): read the keychain item \(service) for \(subscribers.count) sandbox(es)")
        let before = _state, beforeToken = token?.accessToken
        switch r {
        case .found(let raw):
            if let t = ClaudeLogin.parse(raw) {
                warnedUnreadable = false
                if let id = identity {
                    _seen = id
                    if _pinned == nil { _pinned = id; newIdentity = id }
                }
                if let p = _pinned, let id = identity, !id.sameAccount(as: p) {
                    _state = .accountChanged
                    token = nil
                } else {
                    token = t
                    _state = (t.expiresAt.map { $0 <= now } ?? false) ? .expired : .ok
                }
            } else {
                if !warnedUnreadable { events.append((nil, "\(account): Claude Code's keychain item \(service) has a format doz doesn't know — keeping the last token")) }
                warnedUnreadable = true
                if token == nil { _state = .unreadable }
            }
        case .absent:
            token = nil
            _state = .signedOut
        case .locked, .failed:
            if !warnedUnreadable {
                events.append((nil, "\(account): could not read \(service) (\(r == .locked ? "the keychain is locked" : "security failed")) — keeping the last token"))
            }
            warnedUnreadable = true
            if token == nil { _state = .unreadable }
        }
        if _state != before || token?.accessToken != beforeToken {
            for (name, sb) in subscribers { apply(name, sb) }
            if _state != before, _state != .unknown {
                let text = describe(now: now)
                for name in subscribers.keys.sorted() { events.append((name, text)) }
            }
        }
        lock.unlock()
        if let newIdentity { onIdentity(newIdentity) }
        for (s, t) in events { onEvent(s, t) }
    }

    /// Under the lock.
    private func describe(now: Date) -> String {
        switch _state {
        case .ok: "\(account) login ok" + (token?.expiresAt.map { " (access expires \(CredentialVaultClock.hm($0)))" } ?? "")
        case .expired: "\(account) login expired at \(token?.expiresAt.map(CredentialVaultClock.hm) ?? "?") — it renews only while Claude Code runs on the Mac"
        case .signedOut: "\(account): Claude Code signed out on the Mac — the sandbox's token was cleared"
        case .accountChanged: "\(account): the Mac is now signed in as a different Claude account\(_seen.map { " (\($0.label))" } ?? "") — held; `doz account use NAME \(account)` follows it"
        case .unreadable: "\(account): the Mac login could not be read"
        case .unknown: ""
        }
    }

    /// Under the lock: what one subscriber's vault gets now.
    private func apply(_ name: String, _ sb: Sandbox) {
        let b = CredentialBinding.claudeOAuth
        switch _state {
        case .ok, .expired:
            guard let t = token else { return }
            sb.setCredential(b, secret: t.accessToken, expiresAt: t.expiresAt, environment: t.sessionEnvironment,
                             notice: "this Mac's Claude login expired at \(t.expiresAt.map(CredentialVaultClock.hm) ?? "?") — open Claude Code on the Mac "
                                     + "(any prompt), then retry: this session recovers without a restart")
        case .signedOut:
            sb.setCredential(b, secret: nil, expiresAt: nil, environment: [:],
                             notice: "this Mac's Claude Code signed out — sign in again with `claude` on the Mac, or pick another account: "
                                     + "doz account use \(name) ACCOUNT")
        case .accountChanged:
            sb.setCredential(b, secret: nil, expiresAt: nil, environment: [:],
                             notice: "the Mac is now signed in as a different Claude account\(_seen.map { " (\($0.label))" } ?? "") — "
                                     + "\(name) is held; to follow it: doz account use \(name) \(account)")
        case .unreadable, .unknown:
            if token == nil {
                sb.setCredential(b, secret: nil, expiresAt: nil, environment: [:],
                                 notice: "doz could not read this Mac's Claude login (\(service)) — doz doctor says why")
            }
        }
    }

    /// D3: the Mac's own `claude -p` once, when the access token is within `window` of expiry (or
    /// past it), a subscriber used it within `recentUse`, no Claude Code runs on the Mac, and it
    /// has not already run for this expiry. Off unless enabled.
    @discardableResult
    public func keepaliveIfDue(now: Date = Date()) -> Bool {
        lock.lock()
        guard let k = _keepalive, k.enabled, let t = token, let exp = t.expiresAt,
              _state == .ok || _state == .expired, exp.timeIntervalSince(now) <= k.window, lastKeepaliveFor != exp else {
            lock.unlock(); return false
        }
        let used = subscribers.values.contains { sb in
            sb.egress?.vault.lastUsed(CredentialBinding.claudeOAuth.id).map { now.timeIntervalSince($0) <= k.recentUse } ?? false
        }
        guard used else { lock.unlock(); return false }
        lastKeepaliveFor = exp
        lock.unlock()
        guard !k.isClaudeRunning() else {
            onEvent(nil, "\(account): keep-alive not needed — Claude Code is running on the Mac and renews its login itself")
            return false
        }
        guard let bin = k.binary() else {
            onEvent(nil, "\(account): keep-alive skipped — Claude Code isn't installed on this Mac")
            return false
        }
        onEvent(nil, "\(account): keep-alive — the login expires \(CredentialVaultClock.hm(exp)) and a sandbox is using it: running the Mac's Claude Code once")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-keepalive")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let code = k.runner.run(binary: bin, arguments: KeepaliveConfig.arguments, environment: Self.scrubbedEnvironment(configDir: configDir),
                                directory: dir, timeout: 120)
        readNow(now: Date())
        onEvent(nil, "\(account): keep-alive finished (exit \(code)); the login now \(state == .ok ? "is ok" + (expiresAt.map { " until \(CredentialVaultClock.hm($0))" } ?? "") : "is \(state.label)")")
        return true
    }

    /// PATH, HOME, USER, LANG, TMPDIR — never ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN (they
    /// would override the login this run exists to renew).
    public static func scrubbedEnvironment(configDir: String?, from env: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var out: [String: String] = [:]
        for k in ["PATH", "HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL"] { if let v = env[k] { out[k] = v } }
        if let d = configDir { out["CLAUDE_CONFIG_DIR"] = d }
        return out
    }
}

public enum CredentialVaultClock {
    public static func hm(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
