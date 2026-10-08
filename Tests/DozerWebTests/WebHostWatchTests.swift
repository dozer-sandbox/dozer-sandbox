import Darwin
import Foundation
import DozerKit
import DozerHost
import XCTest
@testable import DozerWeb

/// 594 W18 — the UI watches the host: every start, clean stop, crash and change of build is told once
/// (the SSE `host` event); `doz ui` asks for its last port again so an open page reconnects.
final class WebHostWatchTests: XCTestCase {
    func host(_ running: Bool, pid: Int32? = nil, version: String? = nil, live: [String] = [], pending: [String] = []) -> WebHost {
        WebHost(running: running, version: version, pid: pid, startedAt: nil, idleTimeoutMinutes: nil, idleSeconds: nil,
                liveSandboxes: live, connections: nil, recoveryPending: pending, store: "/s", uiVersion: "ui")
    }

    func overview(_ h: WebHost, died: [String] = []) -> WebOverview {
        let rows = ["a", "b"].map { name in
            WebSandboxRow(SandboxInfo(name: name, image: "lab", phase: "off", busy: false, cpus: 1, memoryMiB: 512, ramHeldMiB: 0,
                                      memoryReturnedMiB: 0, diskBytes: 0, sessions: nil, network: "nat", deniedConnections: nil,
                                      workspace: nil, createdAt: nil, diedWithHost: died.contains(name) ? true : nil))
        }
        return WebOverview(host: h, sandboxes: rows, source: h.running ? "host" : "store")
    }

    func testTheFirstLookTellsNothingThenEachTransitionOnce() {
        var w = WebHostWatch()
        XCTAssertEqual(w.saw(overview(host(true, pid: 10, version: "0.12.0-rc.3", live: ["a"]))), [], "the first look only sets the state")
        XCTAssertEqual(w.saw(overview(host(true, pid: 10, version: "0.12.0-rc.3", live: ["a"]))), [])
        // A clean stop: no stale pid, nothing to recover — `a` was hibernated.
        let stop = w.probed(WebHostProbe(running: false, exitReason: "doz host stop"))
        XCTAssertEqual(stop?.state, "stopped")
        XCTAssertEqual(stop?.sandboxes, ["a"])
        XCTAssertEqual(stop?.reason, "doz host stop")
        XCTAssertEqual(stop?.version, "0.12.0-rc.3")
        XCTAssertNil(w.probed(WebHostProbe(running: false)), "told once")
        XCTAssertEqual(w.saw(overview(host(false))), [])
        // It comes back as another build.
        let up = w.saw(overview(host(true, pid: 11, version: "0.12.0-rc.4")))
        XCTAssertEqual(up.map(\.state), ["running"])
        XCTAssertEqual(up.first?.previousVersion, "0.12.0-rc.3")
        XCTAssertEqual(up.first?.text, "host started (pid 11, doz 0.12.0-rc.4) — was doz 0.12.0-rc.3")
        // The same build again: no "was".
        _ = w.probed(WebHostProbe(running: false))
        XCTAssertNil(w.saw(overview(host(true, pid: 12, version: "0.12.0-rc.4"))).first?.previousVersion)
    }

    func testAKillWithARunningSandboxIsADeathAndItsRecoveryIsNotToldTwice() {
        var w = WebHostWatch()
        _ = w.saw(overview(host(true, pid: 10, version: "v", live: ["a", "b"])))
        // kill -9: the pid file stays, `a` ran (lost), `b` was asleep (restored asleep, not lost).
        let died = w.probed(WebHostProbe(running: false, stalePID: true, lost: ["a"], recovering: ["a", "b"]))
        XCTAssertEqual(died?.state, "died")
        XCTAssertEqual(died?.sandboxes, ["a"])
        XCTAssertNil(died?.reason)
        XCTAssertEqual(died?.text, "host died — 1 sandbox was running, now shut down: a")
        // The overview then starts a host to recover (the CLI's rule): `a` shows "died with host".
        let next = w.saw(overview(host(true, pid: 20, version: "v"), died: ["a"]))
        XCTAssertEqual(next.map(\.state), ["running"], "the death is not told again")
        XCTAssertEqual(w.saw(overview(host(true, pid: 20, version: "v"), died: ["a"])), [])
    }

    func testAKilledIdleHostIsADeathToo() {
        var w = WebHostWatch()
        _ = w.saw(overview(host(true, pid: 10, version: "v")))
        let c = w.probed(WebHostProbe(running: false, stalePID: true))
        XCTAssertEqual(c?.state, "died")
        XCTAssertEqual(c?.sandboxes, [])
        XCTAssertEqual(c?.text, "host died — no sandbox was running")
    }

    func testANewHostBetweenTwoLooksIsStillTold() {
        var w = WebHostWatch()
        _ = w.saw(overview(host(true, pid: 10, version: "v", live: ["a"])))
        // Killed and recovered (by a CLI command) between two polls: the mark tells the death.
        let c = w.saw(overview(host(true, pid: 30, version: "v"), died: ["a"]))
        XCTAssertEqual(c.map(\.state), ["died", "running"])
        XCTAssertEqual(c.first?.sandboxes, ["a"])
        // Replaced cleanly between two polls: a stop, then the start.
        let d = w.saw(overview(host(true, pid: 31, version: "v2"), died: ["a"]))
        XCTAssertEqual(d.map(\.state), ["stopped", "running"])
        XCTAssertEqual(d.last?.previousVersion, "v")
    }

    func testWithoutAProbeTheOverviewDecides() {
        var w = WebHostWatch()
        _ = w.saw(overview(host(true, pid: 1, version: "v", live: ["a"])))
        XCTAssertEqual(w.saw(overview(host(false, pending: ["a"]))).map(\.state), ["died"])
        _ = w.saw(overview(host(true, pid: 2, version: "v", live: ["b"])))
        let s = w.saw(overview(host(false)))
        XCTAssertEqual(s.map(\.state), ["stopped"])
        XCTAssertEqual(s.first?.sandboxes, ["b"])
    }

    func testTheExitReasonIsTheLastHostsOwnWord() {
        let t = "2026-09-30T10:00:00Z"
        func log(_ lines: [String]) -> String { lines.map { "\(t) \($0)" }.joined(separator: "\n") + "\n" }
        XCTAssertEqual(HostExitReason.parse(log(["doz host 1 (pid 5) — store /s", "host stop requested: hibernating every sandbox, then exiting", "host exiting"])), "doz host stop")
        XCTAssertEqual(HostExitReason.parse(log(["doz host 1 (pid 5) — store /s", "signal 15: hibernating every sandbox, then exiting", "host exiting"])), "SIGTERM")
        XCTAssertEqual(HostExitReason.parse(log(["doz host 1 (pid 5) — store /s", "idle for 5 min with nothing running — exiting", "host exiting"])), "idle")
        XCTAssertEqual(HostExitReason.parse(log(["doz host 1 (pid 5) — store /s", "my program changed (replaced) and nothing is running — exiting so …", "host exiting"])), "its program changed")
        // An earlier host's clean exit, then a host that never said it exited (kill -9): no reason.
        XCTAssertNil(HostExitReason.parse(log(["doz host 1 (pid 5) — store /s", "idle for 5 min with nothing running — exiting", "host exiting",
                                              "doz host 1 (pid 6) — store /s", "listening on /s/host.sock"])))
        // The reason is the last host's, not an earlier one's.
        XCTAssertEqual(HostExitReason.parse(log(["doz host 1 (pid 5) — store /s", "idle for 5 min with nothing running — exiting", "host exiting",
                                                 "doz host 1 (pid 6) — store /s", "signal 15: hibernating every sandbox, then exiting", "host exiting"])), "SIGTERM")
        XCTAssertNil(HostExitReason.parse(""))
    }

    // MARK: W20 — which side is older

    func testVersionsCompareAsSemverWithPreReleases() {
        let ordered = ["0.9.9", "0.10.0-alpha", "0.10.0-alpha.1", "0.10.0-alpha.beta", "0.10.0-beta.2", "0.10.0-beta.11",
                       "0.10.0-rc.1", "0.10.0", "0.12.0-rc.3", "0.12.0-rc.5", "0.12.0", "0.12.1", "1.0.0"]
        for (i, a) in ordered.enumerated() {
            for (j, b) in ordered.enumerated() {
                let want: ComparisonResult = i < j ? .orderedAscending : i > j ? .orderedDescending : .orderedSame
                XCTAssertEqual(WebVersion.compare(a, b), want, "\(a) vs \(b)")
            }
        }
        XCTAssertEqual(WebVersion.compare("0.12.0+abc", "0.12.0"), .orderedSame, "build metadata is ignored")
        for bad in ["", "0.12", "v0.12.0", "0.12.0-", "0.12.0-rc..1", "0.12.x", "dev"] {
            XCTAssertNil(WebVersion.compare(bad, "0.12.0"), bad)
        }
    }

    func testTheMismatchNoteAdvisesTheOlderSide() {
        // The owner's case: the UI is rc.5, the host still rc.3 → stop the HOST.
        let host = WebVersionNote.make(ui: "0.12.0-rc.5", host: "0.12.0-rc.3")
        XCTAssertEqual(host?.older, "host")
        XCTAssertEqual(host?.text, "The host is still 0.12.0-rc.3 — doz host stop (sandboxes hibernate) and the next action runs 0.12.0-rc.5.")
        // The UI older → restart doz ui.
        let ui = WebVersionNote.make(ui: "0.12.0-rc.5", host: "0.12.0")
        XCTAssertEqual(ui?.older, "ui")
        XCTAssertEqual(ui?.text, "doz ui is 0.12.0-rc.5, the host is 0.12.0 — restart doz ui (Ctrl-C it, then doz ui) so the page and the host are the same build.")
        XCTAssertNil(WebVersionNote.make(ui: "0.12.0", host: "0.12.0"))
        XCTAssertNil(WebVersionNote.make(ui: "0.12.0", host: nil))
        XCTAssertNil(WebVersionNote.make(ui: "0.12.0+a", host: "0.12.0+b"), "the same release")
        let odd = WebVersionNote.make(ui: "0.12.0", host: "dev")
        XCTAssertNil(odd?.older)
        XCTAssertEqual(odd?.text, "doz ui is 0.12.0, the host is dev — different builds.")
    }

    // MARK: the real probe, on a scratch store

    func testTheProbeNeverStartsAHostAndSeesAStalePID() throws {
        let dir = URL(fileURLWithPath: "/tmp/doz-hw-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        let store = DozerStore(root: dir)
        try store.ensureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = HostWebData(store: store, version: "test") { [] }
        XCTAssertEqual(data.hostProbe(), WebHostProbe(running: false))
        // A pid file naming no process: what a kill -9 leaves.
        var dead: Int32 = 99_999
        while kill(dead, 0) == 0 || errno != ESRCH { dead += 1 }
        try "\(dead)\n".write(to: store.pidFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(data.hostProbe()?.stalePID, true)
        // A pid file naming a live process (this one) is not stale.
        try "\(getpid())\n".write(to: store.pidFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(data.hostProbe()?.stalePID, false)
        XCTAssertFalse(store.hostIsRunning())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.socket.path), "looking never starts a host")
    }

    // MARK: W19 — sessions kept across a restart

    func testSessionsOutliveTheProcessAsDigestsForTheSamePortOnly() async throws {
        let dir = URL(fileURLWithPath: "/tmp/doz-hs-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("ui.sessions")
        let cap = try WebBootstrapCapability(testingValue: "test-capability-abcdefghijklmnopqrstuvwxyz")
        let first = WebSessionStore(bootstrap: cap, limits: .standard, persist: file, port: 50_001)
        let s = try await first.exchange(cap.value)
        var st = stat()
        XCTAssertEqual(stat(file.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600, "the store's own trust: 0600")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains(s.cookieValue), "never the cookie — its digest")
        XCTAssertTrue(text.contains(WebSessionStore.digest(s.cookieValue)))
        // The next UI on the same port: the page's cookie still signs it in, with the same CSRF token.
        let next = WebSessionStore(bootstrap: .make(), limits: .standard, persist: file, port: 50_001)
        let again = try await next.authenticate(s.cookieValue)
        XCTAssertEqual(again.csrfToken, s.csrfToken)
        _ = try await next.authenticateMutation(s.cookieValue, csrf: s.csrfToken)
        // …and the one-use link does not: links never outlive the process.
        do { _ = try await next.exchange(cap.value); XCTFail("a link from the last process") } catch {}
        // Another port: nothing carried over.
        let elsewhere = WebSessionStore(bootstrap: .make(), limits: .standard, persist: file, port: 50_002)
        do { _ = try await elsewhere.authenticate(s.cookieValue); XCTFail("another port") } catch {}
        // Rotation ends them all, and the file goes.
        await next.revokeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let after = WebSessionStore(bootstrap: .make(), limits: .standard, persist: file, port: 50_001)
        do { _ = try await after.authenticate(s.cookieValue); XCTFail("rotated") } catch {}
        // Expired sessions are not loaded.
        let clock = FixedClock()
        let old = WebSessionStore(bootstrap: cap, limits: .standard, now: { clock.now }, persist: file, port: 50_001)
        let o = try await old.exchange(cap.value)
        // 605: a session is remembered 14 days without use (was 12 h).
        clock.now = clock.now.addingTimeInterval(WebLimits.rememberedSession + 3600)
        let late = WebSessionStore(bootstrap: .make(), limits: .standard, now: { clock.now }, persist: file, port: 50_001)
        do { _ = try await late.authenticate(o.cookieValue); XCTFail("expired") } catch {}
    }

    final class FixedClock: @unchecked Sendable { var now = Date() }

    /// W19 end to end: a page's stream on a UI that stops and starts again on the same port reconnects
    /// with the same cookie; a rotation ends it with `rotated`.
    func testARestartedUIKeepsThePageSignedInAndARotationEndsIt() async throws {
        let dir = URL(fileURLWithPath: "/tmp/doz-hr-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        let store = DozerStore(root: dir)
        try store.ensureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeData()
        let cap = try WebBootstrapCapability(testingValue: "test-capability-abcdefghijklmnopqrstuvwxyz")
        let first = try await DozerWebServer.bind(data: fake, assets: try WebAssets.load(), version: "test", capability: cap,
                                                  sessionsFile: WebControl.sessionsFile(store))
        WebControl.rememberPort(store, first.origin.port)
        let t1 = Task { try await first.run() }
        let host = first.origin.authority
        let r = try RawHTTP.request(port: first.origin.port, method: "POST", path: "/api/v1/session",
                                    headers: ["Host": host, "Origin": first.origin.value, "Authorization": "Bearer \(cap.value)"], body: nil)
        XCTAssertEqual(r.status, 200)
        let cookie = String(try XCTUnwrap(r.header("set-cookie")).split(separator: ";")[0])
        await first.close()
        _ = try? await t1.value
        let second = try await DozerWebServer.bind(data: fake, assets: try WebAssets.load(), version: "test2",
                                                   address: WebControl.address(store), sessionsFile: WebControl.sessionsFile(store))
        XCTAssertEqual(second.origin.port, first.origin.port)
        let t2 = Task { try await second.run() }
        defer { t2.cancel() }
        XCTAssertEqual(try RawHTTP.request(port: second.origin.port, method: "GET", path: "/api/v1/session",
                                           headers: ["Host": host, "Cookie": cookie], body: nil).status, 200, "still signed in")
        let s = try RawStream(port: second.origin.port, path: "/api/v1/stream", headers: ["Host": host, "Cookie": cookie])
        defer { s.close() }
        _ = try s.read(until: "event: hello", seconds: 5)
        let reconnected = await second.waitForPage(seconds: 2)
        XCTAssertTrue(reconnected)
        second.tellPages("doz ui restarted — test2")
        XCTAssertTrue(try s.read(until: "doz ui restarted", seconds: 5).contains("event: notice"))
        _ = await second.rotate()
        XCTAssertTrue(try s.read(until: "rotated", seconds: 5).contains("event: end"))
        XCTAssertEqual(try RawHTTP.request(port: second.origin.port, method: "GET", path: "/api/v1/session",
                                           headers: ["Host": host, "Cookie": cookie], body: nil).status, 401, "rotated: signed out")
        await second.close()
    }

    // MARK: the port

    func testTheNextUIAsksForTheLastPortAndFallsBackWhenTaken() async throws {
        let dir = URL(fileURLWithPath: "/tmp/doz-hp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        let store = DozerStore(root: dir)
        try store.ensureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(WebControl.address(store).port, 0, "no port file: the OS picks")
        let fake = FakeData()
        let first = try await DozerWebServer.bind(data: fake, assets: try WebAssets.load(), version: "test", address: WebControl.address(store))
        let port = first.origin.port
        WebControl.rememberPort(store, port)
        var st = stat()
        XCTAssertEqual(stat(WebControl.portFile(store).path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        // While it listens, the port is taken: the next asks the OS.
        XCTAssertEqual(WebControl.address(store).port, 0)
        let t1 = Task { try await first.run() }
        await first.close()
        _ = try? await t1.value
        // Gone: the next UI gets the same port (and so the same origin).
        let address = WebControl.address(store)
        XCTAssertEqual(address.port, port)
        let second = try await DozerWebServer.bind(data: fake, assets: try WebAssets.load(), version: "test", address: address)
        XCTAssertEqual(second.origin.port, port)
        XCTAssertEqual(second.origin.authority, "127.0.0.1:\(port)")
        let t2 = Task { try await second.run() }
        await second.close()
        _ = try? await t2.value
        // Garbage or a privileged port in the file: the OS picks.
        try "80\n".write(to: WebControl.portFile(store), atomically: true, encoding: .utf8)
        XCTAssertEqual(WebControl.address(store).port, 0)
        try "not a port".write(to: WebControl.portFile(store), atomically: true, encoding: .utf8)
        XCTAssertEqual(WebControl.address(store).port, 0)
        XCTAssertNil(WebLoopbackAddress(reusing: 70_000))
    }
}
