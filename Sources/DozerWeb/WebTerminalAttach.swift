import Darwin
import Foundation
import DozerKit
import DozerHost

// 591 — one terminal's connection to the host's attach relay (585): the SAME `attach` HostOp and
// wire the CLI's `doz attach` uses (`ClientWire`). The web layer adds no host operation.

/// How the host answered the attach.
public enum WebAttachStart: Equatable, Sendable {
    /// Relaying now (the session's SNAPSHOT comes first).
    case attached(session: String)
    /// The sandbox is not running (paused, asleep, hibernated): the host holds the connection and
    /// attaches it by itself when the sandbox runs again.
    case held(session: String, phase: String)
}

/// A live attach connection. PULLED, so it has backpressure: the bridge reads the next chunk only
/// after the browser has taken the previous one — no queue grows in this process; a viewer that
/// falls far behind is dropped by the guest's holder (deckhold's per-client limit) and reattaches
/// with a fresh SNAPSHOT.
public protocol WebTerminalAttachment: AnyObject, Sendable {
    var start: WebAttachStart { get }
    /// The next bytes from the host; nil once the host closed the connection — the session's end
    /// (after the ended notice), a hibernation or Sleep (the guest session lives on: reattach), or `close()`.
    func read() async -> Data?
    /// Raw attach-wire bytes: keystrokes, or a `ClientWire.resize` frame.
    func send(_ bytes: [UInt8])
    func close()
}

/// The real attachment: a connection to `<store>/host.sock` in this process — blocking reads on a
/// serial queue of its own (one read at a time, only when asked), writes under a lock.
final class HostTerminalAttachment: WebTerminalAttachment, @unchecked Sendable {
    let start: WebAttachStart
    private let client: HostClient
    private let queue = DispatchQueue(label: "doz-ui-terminal-read")
    private let lock = NSLock()
    private var closed = false
    private var early: Data?

    private init(client: HostClient, start: WebAttachStart) {
        self.client = client
        self.start = start
        let e = client.reader.takeRemainder()
        early = e.isEmpty ? nil : e
    }

    /// Attach (blocking — call off the cooperative pool). Starts a host when none runs, as
    /// `doz attach` does: opening a terminal is an explicit attach (591 T3).
    static func open(store: DozerStore, sandbox: String, session: String?, size: TermSize) throws -> HostTerminalAttachment {
        let client = try HostClient.connect(store: store, autostart: true)
        var req = HostRequest(.attach, name: sandbox)
        req.session = session
        req.cols = size.cols
        req.rows = size.rows
        req.wake = false                       // the UI wakes only on a real keystroke (the 541 rule)
        try client.send(req)
        guard let reply = try client.next() else { throw HostError(.unavailable, "the host closed the connection") }
        guard reply.ok == true else { throw reply.error ?? HostError(.failed, "attach failed") }
        let resolved = reply.result?["session"]?.stringValue ?? session ?? ""
        let start: WebAttachStart = reply.result?["state"]?.stringValue == "held"
            ? .held(session: resolved, phase: reply.result?["phase"]?.stringValue ?? "")
            : .attached(session: resolved)
        return HostTerminalAttachment(client: client, start: start)
    }

    func read() async -> Data? {
        if let e = lock.withLock({ () -> Data? in defer { early = nil }; return early }) { return e }
        let fd = client.fd
        return await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            queue.async {
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = Darwin.read(fd, &buf, buf.count)
                    if n < 0 && errno == EINTR { continue }
                    c.resume(returning: n > 0 ? Data(buf[0..<n]) : nil)
                    return
                }
            }
        }
    }

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        UnixSocket.writeAll(client.fd, Data(bytes))
    }

    /// Wake a blocked read (→ 0) and refuse further writes; the fd itself is released with the client.
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.shutdown(client.fd, SHUT_RDWR)
    }

    deinit { close() }
}
