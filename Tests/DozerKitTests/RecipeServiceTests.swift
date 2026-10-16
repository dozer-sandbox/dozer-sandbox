import XCTest
@testable import DozerKit

/// 618: a recipe's background service (OpenCode 2's `opencode serve --service`) keeps the environment of the run that
/// started it, so the launcher restarts it when a model or source chosen since differs — declared, never per agent.
final class RecipeServiceTests: XCTestCase {
    func testOpenCode2DeclaresItsServiceAndItsLauncherRestartsIt() throws {
        let r = try XCTUnwrap(AgentRecipes.recipe("opencode2"))
        let s = try XCTUnwrap(r.launch.service)
        XCTAssertEqual(s.args, ["serve", "--service"])
        XCTAssertEqual(s.restart, ["service", "restart"])
        XCTAssertEqual(s.start, ["service", "start"])
        XCTAssertEqual(s.env, ["DOZ_MODEL"])
        let sh = AgentImages.recipeLauncherScript(r)
        XCTAssertTrue(sh.contains("[ \"$c\" = 'opencode|serve --service' ] || continue"), sh)
        XCTAssertTrue(sh.contains("s/^DOZ_MODEL=//p"), "it compares DOZ_MODEL")
        XCTAssertTrue(sh.contains("[ -n \"${DOZ_MODEL+x}\" ]"), "only when this run sets it")
        XCTAssertTrue(sh.contains("/usr/local/bin/opencode service restart >/dev/null 2>&1 || /usr/local/bin/opencode service start >/dev/null 2>&1 || echo"))
        XCTAssertTrue(sh.contains("[ -O \"$p\" ]"), "only this user's processes")
        // Before the passthrough: `opencode pair` with another model still meets a fresh service.
        let check = try XCTUnwrap(sh.range(of: "doz_service_check\n"))
        let pass = try XCTUnwrap(sh.range(of: "case \"$1\" in"))
        XCTAssertLessThan(check.lowerBound, pass.lowerBound)
    }

    func testOnlyARecipeThatDeclaresOneGetsTheCheck() {
        for r in AgentRecipes.all where r.launch.service == nil && !r.isBuiltin {
            XCTAssertFalse(AgentImages.recipeLauncherScript(r).contains("doz_service_check"), r.id)
        }
    }

    func testTheDeclarationIsChecked() throws {
        let base = try XCTUnwrap(AgentRecipes.recipe("opencode2"))
        func refused(_ change: (inout AgentRecipe.Launch.Service) -> Void, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
            var r = base
            change(&r.launch.service!)
            XCTAssertThrowsError(try r.validate(), why, file: file, line: line)
        }
        XCTAssertNoThrow(try base.validate())
        refused({ $0.args = [] }, "its arguments")
        refused({ $0.restart = ["service", "re'start"] }, "plain words only: it is written into a shell script")
        refused({ $0.args = ["serve", "$(id)"] }, "no substitution")
        refused({ $0.start = [] }, "a start, when given, says something")
        refused({ $0.env = ["XAI_API_KEY"] }, "a key's placeholder differs per run: never compared")
        refused({ $0.env = ["DOZ_MODEL", "DOZ_MODEL"] }, "once each")
        refused({ $0.env = ["doz model"] }, "a variable name")
    }
}
