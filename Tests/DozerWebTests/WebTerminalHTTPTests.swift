import Darwin
import Foundation
import DozerKit
import DozerHost
import XCTest
@testable import DozerWeb

/// 591 — the terminal socket on a REAL listener, driven by a raw WebSocket client (so every header —
/// Host, Origin, Cookie, the subprotocol — is exactly what the test says). The host side is a fake
/// attach connection the test scripts.
final class WebTerminalHTTPTests: XCTestCase {
    var server: DozerWebServer!
    var serveTask: Task<Void, Error>!
    let capability = try! WebBootstrapCapability(testingValue: "test-capability-abcdefghijklmnopqrstuvwxyz")
    let fake = FakeData()

    override func setUp() async throws {
        server = try await DozerWebServer.bind(data: fake, assets: try WebAssets.load(), version: "test",
                                                capability: capability, pollInterval: .milliseconds(200))
        let s = server!
        serveTask = Task { try await s.run() }
    }

    override func tearDown() async throws {
        await server?.close()
        _ = try? await serveTask?.value
        server = nil
    }

    var port: Int { server.origin.port }
    var host: String { server.origin.authority }
    var origin: String { server.origin.value }

    func request(_ path: String, _ headers: [String: String] = [:], method: String = "GET", body: String? = nil) throws -> RawResponse {
        var h = ["Host": host]
        for (k, v) in headers { h[k] = v }
        return try RawHTTP.request(port: port, method: method, path: path, headers: h, body: body)
    }

    /// A new browser session, from a fresh one-use link (each test may open several).
    func signIn() throws -> (String, String) {
        let s = server!
        let link = try awaitValue { await s.newLink() }
        let cap = String(try XCTUnwrap(link.fragment).dropFirst("cap=".count))
        let r = try request("/api/v1/session", ["Origin": origin, "Authorization": "Bearer \(cap)"], method: "POST")
        XCTAssertEqual(r.status, 200, r.text)
        let pair = String(try XCTUnwrap(r.header("set-cookie")).split(separator: ";")[0])
        let csrf = try XCTUnwrap((try JSONSerialization.jsonObject(with: r.body) as? [String: Any])?["csrf"] as? String)
        return (pair, csrf)
    }

    func ticket(_ cookie: String, _ csrf: String, sandbox: String = "demo", body: String = #"{"mode":"interactive","cols":100,"rows":30}"#) throws -> String {
        let r = try request("/api/v1/sandboxes/\(sandbox)/terminal-ticket",
                            ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf, "Content-Type": "application/json"], method: "POST", body: body)
        XCTAssertEqual(r.status, 200, r.text)
        let j = try XCTUnwrap(try JSONSerialization.jsonObject(with: r.body) as? [String: Any])
        XCTAssertEqual(j["expiresInSeconds"] as? Int, 30)
        return try XCTUnwrap(j["ticket"] as? String)
    }

    func socket(_ ticket: String?, cookie: String?, sandbox: String = "demo", headers: [String: String] = [:]) throws -> RawWebSocket {
        var h = ["Host": host, "Origin": origin]
        if let cookie { h["Cookie"] = cookie }
        if let ticket { h["Sec-WebSocket-Protocol"] = "doz-terminal.v1, doz-ticket.\(ticket)" }
        for (k, v) in headers { h[k] = v }
        return try RawWebSocket(port: port, path: "/api/v1/sandboxes/\(sandbox)/terminal-socket", headers: h.filter { !$0.value.isEmpty })
    }

    /// An open terminal on a scripted attachment.
    func open(_ a: FakeAttachment, body: String = #"{"mode":"interactive","cols":100,"rows":30}"#) throws -> (RawWebSocket, String, String) {
        fake.script(a)
        let (cookie, csrf) = try signIn()
        let ws = try socket(try ticket(cookie, csrf, body: body), cookie: cookie)
        XCTAssertEqual(ws.status, 101, ws.body)
        XCTAssertEqual(ws.headers["sec-websocket-protocol"], "doz-terminal.v1", "only the protocol is echoed — never the ticket")
        return (ws, cookie, csrf)
    }

    func wait(_ what: String, seconds: Double = 5, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return }; usleep(20_000) }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: the ticket

    func testATicketNeedsTheSessionOriginCSRFAndAStrictBody() throws {
        let (cookie, csrf) = try signIn()
        let path = "/api/v1/sandboxes/demo/terminal-ticket"
        let json = ["Content-Type": "application/json"]
        let good = #"{"mode":"interactive"}"#
        XCTAssertEqual(try request(path, ["Origin": origin, "X-Doz-CSRF": csrf].merging(json) { a, _ in a }, method: "POST", body: good).status, 401)
        XCTAssertEqual(try request(path, ["Cookie": cookie, "Origin": origin].merging(json) { a, _ in a }, method: "POST", body: good).status, 403)
        XCTAssertEqual(try request(path, ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": "wrong"].merging(json) { a, _ in a }, method: "POST", body: good).status, 403)
        XCTAssertEqual(try request(path, ["Cookie": cookie, "X-Doz-CSRF": csrf].merging(json) { a, _ in a }, method: "POST", body: good).status, 403)
        XCTAssertEqual(try request(path, ["Cookie": cookie, "Origin": "http://evil.example", "X-Doz-CSRF": csrf].merging(json) { a, _ in a }, method: "POST", body: good).status, 403)
        XCTAssertEqual(try request(path, ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf, "Content-Type": "text/plain"], method: "POST", body: good).status, 415)
        XCTAssertEqual(try request(path, ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf].merging(json) { a, _ in a }, method: "POST", body: #"{"mode":"root"}"#).status, 400)
        XCTAssertEqual(try request(path, ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf].merging(json) { a, _ in a }, method: "POST", body: #"{"mode":"interactive","argv":["sh"]}"#).status, 400)
        XCTAssertEqual(try request(path, ["Cookie": cookie], method: "GET").status, 404, "minted by POST only")
        let t = try ticket(cookie, csrf)
        XCTAssertTrue(WebRandom.isToken(t))
    }

    // MARK: the upgrade

    func testTheUpgradeRefusesEverythingButAFreshTicketOfThisSessionAndNeverSays101() throws {
        let (cookie, csrf) = try signIn()
        func refused(_ ws: RawWebSocket, _ status: Int, _ code: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(ws.status, status, what, file: file, line: line)
            XCTAssertTrue(ws.body.contains(code), "\(what): \(ws.body)", file: file, line: line)
            XCTAssertNil(ws.headers["sec-websocket-accept"], what, file: file, line: line)
        }
        refused(try socket(try ticket(cookie, csrf), cookie: cookie, headers: ["Origin": ""]), 403, "origin-rejected", "no Origin")
        refused(try socket(try ticket(cookie, csrf), cookie: cookie, headers: ["Origin": "http://evil.example"]), 403, "origin-rejected", "a foreign Origin")
        refused(try socket(try ticket(cookie, csrf), cookie: cookie, headers: ["Host": "localhost:\(port)"]), 403, "host-rejected", "a wrong Host")
        refused(try socket(try ticket(cookie, csrf), cookie: cookie, headers: ["Sec-Fetch-Site": "cross-site"]), 403, "cross-site", "cross-site")
        refused(try socket(try ticket(cookie, csrf), cookie: nil), 401, "unauthenticated", "no cookie")
        refused(try socket(nil, cookie: cookie), 401, "ticket-missing", "no ticket")
        refused(try socket("made-up-ticket-0123456789abcdef", cookie: cookie), 401, "ticket-rejected", "an unknown ticket")

        // Bound to the sandbox: presented on another sandbox's socket it is refused AND spent.
        let t1 = try ticket(cookie, csrf)
        refused(try socket(t1, cookie: cookie, sandbox: "other"), 401, "ticket-rejected", "another sandbox")
        refused(try socket(t1, cookie: cookie), 401, "ticket-used", "spent by the misuse")

        // Bound to the browser session: another session's cookie cannot use it.
        let t2 = try ticket(cookie, csrf)
        let other = try signIn().0
        refused(try socket(t2, cookie: other), 401, "ticket-rejected", "another browser session")

        // One use: the second presentation is refused.
        fake.script(FakeAttachment(.attached(session: "shell")))
        let t3 = try ticket(cookie, csrf)
        let ok = try socket(t3, cookie: cookie)
        XCTAssertEqual(ok.status, 101)
        refused(try socket(t3, cookie: cookie), 401, "ticket-used", "reuse")
        ok.close()

        // A plain GET of the socket route is not a terminal.
        let plain = try request("/api/v1/sandboxes/demo/terminal-socket", ["Cookie": cookie])
        XCTAssertEqual(plain.status, 400)
        XCTAssertTrue(plain.text.contains("upgrade-required"))
    }

    func awaitValue<T: Sendable>(_ f: @escaping @Sendable () async -> T) throws -> T {
        let box = Box<T>()
        let sem = DispatchSemaphore(value: 0)
        Task { box.value = await f(); sem.signal() }
        guard sem.wait(timeout: .now() + 5) == .success, let v = box.value else { throw POSIXError(.ETIMEDOUT) }
        return v
    }
    final class Box<T>: @unchecked Sendable { var value: T? }

    // MARK: the bridge

    func testATerminalRelaysBothWaysAndResizesAndInputCannotForgeFrames() throws {
        let a = FakeAttachment(.attached(session: "shell"))
        let (ws, _, _) = try open(a)
        XCTAssertTrue(try ws.readText(containing: #""headline":"Attaching…""#).contains(#""session":"shell""#))
        a.feed("\u{1B}c$ hello")                                             // the SNAPSHOT, then output
        XCTAssertEqual(try ws.readBinary(), Array("\u{1B}c$ hello".utf8))
        XCTAssertTrue(try ws.readText(containing: #""kind":"none""#).contains(#""phase":"running""#))
        let at = try XCTUnwrap(fake.attaches.first)
        XCTAssertEqual(at.name, "demo")
        XCTAssertEqual(at.size, TermSize(cols: 100, rows: 30), "the first attach has the page's size")
        try ws.sendBinary(Array("ls\r".utf8) + [0xFF, 0x52, 0, 1, 0, 1])       // a forged RESIZE inside input
        try ws.sendText(#"{"t":"resize","cols":132,"rows":43}"#)
        try ws.sendText(#"{"t":"ping"}"#)
        wait("input and the resize") { a.sent.count >= 3 + 4 + 6 }
        XCTAssertEqual(a.sent, Array("ls\r".utf8) + [0x52, 0, 1, 0, 1] + ClientWire.resize(TermSize(cols: 132, rows: 43)),
                       "0xFF is removed, so the forged bytes are plain input")
        XCTAssertEqual(fake.performedOps, [], "typing into a running sandbox is not an operation")
        ws.close()
        wait("the attach closed with the socket") { a.closed }
    }

    func testWatchOnlyNeverReachesTheHostAndNeverResizesTheSession() throws {
        fake.phase = "hibernated"
        let a = FakeAttachment(.held(session: "shell", phase: "hibernated"))
        let (ws, _, _) = try open(a, body: #"{"mode":"watch","cols":100,"rows":30}"#)
        let s = try ws.readText(containing: #""kind":"hibernated""#)
        XCTAssertTrue(s.contains(#""headline":"Sandbox hibernated""#), s)
        XCTAssertTrue(s.contains(#""mode":"watch""#))
        XCTAssertEqual(fake.attaches.first?.size, TermSize(cols: 0, rows: 0), "HELLO 0×0 keeps the session's size")
        try ws.sendBinary(Array("x".utf8))
        try ws.sendText(#"{"t":"resize","cols":50,"rows":20}"#)
        usleep(300_000)
        XCTAssertEqual(a.sent, [])
        XCTAssertEqual(fake.performedOps, [], "a watcher's key never wakes")
        ws.close()
    }

    /// 599 (594.B1/B2): a bridge's notice becomes a `notice` text frame (the page toasts it) — never bytes
    /// on the screen, even when a read cuts it.
    func testABridgeNoticeIsATextFrameNeverScreenBytes() throws {
        let a = FakeAttachment(.attached(session: "shell"))
        let (ws, _, _) = try open(a)
        _ = try ws.readText(containing: #""headline":"Attaching…""#)
        let notice = Array(ClientWire.notice(BridgeNotice("clipboard", "demo copied 22 chars")))
        a.feed(Data(Array("one".utf8) + notice.prefix(12)))
        a.feed(Data(Array(notice.dropFirst(12)) + Array("two".utf8)))
        var screen: [UInt8] = []
        var text = ""
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !(String(decoding: screen, as: UTF8.self).contains("two") && text.contains(#""t":"notice""#)) {
            let (op, p) = try ws.readFrame()
            if op == 2 { screen += p }
            if op == 1, String(decoding: p, as: UTF8.self).contains(#""t":"notice""#) { text = String(decoding: p, as: UTF8.self) }
        }
        XCTAssertEqual(String(decoding: screen, as: UTF8.self), "onetwo", "nothing of the notice reaches the screen")
        XCTAssertTrue(text.contains(#""kind":"clipboard""#) && text.contains(#""text":"demo copied 22 chars""#), text)
        ws.close()
    }

    func testTheEndNoticeEndsTheTerminalAndNeverReachesTheScreen() throws {
        let a = FakeAttachment(.attached(session: "shell"))
        let (ws, _, _) = try open(a)
        let notice = Array(ClientWire.endedNotice(.exited(3), text: "the shell session has ended (exit 3)"))
        a.feed(Data(Array("bye".utf8) + notice.prefix(9)))                // split inside the sentinel
        a.feed(Data(notice.dropFirst(9)))
        a.hangUp()
        XCTAssertEqual(try ws.readBinary(), Array("bye".utf8))
        let ended = try ws.readText(containing: #""t":"ended""#)
        XCTAssertTrue(ended.contains(#""code":3"#), ended)
        XCTAssertTrue(ended.contains("the shell session has ended (exit 3)"))
        XCTAssertEqual(try ws.readClose(), 1000)
        XCTAssertEqual(fake.attachCount, 1, "an ended session is not reattached")
    }

    func testARefusedAttachIsAnErrorFrame() throws {
        // A session that is not there (an off sandbox is the boot view instead — see below).
        fake.attachError = HostError(.notFound, "no session nope in demo")
        let (cookie, csrf) = try signIn()
        let ws = try socket(try ticket(cookie, csrf, body: #"{"mode":"interactive","session":"nope"}"#), cookie: cookie)
        XCTAssertEqual(ws.status, 101)
        let e = try ws.readText(containing: #""t":"error""#)
        XCTAssertTrue(e.contains("not-found"), e)
        XCTAssertEqual(try ws.readClose(), 1000)
    }

    func testWhileNotRunningAKeystrokeWakesAndAReportNeverDoes() throws {
        fake.hold = true                                                      // the wake stays in flight
        defer { fake.hold = false }
        fake.phase = "hibernated"
        let a = FakeAttachment(.held(session: "shell", phase: "hibernated"))
        let (ws, _, _) = try open(a)
        _ = try ws.readText(containing: #""headline":"Sandbox hibernated · press any key to wake""#)
        for report in ["\u{1B}[I", "\u{1B}[O", "\u{1B}[12;40R", "\u{1B}[?62;22c", "\u{1B}[<35;1;1M"] {
            try ws.sendBinary(Array(report.utf8))
        }
        _ = try ws.readText(containing: #""reportsIgnored":5"#)
        XCTAssertEqual(fake.performedOps, [], "focus and other reports never wake (the 541 rule)")
        try ws.sendBinary(Array("x".utf8))
        let s = try ws.readText(containing: #""keystrokeWakes":1"#)
        XCTAssertTrue(s.contains(#""headline":"Waking the sandbox…""#), s)
        wait("the wake") { fake.performedOps == [.wake] }
        XCTAssertEqual(fake.performed.first?.name, "demo")
        try ws.sendBinary(Array("y".utf8))                                    // a second key while it wakes: nothing new
        usleep(200_000)
        XCTAssertEqual(fake.performedOps, [.wake])
        XCTAssertEqual(a.sent, [], "keys for a sleeping sandbox are dropped, never queued")
        ws.close()
    }

    // MARK: 591 polish — the engine's sandboxed frame (T2)

    func testTheTerminalFrameHasItsOwnPolicyAndOnlyItsFilesAreLoadableFromAnOpaqueOrigin() throws {
        let f = try request("/terminal-frame", ["Sec-Fetch-Site": "same-origin", "Sec-Fetch-Dest": "iframe"])
        XCTAssertEqual(f.status, 200)
        XCTAssertEqual(f.header("x-frame-options"), "SAMEORIGIN")
        let csp = try XCTUnwrap(f.header("content-security-policy"))
        XCTAssertTrue(csp.contains("connect-src 'none'") && csp.contains("frame-ancestors 'self'") && csp.contains("'wasm-unsafe-eval'"), csp)
        XCTAssertEqual(f.header("cache-control"), "no-store")
        XCTAssertEqual(try request("/terminal-frame", method: "POST").status, 404)
        let assets = try WebAssets.load().assets.keys
        let frameJS = try XCTUnwrap(assets.first { $0.hasPrefix("/assets/frame-") && $0.hasSuffix(".js") })
        let engine = try XCTUnwrap(assets.first { $0.hasPrefix("/assets/vendor-ghostty-web-") })
        let appJS = try XCTUnwrap(assets.first { $0.hasPrefix("/assets/app-") && $0.hasSuffix(".js") })
        let wasm = try XCTUnwrap(assets.first { $0.hasSuffix(".wasm") })
        // What the opaque-origin frame loads: cross-site, Origin null — served, with CORP cross-origin.
        for p in [frameJS, engine] {
            let r = try request(p, ["Sec-Fetch-Site": "cross-site", "Origin": "null"])
            XCTAssertEqual(r.status, 200, p)
            XCTAssertEqual(r.header("cross-origin-resource-policy"), "cross-origin", p)
            XCTAssertEqual(try request(p, ["Host": "evil.example"]).status, 403, "the Host check still comes first")
        }
        // Everything else keeps the page's rules: no cross-site load, CORP same-origin.
        for p in [appJS, wasm, "/"] {
            XCTAssertEqual(try request(p, ["Sec-Fetch-Site": "cross-site"]).status, 403, p)
            XCTAssertEqual(try request(p).header("cross-origin-resource-policy"), "same-origin", p)
        }
    }

    /// 593: the icon sprite — generated from the pinned Lucide files: a same-origin SVG with the
    /// page's rules (no cross-site load), holding only <symbol>s of drawing elements, named in the page.
    func testTheIconSpriteIsASameOriginSVGOfSymbolsOnly() throws {
        let web = try WebAssets.load()
        let sprite = try XCTUnwrap(web.assets.values.first { $0.publicPath.hasPrefix("/assets/vendor-lucide-icons-") })
        XCTAssertEqual(sprite.mimeType, "image/svg+xml")
        let text = String(decoding: sprite.data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("<svg xmlns=\"http://www.w3.org/2000/svg\">"))
        for id in ["play", "pause", "moon", "moon-star", "sun", "power", "rotate-ccw", "trash-2", "square-terminal", "copy", "layout-template",
                   "panel-right", "camera", "history", "git-fork", "shield", "clipboard", "refresh-cw", "settings", "log-out", "flame",
                   "badge-check", "heart-pulse", "box", "layout-grid", "layers", "list-checks", "key-round", "chart-line", "activity", "stethoscope"] {
            XCTAssertTrue(text.contains("<symbol id=\"\(id)\" viewBox=\"0 0 24 24\">"), id)
        }
        for forbidden in ["<script", "href", "on", "style", "<foreignObject", "<image", "url("] where forbidden != "on" {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        XCTAssertNil(text.range(of: #"\son[a-z]+="#, options: .regularExpression), "no event handler")
        let index = String(decoding: try XCTUnwrap(web.assets["/"]).data, as: UTF8.self)
        XCTAssertTrue(index.contains("content=\"\(sprite.publicPath)\""), "the page names the hashed sprite")
        let r = try request(sprite.publicPath, ["Sec-Fetch-Site": "same-origin", "Sec-Fetch-Dest": "image"])
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.header("content-type"), "image/svg+xml")
        XCTAssertEqual(r.header("x-content-type-options"), "nosniff")
        XCTAssertEqual(r.header("cross-origin-resource-policy"), "same-origin")
        XCTAssertEqual(try request(sprite.publicPath, ["Sec-Fetch-Site": "cross-site"]).status, 403, "not loadable by another site")
    }

    // MARK: 591 polish — the boot view, the wake note

    func testAnOffSandboxShowsItsBootThenTheImagesSessionInTheSamePane() throws {
        fake.phase = "off"
        let (cookie, csrf) = try signIn()
        let ws = try socket(try ticket(cookie, csrf), cookie: cookie)            // nothing scripted: the attach says "off"
        XCTAssertEqual(ws.status, 101)
        _ = try ws.readText(containing: #""kind":"shutDown""#)
        // A start begins: the host runs, its events and the console flow.
        fake.hostUp = true
        usleep(400_000)                                                         // the bridge subscribes (it polls every 200 ms)
        fake.emit(HostEvent(kind: .phase, sandbox: "demo", text: "booting", phase: "booting"))
        _ = try ws.readText(containing: #""kind":"boot""#)
        var seen = ""
        func readUntil(_ needle: String) throws {
            let end = Date().addingTimeInterval(5)
            while !seen.contains(needle) {
                guard Date() < end else { XCTFail("no \(needle) in \(seen.debugDescription)"); throw POSIXError(.ETIMEDOUT) }
                let (op, p) = try ws.readFrame(seconds: 5)
                if op == 2 { seen += String(decoding: p, as: UTF8.self) }
            }
        }
        try readUntil("── starting demo ──")
        // 593: animated (the default) — a spinner on the step under way, the pull's bar, the output tail.
        let digest = String(repeating: "0123456789abcdef", count: 4)
        fake.emit(HostEvent(kind: .note, sandbox: "demo", text: "baking image pi from docker.io/library/node@sha256:\(digest) (one-time)"))
        fake.emit(HostEvent(kind: .started, sandbox: "demo", text: "pulled the base image node"))
        try readUntil("⠋\u{1B}[0m pulled the base image node")
        var p = HostEvent(kind: .progress, sandbox: "demo", text: "pulling node@0123456789ab", completedBytes: 40_000_000, totalBytes: 100_000_000)
        p.completedItems = 1
        p.totalItems = 3
        fake.emit(p)
        try readUntil("40 / 100 MB")
        XCTAssertTrue(seen.contains("████████░░░░░░░░░░░░") && seen.contains("(1/3 layers)"), "the download's bar and layers")
        fake.emit(HostEvent(kind: .output, sandbox: "demo", text: "npm \u{1B}[31mWARN\u{1B}]52;c;eA==\u{07} deprecated"))
        try readUntil("deprecated")
        usleep(400_000)                                                         // a few ticks: the spinner moves
        p.completedBytes = 100_000_000
        p.completedItems = 3
        fake.emit(p)
        fake.emit(HostEvent(kind: .step, sandbox: "demo", text: "pulled the base image node", milliseconds: 2100))
        try readUntil("✓\u{1B}[0m pulled the base image node")
        XCTAssertTrue(seen.contains("pulled node@0123456789ab: 100 MB in"), "the download's summary line")
        XCTAssertTrue(seen.contains("node@0123456789ab (one-time)") && !seen.contains(digest), "digests trimmed to 12")
        XCTAssertTrue(["⠙", "⠹", "⠸"].contains { seen.contains($0) }, "the spinner ticked")
        XCTAssertFalse(seen.contains("\u{1B}]52") || seen.contains("\u{1B}[31m"), "the guest's output is inert")
        fake.emit(HostEvent(kind: .step, sandbox: "demo", text: "VM created and booted", milliseconds: 252))
        wait("the console subscription") { fake.consoleSubscribers >= 1 }
        fake.console("[    0.000000] Linux version 6.18")
        fake.console("evil \u{1B}]52;c;cHduZWQ=\u{07}\u{1B}]8;;javascript:x\u{1B}\\link\u{9B}2J done")
        try readUntil("done")
        XCTAssertTrue(seen.contains("✓\u{1B}[0m VM created and booted"))
        XCTAssertTrue(seen.contains("[    0.000000] Linux version 6.18"))
        XCTAssertTrue(seen.contains("evil ]52;c;cHduZWQ=]8;;javascript:x\\link2J done"), "guest console text is inert: no ESC, BEL or C1 survives")
        // It runs: the image's own session is opened, then attached in the same pane.
        let a = FakeAttachment(.attached(session: "shell"))
        fake.script(a)
        fake.phase = "running"
        fake.emit(HostEvent(kind: .phase, sandbox: "demo", text: "running", phase: "running"))
        try readUntil("── the ")
        _ = try ws.readText(containing: #""t":"boot-done""#)
        wait("open-session and the attach") { fake.performedOps.contains(.openSession) && fake.attachCount == 2 }
        XCTAssertNil(fake.performed.first { $0.op == .openSession }?.argv, "the image's own session")
        a.feed(Data(WebTerminalWire.snapshotPrefix + Array("$ ".utf8)))
        let snap = try ws.readBinary()
        XCTAssertTrue(snap.starts(with: Array("\u{1B}[?1049l\u{1B}[!p".utf8)), "the first SNAPSHOT keeps the boot log in the scrollback")
        XCTAssertFalse(String(decoding: snap, as: UTF8.self).contains("\u{1B}c"), "no full reset")
        XCTAssertFalse(String(decoding: snap, as: UTF8.self).contains("\u{1B}[3J"), "the scrollback is not cleared")
        _ = try ws.readText(containing: #""kind":"none""#)
        ws.close()
    }

    /// 593: ui.progress = plain (here: $DOZ_PROGRESS in the UI's environment) — one line per step, a
    /// download's summary, no spinner, no bar, no output tail.
    func testPlainProgressInTheBootView() async throws {
        await server.close()
        _ = try? await serveTask.value
        server = try await DozerWebServer.bind(data: fake, assets: try WebAssets.load(), version: "test",
                                                settings: WebSettingsStore(environment: ["DOZ_PROGRESS": "plain"]),
                                                capability: capability, pollInterval: .milliseconds(200))
        let s = server!
        serveTask = Task { try await s.run() }
        fake.phase = "off"
        let (cookie, csrf) = try signIn()
        let ws = try socket(try ticket(cookie, csrf), cookie: cookie)
        XCTAssertEqual(ws.status, 101)
        _ = try ws.readText(containing: #""kind":"shutDown""#)
        fake.hostUp = true
        usleep(400_000)
        fake.emit(HostEvent(kind: .phase, sandbox: "demo", text: "booting", phase: "booting"))
        _ = try ws.readText(containing: #""kind":"boot""#)
        var seen = ""
        func readUntil(_ needle: String) throws {
            let end = Date().addingTimeInterval(5)
            while !seen.contains(needle) {
                guard Date() < end else { XCTFail("no \(needle) in \(seen.debugDescription)"); throw POSIXError(.ETIMEDOUT) }
                let (op, p) = try ws.readFrame(seconds: 5)
                if op == 2 { seen += String(decoding: p, as: UTF8.self) }
            }
        }
        try readUntil("── starting demo ──")
        fake.emit(HostEvent(kind: .started, sandbox: "demo", text: "pulled the base image node"))
        fake.emit(HostEvent(kind: .progress, sandbox: "demo", text: "pulling node@0123456789ab", completedBytes: 40_000_000, totalBytes: 100_000_000))
        fake.emit(HostEvent(kind: .output, sandbox: "demo", text: "added 3 packages"))
        usleep(400_000)
        fake.emit(HostEvent(kind: .progress, sandbox: "demo", text: "pulling node@0123456789ab", completedBytes: 100_000_000, totalBytes: 100_000_000))
        fake.emit(HostEvent(kind: .step, sandbox: "demo", text: "pulled the base image node", milliseconds: 2100))
        try readUntil("[doz] pulled the base image node — 2100 ms")
        XCTAssertTrue(seen.contains("[doz] pulled node@0123456789ab: 100 MB in"), "the download's summary line")
        for animated in ["⠋", "⠙", "█", "░", "added 3 packages", "\u{1B}[J", "\u{1B}[1A"] {
            XCTAssertFalse(seen.contains(animated), "plain: no \(animated.debugDescription)")
        }
        ws.close()
    }

    func testAWakeByKeySaysHowLongItTook() throws {
        fake.phase = "hibernated"
        let a = FakeAttachment(.held(session: "shell", phase: "hibernated"))
        let (ws, _, _) = try open(a)
        _ = try ws.readText(containing: #""kind":"hibernated""#)
        try ws.sendBinary(Array("x".utf8))
        wait("the wake") { fake.performedOps == [.wake] }
        usleep(300_000)
        fake.phase = "running"
        a.feed("\u{1B}cscreen")                                                   // the host attached it: the SNAPSHOT
        let s = try ws.readText(containing: #""notice":"woke in "#)
        XCTAssertTrue(s.contains(#""kind":"none""#), s)
        ws.close()
    }

    func testAPausedAttachedTerminalResumesOnAKey() throws {
        let a = FakeAttachment(.attached(session: "shell"))
        let (ws, _, _) = try open(a)
        a.feed("screen")
        _ = try ws.readBinary()
        _ = try ws.readText(containing: #""kind":"none""#)
        fake.bump()                                                            // the fake's overview now says paused
        _ = try ws.readText(containing: #""headline":"Sandbox paused · press any key to resume""#, seconds: 5)
        try ws.sendBinary(Array("k".utf8))
        wait("the resume") { fake.performedOps == [.resume] }
        XCTAssertEqual(a.sent, [], "the key that resumes is not typed into the frozen guest")
        ws.close()
    }

    func testAHibernateReattachesOnTheSameSocket() throws {
        let first = FakeAttachment(.attached(session: "shell"))
        let second = FakeAttachment(.held(session: "shell", phase: "hibernated"))
        let (ws, _, _) = try open(first)
        fake.script(second)                                                    // what the reattach gets
        first.feed("before")
        XCTAssertEqual(try ws.readBinary(), Array("before".utf8))
        first.hangUp()                                                         // Hibernate closes the host connection
        _ = try ws.readText(containing: #""kind":"hibernated""#)
        wait("the reattach") { fake.attachCount == 2 }
        second.feed("\u{1B}c" + "before")                                      // woken: the host attaches it and sends the SNAPSHOT
        XCTAssertEqual(try ws.readBinary(), Array("\u{1B}cbefore".utf8))
        _ = try ws.readText(containing: #""kind":"none""#)
        try ws.sendBinary(Array("after\r".utf8))
        wait("typing after the wake") { second.sentText == "after\r" }
        ws.close()
    }

    func testOversizeFramesBadFramesAndFloodsClose() throws {
        do {
            let a = FakeAttachment(.attached(session: "shell"))
            let (ws, _, _) = try open(a)
            try ws.sendBinary([UInt8](repeating: 0x61, count: 70 * 1024))
            // NIO answers 1009 and closes; with the oversize payload unread the close can arrive as a
            // reset instead — either way the socket is gone and nothing reached the host.
            let code = try? ws.readClose()
            XCTAssertTrue(code == 1009 || code == nil, "a frame over 64 KiB: \(String(describing: code))")
            XCTAssertThrowsError(try ws.readFrame(seconds: 2), "the connection is closed")
            XCTAssertEqual(a.sent, [])
        }
        do {
            let (ws, _, _) = try open(FakeAttachment(.attached(session: "shell")))
            try ws.sendText(#"{"t":"exec","argv":["sh"]}"#)
            XCTAssertEqual(try ws.readClose(), 1008, "an unknown message")
        }
        do {
            let a = FakeAttachment(.attached(session: "shell"))
            let (ws, _, _) = try open(a)
            // A real flood: up to 64 × 60 KiB (3.75 MiB), stopping when the server closes. It used to
            // send 18 × 60 KiB (≈ 1.05 MiB, 5% over the 1 MiB burst) — on a loaded CI runner the
            // sends took long enough for the refill to cover that 5%, every frame reached the host
            // (1,105,920 bytes) and the budget never tripped (2026-10-02). What matters: the flood is
            // CUT OFF, and what got through is the burst plus at most a refill's slack.
            let frame = 60 * 1024
            var frames = 0
            do { for _ in 0..<64 { try ws.sendBinary([UInt8](repeating: 0x61, count: frame)); frames += 1 } } catch {}
            // 1008, or a reset when the close races the frames still in flight — either way it is gone.
            let code = try? ws.readClose(skipOther: true)
            XCTAssertTrue(code == 1008 || code == nil, "input over the budget: \(String(describing: code))")
            XCTAssertThrowsError(try ws.readFrame(seconds: 2), "the connection is closed")
            XCTAssertLessThan(a.sent.count, frames * frame, "the flood was cut off (\(a.sent.count) of \(frames * frame))")
            XCTAssertLessThanOrEqual(a.sent.count, (1 << 20) + 512 * 1024, "the burst plus a refill's slack")
        }
    }

    func testSigningOutClosesThatSessionsTerminals() throws {
        let (ws, cookie, csrf) = try open(FakeAttachment(.attached(session: "shell")))
        let out = try request("/api/v1/session", ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf], method: "DELETE")
        XCTAssertEqual(out.status, 204)
        XCTAssertEqual(try ws.readClose(skipOther: true), 1008)
    }

    func testShutdownClosesTerminals() async throws {
        let (ws, _, _) = try open(FakeAttachment(.attached(session: "shell")))
        await server.close()
        XCTAssertEqual(try ws.readClose(skipOther: true), 1001)
    }
}

// MARK: a raw WebSocket client (RFC 6455, client side: masked frames)

final class RawWebSocket {
    let fd: Int32
    private(set) var status = 0
    private(set) var headers: [String: String] = [:]
    private(set) var body = ""
    private var buffer: [UInt8] = []

    init(port: Int, path: String, headers h: [String: String]) throws {
        fd = try RawHTTP.connect(port: port)
        var key = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&key, 16)
        var s = "GET \(path) HTTP/1.1\r\n"
        for (k, v) in h { s += "\(k): \(v)\r\n" }
        s += "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(Data(key).base64EncodedString())\r\n\r\n"
        try write(Array(s.utf8))
        // The response head.
        while true {
            if let r = findCRLFCRLF() {
                let head = String(decoding: buffer[..<r], as: UTF8.self).components(separatedBy: "\r\n")
                buffer = Array(buffer[(r + 4)...])
                status = Int(head[0].split(separator: " ")[1]) ?? 0
                for line in head.dropFirst() {
                    guard let c = line.firstIndex(of: ":") else { continue }
                    headers[line[..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
                }
                break
            }
            try fill()
        }
        if status != 101, let n = headers["content-length"].flatMap(Int.init) {
            while buffer.count < n { try fill() }
            body = String(decoding: buffer.prefix(n), as: UTF8.self)
            buffer.removeFirst(n)
        }
    }

    private func findCRLFCRLF() -> Int? {
        guard buffer.count >= 4 else { return nil }
        for i in 0...(buffer.count - 4) where buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10 { return i }
        return nil
    }

    private func fill() throws {
        var b = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.read(fd, &b, b.count)
        if n <= 0 { throw POSIXError(n == 0 ? .ECONNRESET : .ETIMEDOUT) }
        buffer += b[0..<n]
    }

    private func write(_ bytes: [UInt8]) throws {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { throw POSIXError(.EPIPE) }
            off += n
        }
    }

    func send(opcode: UInt8, _ payload: [UInt8]) throws {
        var f: [UInt8] = [0x80 | opcode]
        if payload.count < 126 { f.append(0x80 | UInt8(payload.count)) }
        else if payload.count < 65536 { f += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] }
        else { f.append(0x80 | 127); for i in (0..<8).reversed() { f.append(UInt8((UInt64(payload.count) >> (UInt64(i) * 8)) & 0xFF)) } }
        var mask = [UInt8](repeating: 0, count: 4)
        arc4random_buf(&mask, 4)
        f += mask
        f += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        try write(f)
    }
    func sendBinary(_ b: [UInt8]) throws { try send(opcode: 2, b) }
    func sendText(_ s: String) throws { try send(opcode: 1, Array(s.utf8)) }

    /// The next frame from the server (unmasked), as (opcode, payload).
    func readFrame(seconds: Double = 5) throws -> (UInt8, [UInt8]) {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if buffer.count >= 2 {
                let op = buffer[0] & 0x0F
                var len = Int(buffer[1] & 0x7F), at = 2
                if len == 126, buffer.count >= 4 { len = Int(buffer[2]) << 8 | Int(buffer[3]); at = 4 }
                else if len == 127, buffer.count >= 10 { len = (2..<10).reduce(0) { $0 << 8 | Int(buffer[$1]) }; at = 10 }
                if (len < 126 || at > 2), buffer.count >= at + len {
                    let payload = Array(buffer[at..<(at + len)])
                    buffer.removeFirst(at + len)
                    return (op, payload)
                }
            }
            guard Date() < deadline else { throw POSIXError(.ETIMEDOUT) }
            try fill()
        }
    }

    /// Text frames until one contains `needle` (binary frames in between are skipped).
    func readText(containing needle: String, seconds: Double = 5) throws -> String {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let (op, p) = try readFrame(seconds: deadline.timeIntervalSinceNow)
            if op == 8 { throw POSIXError(.ECONNRESET) }
            if op == 1 { let s = String(decoding: p, as: UTF8.self); if s.contains(needle) { return s } }
        }
        throw POSIXError(.ETIMEDOUT)
    }

    /// The next binary frame (text frames in between are skipped).
    func readBinary(seconds: Double = 5) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let (op, p) = try readFrame(seconds: deadline.timeIntervalSinceNow)
            if op == 2 { return p }
            if op == 8 { throw POSIXError(.ECONNRESET) }
        }
        throw POSIXError(.ETIMEDOUT)
    }

    /// The close code (the next frame must be a close, unless `skipOther`).
    func readClose(seconds: Double = 5, skipOther: Bool = true) throws -> Int {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let (op, p) = try readFrame(seconds: deadline.timeIntervalSinceNow)
            if op == 8 { return p.count >= 2 ? Int(p[0]) << 8 | Int(p[1]) : 1005 }
            if !skipOther { throw POSIXError(.EBADMSG) }
        }
        throw POSIXError(.ETIMEDOUT)
    }

    private var closed = false
    func close() { if !closed { closed = true; Darwin.close(fd) } }
    deinit { close() }
}
