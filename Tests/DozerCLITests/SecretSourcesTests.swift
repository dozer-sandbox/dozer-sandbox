import Foundation
@testable import DozerKit
import XCTest
@testable import DozerCLI
@testable import DozerHost
@testable import DozerWeb

/// 617 (§7, D6): keys read on use from 1Password, AWS or a command — the reference stored, never the value; the runner
/// (argv only, its own group, capped, timed out); the vault's cache, version and re-read after a 401; failures as the
/// proxy's notice; custom keys swapped only on their own allowed hosts. Fake `op`/`aws`/commands in a temp folder —
/// never the real tools (TestSafety refuses them here).
final class SecretSourcesTests: XCTestCase {
    private var root: URL!
    private var bin: URL!
    let keychain = FakeKeychain()
    static let value = "xai-SOURCED-SECRET-0123456789abcdef"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-secrets-\(UUID().uuidString.prefix(8))")
        bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try script("op", """
            #!/bin/sh
            d=$(dirname "$0")
            echo x >> "$d/op-calls"
            if [ -f "$d/op-signedout" ]; then echo "[ERROR] You are not currently signed in. Please run op signin --help" >&2; exit 1; fi
            [ "$1" = "read" ] && [ "$2" = "--no-newline" ] || exit 2
            cat "$d/value"
            """)
        try script("aws", """
            #!/bin/sh
            d=$(dirname "$0")
            if [ -f "$d/aws-denied" ]; then echo "An error occurred (AccessDeniedException) when calling the GetSecretValue operation" >&2; exit 254; fi
            printf '{"api_key":"%s","other":"x"}\\n' "$(cat "$d/value")"
            """)
        try script("cmd", """
            #!/bin/sh
            d=$(dirname "$0")
            echo x >> "$d/cmd-calls"
            cat "$d/value"
            """)
        try Data((Self.value + "\n").utf8).write(to: bin.appendingPathComponent("value"))
        setenv("DOZ_TEST_OP", bin.appendingPathComponent("op").path, 1)
        setenv("DOZ_TEST_AWS", bin.appendingPathComponent("aws").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("DOZ_TEST_OP")
        unsetenv("DOZ_TEST_AWS")
        try? FileManager.default.removeItem(at: root)
    }

    /// The store — beside the fake programs, never around them (a program inside the store is refused).
    var storeRoot: URL { root.appendingPathComponent("store") }

    func script(_ name: String, _ text: String) throws {
        let u = bin.appendingPathComponent(name)
        try Data(text.utf8).write(to: u)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
    }

    var env: [String: String] { ["DOZ_TEST_OP": bin.appendingPathComponent("op").path, "DOZ_TEST_AWS": bin.appendingPathComponent("aws").path, "HOME": root.path] }
    func calls(_ name: String) -> Int { ((try? String(contentsOf: bin.appendingPathComponent(name), encoding: .utf8)) ?? "").split(separator: "\n").count }

    func core() async -> HostCore {
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let c = HostCore(store: DozerStore(root: storeRoot), readOnly: false, version: "test", services: s)
        await c.load()
        return c
    }

    func addSourced(_ c: HostCore, _ name: String, _ source: SecretSource, provider: String? = "xai", kind: AccountKind = .key,
                    env: [String: String]? = nil, verify: Bool = true, force: Bool = false) async -> HostMessage {
        var r = provider.map { HostRequest.keyAccountAdd(name: name, provider: $0, secret: nil, verify: verify, force: force) }
            ?? HostRequest.accountAdd(name: name, kind: kind, plan: nil, secret: nil, verify: verify, force: force)
        if kind != .key { r.accountKind = kind.rawValue; r.provider = nil }
        r.secretSource = source
        r.sourceEnv = env
        return await c.handle(r)
    }

    func waitFor(_ what: @autoclosure @escaping () -> Bool, _ message: String = "") async {
        var n = 0
        while !what() && n < 300 { n += 1; try? await Task.sleep(nanoseconds: 10_000_000) }
        let ok = what()
        XCTAssertTrue(ok, message)
    }

    // MARK: parsing what a person types

    func testReferencesAreParsedAndRefused() throws {
        XCTAssertEqual(try SecretSource.parse(from: "op://Dev/xai/credential"), .onePassword(reference: "op://Dev/xai/credential"))
        XCTAssertEqual(try SecretSource.parse(from: "aws:arn:aws:secretsmanager:eu-west-1:123456789012:secret:dev/xai-AbCdEf#api_key"),
                       .awsSecretsManager(arn: "arn:aws:secretsmanager:eu-west-1:123456789012:secret:dev/xai-AbCdEf", jsonKey: "api_key"))
        for bad in ["op://Dev/xai", "op://Dev//credential", "op://Dev/x ai/credential", "aws:arn:aws:s3:::bucket", "aws:arn:aws:secretsmanager:eu-west-1:12:secret:x",
                    "aws:arn:aws:secretsmanager:eu-west-1:123456789012:secret:x#bad key", "env:XAI_API_KEY", "https://example.com/key"] {
            XCTAssertThrowsError(try SecretSource.parse(from: bad), bad)
        }
    }

    func testACommandIsArgvNeverAShell() throws {
        let cmd = bin.appendingPathComponent("cmd").path
        XCTAssertEqual(try SecretSource.parseCommand("\(cmd) --field 'two words' \"x y\"", resolve: { _ in nil }),
                       .command(program: cmd, arguments: ["--field", "two words", "x y"]))
        XCTAssertEqual(try SecretSource.parseCommand("cmd token", resolve: { $0 == "cmd" ? cmd : nil }), .command(program: cmd, arguments: ["token"]),
                       "a bare name is resolved to an absolute path once, at add time")
        for bad in ["\(cmd); rm -rf /", "\(cmd) | cat", "\(cmd) && true", "\(cmd) $(id)", "\(cmd) `id`", "\(cmd) > /tmp/x", "\(cmd) < /etc/passwd",
                    "\(cmd) &", "\(cmd)\nid", "\(cmd) 'unclosed", "relative/cmd", "nope-not-installed", "/etc/hosts", "$HOME/x", ""] {
            XCTAssertThrowsError(try SecretSource.parseCommand(bad, resolve: { _ in nil }), bad)
        }
    }

    func testTheToolVariablesAreAllowListedAndTheTTLBounded() throws {
        XCTAssertNoThrow(try SecretSources.checkEnvironment(["OP_ACCOUNT": "my.1password.com", "AWS_PROFILE": "dev", "AWS_REGION": "eu-west-1"]))
        for bad in [["OP_SERVICE_ACCOUNT_TOKEN": "ops_x"], ["AWS_SECRET_ACCESS_KEY": "x"], ["PATH": "/tmp"], ["DOZ_STORE": "/x"], ["AWS_PROFILE": "a\nb"], ["AWS_PROFILE": ""]] {
            XCTAssertThrowsError(try SecretSources.checkEnvironment(bad), "\(bad.keys)")
        }
        XCTAssertEqual(SecretSources.parseTTL("55m"), 3300)
        XCTAssertEqual(SecretSources.parseTTL("2h"), 7200)
        XCTAssertEqual(SecretSources.parseTTL("300"), 300)
        XCTAssertNil(SecretSources.parseTTL("10s"), "at least a minute")
        XCTAssertNil(SecretSources.parseTTL("25h"))
        XCTAssertNil(SecretSources.parseTTL("soon"))
        // The tool runs with who/where and its own sign-in variables — never DOZ_ ones; the standard PATH; the account's.
        let e = SecretSources.toolEnvironment(["HOME": "/Users/x", "PATH": "/evil", "DOZ_STORE": "/s", "OP_SERVICE_ACCOUNT_TOKEN": "t", "AWS_PROFILE": "host",
                                               "ANTHROPIC_API_KEY": "sk-ant-x", "SSH_AUTH_SOCK": "/s"], sourceEnv: ["AWS_PROFILE": "dev", "PATH": "/nope"])
        XCTAssertEqual(e, ["HOME": "/Users/x", "PATH": SecretSources.standardPath, "OP_SERVICE_ACCOUNT_TOKEN": "t", "AWS_PROFILE": "dev"])
    }

    // MARK: the runner

    func testReadsFromOnePasswordAWSAndACommand() throws {
        let op = SecretSources.read(.onePassword(reference: "op://Dev/xai/credential"), account: "a", sourceEnv: [:], environment: env)
        XCTAssertEqual(op.secret, Self.value, "trimmed, one line")
        let aws = SecretSources.read(.awsSecretsManager(arn: "arn:aws:secretsmanager:eu-west-1:123456789012:secret:x", jsonKey: "api_key"), account: "a", sourceEnv: [:], environment: env)
        XCTAssertEqual(aws.secret, Self.value, "the JSON key's string")
        let missingKey = SecretSources.read(.awsSecretsManager(arn: "arn:aws:secretsmanager:eu-west-1:123456789012:secret:x", jsonKey: "nope"), account: "a", sourceEnv: [:], environment: env)
        XCTAssertNil(missingKey.secret)
        XCTAssertTrue(missingKey.notice?.contains("no string field nope") == true)
        let cmd = SecretSources.read(.command(program: bin.appendingPathComponent("cmd").path, arguments: []), account: "a", sourceEnv: [:], environment: env)
        XCTAssertEqual(cmd.secret, Self.value)
    }

    func testFailuresNameTheCauseAndTheFix() throws {
        FileManager.default.createFile(atPath: bin.appendingPathComponent("op-signedout").path, contents: Data())
        let op = SecretSources.read(.onePassword(reference: "op://Dev/xai/credential"), account: "grok-op", sourceEnv: ["OP_ACCOUNT": "my"], environment: env)
        XCTAssertNil(op.secret)
        // 617 (owner): the tool's own first line (its log prefix dropped), the plain reason, then what to do.
        XCTAssertEqual(op.notice, "the key of account grok-op comes from 1Password: op://Dev/xai/credential, but op says: "
                       + "You are not currently signed in. Please run op signin --help"
                       + " (op is not signed in) — run op signin --account my (or give the host OP_SERVICE_ACCOUNT_TOKEN), then doz account refresh grok-op")
        FileManager.default.createFile(atPath: bin.appendingPathComponent("aws-denied").path, contents: Data())
        let aws = SecretSources.read(.awsSecretsManager(arn: "arn:aws:secretsmanager:eu-west-1:123456789012:secret:x", jsonKey: nil), account: "a", sourceEnv: [:], environment: env)
        XCTAssertTrue(aws.notice?.contains("AccessDenied") == true, aws.notice ?? "")
        // Not installed (no seam, outside a guarded run) and the guarded run's own refusal.
        let none = SecretSources.read(.onePassword(reference: "op://Dev/xai/credential"), account: "a", sourceEnv: [:], environment: ["DOZ_TEST_REAL_MAC": "1", "PATH": "/nonexistent"])
        if SecretSources.locate("op") == nil { XCTAssertTrue(none.notice?.contains("brew install 1password-cli") == true, none.notice ?? "") }
        let guarded = SecretSources.read(.onePassword(reference: "op://Dev/xai/credential"), account: "a", sourceEnv: [:], environment: ["DOZ_TEST_GUARD": "1"])
        XCTAssertTrue(guarded.notice?.contains("TEST SAFETY: a test would run the real op") == true, guarded.notice ?? "")
        XCTAssertNotNil(SecretSources.toolProgram("aws", environment: ["DOZ_TEST_GUARD": "1"]).refusal)
        XCTAssertNil(SecretSources.toolProgram("aws", environment: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_REAL_MAC": "1"]).refusal, "lifted only on purpose")
        // A command that exits non-zero.
        try script("fails", "#!/bin/sh\necho oops >&2\nexit 3\n")
        let f = SecretSources.read(.command(program: bin.appendingPathComponent("fails").path, arguments: []), account: "a", sourceEnv: [:], environment: env)
        XCTAssertEqual(f.notice, "the key of account a comes from command: \(bin.path)/fails, but \(bin.path)/fails says: oops — run that command in Terminal "
                       + "to check it, then doz account refresh a")
    }

    /// 617 (owner): `account show`'s verification is history — when it was checked.
    func testVerifiedIsHistory() throws {
        var r = AccountRow(name: "demo", kind: "key", isDefault: false, usedBy: [], state: "ok")
        XCTAssertEqual(verifiedLine(r), "—")
        r.verification = "verified"
        XCTAssertEqual(verifiedLine(r), "verified", "no date known (an older record)")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-12T18:00:00Z"))
        r.verifiedAt = now.addingTimeInterval(-3600)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM HH:mm"
        XCTAssertEqual(verifiedLine(r, now: now), "last verified " + f.string(from: r.verifiedAt!))
        r.verification = "rejected: 401"
        XCTAssertEqual(verifiedLine(r, now: now), "rejected: 401 (" + f.string(from: r.verifiedAt!) + ")")
        r.verifiedAt = now.addingTimeInterval(-400 * 86_400)
        XCTAssertTrue(verifiedLine(r, now: now).contains("2025"), "another year: with the year")
    }

    /// 617 (owner, after "…exited 44"): the tool's first stderr line — inert, ≤ 160 characters, never stdout, never a line
    /// with the account's key in it; known exits in plain words; what to do.
    func testAFailingToolSaysWhyInItsOwnWords() throws {
        // The owner's case: a command reading the keychain with /usr/bin/security (a fake of the same name).
        try script("security", "#!/bin/sh\necho 'security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.' >&2\nexit 44\n")
        let p = bin.appendingPathComponent("security").path
        let s = SecretSources.read(.command(program: p, arguments: ["find-generic-password", "-w", "-s", "demo"]), account: "demo", sourceEnv: [:], environment: env)
        XCTAssertEqual(s.notice, "the key of account demo comes from command: \(p) find-generic-password -w -s demo, but \(p) says: The specified item could "
                       + "not be found in the keychain. (the keychain has no such item) — run that command in Terminal to check it, then doz account refresh demo")
        XCTAssertEqual(SecretSources.knownReason("security", status: 51, stderr: ""), "the keychain would have to ask you, and nobody can answer here")
        XCTAssertEqual(SecretSources.knownReason("security", status: 36, stderr: ""), "the keychain is locked")
        XCTAssertEqual(SecretSources.knownReason("gh", status: 1, stderr: "you are not logged into any github hosts. run gh auth login"), "gh is not signed in — gh auth login")
        XCTAssertEqual(SecretSources.knownReason("aws", status: 254, stderr: "an error occurred (expiredtokenexception)"), "its AWS credentials expired")
        // Never stdout (it may be the key), even when the tool fails.
        try script("leaky", "#!/bin/sh\nprintf 'sk-STDOUT-SECRET-123456'\necho 'bad request' >&2\nexit 2\n")
        let l = SecretSources.read(.command(program: bin.appendingPathComponent("leaky").path, arguments: []), account: "a", sourceEnv: [:], environment: env)
        XCTAssertFalse(l.notice?.contains("sk-STDOUT") == true, l.notice ?? "")
        XCTAssertTrue(l.notice?.contains("says: bad request") == true, l.notice ?? "")
        // A tool that echoes the key on stderr: its line is not shown when a word matches the account's last fingerprint.
        let key = "xai-ECHOED-KEY-0123456789"
        try script("echoes", "#!/bin/sh\necho \"invalid key \(key) rejected\" >&2\nexit 1\n")
        let k = SecretSources.read(.command(program: bin.appendingPathComponent("echoes").path, arguments: []), account: "a", sourceEnv: [:], environment: env,
                                   knownFingerprint: CredentialFingerprint.of(key))
        XCTAssertFalse(k.notice?.contains(key) == true, k.notice ?? "")
        XCTAssertTrue(k.notice?.contains("echoes exited 1") == true, "said without its words: \(k.notice ?? "")")
        // Inert and short.
        XCTAssertEqual(SecretSources.firstErrorLine("\n\u{1B}]52;c;eA==\u{07}ESC in it\u{9B}2J\nsecond", tool: "x", knownFingerprint: nil), "]52;c;eA==ESC in it2J")
        XCTAssertEqual(SecretSources.firstErrorLine(String(repeating: "a", count: 300), tool: "x", knownFingerprint: nil)?.count, 160)
        XCTAssertEqual(SecretSources.firstErrorLine("Error: the vault is locked", tool: "x", knownFingerprint: nil), "the vault is locked")
        XCTAssertEqual(SecretSources.firstErrorLine("the request: denied", tool: "x", knownFingerprint: nil), "the request: denied", "a sentence keeps its words")
        XCTAssertNil(SecretSources.firstErrorLine("  \n \n", tool: "x", knownFingerprint: nil))
    }

    func testOutputMustBeOneCleanLineUnderTheCap() throws {
        for (name, body) in [("empty", "exit 0"), ("lines", "printf 'a\\nb\\n'"), ("ctrl", "printf 'a\\033[31mb'"),
                             ("big", "head -c 9000 /dev/zero | tr '\\\\000' a")] {
            try script(name, "#!/bin/sh\n\(body)\n")
            let r = SecretSources.read(.command(program: bin.appendingPathComponent(name).path, arguments: []), account: "a", sourceEnv: [:], environment: env)
            XCTAssertNil(r.secret, name)
            XCTAssertTrue(r.notice?.contains("answered nothing usable") == true, "\(name): \(r.notice ?? "")")
        }
        try script("spaces", "#!/bin/sh\nprintf '  \(Self.value)  \\n\\n'\n")
        XCTAssertEqual(SecretSources.read(.command(program: bin.appendingPathComponent("spaces").path, arguments: []), account: "a", sourceEnv: [:], environment: env).secret, Self.value)
    }

    func testATimeoutKillsTheWholeGroup() async throws {
        let pidFile = root.appendingPathComponent("child.pid")
        try script("hang", "#!/bin/sh\nsleep 30 &\necho $! > \"$1\"\nsleep 30\n")
        let started = Date()
        let r = SecretSources.run([bin.appendingPathComponent("hang").path, pidFile.path], environment: ["PATH": SecretSources.standardPath], timeout: 0.5)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let child = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        await waitFor(kill(child, 0) != 0, "the background child was killed with its group")
    }

    func testStdinIsNullAndNoShellRuns() throws {
        try script("stdin", "#!/bin/sh\nif read x; then echo \"got-$x\"; else echo none; fi\n")
        XCTAssertEqual(SecretSources.read(.command(program: bin.appendingPathComponent("stdin").path, arguments: []), account: "a", sourceEnv: [:], environment: env).secret, "none")
        // An argument with shell syntax is passed as it is (argv), never interpreted.
        try script("echo1", "#!/bin/sh\nprintf '%s' \"$1\"\n")
        XCTAssertEqual(SecretSources.read(.command(program: bin.appendingPathComponent("echo1").path, arguments: ["$HOME*"]), account: "a", sourceEnv: [:], environment: env).secret, "$HOME*")
    }

    // MARK: the host

    func testASourcedAccountStoresTheReferenceNeverTheValue() async throws {
        let c = await core()
        let m = await addSourced(c, "grok-op", .onePassword(reference: "op://Dev/xai/credential"), env: ["OP_ACCOUNT": "my"])
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertEqual(calls("op-calls"), 1, "one live read at add time")
        XCTAssertTrue(keychain.writes.isEmpty, "never written to the keychain")
        let file = try String(contentsOf: storeRoot.appendingPathComponent("accounts.json"), encoding: .utf8)
        XCTAssertTrue(file.contains("op://Dev/xai/credential"))
        XCTAssertFalse(file.contains(Self.value))
        let a = try XCTUnwrap(AccountStore(store: DozerStore(root: storeRoot)).load().accounts.first { $0.name == "grok-op" })
        XCTAssertEqual(a.source, .onePassword(reference: "op://Dev/xai/credential"))
        XCTAssertEqual(a.sourceEnv, ["OP_ACCOUNT": "my"])
        XCTAssertNil(a.keychainService)
        XCTAssertEqual(a.fingerprint, CredentialFingerprint.of(Self.value))
        XCTAssertTrue(a.readsOnUse)
        let rows = try XCTUnwrap(m.result).decode([AccountRow].self)
        let row = try XCTUnwrap(rows.first { $0.name == "grok-op" })
        XCTAssertEqual(row.sourceLabel, "1Password: op://Dev/xai/credential")
        XCTAssertEqual(row.sourceState, "ok")
        XCTAssertEqual(row.state, "ok")
        XCTAssertEqual(renderAccount(row).contains("1Password: op://Dev/xai/credential"), true)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(rows), as: UTF8.self).contains(Self.value))
        // A source that fails refuses the add (unless --no-verify), naming the cause.
        FileManager.default.createFile(atPath: bin.appendingPathComponent("op-signedout").path, contents: Data())
        let bad = await addSourced(c, "grok-op2", .onePassword(reference: "op://Dev/xai/credential"))
        XCTAssertTrue(bad.error?.message.contains("op is not signed in") == true, bad.error?.message ?? "")
        let later = await addSourced(c, "grok-op2", .onePassword(reference: "op://Dev/xai/credential"), verify: false)
        XCTAssertNil(later.error, later.error?.message ?? "")
        // Flags only an API key takes; the allow-list on the host too.
        let wrongKind = await addSourced(c, "st", .onePassword(reference: "op://Dev/xai/credential"), provider: nil, kind: .setupToken)
        XCTAssertNotNil(wrongKind.error)
        let badEnv = await addSourced(c, "e", .onePassword(reference: "op://Dev/xai/credential"), env: ["OP_SERVICE_ACCOUNT_TOKEN": "x"])
        XCTAssertNotNil(badEnv.error)
        let badCmd = await addSourced(c, "e", .command(program: "/etc/hosts", arguments: []))
        XCTAssertNotNil(badCmd.error, "a command must be an executable file")
    }

    func testAnExistingKeyAccountSwitchesWithForceAndLeavesNoCopy() async throws {
        let c = await core()
        _ = await c.handle(HostRequest.accountAdd(name: "work", kind: .apiKey, plan: nil, secret: "sk-ant-api03-OLDKEY0123456789abcdef"))
        XCTAssertNotNil(keychain.get("doz-anthropic:work"))
        let cmd = SecretSource.command(program: bin.appendingPathComponent("cmd").path, arguments: [])
        let noForce = await addSourced(c, "work", cmd, provider: nil, kind: .apiKey)
        XCTAssertEqual(noForce.error?.code, .exists)
        let m = await addSourced(c, "work", cmd, provider: nil, kind: .apiKey, force: true)
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertNil(keychain.get("doz-anthropic:work"), "the old key's item Dozer made is gone")
        let a = try XCTUnwrap(AccountStore(store: DozerStore(root: storeRoot)).load().accounts.first { $0.name == "work" })
        XCTAssertEqual(a.kind, .apiKey)
        XCTAssertEqual(a.binding, .anthropic)
        XCTAssertTrue(a.readsOnUse)
    }

    func testTheVaultCachesForTheTTLRereadsOnRefreshAndOnceAfterA401() async throws {
        let c = await core()
        let cmd = SecretSource.command(program: bin.appendingPathComponent("cmd").path, arguments: [])
        let added = await addSourced(c, "gx", cmd)
        XCTAssertNil(added.error)
        let made = await { () async -> HostMessage in
            var r = HostRequest(.create, name: "gk")
            r.create = CreateOptions(image: "grok", network: "locked", account: "gx")
            return await c.handle(r)
        }()
        XCTAssertNil(made.error, made.error?.message ?? "")
        let v = try await XCTUnwrapAsync(await c.vault(of: "gk"))
        let state = c.secretSourceState
        await waitFor(state.readCount("gx") >= 2, "the eager read when the account was applied (1 at add)")
        await waitFor(v.hasSecret("key:xai"))
        XCTAssertEqual(v.sessionEnvironment().keys.sorted(), ["XAI_API_KEY"])
        let after = state.readCount("gx")
        v.prefetch("key:xai")
        v.prefetch("key:xai")
        XCTAssertEqual(state.readCount("gx"), after, "cached for the TTL")
        // Past the TTL: read again.
        v.prefetch("key:xai", now: Date().addingTimeInterval(TimeInterval(SecretSources.defaultTTL + 1)))
        XCTAssertEqual(state.readCount("gx"), after + 1)
        // `doz account refresh`: the generation moves, the next use reads again.
        var r = HostRequest(.accountRefresh)
        r.account = "gx"
        let refreshed = await c.handle(r)
        XCTAssertNil(refreshed.error, refreshed.error?.message ?? "")
        XCTAssertEqual(try XCTUnwrap(refreshed.result).decode([AccountRow].self).first { $0.name == "gx" }?.sourceState, "ok")
        let afterRefresh = state.readCount("gx")
        v.prefetch("key:xai")
        XCTAssertEqual(state.readCount("gx"), afterRefresh + 1, "the cached value was dropped")
        // An upstream 401: one re-read, then not again for 10 s.
        v.upstreamRejected("key:xai")
        v.prefetch("key:xai")
        XCTAssertEqual(state.readCount("gx"), afterRefresh + 2)
        v.upstreamRejected("key:xai")
        v.prefetch("key:xai")
        XCTAssertEqual(state.readCount("gx"), afterRefresh + 2, "a key that is simply wrong does not re-run the tool on every request")
        // A keychain account cannot be refreshed.
        _ = await c.handle(HostRequest.keyAccountAdd(name: "kc", provider: "xai", secret: "xai-KC-0123456789abcdef"))
        r.account = "kc"
        let kc = await c.handle(r)
        XCTAssertNotNil(kc.error)
        // The value is nowhere on disk.
        for f in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap({ $0 as? URL }) ?? [] where !f.path.contains("/bin/") {
            if let s = try? String(contentsOf: f, encoding: .utf8) { XCTAssertFalse(s.contains(Self.value), f.path) }
        }
    }

    func testASignedOutSourceIsTheProxys401NamingTheFix() async throws {
        let c = await core()
        let added = await addSourced(c, "gop", .onePassword(reference: "op://Dev/xai/credential"))
        XCTAssertNil(added.error)
        var cr = HostRequest(.create, name: "gk")
        cr.create = CreateOptions(image: "grok", network: "locked", account: "gop")
        let made = await c.handle(cr)
        XCTAssertNil(made.error)
        let v = try await XCTUnwrapAsync(await c.vault(of: "gk"))
        await waitFor(v.hasSecret("key:xai"))
        FileManager.default.createFile(atPath: bin.appendingPathComponent("op-signedout").path, contents: Data())
        var r = HostRequest(.accountRefresh)
        r.account = "gop"
        let m = await c.handle(r)
        let row = try XCTUnwrap(try XCTUnwrap(m.result).decode([AccountRow].self).first { $0.name == "gop" })
        XCTAssertEqual(row.sourceState, "failed")
        XCTAssertEqual(row.state, "unavailable")
        XCTAssertTrue(row.sourceProblem?.contains("run op signin") == true, row.sourceProblem ?? "")
        v.prefetch("key:xai")
        XCTAssertFalse(v.hasSecret("key:xai"), "never another key")
        XCTAssertTrue(v.notice("key:xai")?.contains("(op is not signed in) — run op signin") == true, v.notice("key:xai") ?? "")
        // The sandbox's banner says the same.
        var ls = HostRequest(.ls)
        ls.withSessions = false
        let listed = await c.handle(ls)
        let info = try XCTUnwrap(try XCTUnwrap(listed.result).decode([SandboxInfo].self).first { $0.name == "gk" })
        XCTAssertTrue(info.credentialProblem?.contains("op signin") == true, info.credentialProblem ?? "")
        // Signed in again: refresh reads it.
        try FileManager.default.removeItem(at: bin.appendingPathComponent("op-signedout"))
        let again = await c.handle(r)
        XCTAssertNil(again.error)
        v.prefetch("key:xai")
        XCTAssertTrue(v.hasSecret("key:xai"))
    }

    // MARK: custom keys

    func custom(_ c: HostCore, _ name: String, hosts: [String] = ["api.example.test"], bearer: Bool = true) async -> HostMessage {
        var r = HostRequest.accountAdd(name: name, kind: .key, plan: nil, secret: "EXAMPLE-CUSTOM-0123456789")
        r.custom = CustomKey(hosts: hosts, header: bearer ? "authorization" : "x-api-key", format: bearer ? "Bearer %s" : "%s", env: "EXAMPLE_API_KEY")
        return await c.handle(r)
    }

    func testACustomKeyIsSwappedOnlyOnItsOwnAllowedHost() async throws {
        let c = await core()
        let added = await custom(c, "ex")
        XCTAssertNil(added.error, added.error?.message ?? "")
        XCTAssertEqual(keychain.get("doz-custom:ex"), "EXAMPLE-CUSTOM-0123456789")
        XCTAssertNil(AccountStore(store: DozerStore(root: storeRoot)).load().providerDefaults?["custom"], "a custom key is never a default")
        // Refused unless each host is allowed on purpose.
        var cr = HostRequest(.create, name: "cc")
        cr.create = CreateOptions(image: "claude-code", account: "none")
        cr.create?.keys = ["ex"]
        let refused = await c.handle(cr)
        XCTAssertTrue(refused.error?.message.contains("--allow site:api.example.test") == true, refused.error?.message ?? "")
        cr.create?.allow = ["site:api.example.test"]
        let made = await c.handle(cr)
        XCTAssertNil(made.error, made.error?.message ?? "")
        let v = try await XCTUnwrapAsync(await c.vault(of: "cc"))
        XCTAssertTrue(v.hasSecret("custom:ex"))
        let ph = try XCTUnwrap(v.sessionEnvironment()["EXAMPLE_API_KEY"])
        func head(_ host: String) -> [UInt8] { Array("GET /v1/x HTTP/1.1\r\nHost: \(host)\r\nAuthorization: Bearer \(ph)\r\n\r\n".utf8) }
        guard case .swapped(let out, let b) = v.rewrite(head: head("api.example.test"), host: "api.example.test") else { return XCTFail("not swapped on its host") }
        XCTAssertEqual(b, "custom:ex")
        XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("Authorization: Bearer EXAMPLE-CUSTOM-0123456789"))
        if case .swapped = v.rewrite(head: head("api.other.test"), host: "api.other.test") { XCTFail("swapped on another host") }
        // Swap-only: never added to a request without its placeholder.
        let plain = Array("GET / HTTP/1.1\r\nHost: api.example.test\r\n\r\n".utf8)
        if case .injected = v.rewrite(head: plain, host: "api.example.test") { XCTFail("injected without a placeholder") }
        // Detach / attach.
        var use = HostRequest(.accountUse, name: "cc")
        use.account = "ex"
        use.removeExtra = true
        let off = await c.handle(use)
        XCTAssertNil(off.error, off.error?.message ?? "")
        XCTAssertNil(v.allBindings.first { $0.id == "custom:ex" }, "taken off: its placeholders are refused at once")
        use.removeExtra = nil
        use.extra = true
        let on = await c.handle(use)
        XCTAssertNil(on.error, on.error?.message ?? "")
        XCTAssertTrue(v.hasSecret("custom:ex"))
        // Its host denied: the key is withheld, the notice says how to allow it.
        var deny = HostRequest(.netPolicy, name: "cc")
        deny.deny = ["api.example.test"]
        let denied = await c.handle(deny)
        XCTAssertNil(denied.error, denied.error?.message ?? "")
        let p = try await XCTUnwrapAsync(await c.effectiveNetworkPolicy(of: "cc"))
        XCTAssertEqual(p.evaluateConnection(host: "api.example.test", port: 443).kind, .deny)
        XCTAssertFalse(v.hasSecret("custom:ex"))
        XCTAssertTrue(v.notice("custom:ex")?.contains("doz net allow cc site:api.example.test") == true, v.notice("custom:ex") ?? "")
    }

    func testCustomKeysAreValidated() async throws {
        let c = await core()
        for (hosts, why) in [([String](), "no host"), (["api.x.ai"], "a provider's host"), (["api.github.com"], "GitHub's"), (["api.openai.com"], "OpenAI's"),
                             (["*.example.test"], "a wildcard"), (["localhost"], "not a dotted name")] {
            let m = await custom(c, "bad", hosts: hosts)
            XCTAssertNotNil(m.error, why)
        }
        XCTAssertThrowsError(try CustomKey(hosts: ["a.example.test"], header: "x-api-key", format: "%s", env: "DOZ_KEY").validate())
        XCTAssertThrowsError(try CustomKey(hosts: ["a.example.test"], header: "host", format: "%s", env: "EX_KEY").validate())
        XCTAssertThrowsError(try CustomKey(hosts: ["a.example.test"], header: "x-api-key", format: "Bearer %s", env: "EX_KEY").validate())
        XCTAssertNoThrow(try CustomKey(hosts: ["a.example.test"], header: "x-api-key", format: "%s", env: "EX_KEY").validate())
        let k = CustomKey(hosts: ["A.Example.Test"], header: "X-Api-Key", format: "%s", env: "EX_KEY")
        XCTAssertEqual(k.binding(account: "n"), CredentialBinding(id: "custom:n", hosts: ["a.example.test"], header: .apiKey(name: "x-api-key"),
                                                                  environmentVariable: "EX_KEY", swapOnly: true))
        // The CLI's flags.
        XCTAssertThrowsError(try AccountAdd.parse(["x", "--custom", "--host", "a.example.test"]).validate())
        XCTAssertThrowsError(try AccountAdd.parse(["x", "--custom", "--host", "a.example.test", "--env-var", "EX", "--bearer", "--header", "x-k"]).validate())
        XCTAssertNoThrow(try AccountAdd.parse(["x", "--custom", "--host", "a.example.test", "--env-var", "EX", "--header", "x-k"]).validate())
        XCTAssertThrowsError(try AccountAdd.parse(["x", "--provider", "xai", "--from", "op://a/b/c", "--from-command", "/bin/echo"]).validate())
        XCTAssertThrowsError(try AccountAdd.parse(["x", "--setup-token", "--from", "op://a/b/c"]).validate())
        XCTAssertThrowsError(try AccountAdd.parse(["x", "--provider", "xai", "--env", "AWS_PROFILE=dev"]).validate(), "--env goes with a source")
        XCTAssertThrowsError(try AccountAdd.parse(["x", "--provider", "xai", "--from", "op://a/b/c", "--ttl", "5s"]).validate())
        XCTAssertNoThrow(try AccountAdd.parse(["x", "--provider", "xai", "--from", "op://a/b/c", "--ttl", "2h", "--env", "OP_ACCOUNT=my"]).validate())
        XCTAssertEqual(try Create.parse(["x", "--key", "a", "--key", "b"]).create.options(defaultImage: "lab").keys, ["a", "b"])
    }

    /// The VM proof's seam: more hosts to the fake — only with the seam itself set.
    func testTheSeamsExtraHostsNeedTheSeam() throws {
        let ca = root.appendingPathComponent("ca.pem")
        try Data("-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n".utf8).write(to: ca)
        XCTAssertEqual(ProviderSeam.extraHosts(environment: ["DOZ_TEST_PROVIDER_HOSTS": "www.example.com"]), [], "no seam, no hosts")
        XCTAssertEqual(ProviderSeam.extraHosts(environment: ["DOZ_TEST_PROVIDER_UPSTREAM": "127.0.0.1:1", "DOZ_TEST_PROVIDER_CA": ca.path,
                                                             "DOZ_TEST_PROVIDER_HOSTS": "WWW.example.com, a.example.test"]), ["www.example.com", "a.example.test"])
    }

    // MARK: records and projections

    func testOlderRecordsDecodeAsKeychain() throws {
        let old = #"{"name":"work","kind":"api-key","keychainService":"doz-anthropic:work","addedAt":"2026-09-01T00:00:00Z"}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let a = try d.decode(AccountRecord.self, from: Data(old.utf8))
        XCTAssertNil(a.source)
        XCTAssertFalse(a.readsOnUse)
        XCTAssertEqual(a.effectiveSource, SecretSource.keychain(service: "doz-anthropic:work"))
        let s = SecretSource.awsSecretsManager(arn: "arn:aws:secretsmanager:eu-west-1:123456789012:secret:x", jsonKey: "k")
        XCTAssertEqual(try JSONDecoder().decode(SecretSource.self, from: JSONEncoder().encode(s)), s)
        XCTAssertThrowsError(try JSONDecoder().decode(SecretSource.self, from: Data(#"{"kind":"env","name":"X"}"#.utf8)))
    }

    func testTheWebProjectionHasNoSecretShapedField() throws {
        var row = AccountRow(name: "gx", kind: "key", plan: nil, identity: nil, expiresAt: nil, verification: "verified", isDefault: false, usedBy: [],
                             state: "ok", keychainService: nil, fingerprint: "abcdef123456", provider: "xai")
        row.sourceLabel = "1Password: op://Dev/xai/credential"
        row.sourceState = "failed"
        row.sourceProblem = "the key of account gx comes from 1Password: op://Dev/xai/credential, but op is not signed in"
        row.hosts = ["api.example.test"]
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: WebJSON.encoder.encode(WebAccount(row))) as? [String: Any])
        let forbidden = ["secret", "token", "password", "apikey", "api_key", "bearer", "authorization", "cookie", "csrf", "credentialvalue"]
        for k in obj.keys { XCTAssertFalse(forbidden.contains { k.lowercased().contains($0) }, k) }
        XCTAssertEqual(obj["sourceLabel"] as? String, "1Password: op://Dev/xai/credential")
        XCTAssertEqual(obj["hosts"] as? [String], ["api.example.test"])
        // Refresh is one HostOp; adding a source is never an action (D7).
        XCTAssertEqual(try WebAction.decode(Data(#"{"action":"account-refresh","account":"gx"}"#.utf8)).hostRequest.op, .accountRefresh)
        XCTAssertThrowsError(try WebAction.decode(Data(#"{"action":"account-refresh","account":"gx","source":"op://a/b/c"}"#.utf8)))
    }
}
