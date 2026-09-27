import Security
import XCTest
@testable import SnoozeContainerKit

/// 580 — placeholders (issue, revoke, wrong host, unknown), header rewrite fidelity, the request
/// reader, the per-sandbox CA, DNS answers, the connection log.
final class CredentialTests: XCTestCase {
    let secret = "sk-ant-REAL-SECRET-0123456789"

    func vault() -> CredentialVault {
        let v = CredentialVault()
        v.set(.anthropic, secret: secret)
        v.set(CredentialBinding(id: "github", hosts: ["api.github.com"], header: .bearer, environmentVariable: "GH_TOKEN"), secret: "ghp_REAL")
        return v
    }

    func head(_ s: String) -> [UInt8] { Array(s.replacingOccurrences(of: "\n", with: "\r\n").utf8) }
    func text(_ b: [UInt8]?) -> String { String(decoding: b ?? [], as: UTF8.self) }

    func testPlaceholdersAreFreshPerIssueAndRevocable() throws {
        let v = vault()
        let a = try XCTUnwrap(v.mint("anthropic")), b = try XCTUnwrap(v.mint("anthropic"))
        XCTAssertNotEqual(a, b, "every session gets its own placeholder")
        XCTAssertTrue(a.hasPrefix("snz_cred_"))
        XCTAssertFalse(a.contains(secret))
        XCTAssertNil(v.mint("nope"))
        let env = v.sessionEnvironment()
        XCTAssertEqual(Set(env.keys), ["ANTHROPIC_API_KEY", "GH_TOKEN"])
        XCTAssertFalse(env.values.contains { $0.contains("REAL") }, "the guest only ever sees placeholders")
        v.revokeAll()
        XCTAssertEqual(v.livePlaceholderCount, 0)
        guard case .reject = v.rewrite(head: head("POST /v1/messages HTTP/1.1\nHost: api.anthropic.com\nx-api-key: \(a)\n\n"), host: "api.anthropic.com") else {
            return XCTFail("a revoked placeholder is refused")
        }
    }

    /// Two bindings on one host (an API key and a Claude login): the request's own placeholder
    /// decides which secret goes in, and in which header.
    func testTwoBindingsOnOneHostSwapByTheCarriedPlaceholder() throws {
        let v = vault()
        v.set(.claudeOAuth, secret: "sk-ant-oat01-REAL-ACCESS")
        let oauth = try XCTUnwrap(v.mint(CredentialBinding.claudeOAuth.id))
        let d = v.rewrite(head: head("POST /v1/messages HTTP/1.1\nHost: api.anthropic.com\nAuthorization: Bearer \(oauth)\n\n"),
                          host: "api.anthropic.com")
        XCTAssertEqual(d, .swapped(head("POST /v1/messages HTTP/1.1\nHost: api.anthropic.com\nAuthorization: Bearer sk-ant-oat01-REAL-ACCESS\n\n"),
                                   binding: "claude-oauth"))
        let key = try XCTUnwrap(v.mint(CredentialBinding.anthropic.id))
        let k = v.rewrite(head: head("POST /v1/messages HTTP/1.1\nHost: api.anthropic.com\nx-api-key: \(key)\n\n"), host: "api.anthropic.com")
        XCTAssertEqual(k, .swapped(head("POST /v1/messages HTTP/1.1\nHost: api.anthropic.com\nx-api-key: \(secret)\n\n"), binding: "anthropic"))
        // Only the binding holding a secret gets a placeholder in a session's environment.
        v.set(.anthropic, secret: nil)
        XCTAssertEqual(Set(v.sessionEnvironment().keys), ["CLAUDE_CODE_OAUTH_TOKEN", "GH_TOKEN"])
    }

    func testSwapIsByteExact() throws {
        let v = vault()
        let t = try XCTUnwrap(v.mint("anthropic"))
        let raw = head("POST /v1/messages?beta=true HTTP/1.1\nHost: api.anthropic.com\nX-Api-Key:   \(t)  \ncontent-type: application/json\nanthropic-version: 2023-06-01\n\n")
        let d = v.rewrite(head: raw, host: "api.anthropic.com")
        guard case .swapped(let out, "anthropic") = d else { return XCTFail("\(d)") }
        let expected = text(raw).replacingOccurrences(of: t, with: secret)
        XCTAssertEqual(text(out), expected, "only the placeholder's bytes change — case, spacing and order kept")
    }

    func testInjectWhenNoHeader() {
        let v = vault()
        let raw = head("GET /v1/models HTTP/1.1\nHost: api.anthropic.com\nAccept: */*\n\n")
        guard case .injected(let out, "anthropic") = v.rewrite(head: raw, host: "api.anthropic.com") else { return XCTFail() }
        XCTAssertEqual(text(out), text(raw).replacingOccurrences(of: "Accept: */*\r\n", with: "Accept: */*\r\nx-api-key: \(secret)\r\n"))
        guard case .injected(let gh, "github") = v.rewrite(head: head("GET /user HTTP/1.1\nHost: api.github.com\n\n"), host: "api.github.com") else { return XCTFail() }
        XCTAssertTrue(text(gh).contains("Authorization: Bearer ghp_REAL\r\n"))
    }

    func testWrongHostAndUnknownPlaceholdersAreRejected() throws {
        let v = vault()
        let t = try XCTUnwrap(v.mint("anthropic"))
        // The anthropic placeholder sent to GitHub (a host the proxy decrypts).
        guard case .reject(let why) = v.rewrite(head: head("GET / HTTP/1.1\nHost: api.github.com\nAuthorization: Bearer \(t)\n\n"), host: "api.github.com") else {
            return XCTFail("wrong host must be refused")
        }
        XCTAssertTrue(why.contains("api.github.com"))
        // Anywhere in the head, not only the auth header.
        guard case .reject = v.rewrite(head: head("GET /?k=\(t) HTTP/1.1\nHost: api.github.com\n\n"), host: "api.github.com") else { return XCTFail() }
        guard case .reject = v.rewrite(head: head("GET / HTTP/1.1\nHost: api.anthropic.com\nx-api-key: snz_cred_deadbeef\n\n"), host: "api.anthropic.com") else {
            return XCTFail("an unknown placeholder is refused")
        }
        // A binding without a secret on this Mac.
        let empty = CredentialVault()
        empty.set(.anthropic, secret: nil)
        let e = try XCTUnwrap(empty.mint("anthropic"))
        guard case .reject = empty.rewrite(head: head("GET / HTTP/1.1\nHost: api.anthropic.com\nx-api-key: \(e)\n\n"), host: "api.anthropic.com") else { return XCTFail() }
    }

    func testToolsOwnCredentialPassesThroughUntouched() {
        let v = vault()
        let raw = head("GET / HTTP/1.1\nHost: api.anthropic.com\nx-api-key: sk-ant-the-users-own\n\n")
        XCTAssertEqual(v.rewrite(head: raw, host: "api.anthropic.com"), .passThrough(raw))
        let other = head("GET / HTTP/1.1\nHost: example.com\n\n")
        XCTAssertEqual(v.rewrite(head: other, host: "example.com"), .passThrough(other), "no binding → untouched, nothing injected")
        XCTAssertEqual(v.boundHosts, ["api.anthropic.com", "api.github.com"])
    }

    func testRequestReaderSplitsHeadsAndBodies() {
        var r = HTTPRequestReader()
        let a = head("POST /a HTTP/1.1\nContent-Length: 5\n\n")
        let b = head("POST /b HTTP/1.1\nTransfer-Encoding: chunked\n\n")
        let chunked = Array("3\r\nabc\r\n0\r\nX-T: 1\r\n\r\n".utf8)
        let c = head("GET /ws HTTP/1.1\nUpgrade: websocket\n\n")
        let all = a + Array("hello".utf8) + b + chunked + c + [1, 2, 3]
        var events: [HTTPRequestReader.Event] = []
        for byte in all { events += r.feed([byte]) }      // worst case: one byte at a time
        let heads = events.compactMap { if case .head(let h) = $0 { return h } else { return nil } }
        XCTAssertEqual(heads, [a, b, c])
        let body = events.flatMap { e -> [UInt8] in if case .body(let x) = e { return x } else { return [] } }
        XCTAssertEqual(body, Array("hello".utf8) + chunked, "chunk framing passes through unchanged")
        let raw = events.flatMap { e -> [UInt8] in if case .raw(let x) = e { return x } else { return [] } }
        XCTAssertEqual(raw, [1, 2, 3], "after an Upgrade, bytes are opaque")
        var m = HTTPRequestReader()
        XCTAssertEqual(m.feed(Array("NOT HTTP\r\n\r\n".utf8)).last, .malformed("unparseable request head"))
    }

    func testHeadPathDropsTheQuery() throws {
        let h = try XCTUnwrap(HTTPHead(head("GET /v1/x?key=secret&a=b HTTP/1.1\nHost: a\n\n")))
        XCTAssertEqual(h.pathOnly, "/v1/x")
        XCTAssertEqual(try XCTUnwrap(HTTPHead(head("GET http://h.test/p?q=1 HTTP/1.1\n\n"))).pathOnly, "/p")
    }

    func testCAAndLeaves() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ca-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ca = try SandboxCA.loadOrCreate(in: dir, sandbox: "t1")
        let again = try SandboxCA.loadOrCreate(in: dir, sandbox: "t1")
        XCTAssertEqual(ca.fingerprint, again.fingerprint, "the CA is kept in the sandbox's directory")
        let keyPerms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("egress-ca-key.pem").path)[.posixPermissions] as? Int
        XCTAssertEqual(keyPerms, 0o600)
        XCTAssertTrue(ca.certificatePEM.hasPrefix("-----BEGIN CERTIFICATE-----"))
        let leaf = try ca.leaf(for: "API.Anthropic.com")
        XCTAssertTrue(leaf.keyPEM.contains("PRIVATE KEY"))
        XCTAssertEqual(try ca.leaf(for: "api.anthropic.com").certificatePEM, leaf.certificatePEM, "cached per host")
        // The leaf verifies against the CA as the only anchor (Security.framework, as a guest would).
        XCTAssertTrue(try Self.verifies(leaf: leaf.certificatePEM, ca: ca.certificatePEM, host: "api.anthropic.com"))
        XCTAssertFalse(try Self.verifies(leaf: leaf.certificatePEM, ca: ca.certificatePEM, host: "example.com"), "SAN is exactly the host")
        let other = try SandboxCA.generate(sandbox: "t2")
        XCTAssertFalse(try Self.verifies(leaf: leaf.certificatePEM, ca: other.certificatePEM, host: "api.anthropic.com"), "per-sandbox trust")
    }

    static func verifies(leaf: String, ca: String, host: String) throws -> Bool {
        func der(_ pem: String) -> Data { Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined())! }
        let l = SecCertificateCreateWithData(nil, der(leaf) as CFData)!, c = SecCertificateCreateWithData(nil, der(ca) as CFData)!
        var trust: SecTrust?
        SecTrustCreateWithCertificates([l] as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust)
        SecTrustSetAnchorCertificates(trust!, [c] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust!, true)
        return SecTrustEvaluateWithError(trust!, nil)
    }

    func testDNSMessages() throws {
        // id 0x1234, RD, one question: example.com A IN
        var q: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for l in ["example", "com"] { q.append(UInt8(l.count)); q += Array(l.utf8) }
        q += [0, 0, 1, 0, 1]
        let (name, type, end) = try XCTUnwrap(DNSMessage.question(q))
        XCTAssertEqual(name, "example.com"); XCTAssertEqual(type, 1); XCTAssertEqual(end, q.count)
        let r = DNSMessage.response(to: q, questionEnd: end, rcode: 0, answers: [0x5DB8_D822])
        XCTAssertEqual(Array(r[0..<2]), [0x12, 0x34])
        XCTAssertEqual(r[3] & 0x0f, 0)
        XCTAssertEqual(r[7], 1, "one answer")
        XCTAssertEqual(Array(r.suffix(4)), [0x5D, 0xB8, 0xD8, 0x22])
        let nx = DNSMessage.response(to: q, questionEnd: end, rcode: 3, answers: [])
        XCTAssertEqual(nx[3] & 0x0f, 3)
        XCTAssertNil(DNSMessage.question([1, 2, 3]))

        // Policy gating through the proxy itself (no network needed for a denied name).
        let proxy = try EgressProxy(policy: .locked, ca: nil)
        let denied = proxy.answer(q)
        XCTAssertFalse(denied.allowed)
        XCTAssertEqual(denied.bytes[3] & 0x0f, 3, "a denied name does not resolve")
        proxy.policy = NetworkPolicy(rules: [EgressRule(host: "example.com")])
        var aaaa = q; aaaa[aaaa.count - 3] = 28
        let v6 = proxy.answer(aaaa)
        XCTAssertTrue(v6.allowed)
        XCTAssertEqual(v6.bytes[7], 0, "no AAAA: the guest has no IPv6 path")
    }

    func testConnectionLogIsMetadataAndExports() {
        let log = ConnectionLog(capacity: 3)
        var r = ConnectionRecord(kind: .connect, host: "a.test", port: 443, verdict: .allowed, rule: "allow a.test", open: true)
        log.upsert(r)
        r.bytesDown = 10; r.open = false
        log.upsert(r)
        XCTAssertEqual(log.records.count, 1, "updated in place")
        XCTAssertEqual(log.records[0].bytesDown, 10)
        for i in 0..<4 { log.upsert(ConnectionRecord(kind: .dns, host: "n\(i).test", verdict: .denied, rule: "default deny")) }
        XCTAssertEqual(log.records.count, 3, "bounded")
        XCTAssertEqual(log.deniedCount, 4)
        let lines = log.exportJSONLines()
        let back = ConnectionLog.parseJSONLines(lines)
        XCTAssertEqual(back.map(\.host), log.records.map(\.host))
        let keys = Set((try? JSONSerialization.jsonObject(with: Data(lines.split(separator: 10)[0])) as? [String: Any])?.keys.map { $0 } ?? [])
        XCTAssertFalse(keys.contains("body") || keys.contains("headers") || keys.contains("query"), "metadata only")
    }
}
