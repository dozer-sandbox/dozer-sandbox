import Foundation
import DozerKit

// 617 (§7, D6) — keys read on use from their source, and custom keys attached beside the account.

extension HostCore {
    /// Put account `a`'s key into binding `binding` of the sandbox's vault: from the keychain (as before), or — when
    /// the account reads it from 1Password, AWS or a command — as a PROVIDER the vault reads on use (the GitHub
    /// "as you" pattern): cached for the account's TTL, read again when its version (the reference's fingerprint +
    /// the account's generation) changes, once after an upstream 401, and eagerly now so the agent's first call does
    /// not wait. `addAgain`: the command that stores the key again.
    func applyKeySecret(_ m: Managed, _ a: AccountRecord, binding: CredentialBinding, addAgain: String) {
        let sb = m.sandbox
        guard let vault = sb.egress?.vault else { return }
        if a.readsOnUse, let source = a.source {
            let state = secretSourceState, account = a.name, env = a.sourceEnv ?? [:], known = a.fingerprint
            let base = SecretSources.fingerprint(source, environment: env)
            let environment = ProcessInfo.processInfo.environment
            vault.setProvider(binding, ttl: TimeInterval(a.ttlSeconds ?? SecretSources.defaultTTL),
                              version: { base + ":" + String(state.generation(account)) },
                              read: {
                                  let r = SecretSources.read(source, account: account, sourceEnv: env, environment: environment, knownFingerprint: known)
                                  state.record(account, r)
                                  if r.secret != nil { HostLog.line("account \(account): read its key from \(source.tool.map { $0 == "op" ? "1Password" : "AWS" } ?? "its command") (fp \(CredentialFingerprint.of(r.secret!)))") }
                                  return r
                              })
            let id = binding.id
            // One handler per vault: chain the one already there (a sandbox's account and its custom keys; every
            // apply starts from none — `detachWatcher`).
            let previous = vault.onStale
            vault.onStale = { [weak state] stale in
                guard stale == id else { previous?(stale); return }
                state?.staleAfterRejection(account)
            }
            Task.detached { vault.prefetch(id) }
            return
        }
        vault.clearProvider(binding.id)
        let service = a.keychainService ?? ""
        let read = services.keychain.read(service: service, account: a.adopted == true ? nil : Keychain.user)
        if let secret = read.value {
            sb.setCredential(binding, secret: secret, expiresAt: a.expiresAt, environment: [:], notice: "the key of account \(a.name) is not available — \(addAgain)")
        } else {
            sb.setCredential(binding, secret: nil, expiresAt: nil, environment: [:],
                             notice: "the keychain item \(service) of account \(a.name) is \(read == .locked ? "locked" : "missing") — "
                                 + (read == .locked ? "unlock the login keychain" : "add it again: \(addAgain)"))
        }
    }

    /// 617 (D6): the sandbox's custom keys — each swapped only on its own hosts, and only while the policy allows every
    /// one of them (otherwise its placeholder gets the proxy's 401 saying how to allow it). Keys no longer attached
    /// are removed (their placeholders refused at once).
    func applyExtraKeys(_ m: Managed, _ file: AccountsFile) {
        guard let egress = m.sandbox.egress else { return }
        let wanted = m.config.extraKeys ?? []
        for b in egress.vault.allBindings where b.id.hasPrefix("custom:") && !wanted.contains(String(b.id.dropFirst(7))) {
            egress.vault.remove(b.id)
        }
        for name in wanted {
            guard let a = file.accounts.first(where: { $0.name == name }), let c = a.custom else {
                let b = CredentialBinding(id: "custom:" + name, hosts: [], header: .bearer)
                egress.vault.remove(b.id)
                note(m.name, "the custom key \(name) this sandbox uses no longer exists — doz account use \(m.name) \(name) --remove-extra")
                continue
            }
            let binding = c.binding(account: name)
            let refused = c.hosts.filter { egress.policy.evaluateConnection(host: $0, port: 443).kind == .deny }
            if !refused.isEmpty {
                egress.vault.clearProvider(binding.id)
                m.sandbox.setCredential(binding, secret: nil, expiresAt: nil, environment: [:],
                                        notice: Self.extraKeyHostsRefused(m.name, name, refused))
                continue
            }
            applyKeySecret(m, a, binding: binding, addAgain: "doz account add \(name) --custom … --force")
        }
    }

    static func extraKeyHostsRefused(_ sandbox: String, _ key: String, _ hosts: [String]) -> String {
        "the custom key \(key) goes only to hosts the sandbox may reach, and \(hosts.joined(separator: ", ")) \(hosts.count == 1 ? "is" : "are") not allowed — "
            + hosts.map { "doz net allow \(sandbox) site:\($0)" }.joined(separator: "; ")
    }

    /// `doz account use SANDBOX NAME --extra | --remove-extra`.
    func useExtraKey(_ m: Managed, _ name: String, attach: Bool) throws -> [CredentialRow] {
        guard m.sandbox.egress != nil else { throw HostError(.invalid, "\(m.name) is not proxied — a custom key needs the Mac's proxy") }
        var keys = m.config.extraKeys ?? []
        let file = accountStore.load()
        if attach {
            guard let a = file.accounts.first(where: { $0.name == name }), let c = a.custom else {
                throw HostError(.notFound, "no custom key \(name) (doz account add \(name) --custom --host H --env-var V)")
            }
            if let p = m.sandbox.egress?.policy {
                let refused = c.hosts.filter { p.evaluateConnection(host: $0, port: 443).kind == .deny }
                if !refused.isEmpty { throw HostError(.invalid, Self.extraKeyHostsRefused(m.name, name, refused)) }
            }
            if !keys.contains(name) { keys.append(name) }
        } else {
            guard keys.contains(name) else { throw HostError(.notFound, "\(m.name) does not use the custom key \(name)") }
            keys.removeAll { $0 == name }
        }
        m.config.extraKeys = keys.isEmpty ? nil : keys
        try m.config.write(store.configFile(m.name))
        applyAccount(m)
        note(m.name, attach ? "uses the custom key \(name) — open sessions get its variable at their next start" : "no longer uses the custom key \(name)")
        return credentials(m)
    }

    /// 617: `doz account refresh NAME` — drop the cached value everywhere and read the key from its source now.
    func refreshAccount(_ r: HostRequest) async throws -> [AccountRow] {
        guard let name = r.account else { throw HostError(.invalid, "which account?") }
        let file = accountStore.load()
        guard let a = file.accounts.first(where: { $0.name == name }) else { throw HostError(.notFound, "no account \(name)") }
        guard a.readsOnUse, let source = a.source else {
            throw HostError(.invalid, "\(name) keeps its key in the keychain — nothing to read again (doz account verify \(name) checks it)")
        }
        secretSourceState.bump(name)
        let env = a.sourceEnv ?? [:], state = secretSourceState, known = a.fingerprint
        let read = await Task.detached { SecretSources.read(source, account: name, sourceEnv: env, knownFingerprint: known) }.value
        state.record(name, read)
        for m in sandboxesUsing(name, file) + managed.values.filter({ $0.config.extraKeys?.contains(name) == true }) {
            m.sandbox.egress?.vault.expireProviders()
        }
        note(nil, read.secret != nil ? "account \(name): its key was read again from \(source.label)" : "account \(name): \(read.notice ?? "its source answered nothing")")
        return await accountRows()
    }

    /// A source as the host accepts it: a command's program absolute, executable, never inside the store; the others
    /// re-parsed (the client's parse is never trusted).
    func validateSource(_ s: SecretSource) throws {
        switch s {
        case .keychain: break
        case .onePassword(let ref): _ = try SecretSource.parse(from: ref)
        case .awsSecretsManager(let arn, let key): _ = try SecretSource.parse(from: "aws:" + arn + (key.map { "#" + $0 } ?? ""))
        case .command(let p, let args):
            guard p.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: p) else { throw HostError(.invalid, "--from-command: \(p) is not an executable file") }
            let real = URL(fileURLWithPath: p).resolvingSymlinksInPath().path, storeRoot = store.root.resolvingSymlinksInPath().path
            guard !(real == storeRoot || real.hasPrefix(storeRoot + "/")) else { throw HostError(.invalid, "--from-command: a program inside Dozer's store is refused") }
            for a in args where a.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) || a.count > 1024 {
                throw HostError(.invalid, "--from-command: an argument holds a control character")
            }
            guard args.count <= 32 else { throw HostError(.invalid, "--from-command: at most 32 arguments") }
        }
    }

    /// 617: the planner's facts from this host (or, with no host, this in-process reader) — then the plan.
    func plan(_ r: PlanRequest) -> CreatePlan { plans([r])[0] }

    /// 617 (owner: Quick try "a blank modal with a considerable delay"): several plans on ONE reading of the store's
    /// facts — the image list (`images()`: every image's readiness, ~0.6 s with ~50 images) was read again for each
    /// of the ~45 agents the Quick try plans. Every plan is exactly what `plan` alone answers.
    func plans(_ rs: [PlanRequest]) -> [CreatePlan] {
        guard !rs.isEmpty else { return [] }
        let settings = DozerSettings.load()
        let file = accountStore.load()
        var labels: [String: String] = [:]
        for a in file.accounts where a.readsOnUse { labels[a.name] = a.source?.label }
        let taken = Set(managed.keys).union(store.sandboxNames())
        let rows = (try? images()) ?? []
        var codex: (openaiDefault: String?, signedIn: Bool)?        // read once, and only for a Codex plan
        return rs.map { r in
            let openai = AgentCredentials.codexFlow(CreatePlanner.image(r, settings: settings))
            if openai, codex == nil { codex = (effectiveOpenAIDefault(file), codexMacSignedIn()) }
            let facts = PlanFacts(settings: settings, accounts: file, taken: taken, images: rows, sourceLabels: labels, store: store,
                                  openaiDefault: openai ? codex?.openaiDefault : file.openaiDefault,
                                  codexMac: openai && codex?.signedIn == true)
            return CreatePlanner.plan(r, facts: facts)
        }
    }

    /// The source's last read, for `account ls|show` and the banner.
    func sourceRowFields(_ a: AccountRecord) -> (label: String?, state: String?, problem: String?) {
        guard a.readsOnUse, let s = a.source else { return (nil, nil, nil) }
        guard let o = secretSourceState.outcome(a.name) else { return (s.label, "unchecked", nil) }
        return (s.label, o.ok ? "ok" : "failed", o.ok ? nil : o.notice)
    }
}
