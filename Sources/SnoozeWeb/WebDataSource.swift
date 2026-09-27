import Darwin
import Foundation
import SnoozeContainerKit
import SnoozeHost

/// Everything the UI can show, as typed reads. The server knows nothing else: it has no path to a
/// VM, a keychain or a file except through these calls (tests substitute a fake).
public protocol SnoozeWebData: Sendable {
    var storePath: String { get }
    func overview() async throws -> WebOverview
    func sandbox(_ name: String) async throws -> WebSandboxDetail
    func sessions(_ name: String) async throws -> [WebSessionRow]
    func network(_ name: String) async throws -> WebNetwork
    func images() async throws -> [WebImage]
    func accounts() async throws -> WebAccounts
    func metrics() async throws -> WebMetrics
    func doctor() async throws -> [WebDoctorCheck]
    /// The host's event stream, while a host runs (nil when none does). The stream ends when the
    /// host goes away or the task consuming it is cancelled.
    func hostEvents() -> AsyncStream<HostEvent>?
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

    public init(store: SnoozeStore, version: String, doctor: @escaping @Sendable () -> [WebDoctorCheck]) {
        self.store = store
        self.version = version
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
        let (v, fromHost) = try await query(HostRequest(.ls))
        let rows = try v.decode([SandboxInfo].self).map(WebSandboxRow.init)
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
        return WebSandboxDetail(d, attachCommand: attachCommand(name))
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
        let file = AccountStore(store: store).load()
        return WebAccounts(accounts: rows.map(WebAccount.init), defaultAccount: file.defaultAccount, keepalive: file.keepalive)
    }

    public func metrics() async throws -> WebMetrics {
        let url = store.metrics
        guard FileManager.default.fileExists(atPath: url.path) else {
            return WebMetrics(available: false, runs: 0, rows: 0, sessions: 0, networkMinutes: 0, summary: [])
        }
        return try await blocking {
            let m = try MetricsStore(url: url)
            let c = m.counts()
            return WebMetrics(available: true, runs: c.runs, rows: c.events, sessions: c.sessions, networkMinutes: c.networkMinutes,
                              summary: m.summary(MetricsFilter(includeSteps: false)).map(WebMetricsRow.init))
        }
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
