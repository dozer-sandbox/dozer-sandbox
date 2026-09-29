import Foundation

/// The CLOSED route table (590). Every route is a case; a path that does not parse to one is a 404
/// before any session is looked at or any host call is made. Identifiers are allowlisted here (a
/// sandbox name is the library's own rule: 1–40 of [a-z0-9-], not starting with `-`), so no
/// request text reaches the host that the host would not accept from the CLI.
///
/// The unsafe routes are the session's own (bootstrap, renew, sign out) and, since phase 2, the
/// typed actions (`WebAction`: a closed enum, each exactly one `HostOp`), the policy preview and
/// Terminal.app. There is deliberately no generic command, exec, file-read, URL-open, proxy or PTY
/// route — and none may be added: a new capability is a new TYPED case. 591's terminal socket is
/// not a PTY route: it ATTACHES to a session the host already holds (the CLI's `attach`), only with
/// a one-use ticket minted by a CSRF-checked POST, and a new session is still the typed
/// `open-session` action.
public enum WebRoute: Equatable, Sendable {
    // static
    case index
    case asset(String)
    /// 591: GET /terminal-frame — the terminal engine's document, loaded only into a sandboxed,
    /// opaque-origin iframe of the page (its own CSP; `frame-ancestors 'self'`).
    case terminalFrame
    // session
    case sessionBootstrap          // POST   /api/v1/session   (Authorization: Bearer <capability>)
    case sessionInfo               // GET    /api/v1/session
    case sessionRenew              // POST   /api/v1/session/renew
    case sessionEnd                // DELETE /api/v1/session
    // read-only views
    case overview                  // GET /api/v1/overview
    case sandbox(String)           // GET /api/v1/sandboxes/{name}
    case sandboxSessions(String)   // GET /api/v1/sandboxes/{name}/sessions
    case sandboxNetwork(String)    // GET /api/v1/sandboxes/{name}/network
    case images                    // GET /api/v1/images
    case imageTree                 // GET /api/v1/images/tree   (593: the lineage, with sizes)
    case accounts                  // GET /api/v1/accounts
    case metrics(WebMetricsQuery)  // GET /api/v1/metrics?image=&days=&steps=
    case metricsCSV(WebMetricsQuery) // GET /api/v1/metrics.csv?…  (a download)
    case events                    // GET /api/v1/events
    case doctor                    // GET /api/v1/doctor
    case stream                    // GET /api/v1/stream   (server-sent events)
    // phase 2 — actions (every one: exact Origin + X-Doz-CSRF + a JSON body)
    case actions                   // POST /api/v1/actions   ({"action": <closed enum>, …} → one HostOp)
    case operations                // GET  /api/v1/operations (the UI's recent operations)
    case policyPreview(String)     // POST /api/v1/sandboxes/{name}/network/preview (changes nothing)
    case terminal(String)          // POST /api/v1/sandboxes/{name}/terminal (Terminal.app, fixed script)
    // 591 — browser terminals (591.01-DESIGN.md §4): a one-use ticket, then the socket it opens.
    case terminalTicket(String)    // POST /api/v1/sandboxes/{name}/terminal-ticket (CSRF; {mode, session?, cols?, rows?})
    case terminalSocket(String)    // GET  /api/v1/sandboxes/{name}/terminal-socket (WebSocket upgrade + the ticket)
    // 591 settings — doz.toml: the report, and ONE typed change (closed schema, CSRF).
    case settings                  // GET  /api/v1/settings
    case settingsChange            // POST /api/v1/settings  ({key, value} | {key, reset: true})
    // 594 — onboarding: the wizard's facts; the settings file + prompt template written only when
    // missing (CSRF, strict {defaultImage, account}); the host's image preparations.
    case onboarding                // GET  /api/v1/onboarding
    case onboardingConfig          // POST /api/v1/onboarding/config
    case preparations              // GET  /api/v1/preparations
    // 594 (owner ruling) — an account from a key or a setup token typed in a masked field. NOT an
    // action: an action is an operation (a title, progress, an outcome on every page); this is one
    // synchronous request whose body alone carries the secret, allowed while ui.allow_secret_entry.
    case accountAdd                // POST /api/v1/accounts  ({name, kind, secret, plan?})

    public var isStatic: Bool {
        switch self { case .index, .asset, .terminalFrame: true; default: false }
    }

    /// Parse a request target. Only the metrics routes read a query string (three keys, each by its
    /// rule — anything else there is not a route); the others ignore it. Anything unusual in the
    /// path — percent-encoding, dot segments, a trailing slash, a double slash — is not a route.
    public static func parse(method: WebHTTPMethod, target: String) -> WebRoute? {
        var path = target
        var query: String?
        if let q = path.firstIndex(of: "?") {
            query = String(path[path.index(after: q)...])
            path = String(path[..<q])
        }
        guard path.hasPrefix("/"), !path.contains("%"), !path.contains("//"), path.count <= 256 else { return nil }
        if path == "/" { return method.isSafe ? .index : nil }
        if path == WebAssets.frameDocument { return method.isSafe ? .terminalFrame : nil }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        if parts.count == 2, parts[0] == "assets" { return method.isSafe ? .asset(path) : nil }
        guard parts.count >= 3, parts[0] == "api", parts[1] == "v1" else { return nil }
        let rest = Array(parts.dropFirst(2))
        switch (method, rest.count) {
        case (.post, 1) where rest[0] == "session": return .sessionBootstrap
        case (.get, 1) where rest[0] == "session": return .sessionInfo
        case (.delete, 1) where rest[0] == "session": return .sessionEnd
        case (.post, 2) where rest == ["session", "renew"]: return .sessionRenew
        case (.post, 1) where rest[0] == "actions": return .actions
        case (.post, 1) where rest[0] == "settings": return .settingsChange
        case (.post, 2) where rest == ["onboarding", "config"]: return .onboardingConfig
        case (.post, 1) where rest[0] == "accounts": return .accountAdd
        case (.post, 4) where rest[0] == "sandboxes" && isSandboxName(rest[1]) && rest[2] == "network" && rest[3] == "preview":
            return .policyPreview(rest[1])
        case (.post, 3) where rest[0] == "sandboxes" && isSandboxName(rest[1]) && rest[2] == "terminal":
            return .terminal(rest[1])
        case (.post, 3) where rest[0] == "sandboxes" && isSandboxName(rest[1]) && rest[2] == "terminal-ticket":
            return .terminalTicket(rest[1])
        default: break
        }
        guard method == .get else { return nil }
        switch rest.count {
        case 1:
            switch rest[0] {
            case "overview": return .overview
            case "images": return .images
            case "accounts": return .accounts
            case "metrics": return WebMetricsQuery.parse(query).map(WebRoute.metrics)
            case "metrics.csv": return WebMetricsQuery.parse(query).map(WebRoute.metricsCSV)
            case "operations": return .operations
            case "events": return .events
            case "doctor": return .doctor
            case "stream": return .stream
            case "settings": return .settings
            case "onboarding": return .onboarding
            case "preparations": return .preparations
            default: return nil
            }
        case 2 where rest == ["images", "tree"]:
            return .imageTree
        case 2 where rest[0] == "sandboxes" && isSandboxName(rest[1]):
            return .sandbox(rest[1])
        case 3 where rest[0] == "sandboxes" && isSandboxName(rest[1]):
            switch rest[2] {
            case "sessions": return .sandboxSessions(rest[1])
            case "network": return .sandboxNetwork(rest[1])
            case "terminal-socket": return .terminalSocket(rest[1])
            default: return nil
            }
        default:
            return nil
        }
    }

    /// The library's sandbox-name rule (`SandboxSpec.validate`).
    public static func isSandboxName(_ s: String) -> Bool {
        (1...40).contains(s.count) && s.first != "-" && s.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}
