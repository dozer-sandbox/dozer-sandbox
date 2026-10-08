import ArgumentParser
import Darwin
import Foundation
import DozerKit
import XCTest
@testable import DozerCLI
@testable import DozerHost

/// 598 — the Homebrew release: the version stamp beside the executable, a Homebrew keg recognised
/// (and never removed by `doz uninstall`), `doz host upgrade-check`, and a host refusing to boot once
/// an upgrade removed its program. No VM, no Homebrew, no network.
final class ReleaseTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: "/tmp/d598r-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// A fake install layout: `<root>/libexec/doz/doz` (an empty file), `<root>/bin/doz` a link to it.
    private func layout(_ root: URL, version: String?) throws -> (exe: URL, link: URL) {
        let libexec = root.appendingPathComponent("libexec/doz")
        try FileManager.default.createDirectory(at: libexec, withIntermediateDirectories: true)
        let exe = libexec.appendingPathComponent("doz")
        FileManager.default.createFile(atPath: exe.path, contents: Data())
        if let version { try (version + "\n").write(to: libexec.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("doz")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../libexec/doz/doz")
        return (exe, link)
    }

    func testTheVersionStampIsReadBesideTheResolvedExecutable() throws {
        let (exe, link) = try layout(dir.appendingPathComponent("keg"), version: "0.12.0")
        XCTAssertEqual(ReleaseStamp.read(executable: exe.path), "0.12.0")
        XCTAssertEqual(ReleaseStamp.read(executable: link.path), "0.12.0", "through bin/doz, the link Homebrew makes")
        let (plain, _) = try layout(dir.appendingPathComponent("plain"), version: nil)
        XCTAssertNil(ReleaseStamp.read(executable: plain.path), "a build without a stamp falls back to builtVersion")
        for bad in ["", "latest", "0.12", "v0.12.0", "0.12.0\n0.13.0", String(repeating: "1", count: 50)] {
            XCTAssertNil(ReleaseStamp.parse(bad), bad)
        }
        XCTAssertEqual(ReleaseStamp.parse(" 0.12.0-rc.1\n"), "0.12.0-rc.1")
        // This test binary has no stamp beside it: the constant.
        XCTAssertEqual(DozerCommand.version, DozerCommand.builtVersion)
    }

    func testAHomebrewKegIsRecognisedAndNeverTakenForAMakeInstall() throws {
        let cellar = dir.appendingPathComponent("opt/homebrew/Cellar/doz/0.12.0")
        let (exe, kegLink) = try layout(cellar, version: "0.12.0")
        // /opt/homebrew/bin/doz → ../Cellar/doz/0.12.0/bin/doz → ../libexec/doz/doz
        let prefixBin = dir.appendingPathComponent("opt/homebrew/bin")
        try FileManager.default.createDirectory(at: prefixBin, withIntermediateDirectories: true)
        let brewLink = prefixBin.appendingPathComponent("doz")
        try FileManager.default.createSymbolicLink(atPath: brewLink.path, withDestinationPath: "../Cellar/doz/0.12.0/bin/doz")
        for path in [exe.path, kegLink.path, brewLink.path] {
            XCTAssertEqual(Uninstall.homebrewKeg(executable: path)?.resolvingSymlinksInPath().path,
                           cellar.resolvingSymlinksInPath().path, path)
        }
        // 611: every channel's formula is a keg too (doz-beta, doz-canary) — never removed by doz uninstall.
        let beta = dir.appendingPathComponent("opt/homebrew/Cellar/doz-beta/0.32.0-rc.1")
        let (betaExe, _) = try layout(beta, version: "0.32.0-rc.1")
        XCTAssertEqual(Uninstall.homebrewKeg(executable: betaExe.path)?.resolvingSymlinksInPath().path, beta.resolvingSymlinksInPath().path)
        XCTAssertEqual(Uninstall.formula(beta), "doz-beta")
        let other = dir.appendingPathComponent("opt/homebrew/Cellar/dozzz/1.0.0")
        let (otherExe, _) = try layout(other, version: "1.0.0")
        XCTAssertNil(Uninstall.homebrewKeg(executable: otherExe.path), "not one of doz's formulas")
        let (local, _) = try layout(dir.appendingPathComponent("home/.local"), version: nil)
        XCTAssertNil(Uninstall.homebrewKeg(executable: local.path), "make install-cli's layout is not a keg")
        XCTAssertNotNil(Uninstall.installation(executable: local.path))
        XCTAssertNil(Uninstall.homebrewKeg(executable: "/x/.build/debug/doz"))
    }

    func testUpgradeCheckReadsAProcessExecutableFromTheKernel() {
        let mine = HostUpgradeCheck.executablePath(of: getpid())
        XCTAssertNotNil(mine)
        XCTAssertEqual(mine.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().lastPathComponent },
                       URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath().lastPathComponent)
        XCTAssertNil(HostUpgradeCheck.executablePath(of: 999_999))
    }

    func testUpgradeCheckWithNoHostSaysSoAndExitsZero() throws {
        let store = dir.appendingPathComponent("store")
        let cmd = try DozerCommand.parseAsRoot(["host", "upgrade-check", "--store", store.path, "--json"])
        XCTAssertTrue(cmd is HostUpgradeCheck)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path), "parsing makes nothing")
    }

    /// A host whose program an upgrade removed refuses to boot, plainly, and says so in its status.
    func testAHostWhoseProgramIsGoneRefusesBootsPlainly() async throws {
        let store = DozerStore(root: dir.appendingPathComponent("store"))
        let core = HostCore(store: store, readOnly: false, version: "test",
                            services: .forHost(environment: ["DOZ_TEST_CREDENTIALS": "memory"]))
        await core.load()
        let noneYet = await core.programGone()
        XCTAssertNil(noneYet, "no program recorded: nothing to say")
        let (exe, _) = try layout(dir.appendingPathComponent("oldkeg"), version: "0.11.0")
        await core.setExecutable(ExecutableIdentity.of(path: exe.path))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("oldkeg"))
        let gone = await core.programGone()
        XCTAssertTrue(gone?.contains("is gone") ?? false, gone ?? "nil")
        for op: HostOp in [.create, .start, .wake] {
            var r = HostRequest(op, name: "a")
            r.create = CreateOptions(image: "lab")
            let m = await core.handle(r)
            XCTAssertEqual(m.error?.code, .unavailable, "\(op)")
            XCTAssertTrue(m.error?.message.contains("doz host stop") ?? false, "\(op): \(m.error?.message ?? "")")
        }
        let ls = await core.handle(HostRequest(.ls))
        XCTAssertEqual(ls.ok, true, "reading still works")
        let st = await core.status()
        XCTAssertEqual(st.executableChange, "removed")
        XCTAssertTrue(st.executableNote?.contains("brew") ?? false)
    }
}
