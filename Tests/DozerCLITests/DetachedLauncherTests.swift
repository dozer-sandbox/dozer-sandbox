import XCTest
@testable import DozerHost

/// 606 rc.2 — `doz serve start --detach` is the host's double spawn (`HostLauncher`): the intermediate and the detached
/// process's argument lists.
final class DetachedLauncherTests: XCTestCase {
    func testTheIntermediateAndTheDetachedServe() {
        XCTAssertEqual(DetachedLauncher.serveIntermediateArgs(executable: "/opt/doz", store: "/tmp/s", extra: ["--port", "17613"]),
                       ["/opt/doz", "serve", "start", "--launch-detached", "--store", "/tmp/s", "--port", "17613"])
        let p = DetachedLauncher.serveProcessArgs(executable: "/opt/doz", store: "/tmp/s", extra: ["--bind", "loopback"])
        XCTAssertEqual(p, ["/opt/doz", "serve", "start", "--launched", "--no-invite", "--store", "/tmp/s", "--bind", "loopback"])
        XCTAssertFalse(p.contains("--detach"), "the detached one never detaches again")
        XCTAssertTrue(p.contains("--no-invite"), "no terminal: no invite printed into a log")
        XCTAssertEqual(DetachedLauncher.serveLog(URL(fileURLWithPath: "/tmp/s")).path, "/tmp/s/serve/serve.log")
    }
}
