import Foundation

// 593 — how a long start, wake or bake shows while it happens, in a TERMINAL: the web UI's boot view
// (a browser terminal) and the CLI's stderr are both one. ONE model (`ProgressBoard`: which steps are
// under way, the transfer, the last lines of output) and ONE renderer (`ProgressTerminal`), in two modes:
//
//   animated  the step under way on a line of its own — a braille spinner and the seconds so far,
//             rewritten in place — then "✓ step — 1.2 s" (or "✗ step — why") when it ends; a transfer
//             as a bar ("pulling node@1a2b3c4d5e6f  ██████░░░░  87 / 142 MB  6.1 MB/s  ~9 s"); the
//             output's last two lines, dim, beneath. That live block is ERASED and redrawn below each
//             finished line, so the scrollback only ever holds finished lines — no spinner frames.
//   plain     one line per finished step, note or console line, and a transfer's summary when it
//             ends ("pulled 142 MB in 23 s") — no redraw, no escape beyond the caller's styling.
//
// Host-authored text is ours; `output` lines are the guest's and were made inert by the library —
// they are made inert again here (`InertText` rules) before a byte of them is written. Digests are
// trimmed to 12 hex characters for people.

public enum ProgressMode: String, Sendable, Equatable {
    case animated, plain
}

public enum ProgressFormat {
    public static let spinnerFrames: [String] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    /// `sha256:<64 hex>` → its first 12; any other run of 64 hex characters too.
    public static func trimDigests(_ s: String) -> String {
        var out = s.replacingOccurrences(of: #"sha256:([0-9a-f]{12})[0-9a-f]{52}"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\b([0-9a-f]{12})[0-9a-f]{52}\b"#, with: "$1", options: .regularExpression)
        return out
    }

    /// Text made inert (for guest output; host text passes through it too — it costs nothing).
    public static func inert(_ s: String, limit: Int = 200) -> String {
        var out = String.UnicodeScalarView()
        var n = 0
        for u in s.unicodeScalars {
            if (u.value < 0x20 && u != "\t") || (0x7F...0x9F).contains(u.value) { continue }
            if n == limit { out.append("…"); break }
            out.append(u == "\t" ? " " : u)
            n += 1
        }
        return String(out)
    }

    /// 1.2 s · 850 ms · 2 min 5 s.
    public static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let s = Int(seconds.rounded())
        return "\(s / 60) min \(s % 60) s"
    }

    /// Bytes in decimal megabytes (what a download reads in): 87 MB, 1.4 GB, 512 kB.
    public static func bytes(_ b: Int64) -> String {
        let d = Double(b)
        if d >= 1e9 { return String(format: "%.1f GB", d / 1e9) }
        if d >= 1e6 { return String(format: "%.0f MB", d / 1e6) }
        if d >= 1e3 { return String(format: "%.0f kB", d / 1e3) }
        return "\(b) B"
    }

    /// `87 / 142 MB` (the total's unit for both).
    public static func amount(_ done: Int64, _ total: Int64?) -> String {
        guard let total, total > 0 else { return bytes(done) }
        let d = Double(done), t = Double(total)
        if t >= 1e9 { return String(format: "%.1f / %.1f GB", d / 1e9, t / 1e9) }
        if t >= 1e6 { return String(format: "%.0f / %.0f MB", d / 1e6, t / 1e6) }
        return "\(bytes(done)) / \(bytes(total))"
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond >= 1e6 ? String(format: "%.1f MB/s", bytesPerSecond / 1e6) : String(format: "%.0f kB/s", bytesPerSecond / 1e3)
    }

    /// A bar of `width` cells: full and empty blocks.
    public static func bar(_ fraction: Double, width: Int = 20) -> String {
        let f = max(0, min(1, fraction.isFinite ? fraction : 0))
        let full = Int((f * Double(width)).rounded())
        return String(repeating: "█", count: full) + String(repeating: "░", count: width - full)
    }
}

/// What a person sees finish (a line that goes into the scrollback).
public enum ProgressFinal: Equatable, Sendable {
    case stepDone(String, seconds: Double)
    case stepFailed(String, seconds: Double, error: String?)
    case note(String)
    case transferDone(String, bytes: Int64, seconds: Double)
    /// A line from outside the board (the boot console): written as it is.
    case raw(String)
}

/// The state of one start / wake / bake, from host events.
public final class ProgressBoard: @unchecked Sendable {
    public struct Transfer: Equatable, Sendable {
        public var label: String
        public var done: Int64
        public var total: Int64?
        public var items: Int?
        public var totalItems: Int?
        public var started: Date
        public var updated: Date
        /// Where the rate is measured from (the first sample: a pull reports its total first).
        public var firstDone: Int64
    }

    private let lock = NSLock()
    private var steps: [(label: String, started: Date)] = []
    private var transfer: Transfer?
    private var tail: [String] = []
    public let tailLines: Int

    public init(tailLines: Int = 2) { self.tailLines = tailLines }

    /// Apply an event; what finished (for the scrollback) is returned.
    @discardableResult
    public func apply(_ e: HostEvent, now: Date = Date()) -> [ProgressFinal] {
        lock.withLock {
            let text = ProgressFormat.trimDigests(ProgressFormat.inert(e.text ?? "", limit: 400))
            switch e.kind {
            case .started:
                steps.append((text, now))
                return []
            case .step:
                let started = removeStep(e.startedAs.map { ProgressFormat.trimDigests(ProgressFormat.inert($0, limit: 400)) } ?? text)
                var out: [ProgressFinal] = []
                if let t = transfer, t.label.isEmpty == false, started != nil || steps.isEmpty {
                    out.append(.transferDone(t.label, bytes: t.done, seconds: now.timeIntervalSince(t.started)))
                    transfer = nil
                }
                tail = []
                out.append(.stepDone(text, seconds: (e.milliseconds ?? 0) / 1000))
                return out
            case .failed:
                _ = removeStep(e.startedAs.map { ProgressFormat.trimDigests(ProgressFormat.inert($0, limit: 400)) } ?? text)
                transfer = nil
                tail = []
                return [.stepFailed(text, seconds: (e.milliseconds ?? 0) / 1000, error: e.error.map { ProgressFormat.trimDigests(ProgressFormat.inert($0)) })]
            case .progress:
                let done = e.completedBytes ?? 0
                var out: [ProgressFinal] = []
                if var t = transfer, t.label == text {
                    t.done = done
                    t.total = e.totalBytes
                    t.items = e.completedItems
                    t.totalItems = e.totalItems
                    t.updated = now
                    transfer = t
                } else {
                    if let t = transfer { out.append(.transferDone(t.label, bytes: t.done, seconds: now.timeIntervalSince(t.started))) }
                    transfer = Transfer(label: text, done: done, total: e.totalBytes, items: e.completedItems, totalItems: e.totalItems,
                                        started: now, updated: now, firstDone: done)
                }
                // A transfer that reached its total is done.
                if let t = transfer, let total = t.total, total > 0, t.done >= total, t.totalItems.map({ (t.items ?? 0) >= $0 }) ?? true {
                    transfer = nil
                    out.append(.transferDone(t.label, bytes: t.done, seconds: now.timeIntervalSince(t.started)))
                }
                return out
            case .output:
                guard !text.isEmpty else { return [] }
                tail.append(text)
                if tail.count > tailLines { tail.removeFirst(tail.count - tailLines) }
                return []
            case .note, .host:
                return text.isEmpty ? [] : [.note(text)]
            case .phase, .connection, .console, .sessionStatus:
                return []
            }
        }
    }

    private func removeStep(_ label: String) -> Date? {
        if let i = steps.lastIndex(where: { $0.label == label }) { return steps.remove(at: i).started }
        // 594 W8: a step may end with its result appended ("verify: X" ends as "verify: X → 2.1.285").
        if let i = steps.lastIndex(where: { label.hasPrefix($0.label + " → ") }) { return steps.remove(at: i).started }
        return nil
    }

    /// Everything still under way, as finished lines (the operation ended: nothing is left live).
    public func finishAll(now: Date = Date()) -> [ProgressFinal] {
        lock.withLock {
            var out: [ProgressFinal] = []
            if let t = transfer { out.append(.transferDone(t.label, bytes: t.done, seconds: now.timeIntervalSince(t.started))) }
            transfer = nil
            steps = []
            tail = []
            return out
        }
    }

    /// A line of the live block.
    public enum Live: Equatable, Sendable {
        case step(String, seconds: Double)
        case transfer(String)
        case output(String)
    }

    /// The live block now (animated mode): the newest step under way, the transfer, the tail.
    public func live(now: Date = Date()) -> [Live] {
        lock.withLock {
            var out: [Live] = []
            if let s = steps.last { out.append(.step(s.label, seconds: now.timeIntervalSince(s.started))) }
            if let t = transfer { out.append(.transfer(Self.transferLine(t, now: now))) }
            out += tail.map { .output($0) }
            return out
        }
    }

    public var isLive: Bool { lock.withLock { !steps.isEmpty || transfer != nil || !tail.isEmpty } }

    /// 594: the transfer under way (for a view that draws its own bar — the onboarding wizard).
    public var currentTransfer: Transfer? { lock.withLock { transfer } }

    /// `pulling node@1a2b3c4d5e6f  ██████░░░░  87 / 142 MB  6.1 MB/s  ~9 s  (3/5 layers)`.
    public static func transferLine(_ t: Transfer, now: Date) -> String {
        var parts = [t.label]
        let elapsed = now.timeIntervalSince(t.started)
        let rate = elapsed > 0.5 ? Double(t.done - t.firstDone) / elapsed : 0
        if let total = t.total, total > 0 {
            parts.append(ProgressFormat.bar(Double(t.done) / Double(total)))
        }
        parts.append(ProgressFormat.amount(t.done, t.total))
        if rate > 0 {
            parts.append(ProgressFormat.rate(rate))
            // Time left, once there is a rate worth trusting (and not the hours an early estimate says).
            if let total = t.total, total > t.done, elapsed >= 3 {
                let left = Double(total - t.done) / rate
                if left < 3600 { parts.append("~" + ProgressFormat.duration(left).replacingOccurrences(of: ".0 s", with: " s")) }
            }
        }
        if let ti = t.totalItems { parts.append("(\(t.items ?? 0)/\(ti) layers)") }
        return parts.joined(separator: "  ")
    }
}

/// The board as terminal bytes: finished lines into the scrollback, the live block (animated)
/// redrawn beneath them. Not thread-safe by itself: its owner serializes calls.
public final class ProgressTerminal {
    public let mode: ProgressMode
    /// ANSI styling (dim / green / red / bold). False: none at all (NO_COLOR).
    public let color: Bool
    /// What finished lines look like in plain mode for this sink (the CLI prefixes "  · ", the web
    /// boot view "[doz] " and dims them).
    private let plainPrefix: String
    private let plainStyle: String?
    private var blockHeight = 0
    private var frame = 0
    public let board: ProgressBoard

    public init(mode: ProgressMode, color: Bool = true, plainPrefix: String = "", plainStyle: String? = nil, board: ProgressBoard = ProgressBoard()) {
        self.mode = mode
        self.color = color
        self.plainPrefix = plainPrefix
        self.plainStyle = plainStyle
        self.board = board
    }

    private func style(_ code: String, _ s: String) -> String { color ? "\u{1B}[\(code)m" + s + "\u{1B}[0m" : s }

    /// A finished line, formatted for this mode.
    public func format(_ f: ProgressFinal) -> String {
        let s = unstyledFormat(f)
        if case .raw = f { return s }                       // the caller's own line, styled by it
        if mode == .plain, let st = plainStyle, color { return style(st, s) }
        return s
    }

    private func unstyledFormat(_ f: ProgressFinal) -> String {
        switch (mode, f) {
        case (.animated, .stepDone(let l, let s)): return style("32", "✓") + " " + l + style("2", " — " + ProgressFormat.duration(s))
        case (.animated, .stepFailed(let l, let s, let why)): return style("31", "✗ " + l + " — " + (why ?? "failed")) + style("2", " (" + ProgressFormat.duration(s) + ")")
        case (.animated, .note(let t)): return style("2", "  " + t)
        case (.animated, .transferDone(let l, let b, let s)): return style("32", "✓") + " " + Self.pulled(l, b, s)
        case (.plain, .stepDone(let l, let s)): return plainPrefix + l + String(format: " — %.0f ms", s * 1000)
        case (.plain, .stepFailed(let l, let s, let why)): return plainPrefix + "FAILED: " + l + (why.map { " — \($0)" } ?? "") + String(format: " (%.0f ms)", s * 1000)
        case (.plain, .note(let t)): return plainPrefix + t
        case (.plain, .transferDone(let l, let b, let s)): return plainPrefix + Self.pulled(l, b, s)
        case (_, .raw(let t)): return t
        }
    }

    /// "pulled node@1a2b3c4d5e6f: 142 MB in 23.0 s" (a download's label reads "pulling …").
    static func pulled(_ label: String, _ bytes: Int64, _ seconds: Double) -> String {
        let what = label.hasPrefix("pulling ") ? "pulled " + label.dropFirst(8) : label.hasPrefix("downloading ") ? "downloaded " + label.dropFirst(12) : label
        return "\(what): \(ProgressFormat.bytes(bytes)) in \(ProgressFormat.duration(seconds))"
    }

    /// The terminal's width in columns: every live line is cut to fit ONE row, so the block's height in
    /// rows is its number of lines (a wrapped line would leave rows behind on every redraw).
    public var width: Int = 80

    private func fit(_ s: String, _ room: Int) -> String {
        guard room > 0 else { return "" }
        return s.count <= room ? s : String(s.prefix(max(0, room - 1))) + "…"
    }

    private func liveText(_ l: ProgressBoard.Live) -> String {
        let cols = max(20, width) - 1
        switch l {
        case .step(let label, let s):
            let d = "  " + ProgressFormat.duration(s)
            return style("36", ProgressFormat.spinnerFrames[frame % ProgressFormat.spinnerFrames.count]) + " " + fit(label, cols - 2 - d.count) + style("2", d)
        case .transfer(let t): return "  " + fit(t, cols - 2)
        case .output(let o): return style("2", "  │ " + fit(o, cols - 4))
        }
    }

    /// The bytes that erase the live block (the cursor is left at the start of its first line).
    private func eraseBlock() -> String {
        guard blockHeight > 0 else { return "" }
        defer { blockHeight = 0 }
        return "\r" + (blockHeight > 1 ? "\u{1B}[\(blockHeight - 1)A" : "") + "\u{1B}[J"
    }

    private func drawBlock(now: Date) -> String {
        guard mode == .animated else { return "" }
        let lines = board.live(now: now).map(liveText)
        blockHeight = lines.count
        return lines.joined(separator: "\r\n")
    }

    /// Finished lines (from `board.apply`, or raw console lines) → bytes: in animated mode the live
    /// block is erased first and redrawn after them.
    public func write(_ finals: [ProgressFinal], now: Date = Date()) -> String {
        if mode == .plain { return finals.map { format($0) + "\r\n" }.joined() }
        let body = finals.map { format($0) + "\r\n" }.joined()
        return eraseBlock() + body + drawBlock(now: now)
    }

    /// An event → bytes.
    public func apply(_ e: HostEvent, now: Date = Date()) -> String {
        let finals = board.apply(e, now: now)
        if mode == .plain { return write(finals, now: now) }
        return write(finals, now: now)
    }

    /// A tick of the spinner (animated): the block redrawn; "" when nothing is live.
    public func tick(now: Date = Date()) -> String {
        guard mode == .animated, blockHeight > 0 || board.isLive else { return "" }
        frame += 1
        return eraseBlock() + drawBlock(now: now)
    }

    /// The end: what is still live becomes finished lines, and the block is gone.
    public func finish(now: Date = Date()) -> String {
        let finals = board.finishAll(now: now)
        if mode == .plain { return write(finals, now: now) }
        return eraseBlock() + finals.map { format($0) + "\r\n" }.joined()
    }

    public var hasBlock: Bool { blockHeight > 0 }
}

extension DozerSettings {
    /// 593: `ui.progress` for this process — `flag` (the CLI's --progress: auto → animated), else
    /// $DOZ_PROGRESS, else the file, else animated.
    public func progressMode(flag: String? = nil) -> ProgressMode {
        let f: TOMLValue? = flag.map { .string($0 == "plain" ? "plain" : "animated") }
        if case .string(let s) = resolve(SettingKey.progress, flag: f).value, s == "plain" { return .plain }
        return .animated
    }
}
