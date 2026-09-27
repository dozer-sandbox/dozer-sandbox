import Foundation

// 590 — the request checks of `snooze ui`, as pure functions over a small request view so every
// rule is a unit test (the HTTP adapter fills `WebRequestMetadata` before it decodes a body or
// dispatches a route). Copied from DeckStack 503's `DeckStackWebSecurity`, plus Fetch Metadata
// (`Sec-Fetch-Site`) as a second, independent cross-site refusal.

public enum WebHTTPMethod: String, Equatable, Sendable {
    case get = "GET", head = "HEAD", post = "POST", delete = "DELETE"
    var isSafe: Bool { self == .get || self == .head }
}

/// What the security layer sees of a request — nothing else.
public struct WebRequestMetadata: Equatable, Sendable {
    public var method: WebHTTPMethod
    public var host: String?
    public var origin: String?
    public var secFetchSite: String?
    public var authorization: String?
    public var cookie: String?
    public var csrfToken: String?
    public var contentType: String?
    public var bodyByteCount: Int

    public init(method: WebHTTPMethod, host: String?, origin: String? = nil, secFetchSite: String? = nil,
                authorization: String? = nil, cookie: String? = nil, csrfToken: String? = nil,
                contentType: String? = nil, bodyByteCount: Int = 0) {
        self.method = method
        self.host = host
        self.origin = origin
        self.secFetchSite = secFetchSite
        self.authorization = authorization
        self.cookie = cookie
        self.csrfToken = csrfToken
        self.contentType = contentType
        self.bodyByteCount = bodyByteCount
    }
}

/// Why a request was refused. The response carries only the code and a FIXED message — never a
/// value from the request (no Host, path or header is reflected).
public enum WebRejection: String, Error, Equatable, Sendable {
    case hostRejected = "host-rejected"
    case originRejected = "origin-rejected"
    case crossSite = "cross-site"
    case methodNotAllowed = "method-not-allowed"
    case bodyTooLarge = "body-too-large"
    case unsupportedMediaType = "unsupported-media-type"
    case malformedAuthorization = "bootstrap-malformed"
    case bootstrapRejected = "bootstrap-rejected"
    case bootstrapUsed = "bootstrap-used"
    case unauthenticated
    case sessionExpired = "session-expired"
    case csrfRejected = "csrf-rejected"
    case notFound = "not-found"
    case tooManyStreams = "too-many-streams"
    case tooManyConnections = "too-many-connections"
    case tooManyOperations = "too-many-operations"
    case alreadyRunning = "already-running"
    case unavailable

    public var status: Int {
        switch self {
        case .hostRejected, .originRejected, .crossSite, .csrfRejected: 403
        case .methodNotAllowed: 405
        case .alreadyRunning: 409
        case .bodyTooLarge: 413
        case .unsupportedMediaType: 415
        case .malformedAuthorization, .bootstrapRejected, .bootstrapUsed, .unauthenticated, .sessionExpired: 401
        case .notFound: 404
        case .tooManyStreams, .tooManyConnections, .tooManyOperations, .unavailable: 503
        }
    }

    public var message: String {
        switch self {
        case .hostRejected: "this server answers only to its own loopback address"
        case .originRejected: "cross-origin requests are refused"
        case .crossSite: "cross-site requests are refused"
        case .methodNotAllowed: "method not allowed"
        case .bodyTooLarge: "request body too large"
        case .unsupportedMediaType: "unsupported content type"
        case .malformedAuthorization: "no link capability was presented"
        case .bootstrapRejected: "this link is not valid for this server — run `snooze ui link` for a new one"
        case .bootstrapUsed: "this link was already used — each link works once; run `snooze ui link` for a new one"
        case .unauthenticated: "not signed in — open a link from `snooze ui link`"
        case .sessionExpired: "the session expired — run `snooze ui link` for a new link"
        case .csrfRejected: "missing or wrong CSRF token"
        case .notFound: "not found"
        case .tooManyStreams: "too many live-update streams are open"
        case .tooManyConnections: "too many connections"
        case .tooManyOperations: "too many operations are running — wait for one to finish"
        case .alreadyRunning: "that is already under way — see its progress in Operations"
        case .unavailable: "the snooze host did not answer"
        }
    }
}

public enum WebSecurity {
    public static let cookiePrefix = "snooze_ui_"
    public static let csrfHeader = "X-Snooze-CSRF"

    /// Port-scoped: two UIs (two stores) on 127.0.0.1 never overwrite each other's cookie (cookies
    /// are host-scoped, not port-scoped).
    public static func cookieName(_ origin: WebOrigin) -> String { cookiePrefix + String(origin.port) }

    /// The exact-listener checks every request passes first: the Host header (DNS rebinding), the
    /// Origin when present, and Fetch Metadata when present.
    static func checkListener(_ r: WebRequestMetadata, _ origin: WebOrigin, originRequired: Bool) throws {
        guard r.host == origin.authority else { throw WebRejection.hostRejected }
        if let o = r.origin {
            guard o == origin.value else { throw WebRejection.originRejected }
        } else if originRequired {
            throw WebRejection.originRejected
        }
        if let site = r.secFetchSite, site != "same-origin", site != "none" { throw WebRejection.crossSite }
    }

    static func checkBody(_ r: WebRequestMetadata, limit: Int) throws {
        guard r.bodyByteCount >= 0, r.bodyByteCount <= limit else { throw WebRejection.bodyTooLarge }
        if r.bodyByteCount > 0 {
            // Only JSON; a form post (the classic CSRF carrier) is not a type this server reads.
            guard let t = r.contentType?.lowercased(), t == "application/json" || t.hasPrefix("application/json;") else {
                throw WebRejection.unsupportedMediaType
            }
        }
    }

    /// `/` and the hashed assets: no session (the page must load to perform the bootstrap), GET or
    /// HEAD only, no body, exact Host.
    public static func validateStatic(_ r: WebRequestMetadata, _ origin: WebOrigin) throws {
        guard r.method.isSafe else { throw WebRejection.methodNotAllowed }
        guard r.bodyByteCount == 0 else { throw WebRejection.bodyTooLarge }
        try checkListener(r, origin, originRequired: false)
    }

    /// `POST /api/v1/session`: Origin REQUIRED and exact; the capability in `Authorization: Bearer`.
    /// Returns the presented capability.
    public static func validateBootstrap(_ r: WebRequestMetadata, _ origin: WebOrigin, limit: Int) throws -> String {
        guard r.method == .post else { throw WebRejection.methodNotAllowed }
        try checkListener(r, origin, originRequired: true)
        try checkBody(r, limit: limit)
        guard let a = r.authorization, a.hasPrefix("Bearer ") else { throw WebRejection.malformedAuthorization }
        let cap = String(a.dropFirst("Bearer ".count))
        guard WebRandom.isToken(cap) else { throw WebRejection.malformedAuthorization }
        return cap
    }

    /// Any authenticated route: exact Host; a safe method may omit Origin (browsers do on a
    /// same-origin GET), an unsafe one must carry it and the CSRF header. Returns the session cookie.
    public static func validateAuthenticated(_ r: WebRequestMetadata, _ origin: WebOrigin, limit: Int) throws -> String {
        try checkListener(r, origin, originRequired: !r.method.isSafe)
        try checkBody(r, limit: limit)
        if !r.method.isSafe, r.csrfToken == nil { throw WebRejection.csrfRejected }
        return try sessionCookie(r.cookie, name: cookieName(origin))
    }

    /// The one cookie of this name; a duplicate (cookie tossing) or malformed value is refused.
    public static func sessionCookie(_ header: String?, name: String) throws -> String {
        guard let header else { throw WebRejection.unauthenticated }
        let values = header.split(separator: ";", omittingEmptySubsequences: false).compactMap { part -> String? in
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard pair.hasPrefix(name + "=") else { return nil }
            return String(pair.dropFirst(name.count + 1))
        }
        guard values.count == 1, let v = values.first, WebRandom.isToken(v) else { throw WebRejection.unauthenticated }
        return v
    }

    public static func setCookie(_ value: String, name: String, maxAge: TimeInterval) -> String {
        "\(name)=\(value); Path=/; Max-Age=\(max(0, Int(maxAge))); HttpOnly; SameSite=Strict"
    }

    public static func clearCookie(name: String) -> String {
        "\(name)=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict"
    }

    /// On EVERY response, success or refusal. No `Access-Control-Allow-*` is ever added.
    public static let responseHeaders: [(String, String)] = [
        ("Content-Security-Policy", "default-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'; object-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; font-src 'self'; manifest-src 'none'"),
        ("X-Content-Type-Options", "nosniff"),
        ("X-Frame-Options", "DENY"),
        ("Referrer-Policy", "no-referrer"),
        ("Cross-Origin-Opener-Policy", "same-origin"),
        ("Cross-Origin-Resource-Policy", "same-origin"),
        ("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=(), clipboard-read=()"),
        ("Pragma", "no-cache"),
    ]
}
