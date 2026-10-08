import Darwin
import NIOCore
import NIOEmbedded
import NIOSSL
import XCTest
@testable import DozerKit

/// 580 — the host proxy end to end WITHOUT a VM: a socketpair stands in for the vsock stream the
/// guest shim would open. Everything here is refused before any upstream connection, so no network.
final class EgressProxyTests: XCTestCase {
    /// Run `proxy.handle` on one end; return the other.
    func open(_ proxy: EgressProxy, header: String) -> Int32 {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        var one: Int32 = 1
        setsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
        let server = fds[1]
        Thread.detachNewThread { proxy.handle(server) }
        _ = Wire.writeAll(fds[0], Array(header.utf8))
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fds[0], SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fds[0]
    }

    func readAll(_ fd: Int32) -> String {
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out += buf[0..<n]
        }
        return String(decoding: out, as: UTF8.self)
    }

    func waitForRecord(_ log: ConnectionLog, _ where_: (ConnectionRecord) -> Bool) -> ConnectionRecord? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let r = log.records.last(where: where_), !r.open { return r }
            usleep(20_000)
        }
        return nil
    }

    func testDeniedConnectIs403AndLogged() throws {
        let proxy = try EgressProxy(policy: .agent, ca: nil)
        let fd = open(proxy, header: "DOZ1 P\nCONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
        defer { close(fd) }
        let reply = readAll(fd)
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403"), reply)
        XCTAssertTrue(reply.contains("X-Sandbox-Policy: denied"))
        let r = try XCTUnwrap(waitForRecord(proxy.log) { $0.host == "example.com" })
        XCTAssertEqual(r.verdict, .denied)
        XCTAssertEqual(r.kind, .connect)
        XCTAssertEqual(r.rule, "default deny")
        XCTAssertEqual(proxy.log.deniedCount, 1)
    }

    func testDeniedPlainHTTPAndPlaceholderOverPlainHTTP() throws {
        let proxy = try EgressProxy(policy: NetworkPolicy(rules: [EgressRule(host: "ok.test", methods: ["GET"])]), ca: nil)
        let post = open(proxy, header: "DOZ1 P\nPOST http://ok.test/x?secret=1 HTTP/1.1\r\nHost: ok.test\r\nContent-Length: 0\r\n\r\n")
        XCTAssertTrue(readAll(post).hasPrefix("HTTP/1.1 403"))
        close(post)
        let r = try XCTUnwrap(waitForRecord(proxy.log) { $0.method == "POST" })
        XCTAssertEqual(r.path, "/x", "never the query string")
        XCTAssertEqual(r.verdict, .denied)

        proxy.vault.set(.anthropic, secret: "sk-REAL")
        let t = try XCTUnwrap(proxy.vault.mint("anthropic"))
        let leak = open(proxy, header: "DOZ1 P\nGET http://ok.test/ HTTP/1.1\r\nHost: ok.test\r\nx-api-key: \(t)\r\n\r\n")
        let reply = readAll(leak)
        close(leak)
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403"), reply)
        XCTAssertFalse(reply.contains("sk-REAL"))
        let lr = try XCTUnwrap(waitForRecord(proxy.log) { $0.credential != nil })
        XCTAssertTrue(lr.credential?.hasPrefix("rejected") == true)
    }

    func testRedirectedTCPToAnUnresolvedAddressIsDenied() throws {
        let proxy = try EgressProxy(policy: .agent, ca: nil)
        let fd = open(proxy, header: "DOZ1 T 203.0.113.9 5432\n")
        defer { close(fd) }
        XCTAssertEqual(readAll(fd), "", "closed without a byte")
        let r = try XCTUnwrap(waitForRecord(proxy.log) { $0.kind == .tcp })
        XCTAssertEqual(r.verdict, .denied)
        XCTAssertEqual(r.host, "203.0.113.9")
    }

    // MARK: decrypted tunnels

    /// A TLS client over `fd` that trusts only `ca` (what a guest with the CA installed does).
    final class GuestTLS {
        let fd: Int32
        let ch = EmbeddedChannel()
        init(fd: Int32, host: String, ca: String) throws {
            self.fd = fd
            var cfg = TLSConfiguration.makeClientConfiguration()
            cfg.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(ca.utf8), format: .pem)])
            cfg.applicationProtocols = ["http/1.1"]
            try ch.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: NIOSSLContext(configuration: cfg), serverHostname: host))
            try ch.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
            _ = Wire.drain(ch, to: fd)
        }
        func send(_ s: String) throws {
            ch.writeAndFlush(ByteBuffer(string: s), promise: nil)
            _ = Wire.drain(ch, to: fd)
        }
        /// Plaintext until the peer closes (or 10 s).
        func receiveAll() throws -> String {
            var plain: [UInt8] = []
            var buf = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                do { try ch.writeInbound(ByteBuffer(bytes: buf[0..<n])) } catch { break }
                _ = Wire.drain(ch, to: fd)
                while let b = try ch.readInbound(as: ByteBuffer.self) { plain += b.readableBytesView }
            }
            return String(decoding: plain, as: UTF8.self)
        }
    }

    func tunnel(_ proxy: EgressProxy, host: String) throws -> GuestTLS {
        let fd = open(proxy, header: "DOZ1 P\nCONNECT \(host):443 HTTP/1.1\r\nHost: \(host):443\r\n\r\n")
        var got: [UInt8] = []
        var b: UInt8 = 0
        while !String(decoding: got, as: UTF8.self).hasSuffix("\r\n\r\n"), read(fd, &b, 1) == 1 { got.append(b) }
        XCTAssertTrue(String(decoding: got, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        return try GuestTLS(fd: fd, host: host, ca: try XCTUnwrap(proxy.ca).certificatePEM)
    }

    func testDecryptedTunnelRefusesAPlaceholderForAnotherHost() throws {
        let proxy = try EgressProxy(policy: NetworkPolicy(rules: [EgressRule(host: "api.anthropic.com"), EgressRule(host: "api.github.test")]),
                                    ca: try SandboxCA.generate(sandbox: "t"))
        proxy.vault.set(.anthropic, secret: "sk-REAL")
        proxy.vault.set(CredentialBinding(id: "gh", hosts: ["api.github.test"], header: .bearer, environmentVariable: "GH_TOKEN"), secret: "ghp_REAL")
        let anthropicPlaceholder = try XCTUnwrap(proxy.vault.mint("anthropic"))
        // The guest's TLS handshake succeeds against the sandbox CA (a leaf for exactly this host) …
        let g = try tunnel(proxy, host: "api.github.test")
        defer { close(g.fd) }
        // … and the anthropic placeholder sent to GitHub is refused before any upstream is contacted.
        try g.send("GET /user HTTP/1.1\r\nHost: api.github.test\r\nx-api-key: \(anthropicPlaceholder)\r\n\r\n")
        let reply = try g.receiveAll()
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403"), reply)
        XCTAssertTrue(reply.contains("credential placeholder"))
        XCTAssertFalse(reply.contains("REAL"))
        let r = try XCTUnwrap(waitForRecord(proxy.log) { $0.kind == .http })
        XCTAssertTrue(r.decrypted)
        XCTAssertEqual(r.verdict, .denied)
        XCTAssertTrue(r.credential?.hasPrefix("rejected") == true)
        XCTAssertEqual(r.path, "/user")
    }

    func testDecryptedTunnelEnforcesMethodRules() throws {
        let proxy = try EgressProxy(policy: NetworkPolicy(rules: [EgressRule(host: "api.github.test", methods: ["GET"])]),
                                    ca: try SandboxCA.generate(sandbox: "t"))
        let g = try tunnel(proxy, host: "api.github.test")
        defer { close(g.fd) }
        try g.send("DELETE /repos/a/b HTTP/1.1\r\nHost: api.github.test\r\nContent-Length: 0\r\n\r\n")
        let reply = try g.receiveAll()
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403"), reply)
        XCTAssertTrue(reply.contains("X-Sandbox-Policy: denied"))
        let r = try XCTUnwrap(waitForRecord(proxy.log) { $0.method == "DELETE" })
        XCTAssertEqual(r.verdict, .denied)
    }

    func testInspectionWithoutACAIsDenied() throws {
        let proxy = try EgressProxy(policy: NetworkPolicy(rules: [EgressRule(host: "api.github.test", methods: ["GET"])]), ca: nil)
        let fd = open(proxy, header: "DOZ1 P\nCONNECT api.github.test:443 HTTP/1.1\r\n\r\n")
        defer { close(fd) }
        XCTAssertTrue(readAll(fd).hasPrefix("HTTP/1.1 403"))
    }

    func testGuestEnvironmentAndSetupScript() throws {
        let proxy = try EgressProxy(policy: .agent, ca: try SandboxCA.generate(sandbox: "t"))
        let e = proxy.guestEnvironment
        XCTAssertEqual(e["HTTPS_PROXY"], "http://127.0.0.1:3128")
        XCTAssertEqual(e["no_proxy"], "localhost,127.0.0.1,::1")
        XCTAssertEqual(e["NODE_EXTRA_CA_CERTS"], EgressProxy.guestCAPath)
        XCTAssertEqual(e["GIT_SSL_CAINFO"], EgressProxy.guestCABundlePath)
        XCTAssertNil(try EgressProxy(policy: .agent, ca: nil).guestEnvironment["NODE_EXTRA_CA_CERTS"])
        let s = EgressProxy.guestSetupScript(withCA: true)
        XCTAssertTrue(s.hasSuffix("/usr/local/bin/doznet up -p 5800"))
        XCTAssertTrue(s.contains("/usr/local/share/ca-certificates/"))
        XCTAssertFalse(EgressProxy.guestSetupScript(withCA: false).contains("ca-certificates"))
    }

    func testDoznetResourceIsBundled() {
        XCTAssertNotNil(DoznetBinary.locate())
    }

    // MARK: 599i — Codex's renewal of a ChatGPT sign-in is answered here, never forwarded

    func codexProxy() throws -> (EgressProxy, String) {
        // Policy: Codex's model hosts only — auth.openai.com is NOT allowed (the renewal is answered anyway).
        let proxy = try EgressProxy(policy: NetworkPolicy(rules: [EgressRule(host: "chatgpt.com")]), ca: try SandboxCA.generate(sandbox: "t"))
        proxy.vault.set(.chatgpt, secret: "ACCESS-REAL")
        let ph = try XCTUnwrap(proxy.vault.mintForFile("chatgpt"))
        let vault = proxy.vault
        proxy.chatgptRenewal = EgressProxy.ChatGPTRenewal { body in
            guard let t = OpenAIAccess.refreshToken(inRenewalBody: body), t.hasPrefix(CredentialVault.placeholderPrefix) else { return nil }
            guard vault.binding(ofPlaceholder: t) == "chatgpt" else {
                return OpenAIAccess.refreshAnswer(placeholder: t, guestIDToken: nil, problem: "not this sandbox's sign-in")
            }
            return OpenAIAccess.refreshAnswer(placeholder: t, guestIDToken: "h.p.ZG96LXVuc2lnbmVk", problem: nil)
        }
        return (proxy, ph)
    }

    func testCodexsRenewalIsAnsweredOnTheMacWithTheSamePlaceholder() throws {
        let (proxy, ph) = try codexProxy()
        let g = try tunnel(proxy, host: "auth.openai.com")
        defer { close(g.fd) }
        let body = #"{"client_id":"app_EMoamEEZ73f0CkXaXp7hrann","grant_type":"refresh_token","refresh_token":"\#(ph)"}"#
        try g.send("POST /oauth/token HTTP/1.1\r\nHost: auth.openai.com\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body)
        let reply = try g.receiveAll()
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200"), reply)
        XCTAssertTrue(reply.contains("\"access_token\":\"\(ph)\""))
        XCTAssertTrue(reply.contains("\"refresh_token\":\"\(ph)\""))
        XCTAssertFalse(reply.contains("ACCESS-REAL"), "the real token never goes to the guest")
        let r = try XCTUnwrap(waitForRecord(proxy.log) { $0.path == "/oauth/token" })
        XCTAssertEqual(r.verdict, .allowed)
        XCTAssertEqual(r.credential, "answered chatgpt renewal (the Mac renews the sign-in)")
        XCTAssertEqual(r.bytesUp, 0, "nothing went upstream")
    }

    func testARenewalWithAnotherPlaceholderIsRefusedAndOneWithoutIsJudgedByThePolicy() throws {
        let (proxy, _) = try codexProxy()
        proxy.vault.set(.openai, secret: "sk-REAL")
        let other = try XCTUnwrap(proxy.vault.mint("openai"))
        let g = try tunnel(proxy, host: "auth.openai.com")
        defer { close(g.fd) }
        let body = #"{"grant_type":"refresh_token","refresh_token":"\#(other)"}"#
        try g.send("POST /oauth/token HTTP/1.1\r\nHost: auth.openai.com\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body)
        let reply = try g.receiveAll()
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 401"), reply)
        XCTAssertTrue(reply.contains("not this sandbox's sign-in"))
        // A renewal that carries no Dozer placeholder (a login made inside the sandbox): the policy, which denies it.
        let g2 = try tunnel(proxy, host: "auth.openai.com")
        defer { close(g2.fd) }
        let own = #"{"grant_type":"refresh_token","refresh_token":"rt_their_own"}"#
        try g2.send("POST /oauth/token HTTP/1.1\r\nHost: auth.openai.com\r\nContent-Length: \(own.utf8.count)\r\n\r\n" + own)
        let reply2 = try g2.receiveAll()
        XCTAssertTrue(reply2.hasPrefix("HTTP/1.1 403"), reply2)
        XCTAssertTrue(reply2.contains("X-Sandbox-Policy: denied"))
        // Any other request to auth.openai.com: the policy as usual.
        let g3 = try tunnel(proxy, host: "auth.openai.com")
        defer { close(g3.fd) }
        try g3.send("GET /oauth/authorize HTTP/1.1\r\nHost: auth.openai.com\r\n\r\n")
        XCTAssertTrue(try g3.receiveAll().hasPrefix("HTTP/1.1 403"))
    }

    func testWithoutASignInAuthOpenAIComIsNotReachedAtAll() throws {
        let proxy = try EgressProxy(policy: NetworkPolicy(rules: [EgressRule(host: "chatgpt.com")]), ca: try SandboxCA.generate(sandbox: "t"))
        let fd = open(proxy, header: "DOZ1 P\nCONNECT auth.openai.com:443 HTTP/1.1\r\nHost: auth.openai.com:443\r\n\r\n")
        defer { close(fd) }
        XCTAssertTrue(readAll(fd).hasPrefix("HTTP/1.1 403"))
    }

    func testAnUnusableSignInIsRefusedInOpenAIsShape() throws {
        let proxy = try EgressProxy(policy: NetworkPolicy(rules: [EgressRule(host: "chatgpt.com")]), ca: try SandboxCA.generate(sandbox: "t"))
        proxy.vault.set(.chatgpt, secret: nil, expiresAt: nil, environment: [:], notice: "the account x has no OpenAI account now")
        let ph = try XCTUnwrap(proxy.vault.mintForFile("chatgpt"))
        let g = try tunnel(proxy, host: "chatgpt.com")
        defer { close(g.fd) }
        try g.send("POST /backend-api/codex/responses HTTP/1.1\r\nHost: chatgpt.com\r\nAuthorization: Bearer \(ph)\r\nContent-Length: 0\r\n\r\n")
        let reply = try g.receiveAll()
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 401"), reply)
        XCTAssertTrue(reply.contains("\"message\":\"doz: the account x has no OpenAI account now\""), reply)
        XCTAssertFalse(reply.contains("authentication_error"), "not Anthropic's shape on OpenAI's host")
    }
}
