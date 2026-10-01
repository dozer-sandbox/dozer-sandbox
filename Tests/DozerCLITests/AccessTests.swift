import Darwin
import Foundation
import XCTest
@testable import DozerKit
@testable import DozerHost

/// 599e: the Access step — what a check says (confirmed, failed with its reason, off, unchecked), that a
/// failure is kept (Skip) and never blocks, that an answer counts only for the choice it was given for, the
/// default GitHub key (never echoed), the SSH agent's key list, the choices as defaults for new sandboxes,
/// and the web's strict bodies. SEAMS ONLY: a scratch XDG, a fake gh that is logged out, an agent socket
/// this test serves, the memory keychain — never the user's gh, ssh-agent, GitHub, settings or keychain,
/// and nothing here reaches the network.
final class AccessTests: XCTestCase {
    var root: URL!
    var store: DozerStore { DozerStore(root: root.appendingPathComponent("store")) }
    var xdg: URL { root.appendingPathComponent("xdg") }
    /// The environment a check sees: scratch everything, no SSH_AUTH_SOCK, no network seam.
    var env: [String: String] {
        ["XDG_CONFIG_HOME": xdg.path, "HOME": root.path, "DOZ_TEST_GH": root.appendingPathComponent("gh").path,
         "DOZ_TEST_SSH_AUTH_SOCK": root.appendingPathComponent("no-agent.sock").path]
    }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/dzac-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("store"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: xdg.appendingPathComponent("dozer-sandbox"), withIntermediateDirectories: true)
        // A gh that is logged out (exit 1) — a check never gets a token to send anywhere.
        try "#!/bin/sh\necho 'not logged in' >&2\nexit 1\n".write(to: root.appendingPathComponent("gh"), atomically: true, encoding: .utf8)
        chmod(root.appendingPathComponent("gh").path, 0o755)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func core(readOnly: Bool = false) -> HostCore {
        HostCore(store: store, readOnly: readOnly, version: "t", services: .forHost(environment: ["DOZ_TEST_CREDENTIALS": "memory"]),
                 newStoreDefaultAccount: "none")
    }
    private func check(_ c: HostCore, _ items: [String], _ choices: [String: String]) async throws -> AccessReport {
        var r = HostRequest(.access)
        r.check = true
        r.items = items
        r.accessChoices = choices
        return try await c.access(r, environment: env)
    }
    private func item(_ r: AccessReport, _ id: String) -> AccessItem { r.items.first { $0.id == id }! }

    // MARK: what a check says

    func testIdentitySummaries() {
        XCTAssertEqual(GitHubIdentity(login: "u", scopes: ["repo", "read:org"]).summary, "signed in as u — scopes: repo, read:org")
        XCTAssertEqual(GitHubIdentity(login: "u", scopes: []).summary, "signed in as u — no scopes (public data only)")
        XCTAssertEqual(GitHubIdentity(login: "u", repositories: 1).summary, "signed in as u — it can see 1 repository")
        XCTAssertEqual(GitHubIdentity(login: "u", repositories: 3).summary, "signed in as u — it can see 3 repositories")
        XCTAssertEqual(GitHubIdentity(login: "u", repositories: 100).summary, "signed in as u — it can see 100+ repositories")
        XCTAssertEqual(GitHubIdentity(login: "u").summary, "signed in as u")
    }

    func testAChunkedAnswerIsJoined() {
        let d = Data("4\r\n[{}]\r\n3\r\n,{}\r\n0\r\n\r\n".utf8)
        XCTAssertEqual(String(decoding: GitHubAccess.dechunked(d), as: UTF8.self), "[{}],{}")
    }

    func testFailuresAreKeptWithTheirReasonAndNeverBlock() async throws {
        let c = core()
        let r = try await check(c, ["github", "ssh"], ["github": "read", "githubSource": "gh", "ssh": "on"])
        XCTAssertEqual(item(r, "github").state, "failed")
        XCTAssertTrue(item(r, "github").detail.contains("not logged in to github.com"), item(r, "github").detail)
        XCTAssertTrue(item(r, "github").detail.contains("gh auth login"), "the reason says what to do")
        XCTAssertEqual(item(r, "ssh").state, "failed")
        XCTAssertTrue(item(r, "ssh").detail.contains("no ssh-agent"), item(r, "ssh").detail)
        XCTAssertEqual(item(r, "github").choice, "read", "the choice is KEPT (Skip), not turned off")
        XCTAssertTrue(item(r, "github").consequence.contains("read-only"))
        // The record: the same answer, read without a check (and without a host).
        var q = HostRequest(.access)
        let again = try await core(readOnly: true).access(q, environment: env)
        XCTAssertEqual(item(again, "ssh").state, "off", "the settings say off: the record's answer (for \"on\") does not apply")
        try Access.write(github: "read", githubSource: "gh", ssh: "on", environment: env)
        let kept = try await core(readOnly: true).access(q, environment: env)
        XCTAssertEqual(item(kept, "github").state, "failed")
        XCTAssertEqual(item(kept, "ssh").state, "failed")
        XCTAssertNotNil(item(kept, "github").checkedAt)
        // Another choice: the old answer does not count for it.
        q.accessChoices = ["github": "push"]
        let other = try await c.access(q, environment: env)
        XCTAssertEqual(item(other, "github").state, "unchecked")
        // Off: nothing to confirm.
        let off = try await check(c, ["github", "ssh"], ["github": "off", "ssh": "off"])
        XCTAssertEqual(item(off, "github").state, "off")
        XCTAssertEqual(item(off, "ssh").state, "off")
        XCTAssertTrue(item(off, "github").consequence.contains("not signed in to GitHub as you"))
        XCTAssertEqual(off.consequences["github"]?.count, 3)
        // Unknown choices are refused.
        do { _ = try await check(c, ["github"], ["github": "admin"]); XCTFail("accepted") } catch let e as HostError {
            XCTAssertEqual(e.code, .invalid)
        }
    }

    func testTheClaudeAccountIsConfirmedTheAccountAddWay() async throws {
        let c = core()
        var r = try await check(c, ["claude"], [:])
        XCTAssertEqual(item(r, "claude").state, "off", "no account (none): nothing to confirm")
        let key = "sk-ant-api03-" + String(repeating: "Q", count: 40)
        let m = await c.handle(HostRequest.accountAdd(name: "work", kind: .apiKey, plan: nil, secret: key))
        XCTAssertEqual(m.ok, true, m.error?.message ?? "")
        var d = HostRequest(.accountDefault)
        d.account = "work"
        _ = await c.handle(d)
        r = try await check(c, ["claude"], [:])
        XCTAssertEqual(item(r, "claude").state, "failed", "the offline seam cannot check it: kept, not confirmed")
        XCTAssertTrue(item(r, "claude").detail.contains("work could not be checked"), item(r, "claude").detail)
    }

    func testTheDefaultGitHubKeyIsHeldNeverEchoedAndUsedByTheKeySource() async throws {
        let c = core()
        var r = try await check(c, ["github"], ["github": "read", "githubSource": "key"])
        XCTAssertEqual(item(r, "github").state, "failed")
        XCTAssertTrue(item(r, "github").detail.contains("no GitHub key is set"), item(r, "github").detail)
        XCTAssertFalse(r.githubKeySet)
        let token = "github_pat_FAKE599eUNIT" + String(repeating: "k", count: 30)
        var set = HostRequest(.accessGithubKey)
        set.secret = "  " + token + "\n"
        let m = await c.handle(set)
        XCTAssertEqual(m.ok, true, m.error?.message ?? "")
        let text = String(decoding: try JSONEncoder().encode(m), as: UTF8.self)
        XCTAssertFalse(text.contains(token), "never echoed")
        XCTAssertEqual(try m.result?.decode(AccessReport.self).githubKeySet, true)
        XCTAssertEqual(c.services.keychain.read(service: Access.githubKeyService, account: Keychain.user), .found(token), "trimmed")
        let t = Access.githubToken(source: "key", keychain: c.services.keychain, environment: env)
        XCTAssertEqual(t.secret, token, "the key source reads it (as a sandbox's provider does)")
        XCTAssertNil(Access.githubToken(source: "off", keychain: c.services.keychain, environment: env).secret)
        // A bad one is refused, without its value in the message.
        var bad = HostRequest(.accessGithubKey)
        bad.secret = "two words"
        let b = await c.handle(bad)
        XCTAssertEqual(b.error?.code, .invalid)
        XCTAssertFalse(b.error?.message.contains("two words") ?? true)
        // Removed.
        var rm = HostRequest(.accessGithubKey)
        rm.clearSetting = true
        _ = await c.handle(rm)
        r = try await check(c, ["github"], ["github": "read", "githubSource": "key"])
        XCTAssertFalse(r.githubKeySet)
        let record = (try? String(contentsOf: store.root.appendingPathComponent("access.json"), encoding: .utf8)) ?? ""
        XCTAssertFalse(record.contains(token), "access.json holds no token")
        // Without a host: a check needs one.
        var q = HostRequest(.access)
        q.check = true
        let ro = await core(readOnly: true).handle(q)
        XCTAssertEqual(ro.error?.code, .unavailable)
    }

    // MARK: the SSH agent

    /// A one-shot agent on a unix socket: answers REQUEST_IDENTITIES with `answer` (the message body).
    private func fakeAgent(_ path: String, answer: [UInt8]) -> Thread {
        unlink(path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        var a = sockaddr_un()
        a.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &a.sun_path) { p in path.utf8CString.withUnsafeBytes { p.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(p.count))) } }
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        listen(s, 1)
        let t = Thread {
            let c = accept(s, nil, nil)
            var req = [UInt8](repeating: 0, count: 5)
            _ = read(c, &req, 5)
            let n = UInt32(answer.count)
            let out = [UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)] + answer
            _ = out.withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
            close(c)
            close(s)
        }
        t.start()
        return t
    }
    private func sshString(_ s: String) -> [UInt8] { let b = Array(s.utf8); let n = UInt32(b.count); return [UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)] + b }

    func testTheAgentsKeysAreListed() throws {
        let path = root.appendingPathComponent("a.sock").path
        _ = fakeAgent(path, answer: [12, 0, 0, 0, 2] + sshString("blob1") + sshString("one@example.invalid") + sshString("blob2") + sshString("two@example.invalid"))
        usleep(50_000)
        guard case .success(let keys) = SSHAgentRelay.listKeys(socket: path) else { return XCTFail("no list") }
        XCTAssertEqual(keys, ["one@example.invalid", "two@example.invalid"])
        _ = fakeAgent(path, answer: [5])                                      // SSH_AGENT_FAILURE
        usleep(50_000)
        guard case .failure(let f) = SSHAgentRelay.listKeys(socket: path) else { return XCTFail("a failure listed") }
        XCTAssertTrue(f.reason.contains("not a list of keys"), f.reason)
        guard case .failure(let none) = SSHAgentRelay.listKeys(socket: root.appendingPathComponent("none.sock").path) else { return XCTFail() }
        XCTAssertTrue(none.reason.contains("no ssh-agent"))
    }

    func testSSHIsConfirmedWithItsKeyCount() async throws {
        let path = root.appendingPathComponent("b.sock").path
        _ = fakeAgent(path, answer: [12, 0, 0, 0, 1] + sshString("blob") + sshString("me@example.invalid"))
        usleep(50_000)
        var e = env
        e["DOZ_TEST_SSH_AUTH_SOCK"] = path
        var r = HostRequest(.access)
        r.check = true
        r.items = ["ssh"]
        r.accessChoices = ["ssh": "on"]
        let rep = try await core().access(r, environment: e)
        XCTAssertEqual(item(rep, "ssh").state, "confirmed")
        XCTAssertEqual(item(rep, "ssh").detail, "the ssh-agent has 1 key: me@example.invalid")
    }

    // MARK: the defaults for new sandboxes

    func testTheChoicesAreTheDefaultsForNewSandboxes() throws {
        XCTAssertEqual(try Access.write(github: "push", githubSource: "key", ssh: "on", environment: env).count, 3)
        XCTAssertEqual(try Access.write(github: "push", githubSource: "key", ssh: "on", environment: env), [], "the same again: nothing to write")
        let s = DozerSettings.load(environment: env)
        XCTAssertEqual(s.string(SettingKey.defaultGithub), "push")
        XCTAssertEqual(s.string(SettingKey.githubCredentials), "key")
        XCTAssertEqual(s.string(SettingKey.sshAgent), "on")
        XCTAssertThrowsError(try Access.write(github: "admin", githubSource: nil, ssh: nil, environment: env))
        // New sandboxes: "Use GitHub as you" + "Push to GitHub" from the setting…
        let (p, _) = try DozerImages.spec(name: "g1", options: CreateOptions(image: "python-claude-code"), store: store, environment: env)
        XCTAssertEqual(AgentPermissions.gitHubMode(p.network.policy?.permissions), .push)
        // …read only…
        try Access.write(github: "read", githubSource: nil, ssh: nil, environment: env)
        let (r, _) = try DozerImages.spec(name: "g2", options: CreateOptions(image: "python-claude-code"), store: store, environment: env)
        XCTAssertEqual(AgentPermissions.gitHubMode(r.network.policy?.permissions), .read)
        // …a sandbox can differ (--allow -github:as-you; the form's exact list)…
        var o = CreateOptions(image: "python-claude-code")
        o.allow = ["-github:as-you"]
        let (d, _) = try DozerImages.spec(name: "g3", options: o, store: store, environment: env)
        XCTAssertNil(AgentPermissions.gitHubMode(d.network.policy?.permissions))
        var f = CreateOptions(image: "python-claude-code")
        f.permissions = ["github"]
        let (fm, _) = try DozerImages.spec(name: "g4", options: f, store: store, environment: env)
        XCTAssertNil(AgentPermissions.gitHubMode(fm.network.policy?.permissions), "the form's exact permissions win")
        let (lk, _) = try DozerImages.spec(name: "g6", options: CreateOptions(image: "python-claude-code", network: "locked"), store: store, environment: env)
        XCTAssertEqual(lk.network.policy?.permissions, ["model"], "a named network is exactly its preset")
        // …and off (the default) adds nothing.
        try Access.write(github: "off", githubSource: nil, ssh: nil, environment: env)
        let (n, _) = try DozerImages.spec(name: "g5", options: CreateOptions(image: "python-claude-code"), store: store, environment: env)
        XCTAssertNil(AgentPermissions.gitHubMode(n.network.policy?.permissions))
        XCTAssertEqual(DozerSettings.definition(SettingKey.defaultGithub)?.defaultValue, .string("off"), "nothing on silently")
    }
}
