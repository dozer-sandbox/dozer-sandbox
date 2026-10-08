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
///
/// 605: the ring is kept in `<store>/ui.operations.json` (0600; written when an operation starts or
/// ends — the lines this file wrote, never a host result, never a secret). A `doz ui` that restarts while
/// one runs leaves the HOST running it (a plain request is not cancelled when its client goes); the next
/// `doz ui` loads the ring, marks each running one interrupted, and resolves it from the monitor's
/// overview (`reconcile`) — the sandbox reached the phase the operation was for, failed, or is somewhere
/// else — so no page ever shows a forever-running operation.
final class WebOperations: @unchecked Sendable {
    let data: DozerWebData
    let hub: SSEHub
    let monitor: WebMonitor
    let file: URL?
    let maxRunning = 8
    let keep = 50
    private let lock = NSLock()
    private var ops: [WebOperation] = []
    private var running = 0
    private var lastProgress: [String: Date] = [:]
    /// What runs now, by `WebAction.dedupeKey` — a repeat of an in-flight action is refused (409).
    private var inFlight: Set<String> = []

    init(data: DozerWebData, hub: SSEHub, monitor: WebMonitor, file: URL? = nil, now: Date = Date()) {
        self.data = data
        self.hub = hub
        self.monitor = monitor
        self.file = file
        guard let file, let d = try? Data(contentsOf: file), let saved = try? WebJSON.decoder.decode([WebOperation].self, from: d) else { return }
        ops = Array(saved.suffix(keep)).map { o in
            var o = o
            if o.state == "running" {
                o.interrupted = true
                o.text = Self.interruptedText
            }
            return o
        }
    }

    static let interruptedText = "interrupted — doz ui restarted while it ran; the host carried on"

    /// Write the ring (0600, atomically).
    private func save() {
        guard let file else { return }
        let snapshot = recent
        WebSessionStore.write(snapshot.isEmpty ? nil : try? WebJSON.encoder.encode(snapshot), to: file)
    }

    /// 605: resolve the operations an earlier `doz ui` left running, from an overview.
    func reconcile(_ o: WebOverview, now: Date = Date()) {
        let rows = Dictionary(o.sandboxes.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let changed: [WebOperation] = lock.withLock {
            var out: [WebOperation] = []
            for i in ops.indices where ops[i].state == "running" && ops[i].interrupted == true {
                guard let (state, text) = Self.resolution(ops[i], rows: rows, now: now) else { continue }
                ops[i].state = state
                ops[i].text = text
                ops[i].milliseconds = max(0, now.timeIntervalSince(ops[i].startedAt) * 1000)
                out.append(ops[i])
            }
            return out
        }
        guard !changed.isEmpty else { return }
        save()
        for c in changed { hub.broadcast("op", c) }
        onChange?(recent)
    }

    /// The phase each lifecycle operation is for (`rm`: gone; `create`: there).
    static let targetPhase: [String: String] = ["start": "running", "wake": "running", "resume": "running", "pause": "paused",
                                                "sleep": "asleep", "hibernate": "hibernated", "shutdown": "off", "reset": "off"]

    /// What an interrupted operation became, judged from the sandbox now — nil while it is still under
    /// way (busy or booting), for at most 30 minutes.
    static func resolution(_ op: WebOperation, rows: [String: WebSandboxRow], now: Date) -> (String, String)? {
        let unknown = ("interrupted", "doz ui restarted while it ran; the host carried it on — its outcome was not seen here")
        guard let name = op.sandbox, targetPhase[op.action] != nil || op.action == "rm" || op.action == "create" else { return unknown }
        let row = rows[name]
        if let row, row.busy || row.phase == "booting" {
            return now.timeIntervalSince(op.startedAt) > 30 * 60 ? unknown : nil
        }
        switch op.action {
        case "rm":
            return row == nil ? ("done", "\(name) removed — finished while doz ui restarted") : ("interrupted", "doz ui restarted while it ran; \(name) is still there")
        case "create":
            return row != nil ? ("done", "created \(name) — finished while doz ui restarted") : ("interrupted", "doz ui restarted while it ran; \(name) was not created")
        default:
            guard let row else { return ("interrupted", "doz ui restarted while it ran; \(name) is gone") }
            if row.phase == targetPhase[op.action] { return ("done", "\(name) is \(row.phaseLabel) — finished while doz ui restarted") }
            if row.phase == "failed" { return ("failed", "\(name) failed while doz ui restarted — its Boot log says why") }
            return ("interrupted", "doz ui restarted while it ran; the host carried on — \(name) is now \(row.phaseLabel)")
        }
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
        save()
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
            save()
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
        let finished = Self.finishedLine(e)
        if let o = update(id, { o in
            guard o.state == "running" else { return }
            o.text = text
            // 594 W22: Restart host keeps each sandbox's line (they hibernate in parallel).
            if o.action == "host-restart", let finished { o.lines = (o.lines ?? []) + [finished] }
        }), o.state == "running" { hub.broadcast("op", o) }
    }

    /// 594 W22: a finished step as the progress view writes it (no colour): "✓ hibernated w1 — 0.4 s",
    /// "✗ hibernating w2 — why".
    static func finishedLine(_ e: HostEvent) -> String? {
        switch e.kind {
        case .step: return ProgressTerminal(mode: .animated, color: false).format(.stepDone(e.text ?? "", seconds: (e.milliseconds ?? 0) / 1000))
        case .failed: return ProgressTerminal(mode: .animated, color: false).format(.stepFailed(e.text ?? "", seconds: (e.milliseconds ?? 0) / 1000, error: e.error))
        default: return nil
        }
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
            let r = try? v.decode(WebHostRestart.self)
            let who = r?.host.map { "the host restarted as doz \($0.version) (pid \($0.pid))" } ?? "the host restarted"
            guard let stop = r?.stop else { return who + " — its sandboxes hibernated; they wake when used" }
            let hib = stop.sandboxes.filter { $0.outcome == "hibernated" }.map(\.name)
            let other = stop.sandboxes.filter { $0.outcome != "hibernated" }.map { "\($0.name): \($0.outcome == "failed" ? "could not hibernate — shut down" : $0.outcome)" }
            var s = who + (hib.isEmpty ? " — nothing was running" : " — hibernated \(hib.joined(separator: ", ")); they wake when used")
            if !other.isEmpty { s += " (" + other.joined(separator: "; ") + ")" }
            return s
        case .builderStart:
            let s = try? v.decode(ContainerToolStatus.self)
            return s?.state == "ready" ? "Apple's container services are running — Dockerfiles can be built" : (s?.note ?? "Apple's container services started")
        case .builderInstall:
            return "Apple's installer package was opened in macOS Installer — approve it there, then start its services"
        case .sessionEnd(let name, let session):
            let r = try? v.decode(SessionEnded.self)
            return r?.how == "not-running" ? "session \(session) in \(name) was not running" : "ended session \(session) in \(name)"
        case .sessionRestart(let name, let session, _):
            guard let r = try? v.decode(SessionRestarted.self) else { return "restarted session \(session) in \(name)" }
            return "restarted session \(session) in \(name)" + (r.resumed ? " — its conversation continues" : "") + (r.notice.map { " (\($0))" } ?? "")
        case .toolsApply(let name):
            let r = (try? v.decode(ToolsLayerReport.self))?.last
            return "\(name): tools — " + (r?.summary ?? "set up")
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
