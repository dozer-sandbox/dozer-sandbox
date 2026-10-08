import Foundation
import DozerKit
import XCTest
@testable import DozerHost

/// The host's model without a VM: images and specs, the store's files, the read-only (in-process)
/// core, the settle delay, and the exec context.
final class HostCoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-unit-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testStoreResolution() {
        XCTAssertEqual(DozerStore.resolve("/x/y", environment: ["DOZ_STORE": "/z"]).root.path, "/x/y")
        XCTAssertEqual(DozerStore.resolve(nil, environment: ["DOZ_STORE": "/z"]).root.path, "/z")
        XCTAssertTrue(DozerStore.resolve(nil, environment: [:]).root.path.hasSuffix("Library/Application Support/dozer-sandbox"))
        let s = DozerStore(root: root)
        XCTAssertEqual(s.socket.lastPathComponent, "host.sock")
        XCTAssertTrue(s.socketPathFits)
        XCTAssertFalse(DozerStore(root: URL(fileURLWithPath: "/" + String(repeating: "d", count: 120))).socketPathFits)
        XCTAssertFalse(s.hostIsRunning(), "no lock holder")
    }

    func testTheLockSaysWhetherAHostRuns() throws {
        let s = DozerStore(root: root)
        let fd = open(s.lockFile.path, O_RDWR | O_CREAT, 0o600)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        // flock is per open file description: a second open sees it held.
        XCTAssertTrue(s.hostIsRunning())
        flock(fd, LOCK_UN)
        XCTAssertFalse(s.hostIsRunning())
    }

    func testMemorySizes() {
        XCTAssertEqual(DozerImages.parseMemory("2G"), 2048)
        XCTAssertEqual(DozerImages.parseMemory("1.5g"), 1536)
        XCTAssertEqual(DozerImages.parseMemory("512M"), 512)
        XCTAssertEqual(DozerImages.parseMemory("512mib"), 512)
        XCTAssertEqual(DozerImages.parseMemory("2048"), 2048)
        XCTAssertNil(DozerImages.parseMemory("lots"))
        XCTAssertNil(DozerImages.parseMemory("-1G"))
        XCTAssertNil(DozerImages.parseMemory(""))
    }

    func testSessionNames() {
        XCTAssertEqual(DozerImages.sessionName(for: ["/usr/bin/top", "-b"]), "top")
        XCTAssertEqual(DozerImages.sessionName(for: ["claude"]), "claude")
        XCTAssertEqual(DozerImages.sessionName(for: ["weird name!"]), "weirdname")
        XCTAssertEqual(DozerImages.sessionName(for: [".hidden"]), "cmd")
        XCTAssertEqual(DozerImages.sessionName(for: []), "cmd")
    }

    func testSpecsFromImages() throws {
        let store = DozerStore(root: root)
        let (lab, labName) = try DozerImages.spec(name: "box", options: CreateOptions(image: "lab", workspace: root.path), store: store, environment: [:])
        XCTAssertEqual(labName, "lab")
        XCTAssertEqual(lab.network, .proxied(.bake), "the lab defaults to proxied, registries only")
        XCTAssertEqual(lab.bakePackages, ["bash", "ncurses", "fd", "tmux"], "599: tmux (sessions.tmux)")
        XCTAssertEqual(lab.memoryMiB, 1024)
        XCTAssertEqual(lab.shares, [Share(hostPath: root.standardizedFileURL.path, guestPath: "/workspace")])
        XCTAssertEqual(lab.storeRoot, store.root)
        let (cc, _) = try DozerImages.spec(name: "cc", options: CreateOptions(image: "claude-code", memoryMiB: 4096), store: store,
                                            environment: ["DOZ_KERNEL_CACHE": "/k"])
        XCTAssertEqual(cc.imageSpec?.name, "claude-code")
        // 597 (P5): Standard is stored as its permissions (by name), the hosts coming from this build.
        XCTAssertEqual(cc.network, .proxied(.permissions(AgentPermissions.preset("agent", base: "node")!, preset: "agent")))
        XCTAssertEqual(AgentPermissions.preset("agent", base: "node"), ["model", "update", "install:system", "install:node", "github", "error-reports"])
        XCTAssertEqual(cc.memoryMiB, 4096)
        XCTAssertEqual(cc.kernelCacheDirectory?.path, "/k")
        let (nat, _) = try DozerImages.spec(name: "n", options: CreateOptions(image: "pi", network: "nat"), store: store,
                                             environment: ["DOZ_SUBNET": "192.168.231.0/24"])
        XCTAssertEqual(nat.network, .nat)
        XCTAssertEqual(nat.subnet, "192.168.231.0/24")
        XCTAssertThrowsError(try DozerImages.spec(name: "x", options: CreateOptions(image: "nope"), store: store, environment: [:]))
        XCTAssertThrowsError(try DozerImages.spec(name: "x", options: CreateOptions(image: "lab", network: "wide-open"), store: store, environment: [:]))
        XCTAssertThrowsError(try DozerImages.spec(name: "Bad_Name", options: CreateOptions(image: "lab"), store: store, environment: [:]))
        XCTAssertThrowsError(try DozerImages.spec(name: "x", options: CreateOptions(image: "lab", workspace: "/does/not/exist"), store: store, environment: [:]))
    }

    func testDefaultSessions() throws {
        let store = DozerStore(root: root)
        func cfg(_ image: String) throws -> SandboxConfig {
            let (s, n) = try DozerImages.spec(name: "x", options: CreateOptions(image: image), store: store, environment: [:])
            return SandboxConfig(name: "x", image: n, spec: s, workspace: nil)
        }
        XCTAssertEqual(try cfg("lab").defaultSession.name, "shell")
        XCTAssertEqual(try cfg("lab").defaultSession.argv, ["bash", "-l"])
        XCTAssertEqual(try cfg("claude-code").defaultSession.argv, ["claude"])
        XCTAssertEqual(try cfg("pi").defaultSession.name, "pi")
    }

    func testConfigRoundTripsAndNeverHoldsASecret() throws {
        let store = DozerStore(root: root)
        let (s, n) = try DozerImages.spec(name: "x", options: CreateOptions(image: "claude-code"), store: store, environment: [:])
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
        let store = DozerStore(root: root)
        let (s, n) = try DozerImages.spec(name: "x", options: CreateOptions(image: "lab"), store: store, environment: [:])
        try SandboxConfig(name: "x", image: n, spec: s, workspace: nil).write(store.configFile("x"))
        XCTAssertEqual(store.needsRecovery(), [])
        for (phase, needs) in [(Phase.off, false), (.hibernated, false), (.running, true), (.asleep, true)] {
            try PersistedSandbox(spec: s, phase: phase, machineIdentifier: Data([1]), macAddress: nil, subnet: nil, shareTags: [:])
                .write(to: store.layout("x").persistedState)
            XCTAssertEqual(store.needsRecovery() == ["x"], needs, "\(phase)")
        }
    }

    func testReadOnlyCoreAnswersFromTheStore() async throws {
        let store = DozerStore(root: root)
        let (s, n) = try DozerImages.spec(name: "x", options: CreateOptions(image: "lab"), store: store, environment: [:])
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
        // A hibernated record left by another process reads as hibernated.
        let layout = store.layout("x")
        try FileManager.default.createDirectory(at: layout.sandboxDirectory, withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: layout.rootfs)
        try Data("snap".utf8).write(to: layout.snapshot)
        try PersistedSandbox(spec: s, phase: .hibernated, machineIdentifier: Data([1]), macAddress: nil, subnet: nil, shareTags: [:])
            .write(to: layout.persistedState)
        let lsAgain = await core.handle(HostRequest(.ls))
        let again = try XCTUnwrap(lsAgain.result).decode([SandboxInfo].self)
        XCTAssertEqual(again.first?.phase, "hibernated")
    }

    /// 593 §9 (S5): a sandbox that is not running lists its sessions from their SAVED screens, and
    /// `session-screen` gives one back — in-process, with no host and nothing in a guest asked.
    func testSessionsOfASandboxThatIsNotRunningComeFromItsSavedScreens() async throws {
        let store = DozerStore(root: root)
        let (s, n) = try DozerImages.spec(name: "x", options: CreateOptions(image: "lab"), store: store, environment: [:])
        try SandboxConfig(name: "x", image: n, spec: s, workspace: nil).write(store.configFile("x"))
        let core = HostCore(store: store, readOnly: true, version: "test")
        await core.load()
        let first = await core.handle(HostRequest(.sessions, name: "x"))
        let none = try XCTUnwrap(first.result).decode([SessionRow].self)
        XCTAssertEqual(none, [], "no saved screens: no sessions (no longer an error)")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let layout = store.layout("x")
        try SavedScreens.write(layout, info: SavedScreenInfo(session: "shell", savedAt: at, reason: "hibernate", cols: 100, rows: 30,
                                                             command: "bash -l", pid: 9, bytesOut: 5),
                               vt: Data("\u{1B}cVT".utf8), text: "$ echo hi\nhi")
        // Shut down (owner, 2026-09-30): no sessions, no screen — whatever is on disk.
        let offList = await core.handle(HostRequest(.sessions, name: "x"))
        let offRows = try XCTUnwrap(offList.result).decode([SessionRow].self)
        XCTAssertEqual(offRows, [], "a shut-down sandbox has no sessions")
        var offScreen = HostRequest(.sessionScreen, name: "x")
        offScreen.session = "shell"
        let offGot = await core.handle(offScreen)
        XCTAssertEqual(offGot.error?.code, .notFound, "…and no screen")
        XCTAssertTrue(offGot.error?.message.contains("no sessions") == true)
        // Hibernated (a record another process left): its sessions from their saved screens.
        try Data("disk".utf8).write(to: layout.rootfs)
        try Data("snap".utf8).write(to: layout.snapshot)
        try PersistedSandbox(spec: s, phase: .hibernated, machineIdentifier: Data([1]), macAddress: nil, subnet: nil, shareTags: [:])
            .write(to: layout.persistedState)
        let listed = await core.handle(HostRequest(.sessions, name: "x"))
        let rows = try XCTUnwrap(listed.result).decode([SessionRow].self)
        XCTAssertEqual(rows.map(\.name), ["shell"])
        XCTAssertEqual(rows.first?.saved, true)
        XCTAssertEqual(rows.first?.savedReason, "hibernate")
        XCTAssertEqual(rows.first?.savedAt, at)
        XCTAssertEqual(rows.first?.cols, 100)
        XCTAssertEqual(rows.first?.ended, false)
        var r = HostRequest(.sessionScreen, name: "x")
        r.session = "shell"
        let got = await core.handle(r)
        let screen = try XCTUnwrap(got.result).decode(SessionScreen.self)
        XCTAssertEqual(screen.text, "$ echo hi\nhi")
        XCTAssertEqual(screen.vt, Data("\u{1B}cVT".utf8))
        XCTAssertEqual(screen.reason, "hibernate")
        r.session = "nope"
        let missing = await core.handle(r)
        XCTAssertEqual(missing.error?.code, .notFound)
        r.session = "../x"
        let bad = await core.handle(r)
        XCTAssertEqual(bad.error?.code, .invalid)
        XCTAssertTrue(HostOp.sessionScreen.isReadOnly, "looking never starts a host")
        XCTAssertTrue(HostOp.terminalLayout.isReadOnly)
        XCTAssertFalse(HostOp.terminalLayoutSet.isReadOnly)
    }

    /// 593 §9 (S1): the terminal layout is the host's (beside doz.json, 0600), validated, and written
    /// in-process when no host runs — never into a sandbox that does not exist.
    func testTheTerminalLayoutIsKeptBesideTheSandbox() async throws {
        let store = DozerStore(root: root)
        let (s, n) = try DozerImages.spec(name: "x", options: CreateOptions(image: "lab"), store: store, environment: [:])
        try SandboxConfig(name: "x", image: n, spec: s, workspace: nil).write(store.configFile("x"))
        let core = HostCore(store: store, readOnly: true, version: "test")
        await core.load()
        let empty = await core.handle(HostRequest(.terminalLayout, name: "x"))
        XCTAssertEqual(empty.result, .null, "none yet")
        let layout = TerminalLayout(split: true, focusedPane: 1, panes: [
            .init(tabs: [.init(session: "shell"), .init(session: "shell-2")], selected: 1),
            .init(tabs: [.init(session: "shell", mode: "watch")], selected: 0)])
        var set = HostRequest(.terminalLayoutSet, name: "x")
        set.layout = layout
        let written = await core.handle(set)
        let back = try XCTUnwrap(written.result).decode(TerminalLayout.self)
        XCTAssertEqual(back.panes, layout.panes)
        XCTAssertNotNil(back.updatedAt)
        let again = await core.handle(HostRequest(.terminalLayout, name: "x"))
        let read = try XCTUnwrap(again.result).decode(TerminalLayout.self)
        XCTAssertEqual(read.panes, layout.panes)
        XCTAssertTrue(read.split)
        XCTAssertEqual(read.focusedPane, 1)
        var st = stat()
        XCTAssertEqual(stat(store.terminalLayoutFile("x").path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        for bad in [TerminalLayout(split: false, panes: []),
                    TerminalLayout(split: true, panes: [.init(tabs: [])]),
                    TerminalLayout(split: false, focusedPane: 1, panes: [.init(tabs: [])]),
                    TerminalLayout(split: false, panes: [.init(tabs: [.init(session: "../etc")])]),
                    TerminalLayout(split: false, panes: [.init(tabs: [.init(session: "a", mode: "type")])]),
                    TerminalLayout(split: false, panes: [.init(tabs: [.init(session: "a")], selected: 3)]),
                    TerminalLayout(split: false, panes: [.init(tabs: Array(repeating: .init(session: "a"), count: 17))])] {
            set.layout = bad
            let refused = await core.handle(set)
            XCTAssertEqual(refused.error?.code, .invalid, "\(bad)")
        }
        XCTAssertEqual(TerminalLayout.read(store, "x")?.panes, layout.panes, "a refused change leaves the layout as it was")
        set.layout = nil
        let cleared = await core.handle(set)
        XCTAssertEqual(cleared.result, .null)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.terminalLayoutFile("x").path), "nil clears it")
        XCTAssertThrowsError(try TerminalLayout.write(layout, store, "gone"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.layout("gone").sandboxDirectory.path), "never re-creates a sandbox's directory")
    }

    func testAllocatedBytesOfAFileAndADirectory() throws {
        let f = root.appendingPathComponent("d/f")
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 10_000).write(to: f)
        XCTAssertGreaterThanOrEqual(allocatedBytes(f), 10_000)
        XCTAssertEqual(allocatedBytes(f.deletingLastPathComponent()), allocatedBytes(f))
        XCTAssertEqual(allocatedBytes(root.appendingPathComponent("missing")), 0)
    }

    func testSettleDelay() {
        XCTAssertEqual(HostCore.settleDelay(since: nil), .zero)
        XCTAssertEqual(HostCore.settleDelay(since: .seconds(1)), .seconds(2))
        XCTAssertEqual(HostCore.settleDelay(since: .seconds(5)), .zero)
    }

    func testExecRunsLikeASession() throws {
        let store = DozerStore(root: root)
        let (cc, n) = try DozerImages.spec(name: "x", options: CreateOptions(image: "claude-code"), store: store, environment: [:])
        let agent = SandboxConfig(name: "x", image: n, spec: cc, workspace: nil)
        let ctx = HostCore.execContext(config: agent, environment: ["A": "1"], workdir: nil, user: nil)
        XCTAssertEqual(ctx.user, "agent")
        XCTAssertEqual(ctx.workdir, "/workspace")
        XCTAssertEqual(ctx.environment["HOME"], "/home/agent")
        XCTAssertEqual(ctx.environment["A"], "1")
        XCTAssertNil(HostCore.execContext(config: agent, environment: [:], workdir: nil, user: "root").user)
        let (lab, ln) = try DozerImages.spec(name: "y", options: CreateOptions(image: "lab"), store: store, environment: [:])
        XCTAssertEqual(HostCore.execContext(config: SandboxConfig(name: "y", image: ln, spec: lab, workspace: nil), environment: [:], workdir: nil, user: nil).workdir, "/root")
        XCTAssertEqual(HostCore.execContext(config: SandboxConfig(name: "y", image: ln, spec: lab, workspace: "/w"), environment: [:], workdir: nil, user: nil).workdir, "/workspace")
    }

    func testMetricsStoreIsSandboxLabsSchema() throws {
        let m = try MetricsStore(url: root.appendingPathComponent("metrics.sqlite"))
        let run = m.beginRun(.current(kind: "doz host", version: "test"))
        let id = m.begin(run: run, action: "wake", sandbox: "x", image: "lab", phaseBefore: "hibernated")
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
