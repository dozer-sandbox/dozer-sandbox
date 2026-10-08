import Darwin
import Foundation
import DozerKit

/// Starts the host FULLY DETACHED (585: no launchd agent — nothing is installed in
/// ~/Library/LaunchAgents; 593: never in the caller's process tree — its parent is launchd, through
/// an intermediate that exits): its own session (`setsid`, so a closed terminal or Ctrl-C never
/// reaches it), stdin `/dev/null`, stdout+stderr appended to `<store>/host.log`, and no other file
/// descriptor of the caller (a test harness's pipes must not be held open by the host).
public enum HostLauncher {
    /// This executable (symlinks resolved).
    public static var executablePath: String {
        if let u = Bundle.main.executableURL?.resolvingSymlinksInPath() { return u.path }
        var size: UInt32 = 4096
        var buf = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buf, &size) == 0 {
            let path = String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        return CommandLine.arguments[0]
    }

    /// Start the host FULLY DETACHED; returns its pid. (593 incident: an auto-started host was a CHILD
    /// of the `doz ui` that started it — its own session, but in the UI's process tree — and a tool
    /// that stopped the UI's tree SIGTERMed the host mid-hibernate; a sandbox lost its programs.)
    ///
    /// A double spawn: an intermediate `<executable> host start --launch-detached …` (its own session)
    /// spawns the host in a session of its own, writes the host's pid on its stdout and exits — so the
    /// host's parent is launchd (1), and no client's group, session or tree contains it. The caller
    /// then waits for its socket, as before. `doz host start --foreground` is the only host that lives in
    /// a caller's tree, and only when a person asks for it.
    @discardableResult
    public static func spawn(store: DozerStore, executable: String = executablePath, extra: [String] = []) throws -> pid_t {
        try store.ensureDirectory()
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw HostError(.unavailable, "could not start the host: \(String(cString: strerror(errno)))") }
        let (readFD, writeFD) = (fds[0], fds[1])
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fa, writeFD, 1)
        posix_spawn_file_actions_addopen(&fa, 2, store.logFile.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        let args = [executable, "host", "start", "--launch-detached", "--store", store.root.path] + extra
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { for p in cargs { free(p) } }
        var mid: pid_t = 0
        let rc = posix_spawn(&mid, executable, &fa, &attr, &cargs, environ)
        close(writeFD)
        guard rc == 0 else {
            close(readFD)
            throw HostError(.unavailable, "could not start the host (\(executable)): \(String(cString: strerror(rc)))")
        }
        // The intermediate answers at once (one line) and exits; it is reaped here, never left a zombie.
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 64)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            var p = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 250) >= 0 else { if errno == EINTR { continue }; break }
            if p.revents == 0 { continue }
            let n = read(readFD, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        close(readFD)
        var status: Int32 = 0
        while waitpid(mid, &status, 0) < 0 && errno == EINTR {}
        guard let pid = Int32(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
            throw HostError(.unavailable, "could not start the host (the launcher said nothing) — see \(store.logFile.path)")
        }
        return pid
    }

    /// The intermediate's job (`doz host start --launch-detached`): spawn `<executable> host start
    /// --foreground --launched --store <store> [extra…]` in a new session, stdin `/dev/null`,
    /// stdout+stderr appended to `<store>/host.log`, no other descriptor; returns its pid. The
    /// intermediate then exits, and the host's parent becomes launchd.
    @discardableResult
    public static func spawnHostProcess(store: DozerStore, executable: String = executablePath, extra: [String] = []) throws -> pid_t {
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
        let args = [executable, "host", "start", "--foreground", "--launched", "--store", store.root.path] + extra
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
    public let store: DozerStore
    public let fd: Int32
    public let reader: LineReader

    init(store: DozerStore, fd: Int32) {
        self.store = store
        self.fd = fd
        reader = LineReader(fd: fd)
    }

    deinit { close(fd) }

    /// Connect to the store's host, starting one when `autostart` and none answers.
    public static func connect(store: DozerStore, autostart: Bool, waitSeconds: Double = 90) throws -> HostClient {
        guard store.socketPathFits else { throw HostError(.unavailable, UnixSocket.Failure.pathTooLong(store.socket.path).localizedDescription) }
        if let fd = UnixSocket.connect(store.socket.path) { return HostClient(store: store, fd: fd) }
        guard autostart else { throw HostError(.unavailable, "no host is running for \(store.root.path)") }
        let pid = try HostLauncher.spawn(store: store)
        let deadline = Date().addingTimeInterval(waitSeconds)
        var reaped = false
        while Date() < deadline {
            if let fd = UnixSocket.connect(store.socket.path) { return HostClient(store: store, fd: fd) }
            // It is not our child (launchd's): gone is `kill(pid, 0)` failing — with no lock holder.
            if !reaped, kill(pid, 0) != 0, errno == ESRCH {
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
    public static func waitForHost(store: DozerStore, seconds: Double = 90) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let fd = UnixSocket.connect(store.socket.path) { close(fd); return true }
            usleep(30_000)
        }
        return false
    }

    static func lastLogLines(_ store: DozerStore, _ n: Int = 3) -> String {
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
            throw HostError(.failed, "an answer this CLI cannot read (\(error.localizedDescription)) — is the host older? (doz host stop)")
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
    public static func request(_ r: HostRequest, store: DozerStore, autostart: Bool = true,
                               onEvent: (HostEvent) -> Void = { _ in }) throws -> HostMessage {
        TestSafety.checkStore(store.root)          // 611
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
