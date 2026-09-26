import Darwin
import Foundation
import SnoozeContainerKit

/// Starts the host as a DETACHED child (585: no launchd agent — nothing is installed in
/// ~/Library/LaunchAgents): its own session (`setsid`, so a closed terminal or Ctrl-C never
/// reaches it), stdin `/dev/null`, stdout+stderr appended to `<store>/host.log`, and no other file
/// descriptor of the caller (a test harness's pipes must not be held open by the host).
public enum HostLauncher {
    /// This executable (symlinks resolved).
    public static var executablePath: String {
        if let u = Bundle.main.executableURL?.resolvingSymlinksInPath() { return u.path }
        var size: UInt32 = 4096
        var buf = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buf, &size) == 0 { return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path }
        return CommandLine.arguments[0]
    }

    /// Spawn `<executable> host --foreground --store <store> [extra…]`; returns its pid.
    @discardableResult
    public static func spawn(store: SnoozeStore, executable: String = executablePath, extra: [String] = []) throws -> pid_t {
        try store.ensureDirectory()
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var def = sigset_t()
        sigfillset(&def)
        posix_spawnattr_setsigdefault(&attr, &def)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, store.logFile.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&fa, 1, 2)
        let args = [executable, "host", "--foreground", "--store", store.root.path] + extra
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { for p in cargs { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &fa, &attr, &cargs, environ)
        guard rc == 0 else { throw HostError(.unavailable, "could not start the host (\(executable)): \(String(cString: strerror(rc)))") }
        return pid
    }
}

/// One connection to the host.
public final class HostClient {
    public let store: SnoozeStore
    public let fd: Int32
    public let reader: LineReader

    init(store: SnoozeStore, fd: Int32) {
        self.store = store
        self.fd = fd
        reader = LineReader(fd: fd)
    }

    deinit { close(fd) }

    /// Connect to the store's host, starting one when `autostart` and none answers.
    public static func connect(store: SnoozeStore, autostart: Bool, waitSeconds: Double = 90) throws -> HostClient {
        guard store.socketPathFits else { throw HostError(.unavailable, UnixSocket.Failure.pathTooLong(store.socket.path).localizedDescription) }
        if let fd = UnixSocket.connect(store.socket.path) { return HostClient(store: store, fd: fd) }
        guard autostart else { throw HostError(.unavailable, "no host is running for \(store.root.path)") }
        let pid = try HostLauncher.spawn(store: store)
        let deadline = Date().addingTimeInterval(waitSeconds)
        var reaped = false
        while Date() < deadline {
            if let fd = UnixSocket.connect(store.socket.path) { return HostClient(store: store, fd: fd) }
            var status: Int32 = 0
            if !reaped, waitpid(pid, &status, WNOHANG) == pid {
                reaped = true
                // It exited: another host may have won the race (then its socket appears) — or it failed.
                if !store.hostIsRunning() {
                    if let fd = UnixSocket.connect(store.socket.path) { return HostClient(store: store, fd: fd) }
                    throw HostError(.unavailable, "the host exited at start — \(lastLogLines(store))")
                }
            }
            usleep(30_000)
        }
        throw HostError(.unavailable, "the host did not answer within \(Int(waitSeconds)) s — \(lastLogLines(store))")
    }

    /// Wait for a host that is starting to answer its socket.
    public static func waitForHost(store: SnoozeStore, seconds: Double = 90) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let fd = UnixSocket.connect(store.socket.path) { close(fd); return true }
            usleep(30_000)
        }
        return false
    }

    static func lastLogLines(_ store: SnoozeStore, _ n: Int = 3) -> String {
        guard let s = try? String(contentsOf: store.logFile, encoding: .utf8) else { return "see \(store.logFile.path)" }
        return s.split(separator: "\n").suffix(n).joined(separator: " | ")
    }

    public func send(_ r: HostRequest) throws {
        var d = try HostWire.encoder.encode(r)
        d.append(10)
        guard UnixSocket.writeAll(fd, d) else { throw HostError(.unavailable, "the host closed the connection") }
    }

    /// The next line from the host; nil at end of stream.
    public func next() throws -> HostMessage? {
        guard let line = reader.readLine() else { return nil }
        do { return try HostWire.decoder.decode(HostMessage.self, from: line) } catch {
            throw HostError(.failed, "an answer this CLI cannot read (\(error.localizedDescription)) — is the host older? (snooze host stop)")
        }
    }

    /// Send `r` and read until the final line, passing progress events to `onEvent`.
    public func call(_ r: HostRequest, onEvent: (HostEvent) -> Void = { _ in }) throws -> HostMessage {
        try send(r)
        while let m = try next() {
            if let e = m.event { onEvent(e); continue }
            if m.ok != nil { return m }
        }
        throw HostError(.unavailable, "the host closed the connection before answering")
    }

    /// One request on a fresh connection. A connection the host dropped before answering at all
    /// (it was exiting as the request arrived) is retried once, starting a new host.
    public static func request(_ r: HostRequest, store: SnoozeStore, autostart: Bool = true,
                               onEvent: (HostEvent) -> Void = { _ in }) throws -> HostMessage {
        var attempt = 0
        while true {
            attempt += 1
            let c = try connect(store: store, autostart: autostart)
            var answered = false
            do {
                return try c.call(r) { e in answered = true; onEvent(e) }
            } catch let e as HostError where e.code == .unavailable && !answered && attempt == 1 {
                usleep(200_000)
                continue
            }
        }
    }
}
