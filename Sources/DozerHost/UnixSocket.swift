import Darwin
import Foundation
import DozerKit

/// Unix-socket plumbing for the host and its clients.
public enum UnixSocket {
    public enum Failure: Error, LocalizedError {
        case pathTooLong(String)
        case system(String, Int32)
        public var errorDescription: String? {
            switch self {
            case .pathTooLong(let p): "the socket path is longer than 103 bytes (\(p)) — use a shorter --store"
            case .system(let what, let e): "\(what): \(String(cString: strerror(e)))"
            }
        }
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in for (i, b) in bytes.enumerated() { buf[i] = b } }
        return addr
    }

    /// Bind and listen at `path` (a stale file there is replaced), mode 0600.
    public static func listen(_ path: String, backlog: Int32 = 64) throws -> Int32 {
        var addr = try address(path)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { let e = errno; close(fd); throw Failure.system("bind \(path)", e) }
        chmod(path, 0o600)
        guard Darwin.listen(fd, backlog) == 0 else { let e = errno; close(fd); throw Failure.system("listen", e) }
        return fd
    }

    /// Connect to `path`; nil when nothing listens there.
    public static func connect(_ path: String) -> Int32? {
        guard var addr = try? address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if ok != 0 { close(fd); return nil }
        noSigPipe(fd)
        return fd
    }

    static func noSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Write everything (false when the peer is gone).
    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, base + off, raw.count - off)
                if n <= 0 { if n < 0 && errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
    }
}

/// Reads newline-terminated lines from a file descriptor, keeping whatever follows the last line
/// (after an `attach` response, that is the terminal's first bytes).
public final class LineReader {
    public let fd: Int32
    public private(set) var buffer = Data()

    public init(fd: Int32) { self.fd = fd }

    /// The next line without its newline; nil at end of stream (or on a line over `limit`).
    public func readLine(limit: Int = 64 << 20) -> Data? {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let nl = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                return Data(line)
            }
            if buffer.count > limit { return nil }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    /// Everything buffered past the last line read (and forget it).
    public func takeRemainder() -> Data {
        defer { buffer = Data() }
        return buffer
    }
}

/// One client connection on the host side. The fd NUMBER is released only by `close()`, and every
/// write checks `closed` under the lock — output still streaming for an old connection must never
/// land in the next client that happens to get that number (the 576 Stop bug).
final class HostConnection: @unchecked Sendable {
    let fd: Int32
    // Two locks (576): `writeLock` is held for a whole, possibly blocking, write; `stateLock` only
    // guards `closed`, so shutdownIO can wake a write blocked on a client that stopped reading.
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
        UnixSocket.noSigPipe(fd)
    }

    /// Wake the reader (read → 0) and any blocked write (→ EPIPE); keep the fd number allocated.
    func shutdownIO() { stateLock.lock(); if !closed { Darwin.shutdown(fd, SHUT_RDWR) }; stateLock.unlock() }

    func close() {
        writeLock.lock(); stateLock.lock()
        if !closed { closed = true; Darwin.close(fd) }
        stateLock.unlock(); writeLock.unlock()
    }

    @discardableResult
    func write(_ data: Data) -> Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        stateLock.lock(); let isClosed = closed; stateLock.unlock()
        guard !isClosed else { return false }
        return UnixSocket.writeAll(fd, data)
    }

    @discardableResult
    func send(_ m: HostMessage) -> Bool {
        guard var d = try? HostWire.encoder.encode(m) else { return false }
        d.append(10)
        return write(d)
    }
}

/// The attach wire (SandboxLab's, 576/581): client → host is raw keyboard bytes plus in-band frames
/// `0xFF 'H' cols rows` (HELLO) and `0xFF 'R' cols rows` (RESIZE), sizes big-endian u16 — 0xFF never
/// occurs in UTF-8, so typing cannot forge a frame. Host → client is raw VT, and at the end a notice
/// carrying `endedSentinel` + the program's exit code.
public enum ClientWire {
    public static let sentinelPrefix = "\u{1B}]777;doz;ended;"
    public static let sentinelEnd = "\u{07}"

    public static func hello(_ s: TermSize) -> [UInt8] { [0xFF, 0x48] + be(s) }
    public static func resize(_ s: TermSize) -> [UInt8] { [0xFF, 0x52] + be(s) }
    /// 599: REPAINT (`0xFF 'S' 0 0 0 0`) — send this viewer a fresh SNAPSHOT of the session's screen (the
    /// program is not resized): what clears a notice or the Ctrl-] menu the client drew over it.
    public static let repaint: [UInt8] = [0xFF, 0x53, 0, 0, 0, 0]
    private static func be(_ s: TermSize) -> [UInt8] {
        [UInt8(s.cols >> 8), UInt8(s.cols & 0xFF), UInt8(s.rows >> 8), UInt8(s.rows & 0xFF)]
    }

    public enum Frame: Equatable { case hello(TermSize), resize(TermSize), input(Data), repaint }

    /// Incremental parser for the client → host direction.
    public struct Parser {
        private var carry: [UInt8] = []
        public init() {}
        public mutating func feed(_ bytes: [UInt8]) -> [Frame] {
            let b = carry + bytes
            carry = []
            var out: [Frame] = []
            var input: [UInt8] = []
            var i = 0
            func flush() { if !input.isEmpty { out.append(.input(Data(input))); input = [] } }
            while i < b.count {
                if b[i] == 0xFF {
                    if b.count - i < 6 { carry = Array(b[i...]); break }
                    let size = TermSize(cols: UInt16(b[i + 2]) << 8 | UInt16(b[i + 3]), rows: UInt16(b[i + 4]) << 8 | UInt16(b[i + 5]))
                    if b[i + 1] == 0x48 { flush(); out.append(.hello(size)); i += 6; continue }
                    if b[i + 1] == 0x52 { flush(); out.append(.resize(size)); i += 6; continue }
                    if b[i + 1] == 0x53 { flush(); out.append(.repaint); i += 6; continue }
                }
                input.append(b[i]); i += 1
            }
            flush()
            return out
        }
    }

    /// How a session ended, as the notice carries it.
    public enum Ending: Equatable, Sendable {
        /// The program exited with this code.
        case exited(Int32)
        /// There is no such session.
        case noSession
        /// The sandbox shut down (or was removed): the session is gone.
        case stopped
    }

    /// The notice the host writes when a session is over (then it closes the connection).
    public static func endedNotice(_ ending: Ending, text: String) -> Data {
        let token: String
        switch ending {
        case .exited(let c): token = String(c)
        case .noSession: token = "none"
        case .stopped: token = "stopped"
        }
        return Data("\u{1B}[0m\(sentinelPrefix)\(token)\(sentinelEnd)\r\n[doz] \(text)\r\n".utf8)
    }

    // MARK: 599 — what a bridge did, told to each viewer

    /// `ESC ] 777 ; doz ; notice ; KIND ; TEXT BEL` — in the host → client stream, like the ended notice.
    public static let noticePrefix = "\u{1B}]777;doz;notice;"
    /// What `holdBack` looks for: the start of either notice.
    public static let dozPrefix = "\u{1B}]777;doz;"

    /// A notice for the viewer (kind and text with every control character removed, the text capped).
    public static func notice(_ n: BridgeNotice) -> Data {
        func clean(_ s: String, _ max: Int) -> String {
            String(String(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && !(0x80...0x9F).contains($0.value) }).prefix(max))
        }
        let kind = clean(n.kind, 32).replacingOccurrences(of: ";", with: "")
        return Data("\(noticePrefix)\(kind);\(clean(n.text, 400))\u{07}".utf8)
    }

    /// How many trailing bytes are a notice whose end has not arrived yet (a whole `ESC]777;doz;` with no
    /// BEL after it, within the last KiB) — held for the next read, so no piece of a notice is shown.
    public static func unfinishedNotice(_ bytes: [UInt8]) -> Int {
        let prefix = Array(dozPrefix.utf8)
        let from = max(0, bytes.count - 1024)
        var at: Int?
        var i = from
        while i < bytes.count, let r = bytes[i...].firstRange(of: prefix) { at = r.lowerBound; i = r.upperBound }
        guard var at, !bytes[at...].contains(0x07) else { return 0 }
        // The ended notice's `ESC[0m` in front of it is the notice's too.
        if at >= 4, Array(bytes[(at - 4)..<at]) == [0x1B, 0x5B, 0x30, 0x6D] { at -= 4 }
        return bytes.count - at
    }

    /// Takes every complete notice out of `bytes`, in order.
    public static func takeNotices(_ bytes: inout [UInt8]) -> [BridgeNotice] {
        let prefix = Array(noticePrefix.utf8)
        var found: [BridgeNotice] = []
        var from = 0
        while from < bytes.count, let r = bytes[from...].firstRange(of: prefix) {
            guard let end = bytes[r.upperBound...].firstIndex(of: 0x07) else { break }
            let body = String(decoding: bytes[r.upperBound..<end], as: UTF8.self)
            let parts = body.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            found.append(BridgeNotice(String(parts[0]), parts.count > 1 ? String(parts[1]) : ""))
            bytes.removeSubrange(r.lowerBound...end)
            from = r.lowerBound
        }
        return found
    }

    /// How many trailing bytes might be the start of either host notice (held for the next read, so a
    /// notice is recognised even when a read splits it): an unfinished notice, else a tail that may begin
    /// one — `ESC]777;doz;`, or the ended notice's `ESC[0m` in front of it (so no piece of a notice
    /// reaches a screen; what is held is at most an SGR reset, sent with the next read).
    public static func holdBack(_ bytes: [UInt8]) -> Int {
        let unfinished = unfinishedNotice(bytes)
        if unfinished > 0 { return unfinished }
        let sentinel = Array(dozPrefix.utf8)
        let patterns = [[0x1B, 0x5B, 0x30, 0x6D] + sentinel, sentinel]
        let window = min(bytes.count, sentinelPrefix.utf8.count + 28)
        guard window > 0 else { return 0 }
        for i in (bytes.count - window)..<bytes.count where bytes[i] == 0x1B {
            let tail = Array(bytes[i...])
            for p in patterns {
                let n = min(tail.count, p.count)
                if Array(tail.prefix(n)) == Array(p.prefix(n)) { return bytes.count - i }
            }
        }
        return 0
    }

    /// The host's line after the ended notice ("[doz] the shell session has ended (exit 0)"), without the tag
    /// (a read that cut the tag itself leaves nothing of it either).
    public static func endingText(_ bytes: ArraySlice<UInt8>) -> String {
        guard let bel = bytes.firstIndex(of: 0x07) else { return "" }
        let s = String(decoding: bytes[(bel + 1)...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if "[doz]".hasPrefix(s) { return "" }
        return s.hasPrefix("[doz] ") ? String(s.dropFirst("[doz] ".count)) : s
    }

    /// 609: what EVERY viewer of a session does with the host → client stream, in one place — `doz attach`
    /// (and run/up), each web pane and each All-sessions tile: a bridge's notice is taken out (never drawn,
    /// even when a read cuts it anywhere), the ended notice is found (nothing of it drawn), and the start
    /// of either is held for the next read. The session's own bridge sequences (OSC 52, OSC 6340) never
    /// get here: the host's `SessionBridgeScanner` took them out, once, for every viewer.
    public struct ViewerStream: Sendable {
        /// One read's worth: what goes on the screen, the notices for the person, and the end when it came
        /// (then nothing after it is drawn).
        public struct Step: Sendable {
            public var screen: [UInt8] = []
            public var notices: [BridgeNotice] = []
            public var ending: Ending?
            /// The host's last word after the ended notice (without `[doz] `).
            public var endingText = ""
        }
        private var pending: [UInt8] = []
        public init() {}
        public init(pending: [UInt8]) { self.pending = pending }

        /// The next bytes from the host → what to draw now (anything that may start a notice is held).
        public mutating func feed<S: Sequence>(_ bytes: S) -> Step where S.Element == UInt8 {
            pending += bytes
            var step = Step()
            step.notices = ClientWire.takeNotices(&pending)
            if let (e, start) = ClientWire.findEnding(in: pending) {
                step.screen = Array(pending[..<start])
                step.ending = e
                step.endingText = ClientWire.endingText(pending[start...])
                pending = []
                return step
            }
            let hold = ClientWire.holdBack(pending)
            step.screen = Array(pending[..<(pending.count - hold)])
            pending = Array(pending.suffix(hold))
            return step
        }

        /// The connection closed without an end: what was held goes on the screen (it was not a notice).
        public mutating func flush() -> [UInt8] {
            defer { pending = [] }
            return pending
        }
    }

    /// Finds a notice in `bytes` (which may hold more): the ending and where the notice starts.
    public static func findEnding(in bytes: [UInt8]) -> (Ending, Int)? {
        let prefix = Array(sentinelPrefix.utf8)
        guard let r = bytes.firstRange(of: prefix) else { return nil }
        guard let end = bytes[r.upperBound...].firstIndex(of: 0x07) else { return nil }
        let token = String(decoding: bytes[r.upperBound..<end], as: UTF8.self)
        let reset: [UInt8] = [0x1B, 0x5B, 0x30, 0x6D]          // the ESC[0m in front, when it is there
        let start = r.lowerBound >= 4 && Array(bytes[(r.lowerBound - 4)..<r.lowerBound]) == reset ? r.lowerBound - 4 : r.lowerBound
        switch token {
        case "none": return (.noSession, start)
        case "stopped": return (.stopped, start)
        default: return Int32(token).map { (.exited($0), start) }
        }
    }
}
