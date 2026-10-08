import Darwin
import Foundation
import XCTest
@testable import DozerKit

/// 593 §9: the sessions' saved screens are files in the sandbox's directory — written, listed, marked
/// ended, pruned and deleted without a VM. (The capture itself is `make test-cli`'s.)
final class SavedScreensTests: XCTestCase {
    private var dir: URL!
    private var spec: SandboxSpec!
    private var layout: StoreLayout!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-scr-\(UUID().uuidString.prefix(8))")
        spec = SandboxSpec(name: "lab", storeRoot: dir)
        layout = StoreLayout(spec: spec)
        try FileManager.default.createDirectory(at: layout.sandboxDirectory, withIntermediateDirectories: true)
        try Data("root".utf8).write(to: layout.rootfs)
        try PersistedSandbox(spec: spec, phase: .off, machineIdentifier: Data([1]), macAddress: nil, subnet: nil, shareTags: [:])
            .write(to: layout.persistedState)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func save(_ session: String, vt: String = "\u{1B}c\u{1B}[1mhi\u{1B}[0m\r\n", text: String = "hi", reason: String = "sleep",
                      bytes: UInt64 = 10) throws {
        try SavedScreens.write(layout, info: SavedScreenInfo(session: session, savedAt: Date(), reason: reason, cols: 80, rows: 24,
                                                             screen: "primary", command: "bash -l", pid: 7, bytesOut: bytes),
                               vt: Data(vt.utf8), text: text)
    }

    private func mode(_ url: URL) -> mode_t {
        var st = stat()
        XCTAssertEqual(stat(url.path, &st), 0, url.path)
        return st.st_mode & 0o777
    }

    func test_writeReadListAndPrivateModes() throws {
        try save("shell")
        try save("worker", text: "line 1\nline 2")
        XCTAssertEqual(SavedScreens.list(layout).map(\.session), ["shell", "worker"])
        let s = try XCTUnwrap(SavedScreens.read(layout, session: "worker"))
        XCTAssertEqual(s.text, "line 1\nline 2")
        XCTAssertEqual(String(decoding: s.vt, as: UTF8.self), "\u{1B}c\u{1B}[1mhi\u{1B}[0m\r\n")
        XCTAssertEqual(s.info.reason, "sleep")
        XCTAssertEqual(s.info.cols, 80)
        XCTAssertEqual(s.info.vtBytes, s.vt.count)
        XCTAssertEqual(mode(layout.screensDirectory), 0o700, "the directory is the user's own")
        for ext in ["vt", "txt", "json"] {
            XCTAssertEqual(mode(layout.screensDirectory.appendingPathComponent("worker.\(ext)")), 0o600, ext)
        }
        XCTAssertNil(SavedScreens.read(layout, session: "nope"))
        XCTAssertNil(SavedScreens.read(layout, session: "../doz"), "only a session name reads a file")
        XCTAssertThrowsError(try save("../escape"))
        XCTAssertThrowsError(try save(".hidden"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: layout.screensDirectory.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [], "atomic writes leave no temporary file")
    }

    func test_aScreenIsNeverWrittenForARemovedSandbox() throws {
        try FileManager.default.removeItem(at: layout.sandboxDirectory)
        XCTAssertThrowsError(try save("shell"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.sandboxDirectory.path), "the sandbox's directory is not re-created")
    }

    /// Owner, 2026-09-30: there is no "ended" screen — a saved screen is a LIVE session's. A record an
    /// earlier 593 build wrote (with `ended`/`exitCode`) still reads; what is written has no such field.
    func test_noEndedScreens() throws {
        try save("shell")
        let json = try String(contentsOf: layout.screensDirectory.appendingPathComponent("shell.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("ended") || json.contains("exitCode"), json)
        let old = #"{"session":"old","savedAt":"2026-09-29T10:00:00.000Z","reason":"shutdown","phase":"running","command":"sh","bytesOut":1,"ended":true,"exitCode":3,"vtBytes":0,"truncated":false}"#
        try Data(old.utf8).write(to: layout.screensDirectory.appendingPathComponent("old.json"))
        XCTAssertEqual(SavedScreens.list(layout).map(\.session), ["old", "shell"], "an older record reads")
    }

    func test_pruneKeepsTheGuestsSessionsAndRemoveAllDeletesTheDirectory() throws {
        try save("a"); try save("b"); try save("c")
        XCTAssertEqual(SavedScreens.remove(layout, keeping: ["b", "z"]).sorted(), ["a", "c"])
        XCTAssertEqual(SavedScreens.list(layout).map(\.session), ["b"])
        XCTAssertEqual(SavedScreens.remove(layout), ["b"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.screensDirectory.path))
    }

    func test_anOversizedSnapshotKeepsItsNewestLines() {
        let lines = (0..<2000).map { "row \($0) " + String(repeating: "x", count: 40) }.joined(separator: "\r\n") + "\r\n\u{1B}[H active"
        let (capped, truncated) = SavedScreens.cappedVT(Data(lines.utf8), limit: 4096)
        XCTAssertTrue(truncated)
        XCTAssertLessThanOrEqual(capped.count, 4096)
        let s = String(decoding: capped, as: UTF8.self)
        XCTAssertTrue(s.hasPrefix("\u{1B}[!p\u{1B}[0mrow "), "a soft reset, then a WHOLE line: \(s.prefix(20).debugDescription)")
        XCTAssertTrue(s.hasSuffix("\u{1B}[H active"), "the active area (drawn last) is kept whole")
        let (same, no) = SavedScreens.cappedVT(Data("small".utf8), limit: 4096)
        XCTAssertEqual(same, Data("small".utf8))
        XCTAssertFalse(no)
    }

    func test_theDumpIsParsedAndItsTextMadeInert() {
        let d = SavedScreens.parseDump("$ ls\u{1B}]52;c;ZXZpbA==\u{07}\u{1B}[31m\tred\u{7F}\u{9B}  \nok   \n\ncursor=3,1 size=120x36 screen=alt")
        XCTAssertEqual(d.text, "$ ls red\nok", "OSC, CSI, DEL and C1 go; a tab is a space; trailing blanks trimmed")
        XCTAssertEqual(d.cols, 120)
        XCTAssertEqual(d.rows, 36)
        XCTAssertEqual(d.screen, "alt")
        let plain = SavedScreens.parseDump("no cursor line")
        XCTAssertEqual(plain.text, "no cursor line")
        XCTAssertNil(plain.cols)
    }

    func test_theCaptureRequestIsHelloKeepingTheSizeThenDump() {
        XCTAssertEqual([UInt8](DeckholdFrame.captureRequest), [UInt8(ascii: "H"), 0, 0, 0, 4, 0, 0, 0, 0, UInt8(ascii: "P"), 0, 0, 0, 0],
                       "HELLO 0×0 (the session keeps its size; nothing typed), then DUMP")
    }

    /// S6: Reset deletes the saved screens (with the disk); Delete removes the sandbox's directory.
    func test_resetAndDeleteRemoveTheSavedScreens() async throws {
        try save("shell")
        let sb = try Sandbox(spec: spec)
        try await sb.resetToImage()
        XCTAssertEqual(SavedScreens.list(layout), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.screensDirectory.path))
        try save("shell")
        try await sb.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.screensDirectory.path))
    }

    /// Duplicate, fork and a template copy disks by name — never the saved screens.
    func test_duplicateForkAndTemplatesNeverCopyTheScreens() async throws {
        try save("shell")
        let sb = try Sandbox(spec: spec)
        var dupSpec = spec!
        dupSpec.name = "dup"
        try sb.duplicate(from: nil, as: dupSpec, copyState: true)
        XCTAssertEqual(SavedScreens.list(StoreLayout(spec: dupSpec)), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: StoreLayout(spec: dupSpec).screensDirectory.path))
        let rp = try await sb.takeRestorePoint(name: "p")
        let forked = try sb.fork(rp.id, as: "forked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: StoreLayout(spec: forked).screensDirectory.path))
        let pointFiles = try FileManager.default.contentsOfDirectory(atPath: layout.restorePointDirectory(rp.id).path)
        XCTAssertFalse(pointFiles.contains { $0.hasPrefix("screens") }, "a restore point holds disks only (\(pointFiles))")
        let img = try sb.saveAsImage(nil, name: "tpl")
        let files = try FileManager.default.contentsOfDirectory(atPath: layout.customImageDirectory(img.key).path).sorted()
        XCTAssertEqual(files, ["image.json", "root.ext4"])
    }
}
