import ArgumentParser
import Darwin
import Foundation
import DozerKit
import DozerHost

// 594 — `doz onboard` (this Mac, once) and `doz init` (a project folder). Design: workspace
// changes/594-*/594.01-DESIGN.md, D1–D10.

/// What `doz onboard --json` prints.
struct OnboardReport: Encodable {
    var store: String
    var checks: [OnboardingCheck]
    var account: String
    /// The account added now (a key or a token), when one was.
    var accountAdded: String?
    /// 599i: the OpenAI account the Codex step added (and made the OpenAI default).
    var openaiAccountAdded: String? = nil
    var accountCommands: [String]
    var settings: String
    var settingsPath: String?
    var promptTemplate: String
    var promptTemplatePath: String?
    var images: [String]
    /// 599e: the Access step — each credential's choice and whether it was confirmed.
    var access: [AccessItem]
    /// 599g: the Workspace rules step — the default `workspace.ignore_mode` chosen (nil: not chosen, unchanged).
    var ignoreMode: String?
    var result: PrepareResult?
}

/// The onboarding itself, shared by `doz onboard` and `doz init` (which onboards first when this
/// store never was).
struct OnboardingFlow {
    let g: GlobalOptions
    let asker: Asker
    let imagesFlag: [String]?
    let accountFlag: Onboarding.Account?
    /// Print human output (false: `--json`, or `init` doing it quietly).
    let talk: Bool
    /// A key / token account: its name, its plan (setup token), read the secret from stdin, replace.
    var accountName: String? = nil
    var plan: String? = nil
    var secretStdin = false
    var force = false
    /// 599e: the Access step's flags (nil: asked on a terminal, else left as the settings are).
    var githubFlag: String? = nil
    var githubSourceFlag: String? = nil
    var sshFlag: String? = nil
    var githubKeyStdin = false
    /// 599g: the Workspace rules step's flag (nil: asked on a terminal, else the settings are left as they are).
    var ignoreModeFlag: String? = nil
    /// The optional sign-up — release news, early access, tips and tricks. Never blocks the onboarding: skipped by default,
    /// and a failure is one line.
    private func stayInTouch() async {
        guard talk else { return }
        guard Usage.isOfficial else {
            say("\nStay in touch (optional): release news, early access and tips and tricks — sign up at \(Usage.signupPage)")
            return
        }
        guard asker.interactive else { return }
        say("\nStay in touch (optional) — release news, early access, tips and tricks; your email is confirmed first and never linked to the usage statistics")
        guard asker.yesNo("  Sign up?", default: false) else { say("  skipped — doz signup any time"); return }
        do {
            guard let r = try SignupCommand.ask(asker, email: nil, interests: [], source: "onboarding-cli", g) else { return }
            let result = try await Usage.signup(r)
            say("  " + SignupCommand.answerLine(result, email: r.email))
        } catch {
            say("  the sign-up did not go through — doz signup tries again, or \(Usage.signupPage)")
        }
    }

    /// 599i: Codex's OpenAI account step — chatgpt, openai-key or later (nil: asked on a terminal when codex is chosen).
    var openaiFlag: String? = nil

    func say(_ s: String) { if talk { Out.stdout(s + "\n") } }

    func run() async throws -> OnboardReport {
        let store = g.dozerStore
        say("Dozer Sandbox — setting up this Mac (once). Store: \(store.root.path)\n")

        // 1. Checks (D5): the doctor's, hard ones stop here.
        let rows = try decode(try await query(HostRequest(.imageList), g), [ImageRow].self, g)
        let prepared = Set(rows.filter { $0.current ?? false }.map(\.name))
        var chosen = imagesFlag ?? ["claude-code"]
        let doctor = Doctor.checks(store: store, claude: accountFlag == nil).map { (check: $0.check, status: $0.status.rawValue, detail: $0.detail) }
        var checks = Onboarding.checks(doctor: doctor, store: store, chosen: chosen, prepared: prepared)
        say("1. Checks")
        for c in checks { say(Self.checkLine(c)) }
        if accountFlag != nil { say("  —     claude          not checked (--account given)") }
        if let stop = checks.first(where: \.blocks) {
            say("")
            throw fail(HostError(.failed, "onboarding stopped: \(stop.check) — \(stop.detail)"), g)
        }

        // 2. Access (599e): the Claude account (D6: offered, never logged in — a key or a token goes EXACTLY
        //    the way `doz account add` takes it), GitHub as you, the SSH agent — each a purposeful choice,
        //    then each CONFIRMED live; a failure is skipped (kept, not confirmed), never blocking.
        say("\n2. Access — what sandboxes may use as you (each is confirmed; nothing is on unless you choose it)")
        say("  Claude account")
        let choice: Onboarding.Account
        if let a = accountFlag {
            choice = a
        } else {
            let login = ClaudeLoginStatus.check(configDir: nil, keychain: macLoginKeychain(), probeBinary: false)
            let signedIn = login.state == .signedIn
            say(signedIn ? "  Claude Code is signed in on this Mac — sandboxes can use that login (nothing is copied; the Mac renews it)."
                         : "  Claude Code is not signed in on this Mac.")
            let (options, preferred) = Onboarding.accountOptions(macSignedIn: signedIn)
            let i = asker.choose("  How should sandboxes reach Claude?", options.map(\.label), preferred: options.firstIndex(of: preferred) ?? 0)
            choice = options[i]
        }
        var added: String?
        switch choice {
        case .mac:
            var r = HostRequest(.accountDefault)
            r.account = "mac"
            _ = try call(r, g)
            say("  the store's default account: mac")
        case .later:
            say("  decide later — nothing changed (a claude-code sandbox says what it needs at its first session)")
        case .apiKey, .setupToken:
            added = try addAccount(choice)
        }
        var step = AccessStep(g: g, asker: asker, talk: talk, githubFlag: githubFlag, sourceFlag: githubSourceFlag, sshFlag: sshFlag)
        step.checkClaude = choice != .later
        if githubKeyStdin { step.githubKey = readGitHubToken(fromStdin: true) }
        let chosenAccess = step.choose()
        say("  Confirming")
        let (access, accessReport) = try step.confirm(AccessChoices(github: chosenAccess.github,
                                                                    githubSource: step.githubKey != nil ? "key" : chosenAccess.githubSource,
                                                                    ssh: chosenAccess.ssh))
        // Written only when CHOSEN (a flag, or answered on a terminal): `--yes` alone changes nothing.
        let accessChosen = asker.interactive || githubFlag != nil || sshFlag != nil || githubSourceFlag != nil || step.githubKey != nil

        // 3. Workspace rules (599g, owner A1): what .dozignore / .dozreadonly do, and the default mode — written
        //    only when CHOSEN (a flag or an answer), as the Access choices are.
        say("\n3. \(WorkspaceRulesGuide.title) — .dozignore and .dozreadonly")
        let ignoreMode = RulesStep(asker: asker, talk: talk, flag: ignoreModeFlag,
                                   current: DozerSettings.load().string(SettingKey.ignoreMode) ?? "lock", folder: nil).run()

        // 4. Images (D2): claude-code ticked; lab and pi opt-in.
        say("\n4. Images")
        if imagesFlag == nil {
            let settings = DozerSettings.load()
            let versions = Dictionary(uniqueKeysWithValues: ["claude-code", "pi", "codex"].compactMap { i in
                Onboarding.agentVersionText(i, store: store, settings: settings).map { (i, $0) } })
            let opts = Onboarding.imageOptions(rows, versions: versions)
            let ticks = asker.checklist("  Which images to prepare now (in the background — minutes, once)?",
                                        opts.map { ("\($0.name) — \($0.summary); \($0.download); \($0.prepared ? "ready" : $0.estimate)", $0.recommended || $0.prepared) })
            chosen = zip(opts, ticks).filter(\.1).map(\.0.name)
            let disk = Onboarding.checks(doctor: [], store: store, chosen: chosen, prepared: prepared)
            if let stop = disk.first(where: \.blocks) { throw fail(HostError(.failed, "onboarding stopped: \(stop.check) — \(stop.detail)"), g) }
            checks = checks.filter { $0.check != "disk" } + disk.filter { $0.check == "disk" }
        }
        say(chosen.isEmpty ? "  none now — each image is prepared by its first start" : "  " + chosen.joined(separator: ", "))

        // 4b (599i). Codex's account — OpenAI only, Dozer's own: a ChatGPT sign-in in the browser, or an OpenAI key.
        var openaiAdded: String?
        if chosen.contains(where: { ImageChoice.parse($0)?.agent == .codex }) || openaiFlag != nil {
            openaiAdded = try openAIAccountStep()
        }

        // 5. Settings (D7): written only when missing; the user's prompt template beside them (D16).
        say("\n5. Settings")
        let (settings, settingsPath) = try settingsOutcome {
            try Onboarding.writeSettingsIfMissing(defaultImage: chosen.first ?? "claude-code", account: Onboarding.defaultAccount(for: choice))
        }
        switch settings {
        case .written: say("  wrote \(settingsPath ?? "doz.toml") — every setting listed at its default; set: defaults.image\(Onboarding.defaultAccount(for: choice) == nil ? "" : ", defaults.account")")
        case .kept: say("  \(settingsPath ?? "doz.toml") exists — left exactly as it is")
        case .unavailable: say("  no settings file (neither XDG_CONFIG_HOME nor HOME is set)")
        }
        // 599e: the Access choices are the defaults for new sandboxes (written even into a file that was kept).
        if accessChosen, settings != .unavailable {
            let set: [String]
            do {
                set = try Access.write(github: access.github, githubSource: access.github == "off" && githubSourceFlag == nil ? nil : access.githubSource,
                                       ssh: access.ssh)
            } catch { throw fail(HostError(.failed, "\(error)"), g) }
            say(set.isEmpty ? "  Access: the settings already say so (defaults.github = \(access.github), sandbox.ssh_agent = \(access.ssh))"
                            : "  Access: set " + set.joined(separator: ", ") + " — new sandboxes follow them (doz access set changes them)")
        }
        // 599g: the rules' default mode, when chosen (into a file that was kept too).
        if let m = ignoreMode, settings != .unavailable {
            let set: [String]
            do { set = try Onboarding.writeIgnoreMode(m) } catch { throw fail(HostError(.failed, "\(error)"), g) }
            say(set.isEmpty ? "  Workspace rules: the settings already say so (workspace.ignore_mode = \(m))"
                            : "  Workspace rules: set " + set.joined(separator: ", ") + " — doz config set workspace.ignore_mode changes it")
        }
        let (template, templatePath) = try settingsOutcome { try Onboarding.writePromptTemplateIfMissing() }
        switch template {
        case .written: say("  wrote \(templatePath ?? AgentPrompt.userTemplateName) — your own environment prompt for agents (all commented out: the built-in one applies)")
        case .kept: say("  \(templatePath ?? AgentPrompt.userTemplateName) exists — left as it is")
        case .unavailable: break
        }
        // 599c: where doz new and the UI's Quick add / New sandbox put each new sandbox's workspace folder.
        let projects = (Workspace.defaultPath(name: "x") as NSString).deletingLastPathComponent
        say("  new sandboxes' workspace folders: \(projects)/<name> (defaults.projects_dir — doz config set defaults.projects_dir DIR moves it)")

        // Stay in touch (optional): the sign-up, asked only on a terminal (--yes and --json skip it). A build from the
        // open-source repository has no sign-up of its own: it names the website.
        await stayInTouch()

        // 6. The preparation (D3): in the host; Ctrl-C detaches.
        var result: PrepareResult?
        let todo = chosen.filter { !prepared.contains($0) }
        if chosen.isEmpty || todo.isEmpty {
            if !chosen.isEmpty { say("\n6. \(chosen.joined(separator: ", ")) already prepared in this store — nothing to do") }
            var r = HostRequest(.onboard)
            r.images = chosen
            r.requestedBy = "doz onboard"
            result = try decode(try call(r, g), PrepareResult.self, g)
        } else {
            say("\n6. Preparing \(chosen.joined(separator: ", ")) in the host — Ctrl-C detaches (it goes on): doz onboard --status watches it, --cancel stops it")
            var r = HostRequest(.onboard)
            r.images = chosen
            r.requestedBy = "doz onboard"
            result = try decode(try followingCall(r, g), PrepareResult.self, g)
        }
        if let rec = result?.onboarded {
            say("\nDone — this Mac is onboarded (\(rec.images.isEmpty ? "no image prepared yet" : rec.images.joined(separator: ", ") + " ready")).")
            say("Next: doz new (a sandbox with every default, attached) · doz init in a project folder (then doz up there) · the UI: doz ui")
        }
        return OnboardReport(store: store.root.path, checks: checks, account: choice.rawValue, accountAdded: added, openaiAccountAdded: openaiAdded,
                             accountCommands: added == nil ? Onboarding.accountCommands(choice) : [],
                             settings: settings.rawValue, settingsPath: settingsPath, promptTemplate: template.rawValue,
                             promptTemplatePath: templatePath, images: chosen, access: accessReport.items, ignoreMode: ignoreMode, result: result)
    }

    /// 599i: Codex's OpenAI account — a ChatGPT sign-in (the browser opens; Dozer's own sign-in, the Mac's
    /// ~/.codex is never touched) or an OpenAI key (a no-echo prompt), added as `doz account add` adds it and
    /// made the store's OpenAI default; or later. Off a terminal without --openai-account: later.
    private func openAIAccountStep() throws -> String? {
        say("  Codex account (OpenAI)")
        // rc.3: this Mac's own Codex login, when it is signed in — the least setup (nothing to add; read-only).
        let macState = CodexMacLogin.read(CodexMacLogin.resolveHome()).state
        let macSignedIn = macState == .ok || macState == .expired
        if macSignedIn { say("  Codex is signed in on this Mac — Codex sandboxes can use that login (nothing is copied; the Mac's Codex renews it).") }
        let choices = OpenAIChoices.onboarding(macSignedIn: macSignedIn, flavor: .current)
        let values = choices.map(\.value), options = choices.map(\.label)
        let pick: String
        if let f = openaiFlag { pick = f } else if asker.interactive {
            pick = values[asker.choose("  How should Codex sandboxes reach OpenAI?", options, preferred: 0)]
        } else if macSignedIn {
            say("  Codex sandboxes use this Mac's Codex login (mac) — the default while it is signed in; nothing written")
            return nil
        } else { pick = "later" }
        if pick == "mac" {
            guard macSignedIn else {
                say("  this Mac's Codex is not signed in (\(macState.label)) — run codex login on the Mac, or add an account later")
                return nil
            }
            var r = HostRequest(.accountDefault)
            r.account = "mac"
            r.accountKind = "codex"
            _ = try call(r, g)
            say("  Codex sandboxes use this Mac's Codex login (mac) — the store's default OpenAI account")
            return "mac"
        }
        func later() -> String? {
            say("  decide later — a codex sandbox says what it needs; then: " + OpenAIChoices.laterHint(flavor: .current))
            return nil
        }
        guard pick != "later" else { return later() }
        let name = asker.interactive ? asker.text("  Account name", default: pick == "chatgpt" ? "chatgpt" : "openai") {
            (try? AccountStore.validateName($0)) == nil ? "1–40 of a-z 0-9 - (not default or none)" : nil
        } : (pick == "chatgpt" ? "chatgpt" : "openai")
        var secret: String?
        if pick == "chatgpt" {
            do { secret = try ChatGPTSignIn.run { say("  " + $0) }.json } catch {
                say("  could not sign in: \(error.localizedDescription) — later: doz account add \(name) --chatgpt")
                return nil
            }
        } else if asker.interactive && isatty(STDIN_FILENO) == 1 {
            secret = try readSecret("  OpenAI API key (not echoed): ", g)
        }
        guard let secret, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            say("  no key given now — later: doz account add \(name) --openai-key")
            return nil
        }
        let kind: AccountKind = pick == "chatgpt" ? .chatgpt : .openaiKey
        let m = try rawCall(HostRequest.accountAdd(name: name, kind: kind, plan: nil, secret: secret, force: force), g)
        guard m.ok == true else {
            let why = (m.error?.message ?? "no reason").replacingOccurrences(of: secret.trimmingCharacters(in: .whitespacesAndNewlines), with: "…")
            say("  could not add \(name): \(why) — onboarding goes on without it")
            return nil
        }
        var r = HostRequest(.accountDefault)
        r.account = name
        _ = try call(r, g)
        let row = ((try? m.result?.decode([AccountRow].self)) ?? []).first { $0.name == name }
        say("  account \(name) added (\(kind.rawValue)\(row?.identity.map { ", \($0)" } ?? "")\(row?.plan.map { ", \($0)" } ?? "")) — the store's default OpenAI account (Codex)")
        return name
    }

    /// A key or a setup token, added exactly as `doz account add` adds it, then made the store default.
    /// On a terminal it is pasted at a no-echo prompt; off one only with `--secret-stdin` (stdin), as
    /// `doz account add` reads it; otherwise nothing is added and the commands are shown. The secret
    /// is never printed, and never part of an error. Returns the account's name when one was added.
    private func addAccount(_ choice: Onboarding.Account) throws -> String? {
        let kind: AccountKind = choice == .setupToken ? .setupToken : .apiKey
        let what = kind == .setupToken ? "setup token" : "API key"
        let name = accountName ?? asker.text("  Account name", default: "work") { (try? AccountStore.validateName($0)) == nil ? "1–40 of a-z 0-9 - (not default or none)" : nil }
        do { try AccountStore.validateName(name) } catch { throw fail(HostError.from(error), g) }
        let plan = kind == .setupToken ? (plan ?? asker.text("  Plan (max, pro, team, enterprise)", default: "max") {
            ["max", "pro", "team", "enterprise"].contains($0.lowercased()) ? nil : "max, pro, team or enterprise"
        }) : nil
        var secret: String?
        if asker.interactive && isatty(STDIN_FILENO) == 1 {
            if kind == .setupToken { say("  run `claude setup-token` in another terminal, then paste the token here") }
            secret = try readSecret("  \(what) (not echoed): ", g)
        } else if secretStdin {
            secret = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        guard let secret, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            say("  no \(what) given now (off a terminal, --secret-stdin reads one from stdin) — add it later:")
            for c in Onboarding.accountCommands(choice) { say("    " + c) }
            return nil
        }
        let m = try rawCall(HostRequest.accountAdd(name: name, kind: kind, plan: plan, secret: secret, force: force), g)
        guard m.ok == true else {
            // The host's message names the account, never the secret; it is scrubbed anyway.
            let why = (m.error?.message ?? "no reason").replacingOccurrences(of: secret.trimmingCharacters(in: .whitespacesAndNewlines), with: "…")
            say("  could not add \(name): \(why)")
            say("  onboarding goes on without it — later: \(Onboarding.accountCommands(choice).dropFirst(kind == .setupToken ? 1 : 0).first ?? "doz account add")")
            return nil
        }
        let rows = (try? m.result?.decode([AccountRow].self)) ?? []
        var r = HostRequest(.accountDefault)
        r.account = name
        _ = try call(r, g)
        let row = rows.first { $0.name == name }
        say("  account \(name) added (\(kind.rawValue)\(row?.verification.map { ", \($0)" } ?? ""); keychain \(row?.keychainService ?? "?"), fingerprint \(row?.fingerprint ?? "?")) — the store's default account")
        return name
    }

    private func settingsOutcome(_ body: () throws -> (Onboarding.ConfigOutcome, String?)) throws -> (Onboarding.ConfigOutcome, String?) {
        do { return try body() } catch let e as SettingsError {
            throw fail(HostError(.failed, e.message), g)
        }
    }

    static func checkLine(_ c: OnboardingCheck) -> String {
        let mark = switch c.status { case "ok": "ok  "; case "warn": "warn"; default: c.hard ? "FAIL" : "warn" }
        return "  \(mark)  \(c.check.padding(toLength: 15, withPad: " ", startingAt: 0)) \(c.detail)"
    }
}

/// A request whose progress is shown while it runs (593's view), from which Ctrl-C DETACHES — the
/// host goes on — saying how to watch again.
func followingCall(_ r: HostRequest, _ g: GlobalOptions,
                   detached: String = "the preparation goes on in the host — doz onboard --status watches it, doz onboard --cancel stops it") throws -> JSONValue {
    var gv = g
    gv.verbose = true                              // show it from the first second: this is the waiting part
    let progress = Progress(gv)
    signal(SIGINT, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    src.setEventHandler {
        progress.finish()
        if g.json { Out.json(["detached": true]) } else { Out.stderr("\n[doz] detached — \(detached)\n") }
        exit(130)
    }
    src.resume()
    defer {
        src.cancel()
        signal(SIGINT, SIG_DFL)
    }
    let m: HostMessage
    do {
        m = try HostClient.request(r, store: g.dozerStore, autostart: true) { progress.handle($0) }
    } catch let e as HostError {
        progress.finish()
        throw fail(e, g)
    } catch {
        progress.finish()
        throw fail(HostError(.unavailable, error.localizedDescription), g)
    }
    progress.finish()
    if m.ok == true { return m.result ?? .null }
    throw fail(m.error ?? HostError(.failed, "the host gave no reason"), g)
}

struct Onboard: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set up this Mac for Dozer Sandbox (once): check it, choose and confirm Access (the Claude account, GitHub, the SSH agent), choose what workspace rules do, write the settings, prepare images in the background.",
        discussion: """
        Re-running is safe: it checks again, leaves existing settings alone and prepares only what is \
        missing. The images are prepared by the host: Ctrl-C detaches (the preparation goes on), \
        --status re-attaches, --cancel stops it. On a terminal it asks (Enter accepts the recommended \
        answer); --yes, --json or no terminal ask nothing.
        """)

    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "Show the onboarding record and the images; follow a preparation that is running.") var status = false
    @Flag(name: .long, help: "Cancel the images being prepared.") var cancel = false
    @Option(name: .long, help: "The images to prepare, comma-separated: claude-code, pi, codex, lab (default: claude-code).") var images: String?
    @Flag(name: .long, help: "Prepare all four images (claude-code, pi, codex, lab — ~20+ min the first time).") var allImages = false
    @Flag(name: .long, help: "Prepare no image now (the first start of each does it).") var noImages = false
    @Option(name: .long, help: "The Claude account step without asking: mac (this Mac's login), api-key, setup-token, or later. Given, the Claude Code checks are not run.") var account: String?
    @Option(name: .long, help: "With --account api-key|setup-token: the account's name (default: work; asked on a terminal).") var accountName: String?
    @Option(name: .long, help: "With --account setup-token: the plan (max, pro, team, enterprise).") var plan: String?
    @Flag(name: .long, help: "With --account api-key|setup-token off a terminal: read the key or token from stdin (as doz account add does). On a terminal it is pasted at a no-echo prompt.") var secretStdin = false
    @Flag(name: .long, help: "With --account api-key|setup-token: replace an account of that name.") var force = false
    @Option(name: .long, help: "The Access step's GitHub choice without asking: off, read or push (new sandboxes signed in to GitHub as you).") var github: String?
    @Option(name: .long, help: "Where the GitHub token comes from: gh (this Mac's gh login) or key (--github-key-stdin).") var githubSource: String?
    @Flag(name: .long, help: "Read a GitHub token from stdin as the default key (implies --github-source key).") var githubKeyStdin = false
    @Option(name: .long, help: "The Access step's SSH choice without asking: on or off (forward this Mac's ssh-agent, github.com only).") var sshAgent: String?
    @Option(name: .long, help: "The Workspace rules step without asking: lock or hide — what a .dozignore in a sandbox's folder does to the paths it lists, by default (the setting workspace.ignore_mode). Lock: listed but unreadable; hide: not there.") var ignoreMode: String?
    @Option(name: .long, help: "Codex's OpenAI account without asking: mac (this Mac's own Codex login, read-only), chatgpt (sign in with ChatGPT in your browser — Dozer's own sign-in), openai-key (pasted at a no-echo prompt) or later.") var openaiAccount: String?
    @Flag(name: [.short, .long], help: "Accept every default; ask nothing. A credential that cannot be confirmed is skipped with a note (exit 0).") var yes = false

    func validate() throws {
        if let v = github, !["off", "read", "push"].contains(v) { throw ValidationError("--github: off, read or push") }
        if let v = githubSource, !["gh", "key"].contains(v) { throw ValidationError("--github-source: gh or key") }
        if let v = sshAgent, !["on", "off"].contains(v) { throw ValidationError("--ssh-agent: on or off") }
        if let v = ignoreMode, !["lock", "hide"].contains(v) { throw ValidationError("--ignore-mode: lock or hide") }
        if let v = openaiAccount, !["mac", "chatgpt", "openai-key", "later"].contains(v) { throw ValidationError("--openai-account: mac, chatgpt, openai-key or later") }
        if openaiAccount == "chatgpt", !BuildFlavor.current.chatgptSignIn { throw ValidationError("--openai-account chatgpt: " + BuildFlavor.chatgptSignInMissing) }
        if githubKeyStdin && secretStdin { throw ValidationError("--github-key-stdin and --secret-stdin both read stdin — add one later (doz access set --github-key / doz account add)") }
        if githubKeyStdin && githubSource == "gh" { throw ValidationError("--github-key-stdin goes with --github-source key") }
        if [status, cancel].filter({ $0 }).count + ((images != nil || allImages || noImages || account != nil || ignoreMode != nil) ? 1 : 0) > 1 {
            throw ValidationError("--status and --cancel stand alone")
        }
        if [images != nil, allImages, noImages].filter({ $0 }).count > 1 { throw ValidationError("one of --images, --all-images, --no-images") }
        if let i = images {
            for n in i.split(separator: ",") where !DozerImages.builtIn.contains(n.trimmingCharacters(in: .whitespaces)) {
                throw ValidationError("--images: claude-code, pi, codex, lab (not \(n))")
            }
        }
        if let a = account, Onboarding.Account(rawValue: a) == nil { throw ValidationError("--account: mac, api-key, setup-token or later") }
        let keyed = account == "api-key" || account == "setup-token"
        if !keyed && (accountName != nil || secretStdin || force) { throw ValidationError("--account-name, --secret-stdin and --force go with --account api-key|setup-token") }
        if plan != nil && account != "setup-token" { throw ValidationError("--plan goes with --account setup-token") }
        if let p = plan, !["max", "pro", "team", "enterprise"].contains(p.lowercased()) { throw ValidationError("--plan: max, pro, team or enterprise") }
    }

    var imageList: [String]? {
        if allImages { return ["claude-code", "pi", "codex", "lab"] }
        if noImages { return [] }
        return images.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    }

    func run() async throws {
        if status { try await showStatus(); return }
        if cancel { try cancelPreparations(); return }
        var flow = OnboardingFlow(g: g, asker: Asker(yes: yes, json: g.json), imagesFlag: imageList,
                                  accountFlag: account.flatMap(Onboarding.Account.init(rawValue:)), talk: !g.json)
        flow.accountName = accountName
        flow.plan = plan?.lowercased()
        flow.secretStdin = secretStdin
        flow.githubFlag = github
        flow.githubSourceFlag = githubKeyStdin ? "key" : githubSource
        flow.sshFlag = sshAgent
        flow.githubKeyStdin = githubKeyStdin
        flow.ignoreModeFlag = ignoreMode
        flow.openaiFlag = openaiAccount
        flow.force = force
        let report = try await flow.run()
        if g.json { Out.json(report) }
    }

    func showStatus() async throws {
        var st = try decode(try await query(HostRequest(.prepareStatus), g), PrepareStatus.self, g)
        let running = st.preparations.filter(\.running)
        if !running.isEmpty {
            if !g.json {
                for p in running { Out.stdout("joining the preparation of \(p.image) (asked by \(p.requestedBy.joined(separator: ", ")); \(Int(p.seconds)) s so far)\n") }
            }
            var r = HostRequest(.prepare)
            r.follow = true
            _ = try? followingCall(r, g)
            st = try decode(try await query(HostRequest(.prepareStatus), g), PrepareStatus.self, g)
        }
        if g.json { Out.json(st); return }
        Out.stdout(Self.render(st))
    }

    static func render(_ st: PrepareStatus) -> String {
        var s = ""
        if let o = st.onboarded {
            s += "onboarded: yes — doz \(o.dozVersion), \(o.date.formatted(date: .abbreviated, time: .shortened))"
                + (o.images.isEmpty ? "" : " (images: \(o.images.joined(separator: ", ")))") + "\n"
        } else {
            s += "onboarded: no — doz onboard sets up this Mac\n"
        }
        var t = [["IMAGE", "STATE"]]
        for r in st.images where r.kind == "builtin" {
            t.append([r.name, (r.current ?? false) ? "ready" : r.baked ? "baked by an older build — prepared again when next needed" : "not prepared (its first start does it)"])
        }
        s += "\n" + Out.table(t)
        if !st.preparations.isEmpty {
            s += "\nrecent preparations:\n"
            for p in st.preparations {
                s += "  \(p.image.padding(toLength: 12, withPad: " ", startingAt: 0)) \(p.state) — \(ProgressFormat.duration(p.seconds))"
                    + (p.error.map { ": \($0)" } ?? "") + " (asked by \(p.requestedBy.joined(separator: ", ")))\n"
            }
        }
        return s
    }

    func cancelPreparations() throws {
        guard g.dozerStore.hostIsRunning() else {
            if g.json { Out.json([PreparationInfo]()) } else { Out.stdout("nothing is being prepared (no host is running)\n") }
            return
        }
        let m = try rawCall(HostRequest(.prepareCancel), g, autostart: false)
        if m.ok == true, let v = m.result {
            let ps = try decode(v, [PreparationInfo].self, g)
            if g.json { Out.json(ps) } else { for p in ps { Out.stdout("cancelling the preparation of \(p.image)\n") } }
        } else if let e = m.error, e.code == .notFound {
            if g.json { Out.json([PreparationInfo]()) } else { Out.stdout("nothing is being prepared\n") }
        } else {
            throw fail(m.error ?? HostError(.failed, "no reason"), g)
        }
    }
}

// 599f: `doz init` is InitCommand.swift (the New Sandbox wizard's steps on a terminal).

func shellQuoted(_ s: String) -> String {
    if !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/._-+:@".contains($0)) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
