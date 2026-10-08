import Darwin
import Foundation
import DozerKit
import XCTest
@testable import DozerHost

/// 593 (owner, 2026-09-30): the boot log — each boot's events and console, the last N kept — without a VM.
final class BootLogsTests: XCTestCase {
    private var root: URL!
    private var store: DozerStore!
    private var layout: StoreLayout!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-boot-\(UUID().uuidString.prefix(8))")
        store = DozerStore(root: root)
        let (s, n) = try DozerImages.spec(name: "x", options: CreateOptions(image: "lab"), store: store, environment: [:])
        try FileManager.default.createDirectory(at: store.layout("x").sandboxDirectory, withIntermediateDirectories: true)
        try SandboxConfig(name: "x", image: n, spec: s, workspace: nil).write(store.configFile("x"))
        layout = store.layout("x")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func mode(_ url: URL) -> mode_t {
        var st = stat()
        return stat(url.path, &st) == 0 ? st.st_mode & 0o777 : 0
    }

    private func boot(_ i: Int, kind: String = "cold boot", failed: Bool = false, keep: Int = 5) throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000 + Double(i))
        let info = BootLogInfo(id: BootLogs.newID(t), kind: kind, startedAt: t, milliseconds: 400, result: failed ? "failed" : "ok",
                               error: failed ? "the kernel said no" : nil, events: 2, consoleBytes: 10)
        let events = [HostEvent(kind: .started, sandbox: "x", text: "booting the VM \(i)", time: t),
                      HostEvent(kind: .step, sandbox: "x", text: "booting the VM \(i)", milliseconds: 250, time: t.addingTimeInterval(0.25))]
        try BootLogs.write(layout, info: info, events: events, console: Data("[ 0.1] boot \(i)\r\n[ 0.2] \u{1B}[31mred\u{1B}]52;c;x\u{07}\n".utf8), keep: keep)
    }

    func test_theNewestAreKeptAndNumberedFromTheLatest() throws {
        for i in 1...7 { try boot(i, kind: i % 2 == 0 ? "wake" : "cold boot") }
        let l = BootLogs.list(layout)
        XCTAssertEqual(l.count, 5, "the last 5")
        XCTAssertEqual(l.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(l.first?.startedAt, Date(timeIntervalSince1970: 1_800_000_007), "1 = the latest")
        XCTAssertEqual(l.last?.startedAt, Date(timeIntervalSince1970: 1_800_000_003))
        XCTAssertEqual(l.first?.kind, "cold boot")
        XCTAssertEqual(l[1].kind, "wake")
        try boot(8, keep: 2)
        XCTAssertEqual(BootLogs.list(layout).count, 2, "a smaller setting prunes at the next boot")
        let dirs = try FileManager.default.contentsOfDirectory(atPath: BootLogs.directory(layout).path)
        XCTAssertEqual(dirs.filter { $0.hasPrefix(".") }, [], "no temporary directory left")
    }

    func test_theRecordIsPrivateAndReadsBack() throws {
        try boot(1)
        try boot(2, failed: true)
        let dir = BootLogs.directory(layout)
        XCTAssertEqual(mode(dir), 0o700)
        let one = dir.appendingPathComponent(BootLogs.list(layout)[0].id)
        XCTAssertEqual(mode(one), 0o700)
        for f in ["boot.json", "events.jsonl", "console.log"] { XCTAssertEqual(mode(one.appendingPathComponent(f)), 0o600, f) }
        let r = try XCTUnwrap(BootLogs.read(layout, name: "x", number: 1))
        XCTAssertEqual(r.info.result, "failed")
        XCTAssertEqual(r.info.error, "the kernel said no")
        XCTAssertEqual(r.events.map(\.kind), [.started, .step])
        XCTAssertEqual(r.console.count, 2)
        XCTAssertEqual(r.console[0], "[ 0.1] boot 2", "CRLF console lines read as lines")
        XCTAssertNil(BootLogs.read(layout, name: "x", number: 3))
        XCTAssertNil(BootLogs.read(layout, name: "x", number: 0))
    }

    /// The boot view's own renderer: ✓ / ✗ steps with their times, then the console with no escape left.
    func test_itRendersAsTheBootViewDrewIt() throws {
        try boot(1)
        try boot(2, failed: true)
        let ok = try XCTUnwrap(BootLogs.read(layout, name: "x", number: 2))
        let text = BootLogs.render(ok, mode: .animated, color: false)
        XCTAssertTrue(text.contains("── cold boot of x"), text)
        XCTAssertTrue(text.contains("✓ booting the VM 1 — 250 ms"), text)
        XCTAssertTrue(text.contains("✓ booted in 400 ms"), text)
        XCTAssertTrue(text.contains("── kernel console (2 lines) ──\r\n[ 0.1] boot 1\r\n"), text)
        XCTAssertTrue(text.contains("[ 0.2] [31mred]52;c;x"), "the console's escapes are made inert: \(text.debugDescription)")
        XCTAssertFalse(text.contains("\u{1B}"), "no colour asked for, none given — and no guest escape")
        let failed = BootLogs.render(try XCTUnwrap(BootLogs.read(layout, name: "x", number: 1)), mode: .plain, color: false)
        XCTAssertTrue(failed.contains("✗ failed in 400 ms — the kernel said no"), failed)
        XCTAssertTrue(failed.contains("[doz] booting the VM 2 — 250 ms"), "plain lines, like the CLI's: \(failed)")
        let consoleOnly = BootLogs.render(ok, color: false, steps: false)
        XCTAssertEqual(consoleOnly, "[ 0.1] boot 1\r\n[ 0.2] [31mred]52;c;x\r\n")
    }

    func test_theRecorderTakesTheBootsEventsAndItsPartOfTheConsole() throws {
        let log = layout.bootLog
        try Data("old boot line\n".utf8).write(to: log)
        let wake = BootRecorder(kind: "wake", bootLog: log)
        let cold = BootRecorder(kind: "cold boot", bootLog: log)
        try Data("old boot line\nwoke\n".utf8).write(to: log)
        XCTAssertEqual(String(decoding: wake.console(log), as: UTF8.self), "woke\n", "a wake: what was written since it began")
        XCTAssertEqual(String(decoding: cold.console(log), as: UTF8.self), "old boot line\nwoke\n", "a cold boot: the file it started afresh")
        try Data("new\n".utf8).write(to: log)
        XCTAssertEqual(String(decoding: wake.console(log), as: UTF8.self), "new\n", "a file shorter than the offset was started afresh")
        wake.record(HostEvent(kind: .step, sandbox: "x", text: "a"))
        wake.record(HostEvent(kind: .console, sandbox: "x", text: "c"))
        wake.record(HostEvent(kind: .connection, sandbox: "x"))
        XCTAssertEqual(wake.snapshot.map(\.kind), [.step], "only what a boot view draws")
    }

    func test_itIsNeverWrittenIntoARemovedSandbox() throws {
        try FileManager.default.removeItem(at: layout.sandboxDirectory)
        try boot(1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.sandboxDirectory.path))
    }

    /// `boot-log` is a read, answered in-process (looking never starts a host).
    func test_theBootLogOpIsARead() async throws {
        for i in 1...3 { try boot(i) }
        let core = HostCore(store: store, readOnly: true, version: "test")
        await core.load()
        var r = HostRequest(.bootLog, name: "x")
        r.list = true
        let listed = await core.handle(r)
        let l = try XCTUnwrap(listed.result).decode(BootLogList.self)
        XCTAssertEqual(l.boots.map(\.number), [1, 2, 3])
        r.list = nil
        r.boot = 2
        let got = await core.handle(r)
        let rec = try XCTUnwrap(got.result).decode(BootLogRecord.self)
        XCTAssertEqual(rec.info.number, 2)
        XCTAssertEqual(rec.console.first, "[ 0.1] boot 2")
        r.boot = 9
        let missing = await core.handle(r)
        XCTAssertEqual(missing.error?.code, .notFound)
        XCTAssertTrue(HostOp.bootLog.isReadOnly)
        XCTAssertEqual(DozerSettings.definition(SettingKey.bootLogsKept)?.defaultValue, .int(5))
    }
}
