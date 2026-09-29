import Foundation
import DozerKit
import DozerHost

// 593 §9 — session memory in the web UI: the saved screens (S3) and the terminal layout (S1), as
// PROJECTIONS (field by field — never a host result passed through) and one STRICT decoder. Two typed
// read routes and one typed, CSRF-checked write; no new action and no host op reachable as one.
//
//   GET  /api/v1/sandboxes/{name}/sessions/{session}/screen   → WebSavedScreen   (session-screen)
//   GET  /api/v1/sandboxes/{name}/layout                      → WebTerminalLayout or null (terminal-layout)
//   POST /api/v1/sandboxes/{name}/layout                      → the stored layout (terminal-layout-set)
//
// A saved screen's VT came from inside the sandbox (untrusted): the page hands it only to the terminal
// engine in its sandboxed, opaque-origin frame — exactly like live output — never to the DOM.

/// A session's last saved screen, for the page's read-only terminal.
public struct WebSavedScreen: Codable, Equatable, Sendable {
    public var session: String
    public var savedAt: Date
    /// `pause`, `sleep`, `hibernate` or `periodic`.
    public var reason: String
    public var cols: UInt16?
    public var rows: UInt16?
    public var screen: String?
    public var command: String
    public var truncated: Bool
    /// The SNAPSHOT (VT bytes), base64 — at most `SavedScreens.maximumVTBytes` before encoding.
    public var vt: String

    public init(_ s: SessionScreen) {
        session = s.session
        savedAt = s.savedAt
        reason = s.reason
        cols = s.cols
        rows = s.rows
        screen = s.screen
        command = s.command
        truncated = s.truncated
        vt = s.vt.prefix(SavedScreens.maximumVTBytes).base64EncodedString()
    }
}

/// A sandbox's terminal layout as the page reads and writes it.
public struct WebTerminalLayout: Codable, Equatable, Sendable {
    public struct Tab: Codable, Equatable, Sendable {
        public var session: String
        public var mode: String
    }
    public struct Pane: Codable, Equatable, Sendable {
        public var tabs: [Tab]
        public var selected: Int?
    }
    public var split: Bool
    public var focusedPane: Int
    public var panes: [Pane]
    public var updatedAt: Date?

    public init(_ l: TerminalLayout) {
        split = l.split
        focusedPane = l.focusedPane
        panes = l.panes.map { Pane(tabs: $0.tabs.map { Tab(session: $0.session, mode: $0.mode) }, selected: $0.selected) }
        updatedAt = l.updatedAt
    }

    /// The page's `POST …/layout` body, STRICTLY: exactly these fields at each level, each its type;
    /// then the host's own rule (`TerminalLayout.validate`). Every refusal is a fixed message that
    /// never echoes a value.
    public static func decode(_ body: Data) throws -> TerminalLayout {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        func exactly(_ o: [String: Any], _ allowed: Set<String>, _ required: Set<String>, _ what: String) throws {
            let keys = Set(o.keys)
            guard keys.isSubset(of: allowed), required.isSubset(of: keys) else { throw WebAction.Invalid("\(what): unexpected or missing field(s)") }
        }
        func bool(_ v: Any?) -> Bool? {
            guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
            return n.boolValue
        }
        func int(_ v: Any?, _ range: ClosedRange<Int>) -> Int? {
            guard let n = v as? NSNumber, CFGetTypeID(n) == CFNumberGetTypeID(), !CFNumberIsFloatType(n), range.contains(n.intValue) else { return nil }
            return n.intValue
        }
        try exactly(d, ["split", "focusedPane", "panes"], ["split", "focusedPane", "panes"], "layout")
        guard let split = bool(d["split"]) else { throw WebAction.Invalid("split is a boolean") }
        guard let focused = int(d["focusedPane"], 0...1) else { throw WebAction.Invalid("focusedPane is 0 or 1") }
        guard let rawPanes = d["panes"] as? [Any], (1...2).contains(rawPanes.count) else { throw WebAction.Invalid("panes: one or two") }
        var panes: [TerminalLayout.Pane] = []
        for p in rawPanes {
            guard let po = p as? [String: Any] else { throw WebAction.Invalid("a pane is an object") }
            try exactly(po, ["tabs", "selected"], ["tabs"], "pane")
            guard let rawTabs = po["tabs"] as? [Any], rawTabs.count <= TerminalLayout.maximumTabs else {
                throw WebAction.Invalid("tabs: at most \(TerminalLayout.maximumTabs) a pane")
            }
            var selected: Int?
            if let s = po["selected"], !(s is NSNull) {
                guard let i = int(s, 0...(TerminalLayout.maximumTabs - 1)) else { throw WebAction.Invalid("selected is a tab's index") }
                selected = i
            }
            var tabs: [TerminalLayout.Tab] = []
            for t in rawTabs {
                guard let to = t as? [String: Any] else { throw WebAction.Invalid("a tab is an object") }
                try exactly(to, ["session", "mode"], ["session", "mode"], "tab")
                guard let s = to["session"] as? String, s.utf8.count <= 64, (try? GuestCommand.validateSessionName(s)) != nil else {
                    throw WebAction.Invalid("session: 1–64 of letters, digits . _ - (not starting with .)")
                }
                guard let m = to["mode"] as? String, TerminalLayout.modes.contains(m) else { throw WebAction.Invalid("mode: interactive or watch") }
                tabs.append(.init(session: s, mode: m))
            }
            panes.append(.init(tabs: tabs, selected: selected))
        }
        let layout = TerminalLayout(split: split, focusedPane: focused, panes: panes)
        do { try layout.validate() } catch let e as HostError { throw WebAction.Invalid(e.message) }
        return layout
    }
}
