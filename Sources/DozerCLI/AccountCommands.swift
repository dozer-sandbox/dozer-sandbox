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
        subcommands: [AccountList.self, AccountAdd.self, AccountVerify.self, AccountRemove.self, AccountDefault.self,
                      AccountUse.self, AccountKeepalive.self])
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
    @Option(name: .long, help: "With --claude-login: the CLAUDE_CONFIG_DIR it uses.") var configDir: String?
    @Option(name: .long, help: "With --api-key: adopt an existing keychain item (its service name) instead of storing a new one.") var keychain: String?
    @Option(name: .long, help: "With --setup-token: the plan (max, pro, team, enterprise) — Claude Code in the sandbox shows it and picks its default model by it.") var plan: String?
    @Flag(name: .long, help: "Store it without the check request.") var noVerify = false
    @Flag(name: .long, help: "Replace an account of that name.") var force = false

    func validate() throws {
        // 611: a public build has no ChatGPT sign-in of its own.
        if chatgpt, !BuildFlavor.current.chatgptSignIn { throw ValidationError(BuildFlavor.chatgptSignInMissing) }
        guard [setupToken, apiKey, claudeLogin, openaiKey, chatgpt].filter({ $0 }).count == 1 else {
            throw ValidationError("which kind? --setup-token, --api-key, --claude-login, --openai-key or --chatgpt")
        }
        if claudeLogin && configDir == nil { throw ValidationError("--claude-login needs --config-dir (the default Mac login is the built-in account mac)") }
        if keychain != nil && !apiKey && !openaiKey { throw ValidationError("--keychain is for --api-key or --openai-key") }
        if plan != nil && (chatgpt || openaiKey) { throw ValidationError("--plan is for --setup-token (a ChatGPT sign-in says its own plan)") }
        if let p = plan, !["max", "pro", "team", "enterprise"].contains(p.lowercased()) { throw ValidationError("--plan: max, pro, team or enterprise") }
    }

    func run() async throws {
        let kind: AccountKind = setupToken ? .setupToken : apiKey ? .apiKey : openaiKey ? .openaiKey : chatgpt ? .chatgpt : .mac
        var r = HostRequest.accountAdd(name: name, kind: kind, plan: plan, secret: nil,
                             verify: !noVerify, force: force, configDir: configDir, keychain: keychain)
        if chatgpt {
            // 599i: check the name first (an existing account without --force), then sign in.
            try AccountStore.validateName(name)
            if !force, let m = try? rawCall(HostRequest(.accountList), g), let rows = try? m.result?.decode([AccountRow].self),
               rows.contains(where: { $0.name == name }) {
                throw fail(HostError(.exists, "an account \(name) exists — --force replaces it (signs in again)"), g)
            }
            let tokens: ChatGPTTokens
            do { tokens = try ChatGPTSignIn.run { Out.stderr("[doz] \($0)\n") } } catch { throw fail(HostError(.failed, error.localizedDescription), g) }
            r.secret = tokens.json
        } else if setupToken || ((apiKey || openaiKey) && keychain == nil) {
            let s = try readSecret(setupToken ? "setup token from `claude setup-token` (not echoed): "
                                   : openaiKey ? "OpenAI API key (not echoed): " : "Anthropic API key (not echoed): ", g)
            guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw fail(HostError(.invalid, "nothing read (pipe it in, or paste it at the prompt)"), g) }
            r.secret = s
        }
        let rows = try decode(try call(r, g), [AccountRow].self, g)
        if g.json { Out.json(rows); return }
        let a = rows.first { $0.name == name }
        let who = [a?.identity, a?.plan].compactMap { $0 }.joined(separator: ", ")
        Out.stdout("account \(name) added (\(a?.kind ?? "?")\(who.isEmpty ? "" : ": " + who)\(a?.verification.map { ", \($0)" } ?? "")) — doz account use SANDBOX \(name)\n")
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
    func run() async throws {
        var r = HostRequest(.accountDefault)
        r.account = name
        if codex { r.accountKind = "codex" }
        let rows = try decode(try call(r, g), [AccountRow].self, g)
        if g.json { Out.json(rows) } else {
            let openai = codex || rows.first { $0.name == name }.flatMap { AccountKind(rawValue: $0.kind) }?.provider == "openai"
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
    func run() async throws {
        var r = HostRequest(.accountUse, name: sandbox)
        r.account = account
        let rows = try decode(try call(r, g), [CredentialRow].self, g)
        if g.json { Out.json(rows); return }
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
