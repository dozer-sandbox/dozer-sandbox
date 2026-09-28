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
    // 591 — the terminal socket.
    case ticketMissing = "ticket-missing"
    case ticketRejected = "ticket-rejected"
    case ticketUsed = "ticket-used"
    case ticketExpired = "ticket-expired"
    case tooManyTickets = "too-many-tickets"
    case tooManyTerminals = "too-many-terminals"
    case upgradeRequired = "upgrade-required"
    /// 591 settings: `ui.terminals = false`.
    case terminalsOff = "terminals-off"

    public var status: Int {
        switch self {
        case .hostRejected, .originRejected, .crossSite, .csrfRejected, .terminalsOff: 403
        case .methodNotAllowed: 405
        case .alreadyRunning: 409
        case .bodyTooLarge: 413
        case .unsupportedMediaType: 415
        case .malformedAuthorization, .bootstrapRejected, .bootstrapUsed, .unauthenticated, .sessionExpired: 401
        case .ticketMissing, .ticketRejected, .ticketUsed, .ticketExpired: 401
        case .upgradeRequired: 400
        case .notFound: 404
        case .tooManyStreams, .tooManyConnections, .tooManyOperations, .unavailable, .tooManyTickets, .tooManyTerminals: 503
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
        case .ticketMissing: "a terminal needs a ticket — open it from the page"
        case .ticketRejected: "this terminal ticket is not valid here — open the terminal again"
        case .ticketUsed: "this terminal ticket was already used — each works once; open the terminal again"
        case .ticketExpired: "this terminal ticket expired — open the terminal again"
        case .tooManyTickets: "too many terminal tickets are waiting — close some terminals"
        case .tooManyTerminals: "too many terminals are open — close one first"
        case .upgradeRequired: "the terminal socket is a WebSocket, opened as the first request of a connection"
        case .terminalsOff: "browser terminals are off (Settings: ui.terminals) — Open in Terminal still works"
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

    /// 591 — the subprotocol the terminal socket speaks, and the prefix that carries its ticket. The
    /// ticket rides in `Sec-WebSocket-Protocol` so it is never in a URL (history, a Referer, a log);
    /// the answer echoes only `terminalProtocol`.
    public static let terminalProtocol = "snooze-terminal.v1"
    public static let ticketProtocolPrefix = "snooze-ticket."

    /// 591 — the terminal socket's upgrade (`GET …/terminal-socket` + `Upgrade: websocket`). Exact
    /// Host; Origin REQUIRED and exact (a WebSocket carries no CSRF header, so the Origin and the
    /// one-use ticket are the cross-site wall); Fetch Metadata; the one cookie of this port; and
    /// exactly one ticket among the offered subprotocols, next to `terminalProtocol`. Returns the
    /// cookie and the presented ticket (the caller consumes it against the cookie's session).
    public static func validateTerminalUpgrade(_ r: WebRequestMetadata, _ origin: WebOrigin, subprotocols: [String]) throws -> (cookie: String, ticket: String) {
        guard r.method == .get else { throw WebRejection.methodNotAllowed }
        try checkListener(r, origin, originRequired: true)
        guard r.bodyByteCount == 0 else { throw WebRejection.bodyTooLarge }
        let cookie = try sessionCookie(r.cookie, name: cookieName(origin))
        let offered = subprotocols.flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }
        let tickets = offered.filter { $0.hasPrefix(ticketProtocolPrefix) }.map { String($0.dropFirst(ticketProtocolPrefix.count)) }
        guard offered.contains(terminalProtocol), tickets.count == 1, let t = tickets.first, WebRandom.isToken(t) else {
            throw WebRejection.ticketMissing
        }
        return (cookie, t)
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
    /// 591: the page may frame ITS OWN terminal frame (`frame-src 'self'`) — the one token the
    /// terminals added to the page. `connect-src 'self'` covers the terminal WebSocket
    /// (`ws://127.0.0.1:<port>`, CSP3). The engine runs only in the frame, under `frameCSP`.
    public static let responseHeaders: [(String, String)] = [
        ("Content-Security-Policy", "default-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'; object-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; font-src 'self'; frame-src 'self'; manifest-src 'none'"),
        ("X-Content-Type-Options", "nosniff"),
        ("X-Frame-Options", "DENY"),
        ("Referrer-Policy", "no-referrer"),
        ("Cross-Origin-Opener-Policy", "same-origin"),
        ("Cross-Origin-Resource-Policy", "same-origin"),
        ("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=(), clipboard-read=()"),
        ("Pragma", "no-cache"),
    ]

    /// 591 (owner ruling T2) — the terminal frame's document: loaded only into the page's sandboxed
    /// (`allow-scripts` only → an opaque origin: no cookie, no storage, no same-origin access) iframe.
    /// The engine may compile WebAssembly (`'wasm-unsafe-eval'`, never `'unsafe-eval'`), and it can
    /// connect to NOTHING (`connect-src 'none'`: the page hands it the WASM bytes and the terminal's
    /// bytes by postMessage). Framed only by this origin.
    public static let frameHeaders: [(String, String)] = [
        ("Content-Security-Policy", "default-src 'none'; base-uri 'none'; frame-ancestors 'self'; form-action 'none'; object-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; connect-src 'none'; img-src 'none'; font-src 'none'; frame-src 'none'; manifest-src 'none'"),
        ("X-Frame-Options", "SAMEORIGIN"),
    ]

    /// 591 — the frame's own script and style and the engine's script are loaded by an opaque origin.
    public static let frameAssetHeaders: [(String, String)] = [("Cross-Origin-Resource-Policy", "cross-origin")]
}
