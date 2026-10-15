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

    /// 617 step 0: Codex's images, pinned BEFORE the agent-recipe refactor (computed at 4b5e9ac + the 617 claim,
    /// VERSION 0.34.0, before any 617 change). Every catalogue base and a Dockerfile's × Codex at its pin: the
    /// canonical JSON's sha256 and the bake key (and the W28 recipe check on the Dockerfile's). The recipe
    /// refactor must leave every byte of these unchanged — a change here re-bakes every Codex image in every store.
    static func codexRecipes() throws -> String {
        let release = AgentImages.codexPinned
        var lines: [String] = []
        for b in BaseCatalogue.all {
            let name = ImageChoice(base: b.id, agent: .codex).name
            let s = try ImageComposer.spec(name: name, base: b.source(), agent: .codex, release: release, native: nil)
            lines.append("\(name) \(sha(String(decoding: s.canonicalJSON, as: UTF8.self))) \(s.bakeKey(kernelSHA256: "k", deckholdSHA256: "d")) \(ImageComposer.recompose(s) == s)")
        }
        let df = BaseSource(reference: "dozer.local/df-0123456789ab@sha256:" + String(repeating: "c", count: 64), packageManager: .auto,
                            hasNode: false, musl: nil, rootfsMiB: 4096, environment: ["X": "1"], path: ["/opt/x/bin"])
        let name = ImageChoice(base: "df-0123456789ab", agent: .codex).name
        let s = try ImageComposer.spec(name: name, base: df, agent: .codex, release: release, native: nil)
        lines.append("\(name) \(sha(String(decoding: s.canonicalJSON, as: UTF8.self))) \(s.bakeKey(kernelSHA256: "k", deckholdSHA256: "d")) \(ImageComposer.recompose(s) == s)")
        // AgentImages.spec("codex") is the Node pair at the pin.
        let node = try XCTUnwrap(AgentImages.spec("codex", release: release))
        lines.append("AgentImages.spec(codex) \(node.bakeKey(kernelSHA256: "k", deckholdSHA256: "d"))")
        return lines.joined(separator: "\n")
    }

    func test_everyCodexImageIsUnchanged() throws {
        // name · sha256 of the canonical JSON · bake key · recompose(spec) == spec
        XCTAssertEqual(try Self.codexRecipes(), """
            codex 28949e1c88846059a661341f9282f894f7b7d4af634d52877c843c230e48b9cc 0c0000c597838c585b92822084b5936f30862ae52cdf919a1fb7446cf4ce9386 true
            python-codex a0f576da0bfee48dab00e3fe5dae718494a3b65cfb0469248f782726770c5cef 80cbc11f1707a9fd2d354bdcc512b137c53c6781794f96844c5540fa0ba05002 true
            go-codex 08ffe3a399c44ac0da0828b5c51a77d724d796b7779a41aa2d793216113e7df6 91519d8aeea92df4002628d95b3fa404c61033e2659901e0a0676292ac855e4c true
            rust-codex 93d3cf288f282d16c661890d2a3f21df23323e1f0b6bc784fdcaa17189253f4e 80743b6b93fb289d5be2cb21b807459a7c6f00d47858fe2b6e2bd040e5c8d036 true
            java-codex 1e320d80bd0d3252aab0a017766a98fcc373ba51f1c7b1d437d4ef8408e02c4f a537ac1d6ac98aecb2f51987423287967d19bbfb3c00f45d9524602d8a0733a3 true
            ruby-codex e7bfbd5edcf6d0bc436883eb02d13c1a4fcf5f18bdf72a7b65c35ef3cb89dfe4 6eb90dc8664c4ab0e4b22fcc3925a0a6415518404f4b78ea80e245222d6c2b74 true
            dotnet-codex ca590af4b72e19dfda92db10b69a87f504d8d51c2134b4e6f32419b54e26f2a1 31755f9d1c169ea650d50324ab0bb0d6383b6d061899472f66948aeae4831793 true
            debian-codex cff6bc5b998d128de18c83977da0e3938985f588f827651e12f1cd10ee1a91e9 bd32a2d6f423a1ce5510a2d4fa5fbd80adc89e68adc8063525cc2bb42eab63aa true
            ubuntu-codex f6ff2c7fc21608d84fbe1693203f33d018e506c70043550c2706f2d26f7cc0e2 738bbb611c2898e628031d2de9ed38067ae6fbbea3c63f2ade21fe2bbeef5aee true
            alpine-codex 1c090ed6e2cabc502d46318cfba17f43c12216422a3ac6cdb39316a4e53e648c ec39fd3e13e3535362c4b9ff48a031440ddeeb719863e25da1ecefca92e5fd9f true
            df-0123456789ab-codex 8a633ef55812831b6d151573d78dcf98a8db7cd856fa0d21b51199ac9b073b22 ce96577343212ba641c13557ffdc0f3303e70796981a60b55c2978e111548e02 true
            AgentImages.spec(codex) 0c0000c597838c585b92822084b5936f30862ae52cdf919a1fb7446cf4ce9386
            """)
        XCTAssertEqual(Self.sha(try Self.codexRecipes()), "2a221cb0d0bea60f83cdcc74b14c14d1a2e007570d0f0c87ed474efec38d5593")
    }

    /// The two Node agent images at their pins, and their bake keys.
    func test_nodeAgentImagesKeepTheirKeys() {
        XCTAssertEqual(AgentImages.claudeCode.bakeKey(kernelSHA256: "k", deckholdSHA256: "d"), "ff020f4b34997d6189fcea996518f4d3fd1979efa807df9fa5f6558d689826c5")
        XCTAssertEqual(AgentImages.pi.bakeKey(kernelSHA256: "k", deckholdSHA256: "d"), "77448e7252340a2243c5ae4224ea7664e9f36fea22f4ebd54a0f7e47f8e1d2cb")
        // 617 step 0: and Codex's Node image at its pin.
        XCTAssertEqual(AgentImages.spec("codex", release: AgentImages.codexPinned)?.bakeKey(kernelSHA256: "k", deckholdSHA256: "d"), "0c0000c597838c585b92822084b5936f30862ae52cdf919a1fb7446cf4ce9386")
    }
}
