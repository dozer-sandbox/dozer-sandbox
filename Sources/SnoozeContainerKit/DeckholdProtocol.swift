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
        var s = "set -e; mkdir -p /run/snooze-vfs; umount -l /run/snooze-vfs 2>/dev/null || true; "
            + "mount -t virtiofs virtiofs /run/snooze-vfs; ls -a /run/snooze-vfs >/dev/null"
        for share in shares {
            s += "; umount -l '\(share.guestPath)' 2>/dev/null || true"
                + "; mount --bind '/run/snooze-vfs/\(share.tag)' '\(share.guestPath)'"
                + "; ls -a '\(share.guestPath)' >/dev/null"
        }
        return s
    }
}
