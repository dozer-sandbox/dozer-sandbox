import Darwin
import Foundation
import DozerKit
import DozerHost
import XCTest
@testable import DozerWeb

/// A UI that holds the store's lock but never answers its control socket (owner, 2026-10-09: a `doz ui` stopped with
/// Ctrl-Z the day before made every later `doz ui` wait forever) — the client gives up after a few seconds and says
/// who holds the store.
final class WebControlUnresponsiveTests: XCTestCase {
    private func scratchStore() -> (DozerStore, URL) {
        let dir = URL(fileURLWithPath: "/tmp/doz-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        return (DozerStore(root: dir), dir)
    }

    func testASilentUIIsGivenUpOnAndNamed() throws {
        let (store, dir) = scratchStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = try XCTUnwrap(try WebControl.takeLock(store))
        defer { close(lock) }
        // Listening — so a connect succeeds — but nobody ever accepts or answers: what a suspended UI looks like.
        let listener = try UnixSocket.listen(WebControl.socket(store).path)
        defer { close(listener) }

        let started = Date()
        XCTAssertNil(WebControl.requestStatus(store), "no answer is no status")
        let waited = Date().timeIntervalSince(started)
        XCTAssertLessThan(waited, Double(WebControl.answerTimeoutSeconds) + 2, "never waits forever")

        let note = try XCTUnwrap(WebControl.holderNote(store), "the lock is held, so the holder is named")
        XCTAssertTrue(note.contains("pid \(getpid())"), note)
        XCTAssertTrue(note.contains("not answering"), note)
    }

    func testNoHolderMeansNoNote() throws {
        let (store, dir) = scratchStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(WebControl.holderNote(store), "no lock file")
        let lock = try XCTUnwrap(try WebControl.takeLock(store))
        close(lock)
        XCTAssertNil(WebControl.holderNote(store), "a lock file nobody holds: no doz ui is running")
    }

    func testAStoppedProcessIsSeenAsStopped() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        defer { kill(p.processIdentifier, SIGCONT); p.terminate(); p.waitUntilExit() }
        XCTAssertFalse(WebControl.processIsStopped(p.processIdentifier))
        kill(p.processIdentifier, SIGSTOP)
        var stopped = false
        for _ in 0..<50 where !stopped {
            stopped = WebControl.processIsStopped(p.processIdentifier)
            if !stopped { usleep(20_000) }
        }
        XCTAssertTrue(stopped)
    }
}
