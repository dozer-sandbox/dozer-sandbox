import Foundation
import DozerKit
import XCTest
@testable import DozerCLI
@testable import DozerHost

// 588 — Claude login for sandboxes, without a VM, a real keychain or the network: a fake keychain,
// a fake verifier, a fake `claude`, a fake clock (explicit `now:`) and a fake keep-alive runner.
// Every token here is a made-up string.

final class FakeKeychain: KeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private var _reads: [String] = []
    private var _writes: [String] = []
    var lockedServices: Set<String> = []

    func put(_ service: String, _ value: String?) { lock.lock(); items[service] = value; lock.unlock() }
    func get(_ service: String) -> String? { lock.lock(); defer { lock.unlock() }; return items[service] }
    var reads: [String] { lock.lock(); defer { lock.unlock() }; return _reads }
    var writes: [String] { lock.lock(); defer { lock.unlock() }; return _writes }

    func read(service: String, account: String?) -> KeychainRead {
        lock.lock(); defer { lock.unlock() }
        _reads.append(service)
        if lockedServices.contains(service) { return .locked }
        return items[service].map(KeychainRead.found) ?? .absent
    }
    /// 599i: the real keychain's per-item limit — a too-long secret fails here as on a Mac.
    var failWrites: Set<String> = []
    func write(service: String, account: String, secret: String) throws {
        try Keychain.checkSecretSize(secret, service: service)
        if lock.withLock({ failWrites.contains(service) }) { throw HostError(.failed, "could not write the keychain item \(service)") }
        lock.lock(); items[service] = secret; _writes.append(service); lock.unlock()
    }
    func delete(service: String, account: String) throws { lock.lock(); items[service] = nil; lock.unlock() }
    func items(servicePrefix: String) -> [KeychainItemInfo] {
        lock.lock(); defer { lock.unlock() }
        return items.keys.filter { $0.hasPrefix(servicePrefix) }.sorted().map { KeychainItemInfo(service: $0, account: "u", modified: nil) }
    }
}

struct FakeVerifier: AccountVerifying {
    var answer: AccountVerification
    func verify(kind: AccountKind, secret: String) async -> AccountVerification { answer }
}

final class FakeRunner: KeepaliveRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _runs: [(String, [String], [String: String])] = []
    var onRun: () -> Void = {}
    var runs: [(String, [String], [String: String])] { lock.lock(); defer { lock.unlock() }; return _runs }
    func run(binary: String, arguments: [String], environment: [String: String], directory: URL, timeout: TimeInterval) -> Int32 {
        lock.lock(); _runs.append((binary, arguments, environment)); lock.unlock()
        onRun()
        return 0
    }
}

/// A Claude Code keychain item (the current shape unless `old`).
func claudeItem(_ access: String, expires: Date?, plan: String? = "max", tier: String? = "default_claude_max_20x", old: Bool = false) -> String {
    var o: [String: Any] = ["accessToken": access, "refreshToken": "sk-ant-ort01-NEVER-USED", "scopes": ["user:inference", "user:profile"]]
    if let e = expires { o["expiresAt"] = e.timeIntervalSince1970 * 1000 }
    if let plan { o["subscriptionType"] = plan }
    if let tier { o["rateLimitTier"] = tier }
    if old { o["clientId"] = "x" } else { o["refreshTokenExpiresAt"] = Date().addingTimeInterval(86_400 * 26).timeIntervalSince1970 * 1000 }
    return String(decoding: try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": o]), as: UTF8.self)
}

final class AccountTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    let keychain = FakeKeychain()
    let svc = ClaudeLogin.baseService

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-acct-\(UUID().uuidString.prefix(8))")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        signIn(as: "acct-1", email: "owner@example.com")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func signIn(as uuid: String, email: String) {
        let o: [String: Any] = ["oauthAccount": ["accountUuid": uuid, "organizationUuid": "org-1", "emailAddress": email, "organizationName": "Org"]]
        try! JSONSerialization.data(withJSONObject: o).write(to: home.appendingPathComponent(".claude.json"))
    }

    func services(binary: String? = "/fake/claude", verifier: AccountVerification = .verified, runner: FakeRunner = FakeRunner(),
                  running: Bool = false) -> CredentialServices {
        CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: verifier), claudeBinary: { binary }, home: home,
                           keepaliveRunner: runner, isClaudeRunning: { running }, watchInterval: .seconds(3600))
    }

    func core(_ s: CredentialServices? = nil) async -> HostCore {
        let c = HostCore(store: DozerStore(root: root), readOnly: false, version: "test", services: s ?? services())
        await c.load()
        return c
    }

    @discardableResult
    func create(_ c: HostCore, _ name: String, account: String? = nil, image: String = "claude-code", network: String? = nil) async throws -> SandboxInfo {
        var r = HostRequest(.create, name: name)
        r.create = CreateOptions(image: image, network: network, account: account)
        let m = await c.handle(r)
        if let e = m.error { throw e }
        return try XCTUnwrap(m.result).decode(SandboxInfo.self)
    }

    func use(_ c: HostCore, _ sandbox: String, _ account: String) async -> HostMessage {
        var r = HostRequest(.accountUse, name: sandbox)
        r.account = account
        return await c.handle(r)
    }

    // MARK: the keychain item

    func testServiceNamePerConfigDirIsClaudeCodesRule() {
        XCTAssertEqual(ClaudeLogin.service(configDir: nil), "Claude Code-credentials")
        // sha256("/Users/someone/.claude") starts b38b2c3b (shasum).
        XCTAssertEqual(ClaudeLogin.service(configDir: "/Users/someone/.claude"), "Claude Code-credentials-b38b2c3b")
        // NFC first: a decomposed é names the same item as a composed one.
        XCTAssertEqual(ClaudeLogin.service(configDir: "/Users/e\u{301}/.claude"), ClaudeLogin.service(configDir: "/Users/\u{e9}/.claude"))
    }

    func testEveryObservedItemShapeParses() throws {
        let exp = Date(timeIntervalSince1970: 1_800_000_000)
        let current = try XCTUnwrap(ClaudeLogin.parse(claudeItem("sk-ant-oat01-A", expires: exp)))
        XCTAssertEqual(current.accessToken, "sk-ant-oat01-A")
        XCTAssertEqual(current.expiresAt, exp)
        XCTAssertNotNil(current.refreshTokenExpiresAt)
        XCTAssertEqual(current.sessionEnvironment, ["CLAUDE_CODE_SUBSCRIPTION_TYPE": "max", "CLAUDE_CODE_RATE_LIMIT_TIER": "default_claude_max_20x"])
        let old = try XCTUnwrap(ClaudeLogin.parse(claudeItem("sk-ant-oat01-B", expires: exp, old: true)))
        XCTAssertEqual(old.accessToken, "sk-ant-oat01-B")
        XCTAssertNil(old.refreshTokenExpiresAt)
        let hex = Data(claudeItem("sk-ant-oat01-C", expires: exp).utf8).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(ClaudeLogin.parse(hex)?.accessToken, "sk-ant-oat01-C")
        let noExpiry = try XCTUnwrap(ClaudeLogin.parse(claudeItem("sk-ant-oat01-D", expires: nil, plan: nil, tier: nil)))
        XCTAssertNil(noExpiry.expiresAt)
        XCTAssertEqual(noExpiry.sessionEnvironment, [:])
        XCTAssertNil(ClaudeLogin.parse("{\"something\":\"else\"}"))
    }

    func testKeychainDumpAttributesParse() {
        let dump = """
        keychain: "/Users/u/Library/Keychains/login.keychain-db"
        version: 512
        class: "genp"
        attributes:
            "acct"<blob>="u"
            "mdat"<timedate>=0x32303236303932363230353935335A00  "20260926205953Z\\000"
            "svce"<blob>="Claude Code-credentials"
        keychain: "/Users/u/Library/Keychains/login.keychain-db"
        class: "genp"
        attributes:
            "acct"<blob>="u"
            "svce"<blob>="Claude Code-credentials-560adfb8"
        keychain: "/Users/u/Library/Keychains/login.keychain-db"
        class: "inet"
        attributes:
            "svce"<blob>="Claude Code-credentials-not-generic"
        """
        let items = SystemKeychain.parseDump(dump, servicePrefix: "Claude Code-credentials")
        XCTAssertEqual(items.map(\.service), ["Claude Code-credentials", "Claude Code-credentials-560adfb8"])
        XCTAssertNotNil(items.first?.modified)
    }

    // MARK: host checks (acceptance 2 + 3: E1–E4)

    func testLoginStatusMessages() {
        let now = Date()
        var st = ClaudeLoginStatus.check(keychain: keychain, home: home, binary: { nil })
        XCTAssertEqual(st.problem(now: now)?.code, .notFound)
        XCTAssertTrue(st.problem(now: now)!.message.contains("isn't installed"), "E1")
        st = ClaudeLoginStatus.check(keychain: keychain, home: home, binary: { "/fake/claude" })
        XCTAssertTrue(st.problem(now: now)!.message.contains("not signed in"), "E2")
        keychain.put(ClaudeLogin.apiKeyService, "sk-ant-api03-CONSOLE")
        st = ClaudeLoginStatus.check(keychain: keychain, home: home, binary: { "/fake/claude" })
        XCTAssertEqual(st.state, .apiKey)
        XCTAssertTrue(st.problem(now: now)!.message.contains("API key, not a subscription"), "E3")
        keychain.put(svc, claudeItem("sk-ant-oat01-OLD", expires: now.addingTimeInterval(-7200)))
        st = ClaudeLoginStatus.check(keychain: keychain, home: home, binary: { "/fake/claude" })
        XCTAssertTrue(st.problem(now: now)!.message.contains("expired 2 h 0 min ago"), "E4: \(st.problem(now: now)!.message)")
        keychain.put(svc, claudeItem("sk-ant-oat01-GOOD", expires: now.addingTimeInterval(3 * 3600 + 29 * 60)))
        st = ClaudeLoginStatus.check(keychain: keychain, home: home, binary: { "/fake/claude" })
        XCTAssertNil(st.problem(now: now))
        XCTAssertEqual(st.summary(now: now), "Claude Max (default_claude_max_20x) · owner@example.com · Org · access expires in 3 h 29 min")
        keychain.lockedServices = [svc]
        XCTAssertEqual(ClaudeLoginStatus.check(keychain: keychain, home: home, binary: { nil }).state, .locked)
    }

    func testDoctorLines() {
        let store = DozerStore(root: root)
        var lines = Doctor.claudeChecks(store: store, keychain: keychain, binary: { nil }, home: home, listItems: true)
        XCTAssertEqual(lines.first { $0.check == "claude" }?.status, .warn)
        XCTAssertTrue(lines.first { $0.check == "claude login" }!.detail.contains("isn't installed"))
        keychain.put(svc, claudeItem("sk-ant-oat01-GOOD", expires: Date().addingTimeInterval(7200)))
        keychain.put(svc + "-560adfb8", claudeItem("sk-ant-oat01-STALE", expires: Date().addingTimeInterval(-86_400 * 80), old: true))
        lines = Doctor.claudeChecks(store: store, keychain: keychain, binary: { "/fake/claude" }, home: home, listItems: true)
        let login = lines.first { $0.check == "claude login" }!
        XCTAssertEqual(login.status, .ok)
        XCTAssertTrue(login.detail.hasPrefix("Claude Max"))
        XCTAssertTrue(lines.first { $0.check == "claude logins" }!.detail.contains("560adfb8 (unknown dir"))
        XCTAssertTrue(lines.first { $0.check == "accounts" }!.detail.contains("mac (default)"))
        let all = lines.map(\.detail).joined()
        XCTAssertFalse(all.contains("sk-ant"), "doctor never prints a token")
    }

    func testUsingTheMacLoginChecksFirstAndChangesNothingOnFailure() async throws {
        let c = await core(services(binary: nil))
        try await create(c, "a", account: "none")
        let before = await c.config(of: "a")
        var m = await use(c, "a", "mac")
        XCTAssertEqual(m.error?.code, .notFound)
        XCTAssertTrue(m.error!.message.contains("isn't installed"))
        keychain.put(ClaudeLogin.apiKeyService, "sk-ant-api03-CONSOLE")
        let c2 = await core(services(binary: "/fake/claude"))
        m = await use(c2, "a", "mac")
        XCTAssertTrue(m.error!.message.contains("API key"))
        keychain.put(svc, claudeItem("sk-ant-oat01-OLD", expires: Date().addingTimeInterval(-60)))
        m = await use(c2, "a", "mac")
        XCTAssertTrue(m.error!.message.contains("expired"))
        let after = await c2.config(of: "a")
        XCTAssertEqual(before?.account, after?.account, "no state change on a failed check")
        let v = await c2.vault(of: "a")
        XCTAssertEqual(v?.hasSecret(CredentialBinding.claudeOAuth.id), false)
    }

    // MARK: the Mac login in a sandbox (acceptance 1, 8, 12)

    func testAFollowerGetsTheMacLoginAndItsPlan() async throws {
        keychain.put(svc, claudeItem("sk-ant-oat01-MAC", expires: Date().addingTimeInterval(7200)))
        let c = await core()
        let info = try await create(c, "a")
        XCTAssertEqual(info.account, "mac", "a new proxied sandbox follows the default, mac")
        let v = try await XCTUnwrapAsync(await c.vault(of: "a"))
        XCTAssertTrue(v.hasSecret(CredentialBinding.claudeOAuth.id))
        XCTAssertFalse(v.hasSecret(CredentialBinding.anthropic.id))
        let env = v.sessionEnvironment()
        XCTAssertEqual(env["CLAUDE_CODE_SUBSCRIPTION_TYPE"], "max")
        XCTAssertEqual(env["CLAUDE_CODE_RATE_LIMIT_TIER"], "default_claude_max_20x")
        XCTAssertFalse(env.values.contains { $0.contains("sk-ant") })
        XCTAssertEqual(info.credentialPolicy, "allow")
        // A lab sandbox on NAT gets no account.
        let nat = try await create(c, "n", account: nil, image: "lab", network: "nat")
        XCTAssertNil(nat.account)
    }

    func testOneWatcherReadsOncePerTickForEverySandbox() async throws {
        keychain.put(svc, claudeItem("sk-ant-oat01-MAC", expires: Date().addingTimeInterval(7200)))
        let c = await core()
        for n in ["a", "b", "c"] { try await create(c, n) }
        let count = await c.loginWatcherCount
        XCTAssertEqual(count, 1)
        let w = try await XCTUnwrapAsync(await c.loginWatcher("mac"))
        XCTAssertEqual(w.subscriberNames, ["a", "b", "c"])
        let before = keychain.reads.filter { $0 == svc }.count
        w.tick()
        XCTAssertEqual(keychain.reads.filter { $0 == svc }.count - before, 1, "one read for three sandboxes")
        // A renewed token reaches all three.
        keychain.put(svc, claudeItem("sk-ant-oat01-RENEWED", expires: Date().addingTimeInterval(8 * 3600)))
        w.tick()
        for n in ["a", "b", "c"] {
            let v = try await XCTUnwrapAsync(await c.vault(of: n))
            let t = try XCTUnwrap(v.mint("claude-oauth"))
            guard case .swapped(let out, _) = v.rewrite(head: Array("GET / HTTP/1.1\r\nHost: api.anthropic.com\r\nAuthorization: Bearer \(t)\r\n\r\n".utf8), host: "api.anthropic.com") else { return XCTFail() }
            XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("RENEWED"))
        }
    }

    func testMacSignOutClearsAndADifferentAccountHolds() async throws {
        keychain.put(svc, claudeItem("sk-ant-oat01-MAC", expires: Date().addingTimeInterval(7200)))
        let c = await core()
        try await create(c, "a")
        let w = try await XCTUnwrapAsync(await c.loginWatcher("mac"))
        let v = try await XCTUnwrapAsync(await c.vault(of: "a"))
        let t = try XCTUnwrap(v.mint("claude-oauth"))
        let req = Array("GET / HTTP/1.1\r\nHost: api.anthropic.com\r\nAuthorization: Bearer \(t)\r\n\r\n".utf8)
        // D5: signed out → cleared at once, and the proxy says why.
        keychain.put(svc, nil)
        w.tick()
        XCTAssertEqual(w.state, .signedOut)
        guard case .refuse(401, let why) = v.rewrite(head: req, host: "api.anthropic.com") else { return XCTFail() }
        XCTAssertTrue(why.contains("signed out"))
        // Locked keychain: the last token is kept.
        keychain.put(svc, claudeItem("sk-ant-oat01-BACK", expires: Date().addingTimeInterval(7200)))
        w.tick()
        XCTAssertEqual(w.state, .ok)
        keychain.lockedServices = [svc]
        w.tick()
        XCTAssertEqual(w.state, .ok)
        XCTAssertTrue(v.hasSecret("claude-oauth"), "a locked keychain keeps the last token")
        keychain.lockedServices = []
        // D6: someone else signs in on the Mac → held.
        signIn(as: "acct-2", email: "other@example.com")
        keychain.put(svc, claudeItem("sk-ant-oat01-OTHER", expires: Date().addingTimeInterval(7200)))
        w.tick()
        XCTAssertEqual(w.state, .accountChanged)
        guard case .refuse(401, let held) = v.rewrite(head: req, host: "api.anthropic.com") else { return XCTFail() }
        XCTAssertTrue(held.contains("different Claude account") && held.contains("doz account use a mac"))
        // The one-command follow.
        let m = await use(c, "a", "mac")
        XCTAssertNil(m.error)
        XCTAssertEqual(w.state, .ok)
        guard case .swapped(let out, _) = v.rewrite(head: req, host: "api.anthropic.com") else { return XCTFail() }
        XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("OTHER"))
        let file = AccountStore(store: DozerStore(root: root)).load()
        XCTAssertEqual(file.accounts.first { $0.name == "mac" }?.identity?.accountUuid, "acct-2")
    }

    func testExpiredLoginIsReReadByTheProxyThenExplained() async throws {
        keychain.put(svc, claudeItem("sk-ant-oat01-OLD", expires: Date().addingTimeInterval(-5)))
        let c = await core()
        try await create(c, "a")
        let v = try await XCTUnwrapAsync(await c.vault(of: "a"))
        let t = try XCTUnwrap(v.mint("claude-oauth"))
        let req = Array("GET / HTTP/1.1\r\nHost: api.anthropic.com\r\nAuthorization: Bearer \(t)\r\n\r\n".utf8)
        let reads = keychain.reads.count
        guard case .refuse(401, let why) = v.rewrite(head: req, host: "api.anthropic.com") else { return XCTFail() }
        XCTAssertTrue(why.contains("expired") && why.contains("open Claude Code on the Mac"))
        XCTAssertEqual(keychain.reads.count - reads, 1, "one synchronous re-read before refusing")
        // Renewed on the Mac meanwhile: the re-read rescues the request.
        keychain.put(svc, claudeItem("sk-ant-oat01-NEW", expires: Date().addingTimeInterval(8 * 3600)))
        guard case .swapped = v.rewrite(head: req, host: "api.anthropic.com") else { return XCTFail() }
    }

    // MARK: keep-alive (acceptance 13, unit half: fake clock + fake runner)

    func testKeepaliveRunsOnceNearExpiryOnlyWhenEnabledUsedAndNoClaudeRuns() async throws {
        let now = Date()
        keychain.put(svc, claudeItem("sk-ant-oat01-MAC", expires: now.addingTimeInterval(300)))
        let runner = FakeRunner()
        runner.onRun = { [keychain, svc] in keychain.put(svc, claudeItem("sk-ant-oat01-RENEWED", expires: Date().addingTimeInterval(8 * 3600))) }
        let running = Locked(false)
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { "/fake/claude" }, home: home,
                                   keepaliveRunner: runner, isClaudeRunning: { running.value }, watchInterval: .seconds(3600))
        let c = await core(s)
        try await create(c, "a")
        let w = try await XCTUnwrapAsync(await c.loginWatcher("mac"))
        let v = try await XCTUnwrapAsync(await c.vault(of: "a"))
        // Off by default.
        XCTAssertEqual(w.keepalive?.enabled, false)
        _ = v.rewrite(head: Array("GET / HTTP/1.1\r\nHost: api.anthropic.com\r\n\r\n".utf8), host: "api.anthropic.com")   // a use
        XCTAssertFalse(w.keepaliveIfDue(now: now))
        var r = HostRequest(.accountKeepalive)
        r.enabled = true
        _ = await c.handle(r)
        XCTAssertEqual(w.keepalive?.enabled, true)
        // Not yet within 10 minutes of expiry.
        XCTAssertFalse(w.keepaliveIfDue(now: now.addingTimeInterval(-600)))
        // Claude Code runs on the Mac: it renews itself.
        running.mutate { $0 = true }
        XCTAssertFalse(w.keepaliveIfDue(now: now))
        XCTAssertEqual(runner.runs.count, 0)
        // A new expiry window, nobody running: once.
        keychain.put(svc, claudeItem("sk-ant-oat01-MAC2", expires: now.addingTimeInterval(240)))
        w.readNow(now: now)
        running.mutate { $0 = false }
        XCTAssertTrue(w.keepaliveIfDue(now: now))
        XCTAssertFalse(w.keepaliveIfDue(now: now), "once per expiry")
        XCTAssertEqual(runner.runs.count, 1)
        let (bin, args, env) = runner.runs[0]
        XCTAssertEqual(bin, "/fake/claude")
        XCTAssertEqual(args, ["-p", "ok", "--model", "haiku", "--max-turns", "1", "--no-session-persistence"])
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(env["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertEqual(w.state, .ok)
        XCTAssertGreaterThan(w.expiresAt ?? .distantPast, now.addingTimeInterval(3600), "the renewed login was read back")
        // No recent use: no run.
        keychain.put(svc, claudeItem("sk-ant-oat01-MAC3", expires: now.addingTimeInterval(86_400 + 120)))
        w.readNow(now: now)
        XCTAssertFalse(w.keepaliveIfDue(now: now.addingTimeInterval(86_400)))
    }

    // MARK: accounts (acceptance 11, unit half)

    func testSetupTokenAccountLivesInTheKeychainNeverOnDisk() async throws {
        let token = "sk-ant-oat01-" + String(repeating: "S", count: 95)
        let c = await core()
        var r = HostRequest(.accountAdd)
        r.account = "work"
        r.accountKind = "setup-token"
        r.plan = "max"
        r.secret = "CLAUDE_CODE_OAUTH_TOKEN=\"" + token.prefix(50) + "\n" + token.dropFirst(50) + "\""   // a wrapped paste
        var m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertEqual(keychain.writes, ["doz-claude:work"])
        XCTAssertEqual(keychain.get("doz-claude:work"), token)
        let file = try String(contentsOf: root.appendingPathComponent("accounts.json"), encoding: .utf8)
        XCTAssertFalse(file.contains("SSSSSSSS"), "no secret in accounts.json")
        let rows = try XCTUnwrap(m.result).decode([AccountRow].self)
        let work = try XCTUnwrap(rows.first { $0.name == "work" })
        XCTAssertEqual(work.kind, "setup-token")
        XCTAssertEqual(work.verification, "verified")
        XCTAssertEqual(work.fingerprint, CredentialFingerprint.of(token))
        XCTAssertEqual(work.expiresAt.map { Int($0.timeIntervalSinceNow / 86_400) }, 364)
        // Pinned: strict by default, the plan in the guest, the sign-in hosts blocked.
        try await create(c, "a", account: "work")
        let v = try await XCTUnwrapAsync(await c.vault(of: "a"))
        XCTAssertEqual(v.foreignPolicy, .strict)
        XCTAssertEqual(v.sessionEnvironment()["CLAUDE_CODE_SUBSCRIPTION_TYPE"], "max")
        let pol = try await XCTUnwrapAsync(await c.effectiveNetworkPolicy(of: "a"))
        XCTAssertEqual(pol.evaluate(host: "platform.claude.com", port: 443).action, .deny)
        XCTAssertEqual(pol.evaluate(host: "api.anthropic.com", port: 443).action, .allow)
        // The guest pasting the same token is recognised.
        let raw = Array("GET / HTTP/1.1\r\nHost: api.anthropic.com\r\nAuthorization: Bearer \(token)\r\n\r\n".utf8)
        v.foreignPolicy = .allow
        guard case .foreign(_, let f) = v.rewrite(head: raw, host: "api.anthropic.com") else { return XCTFail() }
        XCTAssertEqual(f.matches, "work")
        // rm refuses while pinned; --force unpins and deletes the item doz made.
        var rm = HostRequest(.accountRemove)
        rm.account = "work"
        m = await c.handle(rm)
        XCTAssertEqual(m.error?.code, .invalid)
        rm.force = true
        m = await c.handle(rm)
        XCTAssertNil(m.error)
        XCTAssertNil(keychain.get("doz-claude:work"))
        let cfg = await c.config(of: "a")
        XCTAssertEqual(cfg?.account, "default")
    }

    func testARejectedTokenIsNotStored() async throws {
        let c = await core(services(verifier: .rejected("invalid bearer token")))
        var r = HostRequest(.accountAdd)
        r.account = "bad"
        r.accountKind = "setup-token"
        r.secret = "sk-ant-oat01-" + String(repeating: "B", count: 95)
        let m = await c.handle(r)
        XCTAssertEqual(m.error?.code, .failed)
        XCTAssertTrue(m.error!.message.contains("claude setup-token"))
        XCTAssertTrue(keychain.writes.isEmpty)
        // Unavailable (network) stores it, marked unverified.
        let c2 = await core(services(verifier: .unavailable("offline")))
        let m2 = await c2.handle(r)
        XCTAssertNil(m2.error)
        XCTAssertEqual(try XCTUnwrap(m2.result).decode([AccountRow].self).first { $0.name == "bad" }?.verification, "unverified: offline")
        // Not a setup token at all.
        r.secret = "sk-ant-api03-" + String(repeating: "B", count: 95)
        r.force = true
        let m3 = await c2.handle(r)
        XCTAssertTrue(m3.error!.message.contains("isn't a Claude setup token"))
    }

    func testDefaultAccountAndNamesAndPolicy() async throws {
        keychain.put(svc, claudeItem("sk-ant-oat01-MAC", expires: Date().addingTimeInterval(7200)))
        let c = await core()
        var r = HostRequest(.accountAdd)
        r.account = "default"
        r.accountKind = "api-key"
        r.secret = "sk-ant-api03-KEYKEYKEYKEYKEYKEYKEY"
        var m = await c.handle(r)
        XCTAssertEqual(m.error?.code, .invalid, "reserved name")
        r.account = "team-key"
        m = await c.handle(r)
        XCTAssertNil(m.error)
        try await create(c, "a")
        var d = HostRequest(.accountDefault)
        d.account = "team-key"
        m = await c.handle(d)
        XCTAssertNil(m.error)
        let v = try await XCTUnwrapAsync(await c.vault(of: "a"))
        XCTAssertTrue(v.hasSecret("anthropic"), "a follower moves with the default")
        XCTAssertFalse(v.hasSecret("claude-oauth"), "one Anthropic credential at a time")
        XCTAssertEqual(v.foreignPolicy, .strict)
        var p = HostRequest(.keyPolicy, name: "a")
        p.policy = "allow"
        m = await c.handle(p)
        XCTAssertNil(m.error)
        XCTAssertEqual(v.foreignPolicy, .allow)
        var pol = try await XCTUnwrapAsync(await c.effectiveNetworkPolicy(of: "a"))
        XCTAssertEqual(pol.evaluate(host: "claude.ai", port: 443).action, .deny, "597: Sign in is off in Standard")
        var g = HostRequest(.netPolicy, name: "a")
        g.grant = ["sign-in"]
        m = await c.handle(g)
        XCTAssertNil(m.error)
        pol = try await XCTUnwrapAsync(await c.effectiveNetworkPolicy(of: "a"))
        XCTAssertEqual(pol.evaluate(host: "claude.ai", port: 443).action, .allow, "the sign-in block goes with strict")
        p.policy = "auto"
        _ = await c.handle(p)
        XCTAssertEqual(v.foreignPolicy, .strict)
        pol = try await XCTUnwrapAsync(await c.effectiveNetworkPolicy(of: "a"))
        XCTAssertEqual(pol.evaluate(host: "claude.ai", port: 443).action, .deny, "strict blocks sign-in even when its permission is on")
        d.account = "none"
        _ = await c.handle(d)
        XCTAssertFalse(v.hasSecret("anthropic"))
        let lsMessage = await c.handle(HostRequest(.ls))
        let ls = try XCTUnwrap(lsMessage.result).decode([SandboxInfo].self)
        XCTAssertNil(ls.first { $0.name == "a" }?.account)
    }

    // MARK: aliases (D10) and persisted placeholders (D8)

    func testKeySetClaudeLoginIsAccountUseMacAndOldConfigsMigrate() async throws {
        keychain.put(svc, claudeItem("sk-ant-oat01-MAC", expires: Date().addingTimeInterval(7200)))
        let c = await core()
        try await create(c, "a", account: "none")
        var r = HostRequest(.keySet, name: "a")
        r.binding = CredentialBinding.claudeOAuth.id
        r.source = ClaudeLogin.source
        let m = await c.handle(r)
        XCTAssertNil(m.error)
        let rows = try XCTUnwrap(m.result).decode([CredentialRow].self)
        XCTAssertEqual(rows.first { $0.binding == "claude-oauth" }?.source, "account:mac")
        XCTAssertEqual(rows.first { $0.binding == "claude-oauth" }?.state, "ok")
        // key set --anthropic replaces the account.
        var k = HostRequest(.keySet, name: "a")
        k.binding = "anthropic"
        k.secret = "sk-ant-api03-FROM-STDIN-0123456789"
        _ = await c.handle(k)
        let cfg = await c.config(of: "a")
        XCTAssertNil(cfg?.account)
        // A 0aab331 config (credentialSources claude-oauth = claude-login) loads as the mac account.
        let store = DozerStore(root: root)
        var old = try XCTUnwrap(SandboxConfig.read(store.configFile("a")))
        old.account = nil
        old.credentialSources = ["claude-oauth": "claude-login"]
        try old.write(store.configFile("a"))
        let c2 = await core()
        let migrated = await c2.config(of: "a")
        XCTAssertEqual(migrated?.account, "mac")
        XCTAssertEqual(migrated?.credentialSources, [:])
    }

    func testPlaceholdersSurviveANewHost() async throws {
        keychain.put(svc, claudeItem("sk-ant-oat01-MAC", expires: Date().addingTimeInterval(7200)))
        let c = await core()
        try await create(c, "a")
        let v = try await XCTUnwrapAsync(await c.vault(of: "a"))
        let t = try XCTUnwrap(v.mint("claude-oauth"))
        let store = DozerStore(root: root)
        let deadline = Date().addingTimeInterval(5)
        while SandboxConfig.read(store.configFile("a"))?.placeholderHashes == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let text = try String(contentsOf: store.configFile("a"), encoding: .utf8)
        XCTAssertFalse(text.contains(t), "hashes only")
        XCTAssertFalse(text.contains("sk-ant"))
        let c2 = await core()
        let v2 = try await XCTUnwrapAsync(await c2.vault(of: "a"))
        guard case .swapped = v2.rewrite(head: Array("GET / HTTP/1.1\r\nHost: api.anthropic.com\r\nAuthorization: Bearer \(t)\r\n\r\n".utf8), host: "api.anthropic.com") else {
            return XCTFail("a session from the previous host keeps working")
        }
    }

    func testAccountCommandsParse() throws {
        XCTAssertTrue(try DozerCommand.parseAsRoot(["account", "add", "work", "--setup-token", "--plan", "max"]) is AccountAdd)
        XCTAssertThrowsError(try DozerCommand.parseAsRoot(["account", "add", "work"]))
        XCTAssertThrowsError(try DozerCommand.parseAsRoot(["account", "add", "work", "--setup-token", "--plan", "gold"]))
        XCTAssertTrue(try DozerCommand.parseAsRoot(["account", "use", "a", "work"]) is AccountUse)
        XCTAssertTrue(try DozerCommand.parseAsRoot(["account", "keepalive", "on"]) is AccountKeepalive)
        XCTAssertThrowsError(try DozerCommand.parseAsRoot(["account", "keepalive", "maybe"]))
        XCTAssertTrue(try DozerCommand.parseAsRoot(["key", "policy", "a", "strict"]) is KeyPolicy)
        XCTAssertThrowsError(try DozerCommand.parseAsRoot(["key", "policy", "a", "loose"]))
        let create = try XCTUnwrap(try DozerCommand.parseAsRoot(["create", "a", "--image", "claude-code", "--account", "work"]) as? Create)
        XCTAssertEqual(try create.create.options().account, "work")
        let text = KeyList.render([CredentialRow(binding: "claude-oauth", hosts: ["api.anthropic.com"], set: true, source: "account:mac", account: "mac",
                                                 state: "ok", expiresAt: nil, policy: "allow",
                                                 foreign: [ForeignCredential(kind: "oauth", prefix: "sk-ant-oat01", fingerprint: "ab12cd34ef56", header: "authorization",
                                                                             firstSeen: Date(), lastSeen: Date(), requests: 3)])])
        XCTAssertTrue(text.contains("ab12cd34ef56") && text.contains("sk-ant-oat01…"))
    }

    // MARK: 594 — each agent's credentials (owner: "creating a Pi sandbox should have pre-requisites")

    func testTheCompatibilityTable() {
        XCTAssertEqual(AgentCredentials.kinds("claude-code"), [.mac, .setupToken, .apiKey])
        XCTAssertEqual(AgentCredentials.kinds("pi"), [.apiKey], "pi: an Anthropic API key only — never a Claude subscription")
        XCTAssertNil(AgentCredentials.kinds("lab"))
        XCTAssertNil(AgentCredentials.kinds(nil))
        XCTAssertTrue(AgentCredentials.needsAccount("pi"))
        XCTAssertFalse(AgentCredentials.needsAccount("claude-code"))
        XCTAssertFalse(AgentCredentials.accepts("pi", .mac))
        XCTAssertFalse(AgentCredentials.accepts("pi", .setupToken))
        XCTAssertTrue(AgentCredentials.accepts("pi", .apiKey))
        XCTAssertTrue(AgentCredentials.accepts("lab", .mac), "no agent: anything goes")
        XCTAssertEqual(AgentImages.credentials("pi"), [AgentCredentialSupport(provider: "anthropic", accountKinds: ["api-key"])])
        XCTAssertEqual(AgentCredentials.requirement("pi"), "pi needs an Anthropic API key")

        let kinds: [String: AccountKind] = ["mac": .mac, "sub": .setupToken]
        // pi: every way of having no usable account is refused, with the next step.
        var p = AgentCredentials.createProblem(image: "pi", account: nil, defaultAccount: "none", kinds: kinds)
        XCTAssertTrue(p?.contains("pi needs an Anthropic API key") == true && p?.contains("doz account add NAME --api-key") == true, p ?? "nil")
        p = AgentCredentials.createProblem(image: "pi", account: nil, defaultAccount: "mac", kinds: kinds)
        XCTAssertTrue(p?.hasPrefix("pi can't use the account mac (this Mac's Claude login)") == true, p ?? "nil")
        p = AgentCredentials.createProblem(image: "pi", account: "default", defaultAccount: "sub", kinds: kinds)
        XCTAssertTrue(p?.contains("can't use the account sub") == true, p ?? "nil")
        p = AgentCredentials.createProblem(image: "pi", account: "mac", defaultAccount: "none", kinds: kinds)
        XCTAssertTrue(p?.contains("can't use the account mac") == true, p ?? "nil")
        // …and names the accounts that fit, when there are some.
        p = AgentCredentials.createProblem(image: "pi", account: nil, defaultAccount: "mac", kinds: kinds.merging(["work": .apiKey]) { a, _ in a })
        XCTAssertTrue(p?.contains("--account work") == true, p ?? "nil")
        // What fits.
        XCTAssertNil(AgentCredentials.createProblem(image: "pi", account: "work", defaultAccount: "mac", kinds: ["mac": .mac, "work": .apiKey]))
        XCTAssertNil(AgentCredentials.createProblem(image: "pi", account: nil, defaultAccount: "work", kinds: ["mac": .mac, "work": .apiKey]))
        XCTAssertNil(AgentCredentials.createProblem(image: "pi", account: "none", defaultAccount: "mac", kinds: kinds), "an explicit none is a choice")
        XCTAssertNil(AgentCredentials.createProblem(image: "claude-code", account: nil, defaultAccount: "mac", kinds: kinds))
        XCTAssertNil(AgentCredentials.createProblem(image: "claude-code", account: nil, defaultAccount: "none", kinds: kinds))
        XCTAssertNil(AgentCredentials.createProblem(image: "lab", account: "mac", defaultAccount: "none", kinds: kinds))
        // An existing sandbox: the banner.
        XCTAssertEqual(AgentCredentials.sandboxProblem(image: "pi", account: .mac, missing: nil), "pi can't use the account mac — choose an API-key account")
        XCTAssertEqual(AgentCredentials.sandboxProblem(image: "pi", account: nil, missing: nil),
                       "pi has no credential — pi needs an Anthropic API key; choose an API-key account")
        XCTAssertNil(AgentCredentials.sandboxProblem(image: "claude-code", account: .mac, missing: nil))
        XCTAssertNil(AgentCredentials.sandboxProblem(image: "claude-code", account: nil, missing: nil))
    }

    func testPiIsCreatedOnlyWithAnAccountItCanUse() async throws {
        keychain.put(svc, claudeItem("sk-ant-oat01-MAC", expires: Date().addingTimeInterval(7200)))
        let c = await core()
        // The store's default is mac (this Mac's login): pi cannot use it — refused, nothing made.
        do { try await create(c, "p1", image: "pi"); XCTFail("created") } catch let e as HostError {
            XCTAssertEqual(e.code, .invalid)
            XCTAssertTrue(e.message.contains("pi can't use the account mac") && e.message.contains("doz account add NAME --api-key"), e.message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: DozerStore(root: root).layout("p1").sandboxDirectory.path))
        // An explicit none is a choice: made, and it says what is missing.
        let none = try await create(c, "p2", account: "none", image: "pi")
        XCTAssertEqual(none.agent, "pi")
        XCTAssertEqual(none.credentialProblem, "pi has no credential — pi needs an Anthropic API key; choose an API-key account")
        func prompt(_ n: String) async throws -> AgentPromptReport? {
            try await c.handle(HostRequest(.agentPrompt, name: n)).result?.decode(AgentPromptReport.self)
        }
        let promptP2 = try await prompt("p2")
        XCTAssertTrue(promptP2?.text?.contains("no credential you can use is attached") == true, promptP2?.text ?? "")
        XCTAssertFalse(promptP2?.text?.contains("adds the account's credential") == true)
        // Only an API-key account can be given to it.
        let refused = await use(c, "p2", "mac")
        XCTAssertTrue(refused.error?.message.contains("pi can't use the account mac") == true, "\(String(describing: refused.error))")
        var r = HostRequest(.accountAdd)
        r.account = "work"
        r.accountKind = "api-key"
        r.secret = "sk-ant-api03-PIPIPIPIPIPIPIPIPIPIPI"
        let added = await c.handle(r)
        XCTAssertNil(added.error)
        let used = await use(c, "p2", "work")
        XCTAssertNil(used.error, "an API key: yes")
        let v = try await XCTUnwrapAsync(await c.vault(of: "p2"))
        XCTAssertTrue(v.hasSecret("anthropic"), "pi's ANTHROPIC_API_KEY placeholder is swapped for work's key")
        let rows = try await c.handle(HostRequest(.ls)).result!.decode([SandboxInfo].self)
        XCTAssertNil(rows.first { $0.name == "p2" }?.credentialProblem, "the banner goes once it fits")
        let fits = try await prompt("p2")
        XCTAssertTrue(fits?.text?.contains("adds the account's credential (work)") == true, fits?.text ?? "")
        // With --account work: made.
        let ok = try await create(c, "p3", account: "work", image: "pi")
        XCTAssertNil(ok.credentialProblem)
        // Claude Code keeps every account, none included.
        let cc = try await create(c, "cc")
        XCTAssertNil(cc.credentialProblem)
        // A duplicate of p3 onto mac is refused; keeping work is fine.
        var d = HostRequest(.duplicate, name: "p3")
        d.newName = "p4"
        d.duplicate = DuplicateOptions(account: "mac")
        let dm = await c.handle(d)
        XCTAssertTrue(dm.error?.message.contains("pi can't use the account mac") == true, "\(String(describing: dm.error))")
    }
}

func XCTUnwrapAsync<T>(_ v: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(v, file: file, line: line)
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}
