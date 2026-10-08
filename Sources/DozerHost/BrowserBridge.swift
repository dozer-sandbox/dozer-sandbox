import Darwin
import Foundation
import DozerKit

// 599 (594.B2, owner: "add the browser open and port forward bridge … its use-case is to pass through
// browser based oauth logins that the agent TUI initiates"): the host half. The guest's xdg-open shim
// hands a URL over the session's terminal (OSC 6340, taken out by `SessionBridgeScanner`); here the
// URL is checked, opened in the Mac's default browser, and — when it is a sign-in whose redirect is a
// localhost callback — the Mac's `localhost:PORT` is forwarded into the sandbox's for the sign-in's
// duration, so the browser's final redirect reaches the agent's listener. DeckStack's technique and
// its fail-closed parse (`RemoteSandboxOAuthCallbackPort`), re-done here without depending on it.

public enum BrowserBridge {
    /// How long a sign-in's callback is forwarded at most.
    public static let forwardSeconds: TimeInterval = 600
    /// After the first callback has been answered, the forward stays this long (a favicon, a redirect).
    public static let graceSeconds: TimeInterval = 3

    public enum Check: Equatable, Sendable {
        case open(URL)
        case refused(String)
    }

    /// Only http and https, with a host, and not the Mac's own loopback (the sandbox's localhost is not
    /// the Mac's: `http://localhost:3000` from inside is the SANDBOX's server — opening it on the Mac
    /// would reach whatever runs there instead).
    public static func check(_ raw: String) -> Check {
        guard raw.utf8.count <= SessionBridgeScanner.maximumURLBytes,
              !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              let c = URLComponents(string: raw), let scheme = c.scheme?.lowercased() else {
            return .refused("not a URL")
        }
        guard scheme == "http" || scheme == "https" else { return .refused("only http and https URLs are opened (not \(scheme):)") }
        guard let host = c.host?.lowercased(), !host.isEmpty, let url = URL(string: raw) else { return .refused("a URL without a host") }
        if isLoopback(host) {
            return .refused("\(host) is the sandbox's own machine — the Mac's browser cannot reach it there")
        }
        return .open(url)
    }

    static func isLoopback(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "localhost" || h.hasSuffix(".localhost") || h == "0.0.0.0" || h == "::1" || h == "::"
            || h.hasPrefix("127.") || h == "0:0:0:0:0:0:0:1"
    }

    /// The loopback callback a sign-in URL asks the browser to be sent to (DeckStack's fail-closed rules):
    /// read ONLY from `redirect_uri`; its scheme http; its host exactly `localhost` or `127.0.0.1`; an
    /// explicit port 1024–65535. Anything else: nil (nothing is forwarded).
    public static func callback(in url: URL) -> (host: String, port: Int, path: String)? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "redirect_uri" })?.value, !raw.isEmpty,
              let r = URLComponents(string: raw), r.scheme?.lowercased() == "http",
              let host = r.host?.lowercased(), host == "localhost" || host == "127.0.0.1",
              let port = r.port, (1024...65_535).contains(port) else { return nil }
        return (host, port, r.path.isEmpty ? "/" : r.path)
    }

    /// What a notice shows of a URL: scheme, host and path (never the query — a sign-in's state).
    public static func shown(_ url: URL) -> String {
        var s = "\(url.scheme ?? "https")://\(url.host ?? "")"
        if let p = url.port { s += ":\(p)" }
        let path = url.path
        if !path.isEmpty && path != "/" { s += path }
        return s.count > 80 ? String(s.prefix(79)) + "…" : s
    }

    /// Open `url` in the Mac's default browser — or, in tests (`DOZ_TEST_OPEN_URL=<file>`), append it to
    /// that file instead and, as a browser would after the sign-in, GET the callback on the Mac's
    /// `localhost:PORT` (its answer appended too). Never a real browser tab from a test.
    public static func open(_ url: URL, callback: (host: String, port: Int, path: String)?,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let seam = environment["DOZ_TEST_OPEN_URL"], !seam.isEmpty {
            append(seam, "open \(url.absoluteString)\n")
            if let cb = callback {
                let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
                Thread.detachNewThread {
                    usleep(300_000)
                    let got = get(port: cb.port, path: "\(cb.path)?code=doz-test-code&state=\(state)")
                    append(seam, "callback \(cb.port) \(got)\n")
                }
            }
            return true
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [url.absoluteString]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// The opener seam's file (599b: the file bridge records there too).
    static func append(_ path: String, _ line: String) {
        let lock = seamLock
        lock.lock(); defer { lock.unlock() }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }
    private static let seamLock = NSLock()

    /// A plain HTTP/1.0 GET on 127.0.0.1:port (the test seam's browser): the status line and body, one line.
    public static func get(port: Int, path: String) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return "no socket" }
        defer { close(fd) }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var a = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                            sin_port: in_port_t(UInt16(port).bigEndian), sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { return "refused" }
        _ = UnixSocket.writeAll(fd, Data("GET \(path) HTTP/1.0\r\nHost: localhost:\(port)\r\n\r\n".utf8))
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while out.count < 65536 {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return String(decoding: out, as: UTF8.self).replacingOccurrences(of: "\r\n", with: " | ").replacingOccurrences(of: "\n", with: " | ")
    }
}

/// One sign-in's callback: the Mac's loopback `port` (127.0.0.1, and [::1] when free) relayed into the
/// sandbox's `localhost:port`, each connection through a guest `deckhold connect -p port`. Ends after
/// `BrowserBridge.forwardSeconds`, `graceSeconds` after the first answered callback, or `stop()`.
final class LoopbackForward: @unchecked Sendable {
    let sandbox: String
    let port: Int
    private let openStream: @Sendable () async throws -> GuestStream
    private let onEnd: @Sendable (LoopbackForward, String) -> Void
    private var fds: [Int32] = []
    private let lock = NSLock()
    private var stopped = false
    private var answered = false
    private var deadline: Date

    /// Binds now (throws when the Mac's port is taken); `start()` accepts.
    init(sandbox: String, port: Int, openStream: @escaping @Sendable () async throws -> GuestStream,
         onEnd: @escaping @Sendable (LoopbackForward, String) -> Void) throws {
        self.sandbox = sandbox
        self.port = port
        self.openStream = openStream
        self.onEnd = onEnd
        deadline = Date().addingTimeInterval(BrowserBridge.forwardSeconds)
        guard let v4 = Self.listen(v6: false, port: port) else {
            throw HostError(.unavailable, "localhost:\(port) is in use on this Mac")
        }
        fds = [v4]
        if let v6 = Self.listen(v6: true, port: port) { fds.append(v6) }       // best effort: a browser may try ::1 first
    }

    private static func listen(v6: Bool, port: Int) -> Int32? {
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
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
        guard bound == 0, Darwin.listen(fd, 8) == 0 else { close(fd); return nil }
        return fd
    }

    func start() {
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    func stop(_ why: String = "stopped") {
        let fds: [Int32] = lock.withLock {
            guard !stopped else { return [] }
            stopped = true
            let f = self.fds
            self.fds = []
            return f
        }
        guard !fds.isEmpty else { return }
        for fd in fds { close(fd) }
        onEnd(self, why)
    }

    private func acceptLoop() {
        while true {
            let (fds, until, done): ([Int32], Date, Bool) = lock.withLock { (self.fds, deadline, stopped) }
            if done || fds.isEmpty { return }
            if Date() >= until {
                stop(lock.withLock { answered } ? "the sign-in's callback was answered" : "\(Int(BrowserBridge.forwardSeconds / 60)) minutes passed")
                return
            }
            var p = fds.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let n = poll(&p, nfds_t(p.count), 250)
            if n <= 0 { continue }
            for x in p where x.revents & Int16(POLLIN) != 0 {
                let c = accept(x.fd, nil, nil)
                if c >= 0 { relay(c) }
            }
        }
    }

    /// One connection from the Mac's browser → a guest `deckhold connect`, both ways.
    private func relay(_ c: Int32) {
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let open = openStream
        Task.detached { [self] in
            let stream: GuestStream
            do { stream = try await open() } catch { close(c); return }
            // Mac → guest, on a thread of its own (blocking reads).
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 16384)
                while true {
                    let n = read(c, &buf, buf.count)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    stream.send(Data(buf[0..<n]))
                }
                stream.finishInput()
            }
            var sent = 0
            for await d in stream.output {
                if !UnixSocket.writeAll(c, d) { break }
                sent += d.count
            }
            shutdown(c, SHUT_RDWR)
            close(c)
            // The first answered callback ends the forward shortly after (the sign-in is done).
            if sent > 0 {
                lock.withLock {
                    if !answered {
                        answered = true
                        deadline = min(deadline, Date().addingTimeInterval(BrowserBridge.graceSeconds))
                    }
                }
            }
        }
    }
}
