// 585 — the host's lifecycle metrics, ported from SandboxLab (581, `Sources/SandboxLabCore/Metrics.swift`):
// every action the host performs — start, pause/resume, sleep, hibernate, wake, shut down, restore
// points, sessions, the network — with its timing, in `<store>/metrics.sqlite`. The SAME schema as
// SandboxLab's, so the two can be analysed side by side.
//
// The system `SQLite3` module only: no new dependency. One connection per store, serialised by a
// lock (the writes are a few rows per action; WAL keeps a reader — `doz metrics` — from blocking
// the host). The schema is versioned by `schema_migrations`; `migrations` only ever grows.
import Foundation
import SQLite3

public enum MetricsError: Error, LocalizedError {
    case sqlite(String)
    public var errorDescription: String? { if case .sqlite(let s) = self { return "metrics database: \(s)" }; return nil }
}

/// Where the metrics live and what one row says.
public enum MetricsKind: String, Sendable, Codable {
    /// Something the host did on request (Start, Wake, Take restore point, open a session…).
    case action
    /// A library step inside an action (the VM boot inside Start, the snapshot restore inside Wake).
    case step
}

/// The host run (or app launch) a row belongs to.
public struct MetricsRunInfo: Sendable, Equatable {
    public var kind: String
    public var appVersion: String
    public var build: String
    public var machine: String
    public var chip: String
    public var macOS: String

    public init(kind: String, appVersion: String, build: String, machine: String, chip: String, macOS: String) {
        self.kind = kind; self.appVersion = appVersion; self.build = build; self.machine = machine; self.chip = chip; self.macOS = macOS
    }

    /// This process: `hw.model`, the CPU brand, the OS version.
    public static func current(kind: String, version: String) -> MetricsRunInfo {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return MetricsRunInfo(kind: kind, appVersion: version, build: version,
                              machine: sysctlString("hw.model"),
                              chip: sysctlString("machdep.cpu.brand_string"),
                              macOS: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
    }
}

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "?" }
    return String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
}

/// One `events` row, joined with its run.
public struct MetricsEvent: Sendable, Equatable, Identifiable, Codable {
    public var id: Int64
    public var run: Int64
    public var parent: Int64?
    public var kind: MetricsKind
    public var sandbox: String?
    public var image: String?
    public var action: String
    public var phaseBefore: String?
    public var phaseAfter: String?
    public var startedAt: Date
    public var durationMs: Double?
    public var ok: Bool?
    public var error: String?
    public var bytes: Int64?
    public var detailJSON: String?
    public var appVersion: String?
    public var machine: String?
    public var macOS: String?
}

/// What `doz metrics` filters by.
public struct MetricsFilter: Sendable, Equatable {
    public var image: String?
    public var since: Date?
    public var includeSteps: Bool
    public var run: Int64?
    public init(image: String? = nil, since: Date? = nil, includeSteps: Bool = true, run: Int64? = nil) {
        self.image = image; self.since = since; self.includeSteps = includeSteps; self.run = run
    }
}

/// Per action: how many, and the distribution of their durations.
public struct MetricsSummaryRow: Sendable, Equatable, Identifiable, Codable {
    public var id: String { "\(kind.rawValue)|\(action)" }
    public var action: String
    public var kind: MetricsKind
    public var count: Int
    public var failed: Int
    public var medianMs: Double?
    public var p90Ms: Double?
    public var minMs: Double?
    public var maxMs: Double?
}

public enum MetricsMath {
    /// The median (the mean of the two middle values for an even count); nil when empty.
    public static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// The nearest-rank percentile: the smallest value with at least `p` of the values at or below it.
    public static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let rank = Int((p * Double(s.count)).rounded(.up))
        return s[min(max(rank, 1), s.count) - 1]
    }

    /// Group by (kind, action): count, failed, and median / p90 / min / max over the durations that
    /// were recorded. Actions first, then steps; alphabetical within each.
    public static func summarize(_ events: [MetricsEvent]) -> [MetricsSummaryRow] {
        var groups: [String: (MetricsKind, String, [Double], Int, Int)] = [:]
        for e in events {
            let key = "\(e.kind.rawValue)|\(e.action)"
            var g = groups[key] ?? (e.kind, e.action, [], 0, 0)
            g.3 += 1
            if e.ok == false { g.4 += 1 }
            if let d = e.durationMs { g.2.append(d) }
            groups[key] = g
        }
        return groups.values.map { kind, action, ds, count, failed in
            MetricsSummaryRow(action: action, kind: kind, count: count, failed: failed,
                              medianMs: median(ds), p90Ms: percentile(ds, 0.9), minMs: ds.min(), maxMs: ds.max())
        }
        .sorted { ($0.kind == .action ? 0 : 1, $0.action) < ($1.kind == .action ? 0 : 1, $1.action) }
    }

    /// "812 ms", "1.24 s", "3 min 05 s".
    public static func format(_ ms: Double?) -> String {
        guard let ms else { return "—" }
        if ms < 1 { return String(format: "%.2f ms", ms) }
        if ms < 1000 { return String(format: "%.0f ms", ms) }
        if ms < 60_000 { return String(format: "%.2f s", ms / 1000) }
        let s = Int(ms / 1000)
        return String(format: "%d min %02d s", s / 60, s % 60)
    }
}

/// Maps a DozerKit `.step` label (human text, with variable parts) to a stable key, so the
/// same step aggregates across runs. Unknown labels become `step: other` (the label is kept in the
/// row's detail either way). Kept identical to SandboxLab's.
public enum MetricsStepKey {
    public static func key(for label: String) -> String {
        let l = label
        func has(_ p: String) -> Bool { l.hasPrefix(p) }
        let k: String
        if has("base ") { k = l.contains("(cached)") ? "image cached" : "image pull" }
        else if l.range(of: #"^\S+ ready \((pulled|cached)\)"#, options: .regularExpression) != nil { k = l.contains("(cached)") ? "image cached" : "image pull" }
        else if has("flattened") { k = "flatten" }
        else if has("booted the bake VM") { k = "bake vm boot" }
        else if has("bake network") { k = "bake network" }
        else if has("step: ") { k = "bake step " + String(l.dropFirst(6)) }
        else if has("verify: ") { k = "bake verify" }
        else if has("stopped the bake VM") { k = "bake vm stop" }
        else if has("kernel ") && l.contains("(cached") { k = "kernel cache hit" }
        else if has("downloaded ") { k = "kernel download" }
        else if has("verified and extracted") { k = "kernel extract" }
        else if has("guest init image ready") { k = l.contains("cached") ? "initfs cached" : "initfs pull" }
        else if has("root disk cloned") { k = "clone" }
        else if has("created the empty state disk") { k = "state disk" }
        else if has("e2fsck") { k = "fsck" }
        else if has("restored the VM from its snapshot into this process") { k = "restore after crash" }
        else if has("adopted the restored container") { k = "adopt container" }
        else if has("VM created and booted") { k = "vm boot" }
        else if has("container process started") { k = "container start" }
        else if has("installed deckhold") { k = "deckhold" }
        else if has("prepared the guest") { k = "guest prep" }
        else if has("network: ") { k = "network setup" }
        else if has("paused the VM") { k = "vm pause" }
        else if l == "resumed the VM" { k = "vm resume" }
        else if has("saved VM state to disk") { k = "save state" }
        else if has("hibernate: stopped the VM") || l == "stopped the VM" { k = "vm stop" }
        else if has("resumed the VM to stop it") || has("restored the VM to stop it") { k = "stop prep" }
        else if has("stopped the container") { k = "container stop" }
        else if has("restored VM state from disk") { k = "restore state" }
        else if l == "resumed" { k = "resume after restore" }
        else if has("re-synced the guest clock") { k = "clock resync" }
        else if has("re-mounted") { k = "remount shares" }
        else if has("restore point ") && l.contains("sync → pause") { k = "restore point clone (running)" }
        else if has("restore point ") { k = "restore point clone" }
        else if has("reverted to") { k = "revert clone" }
        else { k = "other" }
        return "step: " + k
    }
}

public final class MetricsStore: @unchecked Sendable {
    /// Every schema version, in order. Append; never edit a shipped entry.
    static let migrations: [(version: Int, sql: [String])] = [
        (1, [
            """
            CREATE TABLE runs (id INTEGER PRIMARY KEY AUTOINCREMENT, started_at REAL NOT NULL, kind TEXT NOT NULL,
              app_version TEXT, build TEXT, machine TEXT, chip TEXT, macos TEXT, pid INTEGER)
            """,
            """
            CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, run INTEGER NOT NULL REFERENCES runs(id),
              parent INTEGER, kind TEXT NOT NULL DEFAULT 'action', sandbox TEXT, image TEXT, action TEXT NOT NULL,
              phase_before TEXT, phase_after TEXT, started_at REAL NOT NULL, duration_ms REAL, ok INTEGER,
              error TEXT, bytes INTEGER, detail_json TEXT)
            """,
            "CREATE INDEX events_action ON events(action)",
            "CREATE INDEX events_started ON events(started_at)",
            """
            CREATE TABLE sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, run INTEGER NOT NULL REFERENCES runs(id),
              sandbox TEXT, image TEXT, session TEXT NOT NULL, command TEXT, opened_at REAL NOT NULL, open_ms REAL,
              first_attach_ms REAL, first_screen_ms REAL, ended_at REAL, exit_code INTEGER)
            """,
            """
            CREATE TABLE network (run INTEGER NOT NULL REFERENCES runs(id), sandbox TEXT NOT NULL, minute INTEGER NOT NULL,
              allowed INTEGER NOT NULL DEFAULT 0, denied INTEGER NOT NULL DEFAULT 0, failed INTEGER NOT NULL DEFAULT 0,
              bytes_up INTEGER NOT NULL DEFAULT 0, bytes_down INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (run, sandbox, minute))
            """,
        ]),
    ]
    public static var currentSchemaVersion: Int { migrations.last?.version ?? 0 }

    public let url: URL
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var h: OpaquePointer?
        guard sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(h)
            throw MetricsError.sqlite("\(url.path): \(msg)")
        }
        db = h
        sqlite3_busy_timeout(h, 2000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    // MARK: schema

    /// The highest applied migration (0 for a new file).
    public var schemaVersion: Int {
        (try? query("SELECT COALESCE(MAX(version), 0) FROM schema_migrations", []) { Int(sqlite3_column_int64($0, 0)) }.first) ?? 0
    }

    private func migrate() throws {
        try exec("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL)")
        let have = schemaVersion
        for m in Self.migrations where m.version > have {
            try exec("BEGIN IMMEDIATE")
            do {
                for s in m.sql { try exec(s) }
                try execute("INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)", [.int(Int64(m.version)), .real(Date().timeIntervalSince1970)])
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: writes

    /// A new run (this host process); every row below carries its id.
    @discardableResult
    public func beginRun(_ info: MetricsRunInfo, at date: Date = Date()) -> Int64 {
        (try? insert("INSERT INTO runs (started_at, kind, app_version, build, machine, chip, macos, pid) VALUES (?,?,?,?,?,?,?,?)",
                     [.real(date.timeIntervalSince1970), .text(info.kind), .text(info.appVersion), .text(info.build),
                      .text(info.machine), .text(info.chip), .text(info.macOS), .int(Int64(getpid()))])) ?? 0
    }

    /// An action starting (its duration and outcome come with `finish`). Returns its id, the
    /// `parent` of the library steps recorded while it runs.
    @discardableResult
    public func begin(run: Int64, action: String, kind: MetricsKind = .action, sandbox: String?, image: String?,
                      phaseBefore: String?, startedAt: Date = Date(), parent: Int64? = nil) -> Int64 {
        (try? insert("""
            INSERT INTO events (run, parent, kind, sandbox, image, action, phase_before, started_at) VALUES (?,?,?,?,?,?,?,?)
            """, [.int(run), parent.map(Value.int) ?? .null, .text(kind.rawValue), .opt(sandbox), .opt(image), .text(action),
                  .opt(phaseBefore), .real(startedAt.timeIntervalSince1970)])) ?? 0
    }

    public func finish(_ id: Int64, phaseAfter: String?, durationMs: Double, ok: Bool, error: String? = nil,
                       bytes: Int64? = nil, detail: [String: String] = [:]) {
        try? execute("""
            UPDATE events SET phase_after = ?, duration_ms = ?, ok = ?, error = ?, bytes = ?, detail_json = ? WHERE id = ?
            """, [.opt(phaseAfter), .real(durationMs), .int(ok ? 1 : 0), .opt(error), bytes.map(Value.int) ?? .null,
                  Self.json(detail).map(Value.text) ?? .null, .int(id)])
    }

    /// A finished row in one go (a library step, a session's first screen).
    @discardableResult
    public func record(run: Int64, action: String, kind: MetricsKind = .action, sandbox: String?, image: String?,
                       phaseBefore: String? = nil, phaseAfter: String? = nil, startedAt: Date, durationMs: Double?,
                       ok: Bool = true, error: String? = nil, bytes: Int64? = nil, detail: [String: String] = [:],
                       parent: Int64? = nil) -> Int64 {
        (try? insert("""
            INSERT INTO events (run, parent, kind, sandbox, image, action, phase_before, phase_after, started_at, duration_ms,
              ok, error, bytes, detail_json) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.int(run), parent.map(Value.int) ?? .null, .text(kind.rawValue), .opt(sandbox), .opt(image), .text(action),
                  .opt(phaseBefore), .opt(phaseAfter), .real(startedAt.timeIntervalSince1970), durationMs.map(Value.real) ?? .null,
                  .int(ok ? 1 : 0), .opt(error), bytes.map(Value.int) ?? .null, Self.json(detail).map(Value.text) ?? .null])) ?? 0
    }

    @discardableResult
    public func sessionOpened(run: Int64, sandbox: String, image: String?, session: String, command: String,
                              openedAt: Date, openMs: Double) -> Int64 {
        (try? insert("""
            INSERT INTO sessions (run, sandbox, image, session, command, opened_at, open_ms) VALUES (?,?,?,?,?,?,?)
            """, [.int(run), .text(sandbox), .opt(image), .text(session), .text(command), .real(openedAt.timeIntervalSince1970), .real(openMs)])) ?? 0
    }

    public func sessionFirstAttach(_ id: Int64, ms: Double) {
        try? execute("UPDATE sessions SET first_attach_ms = ? WHERE id = ? AND first_attach_ms IS NULL", [.real(ms), .int(id)])
    }
    public func sessionFirstScreen(_ id: Int64, ms: Double) {
        try? execute("UPDATE sessions SET first_screen_ms = ? WHERE id = ? AND first_screen_ms IS NULL", [.real(ms), .int(id)])
    }
    public func sessionEnded(_ id: Int64, at date: Date = Date(), exitCode: Int32?) {
        try? execute("UPDATE sessions SET ended_at = ?, exit_code = ? WHERE id = ? AND ended_at IS NULL",
                 [.real(date.timeIntervalSince1970), exitCode.map { .int(Int64($0)) } ?? .null, .int(id)])
    }

    /// Add connection counts and bytes to a sandbox's minute (counts only — never hosts or bodies).
    public func addNetwork(run: Int64, sandbox: String, minute: Int64, allowed: Int, denied: Int, failed: Int, bytesUp: Int, bytesDown: Int) {
        try? execute("""
            INSERT INTO network (run, sandbox, minute, allowed, denied, failed, bytes_up, bytes_down) VALUES (?,?,?,?,?,?,?,?)
            ON CONFLICT(run, sandbox, minute) DO UPDATE SET allowed = allowed + excluded.allowed, denied = denied + excluded.denied,
              failed = failed + excluded.failed, bytes_up = bytes_up + excluded.bytes_up, bytes_down = bytes_down + excluded.bytes_down
            """, [.int(run), .text(sandbox), .int(minute), .int(Int64(allowed)), .int(Int64(denied)), .int(Int64(failed)),
                  .int(Int64(bytesUp)), .int(Int64(bytesDown))])
    }

    // MARK: reads

    public func events(_ f: MetricsFilter = MetricsFilter()) -> [MetricsEvent] {
        var sql = """
            SELECT e.id, e.run, e.parent, e.kind, e.sandbox, e.image, e.action, e.phase_before, e.phase_after, e.started_at,
              e.duration_ms, e.ok, e.error, e.bytes, e.detail_json, r.app_version, r.machine, r.macos
            FROM events e LEFT JOIN runs r ON r.id = e.run WHERE 1=1
            """
        var args: [Value] = []
        if let i = f.image { sql += " AND e.image = ?"; args.append(.text(i)) }
        if let s = f.since { sql += " AND e.started_at >= ?"; args.append(.real(s.timeIntervalSince1970)) }
        if !f.includeSteps { sql += " AND e.kind = 'action'" }
        if let r = f.run { sql += " AND e.run = ?"; args.append(.int(r)) }
        sql += " ORDER BY e.started_at, e.id"
        return (try? query(sql, args) { s in
            MetricsEvent(id: sqlite3_column_int64(s, 0), run: sqlite3_column_int64(s, 1), parent: Self.int(s, 2),
                         kind: MetricsKind(rawValue: Self.text(s, 3) ?? "") ?? .action, sandbox: Self.text(s, 4), image: Self.text(s, 5),
                         action: Self.text(s, 6) ?? "", phaseBefore: Self.text(s, 7), phaseAfter: Self.text(s, 8),
                         startedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 9)), durationMs: Self.real(s, 10),
                         ok: Self.int(s, 11).map { $0 != 0 }, error: Self.text(s, 12), bytes: Self.int(s, 13), detailJSON: Self.text(s, 14),
                         appVersion: Self.text(s, 15), machine: Self.text(s, 16), macOS: Self.text(s, 17))
        }) ?? []
    }

    public func summary(_ f: MetricsFilter = MetricsFilter()) -> [MetricsSummaryRow] { MetricsMath.summarize(events(f)) }

    public struct Counts: Sendable, Equatable, Codable {
        public var runs = 0, events = 0, sessions = 0, networkMinutes = 0
        public init(runs: Int = 0, events: Int = 0, sessions: Int = 0, networkMinutes: Int = 0) {
            self.runs = runs; self.events = events; self.sessions = sessions; self.networkMinutes = networkMinutes
        }
    }
    public func counts() -> Counts {
        func n(_ t: String) -> Int { (try? query("SELECT COUNT(*) FROM \(t)", []) { Int(sqlite3_column_int64($0, 0)) }.first) ?? 0 }
        return Counts(runs: n("runs"), events: n("events"), sessions: n("sessions"), networkMinutes: n("network"))
    }

    // MARK: 595 — Resources

    /// Proxy traffic per sandbox: since `sinceMinute` (minutes since 1970), and in all.
    /// The minutes in [from, to) in which each sandbox's network was used (any connection) — activity, for the usage
    /// statistics' "left running with no activity" count. When only, never where.
    public func activeMinutes(fromMinute: Int64, toMinute: Int64) -> [String: [Int64]] {
        let rows = (try? query("""
            SELECT sandbox, minute FROM network WHERE minute >= ? AND minute < ? AND (allowed + denied + failed) > 0 ORDER BY minute
            """, [.int(fromMinute), .int(toMinute)]) { st in (Self.text(st, 0) ?? "", Self.int(st, 1) ?? 0) }) ?? []
        return Dictionary(grouping: rows, by: \.0).mapValues { $0.map(\.1) }
    }

    public func networkTotals(sinceMinute: Int64) -> [ResourceNetwork] {
        let rows = (try? query("""
            SELECT sandbox, SUM(bytes_up), SUM(bytes_down), SUM(allowed + denied + failed),
                   SUM(CASE WHEN minute >= ? THEN bytes_up ELSE 0 END), SUM(CASE WHEN minute >= ? THEN bytes_down ELSE 0 END)
            FROM network GROUP BY sandbox ORDER BY sandbox
            """, [.int(sinceMinute), .int(sinceMinute)]) { st in
            ResourceNetwork(sandbox: Self.text(st, 0) ?? "?", upToday: Self.int(st, 4) ?? 0, downToday: Self.int(st, 5) ?? 0,
                            upTotal: Self.int(st, 1) ?? 0, downTotal: Self.int(st, 2) ?? 0, connectionsTotal: Int(Self.int(st, 3) ?? 0))
        }) ?? []
        return rows
    }

    /// Clear the history (Resources › metrics): every row but `keepingRun`'s (the running host's), then
    /// the file shrinks.
    public func clearHistory(keepingRun: Int64?) throws {
        let keep = keepingRun ?? -1
        try execute("DELETE FROM network WHERE run != ?", [.int(keep)])
        try execute("DELETE FROM sessions WHERE run != ?", [.int(keep)])
        try execute("DELETE FROM events WHERE run != ?", [.int(keep)])
        try execute("DELETE FROM runs WHERE id != ?", [.int(keep)])
        try exec("PRAGMA wal_checkpoint(TRUNCATE)")
        try exec("VACUUM")
    }

    // MARK: CSV

    public static let csvHeader = ["id", "run", "app_version", "machine", "macos", "kind", "sandbox", "image", "action", "parent",
                                   "phase_before", "phase_after", "started_at", "duration_ms", "ok", "error", "bytes", "detail_json"]

    /// Every event row matching `f`, as RFC 4180 CSV (a header line, `\n` line ends).
    public func csv(_ f: MetricsFilter = MetricsFilter()) -> String { Self.csv(events(f)) }

    public static func csv(_ events: [MetricsEvent]) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = [csvHeader.joined(separator: ",")]
        for e in events {
            let fields: [String?] = [String(e.id), String(e.run), e.appVersion, e.machine, e.macOS, e.kind.rawValue, e.sandbox, e.image,
                                     e.action, e.parent.map(String.init), e.phaseBefore, e.phaseAfter, iso.string(from: e.startedAt),
                                     e.durationMs.map { String(format: "%.3f", $0) }, e.ok.map { $0 ? "1" : "0" }, e.error,
                                     e.bytes.map(String.init), e.detailJSON]
            lines.append(fields.map { csvField($0 ?? "") }.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func csvField(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: SQLite plumbing

    enum Value {
        case int(Int64), real(Double), text(String), null
        static func opt(_ s: String?) -> Value { s.map(Value.text) ?? .null }
    }

    static func json(_ d: [String: String]) -> String? {
        guard !d.isEmpty, let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func text(_ s: OpaquePointer?, _ i: Int32) -> String? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_text(s, i).map { String(cString: $0) }
    }
    private static func int(_ s: OpaquePointer?, _ i: Int32) -> Int64? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_int64(s, i)
    }
    private static func real(_ s: OpaquePointer?, _ i: Int32) -> Double? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i)
    }

    private func errorMessage() -> String { String(cString: sqlite3_errmsg(db)) }

    private func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw MetricsError.sqlite(errorMessage()) }
    }

    private func prepare(_ sql: String, _ args: [Value]) throws -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw MetricsError.sqlite(errorMessage()) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .int(let v): sqlite3_bind_int64(st, idx, v)
            case .real(let v): sqlite3_bind_double(st, idx, v)
            case .text(let v): sqlite3_bind_text(st, idx, v, -1, Self.transient)
            case .null: sqlite3_bind_null(st, idx)
            }
        }
        return st
    }

    private func execute(_ sql: String, _ args: [Value]) throws {
        lock.lock(); defer { lock.unlock() }
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_DONE else { throw MetricsError.sqlite(errorMessage()) }
    }

    private func insert(_ sql: String, _ args: [Value]) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_DONE else { throw MetricsError.sqlite(errorMessage()) }
        return sqlite3_last_insert_rowid(db)
    }

    private func query<T>(_ sql: String, _ args: [Value], _ row: (OpaquePointer?) -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW { out.append(row(st)); continue }
            if rc == SQLITE_DONE { break }
            throw MetricsError.sqlite(errorMessage())
        }
        return out
    }
}
