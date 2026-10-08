import Foundation
import NIOCore
import NIOWebSocket
import DozerKit
import DozerHost

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
        case .asleep, .hibernated: op = .wake
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

    /// `reason`: shutdown (doz ui stops), restarting (605: `doz ui restart` — the page reattaches), or
    /// session-ended (every session ended for a new link — the page reattaches after its sign-in).
    func closeAll(reason: String = "shutdown") async {
        for b in all { await b.end(reason == "session-ended" ? .policyViolation : .goingAway, reason) }
    }
}

/// One browser terminal.
final class WebTerminalBridge: @unchecked Sendable {
    let id = UUID()
    let grant: WebTerminalGrant
    private let data: DozerWebData
    private let hub: WebTerminalHub
    private let sessions: WebAuth
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
    // 591 — the boot view, and the wake note.
    private var bootView = false
    private var bootBytes = 0
    private var rewriteSnapshot = false
    private var wakeStart: Date?
    private var wakeVerb = "woke"
    private var notice: String?

    /// 593: the boot view's progress — animated (a spinner on the step under way, a download's bar,
    /// the bake's last output lines, redrawn in place below the finished lines) or plain (`ui.progress`).
    private let progress: ProgressTerminal
    private var progressTicker: Task<Void, Never>?

    init(grant: WebTerminalGrant, data: DozerWebData, hub: WebTerminalHub, sessions: WebAuth, channel: Channel,
         outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>, progressMode: ProgressMode = .animated) {
        progress = ProgressTerminal(mode: progressMode, color: true, plainPrefix: "[doz] ", plainStyle: "2")
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
        // 605: a reattach keeps what the terminal already shows above the screen (its scrollback).
        rewriteSnapshot = grant.reattach
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
            // 594 W18: a REattach (the host hibernated everything and went: `doz host stop`, SIGTERM,
            // idle) waits for a host — started by a wake, a CLI command or Start host — rather than
            // start one itself, which undid every host stop while a terminal was open. (Opening a
            // terminal is an explicit attach and starts one, as `doz attach` does — 591 T3.)
            if !first && !data.hostAnswers() {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let att: any WebTerminalAttachment
            do {
                att = try await data.attachTerminal(grant.sandbox, session: want.0, size: want.1)
            } catch {
                let e = HostError.from(error)
                // 591: an off (or failed) sandbox — wait for a start, showing the boot as it happens,
                // then attach to the session it boots into.
                if e.code == .invalidPhase, grant.mode == .interactive || grant.session == nil {
                    if await bootFlow(from: Phase.off.rawValue) { first = false; continue }
                    return
                }
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
            // 591: held on a sandbox that is booting — show the boot, then attach afresh (a cold boot
            // has no sessions yet: the image's own is opened once it runs).
            if case .held(_, let p) = att.start, p == Phase.booting.rawValue {
                lock.withLock { if attachment === att { attachment = nil } }
                att.close()
                if await bootFlow(from: p) { first = false; continue }
                return
            }
            first = false
            await pushState()
            // 609: the host → client stream as every viewer reads it (`ClientWire.ViewerStream`, shared with
            // `doz attach`): notices out, the end found, a notice's start held for the next read.
            var stream = ClientWire.ViewerStream()
            while let chunk = await att.read() {
                let step = stream.feed(chunk)
                // 599 (594.B1/B2): what a bridge did — a toast on the page, never bytes on the screen.
                for n in step.notices {
                    await sendText(WebTerminalMessage.encode(WebTerminalMessage.Notice(kind: n.kind, text: n.text)))
                }
                if let ending = step.ending {
                    if !step.screen.isEmpty { await sendBinary(step.screen[...]) }
                    await sendText(WebTerminalMessage.encode(WebTerminalMessage.ended(ending, text: step.endingText)))
                    await end(.normalClosure, "ended")
                    return
                }
                let out = step.screen[...]
                if !out.isEmpty {
                    // After a boot view, the first SNAPSHOT keeps the boot log in the scrollback.
                    let keep: Bool = lock.withLock {
                        defer { rewriteSnapshot = false }
                        return rewriteSnapshot
                    }
                    if keep { await sendBinary(WebTerminalWire.keepingScrollback(out)[...]) } else { await sendBinary(out) }
                    let lifted: Bool = lock.withLock {
                        guard awaitingScreen else { return false }
                        awaitingScreen = false
                        everAttached = true
                        screenDeadline = nil
                        // Bytes flow only from a running guest (the monitor may not have seen it yet).
                        setPhaseLocked(Phase.running.rawValue)
                        finishWakeLocked()
                        return true
                    }
                    if lifted { await pushState() }
                }
            }
            let held = stream.flush()
            if !held.isEmpty { await sendBinary(held[...]) }
            // Closed without the end notice: a hibernation (the guest session lives on) or a lost
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
        let before = phase
        phase = p
        phaseSince = Date()
        // 591: a wake (or resume) is timed from when this terminal first saw it to its screen back.
        let sleeping: Set<String> = [Phase.paused.rawValue, Phase.asleep.rawValue, Phase.hibernated.rawValue]
        if let before, sleeping.contains(before), p == Phase.running.rawValue {
            if wakeStart == nil { wakeStart = Date() }
            wakeVerb = before == Phase.paused.rawValue ? "resumed" : "woke"
            if !awaitingScreen { finishWakeLocked() }
        }
        if p == Phase.running.rawValue {
            if awaitingScreen { screenDeadline = Date().addingTimeInterval(Self.screenTimeout) }
        } else {
            screenDeadline = nil
        }
    }

    // MARK: the boot view (591)

    private var bootEvents: Task<Void, Never>?
    private var bootConsoleTask: Task<Void, Never>?

    /// An off, failed or booting sandbox: the cover (with Start) until a start begins; then the boot
    /// as it happens — the host's steps and progress, and the kernel's console — written into this
    /// pane as inert text; once it runs, the image's own session is opened (when this terminal asked
    /// for it) and true is returned: attach. False when the socket ended meanwhile.
    private func bootFlow(from p: String) async -> Bool {
        lock.withLock {
            setPhaseLocked(p)
            awaitingScreen = true
            screenDeadline = nil
        }
        // Follow the host's events BEFORE saying "shut down": the page starts the sandbox only once it
        // sees this terminal waiting, so no step of the start is missed.
        startBootEvents()
        await pushState()
        let name = grant.sandbox
        while !isEnded {
            startBootEvents()
            let ph = lock.withLock { phase }
            if ph == Phase.booting.rawValue || hub.runningAction(name) == "start" { await enterBootView() }
            if ph == Phase.running.rawValue { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if isEnded { await stopBootStreams(); return false }
        if lock.withLock({ bootView }) {
            // A boot too quick for its step to be seen: the console still shows (from its start).
            startBootConsole()
            try? await Task.sleep(for: .milliseconds(500))
        }
        if grant.session == nil {
            do {
                let r = try await data.perform(HostRequest(.openSession, name: name)) { _ in }
                if let s = try? r.decode(SessionOpened.self) { lock.withLock { session = s.session } }
            } catch {
                await bootWrite("[doz] could not open the session: \(HostError.from(error).message)", dim: true)
            }
        }
        await stopBootStreams()
        if lock.withLock({ bootView }) {
            let s = lock.withLock { session } ?? "default"
            await bootWrite("── the \(s) session ──", dim: false, bold: true)
            // The page scrolls the terminal's screen (the end of the boot log) into its scrollback.
            await sendText(#"{"t":"boot-done"}"#)
            lock.withLock {
                bootView = false
                rewriteSnapshot = true
            }
        }
        return true
    }

    private func enterBootView() async {
        let first: Bool = lock.withLock {
            guard !bootView else { return false }
            bootView = true
            return true
        }
        guard first else { return }
        await pushState()
        await bootWrite("── starting \(grant.sandbox) ──", dim: false, bold: true)
    }

    private func startBootEvents() {
        guard lock.withLock({ bootEvents == nil }), let stream = data.hostEvents() else { return }
        let name = grant.sandbox
        let t = Task { [weak self] in
            for await e in stream where e.sandbox == name {
                guard let self else { return }
                switch e.kind {
                case .phase:
                    if let ph = e.phase {
                        let changed: Bool = self.lock.withLock {
                            let before = self.phase
                            self.setPhaseLocked(ph)
                            return before != self.phase
                        }
                        if ph == Phase.booting.rawValue { await self.enterBootView() }
                        if changed { await self.pushState() }
                    }
                case .step, .note, .started, .failed, .progress, .output:
                    // 593: through the progress view — finished lines into the scrollback, the live
                    // block (animated) redrawn beneath them.
                    guard self.lock.withLock({ self.bootView }) else { continue }
                    await self.bootProgress(e)
                    if e.kind == .step, (e.text ?? "").contains("VM created") { self.startBootConsole() }
                default:
                    continue
                }
            }
            self?.lock.withLock { self?.bootEvents = nil }
        }
        lock.withLock { if bootEvents == nil { bootEvents = t } else { t.cancel() } }
    }

    private func startBootConsole() {
        guard lock.withLock({ bootConsoleTask == nil }), let stream = data.bootConsole(grant.sandbox) else { return }
        let t = Task { [weak self] in
            for await line in stream { await self?.bootWrite(line, dim: false) }
        }
        lock.withLock { if bootConsoleTask == nil { bootConsoleTask = t } else { t.cancel() } }
    }

    /// Stop the boot streams AND wait for their last writes, so nothing of the boot lands after the
    /// switch into the session.
    private func stopBootStreams() async {
        let (a, b, c): (Task<Void, Never>?, Task<Void, Never>?, Task<Void, Never>?) = lock.withLock {
            defer { bootEvents = nil; bootConsoleTask = nil; progressTicker = nil }
            return (bootEvents, bootConsoleTask, progressTicker)
        }
        a?.cancel()
        b?.cancel()
        c?.cancel()
        await a?.value
        await b?.value
        await c?.value
        // 593: nothing stays live — what was under way becomes finished lines; the block is erased.
        let tail = lock.withLock { progress.finish() }
        if !tail.isEmpty { await sendBinary(Array(tail.utf8)[...]) }
    }

    /// 593: an event through the progress view. The live block ticks (a spinner frame every 120 ms)
    /// while anything is under way; the bytes of FINISHED lines count against the boot view's cap.
    private func bootProgress(_ e: HostEvent) async {
        let out: String = lock.withLock {
            guard bootBytes < WebTerminalWire.maximumBootBytes else { return "" }
            progress.width = size.cols > 0 ? Int(size.cols) : 80
            let s = progress.apply(e)
            bootBytes += e.kind == .output || e.kind == .progress || e.kind == .started ? 0 : (e.text?.utf8.count ?? 0) + 8
            return s
        }
        if !out.isEmpty { await sendBinary(Array(out.utf8)[...]) }
        startProgressTicker()
    }

    private func startProgressTicker() {
        guard progress.mode == .animated else { return }
        let start: Bool = lock.withLock {
            guard progressTicker == nil, progress.board.isLive else { return false }
            return true
        }
        guard start else { return }
        let t = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, !Task.isCancelled else { return }
                let out: String = self.lock.withLock {
                    self.progress.width = self.size.cols > 0 ? Int(self.size.cols) : 80
                    return self.bootView ? self.progress.tick() : ""
                }
                if !out.isEmpty { await self.sendBinary(Array(out.utf8)[...]) }
                let live = self.lock.withLock { self.progress.board.isLive || self.progress.hasBlock }
                if !live { break }
            }
            self?.lock.withLock { self?.progressTicker = nil }
        }
        lock.withLock { if progressTicker == nil { progressTicker = t } else { t.cancel() } }
    }

    /// One line of the boot view: inert text (no control character survives), capped per line and in all.
    private func bootWrite(_ text: String, dim: Bool, bold: Bool = false) async {
        let line = WebTerminalWire.bootText(text)
        let state: Int = lock.withLock {
            guard bootBytes < WebTerminalWire.maximumBootBytes else { return 0 }
            bootBytes += line.utf8.count + 2
            return bootBytes >= WebTerminalWire.maximumBootBytes ? 2 : 1
        }
        guard state > 0 else { return }
        let text = state == 2 ? "[doz] the boot view stops here (1 MiB) — doz console \(grant.sandbox) has the rest" : line
        let style = bold ? "\u{1B}[1m" : dim ? "\u{1B}[2m" : ""
        // 593: through the progress view, so its live block stays beneath every finished line.
        let out = lock.withLock {
            progress.width = size.cols > 0 ? Int(size.cols) : 80
            return progress.write([.raw(style + text + (style.isEmpty ? "" : "\u{1B}[0m"))])
        }
        await sendBinary(Array(out.utf8)[...])
    }

    /// Caller holds `lock`: the one-line "woke in N s" for the page.
    private func finishWakeLocked() {
        guard let s = wakeStart else { return }
        wakeStart = nil
        notice = String(format: "%@ in %.1f s", wakeVerb, Date().timeIntervalSince(s))
    }

    /// A phase seen by the monitor. While this terminal is attached and has its screen, a hibernation
    /// or a shutdown would have closed the connection — such a report is stale and ignored.
    func monitorPhase(_ p: String) {
        let changed: Bool = lock.withLock {
            let live = attachment != nil && !awaitingScreen
            if live, p == Phase.hibernated.rawValue || p == Phase.off.rawValue || p == Phase.failed.rawValue { return false }
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
            if action == "wake" || action == "resume", wakeStart == nil { wakeStart = Date() }
            if bootView { return (WebTerminalCover.boot, phase) }
            let screenBack = !awaitingScreen || (screenDeadline.map { Date() >= $0 } ?? false)
            let c = WebTerminalCover.derive(phase: phase, since: phaseSince, action: action, screenBack: screenBack,
                                            everAttached: everAttached, watch: grant.mode == .watch)
            return (c, phase)
        }
    }

    private func pushState() async {
        let (c, p) = cover()
        let msg: String = lock.withLock {
            var s = WebTerminalMessage.State(cover: c, session: session, mode: grant.mode, phase: p,
                                             reportsIgnored: reportsIgnored, keystrokeWakes: keystrokeWakes)
            s.notice = notice
            notice = nil
            return WebTerminalMessage.encode(s)
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
        // The budget counts every byte a page sends, watch-only included (a flood is a flood).
        let within = lock.withLock { budget.take(raw.count) }
        guard within else {
            await end(.policyViolation, "input-over-cap")
            return false
        }
        guard grant.mode == .interactive else { return true }              // a watcher's bytes never reach the host
        let bytes = WebTerminalWire.sanitizeInput(raw)
        guard !bytes.isEmpty else { return true }
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
            if hub.keystrokeWake(grant.sandbox, phase: p) {
                lock.withLock {
                    keystrokeWakes += 1
                    if wakeStart == nil { wakeStart = Date() }
                }
            }
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
