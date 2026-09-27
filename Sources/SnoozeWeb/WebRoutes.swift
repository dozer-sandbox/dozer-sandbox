import Foundation

/// The CLOSED route table (590). Every route is a case; a path that does not parse to one is a 404
/// before any session is looked at or any host call is made. Identifiers are allowlisted here (a
/// sandbox name is the library's own rule: 1–40 of [a-z0-9-], not starting with `-`), so no
/// request text reaches the host that the host would not accept from the CLI.
///
/// Phase 1 is READ-ONLY: the only unsafe routes are the session's own (bootstrap, renew, sign out).
/// There is deliberately no generic command, exec, file-read, URL-open or PTY route — and none may
/// be added: a later phase adds TYPED operations, one case each.
public enum WebRoute: Equatable, Sendable {
    // static
    case index
    case asset(String)
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
    case accounts                  // GET /api/v1/accounts
    case metrics                   // GET /api/v1/metrics
    case events                    // GET /api/v1/events
    case doctor                    // GET /api/v1/doctor
    case stream                    // GET /api/v1/stream   (server-sent events)

    public var isStatic: Bool {
        switch self { case .index, .asset: true; default: false }
    }

    /// Parse a request target. The query string is ignored (no route reads one); anything else
    /// unusual — percent-encoding, dot segments, a trailing slash, a double slash — is not a route.
    public static func parse(method: WebHTTPMethod, target: String) -> WebRoute? {
        var path = target
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        guard path.hasPrefix("/"), !path.contains("%"), !path.contains("//"), path.count <= 256 else { return nil }
        if path == "/" { return method.isSafe ? .index : nil }
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
        default: break
        }
        guard method == .get else { return nil }
        switch rest.count {
        case 1:
            switch rest[0] {
            case "overview": return .overview
            case "images": return .images
            case "accounts": return .accounts
            case "metrics": return .metrics
            case "events": return .events
            case "doctor": return .doctor
            case "stream": return .stream
            default: return nil
            }
        case 2 where rest[0] == "sandboxes" && isSandboxName(rest[1]):
            return .sandbox(rest[1])
        case 3 where rest[0] == "sandboxes" && isSandboxName(rest[1]):
            switch rest[2] {
            case "sessions": return .sandboxSessions(rest[1])
            case "network": return .sandboxNetwork(rest[1])
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
