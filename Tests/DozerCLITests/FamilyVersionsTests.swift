import Foundation
@testable import DozerKit
import XCTest
@testable import DozerHost

/// 618: a family's majors (OpenCode 1 and 2) — latest stays within a member's major, an exact release asked for one
/// sandbox (`NAME@VERSION`) is checked like a pin before anything is made, and a sandbox records what it was made as.
/// A stubbed registry: never the network.
final class FamilyVersionsTests: XCTestCase {
    var root: URL!
    var store: DozerStore { DozerStore(root: root) }
    let keychain = FakeKeychain()

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/dzfv-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    static func rel(_ v: String) -> AgentRelease {
        AgentRelease(version: v, integrity: "sha512-" + String(repeating: v.hasPrefix("2") ? "B" : "A", count: 86) + "==")
    }

    /// Answers a version that exists (main or platform package), `latest` as `latest`, and lists `versions`.
    final class Stub: @unchecked Sendable {
        let lock = NSLock()
        var latest = "1.19.0"
        var versions = ["1.18.4", "1.19.0", "1.20.1", "1.21.0-beta.1", "2.0.28", "2.0.29"]
        var calls: [String] = []
        var registry: NpmRegistry {
            var r = NpmRegistry { [self] package, tag in
                try lock.withLock {
                    calls.append("\(package)@\(tag)")
                    let v = tag == "latest" ? latest : tag
                    guard versions.contains(v) else { throw HostError(.notFound, "the npm registry answered 404 for \(package)@\(tag)") }
                    return FamilyVersionsTests.rel(v)
                }
            }
            r.versions = { [self] _ in lock.withLock { versions } }
            return r
        }
    }

    func testLatestStaysWithinTheMembersMajor() async throws {
        let stub = Stub()
        stub.latest = "2.0.29"                         // the package's latest left major 1
        let f = await AgentVersions.refresh("opencode", store: store, settings: DozerSettings(text: nil), registry: stub.registry, force: true)
        XCTAssertNil(f.error)
        XCTAssertEqual(AgentVersions.all(store)["opencode"]?.latest?.version, "1.20.1", "the newest stable 1.x — never 2, never a beta")
        XCTAssertEqual(NpmRegistry.newest(in: stub.versions, major: 2), "2.0.29")
        XCTAssertNil(NpmRegistry.newest(in: stub.versions, major: 3))
        // Its latest within major: as it is.
        stub.latest = "1.19.0"
        _ = await AgentVersions.refresh("opencode", store: store, settings: DozerSettings(text: nil), registry: stub.registry, force: true)
        XCTAssertEqual(AgentVersions.all(store)["opencode"]?.latest?.version, "1.19.0")
    }

    func core(_ registry: NpmRegistry) async -> HostCore {
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let c = HostCore(store: store, readOnly: false, version: "test", services: s, agentRegistry: registry)
        await c.load()
        return c
    }

    func exact(_ v: String) -> CreateOptions {
        var o = CreateOptions(image: "opencode2", network: "locked")
        o.agentVersion = v
        o.agentRef = "opencode@\(v)"
        return o
    }

    func testAnExactReleaseIsCheckedBeforeAnythingIsMade() async throws {
        let stub = Stub()
        let c = await core(stub.registry)
        _ = await c.handle(HostRequest.keyAccountAdd(name: "x", provider: "xai", secret: "xai-FAKE0123456789abcdef"))
        // One that does not exist: a plan problem, and a create refuses it — nothing made.
        var q = HostRequest(.plan)
        q.planRequest = PlanRequest(purpose: "try", create: exact("2.0.99"))
        let pm = await c.handle(q)
        let p = try XCTUnwrap(pm.result).decode(CreatePlan.self)
        XCTAssertTrue(p.problems.contains { $0.code == "version" && $0.text.contains("2.0.99") }, "\(p.problems)")
        var bad = HostRequest(.create, name: "oc-bad")
        bad.create = exact("2.0.99")
        let bm = await c.handle(bad)
        XCTAssertNotNil(bm.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.layout("oc-bad").sandboxDirectory.path), "nothing made")
        // One that does: no problem, and the sandbox is made at it and records it.
        q.planRequest = PlanRequest(purpose: "try", create: exact("2.0.28"))
        let okm = await c.handle(q)
        let ok = try XCTUnwrap(okm.result).decode(CreatePlan.self)
        XCTAssertFalse(ok.problems.contains { $0.code == "version" }, "\(ok.problems)")
        var good = HostRequest(.create, name: "oc-28")
        good.create = exact("2.0.28")
        let gm = await c.handle(good)
        XCTAssertNil(gm.error, gm.error?.message ?? "")
        let cfg = try XCTUnwrap(SandboxConfig.read(store.configFile("oc-28")))
        XCTAssertEqual(cfg.agentRef, "opencode@2.0.28")
        XCTAssertEqual(cfg.spec.imageSpec?.agent?.version, "2.0.28")
        XCTAssertEqual(cfg.image, "opencode2")
    }

    /// An existing sandbox never changes major: its stored image name is its recipe's (OpenCode 1 keeps `opencode`), and
    /// a stored name is never resolved as a family — whatever the family recommends now.
    func testAStoredImageNameKeepsItsMajor() throws {
        XCTAssertEqual(ImageChoice.parse("opencode")?.agent.rawValue, "opencode")
        let (spec, _) = try DozerImages.spec(name: "oc1", options: CreateOptions(image: "opencode", network: "locked"), store: store,
                                             environment: ["XDG_CONFIG_HOME": root.path])
        XCTAssertEqual(spec.imageSpec?.agent?.package, "opencode-ai", "OpenCode 1's package")
        XCTAssertEqual(AgentRef.major(of: spec.imageSpec?.agent?.version ?? ""), 1)
        let (spec2, _) = try DozerImages.spec(name: "oc2", options: CreateOptions(image: "opencode2", network: "locked"), store: store,
                                              environment: ["XDG_CONFIG_HOME": root.path])
        XCTAssertEqual(AgentRef.major(of: spec2.imageSpec?.agent?.version ?? ""), 2)
        // What a person types does resolve: the family's name is its recommended major.
        XCTAssertEqual(try AgentRef.resolve("opencode")?.recipe.id, AgentRef.recommended("opencode")?.id)
    }

    func testTheGuideSaysWhichMajorAndHowToGetTheOther() throws {
        let o2 = try XCTUnwrap(AgentRecipes.recipe("opencode2"))
        let g = try XCTUnwrap(SandboxGuide.make(o2, version: "2.0.28", source: nil, model: nil, account: "x", accountKind: .key,
                                                network: "x", workspace: nil, trial: true))
        let v = try XCTUnwrap(g.facts.first { $0.id == "version" }?.value)
        XCTAssertTrue(v.hasPrefix("OpenCode 2 2.0.28"), v)
        XCTAssertFalse(v.contains("Dozer's pin"), "2.0.28 is not the pin: " + v)
        XCTAssertTrue(v.contains("OpenCode 1: doz try opencode"), v)
        XCTAssertFalse(v.lowercased().contains("latest"))
    }

    func testAMajorWithoutAnExactRecordsTheReleaseItGot() async throws {
        let c = await core(.disabled)                  // never asked: the pin
        _ = await c.handle(HostRequest.keyAccountAdd(name: "x", provider: "xai", secret: "xai-FAKE0123456789abcdef"))
        var r = HostRequest(.create, name: "oc1")
        var o = CreateOptions(image: "opencode", network: "locked")
        o.agentRef = "opencode@1"
        r.create = o
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
        let cfg = try XCTUnwrap(SandboxConfig.read(store.configFile("oc1")))
        XCTAssertEqual(cfg.image, "opencode", "OpenCode 1 keeps its id: an existing sandbox never changes major")
        XCTAssertEqual(cfg.agentRef, "opencode@" + AgentRecipes.recipe("opencode")!.install.pinned.version)
    }
}
