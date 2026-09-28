import Darwin
import Foundation
import SnoozeContainerKit
import SnoozeHost

/// Everything the UI can show and do, as typed calls. The server knows nothing else: it has no path
/// to a VM, a keychain or a file except through these calls (tests substitute a fake).
public protocol SnoozeWebData: Sendable {
    var storePath: String { get }
    func overview() async throws -> WebOverview
    func sandbox(_ name: String) async throws -> WebSandboxDetail
    func sessions(_ name: String) async throws -> [WebSessionRow]
    func network(_ name: String) async throws -> WebNetwork
    func images() async throws -> [WebImage]
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
public final class HostWebData: SnoozeWebData, @unchecked Sendable {
    public let store: SnoozeStore
    public let version: String
    let doctorChecks: @Sendable () -> [WebDoctorCheck]
    /// Records beyond this are left out of the network view (the log lives in the host's memory).
    let logLimit = 500
    private let lock = NSLock()
    private var doctorCache: (Date, [WebDoctorCheck])?

    /// The `snooze` executable Terminal runs (this process's own, symlinks resolved).
    let executable: String
    let terminalLauncher: @Sendable (String) throws -> Void

    public init(store: SnoozeStore, version: String, executable: String = HostLauncher.executablePath,
                terminal: @escaping @Sendable (String) throws -> Void = TerminalHandoff.openInTerminalApp,
                doctor: @escaping @Sendable () -> [WebDoctorCheck]) {
        self.store = store
        self.version = version
        self.executable = executable
        terminalLauncher = terminal
        doctorChecks = doctor
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
        if store.hostIsRunning() || !store.needsRecovery().isEmpty {
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
        let st = fromHost ? await hostStatus() : nil
        let host = WebHost(running: st != nil, version: st?.version, pid: st?.pid, startedAt: st?.startedAt,
                           idleTimeoutMinutes: st?.idleTimeoutMinutes, idleSeconds: st?.idleSeconds,
                           liveSandboxes: st?.liveSandboxes ?? [], connections: st?.connections,
                           // A live record is only "pending recovery" when no host holds it.
                           recoveryPending: fromHost ? [] : store.needsRecovery(), store: store.root.path, uiVersion: version)
        return WebOverview(host: host, sandboxes: rows, source: fromHost ? "host" : "store")
    }

    public func sandbox(_ name: String) async throws -> WebSandboxDetail {
        let d = try await query(HostRequest(.inspect, name: name)).0.decode(SandboxDetail.self)
        var w = WebSandboxDetail(d, attachCommand: attachCommand(name))
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
        guard store.hostIsRunning() else {
            return WebNetwork(name: name, proxied: true, mode: info.info.network, policy: info.policy.map(WebPolicy.init), log: [], logTotal: 0,
                              denied: 0, logAvailable: false, note: "the connection log lives in the host, from its start — no host is running")
        }
        let recs = try await query(HostRequest(.netLog, name: name)).0.decode([ConnectionRecord].self)
        return WebNetwork(name: name, proxied: true, mode: info.info.network, policy: info.policy.map(WebPolicy.init),
                          log: recs.suffix(logLimit).map(WebConnection.init), logTotal: recs.count,
                          denied: recs.filter { $0.verdict == .denied }.count, logAvailable: true, note: nil)
    }

    public func images() async throws -> [WebImage] {
        try await query(HostRequest(.imageList)).0.decode([ImageRow].self).map(WebImage.init)
    }

    public func accounts() async throws -> WebAccounts {
        let rows = try await query(HostRequest(.accountList)).0.decode([AccountRow].self)
        let file = AccountStore(store: store, settings: .load()).load()
        return WebAccounts(accounts: rows.map(WebAccount.init), defaultAccount: file.defaultAccount, keepalive: file.keepalive)
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
        let before = try HostCore.editedPolicy(live, HostRequest(.netPolicy, name: name))
        return WebPolicyPreview(before: before, after: try HostCore.editedPolicy(live, edit.request(name)))
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

    /// `snooze doctor`'s checks, at most every 30 s (it runs `claude --version` and reads the keychain's
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
    /// `snooze console --follow`). Nil when no host runs. Ends when the stream is cancelled.
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

    /// `snooze attach NAME`, with `--store` when this is not the default store (shell-quoted). The UI
    /// shows it to copy; it carries no authority (host.sock is the user's own).
    func attachCommand(_ name: String) -> String {
        let def = SnoozeStore.resolve(nil, environment: [:])
        guard store != def else { return "snooze attach \(name)" }
        return "snooze attach \(name) --store \(shellQuote(store.root.path))"
    }
}

/// POSIX single-quoting.
func shellQuote(_ s: String) -> String {
    if !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/._-+:@".contains($0)) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
