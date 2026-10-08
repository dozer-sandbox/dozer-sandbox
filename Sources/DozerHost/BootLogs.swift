import Darwin
import Foundation
import DozerKit

// 593 (owner, 2026-09-30: "where is the bootup terminal output stored so i can look at it after the
// machine has booted (it flys past so quickly)" — "yes to the boot log"): a record of each BOOT of a
// sandbox — a cold boot (Start), a wake, a restore after a crash — kept by the host in the sandbox's
// own directory:
//
//     <sandbox>/boots/                  0700
//         b-<epoch ms>/                 0700  one boot (the name sorts by time)
//             boot.json                 0600  `BootLogInfo`: started, kind, duration, result, failure
//             events.jsonl              0600  the sandbox's own host events of that boot — exactly what
//                                             the boot view drew (steps, failures, downloads, notes)
//             console.log               0600  that boot's kernel/init console (from `bootlog.log`)
//
// The last `host.boot_logs_kept` (5) are kept. Deleted with the sandbox (`rm`); kept across a reset (a
// reset's next boot is still a boot of that sandbox); never copied by duplicate, fork or a template.
// Replayed by the ONE boot-view renderer (`ProgressBoard` + `ProgressTerminal`'s finished lines), for
// `doz console --steps` and the web UI's Boot log.

/// What is known about one boot (`boot.json`).
public struct BootLogInfo: Codable, Equatable, Sendable {
    public var id: String
    /// 1 = the latest (set when listed).
    public var number: Int?
    /// `cold boot`, `wake` or `restore after crash`.
    public var kind: String
    public var startedAt: Date
    public var milliseconds: Double?
    /// `ok`, `failed`, or `running` (a boot under way — only the host's own list has one).
    public var result: String
    public var error: String?
    public var events: Int
    public var consoleBytes: Int

    public init(id: String, number: Int? = nil, kind: String, startedAt: Date, milliseconds: Double? = nil, result: String,
                error: String? = nil, events: Int = 0, consoleBytes: Int = 0) {
        self.id = id
        self.number = number
        self.kind = kind
        self.startedAt = startedAt
        self.milliseconds = milliseconds
        self.result = result
        self.error = error
        self.events = events
        self.consoleBytes = consoleBytes
    }
}

/// One boot: what is known, its events, its console (lines, as the guest wrote them — make them inert
/// before showing them: `BootLogs.render`).
public struct BootLogRecord: Codable, Equatable, Sendable {
    public var name: String
    public var info: BootLogInfo
    public var events: [HostEvent]
    public var console: [String]

    public init(name: String, info: BootLogInfo, events: [HostEvent], console: [String]) {
        self.name = name
        self.info = info
        self.events = events
        self.console = console
    }
}

/// `boot-log --list`.
public struct BootLogList: Codable, Equatable, Sendable {
    public var name: String
    public var boots: [BootLogInfo]

    public init(name: String, boots: [BootLogInfo]) {
        self.name = name
        self.boots = boots
    }
}

public enum BootLogs {
    public static let defaultKept = 5
    public static let maximumEvents = 20_000
    public static let maximumConsoleBytes = 4 << 20

    public static func directory(_ layout: StoreLayout) -> URL { layout.sandboxDirectory.appendingPathComponent("boots") }

    static func newID(_ date: Date) -> String { String(format: "b-%013.0f", (date.timeIntervalSince1970 * 1000).rounded(.down)) }

    static func isID(_ s: String) -> Bool { s.hasPrefix("b-") && s.count == 15 && s.dropFirst(2).allSatisfy(\.isNumber) }

    /// The kept boots, newest first, numbered from 1.
    public static func list(_ layout: StoreLayout) -> [BootLogInfo] {
        let d = directory(layout)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).filter(isID).sorted(by: >)
        var out: [BootLogInfo] = []
        for n in names {
            guard let data = try? Data(contentsOf: d.appendingPathComponent(n).appendingPathComponent("boot.json")),
                  var i = try? HostWire.decoder.decode(BootLogInfo.self, from: data), i.id == n else { continue }
            i.number = out.count + 1
            out.append(i)
        }
        return out
    }

    /// Boot `number` (1 = the latest), or nil.
    public static func read(_ layout: StoreLayout, name: String, number: Int) -> BootLogRecord? {
        let all = list(layout)
        guard number >= 1, number <= all.count else { return nil }
        let info = all[number - 1]
        let dir = directory(layout).appendingPathComponent(info.id)
        var events: [HostEvent] = []
        if let data = try? Data(contentsOf: dir.appendingPathComponent("events.jsonl")) {
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                if let e = try? HostWire.decoder.decode(HostEvent.self, from: Data(line)) { events.append(e) }
            }
        }
        let console = (try? Data(contentsOf: dir.appendingPathComponent("console.log"))).map(consoleLines) ?? []
        return BootLogRecord(name: name, info: info, events: events, console: console)
    }

    static func consoleLines(_ d: Data) -> [String] {
        var lines = String(decoding: d, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// Write one boot (atomically: a temporary directory renamed into place), then keep the newest `keep`.
    static func write(_ layout: StoreLayout, info: BootLogInfo, events: [HostEvent], console: Data, keep: Int) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: layout.sandboxDirectory.path) else { return }       // removed meanwhile
        let root = directory(layout)
        if !fm.fileExists(atPath: root.path) { try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let tmp = root.appendingPathComponent(".\(info.id).tmp")
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var lines = Data()
            for e in events.prefix(maximumEvents) { lines.append(try HostWire.encoder.encode(e)); lines.append(0x0A) }
            try SavedScreens.writePrivate(lines, to: tmp.appendingPathComponent("events.jsonl"))
            try SavedScreens.writePrivate(console.count > maximumConsoleBytes ? Data(console.suffix(maximumConsoleBytes)) : console,
                                          to: tmp.appendingPathComponent("console.log"))
            try SavedScreens.writePrivate(try HostWire.encoder.encode(info), to: tmp.appendingPathComponent("boot.json"))
            let final = root.appendingPathComponent(info.id)
            try? fm.removeItem(at: final)
            try fm.moveItem(at: tmp, to: final)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        prune(layout, keep: keep)
    }

    /// Keep the newest `keep` boots (at least one).
    static func prune(_ layout: StoreLayout, keep: Int) {
        let root = directory(layout)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter(isID).sorted(by: >)
        for n in names.dropFirst(max(1, keep)) { try? FileManager.default.removeItem(at: root.appendingPathComponent(n)) }
    }

    /// The boot as the boot view drew it — its finished lines (✓/✗ steps with their times, downloads,
    /// notes; the same `ProgressBoard` + `ProgressTerminal` formatting), then its kernel console made
    /// inert — as terminal text (CRLF lines; ANSI styling when `color`).
    public static func render(_ r: BootLogRecord, mode: ProgressMode = .animated, color: Bool = true, steps: Bool = true, console: Bool = true) -> String {
        let term = ProgressTerminal(mode: mode, color: color, plainPrefix: "[doz] ", plainStyle: "2")
        let board = term.board
        func bold(_ s: String) -> String { color ? "\u{1B}[1m" + s + "\u{1B}[0m" : s }
        func dim(_ s: String) -> String { color ? "\u{1B}[2m" + s + "\u{1B}[0m" : s }
        var out = ""
        if steps {
            let when = ISO8601DateFormatter.string(from: r.info.startedAt, timeZone: .current, formatOptions: [.withFullDate, .withFullTime, .withSpaceBetweenDateAndTime])
            out += bold("── \(r.info.kind) of \(r.name) · \(when) ──") + "\r\n"
            var last = r.info.startedAt
            for e in r.events {
                last = e.time
                for f in board.apply(e, now: e.time) { out += term.format(f) + "\r\n" }
            }
            for f in board.finishAll(now: last) { out += term.format(f) + "\r\n" }
            let took = r.info.milliseconds.map { " in " + ProgressFormat.duration($0 / 1000) } ?? ""
            switch r.info.result {
            case "ok": out += (color ? "\u{1B}[32m✓\u{1B}[0m " : "✓ ") + "booted\(took)" + "\r\n"
            case "failed": out += (color ? "\u{1B}[31m✗ failed\u{1B}[0m" : "✗ failed") + took + (r.info.error.map { " — " + ProgressFormat.inert($0, limit: 400) } ?? "") + "\r\n"
            default: out += dim("… still booting") + "\r\n"
            }
        }
        if console {
            if steps { out += bold("── kernel console (\(r.console.count) lines) ──") + "\r\n" }
            for l in r.console { out += inert(l) + "\r\n" }
        }
        return out
    }

    /// Guest text as it may be shown: every control character removed (a tab is a space), ≤ 1000 bytes.
    static func inert(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var bytes = 0
        for u in s.unicodeScalars {
            if (u.value < 0x20 && u.value != 0x09) || (0x7F...0x9F).contains(u.value) { continue }
            bytes += String(u).utf8.count
            if bytes > 1000 { break }
            out.append(u == "\t" ? " " : u)
        }
        return String(out)
    }
}

/// One boot being recorded by the host: the sandbox's events from its start, and where its console
/// began (a wake appends to `bootlog.log`; a cold boot starts it afresh).
final class BootRecorder: @unchecked Sendable {
    let id: String
    let kind: String
    let startedAt: Date
    let consoleOffset: UInt64
    private let lock = NSLock()
    private var events: [HostEvent] = []

    init(kind: String, bootLog: URL, now: Date = Date()) {
        id = BootLogs.newID(now)
        self.kind = kind
        startedAt = now
        consoleOffset = kind == "cold boot" ? 0 : (((try? FileManager.default.attributesOfItem(atPath: bootLog.path))?[.size] as? NSNumber)?.uint64Value ?? 0)
    }

    /// The events a boot view draws (never a connection record or a console line: the console is kept whole).
    func record(_ e: HostEvent) {
        switch e.kind {
        case .connection, .console, .host: return
        default: break
        }
        lock.withLock { if events.count < BootLogs.maximumEvents { events.append(e) } }
    }

    var snapshot: [HostEvent] { lock.withLock { events } }

    /// That boot's console so far: the bytes of `bootlog.log` from where it began (all of it when the
    /// file was started afresh — shorter than the offset).
    func console(_ bootLog: URL) -> Data {
        guard let d = try? Data(contentsOf: bootLog) else { return Data() }
        return UInt64(d.count) >= consoleOffset ? Data(d.dropFirst(Int(consoleOffset))) : d
    }

    func info(result: String, error: String?, console: Int, now: Date = Date()) -> BootLogInfo {
        BootLogInfo(id: id, kind: kind, startedAt: startedAt, milliseconds: result == "running" ? nil : now.timeIntervalSince(startedAt) * 1000,
                     result: result, error: error, events: snapshot.count, consoleBytes: console)
    }
}
