import Darwin
import Foundation
import DozerKit
import DozerHost

/// Everything the UI can show and do, as typed calls. The server knows nothing else: it has no path
/// to a VM, a keychain or a file except through these calls (tests substitute a fake).
public protocol DozerWebData: Sendable {
    var storePath: String { get }
    func overview() async throws -> WebOverview
    func sandbox(_ name: String) async throws -> WebSandboxDetail
    func sessions(_ name: String) async throws -> [WebSessionRow]
    func network(_ name: String) async throws -> WebNetwork
    func images() async throws -> [WebImage]
    /// 593: the lineage (the host's `image-tree`; in-process from the store when no host runs).
    func imageTree() async throws -> WebImageTree
    func accounts() async throws -> WebAccounts
    func metrics(_ q: WebMetricsQuery) async throws -> WebMetrics
    /// Every row of the filter, as CSV (cells that a spreadsheet would run as a formula are defused).
    func metricsCSV(_ q: WebMetricsQuery) async throws -> Data
    func doctor() async throws -> [WebDoctorCheck]
    /// The host's event stream, while a host runs (nil when none does). The stream ends when the
    /// host goes away or the task consuming it is cancelled.
    func hostEvents() -> AsyncStream<HostEvent>?
    /// Phase 2: one host operation (a `WebAction`'s request), starting the host when needed, its
    /// progress lines passed to `onEvent`. Returns the host's result.
    func perform(_ r: HostRequest, onEvent: @escaping @Sendable (HostEvent) -> Void) async throws -> JSONValue
    /// What a policy edit would make of the sandbox's policy (nothing changes).
    func policyPreview(_ name: String, _ edit: WebPolicyEdit) async throws -> WebPolicyPreview
    /// Open Terminal.app attached to the sandbox's session. Returns a line for the page.
    func openTerminal(_ name: String, session: String?) async throws -> String
    /// 591: attach to a session (nil: the image's own) for a browser terminal — the host's `attach`
    /// with `wake: false`, exactly as the CLI sends it. `size` 0×0 keeps the session's size (watch).
    func attachTerminal(_ name: String, session: String?, size: TermSize) async throws -> any WebTerminalAttachment
    /// 591: the boot console as it is written (the host's `console --follow`); nil when no host runs.
    func bootConsole(_ name: String) -> AsyncStream<String>?
    /// 593 §9: a session's last saved screen (`session-screen`; in-process when no host runs).
    func sessionScreen(_ name: String, session: String) async throws -> WebSavedScreen
    /// 593 §9: the sandbox's terminal layout (nil: none yet), and its change (`terminal-layout-set` —
    /// through the host when one runs, else in-process: it never starts one).
    func terminalLayout(_ name: String) async throws -> WebTerminalLayout?
    func setTerminalLayout(_ name: String, _ layout: TerminalLayout) async throws -> WebTerminalLayout?
    /// 593: the kept boots (the host's `boot-log`; in-process when no host runs), and one rendered.
    func bootLogs(_ name: String) async throws -> WebBootList
    func bootLog(_ name: String, number: Int) async throws -> WebBootLog
    /// 594: the onboarding wizard's facts — the checks, the account step, the images, the preparations,
    /// the store's onboarding record (the settings file's part is the server's).
    func onboarding() async throws -> WebOnboarding
    /// 594: the image preparations in the host (running, then recent); empty with no host.
    func preparations() async throws -> [WebPreparation]
    /// 594 (owner ruling): add an account from a key or a token — the host's `account-add`, exactly
    /// the request `doz account add` sends (`HostRequest.accountAdd`), with no progress callback (so
    /// nothing of it reaches an operation or an event). Returns the accounts (never a secret).
    func addAccount(_ a: WebAccountAdd) async throws -> WebAccounts
    /// 594 (owner ruling): a sandbox's own Anthropic key — the host's `key-set`, exactly the request
    /// `doz key set NAME --anthropic` sends (`HostRequest.keySet`, source `browser`), no progress
    /// callback. Returns the sandbox's keys (never a secret).
    func setKey(_ k: WebKeySet) async throws -> [WebCredential]
    /// 595: the Resources account (the host's `resources`; in-process when no host runs), and what a
    /// deletion would do (a dry run — changes nothing).
    func resources() async throws -> WebResources
    func resourcesPreview(_ p: WebResourcePreview) async throws -> ResourcePlan
    /// 594 W18: the host's state without starting one (read before each overview); nil when the
    /// source cannot tell (the overview's `host` is then all there is).
    func hostProbe() -> WebHostProbe?
    /// 594 W18: a host answers its socket now (a terminal's REattach waits for one rather than start
    /// one: an open page must never undo a `doz host stop`).
    func hostAnswers() -> Bool
    /// 594 W20: stop an OLDER host and start this UI's build (refused otherwise).
    func restartHost(onEvent: @escaping @Sendable (HostEvent) -> Void) async throws -> JSONValue
    /// 596: the recommended bases and Apple's container tool (the host's `bases` and `builder-status`,
    /// in-process when no host runs — looking never starts anything).
    func bases() async throws -> WebBases
    /// 599e: the Access report — from the record (never starting a host), or after a live check of
    /// `items` (the host's `access` with `check`), of `choices` when given (else the settings').
    func access(check: WebAccessCheck?) async throws -> AccessReport
    /// 599e: set or remove the default GitHub key (the host's `access-github-key`); never echoed.
    func setAccessGitHubKey(_ k: WebAccessGitHubKey) async throws -> AccessReport
    /// 599h: a sandbox's tools layer — the plan and the last apply (the host's `tools`; a host must run).
    func tools(_ name: String) async throws -> ToolsLayerReport
}

extension DozerWebData {
    public func tools(_ name: String) async throws -> ToolsLayerReport { throw HostError(.notImplemented, "tools") }
    public func access(check: WebAccessCheck?) async throws -> AccessReport { throw HostError(.notImplemented, "access") }
    public func setAccessGitHubKey(_ k: WebAccessGitHubKey) async throws -> AccessReport { throw HostError(.notImplemented, "access") }
    public func bases() async throws -> WebBases { throw HostError(.notImplemented, "bases") }
    public func restartHost(onEvent: @escaping @Sendable (HostEvent) -> Void) async throws -> JSONValue {
        throw HostError(.notImplemented, "host restart")
    }
    public func hostProbe() -> WebHostProbe? { nil }
    public func hostAnswers() -> Bool { true }
    public func onboarding() async throws -> WebOnboarding { throw HostError(.notImplemented, "onboarding") }
    public func preparations() async throws -> [WebPreparation] { [] }
    public func addAccount(_ a: WebAccountAdd) async throws -> WebAccounts { throw HostError(.notImplemented, "accounts") }
    public func setKey(_ k: WebKeySet) async throws -> [WebCredential] { throw HostError(.notImplemented, "keys") }
    public func resources() async throws -> WebResources { throw HostError(.notImplemented, "resources") }
    public func resourcesPreview(_ p: WebResourcePreview) async throws -> ResourcePlan { throw HostError(.notImplemented, "resources") }
}

/// `GET /api/v1/metrics[.csv]?image=…&days=…&steps=0|1`.
public struct WebMetricsQuery: Equatable, Sendable {
    public var image: String?
    public var days: Double?
    public var steps: Bool

    public init(image: String? = nil, days: Double? = nil, steps: Bool = false) {
        self.image = image
        self.days = days
        self.steps = steps
    }

    public var filter: MetricsFilter {
        MetricsFilter(image: image, since: days.map { Date().addingTimeInterval(-$0 * 86_400) }, includeSteps: steps)
    }

    /// From a query string: only these three keys, each by its rule; anything else is not a route.
    public static func parse(_ query: String?) -> WebMetricsQuery? {
        var q = WebMetricsQuery()
        guard let query, !query.isEmpty else { return q }
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard kv.count == 2 else { return nil }
            switch kv[0] {
            case "image":
                if kv[1].isEmpty { continue }
                // `custom:NAME` arrives as custom%3ANAME (the only escape accepted).
                let v = kv[1].replacingOccurrences(of: "%3A", with: ":").replacingOccurrences(of: "%3a", with: ":")
                guard v.range(of: "^(custom:)?[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil else { return nil }
                q.image = v
            case "days":
                if kv[1].isEmpty { continue }
                guard let d = Double(kv[1]), d > 0, d <= 3650 else { return nil }
                q.days = d
            case "steps":
                guard kv[1] == "0" || kv[1] == "1" else { return nil }
                q.steps = kv[1] == "1"
            default:
                return nil
            }
        }
        return q
    }
}

/// The real source: a CLIENT of the store's host (`<store>/host.sock`, the same JSON-lines protocol
/// as the CLI) — the UI never owns a VM. With no host running it answers from the store in this
/// process (`HostCore(readOnly: true)`), exactly as the CLI's read-only commands do: looking never
/// starts the host, except when a crashed host left a sandbox that only a host can recover (the
/// CLI's rule too).
public final class HostWebData: DozerWebData, @unchecked Sendable {
    public let store: DozerStore
    public let version: String
    let doctorChecks: @Sendable () -> [WebDoctorCheck]
    /// Records beyond this are left out of the network view (the log lives in the host's memory).
    let logLimit = 500
    private let lock = NSLock()
    private var doctorCache: (Date, [WebDoctorCheck])?

    /// The `doz` executable Terminal runs (this process's own, symlinks resolved).
    let executable: String
    let terminalLauncher: @Sendable (String) throws -> Void

    /// 594: whether Claude Code is signed in on this Mac (the onboarding's account step) — read-only.
    let macLogin: @Sendable () -> Bool
    private var macLoginCache: (Date, Bool)?

    public init(store: DozerStore, version: String, executable: String = HostLauncher.executablePath,
                terminal: @escaping @Sendable (String) throws -> Void = TerminalHandoff.openInTerminalApp,
                macLogin: @escaping @Sendable () -> Bool = { false },
                doctor: @escaping @Sendable () -> [WebDoctorCheck]) {
        self.store = store
        self.version = version
        self.executable = executable
        terminalLauncher = terminal
        self.macLogin = macLogin
        doctorChecks = doctor
    }

    // MARK: 594 — onboarding

    public func onboarding() async throws -> WebOnboarding {
        let status = try await query(HostRequest(.prepareStatus)).0.decode(PrepareStatus.self)
        let doctor = try await self.doctor()
        let prepared = Set(status.images.filter { $0.current ?? false }.map(\.name))
        let checks = Onboarding.checks(doctor: doctor.map { (check: $0.check, status: $0.status, detail: $0.detail) }, store: store,
                                       chosen: ["claude-code"], prepared: prepared)
        let signedIn: Bool
        if let (t, v) = lock.withLock({ macLoginCache }), Date().timeIntervalSince(t) < 30 {
            signedIn = v
        } else {
            let probe = macLogin
            signedIn = (try? await blocking { probe() }) ?? false
            lock.withLock { macLoginCache = (Date(), signedIn) }
        }
        let file = AccountStore(store: store, settings: .load()).load()
        // 594 W6: what each agent image WILL install (the hourly cache; "latest" when never asked).
        let settings = DozerSettings.load()
        let versions = Dictionary(uniqueKeysWithValues: ["claude-code", "pi", "codex"].compactMap { i in
            Onboarding.agentVersionText(i, store: store, settings: settings).map { (i, $0) } })
        return WebOnboarding(status: status, checks: checks, freeBytes: Onboarding.volume(of: store)?.free, macSignedIn: signedIn,
                             defaultAccount: file.defaultAccount, versions: versions)
    }

    public func addAccount(_ a: WebAccountAdd) async throws -> WebAccounts {
        let store = self.store
        let r = HostRequest.accountAdd(name: a.name, kind: a.kind, plan: a.plan, secret: a.secret)
        let m = try await blocking { try HostClient.request(r, store: store, autostart: true) }
        guard m.ok == true else { throw m.error ?? HostError(.failed, "the host gave no reason") }
        return try await accounts()
    }

    public func setKey(_ k: WebKeySet) async throws -> [WebCredential] {
        let store = self.store
        let r = HostRequest.keySet(name: k.sandbox, secret: k.secret, source: "browser")
        let m = try await blocking { try HostClient.request(r, store: store, autostart: true) }
        guard m.ok == true else { throw m.error ?? HostError(.failed, "the host gave no reason") }
        return try (m.result ?? .null).decode([CredentialRow].self).map(WebCredential.init)
    }

    public func access(check: WebAccessCheck?) async throws -> AccessReport {
        guard let check else { return try await query(HostRequest(.access)).0.decode(AccessReport.self) }
        let store = self.store
        var r = HostRequest(.access)
        r.check = true
        r.items = check.items
        r.accessChoices = check.choices?.dictionary
        let request = r
        let m = try await blocking { try HostClient.request(request, store: store, autostart: true) }
        guard m.ok == true else { throw m.error ?? HostError(.failed, "the host gave no reason") }
        return try (m.result ?? .null).decode(AccessReport.self)
    }

    public func tools(_ name: String) async throws -> ToolsLayerReport {
        let store = self.store
        guard store.hostIsRunning() else { throw HostError(.unavailable, "the host is not running — a sandbox's tools are set up when it starts") }
        let m = try await blocking { try HostClient.request(HostRequest(.tools, name: name), store: store, autostart: false) }
        guard m.ok == true else { throw m.error ?? HostError(.failed, "the host gave no reason") }
        return try (m.result ?? .null).decode(ToolsLayerReport.self)
    }

    public func setAccessGitHubKey(_ k: WebAccessGitHubKey) async throws -> AccessReport {
        let store = self.store
        var r = HostRequest(.accessGithubKey)
        if let s = k.secret { r.secret = s } else { r.clearSetting = true }
        let request = r
        let m = try await blocking { try HostClient.request(request, store: store, autostart: true) }
        guard m.ok == true else { throw m.error ?? HostError(.failed, "the host gave no reason") }
        return try await access(check: nil)          // the host answers it (it runs now): its keychain says

    }

    public func preparations() async throws -> [WebPreparation] {
        guard store.hostIsRunning() else { return [] }
        return try await query(HostRequest(.prepareStatus)).0.decode(PrepareStatus.self).preparations.map(WebPreparation.init)
    }

    public var storePath: String { store.root.path }

    /// A blocking host call, off the cooperative pool.
    private func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(with: Result { try work() }) }
        }
    }

    /// One read: through the host when one runs (or one must recover), else from the store.
    func query(_ r: HostRequest) async throws -> (JSONValue, fromHost: Bool) {
        let store = self.store
        if store.hostIsRunning() {
            // 594 W18: never autostart here. A host that is stopping (`doz host stop`, SIGTERM) closes
            // its socket first and holds its lock while it hibernates everything: a client that
            // autostarts in that window starts the NEXT host at once — an open UI polling every 3 s
            // brought every stopped host straight back. Then read the store, as with no host.
            let reply: HostMessage?
            do {
                reply = try await blocking { try HostClient.request(r, store: store, autostart: false) }
            } catch where !FileManager.default.fileExists(atPath: store.socket.path) || !store.hostIsRunning() {
                reply = nil
            }
            if let m = reply {
                if m.ok == true { return (m.result ?? .null, true) }
                throw m.error ?? HostError(.failed, "the host gave no reason")
            }
        } else if !store.needsRecovery().isEmpty {
            // A crashed host left a sandbox only a host can recover: start one (the CLI's rule).
            let m = try await blocking { try HostClient.request(r, store: store, autostart: true) }
            if m.ok == true { return (m.result ?? .null, true) }
            throw m.error ?? HostError(.failed, "the host gave no reason")
        }
        let core = HostCore(store: store, readOnly: true, version: version)
        await core.load()
        let m = await core.handle(r)
        if m.ok == true { return (m.result ?? .null, false) }
        throw m.error ?? HostError(.failed, "no reason")
    }

    /// 594 W20: Restart host — ONLY when the running host is an OLDER build than this UI (the one
    /// case the page offers it): `host stop` (its sandboxes hibernate), then a host of this UI's own
    /// build, started the normal detached way (HostLauncher). Anything else is refused: `host stop`
    /// on its own stays out of the browser.
    public func restartHost(onEvent: @escaping @Sendable (HostEvent) -> Void) async throws -> JSONValue {
        let store = self.store, ui = version
        guard store.hostIsRunning(), let st = await hostStatus() else {
            throw HostError(.invalid, "no host is running — Start host starts one")
        }
        guard WebVersion.compare(st.version, ui) == .orderedAscending else {
            throw HostError(.invalid, "the host (\(st.version)) is not older than doz ui (\(ui)) — nothing to restart")
        }
        // 594 W22: each sandbox's hibernation reaches the operation as it happens (`onEvent`).
        let stopped = try await blocking { try HostClient.request(HostRequest(.hostStop), store: store, autostart: false, onEvent: onEvent) }
        if stopped.ok != true { throw stopped.error ?? HostError(.failed, "the host did not stop") }
        let stop = try? (stopped.result ?? .null).decode(HostStopResult.self)
        // It exits once it has hibernated everything; a new host would wait for its lock anyway.
        for _ in 0..<600 where store.hostIsRunning() { try await Task.sleep(for: .milliseconds(100)) }
        let m = try await blocking { try HostClient.request(HostRequest(.ping), store: store, autostart: true) }
        guard m.ok == true else { throw m.error ?? HostError(.failed, "the host gave no reason") }
        let host = try? (m.result ?? .null).decode(HostStatus.self)
        return try JSONValue(encoding: WebHostRestart(stop: stop, host: host))
    }

    public func hostAnswers() -> Bool {
        guard let fd = UnixSocket.connect(store.socket.path) else { return false }
        close(fd)
        return true
    }

    public func hostProbe() -> WebHostProbe? {
        let store = self.store
        if store.hostIsRunning() { return WebHostProbe(running: true) }
        let stale = store.hostPID().map { kill($0, 0) != 0 && errno == ESRCH } ?? false
        let recovering = store.needsRecovery()
        let lost = recovering.filter { name in
            let layout = store.layout(name)
            guard let p = PersistedSandbox.read(from: layout.persistedState) else { return false }
            return !(p.phase == .asleep && p.isRestorable(layout: layout))
        }
        return WebHostProbe(running: false, stalePID: stale, lost: lost, recovering: recovering,
                            exitReason: HostExitReason.read(store.logFile))
    }

    func hostStatus() async -> HostStatus? {
        let store = self.store
        guard store.hostIsRunning() else { return nil }
        return try? await blocking {
            let m = try HostClient.request(HostRequest(.ping), store: store, autostart: false)
            return try m.result?.decode(HostStatus.self)
        }
    }

    public func overview() async throws -> WebOverview {
        // Never the per-sandbox session count: it connects to every session's holder in the guest,
        // and this is polled every 3 s (590 bug 3). Sessions are listed on a sandbox's own page.
        var ls = HostRequest(.ls)
        ls.withSessions = false
        let (v, fromHost) = try await query(ls)
        var rows = try v.decode([SandboxInfo].self).map(WebSandboxRow.init)
        for i in rows.indices {
            // The sandbox's own policy decides (a custom one may or may not reach the API).
            if let p = SandboxConfig.read(store.configFile(rows[i].name))?.spec.network.policy {
                rows[i].accountApplies = Self.reachesAccountAPI(p)
            }
        }
        // 605: a host that is STOPPING (`doz host stop`: its socket closed, its lock still held) is putting
        // its live sandboxes away (hibernating them). Read in-process meanwhile, a record still saying live
        // looks shut down — and a page closes a shut-down sandbox's terminals. Say what is true: busy (the
        // next look, once the host has gone, shows where each ended up).
        if !fromHost, store.hostIsRunning() {
            let stopping = Set(store.needsRecovery())
            for i in rows.indices where stopping.contains(rows[i].name) { rows[i].busy = true }
        }
        let st = fromHost ? await hostStatus() : nil
        var host = WebHost(running: st != nil, version: st?.version, pid: st?.pid, startedAt: st?.startedAt,
                           idleTimeoutMinutes: st?.idleTimeoutMinutes, idleSeconds: st?.idleSeconds,
                           liveSandboxes: st?.liveSandboxes ?? [], connections: st?.connections,
                           // A live record is only "pending recovery" when no host holds it.
                           // (Nor while a stopping host still holds the lock: it is hibernating them.)
                           recoveryPending: fromHost || store.hostIsRunning() ? [] : store.needsRecovery(), store: store.root.path, uiVersion: version)
        if host.running { host.versionNote = WebVersionNote.make(ui: version, host: host.version) }
        var o = WebOverview(host: host, sandboxes: rows, source: fromHost ? "host" : "store")
        o.onboarded = OnboardingRecord.read(store) != nil
        return o
    }

    public func sandbox(_ name: String) async throws -> WebSandboxDetail {
        let (v, fromHost) = try await query(HostRequest(.inspect, name: name))
        let d = try v.decode(SandboxDetail.self)
        var w = WebSandboxDetail(d, attachCommand: attachCommand(name))
        // 605: as in `overview` — a stopping host is putting it away (never "shut down" meanwhile).
        if !fromHost, store.hostIsRunning(), store.needsRecovery().contains(name) { w.info.busy = true }
        w.info.accountApplies = d.policy.map(Self.reachesAccountAPI) ?? false
        return w
    }

    /// Whether a proxied sandbox's policy lets a connection reach Anthropic's API — only then does
    /// its account matter (590: lab/bake sandboxes showed the store's `mac` account, which is noise).
    static func reachesAccountAPI(_ p: NetworkPolicy) -> Bool {
        CredentialBinding.anthropic.hosts.contains { p.evaluateConnection(host: $0, port: 443).kind != .deny }
    }

    public func sessions(_ name: String) async throws -> [WebSessionRow] {
        try await query(HostRequest(.sessions, name: name)).0.decode([SessionRow].self).map(WebSessionRow.init)
    }

    public func network(_ name: String) async throws -> WebNetwork {
        let info = try await query(HostRequest(.inspect, name: name)).0.decode(SandboxDetail.self)
        let proxied = info.policy != nil
        guard proxied else {
            return WebNetwork(name: name, proxied: false, mode: info.info.network, policy: nil, log: [], logTotal: 0, denied: 0,
                              logAvailable: false, note: "not proxied (network \(info.info.network)) — it has no policy or connection log")
        }
        // 597: what the agent can do (and, with a host, what it was refused lately).
        let perms = (try? await query(HostRequest(.netPermissions, name: name)).0.decode(PermissionReport.self)).map(WebPermissions.init)
        guard store.hostIsRunning() else {
            return WebNetwork(name: name, proxied: true, mode: info.info.network, policy: info.policy.map(WebPolicy.init), log: [], logTotal: 0,
                              denied: 0, logAvailable: false, note: "the connection log lives in the host, from its start — no host is running",
                              permissions: perms)
        }
        let recs = try await query(HostRequest(.netLog, name: name)).0.decode([ConnectionRecord].self)
        return WebNetwork(name: name, proxied: true, mode: info.info.network, policy: info.policy.map(WebPolicy.init),
                          log: recs.suffix(logLimit).map(WebConnection.init), logTotal: recs.count,
                          denied: recs.filter { $0.verdict == .denied }.count, logAvailable: true, note: nil, permissions: perms)
    }

    public func images() async throws -> [WebImage] {
        try await query(HostRequest(.imageList)).0.decode([ImageRow].self).map(WebImage.init)
    }

    public func imageTree() async throws -> WebImageTree {
        WebImageTree(try await query(HostRequest(.imageTree)).0.decode(ImageTree.self))
    }

    public func accounts() async throws -> WebAccounts {
        let rows = try await query(HostRequest(.accountList)).0.decode([AccountRow].self)
        let file = AccountStore(store: store, settings: .load()).load()
        return WebAccounts(accounts: rows.map(WebAccount.init), defaultAccount: file.defaultAccount, keepalive: file.keepalive,
                           openaiDefault: rows.first { $0.isDefault && AccountKind(rawValue: $0.kind)?.provider == "openai" }?.name)
    }

    public func metrics(_ q: WebMetricsQuery) async throws -> WebMetrics {
        let url = store.metrics
        guard FileManager.default.fileExists(atPath: url.path) else {
            return WebMetrics(available: false, runs: 0, rows: 0, sessions: 0, networkMinutes: 0, summary: [])
        }
        return try await blocking {
            let m = try MetricsStore(url: url)
            let c = m.counts()
            return WebMetrics(available: true, runs: c.runs, rows: c.events, sessions: c.sessions, networkMinutes: c.networkMinutes,
                              summary: m.summary(q.filter).map(WebMetricsRow.init))
        }
    }

    public func metricsCSV(_ q: WebMetricsQuery) async throws -> Data {
        let url = store.metrics
        guard FileManager.default.fileExists(atPath: url.path) else { return Data(MetricsStore.csv([]).utf8) }
        return try await blocking {
            let events = try MetricsStore(url: url).events(q.filter).map(WebCSV.defuse)
            return Data(MetricsStore.csv(events).utf8)
        }
    }

    // MARK: phase 2 — actions

    public func perform(_ r: HostRequest, onEvent: @escaping @Sendable (HostEvent) -> Void) async throws -> JSONValue {
        let store = self.store
        let m = try await blocking { try HostClient.request(r, store: store, autostart: true, onEvent: onEvent) }
        if m.ok == true { return m.result ?? .null }
        throw m.error ?? HostError(.failed, "the host gave no reason")
    }

    public func policyPreview(_ name: String, _ edit: WebPolicyEdit) async throws -> WebPolicyPreview {
        let d = try await query(HostRequest(.inspect, name: name)).0.decode(SandboxDetail.self)
        guard let live = d.policy else { throw HostError(.invalid, "\(name) is not proxied (network \(d.info.network)) — it has no policy") }
        // `before` without the strict sign-in block, like `after`: the host re-derives that block.
        let base = d.info.base.flatMap { BaseCatalogue.base($0) != nil ? $0 : nil }
        let agent = ImageChoice.parse(d.info.image)?.agent        // 599i: Codex keeps "Talk to OpenAI"
        let before = try HostCore.editedPolicy(live, HostRequest(.netPolicy, name: name), base: base, agent: agent)
        return WebPolicyPreview(before: before, after: try HostCore.editedPolicy(live, edit.request(name), base: base, agent: agent))
    }

    public func openTerminal(_ name: String, session: String?) async throws -> String {
        // The sandbox must exist (a clear 404 rather than a Terminal tab that says so).
        _ = try await query(HostRequest(.inspect, name: name))
        let command = TerminalHandoff.command(executable: executable, store: store, sandbox: name, session: session)
        let launch = terminalLauncher
        try await blocking { try launch(command) }
        return "Terminal opened: \(session.map { "\(name) \($0)" } ?? name)"
    }

    public func attachTerminal(_ name: String, session: String?, size: TermSize) async throws -> any WebTerminalAttachment {
        let store = self.store
        return try await blocking { try HostTerminalAttachment.open(store: store, sandbox: name, session: session, size: size) }
    }

    /// `doz doctor`'s checks, at most every 30 s (it runs `claude --version` and reads the keychain's
    /// attributes; it never prints a secret, and neither does this).
    public func doctor() async throws -> [WebDoctorCheck] {
        if let (t, c) = lock.withLock({ doctorCache }), Date().timeIntervalSince(t) < 30 { return c }
        let run = doctorChecks
        let checks = try await blocking { run() }
        lock.withLock { doctorCache = (Date(), checks) }
        return checks
    }

    public func hostEvents() -> AsyncStream<HostEvent>? {
        guard store.hostIsRunning(), let client = try? HostClient.connect(store: store, autostart: false) else { return nil }
        do { try client.send(HostRequest(.events)) } catch { return nil }
        let (stream, cont) = AsyncStream<HostEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let fd = client.fd
        cont.onTermination = { _ in Darwin.shutdown(fd, SHUT_RDWR) }
        Thread.detachNewThread {
            while let m = try? client.next() {
                if m.ok == false { break }
                if let e = m.event { cont.yield(e) }
            }
            cont.finish()
            _ = client                                   // closed (deinit) once the reader is done
        }
        return stream
    }

    /// 591: `console NAME --follow` — the boot console's lines as they are written (the CLI's
    /// `doz console --follow`). Nil when no host runs. Ends when the stream is cancelled.
    public func bootConsole(_ name: String) -> AsyncStream<String>? {
        guard store.hostIsRunning(), let client = try? HostClient.connect(store: store, autostart: false) else { return nil }
        var r = HostRequest(.console, name: name)
        r.follow = true
        do { try client.send(r) } catch { return nil }
        let (stream, cont) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(4096))
        let fd = client.fd
        cont.onTermination = { _ in Darwin.shutdown(fd, SHUT_RDWR) }
        Thread.detachNewThread {
            while let m = try? client.next() {
                if m.ok == false { break }
                if let e = m.event, e.kind == .console { cont.yield(e.text ?? "") }
            }
            cont.finish()
            _ = client
        }
        return stream
    }

    // MARK: 593 §9 — session memory

    public func sessionScreen(_ name: String, session: String) async throws -> WebSavedScreen {
        var r = HostRequest(.sessionScreen, name: name)
        r.session = session
        return WebSavedScreen(try await query(r).0.decode(SessionScreen.self))
    }

    public func terminalLayout(_ name: String) async throws -> WebTerminalLayout? {
        try await query(HostRequest(.terminalLayout, name: name)).0.decode(TerminalLayout?.self).map(WebTerminalLayout.init)
    }

    public func setTerminalLayout(_ name: String, _ layout: TerminalLayout) async throws -> WebTerminalLayout? {
        var r = HostRequest(.terminalLayoutSet, name: name)
        r.layout = layout
        return try await query(r).0.decode(TerminalLayout?.self).map(WebTerminalLayout.init)
    }

    public func bootLogs(_ name: String) async throws -> WebBootList {
        var r = HostRequest(.bootLog, name: name)
        r.list = true
        return WebBootList(try await query(r).0.decode(BootLogList.self))
    }

    public func bootLog(_ name: String, number: Int) async throws -> WebBootLog {
        var r = HostRequest(.bootLog, name: name)
        r.boot = number
        return WebBootLog(try await query(r).0.decode(BootLogRecord.self))
    }

    /// `doz attach NAME`, with `--store` when this is not the default store (shell-quoted). The UI
    /// shows it to copy; it carries no authority (host.sock is the user's own).
    func attachCommand(_ name: String) -> String {
        let def = DozerStore.resolve(nil, environment: [:])
        guard store != def else { return "doz attach \(name)" }
        return "doz attach \(name) --store \(shellQuote(store.root.path))"
    }
}

/// POSIX single-quoting.
func shellQuote(_ s: String) -> String {
    if !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/._-+:@".contains($0)) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
