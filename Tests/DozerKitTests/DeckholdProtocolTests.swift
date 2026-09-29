import XCTest
@testable import DozerKit

final class DeckholdFrameTests: XCTestCase {
    func test_helloAndResizeEncodeBigEndianSize() {
        XCTAssertEqual([UInt8](DeckholdFrame.hello(TermSize(cols: 300, rows: 40)).encoded),
                       [0x48, 0, 0, 0, 4, 0x01, 0x2C, 0, 40])
        XCTAssertEqual([UInt8](DeckholdFrame.resize(TermSize(cols: 80, rows: 24)).encoded),
                       [0x52, 0, 0, 0, 4, 0, 80, 0, 24])
    }

    func test_dataFrameCarriesPayloadVerbatim() {
        let payload = Data([0x6D, 0x03, 0xFF, 0x00])
        XCTAssertEqual(DeckholdFrame.data(payload).encoded, Data([0x44, 0, 0, 0, 4]) + payload)
    }

    func test_decoderHandlesSplitAndCoalescedFrames() throws {
        let wire = DeckholdFrame.snapshot(Data("\u{1B}[?1049l\u{1B}chello".utf8)).encoded
            + DeckholdFrame.output(Data("abc".utf8)).encoded
            + DeckholdFrame.exit(3).encoded
        var d = DeckholdFrameDecoder()
        var got: [DeckholdFrame] = []
        // One byte at a time: every split point.
        for b in wire { got += try d.feed(Data([b])) }
        XCTAssertEqual(got, [.snapshot(Data("\u{1B}[?1049l\u{1B}chello".utf8)), .output(Data("abc".utf8)), .exit(3)])
        XCTAssertEqual(d.pendingByteCount, 0)
        // All at once: coalesced.
        var d2 = DeckholdFrameDecoder()
        XCTAssertEqual(try d2.feed(wire), got)
    }

    func test_decoderExitCodeIsSigned32() throws {
        var d = DeckholdFrameDecoder()
        XCTAssertEqual(try d.feed(DeckholdFrame.exit(130).encoded), [.exit(130)])
        XCTAssertEqual(try d.feed(DeckholdFrame.exit(-1).encoded), [.exit(-1)])
    }

    func test_decoderNoSessionAndInfo() throws {
        var d = DeckholdFrameDecoder()
        XCTAssertEqual(try d.feed(Data([0x4E, 0, 0, 0, 0])), [.noSession])
        XCTAssertEqual(try d.feed(DeckholdFrame.info("x\ty").encoded), [.info("x\ty")])
    }

    func test_decoderRejectsOversizedAndUnknownFrames() {
        var d = DeckholdFrameDecoder()
        XCTAssertThrowsError(try d.feed(Data([0x44, 0x02, 0, 0, 0])))
        var d2 = DeckholdFrameDecoder()
        XCTAssertThrowsError(try d2.feed(Data([0x7A, 0, 0, 0, 0])))
    }
}

final class SessionInfoTests: XCTestCase {
    func test_parsesLiveEndedAndStaleLines() {
        let text = """
        deck\tpid=42\tsize=120x36\tclients=2\tscreen=alt\thistory=10\tbytes=12345\tbash /usr/local/bin/codeck-screensaver
        shell\tended=3
        ghost\t(stale socket)

        """
        let s = SessionInfo.parseList(text)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0], SessionInfo(name: "deck", pid: 42, size: TermSize(cols: 120, rows: 36), clients: 2, screen: "alt",
                                         historyRows: 10, bytesOut: 12345, command: "bash /usr/local/bin/codeck-screensaver"))
        XCTAssertEqual(s[1].name, "shell")
        XCTAssertEqual(s[1].exitCode, 3)
        XCTAssertTrue(s[1].isEnded)
        XCTAssertFalse(s[0].isEnded)
    }
}

final class GuestCommandTests: XCTestCase {
    /// 576 keytest: BusyBox `sh -c` leaks an ignored SIGQUIT into what it execs, so a session's
    /// program must be exec'd by deckhold directly — no shell anywhere in the argv chain.
    func test_sessionsStartWithoutAShell() {
        let argv = GuestCommand.serve(name: "deck", size: TermSize(cols: 120, rows: 36),
                                      argv: ["bash", "/usr/local/bin/codeck-screensaver"])
        XCTAssertEqual(argv, ["/usr/local/bin/deckhold", "serve", "-s", "deck", "-x", "120", "-y", "36", "--",
                              "bash", "/usr/local/bin/codeck-screensaver"])
        XCTAssertFalse(argv.contains("sh"))
        XCTAssertFalse(argv.contains("-c"))
    }

    func test_serveCarriesScrollbackWhenAsked() {
        XCTAssertEqual(GuestCommand.serve(name: "s", size: .standard, argv: ["bash", "-l"], scrollbackBytes: 1024),
                       ["/usr/local/bin/deckhold", "serve", "-s", "s", "-x", "80", "-y", "24", "--scrollback", "1024", "--", "bash", "-l"])
    }

    func test_pipeIsTheHostTransport() {
        XCTAssertEqual(GuestCommand.pipe(name: "deck"), ["/usr/local/bin/deckhold", "pipe", "-s", "deck"])
    }

    func test_sessionNameValidation() {
        for ok in ["deck", "shell-1", "a.b_c", "X"] { XCTAssertNoThrow(try GuestCommand.validateSessionName(ok), ok) }
        for bad in ["", ".hidden", "a b", "a/b", "é", String(repeating: "a", count: 65), "x;rm"] {
            XCTAssertThrowsError(try GuestCommand.validateSessionName(bad), bad)
        }
    }

    func test_environmentHasTermAndPathAndExtrasWin() {
        let env = GuestCommand.environment(["CODECK_COUNTDOWN": "0", "TERM": "dumb"])
        XCTAssertTrue(env.contains("CODECK_COUNTDOWN=0"))
        XCTAssertTrue(env.contains("TERM=dumb"))
        XCTAssertFalse(env.contains("TERM=xterm-256color"))
        XCTAssertTrue(env.contains { $0.hasPrefix("PATH=/usr/local/sbin") })
    }

    /// Wake re-mounts every share: a fresh virtio-fs mount (the previous one detached first, so a
    /// SECOND wake works too), a root listing that refreshes changed node ids BEFORE any bind,
    /// then a re-bind and a listing of each share.
    func test_remountRefreshesBeforeRebindingEveryShare() {
        let s = GuestCommand.remountShares([(tag: "abc123", guestPath: "/work"), (tag: "def456", guestPath: "/data")])
        XCTAssertTrue(s.contains("mount --bind '/run/dozer-vfs/abc123' '/work'"))
        XCTAssertTrue(s.contains("mount --bind '/run/dozer-vfs/def456' '/data'"))
        let detachFresh = s.range(of: "umount -l /run/dozer-vfs")!.lowerBound
        let mountFresh = s.range(of: "mount -t virtiofs virtiofs /run/dozer-vfs")!.lowerBound
        let list = s.range(of: "ls -a /run/dozer-vfs")!.lowerBound
        XCTAssertLessThan(detachFresh, mountFresh)
        XCTAssertLessThan(mountFresh, list)
        XCTAssertLessThan(list, s.range(of: "mount --bind")!.lowerBound, "the refreshing listing precedes every bind")
        XCTAssertTrue(s.contains("ls -a '/work' >/dev/null"), "each share is verified")
        XCTAssertTrue(s.hasPrefix("set -e;"), "a failure is loud")
    }
}
