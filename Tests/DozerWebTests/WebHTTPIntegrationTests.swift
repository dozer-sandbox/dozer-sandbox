import Darwin
import Foundation
import DozerKit
import DozerHost
import XCTest
@testable import DozerWeb

/// 590 — a REAL listener on 127.0.0.1, driven with raw HTTP/1.1 over a socket (so every header —
/// Host, Origin, Cookie — is exactly what the test says; URLSession would rewrite Host). The data
/// behind it is a fake: these tests are about the boundary, not the host.
final class WebHTTPIntegrationTests: XCTestCase {
    var server: DozerWebServer!
    var serveTask: Task<Void, Error>!
    let capability = try! WebBootstrapCapability(testingValue: "test-capability-abcdefghijklmnopqrstuvwxyz")
    let fake = FakeData()

    func start(_ limits: WebLimits = .standard) async throws {
        server = try await DozerWebServer.bind(data: fake, assets: try WebAssets.load(), version: "test", limits: limits,
                                                capability: capability, pollInterval: .milliseconds(200))
        let s = server!
        serveTask = Task { try await s.run() }
    }

    override func tearDown() async throws {
        await server?.close()
        _ = try? await serveTask?.value
        server = nil
    }

    var host: String { server.origin.authority }
    var origin: String { server.origin.value }
    var cookieName: String { WebSecurity.cookieName(server.origin) }

    func get(_ path: String, _ headers: [String: String] = [:], method: String = "GET", body: String? = nil) throws -> RawResponse {
        var h = ["Host": host]
        for (k, v) in headers { h[k] = v }
        return try RawHTTP.request(port: server.origin.port, method: method, path: path, headers: h, body: body)
    }

    /// Bootstrap and return (cookie header value, csrf).
    func signIn(_ cap: String? = nil) throws -> (String, String) {
        let r = try get("/api/v1/session", ["Origin": origin, "Authorization": "Bearer \(cap ?? capability.value)"], method: "POST")
        XCTAssertEqual(r.status, 200, r.text)
        let set = try XCTUnwrap(r.header("set-cookie"))
        let pair = String(set.split(separator: ";")[0])
        let csrf = try XCTUnwrap((try JSONSerialization.jsonObject(with: r.body) as? [String: Any])?["csrf"] as? String)
        return (pair, csrf)
    }

    // MARK: static + listener

    func testTheListenerIsLoopbackOnAnEphemeralPort() async throws {
        try await start()
        XCTAssertEqual(server.origin.host, "127.0.0.1")
        XCTAssertGreaterThan(server.origin.port, 1023)
        XCTAssertEqual(server.launchURL.fragment, "cap=" + capability.value)
        XCTAssertNil(server.launchURL.query)
    }

    func testTheIndexAndAssetsLoadWithStrictHeadersAndNoCORS() async throws {
        try await start()
        let r = try get("/")
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.header("content-type"), "text/html; charset=utf-8")
        XCTAssertEqual(r.header("cache-control"), "no-store")
        XCTAssertTrue(r.header("content-security-policy")?.contains("script-src 'self'") == true)
        XCTAssertEqual(r.header("x-frame-options"), "DENY")
        XCTAssertFalse(r.headers.keys.contains { $0.hasPrefix("access-control") })
        // (607: a hashed asset — not /sw.js, a no-store document since 605, which a dictionary's order picked at times.)
        let asset = try XCTUnwrap(try WebAssets.load().assets.keys.first { $0.hasPrefix("/assets/") && $0.hasSuffix(".js") })
        let a = try get(asset)
        XCTAssertEqual(a.status, 200)
        XCTAssertEqual(a.header("content-type"), "application/javascript; charset=utf-8")
        XCTAssertEqual(a.header("cache-control"), WebAssets.immutable)
        let head = try get("/", method: "HEAD")
        XCTAssertEqual(head.status, 200)
        XCTAssertTrue(head.body.isEmpty)
    }

    func testAWrongHostIsRefusedEverywhereBeforeAnythingElse() async throws {
        try await start()
        for h in ["evil.example", "localhost:\(server.origin.port)", "127.0.0.1", "127.0.0.2:\(server.origin.port)"] {
            for path in ["/", "/api/v1/overview", "/api/v1/nope", "/api/v1/session"] {
                let r = try get(path, ["Host": h])
                XCTAssertEqual(r.status, 403, "\(h) \(path)")
                XCTAssertTrue(r.text.contains("host-rejected"))
                XCTAssertFalse(r.text.contains(h), "the Host is never reflected")
            }
        }
    }

    func testCrossOriginAndCrossSiteAreRefused() async throws {
        try await start()
        let (cookie, _) = try signIn()
        XCTAssertEqual(try get("/api/v1/overview", ["Cookie": cookie, "Origin": "http://evil.example"]).status, 403)
        XCTAssertEqual(try get("/api/v1/overview", ["Cookie": cookie, "Sec-Fetch-Site": "cross-site"]).status, 403)
        XCTAssertEqual(try get("/api/v1/overview", ["Cookie": cookie, "Sec-Fetch-Site": "same-site"]).status, 403)
        XCTAssertEqual(try get("/api/v1/overview", ["Cookie": cookie, "Sec-Fetch-Site": "same-origin", "Origin": origin]).status, 200)
        // A preflight gets no CORS answer.
        let pre = try get("/api/v1/overview", ["Origin": "http://evil.example", "Access-Control-Request-Method": "GET"], method: "OPTIONS")
        XCTAssertEqual(pre.status, 405)
        XCTAssertFalse(pre.headers.keys.contains { $0.hasPrefix("access-control") })
    }

    // MARK: bootstrap + session

    func testTheBootstrapIsSingleUseAndSetsAStrictHttpOnlyPortScopedCookie() async throws {
        try await start()
        XCTAssertEqual(try get("/api/v1/session", ["Authorization": "Bearer \(capability.value)"], method: "POST").status, 403,
                       "no Origin: refused, and the capability is not consumed")
        XCTAssertEqual(try get("/api/v1/session", ["Origin": origin, "Authorization": "Bearer wrong-capability-0123456789"], method: "POST").status, 401)
        let r = try get("/api/v1/session", ["Origin": origin, "Authorization": "Bearer \(capability.value)"], method: "POST")
        XCTAssertEqual(r.status, 200)
        let set = try XCTUnwrap(r.header("set-cookie"))
        XCTAssertTrue(set.hasPrefix(cookieName + "="))
        for attr in ["HttpOnly", "SameSite=Strict", "Path=/"] { XCTAssertTrue(set.contains(attr), attr) }
        XCTAssertFalse(set.contains(capability.value))
        XCTAssertFalse(r.text.contains(capability.value), "the answer never echoes the capability")
        let again = try get("/api/v1/session", ["Origin": origin, "Authorization": "Bearer \(capability.value)"], method: "POST")
        XCTAssertEqual(again.status, 401)
        XCTAssertTrue(again.text.contains("bootstrap-used"))
    }

    func testReadsNeedTheCookieAndMutationsTheCSRFToken() async throws {
        try await start()
        XCTAssertEqual(try get("/api/v1/overview").status, 401)
        XCTAssertEqual(try get("/api/v1/overview", ["Cookie": "\(cookieName)=forged-session-value"]).status, 401)
        let (cookie, csrf) = try signIn()
        let o = try get("/api/v1/overview", ["Cookie": cookie])
        XCTAssertEqual(o.status, 200)
        XCTAssertTrue(o.text.contains("\"demo\""))
        XCTAssertEqual(try get("/api/v1/session", ["Cookie": cookie]).status, 200)
        // Renew: Origin + CSRF, both exact.
        XCTAssertEqual(try get("/api/v1/session/renew", ["Cookie": cookie, "Origin": origin], method: "POST").status, 403)
        XCTAssertEqual(try get("/api/v1/session/renew", ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": "x"], method: "POST").status, 403)
        XCTAssertEqual(try get("/api/v1/session/renew", ["Cookie": cookie, "X-Doz-CSRF": csrf], method: "POST").status, 403)
        XCTAssertEqual(try get("/api/v1/session/renew", ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf], method: "POST").status, 200)
        // Sign out: the cookie is cleared and stops working.
        let out = try get("/api/v1/session", ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf], method: "DELETE")
        XCTAssertEqual(out.status, 204)
        XCTAssertTrue(out.header("set-cookie")?.contains("Max-Age=0") == true)
        XCTAssertEqual(try get("/api/v1/overview", ["Cookie": cookie]).status, 401)
    }

    func testANewLinkFromTheControlSocketWorksOnce() async throws {
        try await start()
        let dir = URL(fileURLWithPath: "/tmp/doz-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        let store = DozerStore(root: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = try XCTUnwrap(try WebControl.takeLock(store))
        XCTAssertNil(try WebControl.takeLock(store), "one UI per store")
        let lfd = try WebControl.serve(store, server: server)
        defer { WebControl.cleanUp(store, listenFD: lfd, lockFD: lock) }
        let url = try XCTUnwrap(WebControl.requestLink(store))
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.port, server.origin.port)
        let cap = try XCTUnwrap(url.fragment?.dropFirst("cap=".count)).description
        XCTAssertNotEqual(cap, capability.value)
        _ = try signIn(cap)
        XCTAssertEqual(try get("/api/v1/session", ["Origin": origin, "Authorization": "Bearer \(cap)"], method: "POST").status, 401)
        // The first link is independent of it.
        _ = try signIn()
        // Mode of the socket: the owner's only.
        var st = stat()
        XCTAssertEqual(stat(WebControl.socket(store).path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o077, 0)
    }

    /// 594 W19: the already-running path — `doz ui` asks the running UI (`status`: its origin and open
    /// pages, no key) before it would start a second; `rotate` ends every page's session for a new link;
    /// an unknown command gets nothing.
    func testTheControlSocketSaysWhereTheUIRunsAndRotates() async throws {
        try await start()
        let dir = URL(fileURLWithPath: "/tmp/doz-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        let store = DozerStore(root: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(WebControl.requestStatus(store), "no UI: nothing answers")
        let lock = try XCTUnwrap(try WebControl.takeLock(store))
        let lfd = try WebControl.serve(store, server: server)
        defer { WebControl.cleanUp(store, listenFD: lfd, lockFD: lock) }
        var st = try XCTUnwrap(WebControl.requestStatus(store))
        XCTAssertEqual(st.origin, origin)
        XCTAssertEqual(st.pages, 0, "no page open")
        let (cookie, _) = try signIn()
        let s = try RawStream(port: server.origin.port, path: "/api/v1/stream", headers: ["Host": host, "Cookie": cookie])
        defer { s.close() }
        _ = try s.read(until: "event: hello", seconds: 5)
        st = try XCTUnwrap(WebControl.requestStatus(store))
        XCTAssertEqual(st.pages, 1, "one page open")
        let url = try XCTUnwrap(WebControl.requestRotate(store))
        XCTAssertEqual(url.port, server.origin.port)
        XCTAssertTrue(try s.read(until: "rotated", seconds: 5).contains("event: end"), "the open page is told")
        XCTAssertEqual(try get("/api/v1/overview", ["Cookie": cookie]).status, 401, "its session ended")
        let cap = try XCTUnwrap(url.fragment?.dropFirst("cap=".count)).description
        _ = try signIn(cap)
        // Anything else on the socket: no answer.
        let fd = try XCTUnwrap(UnixSocket.connect(WebControl.socket(store).path))
        defer { close(fd) }
        XCTAssertTrue(UnixSocket.writeAll(fd, Data("exec\n".utf8)))
        XCTAssertNil(LineReader(fd: fd).readLine(limit: 1024))
    }

    // MARK: limits + routes

    func testBodiesOverTheCapAre413() async throws {
        try await start(try WebLimits(maximumRequestBodyBytes: 64))
        let (cookie, csrf) = try signIn()
        let big = String(repeating: "x", count: 200)
        let r = try get("/api/v1/session/renew", ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf, "Content-Type": "application/json"],
                        method: "POST", body: big)
        XCTAssertEqual(r.status, 413)
        let form = try get("/api/v1/session/renew", ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf,
                                                     "Content-Type": "application/x-www-form-urlencoded"], method: "POST", body: "a=b")
        XCTAssertEqual(form.status, 415)
    }

    func testOnlyTheClosedRouteTableAnswers() async throws {
        try await start()
        let (cookie, _) = try signIn()
        for p in ["/api/v1/exec", "/api/v1/sandboxes/demo/exec", "/api/v1/sandboxes/..%2f..%2fetc", "/manifest.json", "/assets/../index.html",
                  "/api/v1/sandboxes/DEMO", "/index.html", "/api/v1/overview/"] {
            XCTAssertEqual(try get(p, ["Cookie": cookie]).status, 404, p)
        }
        XCTAssertEqual(try get("/api/v1/overview", ["Cookie": cookie], method: "PUT").status, 405)
        XCTAssertEqual(try get("/api/v1/overview", ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": "x"], method: "POST").status, 404)
    }

    func testHostErrorsAreTypedAndEveryViewAnswers() async throws {
        try await start()
        let (cookie, _) = try signIn()
        let missing = try get("/api/v1/sandboxes/nope", ["Cookie": cookie])
        XCTAssertEqual(missing.status, 404)
        XCTAssertTrue(missing.text.contains("\"not-found\""))
        for p in ["/api/v1/sandboxes/demo", "/api/v1/sandboxes/demo/sessions", "/api/v1/sandboxes/demo/network", "/api/v1/images",
                  "/api/v1/accounts", "/api/v1/metrics", "/api/v1/events", "/api/v1/doctor"] {
            let r = try get(p, ["Cookie": cookie])
            XCTAssertEqual(r.status, 200, p)
            XCTAssertEqual(r.header("content-type"), "application/json; charset=utf-8")
            XCTAssertEqual(r.header("cache-control"), "no-store")
        }
    }

    /// 593: Images › Lineage — a session-only GET, projected (no host path), depth-first.
    func testTheImageTreeIsASessionOnlyProjection() async throws {
        try await start()
        XCTAssertEqual(try get("/api/v1/images/tree").status, 401)
        let (cookie, csrf) = try signIn()
        let r = try get("/api/v1/images/tree", ["Cookie": cookie])
        XCTAssertEqual(r.status, 200, r.text)
        let t = try JSONDecoder().decode(WebImageTree.self, from: r.body)
        XCTAssertEqual(t.nodes.map { "\($0.depth) \($0.kind) \($0.name)" }, ["0 base OCI base", "1 image pi", "2 sandbox demo"])
        XCTAssertEqual(t.nodes[2].sharedWithParentBytes, 900 << 20)
        XCTAssertFalse(r.text.contains("/s/"), "no host path reaches the browser")
        let post = try get("/api/v1/images/tree", ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf, "Content-Type": "application/json"],
                           method: "POST", body: "{}")
        XCTAssertEqual(post.status, 404, "not a route")
    }

    /// 595: Resources — a session-only GET projected without paths (plus this UI's memory); the preview
    /// is a CSRF-checked POST with a strict body that changes nothing; deleting is only the typed action.
    func testResourcesAreASessionOnlyProjectionAndThePreviewNeedsCSRF() async throws {
        try await start()
        XCTAssertEqual(try get("/api/v1/resources").status, 401)
        let (cookie, csrf) = try signIn()
        let r = try get("/api/v1/resources", ["Cookie": cookie])
        XCTAssertEqual(r.status, 200, r.text)
        let rep = try WebJSON.decoder.decode(ResourceReport.self, from: r.body)
        XCTAssertEqual(rep.items.map(\.id), ["cache:downloads", "unattributed"])
        XCTAssertTrue(rep.items.allSatisfy { $0.path == nil }, "no path reaches the browser")
        XCTAssertFalse(r.text.contains("/tmp/fake-store/content"))
        XCTAssertEqual(rep.memory.map(\.kind), ["sandbox", "ui"], "the UI's own memory is on the account")
        let json = ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf, "Content-Type": "application/json"]
        var noCSRF = json; noCSRF["X-Doz-CSRF"] = nil
        XCTAssertEqual(try get("/api/v1/resources/preview", noCSRF, method: "POST", body: #"{"ids":["logs"]}"#).status, 403)
        var noOrigin = json; noOrigin["Origin"] = nil
        XCTAssertEqual(try get("/api/v1/resources/preview", noOrigin, method: "POST", body: #"{"ids":["logs"]}"#).status, 403)
        XCTAssertEqual(fake.previews.count, 0)
        let p = try get("/api/v1/resources/preview", json, method: "POST", body: #"{"ids":["logs","initfs"]}"#)
        XCTAssertEqual(p.status, 200, p.text)
        XCTAssertEqual(try WebJSON.decoder.decode(ResourcePlan.self, from: p.body).items.map(\.id), ["logs", "initfs"])
        XCTAssertEqual(try get("/api/v1/resources/preview", json, method: "POST", body: #"{"clean":true}"#).status, 200)
        XCTAssertEqual(fake.previews.map(\.clean), [false, true])
        for bad in [#"{"ids":["../x"]}"#, #"{"ids":[]}"#, #"{"clean":true,"ids":["logs"]}"#, #"{"ids":["logs"],"dryRun":false}"#] {
            XCTAssertEqual(try get("/api/v1/resources/preview", json, method: "POST", body: bad).status, 400, bad)
        }
        XCTAssertEqual(fake.previews.count, 2)
        // Nothing near them is a route: no DELETE, no GET preview, no per-item path.
        XCTAssertEqual(try get("/api/v1/resources", json, method: "POST", body: "{}").status, 404)
        XCTAssertEqual(try get("/api/v1/resources/preview", ["Cookie": cookie]).status, 404)
        XCTAssertEqual(try get("/api/v1/resources/cache:downloads", json, method: "DELETE").status, 404)
    }

    /// 593 §9 (S3): a saved screen is a session-only GET, projected (VT as base64, no host path).
    func testASavedScreenIsASessionOnlyProjection() async throws {
        try await start()
        XCTAssertEqual(try get("/api/v1/sandboxes/demo/sessions/shell/screen").status, 401)
        let (cookie, csrf) = try signIn()
        let r = try get("/api/v1/sandboxes/demo/sessions/shell/screen", ["Cookie": cookie])
        XCTAssertEqual(r.status, 200, r.text)
        let s = try WebJSON.decoder.decode(WebSavedScreen.self, from: r.body)
        XCTAssertEqual(s.session, "shell")
        XCTAssertEqual(s.reason, "hibernate")
        XCTAssertEqual(Data(base64Encoded: s.vt), Data("\u{1B}c$ hi\r\n".utf8))
        XCTAssertFalse(r.text.contains("fake-store"), "no host path reaches the browser")
        XCTAssertEqual(try get("/api/v1/sandboxes/demo/sessions/other/screen", ["Cookie": cookie]).status, 404)
        for p in ["/api/v1/sandboxes/demo/sessions/..%2f/screen", "/api/v1/sandboxes/demo/sessions/.x/screen",
                  "/api/v1/sandboxes/demo/sessions/shell/screen/", "/api/v1/sandboxes/demo/sessions/shell"] {
            XCTAssertEqual(try get(p, ["Cookie": cookie]).status, 404, p)
        }
        let post = try get("/api/v1/sandboxes/demo/sessions/shell/screen", ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf,
                                                                           "Content-Type": "application/json"], method: "POST", body: "{}")
        XCTAssertEqual(post.status, 404, "reading only")
    }

    /// 593 §9 (S1): the layout — read with the cookie; changed only with Origin + CSRF + a strict JSON body.
    func testTheTerminalLayoutIsReadWithTheCookieAndChangedWithCSRFAndAStrictBody() async throws {
        try await start()
        XCTAssertEqual(try get("/api/v1/sandboxes/demo/layout").status, 401)
        let (cookie, csrf) = try signIn()
        let none = try get("/api/v1/sandboxes/demo/layout", ["Cookie": cookie])
        XCTAssertEqual(none.status, 200)
        XCTAssertEqual(none.text, "null")
        let body = #"{"split":true,"focusedPane":1,"panes":[{"tabs":[{"session":"shell","mode":"interactive"}],"selected":0},{"tabs":[{"session":"shell-2","mode":"watch"}],"selected":null}]}"#
        let json = ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf, "Content-Type": "application/json"]
        // CSRF and Origin, exactly as every other change.
        var noCSRF = json; noCSRF["X-Doz-CSRF"] = nil
        XCTAssertEqual(try get("/api/v1/sandboxes/demo/layout", noCSRF, method: "POST", body: body).status, 403)
        var noOrigin = json; noOrigin["Origin"] = nil
        XCTAssertEqual(try get("/api/v1/sandboxes/demo/layout", noOrigin, method: "POST", body: body).status, 403)
        XCTAssertEqual(fake.layoutWrites, 0)
        let ok = try get("/api/v1/sandboxes/demo/layout", json, method: "POST", body: body)
        XCTAssertEqual(ok.status, 200, ok.text)
        let back = try WebJSON.decoder.decode(WebTerminalLayout.self, from: try get("/api/v1/sandboxes/demo/layout", ["Cookie": cookie]).body)
        XCTAssertEqual(back.panes.map { p in p.tabs.map { $0.session } }, [["shell"], ["shell-2"]])
        XCTAssertEqual(back.panes[1].tabs[0].mode, "watch")
        XCTAssertNil(back.panes[1].selected)
        XCTAssertTrue(back.split)
        // Strict: an unknown field anywhere, a wrong type, a bad name — 400, nothing written, no value echoed.
        for bad in [#"{"split":false,"focusedPane":0,"panes":[{"tabs":[]}],"extra":1}"#,
                    #"{"split":false,"focusedPane":0,"panes":[{"tabs":[],"x":1}]}"#,
                    #"{"split":false,"focusedPane":0,"panes":[{"tabs":[{"session":"a","mode":"interactive","argv":["sh"]}]}]}"#,
                    #"{"split":"no","focusedPane":0,"panes":[{"tabs":[]}]}"#,
                    #"{"split":false,"focusedPane":0.5,"panes":[{"tabs":[]}]}"#,
                    #"{"split":false,"focusedPane":0,"panes":[{"tabs":[{"session":"../../etc","mode":"interactive"}]}]}"#,
                    #"{"split":false,"focusedPane":0,"panes":[{"tabs":[{"session":"a","mode":"type"}]}]}"#,
                    #"{"split":true,"focusedPane":0,"panes":[{"tabs":[]}]}"#,
                    #"{"split":false,"focusedPane":0,"panes":[]}"#,
                    #"[1]"#] {
            let r = try get("/api/v1/sandboxes/demo/layout", json, method: "POST", body: bad)
            XCTAssertEqual(r.status, 400, bad)
            XCTAssertFalse(r.text.contains("etc") || r.text.contains("argv") || r.text.contains("type\""), "no value echoed: \(r.text)")
        }
        XCTAssertEqual(fake.layoutWrites, 1)
        XCTAssertEqual(try get("/api/v1/sandboxes/nope/layout", json, method: "POST", body: body).status, 404)
        let form = try get("/api/v1/sandboxes/demo/layout", ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf,
                                                               "Content-Type": "text/plain"], method: "POST", body: body)
        XCTAssertEqual(form.status, 415)
    }

    /// 593: the Boot log — session-only GETs; one boot rendered as inert terminal text (no guest escape).
    func testTheBootLogIsASessionOnlyRenderedRead() async throws {
        try await start()
        XCTAssertEqual(try get("/api/v1/sandboxes/demo/boots").status, 401)
        let (cookie, csrf) = try signIn()
        let l = try get("/api/v1/sandboxes/demo/boots", ["Cookie": cookie])
        XCTAssertEqual(l.status, 200, l.text)
        let list = try WebJSON.decoder.decode(WebBootList.self, from: l.body)
        XCTAssertEqual(list.boots.map(\.number), [1, 2])
        XCTAssertEqual(list.boots.first?.result, "failed")
        XCTAssertFalse(l.text.contains("b-1800"), "no internal id")
        let one = try WebJSON.decoder.decode(WebBootLog.self, from: try get("/api/v1/sandboxes/demo/boots/2", ["Cookie": cookie]).body)
        let text = String(decoding: Data(base64Encoded: one.vt) ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.contains("cold boot of demo") && text.contains("VM created and booted") && text.contains("random: crng init done"), text)
        XCTAssertTrue(text.contains("evil ]52;c;eA==line"), "the console's escape is made inert: \(text.debugDescription)")
        XCTAssertFalse(text.contains("\u{1B}]52"), "no OSC reaches the terminal")
        XCTAssertEqual(try get("/api/v1/sandboxes/demo/boots/3", ["Cookie": cookie]).status, 404)
        for p in ["/api/v1/sandboxes/demo/boots/0", "/api/v1/sandboxes/demo/boots/01", "/api/v1/sandboxes/demo/boots/100",
                  "/api/v1/sandboxes/demo/boots/-1", "/api/v1/sandboxes/demo/boots/x", "/api/v1/sandboxes/demo/boots/1/raw"] {
            XCTAssertEqual(try get(p, ["Cookie": cookie]).status, 404, p)
        }
        XCTAssertEqual(try get("/api/v1/sandboxes/demo/boots", ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf,
                                                                 "Content-Type": "application/json"], method: "POST", body: "{}").status, 404, "reading only")
    }

    // MARK: server-sent events

    func testTheStreamSaysHelloThenChangedAndActivity() async throws {
        try await start(try WebLimits(heartbeatInterval: 0.2))
        let (cookie, _) = try signIn()
        let s = try RawStream(port: server.origin.port, path: "/api/v1/stream", headers: ["Host": host, "Cookie": cookie])
        defer { s.close() }
        XCTAssertTrue(try s.read(until: "event: hello", seconds: 5).contains("text/event-stream"))
        fake.bump()
        XCTAssertTrue(try s.read(until: "event: changed", seconds: 5).contains("overview"))
        // No host stream to report it: the poll notes the phase change itself.
        XCTAssertTrue(try s.read(until: "running → paused", seconds: 5).contains("event: activity"))
        let recent = try get("/api/v1/events", ["Cookie": cookie])
        XCTAssertTrue(recent.text.contains("running → paused"))
        XCTAssertTrue(try s.read(until: ": ping", seconds: 5).contains(": ping"), "heartbeats")
    }

    /// 594 W18: the host's transitions reach the page as `host` events (and the Activity feed).
    func testTheStreamTellsTheHostsDeathAndItsReturnAsAnotherBuild() async throws {
        func runningHost(_ pid: Int32, _ version: String) -> WebHost {
            WebHost(running: true, version: version, pid: pid, startedAt: nil, idleTimeoutMinutes: 5, idleSeconds: nil,
                    liveSandboxes: ["demo"], connections: 1, recoveryPending: [], store: fake.storePath, uiVersion: "test")
        }
        fake.phase = "running"
        fake.scriptedHost = runningHost(41, "0.12.0-rc.3")
        fake.probe = WebHostProbe(running: true)
        try await start()
        let (cookie, _) = try signIn()
        let s = try RawStream(port: server.origin.port, path: "/api/v1/stream", headers: ["Host": host, "Cookie": cookie])
        defer { s.close() }
        _ = try s.read(until: "event: hello", seconds: 5)
        try await Task.sleep(for: .milliseconds(600))                  // the first look (it tells nothing)
        fake.probe = WebHostProbe(running: false, stalePID: true, lost: ["demo"], recovering: ["demo"])
        fake.scriptedHost = nil
        let died = try s.read(until: "\"state\":\"died\"", seconds: 5)
        XCTAssertTrue(died.contains("event: host"))
        XCTAssertTrue(died.contains("\"sandboxes\":[\"demo\"]"))
        fake.probe = WebHostProbe(running: true)
        fake.scriptedHost = runningHost(42, "0.12.0-rc.4")
        let back = try s.read(until: "\"previousVersion\":\"0.12.0-rc.3\"", seconds: 5)
        XCTAssertTrue(back.contains("\"state\":\"running\""))
        let recent = try get("/api/v1/events", ["Cookie": cookie]).text
        XCTAssertTrue(recent.contains("host died — 1 sandbox was running, now shut down: demo"), recent)
        XCTAssertTrue(recent.contains("host started (pid 42, doz 0.12.0-rc.4) — was doz 0.12.0-rc.3"), recent)
    }

    func testAStreamThatFallsBehindGetsResyncAndCloses() async throws {
        try await start(try WebLimits(maximumBufferedSSEEvents: 4))
        let (cookie, _) = try signIn()
        let s = try RawStream(port: server.origin.port, path: "/api/v1/stream", headers: ["Host": host, "Cookie": cookie])
        defer { s.close() }
        _ = try s.read(until: "event: hello", seconds: 5)
        let payload = String(repeating: "x", count: 4096)
        for i in 0..<2000 { server.hub.broadcast("activity", WebActivity(seq: i, kind: "note", text: payload)) }
        let text = try s.read(until: "event: resync", seconds: 10)
        XCTAssertTrue(text.contains("event: resync"))
        XCTAssertTrue(s.waitForClose(seconds: 5), "the stream closes after resync")
    }

    func testSigningOutEndsTheSessionsStreams() async throws {
        try await start()
        let (cookie, csrf) = try signIn()
        let s = try RawStream(port: server.origin.port, path: "/api/v1/stream", headers: ["Host": host, "Cookie": cookie])
        defer { s.close() }
        _ = try s.read(until: "event: hello", seconds: 5)
        XCTAssertEqual(try get("/api/v1/session", ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf], method: "DELETE").status, 204)
        XCTAssertTrue(try s.read(until: "session-ended", seconds: 5).contains("event: end"))
        XCTAssertTrue(s.waitForClose(seconds: 5))
    }

    func testStreamsAreBoundedAndNeedASession() async throws {
        try await start(try WebLimits(maximumSSEClients: 1))
        XCTAssertEqual(try get("/api/v1/stream").status, 401)
        let (a, _) = try signIn()
        let first = try RawStream(port: server.origin.port, path: "/api/v1/stream", headers: ["Host": host, "Cookie": a])
        defer { first.close() }
        _ = try first.read(until: "event: hello", seconds: 5)
        let link = await server.newLink()
        let (b, _) = try signIn(String(link.fragment!.dropFirst(4)))
        XCTAssertEqual(try get("/api/v1/stream", ["Cookie": b]).status, 503, "another session: the limit holds")
        // The same session's reconnect (a reloaded tab) replaces its old stream.
        let second = try RawStream(port: server.origin.port, path: "/api/v1/stream", headers: ["Host": host, "Cookie": a])
        defer { second.close() }
        XCTAssertTrue(try first.read(until: "replaced", seconds: 5).contains("event: end"))
        _ = try second.read(until: "event: hello", seconds: 5)
    }

    /// The REAL source on an empty scratch store: answers from the store in-process, and looking
    /// never starts a host (no host.sock, no lock held afterwards).
    func testTheHostSourceReadsAStoreWithoutStartingAHost() async throws {
        let dir = URL(fileURLWithPath: "/tmp/doz-data-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        let store = DozerStore(root: dir)
        try store.ensureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = HostWebData(store: store, version: "test") { [] }
        let o = try await data.overview()
        XCTAssertEqual(o.source, "store")
        XCTAssertFalse(o.host.running)
        XCTAssertTrue(o.sandboxes.isEmpty)
        let images = try await data.images()
        XCTAssertEqual(Set(images.map(\.name)), ["lab", "claude-code", "pi", "codex"])
        do {
            _ = try await data.sandbox("nope")
            XCTFail("expected not-found")
        } catch let e as HostError {
            XCTAssertEqual(e.code, .notFound)
        }
        let m = try await data.metrics(WebMetricsQuery())
        XCTAssertFalse(m.available)
        XCTAssertNil(data.hostEvents())
        XCTAssertFalse(store.hostIsRunning())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.socket.path))
        XCTAssertEqual(data.attachCommand("demo"), "doz attach demo --store \(dir.path)")
    }

    func testShutdownTellsStreamsAndClosesConnections() async throws {
        try await start()
        let (cookie, _) = try signIn()
        let s = try RawStream(port: server.origin.port, path: "/api/v1/stream", headers: ["Host": host, "Cookie": cookie])
        defer { s.close() }
        _ = try s.read(until: "event: hello", seconds: 5)
        await server.close()
        XCTAssertTrue(try s.read(until: "shutdown", seconds: 5).contains("event: end"))
        XCTAssertTrue(s.waitForClose(seconds: 5))
    }

    // MARK: 605 — installable, and graceful restarts

    func testTheWorkerAndTheOfflinePageAreServedWithoutASessionAndTheirOwnHeaders() async throws {
        try await start()
        let sw = try get("/sw.js")
        XCTAssertEqual(sw.status, 200)
        XCTAssertEqual(sw.header("content-type"), "application/javascript; charset=utf-8")
        XCTAssertEqual(sw.header("cache-control"), "no-store")
        XCTAssertEqual(sw.header("content-security-policy"), "default-src 'none'; connect-src 'self'", "the worker's own policy, once")
        XCTAssertTrue(sw.text.contains("const PRECACHE"))
        let off = try get("/offline")
        XCTAssertEqual(off.status, 200)
        XCTAssertEqual(off.header("content-type"), "text/html; charset=utf-8")
        XCTAssertEqual(off.header("cache-control"), "no-store")
        XCTAssertTrue(off.header("content-security-policy")?.contains("manifest-src 'self'; worker-src 'self'") == true)
        XCTAssertTrue(off.text.contains("doz ui"))
        XCTAssertEqual(try get("/sw.js", ["Host": "evil.example:\(server.origin.port)"]).status, 403, "the exact Host first")
        XCTAssertEqual(try get("/offline", ["Sec-Fetch-Site": "cross-site"]).status, 403)
        XCTAssertEqual(try get("/sw.js", method: "POST", body: nil).status, 404)
        let manifest = try XCTUnwrap(try WebAssets.load().assets.values.first { $0.mimeType == "application/manifest+json" })
        let m = try get(manifest.publicPath)
        XCTAssertEqual(m.status, 200)
        XCTAssertEqual(m.header("content-type"), "application/manifest+json")
        XCTAssertFalse(m.headers.keys.contains { $0.hasPrefix("access-control") })
    }

    func testHelloNamesThisBuildsPageFiles() async throws {
        try await start()
        let (cookie, _) = try signIn()
        let s = try RawStream(port: server.origin.port, path: "/api/v1/stream", headers: ["Host": host, "Cookie": cookie])
        defer { s.close() }
        let hello = try s.read(until: "event: hello", seconds: 5) + (try s.read(until: "\n\n", seconds: 5))
        let a = try WebAssets.load()
        XCTAssertTrue(hello.contains("\"script\":\"\(a.pageScript!)\""), hello)
        XCTAssertTrue(hello.contains("\"style\":\"\(a.pageStyle!)\""), hello)
        XCTAssertTrue(hello.contains("\"version\":\"test\""), hello)
    }

    /// `doz ui link --rotate`: the page's stream ends `rotated`, and its next request is a 401 that says
    /// a new link was made (not just "not signed in"); signing out says signed-out.
    func testA401SaysWhyThePageMustSignInAgain() async throws {
        try await start()
        let (cookie, csrf) = try signIn()
        _ = await server.rotate()
        let r = try get("/api/v1/session", ["Cookie": cookie])
        XCTAssertEqual(r.status, 401)
        XCTAssertTrue(r.text.contains("\"session-rotated\""), r.text)
        let fresh = try signIn(await server.newLink().fragment!.replacingOccurrences(of: "cap=", with: ""))
        XCTAssertEqual(try get("/api/v1/session", ["Cookie": fresh.0, "Origin": origin, "X-Doz-CSRF": fresh.1], method: "DELETE").status, 204)
        XCTAssertTrue(try get("/api/v1/overview", ["Cookie": fresh.0]).text.contains("\"signed-out\""))
        XCTAssertTrue(try get("/api/v1/overview", ["Cookie": "\(cookieName)=\(WebRandom.token())"]).text.contains("\"unauthenticated\""))
        _ = csrf
    }

    /// `doz ui restart` (same port): streams end `restarting`, not `shutdown`.
    func testARestartTellsStreamsRestarting() async throws {
        try await start()
        let (cookie, _) = try signIn()
        let s = try RawStream(port: server.origin.port, path: "/api/v1/stream", headers: ["Host": host, "Cookie": cookie])
        defer { s.close() }
        _ = try s.read(until: "event: hello", seconds: 5)
        await server.close(.restarting)
        XCTAssertTrue(try s.read(until: "restarting", seconds: 5).contains("event: end"))
    }

    /// `doz ui restart` onto another port: each page's stream ends `moved` with the new ORIGIN — never a link
    /// (a key): the page cannot follow by itself (Fetch Metadata), the new doz ui opens one.
    func testARestartOntoAnotherPortTellsEachPageWhereItWent() async throws {
        try await start()
        let (c1, _) = try signIn()
        let (c2, _) = try signIn(await server.newLink().fragment!.replacingOccurrences(of: "cap=", with: ""))
        let s1 = try RawStream(port: server.origin.port, path: "/api/v1/stream", headers: ["Host": host, "Cookie": c1])
        let s2 = try RawStream(port: server.origin.port, path: "/api/v1/stream", headers: ["Host": host, "Cookie": c2])
        defer { s1.close(); s2.close() }
        _ = try s1.read(until: "event: hello", seconds: 5)
        _ = try s2.read(until: "event: hello", seconds: 5)
        let to = try WebOrigin(port: 54_999)
        await server.close(.moving(to))
        for s in [s1, s2] {
            let e = try s.read(until: "54999", seconds: 5)
            XCTAssertTrue(e.contains(#"{"origin":"http://127.0.0.1:54999","reason":"moved"}"#), e)
            XCTAssertFalse(e.contains("cap="), "no key in the stream")
        }
    }
}

// MARK: the fake data

final class FakeData: DozerWebData, @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    let storePath = "/tmp/fake-store"

    func bump() { lock.withLock { generation += 1 } }
    /// 591: the phase the overview reports (nil: running, then paused after `bump()`).
    var phase: String? {
        get { lock.withLock { _phase } }
        set { lock.withLock { _phase = newValue } }
    }
    private var _phase: String?

    func overview() async throws -> WebOverview {
        let (g, p) = lock.withLock { (generation, _phase) }
        let info = SandboxInfo(name: "demo", image: "lab", phase: p ?? (g == 0 ? "running" : "paused"), busy: false, cpus: 2, memoryMiB: 1024,
                               ramHeldMiB: 900, memoryReturnedMiB: 124, diskBytes: 1 << 30, sessions: 1, network: "bake",
                               deniedConnections: 0, workspace: nil, createdAt: Date(timeIntervalSince1970: 0), diedWithHost: nil)
        let host = lock.withLock { _host } ?? WebHost(running: false, version: nil, pid: nil, startedAt: nil, idleTimeoutMinutes: nil, idleSeconds: nil,
                                                      liveSandboxes: [], connections: nil, recoveryPending: [], store: storePath, uiVersion: "test")
        return WebOverview(host: host, sandboxes: [WebSandboxRow(info)], source: "store")
    }

    /// 594 W18: a scripted host (nil: none) and what the non-starting probe says.
    var scriptedHost: WebHost? {
        get { lock.withLock { _host } }
        set { lock.withLock { _host = newValue } }
    }
    private var _host: WebHost?
    var probe: WebHostProbe? {
        get { lock.withLock { _probe } }
        set { lock.withLock { _probe = newValue } }
    }
    private var _probe: WebHostProbe?
    func hostProbe() -> WebHostProbe? { probe }

    func sandbox(_ name: String) async throws -> WebSandboxDetail {
        guard name == "demo" else { throw HostError(.notFound, "no sandbox \(name)") }
        let o = try await overview()
        // Built through its Codable form (its only initializer takes the host's SandboxDetail).
        var d: [String: Any] = ["cpus": 2, "memoryMiB": 1024, "rootfsMiB": 2048, "stateDiskMiB": 512, "journalMiB": 16, "networkMode": "bake",
                                "shares": [Any](), "sessions": [Any](), "restorePoints": [Any](), "credentials": [Any](),
                                "directory": "/tmp/fake-store/sandboxes/demo", "snapshotBytes": 0, "hasRootDisk": true,
                                "defaultSession": "shell", "attachCommand": "doz attach demo"]
        d["info"] = try JSONSerialization.jsonObject(with: WebJSON.encoder.encode(o.sandboxes[0]))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(WebSandboxDetail.self, from: JSONSerialization.data(withJSONObject: d))
    }

    func sessions(_ name: String) async throws -> [WebSessionRow] {
        guard name == "demo" else { throw HostError(.notFound, "no sandbox \(name)") }
        return []
    }

    func network(_ name: String) async throws -> WebNetwork {
        WebNetwork(name: name, proxied: false, mode: "nat", policy: nil, log: [], logTotal: 0, denied: 0, logAvailable: false, note: "not proxied")
    }

    func images() async throws -> [WebImage] { [] }
    /// 595: a small account (with a path the projection must drop), and what a preview would plan.
    private(set) var previews: [WebResourcePreview] = []
    func resources() async throws -> WebResources {
        let items = [
            ResourceItem(id: "cache:downloads", group: "caches", name: "download cache", sizeBytes: 400 << 20, freedBytes: 400 << 20,
                         deletable: true, recreatable: true, later: "re-downloaded", cleanable: true, path: "/tmp/fake-store/content"),
            ResourceItem(id: "unattributed", group: "store", name: "unattributed", sizeBytes: 0, refusal: "nothing to delete"),
        ]
        let r = ResourceReport(store: storePath, measuredAt: Date(timeIntervalSince1970: 0), milliseconds: 5, totalBytes: 400 << 20,
                               attributedBytes: 400 << 20, unattributedBytes: 0, occupiedBytes: 400 << 20, cleanableBytes: 400 << 20,
                               volumeFreeBytes: 1 << 40, volumeTotalBytes: 2 << 40, items: items,
                               memory: [ResourceMemory(kind: "sandbox", name: "demo", phase: "running", heldBytes: 900 << 20, allocationBytes: 1 << 30, cpus: 2)],
                               machineCPUs: 8, allocatedCPUs: 2, network: [ResourceNetwork(sandbox: "demo", upToday: 10, downToday: 20)],
                               kernels: [], unusedDays: 30)
        return WebResources(r, uiFootprint: 30 << 20)
    }
    func resourcesPreview(_ p: WebResourcePreview) async throws -> ResourcePlan {
        lock.withLock { previews.append(p) }
        return ResourcePlan(items: p.ids.map { .init(id: $0, name: $0, freedBytes: 1) }, freedBytes: Int64(p.ids.count), dryRun: true, clean: p.clean)
    }
    /// 593: base → image → a sandbox, as the host would measure it.
    func imageTree() async throws -> WebImageTree {
        WebImageTree(ImageTree(disks: [
            .init(path: "/s/images/bases/b/root.ext4", kind: .base, name: "base f97ac66c1d54", allocatedBytes: 300 << 20, uniqueBytes: 10 << 20),
            .init(path: "/s/images/pi/k/root.ext4", kind: .image, name: "pi@bf46815674ce", parentPath: "/s/images/bases/b/root.ext4",
                  allocatedBytes: 900 << 20, uniqueBytes: 600 << 20, sharedWithParentBytes: 290 << 20),
            .init(path: "/s/sandboxes/demo/root.ext4", kind: .sandboxRoot, name: "sandbox demo", sandbox: "demo",
                  parentPath: "/s/images/pi/k/root.ext4", allocatedBytes: 950 << 20, uniqueBytes: 50 << 20, sharedWithParentBytes: 900 << 20),
        ], unionBytes: 960 << 20, milliseconds: 12))
    }
    func accounts() async throws -> WebAccounts { WebAccounts(accounts: [], defaultAccount: "mac", keepalive: false) }
    private(set) var metricsQueries: [WebMetricsQuery] = []
    func metrics(_ q: WebMetricsQuery) async throws -> WebMetrics {
        lock.withLock { metricsQueries.append(q) }
        return WebMetrics(available: false, runs: 0, rows: 0, sessions: 0, networkMinutes: 0, summary: [])
    }
    func metricsCSV(_ q: WebMetricsQuery) async throws -> Data { Data("id,action\n1,'=cmd\n".utf8) }
    func doctor() async throws -> [WebDoctorCheck] { [WebDoctorCheck(check: "macOS", status: "ok", detail: "fake")] }
    // 594: the onboarding's facts, as a store that was never onboarded shows them.
    func onboarding() async throws -> WebOnboarding {
        WebOnboarding(status: PrepareStatus(preparations: [], onboarded: nil, images: [], hostRunning: false),
                      checks: [OnboardingCheck(check: "macOS", status: "ok", detail: "fake", hard: true),
                               OnboardingCheck(check: "claude", status: "warn", detail: "not installed", hard: false)],
                      freeBytes: 100 << 30, macSignedIn: false, defaultAccount: "mac")
    }
    func preparations() async throws -> [WebPreparation] { [] }
    // 594: an account from a key — recorded (in memory: nothing is ever stored). The name `boom` fails
    // with a message that quotes the secret, as a careless host message would: the server must scrub it.
    // 594: a sandbox's own key — recorded; `boom` fails quoting the key; only `demo` exists.
    private var _keys: [WebKeySet] = []
    var keysSet: [WebKeySet] { lock.withLock { _keys } }
    func setKey(_ k: WebKeySet) async throws -> [WebCredential] {
        if k.sandbox == "boom" { throw HostError(.invalid, "the key \(k.secret) was refused") }
        guard k.sandbox == "demo" else { throw HostError(.notFound, "no sandbox \(k.sandbox)") }
        lock.withLock { _keys.append(k) }
        let json = #"{"binding":"anthropic","hosts":["api.anthropic.com"],"set":true,"source":"browser"}"#
        return [WebCredential(try JSONDecoder().decode(CredentialRow.self, from: Data(json.utf8)))]
    }
    private var _added: [WebAccountAdd] = []
    var addedAccounts: [WebAccountAdd] { lock.withLock { _added } }
    func addAccount(_ a: WebAccountAdd) async throws -> WebAccounts {
        if a.name == "boom" { throw HostError(.failed, "Anthropic rejected \(a.secret) (HTTP 401)") }
        lock.withLock { _added.append(a) }
        let json = #"{"name":"\#(a.name)","kind":"\#(a.kind.rawValue)","verification":"unverified: fake","isDefault":false,"usedBy":[],"state":"ok","keychainService":"doz-anthropic:\#(a.name)","fingerprint":"abcdef123456"}"#
        let row = try JSONDecoder().decode(AccountRow.self, from: Data(json.utf8))
        return WebAccounts(accounts: [WebAccount(row)], defaultAccount: "mac", keepalive: false)
    }
    // 591: scripted host events and boot console (only after `hostUp`: nil before, as with no host).
    var hostUp: Bool {
        get { lock.withLock { _hostUp } }
        set { lock.withLock { _hostUp = newValue } }
    }
    private var _hostUp = false
    private var eventSinks: [AsyncStream<HostEvent>.Continuation] = []
    private var consoleSinks: [AsyncStream<String>.Continuation] = []
    func hostEvents() -> AsyncStream<HostEvent>? {
        guard hostUp else { return nil }
        let (s, c) = AsyncStream<HostEvent>.makeStream()
        lock.withLock { eventSinks.append(c) }
        return s
    }
    func bootConsole(_ name: String) -> AsyncStream<String>? {
        guard hostUp else { return nil }
        let (s, c) = AsyncStream<String>.makeStream()
        lock.withLock { consoleSinks.append(c) }
        return s
    }
    var consoleSubscribers: Int { lock.withLock { consoleSinks.count } }
    func emit(_ e: HostEvent) { for c in lock.withLock({ eventSinks }) { c.yield(e) } }
    func console(_ line: String) { for c in lock.withLock({ consoleSinks }) { c.yield(line) } }

    // phase 2
    private(set) var performed: [HostRequest] = []
    private(set) var terminalCommands: [String] = []
    /// While set, `perform` waits (to hold operations open).
    var hold: Bool {
        get { lock.withLock { _hold } }
        set { lock.withLock { _hold = newValue } }
    }
    private var _hold = false
    var failWith: HostError?

    /// 594 W20: Restart host goes through its own guarded method; the fake records it as its `host stop`.
    func restartHost(onEvent: @escaping @Sendable (HostEvent) -> Void) async throws -> JSONValue {
        lock.withLock { performed.append(HostRequest(.hostStop)) }
        return .null
    }

    func perform(_ r: HostRequest, onEvent: @escaping @Sendable (HostEvent) -> Void) async throws -> JSONValue {
        lock.withLock { performed.append(r) }
        onEvent(HostEvent(kind: .step, sandbox: r.name, text: "fake step one", milliseconds: 5))
        while hold { try await Task.sleep(for: .milliseconds(20)) }
        if let e = lock.withLock({ failWith }) { throw e }
        if HostOp.lifecycle.contains(r.op) {
            let json = #"{"name":"\#(r.name ?? "")","operation":"\#(r.op.rawValue)","phaseBefore":"running","phase":"paused","changed":true,"milliseconds":2}"#
            return try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        }
        return .null
    }

    // 593 §9 — session memory: one saved screen (demo/shell) and a layout kept in memory.
    private var _layout: TerminalLayout?
    private(set) var layoutWrites = 0
    func sessionScreen(_ name: String, session: String) async throws -> WebSavedScreen {
        guard name == "demo", session == "shell" else { throw HostError(.notFound, "no saved screen of \(session) in \(name)") }
        let info = SavedScreenInfo(session: "shell", savedAt: Date(timeIntervalSince1970: 1_800_000_000), reason: "hibernate", cols: 80, rows: 24,
                                   screen: "primary", command: "bash -l", pid: 7, bytesOut: 42, vtBytes: 9)
        return WebSavedScreen(SessionScreen(name: name, SavedScreen(info: info, vt: Data("\u{1B}c$ hi\r\n".utf8), text: "$ hi")))
    }
    func terminalLayout(_ name: String) async throws -> WebTerminalLayout? {
        guard name == "demo" else { throw HostError(.notFound, "no sandbox \(name)") }
        return lock.withLock { _layout }.map(WebTerminalLayout.init)
    }
    func setTerminalLayout(_ name: String, _ layout: TerminalLayout) async throws -> WebTerminalLayout? {
        guard name == "demo" else { throw HostError(.notFound, "no sandbox \(name)") }
        try layout.validate()
        var l = layout
        l.updatedAt = Date()
        lock.withLock { _layout = l; layoutWrites += 1 }
        return WebTerminalLayout(l)
    }

    // 593 — boot logs: two boots of demo (the latest failed).
    static let boots = [BootLogInfo(id: "b-1800000000500", number: 1, kind: "wake", startedAt: Date(timeIntervalSince1970: 1_800_000_000.5),
                                    milliseconds: 310, result: "failed", error: "the snapshot is gone"),
                        BootLogInfo(id: "b-1800000000000", number: 2, kind: "cold boot", startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                    milliseconds: 460, result: "ok")]
    func bootLogs(_ name: String) async throws -> WebBootList {
        guard name == "demo" else { throw HostError(.notFound, "no sandbox \(name)") }
        return WebBootList(BootLogList(name: name, boots: Self.boots))
    }
    func bootLog(_ name: String, number: Int) async throws -> WebBootLog {
        guard name == "demo", (1...2).contains(number) else { throw HostError(.notFound, "no boot \(number) of \(name)") }
        let step = HostEvent(kind: .step, sandbox: "demo", text: "VM created and booted", milliseconds: 246)
        return WebBootLog(BootLogRecord(name: name, info: Self.boots[number - 1], events: [step],
                                        console: ["[    0.07] random: crng init done", "evil \u{1B}]52;c;eA==\u{07}line"]))
    }

    func policyPreview(_ name: String, _ edit: WebPolicyEdit) async throws -> WebPolicyPreview {
        let live = NetworkPolicy.presets["bake"]!
        return WebPolicyPreview(before: try HostCore.editedPolicy(live, HostRequest(.netPolicy, name: name)),
                                after: try HostCore.editedPolicy(live, edit.request(name)))
    }

    func openTerminal(_ name: String, session: String?) async throws -> String {
        guard name == "demo" else { throw HostError(.notFound, "no sandbox \(name)") }
        let c = TerminalHandoff.command(executable: "/opt/doz/bin/doz", store: DozerStore(root: URL(fileURLWithPath: storePath)),
                                        sandbox: name, session: session)
        lock.withLock { terminalCommands.append(c) }
        return "Terminal opened"
    }

    // 591 — browser terminals: each attach is answered by the next scripted fake (none left: refused).
    private var _attachments: [FakeAttachment] = []
    private(set) var attaches: [(name: String, session: String?, size: TermSize)] = []
    func script(_ a: FakeAttachment...) { lock.withLock { _attachments += a } }
    var attachCount: Int { lock.withLock { attaches.count } }
    var attachError: HostError? {
        get { lock.withLock { _attachError } }
        set { lock.withLock { _attachError = newValue } }
    }
    private var _attachError: HostError?
    var performedOps: [HostOp] { lock.withLock { performed.map(\.op) } }

    func attachTerminal(_ name: String, session: String?, size: TermSize) async throws -> any WebTerminalAttachment {
        let next: FakeAttachment? = lock.withLock {
            attaches.append((name, session, size))
            return _attachments.isEmpty ? nil : _attachments.removeFirst()
        }
        if let e = lock.withLock({ _attachError }) { throw e }
        guard let next else { throw HostError(.invalidPhase, "\(name) is off — `doz start \(name)` boots it") }
        return next
    }
}

/// A scripted attach connection: the test feeds what the "host" says and reads what the bridge sent.
final class FakeAttachment: WebTerminalAttachment, @unchecked Sendable {
    let start: WebAttachStart
    private let lock = NSLock()
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var iterator: AsyncStream<Data>.Iterator
    private var _sent: [UInt8] = []
    private(set) var closed = false

    init(_ start: WebAttachStart) {
        self.start = start
        (stream, continuation) = AsyncStream<Data>.makeStream()
        iterator = stream.makeAsyncIterator()
    }

    func feed(_ s: String) { continuation.yield(Data(s.utf8)) }
    func feed(_ d: Data) { continuation.yield(d) }
    /// The host closed the connection (a hibernation, or after the ended notice).
    func hangUp() { continuation.finish() }
    var sent: [UInt8] { lock.withLock { _sent } }
    var sentText: String { String(decoding: sent, as: UTF8.self) }

    func read() async -> Data? { await iterator.next() }
    func send(_ bytes: [UInt8]) { lock.withLock { _sent += bytes } }
    func close() {
        lock.withLock { closed = true }
        continuation.finish()
    }
}

extension HostOp {
    static let lifecycle: Set<HostOp> = [.start, .wake, .pause, .resume, .sleep, .hibernate, .shutdown, .reset, .rm]
}

// MARK: raw HTTP

struct RawResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
    var text: String { String(decoding: body, as: UTF8.self) }
    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

enum RawHTTP {
    static func connect(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    static func head(method: String, path: String, headers: [String: String], body: String?) -> Data {
        var s = "\(method) \(path) HTTP/1.1\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        if let body { s += "Content-Length: \(body.utf8.count)\r\n" }
        s += "Connection: close\r\n\r\n" + (body ?? "")
        return Data(s.utf8)
    }

    static func request(port: Int, method: String, path: String, headers: [String: String], body: String? = nil) throws -> RawResponse {
        let fd = try connect(port: port)
        defer { close(fd) }
        let d = head(method: method, path: path, headers: headers, body: body)
        _ = d.withUnsafeBytes { write(fd, $0.baseAddress, d.count) }
        var all = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            all.append(contentsOf: buf[0..<n])
        }
        return try parse(all, method: method)
    }

    static func parse(_ all: Data, method: String) throws -> RawResponse {
        guard let sep = all.range(of: Data("\r\n\r\n".utf8)) else { throw POSIXError(.EBADMSG) }
        let head = String(decoding: all[..<sep.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let status = Int(head[0].split(separator: " ")[1]) ?? 0
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let c = line.firstIndex(of: ":") else { continue }
            headers[line[..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        return RawResponse(status: status, headers: headers, body: Data(all[sep.upperBound...]))
    }
}

/// A long-lived request (the SSE stream), read incrementally.
final class RawStream {
    let fd: Int32
    private var seen = ""

    init(port: Int, path: String, headers: [String: String]) throws {
        fd = try RawHTTP.connect(port: port)
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var s = "GET \(path) HTTP/1.1\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "Accept: text/event-stream\r\n\r\n"
        let d = Data(s.utf8)
        _ = d.withUnsafeBytes { write(fd, $0.baseAddress, d.count) }
    }

    /// Everything read so far once `marker` appears (throws on timeout).
    func read(until marker: String, seconds: Double) throws -> String {
        let deadline = Date().addingTimeInterval(seconds)
        var buf = [UInt8](repeating: 0, count: 65536)
        while !seen.contains(marker) {
            guard Date() < deadline else { throw POSIXError(.ETIMEDOUT) }
            let n = Darwin.read(fd, &buf, buf.count)
            if n > 0 { seen += String(decoding: buf[0..<n], as: UTF8.self) } else if n == 0 { if !seen.contains(marker) { throw POSIXError(.ECONNRESET) } }
        }
        return seen
    }

    /// True when the server closes the connection within the time.
    func waitForClose(seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var buf = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline {
            let n = Darwin.read(fd, &buf, buf.count)
            if n == 0 { return true }
            if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK { return true }
        }
        return false
    }

    func close() { Darwin.close(fd) }
}
