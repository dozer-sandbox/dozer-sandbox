import Foundation
@testable import DozerKit
import XCTest
@testable import DozerCLI
@testable import DozerHost

// 599i — Codex in the host, without a VM, a real keychain or the network: a fake keychain, a fake refresh,
// fake JWTs. Every token here is a made-up string.

func fakeJWT(_ payload: [String: Any], signature: String = "c2ln") -> String {
    let h = OpenAIAccess.base64URL(Data(#"{"alg":"RS256"}"#.utf8))
    let p = OpenAIAccess.base64URL(try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
    return "\(h).\(p).\(signature)"
}

/// Realistically sized (599i rc.2: a real sign-in is ~4 KB — ~2 KB access token, ~1 KB id token with its
/// organizations, a long signature), so a store that cannot hold it fails here as it did on the owner's Mac.
func fakeChatGPTTokens(access: String = "ACCESS-1", refresh: String = "RT-1", expiresIn: TimeInterval = 3600, now: Date = Date()) -> ChatGPTTokens {
    let sig = String(repeating: "S", count: 342)
    let orgs = (0..<6).map { ["id": "org-\($0)-" + String(repeating: "o", count: 24), "title": "Org \($0)", "role": "owner", "is_default": $0 == 0] as [String: Any] }
    let id = fakeJWT(["email": "person@example.invalid", "exp": Int(now.addingTimeInterval(3600).timeIntervalSince1970),
                      "https://api.openai.com/auth": ["chatgpt_plan_type": "pro", "chatgpt_account_id": "acct-9", "chatgpt_user_id": "user-9",
                                                      "organizations": orgs]],
                     signature: "UkVBTC1JRC1TSUc" + sig)
    let at = fakeJWT(["exp": Int(now.addingTimeInterval(expiresIn).timeIntervalSince1970), "jti": access, "scp": ["openid", "profile", "email", "offline_access"],
                      "pad": String(repeating: "p", count: 1200)], signature: sig)
    return ChatGPTTokens(idToken: id, accessToken: at, refreshToken: refresh)
}

final class CodexHostTests: XCTestCase {
    private var root: URL!
    let keychain = FakeKeychain()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-codex-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func services() -> CredentialServices {
        CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                           keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
    }

    func core() async -> HostCore {
        let c = HostCore(store: DozerStore(root: root), readOnly: false, version: "test", services: services())
        await c.load()
        return c
    }

    @discardableResult
    func create(_ c: HostCore, _ name: String, account: String? = nil, image: String = "codex") async throws -> SandboxInfo {
        var r = HostRequest(.create, name: name)
        r.create = CreateOptions(image: image, account: account)
        let m = await c.handle(r)
        if let e = m.error { throw e }
        return try XCTUnwrap(m.result).decode(SandboxInfo.self)
    }

    func add(_ c: HostCore, _ name: String, _ kind: AccountKind, _ secret: String) async -> HostMessage {
        await c.handle(HostRequest.accountAdd(name: name, kind: kind, plan: nil, secret: secret))
    }

    // MARK: the agent and its accounts

    func testCodexIsAnAgentOnEveryBase() {
        XCTAssertEqual(ImageChoice.parse("codex"), ImageChoice(base: "node", agent: .codex))
        XCTAssertEqual(ImageChoice.parse("python-codex"), ImageChoice(base: "python", agent: .codex))
        XCTAssertEqual(ImageChoice.parse("alpine-codex")?.name, "alpine-codex")
        XCTAssertEqual(AgentImages.agentName("go-codex"), "Codex")
        XCTAssertEqual(AgentImages.package("codex"), "@openai/codex")
        XCTAssertEqual(DozerSettings.imageSection(imageSpecName: "python-codex"), "codex")
        XCTAssertEqual(DozerSettings.imageSection(imageSpecName: "python-pi"), "pi", "unchanged")
        XCTAssertEqual(DozerSettings.imageSection(imageSpecName: "go"), "claude-code", "unchanged")
        XCTAssertEqual(SettingKey.agentVersion("codex"), "images.codex_version")
        XCTAssertNotNil(DozerSettings.definition("images.codex.memory_mib"))
        XCTAssertNotNil(DozerSettings.definition("codex.permissions"))
        XCTAssertEqual(Workspace.baseName(image: "codex"), "codex-sandbox")
        XCTAssertEqual(Workspace.baseName(image: "rust-codex"), "rust-codex-sandbox")
    }

    /// Codex takes OpenAI accounts only; Claude Code and pi never get one (and Codex never an Anthropic one).
    func testTheCompatibilityTable() {
        XCTAssertEqual(AgentCredentials.kinds("codex"), [.codexMac, .chatgpt, .openaiKey])
        XCTAssertEqual(AgentCredentials.kinds("python-codex"), [.codexMac, .chatgpt, .openaiKey])
        XCTAssertFalse(AgentCredentials.accepts("claude-code", .codexMac))
        XCTAssertEqual(AgentCredentials.provider("codex"), "openai")
        XCTAssertEqual(AgentCredentials.provider("claude-code"), "anthropic")
        for k in [AccountKind.mac, .setupToken, .apiKey] { XCTAssertFalse(AgentCredentials.accepts("codex", k), k.rawValue) }
        for k in [AccountKind.chatgpt, .openaiKey] {
            XCTAssertFalse(AgentCredentials.accepts("claude-code", k), k.rawValue)
            XCTAssertFalse(AgentCredentials.accepts("pi", k), k.rawValue)
            XCTAssertTrue(AgentCredentials.accepts("codex", k))
            XCTAssertTrue(AgentCredentials.accepts(nil, k), "the lab: any")
        }
        XCTAssertEqual(AccountKind.chatgpt.binding, .chatgpt)
        XCTAssertEqual(AccountKind.openaiKey.binding, .openai)
        XCTAssertEqual(AccountKind.apiKey.binding, .anthropic, "unchanged")
        XCTAssertEqual(AccountKind.setupToken.binding, .claudeOAuth, "unchanged")
        XCTAssertTrue(AgentCredentials.needsAccount("codex"))
        let kinds: [String: AccountKind] = ["mac": .mac, "work": .apiKey, "plan": .chatgpt]
        // The store's Anthropic default is never Codex's.
        let p = AgentCredentials.createProblem(image: "codex", account: nil, defaultAccount: "mac", kinds: kinds)
        XCTAssertTrue(p?.contains("Codex needs an OpenAI account") == true && p?.contains("default OpenAI account is none") == true, p ?? "")
        XCTAssertTrue(p?.contains("--account plan") == true, p ?? "")
        XCTAssertNil(AgentCredentials.createProblem(image: "codex", account: nil, defaultAccount: "mac", kinds: kinds, openaiDefault: "plan"))
        XCTAssertNotNil(AgentCredentials.createProblem(image: "codex", account: "work", defaultAccount: "mac", kinds: kinds))
        XCTAssertNotNil(AgentCredentials.createProblem(image: "claude-code", account: "plan", defaultAccount: "mac", kinds: kinds))
        XCTAssertNil(AgentCredentials.createProblem(image: "claude-code", account: nil, defaultAccount: "mac", kinds: kinds, openaiDefault: "plan"))
        XCTAssertEqual(AgentCredentials.sandboxProblem(image: "codex", account: nil, missing: nil),
                       "Codex has no credential — Codex needs an OpenAI account: this Mac's Codex login, a ChatGPT sign-in or an OpenAI API key; choose an OpenAI account (mac, a ChatGPT sign-in or an OpenAI API key)")
    }

    /// A ChatGPT sign-in is ONE keychain item; accounts.json holds no token; the OpenAI default is separate.
    func testAChatGPTSignInLivesInTheKeychainAndBecomesTheOpenAIDefault() async throws {
        let c = await core()
        let t = fakeChatGPTTokens()
        var m = await add(c, "plan", .chatgpt, t.json)
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertGreaterThan(t.json.utf8.count, 3500, "a realistic sign-in is ~4 KB — more than one item holds")
        XCTAssertEqual(keychain.writes, ["doz-chatgpt:plan"], "only what must persist — one item")
        let kept = try XCTUnwrap(ChatGPTRecord.parse(keychain.get("doz-chatgpt:plan") ?? ""))
        XCTAssertEqual(kept.refreshToken, "RT-1")
        XCTAssertEqual(kept.accountID, "acct-9")
        XCTAssertFalse((keychain.get("doz-chatgpt:plan") ?? "").contains(t.accessToken), "the access token is never kept")
        XCTAssertFalse((keychain.get("doz-chatgpt:plan") ?? "").contains("UkVBTC1JRC1TSUc"), "nor the id_token's signature")
        XCTAssertLessThan((keychain.get("doz-chatgpt:plan") ?? "").utf8.count, 600)
        let file = try String(contentsOf: root.appendingPathComponent("accounts.json"), encoding: .utf8)
        XCTAssertFalse(file.contains("RT-1") || file.contains(t.accessToken) || file.contains("UkVBTC1JRC1TSUc"), "no token in accounts.json")
        XCTAssertTrue(file.contains("acct-9") && file.contains("person@example.invalid"), "the claims that are not secrets")
        let row = try XCTUnwrap(try XCTUnwrap(m.result).decode([AccountRow].self).first { $0.name == "plan" })
        XCTAssertEqual(row.kind, "chatgpt")
        XCTAssertEqual(row.plan, "pro")
        XCTAssertEqual(row.identity, "person@example.invalid")
        XCTAssertFalse(row.isDefault)
        // Not a sign-in: refused, nothing stored.
        m = await add(c, "bad", .chatgpt, "sk-not-tokens")
        XCTAssertEqual(m.error?.code, .invalid)
        XCTAssertNil(keychain.get("doz-chatgpt:bad"))
        // An OpenAI key: sk-… only, in doz-openai:NAME.
        m = await add(c, "okey", .openaiKey, "sk-ant-api03-NOTOPENAI0000000000000")
        XCTAssertNil(m.error, "an sk- key")
        m = await add(c, "k2", .openaiKey, "not-a-key-0000000000000000")
        XCTAssertEqual(m.error?.code, .invalid)
        // The default: an OpenAI account sets the OpenAI one; the Anthropic default stays.
        var d = HostRequest(.accountDefault)
        d.account = "plan"
        m = await c.handle(d)
        XCTAssertNil(m.error)
        let f = AccountStore(store: DozerStore(root: root)).load()
        XCTAssertEqual(f.openaiDefault, "plan")
        XCTAssertEqual(f.defaultAccount, "mac")
        let rows = try XCTUnwrap(m.result).decode([AccountRow].self)
        XCTAssertEqual(rows.filter(\.isDefault).map(\.name).sorted(), ["mac", "plan"])
        // A codex sandbox follows it; claude-code does not.
        let cx = try await create(c, "cx")
        XCTAssertNil(cx.credentialProblem)
        XCTAssertEqual(cx.agent, "codex")
        let v = try await XCTUnwrapAsync(await c.vault(of: "cx"))
        XCTAssertTrue(v.issuesPlaceholder("chatgpt"))
        XCTAssertFalse(v.issuesPlaceholder("anthropic"))
        XCTAssertNil(v.sessionEnvironment()["ANTHROPIC_API_KEY"])
        // Removing it: the OpenAI default is none again (never an Anthropic account), the item deleted.
        var rm = HostRequest(.accountRemove)
        rm.account = "plan"
        m = await c.handle(rm)
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertNil(keychain.get("doz-chatgpt:plan"))
        XCTAssertNil(AccountStore(store: DozerStore(root: root)).load().openaiDefault)
    }

    /// The vault swaps the sign-in's access token on chatgpt.com; the guest's auth.json holds placeholders only.
    func testACodexSandboxGetsPlaceholdersAndTheProxyTheToken() async throws {
        let c = await core()
        let t = fakeChatGPTTokens()
        _ = await add(c, "plan", .chatgpt, t.json)
        try await create(c, "cx", account: "plan")
        let v = try await XCTUnwrapAsync(await c.vault(of: "cx"))
        let ph = try XCTUnwrap(v.mintForFile("chatgpt"))
        let head = Array("POST /backend-api/codex/responses HTTP/1.1\r\nHost: chatgpt.com\r\nAuthorization: Bearer \(ph)\r\n\r\n".utf8)
        guard case .swapped(let out, binding: "chatgpt") = v.rewrite(head: head, host: "chatgpt.com") else { return XCTFail("not swapped") }
        XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("Bearer \(t.accessToken)"))
        // The auth.json script: placeholders, the claims under a fake signature — never a token.
        let script = try await XCTUnwrapAsync(await c.codexAuthScriptForTests("cx"))
        XCTAssertFalse(script.contains(t.accessToken) || script.contains("RT-1") || script.contains("UkVBTC1JRC1TSUc"))
        let b64 = try XCTUnwrap(script.components(separatedBy: "printf %s '").dropFirst().first?.components(separatedBy: "'").first)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(Data(base64Encoded: b64))) as? [String: Any])
        let tokens = try XCTUnwrap(json["tokens"] as? [String: Any])
        XCTAssertTrue((tokens["access_token"] as? String)?.hasPrefix("doz_cred_") == true)
        XCTAssertEqual(tokens["access_token"] as? String, tokens["refresh_token"] as? String)
        XCTAssertEqual(tokens["account_id"] as? String, "acct-9")
        XCTAssertTrue((tokens["id_token"] as? String)?.hasSuffix(".ZG96LXVuc2lnbmVk") == true)
        XCTAssertEqual(json["auth_mode"] as? String, "chatgpt")
        XCTAssertTrue(script.contains("/home/agent/.codex/auth.json") && script.contains("chmod 0600"))
        // The permissions: "Talk to OpenAI" on and locked; Claude Code's own hosts not added beyond Standard's.
        let pol = try await XCTUnwrapAsync(await c.effectiveNetworkPolicy(of: "cx"))
        XCTAssertTrue(pol.permissions?.contains("model:openai") == true)
        XCTAssertEqual(pol.evaluate(host: "chatgpt.com", port: 443).action, .allow)
        XCTAssertEqual(pol.evaluate(host: "api.openai.com", port: 443).action, .allow)
        XCTAssertEqual(pol.evaluate(host: "auth.openai.com", port: 443).action, .deny, "the renewal is answered by the proxy — the host itself is not allowed")
        var revoke = HostRequest(.netPolicy, name: "cx")
        revoke.revoke = ["model:openai"]
        let refused = await c.handle(revoke)
        XCTAssertTrue(refused.error?.message.contains("Codex needs it") == true, "\(String(describing: refused.error))")
        var preset = HostRequest(.netPolicy, name: "cx")
        preset.preset = "locked"
        do { let m = await c.handle(preset); XCTAssertNil(m.error, m.error?.message ?? "") }
        let locked = try await XCTUnwrapAsync(await c.effectiveNetworkPolicy(of: "cx"))
        XCTAssertEqual(locked.permissions, ["model", "model:openai"], "a preset keeps Codex's model")
        // An API-key account instead: the sign-in's binding is gone, the key's auth.json.
        _ = await add(c, "okey", .openaiKey, "sk-proj-FAKEFAKEFAKEFAKEFAKE")
        var use = HostRequest(.accountUse, name: "cx")
        use.account = "okey"
        do { let m = await c.handle(use); XCTAssertNil(m.error, m.error?.message ?? "") }
        XCTAssertTrue(v.hasSecret("openai"))
        XCTAssertFalse(v.issuesPlaceholder("chatgpt"))
        XCTAssertNil(v.binding(ofPlaceholder: ph), "the sign-in's placeholders are revoked with it")
        let keyScript = try await XCTUnwrapAsync(await c.codexAuthScriptForTests("cx"))
        XCTAssertFalse(keyScript.contains("sk-proj-FAKE"))
        // No account: the proxy answers with why — never another account's credential.
        use.account = "none"
        do { let m = await c.handle(use); XCTAssertNil(m.error, m.error?.message ?? "") }
        let ph2 = try XCTUnwrap(v.mintForFile("openai"))
        let api = Array("POST /v1/responses HTTP/1.1\r\nHost: api.openai.com\r\nAuthorization: Bearer \(ph2)\r\n\r\n".utf8)
        guard case .refuse(401, let why) = v.rewrite(head: api, host: "api.openai.com") else { return XCTFail("not refused") }
        XCTAssertTrue(why.contains("no OpenAI account now"), why)
    }

    /// Claude Code's sandboxes are as before: no OpenAI permission, no "OpenAI" in their facts.
    func testClaudeCodeAndPiAreUnchanged() async throws {
        let c = await core()
        var r = HostRequest(.create, name: "cc")
        r.create = CreateOptions(image: "claude-code")
        do { let m = await c.handle(r); XCTAssertNil(m.error, m.error?.message ?? "") }
        let pol = try await XCTUnwrapAsync(await c.effectiveNetworkPolicy(of: "cc"))
        XCTAssertFalse(pol.permissions?.contains("model:openai") == true)
        XCTAssertEqual(pol.evaluate(host: "chatgpt.com", port: 443).action, .deny)
        let report = try await c.handle(HostRequest(.agentPrompt, name: "cc")).result?.decode(AgentPromptReport.self)
        XCTAssertFalse(report?.text?.contains("OpenAI") == true)
        XCTAssertTrue(report?.skill?.contains("(`~/.claude`, `~/.pi/agent`: logins, history, settings)") == true, "the skill as before")
        XCTAssertEqual(report?.skillPath, "/home/agent/.claude/skills/dozer/SKILL.md")
        let perms = PermissionPolicy.report(name: "cc", policy: pol, base: "node", log: [])
        XCTAssertNil(perms.permissions.first { $0.id == "model:openai" })
        XCTAssertFalse(PermissionPolicy.facts(pol, sandbox: "cc").contains("OpenAI"))
        XCTAssertNil(HostCore.withClaudePermissions([:], imageSpec: "claude-code", settings: DozerSettings(text: ""))["DOZ_CODEX_PERMISSIONS"])
    }

    func testCodexsPromptAndSkill() async throws {
        let c = await core()
        _ = await add(c, "okey", .openaiKey, "sk-proj-FAKEFAKEFAKEFAKEFAKE")
        try await create(c, "cx", account: "okey")
        let pm = await c.handle(HostRequest(.agentPrompt, name: "cx"))
        let report = try XCTUnwrap(try pm.result?.decode(AgentPromptReport.self))
        XCTAssertEqual(report.agent, "codex")
        XCTAssertEqual(report.skillPath, "/home/agent/.agents/skills/dozer/SKILL.md", "Codex's user skills — never AGENTS.md")
        XCTAssertTrue(report.text?.contains("requests to OpenAI") == true, report.text ?? "")
        XCTAssertTrue(report.text?.contains("never run `codex login`") == true)
        XCTAssertTrue(report.skill?.contains("(`~/.codex`: logins, history, settings)") == true)
        XCTAssertTrue(report.text?.contains("talk to your AI model (OpenAI)") == true, report.text ?? "")
        XCTAssertFalse(report.text?.contains("Anthropic") == true, report.text ?? "")
        let env = HostCore.withClaudePermissions([:], imageSpec: "codex", settings: DozerSettings(text: ""))
        XCTAssertNil(env["DOZ_CODEX_PERMISSIONS"], "skip is the default — nothing set")
    }

    // MARK: the renewal on the Mac

    final class FakeRefresh: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        var answer: (ChatGPTTokens) -> OpenAIAccess.RefreshResult = { t in
            .renewed(fakeChatGPTTokens(access: "ACCESS-2", refresh: "RT-2"))
        }
        func run(_ t: ChatGPTTokens) -> OpenAIAccess.RefreshResult {
            lock.withLock { calls += 1 }
            usleep(50_000)
            return answer(t)
        }
    }

    func testTheSessionRenewsOnTheMacKeepsTheRotatedTokenFirstAndNeverFallsBack() throws {
        let fake = FakeRefresh()
        keychain.put("doz-chatgpt:plan", ChatGPTRecord(fakeChatGPTTokens(expiresIn: 3600)).json)
        let s = ChatGPTSession(account: "plan", service: "doz-chatgpt:plan", keychain: keychain, refresher: { fake.run($0) })
        s.load()
        // A new host: no access token in memory — the first use renews (the refresh token rotates).
        let (a0, _) = s.read()
        XCTAssertEqual(OpenAIAccess.claims(a0 ?? "")?["jti"] as? String, "ACCESS-2")
        XCTAssertEqual(fake.calls, 1)
        // Signed in just now (adopt): the token as it is, no refresh.
        s.adopt(fakeChatGPTTokens(expiresIn: 3600))
        let (a1, n1) = s.read()
        XCTAssertNotNil(a1)
        XCTAssertNil(n1)
        XCTAssertEqual(fake.calls, 1)
        // An upstream 401 marks it stale: the next read renews, keeps the ROTATED refresh token in the keychain.
        let g = s.generation
        s.markStale()
        XCTAssertGreaterThan(s.generation, g, "the vault re-reads at once")
        let (a2, _) = s.read()
        XCTAssertEqual(fake.calls, 2)
        XCTAssertEqual(OpenAIAccess.claims(a2 ?? "")?["jti"] as? String, "ACCESS-2")
        XCTAssertEqual(ChatGPTRecord.parse(keychain.get("doz-chatgpt:plan") ?? "")?.refreshToken, "RT-2")
        // Many requests at once near expiry: ONE refresh.
        fake.answer = { _ in .renewed(fakeChatGPTTokens(access: "ACCESS-3", refresh: "RT-3", expiresIn: 3600)) }
        s.adopt(fakeChatGPTTokens(access: "ACCESS-2", refresh: "RT-2", expiresIn: 60))
        let group = DispatchGroup()
        for _ in 0..<8 { group.enter(); DispatchQueue.global().async { _ = s.read(); group.leave() } }
        group.wait()
        XCTAssertEqual(fake.calls, 3, "one refresh for eight requests")
        // Signed out: every read and the guest's renewal say what to do — no token, no other account.
        fake.answer = { _ in .signedOut("refresh_token_reused") }
        s.markStale()
        let (a4, n4) = s.read()
        XCTAssertNil(a4)
        XCTAssertTrue(n4?.contains("doz account add plan --chatgpt --force") == true, n4 ?? "")
        let ans = String(decoding: s.renewalAnswer(placeholder: "doz_cred_ab"), as: UTF8.self)
        XCTAssertTrue(ans.hasPrefix("HTTP/1.1 401") && ans.contains("refresh_token_reused"), ans)
        XCTAssertEqual(s.state.label, "signed-out")
        // A network failure with an unexpired access token: it keeps working, and says nothing yet.
        let net = FakeRefresh()
        net.answer = { _ in .unavailable("offline") }
        keychain.put("doz-chatgpt:n", ChatGPTRecord(fakeChatGPTTokens(expiresIn: 3600)).json)
        let s2 = ChatGPTSession(account: "n", service: "doz-chatgpt:n", keychain: keychain, refresher: { net.run($0) })
        s2.load()
        s2.adopt(fakeChatGPTTokens(expiresIn: 3600))
        s2.markStale()
        XCTAssertNotNil(s2.read().secret)
        // The keychain item gone: missing, with the command.
        let s3 = ChatGPTSession(account: "gone", service: "doz-chatgpt:gone", keychain: keychain, refresher: { net.run($0) })
        s3.load()
        XCTAssertEqual(s3.state, .missing)
        XCTAssertTrue(s3.read().notice?.contains("doz account add gone --chatgpt --force") == true)
    }

    // MARK: the keychain's limit (rc.2: a 4 KB sign-in was stored truncated on a real Mac)

    func testTheStoresRefuseWhatOneItemCannotHold() throws {
        let big = String(repeating: "x", count: Keychain.maximumSecretBytes + 1)
        XCTAssertThrowsError(try MemoryKeychain().write(service: "s", account: "u", secret: big))
        XCTAssertThrowsError(try keychain.write(service: "s", account: "u", secret: big))
        XCTAssertNil(keychain.get("s"), "nothing written")
        XCTAssertNoThrow(try MemoryKeychain().write(service: "s", account: "u", secret: String(big.dropLast())))
        // The real tool's line: the largest secret still fits a `security -i` line (hex + the command).
        let line = "add-generic-password -U -a \"\(String(repeating: "u", count: 64))\" -s \"doz-chatgpt:\(String(repeating: "n", count: 40))#8\" -X \"\(String(repeating: "ab", count: Keychain.maximumSecretBytes))\"\n"
        XCTAssertLessThanOrEqual(line.utf8.count, Keychain.maximumLineBytes)
        XCTAssertLessThan(Keychain.maximumLineBytes, 4096)
    }

    func testChunksRoundTripAndNeverLeaveAPartialSecret() throws {
        let k = MemoryKeychain()
        let small = "short-secret"
        try KeychainChunks.write(k, service: "doz-chatgpt:a", secret: small)
        XCTAssertEqual(KeychainChunks.read(k, service: "doz-chatgpt:a"), .found(small))
        XCTAssertEqual(k.items(servicePrefix: "doz-chatgpt:a").map(\.service), ["doz-chatgpt:a"], "one item when it fits")
        let long = (0..<4500).map { _ in "abcdefghij".randomElement()! }.map(String.init).joined()
        try KeychainChunks.write(k, service: "doz-chatgpt:a", secret: long)
        XCTAssertEqual(KeychainChunks.read(k, service: "doz-chatgpt:a"), .found(long), "parts joined back")
        XCTAssertEqual(k.items(servicePrefix: "doz-chatgpt:a").count, 4, "a header and three parts")
        try KeychainChunks.write(k, service: "doz-chatgpt:a", secret: small)
        XCTAssertEqual(k.items(servicePrefix: "doz-chatgpt:a").map(\.service), ["doz-chatgpt:a"], "back to one: the old parts removed")
        // A damaged part: the digest refuses it (never a wrong secret).
        try KeychainChunks.write(k, service: "doz-chatgpt:a", secret: long)
        try k.write(service: "doz-chatgpt:a#2", account: "u", secret: "tampered")
        XCTAssertEqual(KeychainChunks.read(k, service: "doz-chatgpt:a"), .failed)
        // A part that cannot be written: nothing is left at all.
        keychain.failWrites = ["doz-chatgpt:b#2"]
        XCTAssertThrowsError(try KeychainChunks.write(keychain, service: "doz-chatgpt:b", secret: long))
        XCTAssertTrue(keychain.items(servicePrefix: "doz-chatgpt:b").isEmpty, "no partial secret")
        XCTAssertThrowsError(try KeychainChunks.write(k, service: "doz-chatgpt:c", secret: String(repeating: "z", count: Keychain.maximumSecretBytes * 9)))
        XCTAssertTrue(k.items(servicePrefix: "doz-chatgpt:c").isEmpty)
    }

    func testAFailedAddExitsWithAnErrorAndLeavesNoItem() async throws {
        keychain.failWrites = ["doz-chatgpt:plan"]
        let c = await core()
        let m = await add(c, "plan", .chatgpt, fakeChatGPTTokens().json)
        XCTAssertEqual(m.error?.code, .failed, "\(String(describing: m.error))")
        XCTAssertNil(keychain.get("doz-chatgpt:plan"))
        XCTAssertFalse(AccountStore(store: DozerStore(root: root)).load().accounts.contains { $0.name == "plan" }, "not registered")
    }

    func testARotationThatCannotBeKeptLeavesNoSpentToken() throws {
        let fake = FakeRefresh()
        keychain.put("doz-chatgpt:r", ChatGPTRecord(fakeChatGPTTokens(refresh: "RT-OLD")).json)
        let s = ChatGPTSession(account: "r", service: "doz-chatgpt:r", keychain: keychain, refresher: { fake.run($0) })
        s.load()
        keychain.failWrites = ["doz-chatgpt:r"]
        let (a, n) = s.read()
        XCTAssertNotNil(a, "the renewed access token is used (memory)")
        XCTAssertNil(n)
        XCTAssertNil(keychain.get("doz-chatgpt:r"), "the spent refresh token is not left behind")
        XCTAssertTrue(s.notKept)
        s.load()
        XCTAssertNotNil(s.read().secret, "still usable in this host")
        // A long refresh token is chunked, and the rotation rewrites the parts.
        keychain.failWrites = []
        fake.answer = { _ in .renewed(fakeChatGPTTokens(access: "ACCESS-L", refresh: "RT-" + String(repeating: "L", count: 2500))) }
        s.markStale()
        _ = s.read()
        XCTAssertTrue(keychain.get("doz-chatgpt:r")?.hasPrefix(KeychainChunks.headerPrefix) == true, "kept in parts")
        let s2 = ChatGPTSession(account: "r", service: "doz-chatgpt:r", keychain: keychain, refresher: { fake.run($0) })
        s2.load()
        XCTAssertEqual(s2.state, .ok)
        XCTAssertNotNil(s2.guestIDToken)
    }

    func testTheKeptClaimsAreWhatCodexReads() throws {
        let t = fakeChatGPTTokens()
        let r = ChatGPTRecord(t)
        let g = r.idToken
        XCTAssertTrue(g.hasSuffix("." + OpenAIAccess.guestSignature))
        XCTAssertEqual(OpenAIAccess.accountID(idToken: g), "acct-9")
        XCTAssertEqual(OpenAIAccess.planType(idToken: g), "pro")
        XCTAssertEqual(OpenAIAccess.email(idToken: g), "person@example.invalid")
        XCTAssertNil((OpenAIAccess.claims(g)?[OpenAIAccess.authClaim] as? [String: Any])?["organizations"], "the rest is dropped")
        XCTAssertLessThan(r.json.utf8.count, 600)
        // An rc.1 item (the whole tokens) still reads, slimmed.
        XCTAssertEqual(ChatGPTRecord.parse(t.json)?.refreshToken, "RT-1")
    }

    // MARK: versions

    func testCodexsReleaseIsTheVersionAndThePlatformTarballsIntegrity() async throws {
        let store = DozerStore(root: root)
        let asked = Locked<[String]>([])
        let registry = NpmRegistry(lookup: { p, tag in
            asked.mutate { $0.append("\(p)@\(tag)") }
            if tag == "latest" { return AgentRelease(version: "0.161.0", integrity: "sha512-MAIN") }
            return AgentRelease(version: tag, integrity: "sha512-PLATFORM")
        })
        let settings = DozerSettings(text: "")
        let f = await AgentVersions.refresh("codex", store: store, settings: settings, registry: registry)
        XCTAssertEqual(f.latest, "0.161.0")
        XCTAssertEqual(asked.value, ["@openai/codex@latest", "@openai/codex@0.161.0-linux-arm64"])
        XCTAssertEqual(AgentVersions.all(store)["codex"]?.latest, AgentRelease(version: "0.161.0", integrity: "sha512-PLATFORM"))
        let spec = try XCTUnwrap(try AgentVersions.spec("codex", purpose: .prepare, store: store, settings: settings))
        let script = spec.steps.map { $0.argv.joined(separator: " ") }.joined(separator: "\n")
        XCTAssertTrue(script.contains("codex-0.161.0-linux-arm64.tgz") && script.contains("'sha512-PLATFORM'"))
        XCTAssertEqual(AgentVersions.currentRecipe(for: spec), spec, "W28: this doz's recipe")
        // Never asked: the pin.
        XCTAssertEqual(try AgentVersions.spec("codex", purpose: .prepare, store: DozerStore(root: root.appendingPathComponent("x")), settings: settings)?.agent?.version,
                       AgentImages.codexPinned.version)
    }

    // MARK: the launcher

    func testTheLauncherSkipsApprovalsAndDeliversTheFacts() {
        let s = AgentImages.codexLauncherScript
        XCTAssertTrue(s.contains("--dangerously-bypass-approvals-and-sandbox"))
        XCTAssertTrue(s.contains("check_for_update_on_startup=false"))
        XCTAssertTrue(s.contains("cli_auth_credentials_store=file"))
        XCTAssertTrue(s.contains("developer_instructions=$dev"))
        XCTAssertTrue(s.contains("DOZ_CODEX_PERMISSIONS"))
        XCTAssertTrue(s.contains(#"[ "$(id -u)" = 0 ] && mode=ask"#))
        XCTAssertTrue(s.contains("trust_level"), "the folder is trusted (no trust prompt)")
        XCTAssertFalse(s.contains("OPENAI_API_KEY"), "no image spec names a credential")
        XCTAssertFalse(s.contains("auth.json"), "the credentials are the host's, at each session")
        // `login` / `--version` go straight through, without the agent's flags.
        XCTAssertTrue(s.contains("login|logout|mcp"))
    }

    /// Dozer never reads or writes the Mac's own Codex home: no Mac-side source names ~/.codex.
    func testDozerNeverTouchesTheMacsCodexHome() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        for dir in ["DozerHost", "DozerCLI", "DozerWeb"] {
            let e = FileManager.default.enumerator(at: src.appendingPathComponent(dir), includingPropertiesForKeys: nil)
            while let u = e?.nextObject() as? URL {
                guard u.pathExtension == "swift", let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
                // rc.3's ONE production exception: the reader of this Mac's Codex login (`mac` for Codex) — read-only.
                if u.lastPathComponent == "CodexMacLogin.swift" {
                    XCTAssertFalse(text.contains(".write(to:") || text.contains("createFile(") || text.contains("removeItem("), "the Mac's Codex home is only ever read")
                    continue
                }
                for (i, line) in text.components(separatedBy: "\n").enumerated()
                    where line.range(of: #"[~/"]\.codex"#, options: .regularExpression) != nil {
                    let guest = line.contains("/home/agent/.codex") || line.contains("imageSpec.home") || line.contains("~/.codex/auth.json")
                        || line.contains("`~/.codex`") || line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                        || line.contains("(~/.codex)") || line.contains("Mac's ~/.codex") || line.contains("~/.codex is")
                    XCTAssertTrue(guest, "\(u.lastPathComponent):\(i + 1) names .codex outside a guest path: \(line)")
                }
                XCTAssertFalse(text.contains("homeDirectoryForCurrentUser.appendingPathComponent(\".codex"), u.lastPathComponent)
            }
        }
    }
}

extension HostCore {
    /// Tests: the auth.json script a session start of `name` would run.
    func codexAuthScriptForTests(_ name: String) -> String? { managed[name].flatMap { codexAuthScript($0) } }
}

/// 599i rc.2: the REAL login keychain's per-item behaviour through `SystemKeychain` — run only on purpose
/// (`DOZ_TEST_REAL_KEYCHAIN=1`), with a throwaway service `doz-test-limit-<uuid>` that is always deleted.
final class RealKeychainLimitTests: XCTestCase {
    func testTheRealKeychainTakesTheLimitWholeAndRefusesMoreWithoutAPartialItem() throws {
        guard ProcessInfo.processInfo.environment["DOZ_TEST_REAL_KEYCHAIN"] == "1" else { throw XCTSkip("DOZ_TEST_REAL_KEYCHAIN=1 runs it") }
        let k = SystemKeychain()
        let svc = "doz-test-limit-" + UUID().uuidString.prefix(8).lowercased()
        defer { try? k.delete(service: svc, account: Keychain.user) }
        let max = String((0..<Keychain.maximumSecretBytes).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        try k.write(service: svc, account: Keychain.user, secret: max)
        XCTAssertEqual(k.read(service: svc, account: Keychain.user).value, max, "the largest secret allowed is stored whole")
        XCTAssertThrowsError(try k.write(service: svc, account: Keychain.user, secret: max + max))
        XCTAssertEqual(k.read(service: svc, account: Keychain.user).value, max, "a refused write changes nothing (refused before security runs)")
        // Chunked: a 4.5 KB secret through parts, read back whole, then removed with every part.
        let big = String((0..<4500).map { _ in "ABCDEFGHIJ".randomElement()! })
        try KeychainChunks.write(k, service: svc, secret: big)
        XCTAssertEqual(KeychainChunks.read(k, service: svc), .found(big))
        KeychainChunks.remove(k, service: svc)
        XCTAssertEqual(k.read(service: svc, account: Keychain.user), .absent)
        XCTAssertEqual(k.read(service: svc + "#1", account: Keychain.user), .absent)
    }
}
