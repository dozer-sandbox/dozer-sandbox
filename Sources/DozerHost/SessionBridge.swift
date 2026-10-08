import Foundation

// 599 (594.B1/B2) — the session bridges' reader. Every terminal (`doz attach`/`run`/`up`, every `doz ui`
// pane) reaches a session through the host's attach relay, so the host reads the session's output ONCE,
// there, for the two escape sequences a bridge owns, and REMOVES them from what the viewer gets:
//
//   OSC 52   `ESC ] 52 ; <selection> ; <base64> (BEL | ESC \)` — a program copying (Claude Code, vim,
//            tmux with set-clipboard). The host sets the Mac pasteboard (`sandbox.clipboard`). A READ
//            (`?` as the data) is never answered: it never reaches the outer terminal either, so no
//            terminal can answer it on the sandbox's behalf.
//   OSC 6340 `ESC ] 6340 ; doz-open ; <url> (BEL | ESC \)` — the guest's xdg-open shim asking for a
//            URL in the Mac's browser (DeckStack's marker technique; `sandbox.browser_bridge`).
//            599b: `ESC ] 6340 ; doz-file ; <app> ; <path> …` — the same shim asking for a /workspace
//            file in the Mac's default app (or a named one) (`sandbox.open_files`, `WorkspaceFiles`).
//
// Every other byte passes through unchanged (other OSCs included). A sequence cut by a read is held until
// the next; one too long is dropped whole (said as an event), never passed through.

/// What a session's output asked of the host.
public enum BridgeEvent: Equatable, Sendable {
    /// OSC 52 write: the decoded bytes.
    case copy(Data)
    /// OSC 52 read (`?`): refused, always.
    case copyRead
    /// OSC 52 larger than `SessionBridgeScanner.maximumCopyBytes` decoded (its encoded size).
    case copyTooLarge(encodedBytes: Int)
    /// The xdg-open shim's URL (not yet checked — the host decides).
    case openURL(String)
    /// An open request longer than `maximumURLBytes`.
    case openTooLong
    /// 599b: the shim's workspace file (`doz-file;APP;PATH` — the guest's absolute path, and the app it
    /// named, nil: the default app). Not yet checked — the host decides (`WorkspaceFiles`).
    case openFile(path: String, app: String?)
    /// 599b: `doz-open --reveal PATH` (`doz-reveal;PATH`) — shown selected in its folder in the Finder.
    case revealFile(path: String)
}

public struct SessionBridgeScanner: Sendable {
    /// The most one copy may carry, decoded (1 MiB).
    public static let maximumCopyBytes = 1 << 20
    /// Base64 of that, plus the selection field.
    static let maximumCopyEncoded = (maximumCopyBytes + 2) / 3 * 4 + 64
    /// The shim's own cap (DeckStack's 2048), plus `doz-open;`.
    public static let maximumURLBytes = 2048
    static let maximumOpenBody = maximumURLBytes + 16

    private enum Kind: Sendable { case copy, open }
    private enum State: Sendable {
        case ground
        /// Held: ESC, ESC ], ESC ] 5 … — maybe the start of one of ours.
        case prefix
        case body(Kind)
        /// ESC seen inside a body: `\` ends it (ST).
        case bodyEsc(Kind)
        /// Too long: skipped to its terminator.
        case discard(Kind, Int)
        case discardEsc(Kind, Int)
    }

    private static let copyPrefix = Array("\u{1B}]52;".utf8)
    private static let openPrefix = Array("\u{1B}]6340;".utf8)

    private var state: State = .ground
    private var held: [UInt8] = []
    private var body: [UInt8] = []

    public init() {}

    /// A snapshot (or a new connection) starts clean: anything held is dropped.
    public mutating func reset() {
        state = .ground
        held = []
        body = []
    }

    /// Output bytes → what the viewer gets, and what the host was asked.
    public mutating func feed<S: Sequence>(_ bytes: S) -> (out: [UInt8], events: [BridgeEvent]) where S.Element == UInt8 {
        var out: [UInt8] = []
        var events: [BridgeEvent] = []
        for b in bytes { step(b, &out, &events) }
        return (out, events)
    }

    private mutating func step(_ b: UInt8, _ out: inout [UInt8], _ events: inout [BridgeEvent]) {
        switch state {
        case .ground:
            if b == 0x1B { held = [b]; state = .prefix } else { out.append(b) }
        case .prefix:
            held.append(b)
            if held == Self.copyPrefix { state = .body(.copy); body = []; held = []; return }
            if held == Self.openPrefix { state = .body(.open); body = []; held = []; return }
            if Self.copyPrefix.starts(with: held) || Self.openPrefix.starts(with: held) { return }
            // Not ours: everything held goes through — except a trailing ESC, which may start one.
            if b == 0x1B {
                out += held.dropLast()
                held = [0x1B]
            } else {
                out += held
                held = []
                state = .ground
            }
        case .body(let k):
            switch b {
            case 0x07: finish(k, &events)
            case 0x1B: state = .bodyEsc(k)
            case 0x18, 0x1A: state = .ground; body = []                    // CAN / SUB abort a string
            default:
                body.append(b)
                let limit = k == .copy ? Self.maximumCopyEncoded : Self.maximumOpenBody
                if body.count > limit { state = .discard(k, body.count); body = [] }
            }
        case .bodyEsc(let k):
            if b == UInt8(ascii: "\\") { finish(k, &events); return }
            // An ESC that is not ST aborts the string (as a terminal does) and starts a new sequence.
            body = []
            state = .ground
            step(0x1B, &out, &events)
            step(b, &out, &events)
        case .discard(let k, let n):
            switch b {
            case 0x07: discarded(k, n + 1, &events)
            case 0x1B: state = .discardEsc(k, n + 1)
            case 0x18, 0x1A: state = .ground
            default: state = .discard(k, n + 1)
            }
        case .discardEsc(let k, let n):
            if b == UInt8(ascii: "\\") { discarded(k, n + 1, &events); return }
            discarded(k, n, &events)
            step(0x1B, &out, &events)
            step(b, &out, &events)
        }
    }

    private mutating func discarded(_ k: Kind, _ n: Int, _ events: inout [BridgeEvent]) {
        state = .ground
        events.append(k == .copy ? .copyTooLarge(encodedBytes: n) : .openTooLong)
    }

    private mutating func finish(_ k: Kind, _ events: inout [BridgeEvent]) {
        state = .ground
        let text = String(decoding: body, as: UTF8.self)
        body = []
        switch k {
        case .copy:
            // `<selection>;<data>` — the selection (c, p, s, 0–7 or empty) is not ours to honour: the Mac has one.
            guard let semi = text.firstIndex(of: ";") else { return }
            let data = String(text[text.index(after: semi)...])
            if data == "?" { events.append(.copyRead); return }
            guard !data.isEmpty, let bytes = Self.base64(data) else { return }        // a clear, or garbage: nothing
            if bytes.count > Self.maximumCopyBytes { events.append(.copyTooLarge(encodedBytes: data.utf8.count)); return }
            events.append(.copy(bytes))
        case .open:
            // 599b: `doz-file;APP;PATH` — APP has no `;` (the shim and the host both refuse one); the path
            // is everything after it.
            if text.hasPrefix("doz-file;") {
                let rest = text.dropFirst("doz-file;".count)
                guard let semi = rest.firstIndex(of: ";") else { return }
                let app = String(rest[..<semi])
                let path = String(rest[rest.index(after: semi)...])
                if path.utf8.count > Self.maximumURLBytes { events.append(.openTooLong); return }
                if !path.isEmpty { events.append(.openFile(path: path, app: app.isEmpty ? nil : app)) }
                return
            }
            if text.hasPrefix("doz-reveal;") {
                let path = String(text.dropFirst("doz-reveal;".count))
                if path.utf8.count > Self.maximumURLBytes { events.append(.openTooLong); return }
                if !path.isEmpty { events.append(.revealFile(path: path)) }
                return
            }
            guard text.hasPrefix("doz-open;") else { return }
            let url = String(text.dropFirst("doz-open;".count))
            if url.utf8.count > Self.maximumURLBytes { events.append(.openTooLong); return }
            if !url.isEmpty { events.append(.openURL(url)) }
        }
    }

    /// Base64 as terminals accept it: padding optional, no whitespace.
    static func base64(_ s: String) -> Data? {
        var t = s
        let r = t.utf8.count % 4
        if r == 1 { return nil }
        if r > 0 { t += String(repeating: "=", count: 4 - r) }
        return Data(base64Encoded: t)
    }
}

/// What the host did about a bridge event, as each viewer is told (`ClientWire.notice`).
public struct BridgeNotice: Equatable, Sendable {
    /// `clipboard`, `clipboard-off`, `clipboard-refused`, `open`, `open-refused`, `oauth`; 599b: `file`,
    /// `file-off`, `file-refused`.
    public var kind: String
    public var text: String
    public init(_ kind: String, _ text: String) { self.kind = kind; self.text = text }
}

/// 599 (594.B1): the Mac's pasteboard — `/usr/bin/pbcopy`, or (tests) a file: `DOZ_TEST_PASTEBOARD=<path>`
/// makes the host write each copy there instead, so no test ever touches the real clipboard.
public enum MacPasteboard {
    public static func write(_ data: Data, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let seam = environment["DOZ_TEST_PASTEBOARD"], !seam.isEmpty {
            return FileManager.default.createFile(atPath: seam, contents: data)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        pipe.fileHandleForWriting.write(data)
        try? pipe.fileHandleForWriting.close()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

/// A sliding-window limit: at most `count` in `window` seconds, per key.
final class BridgeRateLimit: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [String: [Date]] = [:]
    let count: Int
    let window: TimeInterval
    init(count: Int, window: TimeInterval) { self.count = count; self.window = window }

    func allow(_ key: String, now: Date = Date()) -> Bool {
        lock.withLock {
            var t = (times[key] ?? []).filter { now.timeIntervalSince($0) < window }
            guard t.count < count else { times[key] = t; return false }
            t.append(now)
            times[key] = t
            return true
        }
    }
}

/// The bridges' shared state in the host: rate limits, recent actions (two viewers of one session see
/// every sequence twice — the host acts once), and which sessions already had a read refusal logged.
final class BridgeState: @unchecked Sendable {
    private let lock = NSLock()
    let copies = BridgeRateLimit(count: 10, window: 10)
    let opens = BridgeRateLimit(count: 3, window: 10)
    /// 599b: workspace files opened on the Mac — their own limit, so a burst of files never costs a sign-in.
    let fileOpens = BridgeRateLimit(count: WorkspaceFiles.rateCount, window: WorkspaceFiles.rateWindow)
    private var recent: [String: (Date, BridgeNotice)] = [:]
    private var readLogged: Set<String> = []

    /// The notice of the same action done within `within` seconds, if there was one.
    func recentNotice(_ key: String, within: TimeInterval, now: Date = Date()) -> BridgeNotice? {
        lock.withLock {
            recent = recent.filter { now.timeIntervalSince($0.value.0) < 30 }
            guard let r = recent[key], now.timeIntervalSince(r.0) < within else { return nil }
            return r.1
        }
    }

    func remember(_ key: String, _ n: BridgeNotice, now: Date = Date()) { lock.withLock { recent[key] = (now, n) } }

    /// Do `act` once for `key` within `within` seconds: the second viewer of a session (reading the same
    /// sequence at the same moment) waits for the first and gets its notice. `fresh`: this call acted.
    private let acting = NSLock()
    func once(_ key: String, within: TimeInterval, _ act: () -> BridgeNotice) -> (notice: BridgeNotice, fresh: Bool) {
        acting.lock(); defer { acting.unlock() }
        if let done = recentNotice(key, within: within) { return (done, false) }
        let n = act()
        remember(key, n)
        return (n, true)
    }

    /// True the first time for this sandbox+session.
    func firstRead(_ key: String) -> Bool { lock.withLock { readLogged.insert(key).inserted } }

    /// 599 (B2): each sandbox's sign-in callback forward (one at a time: a new one replaces it).
    private var forwards: [String: LoopbackForward] = [:]
    /// Keep `f` as `sandbox`'s forward; the one it replaces is returned (to be stopped).
    func setForward(_ f: LoopbackForward, for sandbox: String) -> LoopbackForward? {
        lock.withLock { let old = forwards[sandbox]; forwards[sandbox] = f; return old }
    }
    func forwardEnded(_ f: LoopbackForward) { lock.withLock { if forwards[f.sandbox] === f { forwards[f.sandbox] = nil } } }
    func forward(of sandbox: String) -> LoopbackForward? { lock.withLock { forwards[sandbox] } }

    // MARK: 599d — notices that do not come from a session's output (the GitHub login, the SSH agent)

    /// Every terminal attached to each sandbox right now (the attach relay registers them).
    private var viewers: [String: [ObjectIdentifier: HostConnection]] = [:]
    func addViewer(_ sandbox: String, _ c: HostConnection) { lock.withLock { viewers[sandbox, default: [:]][ObjectIdentifier(c)] = c } }
    func removeViewer(_ sandbox: String, _ c: HostConnection) { lock.withLock { viewers[sandbox]?[ObjectIdentifier(c)] = nil } }

    /// Tell every terminal attached to `sandbox`; false: none is (the host log still has it).
    @discardableResult
    func notifyViewers(_ sandbox: String, _ n: BridgeNotice) -> Bool {
        let cs = lock.withLock { Array((viewers[sandbox] ?? [:]).values) }
        for c in cs { _ = c.write(ClientWire.notice(n)) }
        return !cs.isEmpty
    }

    /// "sandbox|what" announced since the setup was last applied.
    private var announced: Set<String> = []
    /// True the first time `what` is used by `sandbox` since `resetFirstUse`.
    func firstUse(_ sandbox: String, _ what: String) -> Bool { lock.withLock { announced.insert(sandbox + "|" + what).inserted } }
    func resetFirstUse(_ sandbox: String) { lock.withLock { announced = announced.filter { !$0.hasPrefix(sandbox + "|") } } }
}

/// 609: which viewer set each session's size last. A session has ONE size, and the attach relay's viewers
/// each send theirs (an attach's HELLO, a RESIZE when their terminal changes) — the last one wins. A viewer
/// that types while another viewer's size is in force first re-applies its own (`takeForInput`): the
/// terminal a person types in is the one the program draws for. Keyed "sandbox|session"; a watcher (0×0)
/// never claims. Same-size re-applies are harmless (no SIGWINCH; the viewer gets a fresh snapshot).
public final class SessionSizeOwners: @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [String: ObjectIdentifier] = [:]
    public init() {}
    /// `who` just set `key`'s size.
    public func claim(_ key: String, _ who: ObjectIdentifier) { lock.withLock { owners[key] = who } }
    /// `who` is about to type into `key`: true (and `who` now owns it) when someone else set the size since.
    public func takeForInput(_ key: String, _ who: ObjectIdentifier) -> Bool {
        lock.withLock {
            if owners[key] == who { return false }
            owners[key] = who
            return true
        }
    }
}
