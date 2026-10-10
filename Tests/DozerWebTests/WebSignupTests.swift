import Darwin
import Foundation
import DozerKit
@testable import DozerHost
import XCTest
@testable import DozerWeb

/// The setup wizard's Stay in touch — `POST /api/v1/signup` on a REAL listener: a typed route (strict body, CSRF,
/// exact Origin), handed to the installed package (a FAKE here — nothing reaches a network), 404 in a build from the
/// repository, and the email never in an answer or an error.
final class WebSignupTests: XCTestCase {
    var server: DozerWebServer!
    var serveTask: Task<Void, Error>!
    let capability = try! WebBootstrapCapability(testingValue: "test-capability-abcdefghijklmnopqrstuvwxyz")
    let fake = FakeData()
    final class Got: @unchecked Sendable { var requests: [SignupRequest] = []; var fail = false }
    let got = Got()

    override func setUp() async throws {
        server = try await DozerWebServer.bind(data: fake, assets: try WebAssets.load(), version: "test",
                                                settings: WebSettingsStore(environment: [:]),
                                                capability: capability, pollInterval: .milliseconds(200))
        let s = server!
        serveTask = Task { try await s.run() }
    }

    override func tearDown() async throws {
        Usage.uninstall()
        await server?.close()
        _ = try? await serveTask?.value
        server = nil
    }

    func installFake() {
        let got = self.got
        Usage.install(send: { _ in }, flush: { _ in }, signup: { r in
            if got.fail { throw UsageError("the server said no for \(r.email)") }
            got.requests.append(r)
            return SignupResult(status: "confirmation-sent")
        })
    }

    var origin: String { server.origin.value }

    func request(_ path: String, _ headers: [String: String] = [:], method: String = "GET", body: String? = nil) throws -> RawResponse {
        var h = ["Host": server.origin.authority]
        for (k, v) in headers { h[k] = v }
        return try RawHTTP.request(port: server.origin.port, method: method, path: path, headers: h, body: body)
    }

    func signIn() throws -> (String, String, [String: Any]) {
        let s = server!
        let box = Box<URL>()
        let sem = DispatchSemaphore(value: 0)
        Task { box.value = await s.newLink(); sem.signal() }
        XCTAssertEqual(sem.wait(timeout: .now() + 5), .success)
        let cap = String(try XCTUnwrap(box.value?.fragment).dropFirst("cap=".count))
        let r = try request("/api/v1/session", ["Origin": origin, "Authorization": "Bearer \(cap)"], method: "POST")
        XCTAssertEqual(r.status, 200, r.text)
        let pair = String(try XCTUnwrap(r.header("set-cookie")).split(separator: ";")[0])
        let info = try XCTUnwrap(try JSONSerialization.jsonObject(with: r.body) as? [String: Any])
        return (pair, try XCTUnwrap(info["csrf"] as? String), info)
    }
    final class Box<T>: @unchecked Sendable { var value: T? }

    func post(_ body: String, _ cookie: String, _ csrf: String?) throws -> RawResponse {
        var h = ["Cookie": cookie, "Origin": origin, "Content-Type": "application/json"]
        if let csrf { h["X-Doz-CSRF"] = csrf }
        return try request("/api/v1/signup", h, method: "POST", body: body)
    }

    let good = #"{"email":"me@example.com","interests":["release-news","support"]}"#

    func testTheRouteAndItsExposure() {
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/signup"), .signup)
        XCTAssertNotEqual(WebRoute.parse(method: .get, target: "/api/v1/signup"), .signup)
        XCTAssertEqual(WebExposure.kind(.signup), .change)
    }

    func testTheBodyIsDecodedStrictlyAndNeverEchoed() throws {
        let r = try WebSignup.decode(Data(good.utf8))
        XCTAssertEqual(r, SignupRequest(email: "me@example.com", interests: ["release-news", "support"], source: "onboarding-web"))
        for body in [#"{"email":"me@example.com"}"#, #"{"email":"me@example.com","interests":["support"],"source":"cli"}"#,
                     #"{"email":"secret-me@","interests":["support"]}"#, #"{"email":"secret-me@example.com","interests":[]}"#,
                     #"{"email":"secret-me@example.com","interests":["support","support"]}"#,
                     #"{"email":"secret-me@example.com","interests":["everything"]}"#, #"{"email":7,"interests":["support"]}"#, "[]", "nope"] {
            XCTAssertThrowsError(try WebSignup.decode(Data(body.utf8)), body) { e in
                XCTAssertFalse("\(e)".contains("secret-me"), "never echoes the address: \(body)")
            }
        }
    }

    func testAnOpenBuildAnswers404AndTheSessionSaysSo() throws {
        let (cookie, csrf, info) = try signIn()
        XCTAssertEqual(info["signup"] as? Bool, false)
        XCTAssertEqual(info["signupPage"] as? String, Usage.signupPage)
        let r = try post(good, cookie, csrf)
        XCTAssertEqual(r.status, 404, r.text)
        XCTAssertTrue(r.text.contains("signup-unavailable"), r.text)
        XCTAssertFalse(r.text.contains("me@example.com"))
    }

    func testAnOfficialBuildHandsItOverWithCSRFOnly() throws {
        installFake()
        let (cookie, csrf, info) = try signIn()
        XCTAssertEqual(info["signup"] as? Bool, true)
        XCTAssertEqual(try post(good, cookie, nil).status, 403, "no CSRF token")
        XCTAssertEqual(try post(good, cookie, "wrong").status, 403)
        XCTAssertTrue([401, 403].contains(try request("/api/v1/signup", ["Origin": origin, "Content-Type": "application/json"], method: "POST", body: good).status), "no session")
        XCTAssertTrue(got.requests.isEmpty)
        let r = try post(good, cookie, csrf)
        XCTAssertEqual(r.status, 200, r.text)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: r.body) as? [String: Any])?["status"] as? String, "confirmation-sent")
        XCTAssertFalse(r.text.contains("me@example.com"), "the answer never carries the address")
        XCTAssertEqual(got.requests, [SignupRequest(email: "me@example.com", interests: ["release-news", "support"], source: "onboarding-web")])
        XCTAssertEqual(try post(#"{"email":"me@example.com","interests":["support"],"extra":1}"#, cookie, csrf).status, 400)
        // A failure is one fixed message — the package's own error (which names the address here) never reaches the page.
        got.fail = true
        let f = try post(good, cookie, csrf)
        XCTAssertNotEqual(f.status, 200)
        XCTAssertFalse(f.text.contains("me@example.com"), f.text)
        XCTAssertTrue(f.text.contains("could not be sent"), f.text)
    }
}
