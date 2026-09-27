import Foundation
import SnoozeContainerKit

/// A multi-subscriber fan-out of host events (`snooze events`).
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
    public nonisolated let store: SnoozeStore
    public nonisolated let readOnly: Bool
    public nonisolated let version: String
    private let metrics: MetricsStore?
    private let metricsRun: Int64
    nonisolated let hub = HostEventHub()

    /// Actor-confined: one per sandbox.
    final class Managed {
        let sandbox: Sandbox
        var config: SandboxConfig
        var eventTask: Task<Void, Never>?
        var networkTask: Task<Void, Never>?
        /// Keeps a `--claude-login` credential current with the Mac's own Claude Code login.
        var loginTask: Task<Void, Never>? { didSet { oldValue?.cancel() } }
        /// The metrics row of the action running now (library steps hang under it).
        var actionRow: Int64?
        var lastAction: (row: Int64, at: Date)?
        var networkCounted: Set<UUID> = []
        /// When a session last started a program (a Deep Sleep lets it settle first — 583).
        var lastSessionOpen: ContinuousClock.Instant?
        var sessionRows: [String: Int64] = [:]
        init(sandbox: Sandbox, config: SandboxConfig) {
            self.sandbox = sandbox
            self.config = config
        }
        var name: String { config.name }
    }

    private var managed: [String: Managed] = [:]
    /// Names being created right now (so two `create`s cannot race).
    private var creating: Set<String> = []

    public init(store: SnoozeStore, readOnly: Bool, version: String) {
        self.store = store
        self.readOnly = readOnly
        self.version = version
        if readOnly {
            metrics = nil
            metricsRun = 0
        } else {
            let m = try? MetricsStore(url: store.metrics)
            metrics = m
            metricsRun = m?.beginRun(.current(kind: "snooze host", version: version)) ?? 0
        }
    }

    // MARK: loading

    /// Every sandbox `snooze create` made in the store.
    public func load() {
        for name in store.sandboxNames() where managed[name] == nil {
            guard let cfg = SandboxConfig.read(store.configFile(name)) else { continue }
            do { try adopt(cfg) } catch { note(nil, "could not load \(name): \(error.localizedDescription)") }
        }
    }

    @discardableResult
    private func adopt(_ cfg: SandboxConfig) throws -> Managed {
        let sb = try Sandbox(spec: cfg.spec)
        let m = Managed(sandbox: sb, config: cfg)
        managed[cfg.name] = m
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
            if cfg.credentialSources[CredentialBinding.claudeOAuth.id] == ClaudeLogin.source {
                m.loginTask = ClaudeLogin.keepFresh(sb)
            }
        }
        return m
    }

    /// What the host does when it starts (not in read-only mode): a sandbox left ASLEEP (its VM was
    /// in a host that died) is restored and put back to sleep — the library's restore after a crash;
    /// one whose record says running died with that host: it is reported, and its disk (never
    /// unmounted) is marked for e2fsck at the next start. Deep-asleep sandboxes need nothing: `wake`
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
                    try await m.sandbox.wake()
                    try await m.sandbox.sleep()
                    finishAction(m, row, t0, ok: true)
                    note(m.name, "restored and asleep again, sessions where they were")
                } catch {
                    finishAction(m, row, t0, ok: false, error: error)
                    note(m.name, "could not restore: \(error.localizedDescription) — `snooze shutdown` discards the snapshot")
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
                note(m.name, "was running when the previous host died — its programs are gone; the next start checks its disk (e2fsck)")
                metrics?.record(run: metricsRun, action: "died with host", sandbox: m.name, image: m.config.image,
                                phaseBefore: "running", phaseAfter: "off", startedAt: Date(), durationMs: nil, ok: false)
            case .off, .deepAsleep:
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
        if let he = HostEvent(e, sandbox: name) {
            hub.yield(he)
            if he.kind != .progress { HostLog.line(he.line) }
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

    private func beginAction(_ m: Managed, _ action: String, phaseBefore: String) -> Int64? {
        guard let metrics else { return nil }
        let row = metrics.begin(run: metricsRun, action: action, sandbox: m.name, image: m.config.image, phaseBefore: phaseBefore)
        m.actionRow = row
        return row
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
        guard let m = managed[name] else { throw HostError(.notFound, "no sandbox \(name) (snooze ls)") }
        return m
    }

    /// The phase as the user sees it: in a new process a sandbox that is off but has a restorable
    /// snapshot is deep asleep (its VM, if it had one, is gone — `wake` restores it).
    func effectivePhase(_ m: Managed) async -> Phase {
        let p = await m.sandbox.phase
        if p == .off, let r = Sandbox.restorableState(for: m.sandbox.spec) { return r.phase == .asleep ? .deepAsleep : r.phase }
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
        return SandboxInfo(name: m.name, image: m.config.image, phase: phase.rawValue, busy: status.busy, cpus: m.sandbox.spec.cpus,
                           memoryMiB: mem, ramHeldMiB: phase.holdsRAM ? mem - min(mem, returned) : 0,
                           memoryReturnedMiB: phase.holdsRAM ? returned : 0,
                           diskBytes: allocatedBytes(m.sandbox.layout.sandboxDirectory), sessions: sessionCount,
                           network: egress.map { $0.policy.preset ?? "custom" } ?? m.config.networkName,
                           deniedConnections: egress?.log.deniedCount, workspace: m.config.workspace,
                           createdAt: m.config.createdAt, diedWithHost: m.config.diedWithHostAt == nil ? nil : true)
    }

    // MARK: requests

    /// Every request but the streaming ones (`attach`, `events`, `net-log --follow` — see HostServer).
    public func handle(_ r: HostRequest, emit: @escaping @Sendable (HostEvent) -> Void = { _ in }) async -> HostMessage {
        guard r.v <= HostProtocol.version else {
            return .failure(HostError(.version, "this host speaks protocol \(HostProtocol.version), the request is \(r.v) — restart it (snooze host stop)"))
        }
        if readOnly && !(r.op.isReadOnly || (r.op == .netPolicy && isPolicyQuery(r)) || r.op == .sessions || (r.op == .netLog && r.follow != true)) {
            return .failure(HostError(.unavailable, "\(r.op.rawValue) needs the host"))
        }
        do {
            return .success(try await perform(r, emit: emit))
        } catch {
            return .failure(HostError.from(error))
        }
    }

    func isPolicyQuery(_ r: HostRequest) -> Bool {
        r.preset == nil && (r.allow ?? []).isEmpty && (r.deny ?? []).isEmpty && (r.removeHosts ?? []).isEmpty
    }

    private func perform(_ r: HostRequest, emit: @escaping @Sendable (HostEvent) -> Void) async throws -> JSONValue {
        switch r.op {
        case .ping:
            return try JSONValue(encoding: await status())
        case .create:
            return try JSONValue(encoding: try await create(r))
        case .start, .wake, .pause, .resume, .sleep, .deepSleep, .shutdown, .reset, .rm:
            return try JSONValue(encoding: try await lifecycle(r.op, name: r.name, emit: emit))
        case .ls:
            var rows: [SandboxInfo] = []
            for m in managed.values.sorted(by: { $0.name < $1.name }) { rows.append(await info(m, sessions: true)) }
            return try JSONValue(encoding: rows)
        case .inspect:
            return try JSONValue(encoding: try await detail(try get(r.name)))
        case .sessions:
            let m = try get(r.name)
            guard await m.sandbox.phase == .running else {
                throw HostError(.invalidPhase, "\(m.name) is \(PhaseName.label(await effectivePhase(m))) — its sessions are listed while it runs")
            }
            return try JSONValue(encoding: try await m.sandbox.sessions().map(SessionRow.init))
        case .openSession:
            return try JSONValue(encoding: try await openSession(r))
        case .exec:
            return try JSONValue(encoding: try await exec(r))
        case .pointTake, .pointList, .pointRevert, .pointFork, .pointRm, .pointSaveImage:
            return try await point(r, emit: emit)
        case .imageList:
            return try JSONValue(encoding: images())
        case .imageBake:
            return try JSONValue(encoding: try await bake(r.image, emit: emit))
        case .imageRm:
            return try JSONValue(encoding: try removeImage(r.image))
        case .netPolicy:
            return try JSONValue(encoding: try netPolicy(r))
        case .netLog:
            let m = try get(r.name)
            guard let log = m.sandbox.egress?.log else { throw HostError(.invalid, "\(m.name) is not proxied (network \(m.config.networkName)) — it has no connection log") }
            return try JSONValue(encoding: log.records.filter { r.deniedOnly != true || $0.verdict == .denied })
        case .keySet, .keyRm:
            return try JSONValue(encoding: try setKey(r))
        case .keyList:
            return try JSONValue(encoding: credentials(try get(r.name)))
        case .attach, .events, .hostStop:
            throw HostError(.invalid, "\(r.op.rawValue) is handled by the server")
        }
    }

    public func status(connections: Int = 0, idleSeconds: Double? = nil, idleTimeoutMinutes: Double = 0,
                       startedAt: Date = Date()) async -> HostStatus {
        HostStatus(version: version, protocolVersion: HostProtocol.version, pid: getpid(), startedAt: startedAt, store: store.root.path,
                   idleTimeoutMinutes: idleTimeoutMinutes, liveSandboxes: await liveSandboxes(), connections: connections,
                   idleSeconds: idleSeconds)
    }

    // MARK: create

    private func create(_ r: HostRequest) async throws -> SandboxInfo {
        guard let name = r.name else { throw HostError(.invalid, "which sandbox? (a name is required)") }
        guard let o = r.create else { throw HostError(.invalid, "create needs --image") }
        guard managed[name] == nil, !creating.contains(name) else { throw HostError(.exists, "sandbox \(name) already exists") }
        guard !FileManager.default.fileExists(atPath: store.layout(name).sandboxDirectory.path) else {
            throw HostError(.exists, "\(store.layout(name).sandboxDirectory.path) already exists (not made by snooze — remove it or pick another name)")
        }
        creating.insert(name)
        defer { creating.remove(name) }
        let (spec, image) = try SnoozeImages.spec(name: name, options: o, store: store)
        let cfg = SandboxConfig(name: name, image: image, spec: spec, workspace: spec.shares.first?.hostPath)
        try cfg.write(store.configFile(name))
        let m = try adopt(cfg)
        metrics?.record(run: metricsRun, action: "create", sandbox: name, image: image, phaseAfter: "off", startedAt: Date(), durationMs: 0,
                        detail: ["network": cfg.networkName])
        note(name, "created (\(image), \(spec.cpus) CPUs, \(spec.memoryMiB) MiB, network \(cfg.networkName))")
        return await info(m, sessions: false)
    }

    // MARK: lifecycle

    /// Start-or-wake, and every other lifecycle operation, in the owner's vocabulary. An operation
    /// that finds the sandbox already where it leads does nothing (`changed: false`).
    private func lifecycle(_ op: HostOp, name: String?, emit: @escaping @Sendable (HostEvent) -> Void) async throws -> LifecycleResult {
        let m = try get(name)
        let sb = m.sandbox
        let before = await effectivePhase(m)
        let t0 = ContinuousClock.now
        func result(_ changed: Bool) async -> LifecycleResult {
            let after = await effectivePhase(m)
            return LifecycleResult(name: m.name, operation: op.rawValue, phaseBefore: before.rawValue, phase: after.rawValue,
                                   changed: changed, milliseconds: ms(since: t0),
                                   info: op == .rm ? nil : await info(m, sessions: false))
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
            case .asleep, .deepAsleep: action = ("wake", { try await sb.wake() })
            case .off, .failed: action = ("start", { try await sb.start() })
            case .booting: throw invalid()
            }
        case .wake, .resume:
            switch before {
            case .running: break
            case .paused: action = ("resume", { try await sb.resume() })
            case .asleep, .deepAsleep: action = ("wake", { try await sb.wake() })
            case .off, .failed: throw invalid(" — `snooze start \(m.name)` boots it")
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
        case .deepSleep:
            switch before {
            case .deepAsleep: break
            case .running, .paused, .asleep:
                // 583: a program a session started less than 3 s ago gets the rest of that time first.
                let wait = Self.settleDelay(since: m.lastSessionOpen.map { ContinuousClock.now - $0 })
                action = ("deep sleep", {
                    if wait > .zero { try? await Task.sleep(for: wait) }
                    try await sb.deepSleep()
                })
            default: throw invalid()
            }
        case .shutdown:
            let actorPhase = await sb.phase
            if actorPhase == .off {
                if Sandbox.restorableState(for: sb.spec) != nil {
                    // Deep asleep from an earlier host: wake it so it stops gracefully (a clean
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
        do {
            try await action.body()
        } catch {
            for _ in 0..<8 { await Task.yield() }
            forward.cancel()
            finishAction(m, row, t0, ok: false, error: error, phaseAfter: (await effectivePhase(m)).rawValue)
            throw error
        }
        for _ in 0..<8 { await Task.yield() }
        forward.cancel()
        finishAction(m, row, t0, ok: true, phaseAfter: (await effectivePhase(m)).rawValue)
        if [.start, .shutdown, .reset].contains(op), m.config.diedWithHostAt != nil {
            m.config.diedWithHostAt = nil
            try? m.config.write(store.configFile(m.name))
        }
        if op == .rm {
            m.eventTask?.cancel()
            m.networkTask?.cancel()
            managed[m.name] = nil
            try? FileManager.default.removeItem(at: store.layout(m.name).sandboxDirectory)
            note(m.name, "removed")
        }
        return await result(true)
    }

    /// How long a Deep Sleep waits for a program started `since` ago (the rest of 3 s).
    static func settleDelay(since: Duration?, settle: Duration = .seconds(3)) -> Duration {
        guard let since, since >= .zero, since < settle else { return .zero }
        return settle - since
    }

    /// Make sure `m` runs, waking a paused or sleeping sandbox when `wake` (never cold-booting one
    /// that is off — that is `start`'s job, and it asks for nothing).
    func ensureRunning(_ m: Managed, wake: Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(300)
        while true {
            let p = await effectivePhase(m)
            let busy = await m.sandbox.status.busy
            switch p {
            case .running where !busy: return
            case .paused where wake && !busy: try await m.sandbox.resume(); return
            case .asleep where wake && !busy, .deepAsleep where wake && !busy:
                let row = beginAction(m, "wake", phaseBefore: p.rawValue)
                let t0 = ContinuousClock.now
                do { try await m.sandbox.wake() } catch {
                    finishAction(m, row, t0, ok: false, error: error)
                    throw error
                }
                finishAction(m, row, t0, ok: true, phaseAfter: "running", detail: ["trigger": "use"])
                return
            case .off, .failed:
                throw HostError(.invalidPhase, "\(m.name) is \(PhaseName.label(p)) — `snooze start \(m.name)` boots it")
            case .paused, .asleep, .deepAsleep:
                if !wake && !busy { throw HostError(.invalidPhase, "\(m.name) is \(PhaseName.label(p))") }
            case .booting, .running:
                break
            }
            if ContinuousClock.now > deadline { throw HostError(.failed, "\(m.name) stayed busy for 5 minutes") }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// For the server's attach relay.
    func sandboxForAttach(_ name: String?, session: String?, wake: Bool) async throws -> (Sandbox, String) {
        let m = try get(name)
        if wake { try await ensureRunning(m, wake: true) }
        let session = session ?? m.config.defaultSession.name
        try GuestCommand.validateSessionName(session)
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
        guard let m = managed[name], let id = m.sessionRows[session] else { return }
        metrics?.sessionFirstAttach(id, ms: ms)
    }

    func sessionEnded(_ name: String, session: String, exitCode: Int32?) {
        guard let m = managed[name], let id = m.sessionRows[session] else { return }
        metrics?.sessionEnded(id, exitCode: exitCode)
    }

    /// Deep-sleep everything with a VM (quit = Deep Sleep, owner ruling 2026-09-25) — `host stop`
    /// and a SIGTERM. The next wake restores each with its sessions and pids.
    public func prepareAllForExit() async {
        var rows: [(Managed, Int64?)] = []
        for m in managed.values {
            let before = await m.sandbox.phase
            guard [.running, .paused, .asleep, .booting, .failed].contains(before) else { continue }
            rows.append((m, beginAction(m, "quit (deep sleep)", phaseBefore: before.rawValue)))
        }
        let t0 = ContinuousClock.now
        let sandboxes = rows.map { $0.0.sandbox }
        await withTaskGroup(of: Void.self) { group in
            for sb in sandboxes { group.addTask { await sb.prepareForExit() } }
        }
        for (m, row) in rows { finishAction(m, row, t0, ok: true, phaseAfter: (await effectivePhase(m)).rawValue) }
        for name in managed.keys { recordNetwork(name) }
    }

    // MARK: sessions

    /// The environment, working directory and user an `exec` runs with — the same as a session's.
    static func execContext(config: SandboxConfig, environment: [String: String], workdir: String?,
                            user: String?) -> (environment: [String: String], workdir: String, user: String?) {
        guard let r = config.spec.recipe else {
            return (environment, workdir ?? (config.workspace != nil ? SnoozeImages.workspaceGuestPath : "/root"), user)
        }
        let runAs = user ?? r.user
        var env = r.sessionEnvironment
        if runAs == r.user { env["HOME"] = r.home; env["USER"] = r.user }
        env.merge(environment) { _, caller in caller }
        return (env, workdir ?? r.workdir, runAs == "root" ? nil : runAs)
    }

    private func openSession(_ r: HostRequest) async throws -> SessionOpened {
        let m = try get(r.name)
        try await ensureRunning(m, wake: r.wake ?? true)
        let list = try await m.sandbox.sessions()
        let live = Set(list.filter { !$0.isEnded }.map(\.name))
        let all = Set(list.map(\.name))
        let argv: [String]
        let session: String
        if let s = r.session {
            try GuestCommand.validateSessionName(s)
            if live.contains(s) {
                if r.argv != nil { throw HostError(.exists, "session \(s) is already running in \(m.name) — attach to it, or pick another name") }
                return SessionOpened(name: m.name, session: s, created: false)
            }
            session = s
            argv = r.argv ?? (s == m.config.defaultSession.name ? m.config.defaultSession.argv : ["bash", "-l"])
        } else if let a = r.argv, !a.isEmpty {
            let base = SnoozeImages.sessionName(for: a)
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
        let size = TermSize(cols: r.cols ?? 120, rows: r.rows ?? 36)
        let workdir: String? = m.config.spec.recipe == nil && m.config.workspace != nil ? SnoozeImages.workspaceGuestPath : nil
        let t0 = ContinuousClock.now
        let started = Date()
        do {
            try await m.sandbox.openSession(session, argv: argv, environment: r.environment ?? [:], workingDirectory: r.workdir ?? workdir,
                                            user: r.user, size: size)
        } catch {
            metrics?.record(run: metricsRun, action: "session open", sandbox: m.name, image: m.config.image, startedAt: started,
                            durationMs: ms(since: t0), ok: false, error: error.localizedDescription, detail: ["session": session])
            throw error
        }
        m.lastSessionOpen = ContinuousClock.now
        let openMs = ms(since: t0)
        metrics?.record(run: metricsRun, action: "session open", sandbox: m.name, image: m.config.image, phaseBefore: "running",
                        phaseAfter: "running", startedAt: started, durationMs: openMs, detail: ["session": session])
        if let id = metrics?.sessionOpened(run: metricsRun, sandbox: m.name, image: m.config.image, session: session,
                                           command: argv.joined(separator: " "), openedAt: started, openMs: openMs) {
            m.sessionRows[session] = id
        }
        return SessionOpened(name: m.name, session: session, created: true)
    }

    private func exec(_ r: HostRequest) async throws -> ExecOutput {
        let m = try get(r.name)
        guard let argv = r.argv, !argv.isEmpty else { throw HostError(.invalid, "exec needs a command (snooze exec NAME -- CMD…)") }
        try await ensureRunning(m, wake: r.wake ?? true)
        let ctx = Self.execContext(config: m.config, environment: r.environment ?? [:], workdir: r.workdir, user: r.user)
        let t0 = ContinuousClock.now
        let res = try await m.sandbox.exec(argv, environment: ctx.environment, workingDirectory: ctx.workdir, user: ctx.user,
                                           timeoutSeconds: r.timeoutSeconds ?? 120)
        return ExecOutput(exitCode: res.exitCode, stdout: res.stdout, stderr: res.stderr, milliseconds: ms(since: t0))
    }

    // MARK: inspect

    private func detail(_ m: Managed) async throws -> SandboxDetail {
        let i = await info(m, sessions: false)
        var sessions: [SessionRow]?
        if i.phase == Phase.running.rawValue, !i.busy, let list = try? await m.sandbox.sessions() { sessions = list.map(SessionRow.init) }
        let status = await m.sandbox.status
        return SandboxDetail(info: i, spec: m.sandbox.spec, policy: m.sandbox.egress?.policy, sessions: sessions,
                             restorePoints: m.sandbox.restorePoints(), credentials: credentials(m),
                             directory: m.sandbox.layout.sandboxDirectory.path, bootLog: m.sandbox.bootLogURL.path,
                             snapshotBytes: Int64(status.snapshotBytes > 0 ? status.snapshotBytes : fileSize(m.sandbox.layout.snapshot)),
                             hasRootDisk: m.sandbox.hasRootDisk, defaultSession: m.config.defaultSession.name)
    }

    private func credentials(_ m: Managed) -> [CredentialRow] {
        guard let vault = m.sandbox.egress?.vault else { return [] }
        return vault.allBindings.map {
            CredentialRow(binding: $0.id, hosts: $0.hosts, set: vault.hasSecret($0.id), source: m.config.credentialSources[$0.id])
        }
    }

    // MARK: restore points

    private func resolvePoint(_ m: Managed, _ ref: String?) throws -> RestorePoint {
        guard let ref, !ref.isEmpty else { throw HostError(.invalid, "which restore point? (an id or a name — snooze point ls \(m.name))") }
        let all = m.sandbox.restorePoints()
        if let p = all.first(where: { $0.id == ref }) { return p }
        if let p = all.last(where: { $0.name == ref }) { return p }
        throw HostError(.notFound, "no restore point \(ref) in \(m.name)")
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
            let row = beginAction(m, "take restore point", phaseBefore: (await effectivePhase(m)).rawValue)
            do {
                let p = try await sb.takeRestorePoint(name: name, note: r.note ?? "")
                finishAction(m, row, t0, ok: true)
                return try JSONValue(encoding: p)
            } catch { finishAction(m, row, t0, ok: false, error: error); throw error }
        case .pointRevert:
            let p = try resolvePoint(m, r.point)
            if await sb.phase == .off, Sandbox.restorableState(for: sb.spec) != nil {
                // Deep asleep from an earlier host: revert discards what it holds anyway.
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

    // MARK: images

    /// The lab's prepared disk key (bash + ncurses on Alpine, 1 GiB).
    private func labSpec(_ name: String = "snooze-image-bake") throws -> SandboxSpec {
        try SnoozeImages.spec(name: name, options: CreateOptions(image: "lab"), store: store).0
    }

    private func images() throws -> [ImageRow] {
        var rows: [ImageRow] = []
        let lab = try labSpec()
        let golden = StoreLayout(spec: lab).golden(for: lab)
        let labBaked = FileManager.default.fileExists(atPath: golden.path)
        rows.append(ImageRow(name: "lab", kind: "builtin", baked: labBaked, key: labBaked ? StoreLayout.goldenKey(for: lab) : nil,
                             bakedAt: labBaked ? (try? FileManager.default.attributesOfItem(atPath: golden.path)[.modificationDate] as? Date) ?? nil : nil,
                             allocatedBytes: labBaked ? allocatedBytes(golden) : nil, note: "Alpine 3.20 + bash, ncurses", fromSandbox: nil))
        for name in ["claude-code", "pi"] {
            let recipe = SnoozeImages.recipe(name)!
            let baked = ImageBaker(storeRoot: store.root).all(recipe).first
            rows.append(ImageRow(name: name, kind: "builtin", baked: baked != nil, key: baked.map { String($0.key.prefix(12)) },
                                 bakedAt: baked?.manifest.bakedAt, allocatedBytes: baked?.manifest.allocatedBytes,
                                 note: recipe.verify.first?.expect.map { "\(name) \($0)" }, fromSandbox: nil))
        }
        for c in store.layout("_").customImages() {
            rows.append(ImageRow(name: c.name, kind: "custom", baked: true, key: c.key, bakedAt: c.createdAt, allocatedBytes: c.allocatedBytes,
                                 note: c.note.isEmpty ? nil : c.note, fromSandbox: c.fromSandbox))
        }
        return rows
    }

    private func bake(_ image: String?, emit: @escaping @Sendable (HostEvent) -> Void) async throws -> ImageRow {
        guard let image else { throw HostError(.invalid, "which image? lab, claude-code or pi") }
        let t0 = ContinuousClock.now
        let started = Date()
        let tmpName = "snooze-image-bake"
        if image == "lab" {
            // The lab's prepared disk is made by its first boot: boot a throwaway sandbox, then remove it.
            let sb = try Sandbox(spec: try labSpec(tmpName))
            let stream = sb.events()
            let forward = Task { for await e in stream { if let he = HostEvent(e, sandbox: image) { emit(he) } } }
            defer { forward.cancel() }
            do {
                try await sb.start()
                try await sb.delete()
            } catch {
                try? await sb.delete()
                throw error
            }
        } else if let recipe = SnoozeImages.recipe(image) {
            var spec = try SnoozeImages.spec(name: tmpName, options: CreateOptions(image: image), store: store).0
            spec.recipe = recipe
            let sb = try Sandbox(spec: spec)
            let stream = sb.events()
            let forward = Task { for await e in stream { if let he = HostEvent(e, sandbox: image) { emit(he) } } }
            defer { forward.cancel() }
            _ = try await sb.ensureImage()
        } else {
            throw HostError(.invalid, "only the built-in images bake (lab, claude-code, pi); a custom image is saved from a restore point")
        }
        metrics?.record(run: metricsRun, action: "bake", sandbox: nil, image: image, startedAt: started, durationMs: ms(since: t0))
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
        } else if let recipe = SnoozeImages.recipe(image) {
            try? fm.removeItem(at: ImageBaker(storeRoot: store.root).imageDirectory(recipe))
        } else {
            let customs = store.layout("_").customImages().filter { $0.name == image || $0.key == image }
            guard !customs.isEmpty else { throw HostError(.notFound, "no image \(image)") }
            for c in customs { try Sandbox.deleteCustomImage(c.key, storeRoot: store.root) }
        }
        return before.filter { $0.name == image || $0.key == image }
    }

    // MARK: network

    private func netPolicy(_ r: HostRequest) throws -> NetworkPolicy {
        let m = try get(r.name)
        guard let egress = m.sandbox.egress else {
            throw HostError(.invalid, "\(m.name) is not proxied (network \(m.config.networkName)) — it has no policy")
        }
        if isPolicyQuery(r) { return egress.policy }
        var p = egress.policy
        if let preset = r.preset {
            guard let np = NetworkPolicy.presets[preset] else { throw HostError(.invalid, "unknown preset \(preset) — locked, bake, agent or open") }
            p = np
        }
        for h in r.removeHosts ?? [] {
            let host = h.lowercased()
            p.rules.removeAll { $0.host == host }
            p.preset = nil
        }
        for h in r.deny ?? [] {
            p.rules.removeAll { $0.host == h.lowercased() && $0.action == .allow && !$0.hasHTTPConditions }
            p.rules.insert(EgressRule(.deny, host: h, note: "snooze net policy"), at: 0)
            p.preset = nil
        }
        for h in r.allow ?? [] { p.allow(host: h, note: "snooze net policy") }
        m.sandbox.setNetworkPolicy(p)
        m.config.spec.network = .proxied(p)
        try m.config.write(store.configFile(m.name))
        metrics?.record(run: metricsRun, action: "network policy", sandbox: m.name, image: m.config.image, startedAt: Date(), durationMs: 0,
                        detail: ["preset": p.preset ?? "custom", "rules": String(p.rules.count)])
        note(m.name, "network policy: \(p.preset ?? "custom") (\(p.rules.count) rules)")
        return p
    }

    // MARK: credentials

    private func setKey(_ r: HostRequest) throws -> [CredentialRow] {
        let m = try get(r.name)
        guard m.sandbox.egress != nil else {
            throw HostError(.invalid, "\(m.name) is not proxied (network \(m.config.networkName)): a key would have to enter the sandbox — create it with a proxied network (agent, open, …)")
        }
        let binding: CredentialBinding
        switch r.binding ?? CredentialBinding.anthropic.id {
        case CredentialBinding.anthropic.id: binding = .anthropic
        case CredentialBinding.claudeOAuth.id: binding = .claudeOAuth
        case let other: throw HostError(.invalid, "unknown credential \(other) — anthropic or claude-oauth")
        }
        // One Anthropic credential at a time: Claude Code prefers ANTHROPIC_API_KEY over an OAuth
        // token when both are in its environment, so setting one forgets the other.
        let other: CredentialBinding = binding.id == CredentialBinding.anthropic.id ? .claudeOAuth : .anthropic
        if r.op == .keySet {
            let secret: String
            if binding.id == CredentialBinding.claudeOAuth.id && r.source == ClaudeLogin.source {
                guard let t = ClaudeLogin.read() else {
                    throw HostError(.notFound, "no Claude Code login on this Mac (keychain item \"\(ClaudeLogin.service)\") — run claude and /login first")
                }
                secret = t.accessToken
                m.loginTask = ClaudeLogin.keepFresh(m.sandbox)
            } else {
                guard let s = r.secret?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
                    throw HostError(.invalid, "an empty key")
                }
                secret = s
                if binding.id == CredentialBinding.claudeOAuth.id { m.loginTask = nil }
            }
            m.sandbox.setCredential(binding, secret: secret)
            m.config.credentialSources[binding.id] = r.source ?? "stdin"
            m.sandbox.setCredential(other, secret: nil)
            m.config.credentialSources[other.id] = nil
            if other.id == CredentialBinding.claudeOAuth.id { m.loginTask = nil }
            note(m.name, "\(binding.id) set (from \(r.source ?? "stdin"); memory only — sessions get a placeholder)")
        } else {
            m.sandbox.setCredential(binding, secret: nil)
            m.config.credentialSources[binding.id] = nil
            if binding.id == CredentialBinding.claudeOAuth.id { m.loginTask = nil }
            note(m.name, "\(binding.id) removed")
        }
        try m.config.write(store.configFile(m.name))
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

/// Reads a generic password with `/usr/bin/security` (the item the user stored; never written by
/// snooze). A timeout guards against a keychain prompt nobody answers.
/// The Mac's own Claude Code login (`snooze key set NAME --claude-login`). Claude Code keeps its
/// subscription OAuth credentials in the login keychain; the host reads only the ACCESS token
/// (short-lived, ~8 h) through `/usr/bin/security` — the tool Claude Code writes the item with, so
/// no keychain dialog — and never the refresh token: a sandbox that refreshed would rotate it
/// and sign the Mac out (Deckosaurus' 488 finding). The Mac's Claude Code refreshes the item
/// itself; `keepFresh` re-reads it so the vault follows.
public enum ClaudeLogin {
    public static let service = "Claude Code-credentials"
    /// The `CredentialRow.source` / `SandboxConfig.credentialSources` value.
    public static let source = "claude-login"

    public struct Token: Sendable {
        public var accessToken: String
        public var expiresAt: Date?
    }

    public static func read() -> Token? {
        guard let raw = Keychain.read(service: service) else { return nil }
        let data = Data(raw.utf8)
        let hex: Data? = {                                 // some versions store it hex-encoded
            var d = Data(); var it = raw.makeIterator()
            while let a = it.next(), let b = it.next() { guard let v = UInt8(String([a, b]), radix: 16) else { return nil }; d.append(v) }
            return d
        }()
        for candidate in [data, hex].compactMap({ $0 }) {
            guard let obj = try? JSONSerialization.jsonObject(with: candidate) as? [String: Any],
                  let o = obj["claudeAiOauth"] as? [String: Any],
                  let t = o["accessToken"] as? String, !t.isEmpty else { continue }
            return Token(accessToken: t, expiresAt: (o["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) })
        }
        return nil
    }

    /// Re-read the Mac's login every 2 minutes and hand a changed access token to the sandbox's vault.
    static func keepFresh(_ sandbox: Sandbox) -> Task<Void, Never> {
        Task.detached { [weak sandbox] in
            var last: String?
            while !Task.isCancelled {
                if let t = read(), t.accessToken != last, let sandbox {
                    sandbox.setCredential(.claudeOAuth, secret: t.accessToken)
                    last = t.accessToken
                }
                if sandbox == nil { return }
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }
}

public enum Keychain {
    public static func read(service: String, timeout: TimeInterval = 5) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
