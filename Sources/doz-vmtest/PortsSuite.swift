import Darwin
import Foundation
import DozerKit
import DozerHost

// 617 (RP-1, owner: "web port forwarding first"): a sandbox's web ports on the Mac's loopback, in a real VM. A lab
// sandbox with NO network (a forward is inbound — it needs none), a tiny HTTP server in the guest (busybox nc, looped),
// `doz ports add` / `doz open` / `doz ports rm`: the Mac's 127.0.0.1:PORT reaches it and nothing else does (not the
// Mac's LAN address); a port taken on the Mac moves (and is kept); sleep, hibernate, host stop and shutdown close every
// listener and wake/start bring them back. The opener seam (`DOZ_TEST_OPEN_URL`) stands in for the browser.
// A recipe's own port (AIChat's playground) is `make recipe-check RECIPES=aichat`'s.

func cliPortsSuite(binary: String) async {
    let t = onboardingHarness(binary, "pf", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    let opened = t.store.appendingPathComponent("opened.log")
    t.env["DOZ_TEST_OPEN_URL"] = opened.path
    defer {
        t.run(["host", "stop"])
        try? FileManager.default.removeItem(at: t.store)
    }
    func log() -> String { (try? String(contentsOf: opened, encoding: .utf8)) ?? "" }
    let base = 42000 + Int(getpid() % 2000) * 10
    let g1 = base + 1, g2 = base + 2
    func answers(_ port: Int, _ path: String = "/hello") -> String { BrowserBridge.get(port: port, path: path) }
    func ports() -> PortsAnswer? {
        let r = t.run(["ports", "pp", "--json"])
        return try? JSONDecoder().decode(PortsAnswer.self, from: Data(r.out.utf8))
    }
    func row(_ guest: Int) -> PortForwardRow? { ports()?.ports.first { $0.port == guest } }
    // The guest's server: busybox nc, one connection at a time, forever; it says which port answered.
    func serve(_ port: Int) -> Bool {
        let handler = "#!/bin/sh\nread line\nprintf 'HTTP/1.0 200 OK\\r\\nContent-Type: text/plain\\r\\n\\r\\nguest \(port) says hello\\r\\n'\n"
        let script = "printf \"$1\" > /tmp/srv\(port).sh && chmod +x /tmp/srv\(port).sh && "
            + "(setsid sh -c 'while true; do nc -l -p \(port) -e /tmp/srv\(port).sh; done' >/dev/null 2>&1 < /dev/null &) ; sleep 0.5; echo started"
        return t.run(["exec", "pp", "--", "sh", "-c", script, "srv", handler]).out.contains("started")
    }

    print("cli: web ports — doz ports, doz open, the forward's lifecycle (617, RP-1)")
    check(t.run(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    var r = t.run(["up", "pp", "--image", "lab", "--isolated", "--memory", "512M", "--network", "none", "--detach"], timeout: 600)
    check(r.code == 0, "up pp --image lab --network none --detach (exit \(r.code))")
    check(serve(g1), "a server in the guest on port \(g1)")

    // 1. Add, list, reach it.
    r = t.run(["ports", "add", "pp", String(g1), "--title", "Test page", "--path", "/hello"])
    check(r.code == 0 && r.out.contains("http://127.0.0.1:\(g1)/hello") && r.out.contains("listening"), "ports add pp \(g1): listening at http://127.0.0.1:\(g1)/hello (\(r.out.debugDescription))")
    check(row(g1)?.macPort == g1 && row(g1)?.origin == "added" && row(g1)?.moved == nil, "--json: on the same Mac port, added, not moved")
    let got = answers(g1)
    check(got.hasPrefix("HTTP/1.0 200 OK") && got.contains("guest \(g1) says hello"), "the Mac's 127.0.0.1:\(g1) reaches the guest's server (\(got.prefix(80).debugDescription))")
    if let lan = macLANAddress() { check(!tcpConnects(lan, g1), "…and the Mac's \(lan):\(g1) does not (loopback only)") }
    check(hostLog(t).contains("Test page: the sandbox's port \(g1) is at http://127.0.0.1:\(g1)/hello on this Mac"), "the host log says where it is")
    r = t.run(["inspect", "pp", "--json"])
    check(r.out.contains("\"url\" : \"http:\\/\\/127.0.0.1:\(g1)\\/hello\"") || r.out.contains("\"url\" : \"http://127.0.0.1:\(g1)/hello\""), "inspect --json carries the forward (the dashboard's Open button)")

    // 2. doz open.
    r = t.run(["open", "pp", "--print"])
    check(r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "http://127.0.0.1:\(g1)/hello", "open pp --print: the URL")
    r = t.run(["open", "pp"])
    check(r.code == 0 && log().contains("open http://127.0.0.1:\(g1)/hello\n"), "open pp: the Mac's browser opens it (the seam: \(log().suffix(80).debugDescription))")
    check(t.run(["open", "pp", "1"]).code != 0, "open pp 1: no such web port")

    // 3. A port another program holds on the Mac: moved, said, reachable, kept.
    let squatter = socket(AF_INET, SOCK_STREAM, 0)
    var a = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                        sin_port: in_port_t(UInt16(g2).bigEndian), sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
    _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(squatter, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    listen(squatter, 1)
    check(serve(g2), "a second server in the guest on \(g2)")
    r = t.run(["ports", "add", "pp", String(g2)])
    let moved = row(g2)
    check(r.code == 0 && moved?.state == "listening" && moved?.moved == true && moved?.macPort != g2, "port \(g2) is taken on the Mac: forwarded on another (\(moved?.macPort ?? 0)), and said moved")
    let m2 = moved?.macPort ?? 0
    check(answers(m2, "/").contains("guest \(g2) says hello"), "the moved port reaches the guest's \(g2)")
    check(hostLog(t).contains("(\(g2) was in use)"), "the host log says the port moved")
    close(squatter)

    // 4. Sleep closes every listener; wake brings them back (on the same Mac ports).
    check(t.run(["sleep", "pp"], timeout: 120).code == 0, "sleep pp")
    check(answers(g1) == "refused" && answers(m2, "/") == "refused", "asleep: both Mac ports are closed")
    check(row(g1)?.state == "stopped", "doz ports: stopped while asleep")
    check(t.run(["wake", "pp"], timeout: 120).code == 0, "wake pp")
    check(waitUntil(10) { answers(g1).contains("guest \(g1) says hello") }, "awake: \(g1) answers again")
    check(row(g2)?.macPort == m2 && answers(m2, "/").contains("guest \(g2)"), "the moved port kept its Mac port (\(m2)) across the sleep")

    // 5. Hibernate, and the host stopping (which hibernates it): closed, then back after the wake.
    check(t.run(["hibernate", "pp"], timeout: 120).code == 0, "hibernate pp")
    check(answers(g1) == "refused", "hibernated: closed")
    check(t.run(["wake", "pp"], timeout: 120).code == 0 && waitUntil(10) { answers(g1).contains("says hello") }, "wake: back")
    check(t.run(["host", "stop"], timeout: 120).code == 0, "host stop (it hibernates pp)")
    check(answers(g1) == "refused", "no host: closed")
    check(t.run(["wake", "pp"], timeout: 120).code == 0 && waitUntil(10) { answers(g1).contains("says hello") }, "a new host, wake: back (the record kept the forwards)")

    // 6. Shut down: closed; started: listening again (the guest's server is gone, so no answer — but the forward is there).
    check(t.run(["shutdown", "pp", "--yes"], timeout: 120).code == 0, "shutdown pp")
    check(answers(g1) == "refused", "off: closed")
    check(t.run(["start", "pp"], timeout: 300).code == 0 && waitUntil(10) { row(g1)?.state == "listening" }, "start pp: listening again")
    check(answers(g1) != "refused" && !answers(g1).contains("says hello"), "…with nothing behind it in a fresh boot (the connection is accepted, then closed)")

    // 7. Remove: no longer forwarded, and not listening.
    r = t.run(["ports", "rm", "pp", String(g1)])
    check(r.code == 0 && r.out.contains("no longer forwarded") && row(g1) == nil, "ports rm pp \(g1)")
    check(answers(g1) == "refused", "…its Mac port is closed")
    check(t.run(["ports", "rm", "pp", String(g1)]).code != 0, "removing it again: not found")
    check(t.run(["ports", "add", "pp", "0"]).code != 0 && t.run(["ports", "add", "pp", "80", "--path", "no-slash"]).code != 0, "a bad port or path is refused")
    check(t.run(["rm", "pp", "--yes"], timeout: 120).code == 0, "rm pp")
    check(answers(m2, "/") == "refused", "a removed sandbox's forwards are closed")
}

/// Wait up to `seconds` for `ok`.
func waitUntil(_ seconds: Double, _ ok: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if ok() { return true }; usleep(250_000) }
    return ok()
}

/// This Mac's first non-loopback IPv4 address (nil: none).
func macLANAddress() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { String(cString: inet_ntoa($0.pointee.sin_addr)) }
        if !ip.hasPrefix("127.") { return ip }
    }
    return nil
}

/// Whether a TCP connection to ip:port is accepted.
func tcpConnects(_ ip: String, _ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var a = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                        sin_port: in_port_t(UInt16(port).bigEndian), sin_addr: in_addr(s_addr: inet_addr(ip)), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
    return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
}
