import Foundation
import XCTest
import ArgumentParser
@testable import DozerHost
@testable import DozerCLI

/// 617: doz get / put / cp — the pure parts (paths, operands, frames, the guest's checks run for real under /bin/sh, the
/// Mac's placing and refusals). The VM proof is probes/617-*/stageC/copy-run.sh.
final class FileCopyTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("filecopy-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dir = dir.resolvingSymlinksInPath()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testGuestPathsAndNames() {
        XCTAssertEqual(CopyPaths.guestPath("report.md"), "/workspace/report.md", "relative: under /workspace")
        XCTAssertEqual(CopyPaths.guestPath("/etc//hosts"), "/etc/hosts")
        XCTAssertEqual(CopyPaths.guestPath("/workspace/a/../b/./c/"), "/workspace/b/c")
        XCTAssertEqual(CopyPaths.guestPath("../../.."), "/")
        XCTAssertNil(CopyPaths.guestPath(""))
        XCTAssertNil(CopyPaths.guestPath("a\nb"), "no control characters")
        XCTAssertNil(CopyPaths.guestPath(String(repeating: "a", count: 5000)))
        XCTAssertTrue(CopyPaths.isItemName("report.md"))
        for bad in ["", ".", "..", "a/b", "a\u{7}"] { XCTAssertFalse(CopyPaths.isItemName(bad), bad) }
    }

    func testCpOperands() {
        XCTAssertEqual(CopyPaths.operand("try-grok:/workspace/x").sandbox, "try-grok")
        XCTAssertEqual(CopyPaths.operand("try-grok:/workspace/x").path, "/workspace/x")
        XCTAssertEqual(CopyPaths.operand("my-app:").path, "", "NAME: alone (/workspace, said by the command)")
        XCTAssertNil(CopyPaths.operand("./a:b").sandbox, "a local name with a colon")
        XCTAssertNil(CopyPaths.operand("/tmp/x").sandbox)
        XCTAssertNil(CopyPaths.operand("Not_A_Name:x").sandbox, "not a sandbox name: a local path")
    }

    func testFramesSurviveEveryCut() throws {
        let a = Data((0..<300).map { UInt8($0 & 0xFF) })
        let stream = CopyFrame.encode(CopyFrame.data, a) + CopyFrame.encode(CopyFrame.data, Data()) + CopyFrame.encode(CopyFrame.end, Data("{}".utf8))
        for cut in 0...stream.count {
            let p = CopyFrame.Parser()
            let f = try p.feed(stream.prefix(cut)) + p.feed(stream.dropFirst(cut))
            XCTAssertEqual(f.map(\.type), [CopyFrame.data, CopyFrame.data, CopyFrame.end], "cut \(cut)")
            XCTAssertEqual(f.first?.payload, a)
        }
        XCTAssertThrowsError(try CopyFrame.Parser().feed(Data([0x5A, 0, 0, 0, 0])), "an unknown frame type")
        XCTAssertThrowsError(try CopyFrame.Parser().feed(Data([CopyFrame.data, 0x7F, 0, 0, 0])), "over the maximum")
    }

    func sh(_ script: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// The guest's checks, run for real (the same POSIX sh tools the guest has: readlink -f, du, find).
    func testTheGetCheck() throws {
        let src = dir.appendingPathComponent("src folder")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "hello".write(to: src.appendingPathComponent("sub/a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("inside").path, withDestinationPath: "sub/a.txt")
        guard case .ok(let k, _, let n, let resolved) = CopyPaths.parseGet(try sh(CopyPaths.getCheckScript(src.path))) else {
            return XCTFail("not ok: \(try sh(CopyPaths.getCheckScript(src.path)))")
        }
        XCTAssertEqual(k, .folder)
        XCTAssertEqual(n, 4, "the folder, sub, a.txt, the link")
        XCTAssertTrue(resolved.hasSuffix("/" + dir.lastPathComponent + "/src folder"), "a path with a space: \(resolved)")
        XCTAssertEqual(CopyPaths.parseGet(try sh(CopyPaths.getCheckScript(src.appendingPathComponent("sub/a.txt").path))).kind, .file)
        // A link that points outside: refused, named.
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("out").path, withDestinationPath: "/etc/hosts")
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("up").path, withDestinationPath: "../elsewhere")
        guard case .escapes(let l) = CopyPaths.parseGet(try sh(CopyPaths.getCheckScript(src.path))) else { return XCTFail("escape not seen") }
        XCTAssertEqual(Set(l), ["out -> /etc/hosts", "up -> ../elsewhere"])
        XCTAssertEqual(CopyPaths.parseGet(try sh(CopyPaths.getCheckScript(dir.appendingPathComponent("nope").path))), .missing)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("dangling").path, withDestinationPath: "nowhere")
        XCTAssertEqual(CopyPaths.parseGet(try sh(CopyPaths.getCheckScript(dir.appendingPathComponent("dangling").path))), .dangling)
        XCTAssertEqual(CopyPaths.parseGet(try sh(CopyPaths.getCheckScript("/"))), .root)
        XCTAssertEqual(CopyPaths.parseGet(try sh(CopyPaths.getCheckScript("/dev/null"))), .special)
        // A name with a quote cannot break out of the script.
        let odd = dir.appendingPathComponent("it's $(echo x)")
        try "x".write(to: odd, atomically: true, encoding: .utf8)
        XCTAssertEqual(CopyPaths.parseGet(try sh(CopyPaths.getCheckScript(odd.path))).kind, .file)
    }

    func testThePutCheck() throws {
        let ws = dir.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        XCTAssertEqual(CopyPaths.parsePut(try sh(CopyPaths.putCheckScript(dest: ws.path, name: "a.txt"))),
                       .ok(writable: true, existing: nil, target: ws.path + "/a.txt"), "into a folder: its own name")
        XCTAssertEqual(CopyPaths.parsePut(try sh(CopyPaths.putCheckScript(dest: ws.path + "/b.txt", name: "a.txt"))),
                       .ok(writable: true, existing: nil, target: ws.path + "/b.txt"), "a new name")
        try "x".write(to: ws.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(CopyPaths.parsePut(try sh(CopyPaths.putCheckScript(dest: ws.path, name: "a.txt"))),
                       .ok(writable: true, existing: .file, target: ws.path + "/a.txt"), "there already")
        XCTAssertEqual(CopyPaths.parsePut(try sh(CopyPaths.putCheckScript(dest: ws.path + "/no/such/x", name: "a"))), .noParent(ws.path + "/no/such"))
        XCTAssertEqual(CopyPaths.parsePut(try sh(CopyPaths.putCheckScript(dest: ws.path + "/missing/", name: "a"))), .noParent(ws.path + "/missing/"))
        XCTAssertEqual(CopyPaths.parsePut(try sh(CopyPaths.putCheckScript(dest: "/", name: "a"))),
                       .ok(writable: false, existing: nil, target: "/a"), "not writable: the host uses root, said")
    }

    func testTheGuestTarsAndErrors() {
        XCTAssertEqual(CopyPaths.getTar("/workspace/out"), ["tar", "-C", "/workspace", "-cf", "-", "out"])
        XCTAssertEqual(CopyPaths.getTar("/etc"), ["tar", "-C", "/", "-cf", "-", "etc"])
        XCTAssertEqual(CopyPaths.putTar("/workspace/in"), ["tar", "-C", "/workspace", "-x", "-o", "-f", "-"], "-o: never the archive's owner")
        XCTAssertEqual(CopyPaths.tarError("\n tar: x: Cannot open: Permission denied\nmore"), "tar: x: Cannot open: Permission denied")
        XCTAssertEqual(CopyPaths.tarError("a\u{1B}[31mb"), "a[31mb", "inert")
    }

    func testWhereAGetLandsAndWhatItRefuses() throws {
        let cwd = dir.path
        XCTAssertEqual(LocalCopy.destination(name: "r.md", local: nil, cwd: cwd).path, cwd + "/r.md")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("into"), withIntermediateDirectories: true)
        XCTAssertEqual(LocalCopy.destination(name: "r.md", local: "into", cwd: cwd).path, cwd + "/into/r.md", "an existing folder: inside, its own name")
        XCTAssertEqual(LocalCopy.destination(name: "r.md", local: "renamed.md", cwd: cwd).path, cwd + "/renamed.md")
        XCTAssertNotNil(LocalCopy.destination(name: "r.md", local: "missing/x", cwd: cwd).problem)
        XCTAssertNotNil(LocalCopy.destination(name: "r.md", local: "newdir/", cwd: cwd).problem, "a folder that is not there")
        // Never into the store (its real path, a link to it, a path inside not yet made).
        let store = dir.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("st-link").path, withDestinationPath: store.path)
        XCTAssertTrue(LocalCopy.inStore(store.path + "/sandboxes/x/new.txt", store: store))
        XCTAssertTrue(LocalCopy.inStore(dir.path + "/st-link/x", store: store))
        XCTAssertFalse(LocalCopy.inStore(dir.path + "/storefront/x", store: store), "a prefix is not inside")
    }

    func testPlacingAndLinksOnTheMac() throws {
        let fm = FileManager.default
        let tmp = dir.appendingPathComponent(".doz-get-1")
        try fm.createDirectory(at: tmp.appendingPathComponent("item/sub"), withIntermediateDirectories: true)
        try "new".write(to: tmp.appendingPathComponent("item/sub/a.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: tmp.appendingPathComponent("item/ok").path, withDestinationPath: "sub/a.txt")
        XCTAssertEqual(LocalCopy.escapingLinks(tmp.appendingPathComponent("item").path), [])
        try fm.createSymbolicLink(atPath: tmp.appendingPathComponent("item/bad").path, withDestinationPath: "../../outside")
        XCTAssertEqual(LocalCopy.escapingLinks(tmp.appendingPathComponent("item").path), ["bad -> ../../outside"])
        try fm.removeItem(at: tmp.appendingPathComponent("item/bad"))
        // Nothing there: a move.
        let dest = dir.appendingPathComponent("dest").path
        try LocalCopy.place(tmp.appendingPathComponent("item").path, at: dest, force: false)
        XCTAssertEqual(try String(contentsOfFile: dest + "/sub/a.txt", encoding: .utf8), "new")
        // There already: refused without --force; merged with it (a file of the same name replaced, others kept).
        try fm.createDirectory(at: tmp.appendingPathComponent("item2/sub"), withIntermediateDirectories: true)
        try "newer".write(to: tmp.appendingPathComponent("item2/sub/a.txt"), atomically: true, encoding: .utf8)
        try "mine".write(toFile: dest + "/mine.txt", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try LocalCopy.place(tmp.appendingPathComponent("item2").path, at: dest, force: false))
        try LocalCopy.place(tmp.appendingPathComponent("item2").path, at: dest, force: true)
        XCTAssertEqual(try String(contentsOfFile: dest + "/sub/a.txt", encoding: .utf8), "newer")
        XCTAssertEqual(try String(contentsOfFile: dest + "/mine.txt", encoding: .utf8), "mine")
        // Never a folder over a file.
        try "f".write(toFile: dir.path + "/afile", atomically: true, encoding: .utf8)
        try fm.createDirectory(at: tmp.appendingPathComponent("item3"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try LocalCopy.place(tmp.appendingPathComponent("item3").path, at: dir.path + "/afile", force: true))
    }

    func testTheCommandsParse() throws {
        XCTAssertNoThrow(try DozerCommand.parseAsRoot(["get", "try-grok", "/workspace/x", "out", "--force"]))
        XCTAssertNoThrow(try DozerCommand.parseAsRoot(["put", "try-grok", "x"]))
        XCTAssertNoThrow(try DozerCommand.parseAsRoot(["cp", "try-grok:/workspace/x", "."]))
        XCTAssertThrowsError(try DozerCommand.parseAsRoot(["get", "try-grok"]), "a PATH is needed")
        XCTAssertEqual(FileTransfer.bre("a.b[1]*"), "a\\.b\\[1\\]\\*")
        XCTAssertEqual(FileTransfer.breReplacement("x~y/z&"), "x\\~y\\/z&", "~ is the match in bsdtar -s; & is not special")
    }

    func testNeitherSideNamesASandboxSuggestsWhereItIs() {
        let ws = "/Users/me/dozer-sandbox-workspaces/try-grok"
        let rows = [CopyHint.Row(name: "box", phase: "off", workspace: "/x/box"),
                    CopyHint.Row(name: "try-grok", phase: "running", workspace: ws)]
        let shown: (String) -> String = { $0.replacingOccurrences(of: "/Users/me", with: "~") }
        // The owner's case: the file is in a sandbox's folder — it is already on the Mac.
        let found = CopyHint.neitherSide(source: "lemonade.html", destination: "~/Developer/fun/lemonade.html", sandboxes: rows,
                                         existsOnMac: { $0 == ws + "/lemonade.html" }, cwd: "/tmp", shown: shown)
        XCTAssertEqual(found, "lemonade.html is in try-grok's folder — it's already on your Mac at ~/dozer-sandbox-workspaces/try-grok/lemonade.html. Or: doz get try-grok lemonade.html ~/Developer/fun/")
        // Not in any folder, one running: name it (from it — the source is not on this Mac).
        XCTAssertEqual(CopyHint.neitherSide(source: "x.txt", destination: ".", sandboxes: rows, existsOnMac: { _ in false }, cwd: "/tmp", shown: shown),
                       "From try-grok: doz cp try-grok:x.txt .")
        // The source is on this Mac: into it.
        XCTAssertEqual(CopyHint.neitherSide(source: "x.txt", destination: "out", sandboxes: rows, existsOnMac: { $0 == "/tmp/x.txt" }, cwd: "/tmp", shown: shown),
                       "Into try-grok: doz cp x.txt try-grok:out")
        // Two running (or none): nothing to suggest; an absolute or escaping source is never looked up in a folder.
        let two = rows.map { CopyHint.Row(name: $0.name, phase: "running", workspace: $0.workspace) }
        XCTAssertNil(CopyHint.neitherSide(source: "x.txt", destination: ".", sandboxes: two, existsOnMac: { _ in false }, cwd: "/tmp", shown: shown))
        XCTAssertNil(CopyHint.neitherSide(source: "../x", destination: ".", sandboxes: [rows[0]], existsOnMac: { _ in true }, cwd: "/tmp", shown: shown))
    }
}

extension CopyPaths.GetCheck {
    var kind: CopyKind? { if case .ok(let k, _, _, _) = self { return k }; return nil }
}
