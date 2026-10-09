import Darwin
import Foundation

/// 606 (rc.2, owner: "add --detach"): `doz serve start --detach` — `doz serve` started FULLY DETACHED, exactly the way
/// the host is (`HostLauncher`; "A host never lives in a client's process tree", 593): a double spawn — an intermediate
/// `<doz> serve start --launch-detached …` in a session of its own spawns `<doz> serve start --launched …` in ANOTHER
/// session, writes its pid and exits, so `doz serve`'s parent is launchd; stdin `/dev/null`, stdout + stderr appended to
/// `<store>/serve/serve.log`, no other descriptor of the caller (`POSIX_SPAWN_CLOEXEC_DEFAULT`), every signal at its
/// default and none blocked. The argument lists are pure (`DetachedLauncherTests`).
public enum DetachedLauncher {
    /// The intermediate: `<doz> serve start --launch-detached --store S [extra…]`.
    public static func serveIntermediateArgs(executable: String, store: String, extra: [String] = []) -> [String] {
        [executable, "serve", "start", "--launch-detached", "--store", store] + extra
    }

    /// The detached `doz serve`: `<doz> serve start --launched --no-invite --store S [extra…]` (no terminal: no invite).
    public static func serveProcessArgs(executable: String, store: String, extra: [String] = []) -> [String] {
        [executable, "serve", "start", "--launched", "--no-invite", "--store", store] + extra
    }

    /// `doz ui --detach`'s intermediate: `<doz> ui start --launch-detached --store S [extra…]`.
    public static func uiIntermediateArgs(executable: String, store: String, extra: [String] = []) -> [String] {
        [executable, "ui", "start", "--launch-detached", "--store", store] + extra
    }
    /// The detached `doz ui`: `<doz> ui start --launched --no-open --store S [extra…]` — it never opens a tab itself
    /// (no terminal); the `doz ui --detach` that started it hands the link over.
    public static func uiProcessArgs(executable: String, store: String, extra: [String] = []) -> [String] {
        [executable, "ui", "start", "--launched", "--no-open", "--store", store] + extra
    }
    /// A detached `doz ui`'s log (`<store>/ui.log`).
    public static func uiLog(_ root: URL) -> URL { root.appendingPathComponent("ui.log") }
    /// `doz serve`'s log (`<store>/serve/serve.log`).
    public static func serveLog(_ root: URL) -> URL { root.appendingPathComponent("serve/serve.log") }

    static func ensureLogDirectory(_ log: URL) {
        let dir = log.deletingLastPathComponent()
        mkdir(dir.path, 0o700)
    }

    /// Run the intermediate (its own session, its stdout a pipe to us, stderr the log) and return the pid it reports.
    public static func spawnViaIntermediate(_ args: [String], log: URL) throws -> pid_t {
        ensureLogDirectory(log)
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw HostError(.unavailable, "could not start doz serve: \(String(cString: strerror(errno)))") }
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
        posix_spawn_file_actions_addopen(&fa, 2, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { for p in cargs { free(p) } }
        var mid: pid_t = 0
        let rc = posix_spawn(&mid, args[0], &fa, &attr, &cargs, environ)
        close(writeFD)
        guard rc == 0 else {
            close(readFD)
            throw HostError(.unavailable, "could not start doz serve (\(args[0])): \(String(cString: strerror(rc)))")
        }
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
            throw HostError(.unavailable, "could not start doz serve (the launcher said nothing) — see \(log.path)")
        }
        return pid
    }

    /// The intermediate's job: spawn `args` in a new session, stdin /dev/null, stdout + stderr the log, no other
    /// descriptor, signals at their defaults; returns its pid (then the intermediate exits: the parent becomes launchd).
    public static func spawnDetached(_ args: [String], log: URL) throws -> pid_t {
        ensureLogDirectory(log)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
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
        posix_spawn_file_actions_addopen(&fa, 1, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&fa, 1, 2)
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { for p in cargs { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, args[0], &fa, &attr, &cargs, environ)
        guard rc == 0 else { throw HostError(.unavailable, "could not start doz serve (\(args[0])): \(String(cString: strerror(rc)))") }
        return pid
    }
}
