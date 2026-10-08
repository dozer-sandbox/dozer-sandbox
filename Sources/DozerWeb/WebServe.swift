import Darwin
import Foundation
import DozerHost

// 606 — `doz serve`: the dashboard for the OTHER browsers of a home lab (owner rulings, 606.01-DESIGN.md's end).
// This file is the rules, as pure functions over small values, so each is a unit test:
//   · which local addresses are served (every LAN interface and Tailscale — never a sandbox's vmnet bridge),
//   · which peers are dropped on accept (every sandbox network: an agent in a VM is Dozer's untrusted party),
//   · what a request's OWN origin is (X-Forwarded-* only from a configured trusted proxy) and whether it is
//     allowed (the Mac's names and addresses, or a configured public origin through a trusted proxy) —
//     the DNS-rebinding defence, re-derived for LAN names.
// `doz ui` (590) is untouched: it stays `WebLoopbackAddress` + `WebOrigin`.

/// An IPv4 or IPv6 address as bytes (IPv4-mapped IPv6 normalised to IPv4).
public struct WebIP: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]                 // 4 or 16
    public var isV4: Bool { bytes.count == 4 }

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("["), s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }                  // a zone id names an interface, not an address
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 {
            bytes = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, s, &v6) == 1 else { return nil }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        bytes = Self.unmapped(b)
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count == 4 || bytes.count == 16 else { return nil }
        self.bytes = bytes.count == 16 ? Self.unmapped(bytes) : bytes
    }

    /// ::ffff:a.b.c.d → a.b.c.d (a dual-stack socket reports IPv4 peers that way).
    static func unmapped(_ b: [UInt8]) -> [UInt8] {
        b.count == 16 && b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF ? Array(b[12..<16]) : b
    }

    public var description: String {
        if isV4 { return bytes.map(String.init).joined(separator: ".") }
        var a = in6_addr()
        withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: bytes) }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count)) != nil else { return "?" }
        return String(cString: buf)
    }

    /// As a URL's host: IPv6 in brackets.
    public var urlHost: String { isV4 ? description : "[\(description)]" }

    public var isLoopback: Bool { isV4 ? bytes[0] == 127 : bytes == [UInt8](repeating: 0, count: 15) + [1] }
    public var isLinkLocal: Bool { isV4 ? bytes[0] == 169 && bytes[1] == 254 : bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 }
    public var isUnspecified: Bool { bytes.allSatisfy { $0 == 0 } }
}

/// A network: an address and a prefix length (`192.168.1.0/24`, `fd7a:115c:a1e0::/48`, `10.0.0.5` = /32).
public struct WebCIDR: Hashable, Sendable, CustomStringConvertible {
    public let address: WebIP
    public let prefix: Int

    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let a = WebIP(String(parts[0])) else { return nil }
        let max = a.isV4 ? 32 : 128
        if parts.count == 2 {
            guard parts[1].allSatisfy(\.isNumber), let p = Int(parts[1]), (0...max).contains(p) else { return nil }
            prefix = p
        } else {
            prefix = max
        }
        address = a
    }

    public init(_ address: WebIP, prefix: Int) {
        self.address = address
        self.prefix = prefix
    }

    public func contains(_ ip: WebIP) -> Bool {
        guard ip.bytes.count == address.bytes.count else { return false }
        var left = prefix
        for i in 0..<ip.bytes.count where left > 0 {
            let bits = min(8, left)
            let mask: UInt8 = bits == 8 ? 0xFF : ~UInt8(0xFF >> bits)
            if ip.bytes[i] & mask != address.bytes[i] & mask { return false }
            left -= bits
        }
        return true
    }

    public var description: String { "\(address)/\(prefix)" }
}

/// One address of one of the Mac's interfaces.
public struct WebInterfaceAddress: Hashable, Sendable {
    public let name: String
    public let address: WebIP
    public let prefix: Int
    public init(name: String, address: WebIP, prefix: Int) {
        self.name = name
        self.address = address
        self.prefix = prefix
    }
    public var network: WebCIDR { WebCIDR(address, prefix: prefix) }

    /// The Mac's addresses now (getifaddrs) — interfaces that are up.
    public static func current() -> [WebInterfaceAddress] {
        var out: [WebInterfaceAddress] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            guard ifa.pointee.ifa_flags & UInt32(IFF_UP) != 0, let a = ifa.pointee.ifa_addr else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            let mask = ifa.pointee.ifa_netmask
            switch Int32(a.pointee.sa_family) {
            case AF_INET:
                let ip = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { s in withUnsafeBytes(of: s.pointee.sin_addr.s_addr) { Array($0) } }
                let m = mask.map { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { s in withUnsafeBytes(of: s.pointee.sin_addr.s_addr) { Array($0) } } } ?? [255, 255, 255, 255]
                if let w = WebIP(bytes: ip) { out.append(WebInterfaceAddress(name: name, address: w, prefix: m.reduce(0) { $0 + $1.nonzeroBitCount })) }
            case AF_INET6:
                let ip = a.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s in withUnsafeBytes(of: s.pointee.sin6_addr) { Array($0) } }
                let m = mask.map { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s in withUnsafeBytes(of: s.pointee.sin6_addr) { Array($0) } } } ?? [UInt8](repeating: 255, count: 16)
                if let w = WebIP(bytes: ip) { out.append(WebInterfaceAddress(name: name, address: w, prefix: m.reduce(0) { $0 + $1.nonzeroBitCount })) }
            default:
                continue
            }
        }
        return out
    }
}

/// Where `doz serve` listens (`serve.bind`).
public enum WebServeBind: Equatable, Sendable {
    /// Every LAN interface and Tailscale (the wildcard, each connection's local address checked).
    case lan
    /// 127.0.0.1 and ::1 — a reverse proxy on this Mac.
    case loopback
    /// Exactly these addresses of the Mac's — a reverse proxy elsewhere on the LAN.
    case addresses([WebIP])

    /// `lan` | `loopback` | addresses separated by commas; nil: not a valid value.
    public static func parse(_ text: String) -> WebServeBind? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t == "lan" || t.isEmpty { return .lan }
        if t == "loopback" { return .loopback }
        let words = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 16 else { return nil }
        var ips: [WebIP] = []
        for w in words {
            guard let ip = WebIP(w), !ip.isUnspecified, !ip.isLinkLocal else { return nil }
            ips.append(ip)
        }
        return .addresses(ips)
    }
}

/// A configured external origin (`serve.public_origins`): what a reverse proxy serves the dashboard as.
public struct WebPublicOrigin: Hashable, Sendable, CustomStringConvertible {
    public let scheme: String          // http | https
    public let host: String            // lowercased; IPv6 in brackets
    public let port: Int?              // nil: the scheme's default

    /// `https://doz.home.example` or `https://doz.home.example:8443` (no path, query or user).
    public init?(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.utf8.count <= 255, let u = URLComponents(string: t), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty, u.user == nil, u.password == nil, u.query == nil, u.fragment == nil,
              u.path.isEmpty || u.path == "/" else { return nil }
        guard host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-:[]".contains($0)) }) else { return nil }
        self.scheme = scheme
        let h = host.lowercased()
        self.host = h.contains(":") && !h.hasPrefix("[") ? "[\(h)]" : h
        let defaultPort = scheme == "https" ? 443 : 80
        port = u.port.flatMap { $0 == defaultPort ? nil : $0 }
        if let p = u.port, !(1...65_535).contains(p) { return nil }
    }

    /// `https://doz.home.example[:port]` — exactly what a browser sends as `Origin`.
    public var description: String { "\(scheme)://\(host)\(port.map { ":\($0)" } ?? "")" }
}

/// `serve.*` as one value.
public struct WebServeConfig: Equatable, Sendable {
    public var port: Int
    public var bind: WebServeBind
    public var publicOrigins: [WebPublicOrigin]
    public var trustedProxies: [WebCIDR]
    public var advertise: Bool

    public init(port: Int = 7443, bind: WebServeBind = .lan, publicOrigins: [WebPublicOrigin] = [], trustedProxies: [WebCIDR] = [],
                advertise: Bool = true) {
        self.port = port
        self.bind = bind
        self.publicOrigins = publicOrigins
        self.trustedProxies = trustedProxies
        self.advertise = advertise
    }

    /// From the settings as this process sees them (flags first; values the schema already validated).
    public init(settings: WebSettingsStore) {
        port = settings.int(SettingKey.servePort)
        bind = WebServeBind.parse(settings.string(SettingKey.serveBind) ?? "lan") ?? .lan
        publicOrigins = WebServeConfig.list(settings.string(SettingKey.servePublicOrigins)).compactMap(WebPublicOrigin.init)
        trustedProxies = WebServeConfig.list(settings.string(SettingKey.serveTrustedProxies)).compactMap(WebCIDR.init)
        advertise = settings.current.bool(SettingKey.serveAdvertise)
    }

    static func list(_ s: String?) -> [String] {
        (s ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public func isTrustedProxy(_ ip: WebIP) -> Bool { trustedProxies.contains { $0.contains(ip) } }
}

/// The Mac's names a browser on the LAN may use (`<LocalHostName>.local`, its host name).
public struct WebMacNames: Equatable, Sendable {
    public var localHostName: String?     // m1max  → m1max.local
    public var hostName: String?          // m1max.lan (the router's DNS), when it is a name

    public init(localHostName: String?, hostName: String?) {
        self.localHostName = localHostName
        self.hostName = hostName
    }

    public var names: [String] {
        var out: [String] = []
        if let l = localHostName?.lowercased(), Self.isName(l) { out.append(l.hasSuffix(".local") ? l : l + ".local") }
        if let h = hostName?.lowercased(), Self.isName(h), !out.contains(h) { out.append(h) }
        return out
    }

    static func isName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 253 && s.first != "-" && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
            && WebIP(s) == nil
    }

    /// This Mac's names, read once (`scutil --get LocalHostName` — read-only — and gethostname).
    public static func current() -> WebMacNames {
        var buf = [CChar](repeating: 0, count: 256)
        let host = gethostname(&buf, buf.count) == 0 ? String(cString: buf) : nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        p.arguments = ["--get", "LocalHostName"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        var local: String?
        if (try? p.run()) != nil {
            let d = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            local = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return WebMacNames(localHostName: local?.isEmpty == false ? local : nil, hostName: host)
    }
}

/// The connection and request rules.
public enum WebServeRules {
    /// Tailscale's ranges (CGNAT IPv4, its IPv6 ULA).
    static let tailscale = [WebCIDR("100.64.0.0/10")!, WebCIDR("fd7a:115c:a1e0::/48")!]
    /// Dozer's automatic NAT subnets (`SubnetPool`: 192.168.100–199.0/24).
    static let automaticNATRange: ClosedRange<UInt8> = 100...199

    /// A vmnet bridge — a sandbox network (`bridge100`, `bridge101`, …; `bridge0` is the Thunderbolt Bridge).
    public static func isSandboxBridge(_ name: String) -> Bool {
        guard name.hasPrefix("bridge"), let n = Int(name.dropFirst("bridge".count)) else { return false }
        return n >= 100
    }

    /// A LAN interface or Tailscale: `en*`, the Thunderbolt Bridge (`bridge0`…`bridge99`), and a `utun`
    /// holding a Tailscale address. Never loopback, a vmnet bridge, or another VPN's tunnel. A LAN interface's
    /// LINK-LOCAL address is served too: another Mac's `<mac>.local` (mDNS) often resolves to it first (measured:
    /// m1a's curl reached m1max.local over fe80::) — only it is never a Host literal (`directOrigins`).
    public static func isServed(_ a: WebInterfaceAddress) -> Bool {
        guard !a.address.isLoopback, !a.address.isUnspecified, !isSandboxBridge(a.name) else { return false }
        if a.name.hasPrefix("en") { return a.name.dropFirst(2).allSatisfy(\.isNumber) }
        if a.name.hasPrefix("bridge") { return true }
        if a.name.hasPrefix("utun") { return !a.address.isLinkLocal && tailscale.contains { $0.contains(a.address) } }
        return false
    }

    /// The networks a sandbox can send from: every vmnet bridge's networks; the automatic NAT range
    /// (192.168.100–199.0/24) wherever no OTHER interface of the Mac is on it (a home LAN on 192.168.150.0/24
    /// stays a LAN); and `defaults.nat_subnet`.
    /// A bridge's LINK-LOCAL network is not one of them: fe80::/64 is every interface's, so it would take every
    /// link-local peer for a sandbox. A guest reaches only its own link's link-local address — the bridge's own,
    /// which `admit` drops as a local address.
    public static func sandboxNetworks(_ interfaces: [WebInterfaceAddress], natSubnet: String? = nil) -> [WebCIDR] {
        var out = interfaces.filter { isSandboxBridge($0.name) && !$0.address.isLinkLocal }.map(\.network)
        let lan = interfaces.filter { !isSandboxBridge($0.name) && $0.address.isV4 && !$0.address.isLoopback }
        for third in automaticNATRange {
            let net = WebCIDR(WebIP(bytes: [192, 168, third, 0])!, prefix: 24)
            if !lan.contains(where: { $0.network.contains(net.address) || net.contains($0.address) }) { out.append(net) }
        }
        if let s = natSubnet, !s.isEmpty, let c = WebCIDR(s) { out.append(c) }
        return out
    }

    public enum Drop: String, Equatable, Sendable {
        /// The peer (or the address it reached) is a sandbox's network.
        case sandbox
        /// It reached an address `doz serve` does not serve (another VPN's tunnel). Never a silent drop: it is
        /// answered over HTTP with why (`WebRejection.notServedAddress`) — only a sandbox's connection is dropped.
        case notServed = "not-served"
    }

    /// Whether a new connection is served: nil = yes; `.sandbox` = dropped before a byte is read; `.notServed` =
    /// answered with why. The Mac's own loopback is served under `lan` (owner bug on rc.1: a browser ON the Mac opened
    /// the printed http://<mac>.local link, which resolved to ::1 — and got no response): loopback is not a sandbox
    /// (a guest cannot reach the Mac's loopback; a proxied sandbox's proxy is refused the dashboards' ports by
    /// `LocalDashboards`), and the same invite rules admit it.
    public static func admit(peer: WebIP, local: WebIP, bind: WebServeBind, interfaces: [WebInterfaceAddress],
                             natSubnet: String? = nil) -> Drop? {
        if sandboxNetworks(interfaces, natSubnet: natSubnet).contains(where: { $0.contains(peer) }) { return .sandbox }
        if interfaces.contains(where: { isSandboxBridge($0.name) && $0.address == local }) { return .sandbox }
        switch bind {
        case .lan:
            if local.isLoopback { return nil }
            return interfaces.contains(where: { $0.address == local && isServed($0) }) ? nil : .notServed
        case .loopback:
            return local.isLoopback ? nil : .notServed
        case .addresses(let ips):
            return ips.contains(local) ? nil : .notServed
        }
    }

    /// The local addresses served now (what `doz serve` prints, and the address literals a browser may use).
    public static func servedAddresses(_ bind: WebServeBind, _ interfaces: [WebInterfaceAddress]) -> [WebIP] {
        switch bind {
        case .lan: return interfaces.filter { isServed($0) && !$0.address.isLinkLocal }.map(\.address).uniqued()
        case .loopback: return [WebIP("127.0.0.1")!, WebIP("::1")!]
        case .addresses(let ips): return ips
        }
    }

    /// The origins a browser reaching the Mac DIRECTLY may have: `http://<name or address>:<port>`.
    public static func directOrigins(port: Int, bind: WebServeBind, interfaces: [WebInterfaceAddress], names: WebMacNames) -> Set<String> {
        var hosts = servedAddresses(bind, interfaces).map(\.urlHost)
        switch bind {
        case .lan: hosts += names.names + ["127.0.0.1", "[::1]", "localhost"]   // the Mac's own browser too
        case .loopback: hosts.append("localhost")
        case .addresses: hosts += names.names
        }
        return Set(hosts.map { "http://\($0.lowercased()):\(port)" })
    }

    /// What one request is, as the security checks see it.
    public struct RequestOrigin: Equatable, Sendable {
        /// The request's OWN origin (`http://m1max.local:7443`, `https://doz.home.example`); nil = its Host is
        /// not one this server answers to (refused before anything else).
        public var origin: String?
        /// It arrived over https at a trusted proxy (X-Forwarded-Proto: https from a `serve.trusted_proxies` peer).
        public var secure: Bool
        /// It came through a trusted proxy.
        public var viaProxy: Bool
        /// Who sent it: the peer, or (through a trusted proxy) the rightmost untrusted X-Forwarded-For hop.
        public var client: String
    }

    /// `host` normalised as an origin's authority for `scheme`: lowercased, the default port dropped.
    static func authority(_ host: String, scheme: String) -> String? {
        let h = host.lowercased()
        guard !h.isEmpty, h.utf8.count <= 300, h.allSatisfy({ $0.isASCII && !$0.isWhitespace && $0 != "/" && $0 != "@" }) else { return nil }
        let defaultPort = scheme == "https" ? ":443" : ":80"
        return h.hasSuffix(defaultPort) ? String(h.dropLast(defaultPort.count)) : h
    }

    /// The request's own origin and whether it is allowed. `hostHeader`, `forwardedProto`, `forwardedHost` and
    /// `forwardedFor` are the single values of those headers (nil when absent or repeated).
    public static func requestOrigin(hostHeader: String?, forwardedProto: String?, forwardedHost: String?, forwardedFor: String?,
                                     peer: WebIP, config: WebServeConfig, direct: Set<String>) -> RequestOrigin {
        let trusted = config.isTrustedProxy(peer)
        var client = peer.description
        if trusted, let xff = forwardedFor {
            // The rightmost hop that is not one of our proxies is the client.
            let hops = xff.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.compactMap(WebIP.init)
            if let c = hops.reversed().first(where: { !config.isTrustedProxy($0) }) { client = c.description }
        }
        var scheme = "http"
        var host = hostHeader
        if trusted {
            if let p = forwardedProto?.lowercased() {
                // A list (a chain of proxies) — the first is what the browser used. A WebSocket upgrade's is ws/wss
                // at some proxies (Traefik): the page's origin is http/https all the same.
                var first = p.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if first == "ws" { first = "http" } else if first == "wss" { first = "https" }
                guard first == "http" || first == "https" else {
                    return RequestOrigin(origin: nil, secure: false, viaProxy: true, client: client)
                }
                scheme = first
            }
            if let fh = forwardedHost { host = fh.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } }
        }
        guard let h = host, let auth = authority(h, scheme: scheme) else {
            return RequestOrigin(origin: nil, secure: false, viaProxy: trusted, client: client)
        }
        let candidate = "\(scheme)://\(auth)"
        let allowed = (scheme == "http" && direct.contains(candidate))
            || (trusted && config.publicOrigins.contains { $0.description == candidate })
        return RequestOrigin(origin: allowed ? candidate : nil, secure: allowed && scheme == "https", viaProxy: trusted, client: client)
    }

    /// The device cookie's name: `__Host-` + Secure over https (a sibling http origin can neither set nor
    /// shadow it); port-scoped either way (cookies ignore ports).
    public static func cookieName(port: Int, secure: Bool) -> String {
        (secure ? "__Host-doz_serve_" : "doz_serve_") + String(port)
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
