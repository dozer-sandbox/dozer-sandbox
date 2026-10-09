import XCTest
@testable import DozerKit

/// 612: the program's status (OSC 7501) as deckhold hands it to the host — INFO fields, STATUS frames, a watcher.
final class ProgramStatusTests: XCTestCase {
    private func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    func test_theFieldsDecode() {
        let p = ProgramStatus(fields: ["status": "state=blocked:app=claude-code:kind=permission:progress=40:msg=\(b64("Run tests?")):title=\(b64("Bash"))",
                                       "status_age": "12"])
        XCTAssertEqual(p, ProgramStatus(state: .blocked, app: "claude-code", kind: .permission, progress: 40, message: "Run tests?",
                                        title: "Bash", ageSeconds: 12))
    }

    func test_noRecordOrAnUnknownStateIsNone() {
        XCTAssertNil(ProgramStatus(fields: [:]))
        XCTAssertNil(ProgramStatus(fields: ["status": ""]))
        XCTAssertNil(ProgramStatus(fields: ["status": "state=napping"]))
        XCTAssertNil(ProgramStatus.parse(frame: ""))
    }

    func test_whatDoesNotFitIsDroppedNotTrusted() {
        let p = ProgramStatus(fields: ["status": "state=working:app=bad name:kind=permission:progress=250:msg=YQ:title=%%%"])
        XCTAssertEqual(p?.state, .working)
        XCTAssertNil(p?.app, "outside [A-Za-z0-9_.+-]")
        XCTAssertNil(p?.kind, "kind is for blocked only")
        XCTAssertNil(p?.progress, "0–100 only")
        XCTAssertEqual(p?.message, "a", "unpadded base64 is read")
        XCTAssertNil(p?.title, "not base64")
        // Control characters never reach a screen (deckhold refuses them already; this is the second line).
        let q = ProgramStatus(fields: ["status": "state=error:msg=\(b64("line one\u{1b}[31m\nline\u{85}two"))"])
        XCTAssertEqual(q?.message, "line one[31mlinetwo")
        // Over the spec's size: none.
        XCTAssertNil(ProgramStatus(fields: ["status": "state=done:msg=\(b64(String(repeating: "x", count: 2049)))"])?.message)
        XCTAssertNil(ProgramStatus(fields: ["status": "state=done:title=\(b64(String(repeating: "x", count: 193)))"])?.title)
    }

    func test_urgencyOrder() {
        let order = ProgramStatus.State.allCases.sorted { $0.urgency > $1.urgency }
        XCTAssertEqual(order, [.blocked, .error, .working, .done, .idle])
        XCTAssertTrue(ProgramStatus.State.working.endsWithProgram)
        XCTAssertTrue(ProgramStatus.State.blocked.endsWithProgram)
        XCTAssertFalse(ProgramStatus.State.done.endsWithProgram)
        XCTAssertFalse(ProgramStatus.State.error.endsWithProgram)
    }

    func test_lsCarriesTheStatusBeforeTheCommand() {
        let text = "main\tpid=7\tsize=120x36\tclients=0\tscreen=alt\thistory=3\tbytes=99\tstatus=state=working:app=pi:msg=\(b64("refactor"))\tstatus_age=4\tpi --continue\n"
            + "old\tpid=8\tsize=80x24\tclients=1\tscreen=primary\thistory=0\tbytes=1\tbash -l\n"
            + "gone\tended=0\n"
        let list = SessionInfo.parseList(text)
        XCTAssertEqual(list.map(\.name), ["gone", "main", "old"])
        let main = list[1]
        XCTAssertEqual(main.command, "pi --continue", "the command is still the last field")
        XCTAssertEqual(main.status, ProgramStatus(state: .working, app: "pi", message: "refactor", ageSeconds: 4))
        XCTAssertNil(list[2].status, "an older holder's line (no status) parses as before")
        XCTAssertEqual(list[2].command, "bash -l")
        XCTAssertNil(list[0].status)
    }

    func test_theFramesRoundTrip() throws {
        var d = DeckholdFrameDecoder()
        let wire = DeckholdFrame.status("status=state=done\tstatus_age=0").encoded + DeckholdFrame.status("").encoded
        XCTAssertEqual(try d.feed(wire.prefix(3)), [])
        XCTAssertEqual(try d.feed(wire.dropFirst(3)), [.status("status=state=done\tstatus_age=0"), .status("")])
        XCTAssertEqual(DeckholdFrame.watch.encoded, Data([UInt8(ascii: "W"), 0, 0, 0, 0]))
    }

    func test_aWatcherSendsWatchAndHearsOnlyStatus() async {
        let c = SessionConnection(statusOf: "main")
        XCTAssertTrue(c.isStatusWatch)
        XCTAssertFalse(c.sawStatus)
        let wire = DeckholdFrame.status("").encoded + DeckholdFrame.status("status=state=working:app=claude-code\tstatus_age=0").encoded
            + DeckholdFrame.exit(0).encoded
        for b in wire { c.receive(Data([b])) }          // cut at every byte
        var out: [SessionOutput] = []
        for await o in c.output { out.append(o) }
        XCTAssertEqual(out, [.status(nil), .status(ProgramStatus(state: .working, app: "claude-code", ageSeconds: 0)), .ended(exitCode: 0)])
        XCTAssertTrue(c.sawStatus)
        var first: Data?
        for await f in c.input { first = first ?? f }
        XCTAssertEqual(first, DeckholdFrame.watch.encoded, "WATCH, never HELLO: no size, not a viewer")
    }

    func test_aHolderThatDropsTheWatchIsTold() async {
        // An older deckhold drops the client that sent WATCH: the pipe ends with no STATUS frame.
        let c = SessionConnection(statusOf: "main")
        c.detach(.transportLost)
        XCTAssertFalse(c.sawStatus)
        XCTAssertEqual(c.finalOutput, .detached(.transportLost))
    }
}
