import Foundation
import XCTest
@testable import DozerWeb

/// 606 — the remote-capability table (`WebExposure`), pinned: every route, three askers (the Mac's doz ui, a remote
/// browser over plain HTTP, a remote browser over https through a trusted proxy).
final class ServeExposureTests: XCTestCase {
    /// One instance of EVERY route. The switch has no default: a new route does not compile here until it is added
    /// (and so pinned below).
    static let samples: [WebRoute] = {
        let all: [WebRoute] = [
            .index, .asset("/assets/x.js"), .terminalFrame, .offline, .serviceWorker, .sessionBootstrap, .sessionInfo, .sessionRenew, .sessionEnd,
            .overview, .sandbox("s"), .sandboxSessions("s"), .sandboxNetwork("s"), .sandboxTools("s"), .images, .imageTree, .accounts,
            .metrics(WebMetricsQuery.parse(nil)!), .metricsCSV(WebMetricsQuery.parse(nil)!), .events, .doctor, .stream, .actions, .operations,
            .policyPreview("s"), .terminal("s"), .terminalTicket("s"), .terminalSocket("s"), .settings, .settingsChange, .sessionScreen("s", "shell"),
            .terminalLayout("s"), .terminalLayoutSet("s"), .bootLogs("s"), .bootLog("s", 1), .onboarding, .onboardingConfig, .preparations,
            .accountAdd, .sandboxKey("s"), .workspaceCheck, .workspaceChoose, .quickAdd, .projectsDirChoose, .projectOpen, .projectPreview,
            .projectWrite, .resources, .resourcesPreview, .bases, .dockerfileChoose, .access, .accessCheck, .accessGithubKey, .signup,
            .serveStatus, .serveDevices, .serveShare, .serveRevoke("abc123"), .serveRename("abc123"), .serveProbe,
        ]
        for r in all { _ = covered(r) }
        return all
    }()

    static func covered(_ r: WebRoute) -> Bool {
        switch r {
        case .index, .asset, .terminalFrame, .offline, .serviceWorker, .sessionBootstrap, .sessionInfo, .sessionRenew, .sessionEnd, .overview,
             .sandbox, .sandboxSessions, .sandboxNetwork, .sandboxTools, .images, .imageTree, .accounts, .metrics, .metricsCSV, .events, .doctor,
             .stream, .actions, .operations, .policyPreview, .terminal, .terminalTicket, .terminalSocket, .settings, .settingsChange,
             .sessionScreen, .terminalLayout, .terminalLayoutSet, .bootLogs, .bootLog, .onboarding, .onboardingConfig, .preparations,
             .accountAdd, .sandboxKey, .workspaceCheck, .workspaceChoose, .quickAdd, .projectsDirChoose, .projectOpen, .projectPreview,
             .projectWrite, .resources, .resourcesPreview, .bases, .dockerfileChoose, .access, .accessCheck, .accessGithubKey, .signup,
             .serveStatus, .serveDevices, .serveShare, .serveRevoke, .serveRename, .serveProbe:
            return true
        }
    }

    /// The table (606.02-PLAN.md): route → (doz ui, remote http, remote https). nil = allowed.
    static let pinned: [String: (WebRejection?, WebRejection?, WebRejection?)] = {
        var t: [String: (WebRejection?, WebRejection?, WebRejection?)] = [:]
        for r in samples { t[ServeExposureTests.label(r)] = (nil, nil, nil) }
        for secret in ["accountAdd", "sandboxKey", "accessGithubKey"] { t[secret] = (nil, .secretOverHTTP, nil) }
        for screen in ["terminal", "workspaceChoose", "projectsDirChoose", "dockerfileChoose"] { t[screen] = (nil, .macScreen, .macScreen) }
        t["serveProbe"] = (.notFound, nil, nil)
        return t
    }()

    static func label(_ r: WebRoute) -> String { DozerWebServer.routeLabel(r) }

    func testEveryRouteHasItsPinnedDecision() {
        XCTAssertEqual(Self.samples.count, Set(Self.samples.map(Self.label)).count, "one sample per route")
        for r in Self.samples {
            let want = Self.pinned[Self.label(r)]!
            XCTAssertEqual(WebExposure.decide(r, .mac), want.0, "\(Self.label(r)) on doz ui")
            XCTAssertEqual(WebExposure.decide(r, .remote(secure: false)), want.1, "\(Self.label(r)) remote, plain HTTP")
            XCTAssertEqual(WebExposure.decide(r, .remote(secure: true)), want.2, "\(Self.label(r)) remote, https via a trusted proxy")
        }
    }

    func testTheRefusalsSayWhyAndWhatToDo() {
        XCTAssertTrue(WebRejection.secretOverHTTP.message.contains("plain HTTP"))
        XCTAssertTrue(WebRejection.secretOverHTTP.message.contains("doz account add"))
        XCTAssertTrue(WebRejection.secretOverHTTP.message.contains("serve.public_origins"))
        XCTAssertEqual(WebRejection.secretOverHTTP.status, 403)
        XCTAssertTrue(WebRejection.macScreen.message.contains("Mac's own screen"))
        XCTAssertEqual(WebRejection.deviceRevoked.status, 401)
        XCTAssertEqual(WebRejection.tooManyAttempts.status, 429)
    }

    func testNewRoutesParse() {
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/serve"), .serveStatus)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/serve/devices"), .serveDevices)
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/serve/share"), .serveShare)
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/serve/devices/abc123/revoke"), .serveRevoke("abc123"))
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/serve/devices/abc123/name"), .serveRename("abc123"))
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/serve/probe"), .serveProbe)
        XCTAssertNil(WebRoute.parse(method: .post, target: "/api/v1/serve/devices/ABC123/revoke"), "ids are lower case")
        XCTAssertNil(WebRoute.parse(method: .post, target: "/api/v1/serve/devices/abc1234/revoke"))
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/serve/share"))
    }
}
