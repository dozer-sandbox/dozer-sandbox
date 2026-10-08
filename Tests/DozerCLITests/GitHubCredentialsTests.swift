import Darwin
import Foundation
import XCTest
@testable import DozerKit
@testable import DozerHost
@testable import DozerCLI

/// 599d: the user's GitHub login by proxy insertion — the placeholder swap (Bearer, token, git's Basic),
/// host scoping, swap-only, the read-on-use source, the read-only classifier (GraphQL included), the
/// permissions, settings, the guest's git setup, the facts. Never a real token: "ghp_FAKE…" values only.
final class GitHubCredentialsTests: XCTestCase {
    private let real = "ghp_FAKEtoken0000000000000000000000000000"
    private func head(_ s: String) -> [UInt8] { Array(s.utf8) }
    private func basic(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    private func vault(reads: Counter? = nil, secret: String? = nil, notice: String? = nil) -> (CredentialVault, String) {
        let v = CredentialVault()
        let s = secret ?? real
        v.setProvider(.github, ttl: 300) { reads?.bump(); return (notice == nil ? s : nil, notice) }
        return (v, v.mint(CredentialBinding.github.id)!)
    }

    // MARK: the swap

    func testGitsBasicLoginIsDecodedSwappedAndReencoded() throws {
        let (v, ph) = vault()
        let d = v.rewrite(head: head("GET /o/r.git/info/refs?service=git-upload-pack HTTP/1.1\r\nHost: github.com\r\nAuthorization: Basic \(basic("x-access-token:" + ph))\r\n\r\n"), host: "github.com")
        guard case .swapped(let out, "github") = d else { return XCTFail("\(d)") }
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.contains("Authorization: Basic \(basic("x-access-token:" + real))\r\n"), text)
        XCTAssertFalse(text.contains(ph) || text.contains(basic("x-access-token:" + ph)), "no trace of the placeholder")
    }

    func testGhsTokenAndBearerAreSwapped() {
        let (v, ph) = vault()
        for scheme in ["token", "Bearer"] {
            let d = v.rewrite(head: head("GET /user HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: \(scheme) \(ph)\r\n\r\n"), host: "api.github.com")
            guard case .swapped(let out, "github") = d else { return XCTFail("\(scheme): \(d)") }
            XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("Authorization: \(scheme) \(real)\r\n"))
        }
    }

    func testNeverToAnotherHostNeverAddedNeverForeignStrict() {
        let (v, ph) = vault()
        // Another host — in clear or inside Basic — is refused (the leak guard).
        for (host, auth) in [("example.com", "token \(ph)"), ("example.com", "Basic \(basic("u:" + ph))"),
                             ("raw.githubusercontent.com", "Basic \(basic("x-access-token:" + ph))"), ("api.anthropic.com", "Bearer \(ph)")] {
            guard case .reject = v.rewrite(head: head("GET / HTTP/1.1\r\nHost: \(host)\r\nAuthorization: \(auth)\r\n\r\n"), host: host) else {
                return XCTFail("\(host) \(auth)")
            }
        }
        // Swap-only: a request without the placeholder never gets the token added.
        let anon = head("GET /o/r.git/info/refs?service=git-upload-pack HTTP/1.1\r\nHost: github.com\r\n\r\n")
        XCTAssertEqual(v.rewrite(head: anon, host: "github.com"), .passThrough(anon))
        // "strict" pins the ANTHROPIC credential: a guest's own GitHub token is flagged, not refused.
        v.foreignPolicy = .strict
        guard case .foreign = v.rewrite(head: head("GET /user HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: token ghp_FAKEguestown00\r\n\r\n"), host: "api.github.com") else {
            return XCTFail("a guest's own GitHub token under strict")
        }
        // The plain-HTTP guard sees a Basic placeholder too.
        XCTAssertEqual(CredentialVault.placeholders(inHead: head("GET http://x/ HTTP/1.1\r\nAuthorization: Basic \(basic("a:" + ph))\r\n\r\n")), [ph])
    }

    func testTheSourceIsReadOnUseCachedAndRevocable() {
        let reads = Counter()
        let (v, ph) = vault(reads: reads)
        XCTAssertTrue(v.boundHosts.isSuperset(of: ["github.com", "api.github.com"]), "decrypted before the first read")
        XCTAssertTrue(v.issuesPlaceholder("github"))
        XCTAssertEqual(reads.value, 0, "nothing read until a request needs it")
        let req = head("GET /user HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: token \(ph)\r\n\r\n")
        _ = v.rewrite(head: req, host: "api.github.com")
        _ = v.rewrite(head: req, host: "api.github.com")
        XCTAssertEqual(reads.value, 1, "kept a few minutes")
        _ = v.rewrite(head: head("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"), host: "example.com")
        XCTAssertEqual(reads.value, 1, "another host never reads it")
        v.expireProviders()
        _ = v.rewrite(head: req, host: "api.github.com")
        XCTAssertEqual(reads.value, 2)
        // Another source chosen (the provider's version): the cache is dropped at once, not after its minutes.
        final class Box: @unchecked Sendable { var s = "gh" }
        let box = Box(), vreads = Counter()
        let vv = CredentialVault()
        vv.setProvider(.github, ttl: 300, version: { box.s }) { vreads.bump(); return (box.s == "off" ? nil : "ghp_FAKE" + box.s, "off") }
        let vph = vv.mint("github")!
        let vreq = head("GET /user HTTP/1.1\r\nAuthorization: token \(vph)\r\n\r\n")
        _ = vv.rewrite(head: vreq, host: "api.github.com"); _ = vv.rewrite(head: vreq, host: "api.github.com")
        XCTAssertEqual(vreads.value, 1)
        box.s = "off"
        guard case .refuse(401, _) = vv.rewrite(head: vreq, host: "api.github.com") else { return XCTFail("off at once") }
        XCTAssertEqual(vreads.value, 2)
        // Off: every placeholder issued is refused at once.
        v.remove("github")
        guard case .reject = v.rewrite(head: req, host: "api.github.com") else { return XCTFail("revoked") }
        XCTAssertFalse(v.boundHosts.contains("github.com"))
        // No login on the Mac: the request with a placeholder gets the reason.
        let (w, ph2) = vault(notice: "Dozer: this Mac's gh is not logged in")
        guard case .refuse(401, let why) = w.rewrite(head: head("GET /user HTTP/1.1\r\nAuthorization: token \(ph2)\r\n\r\n"), host: "api.github.com") else {
            return XCTFail("no login")
        }
        XCTAssertTrue(why.contains("gh is not logged in"))
    }

    func testOnePlaceholderInBothVariablesAndTheUseCallback() {
        let (v, ph) = vault()
        let env = v.sessionEnvironment()
        XCTAssertNotNil(env["GH_TOKEN"])
        XCTAssertEqual(env["GH_TOKEN"], env["GITHUB_TOKEN"])
        XCTAssertTrue(env["GH_TOKEN"]!.hasPrefix("doz_cred_"))
        let used = Counter()
        v.onUse = { id in if id == "github" { used.bump() } }
        _ = v.rewrite(head: head("GET /user HTTP/1.1\r\nAuthorization: token \(ph)\r\n\r\n"), host: "api.github.com")
        XCTAssertEqual(used.value, 1)
    }

    // MARK: read-only

    func testTheReadOnlyClassifier() {
        func c(_ m: String, _ h: String, _ t: String, _ mode: GitHubAccess.Mode = .read) -> GitHubAccess.Verdict {
            GitHubAccess.classify(mode: mode, method: m, host: h, target: t, sandbox: "s")
        }
        XCTAssertEqual(c("GET", "github.com", "/o/r.git/info/refs?service=git-upload-pack"), .allow)
        XCTAssertEqual(c("POST", "github.com", "/o/r.git/git-upload-pack"), .allow)
        for t in ["/o/r.git/info/refs?service=git-receive-pack", "/o/r.git/info/refs?service=git-%72eceive-pack"] {
            guard case .refuse(let why) = c("GET", "github.com", t) else { return XCTFail(t) }
            XCTAssertTrue(why.contains("pushing to GitHub is off for s") && why.contains("doz net allow s github:push"), why)
        }
        for t in ["/o/r.git/git-receive-pack", "/o/r.git/git-receive-pack/", "/o/r.git/git-%72eceive-pack", "/o/r.git/GIT-RECEIVE-PACK"] {
            guard case .refuse = c("POST", "github.com", t) else { return XCTFail(t) }
        }
        XCTAssertEqual(c("POST", "github.com", "/o/r.git/info/lfs/objects/batch"), .needsBody(.lfsBatch))
        guard case .refuse = c("POST", "github.com", "/session") else { return XCTFail("a web form") }
        XCTAssertEqual(c("GET", "api.github.com", "/repos/o/r"), .allow)
        XCTAssertEqual(c("HEAD", "api.github.com", "/repos/o/r"), .allow)
        XCTAssertEqual(c("POST", "api.github.com", "/graphql"), .needsBody(.graphQL))
        XCTAssertEqual(c("POST", "api.github.com", "/graphql/"), .needsBody(.graphQL))
        for (m, t) in [("POST", "/repos/o/r/issues"), ("PATCH", "/repos/o/r"), ("PUT", "/repos/o/r/contents/x"), ("DELETE", "/repos/o/r"), ("OPTIONS", "/")] {
            guard case .refuse = c(m, "api.github.com", t) else { return XCTFail("\(m) \(t)") }
        }
        guard case .refuse = c("POST", "uploads.github.com", "/repos/o/r/releases/1/assets") else { return XCTFail("uploads") }
        XCTAssertEqual(c("GET", "codeload.github.com", "/o/r/tar.gz/main"), .allow)
        XCTAssertEqual(c("POST", "github.com", "/o/r.git/git-receive-pack", .push), .allow)
        XCTAssertEqual(c("DELETE", "api.github.com", "/repos/o/r", .push), .allow)
        XCTAssertEqual(c("POST", "example.com", "/x"), .allow, "not a GitHub host: not this classifier's")
    }

    func testGraphQLIsReadOnlyOnlyWhenEveryOperationIsAQuery() {
        let yes = ["query { viewer { login } }", "{ viewer { login } }", "query Q($n: Int) { repository(name: \"mutation\") { id } }",
                   "# mutation here is a comment\nquery { a }", "fragment F on User { login }\nquery { viewer { ...F } }",
                   "query { a(text: \"\"\"block \"\" mutation\"\"\") }", "query A { a } query B { b }"]
        for q in yes { XCTAssertEqual(GitHubAccess.graphQLIsQuery(q), true, q) }
        let no = ["mutation { addStar(input: {}) { clientMutationId } }", "query A { a } mutation B { b }", "subscription { s }",
                  "  mutation{x}"]
        for q in no { XCTAssertEqual(GitHubAccess.graphQLIsQuery(q), false, q) }
        let unsure = ["", "{", "}", "query { a", "type Query { a: Int }", "extend type X { y: Int }", "query { a(x: \"unclosed) }",
                      "schema { query: Q }", "query) {"]
        for q in unsure { XCTAssertNil(GitHubAccess.graphQLIsQuery(q), q) }
        func body(_ o: Any) -> [UInt8] { Array(try! JSONSerialization.data(withJSONObject: o)) }
        XCTAssertEqual(GitHubAccess.classify(body: body(["query": "{ viewer { login } }"]), kind: .graphQL, sandbox: "s"), .allow)
        guard case .refuse(let w) = GitHubAccess.classify(body: body(["query": "mutation { x }"]), kind: .graphQL, sandbox: "s") else { return XCTFail() }
        XCTAssertTrue(w.contains("GraphQL mutation refused"))
        guard case .refuse = GitHubAccess.classify(body: body([["query": "{ a }"]]), kind: .graphQL, sandbox: "s") else { return XCTFail("a batch") }
        guard case .refuse = GitHubAccess.classify(body: Array("not json".utf8), kind: .graphQL, sandbox: "s") else { return XCTFail("garbage") }
        XCTAssertEqual(GitHubAccess.classify(body: body(["operation": "download", "objects": []]), kind: .lfsBatch, sandbox: "s"), .allow)
        guard case .refuse = GitHubAccess.classify(body: body(["operation": "upload"]), kind: .lfsBatch, sandbox: "s") else { return XCTFail("lfs upload") }
    }

    // MARK: permissions and settings

    func testThePermissionsAreOffInEveryPresetAndPushNeedsAsYou() throws {
        for p in ["locked", "agent", "open"] {
            let names = AgentPermissions.preset(p, base: "node") ?? []
            XCTAssertFalse(names.contains(AgentPermissions.gitHubAsYou) || names.contains(AgentPermissions.gitHubPush), p)
        }
        let std = AgentPermissions.preset("agent", base: "node")!
        XCTAssertEqual(AgentPermissions.presetName(std + [AgentPermissions.gitHubAsYou], base: "node"), "agent", "the login is beside the preset")
        XCTAssertEqual(AgentPermissions.normalized(std + [AgentPermissions.gitHubPush]).contains(AgentPermissions.gitHubPush), false)
        XCTAssertNil(AgentPermissions.gitHubMode(std))
        XCTAssertEqual(AgentPermissions.gitHubMode(std + [AgentPermissions.gitHubAsYou]), .read)
        XCTAssertEqual(AgentPermissions.gitHubMode(std + [AgentPermissions.gitHubAsYou, AgentPermissions.gitHubPush]), .push)
        let base = NetworkPolicy.permissions(std, preset: "agent")
        let pushed = try PermissionPolicy.edited(base, grant: [AgentPermissions.gitHubPush], revoke: [], base: "node")
        XCTAssertEqual(AgentPermissions.gitHubMode(pushed.permissions), .push, "granting push grants both")
        let off = try PermissionPolicy.edited(pushed, grant: [], revoke: [AgentPermissions.gitHubAsYou], base: "node")
        XCTAssertNil(AgentPermissions.gitHubMode(off.permissions))
        XCTAssertFalse(off.permissions!.contains(AgentPermissions.gitHubPush), "revoking as-you revokes push")
        // A pre-597 open policy never infers the login; a denied host never suggests it.
        let legacy = NetworkPolicy(defaultAction: .allow, rules: [], preset: nil)
        XCTAssertNil(AgentPermissions.gitHubMode(PermissionPolicy.inferred(legacy).names))
        XCTAssertNotEqual(AgentPermissions.permission(forHost: "api.github.com")?.group, "github")
        // Choosing a preset keeps it.
        var r = HostRequest(.netPolicy, name: "s")
        r.preset = "locked"
        XCTAssertEqual(AgentPermissions.gitHubMode(try HostCore.editedPolicy(pushed, r, base: "node").permissions), .push)
        // While on, the GitHub hosts are allowed (the network follows the switch).
        var on = base
        on.permissions = AgentPermissions.normalized(std + [AgentPermissions.gitHubAsYou])
        XCTAssertEqual(on.evaluateConnection(host: "api.github.com", port: 443).kind, .allow)
        XCTAssertEqual(NetworkPolicy.permissions(["model"]).evaluateConnection(host: "api.github.com", port: 443).kind, .deny)
    }

    func testTheSettingsAndFlags() throws {
        XCTAssertEqual(DozerSettings.definition(SettingKey.githubCredentials)?.defaultValue, .string("gh"))
        XCTAssertThrowsError(try DozerSettings.definition(SettingKey.githubCredentials)!.parse("maybe"))
        XCTAssertTrue(DozerSettings.perSandbox.contains(SettingKey.sshAgent))
        XCTAssertFalse(DozerSettings.perSandbox.contains(SettingKey.githubCredentials))
        XCTAssertEqual(DozerSettings.definition(SettingKey.sshAgent)?.defaultValue, .string("off"))
        XCTAssertEqual(try CreateArguments.githubWords("read", flag: "--github"), ["+github:as-you", "-github:push"])
        XCTAssertEqual(try CreateArguments.githubWords("push", flag: "--github"), ["+github:as-you", "+github:push"])
        XCTAssertEqual(try CreateArguments.githubWords(nil, flag: "--github"), [])
        XCTAssertThrowsError(try CreateArguments.githubWords("write", flag: "--github"))
        let c = try Create.parse(["x", "--github", "push", "--ssh-agent", "on"])
        XCTAssertEqual(try c.create.sandboxSettings()?[SettingKey.sshAgent], .string("on"))
        let p = try DozerProject.parse("version: 1\nname: p\nimage: claude-code\ngithub: read\nssh_agent: on\n")
        XCTAssertEqual(p.github, "read")
        XCTAssertEqual(p.settings[SettingKey.sshAgent], .string("on"))
        XCTAssertEqual(p.createOptions(folder: URL(fileURLWithPath: "/tmp/p"), file: URL(fileURLWithPath: "/tmp/p/doz_project.yaml")).allow,
                       ["+github:as-you", "-github:push"])
        XCTAssertEqual(try DozerProject.parse("version: 1\nname: p\nimage: lab\ngithub: off\n").github, "off")
        XCTAssertThrowsError(try DozerProject.parse("version: 1\nname: p\nimage: lab\ngithub: write\n"))
        XCTAssertTrue(DozerProject(name: "p", image: "lab").render().contains("# github: off"))
    }

    // MARK: the guest

    func testTheGuestsGitSetupAndHelper() throws {
        let on = GitGuestSetup(on: true, name: "Ada \"the\" Lovelace", email: "ada@example.com")
        let text = GuestCommand.dozerGitConfig(on)
        XCTAssertTrue(text.contains("[credential \"https://github.com\"]\n\thelper = \"\(GuestCommand.gitCredentialHelperPath)\""))
        XCTAssertTrue(text.contains("\tname = \"Ada \\\"the\\\" Lovelace\"\n\temail = \"ada@example.com\""))
        XCTAssertFalse(GuestCommand.dozerGitConfig(.off).contains("[user]"), "off: nothing of the user's")
        XCTAssertNil(GitGuestSetup(on: true, name: "a\nb", email: nil).name, "one line of plain text")
        XCTAssertNil(GitGuestSetup(on: false, name: "x", email: "y").name)
        let fixes = GuestCommand.guestFixes(imageSpec: nil, git: on, sshAgent: true)
        XCTAssertTrue(fixes.contains(GuestCommand.gitCredentialHelperPath) && fixes.contains("path = /etc/dozer/gitconfig")
                      && fixes.contains("agent -p 5801 -s /run/doz/ssh-agent.sock"))
        XCTAssertTrue(GuestCommand.guestFixes(imageSpec: nil).contains("agent stop"), "off by default")
        XCTAssertFalse(GuestCommand.prepareGuest(imageSpec: nil, git: on).contains("agent -p"), "a fresh boot starts the agent after doznet is in")
        // The helper: only a doz placeholder, only https://github.com.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dz599d-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = dir.appendingPathComponent("helper")
        try GuestCommand.gitCredentialHelper.write(to: helper, atomically: true, encoding: .utf8)
        func run(_ input: String, env: [String: String], _ arg: String = "get") throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [helper.path, arg]
            p.environment = env
            let i = Pipe(), o = Pipe()
            p.standardInput = i; p.standardOutput = o; p.standardError = FileHandle.nullDevice
            try p.run()
            i.fileHandleForWriting.write(Data(input.utf8)); try i.fileHandleForWriting.close()
            let out = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return out
        }
        let req = "protocol=https\nhost=github.com\n\n"
        XCTAssertEqual(try run(req, env: ["GH_TOKEN": "doz_cred_abc123"]), "username=x-access-token\npassword=doz_cred_abc123\n")
        XCTAssertEqual(try run("protocol=https\nhost=gitlab.com\n\n", env: ["GH_TOKEN": "doz_cred_abc123"]), "", "another host: nothing")
        XCTAssertEqual(try run(req, env: ["GH_TOKEN": "ghp_FAKEnotours"]), "", "never a token that is not a doz placeholder")
        XCTAssertEqual(try run(req, env: [:]), "")
        XCTAssertEqual(try run(req, env: ["GH_TOKEN": "doz_cred_abc123"], "store"), "", "store/erase do nothing")
    }

    func testTheSSHPortIsOnlyGitHubAndOnlyWhileOn() throws {
        let p = try EgressProxy(policy: .permissions(["model"]), ca: nil)
        XCTAssertEqual(p.connectionVerdict(host: "github.com", port: 22).kind, .deny)
        XCTAssertFalse(p.allowsName("github.com"))
        p.sshToGitHub = true
        XCTAssertEqual(p.connectionVerdict(host: "github.com", port: 22).kind, .allow)
        XCTAssertEqual(p.connectionVerdict(host: "gitlab.com", port: 22).kind, .deny)
        XCTAssertEqual(p.connectionVerdict(host: "github.com", port: 2222).kind, .deny)
        XCTAssertTrue(p.allowsName("github.com"))
    }

    func testTheGuestMayOnlyListAndSignWithTheAgent() {
        func ext(_ name: String) -> [UInt8] { [27] + [0, 0, 0, UInt8(name.utf8.count)] + Array(name.utf8) }
        XCTAssertTrue(SSHAgentRelay.allowed([11]), "list the keys")
        XCTAssertTrue(SSHAgentRelay.allowed([13, 0, 0, 0, 0]), "sign")
        XCTAssertTrue(SSHAgentRelay.allowed(ext("session-bind@openssh.com")))
        for t: UInt8 in [17, 18, 19, 22, 23, 25, 26, 1, 0, 255] {
            XCTAssertFalse(SSHAgentRelay.allowed([t]), "type \(t): add/remove keys, lock, unlock, anything else")
        }
        XCTAssertFalse(SSHAgentRelay.allowed(ext("query")), "another extension")
        XCTAssertFalse(SSHAgentRelay.allowed([27, 0, 0, 0, 9, 1]), "a malformed extension")
        XCTAssertFalse(SSHAgentRelay.allowed([]))
        XCTAssertEqual(SSHAgentRelay.failure, [0, 0, 0, 1, 5])
    }

    // MARK: sources (seams only)

    func testTheSourcesThroughTheirSeams() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dz599d-src-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gh = dir.appendingPathComponent("gh")
        try "#!/bin/sh\n[ \"$1 $2\" = 'auth token' ] && echo \(real)\n".write(to: gh, atomically: true, encoding: .utf8)
        chmod(gh.path, 0o755)
        XCTAssertEqual(GitHubLogin.ghToken(environment: ["DOZ_TEST_GH": gh.path]).secret, real)
        let out = dir.appendingPathComponent("gh-out")
        try "#!/bin/sh\necho 'You are not logged into any GitHub hosts' >&2; exit 1\n".write(to: out, atomically: true, encoding: .utf8)
        chmod(out.path, 0o755)
        let r = GitHubLogin.ghToken(environment: ["DOZ_TEST_GH": out.path])
        XCTAssertNil(r.secret)
        XCTAssertTrue(r.notice?.contains("gh auth login") == true)
        let cfg = dir.appendingPathComponent("gitconfig")
        try "[user]\n\tname = Test Person\n\temail = test@example.invalid\n".write(to: cfg, atomically: true, encoding: .utf8)
        let id = GitHubLogin.macIdentity(environment: ["GIT_CONFIG_GLOBAL": cfg.path, "HOME": dir.path])
        XCTAssertEqual(id.name, "Test Person")
        XCTAssertEqual(id.email, "test@example.invalid")
        XCTAssertNil(GitHubLogin.agentSocket(environment: ["DOZ_TEST_SSH_AUTH_SOCK": cfg.path]), "not a socket")
        XCTAssertNil(GitHubLogin.testUpstream(environment: ["DOZ_TEST_GITHUB_UPSTREAM": "127.0.0.1:1"]), "the CA too")
    }

    // MARK: the agent is told

    func testTheFactsSayItConciselyAndTheSkillInFull() throws {
        func v(_ g: GitHubAccess.Mode?, ssh: Bool = false) -> [String: String] {
            AgentPrompt.values(name: "n", image: "pi", cpus: 1, memoryMiB: 1024, workspace: "/w", network: .none, account: nil, version: "1",
                               hostname: "h", github: g, sshAgent: ssh)
        }
        XCTAssertEqual(v(nil)["github.facts"], "")
        XCTAssertTrue(v(.read)["github.facts"]!.contains("read-only") && v(.read)["github.facts"]!.contains("Push to GitHub"))
        XCTAssertTrue(v(.push)["github.facts"]!.contains("with push"))
        XCTAssertTrue(v(nil, ssh: true)["github.facts"]!.contains("ssh-agent"))
        XCTAssertTrue(v(.read)["github.description"]!.contains("doz_cred_") && v(.read)["github.description"]!.contains("403"))
        XCTAssertTrue(v(nil)["github.description"]!.contains("github:as-you"))
        let off = try AgentPrompt.render(AgentPrompt.builtInTemplate, v(nil), source: "b")
        let on = try AgentPrompt.render(AgentPrompt.builtInTemplate, v(.read), source: "b")
        XCTAssertEqual(on.split(separator: "\n").count, off.split(separator: "\n").count + 1, "one line when on, none when off")
        XCTAssertTrue(AgentPrompt.skillTemplate.contains("## GitHub\n\n{{github.description}}"))
    }
}
