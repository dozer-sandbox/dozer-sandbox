import Darwin
import Foundation
import DozerKit

// 599b (owner, 2026-10-01: "the agent can open files in the workspace that will open in the default (or
// specific) app on the mac ; e.g. html page will open in a browser, same with markdown"): the browser
// bridge's guest shim (`xdg-open`, `open`, `doz-open`) now hands over a FILE as well as a URL — the same
// OSC 6340 marker on the session's terminal (`doz-file;APP;PATH`), read by the same attach relay. No new
// guest→host channel. Here the host decides, and it trusts nothing the guest says:
//
//   1. the path (already absolute in the guest) is normalised LEXICALLY and must lie under /workspace;
//   2. it is mapped onto the Mac folder that is actually shared there (the sandbox's spec, never a path
//      from the guest), and resolved ON THE MAC (`realpath`: every symlink, `..`) — the result must stay
//      inside that folder, resolved the same way;
//   3. it must be a regular file (never a folder, so never an app bundle), of a DOCUMENT type (an
//      allow-list of extensions; a never-list for clearer refusals), not executable, without a Mac
//      resource fork, and its first bytes must not be a program (Mach-O, ELF) or a script (`#!`) —
//      read through a descriptor opened with O_NOFOLLOW and checked to be the very file stat'ed;
//   4. a named app must be in the user's `bridges.open_apps`, and the LISTED spelling is what reaches
//      `open -a` — never the guest's text.
//
// Owner, later the same day: "add a command (bridge variation) so the agent in the VM can open the
// workspace (or child dir of) directory in the Finder". A FOLDER — /workspace itself or any folder in it,
// by the same mapping and the same Mac-side resolution — opens in the Finder (`open -a Finder`, so it is
// never taken for an app); a package folder (an app, a bundle: `isPackage`, or a never-list extension)
// is still refused. `doz-open --reveal PATH` (`doz-reveal;PATH`) shows a file selected in its folder
// (`open -R` — nothing is opened, so a file's type is not checked; a package may be shown this way).
//
// Residual risk (said in the security model): the agent can still change the file between the check and
// LaunchServices opening it (a rename race of a few milliseconds). What it could swap in is limited to
// what the shared folder already reaches, and `open` is never given anything but a resolved path.

public enum WorkspaceFiles {
    /// Where the workspace is in the guest.
    public static let guestRoot = DozerImages.workspaceGuestPath
    /// The longest path the host takes.
    public static let maximumPathBytes = 1024
    /// How many file opens a sandbox may ask for in `rateWindow` seconds.
    public static let rateCount = 3
    public static let rateWindow: TimeInterval = 10

    /// The document types that are opened (lowercased extensions) — the library's list, which the guest
    /// shim checks too.
    public static var documentTypes: [String] { GuestCommand.openFileDocumentTypes }

    /// Types that are never opened, whatever else is true (apps, scripts, installers, link files that run
    /// or redirect). Anything not in `documentTypes` is refused too; this list only makes the refusal clear.
    public static var neverTypes: [String] { GuestCommand.openFileNeverTypes }

    /// How a resolved path is shown on the Mac.
    public enum How: String, Equatable, Sendable {
        /// A document, in its default app or the listed one (`open [-a APP] PATH`).
        case app
        /// A folder, in the Finder (`open -a Finder PATH` — never as an app).
        case finder
        /// A file selected in its folder (`open -R PATH` — nothing is opened).
        case reveal
    }

    /// What the host decided.
    public enum Decision: Equatable, Sendable {
        /// Show `macPath` (resolved, inside the shared folder) `how`; `app` (the LISTED spelling; nil: the
        /// default app) only for `.app`. `shown`: the path inside the workspace, as the notice shows it
        /// (a folder ends in `/`; the workspace itself is `the workspace`).
        case open(macPath: String, shown: String, app: String?, how: How)
        /// `kind`: `file-off` or `file-refused`; `why` is said after the request.
        case refused(kind: String, why: String)
    }

    // MARK: the decision

    /// The whole decision but the rate limit: the setting, isolation, the app, the path, the type and
    /// content. `workspace`: the Mac folder shared at /workspace (nil: an isolated sandbox). `reveal`:
    /// `doz-open --reveal` — a file shown selected in its folder, a folder shown.
    public static func decide(guestPath: String, app: String?, reveal: Bool = false, workspace: String?, enabled: Bool,
                              allowedApps: [String]) -> Decision {
        guard enabled else {
            return .refused(kind: "file-off", why: "opening files is off for it (sandbox.open_files)")
        }
        guard let workspace else {
            return .refused(kind: "file-refused", why: "it is isolated: nothing on this Mac is shared")
        }
        var listed: String?
        if let app {
            if reveal { return .refused(kind: "file-refused", why: "--app with --reveal: a file is shown in the Finder") }
            switch appCheck(app, allowed: allowedApps) {
            case .success(let name): listed = name
            case .failure(let why): return .refused(kind: "file-refused", why: why.message)
            }
        }
        switch resolve(guestPath: guestPath, workspace: workspace, reveal: reveal) {
        case .failure(let why): return .refused(kind: "file-refused", why: why.message)
        case .success(let r):
            if r.folder {
                if listed != nil { return .refused(kind: "file-refused", why: "--app is for files: a folder opens in the Finder") }
                return .open(macPath: r.macPath, shown: r.shown, app: nil, how: .finder)
            }
            return .open(macPath: r.macPath, shown: r.shown, app: reveal ? nil : listed, how: reveal ? .reveal : .app)
        }
    }

    public struct Refusal: Error, Equatable, Sendable {
        public let message: String
        init(_ m: String) { message = m }
    }

    /// What a request shows before it is resolved: the guest path inside /workspace when it is there,
    /// else the path; control characters removed, at most 80 characters.
    public static func shownRequest(_ guestPath: String) -> String {
        var s = String(guestPath.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && !(0x80...0x9F).contains($0.value) })
        if let rel = lexicalRelative(s) { s = rel }
        return s.count > 80 ? "…" + String(s.suffix(79)) : s
    }

    // MARK: apps

    /// `bridges.open_apps`' names (nil: not a valid list). Comma-separated; each 1–64 characters, no
    /// control character, `/`, `;` or `,`, not starting with `-` or `.`; at most 16.
    public static func appNames(_ s: String) -> [String]? {
        let names = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard names.count <= 16 else { return nil }
        for n in names where !isAppName(n) { return nil }
        return names
    }

    public static func isAppName(_ n: String) -> Bool {
        !n.isEmpty && n.count <= 64 && !n.hasPrefix("-") && !n.hasPrefix(".")
            && !n.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value) || "/;,".unicodeScalars.contains($0) })
    }

    /// A named app: the allow-list's own spelling when listed (case-insensitive), else why not.
    public static func appCheck(_ app: String, allowed: [String]) -> Result<String, Refusal> {
        let shown = String(app.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.prefix(64))
        guard isAppName(app) else { return .failure(Refusal("\"\(shown)\" is not an app name")) }
        if let listed = allowed.first(where: { $0.caseInsensitiveCompare(app) == .orderedSame }) { return .success(listed) }
        // Short: a notice is one terminal row. The settings reference says how to add one.
        return .failure(Refusal(allowed.isEmpty
            ? "no app may be named (bridges.open_apps is empty)"
            : "\(shown) is not in bridges.open_apps"))
    }

    // MARK: the path

    /// The part of an absolute guest path under /workspace, normalised lexically (`.`, `..`, `//`);
    /// nil when it is not under /workspace (or is /workspace itself, unless `root`: then "").
    public static func lexicalRelative(_ guestPath: String, root: Bool = false) -> String? {
        guard guestPath.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for c in guestPath.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(c)
        }
        let base = guestRoot.split(separator: "/")
        // `root`: /workspace itself is a place too (a folder to show) — its relative path is "".
        guard parts.count > base.count || (root && parts.count == base.count), Array(parts.prefix(base.count)) == base else { return nil }
        return parts.dropFirst(base.count).joined(separator: "/")
    }

    /// The guest path → the Mac file, resolved on the Mac and checked (see the top of this file).
    /// A folder (the workspace itself or any folder in it) opens in the Finder — never an app or a package
    /// (that is a program, to the Mac), which only `--reveal` may show, selected in its parent. With
    /// `reveal`, a file is shown, not opened, so its type and content are not checked.
    public static func resolve(guestPath: String, workspace: String, reveal: Bool = false)
        -> Result<(macPath: String, shown: String, folder: Bool), Refusal> {
        guard guestPath.utf8.count <= maximumPathBytes else { return .failure(Refusal("the path is longer than \(maximumPathBytes) bytes")) }
        guard !guestPath.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return .failure(Refusal("the path has control characters"))
        }
        // Every reason is short and starts with what matters: a notice is one terminal row.
        guard let rel = lexicalRelative(guestPath, root: true) else { return .failure(Refusal("only files in /workspace are opened")) }
        guard let root = realPath(workspace) else { return .failure(Refusal("the shared folder is not there on this Mac")) }
        let asked = rel.isEmpty ? workspace : (workspace.hasSuffix("/") ? workspace : workspace + "/") + rel
        guard let real = realPath(asked) else { return .failure(Refusal("no such file in the workspace")) }
        guard real == root || (real.hasPrefix(root == "/" ? "/" : root + "/") && real.count > root.count + 1) else {
            return .failure(Refusal("it leads outside the shared folder (a link or ..)"))
        }
        let inside = real == root ? "" : String(real.dropFirst(root.count + 1))
        var st = stat()
        guard lstat(real, &st) == 0 else { return .failure(Refusal("no such file in the workspace")) }
        switch st.st_mode & S_IFMT {
        case S_IFREG: break
        case S_IFDIR:
            let name = (real as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            let package = (try? URL(fileURLWithPath: real, isDirectory: true).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
            if inside.isEmpty { return .success((real, "the workspace", true)) }
            if package || neverTypes.contains(ext) {
                // A package (an app, a bundle) is a program to the Mac: never opened, even in the Finder —
                // but it may be shown selected in its folder.
                if reveal { return .success((real, inside, false)) }
                return .failure(Refusal("\(name) is an app or package: never opened (doz-open --reveal shows it)"))
            }
            return .success((real, inside + "/", true))
        default: return .failure(Refusal("it is not a regular file"))
        }
        let shown = inside
        if reveal { return .success((real, shown, false)) }
        if let why = typeProblem(real) { return .failure(Refusal(why)) }
        if st.st_mode & 0o111 != 0 { return .failure(Refusal("it is executable: never opened")) }
        if let why = contentProblem(real, expecting: st) { return .failure(Refusal(why)) }
        return .success((real, shown, false))
    }

    /// Why a file name's type is not opened (nil: a document type).
    public static func typeProblem(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        if ext.isEmpty { return "it has no document type (.html, .md, .pdf, .txt, …)" }
        if neverTypes.contains(ext) { return ".\(ext) is never opened (an app, script or installer type)" }
        if !documentTypes.contains(ext) { return ".\(ext) is not a document type (html, md, pdf, images, txt, csv, json, …)" }
        return nil
    }

    /// Opens the file without following a link, checks it is the file `expecting` describes, and reads its
    /// first bytes: a Mach-O or ELF program, or a `#!` script, is refused whatever its name; so is a Mac
    /// resource fork (it can name another app to open the file with).
    public static func contentProblem(_ path: String, expecting: stat) -> String? {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return "it could not be read on this Mac" }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_dev == expecting.st_dev, st.st_ino == expecting.st_ino, (st.st_mode & S_IFMT) == S_IFREG else {
            return "it changed while it was checked"
        }
        if fgetxattr(fd, "com.apple.ResourceFork", nil, 0, 0, 0) >= 0 {
            return "it has a Mac resource fork (it could name its app): never opened"
        }
        var b = [UInt8](repeating: 0, count: 4)
        let n = pread(fd, &b, 4, 0)
        return sniff(Array(b.prefix(max(0, n))))
    }

    /// The content sniff alone (unit-tested): a program or a script, by its first bytes.
    public static func sniff(_ head: [UInt8]) -> String? {
        if head.count >= 2, head[0] == 0x23, head[1] == 0x21 { return "it is a script (#!): never opened" }
        guard head.count >= 4 else { return nil }
        let be = UInt32(head[0]) << 24 | UInt32(head[1]) << 16 | UInt32(head[2]) << 8 | UInt32(head[3])
        let machO: Set<UInt32> = [0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE, 0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA]
        if machO.contains(be) { return "it is a Mac program (Mach-O): never opened" }
        if be == 0x7F454C46 { return "it is a program (ELF): never opened" }
        return nil
    }

    static func realPath(_ p: String) -> String? {
        guard let r = realpath(p, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    // MARK: opening

    /// Open `path` on the Mac — its default app, or `app` (`open -a`) — or, in tests
    /// (`DOZ_TEST_OPEN_URL=<file>`, the browser bridge's seam), append `open-file APP|default PATH` to that
    /// file instead. Never a real app from a test.
    /// A folder: `open -a Finder PATH` (the Finder shows it — a folder is never launched as an app);
    /// `.reveal`: `open -R PATH` (selected in its folder; nothing opened). Seam lines: `open-folder PATH`,
    /// `reveal PATH`.
    public static func open(_ path: String, app: String?, how: How = .app,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let seam = environment["DOZ_TEST_OPEN_URL"], !seam.isEmpty {
            switch how {
            case .app: BrowserBridge.append(seam, "open-file \(app ?? "default") \(path)\n")
            case .finder: BrowserBridge.append(seam, "open-folder \(path)\n")
            case .reveal: BrowserBridge.append(seam, "reveal \(path)\n")
            }
            return true
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        switch how {
        case .app: p.arguments = (app.map { ["-a", $0] } ?? []) + [path]
        case .finder: p.arguments = ["-a", "Finder", path]
        case .reveal: p.arguments = ["-R", path]
        }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
