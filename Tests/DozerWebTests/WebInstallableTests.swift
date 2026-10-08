import CryptoKit
import Darwin
import Foundation
import DozerKit
import DozerHost
import XCTest
@testable import DozerWeb

/// 605 — the installable dashboard and its graceful restarts: the web app manifest and icons, the
/// offline page and the service worker (routes, headers, the CSP, what the worker may cache), the asset
/// compiler's rules for them, the remembered session and the reasons a page is told when it must sign in
/// again, the operations ring across a restart, a terminal's reattach,
/// `ui.port`, and the stream's `hello`.
final class WebInstallableTests: XCTestCase {
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    // MARK: routes and headers

    func testTheOfflinePageAndTheWorkerAreClosedGetOnlyRoutes() {
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/offline"), .offline)
        XCTAssertEqual(WebRoute.parse(method: .head, target: "/offline"), .offline)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/sw.js"), .serviceWorker)
        XCTAssertTrue(WebRoute.offline.isStatic)
        XCTAssertTrue(WebRoute.serviceWorker.isStatic)
        for m in [WebHTTPMethod.post, .delete] {
            XCTAssertNil(WebRoute.parse(method: m, target: "/offline"))
            XCTAssertNil(WebRoute.parse(method: m, target: "/sw.js"))
        }
        // The manifest is a hashed asset, never a stable path of its own; nothing else is new.
        for t in ["/app.webmanifest", "/manifest.webmanifest", "/offline/", "/offline.html", "/sw.js/x", "/icons/icon.svg", "/service-worker.js"] {
            XCTAssertNil(WebRoute.parse(method: .get, target: t), t)
        }
    }

    func testThePageMayLinkItsManifestAndRegisterItsWorkerAndNothingElseChanged() {
        let csp = Dictionary(uniqueKeysWithValues: WebSecurity.responseHeaders.map { ($0.0.lowercased(), $0.1) })["content-security-policy"]!
        XCTAssertEqual(csp, "default-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'; object-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; font-src 'self'; frame-src 'self'; manifest-src 'self'; worker-src 'self'")
        XCTAssertFalse(csp.contains("manifest-src 'none'"))
        let sw = Dictionary(uniqueKeysWithValues: WebSecurity.serviceWorkerHeaders.map { ($0.0.lowercased(), $0.1) })
        XCTAssertEqual(sw["content-security-policy"], "default-src 'none'; connect-src 'self'")
        // The frame's policy is untouched (no manifest, no worker).
        let f = Dictionary(uniqueKeysWithValues: WebSecurity.frameHeaders.map { ($0.0.lowercased(), $0.1) })["content-security-policy"]!
        XCTAssertTrue(f.contains("manifest-src 'none'"))
        XCTAssertFalse(f.contains("worker-src"))
    }

    // MARK: the assets

    func testTheManifestNamesTheAppAndEveryIconIsAServedPNGOfItsSize() throws {
        let a = try WebAssets.load()
        let manifests = a.assets.values.filter { $0.mimeType == "application/manifest+json" }
        XCTAssertEqual(manifests.count, 1)
        let m = try XCTUnwrap(manifests.first)
        XCTAssertTrue(m.publicPath.hasPrefix("/assets/app-") && m.publicPath.hasSuffix(".webmanifest"))
        XCTAssertEqual(m.cachePolicy, WebAssets.immutable)
        let j = try XCTUnwrap(try JSONSerialization.jsonObject(with: m.data) as? [String: Any])
        XCTAssertEqual(j["id"] as? String, "/?app=dozer", "a FIXED id: a new hashed manifest URL is the same app")
        XCTAssertEqual(j["name"] as? String, "Dozer Sandbox")
        XCTAssertEqual(j["short_name"] as? String, "Dozer")
        XCTAssertEqual(j["start_url"] as? String, "/#/overview")
        XCTAssertEqual(j["scope"] as? String, "/")
        XCTAssertEqual(j["display"] as? String, "standalone")
        let icons = try XCTUnwrap(j["icons"] as? [[String: String]])
        var purposes: [String: [String]] = [:]
        for i in icons {
            let src = try XCTUnwrap(i["src"])
            let asset = try XCTUnwrap(a.assets[src], "the manifest's icon \(src) is served")
            XCTAssertEqual(asset.mimeType, i["type"])
            purposes[i["purpose"] ?? "any", default: []].append(i["sizes"] ?? "")
            if asset.mimeType == "image/png" {
                let b = [UInt8](asset.data)
                let w = Int(b[16]) << 24 | Int(b[17]) << 16 | Int(b[18]) << 8 | Int(b[19])
                XCTAssertEqual("\(w)x\(w)", i["sizes"], src)
            }
        }
        XCTAssertEqual(Set(purposes["any"] ?? []), ["192x192", "512x512", "any"], "Chrome needs 192 and 512")
        XCTAssertEqual(purposes["maskable"], ["512x512"])
        // The page links it, the SVG favicon, the apple-touch-icon and a theme colour for each scheme.
        let index = String(decoding: a.assets["/"]!.data, as: UTF8.self)
        XCTAssertTrue(index.contains("<link rel=\"manifest\" href=\"\(m.publicPath)\">"))
        let svg = try XCTUnwrap(a.assets.keys.first { $0.hasPrefix("/assets/icon-") && $0.hasSuffix(".svg") })
        XCTAssertTrue(index.contains("<link rel=\"icon\" href=\"\(svg)\" type=\"image/svg+xml\">"))
        XCTAssertFalse(index.contains("href=\"data:,\""), "the empty favicon is gone")
        let touch = try XCTUnwrap(a.assets.keys.first { $0.hasPrefix("/assets/icon-180-") })
        XCTAssertTrue(index.contains("<link rel=\"apple-touch-icon\" href=\"\(touch)\">"))
        XCTAssertTrue(index.contains("<meta name=\"theme-color\" media=\"(prefers-color-scheme: light)\""))
        XCTAssertTrue(index.contains("<meta name=\"theme-color\" media=\"(prefers-color-scheme: dark)\""))
    }

    func testTheWorkerPrecachesOnlyTheOfflinePageAndItsFilesAndNeverTheAPI() throws {
        let a = try WebAssets.load()
        let sw = try XCTUnwrap(a.assets[WebAssets.serviceWorker])
        XCTAssertEqual(sw.cachePolicy, "no-store", "checked for an update at every navigation")
        XCTAssertEqual(sw.mimeType, "application/javascript; charset=utf-8")
        let text = String(decoding: sw.data, as: UTF8.self)
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("const PRECACHE = ") })
        let list = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.dropFirst("const PRECACHE = ".count).dropLast().utf8)) as? [String])
        XCTAssertEqual(list.count, 4)
        XCTAssertEqual(list[0], WebAssets.offlineDocument)
        for p in list { XCTAssertNotNil(a.assets[p], "precached \(p) is served") }
        XCTAssertEqual(Set(list.dropFirst().map { String($0.split(separator: "-")[0]) }), ["/assets/offline", "/assets/icon"])
        XCTAssertFalse(list.contains { $0.hasPrefix("/api") || $0 == "/" || $0 == WebAssets.frameDocument })
        // Its cache's name is per build; it loads nothing; it answers only navigations of / and its list.
        XCTAssertFalse(text.contains("@build@"))
        XCTAssertNotNil(text.range(of: #"const CACHE = "doz-offline-[0-9a-f]{16}";"#, options: .regularExpression))
        for banned in ["importScripts", "eval(", "cache.put", ".put("] { XCTAssertFalse(text.contains(banned), banned) }
        XCTAssertTrue(text.contains("r.mode === 'navigate' && r.destination === 'document' && url.pathname === '/'"))
        // The offline page: a document without a session, its own script and style (precached).
        let offline = try XCTUnwrap(a.assets[WebAssets.offlineDocument])
        XCTAssertEqual(offline.cachePolicy, "no-store")
        let doc = String(decoding: offline.data, as: UTF8.self)
        for p in list.dropFirst() { XCTAssertTrue(doc.contains("\"\(p)\""), "the offline page uses \(p)") }
        XCTAssertTrue(doc.contains("doz ui"))
    }

    func testAPNGIsOnlyAnAppIconAndThePageNamesItsBuild() throws {
        let a = try WebAssets.load()
        for (p, asset) in a.assets where asset.mimeType == "image/png" {
            XCTAssertTrue(WebAssets.isIconPNG(p), p)
        }
        XCTAssertNotNil(a.pageScript)
        XCTAssertTrue(a.pageScript!.hasPrefix("/assets/app-") && a.pageScript!.hasSuffix(".js"))
        XCTAssertTrue(a.pageStyle!.hasPrefix("/assets/app-") && a.pageStyle!.hasSuffix(".css"))
        // A PNG anywhere else is refused at load (a copy of the bundle with a PNG renamed).
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("doz-web-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: Self.root.appendingPathComponent("Sources/DozerWeb/Resources/Web"), to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let mURL = tmp.appendingPathComponent("manifest.json")
        let m = String(decoding: try Data(contentsOf: mURL), as: UTF8.self)
        let icon = try XCTUnwrap(a.assets.keys.first { $0.hasPrefix("/assets/icon-192-") })
        let moved = icon.replacingOccurrences(of: "/assets/icon-192-", with: "/assets/app-192-")
        try FileManager.default.moveItem(at: tmp.appendingPathComponent(String(icon.dropFirst())), to: tmp.appendingPathComponent(String(moved.dropFirst())))
        try Data(m.replacingOccurrences(of: String(icon.dropFirst()), with: String(moved.dropFirst())).utf8).write(to: mURL)
        XCTAssertThrowsError(try WebAssets.load(webRoot: tmp)) { XCTAssertEqual($0 as? WebAssetError, .unsupportedType) }
    }

    /// The compiler's 605 rules, run on a scratch copy of the sources: a worker that loads code, an SVG
    /// master edited without a re-render, a PNG nobody recorded and an icon that draws text are refused.
    func testTheAssetCompilerRefusesWhatItMustNot() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("doz-webc-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        func fresh() throws {
            try? fm.removeItem(at: tmp)
            try fm.createDirectory(at: tmp.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
            try fm.createDirectory(at: tmp.appendingPathComponent("Sources/DozerWeb"), withIntermediateDirectories: true)
            try fm.copyItem(at: Self.root.appendingPathComponent("Scripts/build-web-assets.swift"), to: tmp.appendingPathComponent("Scripts/build-web-assets.swift"))
            try fm.copyItem(at: Self.root.appendingPathComponent("Sources/DozerWeb/WebSource"), to: tmp.appendingPathComponent("Sources/DozerWeb/WebSource"))
            try fm.copyItem(at: Self.root.appendingPathComponent("Sources/DozerWeb/Resources"), to: tmp.appendingPathComponent("Sources/DozerWeb/Resources"))
        }
        func compile() throws -> (Int32, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["swift", tmp.appendingPathComponent("Scripts/build-web-assets.swift").path, "--check"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try p.run()
            let d = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: d, as: UTF8.self))
        }
        let src = tmp.appendingPathComponent("Sources/DozerWeb/WebSource")
        func append(_ file: String, _ text: String) throws {
            let u = src.appendingPathComponent(file)
            try Data((String(decoding: try Data(contentsOf: u), as: UTF8.self) + text).utf8).write(to: u)
        }
        try fresh()
        let ok = try compile()
        XCTAssertEqual(ok.0, 0, ok.1)
        try append("sw.js", "\nimportScripts('/x.js');\n")
        var r = try compile()
        XCTAssertNotEqual(r.0, 0)
        XCTAssertTrue(r.1.contains("sw.js uses importScripts"), r.1)
        try fresh()
        try append("icons/icon.svg", "\n")
        r = try compile()
        XCTAssertTrue(r.1.contains("icons/icon.svg is not the master the PNGs were rendered from"), r.1)
        try fresh()
        try Data([0x89, 0x50]).write(to: src.appendingPathComponent("icons/icon-64.png"))
        r = try compile()
        XCTAssertTrue(r.1.contains("unlisted"), r.1)
        try fresh()
        // An icon that draws text (a font), with its provenance updated to match: refused by content.
        let svgURL = src.appendingPathComponent("icons/icon.svg")
        let svg = String(decoding: try Data(contentsOf: svgURL), as: UTF8.self).replacingOccurrences(of: "</svg>", with: "<text x=\"1\" y=\"1\">Z</text></svg>")
        try Data(svg.utf8).write(to: svgURL)
        let provURL = src.appendingPathComponent("icons/PROVENANCE.json")
        let oldSHA = SHA256.hash(data: try Data(contentsOf: Self.root.appendingPathComponent("Sources/DozerWeb/WebSource/icons/icon.svg"))).map { String(format: "%02x", $0) }.joined()
        let newSHA = SHA256.hash(data: Data(svg.utf8)).map { String(format: "%02x", $0) }.joined()
        try Data(String(decoding: try Data(contentsOf: provURL), as: UTF8.self).replacingOccurrences(of: oldSHA, with: newSHA).utf8).write(to: provURL)
        r = try compile()
        XCTAssertTrue(r.1.contains("<text> is not allowed in an app icon"), r.1)
        try fresh()
        try append("app.webmanifest", "\n")
        try Data(String(decoding: try Data(contentsOf: src.appendingPathComponent("app.webmanifest")), as: UTF8.self)
            .replacingOccurrences(of: "\"/icons/icon-192.png\"", with: "\"/icons/icon-96.png\"").utf8).write(to: src.appendingPathComponent("app.webmanifest"))
        r = try compile()
        XCTAssertTrue(r.1.contains("app.webmanifest references \"/icons/icon-96.png\", which nothing serves"), r.1)
    }

    // MARK: sessions — remembered, and why one ended

    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 2_000_000) }

    func scratch() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("doz-sess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func testABrowserIsRememberedForFourteenDaysRenewedByUse() async throws {
        XCTAssertEqual(WebLimits.standard.sessionLifetime, 14 * 24 * 60 * 60)
        XCTAssertNoThrow(try WebLimits(sessionLifetime: 30 * 24 * 60 * 60))
        XCTAssertThrowsError(try WebLimits(sessionLifetime: 31 * 24 * 60 * 60))
        let clock = Clock()
        let cap = WebBootstrapCapability.make()
        let store = WebSessionStore(bootstrap: cap, limits: .standard, now: { clock.now })
        let s = try await store.exchange(cap.value)
        clock.now += 13 * 24 * 3600
        _ = try await store.renew(s.cookieValue)                     // the page, opened on day 13
        clock.now += 13 * 24 * 3600
        _ = try await store.authenticate(s.cookieValue)              // day 26: still signed in
        clock.now += 15 * 24 * 3600
        await XCTAssertThrowsRejection(.sessionExpired) { _ = try await store.authenticate(s.cookieValue) }
    }

    func testAPageIsToldWhyItMustSignInAgainAcrossARestart() async throws {
        let dir = try scratch()
        let file = dir.appendingPathComponent("ui.sessions"), revoked = dir.appendingPathComponent("ui.revoked")
        let clock = Clock()
        func make(_ port: Int = 7001) -> (WebSessionStore, WebBootstrapCapability) {
            let c = WebBootstrapCapability.make()
            return (WebSessionStore(bootstrap: c, limits: .standard, now: { clock.now }, persist: file, port: port, revoked: revoked), c)
        }
        // Signed out by this browser; rotated (a new link); expired; unknown.
        var (store, cap) = make()
        let a = try await store.exchange(cap.value)
        let b = try await store.exchange(await store.issue().value)
        let c = try await store.exchange(await store.issue().value)
        await store.revoke(a.cookieValue)
        await XCTAssertThrowsRejection(.signedOut) { _ = try await store.authenticate(a.cookieValue) }
        await XCTAssertThrowsRejection(.unauthenticated) { _ = try await store.authenticate(WebRandom.token()) }
        // c expires first (no renewal); b is renewed, then rotated.
        clock.now += 10 * 24 * 3600
        _ = try await store.renew(b.cookieValue)
        clock.now += 5 * 24 * 3600
        await XCTAssertThrowsRejection(.sessionExpired) { _ = try await store.authenticate(c.cookieValue) }
        await store.revokeAll()
        await XCTAssertThrowsRejection(.sessionRotated) { _ = try await store.authenticate(b.cookieValue) }
        // A restarted UI (a new store from the files) says the same — and the files hold digests only.
        (store, cap) = make()
        await XCTAssertThrowsRejection(.signedOut) { _ = try await store.authenticate(a.cookieValue) }
        await XCTAssertThrowsRejection(.sessionRotated) { _ = try await store.authenticate(b.cookieValue) }
        await XCTAssertThrowsRejection(.sessionExpired) { _ = try await store.authenticate(c.cookieValue) }
        let text = String(decoding: try Data(contentsOf: revoked), as: UTF8.self)
        for s in [a, b, c] { XCTAssertFalse(text.contains(s.cookieValue)); XCTAssertTrue(text.contains(WebSessionStore.digest(s.cookieValue))) }
        var st = stat()
        XCTAssertEqual(stat(revoked.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        // Reasons are kept 30 days, then forgotten (unknown).
        clock.now += 31 * 24 * 3600
        (store, cap) = make()
        await XCTAssertThrowsRejection(.unauthenticated) { _ = try await store.authenticate(b.cookieValue) }
    }

    func testDozUINewLinkAtStartEndsTheKeptSessionsAsRotated() async throws {
        let dir = try scratch()
        let file = dir.appendingPathComponent("ui.sessions"), revoked = dir.appendingPathComponent("ui.revoked")
        let cap = WebBootstrapCapability.make()
        let first = WebSessionStore(bootstrap: cap, limits: .standard, persist: file, port: 7002, revoked: revoked)
        let s = try await first.exchange(cap.value)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        WebSessionStore.revokeKept(sessions: file, revoked: revoked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "no session is kept")
        let next = WebSessionStore(bootstrap: .make(), limits: .standard, persist: file, port: 7002, revoked: revoked)
        await XCTAssertThrowsRejection(.sessionRotated) { _ = try await next.authenticate(s.cookieValue) }
    }

    // MARK: operations across a restart

    func testAnOperationLeftRunningIsResolvedFromTheSandboxNow() throws {
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        func op(_ action: String, _ sandbox: String? = "w1") -> WebOperation {
            WebOperation(id: "x", action: action, label: action, sandbox: sandbox, state: "running", text: "", startedAt: t0, milliseconds: nil,
                         interrupted: true)
        }
        func row(_ phase: String, busy: Bool = false) -> [String: WebSandboxRow] {
            ["w1": WebSandboxRow(SandboxInfo(name: "w1", image: "lab", phase: phase, busy: busy, cpus: 1, memoryMiB: 512, ramHeldMiB: 0,
                                             memoryReturnedMiB: 0, diskBytes: 0, sessions: nil, network: "nat", deniedConnections: nil,
                                             workspace: nil, createdAt: nil, diedWithHost: nil))]
        }
        let now = t0.addingTimeInterval(40)
        XCTAssertNil(WebOperations.resolution(op("start"), rows: row("booting"), now: now), "still under way")
        XCTAssertNil(WebOperations.resolution(op("start"), rows: row("off", busy: true), now: now))
        XCTAssertEqual(WebOperations.resolution(op("start"), rows: row("running"), now: now)?.0, "done")
        XCTAssertTrue(WebOperations.resolution(op("start"), rows: row("running"), now: now)!.1.contains("finished while doz ui restarted"))
        XCTAssertEqual(WebOperations.resolution(op("start"), rows: row("failed"), now: now)?.0, "failed")
        XCTAssertEqual(WebOperations.resolution(op("start"), rows: row("off"), now: now)?.0, "interrupted")
        XCTAssertEqual(WebOperations.resolution(op("hibernate"), rows: row("hibernated"), now: now)?.0, "done")
        XCTAssertEqual(WebOperations.resolution(op("shutdown"), rows: row("off"), now: now)?.0, "done")
        XCTAssertEqual(WebOperations.resolution(op("rm"), rows: [:], now: now)?.0, "done")
        XCTAssertEqual(WebOperations.resolution(op("create"), rows: row("off"), now: now)?.0, "done")
        XCTAssertEqual(WebOperations.resolution(op("start"), rows: [:], now: now)?.0, "interrupted", "the sandbox is gone")
        XCTAssertEqual(WebOperations.resolution(op("image-bake", nil), rows: [:], now: now)?.0, "interrupted", "an outcome never seen")
        XCTAssertEqual(WebOperations.resolution(op("start"), rows: row("booting"), now: t0.addingTimeInterval(31 * 60))?.0, "interrupted",
                       "never a forever-spinner")
    }

    func testTheOperationsRingSurvivesARestartAndItsRunningOnesAreReconciled() async throws {
        let dir = try scratch()
        let file = dir.appendingPathComponent("ui.operations.json")
        let fake = FakeData()
        let hub = SSEHub(maxClients: 4, capacity: 16)
        let monitor = WebMonitor(data: fake, hub: hub, pollInterval: .seconds(60))
        let started = Date().addingTimeInterval(-5)
        let saved = [WebOperation(id: "a1", action: "pause", label: "pause demo", sandbox: "demo", state: "running", text: "pausing",
                                  startedAt: started, milliseconds: nil),
                     WebOperation(id: "a2", action: "start", label: "start demo", sandbox: "demo", state: "done", text: "demo: off → running",
                                  startedAt: started, milliseconds: 900)]
        WebSessionStore.write(try WebJSON.encoder.encode(saved), to: file)
        let ops = WebOperations(data: fake, hub: hub, monitor: monitor, file: file)
        let loaded = ops.recent
        XCTAssertEqual(loaded.map(\.id), ["a1", "a2"])
        XCTAssertEqual(loaded[0].state, "running")
        XCTAssertEqual(loaded[0].interrupted, true)
        XCTAssertEqual(loaded[0].text, WebOperations.interruptedText)
        XCTAssertNil(loaded[1].interrupted, "an ended one is as it was")
        let client = try XCTUnwrap(hub.add(cookie: "c"))
        fake.phase = "paused"
        ops.reconcile(try await fake.overview())
        XCTAssertEqual(ops.recent[0].state, "done")
        XCTAssertTrue(ops.recent[0].text.contains("demo is paused — finished while doz ui restarted"), ops.recent[0].text)
        XCTAssertNotNil(ops.recent[0].milliseconds)
        // Told to the pages, and written back.
        client.finish(.clientGone)
        var frames = ""
        for await f in client.frames { frames += String(decoding: f.bytes, as: UTF8.self) }
        XCTAssertTrue(frames.contains("event: op") && frames.contains("finished while doz ui restarted"))
        let back = try WebJSON.decoder.decode([WebOperation].self, from: Data(contentsOf: file))
        XCTAssertEqual(back[0].state, "done")
        var st = stat()
        XCTAssertEqual(stat(file.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
    }

    // MARK: terminals, ui.port, hello

    func testATerminalTicketMayAskToKeepTheScrollbackOnAReattach() throws {
        let d = { (s: String) in try WebTerminalTicketRequest.decode(Data(s.utf8)) }
        XCTAssertFalse(try d(#"{"mode":"watch"}"#).reattach)
        XCTAssertTrue(try d(#"{"mode":"interactive","cols":80,"rows":24,"reattach":true}"#).reattach)
        XCTAssertFalse(try d(#"{"mode":"interactive","reattach":false}"#).reattach)
        for bad in [#"{"mode":"watch","reattach":"yes"}"#, #"{"mode":"watch","reattach":1}"#, #"{"mode":"watch","reattach":null}"#] {
            XCTAssertThrowsError(try d(bad), bad)
        }
    }

    func testTheGrantCarriesTheReattach() async throws {
        let store = WebTerminalTicketStore()
        let t = try await store.mint(cookie: "c", sandbox: "demo", session: nil, mode: .watch, size: nil, reattach: true)
        let g = try await store.consume(t, cookie: "c", sandbox: "demo")
        XCTAssertTrue(g.reattach)
        let t2 = try await store.mint(cookie: "c", sandbox: "demo", session: nil, mode: .watch, size: nil)
        let g2 = try await store.consume(t2, cookie: "c", sandbox: "demo")
        XCTAssertFalse(g2.reattach)
    }

    func testUIPortIsAutomaticOrAnUnprivilegedLoopbackPort() throws {
        let d = try XCTUnwrap(DozerSettings.definition(SettingKey.uiPort))
        XCTAssertEqual(d.defaultValue, .int(0))
        XCTAssertEqual(d.environment, "DOZ_UI_PORT")
        XCTAssertEqual(d.applies, .uiRestart)
        XCTAssertNoThrow(try d.validate(.int(0)))
        XCTAssertNoThrow(try d.validate(.int(1024)))
        XCTAssertNoThrow(try d.validate(.int(65_535)))
        XCTAssertThrowsError(try d.validate(.int(80)))
        XCTAssertThrowsError(try d.validate(.int(1023)))
        XCTAssertThrowsError(try d.validate(.int(65_536)))
        XCTAssertEqual(DozerSettings(text: "[ui]\nport = 7443\n").int(SettingKey.uiPort), 7443)
        XCTAssertEqual(DozerSettings(text: "[ui]\nport = 443\n").int(SettingKey.uiPort), 0, "a privileged port: the default applies")
        XCTAssertEqual(DozerSettings(text: nil, environment: ["DOZ_UI_PORT": "7444"]).int(SettingKey.uiPort), 7444)
        // Still loopback only: the address type holds 127.0.0.1 and a port, nothing else.
        let a = try XCTUnwrap(WebLoopbackAddress(reusing: 54_321))
        XCTAssertEqual(a.host, "127.0.0.1")
    }

    func testHelloNamesTheBuildsPageFiles() throws {
        let a = try WebAssets.load()
        let h = WebHello(serverRun: "r", version: "0.28.0", script: a.pageScript, style: a.pageStyle)
        let j = try XCTUnwrap(try JSONSerialization.jsonObject(with: WebJSON.encoder.encode(h)) as? [String: String])
        XCTAssertEqual(Set(j.keys), ["serverRun", "version", "script", "style"])
        let index = String(decoding: a.assets["/"]!.data, as: UTF8.self)
        XCTAssertTrue(index.contains("src=\"\(j["script"]!)\""), "the page's own script is the one hello names")
        XCTAssertTrue(index.contains("href=\"\(j["style"]!)\""))
    }
}
