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
    private static func be(_ s: TermSize) -> [UInt8] {
        [UInt8(s.cols >> 8), UInt8(s.cols & 0xFF), UInt8(s.rows >> 8), UInt8(s.rows & 0xFF)]
    }

    public enum Frame: Equatable { case hello(TermSize), resize(TermSize), input(Data) }

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
