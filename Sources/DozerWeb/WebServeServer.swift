import Foundation
import DozerHost

// 606 — the server's doz serve side: admission, the devices, invites. On doz ui (the Mac's own dashboard) the
// device routes are answered by the running doz serve over serve.sock — or, when none runs, from its files.

extension DozerWebServer {
    var storeRoot: URL { URL(fileURLWithPath: data.storePath) }

    /// `POST /api/v1/session` on doz serve: a link token (`Authorization: Bearer`) or a typed code (`{"code"}`).
    func admit(_ md: WebRequestMetadata, body: Data, ctx: WebRequestContext, serve st: WebServeState,
               device: inout WebDeviceView?) async throws -> Reply {
        guard md.method == .post else { throw WebRejection.methodNotAllowed }
        try WebSecurity.checkListener(md, ctx.view, originRequired: true)
        try WebSecurity.checkBody(md, limit: limits.maximumRequestBodyBytes)
        var token: String?, code: String?
        if let a = md.authorization {
            guard a.hasPrefix("Bearer "), WebRandom.isToken(String(a.dropFirst(7))) else { throw WebRejection.malformedAuthorization }
            token = String(a.dropFirst(7))
        } else {
            guard md.bodyByteCount > 0, let d = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], Set(d.keys) == ["code"],
                  let c = d["code"] as? String, (1...32).contains(c.count) else { throw WebRejection.malformedAuthorization }
            code = c
        }
        do {
            let (s, dev) = try await st.devices.admit(token: token, code: code, userAgent: ctx.userAgent, address: ctx.client)
            device = dev
            st.audit.record(WebAuditEntry(kind: "admit", device: dev.id, deviceName: dev.name, address: ctx.client,
                                          outcome: "by \(dev.admittedBy), with a \(dev.admittedVia)"))
            hub.broadcast("devices", ["changed": true])
            return json(sessionInfo(s, ctx, dev), extra: [sessionCookieHeader(s, ctx)])
        } catch let r as WebRejection {
            st.audit.record(WebAuditEntry(kind: "admit-refused", address: ctx.client, outcome: r.rawValue))
            throw r
        }
    }

    // MARK: the routes (doz serve answers itself; doz ui asks the running doz serve, else reads its files)

    public func serveStatus() async throws -> WebServeStatus {
        if let st = serveState {
            var s = WebServeStatus(state: "running", origins: st.origins, publicOrigins: st.config.publicOrigins.map(\.description),
                                   port: st.port, bind: Self.describe(st.config.bind), devices: await st.devices.list().count,
                                   openInvites: await st.devices.openInvites, advertised: advertised)
            s.pid = Int(getpid()); s.since = st.startedAt; s.version = version; s.detached = st.detached
            s.log = st.logPath; s.responsibleApp = st.responsibleApp
            return s
        }
        if let r = WebServeControl.request(storeRoot, "status", as: WebServeStatus.self) { return try r.get() }
        return WebServeStatus(state: "stopped", origins: [], publicOrigins: [], port: nil, bind: nil,
                              devices: WebDeviceStore.listFile(WebServeControl.devicesFile(storeRoot)).count, openInvites: nil, advertised: nil)
    }

    public func serveDevices(current cookie: String?) async throws -> WebServeDevices {
        if let st = serveState {
            return WebServeDevices(running: true, devices: await st.devices.list(current: cookie),
                                   activity: WebServeAudit.recent(st.audit.file ?? WebServeControl.auditFile(storeRoot), limit: 50))
        }
        if let r = WebServeControl.request(storeRoot, "devices", as: WebServeDevices.self) { return try r.get() }
        return WebServeControl.offlineDevices(storeRoot)
    }

    /// A new invite; its link is made for `origin` (the asking browser's own) or doz serve's preferred one.
    func serveShare(by: String, origin: String?, ctx: WebRequestContext, device: WebDeviceView?) async throws -> WebServeInviteAnswer {
        if let st = serveState {
            let inv = await share(by: by, address: ctx.client, device: device)
            return inv.answer(origin: origin ?? st.preferredOrigin)
        }
        guard let r = WebServeControl.request(storeRoot, "share", as: WebServeInviteAnswer.self) else { throw WebRejection.serveNotRunning }
        return try r.get()
    }

    /// An invite (doz serve only) — for the CLI's `share` and a browser's Add another browser.
    public func share(by: String, address: String? = nil, device: WebDeviceView? = nil) async -> WebServeInvite {
        guard let st = serveState else { fatalError("share is doz serve's") }
        let inv = await st.devices.share(by: by)
        st.audit.record(WebAuditEntry(kind: "share", device: device?.id, deviceName: device?.name ?? by, address: address))
        return inv
    }

    func serveRevoke(_ id: String, by: String, ctx: WebRequestContext, asker: WebDeviceView?) async throws -> WebServeControl.Revoked {
        if serveState != nil { return WebServeControl.Revoked(revoked: try await revokeDevices(id, by: by, address: ctx.client, asker: asker)) }
        if let r = WebServeControl.request(storeRoot, "revoke \(id)", as: WebServeControl.Revoked.self) { return try r.get() }
        return WebServeControl.Revoked(revoked: try WebServeControl.offlineRevoke(storeRoot, id: id, by: by))
    }

    func serveRename(_ id: String, to name: String, ctx: WebRequestContext, asker: WebDeviceView?) async throws -> WebDeviceView {
        if serveState != nil { return try await renameDevice(id, to: name, by: askerName(asker), address: ctx.client) }
        let clean = WebDeviceStore.clean(name, max: 60).replacingOccurrences(of: "\n", with: " ")
        if let r = WebServeControl.request(storeRoot, "rename \(id) \(clean)", as: WebDeviceView.self) { return try r.get() }
        return try WebServeControl.offlineRename(storeRoot, id: id, to: name)
    }

    private func askerName(_ d: WebDeviceView?) -> String { d?.name ?? "the Mac" }

    /// Revoke one device (or all — `id` nil): its cookie is refused at once, its event streams end, its terminals
    /// close. Returns what was revoked.
    public func revokeDevices(_ id: String?, by: String, address: String? = nil, asker: WebDeviceView? = nil) async throws -> [WebDeviceView] {
        guard let st = serveState else { throw WebRejection.notFound }
        let before = await st.devices.list()
        var digests: [String] = []
        if let id {
            digests = [try await st.devices.revoke(id: id, by: by).digest]
        } else {
            digests = await st.devices.revokeAll(by: by)
        }
        let gone = Set(digests)
        for c in hub.all where gone.contains(WebDeviceStore.digest(c.cookie)) { c.finish(.revoked) }
        for b in terminals.all where gone.contains(WebDeviceStore.digest(b.grant.cookie)) { await b.end(.policyViolation, "session-ended") }
        let revoked = before.filter { d in id == nil || d.id == id }
        for d in revoked {
            st.audit.record(WebAuditEntry(kind: "revoke", device: d.id, deviceName: d.name, address: address, outcome: "by \(by)"))
        }
        hub.broadcast("devices", ["changed": true])
        return revoked
    }

    public func renameDevice(_ id: String, to name: String, by: String, address: String? = nil) async throws -> WebDeviceView {
        guard let st = serveState else { throw WebRejection.notFound }
        let d = try await st.devices.rename(id: id, to: name)
        st.audit.record(WebAuditEntry(kind: "rename", device: d.id, deviceName: d.name, address: address, outcome: "by \(by)"))
        hub.broadcast("devices", ["changed": true])
        return d
    }

    static func describe(_ b: WebServeBind) -> String {
        switch b {
        case .lan: "lan"
        case .loopback: "loopback"
        case .addresses(let ips): ips.map(\.description).joined(separator: ", ")
        }
    }
}
