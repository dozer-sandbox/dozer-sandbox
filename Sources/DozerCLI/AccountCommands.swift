import ArgumentParser
import Darwin
import Foundation
import DozerKit
import DozerHost

// 588 — `doz account`: named Anthropic credentials the host holds (the Mac's own Claude login,
// `claude setup-token` tokens, API keys), a store default, and which account each sandbox uses.
// Secrets are read from a no-echo prompt or stdin, never an argument, and are kept in the login
// keychain; the store's accounts.json has names, kinds, dates and fingerprints only.

struct AccountCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "account",
        abstract: BuildFlavor.current.chatgptSignIn
            ? "Accounts the host holds for sandboxes: the Mac's Claude login, setup tokens, API keys; for Codex, a ChatGPT sign-in or an OpenAI key."
            : "Accounts the host holds for sandboxes: the Mac's Claude login, setup tokens, API keys; for Codex, the Mac's Codex login or an OpenAI key.",
        discussion: """
        mac (built in) is this Mac's own Claude Code login: nothing to add, renewed while Claude Code runs on the Mac. \
        A `claude setup-token` token lasts a year and needs no Mac: doz account add work --setup-token (paste it). \
        Codex uses OpenAI accounts only: mac — this Mac's own Codex login, read-only, nothing to add (the default when Codex is signed in \
        on this Mac) — or \(BuildFlavor.current.chatgptSignIn ? "doz account add NAME --chatgpt (Dozer's own sign-in, in your browser) or --openai-key" : "an OpenAI API key: doz account add NAME --openai-key"). A sandbox follows the store's default account (mac out of the box; for Codex the default OpenAI account) \
        unless it pins one: doz account use NAME ACCOUNT.
        """,
        subcommands: [AccountList.self, AccountShow.self, AccountAdd.self, AccountVerify.self, AccountRefresh.self, AccountRemove.self,
                      AccountDefault.self, AccountUse.self, AccountKeepalive.self])
}

func renderAccounts(_ rows: [AccountRow]) -> String {
    var t = [["NAME", "KIND", "PLAN", "IDENTITY", "STATE", "EXPIRES", "VERIFIED", "DEFAULT", "USED BY"]]
    for a in rows {
        t.append([a.name, a.kind, a.plan ?? "—", a.identity ?? "—", a.state,
                  a.expiresAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—",
                  a.verification ?? "—", a.isDefault ? "yes" : "", a.usedBy.isEmpty ? "—" : a.usedBy.joined(separator: ",")])
    }
    return Out.table(t)
}

struct AccountList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "The accounts (never a secret).")
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        let rows = try decode(try await query(HostRequest(.accountList), g), [AccountRow].self, g)
        if g.json { Out.json(rows) } else { Out.stdout(renderAccounts(rows)) }
    }
}

/// A secret from a no-echo prompt (a terminal) or stdin.
func readSecret(_ prompt: String, _ g: GlobalOptions) throws -> String {
    if isatty(STDIN_FILENO) != 0 {
        var buf = [CChar](repeating: 0, count: 8192)
        guard let p = readpassphrase(prompt, &buf, buf.count, 0) else { throw fail(HostError(.failed, "nothing read"), g) }
        let s = String(cString: p)
        memset(&buf, 0, buf.count)
        return s
    }
    return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
}

struct AccountAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add",
        abstract: "Add an account: a setup token or an API key (prompt or stdin), another Claude config dir's Mac login, "
            + (BuildFlavor.current.chatgptSignIn ? "a ChatGPT sign-in or an OpenAI key (Codex)." : "or an OpenAI key (Codex)."),
        discussion: """
        claude setup-token  then  doz account add work --setup-token --plan max  (paste the token). The token is checked with one tiny request and kept in the login keychain as doz-claude:NAME.
        """ + " " + (BuildFlavor.current.chatgptSignIn ? """
        doz account add chatgpt --chatgpt  opens your browser on OpenAI's sign-in: Dozer's OWN sign-in for Codex sandboxes (kept in the keychain as doz-chatgpt:NAME and renewed by Dozer; \
        the sandbox only ever sees placeholders). Your Mac's own Codex login (~/.codex) is never read or changed.
        """ : """
        doz account add openai --openai-key  (paste the key) for Codex sandboxes; or use this Mac's own Codex login, the built-in account mac (read-only — ~/.codex is never changed).
        """))
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Flag(name: .long, help: "A `claude setup-token` token (a Claude subscription, 1 year).") var setupToken = false
    @Flag(name: .long, help: "An Anthropic API key.") var apiKey = false
    @Flag(name: .long, help: "The Mac's Claude login of another config dir (--config-dir).") var claudeLogin = false
    @Flag(name: .long, help: "An OpenAI API key (Codex).") var openaiKey = false
    @Flag(name: .long, help: ArgumentHelp("Sign in with ChatGPT in your browser (Codex on your ChatGPT plan) — Dozer's own sign-in, not your Mac's Codex login.",
                                          visibility: BuildFlavor.current.chatgptSignIn ? .default : .hidden)) var chatgpt = false
    @Option(name: .long, help: "An API key of this provider or gateway: xai, google, google-stitch, openrouter, vercel-ai-gateway; anthropic = --api-key, openai = --openai-key.") var provider: String?
    @Option(name: .long, help: "With --claude-login: the CLAUDE_CONFIG_DIR it uses.") var configDir: String?
    @Option(name: .long, help: "With --api-key, --openai-key or --provider: adopt an existing keychain item (its service name) instead of storing a new one.") var keychain: String?

    /// 617: `--provider anthropic|openai` are `--api-key|--openai-key`; any other is a `key` of that provider.
    var keyProvider: KeyProvider? {
        guard let provider, let p = KeyProviders.provider(provider.lowercased()), p.builtinBinding == nil else { return nil }
        return p
    }
    var useAPIKey: Bool { apiKey || provider?.lowercased() == "anthropic" }
    var useOpenAIKey: Bool { openaiKey || provider?.lowercased() == "openai" }
    @Option(name: .long, help: "With --setup-token: the plan (max, pro, team, enterprise) — Claude Code in the sandbox shows it and picks its default model by it.") var plan: String?
    @Flag(name: .long, help: "Store it without the check request (and, with --from/--from-command, without reading the key now).") var noVerify = false
    @Flag(name: .long, help: "Replace an account of that name.") var force = false
    @Option(name: .long, help: "Read the key where you keep it, each time a sandbox needs it (kept in memory for --ttl, never stored): op://VAULT/ITEM/FIELD (1Password) or aws:arn:aws:secretsmanager:…[#jsonKey] (AWS Secrets Manager).")
    var from: String?
    @Option(name: .long, help: "Read the key by running this program (its output is the key): argv, never a shell — e.g. 'gh auth token'. Shown and confirmed before it is saved.")
    var fromCommand: String?
    @Option(name: .long, help: "A variable the source's tool runs with (repeatable): OP_ACCOUNT, AWS_PROFILE, AWS_REGION, AWS_CONFIG_FILE, AWS_SHARED_CREDENTIALS_FILE.")
    var env: [String] = []
    @Option(name: .long, help: "How long a key read from --from/--from-command is kept in memory before it is read again: 55m (default), 2h, 300s.")
    var ttl: String?
    @Flag(name: .long, help: "A custom key for any host (with --host, --env-var and --bearer or --header).") var custom = false
    @Option(name: .long, help: "With --custom: a host the key may go to (repeatable). The sandbox must also be allowed to reach it (--allow site:HOST).")
    var host: [String] = []
    @Option(name: .long, help: "With --custom: the variable the sandbox gets its placeholder in, e.g. EXAMPLE_API_KEY.") var envVar: String?
    @Flag(name: .long, help: "With --custom: send it as Authorization: Bearer KEY.") var bearer = false
    @Option(name: .long, help: "With --custom: the header it goes in, e.g. x-api-key.") var header: String?
    @Option(name: .long, help: "With --custom --header: the header's value, %s being the key (default %s).") var format: String?
    @Flag(name: .long, help: "Do not ask (--from-command's confirmation).") var yes = false

    var sourced: Bool { from != nil || fromCommand != nil }

    func validate() throws {
        // 611: a public build has no ChatGPT sign-in of its own.
        if chatgpt, !BuildFlavor.current.chatgptSignIn { throw ValidationError(BuildFlavor.chatgptSignInMissing) }
        if let p = provider, ModelSources.isKeyless(p.lowercased()) {
            throw ValidationError("\(ModelSources.title(p.lowercased())) takes no key — choose it for a sandbox instead (doz try opencode --provider \(p.lowercased()))")
        }
        if let p = provider, KeyProviders.provider(p.lowercased()) == nil {
            throw ValidationError("--provider: \(KeyProviders.all.map(\.id).joined(separator: ", ")) — not \(p)")
        }
        guard [setupToken, apiKey, claudeLogin, openaiKey, chatgpt, provider != nil, custom].filter({ $0 }).count == 1 else {
            throw ValidationError("which kind? --setup-token, --api-key, --claude-login, --openai-key, --chatgpt, --provider xai|google|google-stitch|openrouter|vercel-ai-gateway or --custom")
        }
        // 617 (§7): where the key is read from.
        if from != nil && fromCommand != nil { throw ValidationError("--from or --from-command, not both") }
        if sourced && !(useAPIKey || useOpenAIKey || keyProvider != nil || custom) { throw ValidationError("--from and --from-command are for API keys (--api-key, --openai-key, --provider, --custom)") }
        if sourced && keychain != nil { throw ValidationError("--keychain or --from/--from-command, not both") }
        if (!env.isEmpty || ttl != nil) && !sourced { throw ValidationError("--env and --ttl go with --from or --from-command") }
        if let t = ttl, SecretSources.parseTTL(t) == nil { throw ValidationError("--ttl: 1m to 24h, like 55m or 2h") }
        // 617 (D6): a custom key.
        if custom {
            if host.isEmpty || envVar == nil { throw ValidationError("--custom needs --host HOST and --env-var NAME") }
            if bearer == (header != nil) { throw ValidationError("--custom: --bearer, or --header NAME") }
            if format != nil && header == nil { throw ValidationError("--format goes with --header") }
        } else if !host.isEmpty || envVar != nil || bearer || header != nil || format != nil {
            throw ValidationError("--host, --env-var, --bearer, --header and --format go with --custom")
        }
        if claudeLogin && configDir == nil { throw ValidationError("--claude-login needs --config-dir (the default Mac login is the built-in account mac)") }
        if keychain != nil && !useAPIKey && !useOpenAIKey && keyProvider == nil { throw ValidationError("--keychain is for --api-key, --openai-key or --provider") }
        if plan != nil && (chatgpt || useOpenAIKey || keyProvider != nil) { throw ValidationError("--plan is for --setup-token (a ChatGPT sign-in says its own plan)") }
        if let p = plan, !["max", "pro", "team", "enterprise"].contains(p.lowercased()) { throw ValidationError("--plan: max, pro, team or enterprise") }
    }

    func run() async throws {
        let kind: AccountKind = setupToken ? .setupToken : useAPIKey ? .apiKey : useOpenAIKey ? .openaiKey : chatgpt ? .chatgpt
            : (keyProvider != nil || custom) ? .key : .mac
        var r = HostRequest.accountAdd(name: name, kind: kind, plan: plan, secret: nil,
                             verify: !noVerify, force: force, configDir: configDir, keychain: keychain)
        if custom {
            r.custom = CustomKey(hosts: host, header: bearer ? "authorization" : header ?? "", format: bearer ? "Bearer %s" : format ?? "%s", env: envVar ?? "")
            do { try r.custom?.validate() } catch let e as HostError { throw fail(e, g) }
        }
        if sourced {
            // 617 (§7): the reference only — the host reads the key now (once, to check it) and then on use.
            let source: SecretSource
            do {
                if let f = from { source = try SecretSource.parse(from: f) }
                else { source = try SecretSource.parseCommand(fromCommand ?? "", resolve: SecretSources.locate) }
            } catch let e as HostError { throw fail(e, g) }
            if case .command(let p, let a) = source {
                // D10: the exact argv, shown and confirmed (a terminal's y/N, or --yes).
                let shown = ([p] + a).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
                try confirm("The key of \(name) will be read on this Mac by running: \(shown)\n(no shell; its output is the key; it runs each time the key is read). Save it?", yes: yes, g)
            }
            var envs: [String: String] = [:]
            for kv in env {
                guard let eq = kv.firstIndex(of: "=") else { throw fail(HostError(.invalid, "--env: KEY=VALUE"), g) }
                envs[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
            }
            do { try SecretSources.checkEnvironment(envs) } catch let e as HostError { throw fail(e, g) }
            r.secretSource = source
            r.sourceEnv = envs.isEmpty ? nil : envs
            r.ttlSeconds = ttl.flatMap(SecretSources.parseTTL)
            r.provider = keyProvider?.id
        } else if custom {
            if keychain == nil {
                let s = try readSecret("the key for \(host.joined(separator: ", ")) (not echoed): ", g)
                guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw fail(HostError(.invalid, "nothing read (pipe it in, or paste it at the prompt)"), g) }
                r.secret = s
            }
        } else if let p = keyProvider {
            r.provider = p.id
            if keychain == nil {
                let s = try readSecret("\(p.title) API key (not echoed): ", g)
                guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw fail(HostError(.invalid, "nothing read (pipe it in, or paste it at the prompt)"), g) }
                r.secret = s
            }
        } else if chatgpt {
            // 599i: check the name first (an existing account without --force), then sign in.
            try AccountStore.validateName(name)
            if !force, let m = try? rawCall(HostRequest(.accountList), g), let rows = try? m.result?.decode([AccountRow].self),
               rows.contains(where: { $0.name == name }) {
                throw fail(HostError(.exists, "an account \(name) exists — --force replaces it (signs in again)"), g)
            }
            let tokens: ChatGPTTokens
            do { tokens = try ChatGPTSignIn.run { Out.stderr("[doz] \($0)\n") } } catch { throw fail(HostError(.failed, error.localizedDescription), g) }
            r.secret = tokens.json
        } else if setupToken || ((useAPIKey || useOpenAIKey) && keychain == nil) {
            let s = try readSecret(setupToken ? "setup token from `claude setup-token` (not echoed): "
                                   : useOpenAIKey ? "OpenAI API key (not echoed): " : "Anthropic API key (not echoed): ", g)
            guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw fail(HostError(.invalid, "nothing read (pipe it in, or paste it at the prompt)"), g) }
            r.secret = s
        }
        let rows = try decode(try call(r, g), [AccountRow].self, g)
        if g.json { Out.json(rows); return }
        let a = rows.first { $0.name == name }
        let who = [a?.identity, a?.plan].compactMap { $0 }.joined(separator: ", ")
        let what = a?.kind == AccountKind.key.rawValue ? "key, \(a?.provider ?? "?")" : (a?.kind ?? "?")
        Out.stdout("account \(name) added (\(what)\(who.isEmpty ? "" : ": " + who)\(a?.verification.map { ", \($0)" } ?? "")) — doz account use SANDBOX \(name)\n")
    }
}

struct AccountVerify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "verify", abstract: "Check an account: one tiny request to api.anthropic.com (or api.openai.com for an OpenAI key); a ChatGPT sign-in is renewed when it is due.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    func run() async throws {
        var r = HostRequest(.accountVerify)
        r.account = name
        let rows = try decode(try call(r, g), [AccountRow].self, g)
        if g.json { Out.json(rows); return }
        Out.stdout("\(name): \(rows.first { $0.name == name }?.verification ?? "?")\n")
    }
}

/// `doz account refresh NAME` — read a key kept in 1Password, AWS or a command again now.
struct AccountRefresh: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "refresh",
        abstract: "Read an account's key from where you keep it again now (--from / --from-command accounts): the value kept in memory is dropped.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    func run() async throws {
        var r = HostRequest(.accountRefresh)
        r.account = name
        let rows = try decode(try call(r, g), [AccountRow].self, g)
        if g.json { Out.json(rows); return }
        let a = rows.first { $0.name == name }
        if a?.sourceState == "ok" { Out.stdout("\(name): read again from \(a?.sourceLabel ?? "its source")\n") }
        else { throw fail(HostError(.failed, "\(name): \(a?.sourceProblem ?? "its source answered nothing")"), g) }
    }
}

/// `doz account show NAME` — one account, where its key comes from and the last read (never a value).
struct AccountShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "One account: its kind, where its key comes from and the last read — never a secret.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    func run() async throws {
        let rows = try decode(try await query(HostRequest(.accountList), g), [AccountRow].self, g)
        guard let a = rows.first(where: { $0.name == name }) else { throw fail(HostError(.notFound, "no account \(name)"), g) }
        if g.json { Out.json(a); return }
        Out.stdout(renderAccount(a))
    }
}

/// 617 (owner): the verification is HISTORY — when it was checked, not a state now ("last verified 12 Oct 16:21";
/// "rejected: … (12 Oct 16:21)"). The live state is the `state` line (and, for a key read on use, its last read).
func verifiedLine(_ a: AccountRow, now: Date = Date()) -> String {
    guard let v = a.verification else { return "—" }
    guard let at = a.verifiedAt else { return v }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_GB")
    f.dateFormat = Calendar.current.isDate(at, equalTo: now, toGranularity: .year) ? "d MMM HH:mm" : "d MMM yyyy HH:mm"
    let when = f.string(from: at)
    return v == "verified" ? "last verified \(when)" : "\(v) (\(when))"
}

func renderAccount(_ a: AccountRow) -> String {
    var lines: [(String, String)] = [("name", a.name), ("kind", a.kind == AccountKind.key.rawValue ? "key, \(a.provider ?? "?")" : a.kind)]
    if let h = a.hosts { lines.append(("hosts", h.joined(separator: ", "))) }
    lines.append(("key from", a.sourceLabel ?? (a.kind == AccountKind.mac.rawValue ? "the Mac's Claude Code login" : a.keychainService.map { "the keychain (\($0))" } ?? "—")))
    lines.append(("state", a.sourceState.map { $0 == "unchecked" ? "not read since the host started" : $0 } ?? a.state))
    if let p = a.sourceProblem { lines.append(("problem", p)) }
    if let f = a.fingerprint { lines.append(("fingerprint", f)) }
    lines.append(("verified", verifiedLine(a)))
    if let p = a.plan { lines.append(("plan", p)) }
    if let i = a.identity { lines.append(("identity", i)) }
    lines.append(("default", a.isDefault ? "yes" : "no"))
    lines.append(("used by", a.usedBy.isEmpty ? "—" : a.usedBy.joined(separator: ", ")))
    return lines.map { "\($0.0):".padding(toLength: 13, withPad: " ", startingAt: 0) + $0.1 }.joined(separator: "\n") + "\n"
}

struct AccountRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove an account and the keychain item doz made for it.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Flag(name: .long, help: "Also when sandboxes use it (they then follow the default).") var force = false
    func run() async throws {
        var r = HostRequest(.accountRemove)
        r.account = name
        r.force = force
        let rows = try decode(try call(r, g), [AccountRow].self, g)
        if g.json { Out.json(rows) } else { Out.stdout("account \(name) removed\n") }
    }
}

struct AccountDefault: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "default", abstract: "The account sandboxes that follow the default use (or none). An OpenAI account sets the Codex default; --codex sets it by name (mac = this Mac's Codex login).")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Flag(name: .long, help: "Set the default of Codex sandboxes: mac (this Mac's own Codex login), an OpenAI account, or none.") var codex = false
    @Option(name: .long, help: "With none: clear this key provider's default (xai, google, google-stitch, openrouter, vercel-ai-gateway). A key account sets its own provider's default.") var provider: String?
    func run() async throws {
        var r = HostRequest(.accountDefault)
        r.account = name
        if codex { r.accountKind = "codex" }
        r.provider = provider
        let rows = try decode(try call(r, g), [AccountRow].self, g)
        if g.json { Out.json(rows) } else {
            let row = rows.first { $0.name == name }
            if row?.kind == AccountKind.key.rawValue || (name == "none" && provider != nil) {
                let p = (row?.provider ?? provider).flatMap { KeyProviders.provider($0) }
                Out.stdout("the default \(p?.title ?? "key") account is \(name)\n")
                return
            }
            let openai = codex || row.flatMap { AccountKind(rawValue: $0.kind) }?.provider == "openai"
            Out.stdout(openai ? "the default OpenAI account (Codex) is \(name)\n" : "the default account is \(name)\n")
        }
    }
}

struct AccountUse: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "use",
        abstract: "Which account a sandbox uses: a name, default (follow the store's), or none. Open sessions switch on their next request.",
        discussion: "`doz account use NAME mac` also follows whoever is signed in on the Mac now (after the Mac signed in as a different account).")
    @OptionGroup var g: GlobalOptions
    @Argument var sandbox: String
    @Argument var account: String
    @Flag(name: .long, help: "Attach a custom key (doz account add NAME --custom …) beside the sandbox's account.") var extra = false
    @Flag(name: .long, help: "Take a custom key off the sandbox.") var removeExtra = false
    func validate() throws { if extra && removeExtra { throw ValidationError("--extra or --remove-extra, not both") } }
    func run() async throws {
        var r = HostRequest(.accountUse, name: sandbox)
        r.account = account
        if extra { r.extra = true }
        if removeExtra { r.removeExtra = true }
        let rows = try decode(try call(r, g), [CredentialRow].self, g)
        if g.json { Out.json(rows); return }
        if extra { Out.stdout("\(sandbox) uses the custom key \(account) — sessions opened from now on get its variable\n"); return }
        if removeExtra { Out.stdout("\(sandbox) no longer uses the custom key \(account)\n"); return }
        Out.stdout(account == "none" ? "\(sandbox) uses no account\n" : "\(sandbox) uses \(account)\n")
    }
}

struct AccountKeepalive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "keepalive",
        abstract: "on: near expiry, while a sandbox uses a Mac login and no Claude Code runs on the Mac, the host runs the Mac's claude once (off by default).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "on or off.") var state: String
    func validate() throws { guard ["on", "off"].contains(state) else { throw ValidationError("on or off") } }
    func run() async throws {
        var r = HostRequest(.accountKeepalive)
        r.enabled = state == "on"
        let f = try decode(try call(r, g), AccountsFile.self, g)
        if g.json { Out.json(f) } else { Out.stdout("keep-alive \(f.keepalive ? "on" : "off")\n") }
    }
}
