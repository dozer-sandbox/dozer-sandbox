import Foundation

// Feature 580 Phase 2 — credentials that never enter the sandbox.
//
// A binding says: this secret is for requests to THIS host, in THIS header. The guest gets only a
// placeholder (`snz_cred_…`, the right shape for an SDK that insists on a key, and no power
// anywhere); the host proxy decrypts TLS for bound hosts only, and on each request:
//   - a header carrying a placeholder minted for this host   → the real secret is swapped in;
//   - no auth header at all                                   → the secret is injected (Omnigent's
//                                                               default "swap-on-access" mode);
//   - a placeholder minted for ANOTHER host, or unknown       → 403 and a log entry (leak guard);
//   - a real-looking credential the tool supplied itself      → passed through untouched.
// The secret lives only in the host process (never written to disk, never in the guest).

/// Where a secret goes on the wire.
public enum CredentialHeader: Sendable, Codable, Equatable {
    /// `x-api-key: <secret>` (Anthropic).
    case apiKey(name: String)
    /// `Authorization: Bearer <secret>`.
    case bearer

    public static let xAPIKey = CredentialHeader.apiKey(name: "x-api-key")

    public var headerName: String {
        switch self {
        case .apiKey(let name): name.lowercased()
        case .bearer: "authorization"
        }
    }

    /// The header value for `secret`.
    public func value(_ secret: String) -> String {
        switch self {
        case .apiKey: secret
        case .bearer: "Bearer \(secret)"
        }
    }
}

/// A secret's binding: which host(s) it may be sent to, in which header, and which guest
/// environment variable carries its placeholder.
public struct CredentialBinding: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    /// Exact host names the secret is for (the proxy decrypts TLS for these, and only these).
    public var hosts: [String]
    public var header: CredentialHeader
    /// The guest environment variable a session gets the placeholder in, e.g. `ANTHROPIC_API_KEY`.
    public var environmentVariable: String?

    public init(id: String, hosts: [String], header: CredentialHeader, environmentVariable: String? = nil) {
        self.id = id
        self.hosts = hosts.map { $0.lowercased() }
        self.header = header
        self.environmentVariable = environmentVariable
    }

    /// Anthropic's API key: `x-api-key` on api.anthropic.com, `ANTHROPIC_API_KEY` in the guest.
    public static let anthropic = CredentialBinding(id: "anthropic", hosts: ["api.anthropic.com"], header: .xAPIKey,
                                                    environmentVariable: "ANTHROPIC_API_KEY")

    public func covers(_ host: String) -> Bool { hosts.contains(host.lowercased()) }
}

/// The host-side vault: secrets (memory only), bindings, and the placeholders minted for them.
///
/// **Placeholder lifecycle.** Each `mint` returns a NEW token for one binding — one per session
/// start — so a token is never shared between sessions or sandboxes, and `revokeAll` (on stop)
/// kills every token at once. A token is reusable for that session's requests (an SDK sends its
/// key on every request); "single-use" here means single ISSUE, never reused or re-issued.
public final class CredentialVault: @unchecked Sendable {
    public static let placeholderPrefix = "snz_cred_"

    private let lock = NSLock()
    private var bindings: [String: CredentialBinding] = [:]
    private var secrets: [String: String] = [:]
    /// token → binding id
    private var placeholders: [String: String] = [:]

    public init() {}

    public func set(_ binding: CredentialBinding, secret: String?) {
        lock.lock(); defer { lock.unlock() }
        bindings[binding.id] = binding
        secrets[binding.id] = secret.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func remove(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        bindings[id] = nil
        secrets[id] = nil
        placeholders = placeholders.filter { $0.value != id }
    }

    public var allBindings: [CredentialBinding] {
        lock.lock(); defer { lock.unlock() }
        return bindings.values.sorted { $0.id < $1.id }
    }

    public func hasSecret(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return secrets[id] != nil }

    /// Hosts whose TLS the proxy must decrypt (a binding with a secret covers them).
    public var boundHosts: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(bindings.values.filter { secrets[$0.id] != nil }.flatMap(\.hosts))
    }

    /// A fresh placeholder for binding `id` (nil if there is no such binding).
    public func mint(_ id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard bindings[id] != nil else { return nil }
        var raw = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytesShim.fill(&raw)
        let token = Self.placeholderPrefix + raw.map { String(format: "%02x", $0) }.joined()
        placeholders[token] = id
        return token
    }

    /// The environment a session gets: one fresh placeholder per binding that names a variable.
    public func sessionEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        for b in allBindings { if let v = b.environmentVariable, let t = mint(b.id) { env[v] = t } }
        return env
    }

    public func revokeAll() { lock.lock(); placeholders.removeAll(); lock.unlock() }

    public var livePlaceholderCount: Int { lock.lock(); defer { lock.unlock() }; return placeholders.count }

    /// What to do with one request's headers, bound for `host`. Pure: returns the decision and the
    /// rewritten head (byte-for-byte identical except for the one header value it changes).
    public func rewrite(head: [UInt8], host: String) -> CredentialDecision {
        lock.lock(); defer { lock.unlock() }
        let h = host.lowercased()
        let parsed = HTTPHead(head)
        // Every placeholder anywhere in the head is checked, not only in the bound header.
        let text = String(decoding: head, as: UTF8.self)
        let tokens = Self.placeholderTokens(in: text)
        let binding = bindings.values.first { $0.covers(h) && secrets[$0.id] != nil }
        for t in tokens {
            guard let bid = placeholders[t] else { return .reject("an unknown or revoked credential placeholder") }
            guard let b = bindings[bid], b.covers(h) else { return .reject("a credential placeholder for \(bindings[bid]?.hosts.joined(separator: ",") ?? bid), sent to \(h)") }
            if secrets[bid] == nil { return .reject("a placeholder for \(bid), which has no secret on this Mac") }
            _ = b
        }
        guard let binding, let secret = secrets[binding.id] else { return .passThrough(head) }
        let name = binding.header.headerName
        if let field = parsed?.field(named: name) {
            let value = String(decoding: head[field.valueRange], as: UTF8.self)
            guard let t = tokens.first(where: { value.contains($0) }), placeholders[t] == binding.id else {
                return .passThrough(head)            // the tool's own credential: untouched
            }
            let newValue = Array(value.replacingOccurrences(of: t, with: secret).utf8)
            var out = head
            out.replaceSubrange(field.valueRange, with: newValue)
            return .swapped(out, binding: binding.id)
        }
        guard let parsed else { return .passThrough(head) }
        var out = head
        out.insert(contentsOf: Array("\(Self.canonical(name)): \(binding.header.value(secret))\r\n".utf8), at: parsed.endOfFields)
        return .injected(out, binding: binding.id)
    }

    static func canonical(_ name: String) -> String {
        name == "authorization" ? "Authorization" : name
    }

    static func placeholderTokens(in s: String) -> [String] {
        var out: [String] = []
        var rest = Substring(s)
        while let r = rest.range(of: placeholderPrefix) {
            let tail = rest[r.upperBound...].prefix { $0.isHexDigit }
            out.append(placeholderPrefix + tail)
            rest = rest[r.upperBound...]
        }
        return out
    }
}

public enum CredentialDecision: Sendable, Equatable {
    case passThrough([UInt8])
    case swapped([UInt8], binding: String)
    case injected([UInt8], binding: String)
    case reject(String)

    public var head: [UInt8]? {
        switch self {
        case .passThrough(let h), .swapped(let h, _), .injected(let h, _): h
        case .reject: nil
        }
    }
}

/// `SecRandomCopyBytes` without importing Security into this file's API surface.
enum SecRandomCopyBytesShim {
    static func fill(_ bytes: inout [UInt8]) -> Bool {
        var g = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &g) }
        return true
    }
}

/// A minimal, byte-exact view of an HTTP/1.x request head (request line + fields + CRLF CRLF).
struct HTTPHead {
    struct Field { var name: String; var nameRange: Range<Int>; var valueRange: Range<Int> }
    var method: String
    var target: String
    var version: String
    var fields: [Field]
    /// Index where the terminating empty line starts (insert new fields here).
    var endOfFields: Int
    let bytes: [UInt8]

    init?(_ b: [UInt8]) {
        bytes = b
        guard let firstEnd = Self.crlf(b, from: 0) else { return nil }
        let line = String(decoding: b[0..<firstEnd], as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false)
        guard line.count == 3 else { return nil }
        method = String(line[0]); target = String(line[1]); version = String(line[2])
        var i = firstEnd + 2
        var fs: [Field] = []
        while true {
            guard let e = Self.crlf(b, from: i) else { return nil }
            if e == i { endOfFields = i; break }
            guard let colon = b[i..<e].firstIndex(of: UInt8(ascii: ":")) else { return nil }
            var vs = colon + 1
            while vs < e, b[vs] == 32 || b[vs] == 9 { vs += 1 }
            var ve = e
            while ve > vs, b[ve - 1] == 32 || b[ve - 1] == 9 { ve -= 1 }
            fs.append(Field(name: String(decoding: b[i..<colon], as: UTF8.self).lowercased(), nameRange: i..<colon, valueRange: vs..<ve))
            i = e + 2
        }
        fields = fs
    }

    func field(named n: String) -> Field? { fields.first { $0.name == n } }
    func value(_ n: String) -> String? { field(named: n).map { String(decoding: bytes[$0.valueRange], as: UTF8.self) } }

    /// The path without its query string (the audit log never records parameter values).
    var pathOnly: String {
        let p = target.hasPrefix("http://") || target.hasPrefix("https://") ? (URL(string: target)?.path ?? "/") : target
        return String(p.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "/")
    }

    static func crlf(_ b: [UInt8], from: Int) -> Int? {
        var i = from
        while i + 1 < b.count {
            if b[i] == 13 && b[i + 1] == 10 { return i }
            i += 1
        }
        return nil
    }
}
