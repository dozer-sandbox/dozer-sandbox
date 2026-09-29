import Foundation

/// A browser session: an opaque cookie value (HttpOnly — script never sees it) and a separate CSRF
/// token (returned in a JSON body, kept in page memory, sent as `X-Doz-CSRF` on every unsafe
/// request; never in a cookie or a URL).
public struct WebSession: Equatable, Sendable {
    public let cookieValue: String
    public let csrfToken: String
    public let expiresAt: Date
}

/// The UI's own authentication authority (from DeckStack 503's `DeckStackWebSessionStore`): memory
/// only — no login on disk, nothing shared with a browser profile. Ending the process revokes every
/// session and every link.
public actor WebSessionStore {
    private struct Stored { let csrf: String; var expiresAt: Date }

    private let lifetime: TimeInterval
    private let bootstrapLifetime: TimeInterval
    private let now: @Sendable () -> Date
    private var pending: [String: Date] = [:]
    private var consumed: [String: Date] = [:]
    private var sessions: [String: Stored] = [:]

    public init(bootstrap: WebBootstrapCapability, limits: WebLimits, now: @escaping @Sendable () -> Date = Date.init) {
        lifetime = limits.sessionLifetime
        bootstrapLifetime = limits.bootstrapLifetime
        self.now = now
        pending[bootstrap.value] = now().addingTimeInterval(limits.bootstrapLifetime)
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
        sessions[s.cookieValue] = Stored(csrf: s.csrfToken, expiresAt: s.expiresAt)
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
        guard let s = sessions[cookie] else { throw WebRejection.unauthenticated }
        guard s.expiresAt > now() else {
            sessions[cookie] = nil
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
        sessions[cookie]?.expiresAt = e
        return WebSession(cookieValue: cookie, csrfToken: s.csrfToken, expiresAt: e)
    }

    public func revoke(_ cookie: String) { sessions[cookie] = nil }

    public func isValid(_ cookie: String) -> Bool { (sessions[cookie]?.expiresAt).map { $0 > now() } ?? false }

    public var liveSessionCount: Int { sessions.values.filter { $0.expiresAt > now() }.count }
}
