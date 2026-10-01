import Containerization
import Darwin
import Foundation

// 599d (G4): optional SSH agent forwarding. SSH is end-to-end encrypted, so the proxy cannot insert a
// credential: instead the Mac's ssh-agent is made reachable from inside the sandbox. The private keys
// never leave the Mac — the guest can only list them and ask the agent to SIGN (`allowed`: every other
// request — add, remove, lock — is refused here, never passed to the agent). The guest half is `doznet agent`
// (a unix socket, `GuestCommand.sshAgentGuestSocket`, whose every connection it relays over vsock to
// this listener); this half connects each one to the Mac's agent socket. Only while the user turned it
// on (`sandbox.ssh_agent`); the policy then allows github.com:22 only (`EgressProxy.sshToGitHub`).

/// The user's GitHub setup inside the guest (`GuestCommand.gitConfigScript`): nothing secret — on/off,
/// and the identity copied from the Mac's global git config.
public struct GitGuestSetup: Sendable, Equatable {
    public var on: Bool
    public var name: String?
    public var email: String?
    public init(on: Bool, name: String? = nil, email: String? = nil) {
        self.on = on
        // An identity is one line of plain text (it lands in a config file): anything else is dropped.
        func clean(_ s: String?) -> String? {
            guard let s, !s.isEmpty, s.count <= 200, !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
            return s
        }
        self.name = on ? clean(name) : nil
        self.email = on ? clean(email) : nil
    }
    public static let off = GitGuestSetup(on: false)
}

public final class SSHAgentRelay: @unchecked Sendable {
    /// The vsock port `doznet agent` dials (host CID 2) — beside the proxy's 5800.
    public static let vsockPort: UInt32 = 5801

    /// The Mac's agent socket (`SSH_AUTH_SOCK`).
    public let agentSocket: String
    private let lock = NSLock()
    private var listener: VsockListener?
    private var acceptTask: Task<Void, Never>?
    private var _onConnect: (@Sendable () -> Void)?

    /// Each guest connection (the owner tells the user on first use).
    public var onConnect: (@Sendable () -> Void)? {
        get { lock.withLock { _onConnect } }
        set { lock.withLock { _onConnect = newValue } }
    }

    public init(agentSocket: String) { self.agentSocket = agentSocket }

    /// Accept the guest's connections on `instance` (again after every wake — a VM stop drops vsock listeners).
    public func listen(on instance: VZVirtualMachineInstance) throws {
        stop()
        let l = try instance.listen(Self.vsockPort)
        lock.lock()
        listener = l
        acceptTask = Task.detached { [weak self] in
            for await fh in l {
                let fd = fh.fileDescriptor
                guard let self else { close(fd); continue }
                Thread.detachNewThread { self.handle(fd) }
            }
        }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let l = listener, t = acceptTask
        listener = nil; acceptTask = nil
        lock.unlock()
        try? l?.finish()
        t?.cancel()
    }

    public var isListening: Bool { lock.withLock { listener != nil } }

    func handle(_ fd: Int32) {
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
        onConnect?()
        let a = Self.connectUnix(agentSocket)
        guard a >= 0 else { return }                 // no agent: the guest's ssh sees a closed agent
        defer { close(a) }
        setsockopt(a, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
        Self.relayFiltered(guest: fd, agent: a)
    }

    // MARK: what the guest may ask of the agent

    /// SSH_AGENT_FAILURE, framed: the answer to a request that is not let through.
    static let failure: [UInt8] = [0, 0, 0, 1, 5]
    /// The largest request passed on (OpenSSH's own agent limit).
    static let maximumMessage = 256 << 10

    /// The requests a sandbox may make of the Mac's agent: list its keys (11), sign (13), and the
    /// `session-bind@openssh.com` extension (27) OpenSSH's client sends before using a key. Everything
    /// else — adding or removing keys (17, 18, 19, 25, 26), locking or unlocking the agent (22, 23), other
    /// extensions — is answered SSH_AGENT_FAILURE here and never reaches the agent.
    public static func allowed(_ message: [UInt8]) -> Bool {
        guard let type = message.first else { return false }
        switch type {
        case 11, 13: return true
        case 27:
            guard message.count >= 5 else { return false }
            let n = Int(message[1]) << 24 | Int(message[2]) << 16 | Int(message[3]) << 8 | Int(message[4])
            guard n <= message.count - 5 else { return false }
            return String(decoding: message[5..<(5 + n)], as: UTF8.self) == "session-bind@openssh.com"
        default: return false
        }
    }

    /// Relay a connection, judging each request from the guest (agent → guest passes as it is).
    static func relayFiltered(guest: Int32, agent: Int32) {
        var pending: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            var p = [pollfd(fd: guest, events: Int16(POLLIN), revents: 0), pollfd(fd: agent, events: Int16(POLLIN), revents: 0)]
            if poll(&p, 2, -1) < 0 { if errno == EINTR { continue }; return }
            if p[0].revents != 0 {
                let n = buf.withUnsafeMutableBytes { read(guest, $0.baseAddress, $0.count) }
                if n <= 0 { return }
                pending += buf[0..<n]
                while pending.count >= 4 {
                    let len = Int(pending[0]) << 24 | Int(pending[1]) << 16 | Int(pending[2]) << 8 | Int(pending[3])
                    guard len > 0, len <= maximumMessage else { return }           // malformed: the connection ends
                    guard pending.count >= 4 + len else { break }
                    let message = Array(pending[4..<(4 + len)])
                    let whole = Array(pending[0..<(4 + len)])
                    pending.removeFirst(4 + len)
                    if allowed(message) {
                        guard Wire.writeAll(agent, whole) else { return }
                    } else {
                        guard Wire.writeAll(guest, failure) else { return }
                    }
                }
            }
            if p[1].revents != 0 {
                let n = buf.withUnsafeMutableBytes { read(agent, $0.baseAddress, $0.count) }
                if n <= 0 { return }
                guard Wire.writeAll(guest, Array(buf[0..<n])) else { return }
            }
        }
    }

    /// 599e: what `ssh-add -l` shows — the agent at `socket` asked for its keys (SSH2_AGENTC_REQUEST_IDENTITIES);
    /// their comments, in order. Nothing is signed or changed.
    public static func listKeys(socket path: String) -> Result<[String], CheckFailure> {
        let fd = connectUnix(path)
        guard fd >= 0 else { return .failure(CheckFailure("no ssh-agent answers at \(path)")) }
        defer { close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard Wire.writeAll(fd, [0, 0, 0, 1, 11]), let lenBytes = Wire.readExact(fd, 4) else { return .failure("the ssh-agent did not answer") }
        let len = Int(lenBytes[0]) << 24 | Int(lenBytes[1]) << 16 | Int(lenBytes[2]) << 8 | Int(lenBytes[3])
        guard len >= 5, len <= maximumMessage, let body = Wire.readExact(fd, len), body[0] == 12 else {
            return .failure("the ssh-agent's answer was not a list of keys")
        }
        var i = 1
        func u32() -> Int? {
            guard i + 4 <= body.count else { return nil }
            defer { i += 4 }
            return Int(body[i]) << 24 | Int(body[i + 1]) << 16 | Int(body[i + 2]) << 8 | Int(body[i + 3])
        }
        func string() -> [UInt8]? {
            guard let n = u32(), n >= 0, i + n <= body.count else { return nil }
            defer { i += n }
            return Array(body[i..<(i + n)])
        }
        guard let count = u32(), count < 10_000 else { return .failure("the ssh-agent's answer was malformed") }
        var comments: [String] = []
        for _ in 0..<count {
            guard string() != nil, let c = string() else { return .failure("the ssh-agent's answer was malformed") }
            comments.append(String(decoding: c, as: UTF8.self))
        }
        return .success(comments)
    }

    /// A connected unix stream socket to `path`, or -1.
    public static func connectUnix(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return -1 }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            for (i, b) in bytes.enumerated() { p[i] = b }
            p[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if ok != 0 { close(fd); return -1 }
        return fd
    }
}
