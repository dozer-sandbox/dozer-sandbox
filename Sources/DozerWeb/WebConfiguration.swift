import Foundation

// 590 — `doz ui`: the configuration values of the local web UI. Copied in shape from DeckStack
// feature 503 (`DeckStackWebGatewayConfiguration`): every invariant that matters is a type that
// cannot represent the unsafe case, so no flag, environment variable or caller can widen it.

/// The only address the UI may bind: IPv4 loopback on a port the OS picks — or (594 W18/W19) the port
/// the OS gave this store's last UI, read from the store, never from a flag, variable or setting. IPv6,
/// a hostname, a wildcard and a chosen fixed port are deliberately not representable.
public struct WebLoopbackAddress: Equatable, Sendable {
    public static let host = "127.0.0.1"
    public let host: String
    public let port: Int

    public init() {
        host = Self.host
        port = 0
    }

    /// 594 W18: the port the OS gave the store's LAST `doz ui` (`<store>/ui.port`), asked for again
    /// so an open page reconnects by itself after a restart. Still loopback only; an unprivileged
    /// port only; nil when nothing may be listening there (then the OS picks, as before). The port is
    /// no secret and grants nothing: a page on it must still be signed in by a new one-use link.
    public init?(reusing port: Int) {
        guard (1024...65_535).contains(port), !Self.inUse(port) else { return nil }
        host = Self.host
        self.port = port
    }

    /// Something accepts connections on 127.0.0.1:`port` (also a wildcard listener — which a
    /// SO_REUSEADDR bind to loopback would otherwise shadow on BSD).
    public static func inUse(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = in_port_t(UInt16(port).bigEndian)
        a.sin_addr.s_addr = inet_addr(host)
        let r = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return r == 0 || errno != ECONNREFUSED
    }
}

/// The listener's origin, known only once the ephemeral port is bound. Used for EXACT `Host` and
/// `Origin` comparison (the DNS-rebinding defence) — never a prefix or suffix match.
public struct WebOrigin: Equatable, Sendable {
    public let port: Int

    public init(port: Int) throws {
        guard (1...65_535).contains(port) else { throw WebConfigurationError.invalidOrigin }
        self.port = port
    }

    public var host: String { WebLoopbackAddress.host }
    /// `127.0.0.1:<port>` — the only `Host` header accepted.
    public var authority: String { "\(host):\(port)" }
    /// `http://127.0.0.1:<port>` — the only `Origin` header accepted.
    public var value: String { "http://\(authority)" }
}

/// A single-use, memory-only bootstrap capability (256 bits). Not `Codable`, and its description,
/// debug description and mirror are REDACTED — Swift's default description of a struct prints its
/// stored properties, so leaving out `CustomStringConvertible` (DeckStack's approach) still printed
/// the value through `"\(cap)"`. It leaves the process only inside a launch URL's FRAGMENT (which
/// browsers never send to a server) handed to LaunchServices, a TTY the user asked it be printed on,
/// or the owner-only `ui.sock` answer to `doz ui link`.
public struct WebBootstrapCapability: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "WebBootstrapCapability(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:] as KeyValuePairs<String, Any>, displayStyle: .struct) }
    let value: String

    private init(value: String) { self.value = value }

    public static func make() -> WebBootstrapCapability { WebBootstrapCapability(value: WebRandom.token()) }

    /// A deterministic capability for tests.
    public init(testingValue: String) throws {
        guard WebRandom.isToken(testingValue), testingValue.utf8.count >= 24 else { throw WebConfigurationError.invalidCapability }
        value = testingValue
    }

    /// The one URL that may carry it: `http://127.0.0.1:<port>/#cap=<value>`.
    public func launchURL(origin: WebOrigin) -> URL {
        URL(string: origin.value + "/#cap=" + value)!
    }
}

/// Limits — each bounded, so a configuration cannot turn a limit off.
public struct WebLimits: Sendable, Equatable {
    public var maximumRequestBodyBytes: Int
    public var sessionLifetime: TimeInterval
    public var bootstrapLifetime: TimeInterval
    public var maximumSSEClients: Int
    public var maximumBufferedSSEEvents: Int
    public var heartbeatInterval: TimeInterval
    public var maximumConnections: Int

    /// 605 (owner Q8, "remember this browser"): a session lasts 14 days without use — the page renews it
    /// when it loads and while it is open — so an installed app on this Mac stays signed in.
    public static let rememberedSession: TimeInterval = 14 * 24 * 60 * 60

    public init(maximumRequestBodyBytes: Int = 16 * 1024, sessionLifetime: TimeInterval = WebLimits.rememberedSession,
                bootstrapLifetime: TimeInterval = 5 * 60, maximumSSEClients: Int = 8, maximumBufferedSSEEvents: Int = 64,
                heartbeatInterval: TimeInterval = 15, maximumConnections: Int = 32) throws {
        guard (1...1_048_576).contains(maximumRequestBodyBytes),
              (30...(30 * 24 * 60 * 60)).contains(sessionLifetime),
              (1...3_600).contains(bootstrapLifetime),
              (1...32).contains(maximumSSEClients),
              (1...1024).contains(maximumBufferedSSEEvents),
              (0.05...60).contains(heartbeatInterval),
              (2...256).contains(maximumConnections) else {
            throw WebConfigurationError.invalidLimit
        }
        self.maximumRequestBodyBytes = maximumRequestBodyBytes
        self.sessionLifetime = sessionLifetime
        self.bootstrapLifetime = bootstrapLifetime
        self.maximumSSEClients = maximumSSEClients
        self.maximumBufferedSSEEvents = maximumBufferedSSEEvents
        self.heartbeatInterval = heartbeatInterval
        self.maximumConnections = maximumConnections
    }

    public static let standard = try! WebLimits()
}

public enum WebConfigurationError: Error, Equatable, Sendable {
    case invalidOrigin, invalidCapability, invalidLimit
}

/// 256-bit random tokens (bootstrap capabilities, session cookies, CSRF tokens), base64url.
enum WebRandom {
    static func token() -> String {
        var g = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &g) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// base64url characters only, 1…256 bytes.
    static func isToken(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 256 && s.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
        }
    }
}

/// Compares secrets without an early exit.
func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8), b = Array(rhs.utf8)
    var diff = UInt8(truncatingIfNeeded: a.count ^ b.count)
    for i in 0..<max(a.count, b.count) {
        diff |= (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)
    }
    return diff == 0
}
