import CryptoKit
import Foundation
import XCTest
@testable import DozerKit

/// 599i: Codex joined the agents WITHOUT changing any other image. Every catalogue base × Claude Code /
/// pi / none composes to exactly the spec (and so the bake key) it did before 599i — the digest below was
/// computed from the tree at 0a02301 (before any 599i change) with the same inputs.
final class RecipePinTests: XCTestCase {
    static func sha(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func pre599iRecipes() throws -> String {
        let release = AgentRelease(version: "2.1.285", integrity: "sha512-AAAA")
        let native = NativeClaudeBuild(version: "2.1.285", sha256: ["linux-arm64": String(repeating: "a", count: 64),
                                                                    "linux-arm64-musl": String(repeating: "b", count: 64)])
        var lines: [String] = []
        for b in BaseCatalogue.all {
            for a in [AgentKind.claudeCode, .pi, .none] {
                let name = ImageChoice(base: b.id, agent: a).name
                let s = try ImageComposer.spec(name: name, base: b.source(), agent: a, release: a == .none ? nil : release, native: native)
                lines.append("\(name) \(sha(String(decoding: s.canonicalJSON, as: UTF8.self))) \(s.bakeKey(kernelSHA256: "k", deckholdSHA256: "d"))")
            }
        }
        // A Dockerfile's base, and the recipe check (W28) on every one of them.
        let df = BaseSource(reference: "dozer.local/df-0123456789ab@sha256:" + String(repeating: "c", count: 64), packageManager: .auto,
                            hasNode: false, musl: nil, rootfsMiB: 4096, environment: ["X": "1"], path: ["/opt/x/bin"])
        for a in [AgentKind.claudeCode, .pi, .none] {
            let name = ImageChoice(base: "df-0123456789ab", agent: a).name
            let s = try ImageComposer.spec(name: name, base: df, agent: a, release: a == .none ? nil : release, native: native)
            lines.append("\(name) \(sha(String(decoding: s.canonicalJSON, as: UTF8.self))) \(ImageComposer.recompose(s) == s)")
        }
        return lines.joined(separator: "\n")
    }

    func test_everyPre599iImageIsUnchanged() throws {
        XCTAssertEqual(Self.sha(try Self.pre599iRecipes()), "ff4a78e90b0f2eb10efcc8621c18d4a8175dbd75fb0b63d4bdfe1bec8a57708c")
    }

    /// The two Node agent images at their pins, and their bake keys.
    func test_nodeAgentImagesKeepTheirKeys() {
        XCTAssertEqual(AgentImages.claudeCode.bakeKey(kernelSHA256: "k", deckholdSHA256: "d"), "ff020f4b34997d6189fcea996518f4d3fd1979efa807df9fa5f6558d689826c5")
        XCTAssertEqual(AgentImages.pi.bakeKey(kernelSHA256: "k", deckholdSHA256: "d"), "77448e7252340a2243c5ae4224ea7664e9f36fea22f4ebd54a0f7e47f8e1d2cb")
    }
}
