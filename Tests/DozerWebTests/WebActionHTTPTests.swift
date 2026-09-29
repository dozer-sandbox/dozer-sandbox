import Foundation
import DozerKit
import DozerHost
import XCTest
@testable import DozerWeb

/// 590 phase 2 over a real listener: the action routes' boundary (Origin + CSRF + JSON), the
/// operation lifecycle over SSE, the preview, the Terminal route, metrics filters and CSV.
final class WebActionHTTPTests: XCTestCase {
    var server: DozerWebServer!
    var serveTask: Task<Void, Error>!
    let capability = try! WebBootstrapCapability(testingValue: "test-capability-abcdefghijklmnopqrstuvwxyz")
    let fake = FakeData()
    var cookie = ""
    var csrf = ""

    override func setUp() async throws {
        server = try await DozerWebServer.bind(data: fake, assets: try WebAssets.load(), version: "test", limits: try WebLimits(heartbeatInterval: 0.3),
                                                capability: capability, pollInterval: .milliseconds(200))
        let s = server!
        serveTask = Task { try await s.run() }
        let r = try get("/api/v1/session", ["Origin": origin, "Authorization": "Bearer \(capability.value)"], method: "POST")
        cookie = String(try XCTUnwrap(r.header("set-cookie")).split(separator: ";")[0])
        csrf = try XCTUnwrap((try JSONSerialization.jsonObject(with: r.body) as? [String: Any])?["csrf"] as? String)
    }

    override func tearDown() async throws {
        fake.hold = false
        await server?.close()
        _ = try? await serveTask?.value
        server = nil
    }

    var origin: String { server.origin.value }

    func get(_ path: String, _ headers: [String: String] = [:], method: String = "GET", body: String? = nil) throws -> RawResponse {
        var h = ["Host": server.origin.authority]
        for (k, v) in headers { h[k] = v }
        return try RawHTTP.request(port: server.origin.port, method: method, path: path, headers: h, body: body)
    }

    func post(_ path: String, _ body: String, headers: [String: String]? = nil) throws -> RawResponse {
        try get(path, headers ?? ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf, "Content-Type": "application/json"], method: "POST", body: body)
    }

    func json(_ r: RawResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:] }

    // MARK: the boundary

    func testActionsNeedOriginCSRFAndAJSONBody() throws {
        let body = #"{"action":"pause","sandbox":"demo"}"#
        XCTAssertEqual(try post("/api/v1/actions", body, headers: ["Cookie": cookie, "Origin": origin, "Content-Type": "application/json"]).status, 403, "no CSRF")
        XCTAssertEqual(try post("/api/v1/actions", body, headers: ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": "nope", "Content-Type": "application/json"]).status, 403)
        XCTAssertEqual(try post("/api/v1/actions", body, headers: ["Cookie": cookie, "X-Doz-CSRF": csrf, "Content-Type": "application/json"]).status, 403, "no Origin")
        XCTAssertEqual(try post("/api/v1/actions", body, headers: ["Cookie": cookie, "Origin": "http://evil.example", "X-Doz-CSRF": csrf, "Content-Type": "application/json"]).status, 403)
        XCTAssertEqual(try post("/api/v1/actions", body, headers: ["Origin": origin, "X-Doz-CSRF": csrf, "Content-Type": "application/json"]).status, 401, "no cookie")
        XCTAssertEqual(try post("/api/v1/actions", body, headers: ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf, "Content-Type": "text/plain"]).status, 415)
        XCTAssertEqual(try post("/api/v1/actions", "action=pause&sandbox=demo",
                                headers: ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf, "Content-Type": "application/x-www-form-urlencoded"]).status, 415)
        XCTAssertEqual(try get("/api/v1/actions", ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf, "Content-Type": "application/json"], method: "POST").status, 400, "empty")
        XCTAssertEqual(try post("/api/v1/actions", body, headers: ["Cookie": cookie, "Origin": origin, "X-Doz-CSRF": csrf,
                                                                    "Content-Type": "application/json", "Sec-Fetch-Site": "cross-site"]).status, 403)
        XCTAssertTrue(fake.performed.isEmpty, "nothing reached the host")
    }

    /// Every action over HTTP: refused without CSRF, then accepted with it and sent to the host as
    /// exactly its one HostOp.
    func testEveryActionOverHTTP() throws {
        let workspace = FileManager.default.temporaryDirectory.path
        for (name, sample) in WebActionTests.samples.sorted(by: { $0.key < $1.key }) {
            let body = sample.replacingOccurrences(of: "\"image\":\"lab\",", with: "\"image\":\"lab\",\"workspace\":\"\(workspace)\",")
            let before = fake.performed.count
            XCTAssertEqual(try post("/api/v1/actions", body, headers: ["Cookie": cookie, "Origin": origin, "Content-Type": "application/json"]).status, 403, "\(name) without CSRF")
            let r = try post("/api/v1/actions", body)
            XCTAssertEqual(r.status, 202, "\(name): \(r.text)")
            let deadline = Date().addingTimeInterval(5)
            while fake.performed.count == before && Date() < deadline { usleep(10_000) }
            XCTAssertEqual(fake.performed.last?.op, try WebAction.decode(Data(body.utf8)).hostOp, name)
            while try get("/api/v1/operations", ["Cookie": cookie]).text.contains("\"state\":\"running\"") && Date() < deadline { usleep(10_000) }
        }
        XCTAssertEqual(fake.performed.count, WebActionTests.samples.count)
    }

    func testAnInvalidOrUnconfirmedActionIs400AndNeverReachesTheHost() throws {
        for body in [#"{"action":"exec","sandbox":"demo","argv":["id"]}"#, #"{"action":"rm","sandbox":"demo"}"#,
                     #"{"action":"rm","sandbox":"demo","confirm":"other"}"#, #"{"action":"pause","sandbox":"demo","x":1}"#,
                     #"{"action":"key-set","sandbox":"demo","secret":"sk-ant-api03-canary"}"#] {
            let r = try post("/api/v1/actions", body)
            XCTAssertEqual(r.status, 400, body)
            XCTAssertEqual((json(r)["error"] as? [String: Any])?["code"] as? String, "invalid")
            XCTAssertFalse(r.text.contains("canary"))
        }
        XCTAssertTrue(fake.performed.isEmpty)
    }

    // MARK: operations

    func testAnActionRunsAsAnOperationWithProgressOverSSE() throws {
        let s = try RawStream(port: server.origin.port, path: "/api/v1/stream", headers: ["Host": server.origin.authority, "Cookie": cookie])
        defer { s.close() }
        _ = try s.read(until: "event: hello", seconds: 5)
        let r = try post("/api/v1/actions", #"{"action":"hibernate","sandbox":"demo"}"#)
        XCTAssertEqual(r.status, 202)
        let op = json(r)
        XCTAssertEqual(op["state"] as? String, "running")
        XCTAssertEqual(op["sandbox"] as? String, "demo")
        XCTAssertEqual(op["label"] as? String, "hibernate demo")
        let text = try s.read(until: "running → paused", seconds: 5)
        XCTAssertTrue(text.contains("event: op"))
        XCTAssertTrue(text.contains("fake step one"), "the host's progress line reached the page")
        XCTAssertTrue(text.contains("\"state\":\"done\""))
        XCTAssertEqual(fake.performed.map(\.op), [.hibernate])
        XCTAssertEqual(fake.performed.first?.name, "demo")
        let ops = try get("/api/v1/operations", ["Cookie": cookie])
        XCTAssertTrue(ops.text.contains("\"state\":\"done\""))
    }

    func testAFailedOperationSaysWhy() throws {
        fake.failWith = HostError(.invalidPhase, "demo is off — `doz start demo` boots it")
        let r = try post("/api/v1/actions", #"{"action":"pause","sandbox":"demo"}"#)
        XCTAssertEqual(r.status, 202)
        let deadline = Date().addingTimeInterval(5)
        var ops = ""
        while Date() < deadline {
            ops = try get("/api/v1/operations", ["Cookie": cookie]).text
            if ops.contains("failed") { break }
            usleep(50_000)
        }
        XCTAssertTrue(ops.contains("\"state\":\"failed\""))
        XCTAssertTrue(ops.contains("demo is off"))
    }

    func testOperationsAreBounded() throws {
        fake.hold = true
        for i in 0..<8 { XCTAssertEqual(try post("/api/v1/actions", #"{"action":"pause","sandbox":"s\#(i)"}"#).status, 202) }
        let over = try post("/api/v1/actions", #"{"action":"pause","sandbox":"s9"}"#)
        XCTAssertEqual(over.status, 503)
        XCTAssertTrue(over.text.contains("too-many-operations"))
        fake.hold = false
    }

    /// 590 bug 2: a double-clicked action is one operation — the repeat is 409 while the first runs;
    /// another sandbox, or another session, is not blocked.
    func testARepeatOfAnInFlightActionIsRefused() throws {
        fake.hold = true
        XCTAssertEqual(try post("/api/v1/actions", #"{"action":"open-session","sandbox":"demo"}"#).status, 202)
        let again = try post("/api/v1/actions", #"{"action":"open-session","sandbox":"demo"}"#)
        XCTAssertEqual(again.status, 409)
        XCTAssertTrue(again.text.contains("already-running"))
        XCTAssertEqual(try post("/api/v1/actions", #"{"action":"open-session","sandbox":"demo","session":"other"}"#).status, 202)
        XCTAssertEqual(try post("/api/v1/actions", #"{"action":"open-session","sandbox":"demo2"}"#).status, 202)
        fake.hold = false
        let deadline = Date().addingTimeInterval(5)
        while try get("/api/v1/operations", ["Cookie": cookie]).text.contains("\"state\":\"running\"") && Date() < deadline { usleep(20_000) }
        XCTAssertEqual(try post("/api/v1/actions", #"{"action":"open-session","sandbox":"demo"}"#).status, 202, "once it finished, it may run again")
        XCTAssertEqual(fake.performed.count, 4)
    }

    // MARK: preview, terminal

    func testThePolicyPreviewChangesNothing() throws {
        let r = try post("/api/v1/sandboxes/demo/network/preview", #"{"allow":["example.com"],"remove":["pypi.org"]}"#)
        XCTAssertEqual(r.status, 200, r.text)
        let p = json(r)
        XCTAssertEqual(p["changed"] as? Bool, true)
        XCTAssertTrue((p["added"] as? [String])?.contains { $0.contains("example.com") } == true)
        XCTAssertTrue((p["removed"] as? [String])?.contains { $0.contains("pypi.org") } == true)
        XCTAssertTrue(fake.performed.isEmpty, "a preview is not an operation")
        XCTAssertEqual(try post("/api/v1/sandboxes/demo/network/preview", #"{"sandbox":"other","allow":["x.com"]}"#).status, 400)
        XCTAssertEqual(try post("/api/v1/sandboxes/demo/network/preview", #"{}"#).status, 400)
        XCTAssertEqual(try post("/api/v1/sandboxes/demo/network/preview", #"{"allow":["x.com"]}"#,
                                headers: ["Cookie": cookie, "Origin": origin, "Content-Type": "application/json"]).status, 403)
    }

    func testTheTerminalRouteOpensTheFixedCommandOnly() throws {
        let r = try post("/api/v1/sandboxes/demo/terminal", #"{"session":"worker"}"#)
        XCTAssertEqual(r.status, 200, r.text)
        XCTAssertEqual(fake.terminalCommands, ["exec /opt/doz/bin/doz attach demo worker --store /tmp/fake-store"])
        XCTAssertEqual(try post("/api/v1/sandboxes/demo/terminal", #"{"argv":["id"]}"#).status, 400, "a command is never accepted")
        XCTAssertEqual(try post("/api/v1/sandboxes/demo/terminal", #"{"session":"a;b"}"#).status, 400)
        XCTAssertEqual(try post("/api/v1/sandboxes/nope/terminal", #"{}"#).status, 404)
        XCTAssertEqual(try post("/api/v1/sandboxes/demo/terminal", #"{}"#,
                                headers: ["Cookie": cookie, "Origin": origin, "Content-Type": "application/json"]).status, 403, "CSRF")
        XCTAssertEqual(fake.terminalCommands.count, 1)
    }

    // MARK: metrics

    func testMetricsFiltersAndCSV() throws {
        XCTAssertEqual(try get("/api/v1/metrics?image=lab&days=7&steps=1", ["Cookie": cookie]).status, 200)
        XCTAssertEqual(fake.metricsQueries.last, WebMetricsQuery(image: "lab", days: 7, steps: true))
        XCTAssertEqual(try get("/api/v1/metrics?image=../x", ["Cookie": cookie]).status, 404)
        let csv = try get("/api/v1/metrics.csv?days=1", ["Cookie": cookie])
        XCTAssertEqual(csv.status, 200)
        XCTAssertEqual(csv.header("content-type"), "text/csv; charset=utf-8")
        XCTAssertEqual(csv.header("content-disposition"), "attachment; filename=\"doz-metrics.csv\"")
        XCTAssertEqual(csv.header("x-content-type-options"), "nosniff")
        XCTAssertEqual(try get("/api/v1/metrics.csv").status, 401)
    }
}
