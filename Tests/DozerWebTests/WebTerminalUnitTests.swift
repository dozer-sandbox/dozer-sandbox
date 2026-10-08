import Foundation
import DozerKit
import DozerHost
import XCTest
@testable import DozerWeb

/// 591 — the browser terminals' rules as unit tests: the ticket, the frames, the 541 classifier,
/// the cover, the upgrade checks and the vendored-asset class (591.01-DESIGN.md).
final class WebTerminalUnitTests: XCTestCase {
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 2_000_000)
    }

    func rejection(_ f: () async throws -> Void) async -> WebRejection? {
        do { try await f(); return nil } catch let r as WebRejection { return r } catch { return nil }
    }

    // MARK: the ticket

    func testATicketWorksOnceForItsSessionAndSandboxWithin30Seconds() async throws {
        let clock = Clock()
        let store = WebTerminalTicketStore(now: { clock.now })
        let t = try await store.mint(cookie: "cookie-a", sandbox: "demo", session: "shell", mode: .interactive, size: TermSize(cols: 100, rows: 30))
        XCTAssertTrue(WebRandom.isToken(t))
        XCTAssertGreaterThanOrEqual(t.utf8.count, 43, "256 bits, base64url")
        let g = try await store.consume(t, cookie: "cookie-a", sandbox: "demo")
        XCTAssertEqual(g, WebTerminalGrant(cookie: "cookie-a", sandbox: "demo", session: "shell", mode: .interactive, size: TermSize(cols: 100, rows: 30)))
        let again = await rejection { _ = try await store.consume(t, cookie: "cookie-a", sandbox: "demo") }
        XCTAssertEqual(again, .ticketUsed)
        let unknown = await rejection { _ = try await store.consume("not-a-real-ticket-0123456789", cookie: "cookie-a", sandbox: "demo") }
        XCTAssertEqual(unknown, .ticketRejected)

        // Expired after 30 s — and presenting it spends it.
        let old = try await store.mint(cookie: "cookie-a", sandbox: "demo", session: nil, mode: .watch, size: nil)
        clock.now = clock.now.addingTimeInterval(30.5)
        let expired = await rejection { _ = try await store.consume(old, cookie: "cookie-a", sandbox: "demo") }
        XCTAssertEqual(expired, .ticketExpired)
        let spent = await rejection { _ = try await store.consume(old, cookie: "cookie-a", sandbox: "demo") }
        XCTAssertEqual(spent, .ticketUsed)
    }

    func testATicketIsBoundToTheBrowserSessionAndTheSandboxAndBurntByAMisuse() async throws {
        let store = WebTerminalTicketStore()
        let t = try await store.mint(cookie: "cookie-a", sandbox: "demo", session: nil, mode: .interactive, size: nil)
        let otherSession = await rejection { _ = try await store.consume(t, cookie: "cookie-b", sandbox: "demo") }
        XCTAssertEqual(otherSession, .ticketRejected)
        let burnt = await rejection { _ = try await store.consume(t, cookie: "cookie-a", sandbox: "demo") }
        XCTAssertEqual(burnt, .ticketUsed, "a ticket tried by another session is spent")
        let u = try await store.mint(cookie: "cookie-a", sandbox: "demo", session: nil, mode: .interactive, size: nil)
        let otherSandbox = await rejection { _ = try await store.consume(u, cookie: "cookie-a", sandbox: "other") }
        XCTAssertEqual(otherSandbox, .ticketRejected)
    }

    func testPendingTicketsAreBoundedPerSession() async throws {
        let store = WebTerminalTicketStore(maximumPendingPerSession: 3)
        for _ in 0..<3 { _ = try await store.mint(cookie: "a", sandbox: "demo", session: nil, mode: .interactive, size: nil) }
        let over = await rejection { _ = try await store.mint(cookie: "a", sandbox: "demo", session: nil, mode: .interactive, size: nil) }
        XCTAssertEqual(over, .tooManyTickets)
        XCTAssertEqual(over?.status, 503)
        _ = try await store.mint(cookie: "b", sandbox: "demo", session: nil, mode: .interactive, size: nil)   // another session is unaffected
    }

    func testTheTicketRequestIsDecodedStrictly() throws {
        func d(_ s: String) throws -> WebTerminalTicketRequest { try WebTerminalTicketRequest.decode(Data(s.utf8)) }
        XCTAssertEqual(try d(#"{"mode":"interactive"}"#), WebTerminalTicketRequest(session: nil, mode: .interactive, size: nil))
        XCTAssertEqual(try d(#"{"mode":"interactive","session":"shell","cols":120,"rows":40}"#),
                       WebTerminalTicketRequest(session: "shell", mode: .interactive, size: TermSize(cols: 120, rows: 40)))
        XCTAssertEqual(try d(#"{"mode":"watch","cols":120,"rows":40}"#).size, nil, "a watcher never sizes the session")
        for bad in [#"{}"#, #"{"mode":"admin"}"#, #"{"mode":"interactive","argv":["sh"]}"#, #"{"mode":"interactive","session":"../x"}"#,
                    #"{"mode":"interactive","session":".hidden"}"#, #"{"mode":"interactive","cols":1,"rows":10}"#,
                    #"{"mode":"interactive","cols":80}"#, #"{"mode":"interactive","cols":"80","rows":"24"}"#,
                    #"{"mode":"interactive","cols":80.5,"rows":24}"#, #"{"mode":"interactive","cols":true,"rows":24}"#,
                    #"{"mode":"interactive","cols":80,"rows":501}"#, #"[1]"#, "not json"] {
            XCTAssertThrowsError(try d(bad), bad)
        }
    }

    // MARK: the upgrade checks

    func md(host: String? = "127.0.0.1:50123", origin: String? = "http://127.0.0.1:50123", site: String? = nil,
            cookie: String? = "doz_ui_50123=abcDEF0123456789abcDEF0123456789") -> WebRequestMetadata {
        WebRequestMetadata(method: .get, host: host, origin: origin, secFetchSite: site, cookie: cookie)
    }

    func testTheUpgradeNeedsExactHostOriginACookieAndOneTicket() throws {
        let o = try WebOrigin(port: 50123)
        let ok = ["doz-terminal.v1, doz-ticket.TICKETabc123"]
        let (c, t) = try WebSecurity.validateTerminalUpgrade(md(), o, subprotocols: ok)
        XCTAssertEqual(c, "abcDEF0123456789abcDEF0123456789")
        XCTAssertEqual(t, "TICKETabc123")
        func refused(_ m: WebRequestMetadata, _ p: [String] = ok) -> WebRejection? {
            do { _ = try WebSecurity.validateTerminalUpgrade(m, o, subprotocols: p); return nil } catch { return error as? WebRejection }
        }
        XCTAssertEqual(refused(md(host: "localhost:50123")), .hostRejected)
        XCTAssertEqual(refused(md(host: "evil.example:50123")), .hostRejected)
        XCTAssertEqual(refused(md(origin: nil)), .originRejected, "Origin is REQUIRED on the upgrade")
        XCTAssertEqual(refused(md(origin: "http://evil.example")), .originRejected)
        XCTAssertEqual(refused(md(origin: "http://localhost:50123")), .originRejected)
        XCTAssertEqual(refused(md(site: "cross-site")), .crossSite)
        XCTAssertEqual(refused(md(cookie: nil)), .unauthenticated)
        XCTAssertEqual(refused(md(cookie: "doz_ui_50123=a; doz_ui_50123=b")), .unauthenticated)
        XCTAssertEqual(refused(md(), []), .ticketMissing)
        XCTAssertEqual(refused(md(), ["doz-ticket.abc"]), .ticketMissing, "the protocol itself must be offered")
        XCTAssertEqual(refused(md(), ["doz-terminal.v1"]), .ticketMissing)
        XCTAssertEqual(refused(md(), ["doz-terminal.v1", "doz-ticket.a", "doz-ticket.b"]), .ticketMissing, "exactly one ticket")
        XCTAssertEqual(refused(md(), ["doz-terminal.v1, doz-ticket.bad!chars"]), .ticketMissing)
        XCTAssertNil(refused(md(), ["doz-terminal.v1", "doz-ticket.abc"]), "the list may come as several headers")
    }

    func testTheTerminalRoutesAreTypedAndNothingElseIs() {
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/sandboxes/demo/terminal-ticket"), .terminalTicket("demo"))
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/sandboxes/demo/terminal-socket"), .terminalSocket("demo"))
        for t in ["/api/v1/sandboxes/demo/terminal-socket/x", "/api/v1/sandboxes/Demo/terminal-socket", "/api/v1/terminal-socket",
                  "/api/v1/sandboxes/demo/pty", "/api/v1/sandboxes/demo/attach", "/api/v1/sandboxes/demo/exec", "/api/v1/sandboxes/demo/shell"] {
            XCTAssertNil(WebRoute.parse(method: .get, target: t), t)
            XCTAssertNil(WebRoute.parse(method: .post, target: t), t)
        }
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/sandboxes/demo/terminal-ticket"), "a ticket is minted by POST only")
        XCTAssertNil(WebRoute.parse(method: .post, target: "/api/v1/sandboxes/demo/terminal-socket"))
    }

    // MARK: frames

    func testTextFramesAreAClosedStrictSet() throws {
        func d(_ s: String) throws -> WebTerminalClientFrame { try WebTerminalWire.decodeText(Data(s.utf8)) }
        XCTAssertEqual(try d(#"{"t":"ping"}"#), .ping)
        XCTAssertEqual(try d(#"{"t":"resize","cols":132,"rows":43}"#), .resize(TermSize(cols: 132, rows: 43)))
        for bad in [#"{"t":"exec","argv":["sh"]}"#, #"{"t":"ping","x":1}"#, #"{"t":"resize","cols":0,"rows":10}"#,
                    #"{"t":"resize","cols":1001,"rows":10}"#, #"{"t":"resize","cols":80}"#, #"{"t":"resize","cols":80,"rows":24,"wake":true}"#,
                    #"{"t":"resize","cols":"80","rows":24}"#, #"{"t":"wake"}"#, "[]", ""] {
            XCTAssertThrowsError(try d(bad), bad)
        }
    }

    func testInputCannotForgeTheAttachWiresFrames() {
        let forged: [UInt8] = [0x61] + ClientWire.resize(TermSize(cols: 1, rows: 1)) + [0x62]
        let clean = WebTerminalWire.sanitizeInput(forged)
        XCTAssertFalse(clean.contains(0xFF))
        var p = ClientWire.Parser()
        XCTAssertFalse(p.feed(clean).contains { if case .resize = $0 { true } else { false } })
        XCTAssertEqual(WebTerminalWire.sanitizeInput(Array("héllo ✓".utf8)), Array("héllo ✓".utf8), "UTF-8 never holds 0xFF")
    }

    func testTheInputBudgetAllowsABurstThenTheRate() {
        let t0 = Date(timeIntervalSince1970: 0)
        var b = WebInputBudget(burst: 1000, perSecond: 100, now: t0)
        XCTAssertTrue(b.take(1000, now: t0))
        XCTAssertFalse(b.take(1, now: t0))
        XCTAssertTrue(b.take(100, now: t0.addingTimeInterval(1)))
        XCTAssertFalse(b.take(50, now: t0.addingTimeInterval(1.1)))
        XCTAssertTrue(b.take(1000, now: t0.addingTimeInterval(100)), "refills to the burst, not beyond")
        XCTAssertFalse(b.take(1, now: t0.addingTimeInterval(100)))
    }

    func testTheEndNoticeIsFoundAcrossReadsAndItsTextKept() {
        let notice = Array(ClientWire.endedNotice(.exited(7), text: "the shell session has ended (exit 7)"))
        let all = Array("output".utf8) + notice
        for cut in 1..<all.count {
            var pending = Array(all[..<cut])
            var shown: [UInt8] = []
            if ClientWire.findEnding(in: pending) == nil {
                let hold = WebTerminalWire.holdBack(pending)
                shown += pending[..<(pending.count - hold)]
                pending = Array(pending.suffix(hold))
            }
            pending += all[cut...]
            guard let (e, start) = ClientWire.findEnding(in: pending) else { return XCTFail("cut \(cut): no notice") }
            shown += pending[..<start]
            XCTAssertEqual(e, .exited(7))
            XCTAssertEqual(String(decoding: shown, as: UTF8.self), "output", "cut \(cut): the notice never reaches the screen")
            XCTAssertEqual(WebTerminalWire.endingText(pending[start...]), "the shell session has ended (exit 7)")
        }
    }

    // MARK: 591 polish — the boot view's text and the kept scrollback

    func testBootTextIsInertAndCapped() {
        XCTAssertEqual(WebTerminalWire.bootText("a\u{1B}[31mred\u{07}\u{9B}2J\u{7F}\r\n\tz"), "a[31mred2J z")
        XCTAssertEqual(WebTerminalWire.bootText("\u{1B}]52;c;eA==\u{1B}\\"), "]52;c;eA==\\")
        XCTAssertEqual(WebTerminalWire.bootText(String(repeating: "é", count: 900)).utf8.count, 1000)
    }

    func testTheFirstSnapshotAfterABootKeepsTheScrollback() {
        let snap = WebTerminalWire.snapshotPrefix + Array("\u{1B}[1;1H$ ".utf8)
        let kept = WebTerminalWire.keepingScrollback(snap[...])
        XCTAssertEqual(String(decoding: kept, as: UTF8.self), "\u{1B}[?1049l\u{1B}[!p\u{1B}[0m\u{1B}[H\u{1B}[2J\u{1B}[1;1H$ ",
                       "a soft reset and a clear SCREEN — no full reset, no ED 3")
        XCTAssertEqual(WebTerminalWire.keepingScrollback(Array("plain".utf8)[...]), Array("plain".utf8), "anything else is untouched")
    }

    // MARK: the 541 rule — SandboxLab's cases, unchanged

    private func c(_ s: String) -> TerminalInputClass { TerminalInputClassifier.classify(Data(s.utf8)) }

    func testControlReportsAreNotKeystrokes() {
        XCTAssertEqual(c("\u{1B}[I"), .report)                  // focus in (the window came forward)
        XCTAssertEqual(c("\u{1B}[O"), .report)                  // focus out
        XCTAssertEqual(c("\u{1B}[12;40R"), .report)             // cursor position
        XCTAssertEqual(c("\u{1B}[?62;22c"), .report)            // device attributes reply
        XCTAssertEqual(c("\u{1B}[<35;10;5M"), .report)          // SGR mouse motion
        XCTAssertEqual(c("\u{1B}[<0;10;5m"), .report)
        XCTAssertEqual(c("\u{1B}[?997;1n"), .report)            // colour scheme note
        XCTAssertEqual(c("\u{1B}[0n"), .report)                 // device status
        XCTAssertEqual(c("\u{1B}]11;rgb:0000/0000/0000\u{07}"), .report)   // OSC colour reply
        XCTAssertEqual(c("\u{1B}P>|ghostty 1.2\u{1B}\\"), .report)          // XTVERSION
        XCTAssertEqual(c("\u{1B}[?1004;1$y"), .report)          // DECRPM
        XCTAssertEqual(c("\u{1B}[?1u"), .report)                // kitty flags reply
        XCTAssertEqual(c("\u{1B}[8;24;80t"), .report)           // XTWINOPS
        XCTAssertEqual(c("\u{1B}[I\u{1B}[<35;1;1M"), .report)   // two reports in one write
        XCTAssertEqual(TerminalInputClassifier.classify(Data([0x1B, 0x5B, 0x4D, 0x23, 0x21, 0x21])), .report)   // X10 mouse
        XCTAssertEqual(TerminalInputClassifier.classify(Data()), .report)
    }

    func testWhatAPersonTypesIsAKeystroke() {
        XCTAssertEqual(c("x"), .keystroke)
        XCTAssertEqual(c("\r"), .keystroke)
        XCTAssertEqual(c("\u{03}"), .keystroke)                 // Ctrl-C
        XCTAssertEqual(c("\u{1B}"), .keystroke)                 // Esc
        XCTAssertEqual(c("\u{1B}[A"), .keystroke)               // arrow up
        XCTAssertEqual(c("\u{1B}OA"), .keystroke)               // SS3 arrow
        XCTAssertEqual(c("\u{1B}[15~"), .keystroke)             // F5
        XCTAssertEqual(c("\u{1B}b"), .keystroke)                // Alt-b
        XCTAssertEqual(c("\u{1B}[97;5u"), .keystroke)           // kitty key event
        XCTAssertEqual(c("\u{1B}[I" + "x"), .keystroke)         // a report, then a key
        XCTAssertEqual(c("\u{1B}["), .keystroke)                // truncated: errs towards keystroke
        XCTAssertEqual(c("\u{1B}[200~hello\u{1B}[201~"), .keystroke)   // pasted text
    }

    // MARK: the cover — SandboxLab's states and wording

    func testEachPhaseGetsItsCoverAndOneAction() {
        let t0 = Date(timeIntervalSince1970: 1000)
        func d(_ p: String?, action: String? = nil, screen: Bool = true, ever: Bool = true, watch: Bool = false) -> WebTerminalCover {
            WebTerminalCover.derive(phase: p, since: t0, action: action, screenBack: screen, everAttached: ever, watch: watch)
        }
        XCTAssertEqual(d("running").kind, .none)
        XCTAssertFalse(d("running").isVisible)
        XCTAssertEqual(d("running", screen: false).kind, .reattaching)
        XCTAssertEqual(d("running", screen: false).headline, "Reattaching…")
        XCTAssertEqual(d("running", screen: false, ever: false).headline, "Attaching…")
        XCTAssertTrue(d("running", screen: false).spinner)
        XCTAssertNil(d("running", screen: false).action)
        XCTAssertEqual(d("paused").headline, "Sandbox paused · press any key to resume")
        XCTAssertEqual(d("paused").detail, "CPUs frozen, RAM kept")
        XCTAssertEqual(d("paused").action, .resume)
        XCTAssertEqual(d("paused").since, t0)
        XCTAssertEqual(d("paused").elapsedVerb, "paused")
        XCTAssertEqual(d("asleep").headline, "Sandbox asleep · press any key to wake")
        XCTAssertEqual(d("asleep").detail, "RAM kept, state saved to disk")
        XCTAssertEqual(d("asleep").action, .wake)
        XCTAssertEqual(d("hibernated").headline, "Sandbox hibernated · press any key to wake")
        XCTAssertEqual(d("hibernated").detail, "RAM freed, state on disk — every process comes back")
        XCTAssertEqual(d("hibernated").action, .wake)
        XCTAssertEqual(d("off").headline, "Sandbox shut down")
        XCTAssertEqual(d("off").detail, "The disk is kept; Start cold-boots it.")
        XCTAssertEqual(d("off").action, .start)
        XCTAssertEqual(d("failed").headline, "The sandbox failed to start")
        XCTAssertEqual(d("booting").headline, "Starting the sandbox…")
        XCTAssertEqual(d("hibernated", action: "wake").headline, "Waking the sandbox…")
        XCTAssertEqual(d("running", action: "hibernate").headline, "Hibernating…")
        XCTAssertEqual(d("running", action: "point-take").kind, .none, "a quick freeze: no cover")
        XCTAssertEqual(d(nil).headline, "Attaching…")
        // A watcher's keys never wake — the cover does not say they do.
        XCTAssertEqual(d("hibernated", watch: true).headline, "Sandbox hibernated")
        XCTAssertEqual(d("paused", watch: true).headline, "Sandbox paused")
        XCTAssertEqual(d("hibernated", watch: true).action, .wake, "the button still works")
    }

    // MARK: the vendored asset class

    var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DozerWeb/WebSource")
    }

    func testVendoredFilesAreThePinnedBytesAndServedOnlyAsVendor() throws {
        let vendor = sources.appendingPathComponent("vendor/ghostty-web")
        let pin = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: vendor.appendingPathComponent("VENDOR.json"))) as? [String: Any])
        XCTAssertEqual(pin["package"] as? String, "ghostty-web")
        XCTAssertEqual(pin["version"] as? String, "0.4.0")
        XCTAssertEqual(pin["licence"] as? String, "MIT")
        let files = try XCTUnwrap(pin["files"] as? [[String: Any]])
        for f in files {
            let name = try XCTUnwrap(f["file"] as? String)
            XCTAssertEqual(WebAssets.sha256Hex(try Data(contentsOf: vendor.appendingPathComponent(name))), f["sha256"] as? String, name)
        }
        let assets = try WebAssets.load()
        // 593: the icon sprite is vendored too, but GENERATED from its pinned files (WebTerminalHTTPTests checks it).
        let vendored = assets.assets.values.filter { $0.publicPath.hasPrefix("/assets/vendor-") && !$0.publicPath.hasPrefix("/assets/vendor-lucide-icons-") }
        XCTAssertEqual(Set(vendored.map(\.mimeType)), ["application/javascript; charset=utf-8", "application/wasm"])
        for a in vendored {
            XCTAssertTrue(files.contains { ($0["sha256"] as? String) == a.sha256 }, "\(a.publicPath) is a pinned file")
            XCTAssertEqual(a.cachePolicy, WebAssets.immutable)
        }
        let index = String(decoding: try XCTUnwrap(assets.assets["/"]).data, as: UTF8.self)
        XCTAssertFalse(index.contains("/vendor/"), "every vendored reference is rewritten to its hashed path")
        XCTAssertTrue(index.contains("doz-ghostty-wasm"))
    }

    func testWebAssemblyIsRefusedForThePagesOwnCode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-webassets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("assets"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = Data("<!doctype html>".utf8), wasm = Data([0, 0x61, 0x73, 0x6d])
        try html.write(to: dir.appendingPathComponent("index.html"))
        try wasm.write(to: dir.appendingPathComponent("assets/x.wasm"))
        func manifest(_ cls: String?, path: String = "/assets/x.wasm") throws {
            var e: [String: Any] = ["publicPath": path, "resourcePath": "assets/x.wasm", "mimeType": "application/wasm",
                                    "sha256": WebAssets.sha256Hex(wasm), "cachePolicy": WebAssets.immutable]
            if let cls { e["class"] = cls }
            let m: [String: Any] = ["version": 1, "assets": [
                ["publicPath": "/", "resourcePath": "index.html", "mimeType": "text/html; charset=utf-8", "sha256": WebAssets.sha256Hex(html), "cachePolicy": "no-store"], e]]
            try JSONSerialization.data(withJSONObject: m).write(to: dir.appendingPathComponent("manifest.json"))
        }
        try manifest(nil)
        XCTAssertThrowsError(try WebAssets.load(webRoot: dir)) { XCTAssertEqual($0 as? WebAssetError, .unsupportedType) }
        try manifest("page")
        XCTAssertThrowsError(try WebAssets.load(webRoot: dir)) { XCTAssertEqual($0 as? WebAssetError, .unsupportedType) }
        try manifest("vendor", path: "/assets/x.wasm")
        XCTAssertThrowsError(try WebAssets.load(webRoot: dir)) { XCTAssertEqual($0 as? WebAssetError, .unsafePath) }
        try manifest("vendor", path: "/assets/vendor-x.wasm")
        XCTAssertNoThrow(try WebAssets.load(webRoot: dir))
        try manifest("mystery", path: "/assets/vendor-x.wasm")
        XCTAssertThrowsError(try WebAssets.load(webRoot: dir)) { XCTAssertEqual($0 as? WebAssetError, .malformedManifest) }
    }
}
