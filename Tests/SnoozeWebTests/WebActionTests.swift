import Foundation
import SnoozeContainerKit
import SnoozeHost
import XCTest
@testable import SnoozeWeb

/// 590 phase 2 — the typed actions: each is exactly one HostOp, decoded strictly, destructive ones
/// confirmed; the policy preview, the Terminal hand-off, the CSV defence, the metrics query.
final class WebActionTests: XCTestCase {
    func decode(_ json: String) throws -> WebAction { try WebAction.decode(Data(json.utf8)) }

    func invalid(_ json: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try decode(json), json, file: file, line: line) { XCTAssertTrue($0 is WebAction.Invalid, "\($0)", file: file, line: line) }
    }

    /// A valid body for every action name.
    static let samples: [String: String] = [
        "create": #"{"action":"create","sandbox":"new1","image":"lab","cpus":2,"memoryMiB":1024,"network":"bake","account":"default"}"#,
        "start": #"{"action":"start","sandbox":"a"}"#, "wake": #"{"action":"wake","sandbox":"a"}"#,
        "pause": #"{"action":"pause","sandbox":"a"}"#, "resume": #"{"action":"resume","sandbox":"a"}"#,
        "sleep": #"{"action":"sleep","sandbox":"a"}"#, "deep-sleep": #"{"action":"deep-sleep","sandbox":"a"}"#,
        "shutdown": #"{"action":"shutdown","sandbox":"a","confirm":"a"}"#, "reset": #"{"action":"reset","sandbox":"a","confirm":"a"}"#,
        "rm": #"{"action":"rm","sandbox":"a","confirm":"a"}"#,
        "open-session": #"{"action":"open-session","sandbox":"a","session":"worker","argv":["sleep","60"]}"#,
        "point-take": #"{"action":"point-take","sandbox":"a","point":"p1","note":"before"}"#,
        "point-revert": #"{"action":"point-revert","sandbox":"a","point":"rp-20260927-094949-330-bc2e","confirm":"a"}"#,
        "point-fork": #"{"action":"point-fork","sandbox":"a","point":"p1","newName":"b"}"#,
        "point-rm": #"{"action":"point-rm","sandbox":"a","point":"p1","confirm":"a"}"#,
        "point-save-image": #"{"action":"point-save-image","sandbox":"a","image":"mine"}"#,
        "image-bake": #"{"action":"image-bake","image":"claude-code"}"#,
        "image-rm": #"{"action":"image-rm","image":"mine","confirm":"mine"}"#,
        "net-policy": #"{"action":"net-policy","sandbox":"a","allow":["example.com","*.example.org"],"deny":["evil.example"]}"#,
        "key-policy": #"{"action":"key-policy","sandbox":"a","policy":"strict"}"#,
        "key-rm": #"{"action":"key-rm","sandbox":"a","binding":"anthropic"}"#,
        "account-use": #"{"action":"account-use","sandbox":"a","account":"work"}"#,
        "account-default": #"{"action":"account-default","account":"none"}"#,
        "account-keepalive": #"{"action":"account-keepalive","enabled":true}"#,
        "account-verify": #"{"action":"account-verify","account":"work"}"#,
        "account-rm": #"{"action":"account-rm","account":"work","confirm":"work"}"#,
    ]

    /// Everything the web layer may send to the host — and, as important, what it may never.
    static let allowedOps: Set<HostOp> = [
        .create, .start, .wake, .pause, .resume, .sleep, .deepSleep, .shutdown, .reset, .rm, .openSession,
        .pointTake, .pointRevert, .pointFork, .pointRm, .pointSaveImage, .imageBake, .imageRm, .netPolicy,
        .keyPolicy, .keyRm, .accountUse, .accountDefault, .accountKeepalive, .accountVerify, .accountRemove,
    ]

    func testEveryActionIsExactlyOneAllowedHostOp() throws {
        XCTAssertEqual(Set(Self.samples.keys), Set(WebAction.actionNames), "a sample for every action, and no action without one")
        var ops: [HostOp] = []
        for (name, json) in Self.samples {
            let a = try decode(json)
            XCTAssertTrue(Self.allowedOps.contains(a.hostOp), "\(name) → \(a.hostOp)")
            XCTAssertEqual(a.hostRequest.op, a.hostOp)
            XCTAssertEqual(a.hostRequest.v, HostProtocol.version)
            XCTAssertNil(a.hostRequest.secret, "no action ever carries a secret")
            ops.append(a.hostOp)
        }
        XCTAssertEqual(ops.count, Set(ops).count, "one action per HostOp")
        for forbidden: HostOp in [.exec, .attach, .keySet, .accountAdd, .hostStop, .events, .ping] {
            XCTAssertFalse(ops.contains(forbidden), "\(forbidden) must never be reachable from the browser")
        }
        XCTAssertEqual(WebAction.lifecycleOps["deep-sleep"], .deepSleep)
    }

    func testFieldsMapToTheRequest() throws {
        let c = try decode(Self.samples["create"]!)
        XCTAssertEqual(c.hostRequest.name, "new1")
        XCTAssertEqual(c.hostRequest.create, CreateOptions(image: "lab", cpus: 2, memoryMiB: 1024, network: "bake", account: "default"))
        let s = try decode(Self.samples["open-session"]!)
        XCTAssertEqual(s.hostRequest.argv, ["sleep", "60"])
        XCTAssertEqual(s.hostRequest.session, "worker")
        XCTAssertEqual(s.hostRequest.wake, true)
        let n = try decode(Self.samples["net-policy"]!)
        XCTAssertEqual(n.hostRequest.allow, ["example.com", "*.example.org"])
        XCTAssertEqual(n.hostRequest.deny, ["evil.example"])
        XCTAssertEqual(try decode(Self.samples["account-keepalive"]!).hostRequest.enabled, true)
        XCTAssertEqual(try decode(Self.samples["point-revert"]!).hostRequest.point, "rp-20260927-094949-330-bc2e")
        XCTAssertEqual(try decode(Self.samples["deep-sleep"]!).sandbox, "a")
        XCTAssertNil(try decode(Self.samples["image-bake"]!).sandbox)
    }

    func testDecodingIsStrict() {
        invalid("[]")
        invalid("not json")
        invalid(#"{"sandbox":"a"}"#)                                   // no action
        invalid(#"{"action":"exec","sandbox":"a","argv":["id"]}"#)     // not an action
        invalid(#"{"action":"key-set","sandbox":"a","secret":"x"}"#)   // never
        invalid(#"{"action":"account-add","account":"x"}"#)
        invalid(#"{"action":"start","sandbox":"a","extra":1}"#)        // unknown field
        invalid(#"{"action":"start","sandbox":"a","argv":["id"]}"#)    // a field of another action
        invalid(#"{"action":"start","sandbox":"A"}"#)
        invalid(#"{"action":"start","sandbox":"../x"}"#)
        invalid(#"{"action":"start","sandbox":5}"#)
        invalid(#"{"action":"start"}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","cpus":"2"}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","cpus":2.5}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","cpus":true}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","memoryMiB":64}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","network":"host"}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","subnet":"10.0.0.0"}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","workspace":"relative/path"}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","workspace":"/definitely/not/here/590"}"#)
        invalid(#"{"action":"open-session","sandbox":"a","session":".hidden"}"#)
        invalid(#"{"action":"open-session","sandbox":"a","argv":[]}"#)
        invalid(#"{"action":"open-session","sandbox":"a","argv":["a\u0000b"]}"#)
        invalid(#"{"action":"open-session","sandbox":"a","argv":[1]}"#)
        invalid(#"{"action":"point-take","sandbox":"a","note":"line\nbreak"}"#)
        invalid(#"{"action":"image-bake","image":"mine"}"#)            // only built-ins bake
        invalid(#"{"action":"net-policy","sandbox":"a"}"#)             // nothing to change
        invalid(#"{"action":"net-policy","sandbox":"a","allow":["http://x.com/"]}"#)
        invalid(#"{"action":"net-policy","sandbox":"a","allow":"x.com"}"#)
        invalid(#"{"action":"net-policy","sandbox":"a","preset":"wide"}"#)
        invalid(#"{"action":"key-policy","sandbox":"a","policy":"loose"}"#)
        invalid(#"{"action":"key-rm","sandbox":"a","binding":"github"}"#)
        invalid(#"{"action":"account-default","account":"default"}"#)
        invalid(#"{"action":"account-keepalive","enabled":1}"#)
        let many = "[" + (0..<33).map { "\"h\($0).com\"" }.joined(separator: ",") + "]"
        invalid(#"{"action":"net-policy","sandbox":"a","allow":"# + many + "}")
        let big = String(repeating: "x", count: 4097)
        invalid(#"{"action":"open-session","sandbox":"a","argv":[""# + big + #""]}"#)
    }

    func testTheInvalidMessageNeverEchoesTheValue() {
        do {
            _ = try decode(#"{"action":"start","sandbox":"<script>alert(1)</script>"}"#)
            XCTFail()
        } catch let e as WebAction.Invalid {
            XCTAssertFalse(e.message.contains("script"))
        } catch { XCTFail("\(error)") }
    }

    func testDestructiveActionsNeedTheTypedName() throws {
        for verb in ["shutdown", "reset", "rm"] {
            invalid(#"{"action":"\#(verb)","sandbox":"a"}"#)
            invalid(#"{"action":"\#(verb)","sandbox":"a","confirm":"b"}"#)
            invalid(#"{"action":"\#(verb)","sandbox":"a","confirm":"A"}"#)
            XCTAssertNotNil(try decode(#"{"action":"\#(verb)","sandbox":"a","confirm":"a"}"#).confirmationTarget)
        }
        invalid(#"{"action":"point-rm","sandbox":"a","point":"p1"}"#)
        invalid(#"{"action":"point-revert","sandbox":"a","point":"p1","confirm":"p1"}"#)   // the sandbox's name
        invalid(#"{"action":"image-rm","image":"mine","confirm":"lab"}"#)
        invalid(#"{"action":"account-rm","account":"work"}"#)
        // Not destructive: a confirm field is not even allowed.
        invalid(#"{"action":"pause","sandbox":"a","confirm":"a"}"#)
        XCTAssertNil(try decode(Self.samples["pause"]!).confirmationTarget)
        XCTAssertNil(try decode(Self.samples["deep-sleep"]!).confirmationTarget)
    }

    func testAWorkspaceIsResolvedToAnExistingDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ws-590-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try decode(#"{"action":"create","sandbox":"a","image":"lab","workspace":"\#(dir.path)"}"#)
        XCTAssertEqual(a.hostRequest.create?.workspace, dir.resolvingSymlinksInPath().path)
        let file = dir.appendingPathComponent("f")
        try Data().write(to: file)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","workspace":"\#(file.path)"}"#)
    }

    // MARK: policy preview

    func testThePreviewIsExactlyWhatTheHostWillApply() throws {
        let live = NetworkPolicy.presets["bake"]!
        let edit = WebPolicyEdit(preset: nil, allow: ["example.com"], deny: ["dl-cdn.alpinelinux.org"], remove: ["pypi.org"])
        let after = try HostCore.editedPolicy(live, edit.request("a"))
        let p = WebPolicyPreview(before: try HostCore.editedPolicy(live, HostRequest(.netPolicy, name: "a")), after: after)
        XCTAssertTrue(p.changed)
        XCTAssertNil(p.after.preset, "an edit leaves the preset")
        XCTAssertTrue(p.added.contains { $0.contains("example.com") })
        XCTAssertTrue(p.added.contains { $0.contains("deny dl-cdn.alpinelinux.org") })
        XCTAssertTrue(p.removed.contains { $0.contains("pypi.org") })
        XCTAssertTrue(p.removed.contains { $0.contains("allow dl-cdn.alpinelinux.org") })
        XCTAssertEqual(p.after.rules.first?.label, after.rules.first?.label)
        let same = WebPolicyPreview(before: live, after: try HostCore.editedPolicy(live, WebPolicyEdit(preset: "bake", allow: [], deny: [], remove: []).request("a")))
        XCTAssertFalse(same.changed)
        XCTAssertThrowsError(try HostCore.editedPolicy(live, WebPolicyEdit(preset: "wide", allow: [], deny: [], remove: []).request("a")))
    }

    /// Nit 4: the account column is "n/a" unless the sandbox's policy can reach the API.
    func testTheAccountMattersOnlyWhenThePolicyReachesTheAPI() throws {
        XCTAssertTrue(HostWebData.reachesAccountAPI(NetworkPolicy.presets["agent"]!))
        XCTAssertTrue(HostWebData.reachesAccountAPI(NetworkPolicy.presets["open"]!))
        XCTAssertFalse(HostWebData.reachesAccountAPI(NetworkPolicy.presets["bake"]!))
        XCTAssertFalse(HostWebData.reachesAccountAPI(NetworkPolicy.presets["locked"]!))
        let custom = try HostCore.editedPolicy(NetworkPolicy.presets["bake"]!, WebPolicyEdit(preset: nil, allow: ["api.anthropic.com"], deny: [], remove: []).request("a"))
        XCTAssertTrue(HostWebData.reachesAccountAPI(custom))
    }

    // MARK: Terminal

    func testTheTerminalCommandIsFixedAndQuoted() {
        let c = TerminalHandoff.command(executable: "/Users/me/.local/libexec/snooze/snooze", store: SnoozeStore(root: URL(fileURLWithPath: "/Users/me/My Store")),
                                        sandbox: "demo", session: "worker")
        XCTAssertEqual(c, "exec /Users/me/.local/libexec/snooze/snooze attach demo worker --store '/Users/me/My Store'")
        let q = TerminalHandoff.command(executable: "/tmp/it's/snooze", store: SnoozeStore(root: URL(fileURLWithPath: "/s;rm -rf ~")), sandbox: "d", session: nil)
        XCTAssertEqual(q, "exec '/tmp/it'\\''s/snooze' attach d --store '/s;rm -rf ~'")
        // The one-shot .command file deletes itself first, then runs exactly the command.
        let f = TerminalHandoff.commandFile(q)
        XCTAssertTrue(f.hasPrefix("#!/bin/sh\n"))
        XCTAssertEqual(f.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("#") },
                       ["rm -f -- \"$0\"", q])
    }

    /// The hand-off directory is private to this user (0700), whatever it was before.
    func testTheTerminalHandoffDirectoryIsPrivate() throws {
        let dir = try TerminalHandoff.handoffDirectory()
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o700)
    }

    // MARK: metrics

    func testTheMetricsQueryIsClosed() {
        XCTAssertEqual(WebMetricsQuery.parse(nil), WebMetricsQuery())
        XCTAssertEqual(WebMetricsQuery.parse("image=lab&days=7&steps=1"), WebMetricsQuery(image: "lab", days: 7, steps: true))
        XCTAssertEqual(WebMetricsQuery.parse("image=custom%3Amine&steps=0")?.image, "custom:mine")
        XCTAssertEqual(WebMetricsQuery.parse("image=&days="), WebMetricsQuery())
        for bad in ["image=LAB", "days=-1", "days=abc", "days=99999", "steps=yes", "sort=name", "image", "image=a%20b"] {
            XCTAssertNil(WebMetricsQuery.parse(bad), bad)
        }
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/metrics?days=1"), .metrics(WebMetricsQuery(days: 1)))
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/metrics.csv"), .metricsCSV(WebMetricsQuery()))
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/metrics?evil=1"))
    }

    func testCSVCellsCannotBecomeFormulas() {
        XCTAssertEqual(WebCSV.cell("=HYPERLINK(\"x\")"), "'=HYPERLINK(\"x\")")
        XCTAssertEqual(WebCSV.cell("+1+2"), "'+1+2")
        XCTAssertEqual(WebCSV.cell("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(WebCSV.cell("-12.5"), "-12.5", "a number stays a number")
        XCTAssertEqual(WebCSV.cell("start"), "start")
        XCTAssertNil(WebCSV.cell(nil))
    }

    // MARK: routes

    func testThePhase2RoutesAreTypedToo() {
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/actions"), .actions)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/operations"), .operations)
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/sandboxes/demo/network/preview"), .policyPreview("demo"))
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/sandboxes/demo/terminal"), .terminal("demo"))
        for t in ["/api/v1/actions/start", "/api/v1/sandboxes/demo/start", "/api/v1/sandboxes/demo/exec", "/api/v1/sandboxes/Demo/terminal",
                  "/api/v1/sandboxes/demo/network/apply", "/api/v1/command", "/api/v1/sandboxes/demo/attach"] {
            XCTAssertNil(WebRoute.parse(method: .post, target: t), t)
        }
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/actions"))
        XCTAssertNil(WebRoute.parse(method: .delete, target: "/api/v1/actions"))
    }

    func testOperationSummariesComeFromTheResultNotThroughIt() throws {
        let r = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"name":"a","operation":"deep-sleep","phaseBefore":"running","phase":"deepAsleep","changed":true,"milliseconds":510}"#.utf8))
        XCTAssertEqual(WebOperations.summary(.lifecycle(.deepSleep, name: "a"), r), "a: running → deep asleep in 510 ms")
        let same = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"name":"a","operation":"pause","phaseBefore":"paused","phase":"paused","changed":false,"milliseconds":0}"#.utf8))
        XCTAssertEqual(WebOperations.summary(.lifecycle(.pause, name: "a"), same), "a is already paused")
        XCTAssertEqual(WebOperations.summary(.imageBake("lab"), .null), "lab baked")
    }
}
