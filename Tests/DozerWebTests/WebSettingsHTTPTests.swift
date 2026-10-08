import Darwin
import Foundation
import DozerKit
import DozerHost
import XCTest
@testable import DozerWeb

/// 591 settings — the Settings routes on a REAL listener: the report, and the one typed change
/// (closed schema, CSRF, exact Origin, JSON only, validated, one write). The settings file lives
/// under a scratch XDG_CONFIG_HOME — never the owner's ~/.config.
final class WebSettingsHTTPTests: XCTestCase {
    var server: DozerWebServer!
    var serveTask: Task<Void, Error>!
    let capability = try! WebBootstrapCapability(testingValue: "test-capability-abcdefghijklmnopqrstuvwxyz")
    let fake = FakeData()
    var xdg: URL!
    var file: URL { xdg.appendingPathComponent("dozer-sandbox/doz.toml") }

    override func setUp() async throws {
        xdg = FileManager.default.temporaryDirectory.appendingPathComponent("doz-websettings-\(UUID().uuidString.prefix(8))")
        try await start(["XDG_CONFIG_HOME": xdg.path])
    }

    func start(_ env: [String: String]) async throws {
        await server?.close()
        _ = try? await serveTask?.value
        server = try await DozerWebServer.bind(data: fake, assets: try WebAssets.load(), version: "test",
                                                settings: WebSettingsStore(environment: env),
                                                capability: capability, pollInterval: .milliseconds(200))
        let s = server!
        serveTask = Task { try await s.run() }
    }

    override func tearDown() async throws {
        await server?.close()
        _ = try? await serveTask?.value
        server = nil
        try? FileManager.default.removeItem(at: xdg)
    }

    var host: String { server.origin.authority }
    var origin: String { server.origin.value }

    func request(_ path: String, _ headers: [String: String] = [:], method: String = "GET", body: String? = nil) throws -> RawResponse {
        var h = ["Host": host]
        for (k, v) in headers { h[k] = v }
        return try RawHTTP.request(port: server.origin.port, method: method, path: path, headers: h, body: body)
    }

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

    func awaitValue<T: Sendable>(_ f: @escaping @Sendable () async -> T) throws -> T {
        let box = Box<T>()
        let sem = DispatchSemaphore(value: 0)
        Task { box.value = await f(); sem.signal() }
        guard sem.wait(timeout: .now() + 5) == .success, let v = box.value else { throw POSIXError(.ETIMEDOUT) }
        return v
    }
    final class Box<T>: @unchecked Sendable { var value: T? }

    func change(_ body: String, _ cookie: String, _ csrf: String?, origin o: String? = nil, type: String = "application/json") throws -> RawResponse {
        var h = ["Cookie": cookie, "Origin": o ?? origin, "Content-Type": type]
        if let csrf { h["X-Doz-CSRF"] = csrf }
        return try request("/api/v1/settings", h, method: "POST", body: body)
    }

    func report(_ r: RawResponse) throws -> SettingsReport {
        try JSONDecoder().decode(SettingsReport.self, from: r.body)
    }

    func row(_ r: SettingsReport, _ key: String) throws -> SettingRow { try XCTUnwrap(r.settings.first { $0.key == key }) }

    // MARK: -

    func testTheReportListsEverySettingWithItsSourceAndNeedsASession() throws {
        XCTAssertEqual(try request("/api/v1/settings").status, 401)
        let (cookie, _) = try signIn()
        let r = try request("/api/v1/settings", ["Cookie": cookie])
        XCTAssertEqual(r.status, 200, r.text)
        let rep = try report(r)
        XCTAssertEqual(rep.path, file.path)
        XCTAssertFalse(rep.exists)
        XCTAssertEqual(rep.settings.map(\.key), DozerSettings.schema.map(\.key))
        XCTAssertTrue(rep.settings.allSatisfy { $0.source == .default && $0.value == $0.defaultValue })
        XCTAssertEqual(try row(rep, "ui.boot_view_on_start").value, .bool(true))
        XCTAssertFalse(try row(rep, "store.path").editable, "a host path is read-only in the UI")
        XCTAssertTrue(try row(rep, "ui.boot_view_on_start").editable)
        XCTAssertFalse(rep.notSettable.isEmpty)
    }

    func testAChangeIsWrittenAndReadBackAndReset() throws {
        let (cookie, csrf) = try signIn()
        var r = try change(#"{"key":"ui.boot_view_on_start","value":false}"#, cookie, csrf)
        XCTAssertEqual(r.status, 200, r.text)
        var rep = try report(r)
        XCTAssertEqual(try row(rep, "ui.boot_view_on_start").value, .bool(false))
        XCTAssertEqual(try row(rep, "ui.boot_view_on_start").source, .file)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\nboot_view_on_start = false\n"), "the file shows the uncommented value")
        XCTAssertTrue(text.contains("\n# confirm_shutdown = true\n"), "the rest stays commented at its default")
        var st = stat()
        XCTAssertEqual(stat(file.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        // The page re-reads it.
        rep = try report(try request("/api/v1/settings", ["Cookie": cookie]))
        XCTAssertEqual(try row(rep, "ui.boot_view_on_start").value, .bool(false))
        // Other types.
        for body in [#"{"key":"ui.terminal_font_size","value":16}"#, #"{"key":"ui.split_default","value":"watch"}"#,
                     #"{"key":"images.pi.memory_mib","value":4096}"#, #"{"key":"defaults.nat_subnet","value":"192.168.70.0/24"}"#] {
            r = try change(body, cookie, csrf)
            XCTAssertEqual(r.status, 200, body + " " + r.text)
        }
        XCTAssertEqual(DozerSettings.load(environment: ["XDG_CONFIG_HOME": xdg.path]).fileValues.count, 5)
        // Reset.
        r = try change(#"{"key":"ui.boot_view_on_start","reset":true}"#, cookie, csrf)
        XCTAssertEqual(r.status, 200, r.text)
        XCTAssertEqual(try row(try report(r), "ui.boot_view_on_start").source, .default)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("\n# boot_view_on_start = true\n"))
    }

    func testTheRouteRefusesNoCSRFAnotherOriginAndNonJSON() throws {
        let (cookie, csrf) = try signIn()
        let body = #"{"key":"ui.theme","value":"dark"}"#
        var r = try change(body, cookie, nil)
        XCTAssertEqual(r.status, 403, r.text)
        XCTAssertTrue(r.text.contains("csrf-rejected"))
        r = try change(body, cookie, "not-the-token")
        XCTAssertEqual(r.status, 403)
        r = try change(body, cookie, csrf, origin: "http://evil.example")
        XCTAssertEqual(r.status, 403)
        r = try change(body, cookie, csrf, type: "text/plain")
        XCTAssertEqual(r.status, 415)
        r = try request("/api/v1/settings", ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf], method: "PUT", body: body)
        XCTAssertNotEqual(r.status, 200)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing was written")
    }

    func testTheRouteRefusesUnknownKeysAndBadValues() throws {
        let (cookie, csrf) = try signIn()
        let bad = [
            #"{"key":"ui.nope","value":true}"#, #"{"key":"nope","value":true}"#, #"{"value":true}"#, #"{"key":1,"value":true}"#,
            #"{"key":"ui.boot_view_on_start","value":"false"}"#, #"{"key":"ui.boot_view_on_start","value":0}"#,
            #"{"key":"ui.terminal_font_size","value":200}"#, #"{"key":"ui.terminal_font_size","value":13.5}"#,
            #"{"key":"ui.terminal_font_size","value":true}"#, #"{"key":"ui.split_default","value":"tab"}"#,
            #"{"key":"images.lab.network","value":"wide-open"}"#, #"{"key":"defaults.nat_subnet","value":"10.0.0.1"}"#,
            #"{"key":"ui.theme","value":["dark"]}"#, #"{"key":"ui.theme","value":null}"#, #"{"key":"ui.theme"}"#,
            #"{"key":"ui.theme","value":"dark","reset":true}"#, #"{"key":"ui.theme","reset":false}"#, #"{"key":"ui.theme","reset":1}"#,
            #"{"key":"ui.theme","value":"dark","extra":1}"#, #"["ui.theme","dark"]"#, #"not json"#,
        ]
        for body in bad {
            let r = try change(body, cookie, csrf)
            XCTAssertEqual(r.status, 400, body + " → " + r.text)
            XCTAssertFalse(r.text.contains("wide-open"), "a refused value is never echoed")
        }
        // A host path is not the UI's to set.
        let path = try change(#"{"key":"store.path","value":"/tmp/elsewhere"}"#, cookie, csrf)
        XCTAssertEqual(path.status, 400, path.text)
        XCTAssertTrue(path.text.contains("doz config set"))
        let kernel = try change(#"{"key":"kernel.path","value":"/tmp/vmlinux"}"#, cookie, csrf)
        XCTAssertEqual(kernel.status, 400)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing was written")
    }

    func testAValueTheEnvironmentSetsIsReadOnly() async throws {
        try await start(["XDG_CONFIG_HOME": xdg.path, "DOZ_HOST_IDLE": "9"])
        let (cookie, csrf) = try signIn()
        let rep = try report(try request("/api/v1/settings", ["Cookie": cookie]))
        let idle = try row(rep, "host.idle_timeout_minutes")
        XCTAssertEqual(idle.source, .env)
        XCTAssertEqual(idle.value, .int(9))
        XCTAssertFalse(idle.editable)
        XCTAssertTrue(idle.note?.contains("DOZ_HOST_IDLE") == true)
        let r = try change(#"{"key":"host.idle_timeout_minutes","value":30}"#, cookie, csrf)
        XCTAssertEqual(r.status, 409, r.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAFileThatDoesNotParseIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let broken = "[ui]\ntheme = dark\n"
        try broken.write(to: file, atomically: true, encoding: .utf8)
        let (cookie, csrf) = try signIn()
        let rep = try report(try request("/api/v1/settings", ["Cookie": cookie]))
        XCTAssertNotNil(rep.error)
        XCTAssertTrue(rep.settings.allSatisfy { !$0.editable })
        let r = try change(#"{"key":"ui.theme","value":"dark"}"#, cookie, csrf)
        XCTAssertEqual(r.status, 409, r.text)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), broken)
    }

    func testTerminalsOffRefusesATicket() throws {
        let (cookie, csrf) = try signIn()
        XCTAssertEqual(try change(#"{"key":"ui.terminals","value":false}"#, cookie, csrf).status, 200)
        let r = try request("/api/v1/sandboxes/demo/terminal-ticket",
                            ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf, "Content-Type": "application/json"],
                            method: "POST", body: #"{"mode":"interactive","cols":100,"rows":30}"#)
        XCTAssertEqual(r.status, 403, r.text)
        XCTAssertTrue(r.text.contains("terminals-off"))
        XCTAssertEqual(try change(#"{"key":"ui.terminals","reset":true}"#, cookie, csrf).status, 200)
        let ok = try request("/api/v1/sandboxes/demo/terminal-ticket",
                             ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf, "Content-Type": "application/json"],
                             method: "POST", body: #"{"mode":"interactive","cols":100,"rows":30}"#)
        XCTAssertEqual(ok.status, 200, ok.text)
    }

    func testTheRoutesParse() {
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/settings"), .settings)
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/settings"), .settingsChange)
        XCTAssertNil(WebRoute.parse(method: .delete, target: "/api/v1/settings"))
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/settings/ui.theme"))
        // 594
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/onboarding"), .onboarding)
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/onboarding/config"), .onboardingConfig)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/preparations"), .preparations)
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/accounts"), .accountAdd)
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/sandboxes/demo/key"), .sandboxKey("demo"))
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/sandboxes/demo/key"))
        XCTAssertNil(WebRoute.parse(method: .post, target: "/api/v1/sandboxes/Bad_Name/key"))
        XCTAssertNil(WebRoute.parse(method: .delete, target: "/api/v1/accounts"))
        XCTAssertNotEqual(WebRoute.parse(method: .get, target: "/api/v1/accounts"), .accountAdd, "GET is the list")
        XCTAssertNil(WebRoute.parse(method: .post, target: "/api/v1/onboarding"))
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/onboarding/config"))
        XCTAssertNil(WebRoute.parse(method: .post, target: "/api/v1/preparations"))
        XCTAssertNil(WebRoute.parse(method: .delete, target: "/api/v1/onboarding"))
    }

    /// 594 (D7): the wizard's settings — doz.toml and the prompt template, each written only when
    /// missing; CSRF, exact Origin and a strict body, as every change.
    func testTheOnboardingConfigIsWrittenOnlyWhenMissing() throws {
        let (cookie, csrf) = try signIn()
        func post(_ body: String, csrf c: String?) throws -> RawResponse {
            var h = ["Cookie": cookie, "Origin": origin, "Content-Type": "application/json"]
            if let c { h["X-Doz-CSRF"] = c }
            return try request("/api/v1/onboarding/config", h, method: "POST", body: body)
        }
        let body = #"{"defaultImage":"claude-code","account":"mac"}"#
        XCTAssertEqual(try post(body, csrf: nil).status, 403, "no CSRF token")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        for bad in [#"{"defaultImage":"claude-code"}"#, #"{"defaultImage":"ubuntu","account":"mac"}"#,
                    #"{"defaultImage":"pi","account":"sk-ant-api03-x"}"#, #"{"defaultImage":"pi","account":"mac","path":"/etc"}"#] {
            let r = try post(bad, csrf: csrf)
            XCTAssertEqual(r.status, 400, bad)
            XCTAssertFalse(r.text.contains("sk-ant"), "a refusal never echoes the value")
        }
        let first = try post(body, csrf: csrf)
        XCTAssertEqual(first.status, 200, first.text)
        let res = try JSONDecoder().decode(WebOnboardingConfigResult.self, from: first.body)
        XCTAssertEqual(res.settings, "written")
        XCTAssertEqual(res.promptTemplate, "written")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\nimage = \"claude-code\"\n"))
        XCTAssertTrue(text.contains("\naccount = \"mac\"\n"))
        let again = try JSONDecoder().decode(WebOnboardingConfigResult.self, from: try post(#"{"defaultImage":"lab","account":"later"}"#, csrf: csrf).body)
        XCTAssertEqual(again.settings, "kept")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text, "never overwritten")
        // The wizard's facts and the host's preparations: read with the session.
        XCTAssertEqual(try request("/api/v1/onboarding").status, 401)
        let o = try request("/api/v1/onboarding", ["Cookie": cookie])
        XCTAssertEqual(o.status, 200, o.text)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let ob = try dec.decode(WebOnboarding.self, from: o.body)
        XCTAssertEqual(ob.settingsPath, file.path)
        XCTAssertTrue(ob.settingsExists)
        XCTAssertEqual(ob.defaultImage, "claude-code")
        XCTAssertFalse(ob.blocked)
        XCTAssertEqual(ob.preferredAccount, "later", "no Mac login: decide later is the default")
        XCTAssertEqual(ob.accountOptions.map(\.value), ["api-key", "setup-token", "mac", "later"])
        XCTAssertEqual(try request("/api/v1/preparations", ["Cookie": cookie]).text, "[]")
    }

    /// 594 (owner ruling: sandbox keys in the browser too): POST /api/v1/sandboxes/NAME/key — the same
    /// guarantees as an account: CSRF, a strict {secret} body, the setting, never echoed, scrubbed errors.
    func testASandboxKeyFromAMaskedFieldNeverComesBack() throws {
        let (cookie, csrf) = try signIn()
        let key = "sk-ant-api03-SBXFAKE" + String(repeating: "w", count: 40)
        func post(_ sandbox: String, _ body: String, csrf c: String? = nil) throws -> RawResponse {
            var h = ["Cookie": cookie, "Origin": origin, "Content-Type": "application/json"]
            if let c { h["X-Doz-CSRF"] = c }
            return try request("/api/v1/sandboxes/\(sandbox)/key", h, method: "POST", body: body)
        }
        func clean(_ r: RawResponse, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertFalse(r.text.contains(key) || r.text.contains("SBXFAKEwww"), "\(what): the key came back: \(r.text)", file: file, line: line)
        }
        let good = #"{"secret":"\#(key)"}"#
        var r = try post("demo", good)
        XCTAssertEqual(r.status, 403, "no CSRF token")
        clean(r, "no CSRF")
        for bad in [#"{"secret":"\#(key)","binding":"claude-oauth"}"#,   // the binding is not the browser's to pick
                    #"{"secret":"\#(key)","source":"keychain:x"}"#,
                    #"{"secret":"\#(key)","sandbox":"other"}"#,          // the sandbox comes from the path
                    #"{"secret":"short"}"#, #"{"secret":7}"#, #"{}"#] {
            r = try post("demo", bad, csrf: csrf)
            XCTAssertEqual(r.status, 400, bad)
            clean(r, "a refusal")
        }
        XCTAssertTrue(fake.keysSet.isEmpty)
        r = try post("demo", good, csrf: csrf)
        XCTAssertEqual(r.status, 200, r.text)
        clean(r, "the stored-state summary")
        XCTAssertTrue(r.text.contains("\"source\":\"browser\"") && r.text.contains("\"set\":true"), r.text)
        XCTAssertEqual(fake.keysSet.map(\.sandbox), ["demo"])
        XCTAssertEqual(fake.keysSet.first?.secret, key)
        XCTAssertFalse("\(fake.keysSet[0])".contains(key) || String(reflecting: fake.keysSet[0]).contains(key), "redacted")
        r = try post("boom", good, csrf: csrf)
        XCTAssertEqual(r.status, 400)
        clean(r, "a failure whose host message quoted it")
        XCTAssertTrue(r.text.contains("the key … was refused"), r.text)
        r = try post("nope", good, csrf: csrf)
        XCTAssertEqual(r.status, 404)
        clean(r, "not found")
        // Off: refused, like an account.
        XCTAssertEqual(try request("/api/v1/settings", ["Cookie": cookie, "Origin": origin, "Content-Type": "application/json", "X-Doz-CSRF": csrf],
                                   method: "POST", body: #"{"key":"ui.allow_secret_entry","value":false}"#).status, 200)
        r = try post("demo", good, csrf: csrf)
        XCTAssertEqual(r.status, 403)
        XCTAssertTrue(r.text.contains("secret-entry-off") && r.text.contains("doz key set"), r.text)
        clean(r, "secret entry off")
        XCTAssertEqual(fake.keysSet.count, 1)
    }

    /// 594 (owner: "an easier way to pick a workspace folder", "a better default name", "i dont want the
    /// user to have to create the path first"): the check (defaults, "will be created", refusals — it
    /// makes nothing) and the Mac's picker (CSRF, exact Origin, strict body, one at a time; the test seam
    /// stands in for the dialog — no dialog is ever shown here).
    func testTheWorkspaceCheckAndTheFolderPicker() throws {
        let (cookie, csrf) = try signIn()
        func post(_ path: String, _ body: String, csrf c: String? = nil, origin o: String? = nil) throws -> RawResponse {
            var h = ["Cookie": cookie, "Origin": o ?? origin, "Content-Type": "application/json"]
            if let c { h["X-Doz-CSRF"] = c }
            return try request(path, h, method: "POST", body: body)
        }
        func object(_ r: RawResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:] }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let scratch = "/private/tmp/dzwc-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        // Both need CSRF and the exact Origin.
        for path in ["/api/v1/workspace/check", "/api/v1/workspace/choose"] {
            XCTAssertEqual(try post(path, "{}").status, 403, "\(path): no CSRF")
            XCTAssertEqual(try post(path, "{}", csrf: csrf, origin: "http://evil.example").status, 403, "\(path): a foreign Origin")
            XCTAssertEqual(try post(path, #"{"nope":1}"#, csrf: csrf).status, 400, "\(path): an unknown field")
            XCTAssertEqual(try request(path, ["Cookie": cookie]).status, 404, "\(path): GET is not a route")
        }
        XCTAssertFalse(server.folderPicker.isOpen)

        // Unset, the projects folder is ~/dozer-sandbox-workspaces (whatever this Mac has in it).
        var r = try post("/api/v1/workspace/check", #"{"image":"claude-code","name":"my-box"}"#, csrf: csrf)
        XCTAssertEqual(r.status, 200, r.text)
        var o = object(r)
        XCTAssertEqual(o["defaultPath"] as? String, home + "/dozer-sandbox-workspaces/my-box", "the path follows the name")
        XCTAssertEqual(o["projectsDir"] as? String, home + "/dozer-sandbox-workspaces")
        // defaults.projects_dir moves it (a path: doz config set, not the browser — like kernel.path).
        XCTAssertEqual(try change(#"{"key":"defaults.projects_dir","value":"\#(scratch)/projects"}"#, cookie, csrf).status, 400)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[defaults]\nprojects_dir = \"\(scratch)/projects\"\n".write(to: file, atomically: true, encoding: .utf8)
        // Defaults: the name from the image (demo is taken, not these), the folder under projects_dir.
        o = object(try post("/api/v1/workspace/check", #"{"image":"claude-code"}"#, csrf: csrf))
        XCTAssertEqual(o["suggestedName"] as? String, "claude-sandbox")
        XCTAssertEqual(o["defaultPath"] as? String, scratch + "/projects/claude-sandbox")
        XCTAssertNil(o["error"], "no red error on first view")
        o = object(try post("/api/v1/workspace/check", #"{"image":"lab"}"#, csrf: csrf))
        XCTAssertEqual(o["defaultPath"] as? String, scratch + "/projects/lab-sandbox")
        // A folder there with something in it is taken: the name moves on to -2.
        try FileManager.default.createDirectory(atPath: scratch + "/projects/pi-sandbox", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: scratch + "/projects/pi-sandbox/README"))
        o = object(try post("/api/v1/workspace/check", #"{"image":"pi"}"#, csrf: csrf))
        XCTAssertEqual(o["suggestedName"] as? String, "pi-sandbox-2")
        XCTAssertEqual(o["defaultPath"] as? String, scratch + "/projects/pi-sandbox-2")

        // A typed path: will be created / exists / refused — and nothing is made.
        o = object(try post("/api/v1/workspace/check", #"{"path":"\#(scratch)/new/deep"}"#, csrf: csrf))
        XCTAssertEqual(o["willCreate"] as? Bool, true)
        XCTAssertEqual(o["exists"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch + "/new"), "a check makes nothing")
        try FileManager.default.createDirectory(atPath: scratch + "/have", withIntermediateDirectories: true)
        o = object(try post("/api/v1/workspace/check", #"{"path":"\#(scratch)/have"}"#, csrf: csrf))
        XCTAssertEqual(o["exists"] as? Bool, true)
        XCTAssertNil(o["willCreate"])
        for (bad, says) in [("relative/dir", "absolute"), ("/", "whole Mac"), ("~", "home folder"), ("/usr/local/dozwc", "system location"),
                            ("/tmp/fake-store/ws", "inside the store")] {
            o = object(try post("/api/v1/workspace/check", #"{"path":"\#(bad)"}"#, csrf: csrf))
            XCTAssertTrue((o["error"] as? String)?.contains(says) == true, "\(bad): \(o)")
            XCTAssertNil(o["willCreate"], bad)
        }
        XCTAssertEqual(try post("/api/v1/workspace/check", #"{"path":"a\nb"}"#, csrf: csrf).status, 400, "one line")

        // The picker, through the seam: a folder, then cancelled.
        server.folderPicker.setRunner { _ in scratch + "/have/" }
        r = try post("/api/v1/workspace/choose", #"{"start":"\#(scratch)/new/deep"}"#, csrf: csrf)
        XCTAssertEqual(r.status, 200, r.text)
        XCTAssertEqual(object(r)["path"] as? String, scratch + "/have")
        XCTAssertEqual(object(r)["cancelled"] as? Bool, false)
        server.folderPicker.setRunner { _ in nil }
        o = object(try post("/api/v1/workspace/choose", "{}", csrf: csrf))
        XCTAssertEqual(o["cancelled"] as? Bool, true)
        XCTAssertNil(o["path"])
        XCTAssertEqual(try post("/api/v1/workspace/choose", #"{"start":"relative"}"#, csrf: csrf).status, 400)
        // It opens at the nearest existing folder of the field (never a path that does not exist).
        XCTAssertEqual(WebFolderPicker.startFolder(scratch + "/new/deep", projectsDir: "/nowhere"), scratch)
        XCTAssertEqual(WebFolderPicker.startFolder(nil, projectsDir: scratch + "/have/x"), scratch + "/have")

        // One at a time: while one is open, a second is refused (409) — and the first still answers.
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        server.folderPicker.setRunner { _ in
            entered.signal()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.global().async { gate.wait(); c.resume() } }
            return scratch + "/have"
        }
        let first = Box<RawResponse>()
        let done = DispatchSemaphore(value: 0)
        let (port, hostHeader, originValue) = (server.origin.port, host, origin)
        DispatchQueue.global().async {
            first.value = try? RawHTTP.request(port: port, method: "POST", path: "/api/v1/workspace/choose",
                                               headers: ["Host": hostHeader, "Cookie": cookie, "Origin": originValue, "Content-Type": "application/json",
                                                         "X-Doz-CSRF": csrf], body: "{}")
            done.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(server.folderPicker.isOpen)
        r = try post("/api/v1/workspace/choose", "{}", csrf: csrf)
        XCTAssertEqual(r.status, 409, r.text)
        XCTAssertTrue(r.text.contains("picker-open"), r.text)
        gate.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(first.value?.status, 200)
        XCTAssertFalse(server.folderPicker.isOpen)
    }

    /// The seam: DOZ_TEST_FOLDER_PICKER=/path answers that path, =cancel cancels (no dialog).
    func testTheFolderPickerSeam() async throws {
        let p = WebFolderPicker(environment: ["DOZ_TEST_FOLDER_PICKER": "/private/tmp/x"])
        let a = try await p.choose(start: "/private/tmp")
        XCTAssertEqual(a, WebFolderChoice(path: "/private/tmp/x", cancelled: false))
        let c = try await WebFolderPicker(environment: ["DOZ_TEST_FOLDER_PICKER": "cancel"]).choose(start: "/")
        XCTAssertEqual(c, WebFolderChoice(path: nil, cancelled: true))
        XCTAssertTrue(WebFolderPicker.script.contains("on run argv") && WebFolderPicker.script.contains("item 1 of argv"),
                      "the start folder is an argument of the fixed script, never its text")
    }

    /// 599c: Quick add's plan (CSRF, strict body; changes nothing) — the default image, a free name, the
    /// folder under projects_dir, and a requirement when one click cannot decide; and the Settings page's
    /// Choose… for defaults.projects_dir: the Mac's picker (the seam), its answer written by the SERVER —
    /// the settings route still refuses the key from the browser.
    func testQuickAddAndTheProjectsFolderPicker() throws {
        let (cookie, csrf) = try signIn()
        func post(_ path: String, _ body: String, csrf c: String? = nil) throws -> RawResponse {
            var h = ["Cookie": cookie, "Origin": origin, "Content-Type": "application/json"]
            if let c { h["X-Doz-CSRF"] = c }
            return try request(path, h, method: "POST", body: body)
        }
        func object(_ r: RawResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:] }
        let scratch = "/private/tmp/dzqa-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[defaults]\nprojects_dir = \"\(scratch)/projects\"\nimage = \"lab\"\n".write(to: file, atomically: true, encoding: .utf8)

        for path in ["/api/v1/quick-add", "/api/v1/settings/projects-dir/choose"] {
            XCTAssertEqual(try post(path, "{}").status, 403, "\(path): no CSRF")
            XCTAssertEqual(try post(path, #"{"nope":1}"#, csrf: csrf).status, 400, "\(path): an unknown field")
            XCTAssertEqual(try request(path, ["Cookie": cookie]).status, 404, "\(path): GET is not a route")
        }
        XCTAssertEqual(try post("/api/v1/settings/projects-dir/choose", #"{"path":"/etc"}"#, csrf: csrf).status, 400, "the page never names the path")
        XCTAssertEqual(try post("/api/v1/quick-add", #"{"isolated":"yes"}"#, csrf: csrf).status, 400)

        // The plan: lab (the setting), lab-sandbox (demo is the fake's sandbox), its folder — nothing made.
        var r = try post("/api/v1/quick-add", "{}", csrf: csrf)
        XCTAssertEqual(r.status, 200, r.text)
        var o = object(r)
        XCTAssertEqual(o["name"] as? String, "lab-sandbox")
        XCTAssertEqual(o["image"] as? String, "lab")
        XCTAssertEqual(o["workspace"] as? String, scratch + "/projects/lab-sandbox")
        XCTAssertNil(o["requirement"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch + "/projects"), "a plan makes nothing")
        o = object(try post("/api/v1/quick-add", #"{"isolated":true}"#, csrf: csrf))
        XCTAssertNil(o["workspace"])
        // pi, with no API-key account (the fake has none): the form, with the requirement.
        o = object(try post("/api/v1/quick-add", #"{"image":"pi"}"#, csrf: csrf))
        XCTAssertEqual(o["name"] as? String, "pi-sandbox")
        XCTAssertEqual(o["requirementKind"] as? String, "account")
        XCTAssertTrue((o["requirement"] as? String)?.contains("pi needs an Anthropic API key") == true, "\(o)")

        // The projects folder: never from the settings route (a host path) …
        XCTAssertEqual(try change(#"{"key":"defaults.projects_dir","value":"\#(scratch)/x"}"#, cookie, csrf).status, 400)
        // … but from the Mac's picker: what was chosen there is written.
        try FileManager.default.createDirectory(atPath: scratch + "/chosen", withIntermediateDirectories: true)
        server.folderPicker.setRunner { _ in scratch + "/chosen/" }
        r = try post("/api/v1/settings/projects-dir/choose", "{}", csrf: csrf)
        XCTAssertEqual(r.status, 200, r.text)
        o = object(r)
        XCTAssertEqual(o["path"] as? String, scratch + "/chosen")
        XCTAssertEqual(o["cancelled"] as? Bool, false)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("projects_dir = \"\(scratch)/chosen\""))
        XCTAssertEqual(object(try post("/api/v1/quick-add", "{}", csrf: csrf))["workspace"] as? String, scratch + "/chosen/lab-sandbox")
        // Cancelled: nothing changes. Inside the store: refused.
        server.folderPicker.setRunner { _ in nil }
        o = object(try post("/api/v1/settings/projects-dir/choose", "{}", csrf: csrf))
        XCTAssertEqual(o["cancelled"] as? Bool, true)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("projects_dir = \"\(scratch)/chosen\""))
        server.folderPicker.setRunner { _ in "/tmp/fake-store/projects" }
        r = try post("/api/v1/settings/projects-dir/choose", "{}", csrf: csrf)
        XCTAssertEqual(r.status, 400, r.text)
        XCTAssertTrue(r.text.contains("inside the store"), r.text)
        XCTAssertTrue(WebFolderPicker.script.contains("item 2 of argv"), "the prompt is an argument of the fixed script too")
    }

    /// 599f: the wizard's project routes — CSRF, the exact Origin, strict bodies, POST only; `project-create`
    /// only with {folder}. (The YAML itself is read by the CLI's parser: ProjectWizardTests.)
    func testTheProjectRoutes() throws {
        let (cookie, csrf) = try signIn()
        func post(_ path: String, _ body: String, csrf c: String? = nil, origin o: String? = nil) throws -> RawResponse {
            var h = ["Cookie": cookie, "Origin": o ?? origin, "Content-Type": "application/json"]
            if let c { h["X-Doz-CSRF"] = c }
            return try request(path, h, method: "POST", body: body)
        }
        let scratch = "/private/tmp/dzpr-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        for path in ["/api/v1/project/open", "/api/v1/project/preview", "/api/v1/project/write"] {
            XCTAssertEqual(try post(path, #"{"folder":"\#(scratch)"}"#).status, 403, "\(path): no CSRF")
            XCTAssertEqual(try post(path, #"{"folder":"\#(scratch)"}"#, csrf: csrf, origin: "http://evil.example").status, 403, "\(path): a foreign Origin")
            XCTAssertEqual(try post(path, #"{"folder":"\#(scratch)","nope":1}"#, csrf: csrf).status, 400, "\(path): an unknown field")
            XCTAssertEqual(try request(path, ["Cookie": cookie]).status, 404, "\(path): GET is not a route")
        }
        XCTAssertEqual(try post("/api/v1/project/open", #"{"folder":"\#(scratch)","form":{}}"#, csrf: csrf).status, 400, "open takes only the folder")
        let r = try post("/api/v1/project/open", #"{"folder":"\#(scratch)/new"}"#, csrf: csrf)
        XCTAssertEqual(r.status, 200, r.text)
        XCTAssertTrue(r.text.contains("\"review\"") && r.text.contains("\"name\":\"new\""), r.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch + "/new"), "open makes nothing")
        XCTAssertEqual(try post("/api/v1/project/preview", #"{"folder":"\#(scratch)","form":{"name":"a","image":"lab","rogue":1}}"#, csrf: csrf).status, 400)
        XCTAssertEqual(try post("/api/v1/project/write", #"{"folder":"\#(scratch)","form":{"name":"a","image":"lab"},"replace":"x"}"#, csrf: csrf).status, 400)
        XCTAssertEqual(try post("/api/v1/actions", #"{"action":"project-create","folder":"\#(scratch)","image":"lab"}"#, csrf: csrf).status, 400)
        XCTAssertEqual(try post("/api/v1/actions", #"{"action":"project-create","folder":"\#(scratch)"}"#, csrf: csrf).status, 404, "no project file there")
    }

    /// 594 (owner ruling): a key or a token typed in the browser — ONE CSRF-checked POST, a strict body,
    /// allowed only while ui.allow_secret_entry; no response (success, refusal or failure) carries it.
    func testAnAccountFromAMaskedFieldNeverComesBack() throws {
        let (cookie, csrf) = try signIn()
        let key = "sk-ant-api03-FAKE" + String(repeating: "q", count: 40)
        func post(_ body: String, csrf c: String? = nil, origin o: String? = nil) throws -> RawResponse {
            var h = ["Cookie": cookie, "Origin": o ?? origin, "Content-Type": "application/json"]
            if let c { h["X-Doz-CSRF"] = c }
            return try request("/api/v1/accounts", h, method: "POST", body: body)
        }
        func clean(_ r: RawResponse, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertFalse(r.text.contains(key) || r.text.contains("FAKEqqqq"), "\(what): the secret came back: \(r.text)", file: file, line: line)
        }
        let good = #"{"name":"work","kind":"api-key","secret":"\#(key)"}"#
        var r = try post(good)
        XCTAssertEqual(r.status, 403, "no CSRF token")
        clean(r, "no CSRF")
        r = try post(good, csrf: csrf, origin: "http://evil.example")
        XCTAssertEqual(r.status, 403, "a foreign Origin")
        XCTAssertTrue(fake.addedAccounts.isEmpty)
        XCTAssertNotEqual(WebRoute.parse(method: .get, target: "/api/v1/accounts?secret=x"), .accountAdd, "only a POST adds")
        for bad in [#"{"name":"work","kind":"api-key","secret":"\#(key)","note":"x"}"#,          // an unknown field
                    #"{"name":"work","kind":"mac","secret":"\#(key)"}"#,                         // the Mac login takes no secret
                    #"{"name":"default","kind":"api-key","secret":"\#(key)"}"#,                  // reserved
                    #"{"name":"work","kind":"api-key","secret":"\#(key)","plan":"max"}"#,         // plan is a token's
                    #"{"name":"work","kind":"api-key","secret":"short"}"#,
                    #"{"name":"work","kind":"api-key"}"#] {
            r = try post(bad, csrf: csrf)
            XCTAssertEqual(r.status, 400, bad)
            clean(r, "a refusal")
        }
        r = try post(good, csrf: csrf)
        XCTAssertEqual(r.status, 200, r.text)
        clean(r, "the stored-state summary")
        XCTAssertTrue(r.text.contains("doz-anthropic:work") && r.text.contains("abcdef123456"), "the summary: the item's name and a fingerprint")
        XCTAssertEqual(fake.addedAccounts.map(\.name), ["work"])
        XCTAssertEqual(fake.addedAccounts.first?.secret, key, "the host got it")
        XCTAssertFalse("\(fake.addedAccounts[0])".contains(key), "its description is redacted")
        XCTAssertFalse(String(reflecting: fake.addedAccounts[0]).contains(key))
        r = try post(#"{"name":"sub","kind":"setup-token","plan":"max","secret":"sk-ant-oat01-\#(String(repeating: "t", count: 40))"}"#, csrf: csrf)
        XCTAssertEqual(r.status, 200, r.text)
        XCTAssertEqual(fake.addedAccounts.last?.plan, "max")
        r = try post(#"{"name":"boom","kind":"api-key","secret":"\#(key)"}"#, csrf: csrf)
        XCTAssertEqual(r.status, 500)
        clean(r, "a failure whose host message quoted it")
        XCTAssertTrue(r.text.contains("Anthropic rejected … (HTTP 401)"), r.text)

        // The browser can turn secret entry off, never on; off, the route refuses.
        func setting(_ body: String) throws -> RawResponse {
            try request("/api/v1/settings", ["Cookie": cookie, "Origin": origin, "Content-Type": "application/json", "X-Doz-CSRF": csrf],
                        method: "POST", body: body)
        }
        XCTAssertEqual(try setting(#"{"key":"ui.allow_secret_entry","value":false}"#).status, 200)
        r = try post(good, csrf: csrf)
        XCTAssertEqual(r.status, 403)
        XCTAssertTrue(r.text.contains("secret-entry-off"), r.text)
        clean(r, "secret entry off")
        XCTAssertEqual(try setting(#"{"key":"ui.allow_secret_entry","value":true}"#).status, 400, "never on from the browser")
        XCTAssertEqual(try setting(#"{"key":"ui.allow_secret_entry","reset":true}"#).status, 400, "a reset would turn it on")
        XCTAssertEqual(fake.addedAccounts.count, 2)
    }
}
