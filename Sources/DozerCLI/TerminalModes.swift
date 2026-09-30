import Foundation

// 594 (owner's walkthrough W13): after Ctrl-] detached `doz up` from Claude Code, moving the mouse typed
// `35;44;37M…` into the Mac's shell — Claude Code had turned on SGR mouse reporting (?1006 + ?1003) in
// the OUTER terminal, and the attach client never turned it off. The client now follows the modes the
// session's bytes set in the outer terminal (`TerminalModes.feed`) and, on every way out — detach, the
// session ending, a lost host, SIGINT/SIGTERM/SIGHUP, an error — writes `restoreSequence` before its
// last line: mouse, focus events, bracketed paste, synchronized output off; the alternate screen left
// (only when the session entered it: leaving it otherwise would restore a stale cursor); the cursor
// shown; cursor keys and keypad normal; the kitty keyboard stack popped; the SGR reset.

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
        // The alternate screen — only the ones the session entered.
        for m in [1049, 1047, 47] where dec.contains(m) { s += "\u{1B}[?\(m)l" }
        // Cursor visible; cursor keys and keypad normal.
        s += "\u{1B}[?25h\u{1B}[?1l\u{1B}>"
        // The kitty keyboard protocol: every entry the session pushed, and its flags reset.
        if kittyPushed > 0 { s += "\u{1B}[<\(kittyPushed)u" }
        if kittySet { s += "\u{1B}[=0;1u" }
        s += "\u{1B}[0m"
        return s
    }
}
