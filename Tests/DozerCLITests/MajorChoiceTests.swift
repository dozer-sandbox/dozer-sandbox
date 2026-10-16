import ArgumentParser
import Foundation
@testable import DozerKit
import XCTest
@testable import DozerCLI
@testable import DozerHost
import DozerWeb

/// 618: an earlier major (or an exact release) can be chosen everywhere a tool is chosen in the CLI — try, new, create,
/// up (`--agent`, `--image`), a project file's `agent:` — and the plan says which release and how to get the other.
final class MajorChoiceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-majors-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func facts() -> PlanFacts {
        PlanFacts(settings: DozerSettings(text: ""), accounts: AccountsFile(), taken: [], images: [], store: DozerStore(root: root),
                  projectsDir: "/tmp/618-pin-projects")
    }

    func plan(_ purpose: String, _ args: [String]) throws -> CreatePlan {
        CreatePlanner.plan(PlanRequest(purpose: purpose, create: try ChoiceOptions.from(args).planChoices()), facts: facts())
    }

    var recommended: AgentRecipe { AgentRef.recommended("opencode")! }

    func testAgentAndImageTakeAMajorOrARelease() throws {
        let one = try ChoiceOptions.from(["--agent", "opencode@1"]).planChoices()
        XCTAssertEqual(one.image, "opencode")
        XCTAssertEqual(one.agentRef, "opencode@1")
        XCTAssertNil(one.agentVersion)
        let two = try ChoiceOptions.from(["--agent", "opencode@2.0.28"]).planChoices()
        XCTAssertEqual(two.image, "opencode2")
        XCTAssertEqual(two.agentVersion, "2.0.28")
        XCTAssertEqual(two.agentRef, "opencode@2.0.28")
        let img = try ChoiceOptions.from(["--image", "opencode@2"]).planChoices()
        XCTAssertEqual(img.image, "opencode2")
        XCTAssertEqual(img.agentRef, "opencode@2")
        let fam = try ChoiceOptions.from(["--agent", "opencode"]).planChoices()
        XCTAssertEqual(fam.image, recommended.id, "a family's name is its recommended major")
        let based = try ChoiceOptions.from(["--agent", "opencode@2", "--base", "python"]).planChoices()
        XCTAssertEqual(based.image, "python-opencode2")
        XCTAssertThrowsError(try ChoiceOptions.from(["--agent", "opencode@9"]).planChoices()) {
            XCTAssertTrue("\($0)".contains("opencode@1") && "\($0)".contains("opencode@2"), "\($0)")
        }
        // Not a tool: as before.
        XCTAssertEqual(try ChoiceOptions.from(["--image", "lab"]).planChoices().image, "lab")
        XCTAssertNil(try ChoiceOptions.from(["--agent", "grok"]).planChoices().agentRef)
    }

    func testThePlanSaysWhichReleaseAndHowToGetTheOther() throws {
        let p = try plan("try", ["--agent", "opencode@2"])
        XCTAssertEqual(p.argv.prefix(3), ["doz", "try", "opencode@2"])
        let v = try XCTUnwrap(p.version)
        XCTAssertEqual(v.majors.map(\.ref), ["opencode@1", "opencode@2"])
        XCTAssertEqual(v.majors.first(where: \.chosen)?.major, 2)
        XCTAssertEqual(v.version, AgentRecipes.recipe("opencode2")!.install.pinned.version, "never asked: its pin")
        let line = try XCTUnwrap(v.familyLine())
        XCTAssertTrue(line.hasPrefix("OpenCode 2 "), line)
        XCTAssertTrue(line.contains("OpenCode 1"), line)
        XCTAssertTrue(line.contains("doz try opencode@1") || line.contains("doz try opencode"), line)
        XCTAssertFalse(line.lowercased().contains("latest"), "recommended, never latest")
        XCTAssertTrue(renderPlan(p).contains("  version: OpenCode 2"))
        XCTAssertTrue(p.yaml.contains("agent: opencode@2"), p.yaml)
        // A tool that is not a family: its release only.
        let g = try XCTUnwrap(try plan("try", ["--agent", "grok"]).version)
        XCTAssertTrue(g.majors.isEmpty)
        XCTAssertNil(g.familyLine())
        // The command printed for a family member never means another major (its id alone would be the family's).
        let o1 = try plan("create", ["--image", "opencode@1"])
        XCTAssertTrue(o1.argv.contains("opencode@1"), o1.command)
    }

    /// 618 (owner: yes to model keys): `model_source:` and `model:` — read, written, checked against what the agent is
    /// offered, carried into the create; the plan's yaml says them (no more "not project keys" note).
    func testAProjectFileTakesItsModelSourceAndModel() throws {
        let yaml = "version: 1\nname: p\nagent: opencode@2\nmodel_source: openrouter\nmodel: anthropic/claude-sonnet-4.6\n"
        let p = try DozerProject.parse(yaml)
        XCTAssertEqual(p.modelSource, "openrouter")
        XCTAssertEqual(p.model, "anthropic/claude-sonnet-4.6")
        let o = p.createOptions(folder: root, file: root.appendingPathComponent("doz_project.yaml"), settings: DozerSettings(text: ""))
        XCTAssertEqual(o.modelSource, "openrouter")
        XCTAssertEqual(o.model, "anthropic/claude-sonnet-4.6")
        let back = try DozerProject.parse(p.render())
        XCTAssertEqual(back.modelSource, "openrouter")
        XCTAssertEqual(back.model, "anthropic/claude-sonnet-4.6")
        // Refused with the fix: a source that is no source, one the agent is not offered, a model that is no id, an agent
        // with no choice of model.
        XCTAssertThrowsError(try DozerProject.parse("version: 1\nname: p\nagent: opencode@2\nmodel_source: nosuch\n")) {
            XCTAssertTrue("\($0)".contains("line 4") && "\($0)".contains("model_source:"), "\($0)")
        }
        XCTAssertThrowsError(try DozerProject.parse("version: 1\nname: p\nagent: opencode@2\nmodel_source: google\n")) {
            XCTAssertTrue("\($0)".contains("openrouter") && "\($0)".contains("doz models"), "\($0)")
        }
        XCTAssertThrowsError(try DozerProject.parse("version: 1\nname: p\nagent: opencode@2\nmodel: 'a b'\n"))
        XCTAssertThrowsError(try DozerProject.parse("version: 1\nname: p\nagent: claude-code\nmodel_source: anthropic\n")) {
            XCTAssertTrue("\($0)".contains("no choice of model"), "\($0)")
        }
        // An agent with a choice gets the keys as comments; one without does not.
        var plain = DozerProject(name: "p", image: "opencode2")
        plain.agent = "opencode@2"
        XCTAssertTrue(plain.render().contains("# model_source:"), plain.render())
        var cc = DozerProject(name: "p", image: "claude-code")
        cc.agent = "claude-code"
        XCTAssertFalse(cc.render().contains("model_source"))
        // The plan's file says them.
        let planned = try plan("try", ["--agent", "opencode@2", "--gateway", "openrouter", "--model", "anthropic/claude-sonnet-4.6"])
        XCTAssertTrue(planned.yaml.contains("model_source: openrouter"), planned.yaml)
        XCTAssertTrue(planned.yaml.contains("model: anthropic/claude-sonnet-4.6"), planned.yaml)
        XCTAssertNil(planned.yamlNote)
        // doz init writes them.
        let i = try XCTUnwrap(try DozerCommand.parseAsRoot(["init", "--yes", "--name", "p", "--agent", "opencode@2", "--gateway", "openrouter",
                                                          "--model", "x-ai/grok-build-0.1"]) as? Init)
        let made = try i.ask(folder: root, existing: nil, asker: Asker(yes: true, json: false))
        XCTAssertEqual(made.modelSource, "openrouter")
        XCTAssertEqual(made.model, "x-ai/grok-build-0.1")
        XCTAssertThrowsError(try (try XCTUnwrap(try DozerCommand.parseAsRoot(["init", "--yes", "--name", "p", "--agent", "opencode@2", "--provider", "openrouter"]) as? Init))
            .ask(folder: root, existing: nil, asker: Asker(yes: true, json: false)))
        // New Sandbox's form.
        var form = WebProjectForm(made)
        XCTAssertEqual(form.modelSource, "openrouter")
        form.model = "nope nope"
        XCTAssertThrowsError(try form.project())
    }

    func testAProjectFileTakesAMajor() throws {
        XCTAssertNil(DozerProject.agentProblem("opencode@1"))
        XCTAssertNil(DozerProject.agentProblem("opencode@2.0.28"))
        XCTAssertNil(DozerProject.agentProblem("none"))
        XCTAssertNotNil(DozerProject.agentProblem("opencode@9"))
        XCTAssertNotNil(DozerProject.agentProblem("nosuch"))
        let yaml = "version: 1\nname: p\nagent: opencode@1\n"
        let p = try DozerProject.parse(yaml)
        XCTAssertEqual(p.agent, "opencode@1")
        XCTAssertEqual(p.chosenImage, "opencode")
        let o = p.createOptions(folder: root, file: root.appendingPathComponent("doz_project.yaml"), settings: DozerSettings(text: ""))
        XCTAssertEqual(o.agentRef, "opencode@1")
        let exact = try DozerProject.parse("version: 1\nname: p\nagent: opencode@2.0.28\n")
        let e = exact.createOptions(folder: root, file: root.appendingPathComponent("doz_project.yaml"), settings: DozerSettings(text: ""))
        XCTAssertEqual(e.image, "opencode2")
        XCTAssertEqual(e.agentVersion, "2.0.28")
        XCTAssertThrowsError(try DozerProject.parse("version: 1\nname: p\nagent: opencode@9\n"))
        // The file round-trips.
        XCTAssertEqual(try DozerProject.parse(p.render()).agent, "opencode@1")
    }

    /// A project file outlives the try that wrote it: when the recommended major later moves, a file Dozer wrote must
    /// not move with it — so a family's name is written with the major it resolved to. A file written by hand with the
    /// bare name keeps meaning "recommended", and `doz up` says what that resolved to.
    func testAFileWrittenForLaterKeepsItsMajor() throws {
        let pinned = "opencode@\(recommended.family!.major)"
        func agentLine(_ yaml: String) -> String? {
            yaml.split(separator: "\n").first { $0.hasPrefix("agent: ") }.map { String($0.split(separator: "#")[0]).trimmingCharacters(in: .whitespaces) }
        }
        // The plan's doz_project.yaml (doz try / create / up --dry-run, and the dashboard's plan).
        XCTAssertEqual(agentLine(try plan("try", ["--agent", "opencode"]).yaml), "agent: \(pinned)")
        XCTAssertEqual(agentLine(try plan("create", ["--agent", "opencode", "--base", "python"]).yaml), "agent: \(pinned)")
        // An image named by a member's id: that image (its name is one major's, so it never moves either).
        let byImage = try plan("try", ["--image", recommended.id]).yaml
        XCTAssertTrue(agentLine(byImage) == nil && byImage.contains("image: \(recommended.id) "), byImage)
        XCTAssertEqual(agentLine(try plan("try", ["--agent", "opencode@1"]).yaml), "agent: opencode@1")
        XCTAssertEqual(agentLine(try plan("try", ["--agent", "opencode@2.0.28"]).yaml), "agent: opencode@2.0.28")
        // The one rule all three writers share.
        XCTAssertEqual(DozerProject.fileAgent("opencode"), pinned)
        XCTAssertEqual(DozerProject.fileAgent("opencode2"), "opencode@2")
        XCTAssertEqual(DozerProject.fileAgent("opencode@1"), "opencode@1")
        XCTAssertEqual(DozerProject.fileAgent("grok"), "grok")
        XCTAssertEqual(DozerProject.fileAgent("none"), "none")
        // doz init --agent opencode.
        let i = try XCTUnwrap(try DozerCommand.parseAsRoot(["init", "--yes", "--name", "p", "--agent", "opencode"]) as? Init)
        let made = try i.ask(folder: root, existing: nil, asker: Asker(yes: true, json: false))
        XCTAssertEqual(made.agent, pinned)
        XCTAssertEqual(made.image, recommended.id)
        XCTAssertEqual(agentLine(made.render()), "agent: \(pinned)")
        // The dashboard's New Sandbox.
        var form = WebProjectForm(made)
        form.agent = "opencode"
        XCTAssertEqual(try form.project().agent, pinned)
        // By hand: the bare name stays the recommended major, and doz up says which, once, when it is made.
        let hand = try DozerProject.parse("version: 1\nname: p\nagent: opencode\n")
        XCTAssertEqual(hand.agent, "opencode")
        XCTAssertEqual(hand.chosenImage, recommended.id)
        XCTAssertEqual(try DozerProject.parse(hand.render()).agent, "opencode", "rewriting a file keeps what it says")
        let note = try XCTUnwrap(DozerProject.familyNote("opencode"))
        XCTAssertTrue(note.contains("is \(pinned)") && note.contains("write agent: \(pinned)"), note)
        XCTAssertNil(DozerProject.familyNote("opencode@1"))
        XCTAssertNil(DozerProject.familyNote("opencode2"))
        XCTAssertNil(DozerProject.familyNote("grok"))
        XCTAssertNil(DozerProject.familyNote(nil))
        // The agent: comment (and every "--agent: …" message) names families, not members' ids.
        XCTAssertTrue(DozerProject.agentWords.contains("opencode"))
        XCTAssertFalse(DozerProject.agentWords.contains("opencode2"), DozerProject.agentWords)
        XCTAssertFalse(made.render().contains("opencode2"), made.render())
    }

    func testTheListShowsAFamilyOnceAndSearchFindsAMajor() throws {
        let rec = recommended
        let line = searchLine(SearchHit(outcome: "supported", limit: nil, entry: try XCTUnwrap(DirectoryIndex.build(version: "t").entries.first { $0.id == rec.id })),
                              local: nil, base: nil)
        XCTAssertTrue(line.contains("(recommended; also @"), line)
        XCTAssertTrue(line.contains("try it: doz try opencode"), line)
        let other = AgentRef.members("opencode").first { $0.id != rec.id }!
        let o = searchLine(SearchHit(outcome: "supported", limit: nil, entry: try XCTUnwrap(DirectoryIndex.build(version: "t").entries.first { $0.id == other.id })),
                           local: nil, base: nil)
        XCTAssertTrue(o.contains("try it: doz try opencode@\(other.family!.major)"), o)
        let s = try XCTUnwrap(try DozerCommand.parseAsRoot(["search", "opencode@1"]) as? SearchCommand)
        XCTAssertEqual(s.resolvedTerms, ["opencode"])
    }
}
