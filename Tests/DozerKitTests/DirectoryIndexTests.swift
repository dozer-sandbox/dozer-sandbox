import Foundation
@testable import DozerKit
import XCTest

/// 617 (616.03 §4.5, D12): the directory index format `dozer-directory/v1` — round trip, determinism, the closed
/// decoder, every recipe and known entry present, no user state, and the known list's own rules.
final class DirectoryIndexTests: XCTestCase {
    func testRoundTripAndDeterminism() throws {
        let a = DirectoryIndex.build(version: "0.34.0")
        let bytes = try a.encoded()
        XCTAssertEqual(try DirectoryIndex.decode(bytes), a)
        XCTAssertEqual(try DirectoryIndex.build(version: "0.34.0").encoded(), bytes, "the same build writes the same bytes")
        XCTAssertEqual(a.format, "dozer-directory/v1")
        XCTAssertEqual(DirectoryIndex.signaturePrefix, "dozer-directory/v1\n")
        // Sorted by kind, then current before superseded/retired (617), then id.
        let order = ["agent": 0, "provider": 1, "base": 2]
        let key = { (e: DirectoryIndex.Entry) in "\(order[e.kind]!)\((e.lifecycle?.isCurrent ?? true) ? 0 : 1)\(e.id)" }
        XCTAssertEqual(a.entries.map(key), a.entries.map(key).sorted())
    }

    func testEveryRecipeKnownProviderAndBaseIsThere() {
        let a = DirectoryIndex.build(version: "0.34.0")
        for r in AgentRecipes.all {
            let e = a.entries.first { $0.kind == "agent" && $0.id == r.id }
            XCTAssertEqual(e?.status, "supported", r.id)
            XCTAssertEqual(e?.tryCommand, "doz try \(r.id)")
            XCTAssertEqual(e?.tags.count, CapabilityTags.all.count, "every tag, at its level — a no is a fact too")
            XCTAssertEqual(e?.gateways.count, Gateways.all.count)
        }
        for k in KnownThings.all {
            let e = a.entries.first { $0.id == k.id }
            XCTAssertEqual(e?.status, k.status)
            XCTAssertNotNil(e?.reason)
            XCTAssertNil(e?.tryCommand)
        }
        for p in KeyProviders.all { XCTAssertTrue(a.entries.contains { $0.kind == "provider" && $0.id == p.id }, p.id) }
        for b in BaseCatalogue.all { XCTAssertTrue(a.entries.contains { $0.kind == "base" && $0.id == b.id }, b.id) }
        let grok = a.entries.first { $0.id == "grok" }!
        XCTAssertEqual(grok.reach?.excluded.contains("auth.x.ai"), true)
        XCTAssertEqual(grok.keys, [DirectoryIndex.KeyRef(provider: "xai", accounts: ["key"])])
        XCTAssertEqual(grok.auth.first?.keysPage, "https://console.x.ai/")
    }

    func testTheDecoderIsClosed() throws {
        let bytes = try DirectoryIndex.build(version: "0.34.0").encoded()
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        obj["extra"] = 1
        XCTAssertThrowsError(try DirectoryIndex.decode(JSONSerialization.data(withJSONObject: obj)), "an unknown top-level field")
        var obj2 = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var entries = try XCTUnwrap(obj2["entries"] as? [[String: Any]])
        entries[0]["haveKey"] = "work-xai"
        obj2["entries"] = entries
        XCTAssertThrowsError(try DirectoryIndex.decode(JSONSerialization.data(withJSONObject: obj2)), "an unknown entry field (user state never fits)")
        var obj3 = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        obj3["format"] = "dozer-directory/v2"
        XCTAssertThrowsError(try DirectoryIndex.decode(JSONSerialization.data(withJSONObject: obj3)))
    }

    func testNoUserStateOrSecretShapedField() throws {
        let text = String(decoding: try DirectoryIndex.build(version: "0.34.0").encoded(), as: UTF8.self)
        for word in ["\"haveKey\"", "\"have_key\"", "\"secret\"", "\"token\"", "\"password\"", "\"keychain\"", NSUserName()] {
            XCTAssertFalse(text.contains(word), word)
        }
    }

    func testTheKnownList() throws {
        XCTAssertNoThrow(try KnownThings.validate(KnownThings.all))
        XCTAssertFalse(KnownThings.all.isEmpty)
        var k = KnownThings.all[0]
        k.id = "grok"
        XCTAssertThrowsError(try KnownThings.validate([k]), "a recipe has it now — the entry must go")
        k.id = "x"
        k.aliases = ["claude"]
        XCTAssertThrowsError(try KnownThings.validate([k]), "an alias a recipe has")
        k.aliases = nil
        k.status = "maybe"
        XCTAssertThrowsError(try KnownThings.validate([k]))
    }

    /// 617: every agent carries its mark (a website draws it from `d`, or fetches `mono` beside the index); providers
    /// with a vendor carry the vendor's; a base none.
    func testEveryAgentCarriesItsMark() throws {
        let i = DirectoryIndex.build(version: "0.0.0")
        for e in i.entries where e.kind == "agent" {
            let m = try XCTUnwrap(e.icon, e.id)
            XCTAssertFalse(m.d.isEmpty, e.id)
            if let f = m.mono { XCTAssertNotNil(AgentIcons.files[String(f.dropFirst("icons/".count))], f) }
        }
        XCTAssertEqual(i.entries.first { $0.kind == "agent" && $0.id == "grok" }?.icon?.id, "grok-build")
        XCTAssertEqual(i.entries.first { $0.kind == "provider" && $0.id == "xai" }?.icon?.id, "xai")
        XCTAssertNil(i.entries.first { $0.kind == "base" }?.icon)
        XCTAssertEqual(try DirectoryIndex.decode(try i.encoded()), i, "the strict decoder reads it back")
    }
}
