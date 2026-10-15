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

/// 617: an image's build log, as the sandbox page's build-log tab draws it (the frame's saved mode, read-only): the steps
/// with their times, then each bake step's whole output — rendered by `BuildLogs.render`, every guest byte inert.
public struct WebBuildLog: Codable, Equatable, Sendable {
    public var image: String
    public var state: String
    public var finishedAt: Date
    public var seconds: Double
    public var steps: Int
    public var error: String?
    /// The log as terminal text (base64).
    public var vt: String
    /// 617 (owner: "show how the image was made including all the commands"): the same record as a document — what the
    /// build-log tab draws (inputs, each step's command and files, the checks, the output). Scrubbed of anything
    /// secret-shaped (`BuildLogs.redact`).
    public var document: BuildLogDocument

    public init(_ l: BuildLog) {
        document = BuildLogs.document(BuildLogs.scrubbed(l))
        image = l.image
        state = l.state
        finishedAt = l.finishedAt
        seconds = l.seconds
        steps = l.steps.count
        error = l.error
        vt = Data(BuildLogs.render(l).utf8).prefix(SavedScreens.maximumVTBytes).base64EncodedString()
    }
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
