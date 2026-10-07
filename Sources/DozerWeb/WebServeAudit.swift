import Darwin
import Foundation

// 606 — the audit log of `doz serve` (owner ruling: "the audit log of remote actions kept"):
// `<store>/serve/audit.jsonl`, 0600, one JSON object a line, rotated at 1 MiB (audit.jsonl.1, .2 kept).
// What a remote browser did — admissions, invites, revokes, every change it asked for (route, action, sandbox,
// outcome), terminals opened and closed, refusals, connections dropped — and NEVER a body, a cookie, a token,
// a code, a header value or terminal content. Noisy kinds (dropped connections, refusals) are collapsed: one
// line per kind and address a minute, with how many it stands for.

public struct WebAuditEntry: Codable, Equatable, Sendable {
    public var time: Date
    /// admit · admit-refused · share · revoke · rename · sign-out · change · terminal-open · terminal-close ·
    /// refused · dropped · start · stop
    public var kind: String
    public var device: String?
    public var deviceName: String?
    public var address: String?
    public var route: String?
    public var action: String?
    public var sandbox: String?
    /// ok, or the refusal's code / the HTTP status.
    public var outcome: String?
    /// How many events this line stands for (collapsed kinds), when more than one.
    public var count: Int?

    public init(time: Date = Date(), kind: String, device: String? = nil, deviceName: String? = nil, address: String? = nil,
                route: String? = nil, action: String? = nil, sandbox: String? = nil, outcome: String? = nil, count: Int? = nil) {
        self.time = time; self.kind = kind; self.device = device; self.deviceName = deviceName; self.address = address
        self.route = route; self.action = action; self.sandbox = sandbox; self.outcome = outcome; self.count = count
    }
}

public final class WebServeAudit: @unchecked Sendable {
    public static let maximumBytes = 1 << 20
    public static let kept = 3
    static let collapsed: Set<String> = ["dropped", "refused", "admit-refused"]
    static let collapseWindow: TimeInterval = 60

    public let file: URL?
    private let lock = NSLock()
    private var last: [String: (at: Date, suppressed: Int)] = [:]
    private let now: @Sendable () -> Date

    public init(file: URL?, now: @escaping @Sendable () -> Date = Date.init) {
        self.file = file
        self.now = now
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e
    }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public func record(_ e: WebAuditEntry) {
        var e = e
        e.time = now()
        lock.withLock {
            if Self.collapsed.contains(e.kind) {
                let key = [e.kind, e.address ?? "", e.outcome ?? "", e.route ?? ""].joined(separator: "|")
                if let l = last[key], e.time.timeIntervalSince(l.at) < Self.collapseWindow {
                    last[key] = (l.at, l.suppressed + 1)
                    return
                }
                let before = last[key]?.suppressed ?? 0
                last[key] = (e.time, 0)
                if before > 0 { e.count = before + 1 }
                if last.count > 512 { last = last.filter { e.time.timeIntervalSince($0.value.at) < Self.collapseWindow } }
            }
            append(e)
        }
    }

    private func append(_ e: WebAuditEntry) {
        guard let file, var line = try? Self.encoder.encode(e) else { return }
        line.append(10)
        WebDeviceStore.ensureDirectory(file.deletingLastPathComponent())
        var st = stat()
        if stat(file.path, &st) == 0, Int(st.st_size) + line.count > Self.maximumBytes { rotate(file) }
        let fd = open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
        close(fd)
    }

    private func rotate(_ file: URL) {
        for i in stride(from: Self.kept - 1, through: 1, by: -1) {
            let from = i == 1 ? file.path : file.path + ".\(i - 1)"
            rename(from, file.path + ".\(i)")
        }
    }

    /// The newest `limit` entries (this file, then the rotated ones), newest first.
    public static func recent(_ file: URL, limit: Int = 50) -> [WebAuditEntry] {
        var out: [WebAuditEntry] = []
        for path in [file.path] + (1..<kept).map({ file.path + ".\($0)" }) {
            guard out.count < limit, let d = FileManager.default.contents(atPath: path) else { continue }
            let lines = d.split(separator: 10).reversed()
            for l in lines {
                if let e = try? decoder.decode(WebAuditEntry.self, from: Data(l)) { out.append(e) }
                if out.count >= limit { break }
            }
        }
        return out
    }
}
