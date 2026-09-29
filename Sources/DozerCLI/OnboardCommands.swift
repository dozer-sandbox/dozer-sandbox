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
    var accountCommands: [String]
    var settings: String
    var settingsPath: String?
    var promptTemplate: String
    var promptTemplatePath: String?
    var images: [String]
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

        // 2. The Claude account (D6): offered, never logged in. A key or a token goes EXACTLY the way
        //    `doz account add` takes it: pasted at a no-echo prompt (or, with --secret-stdin, stdin).
        say("\n2. Claude account")
        let choice: Onboarding.Account
        if let a = accountFlag {
            choice = a
        } else {
            let login = ClaudeLoginStatus.check(configDir: nil, keychain: SystemKeychain(), probeBinary: false)
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

        // 3. Images (D2): claude-code ticked; lab and pi opt-in.
        say("\n3. Images")
        if imagesFlag == nil {
            let opts = Onboarding.imageOptions(rows)
            let ticks = asker.checklist("  Which images to prepare now (in the background — minutes, once)?",
                                        opts.map { ("\($0.name) — \($0.summary); \($0.download); \($0.prepared ? "ready" : $0.estimate)", $0.recommended || $0.prepared) })
            chosen = zip(opts, ticks).filter(\.1).map(\.0.name)
            let disk = Onboarding.checks(doctor: [], store: store, chosen: chosen, prepared: prepared)
            if let stop = disk.first(where: \.blocks) { throw fail(HostError(.failed, "onboarding stopped: \(stop.check) — \(stop.detail)"), g) }
            checks = checks.filter { $0.check != "disk" } + disk.filter { $0.check == "disk" }
        }
        say(chosen.isEmpty ? "  none now — each image is prepared by its first start" : "  " + chosen.joined(separator: ", "))

        // 4. Settings (D7): written only when missing; the user's prompt template beside them (D16).
        say("\n4. Settings")
        let (settings, settingsPath) = try settingsOutcome {
            try Onboarding.writeSettingsIfMissing(defaultImage: chosen.first ?? "claude-code", account: Onboarding.defaultAccount(for: choice))
        }
        switch settings {
        case .written: say("  wrote \(settingsPath ?? "doz.toml") — every setting listed at its default; set: defaults.image\(Onboarding.defaultAccount(for: choice) == nil ? "" : ", defaults.account")")
        case .kept: say("  \(settingsPath ?? "doz.toml") exists — left exactly as it is")
        case .unavailable: say("  no settings file (neither XDG_CONFIG_HOME nor HOME is set)")
        }
        let (template, templatePath) = try settingsOutcome { try Onboarding.writePromptTemplateIfMissing() }
        switch template {
        case .written: say("  wrote \(templatePath ?? AgentPrompt.userTemplateName) — your own environment prompt for agents (all commented out: the built-in one applies)")
        case .kept: say("  \(templatePath ?? AgentPrompt.userTemplateName) exists — left as it is")
        case .unavailable: break
        }

        // 5. The preparation (D3): in the host; Ctrl-C detaches.
        var result: PrepareResult?
        let todo = chosen.filter { !prepared.contains($0) }
        if chosen.isEmpty || todo.isEmpty {
            if !chosen.isEmpty { say("\n5. \(chosen.joined(separator: ", ")) already prepared in this store — nothing to do") }
            var r = HostRequest(.onboard)
            r.images = chosen
            r.requestedBy = "doz onboard"
            result = try decode(try call(r, g), PrepareResult.self, g)
        } else {
            say("\n5. Preparing \(chosen.joined(separator: ", ")) in the host — Ctrl-C detaches (it goes on): doz onboard --status watches it, --cancel stops it")
            var r = HostRequest(.onboard)
            r.images = chosen
            r.requestedBy = "doz onboard"
            result = try decode(try followingCall(r, g), PrepareResult.self, g)
        }
        if let rec = result?.onboarded {
            say("\nDone — this Mac is onboarded (\(rec.images.isEmpty ? "no image prepared yet" : rec.images.joined(separator: ", ") + " ready")).")
            say("Next: doz init in a project folder (then doz up there), or doz up NAME --workspace DIR · the UI: doz ui")
        }
        return OnboardReport(store: store.root.path, checks: checks, account: choice.rawValue, accountAdded: added,
                             accountCommands: added == nil ? Onboarding.accountCommands(choice) : [],
                             settings: settings.rawValue, settingsPath: settingsPath, promptTemplate: template.rawValue,
                             promptTemplatePath: templatePath, images: chosen, result: result)
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
        abstract: "Set up this Mac for Dozer Sandbox (once): check it, choose the Claude account, write the settings, prepare images in the background.",
        discussion: """
        Re-running is safe: it checks again, leaves existing settings alone and prepares only what is \
        missing. The images are prepared by the host: Ctrl-C detaches (the preparation goes on), \
        --status re-attaches, --cancel stops it. On a terminal it asks (Enter accepts the recommended \
        answer); --yes, --json or no terminal ask nothing.
        """)

    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "Show the onboarding record and the images; follow a preparation that is running.") var status = false
    @Flag(name: .long, help: "Cancel the images being prepared.") var cancel = false
    @Option(name: .long, help: "The images to prepare, comma-separated: claude-code, pi, lab (default: claude-code).") var images: String?
    @Flag(name: .long, help: "Prepare all three images (claude-code, pi, lab — ~15+ min the first time).") var allImages = false
    @Flag(name: .long, help: "Prepare no image now (the first start of each does it).") var noImages = false
    @Option(name: .long, help: "The Claude account step without asking: mac (this Mac's login), api-key, setup-token, or later. Given, the Claude Code checks are not run.") var account: String?
    @Option(name: .long, help: "With --account api-key|setup-token: the account's name (default: work; asked on a terminal).") var accountName: String?
    @Option(name: .long, help: "With --account setup-token: the plan (max, pro, team, enterprise).") var plan: String?
    @Flag(name: .long, help: "With --account api-key|setup-token off a terminal: read the key or token from stdin (as doz account add does). On a terminal it is pasted at a no-echo prompt.") var secretStdin = false
    @Flag(name: .long, help: "With --account api-key|setup-token: replace an account of that name.") var force = false
    @Flag(name: [.short, .long], help: "Accept every default; ask nothing.") var yes = false

    func validate() throws {
        if [status, cancel].filter({ $0 }).count + ((images != nil || allImages || noImages || account != nil) ? 1 : 0) > 1 {
            throw ValidationError("--status and --cancel stand alone")
        }
        if [images != nil, allImages, noImages].filter({ $0 }).count > 1 { throw ValidationError("one of --images, --all-images, --no-images") }
        if let i = images {
            for n in i.split(separator: ",") where !DozerImages.builtIn.contains(n.trimmingCharacters(in: .whitespaces)) {
                throw ValidationError("--images: claude-code, pi, lab (not \(n))")
            }
        }
        if let a = account, Onboarding.Account(rawValue: a) == nil { throw ValidationError("--account: mac, api-key, setup-token or later") }
        let keyed = account == "api-key" || account == "setup-token"
        if !keyed && (accountName != nil || secretStdin || force) { throw ValidationError("--account-name, --secret-stdin and --force go with --account api-key|setup-token") }
        if plan != nil && account != "setup-token" { throw ValidationError("--plan goes with --account setup-token") }
        if let p = plan, !["max", "pro", "team", "enterprise"].contains(p.lowercased()) { throw ValidationError("--plan: max, pro, team or enterprise") }
    }

    var imageList: [String]? {
        if allImages { return ["claude-code", "pi", "lab"] }
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

struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Make a folder a Dozer Sandbox project: write doz_project.yaml there (onboarding this Mac first if it never was). Then: doz up.",
        discussion: "The folder is shared at /workspace. On a terminal it asks for the sandbox's name and image (Enter accepts the suggestion); --yes, --json or no terminal ask nothing.")

    @OptionGroup var g: GlobalOptions
    @Argument(help: "The folder (default: the current one; made when missing).") var directory: String?
    @Option(name: .long, help: "The sandbox's name (default: from the folder's name).") var name: String?
    @Option(name: .long, help: "claude-code, pi, lab or a template (default: the settings' defaults.image).") var image: String?
    @Option(name: .long, help: "Virtual CPUs.") var cpus: Int?
    @Option(name: .long, help: "Guest RAM: 2G, 512M, 2048 (MiB).") var memory: String?
    @Option(name: .long, help: "agent, bake, locked, open, nat or none.") var network: String?
    @Option(name: .long, help: "default, none or an account name.") var account: String?
    @Flag(name: [.short, .long], help: "Accept every default; ask nothing.") var yes = false
    @Flag(name: .long, help: "Rewrite an existing doz_project.yaml.") var force = false

    func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let folder = (directory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, relativeTo: cwd) } ?? cwd).standardizedFileURL
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: folder.path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw fail(HostError(.invalid, "\(folder.path) is not a folder"), g) }
        } else {
            do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
                throw fail(HostError(.failed, "could not make \(folder.path): \(error.localizedDescription)"), g)
            }
            if !g.json { Out.stdout("made \(folder.path)\n") }
        }
        let file = folder.appendingPathComponent(DozerProject.fileName)
        if fm.fileExists(atPath: file.path), !force {
            throw fail(HostError(.exists, "\(file.path) exists — doz up there uses it (--force rewrites it)"), g)
        }
        let asker = Asker(yes: yes, json: g.json)
        // D1: a project needs an onboarded Mac.
        var onboarded: OnboardReport?
        if OnboardingRecord.read(g.dozerStore) == nil {
            if !g.json { Out.stdout("this Mac has not been onboarded yet — onboarding first\n\n") }
            onboarded = try await OnboardingFlow(g: g, asker: asker, imagesFlag: nil, accountFlag: nil, talk: !g.json).run()
            if !g.json { Out.stdout("\n") }
        }
        let suggested = DozerProject.suggestedName(for: folder)
        let sandbox = name ?? asker.text("Sandbox name", default: suggested) { WebNameRule.isSandboxName($0) ? nil : "1–40 of a-z 0-9 - (not starting with -)" }
        guard WebNameRule.isSandboxName(sandbox) else { throw fail(HostError(.invalid, "--name: 1–40 of a-z 0-9 -"), g) }
        let defImage = DozerSettings.load().string(SettingKey.defaultImage) ?? "claude-code"
        let img = image ?? asker.text("Image (claude-code, pi, lab or a template)", default: defImage) {
            $0.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil ? nil : "an image name"
        }
        var p = DozerProject(name: sandbox, image: img)
        p.cpus = cpus
        if let m = memory {
            guard let v = DozerImages.parseMemory(m) else { throw fail(HostError(.invalid, "--memory: \(m) is not a size (2G, 512M, 2048)"), g) }
            p.memoryMiB = v
        }
        p.network = network
        p.account = account
        let text = p.render()
        do { _ = try DozerProject.parse(text) } catch { throw fail(HostError(.invalid, error.localizedDescription), g) }   // our own file must read back
        do { try Data(text.utf8).write(to: file, options: .atomic) } catch {
            throw fail(HostError(.failed, "could not write \(file.path): \(error.localizedDescription)"), g)
        }
        if g.json {
            Out.json(["project": .string(file.path), "name": .string(sandbox), "image": .string(img), "workspace": .string(folder.path),
                      "onboarded": .bool(onboarded != nil || OnboardingRecord.read(g.dozerStore) != nil)] as [String: JSONValue])
        } else {
            Out.stdout("wrote \(file.path) — sandbox \(sandbox), image \(img), /workspace = \(folder.path)\n")
            Out.stdout("next: \(folder.path == cwd.path ? "" : "cd \(shellQuoted(folder.path)) && ")doz up\n")
        }
    }
}

func shellQuoted(_ s: String) -> String {
    if !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/._-+:@".contains($0)) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
