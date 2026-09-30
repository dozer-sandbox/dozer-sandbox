import Foundation
import DozerKit
import DozerHost

/// The operations the UI started (590 phase 2). `POST /api/v1/actions` answers 202 at once with the
/// operation; the host call runs here, and its progress lines (the host's `event` lines for that
/// request) and its outcome go to every open page as SSE `op` events — so a 40-second cold start
/// shows its steps in the sandbox's row instead of holding an HTTP request open.
///
/// Bounded: at most `maxRunning` at once (503 beyond), the last `keep` remembered. The outcome shown
/// is a line this file writes from the result — the host's result itself is never sent on.
final class WebOperations: @unchecked Sendable {
    let data: DozerWebData
    let hub: SSEHub
    let monitor: WebMonitor
    let maxRunning = 8
    let keep = 50
    private let lock = NSLock()
    private var ops: [WebOperation] = []
    private var running = 0
    private var lastProgress: [String: Date] = [:]
    /// What runs now, by `WebAction.dedupeKey` — a repeat of an in-flight action is refused (409).
    private var inFlight: Set<String> = []

    init(data: DozerWebData, hub: SSEHub, monitor: WebMonitor) {
        self.data = data
        self.hub = hub
        self.monitor = monitor
    }

    var recent: [WebOperation] { lock.withLock { ops } }

    /// 591: told whenever an operation starts or ends (the terminals' covers show a running one).
    var onChange: (@Sendable ([WebOperation]) -> Void)?

    /// `firstLine`: what the operation says until the host's first step (591: "a key typed in a
    /// terminal — waking" for a keystroke wake).
    func start(_ action: WebAction, firstLine: String = "requested — waiting for the host") throws -> WebOperation {
        let verb = action.hostOp == .openSession ? "open-session" : action == .hostStart ? "host-start"
            : action == .hostRestart ? "host-restart" : action.hostRequest.op.rawValue
        let op = WebOperation(id: String(WebRandom.token().prefix(12)), action: verb, label: action.label, sandbox: action.sandbox,
                              state: "running", text: firstLine, startedAt: Date(), milliseconds: nil)
        let key = action.dedupeKey
        try lock.withLock {
            // The same action on the same thing is already under way (a double click, a second tab).
            guard !inFlight.contains(key) else { throw WebRejection.alreadyRunning }
            guard running < maxRunning else { throw WebRejection.tooManyOperations }
            inFlight.insert(key)
            running += 1
            ops.append(op)
            if ops.count > keep { ops.removeFirst(ops.count - keep) }
        }
        hub.broadcast("op", op)
        onChange?(recent)
        let t0 = ContinuousClock.now
        let request = action.hostRequest
        Task {
            let outcome: (String, String)
            do {
                let onEvent: @Sendable (HostEvent) -> Void = { [weak self] e in self?.progress(op.id, e) }
                let result = action == .hostRestart ? try await data.restartHost(onEvent: onEvent)
                                                    : try await data.perform(request, onEvent: onEvent)
                outcome = ("done", Self.summary(action, result))
            } catch {
                outcome = ("failed", HostError.from(error).message)
            }
            let d = ContinuousClock.now - t0
            let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            let final = update(op.id) { o in
                o.state = outcome.0
                o.text = outcome.1
                o.milliseconds = ms
            }
            lock.withLock {
                running -= 1
                inFlight.remove(key)
                lastProgress[op.id] = nil
            }
            if let final { hub.broadcast("op", final) }
            onChange?(recent)
            await monitor.poke()
        }
        return op
    }

    /// A progress line from the host. Download progress ("pulling …: 312 MiB of 640 MiB") is passed
    /// on at most once a second, so a two-minute first start (a pull, a flatten, a bake) visibly
    /// moves instead of looking stuck (590 bug 2).
    private func progress(_ id: String, _ e: HostEvent) {
        if e.kind == .progress || e.kind == .output {
            let now = Date()
            let due: Bool = lock.withLock {
                if let last = lastProgress[id], now.timeIntervalSince(last) < 1 { return false }
                lastProgress[id] = now
                return true
            }
            guard due || (e.completedBytes ?? 0) == (e.totalBytes ?? -1) else { return }
        }
        let text = WebActivity(seq: 0, e).text
        if let o = update(id, { o in if o.state == "running" { o.text = text } }), o.state == "running" { hub.broadcast("op", o) }
    }

    private func update(_ id: String, _ change: (inout WebOperation) -> Void) -> WebOperation? {
        lock.withLock {
            guard let i = ops.firstIndex(where: { $0.id == id }) else { return nil }
            change(&ops[i])
            return ops[i]
        }
    }

    /// One line for the page, from the host's result (never the result itself).
    static func summary(_ a: WebAction, _ v: JSONValue) -> String {
        switch a {
        case .lifecycle(let op, let name):
            guard let r = try? v.decode(LifecycleResult.self) else { return "\(op.rawValue) \(name): done" }
            let label = { (s: String) in Phase(rawValue: s).map(PhaseName.label) ?? s }
            if !r.changed { return "\(name) is already \(label(r.phase))" }
            if op == .rm { return "\(name) removed" }
            return "\(name): \(label(r.phaseBefore)) → \(label(r.phase)) in \(Self.duration(r.milliseconds))"
        case .create(let name, _):
            return "created \(name) — start it to boot"
        case .openSession(let name, _, _):
            let s = try? v.decode(SessionOpened.self)
            return s.map { "\($0.created ? "started" : "already running:") session \($0.session) in \(name)" } ?? "session opened in \(name)"
        case .pointTake(let name, _, _):
            return (try? v.decode(RestorePoint.self)).map { "took \($0.name) of \(name)" } ?? "restore point taken"
        case .pointRevert(let name, _):
            return (try? v.decode(RestorePoint.self)).map { "\(name) reverted to \($0.name) — start boots it" } ?? "\(name) reverted"
        case .pointFork(_, _, let new):
            return "forked as \(new) — start it to boot"
        case .pointRemove:
            return (try? v.decode(RestorePoint.self)).map { "deleted restore point \($0.name)" } ?? "restore point deleted"
        case .pointSaveImage(_, _, let image, _):
            return "saved image \(image)"
        case .templateCreate(let name, _, let image, _):
            return (try? v.decode(CustomImage.self)).map { "saved \(name)'s root disk as the template \(image) (\(DozerImages.formatBytes($0.allocatedBytes)); no state disk)" }
                ?? "saved the template \(image)"
        case .duplicate(let name, let new, _, let o):
            return "duplicated \(name) as \(new) (state disk \(o.copyState == true ? "copied" : "fresh")) — start it to boot"
        case .imageBake(let i):
            return "\(i) baked"
        case .imageRemove(let i):
            return "removed image \(i)"
        case .netPolicy(let name, _):
            return (try? v.decode(NetworkPolicy.self)).map { "\(name): \($0.preset.map { "\($0) preset" } ?? "custom policy"), \($0.rules.count) rules" }
                ?? "\(name): policy changed"
        case .keyPolicy(let name, let p):
            return "\(name): key policy \(p)"
        case .keyRemove(let name, let b):
            return "\(b) removed from \(name)"
        case .accountUse(let name, let acc):
            return "\(name) uses \(acc)"
        case .accountDefault(let acc):
            return "the default account is \(acc)"
        case .accountKeepalive(let on):
            return "keep-alive \(on ? "on" : "off")"
        case .accountVerify(let acc):
            return (try? v.decode([AccountRow].self))?.first { $0.name == acc }.map { "\(acc): \($0.verification ?? $0.state)" } ?? "\(acc) checked"
        case .accountRemove(let acc):
            return "removed account \(acc)"
        case .onboard(let images):
            let r = try? v.decode(PrepareResult.self)
            let preparing = r?.preparations.filter(\.running).map(\.image) ?? []
            if !preparing.isEmpty { return "preparing \(preparing.joined(separator: ", ")) in the host — it goes on in the background; the onboarding is recorded when it is done" }
            return images.isEmpty ? "onboarded (no image prepared now)" : "onboarded — \(images.joined(separator: ", ")) ready"
        case .hostStart:
            let s = try? v.decode(HostStatus.self)
            return s.map { "the host is running (pid \($0.pid), doz \($0.version))" } ?? "the host is running"
        case .hostRestart:
            let s = try? v.decode(HostStatus.self)
            return s.map { "the host restarted as doz \($0.version) (pid \($0.pid)) — its sandboxes hibernated; they wake when used" }
                ?? "the host restarted — its sandboxes hibernated; they wake when used"
        case .prepareCancel:
            let ps = (try? v.decode([PreparationInfo].self)) ?? []
            return ps.isEmpty ? "nothing was being prepared" : "cancelling the preparation of \(ps.map(\.image).joined(separator: ", "))"
        case .resourcesRemove, .resourcesClean:
            guard let p = try? v.decode(ResourcePlan.self) else { return "deleted" }
            var s = p.deleted.isEmpty ? "nothing deleted" : "deleted \(p.deleted.count) item\(p.deleted.count == 1 ? "" : "s") — freed \(DozerImages.formatBytes(p.freedBytes))"
            if !p.refused.isEmpty { s += "; refused \(p.refused.count) (\(p.refused[0].reason))" }
            if !p.failed.isEmpty { s += "; \(p.failed.count) failed (\(p.failed[0].reason))" }
            return s
        case .resourcesKernel:
            return (try? v.decode(ResourceKernelChoice.self)).map { "new sandboxes boot \($0.kernel) — existing ones keep theirs" } ?? "kernel chosen"
        }
    }

    static func duration(_ ms: Double) -> String {
        ms < 1000 ? "\(Int(ms.rounded())) ms" : String(format: "%.1f s", ms / 1000)
    }
}
