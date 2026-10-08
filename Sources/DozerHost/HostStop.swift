import Foundation

// 594 W22 (owner: "doz host stop seems to run with delay but its no doubt hibernating vms. we need some
// progress"): what `host-stop` did, as data — streamed as it happens (one `started` and one `step` or
// `failed` per sandbox, then the host's own last step) and answered as a `HostStopResult`. Every caller
// that stops a host (`doz host stop`, `doz uninstall`, the web UI's Restart host) shows the same thing,
// through the same progress view (`ProgressBoard`/`ProgressTerminal`).

/// One sandbox the stop handled.
public struct HostStopRow: Codable, Equatable, Sendable {
    public var name: String
    public var phaseBefore: String
    public var phase: String
    /// `hibernated` · `failed` (hibernating failed: shut down instead, disk kept) · `kept` (a failed
    /// wake's snapshot kept for the next host) · `shut-down` (it was booting or failed).
    public var outcome: String
    public var milliseconds: Double
    public var error: String?
    /// The snapshot's size on disk, when it hibernated.
    public var snapshotBytes: Int64?

    public init(name: String, phaseBefore: String, phase: String, outcome: String, milliseconds: Double, error: String? = nil, snapshotBytes: Int64? = nil) {
        self.name = name
        self.phaseBefore = phaseBefore
        self.phase = phase
        self.outcome = outcome
        self.milliseconds = milliseconds
        self.error = error
        self.snapshotBytes = snapshotBytes
    }
}

/// `host-stop`'s answer (594 W22; before, the string "stopped" — a client reads either).
public struct HostStopResult: Codable, Equatable, Sendable {
    public var stopped: Bool
    public var sandboxes: [HostStopRow]
    public var milliseconds: Double
    public var version: String?

    public init(sandboxes: [HostStopRow], milliseconds: Double, version: String?) {
        stopped = true
        self.sandboxes = sandboxes
        self.milliseconds = milliseconds
        self.version = version
    }
}

public enum HostStopView {
    /// The line a sandbox's hibernation runs under.
    public static func startedText(_ name: String) -> String { "hibernating \(name)" }

    public static func started(_ name: String) -> HostEvent { HostEvent(kind: .started, sandbox: name, text: startedText(name)) }

    /// How one sandbox's part ended, as the event that ends its line.
    public static func finished(_ r: HostStopRow) -> HostEvent {
        var e: HostEvent
        switch r.outcome {
        case "hibernated":
            e = HostEvent(kind: .step, sandbox: r.name, text: "hibernated \(r.name)" + (r.snapshotBytes.map { " (snapshot \(ProgressFormat.bytes($0)))" } ?? ""),
                          milliseconds: r.milliseconds)
        case "failed":
            e = HostEvent(kind: .failed, sandbox: r.name, text: startedText(r.name), milliseconds: r.milliseconds)
            e.error = (r.error ?? "failed") + " — it was shut down instead (its disk is kept; start it again)"
        case "kept":
            e = HostEvent(kind: .step, sandbox: r.name, text: "kept \(r.name)'s snapshot (its wake had failed — the next host tries it again)", milliseconds: r.milliseconds)
        default:
            e = HostEvent(kind: .step, sandbox: r.name, text: "shut down \(r.name) (it was \(r.phaseBefore))", milliseconds: r.milliseconds)
        }
        e.startedAs = startedText(r.name)
        return e
    }

    /// The last line: "host stopped — 2 sandboxes hibernated (hello-dozer, lab1) in 1.2 s; the next
    /// command starts a new host", or "host stopped (nothing was running)".
    public static func summary(_ r: HostStopResult) -> String {
        let rows = r.sandboxes
        if rows.isEmpty { return "host stopped (nothing was running)" }
        func names(_ o: String) -> [String] { rows.filter { $0.outcome == o }.map(\.name) }
        func count(_ n: Int) -> String { n == 1 ? "1 sandbox" : "\(n) sandboxes" }
        var parts: [String] = []
        let hib = names("hibernated")
        if !hib.isEmpty { parts.append("\(count(hib.count)) hibernated (\(hib.joined(separator: ", ")))") }
        let failed = names("failed")
        if !failed.isEmpty { parts.append("\(count(failed.count)) could not be hibernated and \(failed.count == 1 ? "was" : "were") shut down (\(failed.joined(separator: ", ")))") }
        let kept = names("kept")
        if !kept.isEmpty { parts.append("\(kept.joined(separator: ", ")): a failed wake's snapshot kept") }
        let down = names("shut-down")
        if !down.isEmpty { parts.append("shut down \(down.joined(separator: ", "))") }
        return "host stopped — " + parts.joined(separator: "; ") + " in " + ProgressFormat.duration(r.milliseconds / 1000)
            + "; the next command starts a new host"
    }

    /// A stop the caller only partly saw (the host went away before it answered): what the events said.
    public static func seen(_ events: [HostEvent]) -> String {
        let done = events.filter { $0.kind == .step && $0.startedAs != nil }.compactMap(\.sandbox)
        let failed = events.filter { $0.kind == .failed && $0.startedAs != nil }.compactMap(\.sandbox)
        let started = Set(events.filter { $0.kind == .started }.compactMap(\.sandbox))
        let open = started.subtracting(done).subtracting(failed).sorted()
        var s = "the host exited before it answered"
        if !done.isEmpty { s += " — done: \(done.joined(separator: ", "))" }
        if !failed.isEmpty { s += "; failed: \(failed.joined(separator: ", "))" }
        if !open.isEmpty { s += "; unknown (it went away while handling them): \(open.joined(separator: ", ")) — doz ls says where they are" }
        return s
    }
}
