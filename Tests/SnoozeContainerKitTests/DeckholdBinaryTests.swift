import CryptoKit
import XCTest
@testable import SnoozeContainerKit

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
        let bin = packageRoot.appendingPathComponent("Sources/SnoozeContainerKit/Resources/deckhold")
        let doc = try String(contentsOf: packageRoot.appendingPathComponent("Guest/deckhold/PROVENANCE.md"), encoding: .utf8)
        let sha = SHA256.hash(data: try Data(contentsOf: bin)).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(doc.contains("| sha256 (auto) | `\(sha)` |"), "run `make deckhold` (or Scripts/deckhold-provenance.sh) after changing the binary")
    }
}
