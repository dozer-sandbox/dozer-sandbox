import Darwin
import Foundation
import DozerKit

// 617 (RP-1): standing web-port forwards — the host half (`DozerKit/PortForwarding.swift` says what a forward is).
// One `StandingForward` per (sandbox, guest port) while the sandbox runs: a listener on the Mac's 127.0.0.1 (and [::1]
// when the same port is free there), each accepted connection relayed through a guest `deckhold connect -p PORT`.

final class StandingForward: @unchecked Sendable {
    let sandbox: String
    let guestPort: Int
    /// The Mac port it listens on.
    let macPort: Int
    private let openStream: @Sendable () async throws -> GuestStream
    private var fds: [Int32] = []
    private let lock = NSLock()
    private var stopped = false
    private(set) var connections = 0

    /// Binds now, trying `candidates` in order (0: a free port the system picks); throws when none could be bound.
    init(sandbox: String, guestPort: Int, candidates: [Int], openStream: @escaping @Sendable () async throws -> GuestStream) throws {
        self.sandbox = sandbox
        self.guestPort = guestPort
        self.openStream = openStream
        var bound: (Int32, Int)?
        // A port this forward itself held a moment ago (a sleep then a wake within a second) may still be on its way
        // out: a fixed port is tried a few times before the next candidate.
        outer: for c in candidates {
            for attempt in 0..<(c == 0 ? 1 : 3) {
                if attempt > 0 { usleep(150_000) }
                if let b = Self.listen(v6: false, port: c) { bound = b; break outer }
            }
        }
        guard let (v4, port) = bound else {
            throw HostError(.unavailable, "no port on this Mac's loopback could be bound for \(sandbox):\(guestPort)")
        }
        macPort = port
        fds = [v4]
        if let (v6, _) = Self.listen(v6: true, port: port) { fds.append(v6) }    // best effort: a browser may try ::1 first
    }

    /// A listening socket on the loopback (127.0.0.1 or ::1) at `port` (0: any free one), and the port it got.
    static func listen(v6: Bool, port: Int) -> (Int32, Int)? {
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        // SO_REUSEADDR lets a port whose last connections are in TIME_WAIT (this forward's own, before a sleep) be bound
        // again at once. It would also let a specific address share a port another program holds on the wildcard — so a
        // port something already answers on is refused first (`answers`), never shared.
        if port != 0, answers(v6: v6, port: port) { close(fd); return nil }
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bound: Int32
        if v6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = in_port_t(UInt16(port).bigEndian)
            a.sin6_addr = in6addr_loopback
            bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = in_port_t(UInt16(port).bigEndian)
            a.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard bound == 0, Darwin.listen(fd, 32) == 0 else { close(fd); return nil }
        var got = port
        if port == 0 {
            var a = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
            got = withUnsafePointer(to: &a) { p -> Int in
                v6 ? p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin6_port)) }
                   : p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin_port)) }
            }
        }
        guard got >= PortForwarding.lowestMacPort else { close(fd); return nil }
        return (fd, got)
    }

    /// Whether something already accepts connections on the loopback's `port`.
    static func answers(v6: Bool, port: Int) -> Bool {
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if v6 {
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = in_port_t(UInt16(port).bigEndian)
            a.sin6_addr = in6addr_loopback
            return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } } == 0
        }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = in_port_t(UInt16(port).bigEndian)
        a.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    func start() {
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    var isStopped: Bool { lock.withLock { stopped } }

    func stop() {
        let fds: [Int32] = lock.withLock {
            guard !stopped else { return [] }
            stopped = true
            let f = self.fds
            self.fds = []
            return f
        }
        // shutdown first: the accept loop's poll() returns at once, and the port is free for the next bind.
        for fd in fds { shutdown(fd, SHUT_RDWR); close(fd) }
    }

    private func acceptLoop() {
        while true {
            let (fds, done): ([Int32], Bool) = lock.withLock { (self.fds, stopped) }
            if done || fds.isEmpty { return }
            var p = fds.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let n = poll(&p, nfds_t(p.count), 250)
            if n <= 0 { continue }
            for x in p where x.revents & Int16(POLLIN) != 0 {
                let c = accept(x.fd, nil, nil)
                if c >= 0 {
                    lock.withLock { connections += 1 }
                    relay(c)
                }
            }
        }
    }

    /// One connection from the Mac → a guest `deckhold connect` to the guest's localhost:guestPort, both ways.
    private func relay(_ c: Int32) {
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let open = openStream
        Task.detached {
            let stream: GuestStream
            do { stream = try await open() } catch { close(c); return }
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = read(c, &buf, buf.count)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    stream.send(Data(buf[0..<n]))
                }
                stream.finishInput()
            }
            for await d in stream.output {
                if !UnixSocket.writeAll(c, d) { break }
            }
            shutdown(c, SHUT_RDWR)
            close(c)
        }
    }
}

/// The forwards of every sandbox, and why one could not be bound. Thread-safe.
final class PortForwardTable: @unchecked Sendable {
    private let lock = NSLock()
    private var live: [String: [Int: StandingForward]] = [:]
    private var failed: [String: [Int: String]] = [:]

    func forwards(of sandbox: String) -> [Int: StandingForward] { lock.withLock { live[sandbox] ?? [:] } }
    func failures(of sandbox: String) -> [Int: String] { lock.withLock { failed[sandbox] ?? [:] } }

    func set(_ f: StandingForward) {
        lock.withLock {
            live[f.sandbox, default: [:]][f.guestPort] = f
            failed[f.sandbox]?[f.guestPort] = nil
        }
    }
    func fail(_ sandbox: String, _ port: Int, _ why: String) { lock.withLock { failed[sandbox, default: [:]][port] = why } }

    /// Stop and forget one forward (nil: every forward of the sandbox). Returns the ones stopped.
    @discardableResult
    func remove(_ sandbox: String, port: Int? = nil) -> [StandingForward] {
        let gone: [StandingForward] = lock.withLock {
            if let port {
                failed[sandbox]?[port] = nil
                guard let f = live[sandbox]?.removeValue(forKey: port) else { return [] }
                return [f]
            }
            failed[sandbox] = nil
            return Array((live.removeValue(forKey: sandbox) ?? [:]).values)
        }
        for f in gone { f.stop() }
        return gone
    }
}
