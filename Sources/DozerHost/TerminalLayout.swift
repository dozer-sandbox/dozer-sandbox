import Darwin
import Foundation
import DozerKit

/// 593 §9 (S1, owner 2026-09-29): a sandbox's terminal layout — which panes the web UI shows, split or
/// not, and which session each tab shows — kept by the HOST beside `doz.json`, so a UI restart, a
/// reload or another browser shows the same panes. (It lived only in the browser: after a UI restart
/// every page said "No terminal open" although the sessions were alive.)
///
/// Closed and small: one or two panes, at most `maximumTabs` tabs each, every session name the host's
/// rule, a mode of two. `validate()` is the one check — the web route decodes strictly and the host
/// validates again before it writes.
public struct TerminalLayout: Codable, Equatable, Sendable {
    public struct Tab: Codable, Equatable, Sendable {
        public var session: String
        /// `interactive` (keys reach the session) or `watch` (read-only, never resizes it).
        public var mode: String
        public init(session: String, mode: String = "interactive") {
            self.session = session
            self.mode = mode
        }
    }

    public struct Pane: Codable, Equatable, Sendable {
        public var tabs: [Tab]
        /// The selected tab's index (nil: none).
        public var selected: Int?
        public init(tabs: [Tab], selected: Int? = nil) {
            self.tabs = tabs
            self.selected = selected
        }
    }

    public static let maximumTabs = 16
    public static let modes: Set<String> = ["interactive", "watch"]

    public var split: Bool
    public var focusedPane: Int
    public var panes: [Pane]
    /// When it was written (the host sets it).
    public var updatedAt: Date?

    public init(split: Bool = false, focusedPane: Int = 0, panes: [Pane], updatedAt: Date? = nil) {
        self.split = split
        self.focusedPane = focusedPane
        self.panes = panes
        self.updatedAt = updatedAt
    }

    public func validate() throws {
        guard (1...2).contains(panes.count) else { throw HostError(.invalid, "a layout has one or two panes") }
        guard split == (panes.count == 2) else { throw HostError(.invalid, "a split layout has two panes, an unsplit one one") }
        guard (0..<panes.count).contains(focusedPane) else { throw HostError(.invalid, "focusedPane is a pane's index") }
        for p in panes {
            guard p.tabs.count <= Self.maximumTabs else { throw HostError(.invalid, "at most \(Self.maximumTabs) tabs a pane") }
            if let s = p.selected { guard (0..<p.tabs.count).contains(s) else { throw HostError(.invalid, "selected is a tab's index") } }
            for t in p.tabs {
                guard Self.modes.contains(t.mode) else { throw HostError(.invalid, "a tab's mode is interactive or watch") }
                do { try GuestCommand.validateSessionName(t.session) } catch { throw HostError(.invalid, "a tab's session is 1–64 of [A-Za-z0-9._-]") }
            }
        }
    }

    // MARK: the file

    /// The stored layout (nil: none, or one that no longer validates).
    public static func read(_ store: DozerStore, _ name: String) -> TerminalLayout? {
        guard let d = try? Data(contentsOf: store.terminalLayoutFile(name)),
              let l = try? HostWire.decoder.decode(TerminalLayout.self, from: d), (try? l.validate()) != nil else { return nil }
        return l
    }

    /// Write it (nil: remove it) — atomically, 0600, and only into a sandbox `doz create` made: a layout
    /// never re-creates the directory of a removed sandbox.
    public static func write(_ layout: TerminalLayout?, _ store: DozerStore, _ name: String) throws {
        let url = store.terminalLayoutFile(name)
        guard FileManager.default.fileExists(atPath: store.configFile(name).path) else {
            throw HostError(.notFound, "no sandbox \(name) (doz ls)")
        }
        guard var l = layout else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try l.validate()
        l.updatedAt = Date()
        let data = try HostWire.encoder.encode(l)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".terminal-layout.\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HostError(.failed, "cannot write the terminal layout of \(name)") }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        close(fd)
        guard written == data.count, rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw HostError(.failed, "cannot write the terminal layout of \(name)")
        }
    }
}
