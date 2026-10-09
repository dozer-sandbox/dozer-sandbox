import Foundation
import DozerKit

/// 612: what a session's program (the agent) says it is doing — its program-status record (OSC 7501, kept by
/// deckhold in the guest), as the host holds it. Fields only ever added.
///
/// `message` and `title` are the program's own text: untrusted, shown as data only (the web page renders it
/// with textContent), capped, and NEVER written to host.log — the log and event lines carry metadata only.
public struct SessionStatus: Codable, Equatable, Sendable {
    public var session: String
    public var state: ProgramStatus.State
    public var app: String?
    public var kind: ProgramStatus.Kind?
    public var progress: Int?
    public var message: String?
    public var title: String?
    /// When the program reported it (the host's clock: deckhold's age subtracted from when it was read).
    public var updatedAt: Date

    public init(session: String, state: ProgramStatus.State, app: String? = nil, kind: ProgramStatus.Kind? = nil,
                progress: Int? = nil, message: String? = nil, title: String? = nil, updatedAt: Date = Date()) {
        self.session = session
        self.state = state
        self.app = app
        self.kind = kind
        self.progress = progress
        self.message = message
        self.title = title
        self.updatedAt = updatedAt
    }

    public init(session: String, _ p: ProgramStatus, now: Date = Date()) {
        self.init(session: session, state: p.state, app: p.app, kind: p.kind, progress: p.progress, message: p.message,
                  title: p.title, updatedAt: now.addingTimeInterval(-(p.ageSeconds ?? 0)))
    }

    /// The same report, whenever it was made (what the deduplication compares).
    public func sameReport(as o: SessionStatus) -> Bool {
        state == o.state && app == o.app && kind == o.kind && progress == o.progress && message == o.message && title == o.title
    }

    /// For people: `working`, `working 40%`, `blocked: needs permission`, `done`, `error`, `idle`.
    public var label: String { Self.label(state, kind: kind, progress: progress) }

    public static func label(_ state: ProgramStatus.State, kind: ProgramStatus.Kind? = nil, progress: Int? = nil) -> String {
        switch state {
        case .blocked:
            switch kind {
            case .permission: return "blocked: needs permission"
            case .question: return "blocked: has a question"
            case .auth: return "blocked: needs sign-in"
            case nil: return "blocked"
            }
        case .working: return progress.map { "working \($0)%" } ?? "working"
        case .done, .error, .idle: return state.rawValue
        }
    }

    /// The one a summary shows (`doz ls`, the sidebar): the most urgent (blocked > error > working > done >
    /// idle), the newest of equals. Nil for none.
    public static func mostUrgent(_ all: [SessionStatus]) -> SessionStatus? {
        all.max { a, b in
            a.state.urgency != b.state.urgency ? a.state.urgency < b.state.urgency : a.updatedAt < b.updatedAt
        }
    }

    /// A line for host.log and `doz events` — metadata only, never the program's text.
    public var logLine: String {
        "session \(session): \(label)" + (app.map { " (\($0))" } ?? "")
    }
}
