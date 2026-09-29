import Darwin
import Foundation

// 593 §9 (owner, 2026-09-29 — S2, S5, S6; amended 2026-09-30): a sandbox's SAVED SCREENS. Before a
// sandbox pauses, sleeps or hibernates — and every few minutes while it runs — each of its sessions'
// screens is captured: a momentary attach to deckhold, which answers every HELLO with a SNAPSHOT (VT
// bytes that redraw the screen on a blank terminal) and a DUMP with the screen as plain text. One
// file set per session, in the sandbox's own directory:
//
//     <sandbox>/screens/            0700
//         NAME.vt                   0600  the SNAPSHOT as the guest sent it (VT; ≤ `maximumVTBytes`)
//         NAME.txt                  0600  the active screen as plain text, control characters removed
//         NAME.json                 0600  `SavedScreenInfo`: when, why, size, command
//
// Saved screens exist ONLY for sessions that are still alive in a sandbox you can wake back into
// (paused, asleep, hibernated). The owner's amendment (2026-09-30): "when i shutdown the new sandbox,
// i should not still see the claude terminal screen" — a shutdown (and a reset, a remove, a host that
// died with the VM) DELETES them; a session whose program exited has none. There is no "ended" screen.
//
// Text, not an image: identical to the live terminal, sharp at any size, kilobytes, selectable.
// The bytes came from inside the sandbox, which is untrusted: a reader renders the VT only in a
// terminal engine (the web UI's sandboxed frame), and prints the TEXT (`doz sessions --screen`).
// Never copied by duplicate, fork or a template (they copy disks by name).

/// What is known about one saved screen (`NAME.json`).
public struct SavedScreenInfo: Codable, Sendable, Equatable {
    public var session: String
    public var savedAt: Date
    /// Why it was taken: `pause`, `sleep`, `hibernate` or `periodic`.
    public var reason: String
    /// The sandbox's phase when it was taken (always `running`: only a running guest can answer).
    public var phase: String
    public var cols: UInt16?
    public var rows: UInt16?
    /// `primary` or `alt` (a full-screen program).
    public var screen: String?
    public var command: String
    public var pid: Int?
    /// The session's output counter at the capture (`deckhold ls` bytes=): a periodic capture skips a
    /// session whose counter has not moved.
    public var bytesOut: UInt64
    public var vtBytes: Int
    /// The snapshot was longer than `SavedScreens.maximumVTBytes`: its oldest scrollback was dropped.
    public var truncated: Bool

    public init(session: String, savedAt: Date, reason: String, phase: String = "running", cols: UInt16? = nil, rows: UInt16? = nil,
                screen: String? = nil, command: String = "", pid: Int? = nil, bytesOut: UInt64 = 0, vtBytes: Int = 0, truncated: Bool = false) {
        self.session = session
        self.savedAt = savedAt
        self.reason = reason
        self.phase = phase
        self.cols = cols
        self.rows = rows
        self.screen = screen
        self.command = command
        self.pid = pid
        self.bytesOut = bytesOut
        self.vtBytes = vtBytes
        self.truncated = truncated
    }
}

/// One saved screen: what is known, the VT bytes and the plain text.
public struct SavedScreen: Sendable, Equatable {
    public var info: SavedScreenInfo
    public var vt: Data
    public var text: String

    public init(info: SavedScreenInfo, vt: Data, text: String) {
        self.info = info
        self.vt = vt
        self.text = text
    }
}

/// How a capture went (for the host's log and the tests).
public struct ScreenCaptureReport: Sendable, Equatable {
    public var captured: [String] = []
    /// Unchanged since the last capture (a periodic capture only).
    public var unchanged: [String] = []
    /// Their program had exited: the saved screen (if any) is deleted.
    public var ended: [String] = []
    /// Could not be captured (timeout, transport): the previous file is kept.
    public var failed: [String] = []
    /// Saved screens of sessions the guest no longer has (a previous boot's): removed.
    public var removed: [String] = []
    public var milliseconds: Double = 0
    public init() {}
}

public enum SavedScreens {
    /// A snapshot beyond this keeps its newest part (from a line boundary; the oldest scrollback goes).
    public static let maximumVTBytes = 2 << 20
    /// The plain text kept (the active screen: rows × cols, far less in practice).
    public static let maximumTextBytes = 256 << 10
    /// One session's capture may take this long; then it is given up (the previous file stays).
    public static let perSessionTimeoutSeconds: Int64 = 3
    /// A whole capture (every session) gives up after this — a wedged guest never holds up a sleep.
    public static let totalBudgetSeconds: Double = 8
    /// At most this many sessions are captured at once.
    public static let maximumSessions = 32

    public static func directory(_ layout: StoreLayout) -> URL { layout.screensDirectory }

    static func files(_ layout: StoreLayout, _ session: String) -> (vt: URL, text: URL, info: URL) {
        let d = directory(layout)
        return (d.appendingPathComponent("\(session).vt"), d.appendingPathComponent("\(session).txt"), d.appendingPathComponent("\(session).json"))
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { d, enc in
            var c = enc.singleValueContainer()
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try c.encode(f.string(from: d))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let v = f.date(from: s) { return v }
            f.formatOptions = [.withInternetDateTime]
            if let v = f.date(from: s) { return v }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "not an ISO 8601 date"))
        }
        return d
    }()

    /// Every saved screen of the sandbox, by session name. Unreadable entries are skipped.
    public static func list(_ layout: StoreLayout) -> [SavedScreenInfo] {
        let d = directory(layout)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: d.path) else { return [] }
        var out: [SavedScreenInfo] = []
        for n in names where n.hasSuffix(".json") {
            let session = String(n.dropLast(5))
            guard (try? GuestCommand.validateSessionName(session)) != nil,
                  let data = try? Data(contentsOf: d.appendingPathComponent(n)),
                  let info = try? decoder.decode(SavedScreenInfo.self, from: data), info.session == session else { continue }
            out.append(info)
        }
        return out.sorted { $0.session < $1.session }
    }

    /// One saved screen, or nil when there is none (or its name is not a session name).
    public static func read(_ layout: StoreLayout, session: String) -> SavedScreen? {
        guard (try? GuestCommand.validateSessionName(session)) != nil else { return nil }
        let f = files(layout, session)
        guard let data = try? Data(contentsOf: f.info), let info = try? decoder.decode(SavedScreenInfo.self, from: data),
              info.session == session else { return nil }
        let vt = (try? Data(contentsOf: f.vt)) ?? Data()
        let text = (try? String(contentsOf: f.text, encoding: .utf8)) ?? ""
        return SavedScreen(info: info, vt: vt.count > maximumVTBytes ? Data(vt.suffix(maximumVTBytes)) : vt, text: text)
    }

    /// Write one session's screen: the directory 0700, each file 0600, each atomically (a crash leaves
    /// the previous file or the new one, never half of one). The VT is capped (`cappedVT`).
    public static func write(_ layout: StoreLayout, info: SavedScreenInfo, vt: Data, text: String) throws {
        try GuestCommand.validateSessionName(info.session)
        try ensureDirectory(layout)
        let f = files(layout, info.session)
        let (capped, truncated) = cappedVT(vt)
        var i = info
        i.vtBytes = capped.count
        i.truncated = truncated
        try writePrivate(capped, to: f.vt)
        try writePrivate(Data(inertScreenText(text).utf8), to: f.text)
        try writePrivate(try encoder.encode(i), to: f.info)
    }

    /// Remove saved screens: those NOT in `keeping` (sessions the guest no longer has), or every one.
    @discardableResult
    public static func remove(_ layout: StoreLayout, keeping: Set<String>? = nil) -> [String] {
        var gone: [String] = []
        for i in list(layout) where !(keeping?.contains(i.session) ?? false) {
            let f = files(layout, i.session)
            for u in [f.vt, f.text, f.info] { try? FileManager.default.removeItem(at: u) }
            gone.append(i.session)
        }
        if keeping == nil { try? FileManager.default.removeItem(at: directory(layout)) }
        return gone
    }

    /// A snapshot over the cap keeps its NEWEST bytes, cut at a line boundary (the oldest scrollback
    /// goes; the active area is drawn last and stays whole), after a soft reset.
    public static func cappedVT(_ vt: Data, limit: Int = maximumVTBytes) -> (Data, Bool) {
        guard vt.count > limit else { return (vt, false) }
        let prefix = Data("\u{1B}[!p\u{1B}[0m".utf8)
        var tail = vt.suffix(limit - prefix.count)
        if let nl = tail.firstIndex(of: 0x0A) { tail = tail[(nl + 1)...] }
        return (prefix + tail, true)
    }

    /// deckhold's DUMP text (`…rows…\ncursor=X,Y size=CxR screen=S`) → the screen's text (inert: every
    /// control character but a newline removed, escape sequences with it) and what the last line says.
    public static func parseDump(_ dump: String) -> (text: String, cols: UInt16?, rows: UInt16?, screen: String?) {
        var lines = dump.components(separatedBy: "\n")
        var cols: UInt16?, rows: UInt16?, screen: String?
        if let last = lines.last, last.hasPrefix("cursor=") {
            lines.removeLast()
            for field in last.split(separator: " ") {
                let kv = field.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "size":
                    let p = kv[1].split(separator: "x").compactMap { UInt16($0) }
                    if p.count == 2 { cols = p[0]; rows = p[1] }
                case "screen": screen = kv[1]
                default: break
                }
            }
        }
        return (inertScreenText(lines.joined(separator: "\n")), cols, rows, screen)
    }

    /// Guest text as it may be printed: escape sequences and every control character but `\n` removed
    /// (a tab becomes a space), trailing blanks trimmed per line, capped.
    public static func inertScreenText(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        enum State { case text, escape, csi, string, stringEscape }
        var state = State.text
        for u in s.unicodeScalars {
            switch state {
            case .escape:
                switch u {
                case "[": state = .csi
                case "]", "P", "_", "^", "X": state = .string
                default: state = .text
                }
                continue
            case .csi:
                if (0x40...0x7E).contains(u.value) { state = .text }
                continue
            case .string:
                if u.value == 0x07 { state = .text } else if u.value == 0x1B { state = .stringEscape }
                continue
            case .stringEscape:
                state = u == "\\" ? .text : .string
                continue
            case .text:
                break
            }
            if u.value == 0x1B { state = .escape; continue }
            if u == "\n" { out.append(u); continue }
            if u == "\t" { out.append(" "); continue }
            if u.value < 0x20 || (0x7F...0x9F).contains(u.value) { continue }
            out.append(u)
        }
        var text = String(out).components(separatedBy: "\n").map { line in
            var l = Substring(line)
            while l.last == " " { l = l.dropLast() }
            return String(l)
        }.joined(separator: "\n")
        while text.hasSuffix("\n") { text.removeLast() }
        if text.utf8.count > maximumTextBytes { text = String(decoding: Data(text.utf8.suffix(maximumTextBytes)), as: UTF8.self) }
        return text
    }

    // MARK: files

    static func ensureDirectory(_ layout: StoreLayout) throws {
        let d = directory(layout)
        // The sandbox's directory must exist already: a saved screen never re-creates a removed sandbox.
        guard FileManager.default.fileExists(atPath: layout.sandboxDirectory.path) else {
            throw SandboxError.invalidSpec("no sandbox directory for \(layout.name)")
        }
        if !FileManager.default.fileExists(atPath: d.path) {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        chmod(d.path, 0o700)
    }

    /// Atomically, 0600 from the first byte (the temporary file is created 0600, then renamed). (Also
    /// the host's boot logs.)
    public static func writePrivate(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path]) }
        var ok = true
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { if errno == EINTR { continue }; ok = false; break }
                off += n
            }
        }
        fchmod(fd, 0o600)
        close(fd)
        guard ok, rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
