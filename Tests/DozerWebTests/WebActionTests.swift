import Foundation
import DozerKit
import DozerHost
import XCTest
@testable import DozerWeb

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
        "sleep": #"{"action":"sleep","sandbox":"a"}"#, "hibernate": #"{"action":"hibernate","sandbox":"a"}"#,
        "shutdown": #"{"action":"shutdown","sandbox":"a"}"#, "reset": #"{"action":"reset","sandbox":"a","confirm":"a"}"#,
        "rm": #"{"action":"rm","sandbox":"a","confirm":"a"}"#,
        "open-session": #"{"action":"open-session","sandbox":"a","session":"worker","argv":["sleep","60"]}"#,
        "point-take": #"{"action":"point-take","sandbox":"a","point":"p1","note":"before"}"#,
        "point-revert": #"{"action":"point-revert","sandbox":"a","point":"rp-20260927-094949-330-bc2e","confirm":"a"}"#,
        "point-fork": #"{"action":"point-fork","sandbox":"a","point":"p1","newName":"b"}"#,
        "point-rm": #"{"action":"point-rm","sandbox":"a","point":"p1","confirm":"a"}"#,
        "point-save-image": #"{"action":"point-save-image","sandbox":"a","image":"mine"}"#,
        "template-create": #"{"action":"template-create","sandbox":"a","image":"my-tpl","note":"node + tools"}"#,
        "duplicate": #"{"action":"duplicate","sandbox":"a","newName":"a2","workspace":"/tmp","cpus":4,"memoryMiB":2048,"network":"locked","account":"none","copyState":true}"#,
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
        "onboard": #"{"action":"onboard","images":["claude-code","lab"]}"#,
        "prepare-cancel": #"{"action":"prepare-cancel","images":["pi"]}"#,
        "resources-rm": #"{"action":"resources-rm","ids":["cache:downloads","kernel:6.12.1-1","point:web/rp-1"]}"#,
        "resources-clean": #"{"action":"resources-clean"}"#,
        "resources-kernel": #"{"action":"resources-kernel","kernel":"kernel:6.12.1-1"}"#,
        "host-start": #"{"action":"host-start"}"#,
        "host-restart": #"{"action":"host-restart"}"#,
        // 596 (B7): Apple's container tool — start its services, install it (the page said what each does).
        "builder-start": #"{"action":"builder-start"}"#,
        "builder-install": #"{"action":"builder-install"}"#,
        // 599h: the tools layer again (the wizard's Retry).
        "tools-apply": #"{"action":"tools-apply","sandbox":"web"}"#,
        "session-end": #"{"action":"session-end","sandbox":"web","session":"codex"}"#,
        "session-restart": #"{"action":"session-restart","sandbox":"web","session":"codex","fresh":false}"#,
    ]

    /// Everything the web layer may send to the host — and, as important, what it may never.
    static let allowedOps: Set<HostOp> = [
        .create, .start, .wake, .pause, .resume, .sleep, .hibernate, .shutdown, .reset, .rm, .openSession,
        .pointTake, .pointRevert, .pointFork, .pointRm, .pointSaveImage, .imageBake, .imageRm, .netPolicy,
        .keyPolicy, .keyRm, .accountUse, .accountDefault, .accountKeepalive, .accountVerify, .accountRemove,
        .templateCreate, .duplicate, .onboard, .prepareCancel, .resourcesRemove, .resourcesClean, .resourcesKernel, .ping,
        // 596 (B7): consented by the person's click on a button that said what it does.
        .builderStart, .builderInstall,
        // 599h: set a sandbox's tools layer up again (it installs only what its settings already call for).
        .toolsApply,
        // 608: End session / Restart session (a running sandbox only; never a wake).
        .sessionEnd, .sessionRestart,
        // 594 W20: only as Restart host, which the data source refuses unless the host is OLDER.
        .hostStop,
    ]

    /// 595: resources — ids by their rule, each once; no typed name (a plain confirmation: owner);
    /// never a dry-run flag or a path from the browser.
    func testResourceActionsDecodeStrictly() throws {
        let r = try decode(Self.samples["resources-rm"]!)
        XCTAssertEqual(r.hostRequest.op, .resourcesRemove)
        XCTAssertEqual(r.hostRequest.ids, ["cache:downloads", "kernel:6.12.1-1", "point:web/rp-1"])
        XCTAssertNil(r.hostRequest.dryRun, "an action deletes; the preview route is the dry run")
        XCTAssertNil(r.confirmationTarget)
        XCTAssertNil(r.sandbox)
        XCTAssertEqual(r.label, "delete 3 resources")
        XCTAssertNotEqual(r.dedupeKey, try decode(#"{"action":"resources-rm","ids":["logs"]}"#).dedupeKey)
        XCTAssertEqual(try decode(Self.samples["resources-clean"]!).hostRequest.op, .resourcesClean)
        XCTAssertEqual(try decode(Self.samples["resources-kernel"]!).hostRequest.kernel, "kernel:6.12.1-1")
        XCTAssertEqual(try decode(#"{"action":"resources-kernel","kernel":"pinned"}"#).hostRequest.kernel, "pinned")
        invalid(#"{"action":"resources-rm"}"#)
        invalid(#"{"action":"resources-rm","ids":[]}"#)
        invalid(#"{"action":"resources-rm","ids":"logs"}"#)
        invalid(#"{"action":"resources-rm","ids":["logs","logs"]}"#)
        invalid(#"{"action":"resources-rm","ids":["image:../../etc"]}"#)
        invalid(#"{"action":"resources-rm","ids":["/etc/passwd"]}"#)
        invalid(#"{"action":"resources-rm","ids":["stray:a b"]}"#)
        invalid(#"{"action":"resources-rm","ids":[1]}"#)
        invalid(#"{"action":"resources-rm","ids":["logs"],"dryRun":false}"#)
        invalid(#"{"action":"resources-rm","ids":["logs"],"confirm":"logs"}"#)
        let many = "[" + (0..<501).map { "\"stray:f\($0)\"" }.joined(separator: ",") + "]"
        invalid(#"{"action":"resources-rm","ids":"# + many + "}")
        invalid(#"{"action":"resources-clean","ids":["logs"]}"#)
        invalid(#"{"action":"resources-kernel"}"#)
        invalid(#"{"action":"resources-kernel","kernel":"/tmp/vmlinux"}"#)
        invalid(#"{"action":"resources-kernel","kernel":"image:pi"}"#)
        invalid(#"{"action":"resources-kernel","kernel":"kernel:../x"}"#)
    }

    /// 595: the preview's body — exactly {ids} or {clean: true}.
    func testResourcePreviewDecodesStrictly() throws {
        XCTAssertEqual(try WebResourcePreview.decode(Data(#"{"ids":["logs","initfs"]}"#.utf8)).hostRequest.ids, ["logs", "initfs"])
        let c = try WebResourcePreview.decode(Data(#"{"clean":true}"#.utf8))
        XCTAssertEqual(c.hostRequest.op, .resourcesClean)
        XCTAssertEqual(c.hostRequest.dryRun, true)
        XCTAssertEqual(try WebResourcePreview.decode(Data(#"{"ids":["logs"]}"#.utf8)).hostRequest.dryRun, true)
        for bad in [#"{}"#, #"[]"#, #"{"ids":[]}"#, #"{"clean":false}"#, #"{"clean":1}"#, #"{"clean":true,"ids":["logs"]}"#,
                    #"{"ids":["logs"],"dryRun":false}"#, #"{"ids":["../x"]}"#] {
            XCTAssertThrowsError(try WebResourcePreview.decode(Data(bad.utf8)), bad)
        }
    }

    /// 594 W20: "Restart host" — no fields; `host stop` + a start of this UI's build, refused by the
    /// data source unless the running host is an older build (and by the fake, which has no host).
    func testRestartHostIsTheOnlyHostStopAndItIsGuarded() async throws {
        let a = try decode(Self.samples["host-restart"]!)
        XCTAssertEqual(a, .hostRestart)
        XCTAssertEqual(a.hostOp, .hostStop)
        XCTAssertNil(a.sandbox)
        XCTAssertEqual(a.label, "host-restart")
        invalid(#"{"action":"host-restart","sandbox":"a"}"#)
        invalid(#"{"action":"host-stop"}"#)
        XCTAssertTrue(WebOperations.summary(.hostRestart, .null).contains("hibernated"))
        // 594 W22: the stop's rows in the outcome, and each sandbox's line on the operation.
        let rows = [HostStopRow(name: "w1", phaseBefore: "running", phase: "hibernated", outcome: "hibernated", milliseconds: 400),
                    HostStopRow(name: "w2", phaseBefore: "running", phase: "off", outcome: "failed", milliseconds: 90, error: "boom")]
        let v = try JSONValue(encoding: WebHostRestart(stop: HostStopResult(sandboxes: rows, milliseconds: 500, version: "a"), host: nil))
        XCTAssertEqual(WebOperations.summary(.hostRestart, v),
                       "the host restarted — hibernated w1; they wake when used (w2: could not hibernate — shut down)")
        XCTAssertEqual(WebOperations.finishedLine(HostStopView.finished(rows[0])), "✓ hibernated w1 — 400 ms")
        XCTAssertEqual(WebOperations.finishedLine(HostStopView.finished(rows[1])),
                       "✗ hibernating w2 — boom — it was shut down instead (its disk is kept; start it again) (90 ms)")
        XCTAssertNil(WebOperations.finishedLine(HostStopView.started("w1")))
        // A store with no host: nothing to restart (and nothing is started).
        let dir = URL(fileURLWithPath: "/tmp/doz-hr-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        let store = DozerStore(root: dir)
        try store.ensureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = HostWebData(store: store, version: "0.12.0") { [] }
        do { _ = try await data.restartHost { _ in }; XCTFail("no host") } catch {
            XCTAssertTrue(HostError.from(error).message.contains("no host is running"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.socket.path), "nothing started")
    }

    /// 594 W18: "Start host" — the host's `ping` (sent with autostart like every action), nothing more.
    func testStartHostIsAPingWithNoFields() throws {
        let a = try decode(Self.samples["host-start"]!)
        XCTAssertEqual(a, .hostStart)
        XCTAssertEqual(a.hostRequest.op, .ping)
        XCTAssertNil(a.sandbox)
        XCTAssertNil(a.confirmationTarget)
        XCTAssertEqual(a.label, "host-start")
        invalid(#"{"action":"host-start","sandbox":"a"}"#)
        invalid(#"{"action":"host-stop"}"#)
        XCTAssertEqual(WebOperations.summary(.hostStart, .null), "the host is running")
    }

    /// 594: onboard and prepare-cancel — built-in images only, each once; onboard never waits.
    func testOnboardingActionsDecodeStrictly() throws {
        let o = try decode(Self.samples["onboard"]!)
        XCTAssertEqual(o.hostRequest.op, .onboard)
        XCTAssertEqual(o.hostRequest.images, ["claude-code", "lab"])
        XCTAssertEqual(o.hostRequest.follow, false, "the preparation runs in the host; the action ends at once")
        XCTAssertEqual(o.hostRequest.requestedBy, "doz ui")
        XCTAssertEqual(try decode(#"{"action":"onboard"}"#).hostRequest.images, [], "no images: onboarding is recorded at once")
        XCTAssertNil(try decode(#"{"action":"prepare-cancel"}"#).hostRequest.images, "none named: every running one")
        XCTAssertEqual(try decode(Self.samples["prepare-cancel"]!).hostRequest.images, ["pi"])
        invalid(#"{"action":"onboard","images":["ubuntu"]}"#)
        invalid(#"{"action":"onboard","images":["pi","pi"]}"#)
        invalid(#"{"action":"onboard","images":"pi"}"#)
        invalid(#"{"action":"onboard","images":["pi"],"follow":true}"#)
        invalid(#"{"action":"onboard","images":["lab","pi","claude-code","lab"]}"#)
        invalid(#"{"action":"prepare-cancel","images":[1]}"#)
    }

    /// 593: templates and duplicates — strict, and each field mapped to the host's request.
    func testTemplatesAndDuplicatesDecodeStrictly() throws {
        let t = try decode(Self.samples["template-create"]!)
        XCTAssertEqual(t.hostRequest.op, .templateCreate)
        XCTAssertEqual(t.hostRequest.image, "my-tpl")
        XCTAssertNil(t.hostRequest.point, "no point: the current disk")
        XCTAssertNil(t.confirmationTarget)
        let d = try decode(Self.samples["duplicate"]!)
        XCTAssertEqual(d.hostRequest.newName, "a2")
        let tmp = "/private/tmp"                                        // 594: realpath (the link /tmp resolved)
        XCTAssertEqual(d.hostRequest.duplicate, DuplicateOptions(workspace: tmp, cpus: 4, memoryMiB: 2048, network: "locked", account: "none", copyState: true))
        XCTAssertEqual(try decode(#"{"action":"duplicate","sandbox":"a","newName":"b"}"#).hostRequest.duplicate, DuplicateOptions(),
                       "nothing given: the source's everything, a fresh state disk")
        XCTAssertNil(try decode(#"{"action":"duplicate","sandbox":"a","newName":"b","copyState":false}"#).hostRequest.duplicate?.copyState)
        XCTAssertNotEqual(try decode(#"{"action":"duplicate","sandbox":"a","newName":"b"}"#).dedupeKey,
                          try decode(#"{"action":"duplicate","sandbox":"a","newName":"c"}"#).dedupeKey, "two duplicates to two names may run together")
        invalid(#"{"action":"template-create","sandbox":"a"}"#)                                  // no name
        invalid(#"{"action":"template-create","sandbox":"a","image":"Bad Name"}"#)
        invalid(#"{"action":"template-create","sandbox":"a","image":"lab"}"#)                    // a built-in's name
        invalid(#"{"action":"template-create","sandbox":"a","image":"t","state":true}"#)         // never the state disk
        invalid(#"{"action":"duplicate","sandbox":"a"}"#)                                        // no new name
        invalid(#"{"action":"duplicate","sandbox":"a","newName":"a"}"#)                          // onto itself
        invalid(#"{"action":"duplicate","sandbox":"a","newName":"B"}"#)
        invalid(#"{"action":"duplicate","sandbox":"a","newName":"b","workspace":"relative"}"#)
        invalid(#"{"action":"duplicate","sandbox":"a","newName":"b","workspace":"/w","isolated":true}"#)
        invalid(#"{"action":"duplicate","sandbox":"a","newName":"b","copyState":"yes"}"#)
        invalid(#"{"action":"duplicate","sandbox":"a","newName":"b","copyState":1}"#)
        invalid(#"{"action":"duplicate","sandbox":"a","newName":"b","cpus":0}"#)
        invalid(#"{"action":"duplicate","sandbox":"a","newName":"b","network":"host"}"#)
        invalid(#"{"action":"duplicate","sandbox":"a","newName":"b","image":"lab"}"#)           // not a field of duplicate
    }

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
        // 594 W18: `ping` is reachable — as "Start host" (a status read that starts a host the way
        // every action does); `host stop` only as W20's guarded Restart host.
        XCTAssertEqual(Self.samples.filter { (try? decode($0.value).hostOp) == .hostStop }.map(\.key), ["host-restart"])
        for forbidden: HostOp in [.exec, .attach, .keySet, .accountAdd, .events] {
            XCTAssertFalse(ops.contains(forbidden), "\(forbidden) must never be reachable from the browser")
        }
        XCTAssertEqual(WebAction.lifecycleOps["hibernate"], .hibernate)
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
        XCTAssertEqual(try decode(Self.samples["hibernate"]!).sandbox, "a")
        XCTAssertNil(try decode(Self.samples["image-bake"]!).sandbox)
        let restart = try decode(Self.samples["session-restart"]!)
        XCTAssertEqual(restart.hostRequest.session, "codex")
        XCTAssertNil(restart.hostRequest.fresh, "fresh: false is not sent")
        XCTAssertEqual(try decode(#"{"action":"session-restart","sandbox":"web","session":"codex","fresh":true}"#).hostRequest.fresh, true)
        XCTAssertEqual(try decode(Self.samples["session-end"]!).hostRequest.op, .sessionEnd)
        XCTAssertEqual(try decode(Self.samples["session-end"]!).sandbox, "web")
        // 608: the session is required and a valid name; nothing else is taken.
        invalid(#"{"action":"session-end","sandbox":"web"}"#)
        invalid(#"{"action":"session-restart","sandbox":"web","session":"../x"}"#)
        invalid(#"{"action":"session-restart","sandbox":"web","session":"codex","argv":["sh"]}"#)
    }

    func testDecodingIsStrict() throws {
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
        // 596 (B1, B6): a base × agent image; a Dockerfile (absolute, a file) carried with the agent's image.
        XCTAssertEqual(try decode(#"{"action":"create","sandbox":"a","image":"python-claude-code"}"#).hostRequest.create?.image, "python-claude-code")
        let df = try decode(#"{"action":"create","sandbox":"a","image":"pi","dockerfile":"/private/tmp/app/Dockerfile"}"#)
        XCTAssertEqual(df.hostRequest.create?.dockerfile, "/private/tmp/app/Dockerfile")
        invalid(#"{"action":"create","sandbox":"a","image":"python-pi","dockerfile":"/private/tmp/app/Dockerfile"}"#)   // the base is the Dockerfile's
        invalid(#"{"action":"create","sandbox":"a","image":"pi","dockerfile":"Dockerfile"}"#)                          // relative
        invalid(#"{"action":"create","sandbox":"a","image":"pi","dockerfile":"/a\nb"}"#)
        XCTAssertEqual(try decode(#"{"action":"image-bake","image":"go-claude-code"}"#).hostRequest.image, "go-claude-code")
        invalid(#"{"action":"image-bake","image":"cobol-pi"}"#)
        invalid(#"{"action":"builder-start","yes":true}"#)
        XCTAssertEqual(try decode(Self.samples["builder-start"]!).hostRequest.requestedBy, "doz ui")
        invalid(#"{"action":"create","sandbox":"a","image":"lab","cpus":"2"}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","cpus":2.5}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","cpus":true}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","memoryMiB":64}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","network":"host"}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","subnet":"10.0.0.0"}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","workspace":"relative/path"}"#)
        invalid(#"{"action":"create","sandbox":"a","image":"lab","workspace":"/w\nx"}"#)                // one line
        invalid(#"{"action":"create","sandbox":"a","image":"lab","workspace":"/w","isolated":true}"#)   // not both
        invalid(#"{"action":"create","sandbox":"a","image":"lab","isolated":"yes"}"#)
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
        // 591: Shut Down keeps the disk — a plain confirmation in the page, no typed name.
        XCTAssertNil(try decode(#"{"action":"shutdown","sandbox":"a"}"#).confirmationTarget)
        for verb in ["reset", "rm"] {
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
        XCTAssertNil(try decode(Self.samples["hibernate"]!).confirmationTarget)
    }

    /// 594: a workspace is an absolute path (or ~/…), resolved; it need not exist — the HOST makes it
    /// (and refuses a file, the store, a system location). Isolated is its own field.
    func testAWorkspaceIsResolvedAndNeedNotExist() throws {
        let dir = "/private/tmp/ws-590-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = try decode(#"{"action":"create","sandbox":"a","image":"lab","workspace":"\#(dir.replacingOccurrences(of: "/private/tmp", with: "/tmp"))"}"#)
        XCTAssertEqual(a.hostRequest.create?.workspace, dir, "links resolved")
        let missing = try decode(#"{"action":"create","sandbox":"a","image":"lab","workspace":"\#(dir)/new/deep"}"#)
        XCTAssertEqual(missing.hostRequest.create?.workspace, dir + "/new/deep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/new"), "decoding makes nothing")
        let home = try decode(#"{"action":"create","sandbox":"a","image":"lab","workspace":"~/proj-x"}"#)
        XCTAssertEqual(home.hostRequest.create?.workspace, Workspace.home() + "/proj-x")
        let iso = try decode(#"{"action":"duplicate","sandbox":"a","newName":"b","isolated":true}"#)
        XCTAssertEqual(iso.hostRequest.duplicate?.isolated, true)
        XCTAssertNil(iso.hostRequest.duplicate?.workspace)
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
        let c = TerminalHandoff.command(executable: "/Users/me/.local/libexec/doz/doz", store: DozerStore(root: URL(fileURLWithPath: "/Users/me/My Store")),
                                        sandbox: "demo", session: "worker")
        XCTAssertEqual(c, "exec /Users/me/.local/libexec/doz/doz attach demo worker --store '/Users/me/My Store'")
        let q = TerminalHandoff.command(executable: "/tmp/it's/doz", store: DozerStore(root: URL(fileURLWithPath: "/s;rm -rf ~")), sandbox: "d", session: nil)
        XCTAssertEqual(q, "exec '/tmp/it'\\''s/doz' attach d --store '/s;rm -rf ~'")
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
        // 593: the lineage is a GET of its own; nothing near it is a route.
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/images/tree"), .imageTree)
        for (m, t) in [(WebHTTPMethod.post, "/api/v1/images/tree"), (.get, "/api/v1/images/tree/"), (.get, "/api/v1/images/tree/x"),
                       (.get, "/api/v1/images/Tree"), (.delete, "/api/v1/images/tree"), (.get, "/api/v1/images/lab")] {
            XCTAssertNil(WebRoute.parse(method: m, target: t), t)
        }
        // 595: the account (GET) and the preview (POST); deleting is an action, never a route.
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/resources"), .resources)
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/resources/preview"), .resourcesPreview)
        for (m, t) in [(WebHTTPMethod.post, "/api/v1/resources"), (.delete, "/api/v1/resources"), (.get, "/api/v1/resources/preview"),
                       (.post, "/api/v1/resources/delete"), (.post, "/api/v1/resources/clean"), (.get, "/api/v1/resources/logs"),
                       (.get, "/api/v1/resources/")] {
            XCTAssertNil(WebRoute.parse(method: m, target: t), t)
        }
    }

    func testOperationSummariesComeFromTheResultNotThroughIt() throws {
        let r = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"name":"a","operation":"hibernate","phaseBefore":"running","phase":"hibernated","changed":true,"milliseconds":510}"#.utf8))
        XCTAssertEqual(WebOperations.summary(.lifecycle(.hibernate, name: "a"), r), "a: running → hibernated in 510 ms")
        let same = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"name":"a","operation":"pause","phaseBefore":"paused","phase":"paused","changed":false,"milliseconds":0}"#.utf8))
        XCTAssertEqual(WebOperations.summary(.lifecycle(.pause, name: "a"), same), "a is already paused")
        XCTAssertEqual(WebOperations.summary(.imageBake("lab"), .null), "lab baked")
    }
}
