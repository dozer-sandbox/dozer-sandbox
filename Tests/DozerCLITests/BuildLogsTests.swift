import Foundation
import DozerKit
import XCTest
@testable import DozerCLI
@testable import DozerHost

/// 617: an image's build log — every line of each bake step, kept per image in the store, rendered inert.
final class BuildLogsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-blog-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testAStepsWholeOutputKeepsEveryLineInOrderInert() {
        let w = StepOutputLines()
        w.add(Data("Get:1 http://deb\nGet:2 ht".utf8))
        w.add(Data("tp://deb\n\u{1B}[31mred\u{1B}[0m\nprogress 10%\rprogress 100%\n".utf8))
        w.add(Data("no newline at the end".utf8))
        XCTAssertEqual(w.finish(), ["Get:1 http://deb", "Get:2 http://deb", "red", "progress 100%", "no newline at the end"])
        XCTAssertEqual(w.finish(), [], "finish empties it")
    }

    func testAStepsOutputIsCappedHeadAndTailWithTheCountSaid() {
        let w = StepOutputLines(head: 2, tail: 3)
        w.add(Data((1...10).map { "l\($0)" }.joined(separator: "\n").appending("\n").utf8))
        XCTAssertEqual(w.finish(), ["l1", "l2", "… 5 lines not kept …", "l8", "l9", "l10"])
    }

    func testTheLogIsKeptPerImageRoundTripsAndIsPrivate() throws {
        let store = DozerStore(root: root)
        let log = BuildLog(image: "node-codex", state: "done", startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                           finishedAt: Date(timeIntervalSince1970: 1_800_000_090), seconds: 90, error: nil,
                           steps: [PreparationStep(label: "step: install codex", kind: "step", seconds: 42)],
                           sections: [.init(label: "step: install codex", lines: ["added 1 package"])])
        BuildLogs.save(log, store: store)
        XCTAssertEqual(BuildLogs.read("node-codex", store: store), log)
        let u = try XCTUnwrap(BuildLogs.url("node-codex", store: store))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: u.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(Resources.classify(["build-logs", "node-codex.json"], currentLabKey: nil), "store", "Dozer's own records")
        XCTAssertNil(BuildLogs.read("pi", store: store))
        for bad in ["../x", "a/b", "", ".hidden", "UPPER", String(repeating: "a", count: 65)] {
            XCTAssertNil(BuildLogs.url(bad, store: store), bad)
        }
    }

    func testTheLogIsCappedNewestSectionsFirst() {
        let big = BuildLog.Section(label: "step: old", lines: Array(repeating: "x", count: BuildLogs.maximumLines))
        let new = BuildLog.Section(label: "step: new", lines: ["a", "b"])
        let l = BuildLogs.capped(BuildLog(image: "pi", state: "done", startedAt: Date(), finishedAt: Date(), seconds: 1, error: nil,
                                          steps: [], sections: [big, new]))
        XCTAssertEqual(l.sections.last, new, "the newest section whole")
        XCTAssertEqual(l.sections.first?.lines.first, "… 2 lines not kept …")
        XCTAssertEqual(l.sections.reduce(0) { $0 + $1.lines.count }, BuildLogs.maximumLines + 1)
    }

    func testTheRenderingIsTheStepsThenTheOutputAndNothingInIsASequence() {
        let l = BuildLog(image: "pi", state: "failed", startedAt: Date(), finishedAt: Date(), seconds: 75, error: "exit 1",
                         steps: [PreparationStep(label: "pulled node", kind: "transfer", seconds: 3),
                                 PreparationStep(label: "step: baseline", kind: "step", seconds: 12.5),
                                 PreparationStep(label: "step: install pi", kind: "failed", seconds: 2, error: "exit \u{1B}]52;c;eA==\u{07}1")],
                         sections: [.init(label: "step: install pi", lines: ["evil \u{1B}]52;c;eA==\u{07}line", "\u{1B}[2Jclear"])])
        let text = BuildLogs.render(l)
        XCTAssertTrue(text.contains("How pi was built"), text)
        XCTAssertTrue(text.contains("1:15"))
        XCTAssertTrue(text.contains("not recorded"), "an earlier doz's log says the commands were not recorded")
        XCTAssertTrue(text.contains("== 1. Install pi =="), text)
        XCTAssertTrue(text.contains("evil line") && text.contains("clear"))
        XCTAssertFalse(text.contains("]52;"), "no OSC from the guest")
        XCTAssertFalse(text.contains("\u{1B}[2J"), "no screen control from the guest")
        XCTAssertFalse(text.contains("\u{07}"))
        XCTAssertTrue(text.contains("\r\n"))
    }

    /// The whole flow without a VM: a preparation's runner hands each step's output to the sink; the log is kept when
    /// it ends — and the output is never an event a client sees.
    func testAPreparationKeepsItsBuildLogWhenItEnds() async throws {
        let store = DozerStore(root: root)
        let c = HostCore(store: store, readOnly: false, version: "t", newStoreDefaultAccount: "mac")
        await c.setPreparationRunner({ image, _, emit in
            emit(HostEvent(kind: .started, sandbox: image, text: "step: install"))
            HostCore.buildOutputSink?(.section("step: install", ["line 1", "line 2"]))
            emit(HostEvent(kind: .step, sandbox: image, text: "step: install", milliseconds: 1500))
        }, prepared: { _, _ in false })
        var r = HostRequest(.onboard)
        r.images = ["claude-code"]
        r.requestedBy = "test"
        r.follow = false
        _ = await c.handle(r)
        var log: BuildLog?
        for _ in 0..<100 where log == nil {
            log = BuildLogs.read("claude-code", store: store)
            if log == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let l = try XCTUnwrap(log, "the build log is kept")
        XCTAssertEqual(l.state, "done")
        XCTAssertEqual(l.sections, [.init(label: "step: install", lines: ["line 1", "line 2"])])
        XCTAssertEqual(l.steps.map(\.label), ["step: install"])
    }

    // MARK: 617 — how the image was made, every command verbatim

    private func geminiPlan() throws -> (ImageSpec, BakePlan) {
        let g = try XCTUnwrap(AgentKind(rawValue: "gemini"))
        let spec = try ImageComposer.spec(name: "debian-gemini", base: BaseCatalogue.base("debian")!.source(), agent: g,
                                          release: AgentRelease(version: "1.2.3", integrity: "sha512-AAAA"), native: nil)
        let plan = ImageBaker.plan(spec, key: String(repeating: "a", count: 64), kernelFile: "vmlinux-6.18.15-186", kernelSHA256: String(repeating: "b", count: 64),
                                   initfsReference: "ghcr.io/apple/containerization/vminit:0.47.0", policy: NetworkPolicy.bake,
                                   networkEnvironment: ["HTTPS_PROXY": "http://127.0.0.1:3128"], cpus: 4, memoryMiB: 2048)
        return (spec, plan)
    }

    /// The owner's rule: the build log shows every command and script exactly as it ran — taken from the spec, verbatim.
    func testARecordedBuildLogHoldsEveryStepsScriptVerbatim() throws {
        let store = DozerStore(root: root)
        let (spec, plan) = try geminiPlan()
        XCTAssertEqual(plan.steps.map(\.argv), spec.steps.map(\.argv), "the plan is the spec's argv, unchanged")
        XCTAssertEqual(plan.checks.map(\.argv), spec.verify.map(\.argv))
        let steps = spec.steps.map { PreparationStep(label: "step: " + $0.name, kind: "step", seconds: 1) }
        BuildLogs.save(BuildLog(image: "debian-gemini", state: "done", startedAt: Date(), finishedAt: Date(), seconds: 60, error: nil,
                                steps: steps, sections: [.init(label: "step: " + spec.steps[0].name, lines: ["Get:1 http://deb.debian.org"])], plan: plan), store: store)
        let log = try XCTUnwrap(BuildLogs.read("debian-gemini", store: store))
        let doc = BuildLogs.document(log)
        XCTAssertTrue(doc.recorded)
        XCTAssertEqual(doc.steps.count, spec.steps.count)
        let text = BuildLogs.plainText(doc)
        for (i, step) in spec.steps.enumerated() {
            let script = step.argv.last!
            XCTAssertEqual(doc.steps[i].script.joined(separator: "\n"), script, "\(step.name): verbatim")
            for line in script.components(separatedBy: "\n") where !line.isEmpty {
                XCTAssertTrue(text.contains(line), "\(step.name): the CLI's text has \(line)")
            }
        }
        // The inputs, and plain titles (display only).
        XCTAssertTrue(doc.inputs.contains { $0.label == "Base image" && $0.value == spec.base })
        XCTAssertTrue(doc.inputs.contains { $0.label == "Recipe" && $0.value.contains("@google/gemini-cli 1.2.3") && $0.value.contains("sha512-AAAA") })
        XCTAssertTrue(doc.inputs.contains { $0.label == "Guest init" && $0.value.hasSuffix("vminit:0.47.0") })
        XCTAssertFalse(doc.policy.isEmpty, "the bake network policy's rules")
        let titles = doc.steps.map(\.title)
        XCTAssertTrue(titles.contains("Install the developer baseline"), titles.joined(separator: " | "))
        XCTAssertTrue(titles.contains("Install Gemini CLI 1.2.3"), titles.joined(separator: " | "))
        XCTAssertTrue(titles.contains("Install the launcher"), titles.joined(separator: " | "))
        XCTAssertTrue(doc.checks.map(\.title).contains("Check: apt's package lists are kept"), doc.checks.map(\.title).joined(separator: " | "))
        // The files a step writes: the launcher, its path and contents.
        let launcher = try XCTUnwrap(doc.steps.flatMap(\.files).first { $0.path == "/home/agent/.local/bin/gemini" })
        XCTAssertTrue(launcher.lines.contains { $0.contains("exec /usr/local/bin/gemini") })
        XCTAssertEqual(doc.steps.first?.output, ["Get:1 http://deb.debian.org"])
        XCTAssertTrue(doc.steps[0].environment.contains { $0.label == "HTTPS_PROXY" }, "the environment as passed")
    }

    /// Nothing secret-shaped is ever kept in a build log — not in a command, an environment or the output.
    func testNothingSecretShapedReachesTheLog() throws {
        let store = DozerStore(root: root)
        var (_, plan) = try geminiPlan()
        let secrets = ["sk-ant-api03-SECRETSECRETSECRET", "AIzaSyD-FAKEFAKEFAKEFAKEFAKE12", "xai-SECRETSECRETSECRET12",
                       "ghp_0123456789abcdefghijABCDEFGHIJ", "doz_cred_abcdef123456", "eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.SflKxwRJSMeKKF2QT4",
                       "AKIAABCDEFGHIJKLMNOP", "pa55word"]
        plan.steps[0].argv[plan.steps[0].argv.count - 1] += "\ncurl -H 'Authorization: Bearer abcdefghijklmnop1234' https://u:pa55word@example.com # \(secrets[0])"
        plan.steps[0].environment["SOME_VALUE"] = secrets[1]
        plan.steps[0].environment["GITHUB_TOKEN"] = "anything"
        plan.checks[0].argv.append(secrets[2])
        BuildLogs.save(BuildLog(image: "debian-gemini", state: "failed", startedAt: Date(), finishedAt: Date(), seconds: 1,
                                error: "exit 1 \(secrets[3])", steps: [], sections: [.init(label: "step: x", lines: [secrets[6]])], plan: plan), store: store)
        let raw = try String(contentsOf: XCTUnwrap(BuildLogs.url("debian-gemini", store: store)), encoding: .utf8)
        for s in secrets { XCTAssertFalse(raw.contains(s), "kept: \(s)") }
        XCTAssertFalse(raw.contains("abcdefghijklmnop1234"))
        XCTAssertFalse(raw.contains("GITHUB_TOKEN"), "a credential-named variable is not kept at all")
        XCTAssertTrue(raw.contains("[redacted]"))
        XCTAssertTrue(raw.contains("sha512-AAAA"), "an integrity is not a secret: it stays")
        // And what is shown is scrubbed too (a log written by anything else).
        let shown = BuildLogs.render(BuildLog(image: "x", state: "done", startedAt: Date(), finishedAt: Date(), seconds: 1, error: nil,
                                              steps: [], sections: [.init(label: "step: a", lines: [secrets[4], secrets[5]])], plan: nil))
        for s in [secrets[4], secrets[5]] { XCTAssertFalse(shown.contains(s), s) }
    }

    func testTheHostReadsALogByImageForTheCLI() async throws {
        let store = DozerStore(root: root)
        let (_, plan) = try geminiPlan()
        BuildLogs.save(BuildLog(image: "debian-gemini", state: "done", startedAt: Date(), finishedAt: Date(), seconds: 1, error: nil,
                                steps: [], sections: [], plan: plan), store: store)
        let c = HostCore(store: store, readOnly: true, version: "t", newStoreDefaultAccount: "mac")
        var r = HostRequest(.buildLog)
        r.image = "debian-gemini"
        let ok = await c.handle(r)
        let log = try XCTUnwrap(ok.result).decode(BuildLog.self)
        XCTAssertEqual(log.plan?.image, "debian-gemini")
        r.image = "../etc"
        let bad = await c.handle(r)
        XCTAssertNil(bad.result, "not an image name")
        r.image = "pi"
        let none = await c.handle(r)
        XCTAssertNil(none.result, "none kept")
    }
}
