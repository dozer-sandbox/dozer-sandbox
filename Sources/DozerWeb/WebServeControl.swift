import Darwin
import Foundation
import DozerHost

/// 606 — one `doz serve` per store, and the Mac's way to talk to it (`WebControl`'s model, 590):
///
///     <store>/serve.lock        flock'd by the running doz serve for its whole life
///     <store>/serve.sock        0600, in the user's own store directory; the peer's uid is checked too
///     <store>/serve/            0700: devices.json (0600), audit.jsonl (0600), port (what the host keeps sandboxes from)
///
/// One line each way; the answer is one JSON object (or an error line). `status`, `devices`, `share`,
/// `revoke ID|--all`, `rename ID NAME`, `probe` (a one-use token for `doz doctor`), `stop`. A `share` answer holds
/// an invite's link — a bearer key for one admission, for five minutes: the CLI prints it only to a terminal.
public enum WebServeControl {
    public static func lockFile(_ root: URL) -> URL { root.appendingPathComponent("serve.lock") }
    public static func socket(_ root: URL) -> URL { root.appendingPathComponent("serve.sock") }
    public static func directory(_ root: URL) -> URL { root.appendingPathComponent("serve", isDirectory: true) }
    public static func devicesFile(_ root: URL) -> URL { directory(root).appendingPathComponent("devices.json") }
    public static func auditFile(_ root: URL) -> URL { directory(root).appendingPathComponent("audit.jsonl") }
    /// The port a running doz serve listens on (the host refuses it to sandboxes — `HostServer`).
    public static func portFile(_ root: URL) -> URL { directory(root).appendingPathComponent("port") }

    /// Take the store's serve lock for the life of the process; nil when another doz serve holds it.
    public static func takeLock(_ root: URL) throws -> Int32? {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(lockFile(root).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HostError(.failed, "cannot open \(lockFile(root).path): \(String(cString: strerror(errno)))") }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        return fd
    }

    public static func releaseLock(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }

    public static func writePort(_ root: URL, _ port: Int) {
        WebDeviceStore.ensureDirectory(directory(root))
        WebSessionStore.write(Data("\(port)\n".utf8), to: portFile(root))
    }

    /// Serve the socket for `server` on a background thread. `onStop` runs after `stop` is answered.
    @discardableResult
    public static func serve(_ root: URL, server: DozerWebServer, onStop: @escaping @Sendable () -> Void) throws -> Int32 {
        let lfd = try UnixSocket.listen(socket(root).path, backlog: 8)
        Thread.detachNewThread {
            while true {
                let c = accept(lfd, nil, nil)
                if c < 0 {
                    if errno == EINTR { continue }
                    return
                }
                _ = fcntl(c, F_SETFD, FD_CLOEXEC)
                answer(c, server: server, onStop: onStop)
                close(c)
            }
        }
        return lfd
    }

    private final class Box: @unchecked Sendable { var data: Data? }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e
    }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    private static func encoded<T: Encodable>(_ v: T) -> Data { (try? encoder.encode(v)) ?? Data("{}".utf8) }
    private static func failure(_ message: String) -> Data { encoded(["error": message]) }

    private static func answer(_ fd: Int32, server: DozerWebServer, onStop: @escaping @Sendable () -> Void) {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard let line = LineReader(fd: fd).readLine(limit: 512) else { return }
        let text = String(decoding: line, as: UTF8.self)
        let words = text.split(separator: " ", maxSplits: 2).map(String.init)
        guard let command = words.first else { return }
        if command == "stop" {
            _ = UnixSocket.writeAll(fd, Data("{\"stopping\":true}\n".utf8))
            onStop()
            return
        }
        guard let st = server.serveState else { return }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task {
            defer { done.signal() }
            do {
                switch command {
                case "status": box.data = encoded(try await server.serveStatus())
                case "devices": box.data = encoded(try await server.serveDevices(current: nil))
                case "share": box.data = encoded(await server.share(by: "the Mac").answer(origin: st.preferredOrigin, alsoAt: st.addressOrigins))
                case "probe": box.data = encoded(["token": st.issueProbe()])
                case "revoke" where words.count >= 2:
                    box.data = encoded(["revoked": try await server.revokeDevices(words[1] == "--all" ? nil : words[1], by: "the Mac")])
                case "rename" where words.count == 3:
                    box.data = encoded(try await server.renameDevice(words[1], to: words[2], by: "the Mac"))
                default: box.data = failure("unknown request")
                }
            } catch let r as WebRejection {
                box.data = failure(r == .notFound ? "no such device" : r.message)
            } catch let e as WebAction.Invalid {
                box.data = failure(e.message)
            } catch {
                box.data = failure("\(error)")
            }
        }
        done.wait()
        guard var d = box.data else { return }
        d.append(10)
        _ = UnixSocket.writeAll(fd, d)
    }

    // MARK: the client (the CLI, and doz ui's Devices page)

    /// One request; nil when no doz serve runs for this store.
    public static func ask(_ root: URL, _ line: String) -> Data? {
        guard let fd = UnixSocket.connect(socket(root).path) else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard UnixSocket.writeAll(fd, Data((line + "\n").utf8)), let answer = LineReader(fd: fd).readLine(limit: 4 << 20) else { return nil }
        return answer
    }

    /// The answer as `T`, or its error; nil when no doz serve runs.
    public static func request<T: Decodable>(_ root: URL, _ line: String, as: T.Type) -> Result<T, HostError>? {
        guard let d = ask(root, line) else { return nil }
        if let e = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let m = e["error"] as? String {
            return .failure(HostError(.failed, m))
        }
        guard let v = try? decoder.decode(T.self, from: d) else { return .failure(HostError(.failed, "doz serve gave an answer this doz does not read — is it another version?")) }
        return .success(v)
    }

    public struct Revoked: Codable, Sendable { public var revoked: [WebDeviceView] }
    public struct Probe: Codable, Sendable { public var token: String }

    /// The device list without a running doz serve (the file).
    public static func offlineDevices(_ root: URL) -> WebServeDevices {
        WebServeDevices(running: false, devices: WebDeviceStore.listFile(devicesFile(root)),
                        activity: WebServeAudit.recent(auditFile(root), limit: 50))
    }

    /// Revoke (or rename) in the file while no doz serve runs — holding serve.lock meanwhile, so a doz serve
    /// starting at that moment reads the file after the change. `id` nil = every device.
    public static func offlineRevoke(_ root: URL, id: String?, by: String) throws -> [WebDeviceView] {
        guard let fd = try takeLock(root) else { throw WebRejection.serveNotRunning }   // it started meanwhile: ask it instead
        defer { releaseLock(fd) }
        let gone = try WebDeviceStore.revokeInFile(devicesFile(root), id: id, by: by)
        for d in gone {
            WebServeAudit(file: auditFile(root)).record(WebAuditEntry(kind: "revoke", device: d.id, deviceName: d.name, outcome: "by \(by)"))
        }
        return gone
    }

    public static func offlineRename(_ root: URL, id: String, to name: String) throws -> WebDeviceView {
        guard let fd = try takeLock(root) else { throw WebRejection.serveNotRunning }
        defer { releaseLock(fd) }
        return try WebDeviceStore.renameInFile(devicesFile(root), id: id, to: name)
    }

    public static func cleanUp(_ root: URL, listenFD: Int32, lockFD: Int32) {
        unlink(socket(root).path)
        unlink(portFile(root).path)
        if listenFD >= 0 { close(listenFD) }
        releaseLock(lockFD)
    }
}
