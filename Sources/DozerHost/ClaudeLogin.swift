import CryptoKit
import Darwin
import Foundation
import DozerKit

// 588 — the Mac's own Claude Code login, read-only, and the keychain doz uses for its own
// accounts. Every keychain access goes through `/usr/bin/security` (the tool Claude Code itself
// writes its items with, so no keychain dialog), and every secret written travels on that tool's
// STDIN (`security -i`), never in an argument a `ps` could show. Dozer never holds, reads for
// use, or writes Claude Code's refresh token, and never writes a `Claude Code-credentials*` item.

/// The outcome of one keychain read. `security` exits 44 for "no such item" and 36 when the
/// keychain is locked / interaction is not allowed; anything else (or a timeout) is `failed`.
public enum KeychainRead: Equatable, Sendable {
    case found(String)
    case absent
    case locked
    case failed

    public var value: String? { if case .found(let v) = self { return v }; return nil }
}

/// A keychain item's ATTRIBUTES (never its data).
public struct KeychainItemInfo: Equatable, Sendable, Codable {
    public var service: String
    public var account: String?
    public var modified: Date?
}

/// The keychain, as doz uses it (a fake in tests).
public protocol KeychainAccess: Sendable {
    func read(service: String, account: String?) -> KeychainRead
    /// Add or replace a generic password (the secret on the tool's stdin).
    func write(service: String, account: String, secret: String) throws
    func delete(service: String, account: String) throws
    /// Every generic-password item whose service starts with `prefix` — attributes only.
    func items(servicePrefix: String) -> [KeychainItemInfo]
}

/// The login keychain through `/usr/bin/security`.
public struct SystemKeychain: KeychainAccess {
    public var timeout: TimeInterval = 5
    public init() {}

    public func read(service: String, account: String?) -> KeychainRead {
        TestSafety.enforce(TestSafety.keychainViolation(service: service))   // 611
        var args = ["find-generic-password", "-s", service]
        if let account { args += ["-a", account] }
        args.append("-w")
        guard let r = Self.run(args, stdin: nil, timeout: timeout) else { return .failed }
        switch r.status {
        case 0:
            let s = String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? .absent : .found(s)
        case 44: return .absent
        case 36, 51: return .locked
        default: return .failed
        }
    }

    /// The secret goes on `security -i`'s STDIN as ONE command line (hex) — never an argument. `security -i`
    /// cuts input lines at ~4096 bytes (599i: a 4.2 KB ChatGPT sign-in was stored truncated, rc 1), so a
    /// secret longer than `Keychain.maximumSecretBytes` (or a line over `Keychain.maximumLineBytes`) is REFUSED
    /// before `security` runs. After writing, the item is read back: anything but the exact secret (a failed
    /// or partial write) deletes the item and throws — no partial item is ever left.
    public func write(service: String, account: String, secret: String) throws {
        TestSafety.enforce(TestSafety.keychainViolation(service: service))   // 611
        try Self.checkName(service); try Self.checkName(account)
        try Keychain.checkSecretSize(secret, service: service)
        let hex = Data(secret.utf8).map { String(format: "%02x", $0) }.joined()
        let line = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
        guard line.utf8.count <= Keychain.maximumLineBytes else {
            throw HostError(.invalid, "the keychain item \(service) would be too long for the keychain tool (\(line.utf8.count) bytes) — nothing written")
        }
        let r = Self.run(["-i"], stdin: Data(line.utf8), timeout: timeout)
        // (`find-generic-password -w` prints a non-ASCII secret as hex — either form is the secret whole.)
        let back = r?.status == 0 ? read(service: service, account: account).value : nil
        guard let back, back == secret.trimmingCharacters(in: .whitespacesAndNewlines) || back == hex else {
            try? delete(service: service, account: account)          // never a partial item
            throw HostError(.failed, "could not write the keychain item \(service) (is the login keychain unlocked?)")
        }
    }

    public func delete(service: String, account: String) throws {
        TestSafety.enforce(TestSafety.keychainViolation(service: service))   // 611
        try Self.checkName(service)
        guard let r = Self.run(["delete-generic-password", "-s", service, "-a", account], stdin: nil, timeout: timeout),
              r.status == 0 || r.status == 44 else {
            throw HostError(.failed, "could not delete the keychain item \(service)")
        }
    }

    public func items(servicePrefix: String) -> [KeychainItemInfo] {
        // dump-keychain WITHOUT -d: attributes only, never an item's data.
        guard let r = Self.run(["dump-keychain"], stdin: nil, timeout: 20), r.status == 0 else { return [] }
        return Self.parseDump(String(decoding: r.out, as: UTF8.self), servicePrefix: servicePrefix)
    }

    static func parseDump(_ text: String, servicePrefix: String) -> [KeychainItemInfo] {
        var out: [KeychainItemInfo] = []
        for block in text.components(separatedBy: "keychain: ").dropFirst() {
            guard block.contains("class: \"genp\"") else { continue }
            func attr(_ key: String) -> String? {
                guard let r = block.range(of: "\"\(key)\"<blob>=\"") else { return nil }
                let rest = block[r.upperBound...]
                guard let end = rest.firstIndex(of: "\"") else { return nil }
                return String(rest[..<end])
            }
            guard let svc = attr("svce"), svc.hasPrefix(servicePrefix) else { continue }
            var modified: Date?
            if let r = block.range(of: "\"mdat\"<timedate>=") , let q = block[r.upperBound...].range(of: "\"") {
                let s = block[q.upperBound...].prefix(15)       // 20260926205953Z
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
                f.dateFormat = "yyyyMMddHHmmss'Z'"
                modified = f.date(from: String(s))
            }
            if !out.contains(where: { $0.service == svc }) { out.append(KeychainItemInfo(service: svc, account: attr("acct"), modified: modified)) }
        }
        return out.sorted { $0.service < $1.service }
    }

    static func checkName(_ s: String) throws {
        guard !s.isEmpty, !s.contains("\""), !s.contains("\n"), !s.contains("\\") else {
            throw HostError(.invalid, "not a usable keychain name: \(s)")
        }
    }

    static func run(_ args: [String], stdin: Data?, timeout: TimeInterval) -> (status: Int32, out: Data)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
        do { try p.run() } catch { return nil }
        if let stdin {
            inp.fileHandleForWriting.write(stdin)
            try? inp.fileHandleForWriting.close()
        }
        // Collected on its own thread: `dump-keychain` can outgrow a pipe's buffer.
        let box = DataBox()
        let done = DispatchSemaphore(value: 0)
        let handle = out.fileHandleForReading
        DispatchQueue.global().async { box.data = handle.readDataToEndOfFile(); done.signal() }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return nil }
        _ = done.wait(timeout: .now() + 2)
        return (p.terminationStatus, box.data)
    }
}

final class DataBox: @unchecked Sendable { var data = Data() }

/// Reads a generic password the USER stored (`doz key set NAME --anthropic --keychain SERVICE`).
public enum Keychain {
    /// 599i: the most one keychain item may hold through `security -i` (hex doubles it; the tool cuts a line
    /// at ~4096 bytes). Larger secrets are refused (`checkSecretSize`) — or chunked (`KeychainChunks`).
    public static let maximumSecretBytes = 1800
    public static let maximumLineBytes = 4000

    public static func checkSecretSize(_ secret: String, service: String) throws {
        guard secret.utf8.count <= maximumSecretBytes else {
            throw HostError(.invalid, "the secret for the keychain item \(service) is \(secret.utf8.count) bytes — over the \(maximumSecretBytes) one item can hold; nothing written")
        }
    }

    public static func read(service: String, timeout: TimeInterval = 5) -> String? {
        var k = SystemKeychain()
        k.timeout = timeout
        return k.read(service: service, account: nil).value
    }

    /// The account attribute Claude Code (and doz) use: `$USER`.
    public static var user: String {
        let u = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        return u.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) == nil ? "claude-code-user" : u
    }
}

/// Who a Claude login belongs to — from Claude Code's own config (`oauthAccount`), read locally.
public struct ClaudeIdentity: Codable, Equatable, Sendable {
    public var accountUuid: String?
    public var organizationUuid: String?
    public var email: String?
    public var organizationName: String?

    public init(accountUuid: String?, organizationUuid: String?, email: String?, organizationName: String?) {
        self.accountUuid = accountUuid
        self.organizationUuid = organizationUuid
        self.email = email
        self.organizationName = organizationName
    }

    /// Two identities are the same account when their ids agree (an email can be renamed).
    public func sameAccount(as o: ClaudeIdentity) -> Bool {
        if let a = accountUuid, let b = o.accountUuid { return a == b && organizationUuid == o.organizationUuid }
        return email == o.email
    }

    public var label: String { [email, organizationName].compactMap { $0 }.joined(separator: " · ") }
}

/// The access token of a Claude Code login and what can be said about it — never the refresh token.
public struct ClaudeLoginToken: Sendable, Equatable {
    public var accessToken: String
    public var expiresAt: Date?
    public var refreshTokenExpiresAt: Date?
    public var subscriptionType: String?
    public var rateLimitTier: String?
    public var scopes: [String]

    /// The non-secret variables that let Claude Code in the guest show the plan and pick its
    /// default model (588, D1): it reads them beside CLAUDE_CODE_OAUTH_TOKEN.
    public var sessionEnvironment: [String: String] {
        var e: [String: String] = [:]
        if let s = subscriptionType, !s.isEmpty { e["CLAUDE_CODE_SUBSCRIPTION_TYPE"] = s }
        if let t = rateLimitTier, !t.isEmpty { e["CLAUDE_CODE_RATE_LIMIT_TIER"] = t }
        return e
    }
}

/// The Mac's own Claude Code login (`doz account use NAME mac`, alias `key set --claude-login`).
///
/// Claude Code keeps its subscription OAuth credentials in the login keychain, one item per config
/// directory, and renews the ACCESS token itself (it lives ~8 h; Claude Code refreshes it when a
/// `claude` process runs within 5 minutes of expiry). Dozer reads only the access token: its
/// refresh token has ONE writer, the Mac's Claude Code — a second holder would fork that token
/// family (the reason a copied `.credentials.json` was rejected in an earlier project).
public enum ClaudeLogin {
    public static let baseService = "Claude Code-credentials"
    /// Where Claude Code keeps a Console API key (not a subscription): never read by doz.
    public static let apiKeyService = "Claude Code"
    /// The legacy `CredentialRow.source` of `key set --claude-login`.
    public static let source = "claude-login"

    /// Claude Code's item name for a config directory: `Claude Code-credentials` for the default
    /// one, else `-` + the first 8 hex of sha256(NFC(dir)).
    public static func service(configDir: String?) -> String {
        guard let dir = configDir, !dir.isEmpty else { return baseService }
        let h = SHA256.hash(data: Data(dir.precomposedStringWithCanonicalMapping.utf8)).map { String(format: "%02x", $0) }.joined()
        return baseService + "-" + h.prefix(8)
    }

    /// Plain JSON or hex-encoded JSON (`security -w` prints hex for data it cannot print).
    public static func parse(_ raw: String) -> ClaudeLoginToken? {
        let data = Data(raw.utf8)
        let hex: Data? = {
            guard raw.count % 2 == 0 else { return nil }
            var d = Data(); var it = raw.makeIterator()
            while let a = it.next(), let b = it.next() { guard let v = UInt8(String([a, b]), radix: 16) else { return nil }; d.append(v) }
            return d
        }()
        for candidate in [data, hex].compactMap({ $0 }) {
            guard let obj = try? JSONSerialization.jsonObject(with: candidate) as? [String: Any],
                  let o = obj["claudeAiOauth"] as? [String: Any],
                  let t = o["accessToken"] as? String, !t.isEmpty else { continue }
            func date(_ k: String) -> Date? { (o[k] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
            return ClaudeLoginToken(accessToken: t, expiresAt: date("expiresAt"), refreshTokenExpiresAt: date("refreshTokenExpiresAt"),
                                    subscriptionType: o["subscriptionType"] as? String, rateLimitTier: o["rateLimitTier"] as? String,
                                    scopes: o["scopes"] as? [String] ?? [])
        }
        return nil
    }

    /// Claude Code's global config file for a config directory: `~/.claude.json` by default,
    /// `<dir>/.claude.json` for an explicit one.
    public static func configFile(configDir: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let d = configDir, !d.isEmpty { return URL(fileURLWithPath: (d as NSString).expandingTildeInPath).appendingPathComponent(".claude.json") }
        return home.appendingPathComponent(".claude.json")
    }

    /// Who the login belongs to (a local file read — no network, no secret).
    public static func identity(configDir: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ClaudeIdentity? {
        guard let d = try? Data(contentsOf: configFile(configDir: configDir, home: home)),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let o = obj["oauthAccount"] as? [String: Any] else { return nil }
        return ClaudeIdentity(accountUuid: o["accountUuid"] as? String, organizationUuid: o["organizationUuid"] as? String,
                              email: o["emailAddress"] as? String, organizationName: o["organizationName"] as? String)
    }

    /// Where `claude` is: the usual install places, then a login shell's PATH (the host process
    /// has a thin one). The same order as DeckKit's resolver.
    public static func resolveBinary(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                     environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let e = environment["CLAUDE_BINARY"], !e.isEmpty, FileManager.default.isExecutableFile(atPath: e) { return e }
        let candidates = ["\(home.path)/.local/bin/claude", "/usr/local/bin/claude", "/opt/homebrew/bin/claude", "\(home.path)/.claude/local/claude"]
        if let c = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return c }
        guard let r = run("/bin/sh", ["-lc", "command -v claude"], timeout: 5), r.status == 0 else { return nil }
        let p = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// `claude --version` → `2.1.283` (no side effects).
    public static func version(binary: String) -> String? {
        guard let r = run(binary, ["--version"], timeout: 10), r.status == 0 else { return nil }
        return r.out.split(separator: " ").first.map(String.init)
    }

    /// Is a Claude Code process running on this Mac (the only thing that renews its login)?
    public static func isClaudeRunning() -> Bool {
        guard let r = run("/usr/bin/pgrep", ["-f", "(^|/)claude( |$)|share/claude/versions/"], timeout: 5) else { return false }
        return r.status == 0
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, out: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["ANTHROPIC_API_KEY"] = nil
        env["CLAUDE_CODE_OAUTH_TOKEN"] = nil
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return nil }
        return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}

/// What `doctor` and `account use … mac` (alias `key set --claude-login`) find about a Mac login.
public struct ClaudeLoginStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// A subscription login is in the keychain.
        case signedIn = "signed-in"
        /// No login item; Claude Code keeps an API key instead.
        case apiKey = "api-key"
        case signedOut = "signed-out"
        case locked
        case unreadable
    }
    public var configDir: String?
    public var service: String
    public var binary: String?
    public var version: String?
    public var state: State
    public var subscriptionType: String?
    public var rateLimitTier: String?
    public var expiresAt: Date?
    public var refreshTokenExpiresAt: Date?
    public var identity: ClaudeIdentity?
    public var claudeRunning: Bool?

    public var installed: Bool { binary != nil }

    /// Gather it. `binary` and `version` are looked up only when `probeBinary`.
    public static func check(configDir: String? = nil, keychain: KeychainAccess, probeBinary: Bool = true,
                             home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             binary: (() -> String?)? = nil) -> ClaudeLoginStatus {
        let service = ClaudeLogin.service(configDir: configDir)
        let bin = probeBinary ? (binary ?? { ClaudeLogin.resolveBinary(home: home) })() : nil
        var s = ClaudeLoginStatus(configDir: configDir, service: service, binary: bin,
                                  version: probeBinary ? bin.flatMap(ClaudeLogin.version) : nil, state: .signedOut)
        switch keychain.read(service: service, account: Keychain.user) {
        case .found(let raw):
            guard let t = ClaudeLogin.parse(raw) else { s.state = .unreadable; return s }
            s.state = .signedIn
            s.subscriptionType = t.subscriptionType
            s.rateLimitTier = t.rateLimitTier
            s.expiresAt = t.expiresAt
            s.refreshTokenExpiresAt = t.refreshTokenExpiresAt
            s.identity = ClaudeLogin.identity(configDir: configDir, home: home)
        case .absent:
            if keychain.read(service: ClaudeLogin.apiKeyService, account: Keychain.user) != .absent, configDir == nil {
                s.state = .apiKey
            }
        case .locked: s.state = .locked
        case .failed: s.state = .unreadable
        }
        return s
    }

    /// Why this login cannot back a sandbox right now (nil: it can). The E1–E4 messages.
    public func problem(now: Date = Date()) -> HostError? {
        switch state {
        case .signedIn:
            if let e = expiresAt, e <= now {
                return HostError(.failed, "this Mac's Claude login expired \(Self.ago(e, now: now)) and renews only while Claude Code runs on this Mac — "
                                 + "open Claude Code on the Mac (any prompt), then retry")
            }
            return nil
        case .apiKey:
            return HostError(.failed, "this Mac's Claude Code uses an Anthropic API key, not a subscription — the Mac login needs a Claude "
                             + "subscription sign-in; for an API key use: doz account add NAME --api-key (or key set NAME --anthropic --keychain …)")
        case .signedOut:
            if !installed {
                return HostError(.notFound, "Claude Code isn't installed on this Mac — install it (https://claude.com/claude-code), run `claude`, "
                                 + "sign in, then retry; or use an API key: doz key set NAME --anthropic")
            }
            return HostError(.notFound, "Claude Code is installed\(version.map { " (\($0))" } ?? "") but not signed in on this Mac"
                             + (configDir.map { " for \($0)" } ?? "") + " — run `claude` and sign in with your Claude subscription")
        case .locked:
            return HostError(.failed, "the login keychain is locked — unlock it (log in to the Mac, or: security unlock-keychain), then retry")
        case .unreadable:
            return HostError(.failed, "Claude Code's keychain item \(service) has a format doz doesn't know — update doz, or sign in again with `claude`")
        }
    }

    /// `Claude Max (default_claude_max_20x) · you@… · access expires in 3 h 29 min`.
    public func summary(now: Date = Date()) -> String {
        var parts: [String] = []
        if let p = subscriptionType { parts.append("Claude \(p.capitalized)" + (rateLimitTier.map { " (\($0))" } ?? "")) }
        if let i = identity, !i.label.isEmpty { parts.append(i.label) }
        if let e = expiresAt {
            parts.append(e > now ? "access expires in \(Self.span(e.timeIntervalSince(now)))" : "access expired \(Self.ago(e, now: now))")
        }
        return parts.joined(separator: " · ")
    }

    static func span(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded())      // expiresAt is stored in ms: 7199.999 s reads as 2 h 0 min
        if m < 60 { return "\(max(m, 0)) min" }
        if m < 60 * 48 { return "\(m / 60) h \(m % 60) min" }
        return "\(m / 1440) days"
    }

    static func ago(_ d: Date, now: Date) -> String { "\(span(now.timeIntervalSince(d))) ago" }
}
