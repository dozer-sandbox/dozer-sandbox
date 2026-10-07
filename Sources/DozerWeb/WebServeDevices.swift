import CryptoKit
import Darwin
import Foundation

// 606 — `doz serve`'s browsers ("devices"): admitted ONCE by an invite, kept until REVOKED (owner ruling).
//
// An INVITE is what "share / add another browser" makes — `doz serve` at start, `doz serve share`, any admitted
// browser's Add another browser, the Mac's dashboard: a 256-bit link token (carried in a URL FRAGMENT, `#cap=`,
// and posted as `Authorization: Bearer` — the `doz ui` link model), an 8-character access code (40 bits,
// Crockford base32) and the QR code of the link. Whichever is used first admits ONE device and ends the
// invite; it lives 5 minutes, in memory only.
//
// A DEVICE is kept in `<store>/serve/devices.json` (0600, in a 0700 directory): its cookie's SHA-256 — never
// the cookie (reading the file signs nobody in, `WebSessionStore`'s reasoning) — its CSRF token, its name,
// when it was admitted and last seen, from where, with which browser, and by whom. A revoked device's digest
// is kept 30 days with who revoked it, so its page says why it was signed out.

/// One admitted browser, as the device list shows it (no cookie, no CSRF token).
public struct WebDeviceView: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var created: Date
    public var lastSeen: Date
    public var lastAddress: String
    public var userAgent: String
    /// Who made the invite it came in by ("the Mac", or another device's name).
    public var admittedBy: String
    /// link | code
    public var admittedVia: String
    /// The browser asking (only in a browser's answer).
    public var current: Bool?
}

/// A fresh invite, for the one who asked (the CLI over `serve.sock`, a browser's Add another browser). The link
/// token is a bearer key for one admission: its description and mirror are redacted.
public struct WebServeInvite: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let id: String
    let token: String
    public let code: String
    public let expiresAt: Date
    public var description: String { "WebServeInvite(\(id), redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["id": id], displayStyle: .struct) }

    /// The link for one browser: `<origin>/#cap=<token>`.
    public func link(origin: String) -> String { origin + "/#cap=" + token }

    /// For tests.
    public var testToken: String { token }

    /// What a browser (and the CLI over the socket) receives: the link, the code, the expiry, the QR matrix of the link.
    /// `alsoAt`: the same invite at other origins of this doz serve (its LAN addresses — `.local` does not resolve
    /// the same everywhere: IPv6 link-local on another Mac, ::1 on this one).
    public func answer(origin: String, alsoAt: [String] = []) -> WebServeInviteAnswer {
        let link = link(origin: origin)
        let qr = try? WebQR.encode(link)
        let alt = alsoAt.filter { $0 != origin }.map { self.link(origin: $0) }
        return WebServeInviteAnswer(link: link, code: code, expiresAt: expiresAt, qr: qr.map { WebServeInviteAnswer.QR(size: $0.size, rows: $0.rows) },
                                    alternates: alt.isEmpty ? nil : alt)
    }
}

/// An invite as it is handed over (a browser's Add another browser, `doz serve share`).
public struct WebServeInviteAnswer: Codable, Equatable, Sendable, CustomStringConvertible {
    public struct QR: Codable, Equatable, Sendable { public var size: Int; public var rows: [String] }
    public var link: String
    public var code: String
    public var expiresAt: Date
    public var qr: QR?
    /// The same link at doz serve's LAN addresses (the CLI prints them beside the `.local` one).
    public var alternates: [String]? = nil
    public var description: String { "WebServeInviteAnswer(redacted)" }
}

/// Wrong admission attempts (pure; time injected): per address, and wrong CODES in all.
struct WebAttemptLimiter: Sendable {
    static let perAddress = 10, codesInAll = 20
    static let window: TimeInterval = 10 * 60
    private var byAddress: [String: [Date]] = [:]
    private var codes: [Date] = []

    mutating func prune(_ now: Date) {
        byAddress = byAddress.compactMapValues { d in let k = d.filter { now.timeIntervalSince($0) < Self.window }; return k.isEmpty ? nil : k }
        codes = codes.filter { now.timeIntervalSince($0) < Self.window }
    }

    /// This address may not try again yet.
    mutating func blocked(_ address: String, now: Date) -> Bool {
        prune(now)
        return (byAddress[address]?.count ?? 0) >= Self.perAddress
    }

    /// Count a wrong attempt. Returns true when wrong CODES in all reached the limit (every open code is then
    /// cancelled; the links stay — they are 256 bits).
    mutating func failed(_ address: String, code: Bool, now: Date) -> Bool {
        prune(now)
        byAddress[address, default: []].append(now)
        guard code else { return false }
        codes.append(now)
        if codes.count >= Self.codesInAll { codes = []; return true }
        return false
    }
}

public actor WebDeviceStore {
    struct Device: Codable, Equatable {
        var id: String
        var name: String
        var cookieSHA256: String
        var csrf: String
        var created: Date
        var lastSeen: Date
        var lastAddress: String
        var userAgent: String
        var admittedBy: String
        var admittedVia: String
        var view: WebDeviceView {
            WebDeviceView(id: id, name: name, created: created, lastSeen: lastSeen, lastAddress: lastAddress, userAgent: userAgent,
                          admittedBy: admittedBy, admittedVia: admittedVia, current: nil)
        }
    }
    struct Revoked: Codable, Equatable { var id: String; var name: String; var at: Date; var by: String }
    struct File: Codable { var devices: [Device]; var revoked: [String: Revoked] }
    struct Invite { var id: String; var token: String; var code: String?; var expiresAt: Date; var by: String }

    public static let inviteLifetime: TimeInterval = 5 * 60
    public static let maximumInvites = 8
    public static let maximumDevices = 64
    static let revokedKept: TimeInterval = 30 * 24 * 60 * 60
    /// What the page is told a device's cookie lasts (renewed at each page load and at half-life — the cookie is
    /// re-set each time): the DEVICE itself never expires.
    static let reportedLifetime: TimeInterval = 14 * 24 * 60 * 60
    /// The cookie's own Max-Age (browsers cap it at 400 days); every renewal sets it again.
    public static let cookieMaxAge: TimeInterval = 400 * 24 * 60 * 60
    /// Code alphabet: Crockford base32 (no I, L, O, U).
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    private let file: URL?
    private let now: @Sendable () -> Date
    private var devices: [Device] = []
    private var byDigest: [String: Int] = [:]
    private var revoked: [String: Revoked] = [:]
    private var invites: [Invite] = []
    /// Used link tokens and codes until their invite would have expired (so a second use says "used").
    private var spent: [(token: String, code: String?, until: Date)] = []
    private var limiter = WebAttemptLimiter()
    private var dirty = false
    private var lastSave = Date.distantPast

    public init(file: URL?, now: @escaping @Sendable () -> Date = Date.init) {
        self.file = file
        self.now = now
        if let file, let f = Self.read(file) {
            devices = f.devices
            let t = now()
            revoked = f.revoked.filter { t.timeIntervalSince($0.value.at) < Self.revokedKept }
        }
        for (i, d) in devices.enumerated() { byDigest[d.cookieSHA256] = i }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    static func read(_ url: URL) -> File? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(File.self, from: d)
    }

    static func digest(_ cookie: String) -> String { WebSessionStore.digest(cookie) }

    private func reindex() {
        byDigest = [:]
        for (i, d) in devices.enumerated() { byDigest[d.cookieSHA256] = i }
    }

    /// Write the file now (0600, atomically; its directory 0700).
    private func save() {
        dirty = false
        lastSave = now()
        guard let file else { return }
        Self.ensureDirectory(file.deletingLastPathComponent())
        WebSessionStore.write(try? Self.encoder.encode(File(devices: devices, revoked: revoked)), to: file)
    }

    static func ensureDirectory(_ dir: URL) {
        mkdir(dir.path, 0o700)
        chmod(dir.path, 0o700)
    }

    /// Write what `touch` changed (at most once a minute, and at the end).
    public func flush() { if dirty { save() } }

    // MARK: invites

    private func prune() {
        let t = now()
        invites.removeAll { $0.expiresAt <= t }
        spent.removeAll { $0.until <= t }
        revoked = revoked.filter { t.timeIntervalSince($0.value.at) < Self.revokedKept }
    }

    static func randomCode() -> String {
        var g = SystemRandomNumberGenerator()
        return String((0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &g)] })
    }

    /// `ABCD-EFGH` as a person reads it.
    public static func display(_ code: String) -> String { String(code.prefix(4)) + "-" + String(code.dropFirst(4)) }

    /// What a person typed → the code (upper case, no separators; O → 0, I and L → 1), or nil.
    public static func normalize(_ typed: String) -> String? {
        var out = ""
        for ch in typed.uppercased() {
            if ch == "-" || ch == " " { continue }
            let c: Character = ch == "O" ? "0" : (ch == "I" || ch == "L") ? "1" : ch
            guard alphabet.contains(c) else { return nil }
            out.append(c)
        }
        return out.count == 8 ? out : nil
    }

    /// A new invite (the oldest open one goes when there are already `maximumInvites`).
    public func share(by: String) -> WebServeInvite {
        prune()
        while invites.count >= Self.maximumInvites { invites.removeFirst() }
        let inv = Invite(id: String(WebRandom.token().prefix(8)), token: WebRandom.token(), code: Self.randomCode(),
                         expiresAt: now().addingTimeInterval(Self.inviteLifetime), by: by)
        invites.append(inv)
        return WebServeInvite(id: inv.id, token: inv.token, code: Self.display(inv.code!), expiresAt: inv.expiresAt)
    }

    public var openInvites: Int { prune(); return invites.count }

    // MARK: admission

    /// Admit a browser by a link token or a code (exactly one). Throws a rejection that never echoes a value.
    public func admit(token: String?, code: String?, userAgent: String?, address: String) throws -> (WebSession, WebDeviceView) {
        prune()
        if limiter.blocked(address, now: now()) { throw WebRejection.tooManyAttempts }
        var index: Int?
        if let token {
            index = invites.firstIndex { constantTimeEqual(token, $0.token) }
            if index == nil {
                _ = limiter.failed(address, code: false, now: now())
                if spent.contains(where: { constantTimeEqual(token, $0.token) }) { throw WebRejection.admissionUsed }
                throw WebRejection.admissionRejected
            }
        } else if let typed = code {
            guard let c = Self.normalize(typed) else {
                if limiter.failed(address, code: true, now: now()) { cancelCodes() }
                throw WebRejection.admissionRejected
            }
            index = invites.firstIndex { $0.code.map { constantTimeEqual(c, $0) } ?? false }
            if index == nil {
                if limiter.failed(address, code: true, now: now()) { cancelCodes() }
                if spent.contains(where: { $0.code.map { constantTimeEqual(c, $0) } ?? false }) { throw WebRejection.admissionUsed }
                throw WebRejection.admissionRejected
            }
        } else {
            throw WebRejection.malformedAuthorization
        }
        let inv = invites.remove(at: index!)
        spent.append((inv.token, inv.code, inv.expiresAt))
        guard devices.count < Self.maximumDevices else { throw WebRejection.tooManyDevices }
        let t = now()
        let ua = Self.clean(userAgent ?? "", max: 200)
        let cookie = WebRandom.token()
        let d = Device(id: Self.newID(taken: Set(devices.map(\.id))), name: uniqueName(Self.family(ua)), cookieSHA256: Self.digest(cookie),
                       csrf: WebRandom.token(), created: t, lastSeen: t, lastAddress: address, userAgent: ua,
                       admittedBy: inv.by, admittedVia: token != nil ? "link" : "code")
        devices.append(d)
        reindex()
        save()
        return (WebSession(cookieValue: cookie, csrfToken: d.csrf, expiresAt: t.addingTimeInterval(Self.reportedLifetime)), d.view)
    }

    private func cancelCodes() {
        for i in invites.indices { invites[i].code = nil }
    }

    static func newID(taken: Set<String>) -> String {
        while true {
            let id = String(WebRandom.token().lowercased().filter { $0.isLetter || $0.isNumber }.prefix(6))
            if id.count == 6, !taken.contains(id) { return id }
        }
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(devices.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Printable text only (no control characters), at most `max` characters.
    static func clean(_ s: String, max: Int) -> String {
        String(String(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && !(0x80...0x9F).contains($0.value) }).prefix(max))
    }

    /// "Chrome on macOS" from a User-Agent (a name to start with — the device list can rename it).
    static func family(_ ua: String) -> String {
        let os: String = ua.contains("iPhone") ? "iPhone" : ua.contains("iPad") ? "iPad" : ua.contains("Android") ? "Android"
            : ua.contains("Mac OS X") || ua.contains("Macintosh") ? "macOS" : ua.contains("Windows") ? "Windows"
            : ua.contains("CrOS") ? "ChromeOS" : ua.contains("Linux") ? "Linux" : ""
        let browser: String = ua.contains("Edg/") ? "Edge" : ua.contains("Firefox/") || ua.contains("FxiOS") ? "Firefox"
            : ua.contains("HeadlessChrome") ? "Headless Chrome" : ua.contains("Chrome/") || ua.contains("CriOS") ? "Chrome"
            : ua.contains("Safari/") ? "Safari" : ua.hasPrefix("curl/") ? "curl" : "A browser"
        return os.isEmpty ? browser : "\(browser) on \(os)"
    }

    // MARK: the cookie

    /// The device a cookie belongs to; a revoked one says so.
    public func authenticate(_ cookie: String) throws -> (WebSession, WebDeviceView) {
        let key = Self.digest(cookie)
        guard let i = byDigest[key] else {
            if revoked[key] != nil { throw WebRejection.deviceRevoked }
            throw WebRejection.notAdmitted
        }
        let d = devices[i]
        return (WebSession(cookieValue: cookie, csrfToken: d.csrf, expiresAt: now().addingTimeInterval(Self.reportedLifetime)), d.view)
    }

    public func authenticateMutation(_ cookie: String, csrf: String?) throws -> (WebSession, WebDeviceView) {
        let r = try authenticate(cookie)
        guard let csrf, constantTimeEqual(csrf, r.0.csrfToken) else { throw WebRejection.csrfRejected }
        return r
    }

    public func isValid(_ cookie: String) -> Bool { byDigest[Self.digest(cookie)] != nil }

    /// Seen now, from `address`, with `userAgent` — written at most once a minute.
    public func touch(_ cookie: String, address: String, userAgent: String?) {
        guard let i = byDigest[Self.digest(cookie)] else { return }
        devices[i].lastSeen = now()
        devices[i].lastAddress = address
        if let ua = userAgent { devices[i].userAgent = Self.clean(ua, max: 200) }
        dirty = true
        if now().timeIntervalSince(lastSave) > 60 { save() }
    }

    // MARK: the list

    public func list(current cookie: String? = nil) -> [WebDeviceView] {
        let mine = cookie.map(Self.digest)
        return devices.map { d in var v = d.view; if mine != nil { v.current = d.cookieSHA256 == mine }; return v }
    }

    /// Revoke one device (by id): its cookie is refused from now on. Returns its cookie digest (to end its
    /// streams and terminals) and the device.
    public func revoke(id: String, by: String) throws -> (digest: String, device: WebDeviceView) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { throw WebRejection.notFound }
        let d = devices.remove(at: i)
        revoked[d.cookieSHA256] = Revoked(id: d.id, name: d.name, at: now(), by: by)
        reindex()
        save()
        return (d.cookieSHA256, d.view)
    }

    /// Every device (`doz serve revoke --all`).
    public func revokeAll(by: String) -> [String] {
        let t = now()
        for d in devices { revoked[d.cookieSHA256] = Revoked(id: d.id, name: d.name, at: t, by: by) }
        let digests = devices.map(\.cookieSHA256)
        devices = []
        reindex()
        save()
        return digests
    }

    /// The device's own sign-out: it is forgotten (a new invite brings it back).
    public func signOut(_ cookie: String) {
        let key = Self.digest(cookie)
        guard let i = byDigest[key] else { return }
        let d = devices.remove(at: i)
        revoked[key] = Revoked(id: d.id, name: d.name, at: now(), by: "itself (signed out)")
        reindex()
        save()
    }

    public func rename(id: String, to name: String) throws -> WebDeviceView {
        let n = Self.clean(name.trimmingCharacters(in: .whitespaces), max: 60)
        guard !n.isEmpty else { throw WebAction.Invalid("a device's name is 1–60 printable characters") }
        guard let i = devices.firstIndex(where: { $0.id == id }) else { throw WebRejection.notFound }
        devices[i].name = n
        save()
        return devices[i].view
    }

    /// Who a revoked cookie was, and by whom (for the 401's message), if it is known.
    public func revocation(_ cookie: String) -> (name: String, by: String)? {
        revoked[Self.digest(cookie)].map { ($0.name, $0.by) }
    }

    // MARK: without a running doz serve (the CLI, the Mac's dashboard)

    /// The devices in the file (no `doz serve` running).
    public static func listFile(_ url: URL) -> [WebDeviceView] { (read(url)?.devices ?? []).map(\.view) }

    /// Revoke in the file (no `doz serve` running — the caller holds `serve.lock`). Returns what was revoked.
    public static func revokeInFile(_ url: URL, id: String?, by: String, now: Date = Date()) throws -> [WebDeviceView] {
        guard var f = read(url) else { if id == nil { return [] }; throw WebRejection.notFound }
        let gone = f.devices.filter { id == nil || $0.id == id }
        guard !gone.isEmpty || id == nil else { throw WebRejection.notFound }
        for d in gone { f.revoked[d.cookieSHA256] = Revoked(id: d.id, name: d.name, at: now, by: by) }
        f.devices.removeAll { id == nil || $0.id == id }
        ensureDirectory(url.deletingLastPathComponent())
        WebSessionStore.write(try? encoder.encode(f), to: url)
        return gone.map(\.view)
    }

    public static func renameInFile(_ url: URL, id: String, to name: String) throws -> WebDeviceView {
        guard var f = read(url), let i = f.devices.firstIndex(where: { $0.id == id }) else { throw WebRejection.notFound }
        let n = clean(name.trimmingCharacters(in: .whitespaces), max: 60)
        guard !n.isEmpty else { throw WebAction.Invalid("a device's name is 1–60 printable characters") }
        f.devices[i].name = n
        WebSessionStore.write(try? encoder.encode(f), to: url)
        return f.devices[i].view
    }
}
