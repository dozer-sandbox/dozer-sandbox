import Darwin
import XCTest
@testable import DozerHost
@testable import DozerKit

/// 617 (RP-1): web-port forwards — the Mac port choice, the loopback-only listener, the relay through a guest stream,
/// a collision moving the port, stop closing it, the recipe format's validation and the wire shapes.
final class PortForwardTests: XCTestCase {
    /// Whether a program in the sandbox listens on a port: the guest's /proc/net/tcp and tcp6, LISTEN (0A) rows only —
    /// an established connection or a port only the Mac forwards is not "serving".
    func testServingIsReadFromTheGuestsListeningSockets() {
        let text = """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 0100007F:1F40 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1001        0 1 1 0000000000000000 100 0 0 10 0
           1: 0100007F:1F90 0100007F:D431 01 00000000:00000000 00:00000000 00000000  1001        0 2 1 0000000000000000 20 4 30 10 -1
          sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000000000000000000000000000:0BB8 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1001        0 3 1
        """
        XCTAssertEqual(HostCore.listeningPorts(procNetTCP: text), [8000, 3000], "8080 only has an established connection")
        XCTAssertEqual(HostCore.listeningPorts(procNetTCP: ""), [])
        // The row says it, and the page's projection carries it with the recipe's command.
        var row = PortForwardRow(port: 8080, title: "Fabric REST API", path: "/swagger/index.html", protocol: "http", origin: "recipe",
                                 state: "listening", macPort: 8080, url: "http://127.0.0.1:8080/swagger/index.html")
        row.serving = false
        row.serveHint = "fabric --serve"
        let json = String(decoding: try! JSONEncoder().encode(row), as: UTF8.self)
        XCTAssertTrue(json.contains("\"serving\":false") && json.contains("\"serve_hint\":\"fabric --serve\""), json)
    }

    func testTheMacPortIsTheOneItHadThenTheGuestsThenAnyFreeOne() {
        XCTAssertEqual(PortForwarding.macPortCandidates(guest: 8080, previous: nil), [8080, 0])
        XCTAssertEqual(PortForwarding.macPortCandidates(guest: 8080, previous: 50123), [50123, 8080, 0])
        XCTAssertEqual(PortForwarding.macPortCandidates(guest: 8080, previous: 8080), [8080, 0])
        // A privileged guest port is never bound on the Mac.
        XCTAssertEqual(PortForwarding.macPortCandidates(guest: 80, previous: nil), [0])
        XCTAssertEqual(PortForwarding.macPortCandidates(guest: 80, previous: 443), [0])
    }

    func testPathsAndURLs() {
        XCTAssertTrue(PortForwarding.isPath("/"))
        XCTAssertTrue(PortForwarding.isPath("/playground?x=1"))
        XCTAssertFalse(PortForwarding.isPath("playground"))
        XCTAssertFalse(PortForwarding.isPath("/a b"))
        XCTAssertFalse(PortForwarding.isPath("/a\nb"))
        XCTAssertEqual(PortForwarding.url(macPort: 8000, path: "/playground"), "http://127.0.0.1:8000/playground")
        XCTAssertEqual(PortForwarding.url(macPort: 8000, path: nil), "http://127.0.0.1:8000/")
        XCTAssertEqual(PortForwarding.url(macPort: 8000, path: "evil.example/"), "http://127.0.0.1:8000/")
    }

    /// The forward listens on 127.0.0.1 only, relays a connection both ways through the guest stream, and stop closes it.
    func testItRelaysOnTheLoopbackAndStopClosesIt() throws {
        let f = try StandingForward(sandbox: "box", guestPort: 8000, candidates: [0], openStream: {
            GuestStream.inMemory { _ in Data("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8) }
        })
        f.start()
        XCTAssertGreaterThanOrEqual(f.macPort, PortForwarding.lowestMacPort)
        XCTAssertTrue(Self.connects("127.0.0.1", f.macPort))
        if let lan = Self.lanAddress() { XCTAssertFalse(Self.connects(lan, f.macPort), "loopback only — never the Mac's \(lan)") }
        let got = BrowserBridge.get(port: f.macPort, path: "/")
        XCTAssertTrue(got.hasPrefix("HTTP/1.0 200 OK"), got)
        XCTAssertTrue(got.hasSuffix("ok"), got)
        f.stop()
        XCTAssertTrue(f.isStopped)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(BrowserBridge.get(port: f.macPort, path: "/"), "refused")
    }

    /// A Mac port another program holds is never shared: the next candidate (a free port) is taken.
    func testATakenPortMovesToAFreeOne() throws {
        guard let (held, port) = StandingForward.listen(v6: false, port: 0) else { return XCTFail("no port") }
        defer { close(held) }
        let f = try StandingForward(sandbox: "box", guestPort: port, candidates: PortForwarding.macPortCandidates(guest: port, previous: nil),
                                    openStream: { GuestStream.inMemory { $0 } })
        defer { f.stop() }
        XCTAssertNotEqual(f.macPort, port)
        // And with no candidate left, it says so.
        XCTAssertThrowsError(try StandingForward(sandbox: "box", guestPort: port, candidates: [port], openStream: { GuestStream.inMemory { $0 } }))
    }

    func testTheTableForgetsOneOrAll() throws {
        let t = PortForwardTable()
        let a = try StandingForward(sandbox: "box", guestPort: 1, candidates: [0], openStream: { GuestStream.inMemory { $0 } })
        let b = try StandingForward(sandbox: "box", guestPort: 2, candidates: [0], openStream: { GuestStream.inMemory { $0 } })
        t.set(a); t.set(b)
        t.fail("box", 3, "no port")
        XCTAssertEqual(Set(t.forwards(of: "box").keys), [1, 2])
        XCTAssertEqual(t.failures(of: "box")[3], "no port")
        XCTAssertEqual(t.remove("box", port: 1).count, 1)
        XCTAssertTrue(a.isStopped)
        XCTAssertEqual(t.remove("box").count, 1)
        XCTAssertTrue(b.isStopped)
        XCTAssertTrue(t.forwards(of: "box").isEmpty)
        XCTAssertTrue(t.failures(of: "box").isEmpty)
    }

    func testARecipesPortsAreValidated() throws {
        guard var r = AgentRecipes.recipe("aichat") else { return XCTFail("aichat") }
        XCTAssertEqual(r.ports?.ports.first?.port, 8000)
        XCTAssertEqual(r.ports?.serve, ["aichat", "--serve"])
        XCTAssertNoThrow(try r.validate())
        func bad(_ p: AgentRecipe.WebPorts, _ why: String) {
            r.ports = p
            XCTAssertThrowsError(try r.validate(), why)
        }
        bad(.init(ports: []), "none")
        bad(.init(ports: [.init(port: 0, title: "x")]), "port 0")
        bad(.init(ports: [.init(port: 70_000, title: "x")]), "too big")
        bad(.init(ports: [.init(port: 80, title: "x"), .init(port: 80, title: "y")]), "twice")
        bad(.init(ports: [.init(port: 80, title: "")]), "no title")
        bad(.init(ports: [.init(port: 80, title: "x", protocol: "ftp")]), "protocol")
        bad(.init(ports: [.init(port: 80, title: "x", auth: "token")]), "token with no hint")
        bad(.init(ports: [.init(port: 80, title: "x", path: "nopath")]), "path")
        bad(.init(ports: [.init(port: 80, title: "x")], serve: []), "empty serve")
        bad(.init(ports: (1...17).map { .init(port: $0, title: "p\($0)") }), "too many")
    }

    func testTheWireShapes() throws {
        let row = PortForwardRow(port: 8000, title: "AIChat web", path: "/playground", protocol: "http", origin: "recipe", state: "listening",
                                 macPort: 64000, url: "http://127.0.0.1:64000/playground", moved: true)
        let json = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
        XCTAssertTrue(json.contains("\"mac_port\":64000"), json)
        XCTAssertEqual(try JSONDecoder().decode(PortForwardRow.self, from: Data(json.utf8)), row)
        var r = HostRequest(.ports, name: "box")
        r.portAdd = PortForwardEntry(port: 3000, title: "dev", path: "/")
        let back = try HostWire.decoder.decode(HostRequest.self, from: try HostWire.encoder.encode(r))
        XCTAssertEqual(back.portAdd, r.portAdd)
        XCTAssertEqual(HostOp.ports.rawValue, "ports")
        XCTAssertFalse(HostOp.ports.isReadOnly, "the listeners live in the host")
    }

    /// This Mac's first non-loopback IPv4 address (nil: none), to show a forward is not reachable on it.
    static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let a = p.pointee.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let ip = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { String(cString: inet_ntoa($0.pointee.sin_addr)) }
            if !ip.hasPrefix("127.") { return ip }
        }
        return nil
    }

    /// Whether a TCP connection to ip:port is accepted.
    static func connects(_ ip: String, _ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var a = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                            sin_port: in_port_t(UInt16(port).bigEndian), sin_addr: in_addr(s_addr: inet_addr(ip)), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }
}
