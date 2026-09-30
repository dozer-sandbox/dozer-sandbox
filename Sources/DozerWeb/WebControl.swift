import Darwin
import Foundation
import DozerHost

/// One UI per store, and a way to get a NEW link from the one that runs (590; DeckStack 503's
/// `deck stack web link`, over its owner-only control socket).
///
///     <store>/ui.lock   flock'd by the running UI for its whole life
///     <store>/ui.sock   0600, in the user's own store directory; the peer's uid is checked too
///
/// The socket speaks one line each way: `link` → a fresh one-use launch URL. That URL is a bearer
/// credential (for the UI only, for a few minutes, once): the only other place it goes is a
/// browser (LaunchServices, never a process argument) or the TTY the user asked it be printed on.
public enum WebControl {
    public static func lockFile(_ store: DozerStore) -> URL { store.root.appendingPathComponent("ui.lock") }
    public static func socket(_ store: DozerStore) -> URL { store.root.appendingPathComponent("ui.sock") }
    /// 594 W18: the port the store's last UI listened on (0600) — the next `doz ui` asks for it again,
    /// so a page left open reconnects to the same origin. Not a secret; a page there still needs a
    /// new link to sign in.
    public static func portFile(_ store: DozerStore) -> URL { store.root.appendingPathComponent("ui.port") }

    /// The address a new UI binds: the last port when nothing listens there, else the OS's pick.
    public static func address(_ store: DozerStore) -> WebLoopbackAddress {
        guard let s = try? String(contentsOf: portFile(store), encoding: .utf8),
              let port = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              let a = WebLoopbackAddress(reusing: port) else { return WebLoopbackAddress() }
        return a
    }

    /// Remember the port this UI listens on.
    public static func rememberPort(_ store: DozerStore, _ port: Int) {
        let url = portFile(store)
        guard (try? "\(port)\n".write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        chmod(url.path, 0o600)
    }

    /// Take the store's UI lock for the life of the process; nil when another UI holds it.
    public static func takeLock(_ store: DozerStore) throws -> Int32? {
        try store.ensureDirectory()
        let fd = open(lockFile(store).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HostError(.failed, "cannot open \(lockFile(store).path): \(String(cString: strerror(errno)))") }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        return fd
    }

    /// Serve `link` requests for `server` on a background thread. Returns the listening fd.
    @discardableResult
    public static func serve(_ store: DozerStore, server: DozerWebServer) throws -> Int32 {
        let lfd = try UnixSocket.listen(socket(store).path, backlog: 8)
        Thread.detachNewThread {
            while true {
                let c = accept(lfd, nil, nil)
                if c < 0 {
                    if errno == EINTR { continue }
                    return
                }
                _ = fcntl(c, F_SETFD, FD_CLOEXEC)
                answer(c, server: server)
                close(c)
            }
        }
        return lfd
    }

    private final class Box: @unchecked Sendable { var url: URL? }

    private static func answer(_ fd: Int32, server: DozerWebServer) {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard let line = LineReader(fd: fd).readLine(limit: 64) else { return }
        let command = String(decoding: line, as: UTF8.self)
        guard ["link", "rotate", "status"].contains(command) else { return }
        if command == "status" {
            // 594 W19: the origin and how many pages are open (no key in it).
            _ = UnixSocket.writeAll(fd, Data("\(server.origin.value) \(server.openPages)\n".utf8))
            return
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.url = command == "rotate" ? await server.rotate() : await server.newLink()
            done.signal()
        }
        done.wait()
        guard let url = box.url else { return }
        _ = UnixSocket.writeAll(fd, Data((url.absoluteString + "\n").utf8))
    }

    private static func ask(_ store: DozerStore, _ command: String) -> String? {
        guard let fd = UnixSocket.connect(socket(store).path) else { return nil }
        defer { close(fd) }
        guard UnixSocket.writeAll(fd, Data((command + "\n").utf8)), let line = LineReader(fd: fd).readLine(limit: 1024) else { return nil }
        return String(decoding: line, as: UTF8.self)
    }

    private static func launchURL(_ s: String?) -> URL? {
        guard let s, let url = URL(string: s), url.scheme == "http", url.host == WebLoopbackAddress.host,
              url.fragment?.hasPrefix("cap=") == true else { return nil }
        return url
    }

    /// Ask the store's running UI for a new link; nil when no UI runs for this store.
    public static func requestLink(_ store: DozerStore) -> URL? { launchURL(ask(store, "link")) }

    /// 594 W19: end every session of the running UI (each open page is told to use a new link) and
    /// get that new link; nil when no UI runs.
    public static func requestRotate(_ store: DozerStore) -> URL? { launchURL(ask(store, "rotate")) }

    /// 594 W19: the running UI's origin and its open pages; nil when no UI runs for this store.
    public static func requestStatus(_ store: DozerStore) -> (origin: String, pages: Int)? {
        guard let parts = ask(store, "status")?.split(separator: " "), parts.count == 2, let n = Int(parts[1]),
              parts[0].hasPrefix("http://\(WebLoopbackAddress.host):") else { return nil }
        return (String(parts[0]), n)
    }

    /// 594 W19: the sessions a restarted UI keeps (`WebSessionStore`: cookie digests, 0600).
    public static func sessionsFile(_ store: DozerStore) -> URL { store.root.appendingPathComponent("ui.sessions") }

    /// Remove the socket when the UI stops.
    public static func cleanUp(_ store: DozerStore, listenFD: Int32, lockFD: Int32) {
        unlink(socket(store).path)
        close(listenFD)
        flock(lockFD, LOCK_UN)
        close(lockFD)
    }
}
