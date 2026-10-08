import Darwin
import Foundation

/// 606: Dozer's own dashboards (`doz ui`, `doz serve`) are never reachable from a sandbox. A PROXIED sandbox has
/// no network interface — its traffic leaves from the host process itself, through the egress proxy — so a
/// policy that allows everything (`open`) would otherwise let the agent connect to the Mac's own addresses on a
/// dashboard's port. `Wire.connectTCP` refuses that, whatever the policy says: a destination that is THIS Mac
/// (loopback, the unspecified address, or any address of one of its interfaces) on a port `protectedPorts`
/// names. The host sets it (the ports its store's dashboards listen on); nil = nothing protected.
public enum LocalDashboards {
    nonisolated(unsafe) private static var provider: (@Sendable () -> Set<UInt16>)?
    private static let lock = NSLock()

    public static func protect(_ ports: (@Sendable () -> Set<UInt16>)?) {
        lock.lock(); provider = ports; lock.unlock()
    }

    static var ports: Set<UInt16> {
        lock.lock(); let p = provider; lock.unlock()
        return p?() ?? []
    }

    /// Whether connecting to `addr` (a sockaddr from getaddrinfo) on `port` would reach a dashboard of this Mac.
    static func refuses(_ addr: UnsafePointer<sockaddr>, port: UInt16) -> Bool {
        let protected = ports
        guard protected.contains(port) else { return false }
        guard let ip = bytes(addr) else { return true }
        return isThisMac(ip)
    }

    /// Whether `host:port` (a name or an address) resolves to a dashboard of this Mac.
    public static func refuses(host: String, port: UInt16) -> Bool {
        guard ports.contains(port) else { return false }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { return false }
        defer { freeaddrinfo(first) }
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            if let sa = a.pointee.ai_addr, refuses(UnsafePointer(sa), port: port) { return true }
            ai = a.pointee.ai_next
        }
        return false
    }

    static func bytes(_ sa: UnsafePointer<sockaddr>) -> [UInt8]? {
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { s in withUnsafeBytes(of: s.pointee.sin_addr.s_addr) { Array($0) } }
        case AF_INET6:
            let b = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s in withUnsafeBytes(of: s.pointee.sin6_addr) { Array($0) } }
            // IPv4-mapped → IPv4.
            if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF { return Array(b[12..<16]) }
            return b
        default:
            return nil
        }
    }

    /// Loopback, unspecified, or an address of one of this Mac's interfaces.
    static func isThisMac(_ ip: [UInt8]) -> Bool {
        if ip.count == 4, ip[0] == 127 || ip == [0, 0, 0, 0] { return true }
        if ip.count == 16, ip == [UInt8](repeating: 0, count: 15) + [1] || ip.allSatisfy({ $0 == 0 }) { return true }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return true }      // cannot tell: refuse
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            if let a = ifa.pointee.ifa_addr, let b = bytes(UnsafePointer(a)), b == ip { return true }
            p = ifa.pointee.ifa_next
        }
        return false
    }
}
