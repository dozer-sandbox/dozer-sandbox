import Foundation
import XCTest
@testable import DozerCLI
@testable import DozerKit

/// 617: the YAML recipes are the source; `Recipes/compiled/PRODUCT.json` is exactly what each compiles to (`make
/// recipes` writes them: DOZ_WRITE_RECIPES=1), and each compiles to the model Dozer runs.
final class RecipeSourceTests: XCTestCase {
    static let recipes = Pins.packageRoot.appendingPathComponent("Sources/DozerKit/Recipes")

    /// Every `agents/VENDOR/PRODUCT.yaml`, by its relative path.
    static func yamlFiles() throws -> [String] {
        let base = recipes.appendingPathComponent("agents")
        var out: [String] = []
        for vendor in try FileManager.default.contentsOfDirectory(atPath: base.path).sorted() where !vendor.hasPrefix(".") {
            let dir = base.appendingPathComponent(vendor)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            for f in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() where f.hasSuffix(".yaml") { out.append(vendor + "/" + f) }
        }
        return out
    }

    func testTheCompiledRecipesAreExactlyTheYAML() throws {
        let write = ProcessInfo.processInfo.environment["DOZ_WRITE_RECIPES"] == "1"
        let files = try Self.yamlFiles()
        XCTAssertFalse(files.isEmpty)
        var compiledNames: Set<String> = []
        for rel in files {
            let yaml = try String(contentsOf: Self.recipes.appendingPathComponent("agents/" + rel), encoding: .utf8)
            let json = try RecipeSource.compile(yaml: yaml)
            let product = String(rel.split(separator: "/").last!.dropLast(".yaml".count))
            compiledNames.insert(product + ".json")
            let u = Self.recipes.appendingPathComponent("compiled/\(product).json")
            let have = try? Data(contentsOf: u)
            if have != json {
                if write || have == nil {
                    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try json.write(to: u, options: .atomic)
                    if !write { XCTFail("compiled/\(product).json written — review and commit it, then re-run") }
                } else {
                    XCTFail("compiled/\(product).json is not what agents/\(rel) compiles to — run make recipes")
                }
            }
            // The file's id is its path.
            let doc = try RecipeDocument.decode(json)
            XCTAssertEqual(doc.id + ".yaml", rel, "a recipe's id is VENDOR/PRODUCT, its path")
            XCTAssertTrue(yaml.hasPrefix("# yaml-language-server: $schema=../../../../../schema/dozer-recipe-2.schema.json\n"),
                          "\(rel) starts with the editor's schema line")
        }
        let present = Set((try? FileManager.default.contentsOfDirectory(atPath: Self.recipes.appendingPathComponent("compiled").path)) ?? [])
            .filter { $0.hasSuffix(".json") }
        XCTAssertEqual(present, compiledNames, "every compiled file has its YAML, and no other")
    }

    /// Each YAML compiles to exactly the recipe Dozer runs (the model every other test checks).
    func testEachYAMLIsTheRecipeDozerRuns() throws {
        for rel in try Self.yamlFiles() {
            let yaml = try String(contentsOf: Self.recipes.appendingPathComponent("agents/" + rel), encoding: .utf8)
            let r = try RecipeDocument.decode(try RecipeSource.compile(yaml: yaml)).recipe()
            XCTAssertEqual(r, AgentRecipes.recipe(r.id), rel)
        }
        XCTAssertEqual(try Self.yamlFiles().count, AgentRecipes.compiledFiles.count, "one YAML per compiled recipe")
    }

    func testTheYAMLReaderIsCoreSchemaOnlyAndPlainData() throws {
        let tree = try JSONSerialization.jsonObject(with: try RecipeSource.compile(yaml: "a: no\nb: 2026-10-12\nc: true\nd: 3\ne: '3'\nf: on\n")) as? [String: Any]
        XCTAssertEqual(tree?["a"] as? String, "no", "YAML 1.1's no is a word here")
        XCTAssertEqual(tree?["b"] as? String, "2026-10-12", "a date stays a string")
        XCTAssertEqual(tree?["c"] as? Bool, true)
        XCTAssertEqual(tree?["d"] as? Int, 3)
        XCTAssertEqual(tree?["e"] as? String, "3")
        XCTAssertEqual(tree?["f"] as? String, "on")
        XCTAssertThrowsError(try RecipeSource.compile(yaml: "a: &x 1\nb: *x\n"), "no anchors")
        XCTAssertThrowsError(try RecipeSource.compile(yaml: "- a\n- b\n"), "one mapping")
    }

    /// ONE-OFF (617, the move to YAML): DOZ_WRITE_RECIPE_YAML=1 writes each compiled recipe's YAML from the model.
    func testWriteTheYAMLFromTheModel() throws {
        guard ProcessInfo.processInfo.environment["DOZ_WRITE_RECIPE_YAML"] == "1" else { throw XCTSkip("DOZ_WRITE_RECIPE_YAML=1 writes the YAML") }
        let table: [String: (vendor: String, description: String, licenses: [String])] = [
            "claude-code": ("anthropic", "Anthropic's coding agent in your terminal.", ["LicenseRef-proprietary"]),
            "codex": ("openai", "OpenAI's open-source coding agent.", ["Apache-2.0"]),
            "antigravity": ("google", "Google's lead coding agent, on a Gemini API key.", ["LicenseRef-Google-Antigravity-Terms"]),
            "gemini": ("google", "Google's earlier open-source coding agent, superseded by Antigravity CLI.", ["Apache-2.0"]),
            "grok": ("xai", "xAI's coding agent, on an xAI API key.", ["Apache-2.0"]),
            "pi": ("earendil-works", "A small, open-source coding agent that works with many model providers.", ["MIT"]),
        ]
        for r in AgentRecipes.all {
            let t = try XCTUnwrap(table[r.id], r.id)
            let doc = RecipeDocument(r, vendor: t.vendor, description: t.description, licenses: t.licenses)
            let text = try RecipeSource.yaml(doc, schemaPath: "../../../../../schema/dozer-recipe-2.schema.json",
                                             header: "\(r.title) — Dozer's recipe (schema 2). The format: docs/recipes/RECIPE-FORMAT.md.\nEdit this file, then run make recipes (it writes Recipes/compiled/\(r.id).json, which Dozer embeds).")
            let u = Self.recipes.appendingPathComponent("agents/\(t.vendor)/\(r.id).yaml")
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: u, options: .atomic)
            // It reads back to the same model.
            let back = try RecipeDocument.decode(try RecipeSource.compile(yaml: text)).recipe()
            XCTAssertEqual(back, r, r.id)
        }
    }
}
