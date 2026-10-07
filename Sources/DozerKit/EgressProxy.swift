import Containerization
import Darwin
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSL
import Security

// Feature 580 — the host half of a proxied sandbox's network. It runs in the host app's process
// and is the ONLY way out of a VM that has no network interface: the guest's `doznet` relays
// every connection and DNS question over vsock to `listen(on:)`. Each connection gets its own
// thread with blocking I/O (a sandbox makes tens of connections, not thousands).
//
//   "DOZ1 P"            the HTTP proxy protocol: CONNECT host:port (a tunnel — passed through by
//                       name, or decrypted when a credential binding or an HTTP rule needs it),
//                       or an absolute-form plain-HTTP request.
//   "DOZ1 T ip port"    any other TCP (the guest firewall's REDIRECT); the host name is recovered
//                       from the DNS answers this proxy gave, so the policy judges names, not IPs.
//   "DOZ1 D"            one DNS question: judged by the policy, answered from the Mac's resolver.
//
// Decryption uses a per-sandbox CA (`SandboxCA`) and NIOSSL (BoringSSL) driven synchronously
// through `EmbeddedChannel`, so no keychain is involved. ALPN offers only http/1.1 on decrypted
// tunnels (HTTP/2 and gRPC to a decrypted host are downgraded or fail); every other host passes
// through untouched — WebSockets, HTTP/2 and gRPC included. A client that pins its server's
// certificate fails loudly on a decrypted host, which is why only bound hosts are decrypted.

/// The host half of a proxied sandbox's network (580): the only way out of a VM with no network
/// interface — every connection and DNS question the guest's `doznet` relays over vsock
/// arrives here, is judged against a `NetworkPolicy`, logged, and (for bound hosts) decrypted.
public final class EgressProxy: @unchecked Sendable {
    /// The vsock port `doznet` dials (host CID 2).
    public static let vsockPort: UInt32 = 5800
    /// The guest's proxy endpoint.
    public static let proxyURL = "http://127.0.0.1:3128"
    public static let guestCAPath = "/etc/dozer/ca.pem"
    public static let guestCABundlePath = "/etc/dozer/ca-bundle.pem"
    public static let guestShimPath = "/usr/local/bin/doznet"

    public let log: ConnectionLog
    public let vault: CredentialVault
    private let lock = NSLock()
    private var _ca: SandboxCA?
    private var _policy: NetworkPolicy
    private var listener: VsockListener?
    private var acceptTask: Task<Void, Never>?
    private var names: [UInt32: String] = [:]
    private var _ownName: String?
    /// 594 W29: the sandbox's own host name (lower-cased), answered locally as 127.0.1.1.
    public var ownName: String? {
        get { lock.withLock { _ownName } }
        set { lock.withLock { _ownName = newValue?.lowercased() } }
    }
    private var serverContexts: [String: NIOSSLContext] = [:]
    private let clientContext: NIOSSLContext

    public init(policy: NetworkPolicy, ca: SandboxCA?, log: ConnectionLog = ConnectionLog(), vault: CredentialVault = CredentialVault()) throws {
        _policy = policy
        _ca = ca
        self.log = log
        self.vault = vault
        var cfg = TLSConfiguration.makeClientConfiguration()
        cfg.applicationProtocols = ["http/1.1"]
        clientContext = try NIOSSLContext(configuration: cfg)
    }

    /// The sandbox's CA (set at boot; nil: nothing can be decrypted, so bound hosts are denied).
    public var ca: SandboxCA? {
        get { lock.lock(); defer { lock.unlock() }; return _ca }
        set { lock.lock(); _ca = newValue; serverContexts = [:]; lock.unlock() }
    }

    public var policy: NetworkPolicy {
        get { lock.lock(); defer { lock.unlock() }; return _policy }
        set { lock.lock(); _policy = newValue; lock.unlock() }
    }

    /// 599d: this sandbox's GitHub login and its mode — read-only is enforced on every request that
    /// carries it (`GitHubAccess`). nil: the login is not this sandbox's.
    public var github: GitHubGate? {
        get { lock.lock(); defer { lock.unlock() }; return _github }
        set { lock.lock(); _github = newValue; lock.unlock() }
    }
    private var _github: GitHubGate?

    /// 599d (G4): while the user's SSH agent is forwarded, `github.com:22` is allowed — and only that.
    public var sshToGitHub: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _sshToGitHub }
        set { lock.lock(); _sshToGitHub = newValue; lock.unlock() }
    }
    private var _sshToGitHub = false

    /// 599d TEST SEAM: the GitHub hosts' upstream leg goes to `host:port` instead, verified against
    /// `anchorsPEM` ONLY (the fake upstream's own CA) for the GitHub host name. The host sets it only from
    /// `DOZ_TEST_GITHUB_UPSTREAM` + `DOZ_TEST_GITHUB_CA`; nothing else reaches it.
    public struct UpstreamOverride: Sendable, Equatable {
        public var host: String
        public var port: UInt16
        public var anchorsPEM: String
        public init(host: String, port: UInt16, anchorsPEM: String) { self.host = host; self.port = port; self.anchorsPEM = anchorsPEM }
    }
    public var githubUpstreamForTests: UpstreamOverride? {
        get { lock.lock(); defer { lock.unlock() }; return _githubUpstream }
        set { lock.lock(); _githubUpstream = newValue; lock.unlock() }
    }
    private var _githubUpstream: UpstreamOverride?

    /// The policy's verdict for a connection, with 599d's one addition: `github.com:22` while the SSH
    /// agent is forwarded.
    func connectionVerdict(host: String, port: UInt16) -> NetworkPolicy.ConnectionVerdict {
        if port == 22, host.lowercased() == "github.com", sshToGitHub {
            return NetworkPolicy.ConnectionVerdict(kind: .allow, rule: "SSH agent forwarding (github.com:22)", ruleIndex: nil)
        }
        // 599i: the renewal of this sandbox's ChatGPT sign-in is answered by the proxy itself, so its host is
        // reached (decrypted) even when the policy does not allow it — every OTHER request there is still judged.
        if port == 443, host.lowercased() == OpenAIAccess.authHost, chatgptRenewal != nil,
           policy.evaluateConnection(host: host, port: port).kind == .deny {
            return NetworkPolicy.ConnectionVerdict(kind: .inspect, rule: "ChatGPT sign-in renewal (answered by Dozer on the Mac)", ruleIndex: nil)
        }
        return policy.evaluateConnection(host: host, port: port)
    }

    /// 599i TEST SEAM: the OpenAI hosts' upstream leg (chatgpt.com, api.openai.com, auth.openai.com) goes
    /// to a fake OpenAI, trusting ONLY its CA. The host sets it only from `DOZ_TEST_OPENAI_UPSTREAM` +
    /// `DOZ_TEST_OPENAI_CA`.
    public var openaiUpstreamForTests: UpstreamOverride? {
        get { lock.lock(); defer { lock.unlock() }; return _openaiUpstream }
        set { lock.lock(); _openaiUpstream = newValue; lock.unlock() }
    }
    private var _openaiUpstream: UpstreamOverride?

    /// 599i: Codex's refresh of a ChatGPT sign-in (`POST auth.openai.com/oauth/token`) is ANSWERED HERE,
    /// never forwarded: the refresh token in the guest is a placeholder, and the Mac holds (and renews)
    /// the real one. `answer` gets the request body and returns the whole response; nil = the body
    /// carried no placeholder of this sandbox's (then the request is judged by the policy like any other).
    public struct ChatGPTRenewal: Sendable {
        public var answer: @Sendable (_ body: [UInt8]) -> [UInt8]?
        public init(answer: @escaping @Sendable (_ body: [UInt8]) -> [UInt8]?) { self.answer = answer }
    }
    public var chatgptRenewal: ChatGPTRenewal? {
        get { lock.lock(); defer { lock.unlock() }; return _chatgptRenewal }
        set { lock.lock(); _chatgptRenewal = newValue; lock.unlock() }
    }
    private var _chatgptRenewal: ChatGPTRenewal?
    /// The most a renewal request's body may be (it is held whole before it is answered).
    static let maximumRenewalBody = 64 << 10

    /// 599i: whether a request is Codex's renewal of a ChatGPT sign-in (answered by the proxy).
    func isChatGPTRenewal(host: String, method: String, path: String) -> Bool {
        chatgptRenewal != nil && host.lowercased() == OpenAIAccess.authHost && method == "POST" && path == OpenAIAccess.tokenPath
    }

    /// 599d test seam: where a GitHub host's upstream leg goes instead (nil: the real host). 599i: and the OpenAI hosts'.
    func upstreamOverride(for host: String) -> UpstreamOverride? {
        if let o = openaiUpstreamForTests, OpenAIAccess.isOpenAIHost(host) { return o }
        guard let o = githubUpstreamForTests, GitHubAccess.credentialHosts.contains(host.lowercased()) else { return nil }
        return o
    }

    /// DNS: the policy's answer, and github.com while the SSH agent is forwarded.
    func allowsName(_ name: String) -> Bool {
        policy.allowsName(name) || (sshToGitHub && name.lowercased() == "github.com")
    }

    // MARK: listening

    /// Accept the guest's connections on `instance`'s vsock port. Call again after every wake from
    /// disk: a VM stop drops the host's vsock listeners (580.03), and restoring does not bring them back.
    public func listen(on instance: VZVirtualMachineInstance) throws {
        stopListening()
        let l = try instance.listen(Self.vsockPort)
        lock.lock()
        listener = l
        acceptTask = Task.detached { [weak self] in
            for await fh in l {
                let fd = fh.fileDescriptor
                guard let self else { close(fd); continue }
                Thread.detachNewThread { self.handle(fd) }
            }
        }
        lock.unlock()
    }

    public func stopListening() {
        lock.lock()
        let l = listener, t = acceptTask
        listener = nil; acceptTask = nil
        lock.unlock()
        try? l?.finish()
        t?.cancel()
    }

    public var isListening: Bool { lock.lock(); defer { lock.unlock() }; return listener != nil }

    // MARK: the guest's view

    /// What every guest command and session of a proxied sandbox gets: the proxy, and the
    /// sandbox CA for the tools that do not read the system trust store.
    public var guestEnvironment: [String: String] {
        var e: [String: String] = [:]
        for k in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] { e[k] = Self.proxyURL }
        for k in ["NO_PROXY", "no_proxy"] { e[k] = "localhost,127.0.0.1,::1" }
        if ca != nil {
            e["NODE_EXTRA_CA_CERTS"] = Self.guestCAPath
            for k in ["SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "GIT_SSL_CAINFO"] { e[k] = Self.guestCABundlePath }
        }
        return e
    }

    /// The privileged script a fresh boot runs (after the CA certificate is copied to
    /// `guestCAPath` and the shim to `guestShimPath`): trust the CA system-wide (the bundle every
    /// distro's TLS reads, plus `update-ca-certificates`' source directory so a later run keeps
    /// it), build the combined bundle the environment points at, and start the shim. Idempotent.
    public static func guestSetupScript(withCA: Bool) -> String {
        var s = "set -e; "
        if withCA {
            s += """
            mkdir -p /etc/dozer /usr/local/share/ca-certificates; chmod 644 \(guestCAPath); \
            cp \(guestCAPath) /usr/local/share/ca-certificates/dozer-sandbox-ca.crt; \
            sys=; for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do \
            if [ -f "$f" ]; then sys=$f; break; fi; done; \
            if [ -n "$sys" ]; then line=$(sed -n 2p \(guestCAPath)); grep -qF "$line" "$sys" || cat \(guestCAPath) >> "$sys"; \
            cat "$sys" > \(guestCABundlePath); else mkdir -p /etc/ssl/certs; cat \(guestCAPath) > /etc/ssl/certs/ca-certificates.crt; \
            cat \(guestCAPath) > \(guestCABundlePath); fi; chmod 644 \(guestCABundlePath);
            """
        }
        s += "\(guestShimPath) up -p \(vsockPort)"
        return s
    }

    // MARK: one connection

    func handle(_ fd: Int32) {
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
        guard let header = Wire.readLine(fd) else { return }
        let parts = header.split(separator: " ").map(String.init)
        guard parts.first == "DOZ1", parts.count >= 2 else { return }
        switch parts[1] {
        case "P": handleProxy(fd)
        case "T" where parts.count == 4: handleTransparent(fd, ip: parts[2], port: UInt16(parts[3]) ?? 0)
        case "D": handleDNS(fd)
        default: break
        }
    }

    // MARK: DNS

    func handleDNS(_ fd: Int32) {
        guard let l = Wire.readExact(fd, 2), let q = Wire.readExact(fd, Int(l[0]) << 8 | Int(l[1])) else { return }
        let t0 = ContinuousClock.now
        let reply = answer(q)
        _ = Wire.writeAll(fd, [UInt8(reply.bytes.count >> 8), UInt8(reply.bytes.count & 0xff)] + reply.bytes)
        guard let name = reply.name else { return }
        log.upsert(ConnectionRecord(kind: .dns, host: name, verdict: reply.allowed ? .allowed : .denied,
                                    rule: reply.rule, bytesUp: q.count, bytesDown: reply.bytes.count,
                                    latencyMs: milliseconds(since: t0), detail: reply.summary))
    }

    struct DNSReply { var bytes: [UInt8]; var name: String?; var allowed: Bool; var rule: String; var summary: String }

    /// Judge and answer one DNS query. A denied name gets NXDOMAIN; A records come from the Mac's
    /// resolver (and are remembered, so a redirected TCP connection to that address is judged by
    /// name); AAAA and every other type get an empty answer — the guest has no IPv6 path.
    func answer(_ q: [UInt8]) -> DNSReply {
        guard let question = DNSMessage.question(q) else {
            return DNSReply(bytes: DNSMessage.response(to: q, questionEnd: min(q.count, 12), rcode: 1, answers: []),
                            name: nil, allowed: false, rule: "", summary: "malformed")
        }
        let (name, qtype, qEnd) = question
        // 594 W29: the sandbox's OWN name (its hostname — sudo looks it up) is answered here: 127.0.1.1,
        // never judged by the policy, never logged (the guest's /etc/hosts says the same; this is the
        // belt to that brace, for anything that asks DNS anyway).
        if let own = ownName, name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == own {
            return DNSReply(bytes: DNSMessage.response(to: q, questionEnd: qEnd, rcode: 0, answers: qtype == 1 ? [0x7F00_0101] : []),
                            name: nil, allowed: true, rule: "", summary: "the sandbox's own name")
        }
        let pol = policy
        guard allowsName(name) else {
            return DNSReply(bytes: DNSMessage.response(to: q, questionEnd: qEnd, rcode: 3, answers: []), name: name,
                            allowed: false, rule: pol.evaluate(host: name, port: 443).rule, summary: "type \(qtype) → NXDOMAIN (policy)")
        }
        let rule = pol.evaluate(host: name, port: 443).rule
        guard qtype == 1 else {
            return DNSReply(bytes: DNSMessage.response(to: q, questionEnd: qEnd, rcode: 0, answers: []), name: name,
                            allowed: true, rule: rule, summary: "type \(qtype) → no records (IPv4 only)")
        }
        let addrs = Self.resolveIPv4(name)
        guard !addrs.isEmpty else {
            return DNSReply(bytes: DNSMessage.response(to: q, questionEnd: qEnd, rcode: 3, answers: []), name: name,
                            allowed: true, rule: rule, summary: "A → NXDOMAIN")
        }
        lock.lock()
        if names.count > 4096 { names.removeAll() }
        for a in addrs { names[a] = name.lowercased() }
        lock.unlock()
        return DNSReply(bytes: DNSMessage.response(to: q, questionEnd: qEnd, rcode: 0, answers: addrs), name: name,
                        allowed: true, rule: rule, summary: "A → " + addrs.map(Self.dotted).joined(separator: ", "))
    }

    static func resolveIPv4(_ name: String) -> [UInt32] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var out: [UInt32] = []
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let v = a.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if !out.contains(v) { out.append(v) }
            ai = a.pointee.ai_next
        }
        return out
    }

    static func dotted(_ v: UInt32) -> String { "\(v >> 24).\(v >> 16 & 0xff).\(v >> 8 & 0xff).\(v & 0xff)" }

    /// The name the guest resolved `ip` from (via this proxy's DNS), if any.
    func name(for ip: String) -> String? {
        guard let v = IPv4CIDR.parseAddress(ip) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return names[v]
    }

    // MARK: the HTTP proxy port

    func handleProxy(_ fd: Int32) {
        var pending: [UInt8] = []
        guard let head = Wire.readHead(fd, into: &pending), let h = HTTPHead(head) else { return }
        if h.method == "CONNECT" {
            let (host, port) = Self.splitHostPort(h.target, defaultPort: 443)
            tunnel(fd, host: host, port: port, kind: .connect, leftover: pending, connectReply: true)
        } else {
            plainHTTP(fd, head: head, parsed: h, leftover: pending)
        }
    }

    static func splitHostPort(_ s: String, defaultPort: UInt16) -> (String, UInt16) {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            return (host, rest.hasPrefix(":") ? UInt16(rest.dropFirst()) ?? defaultPort : defaultPort)
        }
        let p = s.split(separator: ":", maxSplits: 1).map(String.init)
        return (p[0].lowercased(), p.count == 2 ? UInt16(p[1]) ?? defaultPort : defaultPort)
    }

    /// 606: what a sandbox is told when it tries to reach one of Dozer's own dashboards on this Mac.
    static let dashboardRefusal = "Dozer's own dashboard on this Mac is never reachable from a sandbox"

    /// A tunnel to host:port — through CONNECT (`connectReply`) or a redirected connection.
    func tunnel(_ fd: Int32, host: String, port: UInt16, kind: ConnectionRecord.Kind, leftover: [UInt8], connectReply: Bool,
                connectTo: String? = nil) {
        let t0 = ContinuousClock.now
        let v = connectionVerdict(host: host, port: port)
        var rec = ConnectionRecord(kind: kind, host: host, port: port, verdict: .allowed, rule: v.rule, open: true)
        // A credential is only ever inserted into HTTPS; SSH (599d, port 22) is end-to-end and passes as it is.
        let bound = vault.boundHosts.contains(host) && port != 22
        let decrypt = (bound || v.kind == .inspect) && IPv4CIDR.parseAddress(host) == nil
        if v.kind == .deny || (v.kind == .inspect && (ca == nil || !decrypt)) {
            rec.verdict = .denied
            rec.open = false
            rec.detail = v.kind == .deny ? nil : "needs request inspection, which this tunnel cannot have"
            log.upsert(rec)
            if connectReply { _ = Wire.writeAll(fd, Self.denial(host: "\(host):\(port)", rule: v.rule)) }
            return
        }
        if decrypt, let ca {
            if connectReply { _ = Wire.writeAll(fd, Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8)) }
            rec.decrypted = true
            log.upsert(rec)
            intercept(fd, host: host, port: port, ca: ca, leftover: leftover, tunnel: &rec, t0: t0)
            rec.open = false
            rec.durationMs = milliseconds(since: t0)
            log.upsert(rec)
            return
        }
        if LocalDashboards.refuses(host: connectTo ?? host, port: port) {
            rec.verdict = .denied
            rec.open = false
            rec.detail = Self.dashboardRefusal
            log.upsert(rec)
            if connectReply { _ = Wire.writeAll(fd, Self.forbidden(Self.dashboardRefusal)) }
            return
        }
        let up = Wire.connectTCP(connectTo ?? host, port)
        rec.latencyMs = milliseconds(since: t0)
        guard up >= 0 else {
            rec.verdict = .failed
            rec.open = false
            rec.detail = "could not connect from the Mac"
            log.upsert(rec)
            if connectReply { _ = Wire.writeAll(fd, Array("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)) }
            return
        }
        defer { close(up) }
        log.upsert(rec)
        if connectReply { _ = Wire.writeAll(fd, Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8)) }
        if !leftover.isEmpty { _ = Wire.writeAll(up, leftover); rec.bytesUp += leftover.count }
        let (u, d) = Wire.relay(fd, up)
        rec.bytesUp += u; rec.bytesDown = d
        rec.open = false
        rec.durationMs = milliseconds(since: t0)
        log.upsert(rec)
    }

    /// One absolute-form plain-HTTP request (the proxy port without CONNECT). Judged with its
    /// method and path; sent upstream with `Connection: close`; only that request's body is
    /// forwarded, so a pipelined second request cannot slip past the policy.
    func plainHTTP(_ fd: Int32, head: [UInt8], parsed h: HTTPHead, leftover: [UInt8]) {
        let t0 = ContinuousClock.now
        guard let url = URL(string: h.target), let host = url.host?.lowercased(), url.scheme?.lowercased() == "http" else {
            _ = Wire.writeAll(fd, Array("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
            return
        }
        let port = UInt16(url.port ?? 80)
        var path = url.path.isEmpty ? "/" : url.path
        let pathOnly = path
        if let q = url.query { path += "?" + q }
        let v = policy.evaluate(host: host, port: port, method: h.method, path: pathOnly)
        var rec = ConnectionRecord(kind: .http, host: host, port: port, method: h.method, path: pathOnly, verdict: .allowed, rule: v.rule, open: true)
        if v.action == .deny {
            rec.verdict = .denied; rec.open = false
            log.upsert(rec)
            _ = Wire.writeAll(fd, Self.denial(host: "\(host):\(port) \(h.method) \(pathOnly)", rule: v.rule))
            return
        }
        // A placeholder has no business on plain HTTP (secrets are only ever sent over TLS).
        if !CredentialVault.placeholders(inHead: head).isEmpty {
            rec.verdict = .denied; rec.open = false; rec.credential = "rejected: a credential placeholder over plain HTTP"
            log.upsert(rec)
            _ = Wire.writeAll(fd, Self.forbidden("a credential placeholder may not be sent to \(host) (plain HTTP)"))
            return
        }
        // Rebuild the head: origin-form target, no proxy fields, Connection: close.
        var out = Array("\(h.method) \(path) \(h.version)\r\n".utf8)
        for f in h.fields where !["connection", "proxy-connection", "proxy-authorization", "keep-alive"].contains(f.name) {
            out += head[f.nameRange.lowerBound..<f.valueRange.upperBound]
            out += [13, 10]
        }
        out += Array("Connection: close\r\n\r\n".utf8)
        if LocalDashboards.refuses(host: host, port: port) {
            rec.verdict = .denied; rec.open = false; rec.detail = Self.dashboardRefusal
            log.upsert(rec)
            _ = Wire.writeAll(fd, Self.forbidden(Self.dashboardRefusal))
            return
        }
        let up = Wire.connectTCP(host, port)
        rec.latencyMs = milliseconds(since: t0)
        guard up >= 0 else {
            rec.verdict = .failed; rec.open = false; rec.detail = "could not connect from the Mac"
            log.upsert(rec)
            _ = Wire.writeAll(fd, Array("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
            return
        }
        defer { close(up) }
        log.upsert(rec)
        _ = Wire.writeAll(up, out)
        rec.bytesUp = out.count
        // Forward exactly this request's body, then only relay the response.
        var reader = HTTPRequestReader()
        _ = reader.feed(head)
        var done = reader.atRequestBoundary
        func forward(_ events: [HTTPRequestReader.Event]) {
            for e in events {
                switch e {
                case .body(let b), .raw(let b): if !done { _ = Wire.writeAll(up, b); rec.bytesUp += b.count }
                case .head, .malformed: done = true
                }
            }
            if reader.atRequestBoundary { done = true }
        }
        if !leftover.isEmpty { forward(reader.feed(leftover)) }
        var buf = [UInt8](repeating: 0, count: 65536)
        var guestOpen = !done
        while true {
            var p = [pollfd(fd: guestOpen ? fd : -1, events: Int16(POLLIN), revents: 0), pollfd(fd: up, events: Int16(POLLIN), revents: 0)]
            if poll(&p, 2, -1) < 0 { if errno == EINTR { continue }; break }
            if guestOpen, p[0].revents != 0 {
                let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n <= 0 { guestOpen = false; shutdown(up, SHUT_WR) } else {
                    forward(reader.feed(Array(buf[0..<n])))
                    if done { guestOpen = false }
                }
            }
            if p[1].revents != 0 {
                let n = buf.withUnsafeMutableBytes { read(up, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                if !Wire.writeAll(fd, Array(buf[0..<n])) { break }
                rec.bytesDown += n
            }
        }
        rec.open = false
        rec.durationMs = milliseconds(since: t0)
        log.upsert(rec)
    }

    // MARK: redirected TCP

    func handleTransparent(_ fd: Int32, ip: String, port: UInt16) {
        let name = name(for: ip)
        let host = name ?? ip
        if port == 443, name != nil {
            // A TLS client that ignored HTTPS_PROXY: same judgement (and injection) as CONNECT.
            tunnel(fd, host: host, port: port, kind: .tcp, leftover: [], connectReply: false, connectTo: ip)
            return
        }
        let v = connectionVerdict(host: host, port: port)
        let bound = vault.boundHosts.contains(host) && port != 22          // 599d: SSH is never inspected
        if v.kind != .allow || bound {
            log.upsert(ConnectionRecord(kind: .tcp, host: host, port: port, verdict: .denied, rule: v.rule,
                                        detail: v.kind == .inspect || bound ? "this host needs the HTTP proxy (request inspection)" : (name == nil ? "address not resolved through the sandbox DNS" : nil)))
            return
        }
        tunnel(fd, host: host, port: port, kind: .tcp, leftover: [], connectReply: false, connectTo: ip)
    }

    // MARK: decrypted tunnels

    /// Terminate the guest's TLS with a leaf from the sandbox CA, judge and rewrite every request,
    /// and re-encrypt to the real host (verified against the Mac's trust store).
    func intercept(_ fd: Int32, host: String, port: UInt16, ca: SandboxCA, leftover: [UInt8], tunnel rec: inout ConnectionRecord,
                   t0: ContinuousClock.Instant) {
        let guest: EmbeddedChannel
        do {
            guest = try makeServerChannel(host: host, ca: ca)
        } catch {
            rec.verdict = .failed; rec.detail = "could not make a certificate for \(host): \(error)"
            return
        }
        var upstream: TLSUpstream?
        var reader = HTTPRequestReader()
        var buf = [UInt8](repeating: 0, count: 65536)
        var guestOpen = true
        var closing = false
        var current: ConnectionRecord?
        // 588: once this connection carried the guest's own credential, none of its requests gets
        // ours injected (Claude Code's telemetry rides the same connection without auth).
        var foreignOnConnection = false
        // The binding whose secret the last request carried: a 401 answer makes the owner re-read it.
        var awaitingStatus: String?
        defer {
            // Never `finish()`: it waits on close(), and NIOSSL's close waits for the peer's
            // close_notify — a thread blocked forever per tunnel.
            guest.close(promise: nil)
            _ = Wire.drain(guest, to: fd)
            upstream?.close()
            if var c = current { c.open = false; log.upsert(c) }
        }
        func toGuest() -> Bool { Wire.drain(guest, to: fd) }
        func reject(_ status: [UInt8]) {
            guest.writeAndFlush(ByteBuffer(bytes: status), promise: nil)
            _ = toGuest()
            closing = true
        }
        // 599d: a read-only GitHub request whose BODY decides it (GraphQL, LFS) is held here — head and
        // body — until the body is whole; nothing of it goes upstream before.
        var held: (head: [UInt8], record: ConnectionRecord, kind: GitHubAccess.BodyKind, length: Int, body: [UInt8])?
        /// Open the upstream leg (once) and send `out`; false: it could not be opened (the guest was told).
        func sendUpstream(_ out: [UInt8], _ record: ConnectionRecord) -> Bool {
            var r = record
            if upstream == nil {
                let ut0 = ContinuousClock.now
                guard let u = TLSUpstream(host: host, port: port, context: clientContext, override: upstreamOverride(for: host)) else {
                    r.verdict = .failed; r.open = false; r.detail = "could not connect from the Mac"
                    log.upsert(r)
                    reject(Array("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
                    return false
                }
                upstream = u
                rec.latencyMs = milliseconds(since: ut0)
                r.latencyMs = rec.latencyMs
            }
            upstream?.send(out)
            r.bytesUp = out.count
            rec.bytesUp += out.count
            current = r
            log.upsert(r)
            return true
        }
        func refuseGitHub(_ record: ConnectionRecord, _ why: String) {
            var r = record
            r.verdict = .denied; r.open = false; r.credential = "refused: GitHub is read-only for this sandbox"
            log.upsert(r)
            current = nil
            reject(Self.response(403, why + "\n", extra: "X-Sandbox-Policy: github\r\n"))
        }
        func releaseHeld() {
            guard let hd = held else { return }
            held = nil
            let gate = github
            switch GitHubAccess.classify(body: hd.body, kind: hd.kind, sandbox: gate?.sandbox ?? "this sandbox") {
            case .allow:
                if sendUpstream(hd.head, hd.record), !hd.body.isEmpty {
                    upstream?.send(hd.body)
                    rec.bytesUp += hd.body.count
                    current?.bytesUp += hd.body.count
                }
            case .refuse(let why):
                refuseGitHub(hd.record, why)
            case .needsBody:
                refuseGitHub(hd.record, GitHubAccess.pushOff(gate?.sandbox ?? "this sandbox", "a request Dozer could not decide was refused"))
            }
        }
        // 599i: Codex's renewal of a ChatGPT sign-in — held whole, then answered here (or, when it carries no
        // placeholder of this sandbox's, judged by the policy and forwarded like any request).
        var renewal: (head: [UInt8], record: ConnectionRecord, length: Int, body: [UInt8])?
        func finishRenewal() {
            guard let rn = renewal else { return }
            renewal = nil
            var r = rn.record
            if let gate = chatgptRenewal, let answer = gate.answer(rn.body) {
                let ok = answer.count >= 12 && Array(answer[9..<12]) == Array("200".utf8)
                r.verdict = ok ? .allowed : .denied
                r.open = false
                r.credential = ok ? "answered chatgpt renewal (the Mac renews the sign-in)" : "refused chatgpt renewal"
                log.upsert(r)
                current = nil
                reject(answer)
                return
            }
            // Not ours: the policy decides, as for any request.
            let v = policy.evaluate(host: host, port: port, method: "POST", path: OpenAIAccess.tokenPath)
            r.rule = v.rule
            if v.action == .deny {
                r.verdict = .denied; r.open = false
                log.upsert(r)
                current = nil
                reject(Self.denial(host: "\(host) POST \(OpenAIAccess.tokenPath)", rule: v.rule))
                return
            }
            if sendUpstream(rn.head, r), !rn.body.isEmpty {
                upstream?.send(rn.body)
                rec.bytesUp += rn.body.count
                current?.bytesUp += rn.body.count
            }
        }
        func process(_ events: [HTTPRequestReader.Event]) {
            for e in events {
                if closing { return }
                switch e {
                case .malformed(let why):
                    reject(Self.forbidden("unreadable request: \(why)"))
                case .head(let raw):
                    guard let h = HTTPHead(raw) else { reject(Self.forbidden("unreadable request")); return }
                    if var c = current { c.open = false; log.upsert(c) }
                    let path = h.pathOnly
                    if isChatGPTRenewal(host: host, method: h.method, path: path) {
                        let r = ConnectionRecord(kind: .http, host: host, port: port, method: h.method, path: path,
                                                 verdict: .allowed, rule: "ChatGPT sign-in renewal (answered by Dozer on the Mac)", decrypted: true, open: true)
                        let length = Int(h.value("content-length") ?? "") ?? -1
                        guard h.value("transfer-encoding") == nil, length >= 0, length <= Self.maximumRenewalBody else {
                            var d = r; d.verdict = .denied; d.open = false; d.credential = "refused: a renewal Dozer could not read"
                            log.upsert(d)
                            current = nil
                            reject(OpenAIAccess.refreshAnswer(placeholder: "", guestIDToken: nil, problem: "a sign-in renewal Dozer could not read was refused"))
                            return
                        }
                        renewal = (raw, r, length, [])
                        if length == 0 { finishRenewal() }
                        continue
                    }
                    let v = policy.evaluate(host: host, port: port, method: h.method, path: path)
                    var r = ConnectionRecord(kind: .http, host: host, port: port, method: h.method, path: path,
                                             verdict: .allowed, rule: v.rule, decrypted: true, open: true)
                    if v.action == .deny {
                        r.verdict = .denied; r.open = false
                        log.upsert(r)
                        current = nil
                        reject(Self.denial(host: "\(host) \(h.method) \(path)", rule: v.rule))
                        return
                    }
                    let decision = vault.rewrite(head: raw, host: host, inject: !foreignOnConnection)
                    awaitingStatus = nil
                    switch decision {
                    case .reject(let why):
                        r.verdict = .denied; r.open = false; r.credential = "rejected: \(why)"
                        log.upsert(r)
                        current = nil
                        reject(Self.forbidden(why))
                        return
                    case .refuse(let code, let why):
                        r.verdict = .denied; r.open = false
                        r.credential = code == 401 ? "unavailable: \(why)" : "refused: \(why)"
                        log.upsert(r)
                        current = nil
                        // 599i: in OpenAI's error shape on OpenAI's hosts (Codex shows its message).
                        reject(OpenAIAccess.isOpenAIHost(host) ? OpenAIAccess.refusal(code, why) : Self.refusal(code, why))
                        return
                    case .swapped(_, let b): r.credential = "swapped \(b)"; awaitingStatus = b
                    case .injected(_, let b): r.credential = "injected \(b)"; awaitingStatus = b
                    case .foreign(_, let f): r.credential = f.label; foreignOnConnection = true
                    case .passThrough: break
                    }
                    let out = decision.head ?? raw
                    // 599d: a request carrying the user's GitHub login, judged against the sandbox's mode.
                    let usesGitHubLogin: Bool = {
                        switch decision {
                        case .swapped(_, let b), .injected(_, let b): return b == CredentialBinding.github.id
                        default: return false
                        }
                    }()
                    if usesGitHubLogin {
                        let gate = github ?? GitHubGate(mode: .read, sandbox: "this sandbox")   // no gate: the strictest
                        switch GitHubAccess.classify(mode: gate.mode, method: h.method, host: host, target: h.target, sandbox: gate.sandbox) {
                        case .allow:
                            r.credential = "swapped github (\(gate.mode.rawValue))"
                        case .refuse(let why):
                            refuseGitHub(r, why)
                            return
                        case .needsBody(let kind):
                            r.credential = "swapped github (read — body checked)"
                            if h.value("transfer-encoding") != nil {
                                refuseGitHub(r, GitHubAccess.pushOff(gate.sandbox, "a request Dozer could not check (chunked) was refused"))
                                return
                            }
                            let length = Int(h.value("content-length") ?? "0") ?? -1
                            guard length >= 0, length <= GitHubAccess.maximumBody else {
                                refuseGitHub(r, GitHubAccess.pushOff(gate.sandbox, "a request too large to check was refused"))
                                return
                            }
                            held = (out, r, kind, length, [])
                            if length == 0 { releaseHeld() }
                            continue
                        }
                    }
                    guard sendUpstream(out, r) else { return }
                case .body(let b), .raw(let b):
                    if var rn = renewal {
                        rn.body += b
                        renewal = rn
                        if rn.body.count >= rn.length {
                            if rn.body.count > rn.length { renewal = nil; reject(Self.forbidden("a renewal longer than it said")); return }
                            finishRenewal()
                        }
                        continue
                    }
                    if var hd = held {
                        hd.body += b
                        held = hd
                        if hd.body.count > hd.length {
                            held = nil
                            refuseGitHub(hd.record, GitHubAccess.pushOff(github?.sandbox ?? "this sandbox", "a request longer than it said was refused"))
                            return
                        }
                        if hd.body.count == hd.length { releaseHeld() }
                        continue
                    }
                    upstream?.send(b)
                    rec.bytesUp += b.count
                    current?.bytesUp += b.count
                }
            }
        }
        func fromGuest(_ bytes: [UInt8]) -> Bool {
            do { try guest.writeInbound(ByteBuffer(bytes: bytes)) } catch {
                rec.verdict = .failed
                rec.detail = "TLS with the guest failed (\(error)) — does the tool trust the sandbox CA, or pin its certificate?"
                _ = toGuest()
                return false
            }
            guard toGuest() else { return false }
            var plain: [UInt8] = []
            while let b = try? guest.readInbound(as: ByteBuffer.self) { plain += b.readableBytesView }
            if !plain.isEmpty { process(reader.feed(plain)) }
            return true
        }
        if !leftover.isEmpty, !fromGuest(leftover) { return }
        while !closing {
            var p = [pollfd(fd: guestOpen ? fd : -1, events: Int16(POLLIN), revents: 0),
                     pollfd(fd: upstream?.fd ?? -1, events: Int16(POLLIN), revents: 0)]
            if !guestOpen && upstream == nil { break }
            if poll(&p, 2, -1) < 0 { if errno == EINTR { continue }; break }
            if guestOpen, p[0].revents != 0 {
                let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n <= 0 {
                    guestOpen = false
                    upstream?.closeWrite()
                    if upstream == nil { break }
                } else if !fromGuest(Array(buf[0..<n])) { break }
            }
            if let u = upstream, p[1].revents != 0 {
                switch u.receive() {
                case .data(let plain):
                    if let b = awaitingStatus, !plain.isEmpty {
                        awaitingStatus = nil
                        // "HTTP/1.1 401 " — our secret was refused upstream: re-read it before the
                        // guest sees the answer, so its retry carries the renewed one.
                        if plain.count >= 12, Array(plain[9..<12]) == Array("401".utf8) {
                            vault.upstreamRejected(b)
                            current?.detail = "upstream 401 — the credential was re-read"
                        }
                    }
                    if !plain.isEmpty {
                        rec.bytesDown += plain.count
                        current?.bytesDown += plain.count
                        guest.writeAndFlush(ByteBuffer(bytes: plain), promise: nil)
                        if !toGuest() { closing = true }
                    }
                case .closed:
                    guest.close(promise: nil)
                    _ = toGuest()
                    shutdown(fd, SHUT_WR)
                    closing = true
                case .failed(let why):
                    rec.verdict = .failed
                    rec.detail = why
                    if var c = current { c.verdict = .failed; c.detail = why; log.upsert(c) }
                    reject(Array("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
                }
            }
        }
    }

    func makeServerChannel(host: String, ca: SandboxCA) throws -> EmbeddedChannel {
        let ctx: NIOSSLContext
        lock.lock()
        let cached = serverContexts[host]
        lock.unlock()
        if let cached { ctx = cached } else {
            let leaf = try ca.leaf(for: host)
            let chain = [try NIOSSLCertificate(bytes: Array(leaf.certificatePEM.utf8), format: .pem),
                         try NIOSSLCertificate(bytes: Array(ca.certificatePEM.utf8), format: .pem)]
            var cfg = TLSConfiguration.makeServerConfiguration(
                certificateChain: chain.map { .certificate($0) },
                privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(leaf.keyPEM.utf8), format: .pem)))
            cfg.applicationProtocols = ["http/1.1"]
            ctx = try NIOSSLContext(configuration: cfg)
            lock.lock(); serverContexts[host] = ctx; lock.unlock()
        }
        let ch = EmbeddedChannel()
        try ch.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: ctx))
        try ch.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
        return ch
    }

    // MARK: canned responses

    static func denial(host: String, rule: String) -> [UInt8] {
        response(403, "blocked by the sandbox network policy: \(host) (\(rule))\n", extra: "X-Sandbox-Policy: denied\r\n")
    }

    static func forbidden(_ why: String) -> [UInt8] {
        response(403, "refused by the sandbox proxy: \(why)\n", extra: "X-Sandbox-Policy: credential\r\n")
    }

    /// The proxy's own answer in the shape of an Anthropic API error, so a client shows its message
    /// (588: an unavailable or expired credential → 401; a strict refusal → 403).
    static func refusal(_ code: Int, _ message: String) -> [UInt8] {
        let type = code == 401 ? "authentication_error" : "permission_error"
        let obj: [String: Any] = ["type": "error", "error": ["type": type, "message": "doz: " + message]]
        let b = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])).map(Array.init) ?? []
        let reason = code == 401 ? "Unauthorized" : "Forbidden"
        return Array("HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nX-Sandbox-Policy: credential\r\nConnection: close\r\nContent-Length: \(b.count)\r\n\r\n".utf8) + b
    }

    static func response(_ code: Int, _ body: String, extra: String = "") -> [UInt8] {
        let b = Array(body.utf8)
        return Array("HTTP/1.1 \(code) \(code == 403 ? "Forbidden" : "Error")\r\nContent-Type: text/plain\r\n\(extra)Connection: close\r\nContent-Length: \(b.count)\r\n\r\n".utf8) + b
    }
}

/// The re-encrypted leg to the real host: a TCP socket and NIOSSL's client, verified against the
/// Mac's trust store (Security.framework) for exactly `host`.
final class TLSUpstream {
    enum Received { case data([UInt8]), closed, failed(String) }

    let fd: Int32
    let channel: EmbeddedChannel
    private var buf = [UInt8](repeating: 0, count: 65536)
    private var failure: String?

    init?(host: String, port: UInt16, context: NIOSSLContext, override: EgressProxy.UpstreamOverride? = nil) {
        // 599d test seam: another address, and ONLY the given anchors trusted (for `host`'s name).
        let fd = Wire.connectTCP(override?.host ?? host, override?.port ?? port)
        guard fd >= 0 else { return nil }
        self.fd = fd
        channel = EmbeddedChannel()
        let failureBox = FailureBox()
        let anchors = override.map { TLSUpstream.certificates(pem: $0.anchorsPEM) }
        do {
            let handler = try NIOSSLClientHandler(context: context, serverHostname: host) { certs, promise in
                if TLSUpstream.trusted(certs, host: host, anchors: anchors) { promise.succeed(.certificateVerified) } else {
                    failureBox.value = "the certificate of \(host) is not trusted by this Mac"
                    promise.succeed(.failed)
                }
            }
            try channel.pipeline.syncOperations.addHandler(handler)
            try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
        } catch {
            Darwin.close(fd)
            return nil
        }
        self.failureBox = failureBox
        _ = Wire.drain(channel, to: fd)
    }

    private var failureBox = FailureBox()
    final class FailureBox: @unchecked Sendable { var value: String? }

    func send(_ bytes: [UInt8]) {
        channel.writeAndFlush(ByteBuffer(bytes: bytes), promise: nil)
        _ = Wire.drain(channel, to: fd)
    }

    func receive() -> Received {
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n <= 0 {
            channel.close(promise: nil)
            return .closed
        }
        do { try channel.writeInbound(ByteBuffer(bytes: buf[0..<n])) } catch {
            return .failed(failureBox.value ?? "TLS to the upstream failed: \(error)")
        }
        (channel.eventLoop as? EmbeddedEventLoop)?.run()
        _ = Wire.drain(channel, to: fd)
        var plain: [UInt8] = []
        while let b = try? channel.readInbound(as: ByteBuffer.self) { plain += b.readableBytesView }
        return .data(plain)
    }

    func closeWrite() {
        channel.close(promise: nil)
        _ = Wire.drain(channel, to: fd)
        shutdown(fd, SHUT_WR)
    }

    func close() {
        channel.close(promise: nil)                  // not finish(): see intercept
        _ = Wire.drain(channel, to: fd)
        Darwin.close(fd)
    }

    static func trusted(_ certs: [NIOSSLCertificate], host: String, anchors: [SecCertificate]? = nil) -> Bool {
        let sec = certs.compactMap { c -> SecCertificate? in
            guard let der = try? c.toDERBytes() else { return nil }
            return SecCertificateCreateWithData(nil, Data(der) as CFData)
        }
        guard !sec.isEmpty else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(sec as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess,
              let trust else { return false }
        if let anchors {
            // 599d test seam: these anchors and nothing else (never the Mac's store as well).
            guard !anchors.isEmpty, SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return false }
        }
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// The certificates in a PEM text.
    static func certificates(pem: String) -> [SecCertificate] {
        var out: [SecCertificate] = []
        var rest = Substring(pem)
        while let b = rest.range(of: "-----BEGIN CERTIFICATE-----"), let e = rest[b.upperBound...].range(of: "-----END CERTIFICATE-----") {
            let body = rest[b.upperBound..<e.lowerBound].filter { !$0.isWhitespace }
            if let der = Data(base64Encoded: String(body)), let c = SecCertificateCreateWithData(nil, der as CFData) { out.append(c) }
            rest = rest[e.upperBound...]
        }
        return out
    }
}

// MARK: - blocking socket plumbing

enum Wire {
    static func writeAll(_ fd: Int32, _ data: [UInt8]) -> Bool {
        var off = 0
        while off < data.count {
            let w = data[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if w < 0 { if errno == EINTR { continue }; return false }
            off += w
        }
        return true
    }

    static func readExact(_ fd: Int32, _ n: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: n), off = 0
        while off < n {
            let r = out[off...].withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if r < 0 && errno == EINTR { continue }
            if r <= 0 { return nil }
            off += r
        }
        return out
    }

    static func readLine(_ fd: Int32, max: Int = 256) -> String? {
        var bytes: [UInt8] = []
        var b: UInt8 = 0
        while bytes.count < max {
            let r = read(fd, &b, 1)
            if r < 0 && errno == EINTR { continue }
            if r <= 0 { return nil }
            if b == 10 { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(b)
        }
        return nil
    }

    /// Read until the end of an HTTP head; what came after it is left in `rest`.
    static func readHead(_ fd: Int32, into rest: inout [UInt8]) -> [UInt8]? {
        var acc: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 8192)
        while acc.count < HTTPRequestReader.maxHead {
            if let e = HTTPRequestReader.find(acc, [13, 10, 13, 10]) {
                rest = Array(acc[(e + 4)...])
                return Array(acc[0..<(e + 4)])
            }
            let r = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if r < 0 && errno == EINTR { continue }
            if r <= 0 { return nil }
            acc += buf[0..<r]
        }
        return nil
    }

    /// Copy both ways until both directions close. Returns (a→b, b→a) bytes.
    static func relay(_ a: Int32, _ b: Int32) -> (Int, Int) {
        var buf = [UInt8](repeating: 0, count: 65536)
        var aOpen = true, bOpen = true, ab = 0, ba = 0
        while aOpen || bOpen {
            var p = [pollfd(fd: aOpen ? a : -1, events: Int16(POLLIN), revents: 0),
                     pollfd(fd: bOpen ? b : -1, events: Int16(POLLIN), revents: 0)]
            if poll(&p, 2, -1) < 0 { if errno == EINTR { continue }; break }
            for i in 0..<2 where p[i].revents != 0 {
                let from = i == 0 ? a : b, to = i == 0 ? b : a
                let r = buf.withUnsafeMutableBytes { read(from, $0.baseAddress, $0.count) }
                if r < 0 && errno == EINTR { continue }
                if r <= 0 {
                    shutdown(to, SHUT_WR)
                    if i == 0 { aOpen = false } else { bOpen = false }
                    if r < 0 { return (ab, ba) }
                    continue
                }
                if !writeAll(to, Array(buf[0..<r])) { return (ab, ba) }
                if i == 0 { ab += r } else { ba += r }
            }
        }
        return (ab, ba)
    }

    /// Write whatever `channel` has produced (ciphertext) to `fd`.
    static func drain(_ channel: EmbeddedChannel, to fd: Int32) -> Bool {
        (channel.eventLoop as? EmbeddedEventLoop)?.run()
        while let b = try? channel.readOutbound(as: ByteBuffer.self) {
            if !writeAll(fd, Array(b.readableBytesView)) { return false }
        }
        return true
    }

    /// TCP connect by name (the Mac's resolver) or address, with a timeout.
    static func connectTCP(_ host: String, _ port: UInt16, timeoutMS: Int32 = 10_000) -> Int32 {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { return -1 }
        defer { freeaddrinfo(first) }
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            // 606: never one of Dozer's own dashboards on this Mac, whatever the policy says.
            if let sa = a.pointee.ai_addr, LocalDashboards.refuses(UnsafePointer(sa), port: port) { ai = a.pointee.ai_next; continue }
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd >= 0 {
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, 4)
                let fl = fcntl(fd, F_GETFL)
                _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK)
                var ok = connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0
                if !ok && errno == EINPROGRESS {
                    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&p, 1, timeoutMS) == 1 {
                        var err: Int32 = 0
                        var len = socklen_t(4)
                        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                        ok = err == 0
                    }
                }
                if ok { _ = fcntl(fd, F_SETFL, fl); return fd }
                close(fd)
            }
            ai = a.pointee.ai_next
        }
        return -1
    }
}

// MARK: - DNS wire format (just what the proxy needs)

enum DNSMessage {
    /// (name, qtype, index just past the question) of a standard one-question query.
    static func question(_ q: [UInt8]) -> (String, Int, Int)? {
        guard q.count >= 12, q[4] == 0, q[5] >= 1 else { return nil }
        var i = 12
        var labels: [String] = []
        while i < q.count, q[i] != 0 {
            let n = Int(q[i])
            guard n < 64 else { return nil }
            i += 1
            guard i + n <= q.count else { return nil }
            labels.append(String(decoding: q[i..<i + n], as: UTF8.self))
            i += n
        }
        i += 1
        guard i + 4 <= q.count, !labels.isEmpty else { return nil }
        return (labels.joined(separator: ".").lowercased(), Int(q[i]) << 8 | Int(q[i + 1]), i + 4)
    }

    /// A response to `q` echoing its question, with `answers` as A records (TTL 60).
    static func response(to q: [UInt8], questionEnd: Int, rcode: UInt8, answers: [UInt32]) -> [UInt8] {
        guard q.count >= 12 else { return [] }
        var r: [UInt8] = [q[0], q[1], 0x81 | (q[2] & 0x01), 0x80 | rcode, 0, questionEnd > 12 ? 1 : 0,
                          UInt8(answers.count >> 8), UInt8(answers.count & 0xff), 0, 0, 0, 0]
        r += q[12..<questionEnd]
        for a in answers {
            r += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, UInt8(a >> 24), UInt8(a >> 16 & 0xff), UInt8(a >> 8 & 0xff), UInt8(a & 0xff)]
        }
        return r
    }
}
