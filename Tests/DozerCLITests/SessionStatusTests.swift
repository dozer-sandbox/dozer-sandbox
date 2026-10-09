import Foundation
import DozerKit
import XCTest
@testable import DozerHost

/// 612: the agents' status in the host — the model, its words, the summary, deduplicated events, the fields of
/// `ls` and `sessions`, and the program's text kept out of every log line.
final class SessionStatusTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-status-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func status(_ session: String, _ state: ProgramStatus.State, kind: ProgramStatus.Kind? = nil, message: String? = nil,
                        at: TimeInterval = 0) -> SessionStatus {
        SessionStatus(session: session, state: state, app: "claude-code", kind: kind, message: message, updatedAt: Date(timeIntervalSince1970: at))
    }

    func testTheWords() {
        XCTAssertEqual(SessionStatus.label(.blocked, kind: .permission), "blocked: needs permission")
        XCTAssertEqual(SessionStatus.label(.blocked, kind: .question), "blocked: has a question")
        XCTAssertEqual(SessionStatus.label(.blocked, kind: .auth), "blocked: needs sign-in")
        XCTAssertEqual(SessionStatus.label(.blocked), "blocked")
        XCTAssertEqual(SessionStatus.label(.working, progress: 40), "working 40%")
        XCTAssertEqual(SessionStatus.label(.working), "working")
        XCTAssertEqual(SessionStatus.label(.done), "done")
        XCTAssertEqual(SessionStatus.label(.error), "error")
        XCTAssertEqual(SessionStatus.label(.idle), "idle")
    }

    func testTheMostUrgentIsShown() {
        XCTAssertNil(SessionStatus.mostUrgent([]))
        let all = [status("a", .done, at: 9), status("b", .working, at: 1), status("c", .idle, at: 10)]
        XCTAssertEqual(SessionStatus.mostUrgent(all)?.session, "b")
        XCTAssertEqual(SessionStatus.mostUrgent(all + [status("d", .error, at: 0)])?.session, "d")
        XCTAssertEqual(SessionStatus.mostUrgent(all + [status("d", .error), status("e", .blocked, kind: .question)])?.session, "e")
        XCTAssertEqual(SessionStatus.mostUrgent([status("x", .done, at: 1), status("y", .done, at: 5)])?.session, "y", "the newest of equals")
    }

    func testTheAgeBecomesATime() {
        let now = Date(timeIntervalSince1970: 1000)
        let s = SessionStatus(session: "main", ProgramStatus(state: .done, ageSeconds: 30), now: now)
        XCTAssertEqual(s.updatedAt, Date(timeIntervalSince1970: 970))
    }

    func testTheProgramsTextIsNeverInALogLine() {
        let s = status("main", .blocked, kind: .permission, message: "rm -rf /secret-plan")
        var e = HostEvent(kind: .sessionStatus, sandbox: "box", text: s.logLine)
        e.session = "main"
        e.sessionStatus = s
        XCTAssertEqual(e.line, "box: session main: blocked: needs permission (claude-code)")
        XCTAssertFalse(e.line.contains("secret"))
    }

    func testChangesAreToldOnceAndKept() async throws {
        let core = HostCore(store: DozerStore(root: root), readOnly: true, version: "t")
        let events = core.subscribe()
        let collected = Task { () -> [HostEvent] in
            var out: [HostEvent] = []
            for await e in events where e.kind == .sessionStatus {
                out.append(e)
                if out.count == 4 { break }
            }
            return out
        }
        await core.setStatus("box", session: "main", status("main", .working, at: 1))
        await core.setStatus("box", session: "main", status("main", .working, at: 50))      // the same report, later: no event
        await core.setStatus("box", session: "main", status("main", .blocked, kind: .permission, at: 60))
        await core.setStatus("box", session: "other", status("other", .done, at: 61))
        await core.setStatus("box", session: "main", nil)
        await core.setStatus("box", session: "main", nil)                                    // nothing to clear: no event
        let seen = await collected.value
        XCTAssertEqual(seen.map { $0.sessionStatus?.state }, [.working, .blocked, .done, nil])
        XCTAssertEqual(seen.map(\.session), ["main", "main", "other", "main"])
        var info = SandboxInfo(name: "box", image: "lab", phase: "running", busy: false, cpus: 1, memoryMiB: 512, ramHeldMiB: 0,
                               memoryReturnedMiB: 0, diskBytes: 0, sessions: nil, network: "nat", deniedConnections: nil,
                               workspace: nil, createdAt: nil, diedWithHost: nil)
        await core.statusFields("box", into: &info)
        XCTAssertEqual(info.sessionStatuses?.map(\.session), ["other"])
        XCTAssertEqual(info.agentStatus?.state, .done)
        XCTAssertEqual(info.agentWorking, false)
        await core.setStatus("box", session: "main", status("main", .working, at: 70))
        await core.statusFields("box", into: &info)
        XCTAssertEqual(info.agentWorking, true, "the signal an idle sleep must respect")
        XCTAssertEqual(info.agentStatus?.state, .working)
        await core.clearStatuses("box")
        var none = info
        none.sessionStatuses = nil; none.agentStatus = nil; none.agentWorking = nil
        await core.statusFields("box", into: &none)
        XCTAssertNil(none.agentStatus, "a stopped sandbox's programs said nothing")
    }

    func testSessionRowsTakeTheGuestsWordForLiveSessionsAndTheHostsForTheRest() async {
        let core = HostCore(store: DozerStore(root: root), readOnly: true, version: "t")
        await core.setStatus("box", session: "gone", status("gone", .done, at: 5))
        await core.setStatus("box", session: "main", status("main", .working, at: 5))
        let live = SessionInfo.parseList("main\tpid=1\tsize=80x24\tclients=0\tscreen=primary\thistory=0\tbytes=0\tstatus=state=working:app=claude-code\tstatus_age=3\tclaude\n"
                                         + "fresh\tpid=2\tsize=80x24\tclients=0\tscreen=primary\thistory=0\tbytes=0\tbash\n"
                                         + "gone\tended=0\n")
        let rows = await core.withStatuses("box", live.map(SessionRow.init), live: live)
        let by = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        XCTAssertEqual(by["main"]?.status?.updatedAt, Date(timeIntervalSince1970: 5), "the same report keeps the host's time")
        XCTAssertNil(by["fresh"]?.status)
        XCTAssertEqual(by["gone"]?.status?.state, .done, "done survives the program")
    }

    func testTheFieldsRoundTripAndAreOnlyAdded() throws {
        var info = SandboxInfo(name: "box", image: "lab", phase: "running", busy: false, cpus: 1, memoryMiB: 512, ramHeldMiB: 0,
                               memoryReturnedMiB: 0, diskBytes: 0, sessions: nil, network: "nat", deniedConnections: nil,
                               workspace: nil, createdAt: nil, diedWithHost: nil)
        let plain = try HostWire.encoder.encode(info)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("agent"), "nothing reported: no field")
        info.sessionStatuses = [status("main", .blocked, kind: .auth, message: "Sign in")]
        info.agentStatus = info.sessionStatuses?.first
        info.agentWorking = false
        let back = try HostWire.decoder.decode(SandboxInfo.self, from: HostWire.encoder.encode(info))
        XCTAssertEqual(back, info)
        // An event a client did not ask for never reaches it: the kind is new.
        XCTAssertEqual(HostEvent.Kind.sessionStatus.rawValue, "session-status")
        var r = HostRequest(.events)
        XCTAssertNil(r.sessionStatus)
        r.sessionStatus = true
        XCTAssertEqual(try HostWire.decoder.decode(HostRequest.self, from: HostWire.encoder.encode(r)).sessionStatus, true)
    }

    func testTheBridgesPassOSC7501ThroughUntouched() {
        let seq = Array("\u{1b}]7501;state=working:app=claude-code\u{1b}\\x\u{1b}]7501;?\u{07}".utf8)
        for cut in 0...seq.count {
            var s = SessionBridgeScanner()
            let (a, ea) = s.feed(Data(seq[..<cut]))
            let (b, eb) = s.feed(Data(seq[cut...]))
            XCTAssertEqual(a + b, seq, "cut at \(cut)")
            XCTAssertTrue(ea.isEmpty && eb.isEmpty)
        }
    }
}
