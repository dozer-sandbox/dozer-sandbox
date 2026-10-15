import Foundation
@testable import DozerKit
import XCTest
@testable import DozerCLI
@testable import DozerHost
@testable import DozerWeb

/// 617 (owner: "yes - split them, also use tags to classify them"): every recipe and every known entry declares what it
/// is — a coding agent or an AI tool, and its categories — from one vocabulary (tags.json); search, `doz try`'s list,
/// the Quick try and New Sandbox read them.
final class CategoriesTests: XCTestCase {
    func testTheVocabulary() throws {
        XCTAssertNoThrow(try Categories.validate())
        XCTAssertEqual(Categories.kinds.map(\.id), ["coding-agent", "ai-tool"])
        XCTAssertEqual(Categories.all.map(\.id), ["coding-agent", "personal-agent", "terminal-tool", "framework", "browser-agent", "mcp", "research",
                                                  "evaluation", "workflow", "local-models", "chat-app"])
        for c in Categories.all { XCTAssertNil(CapabilityTags.tag(c.id), "\(c.id) is not also a capability tag") }
        // The schema's enum is the vocabulary.
        let schema = try String(contentsOf: Pins.packageRoot.appendingPathComponent("schema/dozer-recipe-2.schema.json"), encoding: .utf8)
        XCTAssertTrue(schema.contains(Categories.all.map { "\"\($0.id)\"" }.joined(separator: ", ")), "the schema lists exactly the categories, in order")
        XCTAssertThrowsError(try Categories.validate(kinds: [CatalogWord(id: "ai-tool", title: "x", meaning: "y")], categories: Categories.all))
        XCTAssertThrowsError(try Categories.validate(kinds: Categories.kinds, categories: Categories.all + [CatalogWord(id: "headless", title: "x", meaning: "y")]),
                             "a capability tag's name")
    }

    func testEveryRecipeAndKnownEntryDeclaresWhatItIs() throws {
        for r in AgentRecipes.all {
            XCTAssertNoThrow(try Categories.validate(kind: r.catalogKind, categories: r.categories, what: r.id))
        }
        for k in KnownThings.all {
            XCTAssertNoThrow(try Categories.validate(kind: k.kind, categories: k.categories, what: k.id))
        }
        let kindOf = Dictionary(uniqueKeysWithValues: AgentRecipes.all.map { ($0.id, $0.catalogKind ?? "") })
        for id in ["claude-code", "pi", "codex", "grok", "gemini", "opencode"] { XCTAssertEqual(kindOf[id], "coding-agent", id) }
        for id in ["fabric", "llm", "shell-gpt", "aichat", "smolagents", "promptfoo", "openclaw"] { XCTAssertEqual(kindOf[id], "ai-tool", id) }
        XCTAssertEqual(AgentRecipes.recipe("promptfoo")?.categories, ["evaluation"])
        XCTAssertEqual(KnownThings.all.first { $0.id == "ollama" }?.categories, ["local-models"])
        // The rules.
        XCTAssertThrowsError(try Categories.validate(kind: nil, categories: ["mcp"], what: "x"), "a kind is required")
        XCTAssertThrowsError(try Categories.validate(kind: "tool", categories: ["mcp"], what: "x"))
        XCTAssertThrowsError(try Categories.validate(kind: "ai-tool", categories: [], what: "x"), "a category is required")
        XCTAssertThrowsError(try Categories.validate(kind: "ai-tool", categories: ["mcp", "mcp"], what: "x"), "each once")
        XCTAssertThrowsError(try Categories.validate(kind: "ai-tool", categories: ["coding-agent"], what: "x"), "a coding agents' category")
        XCTAssertThrowsError(try Categories.validate(kind: "coding-agent", categories: ["mcp"], what: "x"), "an AI tools' category")
        XCTAssertNoThrow(try Categories.validate(kind: "coding-agent", categories: ["coding-agent", "personal-agent"], what: "x"), "either kind's")
        var r = try XCTUnwrap(AgentRecipes.recipe("llm"))
        r.categories = ["nope"]
        XCTAssertThrowsError(try r.validate())
    }

    func testSearchFiltersByKindAndCategoryComingIncluded() {
        let index = DirectoryIndex.build(version: "test")
        func ids(_ tags: [String]) -> Set<String> { Set(DirectorySearch.search(SearchQuery.parse([], tags: tags), in: index).hits.map(\.entry.id)) }
        let tools = ids(["terminal-tool"])
        XCTAssertTrue(tools.isSuperset(of: ["llm", "shell-gpt", "aichat", "ai-shell"]), "shipped and coming")
        XCTAssertFalse(tools.contains("grok"))
        XCTAssertTrue(ids(["mcp"]).isSuperset(of: ["mcp-inspector", "toolhive"]))
        XCTAssertTrue(ids(["coding-agent"]).isSuperset(of: ["claude-code", "aider"]))
        XCTAssertTrue(ids(["ai-tool", "evaluation"]).isSuperset(of: ["promptfoo", "garak"]))
        XCTAssertEqual(ids(["ai-tool", "coding-agent"]).filter { id in AgentRecipes.recipe(id)?.catalogKind == "ai-tool" }, [], "both: AND")
        XCTAssertEqual(index.entries.first { $0.id == "fabric" }?.catalogKind, "ai-tool")
        XCTAssertEqual(categoryLine(kind: "ai-tool", categories: ["personal-agent", "terminal-tool"]), "AI tool · personal agent, terminal tool")
        XCTAssertNoThrow(try SearchCommand.parse(["--tag", "local-models"]).validate())
        XCTAssertThrowsError(try SearchCommand.parse(["--tag", "nonsense"]).validate())
        XCTAssertNoThrow(try TryCommand.parse(["--tag", "ai-tool"]).validate())
        XCTAssertThrowsError(try TryCommand.parse(["--tag", "nonsense"]).validate())
        XCTAssertThrowsError(try TryCommand.parse(["grok", "--tag", "ai-tool"]).validate(), "a list filter — not with an agent")
    }
}
