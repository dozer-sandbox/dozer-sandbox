import Foundation
import XCTest
@testable import DozerKit

/// 617: the icon registry (`Recipes/icons/`) — every file in the manifest and compiled in, every mono file the one
/// allowed shape, every lettermark exactly what `Lettermark` draws, every recipe resolving to a mark.
final class AgentIconsTests: XCTestCase {
    static let folder: URL = {
        var u = URL(fileURLWithPath: #filePath)
        while u.path != "/" {
            u.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: u.appendingPathComponent("Package.swift").path) { break }
        }
        return u.appendingPathComponent("Sources/DozerKit/Recipes/icons")
    }()

    /// A lettermark file is generated: a missing or empty one is WRITTEN and the test fails (review, commit, re-run);
    /// a different one fails (the generator or the spec moved — delete the file to draw it again).
    func testEveryLettermarkIsExactlyWhatTheGeneratorDraws() throws {
        for e in AgentIconsTests.manifest() where e.allowed == "lettermark" {
            let spec = try XCTUnwrap(e.lettermark, e.id)
            let u = AgentIconsTests.folder.appendingPathComponent(e.variants.mono)
            let want = Lettermark.svg(spec)
            let have = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
            if have.isEmpty {
                try Data(want.utf8).write(to: u, options: .atomic)
                XCTFail("\(e.variants.mono): drawn — review and commit it, then re-run")
                continue
            }
            XCTAssertEqual(have, want, "\(e.variants.mono) is not what Lettermark draws for \(spec)")
        }
    }

    func testTheFolderTheManifestAndThePackageAgree() throws {
        let onDisk = Set(try FileManager.default.contentsOfDirectory(atPath: AgentIconsTests.folder.path).filter { $0.hasSuffix(".svg") })
        XCTAssertEqual(onDisk, Set(AgentIcons.files.keys), "every SVG in Recipes/icons is compiled in (AgentIcons.files + Package.swift)")
        let listed = Set(AgentIconsTests.manifest().map(\.variants.mono))
        XCTAssertEqual(onDisk, listed, "every SVG is in icons.json, and every entry's file exists")
        let pkg = try String(contentsOf: AgentIconsTests.folder.appendingPathComponent("../../../../Package.swift").standardizedFileURL, encoding: .utf8)
        for f in onDisk.sorted() { XCTAssertTrue(pkg.contains("\"Recipes/icons/\(f)\""), "Package.swift embeds \(f)") }
        XCTAssertNoThrow(try AgentIcons.validate(AgentIcons.all, files: AgentIcons.files))
    }

    func testAMonoFileIsOnePathInCurrentColourAndNothingElse() throws {
        let ok = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M2 2L22 22Z" fill="currentColor"/></svg>"#
        XCTAssertEqual(try MonoSVG.check(ok).d, "M2 2L22 22Z")
        let refused = [
            ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M2 2L22 22Z" fill="#000"/></svg>"##,
            ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M2 2L22 22Z" fill="currentColor"/><script>x()</script></svg>"##,
            ##"<svg xmlns="http://www.w3.org/2000/svg"><path d="M2 2L22 22Z" fill="currentColor"/></svg>"##,
            ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M2 2L22 22Z" fill="url(#g)"/></svg>"##,
            ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M2 2L22 22Z" fill="currentColor"/><path d="M1 1Z" fill="currentColor"/></svg>"##,
            ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><text>A</text></svg>"##,
            ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M2 2L22 22Z" fill="currentColor" onload="x()"/></svg>"##,
        ]
        for r in refused { XCTAssertThrowsError(try MonoSVG.check(r), r) }
        for e in AgentIcons.all { XCTAssertNoThrow(try MonoSVG.check(String(decoding: AgentIcons.files[e.variants.mono]!, as: UTF8.self)), e.id) }
    }

    func testEveryRecipeResolvesToAMarkAndNothingIsEverBlank() {
        for r in AgentRecipes.all {
            let m = AgentIcons.resolve(r)
            XCTAssertEqual(m.kind, "product", "\(r.id) names its product")
            XCTAssertEqual(m.id, r.icon)
            XCTAssertFalse(m.d.isEmpty)
            XCTAssertEqual(m.mono, "icons/\(AgentIcons.entry(m.id)!.variants.mono)")
        }
        // No product → the publisher's vendor; no vendor either → a lettermark of the title.
        XCTAssertEqual(AgentIcons.resolve(icon: nil, publisher: "OpenAI", title: "Something").id, "openai")
        XCTAssertEqual(AgentIcons.resolve(icon: "nope", publisher: "Google", title: "Something").id, "google")
        let g = AgentIcons.resolve(icon: nil, publisher: "Someone", title: "zed agent")
        XCTAssertEqual(g.id, "letter-z")
        XCTAssertEqual(g.kind, "generated")
        XCTAssertTrue(g.d.count > 60, "a frame and a letter")
        XCTAssertNil(g.mono)
        XCTAssertEqual(AgentIcons.generated("42").id, "letter-none", "no letter: the frame alone, never blank")
    }

    func testAProductNamesAVendorAndOfficialMarksRecordTheirTerms() throws {
        for e in AgentIcons.all {
            XCTAssertNotNil(e.terms, "\(e.id): the brand terms checked")
            if e.kind == "product", let v = e.vendor { XCTAssertEqual(AgentIcons.entry(v)?.kind, "vendor") }
        }
        var bad = AgentIcons.all
        bad[0].allowed = "official"
        bad[0].source = "made up"
        XCTAssertThrowsError(try AgentIcons.validate(bad, files: AgentIcons.files))
        var stray = AgentIcons.files
        stray["stray.svg"] = Array(Lettermark.svg(.init(text: "S", frame: "square")).utf8)
        XCTAssertThrowsError(try AgentIcons.validate(AgentIcons.all, files: stray), "a file in no entry")
        // Colour has room in the schema (accepted, not drawn): a `color` variant decodes.
        let json = #"{"id":"x1","kind":"vendor","name":"X","variants":{"mono":"a.svg","color":"a-color.svg","color-dark":"a-dark.svg"},"source":"s","allowed":"lettermark","checked":"2026-10-13"}"#
        let e = try JSONDecoder().decode(IconEntry.self, from: Data(json.utf8))
        XCTAssertEqual(e.variants.colorDark, "a-dark.svg")
    }

    func testARecipeMayNameOnlyAProduct() throws {
        var r = try XCTUnwrap(AgentRecipes.recipe("grok"))
        r.id = "grok-icon-test"; r.aliases = nil; r.network.model.id = "model:grok-icon-test"
        r.icon = "xai"
        XCTAssertThrowsError(try AgentRecipes.validate(AgentRecipes.all + [r]), "a vendor is not a product")
        r.icon = "nothing-here"
        XCTAssertThrowsError(try AgentRecipes.validate(AgentRecipes.all + [r]))
    }

    static func manifest() -> [IconEntry] {
        struct F: Decodable { var icons: [IconEntry] }
        let d = (try? Data(contentsOf: folder.appendingPathComponent("icons.json"))) ?? Data()
        return (try? JSONDecoder().decode(F.self, from: d).icons) ?? []
    }
}
