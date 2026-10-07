import Foundation
import NIOCore

// 606 — what a `doz serve` server holds beside the shared DozerWeb code: its configuration, the Mac's names,
// the interfaces (re-read every few seconds, so a Wi-Fi switch or a new lease needs no restart), the devices,
// the audit log, the doctor's one-use probe tokens, and the connections per address.

/// How a request is signed in: `doz ui`'s browser sessions (590/605) or `doz serve`'s devices (606).
enum WebAuth: Sendable {
    case browser(WebSessionStore)
    case devices(WebDeviceStore)

    func authenticate(_ cookie: String) async throws -> WebSession {
        switch self {
        case .browser(let s): try await s.authenticate(cookie)
        case .devices(let d): try await d.authenticate(cookie).0
        }
    }

    func authenticateMutation(_ cookie: String, csrf: String?) async throws -> WebSession {
        switch self {
        case .browser(let s): try await s.authenticateMutation(cookie, csrf: csrf)
        case .devices(let d): try await d.authenticateMutation(cookie, csrf: csrf).0
        }
    }

    func isValid(_ cookie: String) async -> Bool {
        switch self {
        case .browser(let s): await s.isValid(cookie)
        case .devices(let d): await d.isValid(cookie)
        }
    }

    func renew(_ cookie: String) async throws -> WebSession {
        switch self {
        case .browser(let s): try await s.renew(cookie)
        case .devices(let d): try await d.authenticate(cookie).0
        }
    }

    func signOut(_ cookie: String) async {
        switch self {
        case .browser(let s): await s.revoke(cookie)
        case .devices(let d): await d.signOut(cookie)
        }
    }
}

/// What one request is: its view of the listener (own origin, cookie name), who asks, from where.
struct WebRequestContext: Sendable {
    var view: WebRequestView
    var principal: WebExposure.Principal
    /// The client's address (a trusted proxy's X-Forwarded-For hop, else the peer) — doz serve only.
    var client: String
    var userAgent: String?

    var secure: Bool { if case .remote(let s) = principal { s } else { false } }
}

public final class WebServeState: @unchecked Sendable {
    public let config: WebServeConfig
    public let names: WebMacNames
    public let devices: WebDeviceStore
    public let audit: WebServeAudit
    let interfacesProvider: @Sendable () -> [WebInterfaceAddress]
    let natSubnet: String?
    /// Per address and in all.
    static let connectionsPerAddress = 32

    private let lock = NSLock()
    private var cached: (at: Date, list: [WebInterfaceAddress]) = (.distantPast, [])
    private var probes: [String: Date] = [:]
    private var perAddress: [String: Int] = [:]
    /// rc.2: when it started, whether detached (`doz serve start --detach`), its log, the app macOS attributes it to.
    public let startedAt = Date()
    public var detached = false
    public var logPath: String?
    public var responsibleApp: String?
    /// The port actually bound (the configured one; a test's ephemeral one).
    public internal(set) var port: Int

    public init(config: WebServeConfig, names: WebMacNames, devices: WebDeviceStore, audit: WebServeAudit, natSubnet: String? = nil,
                interfaces: @escaping @Sendable () -> [WebInterfaceAddress] = WebInterfaceAddress.current) {
        self.config = config
        self.names = names
        self.devices = devices
        self.audit = audit
        self.natSubnet = natSubnet
        interfacesProvider = interfaces
        port = config.port
    }

    /// The Mac's interfaces, at most 3 s old.
    func interfaces() -> [WebInterfaceAddress] {
        lock.withLock {
            if Date().timeIntervalSince(cached.at) > 3 { cached = (Date(), interfacesProvider()) }
            return cached.list
        }
    }

    var directOrigins: Set<String> {
        WebServeRules.directOrigins(port: port, bind: config.bind, interfaces: interfaces(), names: names)
    }

    /// Where browsers reach it, for people: names first, then addresses, then the public origins.
    public var origins: [String] {
        let served = WebServeRules.servedAddresses(config.bind, interfaces())
        let addrs = (served.filter(\.isV4) + served.filter { !$0.isV4 }).map { "http://\($0.urlHost):\(port)" }
        let named: [String] = config.bind == .loopback ? [] : names.names.map { "http://\($0):\(port)" }
        return named + addrs
    }

    /// doz serve's IPv4 address origins (`http://192.168.1.20:7443`) — an invite is printed at these too.
    public var addressOrigins: [String] {
        WebServeRules.servedAddresses(config.bind, interfaces()).filter(\.isV4).map { "http://\($0.urlHost):\(port)" }
    }

    /// The origin an invite's link is made for when the asker has none (the CLI): `<LocalHostName>.local`,
    /// else the first served address, else the first public origin.
    public var preferredOrigin: String {
        if config.bind != .loopback, let n = names.names.first { return "http://\(n):\(port)" }
        if let p = config.publicOrigins.first, config.bind == .loopback { return p.description }
        return origins.first ?? config.publicOrigins.first?.description ?? "http://127.0.0.1:\(port)"
    }

    /// A new connection: nil = serve it, else why it is dropped.
    /// TEST seam: decide a connection's fate instead of the rules (the HTTP tests reach the server only over loopback).
    public var admitOverride: (@Sendable (WebIP, WebIP) -> WebServeRules.Drop?)?

    func admit(peer: SocketAddress?, local: SocketAddress?) -> WebServeRules.Drop? {
        if let o = admitOverride, let p = peer?.ipAddress.flatMap(WebIP.init), let l = local?.ipAddress.flatMap(WebIP.init) { return o(p, l) }
        guard let p = peer?.ipAddress.flatMap(WebIP.init), let l = local?.ipAddress.flatMap(WebIP.init) else { return .notServed }
        return WebServeRules.admit(peer: p, local: l, bind: config.bind, interfaces: interfaces(), natSubnet: natSubnet)
    }

    /// Count a connection from `address`; false when it already has as many as it may. A trusted proxy is every
    /// browser behind it at once (an HTTP/2 page's ~70 module requests become as many upstream connections): only
    /// the server's own cap applies to it.
    func open(_ address: String) -> Bool {
        let proxy = WebIP(address).map(config.isTrustedProxy) ?? false
        return lock.withLock {
            let n = perAddress[address, default: 0]
            guard proxy || n < Self.connectionsPerAddress else { return false }
            perAddress[address] = n + 1
            return true
        }
    }

    func closed(_ address: String) {
        lock.withLock {
            let n = perAddress[address, default: 1] - 1
            perAddress[address] = n > 0 ? n : nil
        }
    }

    /// The request's view: its own origin (or nil), the cookie name, who asks.
    func context(_ head: HTTPHeadersView, peer: SocketAddress?) -> WebRequestContext {
        let ip = peer?.ipAddress.flatMap(WebIP.init) ?? WebIP("0.0.0.0")!
        let r = WebServeRules.requestOrigin(hostHeader: head.single("host"), forwardedProto: head.single("x-forwarded-proto"),
                                            forwardedHost: head.single("x-forwarded-host"), forwardedFor: head.joined("x-forwarded-for"),
                                            peer: ip, config: config, direct: directOrigins)
        let view = WebRequestView(ownOrigin: r.origin, cookieName: WebServeRules.cookieName(port: port, secure: r.secure),
                                  missingCookie: .notAdmitted)
        return WebRequestContext(view: view, principal: .remote(secure: r.secure), client: r.client,
                                 userAgent: head.single("user-agent").map { WebDeviceStore.clean($0, max: 200) })
    }

    // MARK: the doctor's probe

    /// A one-use token (`doz doctor` asks over serve.sock, then fetches a public origin with it).
    public func issueProbe() -> String {
        lock.withLock {
            let t = WebRandom.token()
            let now = Date()
            probes = probes.filter { $0.value > now }
            probes[t] = now.addingTimeInterval(60)
            return t
        }
    }

    func consumeProbe(_ token: String?) -> Bool {
        guard let token else { return false }
        return lock.withLock {
            guard let k = probes.keys.first(where: { constantTimeEqual($0, token) }), probes[k]! > Date() else { return false }
            probes[k] = nil
            return true
        }
    }
}

/// The few headers the serve rules read: the single value of a header (nil when absent or repeated), or all of
/// them joined (X-Forwarded-For may come split).
struct HTTPHeadersView: Sendable {
    let pairs: [(String, String)]
    func single(_ name: String) -> String? {
        let v = pairs.filter { $0.0.lowercased() == name }.map(\.1)
        return v.count == 1 ? v[0] : nil
    }
    func joined(_ name: String) -> String? {
        let v = pairs.filter { $0.0.lowercased() == name }.map(\.1)
        return v.isEmpty ? nil : v.joined(separator: ", ")
    }
}
