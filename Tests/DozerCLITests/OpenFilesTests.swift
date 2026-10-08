import Darwin
import Foundation
import XCTest
@testable import DozerKit
@testable import DozerHost
@testable import DozerCLI

/// 599b: a /workspace file opened on the Mac — the marker, the path mapped and resolved ON THE MAC, the
/// document allow-list and never-list, the content sniff, the app allow-list, the settings, isolation.
final class OpenFilesTests: XCTestCase {
    private var root: URL!
    private var ws: String { root.appendingPathComponent("ws").path }
    private var outside: String { root.appendingPathComponent("outside").path }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dz599b-\(getpid())-\(UInt32.random(in: 0 ... .max))")
        // The workspace as a person makes it: documents, a folder, and links in and out.
        try FileManager.default.createDirectory(atPath: ws + "/sub", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        for (name, text) in [("report.html", "<h1>hi</h1>"), ("notes.md", "# notes"), ("sub/page.htm", "<p>x</p>"), ("REPORT2.HTML", "<p>y</p>"),
                             ("x.command", "echo hi"), ("x.sh", "echo hi"), ("x.webloc", "<plist/>"), ("noext", "text"), ("data.bin", "x"),
                             ("script.txt", "#!/bin/sh\necho hi\n"), ("exec.txt", "plain"), ("fork.txt", "plain")] {
            try write(ws + "/" + name, text)
        }
        chmod(ws + "/exec.txt", 0o755)
        try write(outside + "/secret.html", "<p>secret</p>")
        try FileManager.default.createDirectory(atPath: ws + "/Thing.app/Contents", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: ws + "/abs-out.html", withDestinationPath: outside + "/secret.html")
        try FileManager.default.createSymbolicLink(atPath: ws + "/rel-out.html", withDestinationPath: "../outside/secret.html")
        try FileManager.default.createSymbolicLink(atPath: ws + "/in.html", withDestinationPath: "report.html")
        try FileManager.default.createSymbolicLink(atPath: ws + "/dirlink", withDestinationPath: outside)
        try FileManager.default.createSymbolicLink(atPath: ws + "/to-command.html", withDestinationPath: "x.command")
        // A guest symlink to its OWN absolute path means a Mac path that is not there.
        try FileManager.default.createSymbolicLink(atPath: ws + "/guest-abs.html", withDestinationPath: "/workspace/report.html")
        // A Mach-O program renamed .txt: this Mac's own /bin/ls.
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: ws + "/macho.txt")
        chmod(ws + "/macho.txt", 0o644)
        try Data([0x7F, 0x45, 0x4C, 0x46, 2, 1, 1]).write(to: URL(fileURLWithPath: ws + "/elf.txt"))
        XCTAssertEqual(setxattr(ws + "/fork.txt", "com.apple.ResourceFork", "usro", 4, 0, 0), 0)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ path: String, _ text: String) throws { try text.write(toFile: path, atomically: true, encoding: .utf8) }
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    private func resolved(_ guest: String) -> (path: String, shown: String)? {
        if case .success(let r) = WorkspaceFiles.resolve(guestPath: guest, workspace: ws) { return (r.macPath, r.shown) }
        return nil
    }
    private func refusal(_ guest: String) -> String {
        if case .failure(let r) = WorkspaceFiles.resolve(guestPath: guest, workspace: ws) { return r.message }
        return "(opened)"
    }

    // MARK: the marker

    func testTheScannerTakesAFileMarkerOutWholeAtEveryCut() {
        let whole = "a\u{1B}]6340;doz-file;Typora;/workspace/x;y.md\u{07}b\u{1B}]6340;doz-file;;/workspace/r.html\u{1B}\\c"
        for cut in 0...whole.utf8.count {
            var s = SessionBridgeScanner()
            let all = bytes(whole)
            let (o1, e1) = s.feed(all[..<cut])
            let (o2, e2) = s.feed(all[cut...])
            XCTAssertEqual(String(decoding: o1 + o2, as: UTF8.self), "abc", "cut at \(cut)")
            XCTAssertEqual(e1 + e2, [.openFile(path: "/workspace/x;y.md", app: "Typora"), .openFile(path: "/workspace/r.html", app: nil)], "cut at \(cut)")
        }
        var s = SessionBridgeScanner()
        XCTAssertEqual(s.feed(bytes("\u{1B}]6340;doz-file;no-path-field\u{07}")).events, [], "no second field: nothing")
        XCTAssertEqual(s.feed(bytes("\u{1B}]6340;doz-file;;/workspace/\(String(repeating: "a", count: 2100))\u{07}")).events, [.openTooLong])
        XCTAssertEqual(s.feed(bytes("\u{1B}]6340;doz-open;https://example.com/\u{07}")).events, [.openURL("https://example.com/")], "URLs as before")
    }

    // MARK: the path

    func testTheGuestPathIsNormalisedLexicallyUnderWorkspace() {
        XCTAssertEqual(WorkspaceFiles.lexicalRelative("/workspace/a/../b.md"), "b.md")
        XCTAssertEqual(WorkspaceFiles.lexicalRelative("/workspace//./sub/x.html"), "sub/x.html")
        XCTAssertNil(WorkspaceFiles.lexicalRelative("/workspace/../etc/passwd"))
        XCTAssertNil(WorkspaceFiles.lexicalRelative("/workspace/x/../../etc/hosts"))
        XCTAssertNil(WorkspaceFiles.lexicalRelative("/workspace"))
        XCTAssertNil(WorkspaceFiles.lexicalRelative("/workspace/.."))
        XCTAssertNil(WorkspaceFiles.lexicalRelative("/workspacex/a.md"))
        XCTAssertNil(WorkspaceFiles.lexicalRelative("/etc/hosts"))
        XCTAssertNil(WorkspaceFiles.lexicalRelative("report.html"), "relative: the shim makes it absolute, the host never guesses")
    }

    func testDocumentsInTheWorkspaceMapToTheMacFolder() throws {
        let real = try XCTUnwrap(WorkspaceFiles.realPath(ws))
        XCTAssertEqual(resolved("/workspace/report.html")?.path, real + "/report.html")
        XCTAssertEqual(resolved("/workspace/report.html")?.shown, "report.html")
        XCTAssertEqual(resolved("/workspace/notes.md")?.path, real + "/notes.md")
        XCTAssertEqual(resolved("/workspace/sub/../sub/page.htm")?.shown, "sub/page.htm")
        XCTAssertEqual(resolved("/workspace/REPORT2.HTML")?.shown, "REPORT2.HTML", "the type is case-insensitive")
        XCTAssertEqual(resolved("/workspace/in.html")?.path, real + "/report.html", "a link inside the workspace is followed to its file")
    }

    func testNothingOutsideTheSharedFolder() {
        XCTAssertTrue(refusal("/workspace/../outside/secret.html").contains("only files in /workspace"))
        XCTAssertTrue(refusal("/etc/hosts").contains("only files in /workspace"))
        XCTAssertTrue(refusal("/workspace/abs-out.html").contains("leads outside the shared folder"), "an absolute link out")
        XCTAssertTrue(refusal("/workspace/rel-out.html").contains("leads outside the shared folder"), "a relative link out")
        XCTAssertTrue(refusal("/workspace/dirlink/secret.html").contains("leads outside the shared folder"), "a linked folder out")
        XCTAssertTrue(refusal("/workspace/guest-abs.html").contains("no such file"), "a guest-absolute link names no Mac file")
        XCTAssertTrue(refusal("/workspace/missing.html").contains("no such file"))
        XCTAssertTrue(refusal("/workspace/a\u{01}.html").contains("control characters"))
        XCTAssertTrue(refusal("/workspace/" + String(repeating: "a", count: 1100) + ".md").contains("longer than"))
        // The shared folder itself, resolved: a workspace path that is itself a link still works.
        let link = root.appendingPathComponent("ws-link").path
        XCTAssertNoThrow(try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: ws))
        if case .success(let r) = WorkspaceFiles.resolve(guestPath: "/workspace/notes.md", workspace: link) {
            XCTAssertEqual(r.shown, "notes.md")
        } else { XCTFail("a workspace reached through a link") }
    }

    // MARK: types and content

    func testOnlyDocumentsNeverProgramsOrFolders() {
        XCTAssertTrue(refusal("/workspace/x.command").contains(".command is never opened (an app, script or installer type)"))
        XCTAssertTrue(refusal("/workspace/x.sh").contains(".sh is never opened"))
        XCTAssertTrue(refusal("/workspace/x.webloc").contains(".webloc is never opened"))
        XCTAssertTrue(refusal("/workspace/Thing.app").contains("Thing.app is an app or package: never opened"), "an app bundle, even for the Finder")
        XCTAssertTrue(refusal("/workspace/noext").contains("no document type"))
        XCTAssertTrue(refusal("/workspace/data.bin").contains(".bin is never opened"))
        try? "x".write(toFile: ws + "/sheet.xlsx", atomically: true, encoding: .utf8)
        XCTAssertTrue(refusal("/workspace/sheet.xlsx").contains(".xlsx is not a document type"), "not on either list: refused")
        XCTAssertTrue(refusal("/workspace/to-command.html").contains(".command"), "a document-named link to a program: the FILE's type counts")
        XCTAssertTrue(refusal("/workspace/exec.txt").contains("executable"))
        XCTAssertTrue(refusal("/workspace/script.txt").contains("#!"), "a shebang script named .txt")
        XCTAssertTrue(refusal("/workspace/macho.txt").contains("Mach-O"), "a Mac program renamed .txt")
        XCTAssertTrue(refusal("/workspace/elf.txt").contains("ELF"))
        XCTAssertTrue(refusal("/workspace/fork.txt").contains("resource fork"))
        for t in ["html", "md", "pdf", "png", "svg", "txt", "csv", "json", "yaml", "xml"] { XCTAssertTrue(WorkspaceFiles.documentTypes.contains(t), t) }
        XCTAssertTrue(Set(WorkspaceFiles.documentTypes).isDisjoint(with: WorkspaceFiles.neverTypes))
    }

    func testTheSniff() {
        XCTAssertNotNil(WorkspaceFiles.sniff([0xCF, 0xFA, 0xED, 0xFE]))
        XCTAssertNotNil(WorkspaceFiles.sniff([0xCA, 0xFE, 0xBA, 0xBE]))
        XCTAssertNotNil(WorkspaceFiles.sniff([0xFE, 0xED, 0xFA, 0xCF]))
        XCTAssertNotNil(WorkspaceFiles.sniff([0x23, 0x21]))
        XCTAssertNotNil(WorkspaceFiles.sniff([0x7F, 0x45, 0x4C, 0x46]))
        XCTAssertNil(WorkspaceFiles.sniff(Array("<htm".utf8)))
        XCTAssertNil(WorkspaceFiles.sniff(Array("# h".utf8)))
        XCTAssertNil(WorkspaceFiles.sniff([]))
    }

    // MARK: the decision: setting, isolation, apps

    func testTheDecision() {
        func d(_ app: String? = nil, workspace: String?, enabled: Bool = true, apps: [String] = []) -> WorkspaceFiles.Decision {
            WorkspaceFiles.decide(guestPath: "/workspace/notes.md", app: app, workspace: workspace, enabled: enabled, allowedApps: apps)
        }
        guard case .refused("file-off", let off) = d(workspace: ws, enabled: false) else { return XCTFail("off") }
        XCTAssertTrue(off.contains("sandbox.open_files"))
        guard case .refused("file-refused", let iso) = d(workspace: nil) else { return XCTFail("isolated") }
        XCTAssertTrue(iso.contains("isolated"), iso)
        guard case .refused(_, let none) = d("Typora", workspace: ws) else { return XCTFail("no app allowed") }
        XCTAssertTrue(none.contains("bridges.open_apps is empty"), none)
        guard case .refused(_, let other) = d("Safari", workspace: ws, apps: ["Typora"]) else { return XCTFail("unlisted") }
        XCTAssertEqual(other, "Safari is not in bridges.open_apps")
        guard case .refused(_, let bad) = d("../Evil", workspace: ws, apps: ["Typora"]) else { return XCTFail("bad name") }
        XCTAssertTrue(bad.contains("not an app name"), bad)
        guard case .open(let path, "notes.md", let app, .app) = d("typora", workspace: ws, apps: ["Visual Studio Code", "Typora"]) else { return XCTFail("listed") }
        XCTAssertEqual(app, "Typora", "the LISTED spelling reaches open -a, never the guest's")
        XCTAssertTrue(path.hasSuffix("/ws/notes.md"))
        guard case .open(_, _, nil, .app) = d(workspace: ws) else { return XCTFail("the default app") }
        XCTAssertEqual(WorkspaceFiles.shownRequest("/workspace/sub/../a\u{07}.md"), "a.md")
        XCTAssertEqual(WorkspaceFiles.shownRequest("/etc/hosts"), "/etc/hosts")
    }

    func testTheOpenerSeamRecordsTheMacPathAndApp() throws {
        let seam = root.appendingPathComponent("opened.log").path
        XCTAssertTrue(WorkspaceFiles.open(ws + "/notes.md", app: nil, environment: ["DOZ_TEST_OPEN_URL": seam]))
        XCTAssertTrue(WorkspaceFiles.open(ws + "/notes.md", app: "Typora", environment: ["DOZ_TEST_OPEN_URL": seam]))
        XCTAssertEqual(try String(contentsOfFile: seam, encoding: .utf8), "open-file default \(ws)/notes.md\nopen-file Typora \(ws)/notes.md\n")
    }

    // MARK: settings

    func testTheSettings() throws {
        XCTAssertTrue(DozerSettings.perSandbox.contains(SettingKey.openFiles))
        let of = try XCTUnwrap(DozerSettings.definition(SettingKey.openFiles))
        XCTAssertEqual(of.defaultValue, .string("on"))
        XCTAssertThrowsError(try of.parse("maybe"))
        XCTAssertEqual(try HostCore.checkedSandboxSettings([SettingKey.openFiles: .string("off")]), [SettingKey.openFiles: .string("off")])
        XCTAssertFalse(DozerSettings.perSandbox.contains(SettingKey.openApps), "the app list is the user's, for every sandbox")
        let apps = try XCTUnwrap(DozerSettings.definition(SettingKey.openApps))
        XCTAssertEqual(apps.defaultValue, .string(""))
        XCTAssertEqual(try apps.parse("Typora, Visual Studio Code"), .string("Typora, Visual Studio Code"))
        XCTAssertEqual(WorkspaceFiles.appNames("Typora, Visual Studio Code,"), ["Typora", "Visual Studio Code"])
        XCTAssertEqual(WorkspaceFiles.appNames(""), [])
        for bad in ["/Applications/Typora.app", "a;b", "-a", ".hidden", String(repeating: "x", count: 65),
                    (1...17).map { "a\($0)" }.joined(separator: ",")] {
            XCTAssertThrowsError(try apps.parse(bad), bad)
        }
        let row = try XCTUnwrap(DozerSettings(text: "").report().settings.first { $0.key == SettingKey.openApps })
        XCTAssertEqual(row.type, "apps")
        XCTAssertTrue(row.editable)
        XCTAssertTrue(DozerSettings.render(values: [SettingKey.openApps: .string("Typora")]).contains("[bridges]\n"))
    }

    func testTheProjectFileAndTheCreateFlag() throws {
        let p = try DozerProject.parse("version: 1\nname: p\nimage: lab\nopen_files: off\n")
        XCTAssertEqual(p.settings[SettingKey.openFiles], .string("off"))
        XCTAssertThrowsError(try DozerProject.parse("version: 1\nname: p\nimage: lab\nopen_files: maybe\n"))
        XCTAssertTrue(DozerProject(name: "p", image: "lab").render().contains("# open_files: on"))
        let c = try Create.parse(["x", "--open-files", "off"])
        XCTAssertEqual(try c.create.sandboxSettings(), [SettingKey.openFiles: .string("off")])
        XCTAssertThrowsError(try Create.parse(["x", "--open-files", "maybe"]).create.sandboxSettings())
    }

    // MARK: the agent is told

    func testTheFactsSayItAsItIsForThisSandbox() {
        func files(_ workspace: String?, _ on: Bool, _ apps: [String] = []) -> String {
            AgentPrompt.values(name: "n", image: "pi", cpus: 1, memoryMiB: 1024, workspace: workspace, network: .none, account: nil, version: "1",
                               hostname: "h", openFiles: on, openApps: apps)["files.description"] ?? ""
        }
        XCTAssertTrue(files(nil, true).contains("isolated"))
        XCTAssertTrue(files("/Users/u/p", false).contains("off for this sandbox"))
        let on = files("/Users/u/p", true)
        XCTAssertTrue(on.contains("`xdg-open FILE`") && on.contains("notice") && on.contains("Only the file's default app"), on)
        XCTAssertTrue(files("/Users/u/p", true, ["Typora"]).contains("doz-open --app NAME FILE") && files("/Users/u/p", true, ["Typora"]).contains("Typora"))
        XCTAssertTrue(on.contains("in the Finder") && on.contains("--reveal"), "the skill's longer version names folders and --reveal")
        // The facts block: ONE line for every open bridge (the skill has the long version).
        XCTAssertTrue(AgentPrompt.builtInTemplate.contains("- {{mac.open}}"))
        XCTAssertFalse(AgentPrompt.builtInTemplate.contains("{{files.description}}") || AgentPrompt.builtInTemplate.contains("{{browser.description}}"))
        XCTAssertTrue(AgentPrompt.skillTemplate.contains("{{files.description}}") && AgentPrompt.skillTemplate.contains("{{browser.description}}"))
    }

    func testTheFactsHaveOneOpenLineSayingOnlyWhatIsOn() throws {
        func line(_ workspace: String?, browser: Bool, files: Bool) -> String {
            AgentPrompt.values(name: "n", image: "pi", cpus: 1, memoryMiB: 1024, workspace: workspace, network: .none, account: nil, version: "1",
                               hostname: "h", browser: browser, openFiles: files)["mac.open"] ?? "?"
        }
        let all = line("/Users/u/p", browser: true, files: true)
        XCTAssertEqual(all, "You can show the user things on their Mac: `open`/`xdg-open` a URL (their browser), a /workspace document (its app), or a /workspace folder (Finder); `doz-open --reveal PATH` shows a file in its folder. The user sees a notice each time.")
        XCTAssertEqual(line("/Users/u/p", browser: true, files: false), "You can show the user things on their Mac: `open`/`xdg-open` a URL (their browser). The user sees a notice each time.",
                       "files off: only what still works")
        XCTAssertEqual(line("/Users/u/p", browser: false, files: true),
                       "You can show the user things on their Mac: `open`/`xdg-open` a /workspace document (its app), or a /workspace folder (Finder); `doz-open --reveal PATH` shows a file in its folder. The user sees a notice each time.")
        XCTAssertEqual(line(nil, browser: true, files: true),
                       "You can show the user things on their Mac: `open`/`xdg-open` a URL (their browser); folders and documents can't be opened — nothing is shared. The user sees a notice each time.")
        XCTAssertEqual(line("/Users/u/p", browser: false, files: false), "", "both off: nothing")
        XCTAssertEqual(line(nil, browser: false, files: true), "", "isolated with the browser off: nothing works")
        // Rendered: an empty line is no line at all.
        let v = AgentPrompt.values(name: "n", image: "pi", cpus: 1, memoryMiB: 1024, workspace: nil, network: .none, account: nil, version: "1",
                                   hostname: "h", browser: false, openFiles: false)
        let off = try AgentPrompt.render(AgentPrompt.builtInTemplate, v, source: "b")
        let on = try AgentPrompt.render(AgentPrompt.builtInTemplate,
                                        AgentPrompt.values(name: "n", image: "pi", cpus: 1, memoryMiB: 1024, workspace: "/w", network: .none, account: nil,
                                                           version: "1", hostname: "h"), source: "b")
        XCTAssertFalse(off.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "-" })
        XCTAssertEqual(on.split(separator: "\n").count, off.split(separator: "\n").count + 1)
        XCTAssertTrue(on.contains("- You can show the user things on their Mac"))
    }

    // MARK: folders and --reveal

    func testFoldersOpenInTheFinderAndPackagesNever() throws {
        func d(_ path: String, app: String? = nil, reveal: Bool = false, workspace: String? = nil) -> WorkspaceFiles.Decision {
            WorkspaceFiles.decide(guestPath: path, app: app, reveal: reveal, workspace: workspace ?? ws, enabled: true, allowedApps: ["Typora"])
        }
        let real = try XCTUnwrap(WorkspaceFiles.realPath(ws))
        XCTAssertEqual(d("/workspace"), .open(macPath: real, shown: "the workspace", app: nil, how: .finder), "the workspace itself")
        XCTAssertEqual(d("/workspace/sub/.."), .open(macPath: real, shown: "the workspace", app: nil, how: .finder))
        XCTAssertEqual(d("/workspace/sub"), .open(macPath: real + "/sub", shown: "sub/", app: nil, how: .finder), "a child folder")
        guard case .refused(_, let up) = d("/workspace/.."), case .refused(_, let out) = d("/workspace/dirlink") else { return XCTFail("escapes") }
        XCTAssertTrue(up.contains("only files in /workspace"), up)
        XCTAssertTrue(out.contains("leads outside the shared folder"), "a link to a folder outside: \(out)")
        guard case .refused(_, let pkg) = d("/workspace/Thing.app") else { return XCTFail("a package") }
        XCTAssertTrue(pkg.contains("app or package"), pkg)
        // A folder macOS calls a package without a known extension (.rtfd is one).
        try FileManager.default.createDirectory(atPath: ws + "/Notes.rtfd", withIntermediateDirectories: true)
        guard case .refused(_, let rtfd) = d("/workspace/Notes.rtfd") else { return XCTFail("isPackage") }
        XCTAssertTrue(rtfd.contains("app or package"), rtfd)
        guard case .refused(_, let withApp) = d("/workspace/sub", app: "Typora") else { return XCTFail("--app with a folder") }
        XCTAssertTrue(withApp.contains("a folder opens in the Finder"), withApp)
        guard case .refused(_, let iso) = WorkspaceFiles.decide(guestPath: "/workspace/sub", app: nil, workspace: nil, enabled: true, allowedApps: []) else { return XCTFail("isolated") }
        XCTAssertTrue(iso.contains("isolated"))
        // --reveal: a file selected in its folder (its type is not checked — nothing opens), a folder shown,
        // a package selected in its parent; never outside.
        XCTAssertEqual(d("/workspace/notes.md", reveal: true), .open(macPath: real + "/notes.md", shown: "notes.md", app: nil, how: .reveal))
        XCTAssertEqual(d("/workspace/x.command", reveal: true), .open(macPath: real + "/x.command", shown: "x.command", app: nil, how: .reveal))
        XCTAssertEqual(d("/workspace/sub", reveal: true), .open(macPath: real + "/sub", shown: "sub/", app: nil, how: .finder))
        XCTAssertEqual(d("/workspace/Thing.app", reveal: true), .open(macPath: real + "/Thing.app", shown: "Thing.app", app: nil, how: .reveal))
        guard case .refused = d("/workspace/abs-out.html", reveal: true), case .refused = d("/workspace/notes.md", app: "Typora", reveal: true) else {
            return XCTFail("reveal never outside, never with --app")
        }
        // The seam.
        let seam = root.appendingPathComponent("folders.log").path
        XCTAssertTrue(WorkspaceFiles.open(real + "/sub", app: nil, how: .finder, environment: ["DOZ_TEST_OPEN_URL": seam]))
        XCTAssertTrue(WorkspaceFiles.open(real + "/notes.md", app: nil, how: .reveal, environment: ["DOZ_TEST_OPEN_URL": seam]))
        XCTAssertEqual(try String(contentsOfFile: seam, encoding: .utf8), "open-folder \(real)/sub\nreveal \(real)/notes.md\n")
    }

    func testTheScannerTakesAReveal() {
        var s = SessionBridgeScanner()
        let (out, ev) = s.feed(bytes("a\u{1B}]6340;doz-reveal;/workspace/x y.md\u{07}b"))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "ab")
        XCTAssertEqual(ev, [.revealFile(path: "/workspace/x y.md")])
    }

    // MARK: the guest half

    func testTheShimTakesFilesAndIsValidShell() throws {
        let shim = GuestCommand.openShim
        XCTAssertTrue(shim.contains("# doz:open-url-shim:v6"), "a new stamp: a wake re-installs it")
        XCTAssertTrue(GuestCommand.openShimInstall.contains("doz:open-url-shim:v6"))
        XCTAssertTrue(shim.contains("send \"doz-reveal;$abs\"") && shim.contains("send \"doz-file;;$abs\""))
        XCTAssertTrue(GuestCommand.openShimAliases.contains("doz-open"))
        XCTAssertTrue(shim.contains("send \"doz-file;$app;$abs\""))
        XCTAssertTrue(shim.contains("*.command|") && shim.contains("*.html|"), "the type lists are in the shim")
        XCTAssertFalse(shim.contains("\\#("), "every interpolation was made")
        let file = root.appendingPathComponent("xdg-open")
        try shim.write(to: file, atomically: true, encoding: .utf8)
        func sh(_ args: [String]) throws -> (code: Int32, err: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = args
            let e = Pipe()
            p.standardError = e
            p.standardOutput = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            try p.run()
            let err = String(decoding: e.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return (p.terminationStatus, err)
        }
        XCTAssertEqual(try sh(["-n", file.path]).code, 0, "the shim parses")
        // Refusals that never reach a terminal (this Mac has no /proc/mounts: as an isolated sandbox).
        var r = try sh([file.path, "file:///etc/passwd"])
        XCTAssertTrue(r.code == 1 && r.err.contains("only http and https URLs go to the Mac: file:///etc/passwd"), r.err)
        r = try sh([file.path, "--app", "a/b", "x.md"])
        XCTAssertTrue(r.code == 1 && r.err.contains("is not an app name"), r.err)
        r = try sh([file.path, "--app", "Typora", "https://example.com/"])
        XCTAssertTrue(r.code == 1 && r.err.contains("--app is for files"), r.err)
        r = try sh([file.path, ws + "/notes.md"])
        XCTAssertTrue(r.code == 1 && r.err.contains("this sandbox is isolated"), r.err)
        r = try sh([file.path])
        XCTAssertTrue(r.code == 1 && r.err.contains("usage:"), r.err)
    }
}
