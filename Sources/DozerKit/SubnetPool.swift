import Containerization
import ContainerizationExtras
import Darwin
import Foundation

/// 583: automatic vmnet subnets. A NAT sandbox (and a bake that needs the network) whose spec names no
/// `subnet` gets one of its own from 192.168.100.0/24 … 192.168.199.0/24 instead of vmnet's default:
/// two processes that both take the default can get the SAME subnet and the same guest addresses,
/// and the NAT then silently drops one of them (578/579). A candidate is skipped when
///   · a network interface of the Mac already has an address in it (the LAN, a VPN, another
///     process's running vmnet bridge), or
///   · this process already holds it (every network the library creates is reserved here until the
///     `Sandbox` that made it is gone),
/// and the candidates are tried from a random starting point, so two processes starting at the same
/// moment rarely try the same one first. An explicit `SandboxSpec.subnet` stays an override (and is
/// reserved too, so an automatic pick never lands on it). A proxied sandbox has no NIC and needs none.
enum SubnetPool {
    static let first: UInt32 = 100, last: UInt32 = 199
    /// The candidate /24 networks, as host-order network addresses.
    static let candidates: [UInt32] = (first...last).map { (192 << 24) | (168 << 16) | ($0 << 8) }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: [UInt32: Int] = [:]

    /// The IPv4 networks the Mac has interfaces on, as (address, netmask) in host order.
    static func hostNetworks() -> [(address: UInt32, mask: UInt32)] {
        var out: [(UInt32, UInt32)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            if let a = ifa.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET), let m = ifa.pointee.ifa_netmask {
                let addr = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                let mask = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                if addr >> 24 != 127 { out.append((addr, mask)) }
            }
            p = ifa.pointee.ifa_next
        }
        return out
    }

    /// Whether the /24 at `net` overlaps a network (address, mask).
    static func overlaps(_ net: UInt32, _ other: (address: UInt32, mask: UInt32)) -> Bool {
        let m = other.mask & 0xFFFF_FF00                    // the shorter of the two prefixes
        return net & m == other.address & m
    }

    /// The candidates free of `host` networks and of `taken`, starting at `start` and wrapping.
    static func free(host: [(address: UInt32, mask: UInt32)], taken: Set<UInt32>, start: Int) -> [UInt32] {
        let n = candidates.count
        return (0..<n).map { candidates[(start % n + $0) % n] }
            .filter { c in !taken.contains(c) && !host.contains { overlaps(c, $0) } }
    }

    static func cidr(_ net: UInt32) -> String { "\(net >> 24).\((net >> 16) & 0xFF).\((net >> 8) & 0xFF).0/24" }

    static func network(of subnet: String) -> UInt32? {
        let parts = subnet.split(separator: "/").first?.split(separator: ".").compactMap { UInt32($0) } ?? []
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return nil }
        return (parts[0] << 24 | parts[1] << 16 | parts[2] << 8) & 0xFFFF_FF00
    }

    /// Note that this process uses `subnet` (an explicit or persisted one it created a network on).
    static func reserve(_ subnet: String) {
        guard let n = network(of: subnet) else { return }
        lock.lock(); held[n, default: 0] += 1; lock.unlock()
    }

    static func release(_ subnet: String) {
        guard let n = network(of: subnet) else { return }
        lock.lock()
        if let c = held[n] { held[n] = c > 1 ? c - 1 : nil }
        lock.unlock()
    }

    static var reserved: Set<UInt32> { lock.lock(); defer { lock.unlock() }; return Set(held.keys) }

    /// A vmnet network on a free subnet, reserved for this process (release it with `release`).
    static func makeNetwork() throws -> VmnetNetwork {
        let order = free(host: hostNetworks(), taken: reserved, start: Int.random(in: 0..<candidates.count))
        var lastError: Error?
        for net in order {
            lock.lock()
            if held[net] != nil { lock.unlock(); continue }
            held[net] = 1
            lock.unlock()
            do { return try VmnetNetwork(subnet: try CIDRv4(cidr(net))) } catch {
                release(cidr(net))
                lastError = error
            }
        }
        throw lastError ?? SandboxError.invalidSpec("no free vmnet subnet in 192.168.\(first)–\(last).0/24")
    }
}
