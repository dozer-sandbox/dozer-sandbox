import Foundation
import DozerHost
import XCTest
@testable import DozerWeb

/// 606 — `doz serve`'s rules as pure functions: which addresses are served, which peers are dropped (every sandbox
/// network), what a request's own origin is (X-Forwarded-* only from a trusted proxy) and whether it is allowed.
final class ServeRulesTests: XCTestCase {
    func ip(_ s: String) -> WebIP { WebIP(s)! }
    func iface(_ name: String, _ a: String, _ p: Int) -> WebInterfaceAddress { WebInterfaceAddress(name: name, address: ip(a), prefix: p) }

    /// m1max as measured (606 nat-source.md): two LAN interfaces, Tailscale, a vmnet bridge, another VPN, loopback.
    lazy var mac: [WebInterfaceAddress] = [
        iface("lo0", "127.0.0.1", 8), iface("lo0", "::1", 128),
        iface("en0", "192.168.86.65", 24), iface("en0", "fe80::1c2b:3a4d:5e6f:7081", 64), iface("en0", "fd53:3f5a:6290:d699::65", 64),
        iface("en1", "192.168.86.74", 24),
        iface("utun4", "100.124.200.51", 32), iface("utun4", "fd7a:115c:a1e0::7c3b:c833", 128),
        iface("utun7", "10.8.0.2", 24),                               // another VPN
        iface("bridge0", "169.254.10.1", 16),                         // Thunderbolt Bridge, self-assigned
        iface("bridge100", "192.168.112.1", 24), iface("bridge100", "fd9c:1:2:3::1", 64), iface("bridge100", "fe80::bb:1", 64),
    ]

    func testAddresses() {
        XCTAssertEqual(ip("::ffff:192.168.112.2"), ip("192.168.112.2"), "an IPv4-mapped peer is its IPv4 address")
        XCTAssertEqual(ip("[::1]").description, "::1")
        XCTAssertEqual(ip("fe80::1%en0"), ip("fe80::1"))
        XCTAssertNil(WebIP("m1max.local"))
        XCTAssertNil(WebIP("300.1.1.1"))
        XCTAssertTrue(ip("127.0.0.5").isLoopback)
        XCTAssertTrue(ip("fe80::5").isLinkLocal)
        XCTAssertEqual(ip("fd7a:115c:a1e0::1").urlHost, "[fd7a:115c:a1e0::1]")
        XCTAssertTrue(WebCIDR("192.168.112.0/24")!.contains(ip("192.168.112.250")))
        XCTAssertFalse(WebCIDR("192.168.112.0/24")!.contains(ip("192.168.113.1")))
        XCTAssertTrue(WebCIDR("100.64.0.0/10")!.contains(ip("100.124.200.51")))
        XCTAssertTrue(WebCIDR("fd7a:115c:a1e0::/48")!.contains(ip("fd7a:115c:a1e0::7c3b:c833")))
        XCTAssertFalse(WebCIDR("10.0.0.0/8")!.contains(ip("fd00::1")), "families never match")
        XCTAssertTrue(WebCIDR("10.0.0.5")!.contains(ip("10.0.0.5")))
        XCTAssertFalse(WebCIDR("10.0.0.5")!.contains(ip("10.0.0.6")))
        XCTAssertNil(WebCIDR("10.0.0.0/33"))
    }

    func testWhichInterfacesAreServed() {
        let served = Set(mac.filter(WebServeRules.isServed).map(\.address.description))
        XCTAssertEqual(served, ["192.168.86.65", "fe80::1c2b:3a4d:5e6f:7081", "fd53:3f5a:6290:d699::65", "192.168.86.74", "100.124.200.51",
                                "fd7a:115c:a1e0::7c3b:c833", "169.254.10.1"],
                       "LAN interfaces' link-local addresses too (mDNS answers <mac>.local with them)")
        XCTAssertTrue(WebServeRules.isSandboxBridge("bridge100"))
        XCTAssertTrue(WebServeRules.isSandboxBridge("bridge131"))
        XCTAssertFalse(WebServeRules.isSandboxBridge("bridge0"))
        XCTAssertFalse(WebServeRules.isSandboxBridge("bridgeX"))
    }

    func testSandboxNetworks() {
        let nets = WebServeRules.sandboxNetworks(mac)
        XCTAssertTrue(nets.contains { $0.contains(ip("192.168.112.2")) }, "the running bridge's subnet")
        XCTAssertTrue(nets.contains { $0.contains(ip("fd9c:1:2:3::9")) }, "the bridge's IPv6 network")
        XCTAssertTrue(nets.contains { $0.contains(ip("192.168.150.7")) }, "Dozer's automatic NAT range, even with no VM running")
        XCTAssertFalse(nets.contains { $0.contains(ip("192.168.86.48")) }, "the LAN is not a sandbox network")
        // A home LAN inside 192.168.100–199 stays a LAN.
        let home = [iface("en0", "192.168.150.10", 24)]
        XCTAssertFalse(WebServeRules.sandboxNetworks(home).contains { $0.contains(ip("192.168.150.20")) })
        XCTAssertTrue(WebServeRules.sandboxNetworks(home, natSubnet: "10.77.0.0/16").contains { $0.contains(ip("10.77.3.4")) }, "defaults.nat_subnet")
    }

    func testTheAcceptGate() {
        func admit(_ peer: String, _ local: String, _ bind: WebServeBind = .lan) -> WebServeRules.Drop? {
            WebServeRules.admit(peer: ip(peer), local: ip(local), bind: bind, interfaces: mac)
        }
        // From the LAN, to a LAN or Tailscale address: served.
        XCTAssertNil(admit("192.168.86.48", "192.168.86.65"))
        XCTAssertNil(admit("::ffff:192.168.86.48", "::ffff:192.168.86.74"))
        XCTAssertNil(admit("100.101.102.103", "100.124.200.51"))
        // A NAT sandbox (measured: it arrives with its own address) — to any of the Mac's addresses: dropped.
        for local in ["192.168.86.65", "192.168.86.74", "100.124.200.51", "192.168.112.1", "::ffff:192.168.86.65"] {
            XCTAssertEqual(admit("::ffff:192.168.112.2", local), .sandbox, local)
        }
        XCTAssertEqual(admit("192.168.177.2", "192.168.86.65"), .sandbox, "the NAT range with no bridge up yet")
        XCTAssertEqual(admit("fd9c:1:2:3::2", "fd53:3f5a:6290:d699::65"), .sandbox)
        // Reaching the bridge's own address from anywhere: dropped.
        XCTAssertEqual(admit("192.168.86.48", "192.168.112.1"), .sandbox)
        // The Mac's own browser over loopback (rc.1: <mac>.local resolved to ::1 on the Mac): served — the same invite rules.
        XCTAssertNil(admit("127.0.0.1", "127.0.0.1"))
        XCTAssertNil(admit("::1", "::1"))
        // Not served (and answered over HTTP with why): another VPN.
        XCTAssertEqual(admit("10.8.0.9", "10.8.0.2"), .notServed)
        // Link-local on a LAN interface (another Mac reaching <mac>.local over fe80::): served — and a link-local peer is
        // never mistaken for a sandbox (fe80::/64 is every interface's).
        XCTAssertNil(admit("fe80::aa:48", "fe80::1c2b:3a4d:5e6f:7081"))
        XCTAssertNil(admit("169.254.10.2", "169.254.10.1"))
        // The bridge's own link-local address — the only one a guest can reach over link-local: dropped.
        XCTAssertEqual(admit("fe80::bb:2", "fe80::bb:1"), .sandbox)
        // bind = loopback (a proxy on this Mac): loopback only.
        XCTAssertNil(admit("127.0.0.1", "127.0.0.1", .loopback))
        XCTAssertEqual(admit("192.168.86.48", "192.168.86.65", .loopback), .notServed)
        // bind = addresses: those only; a sandbox still never.
        XCTAssertNil(admit("192.168.86.48", "192.168.86.65", .addresses([ip("192.168.86.65")])))
        XCTAssertEqual(admit("192.168.86.48", "192.168.86.74", .addresses([ip("192.168.86.65")])), .notServed)
        XCTAssertEqual(admit("192.168.112.2", "192.168.86.65", .addresses([ip("192.168.86.65")])), .sandbox)
    }

    let names = WebMacNames(localHostName: "m1max", hostName: "m1max.lan")

    func testDirectOrigins() {
        let d = WebServeRules.directOrigins(port: 7443, bind: .lan, interfaces: mac, names: names)
        XCTAssertTrue(d.isSuperset(of: ["http://m1max.local:7443", "http://m1max.lan:7443", "http://192.168.86.65:7443", "http://100.124.200.51:7443",
                                        "http://[fd7a:115c:a1e0::7c3b:c833]:7443"]))
        XCTAssertFalse(d.contains("http://192.168.112.1:7443"), "never the bridge")
        XCTAssertTrue(d.isSuperset(of: ["http://127.0.0.1:7443", "http://[::1]:7443", "http://localhost:7443"]), "the Mac's own browser")
        XCTAssertFalse(d.contains("http://10.8.0.2:7443"))
        XCTAssertFalse(d.contains { $0.contains("fe80") || $0.contains("169.254") }, "a link-local address is never a Host literal")
        let lo = WebServeRules.directOrigins(port: 7443, bind: .loopback, interfaces: mac, names: names)
        XCTAssertEqual(lo, ["http://127.0.0.1:7443", "http://[::1]:7443", "http://localhost:7443"])
        XCTAssertEqual(WebMacNames(localHostName: "m1max.local", hostName: "192.168.1.5").names, ["m1max.local"], "an address is not a name")
    }

    func origin(_ host: String?, proto: String? = nil, fhost: String? = nil, xff: String? = nil, peer: String = "192.168.86.48",
                config: WebServeConfig = WebServeConfig()) -> WebServeRules.RequestOrigin {
        WebServeRules.requestOrigin(hostHeader: host, forwardedProto: proto, forwardedHost: fhost, forwardedFor: xff, peer: ip(peer), config: config,
                                    direct: WebServeRules.directOrigins(port: 7443, bind: config.bind, interfaces: mac, names: names))
    }

    func testTheRequestsOwnOriginDirectly() {
        XCTAssertEqual(origin("m1max.local:7443").origin, "http://m1max.local:7443")
        XCTAssertEqual(origin("M1MAX.LOCAL:7443").origin, "http://m1max.local:7443", "a name in any case")
        XCTAssertEqual(origin("192.168.86.65:7443").origin, "http://192.168.86.65:7443")
        XCTAssertEqual(origin("[fd7a:115c:a1e0::7c3b:c833]:7443").origin, "http://[fd7a:115c:a1e0::7c3b:c833]:7443")
        // DNS rebinding: another name pointed at the Mac — refused by name.
        XCTAssertNil(origin("evil.example:7443").origin)
        XCTAssertNil(origin("m1max.local").origin, "the port is part of the origin")
        XCTAssertNil(origin("m1max.local:7444").origin)
        XCTAssertNil(origin(nil).origin, "no (or a repeated) Host")
        XCTAssertNil(origin("192.168.112.1:7443").origin, "the bridge's address is not a name of this server")
        XCTAssertFalse(origin("m1max.local:7443").secure)
        XCTAssertEqual(origin("m1max.local:7443", peer: "192.168.86.48").client, "192.168.86.48")
    }

    func testForwardedHeadersOnlyFromATrustedProxy() {
        let proxied = WebServeConfig(bind: .loopback, publicOrigins: [WebPublicOrigin("https://doz.home.example")!],
                                     trustedProxies: [WebCIDR("127.0.0.1")!, WebCIDR("::1")!])
        // The proxy on this Mac, https outside: the public origin, secure.
        var r = origin("127.0.0.1:7443", proto: "https", fhost: "doz.home.example", xff: "203.0.113.9, 192.168.86.48", peer: "127.0.0.1", config: proxied)
        XCTAssertEqual(r.origin, "https://doz.home.example")
        XCTAssertTrue(r.secure)
        XCTAssertTrue(r.viaProxy)
        XCTAssertEqual(r.client, "192.168.86.48", "the rightmost hop that is not a proxy")
        // The proxy passes the Host itself (Caddy, Traefik) instead of X-Forwarded-Host; a default port in it is dropped.
        r = origin("doz.home.example:443", proto: "https", peer: "127.0.0.1", config: proxied)
        XCTAssertEqual(r.origin, "https://doz.home.example")
        // A proto list (a chain): the first is what the browser used.
        r = origin("doz.home.example", proto: "https, http", peer: "127.0.0.1", config: proxied)
        XCTAssertEqual(r.origin, "https://doz.home.example")
        XCTAssertNil(origin("doz.home.example", proto: "gopher", peer: "127.0.0.1", config: proxied).origin)
        // Traefik says wss on a WebSocket upgrade (the terminal socket): the page's origin is https.
        XCTAssertEqual(origin("doz.home.example", proto: "wss", peer: "127.0.0.1", config: proxied).origin, "https://doz.home.example")
        XCTAssertTrue(origin("doz.home.example", proto: "wss", peer: "127.0.0.1", config: proxied).secure)
        // The same headers from anyone else: ignored — and the public origin is never allowed without a trusted proxy.
        let lan = WebServeConfig(publicOrigins: [WebPublicOrigin("https://doz.home.example")!], trustedProxies: [WebCIDR("127.0.0.1")!])
        r = origin("m1max.local:7443", proto: "https", fhost: "doz.home.example", xff: "1.2.3.4", peer: "192.168.86.48", config: lan)
        XCTAssertEqual(r.origin, "http://m1max.local:7443", "an untrusted peer's X-Forwarded-* change nothing")
        XCTAssertFalse(r.secure)
        XCTAssertEqual(r.client, "192.168.86.48", "nor its X-Forwarded-For")
        XCTAssertNil(origin("doz.home.example", peer: "192.168.86.48", config: lan).origin, "the public name, not through the proxy: refused")
        XCTAssertNil(origin("doz.home.example", proto: "https", peer: "192.168.86.48", config: lan).origin)
        // A trusted proxy cannot make up an origin that is not configured.
        XCTAssertNil(origin("evil.example", proto: "https", peer: "127.0.0.1", config: proxied).origin)
        // A trusted proxy without X-Forwarded-Proto is plain http.
        XCTAssertNil(origin("doz.home.example", peer: "127.0.0.1", config: proxied).origin, "https is configured, the request is http")
        XCTAssertEqual(origin("localhost:7443", peer: "127.0.0.1", config: proxied).origin, "http://localhost:7443")
    }

    func testCookieNames() {
        XCTAssertEqual(WebServeRules.cookieName(port: 7443, secure: false), "doz_serve_7443")
        XCTAssertEqual(WebServeRules.cookieName(port: 7443, secure: true), "__Host-doz_serve_7443")
        XCTAssertTrue(WebSecurity.setCookie("v", name: "__Host-doz_serve_7443", maxAge: 10, secure: true).hasSuffix("; Secure"))
        XCTAssertFalse(WebSecurity.setCookie("v", name: "doz_serve_7443", maxAge: 10).contains("Secure"))
    }

    func testPublicOrigins() {
        XCTAssertEqual(WebPublicOrigin("https://Doz.Home.Example")?.description, "https://doz.home.example")
        XCTAssertEqual(WebPublicOrigin("https://doz.home.example:443")?.description, "https://doz.home.example")
        XCTAssertEqual(WebPublicOrigin("https://doz.home.example:8443/")?.description, "https://doz.home.example:8443")
        XCTAssertEqual(WebPublicOrigin("http://[fd00::5]:8080")?.description, "http://[fd00::5]:8080")
        for bad in ["doz.home.example", "ftp://x", "https://doz.home.example/path", "https://u:p@doz.example", "https://doz.example?x=1", "https://"] {
            XCTAssertNil(WebPublicOrigin(bad), bad)
        }
    }

    /// The settings' checks (DozerHost) and the web layer's parsers agree.
    func testTheSettingsAndTheWebLayerAgree() {
        for b in ["lan", "loopback", "192.168.86.65", "192.168.86.65, fd00::5", "[::1]", "0.0.0.0", "::", "fe80::1", "169.254.1.1", "m1max.local", "", "1.2.3.4,"] {
            XCTAssertEqual(ServeSettingValues.isBind(b), WebServeBind.parse(b) != nil && !b.isEmpty, b)
        }
        for o in ["https://doz.example", "https://a.example, http://b.example:8080", "doz.example", "https://x.example/p", ""] {
            let parsed = o.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { WebPublicOrigin($0) }
            XCTAssertEqual(ServeSettingValues.isOriginList(o), !parsed.contains { $0 == nil }, o)
        }
        for a in ["127.0.0.1", "127.0.0.1, ::1", "192.168.1.0/24", "fd00::/8", "10.0.0.0/33", "x.example", ""] {
            let parsed = a.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { WebCIDR($0) }
            XCTAssertEqual(ServeSettingValues.isAddressList(a), !parsed.contains { $0 == nil }, a)
        }
        // The schema: serve.* exist, are read-only in the web UI, and refuse bad values.
        for k in [SettingKey.servePort, SettingKey.serveBind, SettingKey.servePublicOrigins, SettingKey.serveTrustedProxies, SettingKey.serveAdvertise] {
            let d = DozerSettings.definition(k)
            XCTAssertNotNil(d, k)
            XCTAssertEqual(d?.editableInUI, false, k)
        }
        XCTAssertEqual(DozerSettings.definition(SettingKey.servePort)?.defaultValue, .int(7443))
        XCTAssertThrowsError(try DozerSettings.definition(SettingKey.servePort)!.parse("80"))
        XCTAssertThrowsError(try DozerSettings.definition(SettingKey.serveBind)!.parse("0.0.0.0"))
        XCTAssertNoThrow(try DozerSettings.definition(SettingKey.serveBind)!.parse("loopback"))
        XCTAssertThrowsError(try DozerSettings.definition(SettingKey.servePublicOrigins)!.parse("https://x.example/path"))
        XCTAssertThrowsError(try DozerSettings.definition(SettingKey.serveTrustedProxies)!.parse("everyone"))
    }

    func testTheWebUIRefusesServeSettings() throws {
        let store = WebSettingsStore(environment: [:])
        XCTAssertThrowsError(try store.apply(WebSettingChange.decode(Data(#"{"key":"serve.trusted_proxies","value":"0.0.0.0/0"}"#.utf8)))) { e in
            XCTAssertTrue("\(e)".contains("decides who reaches the dashboard"), "\(e)")
        }
    }
}
