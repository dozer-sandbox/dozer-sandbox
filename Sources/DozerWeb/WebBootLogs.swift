import Foundation
import DozerKit
import DozerHost

// 593 (owner, 2026-09-30: "where is the bootup terminal output stored so i can look at it after the
// machine has booted") — the web UI's Boot log: two typed read routes over the host's `boot-log`, as
// PROJECTIONS. One boot is rendered by the ONE boot-view renderer (`BootLogs.render`: the steps as the
// boot view drew them, then the kernel console made inert) into terminal text the page draws in its
// sandboxed frame, read-only — exactly like a saved screen. No new action.
//
//   GET /api/v1/sandboxes/{name}/boots        → WebBootList
//   GET /api/v1/sandboxes/{name}/boots/{n}    → WebBootLog   (1 = the latest)

public struct WebBootInfo: Codable, Equatable, Sendable {
    public var number: Int
    /// `cold boot`, `wake` or `restore after crash`.
    public var kind: String
    public var startedAt: Date
    public var milliseconds: Double?
    /// `ok`, `failed` or `running`.
    public var result: String
    public var error: String?

    public init(_ i: BootLogInfo) {
        number = i.number ?? 0
        kind = i.kind
        startedAt = i.startedAt
        milliseconds = i.milliseconds
        result = i.result
        error = i.error.map { String($0.prefix(400)) }
    }
}

public struct WebBootList: Codable, Equatable, Sendable {
    public var boots: [WebBootInfo]
    public init(_ l: BootLogList) { boots = l.boots.map(WebBootInfo.init) }
}

public struct WebBootLog: Codable, Equatable, Sendable {
    public var info: WebBootInfo
    /// The boot as terminal text (base64): its steps, then its kernel console — every guest byte inert.
    public var vt: String
    public var consoleLines: Int

    public init(_ r: BootLogRecord) {
        info = WebBootInfo(r.info)
        let text = BootLogs.render(r, mode: .animated, color: true, steps: true, console: true)
        vt = Data(text.utf8).prefix(SavedScreens.maximumVTBytes).base64EncodedString()
        consoleLines = r.console.count
    }
}
