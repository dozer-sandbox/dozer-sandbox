import CryptoKit
import Darwin
import Foundation

/// 611 — installing an update: Homebrew's (`brew upgrade <formula>`, a channel switch = uninstall + install of another
/// formula) or a tarball install's own (download → size + sha256 against the SIGNED entry → unpack → the new doz's
/// Developer ID signature and team → its `--version` → an ATOMIC swap of `libexec/doz`, keeping the previous one as
/// `libexec/doz.previous`). A running host keeps its own program (the inode) either way — never overwritten in place
/// (the 591 rule); it switches at `doz host restart`.
public enum UpdateInstaller {
    /// A release's marker file beside the executable (`make release` writes it; `make install-cli` does not) — what
    /// tells a tarball install from a development one.
    public static let releaseMarker = "RELEASE"

    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String
        public init(_ d: String) { description = d }
    }

    // MARK: is now a good time

    /// Nothing would be disturbed: no host runs for `store`, or it runs with no sandbox live (booting, running, paused,
    /// asleep) and no client but the one asking. nil = idle; else why not.
    public static func busyReason(store: DozerStore) -> String? {
        guard store.hostIsRunning() else { return nil }
        guard let m = try? HostClient.request(HostRequest(.ping), store: store, autostart: false), m.ok == true,
              let st = try? (m.result ?? .null).decode(HostStatus.self) else { return "the doz host is busy" }
        if !st.liveSandboxes.isEmpty { return "\(st.liveSandboxes.joined(separator: ", ")) \(st.liveSandboxes.count == 1 ? "is" : "are") running" }
        if st.connections > 1 || st.idleSeconds == nil { return "a session is attached" }
        return nil
    }

    // MARK: Homebrew

    /// `brew`: `DOZ_TEST_BREW` (a fake, in tests), else Homebrew's own places, else the PATH.
    public static func brew(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let t = env["DOZ_TEST_BREW"], !t.isEmpty { return FileManager.default.isExecutableFile(atPath: t) ? t : nil }
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        dirs += (env["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.map { $0 + "/brew" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Run brew with its output passed through to `output` (a terminal's stderr, a test's buffer). Its exit status.
    @discardableResult
    public static func runBrew(_ brew: String, _ args: [String], output: @escaping @Sendable (String) -> Void) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: brew)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_ASK"] = "1"        // Homebrew 7 asks [y/n] before an upgrade; stdin is /dev/null here
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { output(String(decoding: d, as: UTF8.self)) }
        }
        do { try p.run() } catch { output("could not run \(brew): \(error.localizedDescription)\n"); return 127 }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        if !rest.isEmpty { output(String(decoding: rest, as: UTF8.self)) }
        return p.terminationStatus
    }

    /// Bring Dozer's tap up to date — ONLY that tap — before `brew upgrade`/`install`: Homebrew refreshes its taps
    /// only now and then (an auto-update at most once a day), so a plain `brew upgrade doz` says "already up to
    /// date" while the signed feed already names a newer doz (owner, on 0.32.0-rc.1). The tap is an ordinary git
    /// clone (`brew --repository TAP`); a fast-forward pull is what `brew update` does for it, without walking every
    /// other tap. Best effort: a failure is said and the upgrade still runs.
    public static func refreshTap(_ tap: String = Distribution.tap, brew: String,
                                  output: @escaping @Sendable (String) -> Void) {
        let collected = Collected()
        guard runBrew(brew, ["--repository", tap], output: { collected.append($0) }) == 0 else { return }
        let path = collected.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDir: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path + "/.git", isDirectory: &isDir) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", path, "pull", "--ff-only", "-q"]
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { p.terminate() }
        if p.terminationStatus != 0 { output("could not refresh the \(tap) tap — upgrading with what Homebrew has\n") }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock(); private var data = ""
        func append(_ s: String) { lock.lock(); data += s; lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// Switch Homebrew formulas (`doz` → `doz-beta` …): they conflict (one `doz` command), so the current one is
    /// uninstalled first — the store and the settings are not Homebrew's and stay — then the new one installed; if
    /// that fails, the previous one is installed again.
    public static func switchFormula(from: String, to: String, tap: String = Distribution.tap, brew: String,
                                     output: @escaping @Sendable (String) -> Void) throws {
        refreshTap(tap, brew: brew, output: output)
        guard runBrew(brew, ["uninstall", from], output: output) == 0 else { throw Failure("brew uninstall \(from) failed — nothing changed") }
        if runBrew(brew, ["install", "\(tap)/\(to)"], output: output) != 0 {
            let back = runBrew(brew, ["install", "\(tap)/\(from)"], output: output) == 0
            throw Failure("brew install \(tap)/\(to) failed — " + (back ? "\(from) is installed again" : "and \(from) could not be installed again: brew install \(tap)/\(from)"))
        }
    }

    // MARK: a tarball install

    /// Download `entry`'s tarball (`download` puts it at the URL given), check it against the signed entry, unpack it,
    /// check the doz in it, and swap it in for `<prefix>/libexec/doz` atomically. Returns the previous one's place.
    /// `allowAdhoc`: tests (their doz is signed ad hoc) — a real update needs Dozer's Developer ID team.
    public static func installTarball(_ entry: UpdateEntry, prefix: URL, allowAdhoc: Bool = false,
                                      download: @Sendable (URL, URL) async throws -> Void) async throws -> URL {
        let fm = FileManager.default
        let libexec = prefix.appendingPathComponent("libexec")
        let current = libexec.appendingPathComponent("doz")
        guard fm.fileExists(atPath: current.appendingPathComponent("doz").path) else { throw Failure("\(current.path)/doz is not there") }
        let work = libexec.appendingPathComponent(".doz-update-\(getpid())")
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        guard let url = URL(string: entry.archive) else { throw Failure("the entry's archive is not a URL") }
        let archive = work.appendingPathComponent(entry.archiveName)
        try await download(url, archive)

        // The bytes are the signed entry's: size and sha256 (the signature covers both).
        let attrs = try fm.attributesOfItem(atPath: archive.path)
        guard (attrs[.size] as? NSNumber)?.intValue == entry.size else { throw Failure("the download is not \(entry.size) bytes — not installed") }
        guard try sha256(of: archive) == entry.sha256.lowercased() else { throw Failure("the download's sha256 is not the signed one — not installed") }

        let unpacked = work.appendingPathComponent("unpacked")
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        guard run("/usr/bin/tar", ["-xzf", archive.path, "-C", unpacked.path]).status == 0 else { throw Failure("the download does not unpack") }
        let top = unpacked.appendingPathComponent("doz-\(entry.version)")
        let newDir = top.appendingPathComponent("libexec/doz")
        let newDoz = newDir.appendingPathComponent("doz")
        guard fm.isExecutableFile(atPath: newDoz.path) else { throw Failure("the download has no libexec/doz/doz") }

        // The doz in it: a valid signature (strict), Dozer's team (unless a test), and the version it says.
        guard run("/usr/bin/codesign", ["--verify", "--strict", newDoz.path]).status == 0 else { throw Failure("the new doz's signature does not verify — not installed") }
        if !allowAdhoc {
            let info = run("/usr/bin/codesign", ["-dv", "--verbose=2", newDoz.path]).output
            guard info.contains("TeamIdentifier=\(Distribution.teamID)\n") else { throw Failure("the new doz is not signed by Dozer's Developer ID (team \(Distribution.teamID)) — not installed") }
        }
        let said = run(newDoz.path, ["--version"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard said == entry.version else { throw Failure("the new doz says \(said), not \(entry.version) — not installed") }

        // The swap: the new folder beside the current one, then ONE atomic exchange (renamex_np RENAME_SWAP) — a
        // running host keeps its open program; nothing is ever half-installed. The previous one stays as doz.previous.
        let staged = libexec.appendingPathComponent("doz.new")
        try? fm.removeItem(at: staged)
        try fm.moveItem(at: newDir, to: staged)
        guard renamex_np(staged.path, current.path, UInt32(RENAME_SWAP)) == 0 else {
            let why = String(cString: strerror(errno))
            try? fm.removeItem(at: staged)
            throw Failure("could not swap the new doz in (\(why)) — the installed one is unchanged")
        }
        let previous = libexec.appendingPathComponent("doz.previous")
        try? fm.removeItem(at: previous)
        try fm.moveItem(at: staged, to: previous)
        // bin/doz is a relative link into libexec/doz/doz — the same path before and after.
        let link = prefix.appendingPathComponent("bin/doz")
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil {
            try? fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../libexec/doz/doz")
        }
        return previous
    }

    /// URLSession's download, moved to `to`.
    public static let urlSessionDownload: @Sendable (URL, URL) async throws -> Void = { url, to in
        let (tmp, resp) = try await URLSession(configuration: .ephemeral).download(from: url)
        guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else { throw Failure("the download answered \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
        try? FileManager.default.removeItem(at: to)
        try FileManager.default.moveItem(at: tmp, to: to)
    }

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (127, "") }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }
}
