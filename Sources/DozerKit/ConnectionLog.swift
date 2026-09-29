import Foundation

// Feature 580 Phase 3 — the audit log of a proxied sandbox: METADATA ONLY. Host, port, method and
// path (for requests the proxy reads — never the query string), the rule that decided, the
// verdict, bytes each way and timing. Never a body, a header value, a prompt or a credential.

/// One connection judged by a proxied sandbox's egress policy — metadata only, never a body,
/// header value, prompt or credential (580).
public struct ConnectionRecord: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        /// A DNS question the guest asked (answered on the Mac, or refused).
        case dns
        /// A tunnel through the HTTP proxy (`CONNECT host:port`).
        case connect
        /// One HTTP request the proxy read: plain HTTP, or inside a decrypted tunnel.
        case http
        /// Any other TCP connection, redirected to the proxy by the guest firewall.
        case tcp
    }
    public enum Verdict: String, Sendable, Codable {
        case allowed, denied, failed
    }

    public var id: UUID
    public var time: Date
    public var kind: Kind
    public var host: String
    public var port: UInt16?
    public var method: String?
    /// The request path WITHOUT its query string.
    public var path: String?
    public var verdict: Verdict
    public var rule: String
    /// The tunnel was decrypted (a credential binding or an HTTP rule needed it).
    public var decrypted: Bool
    /// What happened to a credential: `injected anthropic`, `swapped anthropic`, `rejected: …`.
    public var credential: String?
    public var bytesUp: Int
    public var bytesDown: Int
    /// Time to reach the upstream (connect; TLS for decrypted tunnels), ms.
    public var latencyMs: Double?
    /// Open → close, ms (nil while open).
    public var durationMs: Double?
    public var open: Bool
    public var detail: String?

    public init(kind: Kind, host: String, port: UInt16? = nil, method: String? = nil, path: String? = nil,
                verdict: Verdict, rule: String, decrypted: Bool = false, credential: String? = nil,
                bytesUp: Int = 0, bytesDown: Int = 0, latencyMs: Double? = nil, durationMs: Double? = nil,
                open: Bool = false, detail: String? = nil, id: UUID = UUID(), time: Date = Date()) {
        self.id = id
        self.time = time
        self.kind = kind
        self.host = host
        self.port = port
        self.method = method
        self.path = path
        self.verdict = verdict
        self.rule = rule
        self.decrypted = decrypted
        self.credential = credential
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
        self.latencyMs = latencyMs
        self.durationMs = durationMs
        self.open = open
        self.detail = detail
    }

    /// `host:port`, or the bare host for DNS.
    public var target: String { port.map { "\(host):\($0)" } ?? host }
}

/// A sandbox's connection log: the newest `capacity` records, updated in place while a
/// connection is open, and a live stream for a UI.
public final class ConnectionLog: @unchecked Sendable {
    public let capacity: Int
    private let lock = NSLock()
    private var order: [UUID] = []
    private var byID: [UUID: ConnectionRecord] = [:]
    private var subscribers: [UUID: AsyncStream<ConnectionRecord>.Continuation] = [:]
    private var _denied = 0
    private var _total = 0

    public init(capacity: Int = 5000) { self.capacity = capacity }

    /// Add a record, or replace the one with the same id (a connection that closed).
    public func upsert(_ r: ConnectionRecord) {
        lock.lock()
        if byID[r.id] == nil {
            order.append(r.id)
            _total += 1
            if r.verdict == .denied { _denied += 1 }
            if order.count > capacity { byID[order.removeFirst()] = nil }
        } else if byID[r.id]?.verdict != .denied, r.verdict == .denied {
            _denied += 1
        }
        byID[r.id] = r
        let subs = Array(subscribers.values)
        lock.unlock()
        for s in subs { s.yield(r) }
    }

    /// Every record kept, oldest first.
    public var records: [ConnectionRecord] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { byID[$0] }
    }

    public var deniedCount: Int { lock.lock(); defer { lock.unlock() }; return _denied }
    public var totalCount: Int { lock.lock(); defer { lock.unlock() }; return _total }

    public func clear() {
        lock.lock(); order = []; byID = [:]; _denied = 0; _total = 0; lock.unlock()
    }

    /// Each record as it is added or updated, from now on.
    public func stream() -> AsyncStream<ConnectionRecord> {
        let id = UUID()
        let (s, c) = AsyncStream.makeStream(of: ConnectionRecord.self, bufferingPolicy: .bufferingNewest(1000))
        lock.lock(); subscribers[id] = c; lock.unlock()
        c.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.subscribers[id] = nil; self.lock.unlock()
        }
        return s
    }

    /// The log as JSON lines (one record per line, ISO-8601 times) — usable as test fixtures.
    public func exportJSONLines() -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        var out = Data()
        for r in records {
            if let d = try? enc.encode(r) { out.append(d); out.append(10) }
        }
        return out
    }

    /// Parse what `exportJSONLines` wrote.
    public static func parseJSONLines(_ data: Data) -> [ConnectionRecord] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return data.split(separator: 10).compactMap { try? dec.decode(ConnectionRecord.self, from: Data($0)) }
    }
}
