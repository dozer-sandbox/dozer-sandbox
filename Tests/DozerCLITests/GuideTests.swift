import Foundation
@testable import DozerKit
import XCTest
@testable import DozerCLI
@testable import DozerHost

/// 617.11 (owner: "i tried fabric and it just gave me a terminal … our companion guide"): guide@1 — every recipe has one,
/// its first step IS the check turn, its commands start with the tool (or a shell builtin); Dozer's facts of a sandbox
/// (`SandboxGuide`); Fabric's patterns baked at the pin.
final class GuideTests: XCTestCase {
    private var root: URL!
    let keychain = FakeKeychain()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-guide-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testEveryRecipeHasAGuideWhoseFirstStepIsItsCheck() throws {
        for r in AgentRecipes.all {
            let g = try XCTUnwrap(r.guide, "\(r.id) has a guide")
            XCTAssertTrue(r.guideMatchesCheck(try XCTUnwrap(g.checkStep?.command)), r.id)
            XCTAssertNotNil(g.docs, "\(r.id): its docs")
        }
        // 617 (owner, 2026-10-15): Antigravity CLI's guide first says what the person meets — Google's terms, theirs to
        // accept — then its check turn; `doz try` says it first, in short.
        let agy = try XCTUnwrap(AgentRecipes.recipe("antigravity")?.guide)
        XCTAssertEqual(agy.steps.first?.text, "Antigravity asks you to accept Google's Terms of Service & Data Use; data sharing is ticked by default and you can untick it.")
        XCTAssertNil(agy.steps.first?.command)
        XCTAssertEqual(agy.checkStep?.command, #"agy -p "say ok""#)
        XCTAssertTrue(agy.notice?.contains("Terms of Service & Data Use") == true)
        // A step without a command before the check is fine; a guide with no command at all is not.
        var r = try XCTUnwrap(AgentRecipes.recipe("antigravity"))
        r.guide?.steps = [.init(text: "Only words.")]
        XCTAssertThrowsError(try r.validate())
        let fabric = try XCTUnwrap(AgentRecipes.recipe("fabric")?.guide)
        XCTAssertEqual(fabric.steps.map(\.command), [#"echo hello | fabric "say ok""#, "fabric -l", #"echo "Dozer runs each agent in its own VM" | fabric -p summarize"#,
                                                     "fabric -p extract_wisdom < notes.md"])
        XCTAssertEqual(fabric.steps.last?.edit, true)
    }

    func testTheFirstStepRule() throws {
        let llm = try XCTUnwrap(AgentRecipes.recipe("llm"))
        XCTAssertTrue(llm.guideMatchesCheck(#"llm "say ok""#))
        XCTAssertTrue(llm.guideMatchesCheck("llm 'say ok'"))
        XCTAssertFalse(llm.guideMatchesCheck("llm say ok"), "two words is another command")
        let smol = try XCTUnwrap(AgentRecipes.recipe("smolagents"))
        XCTAssertTrue(smol.guideMatchesCheck(#"smolagent "say ok" --model-type OpenAIModel --model-id "$DOZ_MODEL" --api-base "$OPENAI_BASE_URL""#),
                      "a template is the variable models@1 sets to it")
        XCTAssertFalse(smol.guideMatchesCheck(#"smolagent "say ok" --model-type OpenAIModel --model-id "$HOME" --api-base "$OPENAI_BASE_URL""#))
        let fabric = try XCTUnwrap(AgentRecipes.recipe("fabric"))
        XCTAssertTrue(fabric.guideMatchesCheck(#"echo hello |  fabric "say ok""#), "sh -c: the same words")
        XCTAssertEqual(AgentRecipe.shellWords(#"a "b c" 'd e' f\ g"#), ["a", "b c", "d e", "f g"])
        XCTAssertNil(AgentRecipe.shellWords(#"a "b"#), "an unfinished quote")
    }

    func testAGuideIsValidated() throws {
        let base = try XCTUnwrap(AgentRecipes.recipe("llm"))
        func refused(_ change: (inout AgentRecipe.Guide) -> Void, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
            var r = base
            change(&r.guide!)
            XCTAssertThrowsError(try r.validate(), why, file: file, line: line) { e in XCTAssertTrue("\(e)".contains("guide"), "\(e)", file: file, line: line) }
        }
        XCTAssertNoThrow(try base.validate())
        refused({ $0.steps[0].command = "llm 'say hi'" }, "the first step is the check")
        refused({ $0.steps[0].edit = true }, "the first step runs as it is")
        refused({ $0.steps.append(.init(text: "x", command: "rm -rf /")) }, "a command starts with the tool or a shell builtin")
        refused({ $0.steps.append(.init(text: "x", command: #"llm "unclosed"#)) }, "its quotes closed")
        refused({ $0.steps.append(.init(text: "x", edit: true)) }, "edit is for a command")
        refused({ $0.steps += Array(repeating: .init(text: "x"), count: 8) }, "at most 8 steps")
        refused({ $0.tips = Array(repeating: "t", count: 7) }, "at most 6 tips")
        refused({ $0.tips = ["an `unclosed tip"] }, "code closed")
        refused({ $0.docs = "http://example.com" }, "https docs")
        refused({ $0.intro = String(repeating: "x", count: 401) }, "a short intro")
        refused({ $0.steps[1].text = "line\u{1b}[31m" }, "no control characters")
        // A recipe may have none (an older one); every shipped one has one (above).
        var none = base
        none.guide = nil
        XCTAssertNoThrow(try none.validate())
    }

    func testFabricsPatternsAreBakedAtThePin() throws {
        let r = try XCTUnwrap(AgentRecipes.recipe("fabric"))
        let e = try XCTUnwrap(r.install.extras?.first)
        XCTAssertEqual(e.to, "/opt/fabric/patterns")
        XCTAssertEqual(r.launch.env["CUSTOM_PATTERNS_DIRECTORY"], "/opt/fabric/patterns")
        let spec = try XCTUnwrap(AgentImages.spec("fabric", release: try XCTUnwrap(r.pinnedRelease)))
        let enc = JSONEncoder()
        enc.outputFormatting = .withoutEscapingSlashes
        let json = String(decoding: try enc.encode(spec), as: UTF8.self)
        XCTAssertTrue(json.contains("codeload.github.com/danielmiessler/fabric/tar.gz/refs/tags/v1.4.518"))
        XCTAssertTrue(json.contains(e.sha256), "checked in the bake")
        XCTAssertTrue(spec.bakeHosts?.contains("codeload.github.com") == true)
        var bad = r
        bad.install.extras![0].to = "/etc/patterns"
        XCTAssertThrowsError(try bad.validate(), "under /opt/<id>/ only")
        bad = r
        bad.install.extras![0].sha256 = "nope"
        XCTAssertThrowsError(try bad.validate())
        // Nothing a bake script would run: no quote or $( in the url or in what it is.
        for u in ["https://codeload.github.com/x'$(touch /tmp/p)'.tar.gz", "https://codeload.github.com/$(id).tar.gz", "https://h/x\".tar.gz"] {
            bad = r
            bad.install.extras![0].url = u
            XCTAssertThrowsError(try bad.validate(), u)
        }
        for w in ["patterns $(id)", "pat'terns", "pat\"terns", "a`b`"] {
            bad = r
            bad.install.extras![0].what = w
            XCTAssertThrowsError(try bad.validate(), w)
        }
        // And the script quotes every recipe string.
        let step = AgentImages.extraInstall(r, e, try XCTUnwrap(r.pinnedRelease)).argv.last!
        XCTAssertTrue(step.contains("label='Fabric'\\''s patterns'"), step)
        XCTAssertFalse(step.contains("\"checksum mismatch for Fabric"), "no recipe string inside double quotes")
    }

    func testTheFactsAreDozersAndTheTextReadsBack() throws {
        let r = try XCTUnwrap(AgentRecipes.recipe("fabric"))
        let g = try XCTUnwrap(SandboxGuide.make(r, version: nil, source: "google", model: "gemini-2.5-flash", account: "google", accountKind: .key,
                                                network: "its model only (Locked)", workspace: "/Users/me/try-fabric", trial: true))
        XCTAssertEqual(g.session, "shell")
        XCTAssertEqual(g.facts.map(\.id), ["version", "model", "network", "folder", "settings"])
        XCTAssertEqual(g.facts[0].value, "Fabric 1.4.518 (Dozer's pin)")
        XCTAssertEqual(g.facts[1].value, "Google AI (Gemini API) · gemini-2.5-flash — your key google stays on the Mac; the sandbox holds a placeholder")
        XCTAssertEqual(g.facts[3].value, "/workspace = /Users/me/try-fabric")
        XCTAssertTrue(g.what.contains("a command-line tool"))
        let text = g.plainText()
        XCTAssertTrue(text.contains("This try\n") && text.contains("Start here\n  1. Check it answers.\n       echo hello | fabric \"say ok\""))
        XCTAssertTrue(g.plainText(stepsOnly: true).hasPrefix("Start here\n"))
        let claude = try XCTUnwrap(SandboxGuide.make(try XCTUnwrap(AgentRecipes.recipe("claude-code")), version: "2.1.300", source: nil, model: nil,
                                                     account: "mac", accountKind: .mac, network: "x", workspace: nil, trial: false))
        XCTAssertEqual(claude.session, "screen")
        XCTAssertEqual(claude.facts[0].value, "Claude Code 2.1.300")
        XCTAssertTrue(claude.facts[1].value.contains("your Claude Code login on this Mac"))
        XCTAssertTrue(claude.facts[3].value.contains("isolated"))
    }

    func core() async -> HostCore {
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let c = HostCore(store: DozerStore(root: root), readOnly: false, version: "test", services: s)
        await c.load()
        return c
    }

    func testASandboxsDetailCarriesItsGuide() async throws {
        let c = await core()
        _ = await c.handle(HostRequest.keyAccountAdd(name: "google", provider: "google", secret: "AIzaFAKE0123456789abcdef"))
        var r = HostRequest(.create, name: "fb")
        r.create = CreateOptions(image: "fabric", network: "locked")
        r.create?.trial = true
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
        let dm = await c.handle(HostRequest(.inspect, name: "fb"))
        let d = try XCTUnwrap(dm.result).decode(SandboxDetail.self)
        let g = try XCTUnwrap(d.guide)
        XCTAssertTrue(g.trial)
        XCTAssertEqual(g.facts.first { $0.id == "model" }?.value,
                       "Google AI (Gemini API) · gemini-2.5-flash — your key google stays on the Mac; the sandbox holds a placeholder")
        XCTAssertEqual(g.facts.first { $0.id == "network" }?.value, "its model only (Locked)")
        // A sandbox with no agent has none.
        var lab = HostRequest(.create, name: "lb")
        lab.create = CreateOptions(image: "lab")
        _ = await c.handle(lab)
        let lm = await c.handle(HostRequest(.inspect, name: "lb"))
        let ld = try XCTUnwrap(lm.result).decode(SandboxDetail.self)
        XCTAssertNil(ld.guide)
    }

    func testDozTrysStartHere() throws {
        let r = try XCTUnwrap(AgentRecipes.recipe("fabric"))
        let s = TryCommand.startHere(r.title, try XCTUnwrap(r.guide), sandbox: "try-fabric")
        XCTAssertTrue(s.contains("Start here (doz guide try-fabric has it all):\n  1. Check it answers.\n       echo hello | fabric \"say ok\"\n"))
        XCTAssertTrue(s.contains("fabric -p extract_wisdom < notes.md    (change it first)"))
        XCTAssertNoThrow(try DozerCommand.parseAsRoot(["guide", "try-fabric", "--json"]))
    }
}
