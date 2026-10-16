import XCTest
@testable import DozerKit

/// 618: NAME, NAME@MAJOR, NAME@VERSION — what a person types to name a tool (AgentRef.swift), and the family rules.
final class AgentRefTests: XCTestCase {
    func ref(_ s: String) throws -> AgentRef { try XCTUnwrap(try AgentRef.resolve(s)) }

    func testAFamilysNameIsItsRecommendedMajor() throws {
        let rec = try XCTUnwrap(AgentRef.recommended("opencode"))
        let r = try ref("opencode")
        XCTAssertEqual(r.recipe.id, rec.id)
        XCTAssertNil(r.exact)
        XCTAssertEqual(r.text, "opencode")
        XCTAssertEqual(AgentRef.members("opencode").map(\.id), ["opencode", "opencode2"])
        XCTAssertEqual(try ref("OpenCode").recipe.id, rec.id, "case does not matter")
    }

    func testAMajorAndAnExactRelease() throws {
        XCTAssertEqual(try ref("opencode@1").recipe.id, "opencode")
        XCTAssertEqual(try ref("opencode@2").recipe.id, "opencode2")
        let e = try ref("opencode@2.0.28")
        XCTAssertEqual(e.recipe.id, "opencode2")
        XCTAssertEqual(e.exact, "2.0.28")
        XCTAssertEqual(e.text, "opencode@2.0.28")
        XCTAssertEqual(try ref("opencode@1.18.4").recipe.id, "opencode", "a release picks its own major")
        // A member by its own id is that major — never the recommended one.
        let own = try ref("opencode2")
        XCTAssertEqual(own.recipe.id, "opencode2")
        XCTAssertEqual(own.text, "opencode@2")
    }

    func testWhatCannotBeServedSaysTheChoices() {
        XCTAssertThrowsError(try AgentRef.resolve("opencode@9")) { XCTAssertTrue("\($0)".contains("opencode@1") && "\($0)".contains("opencode@2"), "\($0)") }
        XCTAssertThrowsError(try AgentRef.resolve("opencode@3.0.0")) { XCTAssertTrue("\($0)".contains("not @3.0.0"), "\($0)") }
        XCTAssertThrowsError(try AgentRef.resolve("opencode@latest"), "after @ a major or a release")
        XCTAssertThrowsError(try AgentRef.resolve("opencode@2.0"  + "'; rm -rf /"), "never a shell word")
        XCTAssertThrowsError(try AgentRef.resolve("nosuchtool@1"))
        XCTAssertThrowsError(try AgentRef.resolve("@1"))
        // Any tool: its own major only; a pinned-only tool its pin only.
        XCTAssertEqual(try? AgentRef.resolve("grok@1")?.recipe.id, "grok")
        XCTAssertThrowsError(try AgentRef.resolve("grok@7"))
        let fabric = AgentRecipes.recipe("fabric")!.install.pinned.version
        XCTAssertNoThrow(try AgentRef.resolve("fabric@\(fabric)"))
        XCTAssertThrowsError(try AgentRef.resolve("fabric@1.4.1")) { XCTAssertTrue("\($0)".contains("pins"), "\($0)") }
    }

    func testOnlyAToolsNameResolves() throws {
        XCTAssertNil(try AgentRef.resolve("python"), "a base: the caller's")
        XCTAssertNil(try AgentRef.resolve("none"))
        XCTAssertNil(try AgentRef.resolve("my-template"))
        XCTAssertEqual(try ref("claude").recipe.id, "claude-code", "an alias")
    }

    func testWhatASandboxRecordsAndHowAListSaysIt() throws {
        let o2 = try XCTUnwrap(AgentRecipes.recipe("opencode2")), o1 = try XCTUnwrap(AgentRecipes.recipe("opencode"))
        XCTAssertEqual(AgentRef.recorded(o2, version: "2.0.29"), "opencode@2.0.29")
        XCTAssertEqual(AgentRef.recorded(o1, version: "1.19.0+b1"), "opencode@1.19.0")
        XCTAssertEqual(AgentRef.recorded(try XCTUnwrap(AgentRecipes.recipe("grok")), version: nil), "grok")
        let rec = try XCTUnwrap(AgentRef.recommended("opencode"))
        XCTAssertEqual(AgentRef.choicesLine(rec), rec.id == "opencode" ? "recommended; also @2" : "recommended; also @1")
        XCTAssertNil(AgentRef.choicesLine(try XCTUnwrap(AgentRecipes.recipe("grok"))))
        XCTAssertEqual(AgentRef.major(of: "2.0.29"), 2)
        XCTAssertEqual(AgentRef.major(of: "0.160.1"), 0)
    }

    func testAFamilyIsChecked() throws {
        let o1 = try XCTUnwrap(AgentRecipes.recipe("opencode")), o2 = try XCTUnwrap(AgentRecipes.recipe("opencode2"))
        XCTAssertNoThrow(try AgentRecipes.validateFamilies([o1, o2]))
        var a = o1, b = o2
        a.family!.recommended = true; b.family!.recommended = true
        XCTAssertThrowsError(try AgentRecipes.validateFamilies([a, b]), "exactly one recommended")
        a.family!.recommended = false; b.family!.recommended = false
        XCTAssertThrowsError(try AgentRecipes.validateFamilies([a, b]), "exactly one recommended")
        var same = o2
        same.family!.major = 1
        XCTAssertThrowsError(try AgentRecipes.validateFamilies([o1, same]), "each major once")
        var wrongPin = o2
        wrongPin.install.pinned.version = "1.99.0"
        XCTAssertThrowsError(try AgentRecipes.validateFamilies([o1, wrongPin]), "a member pins its own major")
        var renamed = o1
        renamed.family!.family = "oc"
        var renamed2 = o2
        renamed2.family!.family = "oc"
        XCTAssertThrowsError(try AgentRecipes.validateFamilies([renamed, renamed2]), "the family's name is a member's id")
    }
}
