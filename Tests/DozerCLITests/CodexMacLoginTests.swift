import Foundation
@testable import DozerKit
import XCTest
@testable import DozerCLI
@testable import DozerHost

// 599i rc.3 — `mac` for Codex: THIS Mac's own Codex login, read-only. Every test here uses a FAKE Codex home
// (a scratch folder) — never the real ~/.codex — and checks Dozer never writes it.

final class CodexMacLoginTests: XCTestCase {
    private var root: URL!
    private var codexHome: URL!
    let keychain = FakeKeychain()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-cxmac-\(UUID().uuidString.prefix(8))")
        codexHome = root.appendingPathComponent("codex-home")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// The Mac's Codex writing its auth.json (as `codex login` / a refresh does) — the FAKE home only.
    func macCodexSignsIn(access: String = "ACCESS-MAC-1", expiresIn: TimeInterval = 3600, refresh: String = "RT-MAC-NEVER-READ") {
        let t = fakeChatGPTTokens(access: access, refresh: refresh, expiresIn: expiresIn)
        let o: [String: Any] = ["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(), "last_refresh": "2026-10-07T00:00:00Z",
                                "tokens": ["id_token": t.idToken, "access_token": t.accessToken, "refresh_token": t.refreshToken, "account_id": "acct-9"]]
        let tmp = codexHome.appendingPathComponent("auth.json.tmp")
        try! JSONSerialization.data(withJSONObject: o).write(to: tmp)
        _ = rename(tmp.path, codexHome.appendingPathComponent("auth.json").path)
    }

    func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        for f in (try? FileManager.default.contentsOfDirectory(atPath: codexHome.path)) ?? [] {
            let a = try? FileManager.default.attributesOfItem(atPath: codexHome.appendingPathComponent(f).path)
            out[f] = "\(a?[.size] ?? 0)|\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }
        return out
    }

    func services(runner: KeepaliveRunning = FakeRunner(), binary: String? = "/fake/codex") -> CredentialServices {
        let home = codexHome!
        return CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                  keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600),
                                  codexHome: { home }, codexBinary: { binary }, codexRunner: runner)
    }

    func core(_ s: CredentialServices? = nil) async -> HostCore {
        let c = HostCore(store: DozerStore(root: root.appendingPathComponent("store")), readOnly: false, version: "test", services: s ?? services())
        await c.load()
        return c
    }

    // MARK: reading

    func testItReadsOnlyTheAccessTokenAndWhatTheGuestNeeds() throws {
        macCodexSignsIn()
        let r = CodexMacLogin.read(codexHome)
        XCTAssertEqual(r.state, .ok)
        let t = try XCTUnwrap(r.token)
        XCTAssertEqual(OpenAIAccess.claims(t.accessToken)?["jti"] as? String, "ACCESS-MAC-1")
        XCTAssertEqual(t.accountID, "acct-9")
        XCTAssertFalse("\(t)".contains("ACCESS-MAC"))
        // The refresh token is not in anything Dozer keeps.
        XCTAssertFalse(String(reflecting: t).contains("RT-MAC-NEVER-READ"))
        XCTAssertFalse(t.claims.contains("RT-MAC"))
        XCTAssertFalse(String(decoding: OpenAIAccess.base64URLDecode(t.claims) ?? Data(), as: UTF8.self).contains("RT-MAC"))
        XCTAssertEqual(OpenAIAccess.planType(idToken: OpenAIAccess.idToken(claims: t.claims)), "pro")
    }

    func testTheOtherStatesAreSaid() throws {
        XCTAssertEqual(CodexMacLogin.read(codexHome).state, .signedOut)
        XCTAssertEqual(CodexMacLogin.read(nil).state, .signedOut)
        try "cli_auth_credentials_store = \"keyring\"\n".write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(CodexMacLogin.read(codexHome).state, .keyring)
        try JSONSerialization.data(withJSONObject: ["auth_mode": "apikey", "OPENAI_API_KEY": "sk-MAC"]).write(to: codexHome.appendingPathComponent("auth.json"))
        XCTAssertEqual(CodexMacLogin.read(codexHome).state, .apiKey)
        macCodexSignsIn(expiresIn: -60)
        XCTAssertEqual(CodexMacLogin.read(codexHome).state, .expired)
        let s = CodexMacSession(codexHome: codexHome, keepaliveEnabled: { false })
        XCTAssertTrue(s.problem()?.contains("your Mac's Codex login has expired — run codex on the Mac") == true)
        XCTAssertTrue(s.problem()?.contains("codex.keep_alive") == true)
    }

    /// The test guard: no fake home, no memory seam, inside XCTest → it would stop the run. Asked without the
    /// XCTest condition, the memory seam answers "none" and DOZ_TEST_CODEX_HOME wins.
    func testTestsResolveOnlyAFakeHome() {
        XCTAssertEqual(CodexMacLogin.resolveHome(environment: ["DOZ_TEST_CODEX_HOME": codexHome.path])?.path, codexHome.path)
        XCTAssertNil(CodexMacLogin.resolveHome(environment: ["DOZ_TEST_CREDENTIALS": "memory"]))
        XCTAssertNil(CodexMacLogin.resolveBinary(environment: ["DOZ_TEST_CREDENTIALS": "memory"]))
    }

    // MARK: the proxy's read: on use, re-read when the Mac refreshed, never another account

    func testARefreshTheMacDidIsPickedUpAtOnceAndStaleIsDozersMessage() throws {
        macCodexSignsIn(access: "ACCESS-MAC-1", expiresIn: -10)
        let before = snapshot()
        let s = CodexMacSession(codexHome: codexHome, keepaliveEnabled: { false })
        let v = CredentialVault()
        v.setProvider(.chatgpt, ttl: 3600, version: { s.version }, read: { s.read() })
        let ph = try XCTUnwrap(v.mintForFile("chatgpt"))
        let head = Array("POST /backend-api/codex/responses HTTP/1.1\r\nHost: chatgpt.com\r\nAuthorization: Bearer \(ph)\r\n\r\n".utf8)
        guard case .refuse(401, let why) = v.rewrite(head: head, host: "chatgpt.com") else { return XCTFail("an expired Mac login must be refused") }
        XCTAssertTrue(why.contains("your Mac's Codex login has expired"), why)
        // The Mac's Codex refreshes (a new file): the next request has the new token — no restart, despite the long ttl.
        usleep(20_000)
        macCodexSignsIn(access: "ACCESS-MAC-2", expiresIn: 3600)
        guard case .swapped(let out, _) = v.rewrite(head: head, host: "chatgpt.com") else { return XCTFail("not swapped after the Mac's refresh") }
        let sent = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(sent.contains("Bearer " + CodexMacLogin.read(codexHome).token!.accessToken))
        // Codex's own renewal in the guest: the same placeholder back, the Mac's claims, nothing renewed by Dozer.
        let ans = String(decoding: s.renewalAnswer(placeholder: ph), as: UTF8.self)
        XCTAssertTrue(ans.hasPrefix("HTTP/1.1 200") && ans.contains(ph) && !ans.contains("ACCESS-MAC"), ans)
        XCTAssertNotEqual(snapshot(), before, "(the fake Mac Codex rewrote its file)")
        let after = snapshot()
        _ = s.read(); _ = s.current(); _ = s.problem()
        XCTAssertEqual(snapshot(), after, "Dozer never writes the Mac's Codex home")
    }

    // MARK: keep-alive

    func testTheKeepaliveRunsTheMacsCodexOnlyWhenDueUsedAndOn() throws {
        let runner = FakeRunner()
        var on = false
        let lockedOn = Locked(false)
        macCodexSignsIn(expiresIn: 3600)
        let s = CodexMacSession(codexHome: codexHome, runner: runner, binary: { "/fake/codex" }, keepaliveEnabled: { lockedOn.value })
        _ = on
        XCTAssertFalse(s.keepaliveIfDue(), "off")
        lockedOn.mutate { $0 = true }
        XCTAssertFalse(s.keepaliveIfDue(), "not near expiry")
        macCodexSignsIn(access: "ACCESS-NEAR", expiresIn: 200)
        XCTAssertFalse(s.keepaliveIfDue(), "near expiry but no sandbox used it")
        _ = s.read()
        // The fake codex: what the Mac's codex doctor does — refresh its own file.
        runner.onRun = { [self] in self.macCodexSignsIn(access: "ACCESS-RENEWED", expiresIn: 3600) }
        XCTAssertTrue(s.keepaliveIfDue())
        XCTAssertEqual(runner.runs.count, 1)
        XCTAssertEqual(runner.runs.first?.0, "/fake/codex")
        XCTAssertEqual(runner.runs.first?.1, ["doctor"], "no model call")
        XCTAssertEqual(runner.runs.first?.2["CODEX_HOME"], codexHome.path)
        XCTAssertEqual(OpenAIAccess.claims(s.current().token!.accessToken)?["jti"] as? String, "ACCESS-RENEWED")
        XCTAssertFalse(s.keepaliveIfDue(), "not again for this expiry")
    }

    // MARK: the host

    func testMacIsTheDefaultCodexAccountWhenTheMacsCodexIsSignedIn() async throws {
        let c = await core()
        // Not signed in: Codex needs an account.
        var r = HostRequest(.create, name: "cx0")
        r.create = CreateOptions(image: "codex")
        do { let e = await c.handle(r).error; XCTAssertTrue(e?.message.contains("Codex needs an OpenAI account") == true) }
        // Signed in on the Mac: Codex follows it; nothing is written to the keychain or accounts.json.
        macCodexSignsIn()
        let before = snapshot()
        r = HostRequest(.create, name: "cx")
        r.create = CreateOptions(image: "codex")
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
        let info = try XCTUnwrap(m.result).decode(SandboxInfo.self)
        XCTAssertNil(info.credentialProblem)
        XCTAssertTrue(keychain.writes.isEmpty)
        let v = try await XCTUnwrapAsync(await c.vault(of: "cx"))
        let ph = try XCTUnwrap(v.mintForFile("chatgpt"))
        let head = Array("POST /x HTTP/1.1\r\nHost: chatgpt.com\r\nAuthorization: Bearer \(ph)\r\n\r\n".utf8)
        guard case .swapped(let out, _) = v.rewrite(head: head, host: "chatgpt.com") else { return XCTFail() }
        XCTAssertTrue(String(decoding: out, as: UTF8.self).contains(CodexMacLogin.read(codexHome).token!.accessToken))
        // The guest's auth.json: placeholders, the Mac's claims (unsigned) — never its tokens.
        let script = try await XCTUnwrapAsync(await c.codexAuthScriptForTests("cx"))
        let tokensOnMac = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: codexHome.appendingPathComponent("auth.json"))) as? [String: Any])["tokens"] as! [String: Any]
        for k in ["access_token", "refresh_token", "id_token"] {
            let raw = tokensOnMac[k] as! String
            let b64 = script.components(separatedBy: "printf %s '").dropFirst().first!.components(separatedBy: "'").first!
            XCTAssertFalse(String(decoding: Data(base64Encoded: b64)!, as: UTF8.self).contains(raw), k)
        }
        // account ls: mac (codex-mac) with plan and email, the default; Claude's mac unchanged.
        let rows = try await c.handle(HostRequest(.accountList)).result!.decode([AccountRow].self)
        let cm = try XCTUnwrap(rows.first { $0.kind == "codex-mac" })
        XCTAssertEqual(cm.name, "mac")
        XCTAssertEqual(cm.plan, "pro")
        XCTAssertEqual(cm.identity, "person@example.invalid")
        XCTAssertTrue(cm.isDefault)
        XCTAssertEqual(cm.usedBy, ["cx"])
        XCTAssertEqual(rows.first { $0.kind == "mac" }?.name, "mac")
        // A Claude Code sandbox is untouched by it.
        var cc = HostRequest(.create, name: "cc")
        cc.create = CreateOptions(image: "claude-code")
        do { let e = await c.handle(cc).error; XCTAssertNil(e, e?.message ?? "") }
        let ccVault = try await XCTUnwrapAsync(await c.vault(of: "cc"))
        XCTAssertFalse(ccVault.issuesPlaceholder("chatgpt"))
        // The facts say the Mac's own login.
        let pm = await c.handle(HostRequest(.agentPrompt, name: "cx"))
        let report = try XCTUnwrap(try pm.result?.decode(AgentPromptReport.self))
        XCTAssertTrue(report.text?.contains("the user's own Codex login on their Mac (the account mac)") == true, report.text ?? "")
        // Signed out on the Mac: the proxy says so — never another account (the openai key beside it is not used).
        _ = await c.handle(HostRequest.accountAdd(name: "okey", kind: .openaiKey, plan: nil, secret: "sk-proj-FAKEFAKEFAKEFAKEFAKE"))
        try FileManager.default.removeItem(at: codexHome.appendingPathComponent("auth.json"))
        guard case .refuse(401, let why) = v.rewrite(head: head, host: "chatgpt.com") else { return XCTFail("signed out must be refused") }
        XCTAssertTrue(why.contains("this Mac's Codex is not signed in"), why)
        let ls = try await c.handle(HostRequest(.ls)).result!.decode([SandboxInfo].self)
        XCTAssertNotNil(ls.first { $0.name == "cx" }?.credentialProblem, "the sandbox's page says it has no credential it can use")
        var use = HostRequest(.accountUse, name: "cx")
        use.account = "mac"
        do { let e = await c.handle(use).error; XCTAssertTrue(e?.message.contains("not signed in") == true, "mac cannot be chosen while signed out") }
        // Dozer wrote nothing to the Mac's Codex home.
        macCodexSignsIn()
        _ = before
        let s2 = snapshot()
        _ = await c.handle(HostRequest(.accountList))
        _ = v.rewrite(head: head, host: "chatgpt.com")
        XCTAssertEqual(snapshot(), s2, "never a write to CODEX_HOME")
        // --codex: the Codex default by name.
        var d = HostRequest(.accountDefault)
        d.account = "okey"
        d.accountKind = "codex"
        do { let e = await c.handle(d).error; XCTAssertNil(e, e?.message ?? "") }
        XCTAssertEqual(AccountStore(store: DozerStore(root: root.appendingPathComponent("store"))).load().openaiDefault, "okey")
        d.account = "mac"
        do { let e = await c.handle(d).error; XCTAssertNil(e, e?.message ?? "") }
        XCTAssertEqual(AccountStore(store: DozerStore(root: root.appendingPathComponent("store"))).load().defaultAccount, "mac", "Claude's default untouched")
    }

    func testDoctorSaysHowTheMacsCodexLoginStands() {
        XCTAssertTrue(Doctor.codexLoginCheck(home: codexHome, settings: DozerSettings(text: "")).detail.contains("not signed in"))
        macCodexSignsIn()
        let ok = Doctor.codexLoginCheck(home: codexHome, settings: DozerSettings(text: "[codex]\nkeep_alive = true\n"))
        XCTAssertEqual(ok.status, .ok)
        XCTAssertTrue(ok.detail.contains("signed in") && ok.detail.contains("keep-alive on"), ok.detail)
        macCodexSignsIn(expiresIn: -5)
        XCTAssertEqual(Doctor.codexLoginCheck(home: codexHome, settings: DozerSettings(text: "")).status, .warn)
    }
}
