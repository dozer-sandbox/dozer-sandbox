import Foundation
import SnoozeContainerKit
import XCTest
@testable import SnoozeHost

/// The host's model without a VM: images and specs, the store's files, the read-only (in-process)
/// core, the settle delay, and the exec context.
final class HostCoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("snooze-unit-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testStoreResolution() {
        XCTAssertEqual(SnoozeStore.resolve("/x/y", environment: ["SNOOZE_STORE": "/z"]).root.path, "/x/y")
        XCTAssertEqual(SnoozeStore.resolve(nil, environment: ["SNOOZE_STORE": "/z"]).root.path, "/z")
        XCTAssertTrue(SnoozeStore.resolve(nil, environment: [:]).root.path.hasSuffix("Library/Application Support/SnoozeContainerKit"))
        let s = SnoozeStore(root: root)
        XCTAssertEqual(s.socket.lastPathComponent, "host.sock")
        XCTAssertTrue(s.socketPathFits)
        XCTAssertFalse(SnoozeStore(root: URL(fileURLWithPath: "/" + String(repeating: "d", count: 120))).socketPathFits)
        XCTAssertFalse(s.hostIsRunning(), "no lock holder")
    }

    func testTheLockSaysWhetherAHostRuns() throws {
        let s = SnoozeStore(root: root)
        let fd = open(s.lockFile.path, O_RDWR | O_CREAT, 0o600)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        // flock is per open file description: a second open sees it held.
        XCTAssertTrue(s.hostIsRunning())
        flock(fd, LOCK_UN)
        XCTAssertFalse(s.hostIsRunning())
    }

    func testMemorySizes() {
        XCTAssertEqual(SnoozeImages.parseMemory("2G"), 2048)
        XCTAssertEqual(SnoozeImages.parseMemory("1.5g"), 1536)
        XCTAssertEqual(SnoozeImages.parseMemory("512M"), 512)
        XCTAssertEqual(SnoozeImages.parseMemory("512mib"), 512)
        XCTAssertEqual(SnoozeImages.parseMemory("2048"), 2048)
        XCTAssertNil(SnoozeImages.parseMemory("lots"))
        XCTAssertNil(SnoozeImages.parseMemory("-1G"))
        XCTAssertNil(SnoozeImages.parseMemory(""))
    }

    func testSessionNames() {
        XCTAssertEqual(SnoozeImages.sessionName(for: ["/usr/bin/top", "-b"]), "top")
        XCTAssertEqual(SnoozeImages.sessionName(for: ["claude"]), "claude")
        XCTAssertEqual(SnoozeImages.sessionName(for: ["weird name!"]), "weirdname")
        XCTAssertEqual(SnoozeImages.sessionName(for: [".hidden"]), "cmd")
        XCTAssertEqual(SnoozeImages.sessionName(for: []), "cmd")
    }

    func testSpecsFromImages() throws {
        let store = SnoozeStore(root: root)
        let (lab, labName) = try SnoozeImages.spec(name: "box", options: CreateOptions(image: "lab", workspace: root.path), store: store, environment: [:])
        XCTAssertEqual(labName, "lab")
        XCTAssertEqual(lab.network, .proxied(.bake), "the lab defaults to proxied, registries only")
        XCTAssertEqual(lab.bakePackages, ["bash", "ncurses"])
        XCTAssertEqual(lab.memoryMiB, 1024)
        XCTAssertEqual(lab.shares, [Share(hostPath: root.standardizedFileURL.path, guestPath: "/workspace")])
        XCTAssertEqual(lab.storeRoot, store.root)
        let (cc, _) = try SnoozeImages.spec(name: "cc", options: CreateOptions(image: "claude-code", memoryMiB: 4096), store: store,
                                            environment: ["SNOOZE_KERNEL_CACHE": "/k"])
        XCTAssertEqual(cc.recipe?.name, "claude-code")
        XCTAssertEqual(cc.network, .proxied(.agent))
        XCTAssertEqual(cc.memoryMiB, 4096)
        XCTAssertEqual(cc.kernelCacheDirectory?.path, "/k")
        let (nat, _) = try SnoozeImages.spec(name: "n", options: CreateOptions(image: "pi", network: "nat"), store: store,
                                             environment: ["SNOOZE_SUBNET": "192.168.231.0/24"])
        XCTAssertEqual(nat.network, .nat)
        XCTAssertEqual(nat.subnet, "192.168.231.0/24")
        XCTAssertThrowsError(try SnoozeImages.spec(name: "x", options: CreateOptions(image: "nope"), store: store, environment: [:]))
        XCTAssertThrowsError(try SnoozeImages.spec(name: "x", options: CreateOptions(image: "lab", network: "wide-open"), store: store, environment: [:]))
        XCTAssertThrowsError(try SnoozeImages.spec(name: "Bad_Name", options: CreateOptions(image: "lab"), store: store, environment: [:]))
        XCTAssertThrowsError(try SnoozeImages.spec(name: "x", options: CreateOptions(image: "lab", workspace: "/does/not/exist"), store: store, environment: [:]))
    }

    func testDefaultSessions() throws {
        let store = SnoozeStore(root: root)
        func cfg(_ image: String) throws -> SandboxConfig {
            let (s, n) = try SnoozeImages.spec(name: "x", options: CreateOptions(image: image), store: store, environment: [:])
            return SandboxConfig(name: "x", image: n, spec: s, workspace: nil)
        }
        XCTAssertEqual(try cfg("lab").defaultSession.name, "shell")
        XCTAssertEqual(try cfg("lab").defaultSession.argv, ["bash", "-l"])
        XCTAssertEqual(try cfg("claude-code").defaultSession.argv, ["claude"])
        XCTAssertEqual(try cfg("pi").defaultSession.name, "pi")
    }

    func testConfigRoundTripsAndNeverHoldsASecret() throws {
        let store = SnoozeStore(root: root)
        let (s, n) = try SnoozeImages.spec(name: "x", options: CreateOptions(image: "claude-code"), store: store, environment: [:])
        let c = SandboxConfig(name: "x", image: n, spec: s, workspace: nil, credentialSources: ["anthropic": "keychain:svc"])
        try c.write(store.configFile("x"))
        let back = try XCTUnwrap(SandboxConfig.read(store.configFile("x")))
        XCTAssertEqual(back.spec, c.spec)
        XCTAssertEqual(back.credentialSources, c.credentialSources)
        XCTAssertEqual(back.createdAt.timeIntervalSince1970, c.createdAt.timeIntervalSince1970, accuracy: 0.001, "ISO-8601 with milliseconds")
        XCTAssertEqual(store.sandboxNames(), ["x"])
        let text = try String(contentsOf: store.configFile("x"), encoding: .utf8)
        XCTAssertFalse(text.contains("sk-ant"), "only where a key comes from")
    }

    func testRecoveryIsNeededOnlyForALiveVMsRecord() throws {
        let store = SnoozeStore(root: root)
        let (s, n) = try SnoozeImages.spec(name: "x", options: CreateOptions(image: "lab"), store: store, environment: [:])
        try SandboxConfig(name: "x", image: n, spec: s, workspace: nil).write(store.configFile("x"))
        XCTAssertEqual(store.needsRecovery(), [])
        for (phase, needs) in [(Phase.off, false), (.deepAsleep, false), (.running, true), (.asleep, true)] {
            try PersistedSandbox(spec: s, phase: phase, machineIdentifier: Data([1]), macAddress: nil, subnet: nil, shareTags: [:])
                .write(to: store.layout("x").persistedState)
            XCTAssertEqual(store.needsRecovery() == ["x"], needs, "\(phase)")
        }
    }

    func testReadOnlyCoreAnswersFromTheStore() async throws {
        let store = SnoozeStore(root: root)
        let (s, n) = try SnoozeImages.spec(name: "x", options: CreateOptions(image: "lab"), store: store, environment: [:])
        try SandboxConfig(name: "x", image: n, spec: s, workspace: nil).write(store.configFile("x"))
        let core = HostCore(store: store, readOnly: true, version: "test")
        await core.load()
        let ls = await core.handle(HostRequest(.ls))
        let rows = try XCTUnwrap(ls.result).decode([SandboxInfo].self)
        XCTAssertEqual(rows.map(\.name), ["x"])
        XCTAssertEqual(rows.first?.phase, "off")
        XCTAssertEqual(rows.first?.ramHeldMiB, 0)
        XCTAssertEqual(rows.first?.network, "bake")
        // Anything that changes a sandbox needs the host.
        let start = await core.handle(HostRequest(.start, name: "x"))
        XCTAssertEqual(start.error?.code, .unavailable)
        let missing = await core.handle(HostRequest(.inspect, name: "nope"))
        XCTAssertEqual(missing.error?.code, .notFound)
        var future = HostRequest(.ls)
        future.v = HostProtocol.version + 1
        let v = await core.handle(future)
        XCTAssertEqual(v.error?.code, .version)
        // A deep-asleep record left by another process reads as deep asleep.
        let layout = store.layout("x")
        try FileManager.default.createDirectory(at: layout.sandboxDirectory, withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: layout.rootfs)
        try Data("snap".utf8).write(to: layout.snapshot)
        try PersistedSandbox(spec: s, phase: .deepAsleep, machineIdentifier: Data([1]), macAddress: nil, subnet: nil, shareTags: [:])
            .write(to: layout.persistedState)
        let lsAgain = await core.handle(HostRequest(.ls))
        let again = try XCTUnwrap(lsAgain.result).decode([SandboxInfo].self)
        XCTAssertEqual(again.first?.phase, "deepAsleep")
    }

    func testSettleDelay() {
        XCTAssertEqual(HostCore.settleDelay(since: nil), .zero)
        XCTAssertEqual(HostCore.settleDelay(since: .seconds(1)), .seconds(2))
        XCTAssertEqual(HostCore.settleDelay(since: .seconds(5)), .zero)
    }

    func testExecRunsLikeASession() throws {
        let store = SnoozeStore(root: root)
        let (cc, n) = try SnoozeImages.spec(name: "x", options: CreateOptions(image: "claude-code"), store: store, environment: [:])
        let agent = SandboxConfig(name: "x", image: n, spec: cc, workspace: nil)
        let ctx = HostCore.execContext(config: agent, environment: ["A": "1"], workdir: nil, user: nil)
        XCTAssertEqual(ctx.user, "agent")
        XCTAssertEqual(ctx.workdir, "/workspace")
        XCTAssertEqual(ctx.environment["HOME"], "/home/agent")
        XCTAssertEqual(ctx.environment["A"], "1")
        XCTAssertNil(HostCore.execContext(config: agent, environment: [:], workdir: nil, user: "root").user)
        let (lab, ln) = try SnoozeImages.spec(name: "y", options: CreateOptions(image: "lab"), store: store, environment: [:])
        XCTAssertEqual(HostCore.execContext(config: SandboxConfig(name: "y", image: ln, spec: lab, workspace: nil), environment: [:], workdir: nil, user: nil).workdir, "/root")
        XCTAssertEqual(HostCore.execContext(config: SandboxConfig(name: "y", image: ln, spec: lab, workspace: "/w"), environment: [:], workdir: nil, user: nil).workdir, "/workspace")
    }

    func testMetricsStoreIsSandboxLabsSchema() throws {
        let m = try MetricsStore(url: root.appendingPathComponent("metrics.sqlite"))
        let run = m.beginRun(.current(kind: "snooze host", version: "test"))
        let id = m.begin(run: run, action: "wake", sandbox: "x", image: "lab", phaseBefore: "deepAsleep")
        m.record(run: run, action: MetricsStepKey.key(for: "restored VM state from disk"), kind: .step, sandbox: "x", image: "lab",
                 startedAt: Date(), durationMs: 230, parent: id)
        m.finish(id, phaseAfter: "running", durationMs: 300, ok: true)
        let rows = m.summary()
        XCTAssertEqual(rows.map(\.action), ["wake", "step: restore state"])
        XCTAssertEqual(rows.first?.medianMs, 300)
        XCTAssertEqual(m.schemaVersion, MetricsStore.currentSchemaVersion)
        XCTAssertTrue(m.csv().hasPrefix(MetricsStore.csvHeader.joined(separator: ",")))
    }
}
