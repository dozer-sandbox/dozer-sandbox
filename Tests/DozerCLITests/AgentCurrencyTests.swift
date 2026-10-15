import Foundation
import XCTest
@testable import DozerKit
@testable import DozerHost
@testable import DozerWeb

/// 617 (owner: "record the latest version and how old it is and is it current"): what is MEASURED (the latest
/// release, its date, a deprecation — the host's registry cache), what is RECORDED (a recipe's lifecycle), and how the
/// lists show both. Fixed documents only — never the registry.
final class AgentCurrencyTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-10-12T00:00:00Z")!
    func daysAgo(_ n: Int) -> Date { now.addingTimeInterval(-Double(n) * 86_400) }

    func testFreshnessFromTheCache() {
        func rec(_ v: String, released: Date?, deprecated: String? = nil, info: String? = nil) -> AgentVersionRecord {
            var r = AgentVersionRecord(latest: AgentRelease(version: v, integrity: "sha512-AAAA"), checkedAt: now)
            r.latestReleased = released; r.latestDeprecated = deprecated; r.infoVersion = info ?? v
            return r
        }
        let active = AgentCurrency.make(agent: "a", record: rec("1.0.0", released: daysAgo(10)), lifecycle: .current, now: now)
        XCTAssertEqual(active.freshness, "active")
        XCTAssertEqual(active.ageDays, 10)
        XCTAssertEqual(AgentCurrency.make(agent: "a", record: rec("1.0.0", released: daysAgo(100)), lifecycle: .current, now: now).freshness, "quiet")
        XCTAssertEqual(AgentCurrency.make(agent: "a", record: rec("1.0.0", released: daysAgo(200)), lifecycle: .current, now: now).freshness, "stale")
        XCTAssertEqual(AgentCurrency.make(agent: "a", record: rec("1.0.0", released: daysAgo(5), deprecated: "use b"), lifecycle: .current, now: now).freshness,
                       "deprecated", "deprecated overrides a recent release")
        // The facts belong to the version they were looked up for: a newer latest without them says nothing yet.
        let newer = AgentCurrency.make(agent: "a", record: rec("1.1.0", released: daysAgo(400), info: "1.0.0"), lifecycle: .current, now: now)
        XCTAssertEqual(newer.freshness, "unknown")
        XCTAssertNil(newer.released)
        // Never checked: said.
        XCTAssertEqual(AgentCurrency.make(agent: "a", record: nil, lifecycle: .current, now: now).line, "latest: not checked yet")
        // A manifest release's build part is not what a person reads.
        let agy = AgentCurrency.make(agent: "a", record: rec("1.3.3+5524738307653632", released: daysAgo(2)), lifecycle: .current, now: now)
        XCTAssertEqual(agy.latest, "1.3.3")
        XCTAssertTrue(agy.line.hasPrefix("latest 1.3.3 · released 10 Oct 2026 (2 days ago) · active"), agy.line)
    }

    func testTheRegistryDocumentAndTheManifestAreRead() throws {
        let doc = Data(#"{"time":{"0.63.0":"2026-09-30T10:00:00.000Z"},"versions":{"0.63.0":{"deprecated":"Gemini CLI is retired — use Antigravity CLI"}}}"#.utf8)
        let info = NpmRegistry.parseReleaseInfo(doc, version: "0.63.0")
        XCTAssertEqual(info.released, ISO8601DateFormatter().date(from: "2026-09-30T10:00:00Z"))
        XCTAssertEqual(info.deprecated, "Gemini CLI is retired — use Antigravity CLI")
        XCTAssertNil(NpmRegistry.parseReleaseInfo(Data("{}".utf8), version: "1.0.0").released)

        let r = try XCTUnwrap(AgentRecipes.recipe("antigravity"))
        let hex = String(repeating: "ab", count: 64)
        let good = Data(#"{"version":"1.3.3","url":"https://storage.googleapis.com/antigravity-public/antigravity-cli/1.3.3-5524738307653632/linux-arm/cli_linux_arm64.tar.gz","sha512":"\#(hex)"}"#.utf8)
        let rel = try NpmRegistry.parseManifest(good, recipe: r)
        XCTAssertEqual(rel.version, "1.3.3+5524738307653632")
        XCTAssertTrue(rel.isWellFormed)
        XCTAssertEqual(AgentImages.manifestArchiveURL(r, rel), "https://storage.googleapis.com/antigravity-public/antigravity-cli/1.3.3-5524738307653632/linux-arm/cli_linux_arm64.tar.gz")
        let elsewhere = Data(#"{"version":"1.3.3","url":"https://example.com/1.3.3-1/x.tar.gz","sha512":"\#(hex)"}"#.utf8)
        XCTAssertThrowsError(try NpmRegistry.parseManifest(elsewhere, recipe: r), "an archive the recipe does not name is refused")
        XCTAssertThrowsError(try NpmRegistry.parseManifest(Data(#"{"version":"1.3.3"}"#.utf8), recipe: r))
    }

    func testTheLifecycleIsRecordedAndChecked() throws {
        let g = try XCTUnwrap(AgentRecipes.recipe("gemini")?.lifecycle)
        XCTAssertEqual(g.status, "superseded")
        XCTAssertEqual(g.by, "antigravity")
        XCTAssertNoThrow(try AgentLifecycle.validate(recipes: AgentRecipes.all, known: KnownThings.all))
        XCTAssertNoThrow(try KnownThings.validate(KnownThings.all))
        var bad = try XCTUnwrap(AgentRecipes.recipe("gemini"))
        bad.lifecycle = AgentLifecycle(status: "superseded", by: "nobody", note: "x")
        XCTAssertThrowsError(try AgentLifecycle.validate(recipes: [bad], known: []), "by names no recipe")
        bad.lifecycle = AgentLifecycle(status: "superseded", note: "x")
        XCTAssertThrowsError(try AgentLifecycle.validate(recipes: [bad], known: []), "superseded needs by")
        bad.lifecycle = AgentLifecycle(status: "retired")
        XCTAssertThrowsError(try AgentLifecycle.validate(recipes: [bad], known: []), "retired says why")
        bad.lifecycle = AgentLifecycle(status: "sleeping", note: "x")
        XCTAssertThrowsError(try AgentLifecycle.validate(recipes: [bad], known: []))
        // The index carries it, and a superseded agent comes after the current ones.
        let index = DirectoryIndex.build(version: "0.34.0")
        let agents = index.entries.filter { $0.kind == "agent" && $0.status == "supported" }.map(\.id)
        XCTAssertEqual(agents.last, "gemini")
        XCTAssertLessThan(agents.firstIndex(of: "antigravity")!, agents.firstIndex(of: "gemini")!)
        XCTAssertEqual(index.entries.first { $0.id == "gemini" }?.lifecycle?.by, "antigravity")
    }
}
