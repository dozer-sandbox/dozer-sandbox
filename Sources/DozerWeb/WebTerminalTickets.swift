import Foundation
import DozerKit

// 591 — the terminal socket's ticket (591.01-DESIGN.md §4). A WebSocket upgrade cannot carry the
// CSRF header, so a terminal is opened in two steps: a CSRF-checked `POST …/terminal-ticket` mints
// a one-use, 30-second ticket bound to the browser session, the sandbox, the session name and the
// mode; the upgrade presents it (in `Sec-WebSocket-Protocol`) and consumes it.

/// Interactive (keys reach the session) or watch-only (nothing the browser sends reaches the host,
/// and the attach never resizes the session: HELLO 0×0).
public enum WebTerminalMode: String, Codable, Equatable, Sendable {
    case interactive, watch
}

/// The body of `POST /api/v1/sandboxes/{name}/terminal-ticket`, decoded STRICTLY.
public struct WebTerminalTicketRequest: Equatable, Sendable {
    public var session: String?
    public var mode: WebTerminalMode
    /// The page's terminal size for the first attach (interactive only; a watcher keeps the session's).
    public var size: TermSize?
    /// 605: the page reattaches a terminal it had (after `doz ui` restarted, or a sign-in again): the first
    /// SNAPSHOT then keeps the terminal's scrollback, as after a boot view.
    public var reattach: Bool = false

    public static let colsRange: ClosedRange<Int> = 2...1000
    public static let rowsRange: ClosedRange<Int> = 1...500

    public static func decode(_ body: Data) throws -> WebTerminalTicketRequest {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        let extra = Set(d.keys).subtracting(["session", "mode", "cols", "rows", "reattach"])
        guard extra.isEmpty else { throw WebAction.Invalid("unexpected field(s): \(extra.sorted().joined(separator: ", "))") }
        guard let m = d["mode"] as? String, let mode = WebTerminalMode(rawValue: m) else { throw WebAction.Invalid("mode: interactive or watch") }
        var session: String?
        if let v = d["session"] {
            guard let s = v as? String, s.utf8.count <= 64 else { throw WebAction.Invalid("session: 1–64 of letters, digits . _ - (not starting with .)") }
            do { try GuestCommand.validateSessionName(s) } catch { throw WebAction.Invalid("session: 1–64 of letters, digits . _ - (not starting with .)") }
            session = s
        }
        func dim(_ key: String, _ range: ClosedRange<Int>) throws -> Int? {
            guard let v = d[key] else { return nil }
            // A JSON number that is a whole number in range; never a string or a bool.
            guard let n = v as? NSNumber, CFGetTypeID(n) == CFNumberGetTypeID(), !CFNumberIsFloatType(n), range.contains(n.intValue) else {
                throw WebAction.Invalid("\(key): a whole number in \(range.lowerBound)…\(range.upperBound)")
            }
            return n.intValue
        }
        let cols = try dim("cols", colsRange), rows = try dim("rows", rowsRange)
        guard (cols == nil) == (rows == nil) else { throw WebAction.Invalid("cols and rows go together") }
        let size = cols.map { TermSize(cols: UInt16($0), rows: UInt16(rows!)) }
        var reattach = false
        if let v = d["reattach"] {
            guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw WebAction.Invalid("reattach: true or false") }
            reattach = n.boolValue
        }
        return WebTerminalTicketRequest(session: session, mode: mode, size: mode == .watch ? nil : size, reattach: reattach)
    }
}

/// What a consumed ticket grants: one terminal on this sandbox (and session, when named), for the
/// browser session that minted it.
public struct WebTerminalGrant: Equatable, Sendable {
    public let cookie: String
    public let sandbox: String
    public let session: String?
    public let mode: WebTerminalMode
    public let size: TermSize?
    /// 605: see `WebTerminalTicketRequest.reattach`.
    public var reattach: Bool = false
}

/// The ticket answer. `ticket` is a one-use capability for 30 s — it goes to the page (which keeps
/// it in memory for the moment it takes to open the socket), never into a URL or storage.
struct WebTerminalTicketInfo: Encodable {
    let ticket: String
    let expiresInSeconds: Int
    let session: String?
    let mode: WebTerminalMode
}

/// Memory-only, like the session store: the process is the revocation boundary.
public actor WebTerminalTicketStore {
    private struct Pending {
        let grant: WebTerminalGrant
        let issuedAt: Date
    }

    public let lifetime: TimeInterval
    public let maximumPendingPerSession: Int
    private let now: @Sendable () -> Date
    private var pending: [String: Pending] = [:]
    /// Recently consumed tickets (for "already used" instead of "not valid"), kept a few minutes.
    private var consumed: [String: Date] = [:]

    public init(lifetime: TimeInterval = 30, maximumPendingPerSession: Int = 16, now: @escaping @Sendable () -> Date = Date.init) {
        self.lifetime = lifetime
        self.maximumPendingPerSession = maximumPendingPerSession
        self.now = now
    }

    private func prune() {
        let t = now()
        // An expired ticket is kept one lifetime longer, so presenting it says "expired", not "unknown".
        pending = pending.filter { t.timeIntervalSince($0.value.issuedAt) < lifetime * 2 }
        consumed = consumed.filter { t.timeIntervalSince($0.value) < 300 }
    }

    /// A new one-use ticket for `cookie`'s browser session.
    public func mint(cookie: String, sandbox: String, session: String?, mode: WebTerminalMode, size: TermSize?, reattach: Bool = false) throws -> String {
        prune()
        let t = now()
        let live = pending.values.filter { $0.grant.cookie == cookie && t.timeIntervalSince($0.issuedAt) < lifetime }.count
        guard live < maximumPendingPerSession else { throw WebRejection.tooManyTickets }
        let token = WebRandom.token()
        pending[token] = Pending(grant: WebTerminalGrant(cookie: cookie, sandbox: sandbox, session: session, mode: mode, size: size, reattach: reattach), issuedAt: t)
        return token
    }

    /// Consume `ticket` for an upgrade presented with `cookie` on `sandbox`'s socket. The ticket is
    /// spent even when a check fails (a stolen ticket tried from elsewhere is burnt).
    public func consume(_ ticket: String, cookie: String, sandbox: String) throws -> WebTerminalGrant {
        prune()
        guard let key = pending.keys.first(where: { constantTimeEqual(ticket, $0) }) else {
            if consumed.keys.contains(where: { constantTimeEqual(ticket, $0) }) { throw WebRejection.ticketUsed }
            throw WebRejection.ticketRejected
        }
        let p = pending.removeValue(forKey: key)!
        consumed[key] = now()
        guard now().timeIntervalSince(p.issuedAt) < lifetime else { throw WebRejection.ticketExpired }
        guard constantTimeEqual(p.grant.cookie, cookie), p.grant.sandbox == sandbox else { throw WebRejection.ticketRejected }
        return p.grant
    }

    public var pendingCount: Int { pending.count }
}
