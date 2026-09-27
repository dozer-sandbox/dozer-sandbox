import Darwin
import Foundation
import SnoozeHost

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
    public static func lockFile(_ store: SnoozeStore) -> URL { store.root.appendingPathComponent("ui.lock") }
    public static func socket(_ store: SnoozeStore) -> URL { store.root.appendingPathComponent("ui.sock") }

    /// Take the store's UI lock for the life of the process; nil when another UI holds it.
    public static func takeLock(_ store: SnoozeStore) throws -> Int32? {
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
    public static func serve(_ store: SnoozeStore, server: SnoozeWebServer) throws -> Int32 {
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

    private static func answer(_ fd: Int32, server: SnoozeWebServer) {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard let line = LineReader(fd: fd).readLine(limit: 64), String(decoding: line, as: UTF8.self) == "link" else { return }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.url = await server.newLink()
            done.signal()
        }
        done.wait()
        guard let url = box.url else { return }
        _ = UnixSocket.writeAll(fd, Data((url.absoluteString + "\n").utf8))
    }

    /// Ask the store's running UI for a new link; nil when no UI runs for this store.
    public static func requestLink(_ store: SnoozeStore) -> URL? {
        guard let fd = UnixSocket.connect(socket(store).path) else { return nil }
        defer { close(fd) }
        guard UnixSocket.writeAll(fd, Data("link\n".utf8)), let line = LineReader(fd: fd).readLine(limit: 1024) else { return nil }
        guard let url = URL(string: String(decoding: line, as: UTF8.self)), url.scheme == "http", url.host == WebLoopbackAddress.host,
              url.fragment?.hasPrefix("cap=") == true else { return nil }
        return url
    }

    /// Remove the socket when the UI stops.
    public static func cleanUp(_ store: SnoozeStore, listenFD: Int32, lockFD: Int32) {
        unlink(socket(store).path)
        close(listenFD)
        flock(lockFD, LOCK_UN)
        close(lockFD)
    }
}
