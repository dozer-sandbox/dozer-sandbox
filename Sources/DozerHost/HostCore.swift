import Foundation
import DozerKit

/// A multi-subscriber fan-out of host events (`doz events`).
final class HostEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<HostEvent>.Continuation] = [:]

    func subscribe() -> AsyncStream<HostEvent> {
        let (s, c) = AsyncStream<HostEvent>.makeStream(bufferingPolicy: .bufferingNewest(2000))
        let id = UUID()
        lock.lock(); subscribers[id] = c; lock.unlock()
        c.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.subscribers[id] = nil; self.lock.unlock()
        }
        return s
    }

    func yield(_ e: HostEvent) {
        lock.lock(); let subs = Array(subscribers.values); lock.unlock()
        for s in subs { s.yield(e) }
    }
}

/// The host's model: every sandbox of the store, each a `Sandbox` living in THIS process, and every
/// operation the protocol offers. The server (`HostServer`) owns one with `readOnly: false`; a
/// read-only command with no host running builds one with `readOnly: true` in-process (no VM is
/// started, no metrics are written, nothing on disk changes).
public actor HostCore {
    public nonisolated let store: DozerStore
    public nonisolated let readOnly: Bool
    public nonisolated let version: String
    let metrics: MetricsStore?
    let metricsRun: Int64
    /// 595: operations that touch the store's disks under way now (a deletion waits for none).
    var diskOpsInFlight = 0
    nonisolated let hub = HostEventHub()
    /// 599h: the tools layer's downloads (gh), once per store.
    public nonisolated var toolsCache: ToolsCache { ToolsCacheRegistry.cache(for: store.root.appendingPathComponent("tools")) }
    /// 588: the store's accounts (metadata only), the keychain / verifier / Claude probes (fakes in
    /// tests), and ONE watcher per Mac login in use.
    public nonisolated let accountStore: AccountStore
    nonisolated let services: CredentialServices
    var watchers: [String: LoginWatcher] = [:]
    /// 599i: one session per ChatGPT account (its sandboxes share it).
    var chatgptSessions: [String: ChatGPTSession] = [:]
    /// 611: what this build leaves out (a public build: no ChatGPT sign-in of its own). Tests set it.
    var buildFlavor: BuildFlavor = .current
    public func setBuildFlavor(_ f: BuildFlavor) { buildFlavor = f; chatgptSessions = [:] }
    /// 599i rc.3: the reader of this Mac's own Codex login (`mac` for Codex) — made on first use.
    var codexMacReader: CodexMacSession?

    /// Actor-confined: one per sandbox.
    final class Managed {
        let sandbox: Sandbox
        var config: SandboxConfig
        var eventTask: Task<Void, Never>?
        var networkTask: Task<Void, Never>?
        /// 588: the Mac-login watcher this sandbox follows (nil: none).
        var watcher: LoginWatcher?
        /// The metrics row of the action running now (library steps hang under it).
        var actionRow: Int64?
        var lastAction: (row: Int64, at: Date)?
        var networkCounted: Set<UUID> = []
        /// When a session last started a program (hibernating lets it settle first — 583).
        var lastSessionOpen: ContinuousClock.Instant?
        var sessionRows: [String: Int64] = [:]
        /// 593: the boot being recorded (a cold boot, a wake, a restore after a crash), if one is.
        var boot: BootRecorder?
        init(sandbox: Sandbox, config: SandboxConfig) {
            self.sandbox = sandbox
            self.config = config
        }
        var name: String { config.name }
    }

    var managed: [String: Managed] = [:]
    /// Names being created right now (so two `create`s cannot race).
    private var creating: Set<String> = []
    /// 590: `open-session` is serialized per sandbox.
    let sessionGate = KeyedGate()
    /// 610: the cold starts under way (an open, an attach, an exec or a second start JOINS one — `ensureRunning`).
    nonisolated let coldStarts = ColdStarts()
    /// 599: the session bridges' limits and recent actions (`HostCore+Bridges`).
    nonisolated let bridgeState = BridgeState()
    /// 609: which viewer set each session's size last (the attach relay re-applies the typist's).
    nonisolated let sizeOwners = SessionSizeOwners()
    /// 612: the programs' status per sandbox and session, the status watchers (keyed sandbox NUL session), the
    /// ones being opened, the sessions whose holder cannot answer, and a lost watcher's retries (`HostCore+Status`).
    var statuses: [String: [String: SessionStatus]] = [:]
    /// Since when a session's program has reported `working` (its metrics row "agent working" is written when it stops).
    var workingSince: [String: Date] = [:]
    var statusWatches: [String: SessionConnection] = [:]
    var statusOpening: Set<String> = []
    var statusUnsupported: Set<String> = []
    var statusRetries: [String: Int] = [:]
    /// 599d: GitHub tokens given with `doz key set NAME --github` from stdin — in this host's MEMORY only
    /// (never written: a new host needs them given again, or a keychain item).
    var githubKeys: [String: String] = [:]
    /// 594: the image preparation running per image (single-flight), and the recent finished ones.
    var preparations: [String: Preparation] = [:]
    var recentPreparations: [Preparation] = []
    /// The work of a preparation (tests substitute one that needs no VM or network).
    var preparationRunner: PreparationRunner = HostCore.runPreparation
    public typealias PreparationRunner = @Sendable (String, DozerStore, @escaping @Sendable (HostEvent) -> Void) async throws -> Void
    /// Whether an image is already prepared for this build (tests substitute one).
    var preparedCheck: @Sendable (String, DozerStore) -> Bool = HostCore.isPrepared

    /// 594: where `latest` agent versions are asked — the real host asks the npm registry; an
    /// in-process host (and a unit test, unless it sets a stub) asks nothing.
    var agentRegistry: NpmRegistry = .disabled
    public func setAgentRegistry(_ r: NpmRegistry) { agentRegistry = r }

    /// Tests: the preparation work and the "already prepared" check.
    public func setPreparationRunner(_ r: @escaping PreparationRunner, prepared: @escaping @Sendable (String, DozerStore) -> Bool) {
        preparationRunner = r
        preparedCheck = prepared
    }

    public init(store: DozerStore, readOnly: Bool, version: String, services: CredentialServices = .forHost(),
                newStoreKeepalive: Bool = false, newStoreDefaultAccount: String? = nil, agentRegistry: NpmRegistry = .disabled) {
        TestSafety.checkStore(store.root)          // 611: a guarded test never runs on the default store
        self.store = store
        self.agentRegistry = agentRegistry
        self.readOnly = readOnly
        self.version = version
        self.services = services
        // 594: a store with no accounts.json follows the settings' `defaults.account`.
        let defaultAccount = newStoreDefaultAccount ?? DozerSettings.load().string(SettingKey.defaultAccount) ?? "mac"
        self.accountStore = AccountStore(store: store, newStoreKeepalive: newStoreKeepalive, newStoreDefault: defaultAccount)
        if readOnly {
            metrics = nil
            metricsRun = 0
        } else {
            let m = try? MetricsStore(url: store.metrics)
            metrics = m
            metricsRun = m?.beginRun(.current(kind: "doz host", version: version)) ?? 0
        }
    }

    // MARK: loading

    /// Every sandbox `doz create` made in the store.
    public func load() {
        for name in store.sandboxNames() where managed[name] == nil {
            guard let cfg = SandboxConfig.read(store.configFile(name)) else { continue }
            do { try adopt(cfg) } catch { note(nil, "could not load \(name): \(error.localizedDescription)") }
        }
    }

    @discardableResult
    private func adopt(_ config: SandboxConfig) throws -> Managed {
        var cfg = config
        // 588: `key set --claude-login` (0aab331) is the Mac account now.
        if cfg.credentialSources[CredentialBinding.claudeOAuth.id] == ClaudeLogin.source {
            cfg.credentialSources[CredentialBinding.claudeOAuth.id] = nil
            cfg.account = "mac"
            if !readOnly { try? cfg.write(store.configFile(cfg.name)) }
        }
        let sb = try Sandbox(spec: cfg.spec)
        let m = Managed(sandbox: sb, config: cfg)
        managed[cfg.name] = m
        sb.setAgentSudo(Self.agentSudo(cfg))
        sb.setWorkspaceRuleMode(Self.ruleMode(cfg).mode)              // 599g
        sb.passthroughViews = Self.workspaceViewOn(cfg)                // 608
        if !readOnly { sb.setTimeZone(Self.guestTimeZone()) }
        if !readOnly {
            let name = cfg.name
            let events = sb.events()
            m.eventTask = Task { [weak self] in
                for await e in events { await self?.handleEvent(name, e) }
            }
            if let log = sb.egress?.log {
                let stream = log.stream()
                m.networkTask = Task { [weak self] in
                    var pending = false
                    for await _ in stream {
                        if pending { continue }
                        pending = true
                        try? await Task.sleep(for: .seconds(2))
                        pending = false
                        await self?.recordNetwork(name)
                    }
                }
            }
            // A key whose source is the keychain is read again (secrets are never on disk).
            for (binding, source) in cfg.credentialSources where source.hasPrefix("keychain:") && binding == CredentialBinding.anthropic.id {
                let service = String(source.dropFirst(9))
                Task.detached { [weak sb] in
                    if let secret = Keychain.read(service: service), let sb { sb.setCredential(.anthropic, secret: secret) }
                }
            }
            installCredentialHooks(m)
            applyAccount(m)
            applyGitHub(m)                                  // 599d
        }
        return m
    }

    /// What the host does when it starts (not in read-only mode): a sandbox left ASLEEP (its VM was
    /// in a host that died) is restored and put back to sleep — the library's restore after a crash;
    /// one whose record says running died with that host: it is reported, and its disk (never
    /// unmounted) is marked for e2fsck at the next start. Hibernated sandboxes need nothing: `wake`
    /// adopts them in this process, sessions and pids intact.
    public func recoverAfterStart() async {
        for m in managed.values {
            let layout = store.layout(m.name)
            guard var p = PersistedSandbox.read(from: layout.persistedState) else { continue }
            switch p.phase {
            case .asleep where p.isRestorable(layout: layout):
                note(m.name, "was asleep when the previous host went away — restoring it (restore after a crash)")
                let row = beginAction(m, "restore after crash", phaseBefore: "asleep")
                let t0 = ContinuousClock.now
                do {
                    beginBoot(m, kind: "restore after crash")
                    do { try await m.sandbox.wake() } catch { await endBoot(m, error: error); throw error }
                    await endBoot(m, error: nil)
                    try await m.sandbox.sleep()
                    finishAction(m, row, t0, ok: true)
                    note(m.name, "restored and asleep again, sessions where they were")
                } catch {
                    finishAction(m, row, t0, ok: false, error: error)
                    note(m.name, "could not restore: \(error.localizedDescription) — `doz shutdown` discards the snapshot")
                }
            case .running, .paused, .booting, .failed, .asleep:
                // The VM died with the host: nothing to restore. Its disk was never unmounted and the
                // ext4 has no journal — the library e2fscks a disk so marked before it boots.
                p.phase = .off
                if FileManager.default.fileExists(atPath: layout.rootfs.path) { p.fsckOnNextBoot = true }
                try? FileManager.default.removeItem(at: layout.snapshot)
                try? p.write(to: layout.persistedState)
                m.config.diedWithHostAt = Date()
                try? m.config.write(store.configFile(m.name))
                // 593 (owner, 2026-09-30): its sessions died too — a shut-down sandbox shows no session
                // screens and has no panes: its saved screens and its terminal layout are deleted.
                SavedScreens.remove(layout)
                try? TerminalLayout.write(nil, store, m.name)
                SessionRecords.write(nil, store, m.name)        // 608
                note(m.name, "was running when the previous host died — its programs are gone; the next start checks its disk (e2fsck)")
                metrics?.record(run: metricsRun, action: "died with host", sandbox: m.name, image: m.config.image,
                                phaseBefore: "running", phaseAfter: "off", startedAt: Date(), durationMs: nil, ok: false)
            case .off, .hibernated:
                break
            }
        }
    }

    // MARK: events and metrics

    public nonisolated func subscribe() -> AsyncStream<HostEvent> { hub.subscribe() }

    func note(_ sandbox: String?, _ text: String) {
        let e = HostEvent(kind: sandbox == nil ? .host : .note, sandbox: sandbox, text: text)
        hub.yield(e)
        if !readOnly { HostLog.line(e.line) }
    }

    private func handleEvent(_ name: String, _ e: SandboxEvent) {
        // 612: a sandbox that comes to run gets its sessions' status watchers again; one that is off has no programs.
        if case .phase(let p) = e {
            if p == .running { Task { await self.refreshStatusWatches(name) } }
            if p == .off { clearStatuses(name) }
        }
        if let he = HostEvent(e, sandbox: name) {
            managed[name]?.boot?.record(he)
            hub.yield(he)
            if he.kind != .progress, he.kind != .output { HostLog.line(he.line) }   // 593: a bake's output is live only
        }
        guard case .step(let label, let ms) = e, let metrics, let m = managed[name] else { return }
        let recent = m.lastAction.flatMap { Date().timeIntervalSince($0.at) < 1.5 ? $0.row : nil }
        metrics.record(run: metricsRun, action: MetricsStepKey.key(for: label), kind: .step, sandbox: name, image: m.config.image,
                       startedAt: Date().addingTimeInterval(-ms / 1000), durationMs: ms, detail: ["label": label],
                       parent: m.actionRow ?? recent)
    }

    /// Finished connections into the metrics, as counts and bytes per sandbox per minute (never hosts).
    func recordNetwork(_ name: String) {
        guard let metrics, let m = managed[name], let log = m.sandbox.egress?.log else { return }
        var buckets: [Int64: (allowed: Int, denied: Int, failed: Int, up: Int, down: Int)] = [:]
        for r in log.records where !r.open && !m.networkCounted.contains(r.id) {
            m.networkCounted.insert(r.id)
            let minute = Int64(r.time.timeIntervalSince1970 / 60)
            var b = buckets[minute] ?? (0, 0, 0, 0, 0)
            switch r.verdict {
            case .allowed: b.allowed += 1
            case .denied: b.denied += 1
            case .failed: b.failed += 1
            }
            b.up += r.bytesUp
            b.down += r.bytesDown
            buckets[minute] = b
        }
        for (minute, b) in buckets {
            metrics.addNetwork(run: metricsRun, sandbox: name, minute: minute, allowed: b.allowed, denied: b.denied,
                               failed: b.failed, bytesUp: b.up, bytesDown: b.down)
        }
    }

    // MARK: boot logs (593, owner 2026-09-30)

    /// Start recording a boot of `m` (`cold boot`, `wake`, `restore after crash`).
    func beginBoot(_ m: Managed, kind: String) {
        guard !readOnly else { return }
        // EXPERIMENTAL (604): put the sound kernel back when it went (Resources may delete an unused one); the
        // boot says plainly when it cannot.
        if m.config.spec.audio == true {
            _ = try? MacAudio.installSoundKernel(into: m.config.spec.kernelCacheDirectory ?? StoreLayout(spec: m.config.spec).kernels)
        }
        m.boot = BootRecorder(kind: kind, bootLog: m.sandbox.bootLogURL)
    }

    /// The boot is over: keep it (its events, its console, how it went), then the newest
    /// `host.boot_logs_kept`. The sandbox's event stream is drained a little first (its events reach the
    /// actor asynchronously). Never fails the operation.
    func endBoot(_ m: Managed, error: Error?) async {
        guard let rec = m.boot else { return }
        for _ in 0..<8 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        m.boot = nil
        let console = rec.console(m.sandbox.bootLogURL)
        let info = rec.info(result: error == nil ? "ok" : "failed", error: error.map { explain($0).message }, console: console.count)
        let keep = DozerSettings.load().int(SettingKey.bootLogsKept)
        do { try BootLogs.write(m.sandbox.layout, info: info, events: rec.snapshot, console: console, keep: keep) } catch {
            note(m.name, "could not keep the boot log: \(error.localizedDescription)")
        }
    }

    /// `boot-log`: the kept boots (newest first) — with, from the host, the one under way as number 1.
    func bootLog(_ r: HostRequest) throws -> JSONValue {
        let m = try get(r.name)
        let layout = m.sandbox.layout
        let live = m.boot
        var boots = BootLogs.list(layout)
        if let live { boots.insert(live.info(result: "running", error: nil, console: live.console(m.sandbox.bootLogURL).count), at: 0) }
        for i in boots.indices { boots[i].number = i + 1 }
        if r.list == true { return try JSONValue(encoding: BootLogList(name: m.name, boots: boots)) }
        let n = r.boot ?? 1
        guard n >= 1, n <= boots.count else {
            throw HostError(.notFound, boots.isEmpty ? "no boot of \(m.name) is kept yet — one is recorded each time it starts or wakes"
                                                     : "no boot \(n) of \(m.name): \(boots.count) kept (doz console \(m.name) --list)")
        }
        if n == 1, let live {
            let console = BootLogs.consoleLines(live.console(m.sandbox.bootLogURL))
            return try JSONValue(encoding: BootLogRecord(name: m.name, info: boots[0], events: live.snapshot, console: console))
        }
        guard var rec = BootLogs.read(layout, name: m.name, number: live == nil ? n : n - 1) else {
            throw HostError(.notFound, "boot \(n) of \(m.name) could not be read")
        }
        rec.info.number = n
        return try JSONValue(encoding: rec)
    }

    private func beginAction(_ m: Managed, _ action: String, phaseBefore: String) -> Int64? {
        guard let metrics else { return nil }
        let row = metrics.begin(run: metricsRun, action: action, sandbox: m.name, image: m.config.image, phaseBefore: phaseBefore)
        m.actionRow = row
        return row
    }

    /// 594: a preparation's metrics row (no sandbox: the image's).
    func recordPreparation(_ image: String, started: Date, t0: ContinuousClock.Instant, ok: Bool, error: String?, failedStep: String? = nil) {
        metrics?.record(run: metricsRun, action: "prepare", sandbox: nil, image: image, startedAt: started, durationMs: ms(since: t0),
                        ok: ok, error: error, detail: failedStep.map { ["failedStep": $0] } ?? [:])
    }

    /// A new sandbox's account as its KIND (mac, api-key, setup-token, none) — nil when it is none of those.
    func createdAccountKind(_ account: String?) -> String? {
        guard let account else { return "none" }
        let (def, kinds) = accountKinds()
        switch kinds[account == "default" ? def : account] {
        case .mac?, .codexMac?: return "mac"
        case .apiKey?, .openaiKey?: return "api-key"
        case .setupToken?: return "setup-token"
        case nil: return account == "default" && (def.isEmpty || def == "none") ? "none" : nil
        default: return nil
        }
    }

    private func finishAction(_ m: Managed, _ row: Int64?, _ t0: ContinuousClock.Instant, ok: Bool, error: Error? = nil,
                              phaseAfter: String? = nil, detail: [String: String] = [:]) {
        guard let row, let metrics else { return }
        metrics.finish(row, phaseAfter: phaseAfter, durationMs: ms(since: t0), ok: ok, error: error?.localizedDescription, detail: detail)
        m.actionRow = nil
        m.lastAction = (row, Date())
    }

    // MARK: state

    func get(_ name: String?) throws -> Managed {
        guard let name, !name.isEmpty else { throw HostError(.invalid, "which sandbox? (a name is required)") }
        guard let m = managed[name] else { throw HostError(.notFound, "no sandbox \(name) (doz ls)") }
        return m
    }

    /// The phase as the user sees it: in a new process a sandbox that is off but has a restorable
    /// snapshot is hibernated (its VM, if it had one, is gone — `wake` restores it).
    func effectivePhase(_ m: Managed) async -> Phase {
        let p = await m.sandbox.phase
        if p == .off, let r = Sandbox.restorableState(for: m.sandbox.spec) { return r.phase == .asleep ? .hibernated : r.phase }
        return p
    }

    /// Sandboxes with a VM in this process (booting, running, paused or asleep).
    public func liveSandboxes() async -> [String] {
        var out: [String] = []
        for m in managed.values {
            let p = await m.sandbox.phase
            let busy = await m.sandbox.status.busy
            if p.holdsRAM || busy { out.append(m.name) }
        }
        return out.sorted()
    }

    func info(_ m: Managed, sessions withSessions: Bool) async -> SandboxInfo {
        let status = await m.sandbox.status
        let phase = await effectivePhase(m)
        let returned = await m.sandbox.memoryReturnedMiB
        let mem = m.sandbox.spec.memoryMiB
        var sessionCount: Int?
        if withSessions, phase == .running, !status.busy, let list = try? await m.sandbox.sessions() {
            sessionCount = list.filter { !$0.isEnded }.count
        }
        let egress = m.sandbox.egress
        var i = SandboxInfo(name: m.name, image: m.config.image, phase: phase.rawValue, busy: status.busy, cpus: m.sandbox.spec.cpus,
                           memoryMiB: mem, ramHeldMiB: phase.holdsRAM ? mem - min(mem, returned) : 0,
                           memoryReturnedMiB: phase.holdsRAM ? returned : 0,
                           diskBytes: allocatedBytes(m.sandbox.layout.sandboxDirectory), sessions: sessionCount,
                           network: egress.map { $0.policy.preset ?? "custom" } ?? m.config.networkName,
                           deniedConnections: egress?.log.deniedCount, workspace: m.config.workspace,
                           createdAt: m.config.createdAt, diedWithHost: m.config.diedWithHostAt == nil ? nil : true,
                           account: accountName(m), credentialState: readOnly ? nil : credentialState(m, binding: nil),
                           credentialPolicy: egress == nil ? nil : effectivePolicy(m, accountStore.load()).rawValue,
                           foreignCredentials: egress.map { $0.vault.foreignSightings.count }.flatMap { $0 == 0 ? nil : $0 })
        i.agent = m.sandbox.spec.imageSpec?.name
        i.credentialProblem = credentialProblem(m)
        statusFields(m.name, into: &i)                                 // 612: from memory, never the guest
        i.workspaceRules = workspaceRulesInfo(m, phase: phase)       // 599g: two stats when there are no rules
        i.workspaceView = Self.workspaceViewState(running: phase == .running, workspace: m.config.workspace != nil,
                                                  active: Array(m.sandbox.activeViews.values), fallbacks: m.sandbox.viewFallbacks,
                                                  viewOn: m.sandbox.passthroughViews)   // 608
        // 594 W28: an image an older doz's recipe made (its disk lacks what this doz's has). 596: any
        // base × agent image.
        if let s = m.sandbox.spec.imageSpec, m.sandbox.spec.customImage == nil, ImageChoice.parse(s.name)?.name == s.name,
           !AgentVersions.isCurrentRecipe(s) {
            i.olderImage = AgentVersions.recipeChanges(s)
        }
        // 596: the base × agent, and a Dockerfile's rebuild state.
        if let c = m.config.imageChoice {
            i.base = c.base
            i.imageTitle = c.title
            if c.isDockerfile, let rec = Dockerfiles.record(c.base, store) {
                i.dockerfile = rec.dockerfile
                let own = m.sandbox.spec.imageSpec?.base
                if rec.reference == nil || own.map(Dockerfiles.isPlaceholder) == true {
                    i.rebuildAvailable = nil     // never built: its first start builds it
                } else if rec.changedSinceBuild {
                    i.rebuildAvailable = "Dockerfile changed — rebuild available (prepare the image, then reset the sandbox to take it)"
                } else if let r = rec.reference, own != r {
                    i.rebuildAvailable = "a newer build of its Dockerfile is prepared — reset the sandbox to take it"
                }
            }
        }
        return i
    }

    // MARK: requests

    /// Every request but the streaming ones (`attach`, `events`, `net-log --follow` — see HostServer).
    public func handle(_ r: HostRequest, emit: @escaping @Sendable (HostEvent) -> Void = { _ in }) async -> HostMessage {
        guard r.v <= HostProtocol.version else {
            return .failure(HostError(.version, "this host speaks protocol \(HostProtocol.version), the request is \(r.v) — restart it (doz host stop)"))
        }
        // 593: `terminal-layout-set` is answered in-process too: it writes one small file of the web UI's
        // state beside doz.json (never a VM, never a secret — like the UI's doz.toml), and a host is not
        // started to write it. With a host running, the host writes it (serialised with `rm`).
        if readOnly && !(r.op.isReadOnly || (r.op == .netPolicy && isPolicyQuery(r)) || r.op == .sessions || (r.op == .netLog && r.follow != true)
                         || (r.op == .console && r.follow != true) || (r.op == .agentPrompt && r.prompt == nil && r.clearPrompt != true && r.agentSudo == nil && r.clearAgentSudo != true)
                         || r.op == .terminalLayoutSet || ([.resourcesRemove, .resourcesClean].contains(r.op) && r.dryRun == true)
                         || (r.op == .sandboxSettings && r.setting == nil) || (r.op == .access && r.check != true)) {
            return .failure(HostError(.unavailable, "\(r.op.rawValue) needs the host"))
        }
        // 598: an upgrade removed this host's installation — refuse a boot plainly, before it fails oddly.
        if Self.bootOps.contains(r.op), let gone = programGone() {
            return .failure(HostError(.unavailable, gone))
        }
        // 595: a deletion waits until nothing that uses the store's disks is under way.
        let touchesDisks = Self.diskOps.contains(r.op)
        if touchesDisks { diskOpsInFlight += 1 }
        defer { if touchesDisks { diskOpsInFlight -= 1 } }
        do {
            return .success(try await perform(r, emit: emit))
        } catch {
            return .failure(explain(error))
        }
    }

    // MARK: 591 — the host's own program

    private var executable: ExecutableIdentity?

    /// The file this host runs from, as it was at start (the server sets it; an in-process read-only
    /// core has none).
    public func setExecutable(_ e: ExecutableIdentity?) { executable = e }

    /// How that file has changed since this host started (nil: it has not, or no identity is known).
    public func executableChange() -> ExecutableIdentity.Change? {
        guard let executable else { return nil }
        return executable.change(now: ExecutableIdentity.of(path: executable.path), runningCodeValid: ExecutableIdentity.runningCodeIsValid())
    }

    /// 598: operations that boot a VM (or prepare an image in one) — they need this host's resource
    /// bundle (the deckhold and doznet guest binaries) beside its program.
    static let bootOps: Set<HostOp> = [.create, .start, .wake, .prepare, .imageBake, .onboard]

    /// 598: why this host cannot boot anything now, or nil. A Homebrew upgrade installs the new build
    /// in a new keg and `brew cleanup` (which `brew upgrade` runs) deletes the old one — the program
    /// this host runs from and its resources. The running process keeps its code (the file stays open)
    /// and every VM it runs keeps running, but a boot would fail oddly on a missing guest binary. So
    /// before one, say what happened and what to do.
    public func programGone() -> String? {
        guard !readOnly, let executable else { return nil }
        if executableChange() == .removed { return ExecutableIdentity.explain(.removed, path: executable.path) }
        if DeckholdBinary.locate() == nil || DoznetBinary.locate() == nil {
            return "this host's resources (the guest binaries beside \(executable.path)) are gone — an upgrade removed its "
                + "installation — `doz host stop`, then retry: the installed doz starts a new host (sandboxes asleep keep their snapshots)"
        }
        return nil
    }

    /// An error as the client sees it. When this host's program was rewritten under it, macOS refuses
    /// its VMs with a raw "Internal Virtualization error": say what happened and what to do instead.
    /// 593: ONLY an error the Virtualization framework raised gets this — an ordinary host error (a
    /// missing restore point, a bad name, a phase) is reported as it is, even when the program changed.
    public func explain(_ error: Error) -> HostError {
        let e = HostError.from(error)
        guard let executable, executableChange() == .overwritten, Self.isVirtualizationError(error) else { return e }
        return HostError(.failed, ExecutableIdentity.explain(.overwritten, path: executable.path)
                                  + " (the Virtualization framework said: \(e.message.prefix(160)))")
    }

    /// An error that came from Virtualization.framework: `VZErrorDomain` anywhere in its chain
    /// (underlying errors, and errors a library error wraps), or the framework's own refusals of a
    /// process whose code signature broke ("Internal Virtualization error", the entitlement). The
    /// host's and the library's own typed errors never are.
    static func isVirtualizationError(_ error: Error) -> Bool {
        if error is HostError { return false }
        if let s = error as? SandboxError {
            switch s {
            case .invalidPhase, .notRunning, .restorePointNotFound, .alreadyExists, .invalidSpec, .invalidSessionName: return false
            default: break
            }
        }
        var seen = 0
        func visit(_ e: Error) -> Bool {
            seen += 1
            guard seen < 32 else { return false }
            let ns = e as NSError
            if ns.domain == "VZErrorDomain" { return true }
            let text = ns.localizedDescription + " " + String(describing: e)
            for marker in ["VZErrorDomain", "Internal Virtualization error", "com.apple.security.virtualization"] where text.contains(marker) {
                return true
            }
            if let u = ns.userInfo[NSUnderlyingErrorKey] as? Error, visit(u) { return true }
            if let us = ns.userInfo[NSMultipleUnderlyingErrorsKey] as? [Error], us.contains(where: visit) { return true }
            // A library error that carries its cause (Containerization's `cause`, and the like).
            for child in Mirror(reflecting: e).children {
                if let inner = child.value as? Error, visit(inner) { return true }
                if let opt = child.value as? Optional<Any>, case .some(let v) = opt, let inner = v as? Error, visit(inner) { return true }
            }
            return false
        }
        return visit(error)
    }

    func isPolicyQuery(_ r: HostRequest) -> Bool {
        r.preset == nil && (r.allow ?? []).isEmpty && (r.deny ?? []).isEmpty && (r.removeHosts ?? []).isEmpty
            && (r.grant ?? []).isEmpty && (r.revoke ?? []).isEmpty
    }

    /// 594 W23: the agent's passwordless sudo for a sandbox — its own choice, else the setting
    /// `sandbox.agent_sudo` (read now: a changed setting applies at the next boot or session).
    static func agentSudo(_ cfg: SandboxConfig, settings: @autoclosure () -> DozerSettings = .load()) -> Bool {
        cfg.agentSudo ?? settings().bool(SettingKey.agentSudo)
    }

    /// 594 W10: the guest's time zone — `sandbox.timezone`: `mac` (this Mac's zone, read NOW, so a
    /// wake after the Mac changed zone follows it) or a zone name. `DOZ_TEST_MAC_TIMEZONE` (a TEST
    /// seam: a zone name, or a file holding one) stands in for the Mac's.
    static func guestTimeZone(settings: DozerSettings = .load(),
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> GuestTimeZone? {
        let v = settings.string(SettingKey.timeZone) ?? "mac"
        guard v == "mac" else { return GuestTimeZone(named: v) }
        return GuestTimeZone(named: macTimeZoneName(environment: environment))
    }

    static func macTimeZoneName(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let t = environment["DOZ_TEST_MAC_TIMEZONE"], !t.isEmpty {
            if t.hasPrefix("/") { return (try? String(contentsOfFile: t, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "UTC" }
            return t
        }
        NSTimeZone.resetSystemTimeZone()        // a long-lived host: the Mac may have changed zone since
        return NSTimeZone.system.identifier
    }

    private func perform(_ r: HostRequest, emit: @escaping @Sendable (HostEvent) -> Void) async throws -> JSONValue {
        if let n = r.name, let m = managed[n] {
            m.sandbox.setAgentSudo(Self.agentSudo(m.config))
            m.sandbox.setTimeZone(Self.guestTimeZone())
            m.sandbox.setWorkspaceRuleMode(Self.ruleMode(m.config).mode)   // 599g: read per request, like the rest
            m.sandbox.passthroughViews = Self.workspaceViewOn(m.config)    // 608: used at the next fresh boot / hibernation's wake
            // 599d: the setting sandbox.ssh_agent changed in the file since — follow it.
            if m.sandbox.egress != nil, (Self.sandboxValue(m.config, SettingKey.sshAgent) == .string("on")) != (m.sandbox.sshAgentSocket != nil) {
                applyGitHub(m)
            }
        }
        switch r.op {
        case .ping:
            return try JSONValue(encoding: await status())
        case .create:
            return try JSONValue(encoding: try await create(r, emit: emit))
        case .start, .wake, .pause, .resume, .sleep, .hibernate, .shutdown, .reset, .rm:
            return try JSONValue(encoding: try await lifecycle(r.op, name: r.name, emit: emit))
        case .ls:
            var rows: [SandboxInfo] = []
            for m in managed.values.sorted(by: { $0.name < $1.name }) { rows.append(await info(m, sessions: r.withSessions ?? true)) }
            return try JSONValue(encoding: rows)
        case .inspect:
            return try JSONValue(encoding: try await detail(try get(r.name)))
        case .sessions:
            return try JSONValue(encoding: try await sessionRows(try get(r.name)))
        case .sessionScreen:
            // 593 §9 (S5): from the sandbox's directory, in any phase — nothing in the guest is asked.
            let m = try get(r.name)
            guard let s = r.session else { throw HostError(.invalid, "which session? (doz sessions \(m.name) --screen SESSION)") }
            try GuestCommand.validateSessionName(s)
            let phase = await effectivePhase(m)
            guard phase == .running || Self.wakeable(phase) else {
                throw HostError(.notFound, "\(m.name) is \(PhaseName.label(phase)) — it has no sessions (Start boots it fresh, with new ones)")
            }
            guard let saved = SavedScreens.read(m.sandbox.layout, session: s) else {
                throw HostError(.notFound, "no saved screen of \(s) in \(m.name) — screens are saved when it pauses, sleeps or hibernates, and every few minutes while it runs")
            }
            return try JSONValue(encoding: SessionScreen(name: m.name, saved))
        case .bootLog:
            return try bootLog(r)
        case .resources:
            return try JSONValue(encoding: await resourceReport())
        case .resourcesRemove, .resourcesClean:
            return try JSONValue(encoding: try await resourcesRemove(r, emit: emit))
        case .resourcesKernel:
            return try JSONValue(encoding: try await resourcesKernel(r))
        case .workspaceRules:
            return try JSONValue(encoding: try await workspaceRulesReport(r))
        case .tools, .toolsApply:
            let m = try get(r.name)
            let phase = await m.sandbox.status.phase
            if r.op == .toolsApply, phase != .running {
                throw HostError(.invalidPhase, "\(m.name) is \(PhaseName.label(phase)) — its tools are set up when it starts or wakes")
            }
            return try JSONValue(encoding: await tools(m, apply: r.op == .toolsApply, emit: emit))
        case .terminalLayout:
            let m = try get(r.name)
            guard let l = TerminalLayout.read(store, m.name) else { return .null }
            return try JSONValue(encoding: l)
        case .terminalLayoutSet:
            let m = try get(r.name)
            try TerminalLayout.write(r.layout, store, m.name)
            guard let l = TerminalLayout.read(store, m.name) else { return .null }
            return try JSONValue(encoding: l)
        case .sessionEnd:
            return try JSONValue(encoding: try await sessionEnd(r))          // 608
        case .sessionRestart:
            return try JSONValue(encoding: try await sessionRestart(r))      // 608
        case .openSession:
            var opened = try await openSession(r, emit: emit)
            opened.defaultSession = defaultSessionName(r.name)      // 594 (W17): the shortest reattach hint
            return try JSONValue(encoding: opened)
        case .exec:
            return try JSONValue(encoding: try await exec(r, emit: emit))
        case .pointTake, .pointList, .pointRevert, .pointFork, .pointRm, .pointSaveImage:
            return try await point(r, emit: emit)
        case .imageList:
            return try JSONValue(encoding: images())
        case .bases:
            let s = store
            let check = preparedCheck
            return try JSONValue(encoding: BaseRow.rows(s) { check($0, s) })
        case .builderStatus:
            return try JSONValue(encoding: ContainerTool.status())
        case .builderStart:
            note(nil, "starting Apple's container services (asked by \(r.requestedBy ?? "a client")): container system start --enable-kernel-install")
            let out = try await Task.detached { try ContainerTool.startServices { line in emit(HostEvent(kind: .output, sandbox: nil, text: ProgressFormat.inert(line, limit: 400))) } }.value
            HostLog.line("container system start: " + out.split(separator: "\n").suffix(3).joined(separator: " | "))
            return try JSONValue(encoding: ContainerTool.status())
        case .builderInstall:
            note(nil, "installing Apple's container tool on demand (asked by \(r.requestedBy ?? "a client")): container \(ContainerTool.package.version), Apple's signed package")
            let said = try await ContainerTool.install { line in emit(HostEvent(kind: .note, sandbox: nil, text: line)) }
            note(nil, said)
            return try JSONValue(encoding: ContainerTool.status())
        case .imageTree:
            // Every disk's extent map is read: off the actor, so nothing else waits on it.
            let s = store
            return try JSONValue(encoding: try await Task.detached { try ImageTree.measure(store: s) }.value)
        case .templateCreate:
            return try JSONValue(encoding: try await templateCreate(r))
        case .duplicate:
            return try JSONValue(encoding: try await duplicate(r))
        case .imageBake:
            return try JSONValue(encoding: try await bake(r.image, emit: emit))
        case .imageRm:
            return try JSONValue(encoding: try removeImage(r.image))
        case .netPolicy:
            return try JSONValue(encoding: try netPolicy(r))
        case .netPermissions:
            // 597: the checklist, and suggestions from what this host saw refused.
            let m = try get(r.name)
            guard let egress = m.sandbox.egress else {
                throw HostError(.invalid, "\(m.name) is not proxied (network \(m.config.networkName)) — it has no permissions")
            }
            return try JSONValue(encoding: PermissionPolicy.report(name: m.name, policy: Self.withoutSignInBlock(egress.policy),
                                                                   base: PermissionPolicy.base(of: m.config), log: egress.log.records))
        case .netLog:
            let m = try get(r.name)
            guard let log = m.sandbox.egress?.log else { throw HostError(.invalid, "\(m.name) is not proxied (network \(m.config.networkName)) — it has no connection log") }
            return try JSONValue(encoding: log.records.filter { r.deniedOnly != true || $0.verdict == .denied })
        case .keySet, .keyRm:
            return try JSONValue(encoding: try await setKey(r))
        case .keyList:
            return try JSONValue(encoding: credentials(try get(r.name)))
        case .keyPolicy:
            return try JSONValue(encoding: try setPolicy(r))
        case .accountList:
            return try JSONValue(encoding: await accountRows())
        case .accountAdd:
            return try JSONValue(encoding: try await addAccount(r))
        case .accountRemove:
            return try JSONValue(encoding: try await removeAccount(r))
        case .accountDefault:
            return try JSONValue(encoding: try await setDefaultAccount(r))
        case .accountUse:
            let m = try get(r.name)
            guard let a = r.account, !a.isEmpty else { throw HostError(.invalid, "which account? (a name, default or none)") }
            return try JSONValue(encoding: try await useAccount(m, a))
        case .accountVerify:
            return try JSONValue(encoding: try await verifyAccount(r))
        case .accountKeepalive:
            return try JSONValue(encoding: try setKeepalive(r))
        case .console:
            // 591: the lines so far (`--follow` is the server's stream).
            let m = try get(r.name)
            return try JSONValue(encoding: BootConsoleLines(name: m.name, lines: BootConsoleTail.lines(of: m.sandbox.bootLogURL)))
        case .prepare:
            return try JSONValue(encoding: try await prepare(r, emit: emit, onboarding: false))
        case .onboard:
            return try JSONValue(encoding: try await prepare(r, emit: emit, onboarding: true))
        case .prepareStatus:
            return try JSONValue(encoding: try prepareStatus())
        case .prepareCancel:
            return try JSONValue(encoding: try cancelPreparations(r))
        case .agentPrompt:
            return try JSONValue(encoding: try agentPrompt(r))
        case .sandboxSettings:
            return try JSONValue(encoding: try sandboxSettings(r))
        case .access:
            return try JSONValue(encoding: try await access(r))
        case .accessGithubKey:
            return try JSONValue(encoding: try setAccessGithubKey(r))
        case .attach, .events, .hostStop:
            throw HostError(.invalid, "\(r.op.rawValue) is handled by the server")
        }
    }

    /// 591: where a sandbox's boot console is written (for the `console --follow` stream).
    public func bootLogURL(_ name: String?) throws -> (URL, String) {
        let m = try get(name)
        return (m.sandbox.bootLogURL, m.name)
    }

    public func status(connections: Int = 0, idleSeconds: Double? = nil, idleTimeoutMinutes: Double = 0,
                       startedAt: Date = Date()) async -> HostStatus {
        var s = HostStatus(version: version, protocolVersion: HostProtocol.version, pid: getpid(), startedAt: startedAt, store: store.root.path,
                           idleTimeoutMinutes: idleTimeoutMinutes, liveSandboxes: await liveSandboxes(), connections: connections,
                           idleSeconds: idleSeconds)
        s.executable = executable?.path
        if !readOnly {
            s.parentPid = getppid()
            s.sessionID = getsid(0)
            s.launchedDetached = HostServer.launchedDetached
            s.microphoneApp = Self.microphoneApp?.description
        }
        if let executable, let c = executableChange() {
            s.executableChange = c.rawValue
            s.executableNote = ExecutableIdentity.explain(c, path: executable.path)
        } else if let gone = programGone() {
            // 598: the program file is still there but its resources went (a keg half-removed).
            s.executableChange = ExecutableIdentity.Change.removed.rawValue
            s.executableNote = gone
        }
        return s
    }

    // MARK: create

    private func create(_ r: HostRequest, emit: @escaping @Sendable (HostEvent) -> Void = { _ in }) async throws -> SandboxInfo {
        guard let name = r.name else { throw HostError(.invalid, "which sandbox? (a name is required)") }
        guard var o = r.create else { throw HostError(.invalid, "create needs --image") }
        guard managed[name] == nil, !creating.contains(name) else { throw HostError(.exists, "sandbox \(name) already exists") }
        guard !FileManager.default.fileExists(atPath: store.layout(name).sandboxDirectory.path) else {
            throw HostError(.exists, "\(store.layout(name).sandboxDirectory.path) already exists (not made by doz — remove it or pick another name)")
        }
        if o.isolated == true, o.workspace != nil { throw HostError(.invalid, "isolated or a workspace — not both") }
        creating.insert(name)
        defer { creating.remove(name) }
        // 594: a workspace that does not exist is made now (mkdir -p), before the VM is configured —
        // and unmade (only what Dozer made, only while empty) if the create fails.
        var prepared: Workspace.Prepared?
        if let ws = o.workspace {
            prepared = try Workspace.prepare(ws, store: store)
            o.workspace = prepared?.path
        }
        var made = false
        defer { if !made, let p = prepared { Workspace.undo(p) } }
        // 596 (B6): a Dockerfile is registered (its base id is the image's); its first start builds it.
        var dockerfile: DockerfileRecord?
        if let df = o.dockerfile {
            let rec = try Dockerfiles.register(df, store: store)
            let agent = ImageChoice.parse(o.image).map(\.agent) ?? .none
            o.image = ImageChoice(base: rec.base, agent: agent).name
            dockerfile = rec
        } else if let c = ImageChoice.parse(o.image), c.isDockerfile, Dockerfiles.record(c.base, store) == nil {
            throw HostError(.notFound, "no Dockerfile is known for \(c.base) — create with --dockerfile PATH")
        }
        // 594: an agent image — latest asked of the registry (hourly, offline-tolerant); this sandbox
        // gets the image already prepared. 594 W28: an out-of-date one is used as it is (the CLI and
        // the page say so) unless the user chose `rebuild` — then this doz's image is prepared first.
        await freshen(o.image, update: false)
        if o.rebuild == true, DozerImages.builtIn.contains(DozerImages.canonicalName(o.image))
            || DozerImages.isPreparable(DozerImages.canonicalName(o.image), store: store) {
            let img = DozerImages.canonicalName(o.image)
            emit(HostEvent(kind: .note, sandbox: name, text: "rebuilding the \(img) image first (as asked) — existing sandboxes keep theirs"))
            try await follow(try preparation(for: img, requestedBy: "create \(name) --rebuild"), emit: emit)
        }
        let (spec, image) = try DozerImages.spec(name: name, options: o, store: store)
        // EXPERIMENTAL (604): an audio sandbox's VM boots the sound kernel — verified into the kernel cache now.
        if spec.audio == true {
            guard !buildFlavor.isPublic else { throw HostError(.invalid, BuildFlavor.audioMissing) }   // 611
            try MacAudio.installSoundKernel(into: spec.kernelCacheDirectory ?? StoreLayout(spec: spec).kernels)
        }
        // 594: the agent's credential prerequisite, before anything is made (pi: an API-key account).
        if spec.network.policy != nil {
            let (def, kinds) = accountKinds()
            if let p = AgentCredentials.createProblem(image: spec.imageSpec?.name, account: o.account, defaultAccount: def, kinds: kinds,
                                                      openaiDefault: openaiDefault(for: spec.imageSpec?.name), codexMac: AgentCredentials.provider(spec.imageSpec?.name) == "openai" && codexMacSignedIn()) {
                throw HostError(.invalid, p)
            }
        }
        var cfg = SandboxConfig(name: name, image: image, spec: spec, workspace: spec.shares.first?.hostPath)
        // 588: a proxied sandbox follows the store's default account unless told otherwise.
        if spec.network.policy != nil {
            switch o.account {
            case nil, "default": cfg.account = "default"
            case "none": cfg.account = nil
            case let a?:
                guard accountStore.load().accounts.contains(where: { $0.name == a }) else {
                    throw HostError(.notFound, "no account \(a) (doz account ls)")
                }
                cfg.account = a
            }
        } else if let a = o.account, a != "none", a != "default" {
            throw HostError(.invalid, "--account needs a proxied network (agent, open, …): the credential lives in the host's proxy")
        }
        // 594: its own layer of the environment prompt, and the project file it came from.
        if let text = o.agentPrompt {
            guard text.utf8.count <= SandboxConfig.maximumAgentPromptBytes else { throw HostError(.invalid, "an agent prompt is at most 16 KiB") }
            cfg.agentPrompt = text
        }
        if let mode = o.agentPromptMode {
            guard ["append", "replace"].contains(mode) else { throw HostError(.invalid, "the agent prompt's mode is append or replace") }
            cfg.agentPromptMode = mode
        }
        cfg.project = o.project
        cfg.agentSudo = o.agentSudo
        cfg.dockerfile = dockerfile?.dockerfile
            ?? cfg.imageChoice.flatMap { $0.isDockerfile ? Dockerfiles.record($0.base, store)?.dockerfile : nil }
        // 599: its own values of the per-sandbox settings (the clipboard and browser bridges, tmux).
        if let s = o.settings, !s.isEmpty { cfg.settings = try Self.checkedSandboxSettings(s) }
        try cfg.write(store.configFile(name))
        let m = try adopt(cfg)
        var createDetail = ["network": cfg.networkName]
        if let kind = createdAccountKind(cfg.account) { createDetail["account"] = kind }     // the KIND only, never a name
        metrics?.record(run: metricsRun, action: "create", sandbox: name, image: image, phaseAfter: "off", startedAt: Date(), durationMs: 0,
                        detail: createDetail)
        made = true
        note(name, "created (\(image), \(spec.cpus) CPUs, \(spec.memoryMiB) MiB, network \(cfg.networkName)"
             + (prepared?.created == true ? ", workspace \(cfg.workspace ?? "") created" : cfg.workspace == nil ? ", isolated" : "") + ")")
        var i = await info(m, sessions: false)
        i.workspaceCreated = prepared?.created == true ? true : nil
        // `doz create --prepare`: what this sandbox's first start would wait for — its image's
        // preparation (started, or joined when one runs) — now, with its progress; the sandbox stays off.
        if o.prepare == true {
            if let img = await imageToPrepare(m) {
                let p = try preparation(for: img, requestedBy: "create \(name)")
                let first = p.info.requestedBy.first ?? ""
                emit(HostEvent(kind: .note, sandbox: name, text: first == "create \(name)"
                               ? "\(img) is not prepared in this store yet — preparing it now (once: the kernel, the base image, the bake); \(name) stays off"
                               : "\(img) is being prepared (\(first) started it) — joining it; \(name) stays off"))
                do { try await follow(p, emit: emit) } catch {
                    throw HostError(.failed, "\(name) was created, but preparing \(img) failed: \(HostError.from(error).message) — its first start tries again")
                }
                i = await info(managed[name] ?? m, sessions: false)
                i.workspaceCreated = prepared?.created == true ? true : nil
                i.imagePreparation = "prepared"
            } else {
                i.imagePreparation = "ready"          // the answer says it (the CLI's line, --json)
            }
        }
        return i
    }

    /// 596 (B8): a Dockerfile sandbox with no root disk (never started, or reset) takes the image its
    /// Dockerfile's last build made — the one a new sandbox would get. A sandbox created before the
    /// first build holds a placeholder base until then. A sandbox WITH a root disk keeps it ("rebuild
    /// available" until `doz reset`). The sandbox's other settings are kept; its record is rewritten
    /// and it is adopted again (it is off: no VM, no session).
    private func rebindDockerfileImage(_ m: Managed, emit: @escaping @Sendable (HostEvent) -> Void) throws -> Managed {
        guard let current = m.config.spec.imageSpec, let c = ImageChoice.parse(current.name), c.isDockerfile,
              m.config.spec.customImage == nil, !m.sandbox.hasRootDisk,
              let fresh = try? DozerImages.spec(name: m.name, options: CreateOptions(image: c.name), store: store).0.imageSpec,
              !Dockerfiles.isPlaceholder(fresh.base), fresh != current else { return m }
        var cfg = m.config
        cfg.spec.imageSpec = fresh
        try cfg.write(store.configFile(m.name))
        detachWatcher(m)
        m.eventTask?.cancel()
        m.networkTask?.cancel()
        managed[m.name] = nil
        let nm = try adopt(cfg)
        let short = fresh.base.split(separator: "@").last.map { String($0.prefix(19)) } ?? ""
        emit(HostEvent(kind: .note, sandbox: m.name, text: "\(m.name) takes its Dockerfile's image as built now (\(short))"))
        note(m.name, "takes its Dockerfile's image as built now (\(short))")
        return nm
    }

    // MARK: lifecycle

    /// Start-or-wake, and every other lifecycle operation, in the owner's vocabulary. An operation
    /// that finds the sandbox already where it leads does nothing (`changed: false`).
    private func lifecycle(_ op: HostOp, name: String?, emit: @escaping @Sendable (HostEvent) -> Void) async throws -> LifecycleResult {
        guard op == .start else { return try await lifecycleBody(op, name: name, emit: emit) }
        // 610 (590.B3): a cold start is recorded from here — its image's preparation included — to its end, so
        // what needs the sandbox running meanwhile (an open-session, an attach, an exec) JOINS it instead of
        // finding it "off"; and a second start joins the first instead of booting it twice.
        let first = try get(name)
        let key = first.name
        let cold = [.off, .failed].contains(await effectivePhase(first))
        guard cold || coldStarts.isRunning(key) else {
            return try await lifecycleBody(op, name: key, emit: emit)
        }
        guard coldStarts.begin(key) else {
            emit(HostEvent(kind: .note, sandbox: key, text: "\(key) is already starting — joining that start"))
            try await coldStarts.wait(key)
            return try await lifecycleBody(op, name: key, emit: emit)      // running now: nothing to do
        }
        do {
            let r = try await lifecycleBody(op, name: key, emit: emit)
            coldStarts.finish(key, error: nil)
            return r
        } catch {
            coldStarts.finish(key, error: Self.joinedStartFailed(key, error))
            throw error
        }
    }

    /// 610: what a caller that joined a cold start is told when that start failed — the start's own reason.
    static func joinedStartFailed(_ name: String, _ error: Error) -> HostError {
        let e = HostError.from(error)
        return HostError(e.code, "\(name) did not start — \(e.message)")
    }

    private func lifecycleBody(_ op: HostOp, name: String?, emit: @escaping @Sendable (HostEvent) -> Void) async throws -> LifecycleResult {
        var m = try get(name)
        // 594 (D4): a cold start that needs an image being prepared — or never prepared — joins that
        // preparation (one download, one bake, whoever asks), its progress on this caller's stream.
        // (596: before anything else, so a Dockerfile sandbox can take the image its build made.)
        let t0 = ContinuousClock.now
        if op == .start, [.off, .failed].contains(await effectivePhase(m)) {
            if let image = await imageToPrepare(m) {
                let p = try preparation(for: image, requestedBy: "start \(m.name)")
                let first = p.info.requestedBy.first ?? ""
                emit(HostEvent(kind: .note, sandbox: m.name, text: first == "start \(m.name)"
                               ? "\(image) is not prepared in this store yet — preparing it first (once: the kernel, the base image, the bake)"
                               : "\(image) is being prepared (\(first) started it) — joining it: one download, one bake"))
                try await follow(p, emit: emit)
            }
            m = try rebindDockerfileImage(m, emit: emit)
        }
        let sb = m.sandbox
        let before = await effectivePhase(m)
        func result(_ changed: Bool) async -> LifecycleResult {
            let after = await effectivePhase(m)
            return LifecycleResult(name: m.name, operation: op.rawValue, phaseBefore: before.rawValue, phase: after.rawValue,
                                   changed: changed, milliseconds: ms(since: t0),
                                   info: op == .rm ? nil : await info(managed[m.name] ?? m, sessions: false))   // (W28: a reset may have moved it to a new image)
        }
        func invalid(_ hint: String = "") -> HostError {
            HostError(.invalidPhase, "\(op.rawValue) is not possible while \(m.name) is \(PhaseName.label(before))" + hint)
        }

        // What to do, decided from the phase observed now.
        typealias Body = @Sendable () async throws -> Void
        var action: (label: String, body: Body)?
        switch op {
        case .start:
            switch before {
            case .running: break
            case .paused: action = ("resume", { try await sb.resume() })
            case .asleep, .hibernated: action = ("wake", { try await sb.wake() })
            case .off, .failed: action = ("start", { try await sb.start() })
            case .booting: throw invalid()
            }
        case .wake, .resume:
            switch before {
            case .running: break
            case .paused: action = ("resume", { try await sb.resume() })
            case .asleep, .hibernated: action = ("wake", { try await sb.wake() })
            case .off, .failed: throw invalid(" — `doz start \(m.name)` boots it")
            case .booting: throw invalid()
            }
        case .pause:
            switch before {
            case .paused: break
            case .running: action = ("pause", { try await sb.pause() })
            default: throw invalid()
            }
        case .sleep:
            switch before {
            case .asleep: break
            case .running, .paused: action = ("sleep", { try await sb.sleep() })
            default: throw invalid()
            }
        case .hibernate:
            switch before {
            case .hibernated: break
            case .running, .paused, .asleep:
                // 583: a program a session started less than 3 s ago gets the rest of that time first.
                let wait = Self.settleDelay(since: m.lastSessionOpen.map { ContinuousClock.now - $0 })
                action = ("hibernate", {
                    if wait > .zero { try? await Task.sleep(for: wait) }
                    try await sb.hibernate()
                })
            default: throw invalid()
            }
        case .shutdown:
            let actorPhase = await sb.phase
            if actorPhase == .off {
                if Sandbox.restorableState(for: sb.spec) != nil {
                    // Hibernated by an earlier host: wake it so it stops gracefully (a clean
                    // unmount), and only if that fails throw the snapshot away (the disk gets e2fsck).
                    let spec = sb.spec
                    action = ("shut down", {
                        do { try await sb.wake(); try await sb.shutDown() } catch {
                            try? await sb.shutDown()
                            if await sb.phase == .off, Sandbox.restorableState(for: spec) != nil { Sandbox.discardRestorableState(for: spec) }
                        }
                    })
                }
            } else {
                action = ("shut down", { try await sb.shutDown() })
            }
        case .reset:
            action = ("reset to image", { try await sb.resetToImage() })
        case .rm:
            action = ("delete sandbox", { try await sb.delete() })
        default:
            throw HostError(.invalid, "not a lifecycle operation: \(op.rawValue)")
        }
        guard let action else { return await result(false) }

        // Forward this sandbox's progress to the caller while the operation runs.
        let stream = sb.events()
        let name = m.name
        let forward = Task { for await e in stream { if let he = HostEvent(e, sandbox: name) { emit(he) } } }
        let row = beginAction(m, action.label, phaseBefore: before.rawValue)
        // 593: a start and a wake are BOOTS — kept (steps, console, result) for the Boot log.
        let bootKind: String? = action.label == "start" ? "cold boot" : action.label == "wake" ? "wake" : nil
        if let bootKind { beginBoot(m, kind: bootKind) }
        do {
            try await action.body()
        } catch {
            if bootKind != nil { await endBoot(m, error: error) }
            for _ in 0..<8 { await Task.yield() }
            forward.cancel()
            finishAction(m, row, t0, ok: false, error: error, phaseAfter: (await effectivePhase(m)).rawValue)
            throw error
        }
        if bootKind != nil { await endBoot(m, error: nil) }
        for _ in 0..<8 { await Task.yield() }
        forward.cancel()
        finishAction(m, row, t0, ok: true, phaseAfter: (await effectivePhase(m)).rawValue)
        // 593 §9: a reset's or a shutdown's sessions are gone — so are its panes (owner, 2026-09-30; the
        // saved screens went with the library's step).
        if op == .reset || op == .shutdown { try? TerminalLayout.write(nil, store, m.name); SessionRecords.write(nil, store, m.name) }
        // 594 W28: a reset takes the image a NEW sandbox gets now (after a rebuild: this doz's) — the
        // state disk (the agent's own state) and the workspace are kept; the next start clones it.
        if op == .reset { moveToCurrentImage(m) }
        if [.start, .shutdown, .reset].contains(op), m.config.diedWithHostAt != nil {
            m.config.diedWithHostAt = nil
            try? m.config.write(store.configFile(m.name))
        }
        if op == .rm {
            detachWatcher(m)
            clearStatuses(m.name)                                       // 612
            m.eventTask?.cancel()
            m.networkTask?.cancel()
            managed[m.name] = nil
            try? FileManager.default.removeItem(at: store.layout(m.name).sandboxDirectory)
            note(m.name, "removed")
        }
        return await result(true)
    }

    /// 594 W28: after a reset (the root disk is gone), point the sandbox at the agent image a create
    /// would take now; its next start clones that. Nothing changes for a template's sandbox, a lab, or
    /// when the image a create takes is the one it has.
    private func moveToCurrentImage(_ m: Managed) {
        guard let old = m.config.spec.imageSpec, ImageChoice.parse(old.name)?.name == old.name, m.config.spec.customImage == nil,
              let now = (try? AgentVersions.spec(old.name, purpose: .create, store: store, settings: .load())) ?? nil,
              now != old, AgentVersions.usable(old.name, store: store, settings: .load()).contains(now) else { return }
        var cfg = m.config
        cfg.spec.imageSpec = now
        do { try cfg.write(store.configFile(m.name)) } catch { note(m.name, "could not record the new image: \(error.localizedDescription)"); return }
        detachWatcher(m)
        m.eventTask?.cancel()
        m.networkTask?.cancel()
        managed[m.name] = nil
        do { try adopt(cfg) } catch { note(m.name, "could not take the new image: \(error.localizedDescription)"); return }
        note(m.name, "reset to the \(old.name) image \(now.agent?.version ?? "")\(AgentVersions.isCurrentRecipe(now) ? " (this doz's)" : "") — the next start boots it")
    }

    /// How long hibernating waits for a program started `since` ago (the rest of 3 s).
    static func settleDelay(since: Duration?, settle: Duration = .seconds(3)) -> Duration {
        guard let since, since >= .zero, since < settle else { return .zero }
        return settle - since
    }

    /// What `ensureRunning` had to do first (594 W27).
    struct EnsureOutcome {
        var started = false
        var woke = false
        var milliseconds: Double?
    }

    /// Make sure `m` runs, waking a paused or sleeping sandbox when `wake`, and — 594 W27, when `start`
    /// (`doz exec`/`doz run` say so unless --no-start) — cold-starting one that is off or failed, exactly
    /// as `start` does (the boot view, the kept boot log, the metrics row).
    @discardableResult
    func ensureRunning(_ m: Managed, wake: Bool, start: Bool = false,
                       emit: @escaping @Sendable (HostEvent) -> Void = { _ in }) async throws -> EnsureOutcome {
        // 594 W10: a wake by use (an attach, a terminal) follows the Mac's zone as it is now.
        m.sandbox.setTimeZone(Self.guestTimeZone())
        // 610 (590.B3): a cold start under way (a first start's preparation takes minutes, and the sandbox is OFF
        // all that time) is JOINED: wait for its end, then go on — or fail with its reason. Then look again from the
        // sandbox's current record (a Dockerfile sandbox is re-adopted with its built image during its start).
        if coldStarts.isRunning(m.name) {
            emit(HostEvent(kind: .note, sandbox: m.name, text: "\(m.name) is starting — waiting for it to run"))
            try await coldStarts.wait(m.name)
            return try await ensureRunning(try get(m.name), wake: wake, start: start, emit: emit)
        }
        let deadline = ContinuousClock.now + .seconds(300)
        while true {
            let p = await effectivePhase(m)
            let busy = await m.sandbox.status.busy
            switch p {
            case .running where !busy: return EnsureOutcome()
            case .off where start && !busy, .failed where start && !busy:
                let r = try await lifecycle(.start, name: m.name, emit: emit)
                return EnsureOutcome(started: true, milliseconds: r.milliseconds)
            case .paused where wake && !busy:
                let t0 = ContinuousClock.now
                try await m.sandbox.resume()
                return EnsureOutcome(woke: true, milliseconds: ms(since: t0))
            case .asleep where wake && !busy, .hibernated where wake && !busy:
                // 598: a wake by use after an upgrade removed this host's installation: say so first.
                if let gone = programGone() { throw HostError(.unavailable, gone) }
                // 595: a wake by use reads the kernel and the guest init — a resource deletion waits for it.
                diskOpsInFlight += 1
                defer { diskOpsInFlight -= 1 }
                let row = beginAction(m, "wake", phaseBefore: p.rawValue)
                let t0 = ContinuousClock.now
                beginBoot(m, kind: "wake")
                do { try await m.sandbox.wake() } catch {
                    await endBoot(m, error: error)
                    finishAction(m, row, t0, ok: false, error: error)
                    throw error
                }
                await endBoot(m, error: nil)
                finishAction(m, row, t0, ok: true, phaseAfter: "running", detail: ["trigger": "use"])
                return EnsureOutcome(woke: true, milliseconds: ms(since: t0))
            case .off, .failed:
                throw HostError(.invalidPhase, "\(m.name) is \(PhaseName.label(p)) — `doz start \(m.name)` boots it")
            case .paused, .asleep, .hibernated:
                if !wake && !busy { throw HostError(.invalidPhase, "\(m.name) is \(PhaseName.label(p))") }
            case .booting, .running:
                break
            }
            if ContinuousClock.now > deadline { throw HostError(.failed, "\(m.name) stayed busy for 5 minutes") }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// For the server's attach relay.
    /// 594 (W17): the session `doz attach NAME` (no session) attaches to.
    func defaultSessionName(_ name: String?) -> String? {
        name.flatMap { managed[$0] }?.config.defaultSession.name
    }

    func sandboxForAttach(_ name: String?, session: String?, wake: Bool) async throws -> (Sandbox, String) {
        let m = try get(name)
        if wake { try await ensureRunning(m, wake: true) }
        let session = session ?? m.config.defaultSession.name
        try GuestCommand.validateSessionName(session)
        // Activity for the "left running with no activity" count: when, never what.
        metrics?.record(run: metricsRun, action: "attach", sandbox: m.name, image: m.config.image, startedAt: Date(), durationMs: 0)
        return (m.sandbox, session)
    }

    /// The effective phase by name (nil: no such sandbox any more).
    func phase(of name: String) async -> Phase? {
        guard let m = managed[name] else { return nil }
        return await effectivePhase(m)
    }

    func busy(_ name: String) async -> Bool {
        guard let m = managed[name] else { return false }
        return await m.sandbox.status.busy
    }

    func sessionAttached(_ name: String, session: String, ms: Double) {
        Task { await self.watchStatus(name, session: session) }       // 612: a session the host had not opened
        guard let m = managed[name], let id = m.sessionRows[session] else { return }
        metrics?.sessionFirstAttach(id, ms: ms)
    }

    func sessionEnded(_ name: String, session: String, exitCode: Int32?) {
        guard let m = managed[name], let id = m.sessionRows[session] else { return }
        metrics?.sessionEnded(id, exitCode: exitCode)
    }

    /// Hibernate everything with a VM (quit = Hibernate, owner ruling 2026-09-25) — `host stop`
    /// and a SIGTERM. The next wake restores each with its sessions and pids.
    /// 594 W22: `onEvent` gets each sandbox's line as it starts and ends (`HostStopView`) and the host's
    /// own last step; the rows are the stop's answer.
    @discardableResult
    public func prepareAllForExit(onEvent: @escaping @Sendable (HostEvent) -> Void = { _ in }) async -> [HostStopRow] {
        // 594: a preparation ends with the host (a bake caches nothing until it is complete).
        await cancelAllPreparations()
        var rows: [(name: String, m: Managed, row: Int64?, before: Phase)] = []
        for (name, m) in managed {
            let before = await m.sandbox.phase
            guard [.running, .paused, .asleep, .booting, .failed].contains(before) else { continue }
            rows.append((name, m, beginAction(m, "quit (hibernate)", phaseBefore: before.rawValue), before))
        }
        rows.sort { (a, b) in a.name < b.name }
        let t0 = ContinuousClock.now
        let work: [(Sandbox, String)] = rows.map { ($0.m.sandbox, $0.name) }
        let befores = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0.before) })
        // Each in parallel, as before; each one's line starts and ends as it does.
        let outcomes: [String: (Sandbox.ExitOutcome, Double)] = await withTaskGroup(of: (String, Sandbox.ExitOutcome, Double).self) { group in
            for (sb, name) in work {
                onEvent(HostStopView.started(name))
                group.addTask {
                    let s = ContinuousClock.now
                    let o = await sb.prepareForExit()
                    let d = ContinuousClock.now - s
                    return (name, o, Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
                }
            }
            var out: [String: (Sandbox.ExitOutcome, Double)] = [:]
            for await (name, o, ms) in group {
                out[name] = (o, ms)
                if let m = managed[name] {
                    onEvent(HostStopView.finished(await stopRow(name, m, before: befores[name] ?? .running, o, ms)))
                }
            }
            return out
        }
        var result: [HostStopRow] = []
        for r in rows {
            let after = await effectivePhase(r.m)
            let (o, ms) = outcomes[r.name] ?? (Sandbox.ExitOutcome.unchanged, 0)
            if case .hibernateFailed = o {
                finishAction(r.m, r.row, t0, ok: false, phaseAfter: after.rawValue)
            } else {
                finishAction(r.m, r.row, t0, ok: true, phaseAfter: after.rawValue)
            }
            result.append(await stopRow(r.name, r.m, before: r.before, o, ms))
        }
        let s = ContinuousClock.now
        onEvent(HostEvent(kind: .started, sandbox: nil, text: "saving the host's state"))
        for name in managed.keys { recordNetwork(name) }
        let d = ContinuousClock.now - s
        onEvent(HostEvent(kind: .step, sandbox: nil, text: "saving the host's state",
                          milliseconds: Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15))
        return result
    }

    private func stopRow(_ name: String, _ m: Managed, before: Phase, _ o: Sandbox.ExitOutcome, _ ms: Double) async -> HostStopRow {
        let after = await effectivePhase(m).rawValue
        switch o {
        case .hibernated:
            let size = (try? FileManager.default.attributesOfItem(atPath: store.layout(name).snapshot.path)[.size] as? NSNumber)?.int64Value
            return HostStopRow(name: name, phaseBefore: before.rawValue, phase: after, outcome: "hibernated", milliseconds: ms, snapshotBytes: size)
        case .hibernateFailed(let why):
            return HostStopRow(name: name, phaseBefore: before.rawValue, phase: after, outcome: "failed", milliseconds: ms, error: why)
        case .keptFailedWake:
            return HostStopRow(name: name, phaseBefore: before.rawValue, phase: after, outcome: "kept", milliseconds: ms)
        case .shutDown, .unchanged:
            return HostStopRow(name: name, phaseBefore: before.rawValue, phase: after, outcome: "shut-down", milliseconds: ms)
        }
    }

    // MARK: sessions

    /// 593 §9: a running sandbox's sessions come from the guest (`deckhold ls`), each with when its
    /// screen was last saved; in any other phase, from its SAVED screens (S5: `saved: true`) — so a
    /// sleeping or shut-down sandbox's sessions are listed without waking it (and looking never starts
    /// the host: this is answered in-process too).
    func sessionRows(_ m: Managed) async throws -> [SessionRow] {
        let saved = m.sandbox.savedScreens()
        guard await m.sandbox.phase == .running else {
            // Only a sandbox one wakes back into has sessions to show (owner, 2026-09-30): shut down,
            // failed or booting — none.
            return withStatuses(m.name, Self.wakeable(await effectivePhase(m)) ? saved.map(SessionRow.init(saved:)) : [], live: nil)
        }
        let byName = Dictionary(saved.map { ($0.session, $0) }, uniquingKeysWith: { a, _ in a })
        let list = try await m.sandbox.sessions()
        let rows = list.map { s in
            var row = SessionRow(s)
            if let i = byName[s.name] {
                row.savedAt = i.savedAt
                row.savedReason = i.reason
            }
            return row
        }
        // 612: a live session the host does not watch yet (opened from inside the guest, or before a host restart).
        for s in list where !s.isEnded { Task { await self.watchStatus(m.name, session: s.name) } }
        return withStatuses(m.name, rows, live: list)
    }

    /// The phases one wakes (or resumes) back into — the only ones with saved screens.
    static func wakeable(_ p: Phase) -> Bool { p == .paused || p == .asleep || p == .hibernated }

    /// 593 §9 (S2): the light periodic capture — every `minutes` (the setting
    /// `host.screen_capture_minutes`; 0 = off), each RUNNING sandbox's sessions that wrote something
    /// since their last saved screen, so a crash still leaves a recent copy. One `deckhold ls` per
    /// sandbox, then a momentary attach per changed session; serialised with the lifecycle.
    public func captureScreensPeriodically() async {
        for m in managed.values {
            guard await m.sandbox.phase == .running else { continue }
            let sb = m.sandbox
            guard let r = await sb.captureScreens(changedOnly: true) else { continue }
            if !r.captured.isEmpty || !r.failed.isEmpty {
                HostLog.line("\(m.name): periodic screen capture — saved \(r.captured.joined(separator: ", "))"
                             + (r.failed.isEmpty ? "" : "; failed \(r.failed.joined(separator: ", "))")
                             + String(format: " (%.0f ms)", r.milliseconds))
            }
        }
    }

    /// The environment, working directory and user an `exec` runs with — the same as a session's.
    static func execContext(config: SandboxConfig, environment: [String: String], workdir: String?,
                            user: String?) -> (environment: [String: String], workdir: String, user: String?) {
        guard let r = config.spec.imageSpec else {
            return (environment, workdir ?? (config.workspace != nil ? DozerImages.workspaceGuestPath : "/root"), user)
        }
        let runAs = user ?? r.user
        var env = r.sessionEnvironment
        if let p = env["PATH"] { env["PATH"] = Sandbox.withGames(p) }     // 594 W30: /usr/games too
        if runAs == r.user { env["HOME"] = r.home; env["USER"] = r.user }
        env.merge(environment) { _, caller in caller }
        return (env, workdir ?? r.workdir, runAs == "root" ? nil : runAs)
    }

    /// 591: the settings' `claude.permissions` reaches the guest's claude launcher as
    /// `DOZ_CLAUDE_PERMISSIONS` — only in a claude-code sandbox, only when it is not the default
    /// (`skip`), and never over the caller's own `-e DOZ_CLAUDE_PERMISSIONS=…`.
    static func withClaudePermissions(_ env: [String: String], imageSpec: String?,
                                      settings: @autoclosure () -> DozerSettings = .load()) -> [String: String] {
        // 599i: Codex's launcher reads DOZ_CODEX_PERMISSIONS (the setting codex.permissions) the same way.
        if imageSpec.flatMap({ ImageChoice.parse($0) })?.agent == .codex {
            guard env["DOZ_CODEX_PERMISSIONS"] == nil, let mode = settings().string(SettingKey.codexPermissions), mode != "skip" else { return env }
            var e = env
            e["DOZ_CODEX_PERMISSIONS"] = mode
            return e
        }
        guard imageSpec.flatMap({ ImageChoice.parse($0) })?.agent == .claudeCode, env["DOZ_CLAUDE_PERMISSIONS"] == nil else { return env }
        guard let mode = settings().string(SettingKey.claudePermissions), mode != "skip" else { return env }
        var e = env
        e["DOZ_CLAUDE_PERMISSIONS"] = mode
        return e
    }

    /// 590: one `open-session` at a time per sandbox. This actor is re-entrant across its awaits, so
    /// two opens of one session (two clicks while the sandbox booted — the owner's first `doz
    /// ui` session; or two quick `doz run`) both saw "not running", both started `deckhold
    /// serve`, and one failed "Address in use". Serialized, the second sees the first's session and
    /// answers "already running".
    private func openSession(_ r: HostRequest, emit: @escaping @Sendable (HostEvent) -> Void = { _ in }) async throws -> SessionOpened {
        var m = try get(r.name)
        let key = m.name
        // 610 (590.B3): join a cold start under way BEFORE queueing at the gate, so every open made during it —
        // not only the first in the queue — ends with the start (and fails with its reason when it fails).
        if coldStarts.isRunning(key) {
            emit(HostEvent(kind: .note, sandbox: key, text: "\(key) is starting — the session opens when it runs"))
            try await coldStarts.wait(key)
            m = try get(key)
        }
        await sessionGate.lock(key)
        defer { sessionGate.unlock(key) }
        // 594 W27: an off sandbox is cold-started first when the caller asks (`doz run` does).
        let first = try await ensureRunning(m, wake: r.wake ?? true, start: r.start ?? false, emit: emit)
        var opened = try await openSessionLocked(r)
        if first.started { opened.started = true }
        if first.woke { opened.woke = true }
        opened.bootMilliseconds = first.milliseconds
        return opened
    }

    /// `extraArguments` (608): appended to the program's argv after everything the host adds (pi's prompt
    /// file) and NOT recorded — a restart's resume arguments (`SessionResume`).
    func openSessionLocked(_ r: HostRequest, extraArguments: [String] = []) async throws -> SessionOpened {
        let opened = try await openSessionBody(r, extraArguments: extraArguments)
        await watchStatus(opened.name, session: opened.session)      // 612: what the program says it is doing
        return opened
    }

    private func openSessionBody(_ r: HostRequest, extraArguments: [String]) async throws -> SessionOpened {
        let m = try get(r.name)
        try await ensureRunning(m, wake: r.wake ?? true)
        // 599g: a rule file that appeared since the boot gets its view before the program starts (nothing
        // runs in the guest when nothing changed).
        await m.sandbox.refreshWorkspaceViews()
        let list = try await m.sandbox.sessions()
        let live = Set(list.filter { !$0.isEnded }.map(\.name))
        let all = Set(list.map(\.name))
        var argv: [String]
        let session: String
        // 599 (594.B3): the session inside tmux (the sandbox's own choice, else sessions.tmux).
        let tmuxWanted = Self.sandboxValue(m.config, SettingKey.tmux) == .bool(true)
        if let s = r.session {
            try GuestCommand.validateSessionName(s)
            if live.contains(s) {
                // The same program again (a repeated click, a retried `run`) is the session already running.
                let running = list.first(where: { $0.name == s && !$0.isEnded })?.command
                if let a = r.argv, running != a.joined(separator: " "), running != GuestCommand.inTmux(session: s, argv: a).joined(separator: " ") {
                    throw HostError(.exists, "session \(s) is already running in \(m.name) — attach to it, or pick another name")
                }
                return SessionOpened(name: m.name, session: s, created: false)
            }
            session = s
            argv = r.argv ?? (s == m.config.defaultSession.name ? m.config.defaultSession.argv : ["bash", "-l"])
        } else if let a = r.argv, !a.isEmpty {
            let base = DozerImages.sessionName(for: a)
            var name = base, n = 2
            while all.contains(name) { name = "\(base)-\(n)"; n += 1 }
            session = name
            argv = a
        } else {
            let d = m.config.defaultSession
            if live.contains(d.name) { return SessionOpened(name: m.name, session: d.name, created: false) }
            session = d.name
            argv = d.argv
        }
        // 608: what a restart reopens — the program as chosen here (before pi's prompt file, tmux, a resume).
        let recordArgv = argv
        // 594 (D15): the environment prompt and the dozer skill, rendered from the sandbox's current
        // facts and written into the guest before the program starts. pi's own session names the
        // facts file (pi reads a file given to --append-system-prompt); Claude Code's launcher reads it.
        // 594 W28: never claim sudo the guest does not have (a disk from an older image).
        // 599 (594.B2): the browser bridge's xdg-open — written at every fresh boot; here too, for a
        // sandbox that has run since before this doz (a wake keeps its old disk state). Idempotent, ~20 ms.
        // 599 (594.B3): with tmux asked for, its configuration too, and whether the image has tmux.
        let prepared = try? await m.sandbox.exec(["sh", "-c", GuestCommand.openShimInstall + (tmuxWanted ? "; " + GuestCommand.tmuxPrepare : "")],
                                                 timeoutSeconds: 10)
        var tmuxNotice: String?
        let inTmux = tmuxWanted && prepared?.output.contains("tmux=yes") == true
        if tmuxWanted && !inTmux {
            tmuxNotice = "sessions.tmux is on, but this sandbox's image has no tmux (an older doz prepared it) — \(session) runs without it; "
                + (m.config.spec.imageSpec != nil ? "doz image bake \(m.config.image) and doz reset \(m.name) bring it" : "install it in the sandbox (apk add tmux)")
            note(m.name, tmuxNotice!)
        }
        let sudoInstalled: Bool? = m.config.spec.imageSpec == nil ? nil
            : ((try? await m.sandbox.exec(["test", "-x", "/usr/bin/sudo"], timeoutSeconds: 10))?.exitCode).map { $0 == 0 }
        if let report = agentPromptReport(m, sudoInstalled: sudoInstalled) {
            if report.enabled, let error = report.error {
                throw HostError(.invalid, "the agent prompt does not render — \(error). Fix it, or turn the prompt off: doz config set agent.prompt false")
            }
            await deliverAgentPrompt(m, report)
            if report.agent == "pi", report.enabled, report.text != nil, argv == m.config.defaultSession.argv {
                argv += ["--append-system-prompt", AgentPrompt.guestPromptPath]
            }
        }
        argv += extraArguments
        // 599i: Codex's credentials for this session — its auth.json with placeholders only (or none).
        await deliverCodexAuth(m)
        let size = TermSize(cols: r.cols ?? 120, rows: r.rows ?? 36)
        let workdir: String? = m.config.spec.imageSpec == nil && m.config.workspace != nil ? DozerImages.workspaceGuestPath : nil
        // A command the caller named (doz run NAME -- CMD, the dashboard's "run a command"): a program the
        // guest does not have is said plainly, before a session that could only end at once with 127.
        if let a = r.argv, let program = a.first, !program.isEmpty,
           let look = await m.sandbox.sessionFinds(program, environment: r.environment ?? [:], workingDirectory: r.workdir ?? workdir, user: r.user),
           !look.found {
            throw HostError(.notFound, Self.missingProgram(program, runsAs: look.runsAs, command: "doz run"))
        }
        if inTmux { argv = GuestCommand.inTmux(session: session, argv: argv) }
        let t0 = ContinuousClock.now
        let started = Date()
        do {
            try await m.sandbox.openSession(session, argv: argv,
                                            environment: Self.withClaudePermissions(r.environment ?? [:], imageSpec: m.config.spec.imageSpec?.name),
                                            workingDirectory: r.workdir ?? workdir,
                                            user: r.user, size: size)
        } catch {
            // deckhold refuses a second holder of a name ("Address in use"): someone else (a program
            // in the guest, another client) started it meanwhile. That session is the answer.
            if let now = try? await m.sandbox.sessions(), now.contains(where: { $0.name == session && !$0.isEnded }) {
                note(m.name, "session \(session) was started meanwhile — using it")
                return SessionOpened(name: m.name, session: session, created: false)
            }
            metrics?.record(run: metricsRun, action: "session open", sandbox: m.name, image: m.config.image, startedAt: started,
                            durationMs: ms(since: t0), ok: false, error: error.localizedDescription, detail: ["session": session])
            throw error
        }
        m.lastSessionOpen = ContinuousClock.now
        // 608: the record a restart reopens from (names of the variables only — never their values).
        if !readOnly {
            SessionRecords.record(session, SessionRecord(argv: recordArgv, workdir: r.workdir, user: r.user,
                                                         environmentKeys: r.environment.map { Array($0.keys) }), store, m.name)
        }
        let openMs = ms(since: t0)
        metrics?.record(run: metricsRun, action: "session open", sandbox: m.name, image: m.config.image, phaseBefore: "running",
                        phaseAfter: "running", startedAt: started, durationMs: openMs, detail: ["session": session])
        if let id = metrics?.sessionOpened(run: metricsRun, sandbox: m.name, image: m.config.image, session: session,
                                           command: argv.joined(separator: " "), openedAt: started, openMs: openMs) {
            m.sessionRows[session] = id
        }
        var opened = SessionOpened(name: m.name, session: session, created: true)
        opened.tmux = inTmux ? true : nil
        opened.notice = tmuxNotice
        return opened
    }

    private func exec(_ r: HostRequest, emit: @escaping @Sendable (HostEvent) -> Void = { _ in }) async throws -> ExecOutput {
        let m = try get(r.name)
        guard let argv = r.argv, !argv.isEmpty else { throw HostError(.invalid, "exec needs a command (doz exec NAME -- CMD…)") }
        // 594 W27: an off sandbox is cold-started first when the caller asks (`doz exec` does).
        let first = try await ensureRunning(m, wake: r.wake ?? true, start: r.start ?? false, emit: emit)
        // 599i: `doz exec NAME -- codex exec …` works before any session has run (its auth.json, placeholders only).
        if m.config.imageChoice?.agent == .codex, (argv.first as NSString?)?.lastPathComponent == "codex" { await deliverCodexAuth(m) }
        let ctx = Self.execContext(config: m.config, environment: Self.withClaudePermissions(r.environment ?? [:], imageSpec: m.config.spec.imageSpec?.name),
                                   workdir: r.workdir, user: r.user)
        let t0 = ContinuousClock.now
        let res: ExecResult
        do {
            res = try await m.sandbox.exec(argv, environment: ctx.environment, workingDirectory: ctx.workdir, user: ctx.user,
                                           timeoutSeconds: r.timeoutSeconds ?? 120)
        } catch {
            if let plain = Self.missingProgramMessage(error, argv: argv, runsAs: ctx.user) { throw HostError(.notFound, plain) }
            throw error
        }
        var out = ExecOutput(exitCode: res.exitCode, stdout: res.stdout, stderr: res.stderr, milliseconds: ms(since: t0))
        // Activity (when, never what): the "left running with no activity" count.
        metrics?.record(run: metricsRun, action: "exec", sandbox: m.name, image: m.config.image, startedAt: Date(), durationMs: out.milliseconds)
        if first.started { out.started = true }
        if first.woke { out.woke = true }
        out.bootMilliseconds = first.milliseconds
        return out
    }

    /// A program the guest cannot find, said plainly. The guest agent's own words come wrapped three
    /// deep (`failed to start process (cause: "internalError: "startProcess: … vmexec error: … failed to
    /// find target executable sudo" (closed three times))`; a person needs only which program and what to do. nil: any
    /// other error (passed on as it was). `runsAs`: the guest user it ran as (nil = root).
    static func missingProgramMessage(_ error: Error, argv: [String], runsAs: String?) -> String? {
        missingProgramMessage(String(describing: error) + " " + error.localizedDescription, argv: argv, runsAs: runsAs)
    }

    static func missingProgramMessage(_ text: String, argv: [String], runsAs: String?) -> String? {
        let marker = "failed to find target executable"
        guard let r = text.range(of: marker) else { return nil }
        // The name the guest reports (up to a quote, space or bracket), else the command as given.
        let rest = text[r.upperBound...].drop { $0 == " " }
        // Stops: double quote, single quote, space, ")", "]", newline, backslash (as code points, so no
        // escaped quote sits in a literal here).
        let stops = Set([34, 39, 32, 41, 93, 10, 92].map { Character(UnicodeScalar(UInt8($0))) })
        let reported = String(rest.prefix { !stops.contains($0) })
        return missingProgram(reported.isEmpty ? (argv.first ?? "the program") : reported, runsAs: runsAs, command: "doz exec")
    }

    /// The sentence for `program` missing in the guest, run by `command` (doz exec / doz run) as
    /// `runsAs` (nil = root).
    static func missingProgram(_ program: String, runsAs: String?, command: String) -> String {
        var s = program.contains("/")
            ? "`\(program)` does not exist in this sandbox (or is not a program it can run)"
            : "`\(program)` is not installed in this sandbox's image (not on its PATH)"
        if (program as NSString).lastPathComponent == "sudo" {
            s += runsAs == nil
                ? " — and it is not needed: \(command) already runs as root unless --user names another user"
                : " — \(command) runs this sandbox's commands as \(runsAs!); --user root runs one as root"
        }
        return s
    }

    // MARK: inspect

    private func detail(_ m: Managed) async throws -> SandboxDetail {
        let i = await info(m, sessions: false)
        var sessions: [SessionRow]?
        var live: [SessionInfo]?
        if i.phase == Phase.running.rawValue, !i.busy, let list = try? await m.sandbox.sessions() { sessions = list.map(SessionRow.init); live = list }
        // 593 §9: paused, asleep or hibernated — the sessions as last saved (`saved: true`), from the
        // sandbox's directory. Shut down: none (owner, 2026-09-30).
        if let p = Phase(rawValue: i.phase), Self.wakeable(p), case let saved = m.sandbox.savedScreens(), !saved.isEmpty {
            sessions = saved.map(SessionRow.init(saved:))
        }
        sessions = sessions.map { withStatuses(m.name, $0, live: live) }      // 612
        let status = await m.sandbox.status
        return SandboxDetail(info: i, spec: m.sandbox.spec, policy: m.sandbox.egress?.policy, sessions: sessions,
                             restorePoints: m.sandbox.restorePoints(), credentials: credentials(m),
                             directory: m.sandbox.layout.sandboxDirectory.path, bootLog: m.sandbox.bootLogURL.path,
                             snapshotBytes: Int64(status.snapshotBytes > 0 ? status.snapshotBytes : fileSize(m.sandbox.layout.snapshot)),
                             hasRootDisk: m.sandbox.hasRootDisk, defaultSession: m.config.defaultSession.name,
                             agentPrompt: agentPromptReport(m), project: m.config.project)
    }

    func credentials(_ m: Managed) -> [CredentialRow] {
        guard let vault = m.sandbox.egress?.vault else { return [] }
        let file = accountStore.load()
        let account = resolvedAccount(m, file)
        let policy = effectivePolicy(m, file).rawValue
        let sightings = vault.foreignSightings
        let inUse: String? = {
            if case .record(let a) = account { return a.kind.binding.id }
            return vault.allBindings.first { vault.hasSecret($0.id) }?.id
        }()
        return vault.allBindings.enumerated().map { i, b in
            var row = CredentialRow(binding: b.id, hosts: b.hosts, set: vault.hasSecret(b.id), source: m.config.credentialSources[b.id])
            row.policy = policy
            if case .record(let a) = account, a.kind.binding.id == b.id {
                row.source = "account:\(a.name)"
                row.account = a.name
            } else if case .missing(let n) = account, b.id == CredentialBinding.claudeOAuth.id {
                row.account = n
            }
            if b.id == inUse || (inUse == nil && i == 0) {
                row.state = readOnly ? nil : credentialState(m, binding: b.id)
                row.expiresAt = vault.expiry(b.id)
                row.foreign = sightings.isEmpty ? nil : sightings
            }
            return row
        }
    }

    // MARK: restore points

    private func resolvePoint(_ m: Managed, _ ref: String?) throws -> RestorePoint {
        try Self.resolvePoint(ref, in: m.sandbox.restorePoints(), sandbox: m.name)
    }

    /// 594 W25: a point by its id, its name, or an unambiguous prefix of either — the host's rule, which
    /// the CLI applies too before it asks to confirm (W26).
    public static func resolvePoint(_ ref: String?, in points: [RestorePoint], sandbox: String) throws -> RestorePoint {
        guard let ref, !ref.isEmpty else { throw HostError(.invalid, "which restore point? (an id or a name — doz point ls \(sandbox))") }
        do {
            return try RestorePoint.resolve(ref, in: points)
        } catch .notFound {
            throw HostError(.notFound, "no restore point \(ref) in \(sandbox) (doz point ls \(sandbox))")
        } catch .ambiguous(let hits) {
            throw HostError(.invalid, "\(ref) could be \(hits.count) restore points of \(sandbox): "
                            + hits.map { "\($0.name) (\($0.id))" }.joined(separator: ", ") + " — type more of the name, or the id")
        }
    }

    private func point(_ r: HostRequest, emit: @escaping @Sendable (HostEvent) -> Void) async throws -> JSONValue {
        let m = try get(r.name)
        let sb = m.sandbox
        let t0 = ContinuousClock.now
        switch r.op {
        case .pointList:
            return try JSONValue(encoding: sb.restorePoints())
        case .pointTake:
            let name = r.pointName ?? "point-\(sb.restorePoints().filter { !$0.automatic }.count + 1)"
            if let problem = RestorePoint.nameProblem(name) { throw HostError(.invalid, problem) }
            let row = beginAction(m, "take restore point", phaseBefore: (await effectivePhase(m)).rawValue)
            do {
                let p = try await sb.takeRestorePoint(name: name, note: r.note ?? "")
                finishAction(m, row, t0, ok: true)
                return try JSONValue(encoding: p)
            } catch { finishAction(m, row, t0, ok: false, error: error); throw error }
        case .pointRevert:
            let p = try resolvePoint(m, r.point)
            if await sb.phase == .off, Sandbox.restorableState(for: sb.spec) != nil {
                // Hibernated by an earlier host: revert discards what it holds anyway.
                Sandbox.discardRestorableState(for: sb.spec)
            }
            let row = beginAction(m, "revert", phaseBefore: (await effectivePhase(m)).rawValue)
            do {
                try await sb.revert(to: p.id)
                finishAction(m, row, t0, ok: true, phaseAfter: "off")
                return try JSONValue(encoding: p)
            } catch { finishAction(m, row, t0, ok: false, error: error); throw error }
        case .pointFork:
            let p = try resolvePoint(m, r.point)
            guard let newName = r.newName else { throw HostError(.invalid, "fork needs a name for the new sandbox") }
            guard managed[newName] == nil else { throw HostError(.exists, "sandbox \(newName) already exists") }
            let spec = try sb.fork(p.id, as: newName)
            var cfg = m.config
            cfg.name = newName
            cfg.spec = spec
            cfg.createdAt = Date()
            cfg.credentialSources = [:]
            cfg.diedWithHostAt = nil
            try cfg.write(store.configFile(newName))
            let nm = try adopt(cfg)
            metrics?.record(run: metricsRun, action: "fork", sandbox: newName, image: cfg.image, startedAt: Date(), durationMs: ms(since: t0),
                            detail: ["from": m.name, "point": p.id])
            return try JSONValue(encoding: await info(nm, sessions: false))
        case .pointRm:
            let p = try resolvePoint(m, r.point)
            try sb.deleteRestorePoint(p.id)
            return try JSONValue(encoding: p)
        case .pointSaveImage:
            guard let image = r.image else { throw HostError(.invalid, "save-image needs --as IMAGE") }
            var pid: String?
            if r.point != nil { pid = try resolvePoint(m, r.point).id }
            let img = try sb.saveAsImage(pid, name: image, note: r.note ?? "")
            metrics?.record(run: metricsRun, action: "save as image", sandbox: m.name, image: m.config.image, startedAt: Date(),
                            durationMs: ms(since: t0), bytes: img.allocatedBytes)
            return try JSONValue(encoding: img)
        default:
            throw HostError(.invalid, "not a restore point operation")
        }
    }

    // MARK: templates and duplicates (593)

    /// The sandbox is stopped AND its record says so (a hibernation by an earlier host is `off` in
    /// memory but holds a snapshot: its disk is not a clean stop).
    private func stoppedOnDisk(_ m: Managed) async -> Bool {
        guard await m.sandbox.phase == .off else { return false }
        return PersistedSandbox.read(from: m.sandbox.layout.persistedState).map { $0.phase == .off } ?? false
    }

    /// A template — a custom image: the ROOT disk only, never the state disk (the agent's logins and
    /// history never go into a disk meant to be shared). From a restore point; from the current disk
    /// of a stopped sandbox; or, from a live one, through a temporary restore point (sync, pause, APFS
    /// clone, resume — crash-consistent, like any point taken while running), deleted afterwards.
    private func templateCreate(_ r: HostRequest) async throws -> CustomImage {
        let m = try get(r.name)
        let sb = m.sandbox
        guard let name = r.image else { throw HostError(.invalid, "a template needs a name (--as TEMPLATE)") }
        guard (1...40).contains(name.count), name.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }), name.first != "-" else {
            throw HostError(.invalid, "a template's name is 1–40 characters of [a-z0-9-]")
        }
        guard !DozerImages.builtIn.contains(name), ImageChoice.parse(name) == nil else { throw HostError(.invalid, "\(name) is a built-in image's name") }
        guard !store.layout("_").customImages().contains(where: { $0.name == name }) else {
            throw HostError(.exists, "a template named \(name) already exists (doz template ls)")
        }
        let t0 = ContinuousClock.now
        let row = beginAction(m, "save as template", phaseBefore: (await effectivePhase(m)).rawValue)
        do {
            let img: CustomImage
            if r.point != nil {
                img = try sb.saveAsImage(try resolvePoint(m, r.point).id, name: name, note: r.note ?? "")
            } else if await stoppedOnDisk(m) {
                img = try sb.saveAsImage(nil, name: name, note: r.note ?? "")
            } else {
                let tmp = try await sb.takeRestorePoint(name: "for template \(name)", note: "temporary — removed once the template is saved")
                defer { try? sb.deleteRestorePoint(tmp.id) }
                img = try sb.saveAsImage(tmp.id, name: name, note: r.note ?? "")
            }
            finishAction(m, row, t0, ok: true)
            metrics?.record(run: metricsRun, action: "save as template", sandbox: m.name, image: m.config.image, startedAt: Date(),
                            durationMs: ms(since: t0), bytes: img.allocatedBytes)
            note(m.name, "saved as template \(name) (root disk only — never the state disk)")
            return img
        } catch { finishAction(m, row, t0, ok: false, error: error); throw error }
    }

    /// A new sandbox from an existing one's disk — its current disk (a live one goes through a
    /// temporary restore point) or one of its restore points — with overrides. The root disk is an
    /// APFS clone; the state disk starts fresh unless `copyState`. Keys are not copied (as for fork).
    private func duplicate(_ r: HostRequest) async throws -> SandboxInfo {
        let m = try get(r.name)
        let sb = m.sandbox
        guard let newName = r.newName else { throw HostError(.invalid, "duplicate needs a name for the new sandbox") }
        guard managed[newName] == nil, !creating.contains(newName) else { throw HostError(.exists, "sandbox \(newName) already exists") }
        guard !FileManager.default.fileExists(atPath: store.layout(newName).sandboxDirectory.path) else {
            throw HostError(.exists, "\(store.layout(newName).sandboxDirectory.path) already exists (not made by doz — remove it or pick another name)")
        }
        let o = r.duplicate ?? DuplicateOptions()
        var spec = m.config.spec
        spec.name = newName
        if let c = o.cpus {
            guard (1...64).contains(c) else { throw HostError(.invalid, "--cpus is 1–64") }
            spec.cpus = c
        }
        if let mem = o.memoryMiB {
            guard (256...262_144).contains(mem) else { throw HostError(.invalid, "--memory is 256 MiB – 256 GiB") }
            spec.memoryMiB = mem
        }
        if o.isolated == true, o.workspace != nil { throw HostError(.invalid, "isolated or a new workspace — not both") }
        // 594: a new workspace that does not exist is made (and unmade if the duplicate fails).
        var prepared: Workspace.Prepared?
        var made = false
        defer { if !made, let p = prepared { Workspace.undo(p) } }
        if let ws = o.workspace {
            prepared = try Workspace.prepare(ws, store: store)
            let path = prepared!.path
            spec.shares = spec.shares.filter { $0.guestPath != DozerImages.workspaceGuestPath } + [Share(hostPath: path, guestPath: DozerImages.workspaceGuestPath)]
        } else if o.isolated == true {
            spec.shares = spec.shares.filter { $0.guestPath != DozerImages.workspaceGuestPath }
        }
        if let net = o.network {
            var mode = try DozerImages.networkMode(net)
            // 597: locked / agent / open are permissions (for the source's base); nothing given = copied.
            if case .proxied(let p) = mode, let preset = p.preset, let names = AgentPermissions.preset(preset, base: PermissionPolicy.base(of: m.config)) {
                mode = .proxied(.permissions(names + AgentPermissions.agentPermissions(m.config.imageChoice?.agent), preset: preset))
            }
            let wasNAT = spec.network == .nat
            spec.network = mode
            if mode != .nat || !wasNAT { spec.subnet = nil }
        }
        try spec.validate()
        var cfg = m.config
        cfg.name = newName
        cfg.spec = spec
        cfg.workspace = spec.shares.first { $0.guestPath == DozerImages.workspaceGuestPath }?.hostPath
        cfg.createdAt = Date()
        cfg.credentialSources = [:]
        cfg.diedWithHostAt = nil
        cfg.placeholderHashes = nil
        if spec.network.policy != nil {
            switch o.account {
            case nil: if cfg.account == nil, m.config.spec.network.policy == nil { cfg.account = "default" }
            case "default": cfg.account = "default"
            case "none": cfg.account = nil
            case let a?:
                guard accountStore.load().accounts.contains(where: { $0.name == a }) else { throw HostError(.notFound, "no account \(a) (doz account ls)") }
                cfg.account = a
            }
            // 594: the agent's credential prerequisite (a duplicate keeps the source's account unless told).
            let (def, kinds) = accountKinds()
            if let p = AgentCredentials.createProblem(image: spec.imageSpec?.name, account: o.account ?? cfg.account ?? "none", defaultAccount: def, kinds: kinds,
                                                      openaiDefault: openaiDefault(for: spec.imageSpec?.name), codexMac: AgentCredentials.provider(spec.imageSpec?.name) == "openai" && codexMacSignedIn()) {
                throw HostError(.invalid, p)
            }
        } else {
            if let a = o.account, a != "none", a != "default" {
                throw HostError(.invalid, "--account needs a proxied network (agent, open, …): the credential lives in the host's proxy")
            }
            cfg.account = nil
            cfg.credentialPolicy = nil
        }
        creating.insert(newName)
        defer { creating.remove(newName) }
        let t0 = ContinuousClock.now
        var from = try r.point.map { try resolvePoint(m, $0).id }
        var temporary: String?
        if from == nil, !(await stoppedOnDisk(m)) {
            let tmp = try await sb.takeRestorePoint(name: "for duplicate \(newName)", note: "temporary — removed once the duplicate is made")
            temporary = tmp.id
            from = tmp.id
        }
        defer { if let t = temporary { try? sb.deleteRestorePoint(t) } }
        try sb.duplicate(from: from, as: spec, copyState: o.copyState == true)
        do {
            try cfg.write(store.configFile(newName))
        } catch {
            try? FileManager.default.removeItem(at: store.layout(newName).sandboxDirectory)
            throw error
        }
        let nm = try adopt(cfg)
        metrics?.record(run: metricsRun, action: "duplicate", sandbox: newName, image: cfg.image, phaseAfter: "off", startedAt: Date(),
                        durationMs: ms(since: t0), detail: ["from": m.name, "point": r.point ?? "current disk", "state": o.copyState == true ? "copied" : "fresh"])
        made = true
        note(newName, "duplicated from \(m.name)\(r.point.map { " (restore point \($0))" } ?? "") — \(spec.cpus) CPUs, \(spec.memoryMiB) MiB, network \(cfg.networkName), state disk \(o.copyState == true ? "copied" : "fresh")"
             + (prepared?.created == true ? ", workspace \(prepared!.path) created" : cfg.workspace == nil ? ", isolated" : ""))
        var i = await info(nm, sessions: false)
        i.workspaceCreated = prepared?.created == true ? true : nil
        return i
    }

    // MARK: images

    /// The lab's prepared disk key (bash + ncurses on Alpine, 1 GiB).
    private func labSpec(_ name: String = "doz-image-bake") throws -> SandboxSpec {
        try DozerImages.spec(name: name, options: CreateOptions(image: "lab"), store: store).0
    }

    func images() throws -> [ImageRow] {
        var rows: [ImageRow] = []
        let lab = try labSpec()
        let golden = StoreLayout(spec: lab).golden(for: lab)
        let labBaked = FileManager.default.fileExists(atPath: golden.path)
        rows.append(ImageRow(name: "lab", kind: "builtin", baked: labBaked, key: labBaked ? StoreLayout.goldenKey(for: lab) : nil,
                             bakedAt: labBaked ? (try? FileManager.default.attributesOfItem(atPath: golden.path)[.modificationDate] as? Date) ?? nil : nil,
                             allocatedBytes: labBaked ? allocatedBytes(golden) : nil, note: "Alpine 3.20 + " + DozerImages.labPackages.joined(separator: ", "), fromSandbox: nil))
        let settings = DozerSettings.load()
        let versions = AgentVersions.all(store)
        rows[0].base = "alpine"
        rows[0].title = ImageChoice(base: "alpine", agent: .none).title
        // 596: every base × agent image the store has anything of (the two Node agent images always).
        for name in DozerImages.composedImagesInStore(store) {
            guard let choice = ImageChoice.parse(name) else { continue }
            let agent = choice.agent == .none ? nil : choice.agent.rawValue
            let proto = ImageSpec(name: name, base: "", steps: [], verify: [], user: "", home: "", persistDirs: [])
            // 594: the one a new sandbox gets — the newest prepared for this build, else (W28) the newest an
            // older doz made, else the newest bake.
            let prepared = AgentVersions.prepared(name, store: store, settings: settings).first
                ?? AgentVersions.usable(name, store: store, settings: settings).first
            let all = ImageBaker(storeRoot: store.root).all(proto)
            let baked = prepared.flatMap { p in all.first { $0.manifest.imageSpec == p } } ?? all.first
            let version = baked?.manifest.imageSpec.agent?.version
            var row = ImageRow(name: name, kind: "builtin", baked: baked != nil, key: baked.map { String($0.key.prefix(12)) },
                               bakedAt: baked?.manifest.bakedAt, allocatedBytes: baked?.manifest.allocatedBytes,
                               note: version.map { "\(agent ?? name) \($0)" } ?? (agent == nil ? choice.title : nil), fromSandbox: nil)
            row.base = choice.base
            row.title = choice.title
            if let agent {
                row.version = version
                row.versionSetting = AgentVersions.setting(agent, settings)
                row.latest = versions[agent]?.latest?.version
                row.latestCheckedAt = versions[agent]?.checkedAt
                if let b = AgentVersions.behind(name, store: store, settings: settings) {
                    row.available = b.target
                } else if prepared == nil, row.versionSetting != "latest" || versions[agent]?.latest != nil,
                          let t = (try? AgentVersions.spec(name, purpose: .prepare, store: store, settings: settings))??.agent?.version, t != version {
                    row.available = t
                }
                row.agent = agent
            }
            // 596: the base moved on since this image was made (a catalogue tag's new digest, a
            // Dockerfile changed or built again) — offered, never rebuilt by itself (W28).
            if let b = baked?.manifest.imageSpec.base {
                if let c = BaseCatalogue.base(choice.base), let d = BaseDigests.all(store)[c.id]?.digest, !b.hasSuffix(d) {
                    row.baseUpdate = "\(c.shortReference) has a newer digest (\(d.dropFirst(7).prefix(12))) — doz image bake \(name) prepares it"
                } else if choice.isDockerfile, let rec = Dockerfiles.record(choice.base, store) {
                    row.dockerfile = rec.dockerfile
                    if rec.changedSinceBuild { row.baseUpdate = "the Dockerfile changed — doz image bake \(name) rebuilds it" }
                }
            } else if choice.isDockerfile {
                row.dockerfile = Dockerfiles.record(choice.base, store)?.dockerfile
            }
            row.preparing = runningPreparation(name) != nil ? true : nil
            // 594 W28: named precisely — never rebuilt by itself.
            if let b = baked, !AgentVersions.isCurrentRecipe(b.manifest.imageSpec) {
                row.olderRecipe = AgentVersions.recipeChanges(b.manifest.imageSpec)
            }
            rows.append(row)
        }
        // 594: prepared for this build (the key it bakes now, the kernel, the guest init disk).
        for i in rows.indices {
            rows[i].current = preparedCheck(rows[i].name, store)
            rows[i].fillStanding()
        }
        for c in store.layout("_").customImages() {
            var row = ImageRow(name: c.name, kind: "custom", baked: true, key: c.key, bakedAt: c.createdAt, allocatedBytes: c.allocatedBytes,
                               note: c.note.isEmpty ? nil : c.note, fromSandbox: c.fromSandbox)
            row.agent = c.imageSpec?.name
            row.fillStanding()                 // W32: "up to date" — never a bare dash
            rows.append(row)
        }
        return rows
    }

    /// `image bake` (594: a preparation — the one running for this image is joined, not repeated).
    private func bake(_ raw: String?, emit: @escaping @Sendable (HostEvent) -> Void) async throws -> ImageRow {
        guard let raw else { throw HostError(.invalid, "which image? lab, claude-code, pi, or a base × agent image (doz base ls)") }
        let image = DozerImages.canonicalName(raw)
        guard DozerImages.builtIn.contains(image) || DozerImages.isPreparable(image, store: store) else {
            throw HostError(.invalid, "only a base × agent image bakes (lab, claude-code, pi, python-claude-code, … — doz base ls); a template is saved from a restore point")
        }
        // 594: latest asked of the registry first — the bake makes the version the settings name.
        if runningPreparation(image) == nil { await freshen(image, update: false) }
        try await follow(try preparation(for: image, requestedBy: "image bake"), emit: emit)
        guard let row = try images().first(where: { $0.name == image }) else { throw HostError(.failed, "the bake left no image") }
        return row
    }

    private func removeImage(_ image: String?) throws -> [ImageRow] {
        guard let image else { throw HostError(.invalid, "which image?") }
        let fm = FileManager.default
        let before = try images()
        if image == "lab" {
            let lab = try labSpec()
            try? fm.removeItem(at: StoreLayout(spec: lab).golden(for: lab))
        } else if let c = ImageChoice.parse(image), c.name == image {
            // 596: any base × agent image (its bakes; a sandbox made from one keeps its own disk).
            try? fm.removeItem(at: store.root.appendingPathComponent("images/\(image)"))
        } else {
            let customs = store.layout("_").customImages().filter { $0.name == image || $0.key == image }
            guard !customs.isEmpty else { throw HostError(.notFound, "no image \(image)") }
            for c in customs { try Sandbox.deleteCustomImage(c.key, storeRoot: store.root) }
        }
        return before.filter { $0.name == image || $0.key == image }
    }

    // MARK: network

    /// What a `net-policy` change makes of `current` (the live policy): the preset, removals, denies,
    /// allows, in that order — the policy that is kept (without the strict sign-in block, which is
    /// re-derived). Pure, so `doz ui`'s preview (590) shows exactly what the change will do.
    /// 599i: `agent` — the sandbox's agent (Codex keeps "Talk to OpenAI" through every edit).
    public static func editedPolicy(_ current: NetworkPolicy, _ r: HostRequest, base: String? = nil, agent: AgentKind? = nil) throws -> NetworkPolicy {
        var p = withoutSignInBlock(current)
        if let preset = r.preset {
            // 597 (P2): locked / agent (Standard) / open are sets of permissions (for the sandbox's base);
            // bake stays a preset of rules (image preparation).
            if let names = AgentPermissions.preset(preset == "standard" ? "agent" : preset, base: base) {
                // 599d: the user's GitHub login is beside the preset — choosing a preset keeps it as it was.
                let identity = (p.permissions ?? []).filter { $0 == AgentPermissions.gitHubAsYou || $0 == AgentPermissions.gitHubPush }
                p = .permissions(names + identity + AgentPermissions.agentPermissions(agent), preset: preset == "standard" ? "agent" : preset)
            } else {
                guard let np = NetworkPolicy.presets[preset] else { throw HostError(.invalid, "unknown preset \(preset) — locked, standard (agent), open or bake") }
                p = np
            }
        }
        // 597 (P6): by permission, or site:HOST.
        if !(r.grant ?? []).isEmpty || !(r.revoke ?? []).isEmpty {
            p = try PermissionPolicy.edited(p, grant: r.grant ?? [], revoke: r.revoke ?? [], base: base, agent: agent)
        }
        for h in r.removeHosts ?? [] {
            let host = h.lowercased()
            p.rules.removeAll { $0.host == host }
            p.preset = nil
        }
        for h in r.deny ?? [] {
            p.rules.removeAll { $0.host == h.lowercased() && $0.action == .allow && !$0.hasHTTPConditions }
            p.rules.insert(EgressRule(.deny, host: h, note: "doz net policy"), at: 0)
            p.preset = nil
        }
        for h in r.allow ?? [] { p.allow(host: h, note: "doz net policy") }
        return p
    }

    private func netPolicy(_ r: HostRequest) throws -> NetworkPolicy {
        let m = try get(r.name)
        guard let egress = m.sandbox.egress else {
            throw HostError(.invalid, "\(m.name) is not proxied (network \(m.config.networkName)) — it has no policy")
        }
        if isPolicyQuery(r) { return egress.policy }
        let p = try Self.editedPolicy(egress.policy, r, base: PermissionPolicy.base(of: m.config), agent: m.config.imageChoice?.agent)
        m.sandbox.setNetworkPolicy(Self.withSignInBlock(p, strict: egress.vault.foreignPolicy == .strict))
        m.config.spec.network = .proxied(p)
        try m.config.write(store.configFile(m.name))
        // 599d: "Use GitHub as you" / "Push to GitHub" take effect at once (turning it off revokes every placeholder).
        if AgentPermissions.gitHubMode(p.permissions) != egress.github?.mode { applyGitHub(m) }
        metrics?.record(run: metricsRun, action: "network policy", sandbox: m.name, image: m.config.image, startedAt: Date(), durationMs: 0,
                        detail: ["preset": p.preset ?? "custom", "rules": String(p.rules.count)])
        note(m.name, "network policy: \(p.preset ?? "custom") (\(p.rules.count) rules)")
        return p
    }

    // MARK: credentials

    private func setKey(_ r: HostRequest) async throws -> [CredentialRow] {
        let m = try get(r.name)
        guard m.sandbox.egress != nil else {
            throw HostError(.invalid, "\(m.name) is not proxied (network \(m.config.networkName)): a key would have to enter the sandbox — create it with a proxied network (agent, open, …)")
        }
        let binding: CredentialBinding
        switch r.binding ?? CredentialBinding.anthropic.id {
        case CredentialBinding.anthropic.id: binding = .anthropic
        case CredentialBinding.claudeOAuth.id: binding = .claudeOAuth
        case CredentialBinding.github.id: return try setGitHubKey(m, r)
        case let other: throw HostError(.invalid, "unknown credential \(other) — anthropic, claude-oauth or github")
        }
        // 588 (D10): `key set --claude-login` is `account use NAME mac`; `key rm --claude-login`
        // of an account-managed sandbox is `account use NAME none`.
        if binding.id == CredentialBinding.claudeOAuth.id, r.op == .keySet, r.source == ClaudeLogin.source {
            return try await useAccount(m, "mac")
        }
        if binding.id == CredentialBinding.claudeOAuth.id, r.op == .keyRm, m.config.account != nil {
            return try await useAccount(m, "none")
        }
        // One Anthropic credential at a time: Claude Code prefers ANTHROPIC_API_KEY over an OAuth
        // token when both are in its environment, so setting one forgets the other — and a key
        // given here replaces the sandbox's account.
        let other: CredentialBinding = binding.id == CredentialBinding.anthropic.id ? .claudeOAuth : .anthropic
        if r.op == .keySet {
            guard let s = r.secret?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
                throw HostError(.invalid, "an empty key")
            }
            m.config.account = nil
            detachWatcher(m)
            m.sandbox.setCredential(binding, secret: s, expiresAt: nil, environment: [:], notice: nil)
            m.config.credentialSources[binding.id] = r.source ?? "stdin"
            m.sandbox.setCredential(other, secret: nil, expiresAt: nil, environment: [:], notice: nil)
            m.config.credentialSources[other.id] = nil
            note(m.name, "\(binding.id) set (from \(r.source ?? "stdin"); memory only — sessions get a placeholder)")
        } else {
            m.sandbox.setCredential(binding, secret: nil, expiresAt: nil, environment: [:], notice: nil)
            m.config.credentialSources[binding.id] = nil
            note(m.name, "\(binding.id) removed")
        }
        try m.config.write(store.configFile(m.name))
        applyPolicy(m, accountStore.load())
        return credentials(m)
    }
}

func ms(since t0: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - t0
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

func fileSize(_ url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
}

/// Timestamped lines on the host's stdout (which is `<store>/host.log` for a detached host).
public enum HostLog {
    nonisolated(unsafe) public static var enabled = false
    private static let lock = NSLock()
    public static func line(_ s: String) {
        guard enabled else { return }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        lock.lock()
        FileHandle.standardOutput.write(Data("\(f.string(from: Date())) \(s)\n".utf8))
        lock.unlock()
    }
}
