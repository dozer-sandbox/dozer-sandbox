import Security
import XCTest
@testable import DozerKit

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
        XCTAssertTrue(a.hasPrefix("doz_cred_"))
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
        guard case .reject = v.rewrite(head: head("GET / HTTP/1.1\nHost: api.anthropic.com\nx-api-key: doz_cred_deadbeef\n\n"), host: "api.anthropic.com") else {
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
        // 588: passed through byte-for-byte, and flagged (a fingerprint, never the value).
        guard case .foreign(let out, let f) = v.rewrite(head: raw, host: "api.anthropic.com") else { return XCTFail() }
        XCTAssertEqual(out, raw)
        XCTAssertEqual(f.header, "x-api-key")
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
        // 594 W29: the sandbox's own name — answered 127.0.1.1 even under `locked`, and not logged (no name).
        var own: [UInt8] = [0x00, 0x07, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        own.append(16); own += Array("claude-sandbox-3".utf8)
        own += [0, 0, 1, 0, 1]
        proxy.ownName = "Claude-Sandbox-3"
        let mine = proxy.answer(own)
        XCTAssertNil(mine.name, "never logged")
        XCTAssertEqual(mine.bytes[3] & 0x0f, 0)
        XCTAssertEqual(Array(mine.bytes.suffix(4)), [127, 0, 1, 1])
        XCTAssertFalse(proxy.answer(q).allowed, "any other name: still the policy")
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

    // MARK: 588 — foreign credentials, expiry, notices, persisted placeholders, session extras

    let oauthHost = "api.anthropic.com"
    let fakeOAuth = "sk-ant-oat01-" + String(repeating: "F", count: 95)
    let fakeKey = "sk-ant-api03-" + String(repeating: "K", count: 95)

    func loginVault(_ secret: String? = "sk-ant-oat01-HOST-HELD-ACCESS") -> CredentialVault {
        let v = CredentialVault()
        v.set(.anthropic, secret: nil)
        v.set(.claudeOAuth, secret: secret)
        return v
    }

    /// A guest's own `x-api-key` never gets our bearer token injected beside it (the 588 phase-1
    /// finding: the Mac's token was added next to a pasted API key) — and the reverse.
    func testNeverInjectBesideTheGuestsOwnCredential() {
        let v = loginVault()
        let withKey = head("POST /v1/messages HTTP/1.1\nHost: api.anthropic.com\nx-api-key: \(fakeKey)\n\n")
        guard case .foreign(let out, let f) = v.rewrite(head: withKey, host: oauthHost) else { return XCTFail() }
        XCTAssertEqual(out, withKey, "untouched: no Authorization added")
        XCTAssertFalse(text(out).contains("HOST-HELD"))
        XCTAssertEqual(f.kind, "api-key")
        XCTAssertEqual(f.prefix, "sk-ant-api03")
        let k = CredentialVault()
        k.set(.claudeOAuth, secret: nil)
        k.set(.anthropic, secret: "sk-ant-api03-HOST-HELD-KEY")
        let withBearer = head("POST /v1/messages HTTP/1.1\nHost: api.anthropic.com\nAuthorization: Bearer \(fakeOAuth)\n\n")
        guard case .foreign(let out2, let f2) = k.rewrite(head: withBearer, host: oauthHost) else { return XCTFail() }
        XCTAssertEqual(out2, withBearer, "no x-api-key added beside a guest bearer token")
        XCTAssertEqual(f2.kind, "oauth")
        XCTAssertEqual(f2.header, "authorization")
    }

    func testForeignSightingIsAFingerprintSeenOnce() throws {
        let v = loginVault()
        let seen = Locked<[ForeignCredential]>([])
        v.onForeign = { f in seen.mutate { $0.append(f) } }
        let raw = head("POST /v1/messages HTTP/1.1\nHost: api.anthropic.com\nAuthorization: Bearer \(fakeOAuth)\n\n")
        _ = v.rewrite(head: raw, host: oauthHost)
        _ = v.rewrite(head: raw, host: oauthHost)
        XCTAssertEqual(seen.value.count, 1, "an event per fingerprint, not per request")
        let s = try XCTUnwrap(v.foreignSightings.first)
        XCTAssertEqual(s.requests, 2)
        XCTAssertEqual(s.fingerprint.count, 12)
        XCTAssertTrue(s.fingerprint.allSatisfy(\.isHexDigit))
        XCTAssertEqual(s.fingerprint, CredentialFingerprint.of("Bearer " + fakeOAuth))
        XCTAssertEqual(s.prefix, "sk-ant-oat01")
        let json = String(decoding: try JSONEncoder().encode(v.foreignSightings), as: UTF8.self) + s.label
        XCTAssertFalse(json.contains(String(repeating: "F", count: 20)), "never the value")
        // A name the owner holds it under.
        v.setFingerprintLabels([CredentialFingerprint.of(fakeKey): "work"])
        guard case .foreign(_, let named) = v.rewrite(head: head("GET / HTTP/1.1\nHost: api.anthropic.com\nx-api-key: \(fakeKey)\n\n"), host: oauthHost) else { return XCTFail() }
        XCTAssertEqual(named.matches, "work")
    }

    func testStrictRefusesTheGuestsOwnCredentialAndStillSwapsOurs() throws {
        let v = loginVault()
        v.foreignPolicy = .strict
        v.strictNotice = "pinned — fp {fp}"
        let raw = head("POST /v1/messages HTTP/1.1\nHost: api.anthropic.com\nAuthorization: Bearer \(fakeOAuth)\n\n")
        guard case .refuse(403, let msg) = v.rewrite(head: raw, host: oauthHost) else { return XCTFail() }
        XCTAssertEqual(msg, "pinned — fp \(CredentialFingerprint.of(fakeOAuth))")
        let t = try XCTUnwrap(v.mint(CredentialBinding.claudeOAuth.id))
        guard case .swapped(let out, "claude-oauth") = v.rewrite(head: head("POST /v1/messages HTTP/1.1\nHost: api.anthropic.com\nAuthorization: Bearer \(t)\n\n"), host: oauthHost) else { return XCTFail() }
        XCTAssertTrue(text(out).contains("Bearer sk-ant-oat01-HOST-HELD-ACCESS"))
    }

    func testAConnectionThatCarriedTheGuestsCredentialGetsNothingInjected() {
        let v = loginVault()
        let bare = head("POST /api/event_logging/v2/batch HTTP/1.1\nHost: api.anthropic.com\n\n")
        XCTAssertEqual(v.rewrite(head: bare, host: oauthHost, inject: false), .passThrough(bare))
        guard case .injected = v.rewrite(head: bare, host: oauthHost) else { return XCTFail("injection is still the default") }
    }

    func testAnExpiredSecretIsReReadOnceThenRefusedWithTheNotice() throws {
        let v = loginVault(nil)
        let past = Date().addingTimeInterval(-60)
        v.set(.claudeOAuth, secret: "sk-ant-oat01-OLD", expiresAt: past, environment: [:], notice: "renew it on the Mac")
        let t = try XCTUnwrap(v.mint(CredentialBinding.claudeOAuth.id))
        let raw = head("POST /v1/messages HTTP/1.1\nHost: api.anthropic.com\nAuthorization: Bearer \(t)\n\n")
        let calls = Locked(0)
        // No renewal: refused with the notice, 401.
        v.onStale = { _ in calls.mutate { $0 += 1 } }
        XCTAssertEqual(v.rewrite(head: raw, host: oauthHost), .refuse(401, "renew it on the Mac"))
        XCTAssertEqual(calls.value, 1, "one re-read per request")
        // The owner renews it during the re-read: the request goes out with the new secret.
        v.onStale = { [v] id in v.set(.claudeOAuth, secret: "sk-ant-oat01-NEW", expiresAt: Date().addingTimeInterval(3600), environment: [:], notice: nil); _ = id }
        guard case .swapped(let out, _) = v.rewrite(head: raw, host: oauthHost) else { return XCTFail() }
        XCTAssertTrue(text(out).contains("sk-ant-oat01-NEW"))
        // An upstream 401 asks for a re-read too.
        v.onStale = { _ in calls.mutate { $0 += 10 } }
        v.upstreamRejected(CredentialBinding.claudeOAuth.id)
        XCTAssertEqual(calls.value, 11)
    }

    func testANoticeExplainsAMissingCredential() throws {
        let v = loginVault(nil)
        v.set(.claudeOAuth, secret: nil, expiresAt: nil, environment: [:], notice: "the Mac signed out")
        let t = try XCTUnwrap(v.mint(CredentialBinding.claudeOAuth.id))
        XCTAssertEqual(v.rewrite(head: head("GET / HTTP/1.1\nHost: api.anthropic.com\nAuthorization: Bearer \(t)\n\n"), host: oauthHost),
                       .refuse(401, "the Mac signed out"))
        XCTAssertEqual(v.rewrite(head: head("GET / HTTP/1.1\nHost: api.anthropic.com\n\n"), host: oauthHost), .refuse(401, "the Mac signed out"))
        XCTAssertTrue(v.boundHosts.contains(oauthHost), "still decrypted, so the reason can be given")
        // Without a notice the leak guard's 403 says what to do.
        let w = loginVault(nil)
        let u = try XCTUnwrap(w.mint(CredentialBinding.claudeOAuth.id))
        guard case .reject(let why) = w.rewrite(head: head("GET / HTTP/1.1\nHost: api.anthropic.com\nAuthorization: Bearer \(u)\n\n"), host: oauthHost) else { return XCTFail() }
        XCTAssertTrue(why.contains("no secret on this Mac"))
    }

    /// D8: a new vault given the old one's placeholder HASHES honours the old placeholders.
    func testPlaceholderHashesCarryPlaceholdersToANewVault() throws {
        let a = loginVault()
        let changed = Locked(0)
        a.onPlaceholdersChanged = { changed.mutate { $0 += 1 } }
        let t = try XCTUnwrap(a.mint(CredentialBinding.claudeOAuth.id))
        XCTAssertEqual(changed.value, 1)
        let hashes = a.placeholderHashes
        XCTAssertEqual(hashes.count, 1)
        XCTAssertFalse(hashes.keys.contains(t), "hashes, never the placeholder")
        XCTAssertEqual(hashes.values.first, "claude-oauth")
        let b = loginVault("sk-ant-oat01-NEW-HOST")
        let raw = head("POST /v1/messages HTTP/1.1\nHost: api.anthropic.com\nAuthorization: Bearer \(t)\n\n")
        guard case .reject = b.rewrite(head: raw, host: oauthHost) else { return XCTFail("unknown to a fresh vault") }
        b.restorePlaceholderHashes(hashes)
        guard case .swapped(let out, _) = b.rewrite(head: raw, host: oauthHost) else { return XCTFail() }
        XCTAssertTrue(text(out).contains("NEW-HOST"))
        b.revokeAll()
        XCTAssertTrue(b.placeholderHashes.isEmpty)
        guard case .reject = b.rewrite(head: raw, host: oauthHost) else { return XCTFail("revoked") }
    }

    func testSessionExtrasTravelWithTheSecretOnly() {
        let v = loginVault(nil)
        v.set(.claudeOAuth, secret: "sk-ant-oat01-X", expiresAt: nil,
              environment: ["CLAUDE_CODE_SUBSCRIPTION_TYPE": "max", "CLAUDE_CODE_RATE_LIMIT_TIER": "default_claude_max_20x"], notice: nil)
        let env = v.sessionEnvironment()
        XCTAssertEqual(env["CLAUDE_CODE_SUBSCRIPTION_TYPE"], "max")
        XCTAssertEqual(env["CLAUDE_CODE_RATE_LIMIT_TIER"], "default_claude_max_20x")
        XCTAssertTrue(env["CLAUDE_CODE_OAUTH_TOKEN"]?.hasPrefix("doz_cred_") == true)
        XCTAssertFalse(env.values.contains { $0.contains("sk-ant") })
        v.set(.claudeOAuth, secret: nil, expiresAt: nil, environment: ["CLAUDE_CODE_SUBSCRIPTION_TYPE": "max"], notice: "gone")
        XCTAssertNil(v.sessionEnvironment()["CLAUDE_CODE_SUBSCRIPTION_TYPE"])
    }

    func testFingerprintsAndKinds() {
        XCTAssertEqual(CredentialFingerprint.kind("Bearer sk-ant-oat01-abc"), "oauth")
        XCTAssertEqual(CredentialFingerprint.kind("sk-ant-api03-abc"), "api-key")
        XCTAssertEqual(CredentialFingerprint.kind("sk-ant-admin01-abc"), "admin-key")
        XCTAssertEqual(CredentialFingerprint.kind("ghp_x"), "other")
        XCTAssertEqual(CredentialFingerprint.prefix("sk-ant-admin01-abcdef"), "sk-ant-admin0")
        XCTAssertEqual(CredentialFingerprint.prefix("ghp_x"), "?")
        XCTAssertEqual(CredentialFingerprint.of("Bearer abc"), CredentialFingerprint.of("abc"))
    }

    func testTheProxysOwnAnswerIsAnAnthropicShapedError() throws {
        let r = EgressProxy.refusal(401, "this Mac's Claude login expired at 04:59")
        let s = String(decoding: r, as: UTF8.self)
        XCTAssertTrue(s.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        let body = try XCTUnwrap(s.components(separatedBy: "\r\n\r\n").last)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let err = try XCTUnwrap(obj["error"] as? [String: Any])
        XCTAssertEqual(err["type"] as? String, "authentication_error")
        XCTAssertEqual(err["message"] as? String, "doz: this Mac's Claude login expired at 04:59")
        XCTAssertTrue(String(decoding: EgressProxy.refusal(403, "x"), as: UTF8.self).contains("permission_error"))
    }
}

/// A value shared with a @Sendable closure in a test.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}
