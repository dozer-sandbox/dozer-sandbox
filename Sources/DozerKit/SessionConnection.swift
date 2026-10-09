import Containerization
import Foundation

/// What a session connection delivers, in order: one `snapshot` first (the holder's current
/// screen, rendered for this viewer's size — a blank terminal that plays it shows exactly what
/// the program shows), then `data` as the program writes it, possibly a later `snapshot` (after
/// a resize settles, or when the program leaves the alternate screen), and exactly one final
/// `ended` or `detached`, after which the stream finishes.
public enum SessionOutput: Sendable, Equatable {
    case snapshot(Data)
    case data(Data)
    /// The program exited with this code — or nil: there is no such session (it never existed
    /// in this sandbox). Do not reattach.
    case ended(exitCode: Int32?)
    /// 612: a STATUS WATCHER's only output (`Sandbox.watchStatus`): the program's status now, then each change
    /// (nil: it has none). A viewer never gets one.
    case status(ProgramStatus?)
    /// The connection is gone but the session is not: reattach when the sandbox runs again
    /// (`sandboxSleeping`), or never (`sandboxStopped` — the session died with the VM).
    case detached(DetachReason)
}

/// Why a session connection ended without the session itself ending.
public enum DetachReason: String, Sendable, Equatable {
    /// `close()` was called.
    case closedByClient
    /// The sandbox is going to sleep on disk: the exec carrying this connection is about to be
    /// severed. The SESSION survives in the guest; attach again after `wake()`.
    case sandboxSleeping
    /// The sandbox is stopping. The session is gone.
    case sandboxStopped
    /// The transport ended without the holder saying why (the pipe process died).
    case transportLost
}

/// One viewer's connection to a guest session — the ONE seam every terminal front end (an
/// embedded surface, an external Terminal, a test) talks to. `Sandbox.attach` makes one.
///
/// Identity is the object (and its `id`), never a file descriptor number. Once closed — by any
/// path — it never delivers another byte and never sends one: the 576 Stop bug was an exec
/// still streaming into a recycled fd number that a NEW viewer had just been given.
public final class SessionConnection: @unchecked Sendable, Identifiable {
    public let id = UUID()
    /// The guest session this connection is attached to.
    public let session: String
    public let output: AsyncStream<SessionOutput>

    private let outputContinuation: AsyncStream<SessionOutput>.Continuation
    /// Frames for the holder: HELLO first, then DATA/RESIZE — the exec's stdin.
    let input: AsyncStream<Data>
    private let inputContinuation: AsyncStream<Data>.Continuation

    private let lock = NSLock()
    private var closed = false
    private var decoder = DeckholdFrameDecoder()
    private var _final: SessionOutput?
    private var _onClose: (@Sendable (SessionConnection) -> Void)?

    /// 612: a status watcher — WATCH instead of HELLO: no size, not a viewer, STATUS frames only.
    public let isStatusWatch: Bool
    private var _sawStatus = false

    init(session: String, size: TermSize) {
        self.session = session
        isStatusWatch = false
        (output, outputContinuation) = AsyncStream<SessionOutput>.makeStream(bufferingPolicy: .unbounded)
        (input, inputContinuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        inputContinuation.yield(DeckholdFrame.hello(size).encoded)
    }

    init(statusOf session: String) {
        self.session = session
        isStatusWatch = true
        (output, outputContinuation) = AsyncStream<SessionOutput>.makeStream(bufferingPolicy: .unbounded)
        (input, inputContinuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        inputContinuation.yield(DeckholdFrame.watch.encoded)
    }

    /// 612: whether the holder ever answered WATCH. A watcher that ends WITHOUT one met a holder too old to
    /// know it (a session started before an update keeps its own deckhold) — do not ask that session again.
    public var sawStatus: Bool { lock.lock(); defer { lock.unlock() }; return _sawStatus }

    /// True once the connection has ended or detached.
    public var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    /// The final element delivered (`ended` or `detached`), once closed.
    public var finalOutput: SessionOutput? { lock.lock(); defer { lock.unlock() }; return _final }

    /// Keystrokes / pasted bytes for the program. Dropped after close.
    public func send(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        inputContinuation.yield(DeckholdFrame.data(bytes).encoded)
    }

    /// The viewer's size changed: the holder resizes the pty (the program gets SIGWINCH) and
    /// its model (reflow), and sends a fresh snapshot once the resize settles.
    public func resize(_ size: TermSize) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        inputContinuation.yield(DeckholdFrame.resize(size).encoded)
    }

    /// 599: a fresh SNAPSHOT of the session's screen for this viewer, the program untouched — a HELLO of
    /// 0×0 on the live connection (deckhold keeps the size for 0×0 and answers every HELLO with a
    /// snapshot, as it does for a screen capture). What a client uses to remove what it drew over it.
    public func repaint() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        inputContinuation.yield(DeckholdFrame.hello(TermSize(cols: 0, rows: 0)).encoded)
    }

    /// Detach this viewer. The session keeps running in the guest.
    public func close() { finish(.detached(.closedByClient)) }

    // MARK: transport side (the Sandbox)

    func setOnClose(_ f: @escaping @Sendable (SessionConnection) -> Void) {
        lock.lock(); _onClose = f; lock.unlock()
    }

    /// Bytes from the pipe exec's stdout: holder → client frames.
    func receive(_ bytes: Data) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        let frames: [DeckholdFrame]
        do { frames = try decoder.feed(bytes) } catch {
            lock.unlock()
            finish(.detached(.transportLost))
            return
        }
        var last: SessionOutput?
        for f in frames {
            switch f {
            case .snapshot(let d): outputContinuation.yield(.snapshot(d))
            case .output(let d): outputContinuation.yield(.data(d))
            case .exit(let code): last = .ended(exitCode: code)
            case .noSession: last = .ended(exitCode: nil)
            case .status(let s):
                _sawStatus = true
                outputContinuation.yield(.status(ProgramStatus.parse(frame: s)))
            case .info, .hello, .data, .resize, .watch: break
            }
            if last != nil { break }
        }
        lock.unlock()
        if let last { finish(last) }
    }

    /// The Sandbox severs this connection (sleep to disk, stop) or its transport died.
    func detach(_ reason: DetachReason) { finish(.detached(reason)) }

    private func finish(_ last: SessionOutput) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        _final = last
        outputContinuation.yield(last)
        outputContinuation.finish()
        inputContinuation.finish()          // → the pipe's stdin closes → it exits
        let cb = _onClose
        _onClose = nil
        lock.unlock()
        cb?(self)
    }
}

/// The pipe exec's stdout → the connection.
struct ConnectionWriter: Writer {
    let connection: SessionConnection
    func write(_ data: Data) throws { connection.receive(data) }
    func close() throws {}
}

/// The connection's frames → the pipe exec's stdin.
struct ConnectionReader: ReaderStream {
    let source: AsyncStream<Data>
    func stream() -> AsyncStream<Data> { source }
}

/// 593: a screen capture's pipe stdout → its SNAPSHOT and DUMP answer (or the EXIT / NOSESSION that
/// came instead). `onDone` fires once, when the answer is complete — the capture then closes stdin.
final class ScreenCollector: Writer, @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = DeckholdFrameDecoder()
    private var snapshot: Data?
    private var dump: String?
    private var exitCode: Int32?
    private var noSession = false
    private var done = false
    var onDone: (@Sendable () -> Void)?

    func write(_ data: Data) throws {
        var fire: (@Sendable () -> Void)?
        lock.lock()
        if !done {
            do {
                for f in try decoder.feed(data) {
                    switch f {
                    case .snapshot(let d): if snapshot == nil { snapshot = d }
                    case .info(let s): dump = s
                    case .exit(let c): exitCode = c
                    case .noSession: noSession = true
                    case .output, .hello, .data, .resize, .watch, .status: break
                    }
                }
            } catch {
                noSession = true
            }
            if dump != nil || exitCode != nil || noSession {
                done = true
                fire = onDone
            }
        }
        lock.unlock()
        fire?()
    }

    func close() throws {}

    /// Nil: no such session, or no screen came back in time.
    var result: Sandbox.CapturedScreen? {
        lock.lock(); defer { lock.unlock() }
        if let exitCode, snapshot == nil { return Sandbox.CapturedScreen(exitCode: exitCode) }
        guard !noSession, let snapshot, let dump else { return nil }
        return Sandbox.CapturedScreen(snapshot: snapshot, dump: dump)
    }
}

/// Collects an exec's output.
final class OutputCollector: Writer, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    /// 593: each chunk as it arrives, too (a bake step's live output).
    private let onData: (@Sendable (Data) -> Void)?
    init(onData: (@Sendable (Data) -> Void)? = nil) { self.onData = onData }
    func write(_ data: Data) throws {
        lock.lock(); buffer.append(data); lock.unlock()
        onData?(data)
    }
    func close() throws {}
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
}

/// 599: a byte stream to a guest program's stdin/stdout (`Sandbox.openGuestStream`) — the browser
/// bridge's `deckhold connect -p PORT`, relaying one TCP connection from the Mac into the guest's loopback.
public final class GuestStream: @unchecked Sendable {
    /// The program's stdout, until it exits.
    public let output: AsyncStream<Data>
    let outputContinuation: AsyncStream<Data>.Continuation
    let input: AsyncStream<Data>
    private let inputContinuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var inputOpen = true
    /// The program's exit code, once it exited (nil before, or when the transport died).
    public private(set) var exitCode: Int32?

    init() {
        (output, outputContinuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        (input, inputContinuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Bytes for the program's stdin (dropped once the input is finished).
    public func send(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if inputOpen { inputContinuation.yield(d) }
    }

    /// The program's stdin reaches its end (the program sees EOF).
    public func finishInput() {
        lock.lock(); defer { lock.unlock() }
        guard inputOpen else { return }
        inputOpen = false
        inputContinuation.finish()
    }

    func ended(_ code: Int32?) {
        lock.lock(); exitCode = code; lock.unlock()
        outputContinuation.finish()
    }
}

/// A guest stream's stdout → its `output`.
struct GuestStreamWriter: Writer {
    let stream: GuestStream
    func write(_ data: Data) throws { stream.outputContinuation.yield(data) }
    func close() throws {}
}

/// The result of `Sandbox.exec`.
public struct ExecResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
}
