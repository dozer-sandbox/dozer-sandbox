import Foundation
import DozerHost

/// One server-sent event, already encoded (`id:` / `event:` / `data:` — data is ONE line of JSON).
struct SSEFrame: Sendable {
    let bytes: Data

    init(event: String, id: Int? = nil, json: Data) {
        var s = ""
        if let id { s += "id: \(id)\n" }
        s += "event: \(event)\ndata: "
        var d = Data(s.utf8)
        // JSONEncoder never emits a raw newline (strings escape it), but be certain: one data line.
        d.append(contentsOf: json.map { $0 == 10 || $0 == 13 ? 32 : $0 })
        d.append(contentsOf: Array("\n\n".utf8))
        bytes = d
    }

    init(comment: String) { bytes = Data(": \(comment)\n\n".utf8) }
}

/// Why a stream ended, for its last frame.
enum SSEEnd: Sendable, Equatable {
    case overflow, sessionEnded, shutdown, replaced, clientGone
    /// 594 W19: every session ended for a new link (`doz ui link --rotate`).
    case rotated
    /// 605: `doz ui restart` — the page stays calm and reconnects (same port, sessions kept).
    case restarting
    /// 605: `doz ui restart` moved the UI to another port (its origin). The page cannot follow by itself
    /// (a script navigation to another port is same-site, which the Fetch-Metadata rule refuses): the new
    /// doz ui opens a tab there, and this page says where it went.
    case moved(String)
    /// 606: this browser was removed from doz serve's devices.
    case revoked
}

/// One live-update client with a BOUNDED queue. When the client cannot keep up the queue is not
/// grown and events are not silently dropped: the stream ends with `resync` (the page refetches
/// everything and reconnects) — DeckStack 503's rule.
final class SSEClient: @unchecked Sendable {
    let id = UUID()
    let cookie: String
    let opened = Date()
    let frames: AsyncStream<SSEFrame>
    private let continuation: AsyncStream<SSEFrame>.Continuation
    private let lock = NSLock()
    private var _end: SSEEnd?

    init(cookie: String, capacity: Int) {
        self.cookie = cookie
        (frames, continuation) = AsyncStream<SSEFrame>.makeStream(bufferingPolicy: .bufferingOldest(capacity))
    }

    var end: SSEEnd? { lock.withLock { _end } }

    func send(_ f: SSEFrame) {
        guard lock.withLock({ _end == nil }) else { return }
        if case .dropped = continuation.yield(f) { finish(.overflow) }
    }

    func finish(_ why: SSEEnd) {
        let first: Bool = lock.withLock {
            guard _end == nil else { return false }
            _end = why
            return true
        }
        if first { continuation.finish() }
    }
}

/// The fan-out to every open stream, bounded in number of clients.
final class SSEHub: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [UUID: SSEClient] = [:]
    private var seq = 0
    let maxClients: Int
    let capacity: Int

    init(maxClients: Int, capacity: Int) {
        self.maxClients = maxClients
        self.capacity = capacity
    }

    var count: Int { lock.withLock { clients.count } }
    var all: [SSEClient] { lock.withLock { Array(clients.values) } }

    /// A new client, or nil when the limit is reached. At the limit, the OLDEST stream of the same
    /// session is replaced (a reloaded tab's old stream is only noticed dead at the next heartbeat).
    func add(cookie: String) -> SSEClient? {
        var evicted: SSEClient?
        let c: SSEClient? = lock.withLock {
            if clients.count >= maxClients {
                guard let old = clients.values.filter({ $0.cookie == cookie }).min(by: { $0.opened < $1.opened }) else { return nil }
                clients[old.id] = nil
                evicted = old
            }
            let c = SSEClient(cookie: cookie, capacity: capacity)
            clients[c.id] = c
            return c
        }
        evicted?.finish(.replaced)
        return c
    }

    func remove(_ c: SSEClient) { lock.withLock { clients[c.id] = nil } }

    func nextSeq() -> Int { lock.withLock { seq += 1; return seq } }

    func broadcast<T: Encodable>(_ event: String, _ value: T) {
        guard let json = try? WebJSON.encoder.encode(value) else { return }
        let f = SSEFrame(event: event, id: nextSeq(), json: json)
        for c in all { c.send(f) }
    }

    func finishAll(_ why: SSEEnd) { for c in all { c.finish(why) } }
}

private struct SlowState: Encodable {
    let images: [WebImage]?
    let accounts: WebAccounts?
}

enum WebJSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    /// What reads `encoder`'s output back (the tests).
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// 605: who else reads each overview the monitor fetched (the operations an earlier `doz ui` left
/// running are resolved from it). Set once, after the operations exist.
final class OverviewHook: @unchecked Sendable {
    private let lock = NSLock()
    private var fn: (@Sendable (WebOverview) -> Void)?
    func set(_ f: @escaping @Sendable (WebOverview) -> Void) { lock.withLock { fn = f } }
    func callAsFunction(_ o: WebOverview) { lock.withLock { fn }?(o) }
}

/// Keeps the open pages current while at least one stream is open (nothing polls otherwise):
///   · polls the overview (short requests — they never keep the host alive), and announces
///     `changed` when it differs;
///   · while a host runs AND holds a live sandbox, follows the host's event stream (`activity`,
///     and an early re-poll). It lets go of the stream when nothing is live, so an open UI never
///     keeps an idle host from exiting (an open host stream counts as a connection).
actor WebMonitor {
    let data: DozerWebData
    let hub: SSEHub
    /// 591: open terminals keep the poll going too, and are told every sandbox's phase.
    let terminals: WebTerminalHub?
    let pollInterval: Duration
    let overviewHook = OverviewHook()
    private var task: Task<Void, Never>?
    private var events: Task<Void, Never>?
    private var lastOverview: Data?
    private var lastSlow: Data?
    private var watch = WebHostWatch()
    /// 594 W18: the last host change told (a page that connects later gets it with `hello`).
    private(set) var lastHostChange: WebHostChange?
    private var lastPhases: [String: String]?
    private var lastPreparations: Data?
    private var activity: [WebActivity] = []
    private var pokes = 0
    let activityLimit = 200

    init(data: DozerWebData, hub: SSEHub, terminals: WebTerminalHub? = nil, pollInterval: Duration) {
        self.data = data
        self.hub = hub
        self.terminals = terminals
        self.pollInterval = pollInterval
    }

    var recent: [WebActivity] { activity }

    /// Called when a stream opens: start polling if nothing polls yet.
    func streamOpened() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.loop() }
    }

    func stop() {
        task?.cancel()
        task = nil
        events?.cancel()
        events = nil
    }

    private func loop() async {
        var round = 0
        while !Task.isCancelled {
            if hub.count == 0 && (terminals?.count ?? 0) == 0 {
                events?.cancel()
                events = nil
                task = nil
                return
            }
            await poll(slow: round % 5 == 0)
            round += 1
            let start = pokes
            // Sleep for the interval, or less when an event asked for an early look.
            var slept = Duration.zero
            while slept < pollInterval && pokes == start && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                slept += .milliseconds(100)
            }
        }
    }

    func poke() { pokes += 1 }

    private func record(_ a: WebActivity) {
        activity.append(a)
        if activity.count > activityLimit { activity.removeFirst(activity.count - activityLimit) }
        hub.broadcast("activity", a)
    }

    /// 594 W18: one host change — to every page (`host`), and to the Activity feed.
    private func tell(_ c: WebHostChange) {
        lastHostChange = c
        hub.broadcast("host", c)
        record(WebActivity(seq: hub.nextSeq(), time: c.time, kind: "host", text: c.text))
    }

    private func poll(slow: Bool) async {
        // 594 W18: the host's state BEFORE the overview — which starts a host to recover a crash, so
        // only this look sees the gap that tells a kill from a clean stop.
        let probe = data.hostProbe()
        if let p = probe, let c = watch.probed(p) { tell(c) }
        guard let o = try? await data.overview() else { return }
        // A host that holds the lock but no longer answers is stopping (it hibernates everything
        // first): its end is told by the next look, with its reason.
        if !(probe?.running == true && !o.host.running) {
            for c in watch.saw(o) { tell(c) }
        }
        terminals?.updatePhases(o.sandboxes.map { ($0.name, $0.phase) })
        overviewHook(o)
        // A phase change the host's stream did not report (the UI follows it only while something is
        // live, so a wake from hibernation happens before it re-subscribes): note it from the poll.
        let phases = Dictionary(o.sandboxes.map { ($0.name, $0.phaseLabel) }, uniquingKeysWith: { a, _ in a })
        if let before = lastPhases, events == nil {
            for (name, now) in phases.sorted(by: { $0.key < $1.key }) where before[name] != nil && before[name] != now {
                var a = WebActivity(seq: hub.nextSeq(), kind: "phase", text: "\(before[name]!) → \(now)")
                a.sandbox = name
                record(a)
            }
        }
        lastPhases = phases
        var topics: [String] = []
        var stable = o
        stable.host.idleSeconds = nil
        stable.host.connections = nil
        if let d = try? WebJSON.encoder.encode(stable), d != lastOverview {
            if lastOverview != nil { topics.append("overview") }
            lastOverview = d
        }
        if slow {
            async let images = try? data.images()
            async let accounts = try? data.accounts()
            let slowState = SlowState(images: await images, accounts: await accounts)
            if let d = try? WebJSON.encoder.encode(slowState), d != lastSlow {
                if lastSlow != nil { topics += ["images", "accounts"] }
                lastSlow = d
            }
        }
        if !topics.isEmpty { hub.broadcast("changed", ["topics": topics]) }
        // 594: the host's image preparations (a CLI `doz onboard` or a start's, too) — told to every
        // page while any runs, and once more when the last one ends.
        var preparing = false
        if o.host.running || lastPreparations != nil {
            let preps = (try? await data.preparations()) ?? []
            preparing = preps.contains { $0.state == "running" || $0.state == "cancelling" }
            if let d = try? WebJSON.encoder.encode(preps), d != lastPreparations {
                if preparing || lastPreparations != nil { hub.broadcast("preparations", preps) }
                lastPreparations = preparing || !preps.isEmpty ? d : nil
            }
        }
        // Follow the host's events only while something is live (see the type's comment).
        let follow = o.host.running && (!o.host.liveSandboxes.isEmpty || preparing)
        if follow && events == nil, let stream = data.hostEvents() {
            events = Task { [weak self] in
                for await e in stream {
                    guard let self else { return }
                    await self.hostEvent(e)
                }
                await self?.eventsEnded()
            }
        } else if !follow, let t = events {
            t.cancel()
            events = nil
        }
    }

    private func hostEvent(_ e: HostEvent) {
        // 612: an agent's status changed — look now (the overview carries it; the page's chips and notices follow).
        // Not an Activity line: an agent goes working → done every turn.
        if e.kind == .sessionStatus { poke(); return }
        guard e.kind != .progress || (e.completedBytes ?? 0) == (e.totalBytes ?? -1) else { return }   // progress: only its end
        guard e.kind != .output, e.kind != .started else { return }     // 593: live-only lines (the boot view shows them)
        record(WebActivity(seq: hub.nextSeq(), e))
        if e.kind == .phase || e.kind == .host { poke() }
    }

    /// The host's stream ended — the host went away, most likely: look now, not at the next tick.
    private func eventsEnded() {
        events = nil
        poke()
    }
}
