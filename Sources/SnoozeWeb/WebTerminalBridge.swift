import Foundation
import NIOCore
import NIOWebSocket
import SnoozeContainerKit
import SnoozeHost

// 591 — the browser terminal's bridge: one WebSocket ↔ one host attach connection
// (591.01-DESIGN.md §4.4–§5). The page renders; everything that decides — what reaches the guest,
// what wakes a sandbox, what the cover says — is here, in the UI process.

/// Every open terminal of this UI: the limit, the phase and operation fan-out, sign-out and shutdown.
final class WebTerminalHub: @unchecked Sendable {
    let maximum: Int
    private let lock = NSLock()
    private var bridges: [UUID: WebTerminalBridge] = [:]
    private var phases: [String: String] = [:]
    private var actions: [String: String] = [:]
    /// For keystroke wakes (set by the server; weak — the operations hold the hub's callback).
    weak var operations: WebOperations?
    /// Called when a terminal opens (the monitor keeps polling while terminals are open).
    var onOpen: (@Sendable () -> Void)?

    init(maximum: Int = 16) { self.maximum = maximum }

    var count: Int { lock.withLock { bridges.count } }
    var all: [WebTerminalBridge] { lock.withLock { Array(bridges.values) } }

    func hasRoom() -> Bool { count < maximum }

    func add(_ b: WebTerminalBridge) -> Bool {
        let ok: Bool = lock.withLock {
            guard bridges.count < maximum else { return false }
            bridges[b.id] = b
            return true
        }
        if ok { onOpen?() }
        return ok
    }

    func remove(_ b: WebTerminalBridge) { lock.withLock { bridges[b.id] = nil } }

    func knownPhase(_ name: String) -> String? { lock.withLock { phases[name] } }
    func runningAction(_ name: String) -> String? { lock.withLock { actions[name] } }

    /// From the monitor's poll: every sandbox's phase. Terminals of a sandbox whose phase changed are told.
    func updatePhases(_ rows: [(name: String, phase: String)]) {
        let changed: [(String, String)] = lock.withLock {
            var out: [(String, String)] = []
            for r in rows where phases[r.name] != r.phase {
                phases[r.name] = r.phase
                out.append((r.name, r.phase))
            }
            return out
        }
        for (name, phase) in changed { for b in all where b.grant.sandbox == name { b.monitorPhase(phase) } }
    }

    /// From the operations: the lifecycle operation running on each sandbox (the oldest one — the
    /// one the others wait behind), for the covers' "Waking the sandbox…".
    func operationsChanged(_ ops: [WebOperation]) {
        var now: [String: String] = [:]
        for o in ops where o.state == "running" {
            guard let s = o.sandbox, now[s] == nil, WebTerminalCover.workingLabel(o.action) != nil else { continue }
            now[s] = o.action
        }
        let touched: Set<String> = lock.withLock {
            let keys = Set(actions.keys).union(now.keys).filter { actions[$0] != now[$0] }
            actions = now
            return keys
        }
        for b in all where touched.contains(b.grant.sandbox) { b.refreshCover() }
    }

    /// A keystroke on a terminal whose sandbox is not running: resume a paused one, wake a sleeping
    /// one — as an operation like any other (deduplicated: a second key while it runs starts nothing).
    func keystrokeWake(_ name: String, phase: String?) -> Bool {
        let op: HostOp
        switch phase.flatMap(Phase.init(rawValue:)) {
        case .paused: op = .resume
        case .asleep, .deepAsleep: op = .wake
        default: return false
        }
        guard let operations else { return false }
        do {
            _ = try operations.start(.lifecycle(op, name: name),
                                     firstLine: "a key typed in a terminal — \(op == .resume ? "resuming" : "waking")")
            return true
        } catch {
            return false                 // already under way, or too many operations: nothing to add
        }
    }

    func closeAll(cookie: String) {
        for b in all where b.grant.cookie == cookie { Task { await b.end(.policyViolation, "session-ended") } }
    }

    func closeAll() async {
        for b in all { await b.end(.goingAway, "shutdown") }
    }
}

/// One browser terminal.
final class WebTerminalBridge: @unchecked Sendable {
    let id = UUID()
    let grant: WebTerminalGrant
    private let data: SnoozeWebData
    private let hub: WebTerminalHub
    private let sessions: WebSessionStore
    private let channel: Channel
    private let outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>

    /// Liveness: the page pings every 25 s; nothing for this long closes the socket.
    static let idleTimeout: TimeInterval = 90
    /// "Reattaching…" never outlasts this.
    static let screenTimeout: TimeInterval = 10
    static let sessionCheckInterval: TimeInterval = 15

    private let lock = NSLock()
    private var session: String?
    private var phase: String?
    private var phaseSince: Date?
    private var attachment: (any WebTerminalAttachment)?
    private var awaitingScreen = true
    private var everAttached = false
    private var screenDeadline: Date?
    private var reportsIgnored = 0
    private var keystrokeWakes = 0
    private var budget = WebInputBudget()
    private var lastFrame = Date()
    private var size: TermSize
    private var lastState: String?
    private var ended = false

    init(grant: WebTerminalGrant, data: SnoozeWebData, hub: WebTerminalHub, sessions: WebSessionStore, channel: Channel,
         outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>) {
        self.grant = grant
        self.data = data
        self.hub = hub
        self.sessions = sessions
        self.channel = channel
        self.outbound = outbound
        session = grant.session
        size = grant.size ?? .standard
        phase = hub.knownPhase(grant.sandbox)
        phaseSince = Date()
    }

    private var isEnded: Bool { lock.withLock { ended } }

    // MARK: running

    func run(_ inbound: NIOAsyncChannelInboundStream<WebSocketFrame>) async {
        await withTaskGroup(of: Void.self) { g in
            g.addTask { await self.hostLoop() }
            g.addTask { await self.inboundLoop(inbound) }
            g.addTask { await self.watchdog() }
            await g.next()
            await self.end(.normalClosure, "done")
            g.cancelAll()
        }
    }

    /// Close the socket once, with a code and a reason; the attach connection goes with it (the guest
    /// session keeps running — this is what Ctrl-] is in the CLI).
    func end(_ code: WebSocketErrorCode, _ reason: String) async {
        let att: (any WebTerminalAttachment)? = lock.withLock {
            guard !ended else { return nil }
            ended = true
            let a = attachment
            attachment = nil
            return a ?? NoAttachment.shared
        }
        guard let att else { return }
        att.close()
        var buf = channel.allocator.buffer(capacity: 2 + reason.utf8.count)
        buf.write(webSocketErrorCode: code)
        buf.writeString(String(reason.prefix(100)))
        try? await outbound.write(WebSocketFrame(fin: true, opcode: .connectionClose, data: buf))
        try? await channel.close()
    }

    // MARK: host → browser

    private func hostLoop() async {
        var first = true
        while !isEnded {
            let watch = grant.mode == .watch
            let want: (String?, TermSize) = lock.withLock { (session, watch ? TermSize(cols: 0, rows: 0) : size) }
            let att: any WebTerminalAttachment
            do {
                att = try await data.attachTerminal(grant.sandbox, session: want.0, size: want.1)
            } catch {
                let e = HostError.from(error)
                if first {
                    await sendText(WebTerminalMessage.encode(WebTerminalMessage.Failure(code: e.code.rawValue, message: e.message)))
                    await end(.normalClosure, "refused")
                    return
                }
                // A reattach refused: the sandbox shut down or was removed while it was away.
                if e.code == .invalidPhase || e.code == .notFound {
                    await sendText(WebTerminalMessage.encode(WebTerminalMessage.ended(.stopped, text: e.message)))
                    await end(.normalClosure, "ended")
                    return
                }
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let adopted: Bool = lock.withLock {
                guard !ended else { return false }
                attachment = att
                awaitingScreen = true
                switch att.start {
                case .attached(let s):
                    session = s
                    setPhaseLocked(Phase.running.rawValue)
                    screenDeadline = Date().addingTimeInterval(Self.screenTimeout)
                case .held(let s, let p):
                    session = s
                    setPhaseLocked(p)
                }
                return true
            }
            guard adopted else { att.close(); return }
            first = false
            await pushState()
            var pending: [UInt8] = []
            while let chunk = await att.read() {
                pending += chunk
                if let (ending, start) = ClientWire.findEnding(in: pending) {
                    if start > 0 { await sendBinary(pending[..<start]) }
                    let text = WebTerminalWire.endingText(pending[start...])
                    await sendText(WebTerminalMessage.encode(WebTerminalMessage.ended(ending, text: text)))
                    await end(.normalClosure, "ended")
                    return
                }
                let hold = WebTerminalWire.holdBack(pending)
                let out = pending[..<(pending.count - hold)]
                if !out.isEmpty {
                    await sendBinary(out)
                    let lifted: Bool = lock.withLock {
                        guard awaitingScreen else { return false }
                        awaitingScreen = false
                        everAttached = true
                        screenDeadline = nil
                        // Bytes flow only from a running guest (the monitor may not have seen it yet).
                        setPhaseLocked(Phase.running.rawValue)
                        return true
                    }
                    if lifted { await pushState() }
                }
                pending = Array(pending.suffix(hold))
            }
            if !pending.isEmpty { await sendBinary(pending[...]) }
            // Closed without the end notice: a Deep Sleep (the guest session lives on) or a lost
            // transport. Reattach — the host holds us until the sandbox runs.
            lock.withLock {
                if attachment === att { attachment = nil }
                awaitingScreen = true
                screenDeadline = nil
                if phase == Phase.running.rawValue, let known = hub.knownPhase(grant.sandbox), known != phase { setPhaseLocked(known) }
            }
            att.close()
            await pushState()
            if isEnded { return }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// Caller holds `lock`.
    private func setPhaseLocked(_ p: String) {
        guard p != phase else { return }
        phase = p
        phaseSince = Date()
        if p == Phase.running.rawValue {
            if awaitingScreen { screenDeadline = Date().addingTimeInterval(Self.screenTimeout) }
        } else {
            screenDeadline = nil
        }
    }

    /// A phase seen by the monitor. While this terminal is attached and has its screen, a Deep Sleep
    /// or a shutdown would have closed the connection — such a report is stale and ignored.
    func monitorPhase(_ p: String) {
        let changed: Bool = lock.withLock {
            let live = attachment != nil && !awaitingScreen
            if live, p == Phase.deepAsleep.rawValue || p == Phase.off.rawValue || p == Phase.failed.rawValue { return false }
            let before = phase
            setPhaseLocked(p)
            return before != phase
        }
        if changed { refreshCover() }
    }

    func refreshCover() { Task { await pushState() } }

    private func cover() -> (WebTerminalCover, String?) {
        let action = hub.runningAction(grant.sandbox)
        return lock.withLock {
            let screenBack = !awaitingScreen || (screenDeadline.map { Date() >= $0 } ?? false)
            let c = WebTerminalCover.derive(phase: phase, since: phaseSince, action: action, screenBack: screenBack,
                                            everAttached: everAttached, watch: grant.mode == .watch)
            return (c, phase)
        }
    }

    private func pushState() async {
        let (c, p) = cover()
        let msg: String = lock.withLock {
            WebTerminalMessage.encode(WebTerminalMessage.State(cover: c, session: session, mode: grant.mode, phase: p,
                                                               reportsIgnored: reportsIgnored, keystrokeWakes: keystrokeWakes))
        }
        let fresh: Bool = lock.withLock {
            guard msg != lastState, !ended else { return false }
            lastState = msg
            return true
        }
        if fresh { await sendText(msg) }
    }

    private func sendText(_ s: String) async {
        try? await outbound.write(WebSocketFrame(fin: true, opcode: .text, data: channel.allocator.buffer(string: s)))
    }

    private func sendBinary(_ bytes: ArraySlice<UInt8>) async {
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let j = min(i + WebTerminalWire.maximumFrameBytes, bytes.endIndex)
            try? await outbound.write(WebSocketFrame(fin: true, opcode: .binary, data: channel.allocator.buffer(bytes: bytes[i..<j])))
            i = j
        }
    }

    // MARK: browser → host

    private func inboundLoop(_ inbound: NIOAsyncChannelInboundStream<WebSocketFrame>) async {
        do {
            for try await frame in inbound {
                lock.withLock { lastFrame = Date() }
                switch frame.opcode {
                case .binary:
                    if await !input(Array(frame.unmaskedData.readableBytesView)) { return }
                case .text:
                    let frameData = Data(frame.unmaskedData.readableBytesView)
                    guard let f = try? WebTerminalWire.decodeText(frameData) else {
                        await end(.policyViolation, "bad-frame")
                        return
                    }
                    if case .resize(let s) = f, grant.mode == .interactive {
                        let att: (any WebTerminalAttachment)? = lock.withLock { size = s; return attachment }
                        att?.send(ClientWire.resize(s))
                    }
                case .ping:
                    try? await outbound.write(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData))
                case .pong:
                    break
                case .connectionClose:
                    await end(.normalClosure, "closed")
                    return
                default:
                    await end(.policyViolation, "bad-frame")
                    return
                }
            }
        } catch {
            // The peer went away (or sent a frame over the cap: NIO has answered 1009 already).
        }
    }

    /// One input frame. False when the socket was closed for it.
    private func input(_ raw: [UInt8]) async -> Bool {
        guard grant.mode == .interactive else { return true }              // a watcher's bytes never reach the host
        let bytes = WebTerminalWire.sanitizeInput(raw)
        guard !bytes.isEmpty else { return true }
        let within = lock.withLock { budget.take(bytes.count) }
        guard within else {
            await end(.policyViolation, "input-over-cap")
            return false
        }
        let (att, p): ((any WebTerminalAttachment)?, String?) = lock.withLock { (attachment, phase) }
        if p == Phase.running.rawValue, let att {
            att.send(bytes)
            return true
        }
        // Not running: the 541 rule. A keystroke wakes (and is dropped — never queued for a frozen
        // guest); a control report is dropped and counted.
        switch TerminalInputClassifier.classify(Data(bytes)) {
        case .report:
            lock.withLock { reportsIgnored += 1 }
        case .keystroke:
            if hub.keystrokeWake(grant.sandbox, phase: p) { lock.withLock { keystrokeWakes += 1 } }
        }
        await pushState()
        return true
    }

    // MARK: timers

    private func watchdog() async {
        var lastSessionCheck = Date()
        while !isEnded {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            let (idle, deadlinePassed): (Bool, Bool) = lock.withLock {
                (Date().timeIntervalSince(lastFrame) > Self.idleTimeout, awaitingScreen && (screenDeadline.map { Date() >= $0 } ?? false))
            }
            if idle { await end(.goingAway, "idle"); return }
            if deadlinePassed { await pushState() }
            if Date().timeIntervalSince(lastSessionCheck) >= Self.sessionCheckInterval {
                lastSessionCheck = Date()
                if await !sessions.isValid(grant.cookie) { await end(.policyViolation, "session-ended"); return }
            }
        }
    }
}

/// A placeholder closed attachment (so `end` can tell "already ended" from "never attached").
private final class NoAttachment: WebTerminalAttachment, @unchecked Sendable {
    static let shared = NoAttachment()
    let start = WebAttachStart.attached(session: "")
    func read() async -> Data? { nil }
    func send(_ bytes: [UInt8]) {}
    func close() {}
}
