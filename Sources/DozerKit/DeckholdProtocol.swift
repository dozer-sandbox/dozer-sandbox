import Foundation

/// The deckhold wire protocol (see `Guest/deckhold/deckhold.c`): frames of
/// `[type u8][length u32 big-endian][payload]`, in both directions.
public enum DeckholdFrame: Equatable, Sendable {
    // client → holder
    case hello(TermSize)
    case data(Data)
    case resize(TermSize)
    // holder → client
    case snapshot(Data)
    case output(Data)
    case exit(Int32)
    case info(String)
    case noSession

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
        case .info(let s):
            payload = Data(s.utf8)
        case .noSession:
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

    /// Parses `deckhold ls` output. Live: `NAME\tpid=…\tsize=CxR\tclients=…\tscreen=…\thistory=…\tbytes=…\tCMD`;
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
                default: info.command = field
                }
            }
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
    public static func remountShares(_ shares: [(tag: String, guestPath: String)]) -> String {
        var s = "set -e; mkdir -p /run/dozer-vfs; umount -l /run/dozer-vfs 2>/dev/null || true; "
            + "mount -t virtiofs virtiofs /run/dozer-vfs; ls -a /run/dozer-vfs >/dev/null"
        for share in shares {
            s += "; umount -l '\(share.guestPath)' 2>/dev/null || true"
                + "; mount --bind '/run/dozer-vfs/\(share.tag)' '\(share.guestPath)'"
                + "; ls -a '\(share.guestPath)' >/dev/null"
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
    /// The other names a program reaches for (links to the shim).
    public static let openShimAliases = ["open", "sensible-browser", "www-browser", "x-www-browser"]
    static let openShimStamp = "doz:open-url-shim:v3"

    /// `path` with the shim's directory first (once).
    public static func withOpenShim(_ path: String) -> String {
        let parts = path.split(separator: ":").map(String.init)
        guard parts.first != openShimDirectory else { return path }
        return ([openShimDirectory] + parts.filter { $0 != openShimDirectory }).joined(separator: ":")
    }

    /// The shim (DeckStack's technique, 535/539 — read, not depended on): this sandbox has no browser,
    /// so the URL is handed to the Mac as a private OSC 6340 marker on the session's terminal, which the
    /// host's attach relay takes out and decides on (http/https only, the setting, a notice); plus a
    /// line a person can read. The marker goes to the controlling terminal, else the session's own
    /// (`$DOZ_TTY`, exported by deckhold — an opener that `setsid`s its child has no controlling
    /// terminal), else stdout. `2>/dev/null` BEFORE `>`: a failed rung prints nothing (DeckStack's lesson).
    public static let openShim = #"""
    #!/bin/sh
    # doz:open-url-shim:v3
    # Dozer Sandbox's browser bridge: this sandbox has no browser, so an http(s) URL is handed to the
    # Mac through the session's terminal (doz shows it and opens it in the Mac's default browser —
    # unless the sandbox's browser bridge is off). Written at every boot; see `doz config show --sandbox`.
    url="${1:-}"
    [ -n "$url" ] || { echo "usage: xdg-open URL" >&2; exit 1; }
    [ "${#url}" -le 2048 ] || { echo "xdg-open: the URL is longer than 2048 bytes — not sent to the Mac" >&2; exit 1; }
    clean=$(printf '%s' "$url" | tr -d '\000-\037\177')
    [ "$clean" = "$url" ] || { echo "xdg-open: the URL has control characters — not sent to the Mac" >&2; exit 1; }
    case "$url" in
        http://*|https://*) ;;
        *) echo "xdg-open: this sandbox has no browser, and only http and https URLs go to the Mac: $url" >&2; exit 1 ;;
    esac
    emit() { printf 'Asking your Mac to open: %s\r\n\033]6340;doz-open;%s\007' "$url" "$url"; }
    # Inside tmux (sessions.tmux) the pane's terminal is tmux's, which drops a sequence it does not
    # know: the marker goes to the session's own terminal ($DOZ_TTY, tmux's client), the line to the pane.
    if [ -n "${TMUX:-}" ] && [ -n "${DOZ_TTY:-}" ] && [ -w "$DOZ_TTY" ] \
        && printf '\033]6340;doz-open;%s\007' "$url" 2>/dev/null > "$DOZ_TTY"; then
        printf 'Asking your Mac to open: %s\n' "$url" 2>/dev/null > /dev/tty || printf 'Asking your Mac to open: %s\n' "$url"
        exit 0
    fi
    if [ -w /dev/tty ] 2>/dev/null && emit 2>/dev/null > /dev/tty; then exit 0; fi
    if [ -n "${DOZ_TTY:-}" ] && [ -w "$DOZ_TTY" ] && emit 2>/dev/null > "$DOZ_TTY"; then exit 0; fi
    emit
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
    public static func prepareGuest(imageSpec: ImageSpec?, agentSudo: Bool = true, timeZone: GuestTimeZone? = nil) -> String {
        var s = "set -e; rm -rf /run/deckhold; mkdir -p /run/deckhold; chmod 1777 /run/deckhold"
        s += "; " + ownHostnameScript
        s += "; " + debconfNoninteractiveScript        // 594 W31: apt never asks (keyboard-configuration …)
        s += "; " + openShimInstall                   // 599: the browser bridge's xdg-open (every image)
        if let tz = timeZone { s += "; " + tz.script }
        guard let r = imageSpec else { return s }
        s += "; " + agentSudoScript(user: r.user, on: agentSudo)
        for d in r.resolvedPersistDirs {
            let src = "\(stateMount)/\(stateKey(d))"
            s += "; mkdir -p '\(src)' '\(d)'; chown \(r.user):\(r.user) '\(src)'"
            s += "; p='\(d)'; while [ \"$p\" != '\(r.home)' ] && [ \"$p\" != / ]; do chown \(r.user):\(r.user) \"$p\"; p=$(dirname \"$p\"); done"
            s += "; mountpoint -q '\(d)' || mount --bind '\(src)' '\(d)'"
        }
        return s
    }
}
