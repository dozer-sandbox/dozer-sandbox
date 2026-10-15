import XCTest
@testable import DozerKit

/// 618: a tool that takes its model only from its own settings file (Crush's `models.large`) gets the chosen source's
/// there at EVERY run (`first_run` `each_run`), each `$DOZ_…` the run's own — never a key: the file names the variable
/// the placeholder is in, and the tool expands it.
final class RecipeEachRunTests: XCTestCase {
    func testCrushSetsItsModelAtEveryRunAndNeverWritesAKey() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("no python3") }
        let r = try XCTUnwrap(AgentRecipes.recipe("crush"))
        XCTAssertEqual(r.launch.firstRun?.filter { $0.eachRun == true }.count, 1)
        let py = AgentImages.recipeSetupPython(r.launch.firstRun!)
        XCTAssertTrue(py.contains("def set_json"))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("eachrun-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let script = home.appendingPathComponent("setup.py")
        try py.write(to: script, atomically: true, encoding: .utf8)
        func run(_ env: [String: String]) throws -> [String: Any] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [script.path]
            p.environment = ["HOME": home.path].merging(env) { a, _ in a }
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
            let data = try Data(contentsOf: home.appendingPathComponent(".config/crush/crush.json"))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        func large(_ c: [String: Any]) -> String? { ((c["models"] as? [String: Any])?["large"] as? [String: Any])?["model"] as? String }
        // No source chosen: the first-run defaults only.
        var c = try run([:])
        XCTAssertEqual(large(c), "grok-build-0.1")
        XCTAssertNil(c["providers"])
        // OpenRouter, then Anthropic: set each time, over what was there.
        let gw = try XCTUnwrap(r.selection(source: "openrouter"))
        c = try run(gw.env.merging(["OPENROUTER_API_KEY": "doz_cred_PLACEHOLDER", "OPENAI_API_KEY": "doz_cred_PLACEHOLDER"]) { a, _ in a })
        XCTAssertEqual(large(c), "openai/gpt-5.4-mini")
        let doz = try XCTUnwrap((c["providers"] as? [String: Any])?["doz"] as? [String: Any])
        XCTAssertEqual(doz["base_url"] as? String, "https://openrouter.ai/api/v1")
        XCTAssertEqual(doz["type"] as? String, "openai-compat")
        XCTAssertEqual(doz["api_key"] as? String, "$OPENAI_API_KEY", "the variable's name, for Crush to expand")
        XCTAssertEqual((doz["models"] as? [[String: Any]])?.first?["id"] as? String, "openai/gpt-5.4-mini")
        let an = try XCTUnwrap(r.selection(source: "anthropic"))
        c = try run(an.env)
        XCTAssertEqual(large(c), "claude-sonnet-4-6")
        XCTAssertEqual(((c["providers"] as? [String: Any])?["doz"] as? [String: Any])?["type"] as? String, "anthropic")
        XCTAssertEqual((c["options"] as? [String: Any])?["disable_metrics"] as? Bool, true, "the first-run keys stay")
        let text = try String(contentsOf: home.appendingPathComponent(".config/crush/crush.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("doz_cred_"), "never a key or a placeholder")
    }

    func testTheDeclarationIsChecked() throws {
        let base = try XCTUnwrap(AgentRecipes.recipe("crush"))
        XCTAssertNoThrow(try base.validate())
        func refused(_ change: (inout AgentRecipe.FirstRun) -> Void, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
            var r = base
            let i = r.launch.firstRun!.firstIndex { $0.eachRun == true }!
            change(&r.launch.firstRun![i])
            XCTAssertThrowsError(try r.validate(), why, file: file, line: line)
        }
        refused({ $0.file = "~/.config/crush/crush.toml" }, "a JSON file")
        refused({ $0.set["providers.doz.api_key"] = .string("$DOZ_API_KEY") }, "never a credential's value")
        refused({ $0.set["x"] = .string("$DOZ_NOT_SET") }, "every models@1 entry sets each one")
        refused({ $0.set = ["x": .string("y")] }, "it names the model")
        // Only such a recipe's helper has it.
        for r in AgentRecipes.all where r.launch.firstRun?.contains(where: { $0.eachRun == true }) != true {
            if let f = r.launch.firstRun, !f.isEmpty { XCTAssertFalse(AgentImages.recipeSetupPython(f).contains("set_json"), r.id) }
        }
    }
}
