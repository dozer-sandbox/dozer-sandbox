import Foundation
import DozerKit
import DozerHost

// 591 — the terminal socket's frames, the input rules, the 541 classifier and the cover, as pure
// code (591.01-DESIGN.md §4.3, §5). The bridge (WebTerminalBridge.swift) wires them to a socket.

/// What the browser may send. Binary frames are input; text frames are a closed set of JSON messages.
public enum WebTerminalClientFrame: Equatable, Sendable {
    case input([UInt8])
    case resize(TermSize)
    case ping
}

public enum WebTerminalWire {
    /// The largest frame (and reassembled message) the browser may send.
    public static let maximumFrameBytes = 64 * 1024

    public struct Violation: Error, Equatable, Sendable {
        public let reason: String
        init(_ r: String) { reason = r }
    }

    /// A text frame, decoded STRICTLY: `{"t":"resize","cols":C,"rows":R}` or `{"t":"ping"}` —
    /// nothing else, no extra field, whole numbers in range.
    public static func decodeText(_ data: Data) throws -> WebTerminalClientFrame {
        guard let obj = try? JSONSerialization.jsonObject(with: data), let d = obj as? [String: Any], let t = d["t"] as? String else {
            throw Violation("not a terminal message")
        }
        func whole(_ key: String, _ range: ClosedRange<Int>) throws -> Int {
            guard let n = d[key] as? NSNumber, CFGetTypeID(n) == CFNumberGetTypeID(), !CFNumberIsFloatType(n), range.contains(n.intValue) else {
                throw Violation("\(key) out of range")
            }
            return n.intValue
        }
        switch t {
        case "ping":
            guard d.count == 1 else { throw Violation("unexpected fields") }
            return .ping
        case "resize":
            guard Set(d.keys) == ["t", "cols", "rows"] else { throw Violation("unexpected fields") }
            return .resize(TermSize(cols: UInt16(try whole("cols", WebTerminalTicketRequest.colsRange)),
                                    rows: UInt16(try whole("rows", WebTerminalTicketRequest.rowsRange))))
        default:
            throw Violation("unknown message")
        }
    }

    /// Input bytes with every 0xFF removed: the attach wire's in-band frames start with 0xFF (which
    /// never occurs in UTF-8), so a page must not be able to forge a HELLO or RESIZE through input.
    public static func sanitizeInput(_ bytes: [UInt8]) -> [UInt8] { bytes.filter { $0 != 0xFF } }

    /// How many trailing bytes might be the start of the host's ended notice (held for the next read,
    /// so the notice is recognised even when a read splits it). The CLI's `AttachClient.holdBack`,
    /// plus the `ESC[0m` the notice starts with (so no piece of the notice reaches the screen; what
    /// is held is at most an SGR reset, sent with the next read).
    /// 609: the one rule every viewer uses (`ClientWire.holdBack`).
    public static func holdBack(_ bytes: [UInt8]) -> Int { ClientWire.holdBack(bytes) }

    // MARK: 591 — the boot view

    /// The most the boot view writes into one pane (the console is guest-written).
    public static let maximumBootBytes = 1 << 20
    public static let maximumBootLineBytes = 1000

    /// One line of the boot view as inert text: every control character (C0 but tab, ESC, DEL, C1)
    /// is removed, so guest-written console text can never be an escape sequence — no OSC 8 link,
    /// no OSC 52, no mode change — and the line is capped.
    public static func bootText(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var bytes = 0
        for u in s.unicodeScalars {
            if (u.value < 0x20 && u.value != 0x09) || (0x7F...0x9F).contains(u.value) { continue }
            bytes += String(u).utf8.count
            if bytes > maximumBootLineBytes { break }
            out.append(u == "\t" ? " " : u)
        }
        return String(out)
    }

    /// deckhold's SNAPSHOT starts by resetting the viewer and clearing its scrollback. After a boot
    /// view the scrollback holds the boot log, so the FIRST snapshot's prefix is rewritten to a soft
    /// reset + home + clear SCREEN (never the full reset, never ED 3). Before it, the page tells the
    /// terminal to scroll its screen into the scrollback (`boot-done`): only the terminal knows its
    /// real height.
    public static let snapshotPrefix: [UInt8] = Array("\u{1B}[?1049l\u{1B}c\u{1B}[H\u{1B}[2J\u{1B}[3J".utf8)
    public static func keepingScrollback(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        guard bytes.starts(with: snapshotPrefix) else { return Array(bytes) }
        return Array("\u{1B}[?1049l\u{1B}[!p\u{1B}[0m\u{1B}[H\u{1B}[2J".utf8) + bytes.dropFirst(snapshotPrefix.count)
    }

    /// The host's line after the notice ("[doz] the shell session has ended (exit 0)"), without the tag.
    public static func endingText(_ bytes: ArraySlice<UInt8>) -> String { ClientWire.endingText(bytes) }
}

/// 591 — the inbound byte budget of one terminal: a burst, refilled at a steady rate. Paste goes
/// through the page's own cap (1 MiB) first; this is the server's wall against a page that floods.
public struct WebInputBudget: Sendable {
    public let burst: Double
    public let perSecond: Double
    private var available: Double
    private var last: Date

    public init(burst: Int = 1 << 20, perSecond: Int = 256 << 10, now: Date = Date()) {
        self.burst = Double(burst)
        self.perSecond = Double(perSecond)
        available = Double(burst)
        last = now
    }

    /// Spend `n` bytes; false when over the budget.
    public mutating func take(_ n: Int, now: Date = Date()) -> Bool {
        available = min(burst, available + max(0, now.timeIntervalSince(last)) * perSecond)
        last = now
        guard Double(n) <= available else { return false }
        available -= Double(n)
        return true
    }
}

/// What one write from a terminal IS: a person typing, or the terminal answering a question the
/// program asked it.
public enum TerminalInputClass: String, Sendable, Equatable {
    /// A person did something at the keyboard — the only class that may wake a sleeping sandbox.
    case keystroke
    /// A terminal CONTROL REPORT: focus in/out, a cursor-position answer, a device-attribute reply,
    /// a mouse report, a bare bracketed-paste bracket. Nobody typed.
    case report
}

/// 591 — the 541 rule in the web UI: a keystroke wakes a paused or sleeping sandbox, the terminal's
/// own control reports never do. SandboxLab's `TerminalInputClassifier` (581), ported unchanged (an
/// app is never imported by a library): a pure function over ONE write. A well-formed report is a
/// report; everything else — printable bytes, control characters, a lone ESC, arrows, function keys,
/// Alt-chords, kitty key events, anything truncated or unrecognised — is a keystroke. It errs towards
/// keystroke: a misread report costs a wake, a misread keystroke would lose a key.
public enum TerminalInputClassifier {
    /// Classifies one write. Empty data is a `.report` (nothing to wake for).
    public static func classify(_ data: Data) -> TerminalInputClass {
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            guard bytes[i] == 0x1B, let next = escapeSequenceEnd(bytes, from: i) else { return .keystroke }
            i = next
        }
        return .report
    }

    /// The index just past a complete REPORT starting at `start`, or nil for a keystroke.
    private static func escapeSequenceEnd(_ b: [UInt8], from start: Int) -> Int? {
        guard start + 1 < b.count else { return nil }                 // a lone ESC is the Esc key
        switch b[start + 1] {
        case 0x5B: return csiEnd(b, from: start + 2)                   // CSI
        case 0x5D: return stringEnd(b, from: start + 2, bel: true)     // OSC reply
        case 0x50, 0x58, 0x5E, 0x5F: return stringEnd(b, from: start + 2, bel: false)   // DCS / SOS / PM / APC
        default: return nil                                            // SS3 arrows, Alt-chords
        }
    }

    private static func csiEnd(_ b: [UInt8], from start: Int) -> Int? {
        var i = start
        var params: [UInt8] = []
        while i < b.count, (0x30...0x3F).contains(b[i]) { params.append(b[i]); i += 1 }
        var inter: [UInt8] = []
        while i < b.count, (0x20...0x2F).contains(b[i]) { inter.append(b[i]); i += 1 }
        guard i < b.count, (0x40...0x7E).contains(b[i]) else { return nil }
        let final = b[i]
        let prefix = params.first.flatMap { (0x3C...0x3F).contains($0) ? $0 : nil }
        let digits = Array(params.drop { (0x3C...0x3F).contains($0) })
        // X10 mouse: `CSI M` + three raw bytes.
        if final == 0x4D, params.isEmpty, inter.isEmpty { return i + 3 < b.count ? i + 4 : nil }
        return isReport(prefix: prefix, digits: digits, inter: inter, final: final) ? i + 1 : nil
    }

    private static func isReport(prefix: UInt8?, digits: [UInt8], inter: [UInt8], final: UInt8) -> Bool {
        let numeric = !digits.isEmpty && digits.allSatisfy { (0x30...0x39).contains($0) || $0 == 0x3B }
        switch final {
        case 0x49, 0x4F: return prefix == nil && digits.isEmpty && inter.isEmpty          // focus in / out
        case 0x52: return prefix == nil && numeric && inter.isEmpty                      // cursor position
        case 0x6E: return (prefix == nil || prefix == 0x3F) && numeric && inter.isEmpty  // device status
        case 0x63: return prefix == 0x3F || prefix == 0x3E || prefix == 0x3D             // device attributes reply
        case 0x7E: return prefix == nil && inter.isEmpty && (digits == Array("200".utf8) || digits == Array("201".utf8))
        case 0x79: return prefix == 0x3F && inter == [0x24]                              // DECRPM
        case 0x75: return prefix == 0x3F                                                 // kitty flags reply (not a key event)
        case 0x74: return prefix == nil && numeric && inter.isEmpty                      // XTWINOPS
        case 0x4D, 0x6D: return prefix == 0x3C && numeric && inter.isEmpty              // SGR mouse
        case 0x53: return prefix == 0x3F && numeric                                      // XTSMGRAPHICS
        default: return false
        }
    }

    private static func stringEnd(_ b: [UInt8], from start: Int, bel: Bool) -> Int? {
        var i = start
        while i < b.count {
            if bel, b[i] == 0x07 { return i + 1 }
            if b[i] == 0x9C { return i + 1 }
            if b[i] == 0x1B {
                guard i + 1 < b.count, b[i + 1] == 0x5C else { return nil }
                return i + 2
            }
            i += 1
        }
        return nil
    }
}

/// 591 — what covers a terminal: nothing while the sandbox runs and the screen is back; the state and
/// its one action while it is paused, asleep, hibernated or shut down; a spinner while something is
/// in flight. SandboxLab's `PaneCover` (581), ported — the same states, the same wording.
public struct WebTerminalCover: Equatable, Encodable, Sendable {
    public enum Kind: String, Encodable, Sendable {
        case none, paused, asleep, hibernated, shutDown, failed, working, reattaching
        /// 591: the boot view — no cover; the pane itself shows the boot as it happens.
        case boot
    }

    static let boot = WebTerminalCover(kind: .boot, headline: "", detail: nil, action: nil, spinner: false, since: nil, elapsedVerb: nil)
    public enum Action: String, Encodable, Sendable { case resume = "Resume", wake = "Wake", start = "Start" }

    public let kind: Kind
    public let headline: String
    /// The line under it, without the elapsed time (the page adds "asleep 7 min" from `since`).
    public let detail: String?
    public let action: Action?
    public let spinner: Bool
    public let since: Date?
    /// The verb for the elapsed time ("paused", "asleep"), when there is one.
    public let elapsedVerb: String?

    public var isVisible: Bool { kind != .none }

    /// Pure: the phase (a `Phase` raw value; nil = not known yet), when it began, the lifecycle
    /// operation in flight on the sandbox (the web action's verb), whether this terminal has its
    /// screen, whether it ever had one, and whether it is watch-only (a watcher's keys never wake).
    public static func derive(phase: String?, since: Date?, action: String?, screenBack: Bool, everAttached: Bool,
                              watch: Bool, hasRootDisk: Bool = true) -> WebTerminalCover {
        if let action, let label = workingLabel(action) { return working(label) }
        guard let phase, let p = Phase(rawValue: phase) else {
            return WebTerminalCover(kind: .reattaching, headline: "Attaching…", detail: nil, action: nil, spinner: true, since: nil, elapsedVerb: nil)
        }
        let key = watch ? "" : " · press any key to "
        switch p {
        case .running:
            if screenBack { return WebTerminalCover(kind: .none, headline: "", detail: nil, action: nil, spinner: false, since: nil, elapsedVerb: nil) }
            return WebTerminalCover(kind: .reattaching, headline: everAttached ? "Reattaching…" : "Attaching…", detail: nil, action: nil,
                                    spinner: true, since: nil, elapsedVerb: nil)
        case .paused:
            return WebTerminalCover(kind: .paused, headline: "Sandbox paused" + (watch ? "" : key + "resume"), detail: "CPUs frozen, RAM kept",
                                    action: .resume, spinner: false, since: since, elapsedVerb: "paused")
        case .asleep:
            return WebTerminalCover(kind: .asleep, headline: "Sandbox asleep" + (watch ? "" : key + "wake"), detail: "RAM kept, state saved to disk",
                                    action: .wake, spinner: false, since: since, elapsedVerb: "asleep")
        case .hibernated:
            return WebTerminalCover(kind: .hibernated, headline: "Sandbox hibernated" + (watch ? "" : key + "wake"),
                                    detail: "RAM freed, state on disk — every process comes back", action: .wake, spinner: false, since: since,
                                    elapsedVerb: "hibernated")
        case .off:
            return WebTerminalCover(kind: .shutDown, headline: "Sandbox shut down",
                                    detail: hasRootDisk ? "The disk is kept; Start cold-boots it." : "Start boots a fresh copy of the image.",
                                    action: .start, spinner: false, since: nil, elapsedVerb: nil)
        case .booting:
            return working("Starting the sandbox…")
        case .failed:
            return WebTerminalCover(kind: .failed, headline: "The sandbox failed to start", detail: "See Activity; Start tries again.",
                                    action: .start, spinner: false, since: nil, elapsedVerb: nil)
        }
    }

    static func working(_ label: String) -> WebTerminalCover {
        WebTerminalCover(kind: .working, headline: label, detail: nil, action: nil, spinner: true, since: nil, elapsedVerb: nil)
    }

    /// Only the operations that change what the terminal can do get a spinner (a restore point taken
    /// while running freezes the guest for milliseconds — not worth a cover). The web action verbs.
    public static func workingLabel(_ action: String) -> String? {
        switch action {
        case "start": "Starting the sandbox…"
        case "wake": "Waking the sandbox…"
        case "resume": "Resuming…"
        case "pause": "Pausing…"
        case "sleep": "Going to sleep…"
        case "hibernate": "Hibernating…"
        case "shutdown": "Shutting down…"
        case "reset": "Resetting to the image…"
        case "rm": "Deleting the sandbox…"
        case "point-revert": "Reverting…"
        default: nil
        }
    }
}

/// UI → browser text frames.
enum WebTerminalMessage {
    struct State: Encodable {
        let t = "state"
        let cover: WebTerminalCover
        let session: String?
        let mode: WebTerminalMode
        let phase: String?
        let reportsIgnored: Int
        let keystrokeWakes: Int
        /// 591: a one-line note the page shows briefly ("woke in 0.4 s").
        var notice: String? = nil
    }
    struct Ended: Encodable {
        let t = "ended"
        let ending: String
        let code: Int32?
        let text: String
    }
    /// 599: a bridge's notice ("hello copied 42 chars") — the page toasts it.
    struct Notice: Encodable {
        let t = "notice"
        let kind: String
        let text: String
    }
    struct Failure: Encodable {
        let t = "error"
        let code: String
        let message: String
    }

    static func encode<T: Encodable>(_ v: T) -> String {
        (try? WebJSON.encoder.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func ended(_ e: ClientWire.Ending, text: String) -> Ended {
        switch e {
        case .exited(let c): Ended(ending: "exited", code: c, text: text)
        case .noSession: Ended(ending: "none", code: nil, text: text)
        case .stopped: Ended(ending: "stopped", code: nil, text: text)
        }
    }
}
