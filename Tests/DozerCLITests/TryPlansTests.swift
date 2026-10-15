import Foundation
@testable import DozerKit
import XCTest
@testable import DozerHost

/// 617 (owner: Quick try "a blank modal with a considerable delay"): `plans` — every try planned on ONE reading of the
/// store's facts — answers exactly what `plan` answers for each, in order, and refuses what `plan` refuses.
final class TryPlansTests: XCTestCase {
    private var root: URL!
    let keychain = FakeKeychain()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-plans-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func core() async -> HostCore {
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let c = HostCore(store: DozerStore(root: root), readOnly: false, version: "test", services: s)
        await c.load()
        return c
    }

    func testPlansAnswerWhatEachPlanAnswers() async throws {
        let c = await core()
        _ = await c.handle(HostRequest.keyAccountAdd(name: "xai1", provider: "xai", secret: "xai-FAKE0123456789abcdef"))
        let agents = ["grok", "fabric", "codex", "claude-code", "llm"]
        let rs = agents.map { a -> PlanRequest in
            var o = CreateOptions(image: "")
            o.image = ImageChoice(base: AgentRecipes.recipe(a)?.defaultBase ?? "node", agent: AgentKind(rawValue: a) ?? .none).name
            return PlanRequest(purpose: "try", name: nil, create: o)
        }
        var q = HostRequest(.plans)
        q.planRequests = rs
        let m = await c.handle(q)
        XCTAssertNil(m.error, m.error?.message ?? "")
        let all = try XCTUnwrap(m.result).decode([CreatePlan].self)
        XCTAssertEqual(all.count, rs.count)
        for (r, p) in zip(rs, all) {
            var one = HostRequest(.plan)
            one.planRequest = r
            let am = await c.handle(one)
            let alone = try XCTUnwrap(am.result).decode(CreatePlan.self)
            XCTAssertEqual(p, alone, r.create.image)
        }
        XCTAssertTrue(HostOp.plans.isReadOnly, "answered in-process when no host runs, like plan")
        // Refused: too many, or a purpose plan refuses.
        q.planRequests = Array(repeating: rs[0], count: 129)
        let refused = await c.handle(q)
        XCTAssertNotNil(refused.error)
        var bad = rs[0]
        bad.purpose = "nope"
        q.planRequests = [bad]
        let refused2 = await c.handle(q)
        XCTAssertNotNil(refused2.error)
    }
}
