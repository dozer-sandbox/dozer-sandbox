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
///     request its CSRF token; sessions still expire (12 h, renewed only by the page), sign-out still
///     revokes one, and `doz ui --new-link` / `doz ui link --rotate` revoke them all (as a missing
///     file or a new port does).
public actor WebSessionStore {
    private struct Stored: Codable { let csrf: String; var expiresAt: Date }
    private struct File: Codable { var port: Int; var sessions: [String: Stored] }

    private let lifetime: TimeInterval
    private let bootstrapLifetime: TimeInterval
    private let now: @Sendable () -> Date
    private let file: URL?
    private let port: Int
    private var pending: [String: Date] = [:]
    private var consumed: [String: Date] = [:]
    /// By the SHA-256 of the cookie value.
    private var sessions: [String: Stored] = [:]

    public init(bootstrap: WebBootstrapCapability, limits: WebLimits, now: @escaping @Sendable () -> Date = Date.init,
                persist: URL? = nil, port: Int = 0) {
        lifetime = limits.sessionLifetime
        bootstrapLifetime = limits.bootstrapLifetime
        self.now = now
        file = persist
        self.port = port
        pending[bootstrap.value] = now().addingTimeInterval(limits.bootstrapLifetime)
        if let persist, let d = try? Data(contentsOf: persist), let f = try? Self.decoder.decode(File.self, from: d), f.port == port {
            let t = now()
            sessions = f.sessions.filter { $0.value.expiresAt > t }
        }
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    static func digest(_ cookie: String) -> String {
        SHA256.hash(data: Data(cookie.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Write the sessions (0600, atomically: a new file, then a rename) — or remove the file when none.
    private func save() {
        guard let file else { return }
        let live = sessions.filter { $0.value.expiresAt > now() }
        if live.isEmpty { unlink(file.path); return }
        guard let d = try? Self.encoder.encode(File(port: port, sessions: live)) else { return }
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).\(getpid())")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        let ok = d.withUnsafeBytes { write(fd, $0.baseAddress, d.count) } == d.count
        close(fd)
        if ok { rename(tmp.path, file.path) } else { unlink(tmp.path) }
    }

    private func prune() {
        let t = now()
        pending = pending.filter { $0.value > t }
        consumed = consumed.filter { $0.value > t }
        sessions = sessions.filter { $0.value.expiresAt > t.addingTimeInterval(-60) }
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
        guard let s = sessions[key] else { throw WebRejection.unauthenticated }
        guard s.expiresAt > now() else {
            sessions[key] = nil
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

    /// Rolls a live session forward (the page calls it at half-life; reads never extend it).
    public func renew(_ cookie: String) throws -> WebSession {
        let s = try authenticate(cookie)
        let e = now().addingTimeInterval(lifetime)
        sessions[Self.digest(cookie)]?.expiresAt = e
        save()
        return WebSession(cookieValue: cookie, csrfToken: s.csrfToken, expiresAt: e)
    }

    public func revoke(_ cookie: String) {
        sessions[Self.digest(cookie)] = nil
        save()
    }

    /// 594 W19: every session ends (`doz ui link --rotate`): each page must sign in with a new link.
    public func revokeAll() {
        sessions = [:]
        save()
    }

    public func isValid(_ cookie: String) -> Bool { (sessions[Self.digest(cookie)]?.expiresAt).map { $0 > now() } ?? false }

    public var liveSessionCount: Int { sessions.values.filter { $0.expiresAt > now() }.count }
}
