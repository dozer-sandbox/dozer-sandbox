import Foundation
import DozerKit
import XCTest
@testable import DozerHost

/// 591 — a host notices when the program it runs from changes under it.
final class ExecutableIdentityTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("exe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// A signed program to play the host's executable (a copy of a system tool).
    func program(_ name: String, from source: String = "/usr/bin/true") throws -> URL {
        let u = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: u)
        return u
    }

    func testTheIdentityIsTheFileAndItsSignature() throws {
        let p = try program("doz")
        let id = try XCTUnwrap(ExecutableIdentity.of(path: p.path))
        XCTAssertEqual(id.path, p.path)
        XCTAssertGreaterThan(id.inode, 0)
        XCTAssertGreaterThan(id.size, 0)
        XCTAssertEqual(id.cdhash?.count, 40, "a signed file has a cdhash (sha-1 or truncated sha-256: 20 bytes)")
        XCTAssertNil(id.change(now: ExecutableIdentity.of(path: p.path)), "unchanged")
        XCTAssertNil(ExecutableIdentity.of(path: dir.appendingPathComponent("none").path))
    }

    func testAnUpdateByRenameIsReplacedAndHarmless() throws {
        let p = try program("doz")
        let id = try XCTUnwrap(ExecutableIdentity.of(path: p.path))
        let new = try program(".doz.new", from: "/usr/bin/false")
        _ = try FileManager.default.replaceItemAt(p, withItemAt: new)          // rename over: a new inode
        XCTAssertEqual(id.change(now: ExecutableIdentity.of(path: p.path)), .replaced)
    }

    func testAnUpdateWrittenIntoTheFileIsOverwritten() throws {
        let p = try program("doz")
        let id = try XCTUnwrap(ExecutableIdentity.of(path: p.path))
        let other = try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/false"))
        let h = try FileHandle(forWritingTo: p)                                // same inode, new bytes (the incident)
        try h.truncate(atOffset: 0)
        try h.write(contentsOf: other)
        try h.close()
        XCTAssertEqual(ExecutableIdentity.of(path: p.path)?.inode, id.inode)
        XCTAssertEqual(id.change(now: ExecutableIdentity.of(path: p.path)), .overwritten)
    }

    func testAnInvalidatedRunningProcessIsOverwrittenWhateverIsAtThePath() throws {
        let p = try program("doz")
        let id = try XCTUnwrap(ExecutableIdentity.of(path: p.path))
        // An install that wrote into the file and then re-signed it (a new inode) broke the process all the same.
        XCTAssertEqual(id.change(now: ExecutableIdentity.of(path: p.path), runningCodeValid: false), .overwritten)
        try FileManager.default.removeItem(at: p)
        XCTAssertEqual(id.change(now: nil), .removed)
        XCTAssertTrue(ExecutableIdentity.runningCodeIsValid(), "this test process is valid")
    }

    func testTheMessagesSayWhatToDo() {
        let o = ExecutableIdentity.explain(.overwritten, path: "/x/doz")
        XCTAssertTrue(o.hasPrefix("this host's program was updated underneath it"), o)
        XCTAssertTrue(o.contains("`doz host stop`, then retry"), o)
        XCTAssertTrue(ExecutableIdentity.explain(.replaced, path: "/x/doz").contains("`doz host stop` switches"))
    }

    func testTheHostExplainsAVMFailureOnlyWhenItsProgramWasOverwritten() async throws {
        let store = DozerStore(root: dir.appendingPathComponent("store"))
        let core = HostCore(store: store, readOnly: true, version: "test")
        let vz = NSError(domain: "VZErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Internal Virtualization error."])
        let p = try program("doz")
        await core.setExecutable(ExecutableIdentity.of(path: p.path))
        var e = await core.explain(vz)
        XCTAssertTrue(e.message.contains("Internal Virtualization error"), "unchanged: the raw error")
        let before = await core.executableChange()
        XCTAssertNil(before)
        let h = try FileHandle(forWritingTo: p)
        try h.seekToEnd()
        try h.write(contentsOf: Data([0]))
        try h.close()
        let after = await core.executableChange()
        XCTAssertEqual(after, .overwritten)
        e = await core.explain(vz)
        XCTAssertTrue(e.message.hasPrefix("this host's program was updated underneath it"), e.message)
        XCTAssertTrue(e.message.contains("Internal Virtualization error"), "the framework's words are kept, after the explanation")
        let st = await core.status()
        XCTAssertEqual(st.executableChange, "overwritten")
        XCTAssertEqual(st.executable, p.path)
        XCTAssertTrue(st.executableNote?.contains("doz host stop") == true)

        // 593: an ordinary host error keeps its own words, even now — never "the Virtualization framework said".
        for plain: Error in [SandboxError.restorePointNotFound("no-such-point"), HostError(.notFound, "no restore point x in alpha"),
                             SandboxError.alreadyExists("sandbox b"), SandboxError.invalidSpec("bad"),
                             NSError(domain: NSPOSIXErrorDomain, code: 2, userInfo: [NSLocalizedDescriptionKey: "No such file"])] {
            let m = await core.explain(plain).message
            XCTAssertFalse(m.contains("updated underneath"), "\(plain) → \(m)")
            XCTAssertFalse(m.contains("Virtualization framework said"), m)
        }
        let code = await core.explain(SandboxError.restorePointNotFound("p")).code
        XCTAssertEqual(code, .notFound, "and its code")
    }

    /// 593: what counts as the Virtualization framework's error.
    func testWhatIsAVirtualizationError() {
        let vz = NSError(domain: "VZErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Internal Virtualization error."])
        XCTAssertTrue(HostCore.isVirtualizationError(vz))
        XCTAssertTrue(HostCore.isVirtualizationError(NSError(domain: "Other", code: 1, userInfo: [NSUnderlyingErrorKey: vz])), "as an underlying error")
        XCTAssertTrue(HostCore.isVirtualizationError(NSError(domain: "Other", code: 1, userInfo: [NSMultipleUnderlyingErrorsKey: [vz]])))
        struct Wrapper: Error { let message: String; let cause: Error? }
        XCTAssertTrue(HostCore.isVirtualizationError(Wrapper(message: "boot failed", cause: vz)), "wrapped by a library error")
        XCTAssertTrue(HostCore.isVirtualizationError(Wrapper(message: "The process doesn’t have the “com.apple.security.virtualization” entitlement.", cause: nil)),
                      "the entitlement refusal of a broken signature")
        XCTAssertFalse(HostCore.isVirtualizationError(Wrapper(message: "boot failed", cause: nil)))
        XCTAssertFalse(HostCore.isVirtualizationError(SandboxError.restorePointNotFound("x")))
        XCTAssertFalse(HostCore.isVirtualizationError(SandboxError.invalidPhase(operation: "wake", phase: .off)))
        XCTAssertFalse(HostCore.isVirtualizationError(HostError(.failed, "Internal Virtualization error")), "a HostError is the host's own")
        XCTAssertFalse(HostCore.isVirtualizationError(NSError(domain: NSCocoaErrorDomain, code: 4)))
    }
}
