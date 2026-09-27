import Foundation
import SnoozeHost

/// "Open in Terminal" (590 phase 2, owner ruling D10: Terminal.app only). The page asks
/// (`POST /api/v1/sandboxes/{name}/terminal`, CSRF-checked); this process asks Terminal.app to run
///
///     exec '<this snooze>' attach NAME [SESSION] --store '<store>'
///
/// No ticket (unlike DeckStack 503's `terminal attach`): `snooze attach` redeems nothing — the
/// terminal runs as the same user, whose host.sock it already may open. So the Apple Event carries
/// no capability and no secret: a fixed verb, a name and a session that passed their allowlists,
/// and single-quoted paths. The command reaches AppleScript as an ARGUMENT of a fixed script
/// (`on run argv`), never spliced into its source.
public enum TerminalHandoff {
    /// The fixed script. `item 1 of argv` is the command; nothing else varies.
    public static let script = """
    on run argv
        tell application "Terminal"
            activate
            do script (item 1 of argv)
        end tell
    end run
    """

    public static func command(executable: String, store: SnoozeStore, sandbox: String, session: String?) -> String {
        var c = "exec \(shellQuote(executable)) attach \(sandbox)"
        if let session { c += " \(session)" }
        return c + " --store \(shellQuote(store.root.path))"
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Run the fixed script with `osascript` (20 s: the first use waits on macOS's Automation prompt).
    @Sendable public static func openInTerminalApp(_ command: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"] + [command]
        let input = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errors
        try p.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(20)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning {
            p.terminate()
            throw Failure(message: "Terminal did not answer within 20 s — is macOS asking whether snooze may control Terminal? Allow it, then try again.")
        }
        guard p.terminationStatus == 0 else {
            let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if err.contains("-1743") || err.lowercased().contains("not authorized") {
                throw Failure(message: "macOS did not allow snooze to control Terminal: System Settings › Privacy & Security › Automation — allow Terminal for the app that runs snooze ui, then try again.")
            }
            throw Failure(message: "Terminal could not be opened (osascript exit \(p.terminationStatus)).")
        }
    }
}

/// CSV for a spreadsheet: a cell that begins with = + - @ (or a tab / CR) is run as a formula by
/// Excel, Numbers and Sheets, and metric rows hold names and error text a sandbox influenced — so
/// such cells get a leading apostrophe (OWASP's CSV-injection defence). Numbers are left alone.
enum WebCSV {
    static func cell(_ s: String?) -> String? {
        guard let s, let f = s.first, "=+-@\t\r".contains(f), Double(s) == nil else { return s }
        return "'" + s
    }

    static func defuse(_ e: MetricsEvent) -> MetricsEvent {
        var e = e
        e.appVersion = cell(e.appVersion)
        e.machine = cell(e.machine)
        e.macOS = cell(e.macOS)
        e.sandbox = cell(e.sandbox)
        e.image = cell(e.image)
        e.action = cell(e.action) ?? e.action
        e.phaseBefore = cell(e.phaseBefore)
        e.phaseAfter = cell(e.phaseAfter)
        e.error = cell(e.error)
        e.detailJSON = cell(e.detailJSON)
        return e
    }
}
