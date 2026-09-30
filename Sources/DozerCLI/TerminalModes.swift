import Foundation

// 594 (owner's walkthrough W13): after Ctrl-] detached `doz up` from Claude Code, moving the mouse typed
// `35;44;37M…` into the Mac's shell — Claude Code had turned on SGR mouse reporting (?1006 + ?1003) in
// the OUTER terminal, and the attach client never turned it off. The client now follows the modes the
// session's bytes set in the outer terminal (`TerminalModes.feed`) and, on every way out — detach, the
// session ending, a lost host, SIGINT/SIGTERM/SIGHUP, an error — writes `restoreSequence` before its
// last line: mouse, focus events, bracketed paste, synchronized output off; the alternate screen left
// (only when the session entered it: leaving it otherwise would restore a stale cursor); the cursor
// shown; cursor keys and keypad normal; the kitty keyboard stack popped; the SGR reset.

/// 594 (owner's walkthrough W16): "detach seems to only happen now after twice sending CTRL-]". Claude
/// Code 2.1.285 asks the outer terminal whether it speaks the kitty keyboard protocol (`CSI ? u`) and,
/// when it does (iTerm2, Ghostty, kitty, WezTerm…), pushes flags 5 (`CSI > 5 u`) and sets xterm's
/// modifyOtherKeys 2 (`CSI > 4 ; 2 m`). The terminal then sends Ctrl-] as `ESC [ 93 ; 5 u` (or
/// `ESC [ 27 ; 5 ; 93 ~`), never 0x1D — and the client, matching only 0x1D, forwarded it to the session.
/// This finds the detach key in every encoding a session can put the outer terminal in: the legacy
/// control byte; kitty CSI-u with any flags (alternate-key sub-fields, event types — a release is
/// swallowed, never a second detach; associated text); modifyOtherKeys. Nothing of it is forwarded.
struct DetachKeyScanner: Sendable {
    /// The control byte (0x1D for Ctrl-]).
    let key: UInt8
    /// Its key as kitty and modifyOtherKeys name it: the base key's code point (`]` = 93, `q` = 113).
    let codepoint: Int
    /// A partial `ESC [ digits ;:` sequence held back for the next read.
    private var held: [UInt8] = []

    init(key: UInt8) {
        self.key = key
        let c = key | 0x40
        codepoint = Int((0x41...0x5A).contains(c) ? c + 0x20 : c)
    }

    enum Result: Equatable { case forward([UInt8]), detach(forwardFirst: [UInt8]) }

    /// The bytes read from the terminal: what to forward, or the detach (with what came before it).
    mutating func scan(_ input: [UInt8]) -> Result {
        let bytes = held + input
        held = []
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == key { return .detach(forwardFirst: out) }
            guard b == 0x1B else { out.append(b); i += 1; continue }
            // ESC [ params final — params only digits ; :
            var j = i + 1
            guard j < bytes.count else {
                // A lone ESC at the end of a read is a key (Escape) — never held.
                out.append(b); i += 1; continue
            }
            guard bytes[j] == UInt8(ascii: "[") else { out.append(b); i += 1; continue }
            j += 1
            let start = j
            while j < bytes.count, (0x30...0x3B).contains(bytes[j]) { j += 1 }        // 0-9 : ;
            if j == bytes.count {
                // Cut by the read: hold it (only a plausible key sequence, and never for long).
                if j > start, bytes.count - i <= 48 { held = Array(bytes[i...]); return .forward(out) }
                out += bytes[i..<j]; i = j; continue
            }
            let final = bytes[j]
            let params = String(decoding: bytes[start..<j], as: UTF8.self)
            switch classify(params, final: final) {
            case .press: return .detach(forwardFirst: out)
            case .release: i = j + 1                                                       // swallowed
            case .other: out += bytes[i...j]; i = j + 1
            }
        }
        return .forward(out)
    }

    private enum Kind { case press, release, other }

    /// `CSI code[:alt…] ; mods[:event] [; text] u` (kitty) or `CSI 27 ; mods ; code ~` (modifyOtherKeys).
    private func classify(_ params: String, final: UInt8) -> Kind {
        let fields = params.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        func ctrlOnly(_ m: String?) -> Bool {
            guard let m, let v = Int(m), v >= 1 else { return false }
            return (v - 1) & ~(64 | 128) == 4                                             // ctrl; caps/num lock ignored
        }
        if final == UInt8(ascii: "u"), fields.count >= 2 {
            guard Int(fields[0].split(separator: ":", omittingEmptySubsequences: false).first ?? "") == codepoint else { return .other }
            let m = fields[1].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard ctrlOnly(m.first) else { return .other }
            return m.count > 1 && m[1] == "3" ? .release : .press
        }
        if final == UInt8(ascii: "~"), fields.count == 3, fields[0] == "27", Int(fields[2]) == codepoint, ctrlOnly(fields[1]) {
            return .press
        }
        return .other
    }
}

/// 594 (owner's walkthrough W17): the SHORTEST command that reattaches to `session` from here — `doz up`
/// when this folder's doz_project.yaml names the sandbox and the session is the one `doz up` attaches;
/// `doz attach NAME` for the sandbox's default session; else `doz attach NAME SESSION`.
func reattachCommand(sandbox: String, session: String, defaultSession: String?,
                     folder: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> String {
    if let f = DozerProject.find(in: folder), let p = try? DozerProject.load(f), p.name == sandbox,
       (p.sessions.first?.name ?? defaultSession) == session {
        return "doz up"
    }
    if session == defaultSession { return "doz attach \(sandbox)" }
    return "doz attach \(sandbox) \(session)"
}

/// The DEC private modes and kitty keyboard state a byte stream leaves set in a terminal.
struct TerminalModes: Sendable, Equatable {
    /// DEC private modes (`CSI ? n h`) set and not reset since.
    private(set) var dec: Set<Int> = []
    /// Kitty keyboard protocol: entries pushed (`CSI > f u`) and not popped (`CSI < n u`).
    private(set) var kittyPushed = 0
    /// Kitty flags set directly (`CSI = f ; m u`).
    private(set) var kittySet = false
    /// `ESC =` (application keypad) without `ESC >` since.
    private(set) var keypadApplication = false
    /// xterm modifyOtherKeys set (`CSI > 4 ; 1|2 m`).
    private(set) var modifyOtherKeys = false

    private enum State: Sendable, Equatable { case ground, esc, csi }
    private var state: State = .ground
    private var buf: [UInt8] = []

    /// Follow the bytes written to the terminal (a chunk at a time; sequences may span chunks).
    mutating func feed<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for b in bytes {
            switch state {
            case .ground:
                if b == 0x1B { state = .esc }
            case .esc:
                switch b {
                case UInt8(ascii: "["): state = .csi; buf.removeAll(keepingCapacity: true)
                case UInt8(ascii: "="): keypadApplication = true; state = .ground
                case UInt8(ascii: ">"): keypadApplication = false; state = .ground
                case UInt8(ascii: "c"): self = TerminalModes()                  // RIS: a full reset
                case 0x1B: state = .esc
                default: state = .ground
                }
            case .csi:
                if (0x40...0x7E).contains(b) {
                    dispatch(final: b)
                    state = .ground
                } else if (0x20...0x3F).contains(b), buf.count < 64 {
                    buf.append(b)
                } else if b == 0x1B {
                    state = .esc
                } else {
                    state = .ground
                }
            }
        }
    }

    private mutating func dispatch(final: UInt8) {
        guard let first = buf.first else { return }
        let params = String(decoding: buf.dropFirst(), as: UTF8.self)
        let numbers = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) }
        switch (first, final) {
        case (UInt8(ascii: "?"), UInt8(ascii: "h")):
            for case let n? in numbers { dec.insert(n) }
        case (UInt8(ascii: "?"), UInt8(ascii: "l")):
            for case let n? in numbers { dec.remove(n) }
        case (UInt8(ascii: ">"), UInt8(ascii: "u")):
            kittyPushed = min(kittyPushed + 1, 64)
        case (UInt8(ascii: "<"), UInt8(ascii: "u")):
            kittyPushed = max(0, kittyPushed - max(1, numbers.first.flatMap { $0 } ?? 1))
        case (UInt8(ascii: "="), UInt8(ascii: "u")):
            kittySet = true
        case (UInt8(ascii: ">"), UInt8(ascii: "m")) where numbers.first == 4:
            // 594 (W16): xterm modifyOtherKeys — `CSI > 4 ; n m` (n 0 = off), `CSI > 4 m` resets it.
            modifyOtherKeys = numbers.count > 1 && (numbers[1] ?? 0) != 0
        default:
            break
        }
    }

    /// What puts the outer terminal back as the shell expects it.
    var restoreSequence: String {
        var s = ""
        // Mouse reporting, every encoding; focus events; bracketed paste; synchronized output.
        s += "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1005l\u{1B}[?1006l\u{1B}[?1015l"
        s += "\u{1B}[?1004l\u{1B}[?2004l\u{1B}[?2026l"
        // The keyboard, BEFORE the alternate screen is left: a terminal keeps a kitty stack per screen
        // (the session pushed on the alternate one). Every entry it pushed; its flags; modifyOtherKeys.
        if kittyPushed > 0 { s += "\u{1B}[<\(kittyPushed)u" }
        if kittySet { s += "\u{1B}[=0;1u" }
        if modifyOtherKeys { s += "\u{1B}[>4m" }
        // The alternate screen — only the ones the session entered.
        for m in [1049, 1047, 47] where dec.contains(m) { s += "\u{1B}[?\(m)l" }
        // Cursor visible; cursor keys and keypad normal.
        s += "\u{1B}[?25h\u{1B}[?1l\u{1B}>"
        s += "\u{1B}[0m"
        return s
    }
}
