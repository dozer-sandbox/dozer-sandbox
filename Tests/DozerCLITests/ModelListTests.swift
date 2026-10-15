import ArgumentParser
import Foundation
import XCTest
@testable import DozerKit
@testable import DozerCLI
@testable import DozerHost
import DozerWeb

/// 618: the models a source offers — a gateway's public list read by the host (strictly, capped, a day's cache, a
/// back-off), a provider's checked default, `doz models`, and the `--model` note.
final class ModelListTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-models-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func fixture(_ source: String) throws -> Data {
        try Data(contentsOf: Pins.packageRoot.appendingPathComponent("Tests/Fixtures/models/\(source).json"))
    }

    // MARK: decoding

    func testOpenRoutersListIsDecodedStrictlyAndCapped() throws {
        let ms = try ModelLists.parse(try fixture("openrouter"), source: "openrouter")
        let ids = Set(ms.map(\.id))
        XCTAssertTrue(ids.contains("openai/gpt-5.4-mini"))
        XCTAssertTrue(ids.contains("acme/variable"))
        XCTAssertFalse(ids.contains("acme/image-maker"), "a model that answers with no text is not offered")
        XCTAssertFalse(ids.contains("bad id with spaces"), "an id that is not a model id is dropped")
        XCTAssertEqual(ms.count, 8, "the rest of the list survives a bad entry: \(ms.map(\.id))")
        let mini = try XCTUnwrap(ms.first { $0.id == "openai/gpt-5.4-mini" })
        XCTAssertEqual(mini.maker, "OpenAI")
        XCTAssertEqual(mini.name, "GPT-5.4 Mini", "\"Maker: Name\" is split")
        XCTAssertEqual(mini.context, 400_000)
        XCTAssertEqual(mini.pricePerMillionIn, 0.25)
        XCTAssertEqual(mini.pricePerMillionOut, 2)
        XCTAssertEqual(mini.tools, true)
        let v = try XCTUnwrap(ms.first { $0.id == "acme/variable" })
        XCTAssertNil(v.pricePerMillionIn, "a variable price (-1) is no price")
        XCTAssertEqual(v.tools, false)
        XCTAssertEqual(v.name, "Variable Price", "control and direction characters removed: \(v.name.unicodeScalars.map { $0.value })")
        XCTAssertEqual(ms.map(\.name), ms.map(\.name).sorted { $0.lowercased() < $1.lowercased() } , "sorted by name")
        XCTAssertThrowsError(try ModelLists.parse(Data("{\"models\":[]}".utf8), source: "openrouter"))
        XCTAssertThrowsError(try ModelLists.parse(Data("<html>".utf8), source: "openrouter"))
        XCTAssertThrowsError(try ModelLists.parse(try fixture("openrouter"), source: "xai"), "a provider publishes no list here")
        // Long text is capped.
        let long = String(repeating: "x", count: 500)
        let doc = "{\"data\":[{\"id\":\"a/b\",\"name\":\"\(long)\",\"context_length\":-5,\"pricing\":{\"prompt\":\"5\"}}]}"
        let one = try XCTUnwrap(try ModelLists.parse(Data(doc.utf8), source: "openrouter").first)
        XCTAssertLessThanOrEqual(one.name.count, 120)
        XCTAssertNil(one.context)
        XCTAssertNil(one.pricePerMillionIn, "a price of 5 dollars a token is not a price")
    }

    func testVercelsListKeepsLanguageModels() throws {
        let ms = try ModelLists.parse(try fixture("vercel-ai-gateway"), source: "vercel-ai-gateway")
        XCTAssertFalse(ms.contains { $0.id == "acme/embed-1" }, "an embedding model is not offered")
        let mini = try XCTUnwrap(ms.first { $0.id == "openai/gpt-5.4-mini" })
        XCTAssertEqual(mini.maker, "openai")
        XCTAssertEqual(mini.tools, true)
        XCTAssertEqual(mini.context, 400_000)
        XCTAssertEqual(mini.pricePerMillionOut, 2)
        XCTAssertEqual(ms.count, 7)
    }

    // MARK: the cache and the back-off

    func testWhenAListIsReadAgain() {
        let now = Date()
        XCTAssertTrue(ModelLists.due(nil, now: now))
        XCTAssertFalse(ModelLists.due(ModelListRecord(fetchedAt: now.addingTimeInterval(-3600)), now: now))
        XCTAssertTrue(ModelLists.due(ModelListRecord(fetchedAt: now.addingTimeInterval(-25 * 3600)), now: now))
        XCTAssertTrue(ModelLists.due(ModelListRecord(fetchedAt: now.addingTimeInterval(-3600)), now: now, force: true), "asked for")
        let failed = ModelListRecord(fetchedAt: now.addingTimeInterval(-30 * 3600), failedAt: now.addingTimeInterval(-60))
        XCTAssertFalse(ModelLists.due(failed, now: now), "a failure a minute ago: not again yet")
        XCTAssertFalse(ModelLists.due(failed, now: now, force: true), "not even when asked")
        XCTAssertTrue(ModelLists.due(failed, now: now.addingTimeInterval(700)), "after the back-off")
    }

    final class Reads: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
        var fail = false
        func next() -> (Int, Bool) { lock.lock(); defer { lock.unlock() }; count += 1; return (count, fail) }
    }

    func testTheHostReadsAGatewaysListOnceADayAndKeepsItOffline() async throws {
        let data = try fixture("openrouter")
        let reads = Reads()
        let c = HostCore(store: DozerStore(root: root), readOnly: false, version: "test", services: .forHost())
        await c.setModelListFetcher(ModelListFetcher { s in
            let (_, fail) = reads.next()
            XCTAssertEqual(s, "openrouter")
            if fail { throw HostError(.unavailable, "offline") }
            return data
        })
        var r = HostRequest(.models)
        r.modelsSource = "openrouter"
        var m = await c.handle(r)
        var l = try XCTUnwrap(try XCTUnwrap(m.result).decode([ModelList].self).first)
        XCTAssertEqual(l.kind, "fetched")
        XCTAssertEqual(l.models.count, 8)
        XCTAssertNotNil(l.fetchedAt)
        XCTAssertEqual(l.defaultModel, "openai/gpt-5.4-mini")
        XCTAssertEqual(reads.count, 1)
        _ = await c.handle(r)
        XCTAssertEqual(reads.count, 1, "a day's cache")
        // Asked to read again, offline: the last list stays, and the failure is kept (no read again at once).
        reads.fail = true
        r.modelsRefresh = true
        m = await c.handle(r)
        l = try XCTUnwrap(try XCTUnwrap(m.result).decode([ModelList].self).first)
        XCTAssertNil(m.error, "offline is silent")
        XCTAssertEqual(l.models.count, 8)
        XCTAssertEqual(reads.count, 2)
        _ = await c.handle(r)
        XCTAssertEqual(reads.count, 2, "the back-off")
        let rec = try XCTUnwrap(ModelLists.all(DozerStore(root: root))["openrouter"])
        XCTAssertNotNil(rec.failedAt)
        XCTAssertTrue(rec.lastError?.contains("offline") == true)
        // The store holds the list, not the raw document.
        let raw = try String(contentsOf: ModelLists.fileURL(DozerStore(root: root)), encoding: .utf8)
        XCTAssertFalse(raw.contains("supported_parameters"))
        // In-process (no host): the cache only, never a read.
        let looker = HostCore(store: DozerStore(root: root), readOnly: true, version: "test", services: .forHost())
        var q = HostRequest(.models)
        q.modelsSource = "openrouter"
        q.modelsRefresh = true
        let seen = await looker.handle(q)
        XCTAssertEqual(try XCTUnwrap(seen.result).decode([ModelList].self).first?.models.count, 8)
        XCTAssertEqual(reads.count, 2)
        XCTAssertTrue(HostOp.models.isReadOnly)
    }

    func testAProviderOffersItsCheckedDefaultAndAGatewayNeverReadSaysSo() async throws {
        let c = HostCore(store: DozerStore(root: root), readOnly: true, version: "test", services: .forHost())
        let m = await c.handle(HostRequest(.models))
        let all = try XCTUnwrap(m.result).decode([ModelList].self)
        XCTAssertEqual(all.map(\.source), ModelSources.ids)
        let x = try XCTUnwrap(all.first { $0.source == "xai" })
        XCTAssertEqual(x.kind, "default")
        XCTAssertEqual(x.models.map(\.id), [x.defaultModel!])
        let o = try XCTUnwrap(all.first { $0.source == "openrouter" })
        XCTAssertEqual(o.kind, "none")
        XCTAssertTrue(o.gateway)
        var bad = HostRequest(.models)
        bad.modelsSource = "nosuch"
        let refused = await c.handle(bad)
        XCTAssertNotNil(refused.error)
    }

    func testTheSeamNeverReadsTheRealListInATestRun() async throws {
        XCTAssertNil(ModelListFetcher.fromEnvironment(["DOZ_TEST_GUARD": "1"]).read, "a guarded run reads nothing")
        let off = try XCTUnwrap(ModelListFetcher.fromEnvironment(["DOZ_TEST_MODEL_LIST": "offline"]).read)
        do { _ = try await off("openrouter"); XCTFail("offline reads nothing") } catch {}
        let dir = root.appendingPathComponent("lists")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try fixture("openrouter").write(to: dir.appendingPathComponent("openrouter.json"))
        let folder = try XCTUnwrap(ModelListFetcher.fromEnvironment(["DOZ_TEST_MODEL_LIST": dir.path]).read)
        let d = try await folder("openrouter")
        XCTAssertEqual(d, try fixture("openrouter"))
        do { _ = try await folder("vercel-ai-gateway"); XCTFail("no file: no list") } catch {}
        XCTAssertEqual(Set(ModelListFetcher.urls.keys), Set(ModelSources.ids.filter(ModelSources.isGateway)), "every gateway has a published list")
    }

    // MARK: the note and the CLI

    func testAnUnlistedModelGetsADidYouMeanNeverARefusal() throws {
        let l = ModelList(source: "openrouter", title: "OpenRouter", gateway: true, kind: "fetched", fetchedAt: Date(), defaultModel: "openai/gpt-5.4-mini",
                          models: try ModelLists.parse(try fixture("openrouter"), source: "openrouter"))
        XCTAssertEqual(ModelLists.suggestions(for: "openai/gpt-5.4-mni", in: l).first, "openai/gpt-5.4-mini")
        XCTAssertEqual(ModelLists.suggestions(for: "claude-sonnet-5.5", in: l).first, "anthropic/claude-sonnet-5.5")
        XCTAssertEqual(ModelLists.suggestions(for: "openai/gpt-5.4-mini", in: l), [], "listed: nothing to say")
        XCTAssertEqual(ModelLists.suggestions(for: "openai/gpt-5.4-mni", in: l), ["openai/gpt-5.4-mini"], "only close ids")
        XCTAssertEqual(ModelLists.suggestions(for: "zz/qqqqqqqqqqqq", in: l), [], "nothing close: no guess")
        XCTAssertEqual(ModelNote.text(model: "zz/qqqqqqqqqqqq", list: l),
                       "note: zz/qqqqqqqqqqqq is not in OpenRouter's model list (doz models --gateway openrouter; used as given)")
        XCTAssertNil(ModelNote.text(model: "openai/gpt-5.4-mini", list: l), "listed: no note")
        let note = try XCTUnwrap(ModelNote.text(model: "openai/gpt-5.4-mni", list: l))
        XCTAssertTrue(note.contains("did you mean openai/gpt-5.4-mini"), note)
        XCTAssertTrue(note.contains("used as given"), "a note, never a refusal: \(note)")
        XCTAssertTrue(note.contains("doz models --gateway openrouter"), note)
        // A provider's list is its default only: no guessing.
        let p = ModelLists.list("xai", record: nil)
        XCTAssertNil(ModelNote.text(model: "grok-9", list: p))
        XCTAssertEqual(ModelLists.suggestions(for: "grok-9", in: p), [])
    }

    func testDozModels() throws {
        let c = try XCTUnwrap(try DozerCommand.parseAsRoot(["models", "--gateway", "openrouter", "gpt", "mini"]) as? ModelsCommand)
        XCTAssertEqual(c.gateway, "openrouter")
        XCTAssertEqual(c.search, ["gpt", "mini"])
        XCTAssertNoThrow(try DozerCommand.parseAsRoot(["models", "--provider", "xai"]))
        let l = ModelList(source: "openrouter", title: "OpenRouter", gateway: true, kind: "fetched", fetchedAt: Date().addingTimeInterval(-7200),
                          defaultModel: "openai/gpt-5.4-mini", models: try ModelLists.parse(try fixture("openrouter"), source: "openrouter"))
        let text = renderModelLists([l], searched: false)
        XCTAssertTrue(text.hasPrefix("OpenRouter (gateway): 8 models — read 2 hours ago"), text)
        XCTAssertTrue(text.contains("openai/gpt-5.4-mini (default)"), text)
        XCTAssertTrue(text.contains("400K"), text)
        let p = renderModelLists([ModelLists.list("anthropic", record: nil)], searched: false)
        XCTAssertTrue(p.contains("the model Dozer checked — any other id with --model"), p)
        let never = renderModelLists([ModelLists.list("vercel-ai-gateway", record: nil)], searched: false)
        XCTAssertTrue(never.contains("doz models --gateway vercel-ai-gateway --refresh"), never)
    }

    // MARK: the web projection

    func testTheWebProjectionPutsTheDefaultFirst() throws {
        let l = ModelList(source: "openrouter", title: "OpenRouter", gateway: true, kind: "fetched", fetchedAt: Date(), defaultModel: "openai/gpt-5.4-mini",
                          models: try ModelLists.parse(try fixture("openrouter"), source: "openrouter"))
        let w = WebModelList(l)
        XCTAssertEqual(w.models.first?.id, "openai/gpt-5.4-mini")
        XCTAssertEqual(w.models.count, l.models.count)
        XCTAssertEqual(w.models.first?.priceIn, 0.25)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/models/openrouter"), .models("openrouter"))
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/models/nosuch"))
        XCTAssertNil(WebRoute.parse(method: .post, target: "/api/v1/models/openrouter"))
        XCTAssertEqual(WebExposure.kind(.models("xai")), .read)
    }
}
