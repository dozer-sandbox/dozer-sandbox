import Darwin
import Foundation
import DozerKit

// 599d — "Use GitHub as you" in the host: where the user's token comes from (read on use, kept in
// memory a few minutes — never written to the store, a log or the guest), the proxy's gate (read or
// push), the guest's git identity and helper, the forwarded SSH agent, and the notice on first use.
//
// Test seams (never the user's own login in a test):
//   DOZ_TEST_GH=<program>              run it instead of the Mac's `gh` (`auth token -h github.com`)
//   DOZ_TEST_SSH_AUTH_SOCK=<socket>    the agent to forward instead of $SSH_AUTH_SOCK
//   DOZ_TEST_GITHUB_UPSTREAM=host:port + DOZ_TEST_GITHUB_CA=<pem>
//                                      the GitHub hosts' upstream leg goes there, trusting ONLY that CA
//   GIT_CONFIG_GLOBAL=<file>           git's own variable: the identity comes from that file

public enum GitHubLogin {
    /// How long a token read from its source is used before it is read again.
    public static let cacheSeconds: TimeInterval = 300

    /// The Mac's `gh` login for github.com — `gh auth token`. Never logged, never stored.
    public static func ghToken(environment env: [String: String] = ProcessInfo.processInfo.environment) -> CredentialVault.SecretRead {
        guard let gh = ghProgram(env) else {
            return (nil, "Dozer: \"Use GitHub as you\" is on, but gh is not installed on this Mac — install it and run gh auth login, or give the sandbox a token: doz key set NAME --github")
        }
        let (code, out) = run(gh, ["auth", "token", "-h", "github.com"], environment: env)
        let token = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code == 0, !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else {
            return (nil, "Dozer: \"Use GitHub as you\" is on, but this Mac's gh is not logged in to github.com — run gh auth login on the Mac")
        }
        return (token, nil)
    }

    static func ghProgram(_ env: [String: String]) -> String? {
        if let t = env["DOZ_TEST_GH"], !t.isEmpty { return t }
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        dirs += (env["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.map { $0 + "/gh" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The Mac's git identity (`git config --global user.name` / `user.email`) — not a secret.
    public static func macIdentity(environment env: [String: String] = ProcessInfo.processInfo.environment) -> (name: String?, email: String?) {
        let git = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let git else { return (nil, nil) }
        func get(_ key: String) -> String? {
            let (code, out) = run(git, ["config", "--global", "--get", key], environment: env)
            let v = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return code == 0 && !v.isEmpty ? v : nil
        }
        return (get("user.name"), get("user.email"))
    }

    /// The Mac's agent socket to forward (nil: none — the user is told).
    public static func agentSocket(environment env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let p = (env["DOZ_TEST_SSH_AUTH_SOCK"]).flatMap { $0.isEmpty ? nil : $0 } ?? env["SSH_AUTH_SOCK"]
        guard let p, !p.isEmpty else { return nil }
        var st = stat()
        guard stat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK else { return nil }
        return p
    }

    /// The test upstream (both variables, a readable CA) — or nil.
    public static func testUpstream(environment env: [String: String] = ProcessInfo.processInfo.environment) -> EgressProxy.UpstreamOverride? {
        guard let u = env["DOZ_TEST_GITHUB_UPSTREAM"], !u.isEmpty, let caPath = env["DOZ_TEST_GITHUB_CA"],
              let pem = try? String(contentsOfFile: caPath, encoding: .utf8) else { return nil }
        let parts = u.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
        return EgressProxy.UpstreamOverride(host: String(parts[0]), port: port, anchorsPEM: pem)
    }

    /// Run a program (no shell), stdout only, at most 10 s.
    static func run(_ program: String, _ args: [String], environment: [String: String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: program)
        p.arguments = args
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus, String(decoding: data.prefix(16 << 10), as: UTF8.self))
    }
}

extension HostCore {
    /// Put the sandbox's GitHub setup in place — from its permissions ("Use GitHub as you", "Push to
    /// GitHub"), the source setting, its own key, `sandbox.ssh_agent` — and apply it to a running guest.
    /// Called when the sandbox is loaded or created, and whenever one of those changes.
    func applyGitHub(_ m: Managed) {
        applyToolInputs(m)                                   // 599h: the tools layer follows the same settings
        guard !readOnly, let egress = m.sandbox.egress else { return }
        let name = m.name
        let env = ProcessInfo.processInfo.environment
        let mode = AgentPermissions.gitHubMode(egress.policy.permissions)
        if let mode {
            let own = m.config.credentialSources[CredentialBinding.github.id]
            let memoryKey = githubKeys[name]
            let keychain = services.keychain
            let read: @Sendable () -> CredentialVault.SecretRead = {
                // The source is read EACH time (the setting can change while the sandbox runs).
                let source = DozerSettings.load(environment: env).string(SettingKey.githubCredentials) ?? "gh"
                if source == "off" {
                    return (nil, "Dozer: \"Use GitHub as you\" is on for \(name), but github.credentials is off on this Mac")
                }
                if let own {
                    if own.hasPrefix("keychain:"), let s = Keychain.read(service: String(own.dropFirst(9))) { return (s, nil) }
                    if let memoryKey { return (memoryKey, nil) }
                    return (nil, "Dozer: the GitHub token of \(name) is gone (it was held in memory by a host that stopped) — give it again: doz key set \(name) --github")
                }
                if source == "key" {
                    // 599e: the default key (the Access step's), when the sandbox has none of its own.
                    if let s = keychain.read(service: Access.githubKeyService, account: Keychain.user).value { return (s, nil) }
                    return (nil, "Dozer: \(name) has no GitHub token (github.credentials is key) — doz key set \(name) --github, or a default: doz access set --github-key")
                }
                return GitHubLogin.ghToken(environment: env)
            }
            // The source setting is the read's "version": choosing another source (or off) applies at the next request.
            let version: @Sendable () -> String = { DozerSettings.load(environment: env).string(SettingKey.githubCredentials) ?? "gh" }
            egress.vault.setProvider(.github, ttl: GitHubLogin.cacheSeconds, version: version, read: read)
            egress.github = GitHubGate(mode: mode, sandbox: name)
            egress.githubUpstreamForTests = GitHubLogin.testUpstream(environment: env)
            let id = GitHubLogin.macIdentity(environment: env)
            m.sandbox.setGitSetup(GitGuestSetup(on: true, name: id.name, email: id.email))
        } else {
            egress.vault.remove(CredentialBinding.github.id)          // every placeholder issued for it is now refused
            egress.github = nil
            egress.githubUpstreamForTests = nil
            m.sandbox.setGitSetup(.off)
        }
        bridgeState.resetFirstUse(name)
        egress.vault.onUse = { [weak self] id in
            guard id == CredentialBinding.github.id else { return }
            Task { await self?.githubUsed(name) }
        }
        let wantSSH = Self.sandboxValue(m.config, SettingKey.sshAgent) == .string("on")
        let socket = wantSSH ? GitHubLogin.agentSocket(environment: env) : nil
        if wantSSH, socket == nil {
            note(name, "SSH agent forwarding is on, but this Mac has no ssh-agent to forward (SSH_AUTH_SOCK) — start one and add a key (ssh-add)")
        }
        let sb = m.sandbox
        var onConnect: (@Sendable () -> Void)?
        if socket != nil {
            onConnect = { [weak self] in
                _ = Task { await self?.sshAgentUsed(name) }
            }
        }
        Task {
            await sb.setSSHAgent(socket: socket, onConnect: onConnect)
            await sb.applyGitHubToGuest()
        }
    }

    /// `doz key set NAME --github` / `doz key rm NAME --github`: the sandbox's own GitHub token — held in this
    /// host's memory (from stdin), or read again from the keychain item it names. It wins over the Mac's gh
    /// login; it is used only while "Use GitHub as you" is on.
    func setGitHubKey(_ m: Managed, _ r: HostRequest) throws -> [CredentialRow] {
        if r.op == .keySet {
            guard let s = r.secret?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, !s.contains(where: { $0.isWhitespace }) else {
                throw HostError(.invalid, "an empty (or not one-word) GitHub token")
            }
            githubKeys[m.name] = s
            m.config.credentialSources[CredentialBinding.github.id] = r.source ?? "stdin"
            note(m.name, "github token set (from \(r.source ?? "stdin"); memory only — the sandbox gets a placeholder while \"Use GitHub as you\" is on)")
        } else {
            githubKeys[m.name] = nil
            m.config.credentialSources[CredentialBinding.github.id] = nil
            note(m.name, "github token removed")
        }
        try m.config.write(store.configFile(m.name))
        applyGitHub(m)
        return credentials(m)
    }

    /// The first request of a "session" (since the setup was last applied) that used the login.
    func githubUsed(_ name: String) {
        guard let m = managed[name], let mode = m.sandbox.egress?.github?.mode else { return }
        let text = "\(name) used your GitHub login (\(mode == .push ? "read and push" : "read-only"))"
        guard bridgeState.firstUse(name, "github") else { return }
        note(name, text)
        bridgeState.notifyViewers(name, BridgeNotice("github", text))
    }

    func sshAgentUsed(_ name: String) {
        guard bridgeState.firstUse(name, "ssh") else { return }
        let text = "\(name) used your SSH agent (it asked your Mac's ssh-agent; your keys stay on the Mac)"
        note(name, text)
        bridgeState.notifyViewers(name, BridgeNotice("ssh", text))
    }
}
