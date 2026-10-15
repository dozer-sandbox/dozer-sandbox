import Foundation

// 617 (RP-1, owner: "web port forwarding first"; design: changes/617-*/617.10-WEB-PORT-FORWARD.md in the workspace).
// A forward maps a port a program listens on inside a sandbox (its own localhost) to a port on the MAC'S LOOPBACK
// (127.0.0.1, and [::1] when free) — never 0.0.0.0. Inbound only: the Mac's browser reaches the guest program; the
// guest reaches nothing through it, so the egress policy and the proxy are not involved and no credential crosses it.
// Each connection is relayed by the guest's `deckhold connect -p PORT` (the transport the sign-in callback forward
// already uses), so it works for every kind of sandbox and needs no guest daemon. The host binds a sandbox's forwards
// while it runs and closes them when it stops, sleeps or hibernates.

public enum PortForwarding {
    /// At most this many forwards per sandbox (recipe and ad hoc together).
    public static let maximumPerSandbox = 16
    /// The Mac side never binds a privileged port: a guest port below this gets a free high port.
    public static let lowestMacPort = 1024

    /// A path an Open button may open: starts with /, no whitespace or control characters, at most 200 bytes.
    public static func isPath(_ p: String) -> Bool {
        p.hasPrefix("/") && p.utf8.count <= 200
            && !p.unicodeScalars.contains { $0.value <= 0x20 || $0.value == 0x7F }
    }

    /// The Mac ports to try, in order: the one it had last time, the guest's own port (when not privileged), then 0
    /// (a free port the system picks). Each once.
    public static func macPortCandidates(guest: Int, previous: Int?) -> [Int] {
        var out: [Int] = []
        for p in [previous, guest] {
            if let p, p >= lowestMacPort, p <= 65_535, !out.contains(p) { out.append(p) }
        }
        out.append(0)
        return out
    }

    /// The URL the Mac's browser opens for a forward.
    public static func url(macPort: Int, path: String?) -> String {
        "http://127.0.0.1:\(macPort)" + (path.flatMap { isPath($0) ? $0 : nil } ?? "/")
    }
}

/// A forward a person added (`doz ports add`) — kept in the sandbox's record; a recipe's own ports are not stored (they
/// come from the recipe each time). `macPort` remembers the Mac port it last had (recipe ports too, by guest port).
public struct PortForwardEntry: Codable, Equatable, Sendable {
    public var port: Int
    public var title: String?
    public var path: String?
    public init(port: Int, title: String? = nil, path: String? = nil) {
        self.port = port; self.title = title; self.path = path
    }
}

/// What `doz ports` shows of one forward.
public struct PortForwardRow: Codable, Equatable, Sendable {
    /// The guest port.
    public var port: Int
    public var title: String
    public var path: String
    /// `http` or `ws`.
    public var `protocol`: String
    /// `recipe` (declared by the image's recipe) or `added` (`doz ports add`).
    public var origin: String
    /// `listening` (on `macPort`), `stopped` (the sandbox is not running) or `failed` (`why`).
    public var state: String
    /// The Mac's loopback port while listening (or the one it had last).
    public var macPort: Int?
    /// The URL to open while listening (http forwards).
    public var url: String?
    /// Set when the Mac port is not the guest port (it was taken, or privileged).
    public var moved: Bool?
    public var why: String?
    public var auth: String?
    public var tokenHint: String?
    /// Whether a program in the sandbox listens on the port (its own localhost) — the forward can be up with nothing
    /// behind it. nil: not checked (not running, or the guest did not answer). The host checks on a look, at most
    /// every few seconds (`HostCore.refreshServing`).
    public var serving: Bool?
    /// The recipe's command that serves it (`ports@1 serve`), to start in a session — said while nothing serves.
    public var serveHint: String?
    enum CodingKeys: String, CodingKey {
        case port, title, path, `protocol`, origin, state, url, moved, why, auth, serving
        case macPort = "mac_port", tokenHint = "token_hint", serveHint = "serve_hint"
    }
    public init(port: Int, title: String, path: String, protocol: String, origin: String, state: String, macPort: Int? = nil,
                url: String? = nil, moved: Bool? = nil, why: String? = nil, auth: String? = nil, tokenHint: String? = nil) {
        self.port = port; self.title = title; self.path = path; self.protocol = `protocol`; self.origin = origin; self.state = state
        self.macPort = macPort; self.url = url; self.moved = moved; self.why = why; self.auth = auth; self.tokenHint = tokenHint
    }
}
