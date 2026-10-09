import Foundation

/// The deckhold wire protocol (see `Guest/deckhold/deckhold.c`): frames of
/// `[type u8][length u32 big-endian][payload]`, in both directions.
public enum DeckholdFrame: Equatable, Sendable {
    // client → holder
    case hello(TermSize)
    case data(Data)
    case resize(TermSize)
    /// 612: become a status watcher — answered with STATUS frames, never DATA (deckhold's 'W').
    case watch
    // holder → client
    case snapshot(Data)
    case output(Data)
    case exit(Int32)
    case info(String)
    case noSession
    /// 612: the program's root status record as text (`ProgramStatus.parse(frame:)`), or "" — none.
    case status(String)

    /// Frames larger than this are a protocol error (deckhold drops such a client too).
    public static let maxPayload = 1 << 24

    /// 593: a screen capture's whole request, one write: HELLO 0×0 (keep the session's size — the
    /// program is not resized, nothing is typed) — answered with a SNAPSHOT — then DUMP, answered with
    /// the screen as plain text, after which deckhold closes this client.
    public static let captureRequest: Data = hello(TermSize(cols: 0, rows: 0)).encoded + Data([UInt8(ascii: "P"), 0, 0, 0, 0])

    public var typeByte: UInt8 {
        switch self {
        case .hello: UInt8(ascii: "H")
        case .data, .output: UInt8(ascii: "D")
        case .resize: UInt8(ascii: "R")
        case .snapshot: UInt8(ascii: "S")
        case .exit: UInt8(ascii: "X")
        case .info: UInt8(ascii: "I")
        case .noSession: UInt8(ascii: "N")
        case .watch: UInt8(ascii: "W")
        case .status: UInt8(ascii: "T")
        }
    }

    /// The frame as bytes on the wire.
    public var encoded: Data {
        var payload = Data()
        switch self {
        case .hello(let s), .resize(let s):
            payload.append(contentsOf: [UInt8(s.cols >> 8), UInt8(s.cols & 0xFF), UInt8(s.rows >> 8), UInt8(s.rows & 0xFF)])
        case .data(let d), .output(let d), .snapshot(let d):
            payload = d
        case .exit(let code):
            let u = UInt32(bitPattern: code)
            payload.append(contentsOf: [UInt8(u >> 24), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)])
        case .info(let s), .status(let s):
            payload = Data(s.utf8)
        case .noSession, .watch:
            break
        }
        let n = UInt32(payload.count)
        var out = Data([typeByte, UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        out.append(payload)
        return out
    }
}

/// Incremental decoder for the holder → client direction. Feed it bytes as they arrive (frames
/// may be split or coalesced arbitrarily); it returns every complete frame, in order.
public struct DeckholdFrameDecoder: Sendable {
    public enum DecodeError: Error, Equatable { case oversizedFrame(Int), unknownType(UInt8) }

    private var buffer = Data()
    public init() {}

    /// Bytes received but not yet part of a complete frame.
    public var pendingByteCount: Int { buffer.count }

    public mutating func feed(_ bytes: Data) throws -> [DeckholdFrame] {
        buffer.append(bytes)
        var frames: [DeckholdFrame] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 5 {
            let type = buffer[offset]
            let n = Int(buffer[offset + 1]) << 24 | Int(buffer[offset + 2]) << 16
                | Int(buffer[offset + 3]) << 8 | Int(buffer[offset + 4])
            guard n <= DeckholdFrame.maxPayload else { throw DecodeError.oversizedFrame(n) }
            guard buffer.endIndex - offset >= 5 + n else { break }
            let payload = Data(buffer[(offset + 5)..<(offset + 5 + n)])
            offset += 5 + n
            switch type {
            case UInt8(ascii: "S"): frames.append(.snapshot(payload))
            case UInt8(ascii: "D"): frames.append(.output(payload))
            case UInt8(ascii: "X"):
                let b = [UInt8](payload)
                let code = b.count >= 4 ? Int32(bitPattern: UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])) : 0
                frames.append(.exit(code))
            case UInt8(ascii: "I"): frames.append(.info(String(decoding: payload, as: UTF8.self)))
            case UInt8(ascii: "N"): frames.append(.noSession)
            case UInt8(ascii: "T"): frames.append(.status(String(decoding: payload, as: UTF8.self)))
            default: throw DecodeError.unknownType(type)
            }
        }
        buffer = Data(buffer[offset...])
        return frames
    }
}

/// One line of `deckhold ls`.
public struct SessionInfo: Sendable, Equatable {
    public var name: String
    /// nil for an ended session.
    public var pid: Int?
    public var size: TermSize?
    /// Attached viewers (all hosts' connections plus any in-guest `deckhold attach`).
    public var clients: Int
    /// "primary" or "alt".
    public var screen: String?
    public var historyRows: Int
    public var bytesOut: UInt64
    public var command: String
    /// Set once the program has exited: its exit code.
    public var exitCode: Int32?
    /// 612: what the program says it is doing (OSC 7501's root record), when it said anything.
    public var status: ProgramStatus?

    public var isEnded: Bool { exitCode != nil }

    public init(name: String, pid: Int? = nil, size: TermSize? = nil, clients: Int = 0, screen: String? = nil,
                historyRows: Int = 0, bytesOut: UInt64 = 0, command: String = "", exitCode: Int32? = nil) {
        self.name = name
        self.pid = pid
        self.size = size
        self.clients = clients
        self.screen = screen
        self.historyRows = historyRows
        self.bytesOut = bytesOut
        self.command = command
        self.exitCode = exitCode
    }

    /// Parses `deckhold ls` output. Live: `NAME\tpid=…\tsize=CxR\tclients=…\tscreen=…\thistory=…\tbytes=…\tCMD`
    /// (612: `status=…\tstatus_age=…` before CMD when the program reported a status);
    /// ended: `NAME\tended=CODE`; a dead socket: `NAME\t(stale socket)` (skipped).
    public static func parseList(_ text: String) -> [SessionInfo] {
        var out: [SessionInfo] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let name = f.first, !name.isEmpty, f.count >= 2 else { continue }
            if f[1].hasPrefix("ended=") {
                out.append(SessionInfo(name: name, exitCode: Int32(f[1].dropFirst(6))))
                continue
            }
            guard f[1].hasPrefix("pid=") else { continue }
            var info = SessionInfo(name: name)
            var status: [String: String] = [:]
            for field in f.dropFirst() {
                let kv = field.split(separator: "=", maxSplits: 1).map(String.init)
                switch kv.first {
                case "pid": info.pid = kv.count > 1 ? Int(kv[1]) : nil
                case "size":
                    let parts = (kv.count > 1 ? kv[1] : "").split(separator: "x").compactMap { UInt16($0) }
                    if parts.count == 2 { info.size = TermSize(cols: parts[0], rows: parts[1]) }
                case "clients": info.clients = kv.count > 1 ? Int(kv[1]) ?? 0 : 0
                case "screen": info.screen = kv.count > 1 ? kv[1] : nil
                case "history": info.historyRows = kv.count > 1 ? Int(kv[1]) ?? 0 : 0
                case "bytes": info.bytesOut = kv.count > 1 ? UInt64(kv[1]) ?? 0 : 0
                case "status", "status_age": status[kv[0]] = kv.count > 1 ? kv[1] : ""
                default: info.command = field
                }
            }
            info.status = ProgramStatus(fields: status)
            out.append(info)
        }
        return out.sorted { $0.name < $1.name }
    }
}

/// The guest-side commands the library runs, built as ARGV — never through `sh -c` for anything
/// that becomes a session: BusyBox ash leaks an ignored SIGQUIT into what it execs, and a program
/// cannot trap a signal that was ignored on entry (576: the screensaver's `m` menu). deckhold
/// additionally resets every signal to default before exec'ing its program.
public enum GuestCommand {
    /// Where the library installs deckhold in the guest on every start.
    public static let deckholdPath = "/usr/local/bin/deckhold"
    /// 610: where a wake copies this build's deckhold before it is renamed over `deckholdPath`.
    public static let deckholdStagingPath = "/usr/local/bin/.deckhold.doz-new"

    /// 610: the guest's deckhold's sha256 (empty when it has none) — one line, for `refreshDeckholdScript`'s caller.
    public static let deckholdDigestScript = "sha256sum \(deckholdPath) 2>/dev/null | cut -d' ' -f1"

    /// 610: put the staged deckhold in place — only when it is exactly `sha256` — by RENAME: a session's running
    /// holder keeps its own (old) file, a session opened from now on runs the new one. Answers `deckhold=updated`
    /// or `deckhold=refused` (the staged copy is removed).
    public static func refreshDeckholdScript(sha256: String) -> String {
        let n = deckholdStagingPath, p = deckholdPath
        return "if [ \"$(sha256sum \(n) 2>/dev/null | cut -d' ' -f1)\" = \(sha256) ]; then chmod 755 \(n) && mv -f \(n) \(p) && echo deckhold=updated; "
            + "else rm -f \(n); echo deckhold=refused; fi"
    }
    public static let path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    public static func validateSessionName(_ name: String) throws {
        let ok = (1...64).contains(name.count)
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
            && !name.hasPrefix(".")
        guard ok else { throw SandboxError.invalidSessionName(name) }
    }

    /// `deckhold serve -s NAME -x C -y R [--scrollback B] -- ARGV…` — the holder daemonises and the
    /// command returns once its socket is listening.
    public static func serve(name: String, size: TermSize, argv: [String], scrollbackBytes: Int? = nil) -> [String] {
        var a = [deckholdPath, "serve", "-s", name, "-x", String(size.cols), "-y", String(size.rows)]
        if let scrollbackBytes { a += ["--scrollback", String(scrollbackBytes)] }
        return a + ["--"] + argv
    }

    /// `deckhold pipe -s NAME` — the frame transport a host connection runs as a non-terminal exec.
    public static func pipe(name: String) -> [String] { [deckholdPath, "pipe", "-s", name] }
    public static func list() -> [String] { [deckholdPath, "ls"] }
    public static func dump(name: String) -> [String] { [deckholdPath, "dump", "-s", name] }

    /// The environment every guest command gets, plus the caller's extras (last wins).
    public static func environment(_ extra: [String: String] = [:]) -> [String] {
        var env: [String: String] = ["PATH": path, "TERM": "xterm-256color", "LANG": "C.UTF-8", "HOME": "/root"]
        for (k, v) in extra { env[k] = v }
        return env.keys.sorted().map { "\($0)=\(env[$0]!)" }
    }

    /// Re-attach every virtio-fs share after a restore, from INSIDE the container's mount
    /// namespace (a privileged exec). The package exposes ONE virtio-fs device tagged `virtiofs`
    /// whose subdirectories are the shares, named by tag; the container's share mounts are binds
    /// of those subdirectories, and after a VM stop they are dead.
    ///
    /// The fresh mount below is NOT a new superblock — virtio-fs reuses the live one for the same
    /// device (the old binds and any open file keep it alive) — so its dentry for `<tag>` can be
    /// the stale one. Listing the root first (READDIRPLUS) makes FUSE replace every entry whose
    /// node id changed; only then is the bind of `<tag>` a live one. (576's POC got this by
    /// accident from a `for d in /mnt/vfs/*` glob; without it the 578 suite's SECOND wake lost
    /// /work.) Each share is then listed, so a failure is loud. Idempotent across repeated wakes:
    /// the previous wake's fresh mount is detached first.
    ///
    /// Workspace rules (599g): a share whose guest runs a view (its conf exists — the GUEST's layout
    /// decides, so a restore into a new process needs no record) is re-bound at its PRIVATE raw path,
    /// never at its guest path, and its daemon is signalled in this same script
    /// (`WorkspaceView.remountWithView`); a share the host now wants a view for (`views`, keyed by tag)
    /// that has none yet gets one after its ordinary re-bind (`WorkspaceView.startScript`). Neither ever
    /// fails the script: they print `doz-view TAG …` lines.
    public static func remountShares(_ shares: [(tag: String, guestPath: String)], views: [String: WorkspaceViewConfig] = [:]) -> String {
        var s = "set -e; mkdir -p /run/dozer-vfs; umount -l /run/dozer-vfs 2>/dev/null || true; "
            + "mount -t virtiofs virtiofs /run/dozer-vfs; ls -a /run/dozer-vfs >/dev/null"
        for share in shares {
            let plain = "umount -l '\(share.guestPath)' 2>/dev/null || true"
                + "; mount --bind '/run/dozer-vfs/\(share.tag)' '\(share.guestPath)'"
                + "; ls -a '\(share.guestPath)' >/dev/null"
            guard WorkspaceView.isSafe(share.tag), WorkspaceView.isSafe(share.guestPath) else { s += "; " + plain; continue }
            let turnOn = views[share.tag].map { "; " + WorkspaceView.startScript($0) } ?? ""
            s += "; if [ -f '\(WorkspaceView.confPath(share.tag))' ]; then "
                + WorkspaceView.remountWithView(tag: share.tag, guestPath: share.guestPath, wanted: views[share.tag])
                + "; else " + plain + turnOn + "; fi"
        }
        return s
    }

    /// Where the state disk is mounted in an image sandbox.
    public static let stateMount = "/state"

    /// 587: guest mount options of the root and state disks — `discard`, so a block the guest frees
    /// is punched out of the host file (online TRIM). Mount options are not a VM input: a snapshot
    /// taken before 587 restores unchanged.
    public static let diskMountOptions = ["discard"]

    /// 587: `fstrim` the root file system — the last step of every bake, so a baked disk holds no
    /// blocks its own install freed. Busybox and util-linux both have it.
    public static let trimRoot = "sync; if command -v fstrim >/dev/null 2>&1; then fstrim -v /; else echo 'fstrim: not available'; fi; sync"

    /// 587: flush the guest's dirty pages, then report what its disks hold (`df -Pk`, POSIX output).
    public static let syncAndMeasure = "sync; df -Pk / \(stateMount) 2>/dev/null || true"

    /// `df -Pk` output → MiB used per mount point.
    public static func parseDiskUsage(_ out: String) -> [String: Double] {
        var m: [String: Double] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 6, let used = Double(f[2]) else { continue }
            m[String(f[f.count - 1])] = used / 1024
        }
        return m
    }

    /// A persist dir's directory on the state disk: its absolute path, flattened.
    /// 594 W29: the guest's own host name resolves locally — `127.0.1.1 <hostname>` in /etc/hosts (once;
    /// idempotent). Without it every `sudo` asked DNS for the sandbox's name 4 times, and a proxied
    /// sandbox's policy denied and logged each. Never fails the caller.
    public static let ownHostnameScript = #"{ h=$(hostname 2>/dev/null) && [ -n "$h" ] && { awk -v h="$h" '{ for (i = 2; i <= NF; i++) if ($i == h) f = 1 } END { exit !f }' /etc/hosts 2>/dev/null || printf '127.0.1.1\t%s\n' "$h" >> /etc/hosts; }; } || true"#

    /// 594 W31 (the owner's `sudo apt-get install`, 2026-10-01, stopped at "Configuring
    /// keyboard-configuration … Keyboard layout:"): Debian's package configuration never asks —
    /// debconf's frontend is set to Noninteractive in its own database, so it holds however apt runs
    /// (sudo drops DEBIAN_FRONTEND from the environment; `doz exec --user root`; a script). An agent
    /// would otherwise hang on the question. Debian/Ubuntu only (no debconf elsewhere); never fails the caller.
    public static let debconfNoninteractiveScript = #"{ command -v debconf-set-selections >/dev/null 2>&1 && echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections; } >/dev/null 2>&1 || true"#

    /// 594 W23 (owner ruling 2026-09-30: "yes, passwordless sudo by default"): where the agent's sudo
    /// rule lives. sudo reads every file in /etc/sudoers.d whose name has no dot and no trailing `~`.
    public static let agentSudoersPath = "/etc/sudoers.d/dozer-agent"

    /// Root shell (idempotent, never fails the caller): `on` → `/etc/sudoers.d/dozer-agent` (0440, root)
    /// giving `user` passwordless sudo, written only when the image has sudo and only after `visudo -cf`
    /// accepts it — a broken drop-in would break sudo for everyone; `off` → the drop-in removed. A root
    /// user, or a user name that is not a plain name, gets nothing.
    public static func agentSudoScript(user: String, on: Bool) -> String {
        let plain = !user.isEmpty && user.count <= 32 && user != "root"
            && user.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" }
            && !(user.first.map { $0.isNumber || $0 == "-" } ?? true)
        guard plain, on else { return "rm -f '\(agentSudoersPath)'" }
        let tmp = "/run/dozer-agent-sudoers"
        // Absolute paths: a utility exec's PATH may lack /usr/sbin. No visudo, no rule (never unchecked).
        return "if [ -x /usr/bin/sudo ] && [ -x /usr/sbin/visudo ]; then mkdir -p /etc/sudoers.d"
            + " && printf '%s ALL=(ALL) NOPASSWD:ALL\\n' '\(user)' > \(tmp) && chmod 0440 \(tmp) && chown 0:0 \(tmp)"
            + " && /usr/sbin/visudo -cf \(tmp) >/dev/null"
            + " && mv -f \(tmp) '\(agentSudoersPath)' || rm -f \(tmp); fi"
    }

    // MARK: 599 (594.B2) — the browser bridge's guest half

    /// Where the `xdg-open` shim lives (root-owned; first on every session's PATH).
    public static let openShimDirectory = "/usr/local/lib/doz/bin"
    public static let openShimPath = openShimDirectory + "/xdg-open"
    /// The other names a program reaches for (links to the shim). 599b: `doz-open` (`--app NAME FILE`).
    public static let openShimAliases = ["open", "sensible-browser", "www-browser", "x-www-browser", "doz-open"]
    static let openShimStamp = "doz:open-url-shim:v6"

    /// 599b: the document types a /workspace file may have to be opened on the Mac (lowercased
    /// extensions). The host (`WorkspaceFiles`) decides; the shim checks the same lists first so the
    /// agent hears why at once.
    public static let openFileDocumentTypes: [String] = [
        "html", "htm", "xhtml",
        "md", "markdown", "mdown", "mkd",
        "pdf",
        "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff", "heic",
        "txt", "text", "log",
        "csv", "tsv",
        "json", "yaml", "yml", "xml", "toml",
    ]
    /// 599b: types never opened (apps, scripts, installers, link files that run or redirect). Anything not
    /// a document type is refused too; this list only makes the refusal say why.
    public static let openFileNeverTypes: [String] = [
        "app", "command", "tool", "terminal", "scpt", "scptd", "applescript", "workflow", "action", "shortcut",
        "webloc", "inetloc", "url", "fileloc", "afploc", "ftploc",
        "pkg", "mpkg", "dmg", "jar", "mobileconfig", "prefpane", "saver", "kext", "plugin", "bundle", "framework",
        "appex", "xpc", "service", "osax", "dylib", "so", "bin", "exe",
        "sh", "bash", "zsh", "csh", "tcsh", "ksh", "fish", "py", "rb", "pl", "php", "js", "mjs", "lua", "swift",
    ]
    static func casePatterns(_ types: [String]) -> String { types.map { "*.\($0)" }.joined(separator: "|") }

    /// `path` with the shim's directory first (once).
    public static func withOpenShim(_ path: String) -> String {
        let parts = path.split(separator: ":").map(String.init)
        guard parts.first != openShimDirectory else { return path }
        return ([openShimDirectory] + parts.filter { $0 != openShimDirectory }).joined(separator: ":")
    }

    /// The shim (DeckStack's technique, 535/539 — read, not depended on): this sandbox has no browser,
    /// so the URL is handed to the Mac as a private OSC 6340 marker on the session's terminal, which the
    /// host's attach relay takes out and decides on (http/https only, the setting, a notice). The marker
    /// goes to the controlling terminal, else the session's own (`$DOZ_TTY`, exported by deckhold — an
    /// opener that `setsid`s its child has no controlling terminal), else stdout when stdout IS a
    /// terminal; with none of them it refuses (exit 1). `2>/dev/null` BEFORE `>`: a failed rung prints
    /// nothing (DeckStack's lesson).
    /// 609 (owner: "I dont actually think we need to show any output in the terminal"): the shim writes
    /// NOTHING a person sees — only the marker, which every viewer has taken out. Up to v5 it also wrote
    /// "Asking your Mac to open: URL" to the terminal, behind the program that owns the screen: an agent's
    /// TUI (Claude Code) redraws relative to where it believes its cursor is and draws blank cells as
    /// cursor jumps, so the inserted rows (a sign-in URL wraps over several) left stray text on screen and
    /// under the spaces the TUI drew afterwards — "space doesn't work" — until something made the TUI
    /// redraw all of it (`doz attach` from a terminal of another size does: a resize). The person is told
    /// by the Dozer notice; the program that ran the shim hears a refusal on stderr and the exit status.
    /// 599b: a FILE as well — `doz-file;APP;/workspace/…` (the path made absolute and resolved HERE, in
    /// the caller's directory; the host resolves it again on the Mac and decides). The shim's own checks
    /// (in /workspace, a document type, not executable, not `#!`) only tell the agent why at once — the
    /// notice goes to the person's terminal, not the agent's. `-a`/`--app NAME` (`doz-open --app`).
    /// 599b, later: a FOLDER in /workspace (`open .` too) opens in the Finder (the same `doz-file;;PATH` —
    /// the host sees it is a folder); `-R`/`--reveal PATH` sends `doz-reveal;PATH` (shown selected in its
    /// folder). A package folder (`*.app`, …) is refused unless revealed. Stamp v5; 609: v6 (silent).
    public static let openShim = #"""
    #!/bin/sh
    # doz:open-url-shim:v6
    # Dozer Sandbox's bridge to the Mac. This sandbox has no browser and no desktop, so an http(s) URL,
    # or a document or folder in /workspace (the folder shared with the Mac), is handed to the Mac
    # through the session's terminal: doz shows it and opens it (the URL in the Mac's default browser,
    # the document in its default app or in an app the user allowed: bridges.open_apps, the folder in
    # the Finder) unless that bridge is off for this sandbox. --reveal shows a file selected in its
    # folder. Written at every boot and wake; see `doz config show --sandbox`.
    me=${0##*/}
    app=""
    reveal=""
    status=0
    usage() {
        echo "usage: $me URL | PATH...    (a PATH in /workspace: a document opens in its app, a folder in the Finder; $me --app NAME FILE... another Mac app the user allowed; $me --reveal PATH... shows it in its folder)" >&2
        exit "${1:-1}"
    }
    while [ $# -gt 0 ]; do
        case "$1" in
            -a|--app) [ $# -ge 2 ] || usage; app="$2"; shift 2 ;;
            --app=*) app="${1#--app=}"; shift ;;
            -R|--reveal) reveal=1; shift ;;
            -h|--help) usage 0 ;;
            --) shift; break ;;
            -?*) echo "$me: unknown option $1 ($me here opens a URL, or a /workspace file, on your Mac)" >&2; exit 1 ;;
            *) break ;;
        esac
    done
    [ $# -ge 1 ] || usage
    if [ -n "$app" ]; then
        capp=$(printf '%s' "$app" | tr -d '\000-\037\177')
        case "$app" in
            -*|.*|*/*|*';'*|*,*) capp="" ;;
        esac
        [ "$capp" = "$app" ] && [ "${#app}" -le 64 ] || { echo "$me: \"$capp\" is not an app name" >&2; exit 1; }
    fi
    refuse() { echo "$me: $*" >&2; status=1; }
    # The marker on the session's terminal ($1: its body) — and nothing else: the person is told by Dozer
    # (a notice), never by text written behind the program that owns the screen (an agent's TUI).
    send() {
        # Inside tmux (sessions.tmux) the pane's terminal is tmux's, which drops a sequence it does not
        # know: the marker goes to the session's own terminal ($DOZ_TTY, tmux's client).
        if [ -n "${TMUX:-}" ] && [ -n "${DOZ_TTY:-}" ] && [ -w "$DOZ_TTY" ] \
            && printf '\033]6340;%s\007' "$1" 2>/dev/null > "$DOZ_TTY"; then return 0; fi
        if [ -w /dev/tty ] 2>/dev/null && printf '\033]6340;%s\007' "$1" 2>/dev/null > /dev/tty; then return 0; fi
        if [ -n "${DOZ_TTY:-}" ] && [ -w "$DOZ_TTY" ] && printf '\033]6340;%s\007' "$1" 2>/dev/null > "$DOZ_TTY"; then return 0; fi
        if [ -t 1 ]; then printf '\033]6340;%s\007' "$1"; return 0; fi
        refuse "no terminal of a Dozer session to reach your Mac through (run it in a session: doz attach, or the dashboard)"
    }
    open_url() {
        [ -z "$app" ] || { refuse "--app is for files; a URL opens in your Mac's default browser: $1"; return; }
        [ -z "$reveal" ] || { refuse "--reveal is for files and folders in /workspace, not a URL: $1"; return; }
        send "doz-open;$1"
    }
    open_file() {
        t=$1
        if ! grep -qs ' /workspace ' /proc/mounts; then
            refuse "this sandbox is isolated (nothing on your Mac is shared), so no file or folder can be opened there: $t"; return
        fi
        [ -e "$t" ] || { refuse "no such file: $t"; return; }
        case "$t" in /*) p=$t ;; *) p=./$t ;; esac
        abs=$(realpath "$p" 2>/dev/null || readlink -f "$p" 2>/dev/null)
        case "$abs" in
            /workspace|/workspace/*) ;;
            *) refuse "only files and folders in /workspace (the folder shared with your Mac) are opened there, not $t"; return ;;
        esac
        name=${abs##*/}
        lower=$(printf '%s' "$name" | tr 'A-Z' 'a-z')
        if [ -n "$reveal" ]; then
            [ -z "$app" ] || { refuse "--app with --reveal: it is shown in the Finder"; return; }
            send "doz-reveal;$abs"; return
        fi
        if [ -d "$abs" ]; then
            [ -z "$app" ] || { refuse "--app is for files; a folder opens in the Finder: $t"; return; }
            case "$lower" in
                \#(casePatterns(openFileNeverTypes))) refuse "$name is an app or package: never opened on your Mac ($me --reveal shows it in its folder)"; return ;;
            esac
            send "doz-file;;$abs"; return
        fi
        case "$lower" in
            \#(casePatterns(openFileNeverTypes))) refuse "$name is a program, script or installer type: never opened on your Mac"; return ;;
            \#(casePatterns(openFileDocumentTypes))) ;;
            *) refuse "only documents are opened on your Mac (html, md, pdf, images, txt, csv, json, yaml, xml...), not $name"; return ;;
        esac
        [ -x "$abs" ] && { refuse "$name is executable: never opened on your Mac"; return; }
        [ "$(head -c 2 "$abs" 2>/dev/null)" = '#!' ] && { refuse "$name is a script: never opened on your Mac"; return; }
        send "doz-file;$app;$abs"
    }
    for target in "$@"; do
        if [ "${#target}" -gt 2048 ]; then refuse "the URL or file name is longer than 2048 bytes: not sent to the Mac"; continue; fi
        clean=$(printf '%s' "$target" | tr -d '\000-\037\177')
        if [ "$clean" != "$target" ]; then refuse "the URL or file name has control characters: not sent to the Mac"; continue; fi
        case "$target" in
            http://*|https://*) open_url "$target" ;;
            *)
                if [ ! -e "$target" ] && printf '%s' "$target" | grep -Eq '^[A-Za-z][A-Za-z0-9+.-]*:'; then
                    refuse "this sandbox has no browser, and only http and https URLs go to the Mac: $target (a file in /workspace goes by its path)"
                else
                    open_file "$target"
                fi ;;
        esac
    done
    exit $status
    """#

    /// A login shell (`bash -l`, the lab's own session) resets PATH in /etc/profile (Alpine and Debian
    /// both): this drop-in, which /etc/profile sources, puts the shim's directory back in front.
    public static let openShimProfilePath = "/etc/profile.d/doz-browser-bridge.sh"
    static let openShimProfile = """
    # doz: the browser bridge's xdg-open first on PATH (a login shell's /etc/profile resets PATH).
    case ":$PATH:" in *":\(openShimDirectory):"*) ;; *) PATH="\(openShimDirectory):$PATH" ;; esac
    export PATH
    """

    /// Root shell: install the shim, its aliases and the profile drop-in when missing or older
    /// (idempotent, never fails the caller).
    public static var openShimInstall: String {
        let quoted = "'" + openShim.replacingOccurrences(of: "'", with: "'\\''") + "\n'"
        let profile = "'" + openShimProfile.replacingOccurrences(of: "'", with: "'\\''") + "\n'"
        let links = openShimAliases.map { "ln -sf xdg-open '\(openShimDirectory)/\($0)'" }.joined(separator: "; ")
        return "{ grep -q '\(openShimStamp)' '\(openShimPath)' 2>/dev/null || { mkdir -p '\(openShimDirectory)'"
            + " && printf '%s' \(quoted) > '\(openShimPath).tmp' && chmod 0755 '\(openShimPath).tmp'"
            + " && mv -f '\(openShimPath).tmp' '\(openShimPath)' && \(links)"
            + "; mkdir -p /etc/profile.d && printf '%s' \(profile) > '\(openShimProfilePath)'; }; } || true"
    }

    // MARK: 599 (594.B3) — tmux inside a session

    /// doz's tmux configuration (root-owned, rewritten at each tmux session start).
    public static let tmuxConfPath = "/usr/local/lib/doz/tmux.conf"

    /// 608: end session NAME's program the way a terminal hangup does, then harder — a ROOT script.
    /// The program deckhold runs is its own session and process-group leader (forkpty), so its group is
    /// signalled: SIGHUP (≤ `hupSeconds`), then SIGTERM (≤ `termSeconds`), then SIGKILL (≤ 2 s). A tmux
    /// server of the session (`-L doz-NAME`, any user's) is killed first — otherwise the next
    /// `new-session -A` would attach the OLD program again. Done = the holder's socket is gone (deckhold
    /// removes it when its program has exited, after telling every viewer EXIT). Prints ONE
    /// `doz-end hangup|terminate|kill|not-running|stuck` line. The name is validated by the caller.
    public static func endSession(name: String, hupSeconds: Int = 3, termSeconds: Int = 3) -> String {
        let tn = name.replacingOccurrences(of: ".", with: "_")
        return """
        n='\(name)'; d=${DECKHOLD_DIR:-/run/deckhold}
        pid=$(\(deckholdPath) ls 2>/dev/null | awk -F'\\t' -v n="$n" '$1==n && $2 ~ /^pid=/ { sub(/^pid=/, "", $2); print $2; exit }')
        if [ -z "$pid" ] || [ ! -S "$d/$n.sock" ]; then echo 'doz-end not-running'; exit 0; fi
        for s in /tmp/tmux-*/doz-\(tn); do [ -S "$s" ] && tmux -S "$s" kill-server 2>/dev/null; done
        gone() { [ ! -S "$d/$n.sock" ]; }
        hit() { kill -s "$1" -- "-$pid" 2>/dev/null || kill -s "$1" "$pid" 2>/dev/null; }
        waitgone() { i=0; while [ $i -lt $(($1 * 10)) ]; do gone && return 0; sleep 0.1; i=$((i + 1)); done; gone; }
        hit HUP; if waitgone \(hupSeconds); then echo 'doz-end hangup'; exit 0; fi
        hit TERM; if waitgone \(termSeconds); then echo 'doz-end terminate'; exit 0; fi
        hit KILL; if waitgone 2; then echo 'doz-end kill'; exit 0; fi
        echo 'doz-end stuck'
        """
    }

    /// What a session inside tmux needs to keep doz's features: the mouse (the web terminal's reports,
    /// W14), OSC 52 passed OUT to deckhold (the clipboard bridge), titles, extended keys where tmux has
    /// them, a TERM the image knows; `update-environment` is not needed — one tmux server per session.
    public static let tmuxConf = """
    # doz: tmux inside a Dozer session (sessions.tmux) — rewritten at each session start.
    set -g mouse on
    set -s set-clipboard on
    set -as terminal-features ',*:clipboard'
    set -s extended-keys on
    set -as terminal-features ',*:extkeys'
    set -g set-titles on
    set -g set-titles-string '#S'
    set -g history-limit 50000
    set -s escape-time 10
    set -g default-terminal screen-256color
    if-shell 'test -e /usr/share/terminfo/t/tmux-256color -o -e /lib/terminfo/t/tmux-256color -o -e /etc/terminfo/t/tmux-256color' 'set -g default-terminal tmux-256color'
    """

    /// Root shell: write the configuration; then say whether tmux is there (`tmux=yes|no` on stdout).
    public static var tmuxPrepare: String {
        let quoted = "'" + tmuxConf.replacingOccurrences(of: "'", with: "'\\''") + "\n'"
        return "{ mkdir -p '\(openShimDirectory)' && printf '%s' \(quoted) > '\(tmuxConfPath)' && chmod 0644 '\(tmuxConfPath)'; } 2>/dev/null; "
            + "if command -v tmux >/dev/null 2>&1; then echo tmux=yes; else echo tmux=no; fi"
    }

    /// `argv` inside tmux: its own server per session (`-L doz-NAME` — the session's environment, not
    /// another's), attached to the tmux session `NAME` or making it (`-A`, so a reopened session finds a
    /// program tmux still holds).
    public static func inTmux(session: String, argv: [String]) -> [String] {
        let name = session.replacingOccurrences(of: ".", with: "_")          // tmux refuses . and : in a name
        return ["tmux", "-L", "doz-\(name)", "-f", tmuxConfPath, "new-session", "-A", "-s", name] + argv
    }

    /// 594 W34 (the owner's claude-sandbox-3 still asked apt's keyboard question on rc.11: W31's
    /// debconf setting ran only at a FRESH boot, and that sandbox had only hibernated and woken since):
    /// the root guest fixes that are safe on a LIVE system — run at every fresh boot (inside
    /// `prepareGuest`) AND at every wake (`LifecycleStep.applyGuestFixes`), so a sandbox that is only
    /// ever woken still gets what a newer doz brings. Each part is idempotent and never fails:
    /// the guest's own host name in /etc/hosts (W29), debconf Noninteractive (W31), the open-URL shim
    /// (599), the time zone (W10), and the agent's sudo following the setting (W23). NOT here: the
    /// deckhold socket reset and the persist-dir bind mounts — those must not run under live sessions.
    public static func guestFixes(imageSpec: ImageSpec?, agentSudo: Bool = true, timeZone: GuestTimeZone? = nil,
                                  git: GitGuestSetup? = nil, sshAgent: Bool = false) -> String {
        var s = ownHostnameScript
        s += "; " + debconfNoninteractiveScript
        s += "; " + openShimInstall
        if let tz = timeZone { s += "; " + tz.script }
        if let r = imageSpec { s += "; " + agentSudoScript(user: r.user, on: agentSudo) }
        // 599d: git's credential helper (always installed — it answers only with a doz placeholder), the
        // user's GitHub setup (identity + helper config, or none), the forwarded SSH agent (or none).
        s += "; " + gitCredentialInstall
        s += "; " + gitConfigScript(git ?? .off)
        s += "; " + sshAgentScript(on: sshAgent)
        return s
    }

    // MARK: 599d — GitHub as the user, in the guest

    /// git's credential helper for https://github.com (root-owned, on every image).
    public static let gitCredentialHelperPath = openShimDirectory + "/git-credential-doz"
    static let gitCredentialStamp = "doz:git-credential:v1"

    /// It answers git with this session's PLACEHOLDER — `$GH_TOKEN`, set by doz while "Use GitHub as you"
    /// is on — and only for https://github.com; Dozer's proxy swaps the user's real token in on the way
    /// out. Without a doz placeholder it answers nothing (git goes on to its other helpers).
    public static let gitCredentialHelper = #"""
    #!/bin/sh
    # doz:git-credential:v1
    # Dozer Sandbox: git's credential helper for https://github.com. It answers with this session's doz
    # placeholder ($GH_TOKEN) — never a real token: Dozer's proxy on the Mac swaps in the user's own login
    # (read-only unless the user turned on "Push to GitHub"). See the dozer skill.
    [ "${1:-}" = get ] || exit 0
    host=; proto=
    while IFS= read -r line && [ -n "$line" ]; do
        case "$line" in
            host=*) host=${line#host=} ;;
            protocol=*) proto=${line#protocol=} ;;
        esac
    done
    [ "$proto" = https ] && [ "$host" = github.com ] || exit 0
    tok=${GH_TOKEN:-${GITHUB_TOKEN:-}}
    case "$tok" in doz_cred_*) ;; *) exit 0 ;; esac
    printf 'username=x-access-token\npassword=%s\n' "$tok"
    """#

    public static var gitCredentialInstall: String {
        let quoted = "'" + gitCredentialHelper.replacingOccurrences(of: "'", with: "'\\''") + "\n'"
        return "{ grep -q '\(gitCredentialStamp)' '\(gitCredentialHelperPath)' 2>/dev/null || { mkdir -p '\(openShimDirectory)'"
            + " && printf '%s' \(quoted) > '\(gitCredentialHelperPath).tmp' && chmod 0755 '\(gitCredentialHelperPath).tmp'"
            + " && mv -f '\(gitCredentialHelperPath).tmp' '\(gitCredentialHelperPath)'; }; } || true"
    }

    /// Dozer's own git config, included from the system's (/etc/gitconfig) — the user's identity and the
    /// helper while "Use GitHub as you" is on; EMPTY otherwise (nothing of the user's stays).
    public static let dozerGitConfigPath = "/etc/dozer/gitconfig"

    /// The file's text for `setup`.
    public static func dozerGitConfig(_ setup: GitGuestSetup) -> String {
        guard setup.on else { return "# Dozer: \"Use GitHub as you\" is off for this sandbox.\n" }
        func value(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var t = "# Dozer: \"Use GitHub as you\" is on — rewritten at every boot and wake.\n"
        t += "[credential \"https://github.com\"]\n\thelper = \(value(gitCredentialHelperPath))\n"
        var user = ""
        if let n = setup.name { user += "\tname = \(value(n))\n" }
        if let e = setup.email { user += "\temail = \(value(e))\n" }
        if !user.isEmpty { t += "[user]\n" + user }
        return t
    }

    /// Root shell: write the file and include it from /etc/gitconfig (once). Idempotent, never fails the caller.
    public static func gitConfigScript(_ setup: GitGuestSetup) -> String {
        let quoted = "'" + dozerGitConfig(setup).replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "{ mkdir -p /etc/dozer && printf '%s' \(quoted) > '\(dozerGitConfigPath).tmp' && chmod 0644 '\(dozerGitConfigPath).tmp'"
            + " && mv -f '\(dozerGitConfigPath).tmp' '\(dozerGitConfigPath)'"
            + " && { grep -qs 'path = \(dozerGitConfigPath)' /etc/gitconfig || printf '[include]\\n\\tpath = \(dozerGitConfigPath)\\n' >> /etc/gitconfig; }; } || true"
    }

    /// 599d (G4): where the forwarded SSH agent listens in the guest (sessions get `SSH_AUTH_SOCK` = it).
    public static let sshAgentGuestSocket = "/run/doz/ssh-agent.sock"

    /// Root shell: start (once) or stop the guest half of the forwarded SSH agent — `doznet agent` relays
    /// each connection on the socket to the Mac over vsock. Only where doznet is (a proxied sandbox);
    /// never fails the caller.
    public static func sshAgentScript(on: Bool) -> String {
        let d = EgressProxy.guestShimPath
        if on {
            return "{ [ -x \(d) ] && { \(d) agent status >/dev/null 2>&1 || \(d) agent -p \(SSHAgentRelay.vsockPort) -s \(sshAgentGuestSocket) >/dev/null; }; } || true"
        }
        return "{ [ -x \(d) ] && \(d) agent stop >/dev/null 2>&1; rm -f \(sshAgentGuestSocket); } || true"
    }

    public static func stateKey(_ dir: String) -> String {
        String(dir.drop(while: { $0 == "/" })).replacingOccurrences(of: "/", with: "_")
    }

    /// Run as root after a FRESH boot (a restore keeps everything in guest memory): a fresh — the
    /// directory is on the root disk, which Stop keeps, so the last boot's sockets and exit records
    /// would otherwise linger — sticky, world-writable deckhold socket directory, so sessions can run as a non-root user; and, for
    /// an image sandbox, each persist dir bind-mounted from the state disk and owned by the user.
    /// Idempotent.
    /// 594 W23: `agentSudo` — the image's user gets passwordless sudo (a sudoers drop-in) or not (the
    /// drop-in removed); applied at every fresh boot, so it follows the sandbox's setting without a rebake.
    /// 594 W10: `timeZone` — the guest's /etc/localtime (every image, the lab too).
    /// 594 W34: plus `guestFixes` — the part that is also safe on a LIVE guest, and runs at every wake too.
    public static func prepareGuest(imageSpec: ImageSpec?, agentSudo: Bool = true, timeZone: GuestTimeZone? = nil,
                                    git: GitGuestSetup? = nil) -> String {
        var s = "set -e; rm -rf /run/deckhold; mkdir -p /run/deckhold; chmod 1777 /run/deckhold"
        // 599g: /run is on the ROOT disk (Stop keeps it), so the last boot's view records would mislead the
        // next wake — a fresh boot has no view yet. The raw mount points are only rmdir'ed (empty ones):
        // never a recursive delete under a path a share is bound at.
        s += "; rm -rf '\(WorkspaceView.viewDirectory)'; for d in '\(WorkspaceView.rawRoot)'/*; do [ -d \"$d\" ] && ! mountpoint -q \"$d\" && rmdir \"$d\" 2>/dev/null; done; true"
        // 599d: the SSH agent's guest half needs doznet, which a fresh boot installs after this (the boot starts it then).
        s += "; " + guestFixes(imageSpec: imageSpec, agentSudo: agentSudo, timeZone: timeZone, git: git, sshAgent: false)
        guard let r = imageSpec else { return s }
        for d in r.resolvedPersistDirs {
            let src = "\(stateMount)/\(stateKey(d))"
            s += "; mkdir -p '\(src)' '\(d)'; chown \(r.user):\(r.user) '\(src)'"
            s += "; p='\(d)'; while [ \"$p\" != '\(r.home)' ] && [ \"$p\" != / ]; do chown \(r.user):\(r.user) \"$p\"; p=$(dirname \"$p\"); done"
            s += "; mountpoint -q '\(d)' || mount --bind '\(src)' '\(d)'"
        }
        return s
    }
}
