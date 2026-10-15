import Foundation
import DozerKit

// 617: `copy` — the host's half of doz get / put / cp (FileCopy.swift has the model). The sandbox is woken or started
// exactly as `doz exec` does (the same flags: a copy is doing something in it, and exec's rule is the one people
// already know); the guest is checked BEFORE a byte moves; then a tar runs on the guest stream.

extension HostCore {
    /// Check, then open the guest's tar. The caller relays the stream (HostServer) and ends it with `CopyDone`.
    func copyOpen(_ r: HostRequest, emit: @escaping @Sendable (HostEvent) -> Void) async throws -> (CopyReady, GuestStream) {
        guard let c = r.fileCopy else { throw HostError(.invalid, "copy: what to copy (doz get / doz put)") }
        guard let path = CopyPaths.guestPath(c.path) else { throw HostError(.invalid, "not a path in a sandbox: \(c.path.debugDescription)") }
        let m = try get(r.name)
        let first = try await ensureRunning(m, wake: r.wake ?? true, start: r.start ?? false, emit: emit)
        let sb = m.sandbox
        let imageUser = m.config.spec.imageSpec?.user
        var ready: CopyReady
        let stream: GuestStream
        switch c.direction {
        case .get:
            let res = try await sb.exec(["sh", "-c", CopyPaths.getCheckScript(path)], timeoutSeconds: 60)
            switch CopyPaths.parseGet(res.output) {
            case .missing: throw HostError(.notFound, "no such file or folder in \(m.name): \(path)")
            case .dangling: throw HostError(.notFound, "\(path) in \(m.name) is a link to something that is not there")
            case .special: throw HostError(.failed, "\(path) in \(m.name) is not a file or a folder (a device, socket or pipe) — not copied")
            case .root: throw HostError(.invalid, "not the whole of \(m.name) (/) — name a folder")
            case .escapes(let links):
                throw HostError(.failed, "\(path) holds links that point outside it — not copied (\(links.joined(separator: "; ")))")
            case .unreadable(let out):
                throw HostError(.failed, "could not look at \(path) in \(m.name): " + (CopyPaths.tarError(out + res.errorOutput) ?? "no answer"))
            case .ok(let kind, let kib, let files, let resolved):
                ready = CopyReady(kind: kind, path: resolved, bytes: kib * 1024, files: files)
                stream = try await sb.openGuestStream(CopyPaths.getTar(resolved))
            }
        case .put:
            guard let name = c.name, CopyPaths.isItemName(name), let kind = c.kind else {
                throw HostError(.invalid, "put: the item's name and kind")
            }
            let res = try await sb.exec(["sh", "-c", CopyPaths.putCheckScript(dest: path, name: name)], user: imageUser, timeoutSeconds: 60)
            switch CopyPaths.parsePut(res.output) {
            case .noParent(let p): throw HostError(.notFound, "no such folder in \(m.name): \(p)")
            case .unreadable(let out):
                throw HostError(.failed, "could not look at \(path) in \(m.name): " + (CopyPaths.tarError(out + res.errorOutput) ?? "no answer"))
            case .ok(let writable, let existing, let target):
                let tname = (target as NSString).lastPathComponent
                guard CopyPaths.isItemName(tname) else { throw HostError(.invalid, "not a name for the copy: \(target)") }
                if let e = existing {
                    if c.force != true {
                        throw HostError(.exists, "\(target) is there already in \(m.name) (a \(e.rawValue)) — --force replaces it")
                    }
                    if e != kind {
                        throw HostError(.exists, "\(target) in \(m.name) is a \(e.rawValue) and this is a \(kind.rawValue) — not replaced")
                    }
                }
                let user = writable ? (imageUser ?? "root") : "root"
                ready = CopyReady(kind: kind, path: target, runAs: user,
                                  rootReason: writable || imageUser == nil || imageUser == "root"
                                      ? nil : "\((target as NSString).deletingLastPathComponent) is not writable by \(imageUser!)",
                                  replaces: existing)
                stream = try await sb.openGuestStream(CopyPaths.putTar(target), user: user)
            }
        }
        if first.started { ready.started = true }
        if first.woke { ready.woke = true }
        return (ready, stream)
    }

    /// The end of a copy: tar's verdict (GNU tar's 1 = a file changed while it was read — a warning, not a failure).
    static func copyDone(_ s: GuestStream, bytes: Int64, since t0: ContinuousClock.Instant, direction: CopyRequest.Direction) -> CopyDone {
        let ms = Double((ContinuousClock.now - t0).components.attoseconds) / 1e15 + Double((ContinuousClock.now - t0).components.seconds) * 1000
        let why = CopyPaths.tarError(s.errorOutput)
        switch s.exitCode {
        case 0?: return CopyDone(ok: true, bytes: bytes, milliseconds: ms)
        case 1? where direction == .get: return CopyDone(ok: true, bytes: bytes, milliseconds: ms, warning: why ?? "a file changed while it was copied")
        case let code?: return CopyDone(ok: false, error: why ?? "the sandbox's tar ended with \(code)", bytes: bytes, milliseconds: ms)
        case nil: return CopyDone(ok: false, error: "the sandbox stopped during the copy", bytes: bytes, milliseconds: ms)
        }
    }
}
