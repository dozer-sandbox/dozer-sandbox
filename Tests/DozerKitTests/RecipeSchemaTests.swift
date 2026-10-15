import Foundation
import XCTest
@testable import DozerKit

/// 617: the recipe format's contract. Every recipe is valid against the published JSON Schema
/// (schema/dozer-recipe-2.schema.json), the Swift loader refuses what the schema refuses, the Kit-shaped view of every
/// recipe is a valid Docker Sandbox Kit v3 descriptor (against Kit's own vendored schema), and the document ⇄ model
/// mapping is lossless. The icon registry's manifest is held to its own schema the same way.
final class RecipeSchemaTests: XCTestCase {
    static let root = AgentRecipeTests.packageRoot
    static let recipeSchema = root.appendingPathComponent("schema/dozer-recipe-2.schema.json")
    static let iconSchema = root.appendingPathComponent("schema/dozer-icons-1.schema.json")
    static let kitSchema = root.appendingPathComponent("Tests/Fixtures/kit-v3/kit.schema.json")
    static let compiled = root.appendingPathComponent("Sources/DozerKit/Recipes/compiled")

    static func trees() throws -> [(String, [String: Any])] {
        try FileManager.default.contentsOfDirectory(atPath: compiled.path).filter { $0.hasSuffix(".json") }.sorted().map { f in
            (f, try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: compiled.appendingPathComponent(f))) as? [String: Any]))
        }
    }

    /// Loads a tree the way Dozer does: the strict decoder, the document's checks, the model's validation.
    static func loads(_ tree: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: tree), let d = try? RecipeDocument.decode(data), let r = try? d.recipe() else { return false }
        return (try? r.validate()) != nil
    }

    func testEveryRecipeIsValidAgainstThePublishedSchema() throws {
        var v = JSONSchemaValidator()
        let all = try Self.trees()
        XCTAssertEqual(all.count, AgentRecipes.compiledFiles.count)
        for (f, t) in all {
            let errors = v.validate(t, schemaFile: Self.recipeSchema)
            XCTAssertTrue(errors.isEmpty, "\(f): \(errors.prefix(8).joined(separator: "\n"))")
            XCTAssertTrue(Self.loads(t), f)
        }
    }

    /// The schema is the contract: what it refuses, the loader refuses; what it accepts (below), the loader accepts.
    func testTheLoaderRefusesWhatTheSchemaRefuses() throws {
        func capIndex(_ t: [String: Any], _ type: String) -> Int { (t["capabilities"] as! [[String: Any]]).firstIndex { $0["type"] as? String == type }! }
        func editCap(_ t: inout [String: Any], _ type: String, _ f: (inout [String: Any]) -> Void) {
            var caps = t["capabilities"] as! [[String: Any]]
            let i = capIndex(t, type)
            f(&caps[i])
            t["capabilities"] = caps
        }
        func editConfig(_ t: inout [String: Any], _ type: String, _ f: (inout [String: Any]) -> Void) {
            editCap(&t, type) { c in var cfg = c["config"] as! [String: Any]; f(&cfg); c["config"] = cfg }
        }
        typealias T = RecipeDocument.Types
        let refused: [(String, (inout [String: Any]) -> Void)] = [
            ("an unknown top-level key", { $0["extra"] = 1 }),
            ("no description", { $0["description"] = nil }),
            ("kind mixin", { $0["kind"] = "mixin" }),
            ("schema 3", { $0["schema"] = 3 }),
            ("an id with capitals", { $0["id"] = "Anthropic/claude-code" }),
            ("a licence that is no SPDX id", { $0["licenses"] = ["the proprietary licence"] }),
            ("provides something else", { $0["provides"] = ["claude-code@1.0.0"] }),
            ("an unknown capability type", { t in var c = t["capabilities"] as! [[String: Any]]; c.append(["type": "com.dozersandbox/nope@1", "config": [:]]); t["capabilities"] = c }),
            ("a second install capability", { t in var c = t["capabilities"] as! [[String: Any]]; c.append(c[capIndex(t, T.install)]); t["capabilities"] = c }),
            ("no launch capability", { t in var c = t["capabilities"] as! [[String: Any]]; c.remove(at: capIndex(t, T.launch)); t["capabilities"] = c }),
            ("a capability name (export's)", { editCap(&$0, T.install) { $0["name"] = "x" } }),
            ("an unknown key in a Kit config", { editConfig(&$0, T.networkPolicy) { $0["extra"] = true } }),
            ("an unknown key in a dozer block", { editConfig(&$0, T.networkPolicy) { c in var d = c["dozer"] as! [String: Any]; d["extra"] = 1; c["dozer"] = d } }),
            ("a network install phase", { editConfig(&$0, T.networkPolicy) { $0["install"] = ["allow": ["registry.npmjs.org:443"]] } }),
            ("a runtime allow without its port", { editConfig(&$0, T.networkPolicy) { c in var r = c["runtime"] as! [String: Any]; var a = r["allow"] as! [String]; a[0] = a[0].replacingOccurrences(of: ":443", with: ""); r["allow"] = a; c["runtime"] = r } }),
            ("a credential's install phase", { editConfig(&$0, T.credential) { $0["phase"] = "install" } }),
            ("a credential the proxy does not manage", { editConfig(&$0, T.credential) { c in var k = c["apiKey"] as! [String: Any]; k["proxyManaged"] = false; c["apiKey"] = k } }),
            ("a volume outside the agent's home", { editConfig(&$0, T.volume) { $0["path"] = "/tmp/x" } }),
            ("an agent-context filename with a slash", { editConfig(&$0, T.agentContext) { $0["filename"] = "a/b.md" } }),
            ("an unknown install kind", { editConfig(&$0, T.install) { $0["kind"] = "curl-pipe-sh" } }),
            ("a launch status of another protocol", { editConfig(&$0, T.launch) { $0["status"] = "loud" } }),
            ("no check (the smoke turn)", { editConfig(&$0, T.launch) { $0["check"] = nil } }),
            ("a check with no argv", { editConfig(&$0, T.launch) { $0["check"] = ["argv": [String](), "expect": "DOZ_FAKE_OK"] } }),
            ("a check that expects nothing", { editConfig(&$0, T.launch) { $0["check"] = ["argv": ["grok", "-p", "x"], "expect": ""] } }),
            ("a check timeout of a day", { editConfig(&$0, T.launch) { $0["check"] = ["argv": ["grok"], "expect": "x", "timeout": 86400] } }),
            ("an unknown key in a check", { editConfig(&$0, T.launch) { $0["check"] = ["argv": ["grok"], "expect": "x", "stdin": "y"] } }),
            ("an unknown auth kind", { editConfig(&$0, T.auth) { c in var m = c["methods"] as! [[String: Any]]; m[0]["kind"] = "password"; c["methods"] = m } }),
            ("an unknown gateway level", { editConfig(&$0, T.gateways) { c in var e = c["entries"] as! [[String: Any]]; if e.isEmpty { e = [["gateway": "openrouter"]] }; e[0]["level"] = "maybe"; c["entries"] = e } }),
            ("an unknown tag level", { editConfig(&$0, T.directory) { c in var tg = c["tags"] as! [[String: Any]]; tg[0]["level"] = "maybe"; c["tags"] = tg } }),
            ("an unknown key in a tag", { editConfig(&$0, T.directory) { c in var tg = c["tags"] as! [[String: Any]]; tg[0]["colour"] = "red"; c["tags"] = tg } }),
        ]
        let accepted: [(String, (inout [String: Any]) -> Void)] = [
            ("another description", { $0["description"] = "Words." }),
            ("a capability's description", { editCap(&$0, T.install) { $0["description"] = "How it is installed." } }),
            ("a check with its exit and timeout", { editConfig(&$0, T.launch) { var c = $0["check"] as? [String: Any] ?? [:]; c["exit"] = 0; c["timeout"] = 300; $0["check"] = c } }),
        ]
        var v = JSONSchemaValidator()
        for (f, original) in try Self.trees() where f == "claude-code.json" || f == "grok.json" {
            for (what, mutate) in refused {
                var t = original
                mutate(&t)
                XCTAssertFalse(v.validate(t, schemaFile: Self.recipeSchema).isEmpty, "\(f): the schema accepts \(what)")
                XCTAssertFalse(Self.loads(t), "\(f): the loader accepts \(what)")
            }
            for (what, mutate) in accepted {
                var t = original
                mutate(&t)
                XCTAssertEqual(v.validate(t, schemaFile: Self.recipeSchema), [], "\(f): \(what)")
                XCTAssertTrue(Self.loads(t), "\(f): \(what)")
            }
        }
    }

    /// Rule 8 (the owner's ruling): the Kit-shaped view of every recipe validates against Kit v3's own published schema,
    /// and keeps Kit's cross-entry rules — so a drift between the two formats fails here first.
    func testTheKitViewOfEveryRecipeIsAValidKitV3Descriptor() throws {
        var v = JSONSchemaValidator()
        for (f, t) in try Self.trees() {
            let doc = try RecipeDocument.decode(JSONSerialization.data(withJSONObject: t))
            let kit = try doc.kitDescriptor()
            let errors = v.validate(kit, schemaFile: Self.kitSchema)
            XCTAssertTrue(errors.isEmpty, "\(f): \(errors.prefix(8).joined(separator: "\n"))")
            let caps = kit["capabilities"] as? [[String: Any]] ?? []
            // §11: every credential inject domain is in the runtime allow list.
            let allow = Set(caps.filter { $0["type"] as? String == RecipeDocument.Types.networkPolicy }
                .flatMap { (($0["config"] as? [String: Any])?["runtime"] as? [String: Any])?["allow"] as? [String] ?? [] }
                .map { $0.replacingOccurrences(of: ":443", with: "") })
            for c in caps where c["type"] as? String == RecipeDocument.Types.credential {
                for i in (((c["config"] as? [String: Any])?["apiKey"] as? [String: Any])?["inject"] as? [[String: Any]]) ?? [] {
                    XCTAssertTrue(allow.contains(i["domain"] as? String ?? ""), "\(f): inject domain \(i["domain"] ?? "") is not allowed")
                }
            }
            // Every ${{ … }} left is a reference to a declared arg; Dozer's own are inert; Dozer's types are optional.
            let text = String(decoding: try JSONSerialization.data(withJSONObject: kit), as: UTF8.self)
            let refs = RecipeDocument.templateNames(text.replacingOccurrences(of: "\\/", with: "/"))
            XCTAssertTrue(refs.allSatisfy { $0 == "kit.args.version" }, "\(f): \(refs)")
            for c in caps where !RecipeDocument.Types.kit.contains(c["type"] as? String ?? "") {
                XCTAssertEqual(c["optional"] as? Bool, true, "\(f): \(c["type"] ?? "") is optional, which a Kit host skips (§7.3)")
            }
            XCTAssertFalse(text.contains("\"dozer\":"), "\(f): no dozer key reaches Kit")
            XCTAssertEqual(kit["schemaVersion"] as? String, "3")
        }
    }

    /// Why export removes the `dozer:` keys: Kit's capability configs are strict too.
    func testKitRefusesADozerKeyLeftInItsOwnCapability() throws {
        var v = JSONSchemaValidator()
        let (_, t) = try XCTUnwrap(try Self.trees().first)
        var kit = try RecipeDocument.decode(JSONSerialization.data(withJSONObject: t)).kitDescriptor()
        var caps = kit["capabilities"] as! [[String: Any]]
        var cfg = caps[0]["config"] as! [String: Any]
        cfg["dozer"] = ["model": ["id": "model"]]
        caps[0]["config"] = cfg
        kit["capabilities"] = caps
        XCTAssertFalse(v.validate(kit, schemaFile: Self.kitSchema).isEmpty)
    }

    /// The document ⇄ model mapping loses nothing: each file is exactly what its model writes back.
    func testTheDocumentAndTheModelMapOneForOne() throws {
        for (f, t) in try Self.trees() {
            let doc = try RecipeDocument.decode(JSONSerialization.data(withJSONObject: t))
            let back = RecipeDocument(try doc.recipe(), vendor: String(doc.id.split(separator: "/")[0]), description: doc.description,
                                      licenses: doc.licenses, versionPattern: doc.args.version.pattern)
            XCTAssertEqual(back, doc, f)
        }
        // The derived Kit parts are the recipe's own: the model's network and its provider.
        let grok = try XCTUnwrap(AgentRecipes.recipe("grok"))
        XCTAssertEqual(RecipeDocument.networkRules(grok).allow, ["api.x.ai:443", "x.ai:443"])
        XCTAssertEqual(RecipeDocument.apiKey("xai")?.inject.map(\.domain), ["api.x.ai"])
        // Templates: Kit's syntax in the file, the model's own inside.
        XCTAssertEqual(RecipeDocument.toModel("grok ${{ kit.args.version }}"), "grok {version}")
        XCTAssertEqual(RecipeDocument.toFile("openrouter/{model}"), "openrouter/${{ dozer.model }}")
        XCTAssertEqual(RecipeDocument.toModel(RecipeDocument.toFile("{gateway.endpoint.v1}")), "{gateway.endpoint.v1}")
        XCTAssertFalse(RecipeDocument.allowedTemplate("kit.env.HOME"), "a recipe has no other template")
    }

    func testTheIconManifestIsHeldToItsSchema() throws {
        var v = JSONSchemaValidator()
        let u = Self.root.appendingPathComponent("Sources/DozerKit/Recipes/icons/icons.json")
        let data = try Data(contentsOf: u)
        let tree = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(v.validate(tree, schemaFile: Self.iconSchema), [])
        XCTAssertEqual(tree["$schema"] as? String, "../../../../schema/dozer-icons-1.schema.json", "editors validate it")
        XCTAssertNoThrow(try AgentIcons.decodeManifest(data))
        // Refused by both: an unknown key, an unknown kind, a lettermark without its letters.
        var icons = tree["icons"] as! [[String: Any]]
        for (what, f) in [("an unknown key", { (e: inout [String: Any]) in e["colour"] = "red" }),
                          ("an unknown kind", { (e: inout [String: Any]) in e["kind"] = "brand" })] as [(String, (inout [String: Any]) -> Void)] {
            var t = tree, e = icons[0]
            f(&e)
            var list = icons
            list[0] = e
            t["icons"] = list
            XCTAssertFalse(v.validate(t, schemaFile: Self.iconSchema).isEmpty, what)
            let d = try JSONSerialization.data(withJSONObject: t)
            XCTAssertThrowsError(try AgentIcons.validate(try AgentIcons.decodeManifest(d), files: AgentIcons.files), what)
        }
        icons[0]["lettermark"] = nil
        var t = tree
        t["icons"] = icons
        XCTAssertFalse(v.validate(t, schemaFile: Self.iconSchema).isEmpty)
        XCTAssertThrowsError(try AgentIcons.validate(try AgentIcons.decodeManifest(JSONSerialization.data(withJSONObject: t)), files: AgentIcons.files))
    }

    /// The validator itself knows every keyword the schemas use (it reports an unknown one), and refuses a known bad.
    func testTheValidatorChecksWhatItIsGiven() throws {
        var v = JSONSchemaValidator()
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("617-schema-\(UUID().uuidString).json")
        try Data(#"{"type":"object","required":["a"],"properties":{"a":{"enum":["x"]}},"additionalProperties":false,"frobnicate":1}"#.utf8).write(to: u)
        defer { try? FileManager.default.removeItem(at: u) }
        let e = v.validate(["a": "y", "b": 1], schemaFile: u)
        XCTAssertTrue(e.contains { $0.contains("frobnicate") }, "\(e)")
        XCTAssertTrue(e.contains { $0.contains("not one of") })
        XCTAssertTrue(e.contains { $0.contains("b is not allowed") })
    }
}
