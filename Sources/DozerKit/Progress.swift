import Containerization
import ContainerizationExtras
import ContainerizationOCI
import Foundation

// 593 (owner: "make these setup console outputs more interactive; add spinners when waiting and
// download progress if possible") — the library's half: a pull's progress in bytes and layers, and a
// bake step's live output, both RATE-LIMITED (at most 4 events a second) and, for guest text, made
// inert (every control character removed) and capped before anything outside the library sees it.

/// Guest text made inert: control characters (C0 but tab, ESC, DEL, C1) removed, a tab as a space,
/// at most `limit` characters (then "…"). A `\r` progress redraw keeps only what follows its last `\r`.
public enum InertText {
    public static func line(_ s: Substring, limit: Int = 200) -> String {
        let afterCR = s.split(separator: "\r", omittingEmptySubsequences: false).last ?? s
        var out = String.UnicodeScalarView()
        var n = 0
        // An escape sequence's parameters are not text either: ESC [ … final byte (CSI); ESC ] / P /
        // _ / ^ / X … BEL or ESC \ (OSC, DCS, APC, PM, SOS); ESC and one byte otherwise.
        enum State { case text, escape, csi, string, stringEscape }
        var state = State.text
        for u in afterCR.unicodeScalars {
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
            if (u.value < 0x20 && u != "\t") || (0x7F...0x9F).contains(u.value) { continue }
            if n == limit { out.append("…"); break }
            out.append(u == "\t" ? " " : u)
            n += 1
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }
}

/// A bake step's output → `.output` lines: split on newlines, each made inert, blank ones dropped,
/// and at most `perSecond` a second (the latest line wins; `flush` sends the last one held back).
public final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = Data()
    private var held: String?
    private var lastSent = Date.distantPast
    private let minimumInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let emit: @Sendable (String) -> Void
    private static let maximumPartial = 16 << 10

    public init(perSecond: Double = 4, now: @escaping @Sendable () -> Date = Date.init, emit: @escaping @Sendable (String) -> Void) {
        minimumInterval = 1 / perSecond
        self.now = now
        self.emit = emit
    }

    public func add(_ data: Data) {
        var out: String?
        lock.withLock {
            partial.append(data)
            var lines: [Substring] = []
            let text = String(decoding: partial, as: UTF8.self)
            let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
            lines = Array(parts.dropLast())
            let rest = parts.last.map(String.init) ?? ""
            partial = Data(rest.utf8.suffix(Self.maximumPartial))
            // A progress bar redrawn with \r (npm, apt) is a line too, as it stands now.
            let live = rest.contains("\r") ? [Substring(rest)] : []
            for l in (lines + live).reversed() {
                let s = InertText.line(l)
                if !s.isEmpty { held = s; break }
            }
            let t = now()
            if let h = held, t.timeIntervalSince(lastSent) >= minimumInterval {
                out = h
                held = nil
                lastSent = t
            }
        }
        if let out { emit(out) }
    }

    /// Send the line still held back (the step ended).
    public func flush() {
        let out: String? = lock.withLock {
            defer { held = nil }
            if held == nil, !partial.isEmpty {
                let s = InertText.line(Substring(String(decoding: partial, as: UTF8.self)))
                partial = Data()
                return s.isEmpty ? nil : s
            }
            return held
        }
        if let out { emit(out) }
    }
}

/// An OCI pull's progress events (Containerization's `ProgressHandler`) → `.transfer` events with
/// the running totals, at most 4 a second, and always the last.
public final class PullMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var done: Int64 = 0, total: Int64 = 0, items = 0, totalItems = 0
    private var lastSent = Date.distantPast
    private let label: String
    private let events: @Sendable (SandboxEvent) -> Void
    private let now: @Sendable () -> Date

    public init(label: String, now: @escaping @Sendable () -> Date = Date.init, events: @escaping @Sendable (SandboxEvent) -> Void) {
        self.label = label
        self.now = now
        self.events = events
    }

    public func add(_ batch: [ProgressEvent]) {
        let e: SandboxEvent? = lock.withLock {
            for ev in batch {
                switch ev {
                case .addSize(let v): done += v
                case .addTotalSize(let v): total += v
                case .addItems(let v): items += v
                case .addTotalItems(let v): totalItems += v
                }
            }
            let t = now()
            guard t.timeIntervalSince(lastSent) >= 0.25 else { return nil }
            lastSent = t
            return snapshotLocked()
        }
        if let e { events(e) }
    }

    public func finish() {
        let e = lock.withLock { snapshotLocked() }
        events(e)
    }

    private func snapshotLocked() -> SandboxEvent {
        .transfer(label, completedBytes: done, totalBytes: total > 0 ? max(total, done) : nil,
                  completedItems: items, totalItems: totalItems > 0 ? totalItems : nil)
    }
}

extension ImageBaker {
    /// Pull `reference` for linux/arm64 with its progress as `.transfer` events (bytes and layers, at
    /// most 4 a second, and always the last). Every pull Dozer makes goes through here: a pull without a
    /// meter is silent for as long as it takes (the lab's first boot and the guest init image were —
    /// a first `doz exec` showed nothing for 18 s), and a nil platform downloads every platform's layers.
    public static func pull(_ reference: String, store: ImageStore, label: String? = nil,
                            events: @escaping @Sendable (SandboxEvent) -> Void) async throws -> Containerization.Image {
        let meter = PullMeter(label: label ?? "pulling \(shortReference(reference))", events: events)
        let img = try await store.pull(reference: reference, platform: Platform(arch: "arm64", os: "linux"), progress: { batch in meter.add(batch) },
                                       maxConcurrentDownloads: pullConcurrency)
        meter.finish()
        return img
    }

    /// `docker.io/library/node@sha256:<64 hex>` → `node@<12 hex>` (a person reads the name and a short digest).
    public static func shortReference(_ ref: String) -> String {
        var name = ref, digest: String?
        if let at = ref.firstIndex(of: "@") {
            name = String(ref[..<at])
            let d = ref[ref.index(after: at)...]
            digest = String((d.hasPrefix("sha256:") ? d.dropFirst(7) : d).prefix(12))
        }
        let short = name.split(separator: "/").last.map(String.init) ?? name
        return digest.map { "\(short)@\($0)" } ?? short
    }
}
