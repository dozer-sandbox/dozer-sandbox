import CryptoKit
import Darwin
import Foundation

/// A browser session: an opaque cookie value (HttpOnly — script never sees it) and a separate CSRF
/// token (returned in a JSON body, kept in page memory, sent as `X-Doz-CSRF` on every unsafe
/// request; never in a cookie or a URL).
public struct WebSession: Equatable, Sendable {
    public let cookieValue: String
    public let csrfToken: String
    public let expiresAt: Date
}

/// The UI's own authentication authority (from DeckStack 503's `DeckStackWebSessionStore`). Nothing
/// shared with a browser profile; one-use links live in memory only and die with the process.
///
/// 594 W19 (owner: "a new web page opening up every time i run doz ui"): the SESSIONS may outlive the
/// process, so a tab left open reconnects to the next `doz ui` without a new login. With `persist`,
/// they are kept in `<store>/ui.sessions` (0600) — and only for the same port (the cookie is named for
/// the port, so a page on another port never presents it anyway). Why this does not weaken the model:
///   · the file holds each cookie's SHA-256, never the cookie: reading it signs nobody in. (It holds
///     each session's CSRF token as is — the page reads it back after a reconnect — which is worth
///     nothing without the cookie.);
///   · it has the trust of the store itself — whoever reads `<store>` owns the sandboxes, their keys'
///     policies and the host's socket already; it lives in the user's own directory, 0600;
///   · every request still passes the exact Host and Origin checks on loopback, and every unsafe
///     request its CSRF token; sessions still expire (605, owner Q8 — "remember this browser": 14 days
///     without use, renewed by the page while it is open, so an installed app on this Mac stays signed
///     in), sign-out still revokes one, and `doz ui --new-link` / `doz ui link --rotate` revoke them all
///     (as a missing file or a new port does).
///
/// 605: a page that must sign in again is told WHY (the 401's code): `session-rotated` (a new link was
/// made), `session-expired`, `signed-out` (this browser signed out) — from `<store>/ui.revoked` (0600:
/// the SHA-256 of each ended cookie and the reason, kept 30 days; never a cookie) — else
/// `unauthenticated` (unknown here: another port, a lost file).

public actor WebSessionStore {
    private struct Stored: Codable { let csrf: String; var expiresAt: Date }
    private struct File: Codable { var port: Int; var sessions: [String: Stored] }
    /// 605: why a cookie no longer signs in (`ui.revoked`).
    struct Ended: Codable { var reason: String; var until: Date }
    private struct RevokedFile: Codable { var revoked: [String: Ended] }

    public static let rotated = "rotated", expired = "expired", signedOut = "signed-out"
    /// How long an ended cookie's reason is kept.
    static let reasonsKept: TimeInterval = 30 * 24 * 60 * 60

    private let lifetime: TimeInterval
    private let bootstrapLifetime: TimeInterval
    private let now: @Sendable () -> Date
    private let file: URL?
    private let revokedFile: URL?
    private let port: Int
    private var pending: [String: Date] = [:]
    private var consumed: [String: Date] = [:]
    /// By the SHA-256 of the cookie value.
    private var sessions: [String: Stored] = [:]
    /// 605: by the SHA-256 of an ended cookie.
    private var ended: [String: Ended] = [:]

    public init(bootstrap: WebBootstrapCapability, limits: WebLimits, now: @escaping @Sendable () -> Date = Date.init,
                persist: URL? = nil, port: Int = 0, revoked: URL? = nil) {
        lifetime = limits.sessionLifetime
        bootstrapLifetime = limits.bootstrapLifetime
        self.now = now
        file = persist
        revokedFile = revoked
        self.port = port
        pending[bootstrap.value] = now().addingTimeInterval(limits.bootstrapLifetime)
        let t = now()
        if let revoked, let d = try? Data(contentsOf: revoked), let r = try? Self.decoder.decode(RevokedFile.self, from: d) {
            ended = r.revoked.filter { $0.value.until > t }
        }
        if let persist, let d = try? Data(contentsOf: persist), let f = try? Self.decoder.decode(File.self, from: d), f.port == port {
            sessions = f.sessions.filter { $0.value.expiresAt > t }
            for (k, _) in f.sessions where f.sessions[k]!.expiresAt <= t { ended[k] = Ended(reason: Self.expired, until: t.addingTimeInterval(Self.reasonsKept)) }
            if sessions.count != f.sessions.count, let revoked {
                // The expired ones are reasons now.
                Self.write(try? Self.encoder.encode(RevokedFile(revoked: ended)), to: revoked)
            }
        }
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    static func digest(_ cookie: String) -> String {
        SHA256.hash(data: Data(cookie.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Write `data` to `url` (0600, atomically: a new file, then a rename) — or remove it when nil.
    static func write(_ data: Data?, to url: URL) {
        guard let data else { unlink(url.path); return }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid())")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        let ok = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) } == data.count
        close(fd)
        if ok { rename(tmp.path, url.path) } else { unlink(tmp.path) }
    }

    /// Write the sessions — or remove the file when none.
    private func save() {
        guard let file else { return }
        let live = sessions.filter { $0.value.expiresAt > now() }
        Self.write(live.isEmpty ? nil : try? Self.encoder.encode(File(port: port, sessions: live)), to: file)
    }

    private func saveRevoked() {
        guard let revokedFile else { return }
        let t = now()
        ended = ended.filter { $0.value.until > t }
        Self.write(ended.isEmpty ? nil : try? Self.encoder.encode(RevokedFile(revoked: ended)), to: revokedFile)
    }

    private func end(_ key: String, _ reason: String) {
        ended[key] = Ended(reason: reason, until: now().addingTimeInterval(Self.reasonsKept))
    }

    private func prune() {
        let t = now()
        pending = pending.filter { $0.value > t }
        consumed = consumed.filter { $0.value > t }
        var changed = false
        for (k, v) in sessions where v.expiresAt <= t.addingTimeInterval(-60) {
            sessions[k] = nil
            end(k, Self.expired)
            changed = true
        }
        if changed { saveRevoked() }
    }

    /// Exchange a capability ONCE for a session. A wrong capability does not consume the real one
    /// (a typo is not a denial of service); a used one says so.
    public func exchange(_ capability: String) throws -> WebSession {
        prune()
        guard let key = pending.keys.first(where: { constantTimeEqual(capability, $0) }) else {
            if consumed.keys.contains(where: { constantTimeEqual(capability, $0) }) { throw WebRejection.bootstrapUsed }
            throw WebRejection.bootstrapRejected
        }
        consumed[key] = pending.removeValue(forKey: key)
        let s = WebSession(cookieValue: WebRandom.token(), csrfToken: WebRandom.token(), expiresAt: now().addingTimeInterval(lifetime))
        sessions[Self.digest(s.cookieValue)] = Stored(csrf: s.csrfToken, expiresAt: s.expiresAt)
        save()
        return s
    }

    /// A new one-use link for this running server (`doz ui link`).
    public func issue() -> WebBootstrapCapability {
        prune()
        let c = WebBootstrapCapability.make()
        pending[c.value] = now().addingTimeInterval(bootstrapLifetime)
        return c
    }

    public func authenticate(_ cookie: String) throws -> WebSession {
        let key = Self.digest(cookie)
        guard let s = sessions[key] else {
            // 605: say why, when this store knows.
            switch ended[key]?.reason {
            case Self.rotated?: throw WebRejection.sessionRotated
            case Self.expired?: throw WebRejection.sessionExpired
            case Self.signedOut?: throw WebRejection.signedOut
            default: throw WebRejection.unauthenticated
            }
        }
        guard s.expiresAt > now() else {
            sessions[key] = nil
            end(key, Self.expired)
            saveRevoked()
            save()
            throw WebRejection.sessionExpired
        }
        return WebSession(cookieValue: cookie, csrfToken: s.csrf, expiresAt: s.expiresAt)
    }

    public func authenticateMutation(_ cookie: String, csrf: String?) throws -> WebSession {
        let s = try authenticate(cookie)
        guard let csrf, constantTimeEqual(csrf, s.csrfToken) else { throw WebRejection.csrfRejected }
        return s
    }

    /// Rolls a live session forward (the page calls it when it loads and at half-life; reads never
    /// extend it).
    public func renew(_ cookie: String) throws -> WebSession {
        let s = try authenticate(cookie)
        let e = now().addingTimeInterval(lifetime)
        sessions[Self.digest(cookie)]?.expiresAt = e
        save()
        return WebSession(cookieValue: cookie, csrfToken: s.csrfToken, expiresAt: e)
    }

    /// This browser signs out.
    public func revoke(_ cookie: String) {
        let key = Self.digest(cookie)
        if sessions.removeValue(forKey: key) != nil { end(key, Self.signedOut); saveRevoked() }
        save()
    }

    /// 594 W19: every session ends (`doz ui link --rotate`): each page must sign in with a new link.
    public func revokeAll() {
        for k in sessions.keys { end(k, Self.rotated) }
        sessions = [:]
        saveRevoked()
        save()
    }

    /// 605: `doz ui --new-link` when no UI runs: the kept sessions (any port) end as `rotated` — the
    /// file goes, their reasons stay — so a page that comes back is told a new link was made.
    public static func revokeKept(sessions file: URL, revoked: URL, now: Date = Date()) {
        defer { unlink(file.path) }
        guard let d = try? Data(contentsOf: file), let f = try? decoder.decode(File.self, from: d), !f.sessions.isEmpty else { return }
        var r = (try? Data(contentsOf: revoked)).flatMap { try? decoder.decode(RevokedFile.self, from: $0) }?.revoked ?? [:]
        r = r.filter { $0.value.until > now }
        for k in f.sessions.keys { r[k] = Ended(reason: rotated, until: now.addingTimeInterval(reasonsKept)) }
        write(try? encoder.encode(RevokedFile(revoked: r)), to: revoked)
    }

    public func isValid(_ cookie: String) -> Bool { (sessions[Self.digest(cookie)]?.expiresAt).map { $0 > now() } ?? false }

    public var liveSessionCount: Int { sessions.values.filter { $0.expiresAt > now() }.count }
}
