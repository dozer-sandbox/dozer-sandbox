import CryptoKit
import Foundation
import DozerKit
import DozerHost
import XCTest
@testable import DozerWeb

/// 590 — the rules of `doz ui`'s security layer, one by one (pure functions and the session
/// actor; no listener). The real-listener tests are WebHTTPIntegrationTests.
final class WebSecurityTests: XCTestCase {
    let origin = try! WebOrigin(port: 50123)

    func md(_ m: WebHTTPMethod = .get, host: String? = "127.0.0.1:50123", origin o: String? = nil, site: String? = nil,
            auth: String? = nil, cookie: String? = nil, csrf: String? = nil, type: String? = nil, body: Int = 0) -> WebRequestMetadata {
        WebRequestMetadata(method: m, host: host, origin: o, secFetchSite: site, authorization: auth, cookie: cookie, csrfToken: csrf,
                           contentType: type, bodyByteCount: body)
    }

    func rejection(_ f: () throws -> Void) -> WebRejection? {
        do { try f(); return nil } catch let r as WebRejection { return r } catch { return nil }
    }

    // MARK: configuration

    func testOnlyLoopbackAndAnEphemeralPortAreRepresentable() throws {
        let a = WebLoopbackAddress()
        XCTAssertEqual(a.host, "127.0.0.1")
        XCTAssertEqual(a.port, 0)
        XCTAssertThrowsError(try WebOrigin(port: 0))
        XCTAssertThrowsError(try WebOrigin(port: 70_000))
        XCTAssertEqual(origin.authority, "127.0.0.1:50123")
        XCTAssertEqual(origin.value, "http://127.0.0.1:50123")
    }

    func testCapabilityIs256BitsInTheFragmentOnly() throws {
        let c = WebBootstrapCapability.make()
        XCTAssertEqual(c.value.count, 43)                          // 32 bytes, base64url, no padding
        XCTAssertTrue(WebRandom.isToken(c.value))
        let url = c.launchURL(origin: origin)
        XCTAssertNil(url.query)
        XCTAssertEqual(url.path, "/")
        XCTAssertEqual(url.fragment, "cap=" + c.value)
        XCTAssertNotEqual(WebBootstrapCapability.make(), c)
        // Not printable by accident: no description, debug description or dump carries the value.
        XCTAssertFalse("\(c)".contains(c.value))
        XCTAssertFalse(String(reflecting: c).contains(c.value))
        var dumped = ""
        dump(c, to: &dumped)
        XCTAssertFalse(dumped.contains(c.value))
        XCTAssertThrowsError(try WebBootstrapCapability(testingValue: "short"))
        XCTAssertThrowsError(try WebBootstrapCapability(testingValue: String(repeating: "a", count: 30) + "+/"))
    }

    func testLimitsAreBounded() {
        XCTAssertThrowsError(try WebLimits(maximumRequestBodyBytes: 0))
        XCTAssertThrowsError(try WebLimits(maximumSSEClients: 0))
        XCTAssertThrowsError(try WebLimits(maximumSSEClients: 1000))
        XCTAssertThrowsError(try WebLimits(maximumConnections: 100_000))
    }

    // MARK: listener checks

    func testHostMustBeExactlyTheListener() {
        for h in ["evil.com", "localhost:50123", "127.0.0.1", "127.0.0.1:50124", "[::1]:50123", "127.0.0.1:50123.evil.com", "127.0.0.1:50123 "] {
            XCTAssertEqual(rejection { try WebSecurity.validateStatic(md(host: h), origin) }, .hostRejected, h)
        }
        XCTAssertEqual(rejection { try WebSecurity.validateStatic(md(host: nil), origin) }, .hostRejected)
        XCTAssertNil(rejection { try WebSecurity.validateStatic(md(), origin) })
    }

    func testOriginWhenPresentMustBeExact() {
        for o in ["http://evil.com", "http://127.0.0.1:50124", "https://127.0.0.1:50123", "http://localhost:50123", "null", "http://127.0.0.1:50123/"] {
            XCTAssertEqual(rejection { try WebSecurity.validateStatic(md(origin: o), origin) }, .originRejected, o)
        }
        XCTAssertNil(rejection { try WebSecurity.validateStatic(md(origin: "http://127.0.0.1:50123"), origin) })
    }

    func testFetchMetadataRefusesCrossSite() {
        for s in ["cross-site", "same-site"] {
            XCTAssertEqual(rejection { try WebSecurity.validateStatic(md(site: s), origin) }, .crossSite, s)
        }
        for s in ["same-origin", "none"] { XCTAssertNil(rejection { try WebSecurity.validateStatic(md(site: s), origin) }) }
    }

    func testStaticIsGetOrHeadWithoutBody() {
        XCTAssertEqual(rejection { try WebSecurity.validateStatic(md(.post), origin) }, .methodNotAllowed)
        XCTAssertEqual(rejection { try WebSecurity.validateStatic(md(body: 3), origin) }, .bodyTooLarge)
        XCTAssertNil(rejection { try WebSecurity.validateStatic(md(.head), origin) })
    }

    func testBootstrapNeedsOriginAndABearerCapability() throws {
        let o = "http://127.0.0.1:50123"
        XCTAssertEqual(rejection { _ = try WebSecurity.validateBootstrap(md(.post, auth: "Bearer abcdefabcdefabcdefabcdef"), origin, limit: 100) }, .originRejected)
        XCTAssertEqual(rejection { _ = try WebSecurity.validateBootstrap(md(.post, origin: o), origin, limit: 100) }, .malformedAuthorization)
        XCTAssertEqual(rejection { _ = try WebSecurity.validateBootstrap(md(.post, origin: o, auth: "Basic x"), origin, limit: 100) }, .malformedAuthorization)
        XCTAssertEqual(rejection { _ = try WebSecurity.validateBootstrap(md(.post, origin: o, auth: "Bearer a b"), origin, limit: 100) }, .malformedAuthorization)
        XCTAssertEqual(rejection { _ = try WebSecurity.validateBootstrap(md(.get, origin: o, auth: "Bearer abc"), origin, limit: 100) }, .methodNotAllowed)
        XCTAssertEqual(try WebSecurity.validateBootstrap(md(.post, origin: o, auth: "Bearer abc_DEF-123"), origin, limit: 100), "abc_DEF-123")
    }

    func testAuthenticatedRequestsNeedTheOneCookieAndMutationsTheCSRFHeader() throws {
        let name = WebSecurity.cookieName(origin)
        XCTAssertEqual(name, "doz_ui_50123")
        let o = "http://127.0.0.1:50123"
        XCTAssertEqual(rejection { _ = try WebSecurity.validateAuthenticated(md(), origin, limit: 10) }, .unauthenticated)
        XCTAssertEqual(try WebSecurity.validateAuthenticated(md(cookie: "a=b; \(name)=tok_1"), origin, limit: 10), "tok_1")
        // Another port's cookie is not this server's.
        XCTAssertEqual(rejection { _ = try WebSecurity.validateAuthenticated(md(cookie: "doz_ui_50124=tok"), origin, limit: 10) }, .unauthenticated)
        // Two cookies of the name (cookie tossing): refused.
        XCTAssertEqual(rejection { _ = try WebSecurity.validateAuthenticated(md(cookie: "\(name)=a; \(name)=b"), origin, limit: 10) }, .unauthenticated)
        XCTAssertEqual(rejection { _ = try WebSecurity.validateAuthenticated(md(cookie: "\(name)=a=b"), origin, limit: 10) }, .unauthenticated)
        // Unsafe: Origin required, then the CSRF header present.
        XCTAssertEqual(rejection { _ = try WebSecurity.validateAuthenticated(md(.post, cookie: "\(name)=a", csrf: "x"), origin, limit: 10) }, .originRejected)
        XCTAssertEqual(rejection { _ = try WebSecurity.validateAuthenticated(md(.post, origin: o, cookie: "\(name)=a"), origin, limit: 10) }, .csrfRejected)
        XCTAssertNoThrow(try WebSecurity.validateAuthenticated(md(.delete, origin: o, cookie: "\(name)=a", csrf: "x"), origin, limit: 10))
    }

    func testBodiesAreCappedAndJSONOnly() {
        let o = "http://127.0.0.1:50123", c = "\(WebSecurity.cookieName(origin))=a"
        XCTAssertEqual(rejection { _ = try WebSecurity.validateAuthenticated(md(.post, origin: o, cookie: c, csrf: "x", type: "application/json", body: 11), origin, limit: 10) }, .bodyTooLarge)
        XCTAssertEqual(rejection { _ = try WebSecurity.validateAuthenticated(md(.post, origin: o, cookie: c, csrf: "x", type: "application/x-www-form-urlencoded", body: 5), origin, limit: 10) }, .unsupportedMediaType)
        XCTAssertEqual(rejection { _ = try WebSecurity.validateAuthenticated(md(.post, origin: o, cookie: c, csrf: "x", body: 5), origin, limit: 10) }, .unsupportedMediaType)
        XCTAssertNil(rejection { _ = try WebSecurity.validateAuthenticated(md(.post, origin: o, cookie: c, csrf: "x", type: "application/json; charset=utf-8", body: 5), origin, limit: 10) })
    }

    func testCookieAttributes() {
        let s = WebSecurity.setCookie("v", name: "doz_ui_1", maxAge: 60)
        for part in ["doz_ui_1=v", "Path=/", "Max-Age=60", "HttpOnly", "SameSite=Strict"] { XCTAssertTrue(s.contains(part), part) }
        XCTAssertFalse(s.contains("Domain"))
        XCTAssertTrue(WebSecurity.clearCookie(name: "doz_ui_1").contains("Max-Age=0"))
    }

    func testResponseHeadersAreStrictAndNeverCORS() {
        let h = Dictionary(uniqueKeysWithValues: WebSecurity.responseHeaders.map { ($0.0.lowercased(), $0.1) })
        XCTAssertTrue(h["content-security-policy"]!.contains("default-src 'none'"))
        XCTAssertTrue(h["content-security-policy"]!.contains("script-src 'self'"))
        XCTAssertTrue(h["content-security-policy"]!.contains("frame-ancestors 'none'"))
        // 591 (T2): the PAGE gains only `frame-src 'self'` (its own terminal frame) and compiles no
        // WebAssembly; the frame alone may ('wasm-unsafe-eval'), and it can connect to nothing.
        let csp = h["content-security-policy"]!
        XCTAssertFalse(csp.contains("unsafe"))
        XCTAssertTrue(csp.contains("script-src 'self';"))
        XCTAssertTrue(csp.contains("connect-src 'self';"))
        XCTAssertTrue(csp.contains("frame-src 'self';"))
        let f = Dictionary(uniqueKeysWithValues: WebSecurity.frameHeaders.map { ($0.0.lowercased(), $0.1) })
        let fcsp = f["content-security-policy"]!
        XCTAssertFalse(fcsp.replacingOccurrences(of: "'wasm-unsafe-eval'", with: "").contains("unsafe"))
        for part in ["default-src 'none'", "script-src 'self' 'wasm-unsafe-eval';", "connect-src 'none';", "frame-ancestors 'self';", "img-src 'none';"] {
            XCTAssertTrue(fcsp.contains(part), part)
        }
        XCTAssertEqual(f["x-frame-options"], "SAMEORIGIN")
        XCTAssertEqual(h["x-frame-options"], "DENY")
        XCTAssertEqual(h["x-content-type-options"], "nosniff")
        XCTAssertEqual(h["referrer-policy"], "no-referrer")
        XCTAssertFalse(h.keys.contains { $0.hasPrefix("access-control") })
    }

    // MARK: routes

    func testTheRouteTableIsClosed() {
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/"), .index)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/?x=1"), .index)
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/session"), .sessionBootstrap)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/session"), .sessionInfo)
        XCTAssertEqual(WebRoute.parse(method: .delete, target: "/api/v1/session"), .sessionEnd)
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/session/renew"), .sessionRenew)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/sandboxes/demo-1"), .sandbox("demo-1"))
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/sandboxes/demo/network"), .sandboxNetwork("demo"))
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/stream"), .stream)
        // 593 §9: a saved screen (a session name by the host's rule), the layout (read; POST changes it).
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/sandboxes/demo/sessions/shell-2.x_y/screen"), .sessionScreen("demo", "shell-2.x_y"))
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/sandboxes/demo/layout"), .terminalLayout("demo"))
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/sandboxes/demo/layout"), .terminalLayoutSet("demo"))
        for t in ["/api/v1/sandboxes/demo/sessions/.hidden/screen", "/api/v1/sandboxes/demo/sessions/a%2fb/screen",
                  "/api/v1/sandboxes/demo/sessions/" + String(repeating: "s", count: 65) + "/screen", "/api/v1/sandboxes/demo/sessions/shell/text",
                  "/api/v1/sandboxes/demo/sessions/sh ell/screen", "/api/v1/sandboxes/Demo/layout", "/api/v1/sandboxes/demo/layout/x"] {
            XCTAssertNil(WebRoute.parse(method: .get, target: t), t)
        }
        XCTAssertNil(WebRoute.parse(method: .post, target: "/api/v1/sandboxes/demo/sessions/shell/screen"), "a screen is only read")
        XCTAssertNil(WebRoute.parse(method: .delete, target: "/api/v1/sandboxes/demo/layout"))
        let refused = [
            "/api/v1/sandboxes/../images", "/api/v1/sandboxes/%2e%2e", "/api/v1/sandboxes/Demo", "/api/v1/sandboxes/-x",
            "/api/v1/sandboxes/" + String(repeating: "a", count: 41), "/api/v1/overview/", "//api/v1/overview", "/api/v2/overview",
            "/api/v1/exec", "/api/v1/sandboxes/demo/exec", "/api/v1/sandboxes/demo/attach", "/api/v1/files", "/assets/../index.html",
            "/assets/a/b.js", "api/v1/overview", "/api/v1/sandboxes/de mo", "/manifest.json",
        ]
        for t in refused { XCTAssertNil(WebRoute.parse(method: .get, target: t), t) }
        // 607: the page script's modules — /assets/app/<layer>/<file> and nothing deeper or elsewhere.
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/assets/app/dom/h-0123456789abcdef.js"), .asset("/assets/app/dom/h-0123456789abcdef.js"))
        XCTAssertEqual(WebRoute.parse(method: .head, target: "/assets/app/views/x.js"), .asset("/assets/app/views/x.js"))
        for t in ["/assets/app/x.js", "/assets/app/other/x.js", "/assets/app/dom/a/b.js", "/assets/app/../app.js", "/assets/app/dom/", "/assets/x/dom/h.js"] {
            XCTAssertNil(WebRoute.parse(method: .get, target: t), t)
        }
        XCTAssertNil(WebRoute.parse(method: .post, target: "/assets/app/dom/h.js"))
        // Phase 1: nothing unsafe but the session's own routes.
        for t in ["/api/v1/overview", "/api/v1/sandboxes/demo", "/api/v1/images", "/api/v1/stream", "/"] {
            XCTAssertNil(WebRoute.parse(method: .post, target: t), t)
            XCTAssertNil(WebRoute.parse(method: .delete, target: t), t)
        }
    }

    // MARK: sessions

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    func testBootstrapIsSingleUseAndATypoDoesNotBurnIt() async throws {
        let cap = try WebBootstrapCapability(testingValue: "abcdefghijklmnopqrstuvwxyz0123")
        let store = WebSessionStore(bootstrap: cap, limits: .standard)
        await XCTAssertThrowsRejection(.bootstrapRejected) { _ = try await store.exchange("abcdefghijklmnopqrstuvwxyz0124") }
        let s = try await store.exchange(cap.value)
        XCTAssertNotEqual(s.cookieValue, s.csrfToken)
        XCTAssertFalse(s.cookieValue.contains(cap.value))
        await XCTAssertThrowsRejection(.bootstrapUsed) { _ = try await store.exchange(cap.value) }
        // A minted link works once too, independently.
        let next = await store.issue()
        _ = try await store.exchange(next.value)
        await XCTAssertThrowsRejection(.bootstrapUsed) { _ = try await store.exchange(next.value) }
    }

    func testBootstrapAndSessionsExpire() async throws {
        let clock = Clock()
        let limits = try WebLimits(sessionLifetime: 60, bootstrapLifetime: 10)
        let cap = WebBootstrapCapability.make()
        let store = WebSessionStore(bootstrap: cap, limits: limits, now: { clock.now })
        clock.now += 11
        await XCTAssertThrowsRejection(.bootstrapRejected) { _ = try await store.exchange(cap.value) }
        let fresh = await store.issue()
        let s = try await store.exchange(fresh.value)
        clock.now += 40
        let renewed = try await store.renew(s.cookieValue)
        XCTAssertEqual(renewed.expiresAt, clock.now + 60)
        clock.now += 50
        _ = try await store.authenticate(s.cookieValue)           // renewed: still valid
        clock.now += 11
        await XCTAssertThrowsRejection(.sessionExpired) { _ = try await store.authenticate(s.cookieValue) }
        // 605: and it keeps saying why (the page shows the reason), never a bare "not signed in".
        await XCTAssertThrowsRejection(.sessionExpired) { _ = try await store.authenticate(s.cookieValue) }
    }

    func testMutationsCompareTheCSRFToken() async throws {
        let cap = WebBootstrapCapability.make()
        let store = WebSessionStore(bootstrap: cap, limits: .standard)
        let s = try await store.exchange(cap.value)
        await XCTAssertThrowsRejection(.csrfRejected) { _ = try await store.authenticateMutation(s.cookieValue, csrf: nil) }
        await XCTAssertThrowsRejection(.csrfRejected) { _ = try await store.authenticateMutation(s.cookieValue, csrf: s.csrfToken + "x") }
        _ = try await store.authenticateMutation(s.cookieValue, csrf: s.csrfToken)
        await store.revoke(s.cookieValue)
        // 605: the reason is this browser's own sign-out.
        await XCTAssertThrowsRejection(.signedOut) { _ = try await store.authenticate(s.cookieValue) }
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(constantTimeEqual("abc", "abc"))
        XCTAssertFalse(constantTimeEqual("abc", "abd"))
        XCTAssertFalse(constantTimeEqual("abc", "abcd"))
        XCTAssertFalse(constantTimeEqual("", "a"))
    }

    // MARK: live updates

    func testAStreamThatFallsBehindEndsWithResyncInsteadOfLosingEvents() {
        let c = SSEClient(cookie: "c", capacity: 3)
        for i in 0..<3 { c.send(SSEFrame(comment: "\(i)")) }
        XCTAssertNil(c.end)
        c.send(SSEFrame(comment: "overflow"))
        XCTAssertEqual(c.end, .overflow)
        c.finish(.shutdown)
        XCTAssertEqual(c.end, .overflow)                          // the first reason sticks
    }

    func testTheHubBoundsClientsAndReplacesOnlyTheSameSessionsOldest() {
        let hub = SSEHub(maxClients: 2, capacity: 4)
        let a1 = hub.add(cookie: "a")!
        _ = hub.add(cookie: "b")!
        XCTAssertNil(hub.add(cookie: "c"))                       // full, and c has no stream to replace
        let a2 = hub.add(cookie: "a")
        XCTAssertNotNil(a2)
        XCTAssertEqual(a1.end, .replaced)
        XCTAssertEqual(hub.count, 2)
    }

    func testSSEFramesAreOneDataLine() throws {
        let f = SSEFrame(event: "activity", id: 7, json: Data("{\"text\":\"a\nb\"}".utf8))
        let s = String(decoding: f.bytes, as: UTF8.self)
        XCTAssertEqual(s, "id: 7\nevent: activity\ndata: {\"text\":\"a b\"}\n\n")
    }

    // MARK: assets

    func testTheBundledAssetsLoadAndEveryDigestMatches() throws {
        let a = try WebAssets.load()
        XCTAssertNotNil(a.assets["/"])
        XCTAssertEqual(a.assets["/"]?.cachePolicy, "no-store")
        // 605: + the offline page and the service worker (stable paths, no-store).
        let documents: Set<String> = ["/", WebAssets.frameDocument, WebAssets.offlineDocument, WebAssets.serviceWorker]
        for (path, asset) in a.assets {
            XCTAssertEqual(WebAssets.sha256Hex(asset.data), asset.sha256, path)
            // 591: the page's files are app-*, the terminal frame's frame-*, vendored ones vendor-*; 605: the
            // offline page's offline-*, the app icons icon-*; 607: the page script's modules app/<layer>/*.
            if documents.contains(path) {
                XCTAssertEqual(asset.cachePolicy, "no-store", path)
            } else {
                XCTAssertTrue(["/assets/app-", "/assets/app/", "/assets/frame-", "/assets/vendor-", "/assets/offline-", "/assets/icon-"].contains { path.hasPrefix($0) }, path)
                XCTAssertEqual(asset.cachePolicy, WebAssets.immutable)
            }
        }
        XCTAssertEqual(Set(a.assets.keys).intersection(documents), documents)
        // Every asset is referenced by one of the documents, the web app manifest or the worker — 607: a module by
        // the page script or another module (a relative specifier: its hashed name in quotes).
        let manifest = a.assets.values.first { $0.mimeType == "application/manifest+json" }.map { String(decoding: $0.data, as: UTF8.self) } ?? ""
        let docs = documents.map { String(decoding: a.assets[$0]!.data, as: UTF8.self) } + [manifest]
        let scripts = a.assets.filter { $0.key.hasPrefix("/assets/app") && $0.key.hasSuffix(".js") }.map { String(decoding: $0.value.data, as: UTF8.self) }
        for path in a.assets.keys where !documents.contains(path) {
            if path.hasPrefix("/assets/app/") {
                let name = String(path.split(separator: "/").last!)
                XCTAssertTrue(scripts.contains { $0.contains("/\(name)'") }, "a page script imports \(path)")
                continue
            }
            XCTAssertTrue(docs.contains { $0.contains("\"\(path)\"") }, "a document references \(path)")
        }
        let index = String(decoding: a.assets["/"]!.data, as: UTF8.self)
        XCTAssertFalse(index.contains("vendor-ghostty-web"), "591 T2: the page never loads the engine — only its frame does")
    }

    /// The drift check, in the test suite too: the committed Resources/Web must be exactly what
    /// WebSource/ builds (the hashed names come from the sources' digests). `make web-assets` fixes it.
    func testCommittedAssetsAreBuiltFromTheCurrentSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = root.appendingPathComponent("Sources/DozerWeb/WebSource")
        let web = root.appendingPathComponent("Sources/DozerWeb/Resources/Web")
        let loaded = try WebAssets.load(webRoot: web)
        // 607: app.js is the module entry — served with its import specifiers rewritten to the modules' hashed
        // names (WebModulesTests checks that only those change), so its bytes are compared there.
        for (name, ext) in [("app", "css"), ("frame", "css"), ("frame", "js"), ("offline", "css"), ("offline", "js")] {
            let d = try Data(contentsOf: src.appendingPathComponent("\(name).\(ext)"))
            let path = "/assets/\(name)-\(WebAssets.sha256Hex(d).prefix(16)).\(ext)"
            XCTAssertEqual(loaded.assets[path]?.data, d, "stale \(name).\(ext) — run make web-assets")
        }
        // index + app.css + app.js; (591) the terminal frame + frame.css + frame.js; the engine's script and
        // WebAssembly; (593) the icon sprite; (605) the offline page + offline.css + offline.js, the service
        // worker, the web app manifest, the SVG icon and its four PNGs; (607) one per module of app.js.
        let modules = (FileManager.default.enumerator(atPath: src.appendingPathComponent("app").path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".js") }
        XCTAssertEqual(loaded.assets.count, 19 + modules.count)
        XCTAssertEqual(loaded.assets.keys.filter { $0.hasPrefix("/assets/vendor-") }.count, 3)
    }

    func testAnAlteredAssetRefusesToLoad() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let web = root.appendingPathComponent("Sources/DozerWeb/Resources/Web")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("doz-web-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: web, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertNoThrow(try WebAssets.load(webRoot: tmp))
        try Data("<script>alert(1)</script>".utf8).write(to: tmp.appendingPathComponent("index.html"))
        XCTAssertThrowsError(try WebAssets.load(webRoot: tmp)) { XCTAssertEqual($0 as? WebAssetError, .digestMismatch("index.html")) }
        // An unsafe path in the manifest is refused before any file is read.
        let bad = #"{"version":1,"assets":[{"publicPath":"/","resourcePath":"../../etc/passwd","mimeType":"text/html; charset=utf-8","sha256":"00","cachePolicy":"no-store"}]}"#
        try Data(bad.utf8).write(to: tmp.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try WebAssets.load(webRoot: tmp)) { XCTAssertEqual($0 as? WebAssetError, .unsafePath) }
    }

    // MARK: models

    /// No field of what the API returns may be secret-shaped (the CSRF token of the session answer
    /// is the one deliberate exception, and only there).
    func testNoAPIModelHasASecretShapedField() throws {
        let now = Date()
        let info = SandboxInfo(name: "a", image: "lab", phase: "running", busy: false, cpus: 1, memoryMiB: 1024, ramHeldMiB: 1024,
                               memoryReturnedMiB: 0, diskBytes: 1, sessions: 1, network: "agent", deniedConnections: 0, workspace: nil,
                               createdAt: now, diedWithHost: nil, account: "mac", credentialState: "ok", credentialPolicy: "allow",
                               foreignCredentials: 1)
        let row = CredentialRow(binding: "anthropic", hosts: ["api.anthropic.com"], set: true, source: "keychain:x", account: "mac",
                                state: "ok", expiresAt: now, policy: "allow",
                                foreign: [ForeignCredential(kind: "oauth", prefix: "sk-ant-oat01-XXXXXXXXXX", fingerprint: "abcdef123456",
                                                            header: "authorization", firstSeen: now, lastSeen: now, requests: 2)])
        let values: [any Encodable] = [
            WebOverview(host: WebHost(running: true, version: "1", pid: 1, startedAt: now, idleTimeoutMinutes: 5, idleSeconds: nil,
                                      liveSandboxes: [], connections: 1, recoveryPending: [], store: "/s", uiVersion: "1"),
                        sandboxes: [WebSandboxRow(info)], source: "host"),
            WebCredential(row),
            WebNetwork(name: "a", proxied: true, mode: "agent", policy: nil, log: [], logTotal: 0, denied: 0, logAvailable: true, note: nil),
            WebAccounts(accounts: [], defaultAccount: "mac", keepalive: false),
            WebMetrics(available: false, runs: 0, rows: 0, sessions: 0, networkMinutes: 0, summary: []),
            WebActivity(seq: 1, kind: "host", text: "x"),
            // 593 §9
            WebSavedScreen(SessionScreen(name: "a", SavedScreen(info: SavedScreenInfo(session: "s", savedAt: now, reason: "sleep"), vt: Data(), text: ""))),
            WebTerminalLayout(TerminalLayout(panes: [.init(tabs: [.init(session: "s")], selected: 0)])),
            // 594
            WebOnboarding(status: PrepareStatus(preparations: [], onboarded: nil, images: [], hostRunning: true),
                          checks: [OnboardingCheck(check: "claude login", status: "ok", detail: "signed in", hard: false)],
                          freeBytes: 1, macSignedIn: true, defaultAccount: "mac"),
            WebPreparation(PreparationInfo(id: "a", image: "pi", state: "running", requestedBy: ["doz onboard"], startedAt: now, finishedAt: nil,
                                           seconds: 1, error: nil, step: "s", stepSeconds: 1,
                                           transfer: PreparationTransfer(label: "pulling", completedBytes: 1, totalBytes: 2, completedItems: 1,
                                                                         totalItems: 2, line: "l"), output: ["o"], lines: ["l"])),
            WebOnboardingConfigResult(settings: "written", settingsPath: "/x", promptTemplate: "kept", promptTemplatePath: "/y", rulesSet: ["workspace.ignore_mode = lock"]),
            // 599g
            WebRulesGuide(),
            WebRuleFile(WorkspaceRulesGuide.FolderFile(name: ".dozignore", patterns: 2, first: ["secrets.env"], skipped: 0)),
        ]
        let forbidden = ["secret", "token", "password", "apikey", "api_key", "bearer", "authorization", "cookie", "csrf", "credentialvalue"]
        for v in values {
            let obj = try JSONSerialization.jsonObject(with: WebJSON.encoder.encode(v))
            for key in keys(obj) {
                XCTAssertFalse(forbidden.contains { key.lowercased().contains($0) }, "secret-shaped field \(key) in \(type(of: v))")
            }
        }
        // A foreign credential's prefix is cut to 13 characters whatever the library hands over.
        XCTAssertEqual(WebCredential(row).foreign.first?.prefix.count, 13)
    }

    func keys(_ o: Any) -> [String] {
        if let d = o as? [String: Any] { return d.keys + d.values.flatMap(keys) }
        if let a = o as? [Any] { return a.flatMap(keys) }
        return []
    }

    func testShellQuoteForTheAttachCommand() {
        XCTAssertEqual(shellQuote("/Users/x/store"), "/Users/x/store")
        XCTAssertEqual(shellQuote("/Users/x/My Store"), "'/Users/x/My Store'")
        XCTAssertEqual(shellQuote("/a'b"), "'/a'\\''b'")
        XCTAssertEqual(shellQuote("/a;rm -rf ~"), "'/a;rm -rf ~'")
    }
}

func XCTAssertThrowsRejection(_ expected: WebRejection, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await body()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let r as WebRejection {
        XCTAssertEqual(r, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
}
