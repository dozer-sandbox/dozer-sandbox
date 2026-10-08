import CryptoKit
import XCTest
@testable import DozerKit

/// The committed guest binary is found at run time and is exactly the one PROVENANCE.md records.
final class DeckholdBinaryTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func test_locateFindsTheResourceWithoutBundleModule() throws {
        let url = try XCTUnwrap(DeckholdBinary.locate(environment: [:]), "the resource bundle beside the test bundle")
        XCTAssertEqual(url.lastPathComponent, "deckhold")
        let head = try FileHandle(forReadingFrom: url).read(upToCount: 20) ?? Data()
        XCTAssertEqual([UInt8](head.prefix(4)), [0x7F, 0x45, 0x4C, 0x46], "an ELF")
        XCTAssertEqual(head[4], 2, "64-bit")
        XCTAssertEqual(UInt16(head[18]) | UInt16(head[19]) << 8, 183, "machine = aarch64")
    }

    func test_environmentOverrideWins() {
        let me = URL(fileURLWithPath: #filePath)
        XCTAssertEqual(DeckholdBinary.locate(environment: [DeckholdBinary.environmentOverride: me.path]), me)
        XCTAssertNil(DeckholdBinary.locate(environment: [DeckholdBinary.environmentOverride: "/nonexistent/deckhold"]))
    }

    func test_committedBinaryMatchesProvenance() throws {
        let bin = packageRoot.appendingPathComponent("Sources/DozerKit/Resources/deckhold")
        let doc = try String(contentsOf: packageRoot.appendingPathComponent("Guest/deckhold/PROVENANCE.md"), encoding: .utf8)
        let sha = SHA256.hash(data: try Data(contentsOf: bin)).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(doc.contains("| sha256 (auto) | `\(sha)` |"), "run `make deckhold` (or Scripts/deckhold-provenance.sh) after changing the binary")
    }

    /// 610: a wake brings this build's deckhold to the guest by RENAME (a running holder keeps its own file), only when
    /// the staged copy is exactly this build's — run here against a scratch copy of the script's paths.
    func test_aWakeReplacesTheGuestsDeckholdByRenameOnlyWhenItIsThisBuilds() throws {
        let bin = try XCTUnwrap(DeckholdBinary.locate(environment: [:]))
        let sha = try XCTUnwrap(Sandbox.digest(bin))
        XCTAssertEqual(sha, SHA256.hash(data: try Data(contentsOf: bin)).map { String(format: "%02x", $0) }.joined())
        let script = GuestCommand.refreshDeckholdScript(sha256: sha)
        XCTAssertTrue(script.contains("mv -f \(GuestCommand.deckholdStagingPath) \(GuestCommand.deckholdPath)"), "a rename, never a write into the running file")
        XCTAssertTrue(GuestCommand.deckholdStagingPath.hasPrefix("/usr/local/bin/."), "staged beside it (same filesystem: the rename is atomic), hidden from PATH lookups")
        // Run it on the Mac with the paths moved into a scratch folder and sha256sum played by shasum.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-unit-dh-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "#!/bin/sh\nexec /usr/bin/shasum -a 256 \"$@\"\n".write(to: dir.appendingPathComponent("bin/sha256sum"), atomically: true, encoding: .utf8)
        chmod(dir.appendingPathComponent("bin/sha256sum").path, 0o755)
        func run(_ staged: Data?) throws -> (String, Data?) {
            let live = dir.appendingPathComponent("deckhold"), new = dir.appendingPathComponent(".deckhold.doz-new")
            try Data("old".utf8).write(to: live)
            if let staged { try staged.write(to: new) } else { try? FileManager.default.removeItem(at: new) }
            let local = script.replacingOccurrences(of: GuestCommand.deckholdStagingPath, with: new.path)
                .replacingOccurrences(of: GuestCommand.deckholdPath, with: live.path)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", local]
            p.environment = ["PATH": dir.appendingPathComponent("bin").path + ":/usr/bin:/bin"]
            let o = Pipe()
            p.standardOutput = o
            try p.run()
            p.waitUntilExit()
            let out = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertFalse(FileManager.default.fileExists(atPath: new.path), "the staged copy never stays")
            return (out.trimmingCharacters(in: .whitespacesAndNewlines), try? Data(contentsOf: live))
        }
        let good = try run(try Data(contentsOf: bin))
        XCTAssertEqual(good.0, "deckhold=updated")
        XCTAssertEqual(good.1, try Data(contentsOf: bin))
        let bad = try run(Data("truncated".utf8))
        XCTAssertEqual(bad.0, "deckhold=refused")
        XCTAssertEqual(bad.1, Data("old".utf8), "a copy that is not this build's never replaces the guest's")
    }
}
