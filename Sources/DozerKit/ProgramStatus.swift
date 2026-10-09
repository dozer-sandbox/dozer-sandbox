import Foundation

/// 612: what a session's program says it is doing — its ROOT record of the program-status protocol (OSC 7501),
/// as deckhold keeps it (`Guest/deckhold/deckhold.c`: deckhold answers the protocol's query, so Claude Code and
/// pi report, and validates every report by the spec before it keeps it). deckhold hands it out as text — in
/// `deckhold ls`'s INFO line and in the STATUS frames a watcher gets — `status=<report body>\tstatus_age=<s>`,
/// the body canonical: `state=…[:app=…][:kind=…][:progress=N][:msg=<base64>][:title=<base64>]`.
///
/// `message` and `title` are the PROGRAM's text: untrusted (from inside a sandbox), shown as data only, never
/// logged. deckhold already refused control characters in them; `parse` caps them again.
public struct ProgramStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable, CaseIterable {
        case idle, working, done, blocked, error

        /// The order a summary shows them in: what needs a person first (blocked > error > working > done > idle).
        public var urgency: Int {
            switch self {
            case .blocked: 4
            case .error: 3
            case .working: 2
            case .done: 1
            case .idle: 0
            }
        }

        /// `working` and `blocked` end when the program does (the spec); `done` and `error` survive it.
        public var endsWithProgram: Bool { self == .working || self == .blocked }
    }

    /// What a `blocked` program waits for.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case permission, question, auth
    }

    public var state: State
    /// The program's machine name (`claude-code`, `pi`) — `[A-Za-z0-9_.+-]{1,32}`.
    public var app: String?
    public var kind: Kind?
    /// 0–100 (working/blocked only); nil = indeterminate.
    public var progress: Int?
    /// One line from the program (untrusted text).
    public var message: String?
    /// A short label from the program (untrusted text).
    public var title: String?
    /// How long ago the program reported it, as deckhold measured (seconds).
    public var ageSeconds: Double?

    public static let maximumMessageLength = 2048
    public static let maximumTitleLength = 192

    public init(state: State, app: String? = nil, kind: Kind? = nil, progress: Int? = nil, message: String? = nil,
                title: String? = nil, ageSeconds: Double? = nil) {
        self.state = state
        self.app = app
        self.kind = kind
        self.progress = progress
        self.message = message
        self.title = title
        self.ageSeconds = ageSeconds
    }

    /// From deckhold's fields: `status` (the report body) and `status_age`. Nil when there is no record or
    /// the text is not one (an unknown state — a newer deckhold's — counts as none).
    public init?(fields: [String: String]) {
        guard let body = fields["status"], !body.isEmpty else { return nil }
        var pairs: [String: String] = [:]
        for pair in body.split(separator: ":") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            pairs[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        guard let s = pairs["state"].flatMap(State.init(rawValue:)) else { return nil }
        state = s
        app = pairs["app"].flatMap { a in
            (1...32).contains(a.utf8.count) && a.utf8.allSatisfy { Self.isNameByte($0) } ? a : nil
        }
        kind = s == .blocked ? pairs["kind"].flatMap(Kind.init(rawValue:)) : nil
        progress = pairs["progress"].flatMap(Int.init).flatMap { (0...100).contains($0) ? $0 : nil }
        message = pairs["msg"].flatMap { Self.text($0, max: Self.maximumMessageLength) }
        title = pairs["title"].flatMap { Self.text($0, max: Self.maximumTitleLength) }
        ageSeconds = fields["status_age"].flatMap(Double.init).flatMap { $0 >= 0 && $0.isFinite ? $0 : nil }
    }

    /// From a STATUS frame's payload (tab-separated `key=value` fields; empty = no record).
    public static func parse(frame text: String) -> ProgramStatus? {
        ProgramStatus(fields: fields(text.split(separator: "\t").map(String.init)))
    }

    static func fields(_ parts: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for p in parts {
            guard let eq = p.firstIndex(of: "=") else { continue }
            out[String(p[..<eq])] = String(p[p.index(after: eq)...])
        }
        return out
    }

    static func isNameByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b == 0x2E || b == 0x2B || b == 0x2D
    }

    /// base64 (padded or not) → one line of text with every control character removed, at most `max` bytes.
    static func text(_ b64: String, max: Int) -> String? {
        var s = b64
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s), !d.isEmpty, d.count <= max else { return nil }
        let t = String(decoding: d, as: UTF8.self).unicodeScalars
            .filter { !($0.value < 0x20 || (0x7F...0x9F).contains($0.value)) }
        let out = String(String.UnicodeScalarView(t)).trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? nil : out
    }
}
