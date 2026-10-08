import ArgumentParser
import Foundation
@testable import DozerKit
import XCTest
@testable import DozerCLI
@testable import DozerHost

/// 611 — the public build flavor, BOTH modes in one test run: no Dozer-own ChatGPT sign-in (the CLI, the host,
/// an existing account kept but never used) and no experimental audio; the private flavor keeps both.
final class BuildFlavorTests: XCTestCase {
    private var root: URL!
    let keychain = FakeKeychain()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-flavor-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("DOZ_TEST_PUBLIC_BUILD")
        try? FileManager.default.removeItem(at: root)
    }

    func core(_ flavor: BuildFlavor) async -> HostCore {
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let c = HostCore(store: DozerStore(root: root), readOnly: false, version: "test", services: s)
        await c.load()
        await c.setBuildFlavor(flavor)
        return c
    }

    func testTheFlavorIsTheCompiledOneUnlessTheTestSeamSaysOtherwise() {
        XCTAssertEqual(BuildFlavor.from([:], compiled: .privateBuild), .privateBuild)
        XCTAssertEqual(BuildFlavor.from([:], compiled: .publicBuild), .publicBuild)
        XCTAssertEqual(BuildFlavor.from(["DOZ_TEST_PUBLIC_BUILD": "1"], compiled: .privateBuild), .publicBuild)
        XCTAssertEqual(BuildFlavor.from(["DOZ_TEST_PUBLIC_BUILD": "0"], compiled: .publicBuild), .privateBuild)
        XCTAssertEqual(BuildFlavor.from(["DOZ_TEST_PUBLIC_BUILD": "yes"], compiled: .privateBuild), .privateBuild)
        XCTAssertFalse(BuildFlavor.publicBuild.chatgptSignIn)
        XCTAssertTrue(BuildFlavor.privateBuild.chatgptSignIn)
        XCTAssertEqual(BuildFlavor.compiled, .privateBuild, "swift test builds the private flavor (make release PUBLIC=1 compiles the public one)")
    }

    func testTheCLIOffersNoChatGPTSignInInAPublicBuild() {
        XCTAssertEqual(OpenAIChoices.onboarding(macSignedIn: true, flavor: .publicBuild).map(\.value), ["mac", "openai-key", "later"])
        XCTAssertEqual(OpenAIChoices.onboarding(macSignedIn: false, flavor: .publicBuild).map(\.value), ["openai-key", "later"])
        XCTAssertEqual(OpenAIChoices.onboarding(macSignedIn: true, flavor: .privateBuild).map(\.value), ["mac", "chatgpt", "openai-key", "later"])
        XCTAssertEqual(OpenAIChoices.preflightAdds(flavor: .publicBuild).map(\.value), ["openai-key"])
        XCTAssertEqual(OpenAIChoices.preflightAdds(flavor: .privateBuild).map(\.value), ["chatgpt", "openai-key"])
        XCTAssertFalse(OpenAIChoices.laterHint(flavor: .publicBuild).contains("--chatgpt"))
        XCTAssertTrue(OpenAIChoices.laterHint(flavor: .privateBuild).contains("--chatgpt"))
    }

    func testAccountAddChatGPTIsRefusedBeforeAnythingRunsInAPublicBuild() throws {
        setenv("DOZ_TEST_PUBLIC_BUILD", "1", 1)
        XCTAssertThrowsError(try DozerCommand.parseAsRoot(["account", "add", "x", "--chatgpt", "--store", root.path])) { e in
            XCTAssertTrue(DozerCommand.message(for: e).contains("does not include Dozer's own ChatGPT sign-in"), DozerCommand.message(for: e))
            XCTAssertTrue(DozerCommand.message(for: e).contains("--openai-key"), "it says what to use instead")
        }
        XCTAssertThrowsError(try DozerCommand.parseAsRoot(["onboard", "--openai-account", "chatgpt", "--store", root.path]))
        let create = try XCTUnwrap(try DozerCommand.parseAsRoot(["create", "a", "--image", "lab", "--audio", "--store", root.path]) as? Create)
        XCTAssertThrowsError(try create.create.options()) { e in
            XCTAssertTrue("\(e)".contains("does not include the experimental audio"), "\(e)")
        }
        XCTAssertNoThrow(try DozerCommand.parseAsRoot(["account", "add", "x", "--openai-key", "--store", root.path]))
        setenv("DOZ_TEST_PUBLIC_BUILD", "0", 1)
        XCTAssertNoThrow(try DozerCommand.parseAsRoot(["account", "add", "x", "--chatgpt", "--store", root.path]), "the private build keeps it")
    }

    func testTheHostTakesNoChatGPTSignInAndKeepsAnExistingOneUnused() async throws {
        // A private (pre-release) build made the account …
        let made = await core(.privateBuild)
        let t = fakeChatGPTTokens()
        let m0 = await made.handle(HostRequest.accountAdd(name: "plan", kind: .chatgpt, plan: nil, secret: t.json))
        XCTAssertNil(m0.error, m0.error?.message ?? "")
        // … a public build keeps it, never uses it, and says why.
        let c = await core(.publicBuild)
        let m1 = await c.handle(HostRequest.accountAdd(name: "plan2", kind: .chatgpt, plan: nil, secret: t.json))
        XCTAssertTrue(m1.error?.message.contains("does not include Dozer's own ChatGPT sign-in") == true, m1.error?.message ?? "")
        let listed = await c.handle(HostRequest(.accountList))
        let rows = try XCTUnwrap(listed.result).decode([AccountRow].self)
        XCTAssertEqual(rows.first { $0.name == "plan" }?.state, "unsupported")
        XCTAssertNil(rows.first { $0.name == "plan2" })
        XCTAssertNotNil(keychain.get("doz-chatgpt:plan"), "kept — doz account rm removes it")
    }

    func testAnUnsupportedSessionNeverRenewsAndEveryReadSaysWhy() {
        keychain.put("doz-chatgpt:plan", ChatGPTRecord(fakeChatGPTTokens(expiresIn: 10)).json)
        let refreshed = LockedFlag()
        let s = ChatGPTSession(account: "plan", service: "doz-chatgpt:plan", keychain: keychain, refresher: { _ in refreshed.set(); return .unavailable("x") })
        s.unsupported = BuildFlavor.chatgptAccountUnsupported("plan")
        s.load()
        XCTAssertTrue(s.problem()?.contains("ChatGPT sign-in, which this doz does not support") == true)
        let r = s.read()
        XCTAssertNil(r.0)
        XCTAssertTrue(r.1?.contains("doz account rm plan") == true, r.1 ?? "")
        XCTAssertFalse(refreshed.isSet, "a public build never renews it")
    }

    func testAPublicBuildRefusesAnAudioSandboxAndAPrivateOneKeepsIt() async throws {
        var o = CreateOptions(image: "lab")
        o.audio = true
        var r = HostRequest(.create, name: "snd")
        r.create = o
        let pub = await core(.publicBuild)
        let m = await pub.handle(r)
        XCTAssertTrue(m.error?.message.contains("does not include the experimental audio support") == true, m.error?.message ?? "")
        let priv = await core(.privateBuild)
        let m2 = await priv.handle(r)
        XCTAssertTrue(m2.error?.message.contains("does not carry") == true, "the private build gets as far as the kernel: \(m2.error?.message ?? "")")
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.withLock { v = true } }
    var isSet: Bool { lock.withLock { v } }
}
