import Foundation
import XCTest
@testable import DozerCLI
@testable import DozerHost
import DozerKit

/// Anonymous usage statistics — the open half (Sources/DozerHost/Usage.swift): the closed list (an encoder that can
/// only say schema keys and vocabulary words), the buckets, the day's numbers from what the host recorded, the off
/// switches, once a day / once a version, the notice, and what a FAKE installed sender is handed. Nothing here reaches
/// a network: the only sender is the fake.
final class UsageTests: XCTestCase {
    private var dir: URL!
    private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: "/tmp/d614u-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        Usage.uninstall()
        try? FileManager.default.removeItem(at: dir)
    }

    func date(_ s: String) -> Date { utc.date(from: DateComponents(year: Int(s.prefix(4))!, month: Int(s.dropFirst(5).prefix(2))!,
                                                                   day: Int(s.dropFirst(8).prefix(2))!, hour: 12))! }
    var files: UsageFiles { UsageFiles(directory: dir) }
    func recorder(_ day: String) -> UsageRecorder { UsageRecorder(files: files, now: date(day), calendar: utc) }
    let machine = UsageMachine(macos: 26, chip: "m4", ram: "32", cores: "9-11")
    let id = "8b6f0e4c-2d1a-4f3e-9c5b-7a8d9e0f1a2b"

    func json(_ m: UsageMessage) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: m.encoded())) as? [String: Any] ?? [:]
    }

    func event(_ action: String, image: String? = "claude-code", ms: Double? = nil, ok: Bool? = true, run: Int64 = 1,
               detail: String? = nil, at: Date? = nil) -> MetricsEvent {
        MetricsEvent(id: 1, run: run, parent: nil, kind: .action, sandbox: "my-secret-project", image: image, action: action,
                     phaseBefore: nil, phaseAfter: nil, startedAt: at ?? date("2026-10-09"), durationMs: ms, ok: ok,
                     error: ok == false ? "a failure naming /Users/someone/secret" : nil, bytes: nil, detailJSON: detail,
                     appVersion: nil, machine: "Mac15,3", macOS: "26.0.1")
    }

    // MARK: the closed list

    /// Every field of the schema filled: the encoder says exactly these keys and words — and the check agrees.
    func testAFullDailyEncodesExactlyTheSchema() throws {
        var d = UsageDaily()
        d.macos = 26; d.chip = "m4"; d.ram = "32"; d.cores = "9-11"
        d.commands = ["create": 2, "ui start": 1, "hibernate": 3]
        d.failed = ["create:1": 1]
        d.onboarding = .init(via: "cli", step: "done", completed: true)
        d.firstSandbox = true; d.timeToFirstSession = "5-30m"
        d.created = .init(agent: ["claude-code": 1, "codex": 1], base: ["node": 1, "dockerfile": 1], account: ["mac": 1, "api-key": 1],
                          network: ["standard": 2])
        d.sandboxes = "2-5"; d.runningMax = "1"; d.points = "6-10"; d.storeGB = "20-100"
        d.timingMs = .init(start: .init(p50: 1200, p90: 2400), wake: .init(p50: 350, p90: 500), hibernate: .init(p50: 900, p90: 1500),
                           pause: .init(p50: 0, p90: 50), agent: "claude-code")
        d.wakeFailed = 0; d.crashRestores = 0; d.hostCrashes = 0; d.prepFailed = ["apt-install": 1]
        d.ui = true; d.app = false; d.serve = false; d.serveDevices = "0"; d.rules = true; d.github = "read"; d.agentStatus = true
        d.pointsTaken = 3; d.templatesMade = 0; d.upgradeMode = "notify"
        d.time = .init(running: ["<5m": 2, "30m-2h": 1], asleep: ["1-8h": 2], removedAge: ["1-7d": 1], runningTotal: "2-8h",
                       agentWorking: ["claude-code": "30m-2h"], idleRunning8h: 0)
        let m = UsageMessage.daily(UsageCommon(id: id, v: "0.33.0", channel: "stable", install: "homebrew"), d)
        let data = m.encoded()
        XCTAssertEqual(UsageSchema.problems(data), [])
        let o = json(m)
        XCTAssertEqual(Set(o.keys), UsageSchema.keys["daily"]!, "every daily key, and nothing else")
        XCTAssertEqual(Set((o["created"] as! [String: Any]).keys), UsageSchema.nested["created"]!)
        XCTAssertEqual(Set((o["timing_ms"] as! [String: Any]).keys), UsageSchema.nested["timing_ms"]!)
        XCTAssertEqual(Set((o["time"] as! [String: Any]).keys), UsageSchema.nested["time"]!)
        XCTAssertEqual(Set((o["onboarding"] as! [String: Any]).keys), UsageSchema.nested["onboarding"]!)
        // Byte for byte (sorted keys, ASCII ranges) — the receiving side's validator accepts exactly this.
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"agent_status":true,"app":false,"channel":"stable","chip":"m4","commands":{"create":2,"hibernate":3,"ui start":1},"cores":"9-11","crash_restores":0,"created":{"account":{"api-key":1,"mac":1},"agent":{"claude-code":1,"codex":1},"base":{"dockerfile":1,"node":1},"network":{"standard":2}},"failed":{"create:1":1},"first_sandbox":true,"github":"read","host_crashes":0,"id":"8b6f0e4c-2d1a-4f3e-9c5b-7a8d9e0f1a2b","install":"homebrew","macos":26,"onboarding":{"completed":true,"step":"done","via":"cli"},"points":"6-10","points_taken":3,"prep_failed":{"apt-install":1},"ram":"32","rules":true,"running_max":"1","sandboxes":"2-5","serve":false,"serve_devices":"0","store_gb":"20-100","templates_made":0,"time":{"agent_working":{"claude-code":"30m-2h"},"asleep":{"1-8h":2},"idle_running_8h":0,"removed_age":{"1-7d":1},"running":{"30m-2h":1,"<5m":2},"running_total":"2-8h"},"time_to_first_session":"5-30m","timing_ms":{"agent":"claude-code","hibernate":{"p50":900,"p90":1500},"pause":{"p50":0,"p90":50},"start":{"p50":1200,"p90":2400},"wake":{"p50":350,"p90":500}},"type":"daily","ui":true,"upgrade_mode":"notify","v":"0.33.0","wake_failed":0}"#)
    }

    func testInstalledAndUpgradedCarryOnlyTheCommonFields() {
        let c = UsageCommon(id: id, v: "0.33.0", channel: "canary", install: "tarball")
        XCTAssertEqual(Set(json(.installed(c)).keys), ["type", "id", "v", "channel", "install"])
        XCTAssertEqual(Set(json(.upgraded(c, from: "0.32.1")).keys), ["type", "id", "v", "channel", "install", "from"])
        XCTAssertEqual(UsageSchema.problems(UsageMessage.installed(c).encoded()), [])
        XCTAssertEqual(UsageSchema.problems(UsageMessage.upgraded(c, from: "0.32.1").encoded()), [])
    }

    /// What the check refuses — each the shape of a leak the encoder must never produce.
    func testTheCheckRefusesAnythingOutsideTheList() {
        func bad(_ s: String) -> Bool { !UsageSchema.problems(Data(s.utf8)).isEmpty }
        let head = #""id":"8b6f0e4c-2d1a-4f3e-9c5b-7a8d9e0f1a2b","v":"0.33.0","channel":"stable","install":"homebrew""#
        XCTAssertFalse(bad(#"{"type":"daily",\#(head)}"#), "the bare daily is fine")
        XCTAssertTrue(bad(#"{"type":"daily",\#(head),"path":"/Users/me"}"#), "an unknown key")
        XCTAssertTrue(bad(#"{"type":"daily",\#(head),"created":{"base":{"df-0123456789ab":1}}}"#), "a Dockerfile's path-derived id")
        XCTAssertTrue(bad(#"{"type":"daily",\#(head),"created":{"base":{"my-template":1}}}"#), "a template's name")
        XCTAssertTrue(bad(#"{"type":"daily",\#(head),"cores":"9–11"}"#), "an en dash")
        XCTAssertTrue(bad(#"{"type":"daily",\#(head),"commands":{"start mybox":1}}"#.replacingOccurrences(of: "start mybox", with: "start My_Box")), "not a command word")
        XCTAssertTrue(bad(#"{"type":"daily",\#(head),"timing_ms":{"start":{"p50":1234,"p90":2000}}}"#), "not rounded")
        XCTAssertTrue(bad(#"{"type":"daily",\#(head),"timing_ms":{"start":{"p50":2000,"p90":1000}}}"#), "p50 above p90")
        XCTAssertTrue(bad(#"{"type":"daily",\#(head),"macos":"26"}"#), "macOS as a string")
        XCTAssertTrue(bad(#"{"type":"daily",\#(head),"time":{"agent_working":{"codex":"2-8h"}}}"#), "agent_working: claude-code and pi only")
        XCTAssertTrue(bad(#"{"type":"daily",\#(head),"first_sandbox":false}"#), "first_sandbox is only ever true")
        XCTAssertTrue(bad(#"{"type":"installed",\#(head),"macos":26}"#), "installed carries nothing more")
        XCTAssertTrue(bad(#"{"type":"installed","id":"8B6F0E4C-2D1A-4F3E-9C5B-7A8D9E0F1A2B","v":"0.33.0","channel":"stable","install":"homebrew"}"#), "an upper-case id")
        XCTAssertTrue(bad(#"{"type":"installed","id":"8b6f0e4c-2d1a-4f3e-9c5b-7a8d9e0f1a2b","v":"0.33.0+local","channel":"stable","install":"homebrew"}"#), "a build suffix")
        XCTAssertTrue(bad(#"{"type":"installed","id":"8b6f0e4c-2d1a-4f3e-9c5b-7a8d9e0f1a2b","v":"0.33.0","channel":"stable","install":"development"}"#))
        let many = (0..<101).map { "\"c\(String(UnicodeScalar(UInt8(97 + $0 % 26))))\($0 / 26 == 0 ? "" : "-\($0 / 26)")\":1" }.joined(separator: ",")
        XCTAssertTrue(bad(#"{"type":"daily",\#(head),"commands":{\#(many)}}"#), "more than 100 keys")
    }

    // MARK: buckets

    func testTheBuckets() {
        let gb: UInt64 = 1 << 30
        XCTAssertEqual([8, 16, 18, 24, 32, 36, 48, 64, 96, 128].map { UsageSchema.ram(bytes: $0 * gb) },
                       ["8", "16", "16", "24", "32", "32", "32", "64+", "64+", "64+"], "rounded DOWN to a listed size")
        XCTAssertEqual([4, 8, 9, 11, 12, 14, 15, 16, 24].map(UsageSchema.cores), ["<=8", "<=8", "9-11", "9-11", "12-15", "12-15", "12-15", "16+", "16+"])
        XCTAssertEqual([0, 1, 2, 5, 6, 10, 11, 25, 26, 400].map(UsageSchema.count), ["0", "1", "2-5", "2-5", "6-10", "6-10", "11-25", "11-25", "26+", "26+"])
        XCTAssertEqual([1, 5, 19, 20, 99, 100].map { UsageSchema.storeGB(bytes: UInt64($0) * 1_000_000_000) }, ["<5", "5-20", "5-20", "20-100", "20-100", "100+"])
        XCTAssertEqual([0, 1, 2, 5, 6].map(UsageSchema.serveDevices), ["0", "1", "2-5", "2-5", "6+"])
        XCTAssertEqual(["Apple M1 Max", "Apple M3", "Apple M4 Pro", "Apple M5 Ultra", "Apple M10", "Intel(R) Core(TM) i9", "?"].map { UsageSchema.chip(brand: $0) },
                       ["m1", "m3", "m4", "m5", "other", "other", "other"])
        XCTAssertEqual([0, 24.9, 25, 74, 1224, 1226, -5, 9_999_999].map(UsageSchema.round50), [0, 0, 50, 50, 1200, 1250, 0, 3_600_000])
        XCTAssertEqual(["agent", "standard", "locked", "open", "nat", "none", "bake", "my-rules"].map(UsageSchema.network),
                       ["standard", "standard", "locked", "open", "nat", "none", "custom", "custom"])
        XCTAssertEqual(UsageSchema.base(image: "claude-code"), "node")
        XCTAssertEqual(UsageSchema.base(image: "lab"), "alpine")
        XCTAssertEqual(UsageSchema.base(image: "df-0123456789ab-pi"), "dockerfile", "never the path-derived id")
        XCTAssertNil(UsageSchema.base(image: "my-secret-template"), "a template's name is never a base")
        XCTAssertEqual(UsageSchema.agent(image: "df-0123456789ab-pi"), "pi")
        XCTAssertNil(UsageSchema.agent(image: "my-secret-template"))
    }

    // MARK: the day's numbers

    func testTheDailyIsBuiltFromWhatTheHostRecorded() throws {
        var day = UsageDay(day: "2026-10-09")
        day.commands = ["create": 2, "ui start": 1, "ls": 4]
        day.failed = ["create:4": 1]
        let ev = [
            event("create", image: "claude-code", detail: #"{"network":"agent"}"#),
            event("create", image: "df-0123456789ab-pi", detail: #"{"network":"nat"}"#),
            event("create", image: "my-secret-template", detail: #"{"network":"my-rules"}"#),
            event("start", ms: 1180), event("start", ms: 1230), event("start", ms: 2410),
            event("wake", ms: 349), event("wake", ok: false), event("hibernate", image: "pi", ms: 912),
            event("restore after crash"), event("died with host", run: 3), event("died with host", run: 3), event("died with host", run: 4),
            event("take restore point", ms: 20), event("take restore point", ok: false), event("save as template", ms: 900),
        ]
        let d = UsageDailyBuilder.build(day, facts: UsageStoreFacts(events: ev, sandboxes: 3, points: 7), machine: machine, upgradeMode: "auto",
                                        calendar: utc)
        XCTAssertEqual(d.commands, ["create": 2, "ui start": 1, "ls": 4])
        XCTAssertEqual(d.failed, ["create:4": 1])
        XCTAssertEqual(d.created?.agent, ["claude-code": 1, "pi": 1], "a template's agent is unknown: not counted")
        XCTAssertEqual(d.created?.base, ["node": 1, "dockerfile": 1])
        XCTAssertEqual(d.created?.network, ["standard": 1, "nat": 1, "custom": 1])
        XCTAssertNil(d.created?.account)
        XCTAssertEqual(d.sandboxes, "2-5")
        XCTAssertEqual(d.points, "6-10")
        XCTAssertEqual(d.timingMs?.start, .init(p50: 1250, p90: 2400))
        XCTAssertEqual(d.timingMs?.wake, .init(p50: 350, p90: 350))
        XCTAssertEqual(d.timingMs?.hibernate, .init(p50: 900, p90: 900))
        XCTAssertNil(d.timingMs?.pause)
        XCTAssertEqual(d.timingMs?.agent, "claude-code")
        XCTAssertEqual(d.wakeFailed, 1)
        XCTAssertEqual(d.crashRestores, 1)
        XCTAssertEqual(d.hostCrashes, 2, "distinct host runs")
        XCTAssertEqual(d.pointsTaken, 1)
        XCTAssertEqual(d.templatesMade, 1)
        XCTAssertEqual(d.ui, true)
        XCTAssertNil(d.serve)
        XCTAssertEqual(d.upgradeMode, "auto")
        let m = UsageMessage.daily(UsageCommon(id: id, v: "0.33.0", channel: "beta", install: "tarball"), d)
        XCTAssertEqual(UsageSchema.problems(m.encoded(), commandNames: UsageCommandName.all), [])
        let text = String(decoding: m.encoded(), as: UTF8.self)
        for leak in ["my-secret", "/Users", "Mac15", "df-0123", "26.0.1", "secret"] { XCTAssertFalse(text.contains(leak), leak) }
    }

    func testTheStoreFactsAreReadForThatDayOnly() throws {
        let store = DozerStore(root: dir.appendingPathComponent("store"))
        try store.ensureDirectory()
        let m = try MetricsStore(url: store.metrics)
        let run = m.beginRun(.current(kind: "test", version: "0"))
        _ = m.record(run: run, action: "start", sandbox: "a", image: "lab", startedAt: date("2026-10-08"), durationMs: 500, ok: true)
        _ = m.record(run: run, action: "start", sandbox: "a", image: "lab", startedAt: date("2026-10-09"), durationMs: 700, ok: true)
        _ = m.record(run: run, action: "start", sandbox: "a", image: "lab", startedAt: date("2026-10-10"), durationMs: 900, ok: true)
        for (name, points) in [("a", 2), ("b", 0)] {
            for i in 0..<points {
                let p = store.layout(name).sandboxDirectory.appendingPathComponent("restore-points/p\(i)")
                try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
                try Data("{}".utf8).write(to: p.appendingPathComponent("meta.json"))
            }
            try FileManager.default.createDirectory(at: store.layout(name).sandboxDirectory, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: store.configFile(name))
        }
        let f = UsageStoreFacts.read(store, day: "2026-10-09", calendar: utc)
        XCTAssertEqual(f.events.map(\.durationMs), [700])
        XCTAssertEqual(f.sandboxes, 2)
        XCTAssertEqual(f.points, 2)
        // A store without a metrics database is not given one.
        let empty = DozerStore(root: dir.appendingPathComponent("empty"))
        _ = UsageStoreFacts.read(empty, day: "2026-10-09", calendar: utc)
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.metrics.path))
    }

    // MARK: the switches

    func testTheSwitches() throws {
        let dev = InstallMethod.development, brew = InstallMethod.homebrew(formula: "doz")
        let none = DozerSettings(text: nil)
        func on(official: Bool = true, method: InstallMethod = brew, settings: DozerSettings = DozerSettings(text: nil),
                env: [String: String] = [:], flag: Bool? = nil, guarded: Bool = false) -> UsageSwitch {
            UsageSwitches.decide(official: official, method: method, settings: settings, env: env, flag: flag, guarded: guarded)
        }
        XCTAssertTrue(on().on)
        XCTAssertEqual(on().settingSource, .default)
        XCTAssertFalse(on(official: false).on, "a build from the repository")
        XCTAssertTrue(on(official: false).why.contains("open-source repository"))
        XCTAssertFalse(on(guarded: true).on, "a test run")
        XCTAssertFalse(on(method: dev).on, "a development build")
        for v in ["1", "true", "yes"] { XCTAssertFalse(on(env: ["DO_NOT_TRACK": v]).on, "DO_NOT_TRACK=\(v)") }
        for v in ["", "0", "false"] { XCTAssertTrue(on(env: ["DO_NOT_TRACK": v]).on, "DO_NOT_TRACK=\(v)") }
        XCTAssertFalse(on(env: ["DO_NOT_TRACK": "1"], flag: true).on, "DO_NOT_TRACK wins over the flag")
        let off = DozerSettings(text: "[telemetry]\nsend_anonymous_usage_stats = false\n")
        XCTAssertFalse(on(settings: off).on)
        XCTAssertEqual(on(settings: off).settingSource, .file)
        XCTAssertTrue(on(settings: off, flag: true).on, "--send-anonymous-usage-stats for one command")
        XCTAssertFalse(on(settings: none, flag: false).on)
        XCTAssertEqual(on(settings: none, flag: false).settingSource, .flag)
        let envOff = DozerSettings(text: nil, environment: ["DOZ_SEND_ANONYMOUS_USAGE_STATS": "false"])
        XCTAssertFalse(on(settings: envOff).on)
        XCTAssertEqual(on(settings: envOff).settingSource, .env)
        // The setting is one of the closed schema's.
        let d = try XCTUnwrap(DozerSettings.definition("telemetry.send_anonymous_usage_stats"))
        XCTAssertEqual(d.defaultValue, .bool(true))
        XCTAssertEqual(d.environment, "DOZ_SEND_ANONYMOUS_USAGE_STATS")
        XCTAssertTrue(d.editableInUI)
    }

    /// In a test run the process decision is always off, installed sender or not.
    func testATestRunIsAlwaysOff() {
        Usage.install(send: { _ in XCTFail("sent in a test run") }, flush: { _ in }, signup: { _ in SignupResult(status: "confirmation-sent") })
        XCTAssertTrue(Usage.isOfficial)
        let d = UsageRuntime.decide(env: [:], settings: DozerSettings(text: nil), flag: true)
        XCTAssertFalse(d.on)
        XCTAssertTrue(d.testRun)
    }

    // MARK: once a day, once a version

    func testOnceADayAndOnceAVersion() throws {
        let fake: (String) -> UsageStoreFacts = { _ in UsageStoreFacts(sandboxes: 1) }
        func due(_ day: String, _ v: String = "0.33.0") throws -> [UsageMessage] {
            try recorder(day).due(version: v, channel: "stable", install: "homebrew", id: id, facts: fake, machine: machine, upgradeMode: "notify")
        }
        try recorder("2026-10-09").recordCommand("create")
        try recorder("2026-10-09").recordCommand("create")
        try recorder("2026-10-09").recordFailure("create", exitCode: 4)
        XCTAssertEqual(try due("2026-10-09").map(\.type), ["installed"], "a new version: installed, no daily yet")
        XCTAssertEqual(try due("2026-10-09"), [], "nothing twice")
        try recorder("2026-10-09").recordCommand("ls")
        // A later day: the first command closes the 9th; the next hand-over carries its daily, once.
        try recorder("2026-10-10").recordCommand("ls")
        let preview = try recorder("2026-10-10").due(version: "0.33.0", channel: "stable", install: "homebrew", id: id, facts: fake,
                                                     machine: machine, upgradeMode: "notify", take: false)
        XCTAssertEqual(preview.map(\.type), ["daily"], "looking takes nothing")
        let out = try due("2026-10-10")
        XCTAssertEqual(out.map(\.type), ["daily"])
        guard case .daily(_, let d) = out[0] else { return XCTFail() }
        XCTAssertEqual(d.commands, ["create": 2, "ls": 1])
        XCTAssertEqual(d.failed, ["create:4": 1])
        XCTAssertEqual(d.sandboxes, "1")
        XCTAssertEqual(try due("2026-10-10"), [])
        // Today so far.
        guard case .daily(_, let today) = recorder("2026-10-10").todaySoFar(UsageCommon(id: id, v: "0.33.0", channel: "stable", install: "homebrew"),
                                                                             facts: UsageStoreFacts(), machine: machine, upgradeMode: "notify")
        else { return XCTFail() }
        XCTAssertEqual(today.commands, ["ls": 1])
        // An upgrade, then a downgrade.
        guard case .upgraded(_, let from) = try XCTUnwrap(try due("2026-10-10", "0.34.0").first) else { return XCTFail() }
        XCTAssertEqual(from, "0.33.0")
        XCTAssertEqual(try due("2026-10-10", "0.33.0").map(\.type), ["installed"])
        // A day more than 7 days old is never sent.
        try recorder("2026-10-11").recordCommand("ls")
        try recorder("2026-10-25").recordCommand("ls")
        XCTAssertEqual(try due("2026-10-25"), [])
    }

    func testTheWizardsStepIsNeverMovedBack() throws {
        let r = recorder("2026-10-09")
        try r.recordOnboarding(via: "web", step: "settings", completed: false)
        try r.recordOnboarding(via: "web", step: "started", completed: false)
        XCTAssertEqual(files.load().current?.onboarding, .init(via: "web", step: "settings", completed: false))
        try r.recordOnboarding(via: "cli", step: "done", completed: true)
        try r.recordOnboarding(via: "cli", step: "started", completed: false)
        XCTAssertEqual(files.load().current?.onboarding, .init(via: "cli", step: "done", completed: true))
        try r.recordOnboarding(via: "web", step: "elsewhere", completed: false)
        XCTAssertEqual(files.load().current?.onboarding?.step, "done")
    }

    func testTurnedOffForgetsTheRecordedDaysAndResetMakesANewID() throws {
        try recorder("2026-10-09").recordCommand("ls")
        try recorder("2026-10-10").recordCommand("ls")
        XCTAssertNotNil(files.load().closed)
        recorder("2026-10-10").forgetDays()
        XCTAssertNil(files.load().current)
        XCTAssertNil(files.load().closed)
        let a = try files.id()
        XCTAssertEqual(try files.id(), a, "kept")
        XCTAssertEqual(a, a.lowercased())
        XCTAssertNotNil(UUID(uuidString: a))
        let b = try files.reset()
        XCTAssertNotEqual(a, b)
        var st = stat()
        XCTAssertEqual(stat(files.idFile.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
    }

    func testTheNoticeIsShownOnceAndOnlyToAPerson() {
        XCTAssertTrue(recorder("2026-10-09").takeNotice())
        XCTAssertFalse(recorder("2026-10-09").takeNotice())
        XCTAssertFalse(UsageHook.noticeApplies(["ls", "--json"], env: ["DOZ_TEST_USAGE_TTY": "1"]))
        XCTAssertFalse(UsageHook.noticeApplies(["-q", "ls"], env: ["DOZ_TEST_USAGE_TTY": "1"]))
        XCTAssertTrue(UsageHook.noticeApplies(["ls"], env: ["DOZ_TEST_USAGE_TTY": "1"]))
        XCTAssertTrue(UsageRecorder.notice.contains("doz config set telemetry.send_anonymous_usage_stats false"))
        XCTAssertTrue(UsageRecorder.notice.contains("doz telemetry show"))
    }

    // MARK: what the installed sender is handed

    func testAFakeSenderIsHandedOnlyMessagesOfTheList() {
        final class Sink: @unchecked Sendable { var sent: [Data] = []; var flushes: [TimeInterval] = []; let lock = NSLock() }
        let sink = Sink()
        XCTAssertFalse(Usage.isOfficial)
        XCTAssertEqual(UsageRecorder.handOver([.installed(UsageCommon(id: id, v: "0.33.0", channel: "stable", install: "homebrew"))]), 1,
                       "counted, but an open build has no one to hand it to")
        Usage.install(send: { d in sink.lock.withLock { sink.sent.append(d) } }, flush: { t in sink.lock.withLock { sink.flushes.append(t) } },
                      signup: { _ in SignupResult(status: "confirmation-sent") })
        let good = UsageMessage.installed(UsageCommon(id: id, v: "0.33.0", channel: "stable", install: "homebrew"))
        let badID = UsageMessage.installed(UsageCommon(id: "not-a-uuid", v: "0.33.0", channel: "stable", install: "homebrew"))
        let badInstall = UsageMessage.installed(UsageCommon(id: id, v: "0.33.0", channel: "stable", install: "development"))
        XCTAssertEqual(UsageRecorder.handOver([good, badID, badInstall]), 1)
        XCTAssertEqual(sink.sent, [good.encoded()])
        XCTAssertEqual(sink.flushes, [1], "one flush, capped at a second")
        XCTAssertEqual(UsageRecorder.handOver([]), 0)
        XCTAssertEqual(sink.flushes, [1], "nothing handed over: no flush")
    }

    // MARK: the sign-up

    func testTheSignupRequest() async throws {
        let r = try SignupRequest.make(email: "  me@example.com ", interests: ["support", "release-news"], source: "cli")
        XCTAssertEqual(r.email, "me@example.com")
        XCTAssertEqual(r.interests, ["release-news", "support"], "the list's order")
        XCTAssertFalse("\(r)".contains("me@example.com"), "the description is redacted")
        XCTAssertFalse(String(reflecting: r).contains("me@example.com"))
        for e in ["", "me", "me@", "@x.com", "me@x", "me @x.com", "me@x..com", "<me>@x.com", "a@b@c.com"] {
            XCTAssertThrowsError(try SignupRequest.make(email: e, interests: ["support"], source: "cli"), e)
        }
        for i in [[], ["news"], ["support", "support"]] {
            XCTAssertThrowsError(try SignupRequest.make(email: "me@example.com", interests: i, source: "cli"), "\(i)")
        }
        XCTAssertThrowsError(try SignupRequest.make(email: "me@example.com", interests: ["support"], source: "elsewhere"))
        // No package: refused, pointing at the website — the address is never in the message.
        do { _ = try await Usage.signup(r); XCTFail() } catch {
            XCTAssertTrue("\(error)".contains(Usage.signupPage))
            XCTAssertFalse("\(error)".contains("me@example.com"))
        }
        final class Got: @unchecked Sendable { var r: SignupRequest? }
        let got = Got()
        Usage.install(send: { _ in }, flush: { _ in }, signup: { req in got.r = req; return SignupResult(status: "confirmation-sent") })
        let answer = try await Usage.signup(SignupRequest(email: "me@example.com", interests: ["support"], source: "onboarding-cli"))
        XCTAssertEqual(answer.status, "confirmation-sent")
        XCTAssertEqual(got.r, SignupRequest(email: "me@example.com", interests: ["support"], source: "onboarding-cli"))
        Usage.install(send: { _ in }, flush: { _ in }, signup: { _ in SignupResult(status: "something-else") })
        do { _ = try await Usage.signup(r); XCTFail("an unknown answer") } catch {}
    }

    // MARK: the CLI's hook

    func testCommandNamesAreDozsOwnWordsOnly() {
        XCTAssertEqual(UsageCommandName.resolve(["start", "mybox"]), "start")
        XCTAssertEqual(UsageCommandName.resolve(["ui", "start", "--port", "9000"]), "ui start")
        XCTAssertEqual(UsageCommandName.resolve(["--store", "/x/image", "image", "ls"]), "image ls")
        XCTAssertEqual(UsageCommandName.resolve(["suspend", "mybox"]), "pause", "an alias counts as its command")
        XCTAssertEqual(UsageCommandName.resolve(["net", "mybox", "allow", "x.com"]), "net")
        XCTAssertNil(UsageCommandName.resolve(["mybox"]))
        XCTAssertNil(UsageCommandName.resolve([]))
        let all = UsageCommandName.all
        XCTAssertTrue(all.isSuperset(of: ["telemetry show", "telemetry reset", "signup", "ui start", "create"]))
        for n in all { XCTAssertTrue(UsageSchema.isCommandName(n), n) }
        XCTAssertFalse(UsageHook.counts(["telemetry", "show"]), "looking never sends")
        XCTAssertFalse(UsageHook.counts(["ls", "--help"]))
        XCTAssertFalse(UsageHook.counts(["--version"]))
        XCTAssertFalse(UsageHook.counts(["host", "start", "--launched"]))
        XCTAssertFalse(UsageHook.counts(["host", "upgrade-check"]))
        XCTAssertTrue(UsageHook.counts(["ls"]))
        XCTAssertNil(UsageHook(["telemetry"]).name)
        XCTAssertEqual(UsageHook(["ls", "--no-send-anonymous-usage-stats"]).flag, false)
        XCTAssertEqual(UsageHook(["--no-send-anonymous-usage-stats", "ls", "--send-anonymous-usage-stats"]).flag, true, "the last wins")
        XCTAssertNil(UsageHook(["ls"]).flag)
        XCTAssertEqual(UsageHook.parserArguments(["--send-anonymous-usage-stats", "ls", "--no-send-anonymous-usage-stats"]),
                       ["ls", "--no-send-anonymous-usage-stats"], "taken out only before the command")
        XCTAssertEqual(UsageHook.parserArguments(["--store", "--no-send-anonymous-usage-stats", "ls"]),
                       ["--store", "--no-send-anonymous-usage-stats", "ls"], "an option's value is left alone")
        XCTAssertNoThrow(try DozerCommand.parseAsRoot(UsageHook.parserArguments(["--no-send-anonymous-usage-stats", "ls", "--send-anonymous-usage-stats"])))
    }

    /// `doz telemetry show` in a build from the repository: it says so, sends nothing, and its preview fits the list.
    func testTelemetryShowInAnOpenBuild() throws {
        let store = DozerStore(root: dir.appendingPathComponent("store"))
        let env = ["XDG_CONFIG_HOME": dir.appendingPathComponent("xdg").path, "HOME": dir.path]
        let r = TelemetryShow.report(store: store, flag: nil, env: env)
        XCTAssertFalse(r.official)
        XCTAssertFalse(r.on)
        XCTAssertTrue(r.why.contains("open-source repository"))
        XCTAssertEqual(r.next, [])
        XCTAssertNil(r.installId, "nothing is made")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("xdg").path), "nothing written")
        let today = try HostWire.encoder.encode(r.today)
        XCTAssertEqual(UsageSchema.problems(today), [], String(decoding: today, as: UTF8.self))
        // Official, but a test run: still off, and why.
        Usage.install(send: { _ in XCTFail("sent") }, flush: { _ in }, signup: { _ in SignupResult(status: "confirmation-sent") })
        let o = TelemetryShow.report(store: store, flag: nil, env: env)
        XCTAssertTrue(o.official)
        XCTAssertFalse(o.on)
        XCTAssertEqual(o.why, "off in a test run")
    }

    // MARK: reports 1–9: the rest of the daily, from a fixed history

    func at(_ s: String) -> Date {            // "2026-10-09 09:04" (UTC)
        let p = s.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" }).map { Int($0)! }
        return utc.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: p[3], minute: p[4]))!
    }
    /// An action row that ENDS at `end` (the timeline uses a row's end) and leaves the sandbox in `phase`.
    func row(_ action: String, _ sandbox: String, _ image: String, end: String, phase: String? = nil, ok: Bool? = true,
             ms: Double = 1000, detail: String? = nil) -> MetricsEvent {
        MetricsEvent(id: 1, run: 1, parent: nil, kind: .action, sandbox: sandbox, image: image, action: action, phaseBefore: nil,
                     phaseAfter: phase, startedAt: at(end).addingTimeInterval(-ms / 1000), durationMs: ms, ok: ok, error: nil, bytes: nil,
                     detailJSON: detail, appVersion: nil, machine: nil, macOS: nil)
    }

    /// The fixed history (UTC): the reported day is 2026-10-09.
    ///   a  claude-code  created 10-08 09:00; running from 10-08 22:00, hibernated 10-09 01:00 (3 h, across midnight); asleep
    ///      until 09:00 (8 h, an edge); running again, removed 09:04 (4 min; 1 day 4 min old).
    ///   b  pi            created 10-09 10:00 (api-key); running from 10:00; its agent working 10:05–12:05; then nothing until
    ///      it is removed at 20:10 — 8 h 05 with no activity: left running idle. Created and removed the same day.
    ///   c  claude-code  running since 10-07 08:00, all day, its network used every hour: never idle, never ended.
    var history: [MetricsEvent] {
        [
            row("create", "c", "claude-code", end: "2026-10-07 07:00", phase: "off", ms: 0, detail: #"{"network":"agent","account":"mac"}"#),
            row("start", "c", "claude-code", end: "2026-10-07 08:00", phase: "running"),
            row("create", "a", "claude-code", end: "2026-10-08 09:00", phase: "off", ms: 0, detail: #"{"network":"agent","account":"mac"}"#),
            row("start", "a", "claude-code", end: "2026-10-08 22:00", phase: "running", ms: 1240),
            row("hibernate", "a", "claude-code", end: "2026-10-09 01:00", phase: "hibernated", ms: 880),
            row("wake", "a", "claude-code", end: "2026-10-09 09:00", phase: "running", ms: 340),
            row("delete sandbox", "a", "claude-code", end: "2026-10-09 09:04", phase: "off"),
            row("create", "b", "pi", end: "2026-10-09 10:00", phase: "off", ms: 0, detail: #"{"network":"locked","account":"api-key"}"#),
            row("start", "b", "pi", end: "2026-10-09 10:00", phase: "running", ms: 2100),
            row("session open", "b", "pi", end: "2026-10-09 10:02"),
            row("agent status", "b", "pi", end: "2026-10-09 10:05", ms: 0),
            row("agent working", "b", "pi", end: "2026-10-09 12:05", ms: 7_200_000),
            row("delete sandbox", "b", "pi", end: "2026-10-09 20:10", phase: "off"),
            row("prepare", "x", "claude-code", end: "2026-10-09 11:00", ok: false, detail: #"{"failedStep":"bake-step"}"#),
            row("prepare", "x", "claude-code", end: "2026-10-09 11:30", ok: false, detail: #"{"failedStep":"kernel-download"}"#),
        ]
    }
    var facts: UsageStoreFacts {
        let h = history
        let day = h.filter { $0.startedAt >= at("2026-10-09 00:00") }
        let hourly = (0..<64).map { at("2026-10-07 08:00").addingTimeInterval(Double($0) * 3600 + 1800) }
        return UsageStoreFacts(events: day, history: h, activeMinutes: ["c": hourly], sandboxes: 1, points: 0, storeBytes: 25_000_000_000,
                               serveDevices: 3, rules: true, github: "read", until: at("2026-10-10 00:00"))
    }

    func testTheTimeBlockFromAFixedHistory() throws {
        var day = UsageDay(day: "2026-10-09")
        day.commands = ["ui start": 1]
        day.features = ["app"]
        let d = UsageDailyBuilder.build(day, facts: facts, machine: machine, upgradeMode: "notify", firstSeen: at("2026-10-09 09:50"), calendar: utc)
        let t = try XCTUnwrap(d.time)
        XCTAssertEqual(t.running, ["2-8h": 1, "<5m": 1, "8h+": 1], "a's 3 h across midnight and its 4 min; b's 10 h 10")
        XCTAssertEqual(t.asleep, ["8-24h": 1], "a asleep exactly 8 h: the lower edge is inclusive")
        XCTAssertEqual(t.removedAge, ["1-7d": 1, "1h-1d": 1], "a: 1 d 4 min; b: created and removed the same day, 10 h 10")
        XCTAssertEqual(t.runningTotal, "8h+")
        XCTAssertEqual(t.agentWorking, ["pi": "2-8h"])
        XCTAssertEqual(t.idleRunning8h, 1, "b only: c's network was in use every hour")
        XCTAssertEqual(d.runningMax, "2-5", "c with a, then c with b")
        XCTAssertEqual(d.created?.account, ["api-key": 1])
        XCTAssertEqual(d.created?.network, ["locked": 1])
        XCTAssertNil(d.firstSandbox, "the store's first sandbox was made on another day")
        XCTAssertEqual(d.timeToFirstSession, "5-30m", "first seen 09:50, first session 10:02")
        XCTAssertEqual(d.prepFailed, ["bake-step": 1, "kernel-download": 1])
        XCTAssertEqual(d.storeGB, "20-100")
        XCTAssertEqual(d.serveDevices, "2-5")
        XCTAssertEqual(d.rules, true)
        XCTAssertEqual(d.github, "read")
        XCTAssertEqual(d.agentStatus, true)
        XCTAssertEqual(d.app, true)
        XCTAssertEqual(d.timingMs?.wake, .init(p50: 350, p90: 350))
        let m = UsageMessage.daily(UsageCommon(id: id, v: "0.33.0", channel: "stable", install: "homebrew"), d)
        XCTAssertEqual(UsageSchema.problems(m.encoded(), commandNames: UsageCommandName.all), [])
        let text = String(decoding: m.encoded(), as: UTF8.self)
        for leak in ["\"a\"", "\"b\"", "\"c\"", "\"x\"", "2026"] { XCTAssertFalse(text.contains(leak), "\(leak) in \(text)") }
    }

    func testTheDayBeforeAndTheFirstSandbox() throws {
        // 10-08: a created (the store's second sandbox), running 22:00 → past midnight — not ended, so not counted yet,
        // but 2 h of running time and c alongside it.
        let d = UsageDailyBuilder.build(UsageDay(day: "2026-10-08"), facts: UsageStoreFacts(events: history.filter {
            $0.startedAt >= at("2026-10-08 00:00") && $0.startedAt < at("2026-10-09 00:00") }, history: history.filter { $0.startedAt < at("2026-10-09 00:00") },
            until: at("2026-10-09 00:00")), machine: machine, upgradeMode: "notify", calendar: utc)
        XCTAssertNil(d.time?.running, "a's stretch ends tomorrow; c's never")
        XCTAssertEqual(d.time?.runningTotal, "8h+", "c all day")
        XCTAssertEqual(d.runningMax, "2-5")
        XCTAssertNil(d.firstSandbox)
        let first = UsageDailyBuilder.build(UsageDay(day: "2026-10-07"), facts: UsageStoreFacts(events: Array(history.prefix(2)), until: at("2026-10-08 00:00")),
                                            machine: machine, upgradeMode: "notify", calendar: utc)
        XCTAssertEqual(first.firstSandbox, true)
        XCTAssertEqual(first.time?.runningTotal, "8h+", "c from 08:00")
        XCTAssertNil(first.timeToFirstSession, "no session yet")
        // A stretch still open when the day is looked at mid-day (`telemetry show`): counted up to now.
        let partial = UsageTimeline.day(history, activeMinutes: [:], dayStart: at("2026-10-09 00:00"), until: at("2026-10-09 00:20"))
        XCTAssertEqual(partial.time?.runningTotal, "30m-2h", "a 20 min + c 20 min")
        XCTAssertEqual(partial.runningMax, 2)
    }

    func testTheBucketEdges() {
        let m: TimeInterval = 60, h: TimeInterval = 3600, d: TimeInterval = 86_400
        XCTAssertEqual([0, 5 * m - 1, 5 * m, 30 * m, 2 * h, 8 * h - 1, 8 * h].map(UsageTimeline.running), ["<5m", "<5m", "5-30m", "30m-2h", "2-8h", "2-8h", "8h+"])
        XCTAssertEqual([h - 1, h, 8 * h, 24 * h, 7 * d - 1, 7 * d].map(UsageTimeline.asleep), ["<1h", "1-8h", "8-24h", "1-7d", "1-7d", "7d+"])
        XCTAssertEqual([h - 1, h, d, 7 * d, 30 * d].map(UsageTimeline.removedAge), ["<1h", "1h-1d", "1-7d", "7-30d", "30d+"])
        XCTAssertEqual([1, 30 * m, 2 * h, 8 * h].map(UsageTimeline.total), ["<30m", "30m-2h", "2-8h", "8h+"])
        XCTAssertEqual([0, 5 * m, 30 * m].map(UsageTimeline.firstSession), ["<5m", "5-30m", "30m+"])
        XCTAssertEqual(["step: apt-get install -y my-secret-package", "downloaded vmlinux (12 MB)", "VM created and booted", "something new"]
                        .map(PreparationStepID.of), ["bake-step", "kernel-download", "vm-boot", "other"])
        for id in ["image-pull", "bake-vm-boot", "restore-point-clone-running"] {
            XCTAssertNotNil(id.range(of: #"^[a-z0-9][a-z0-9._-]{0,47}$"#, options: .regularExpression), id)
        }
    }

    func testFirstSandboxAndFirstSessionAreSentOnce() throws {
        let created = [row("create", "c", "lab", end: "2026-10-09 10:00", phase: "off", ms: 0),
                       row("session open", "c", "lab", end: "2026-10-09 10:40")]
        let f: (String) -> UsageStoreFacts = { _ in UsageStoreFacts(events: created, until: self.at("2026-10-10 00:00")) }
        func due(_ day: String) throws -> [UsageMessage] {
            try recorder(day).due(version: "0.33.0", channel: "stable", install: "homebrew", id: id, facts: f, machine: machine, upgradeMode: "notify")
        }
        try UsageRecorder(files: files, now: at("2026-10-09 10:05"), calendar: utc).recordCommand("new")
        _ = try due("2026-10-09")
        try recorder("2026-10-10").recordCommand("ls")
        guard case .daily(_, let d) = try XCTUnwrap(try due("2026-10-10").first) else { return XCTFail() }
        XCTAssertEqual(d.firstSandbox, true)
        XCTAssertEqual(d.timeToFirstSession, "30m+", "first seen 10:05, first session 10:40")
        XCTAssertEqual(files.load().firstSandboxSent, true)
        // Were the same day reported again (history cleared and re-made), neither goes twice.
        var s = files.load(); s.closed = UsageDay(day: "2026-10-09"); s.closed?.commands = ["ls": 1]; s.lastDaily = nil
        try files.save(s)
        guard case .daily(_, let again) = try XCTUnwrap(try due("2026-10-10").first) else { return XCTFail() }
        XCTAssertNil(again.firstSandbox)
        XCTAssertNil(again.timeToFirstSession)
    }

    func testTheAppFeatureIsAClosedWord() throws {
        let r = recorder("2026-10-09")
        try r.recordFeature("app")
        try r.recordFeature("app")
        try r.recordFeature("/Users/me")
        XCTAssertEqual(files.load().current?.features, ["app"])
    }
}
