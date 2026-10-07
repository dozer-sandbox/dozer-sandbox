import Foundation

// 590 — the request checks of `doz ui`, as pure functions over a small request view so every
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
    /// 606: `X-Doz-Probe` — `doz doctor`'s one-use token (doz serve's probe route only).
    public var probeToken: String?

    public init(method: WebHTTPMethod, host: String?, origin: String? = nil, secFetchSite: String? = nil,
                authorization: String? = nil, cookie: String? = nil, csrfToken: String? = nil,
                contentType: String? = nil, bodyByteCount: Int = 0, probeToken: String? = nil) {
        self.probeToken = probeToken
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
    /// 605: a new link was made (`doz ui --new-link`, `doz ui link --rotate`): every page signed out.
    case sessionRotated = "session-rotated"
    /// 605: this browser signed out.
    case signedOut = "signed-out"
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
    /// 594: `ui.allow_secret_entry = false` — no key or token is taken in the browser.
    case secretEntryOff = "secret-entry-off"
    /// 594: the Mac's folder picker is already open (one at a time).
    case pickerOpen = "picker-open"
    // 606 — doz serve (the other browsers of the LAN).
    /// No device cookie: this browser was never admitted (or its sign-in is unknown here).
    case notAdmitted = "not-admitted"
    /// This browser was removed from the devices.
    case deviceRevoked = "device-revoked"
    /// The link or code is not an open invite (wrong, expired, or its code was cancelled).
    case admissionRejected = "admission-rejected"
    /// The link or code was used already — each admits one browser.
    case admissionUsed = "admission-used"
    case tooManyAttempts = "too-many-attempts"
    case tooManyDevices = "too-many-devices"
    /// A key or token typed in a browser that reached doz serve over plain HTTP.
    case secretOverHTTP = "secret-over-http"
    /// Something that opens a window on the Mac's own screen (a picker, Terminal) asked from another computer.
    case macScreen = "mac-screen"
    /// `doz ui`'s Devices page needs a running doz serve for this.
    case serveNotRunning = "serve-not-running"
    /// 606: the connection reached an address doz serve does not serve (another VPN's tunnel) — said, never a silent drop.
    case notServedAddress = "not-served"

    public var status: Int {
        switch self {
        case .hostRejected, .originRejected, .crossSite, .csrfRejected, .terminalsOff, .secretEntryOff, .secretOverHTTP, .macScreen, .notServedAddress: 403
        case .methodNotAllowed: 405
        case .alreadyRunning, .pickerOpen, .serveNotRunning: 409
        case .tooManyAttempts: 429
        case .bodyTooLarge: 413
        case .unsupportedMediaType: 415
        case .malformedAuthorization, .bootstrapRejected, .bootstrapUsed, .unauthenticated, .sessionExpired, .sessionRotated, .signedOut: 401
        case .notAdmitted, .deviceRevoked, .admissionRejected, .admissionUsed: 401
        case .ticketMissing, .ticketRejected, .ticketUsed, .ticketExpired: 401
        case .upgradeRequired: 400
        case .notFound: 404
        case .tooManyStreams, .tooManyConnections, .tooManyOperations, .unavailable, .tooManyTickets, .tooManyTerminals, .tooManyDevices: 503
        }
    }

    public var message: String {
        switch self {
        case .hostRejected: "this server answers only to its own addresses — not to that name"
        case .originRejected: "cross-origin requests are refused"
        case .crossSite: "cross-site requests are refused"
        case .methodNotAllowed: "method not allowed"
        case .bodyTooLarge: "request body too large"
        case .unsupportedMediaType: "unsupported content type"
        case .malformedAuthorization: "no link capability was presented"
        case .bootstrapRejected: "this link is not valid for this server — run `doz ui link` for a new one"
        case .bootstrapUsed: "this link was already used — each link works once; run `doz ui link` for a new one"
        case .unauthenticated: "not signed in — open a link from `doz ui link`"
        case .sessionExpired: "this browser's sign-in expired (14 days unused) — run `doz ui link` for a new link"
        case .sessionRotated: "a new link was made for this dashboard, and every page was signed out — run `doz ui link` for a new link"
        case .signedOut: "this browser signed out — run `doz ui link` for a new link"
        case .csrfRejected: "missing or wrong CSRF token"
        case .notFound: "not found"
        case .tooManyStreams: "too many live-update streams are open"
        case .tooManyConnections: "too many connections"
        case .tooManyOperations: "too many operations are running — wait for one to finish"
        case .alreadyRunning: "that is already under way — see its progress in Operations"
        case .unavailable: "the doz host did not answer"
        case .ticketMissing: "a terminal needs a ticket — open it from the page"
        case .ticketRejected: "this terminal ticket is not valid here — open the terminal again"
        case .ticketUsed: "this terminal ticket was already used — each works once; open the terminal again"
        case .ticketExpired: "this terminal ticket expired — open the terminal again"
        case .tooManyTickets: "too many terminal tickets are waiting — close some terminals"
        case .tooManyTerminals: "too many terminals are open — close one first"
        case .upgradeRequired: "the terminal socket is a WebSocket, opened as the first request of a connection"
        case .terminalsOff: "browser terminals are off (Settings: ui.terminals) — Open in Terminal still works"
        case .secretEntryOff: "keys and tokens are not taken in the browser (ui.allow_secret_entry = false) — in a terminal: doz account add NAME --api-key|--setup-token, or doz key set SANDBOX --anthropic"
        case .pickerOpen: "the folder picker is already open on this Mac — choose there, or cancel it"
        case .notAdmitted: "this browser is not admitted to Dozer on this Mac — open a link or type a code from Add another browser (on a browser that is signed in) or from doz serve share (on the Mac)"
        case .deviceRevoked: "this browser was removed from Dozer's devices — to come back, open a new link or type a new code (Add another browser on a signed-in browser, or doz serve share on the Mac)"
        case .admissionRejected: "that link or code is not valid (or it expired after five minutes) — make a new one: Add another browser on a signed-in browser, or doz serve share on the Mac"
        case .admissionUsed: "that link or code was already used — each one admits one browser; make a new one: Add another browser, or doz serve share"
        case .tooManyAttempts: "too many wrong codes from this address — wait ten minutes, or open a link instead"
        case .tooManyDevices: "this doz serve has as many browsers as it keeps — remove one in Devices (or doz serve revoke) first"
        case .secretOverHTTP: "a key or token is never typed here over plain HTTP — the network between this browser and the Mac could read it. Add it on the Mac (doz account add NAME --api-key|--setup-token, or the Mac's own doz ui), or reach this dashboard over HTTPS through your reverse proxy (serve.public_origins)"
        case .macScreen: "that opens a window on the Mac's own screen — from another computer, type the path instead (or use a browser terminal)"
        case .serveNotRunning: "doz serve is not running for this store — start it in a terminal: doz serve"
        case .notServedAddress: "doz serve does not answer on this network address — open it at http://<this Mac>.local or one of the addresses doz serve prints (serve.bind decides where it listens)"
        }
    }
}

/// 606: the listener as ONE request sees it — its own origin (nil: its Host is not one this server answers
/// to, refused first) and its session cookie's name. `doz ui`: exactly `http://127.0.0.1:<port>` (590);
/// `doz serve`: `WebServeRules.requestOrigin`.
public struct WebRequestView: Equatable, Sendable {
    public var ownOrigin: String?
    public var cookieName: String
    /// What a request without that cookie is told (`doz serve`: not admitted).
    public var missingCookie: WebRejection

    public init(ownOrigin: String?, cookieName: String, missingCookie: WebRejection = .unauthenticated) {
        self.ownOrigin = ownOrigin
        self.cookieName = cookieName
        self.missingCookie = missingCookie
    }

    /// 590's rule: the exact Host `127.0.0.1:<port>`, the exact origin.
    public static func loopback(_ r: WebRequestMetadata, _ origin: WebOrigin) -> WebRequestView {
        WebRequestView(ownOrigin: r.host == origin.authority ? origin.value : nil, cookieName: WebSecurity.cookieName(origin))
    }
}

public enum WebSecurity {
    public static let cookiePrefix = "doz_ui_"
    public static let csrfHeader = "X-Doz-CSRF"

    /// Port-scoped: two UIs (two stores) on 127.0.0.1 never overwrite each other's cookie (cookies
    /// are host-scoped, not port-scoped).
    public static func cookieName(_ origin: WebOrigin) -> String { cookiePrefix + String(origin.port) }

    /// The exact-listener checks every request passes first: the Host header (DNS rebinding), the
    /// Origin when present, and Fetch Metadata when present.
    static func checkListener(_ r: WebRequestMetadata, _ origin: WebOrigin, originRequired: Bool) throws {
        try checkListener(r, .loopback(r, origin), originRequired: originRequired)
    }

    /// 606: the same checks against the request's OWN origin (`WebRequestView`): nil = its Host is not one
    /// this server answers to; an Origin, when present, must EQUAL it (a page loaded through one name never
    /// drives the API through another); Fetch Metadata same-origin or none.
    static func checkListener(_ r: WebRequestMetadata, _ view: WebRequestView, originRequired: Bool) throws {
        guard let own = view.ownOrigin else { throw WebRejection.hostRejected }
        if let o = r.origin {
            guard o == own else { throw WebRejection.originRejected }
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
        try validateStatic(r, .loopback(r, origin))
    }

    public static func validateStatic(_ r: WebRequestMetadata, _ view: WebRequestView) throws {
        guard r.method.isSafe else { throw WebRejection.methodNotAllowed }
        guard r.bodyByteCount == 0 else { throw WebRejection.bodyTooLarge }
        try checkListener(r, view, originRequired: false)
    }

    /// `POST /api/v1/session`: Origin REQUIRED and exact; the capability in `Authorization: Bearer`.
    /// Returns the presented capability.
    public static func validateBootstrap(_ r: WebRequestMetadata, _ origin: WebOrigin, limit: Int) throws -> String {
        try validateBootstrap(r, .loopback(r, origin), limit: limit)
    }

    public static func validateBootstrap(_ r: WebRequestMetadata, _ view: WebRequestView, limit: Int) throws -> String {
        guard r.method == .post else { throw WebRejection.methodNotAllowed }
        try checkListener(r, view, originRequired: true)
        try checkBody(r, limit: limit)
        guard let a = r.authorization, a.hasPrefix("Bearer ") else { throw WebRejection.malformedAuthorization }
        let cap = String(a.dropFirst("Bearer ".count))
        guard WebRandom.isToken(cap) else { throw WebRejection.malformedAuthorization }
        return cap
    }

    /// Any authenticated route: exact Host; a safe method may omit Origin (browsers do on a
    /// same-origin GET), an unsafe one must carry it and the CSRF header. Returns the session cookie.
    public static func validateAuthenticated(_ r: WebRequestMetadata, _ origin: WebOrigin, limit: Int) throws -> String {
        try validateAuthenticated(r, .loopback(r, origin), limit: limit)
    }

    public static func validateAuthenticated(_ r: WebRequestMetadata, _ view: WebRequestView, limit: Int) throws -> String {
        try checkListener(r, view, originRequired: !r.method.isSafe)
        try checkBody(r, limit: limit)
        if !r.method.isSafe, r.csrfToken == nil { throw WebRejection.csrfRejected }
        return try sessionCookie(r.cookie, name: view.cookieName, missing: view.missingCookie)
    }

    /// 591 — the subprotocol the terminal socket speaks, and the prefix that carries its ticket. The
    /// ticket rides in `Sec-WebSocket-Protocol` so it is never in a URL (history, a Referer, a log);
    /// the answer echoes only `terminalProtocol`.
    public static let terminalProtocol = "doz-terminal.v1"
    public static let ticketProtocolPrefix = "doz-ticket."

    /// 591 — the terminal socket's upgrade (`GET …/terminal-socket` + `Upgrade: websocket`). Exact
    /// Host; Origin REQUIRED and exact (a WebSocket carries no CSRF header, so the Origin and the
    /// one-use ticket are the cross-site wall); Fetch Metadata; the one cookie of this port; and
    /// exactly one ticket among the offered subprotocols, next to `terminalProtocol`. Returns the
    /// cookie and the presented ticket (the caller consumes it against the cookie's session).
    public static func validateTerminalUpgrade(_ r: WebRequestMetadata, _ origin: WebOrigin, subprotocols: [String]) throws -> (cookie: String, ticket: String) {
        try validateTerminalUpgrade(r, .loopback(r, origin), subprotocols: subprotocols)
    }

    public static func validateTerminalUpgrade(_ r: WebRequestMetadata, _ view: WebRequestView, subprotocols: [String]) throws -> (cookie: String, ticket: String) {
        guard r.method == .get else { throw WebRejection.methodNotAllowed }
        try checkListener(r, view, originRequired: true)
        guard r.bodyByteCount == 0 else { throw WebRejection.bodyTooLarge }
        let cookie = try sessionCookie(r.cookie, name: view.cookieName, missing: view.missingCookie)
        let offered = subprotocols.flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }
        let tickets = offered.filter { $0.hasPrefix(ticketProtocolPrefix) }.map { String($0.dropFirst(ticketProtocolPrefix.count)) }
        guard offered.contains(terminalProtocol), tickets.count == 1, let t = tickets.first, WebRandom.isToken(t) else {
            throw WebRejection.ticketMissing
        }
        return (cookie, t)
    }

    /// The one cookie of this name; a duplicate (cookie tossing) or malformed value is refused.
    public static func sessionCookie(_ header: String?, name: String, missing: WebRejection = .unauthenticated) throws -> String {
        guard let header else { throw missing }
        let values = header.split(separator: ";", omittingEmptySubsequences: false).compactMap { part -> String? in
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard pair.hasPrefix(name + "=") else { return nil }
            return String(pair.dropFirst(name.count + 1))
        }
        guard values.count == 1, let v = values.first, WebRandom.isToken(v) else { throw missing }
        return v
    }

    /// 606: `secure` (a device's cookie over https) adds `Secure` — required by its `__Host-` name.
    public static func setCookie(_ value: String, name: String, maxAge: TimeInterval, secure: Bool = false) -> String {
        "\(name)=\(value); Path=/; Max-Age=\(max(0, Int(maxAge))); HttpOnly; SameSite=Strict" + (secure ? "; Secure" : "")
    }

    public static func clearCookie(name: String, secure: Bool = false) -> String {
        "\(name)=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict" + (secure ? "; Secure" : "")
    }

    /// On EVERY response, success or refusal. No `Access-Control-Allow-*` is ever added.
    /// 591: the page may frame ITS OWN terminal frame (`frame-src 'self'`) — the one token the
    /// terminals added to the page. `connect-src 'self'` covers the terminal WebSocket
    /// (`ws://127.0.0.1:<port>`, CSP3). The engine runs only in the frame, under `frameCSP`.
    /// 605: the page links its web app manifest (`manifest-src 'self'`) and registers its service worker
    /// (`worker-src 'self'` — `default-src 'none'` would forbid it); nothing else changed.
    public static let responseHeaders: [(String, String)] = [
        ("Content-Security-Policy", "default-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'; object-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; font-src 'self'; frame-src 'self'; manifest-src 'self'; worker-src 'self'"),
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

    /// 605 — the service worker script's own policy (a worker's CSP is its script's response header): it
    /// fetches only this origin (a navigation of `/`, its precache list) and loads nothing.
    public static let serviceWorkerHeaders: [(String, String)] = [
        ("Content-Security-Policy", "default-src 'none'; connect-src 'self'"),
    ]

    /// 591 — the frame's own script and style and the engine's script are loaded by an opaque origin.
    public static let frameAssetHeaders: [(String, String)] = [("Cross-Origin-Resource-Policy", "cross-origin")]
}
