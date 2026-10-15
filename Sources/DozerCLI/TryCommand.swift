import ArgumentParser
import Darwin
import Foundation
import DozerKit
import DozerHost

// 617 (D14, 616.07, the owner's "try = a hybrid") — `doz try THING`: from nothing to talking to an agent in one
// command. It is `doz new` with Quick-try defaults through the SAME choice options and planner (no second code path):
// a NEW EMPTY folder of its own under defaults.projects_dir (owner, after the demo: files the agent makes are on the Mac,
// opening files and copying work — never one of the person's folders; --isolated keeps none), Locked + the agent's own
// model, the agent's default base, the provider's default key, named try-<agent> and marked as a try. With no key: the "What you need" card (from the recipe's auth) — while the image prepares at
// once in the background. Attached; on the way out: "Keep this try? [S]leep / [d]elete / [k]eep running".

struct TryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "try",
        abstract: "Try an agent now: a throwaway sandbox with safe defaults — made, started and attached in one command.",
        discussion: """
        doz try grok · doz try gemini --base python · doz try (a numbered list of the agents, with your keys). \
        A try works in a NEW EMPTY folder Dozer makes under your projects folder (try-AGENT — never one of yours), shared \
        at /workspace, so what the agent makes is on your Mac; copying to your Mac's clipboard and opening files and links \
        on your Mac work as in any sandbox. It reaches only its own model (Locked; --permissions standard opens package \
        installs), runs on the agent's own base, uses your key for its provider (asked once when there is none), and is \
        named try-AGENT. On the way out it asks: sleep it (the default — it then holds no memory), delete it or keep it \
        running; --rm and --keep answer before. --ui opens the same in the dashboard (doz ui), with the agent chosen. Deleting it removes its folder too when the folder is empty, and asks \
        when the agent left files there. --isolated shares no folder at all (doz get and doz put \
        copy files out and in); --workspace DIR uses yours. Off a terminal it does not attach and asks nothing: it makes and starts \
        the try, keeps it, and prints how to attach. Every choice option of doz new works here.
        """)

    @OptionGroup var g: GlobalOptions
    @Argument(help: "The agent: an id or an alias (doz search lists them). None: a numbered list to pick from.") var thing: String?
    @OptionGroup var choices: ChoiceOptions
    @Option(name: .long, help: "With no agent: list only those with this tag (repeatable) — coding-agent, ai-tool, or a category (terminal-tool, personal-agent, framework …; doz search --help lists them).")
    var tag: [String] = []
    @Flag(name: .long, help: "Delete the try when you leave it, without asking.") var rm = false
    @Flag(name: .long, help: "Keep the try running when you leave it, without asking.") var keep = false
    @Flag(name: [.short, .customLong("detach")], help: "Make and start it, but do not attach (it is kept).") var detach = false
    @Flag(name: .long, help: "Make nothing: print the plan — the command, its doz_project.yaml, what it can reach (--json: as data).")
    var dryRun = false
    @Flag(name: .long, help: "Open the dashboard's Quick try instead (starting doz ui in the background when none runs; an open page is reused per ui.open_browser) — with AGENT chosen.")
    var ui = false

    func validate() throws {
        if rm && keep { throw ValidationError("--rm or --keep, not both") }
        if ui && (rm || keep || detach || dryRun) { throw ValidationError("--ui opens the dashboard's Quick try — it makes the choices there (not with --rm, --keep, -d or --dry-run)") }
        if choices.image != nil { throw ValidationError("a try runs its agent's own image — --base BASE picks another base") }
        // 617 (owner): the list by kind or category.
        for t in tag where Categories.word(t.lowercased()) == nil {
            throw ValidationError("--tag: coding-agent, ai-tool or a category: " + Categories.all.map(\.id).joined(separator: ", "))
        }
        if !tag.isEmpty && (thing != nil || choices.agent != nil) { throw ValidationError("--tag lists agents — not with an agent named") }
    }

    /// Ask the questions and attach: a terminal on both ends, and neither --json nor -d.
    var interactive: Bool { !g.json && !detach && isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 }

    func run() async throws {
        // Which agent.
        let given = thing ?? choices.agent
        if let t = thing, let a = choices.agent, AgentRecipes.matching(t)?.id != AgentRecipes.matching(a)?.id {
            throw fail(HostError(.invalid, "\(t) or --agent \(a) — not both"), g)
        }
        // 617: the dashboard's Quick try, on that agent.
        if ui {
            let id = try given.map { try resolve($0).id }
            try await showDashboardPage("try" + (id.map { "/" + $0 } ?? ""), g)
            return
        }
        let recipe: AgentRecipe
        if let t = given {
            recipe = try resolve(t)
        } else {
            recipe = try await pickFromList()
        }
        // 617: a superseded agent still runs — said first, with what replaces it.
        if let l = recipe.lifecycle, !l.isCurrent, !g.json, !g.quiet { Out.stderr("[doz] note: \(standingLine(l))\n") }
        var c = choices
        c.agent = recipe.id
        // 617: the plan's command is the whole command — the try's own flags too (`doz try grok --rm --dry-run`).
        let flags = (rm ? ["--rm"] : []) + (keep ? ["--keep"] : []) + (detach ? ["-d"] : [])
        let planned = try await requestPlan(PlanRequest(purpose: "try", create: try c.planChoices(), tryFlags: flags.isEmpty ? nil : flags), g)
        if dryRun { printPlan(planned, g); return }
        if let p = planned.problems.first(where: { $0.code != "key" }) {
            throw fail(HostError(.invalid, p.text + (p.fix.map { " — \($0)" } ?? "")), g)
        }
        var o = planned.create
        // --rebuild: an out-of-date image is rebuilt first (a try asks nothing, so without it the current image is used).
        if choices.rebuild { o.rebuild = true }
        // 617 (owner, 2026-10-15): what the person meets at the first start that Dozer leaves to them — said first.
        if !g.json, let n = recipe.guide?.notice { Out.stdout("\(recipe.title): \(n)\n") }
        if !g.json {
            // Said plainly (owner), first: where its files go and what reaches the Mac.
            let said = planned.reach.filter { $0.kind == "folder" || $0.kind == "bridge" }.map { $0.text.prefix(1).lowercased() + $0.text.dropFirst() }
            var parts = [planned.name, planned.imageState.title ?? planned.image] + said
            // Isolated: nothing of the Mac is shared — the way files come out (owner).
            if planned.workspace == nil { parts.append("pull files with: doz get \(planned.name) /workspace/FILE") }
            Out.stdout(parts.joined(separator: " · ") + "\n")
        }
        // The image prepares NOW, in the host, while the key is dealt with (joined by the start below).
        if planned.imageState.state == "unprepared" {
            var prep = HostRequest(.prepare)
            prep.images = [planned.image]
            prep.follow = false
            prep.requestedBy = "doz try"
            if (try? rawCall(prep, g))?.ok == true, !g.json, !g.quiet {
                Out.stderr("[doz] preparing the \(planned.imageState.title ?? planned.image) image now (once) — it goes on while you set up the key\n")
            }
        }
        // The key: the plan's account, else the card (a terminal), else the problem and how to fix it.
        if let p = planned.problems.first(where: { $0.code == "key" }) {
            guard interactive else { throw fail(HostError(.invalid, p.text), g) }
            if recipe.isBuiltin {
                try preflightAgentAccount(&o, g)
            } else if let s = o.modelSource, s != recipe.provider {
                // 617 (models@1): another provider or a gateway — a key of THAT source.
                o.account = try preflightSourceAccount(image: o.image, source: s, account: o.account, g)
            } else {
                o.account = try whatYouNeed(recipe)
            }
        }
        // Make it, start it, open its session.
        var r = HostRequest(.create, name: planned.name)
        r.create = o
        _ = try decode(try call(r, g), SandboxInfo.self, g)
        let started = try decode(try call(HostRequest(.start, name: planned.name), g), LifecycleResult.self, g)
        var open = HostRequest(.openSession, name: planned.name)
        let size = terminalSize()
        open.cols = size.cols
        open.rows = size.rows
        let opened = try decode(try call(open, g), SessionOpened.self, g)
        if !g.json, let n = opened.notice { Out.stderr("[doz] \(n)\n") }
        let attachLine = reattachCommand(sandbox: planned.name, session: opened.session, defaultSession: opened.defaultSession)
        guard interactive else {
            if g.json {
                Out.json(["name": .string(planned.name), "image": .string(planned.image), "phase": .string(started.phase), "session": .string(opened.session),
                          "trial": .bool(true), "attach": .string(attachLine)] as [String: JSONValue])
            } else {
                Out.stdout("\(planned.name) is \(Out.phaseLabel(started.phase)) and kept — \(attachLine) · doz rm \(planned.name) when you are done\n")
            }
            return
        }
        // 617.11 (owner: "i tried fabric and it just gave me a terminal"): a tool whose session is a shell gets its
        // "Start here" first — the guide's steps (doz guide NAME has it all).
        if recipe.launch.session == "shell", let guide = recipe.guide, !g.quiet {
            Out.stderr("\n" + Self.startHere(recipe.title, guide, sandbox: planned.name) + "\n")
        }
        let key = try parseDetachKey("ctrl-]")
        if !g.quiet {
            Out.stderr("[doz] \(planned.name) started — attaching to \(opened.session)\(key.map { " (\(describeKey($0)): the menu · twice: detach)" } ?? "")\n")
        }
        let end = AttachClient.attach(store: g.dozerStore, sandbox: planned.name, session: opened.session, wake: true, detachKey: key, quiet: g.quiet)
        try await finish(planned.name, end: end)
    }

    /// "Keep this try?" — or what --rm / --keep said.
    func finish(_ name: String, end: AttachEnd) async throws {
        let asker = Asker(yes: false, json: g.json)
        var choice = TryExitChoice.decided(rm: rm, keep: keep, interactive: asker.interactive)
        while choice == nil {
            choice = TryExitChoice.parse(asker.text(TryExitChoice.question, default: "S"))
        }
        switch choice! {
        // "Sleep" as a person means it (D14: "it then holds no memory"): Dozer's hibernate — a snapshot on disk, the
        // RAM returned; `doz wake` or `doz attach` brings it back where it was.
        case .sleep: _ = try lifecycle(.hibernate, name, g)
        case .delete:
            let folder = await tryFolder(name, g)
            _ = try lifecycle(.rm, name, g)
            cleanUpTryFolder(folder, g)
        case .keep: Out.stdout("\(name) keeps running — doz attach \(name) · doz rm \(name) when you are done\n")
        }
        if case .ended(let c) = end, c != 0 { throw ExitCode(c) }
    }

    /// THING → a recipe; a known-but-unsupported thing → its sentence (exit 6); nothing → did you mean (exit 2).
    func resolve(_ t: String) throws -> AgentRecipe {
        if t.contains("@") { throw fail(HostError(.notImplemented, "a model (THING@MODEL) comes in a later version — doz try \(t.split(separator: "@").first ?? "") for now"), g) }
        if let r = AgentRecipes.matching(t) { return r }
        let index = DirectoryIndex.build(version: DozerCommand.version)
        let found = DirectorySearch.search(SearchQuery.parse([t]), in: index)
        if let h = found.hits.first(where: { $0.entry.kind == "agent" }) {
            if h.outcome == "supported", let r = AgentRecipes.recipe(h.entry.id) { return r }
            Out.stderr("[doz] \(searchLine(h, local: nil, base: nil))\n")
            throw ExitCode(DozerExit.unavailable)
        }
        let hint = found.suggestion ?? DirectorySearch.suggest(t.lowercased(), in: index)
        Out.stderr("[doz] nothing called '\(t)'" + (hint.map { " — did you mean \($0)? (doz try \($0))" } ?? " — doz search lists the agents") + "\n")
        throw ExitCode(DozerExit.notFound)
    }

    /// 617.11: "Start here" — the guide's steps, numbered, each command indented (the first is its checked turn).
    static func startHere(_ title: String, _ g: AgentRecipe.Guide, sandbox: String) -> String {
        var lines = ["\(title): \(g.intro)", "Start here (doz guide \(sandbox) has it all):"]
        for (i, st) in g.steps.enumerated() {
            lines.append("  \(i + 1). \(st.text)")
            if let c = st.command { lines.append("       \(c)" + (st.edit == true ? "    (change it first)" : "")) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `doz try` alone: the numbered list (a terminal), else the list and exit 64.
    func pickFromList() async throws -> AgentRecipe {
        let index = DirectoryIndex.build(version: DozerCommand.version,
                                         latest: AgentCurrency.all(store: g.dozerStore).compactMapValues(\.indexLatest))
        let (accounts, images) = await searchLocals(g)
        // 617 (owner: "split them, also use tags"): --tag keeps those of a kind or category; coding agents first, then AI tools.
        let wanted = tag.map { $0.lowercased() }
        let fits = { (e: DirectoryIndex.Entry) in wanted.allSatisfy { e.catalogKind == $0 || (e.categories ?? []).contains($0) } }
        let order = Dictionary(uniqueKeysWithValues: Categories.kinds.enumerated().map { ($1.id, $0) })
        let byKind = { (a: DirectoryIndex.Entry, b: DirectoryIndex.Entry) in (order[a.catalogKind ?? ""] ?? 9) < (order[b.catalogKind ?? ""] ?? 9) }
        let agents = index.entries.filter { $0.kind == "agent" && $0.status == "supported" && fits($0) }.enumerated()
            .sorted { byKind($0.1, $1.1) || (!byKind($1.1, $0.1) && $0.0 < $1.0) }.map(\.1)
        let coming = index.entries.filter { $0.kind == "agent" && $0.status != "supported" && fits($0) }
        if agents.isEmpty {
            Out.stderr("[doz] nothing to try with " + wanted.map { "--tag " + $0 }.joined(separator: " ") + " — doz search --tag \(wanted.first ?? "") lists what is coming\n")
            throw ExitCode(DozerExit.notFound)
        }
        if g.json {
            Out.json(agents.map { SearchHitJSON(entry: $0, outcome: "supported", limit: nil, local: searchLocal($0, accounts: accounts, images: images)) })
            throw ExitCode(DozerExit.usage)
        }
        var s = "Try an agent:\n"
        var section: String?
        for (i, e) in agents.enumerated() {
            if e.catalogKind != section, let k = e.catalogKind.flatMap(Categories.kind) {
                section = e.catalogKind
                s += "  \(k.title):\n"
            }
            let l = searchLocal(e, accounts: accounts, images: images)
            let key = l?.haveKey.map { "key: \($0)" + (l?.source.map { " (\($0))" } ?? "") } ?? "no key yet — you'll be asked"
            let image = l?.image == "unprepared" ? "prepares ~1–3 min" : "ready"
            s += String(format: "  %2d. %@ — %@ · %@ · %@\n", i + 1, e.title, e.publisher ?? "", key, image)
            // 617: its latest release (and how old), and its standing with its maker.
            s += "      " + latestLine(e.latest, agent: e.id) + "\n"
            if let l = e.lifecycle, !l.isCurrent { s += "      " + standingLine(l) + "\n" }
        }
        if !coming.isEmpty { s += "  coming: " + coming.map(\.title).joined(separator: ", ") + "\n" }
        Out.stdout(s)
        let asker = Asker(yes: false, json: g.json)
        guard interactive, asker.interactive else {
            Out.stderr("[doz] pick one: doz try AGENT (e.g. doz try \(agents.first?.id ?? "grok"))\n")
            throw ExitCode(DozerExit.usage)
        }
        let answer = asker.text("Pick a number or a name", default: "1") { a in
            if let n = Int(a), (1...agents.count).contains(n) { return nil }
            return AgentRecipes.matching(a) == nil ? "a number from 1 to \(agents.count), or an agent's name" : nil
        }
        if let n = Int(answer) { return try resolve(agents[n - 1].id) }
        return try resolve(answer)
    }

    /// "What you need" (no key of the agent's provider yet): the card, a choice, and the account it makes — or `none`
    /// for a sign-in inside the agent.
    func whatYouNeed(_ recipe: AgentRecipe) throws -> String {
        guard let card = TryCard.build(recipe, haveKey: nil), !card.options.isEmpty,
              let provider = recipe.provider.flatMap({ KeyProviders.provider($0) }) else {
            throw fail(HostError(.invalid, AgentCredentials.requirement(recipe.id)), g)
        }
        Out.stdout("\n" + card.lines.joined(separator: "\n") + "\n\n")
        let asker = Asker(yes: false, json: false)
        let pick = asker.text("Choose 1–\(card.options.count)", default: "1") { a in
            Int(a).map { (1...card.options.count).contains($0) } == true ? nil : "a number from 1 to \(card.options.count)"
        }
        let option = card.options[Int(pick)! - 1]
        if option.kind == "sign-in" {
            Out.stdout("Then sign in inside \(recipe.title) — the sign-in lives in this sandbox (doz rm deletes it)\n")
            return "none"
        }
        let taken = Set(((try? decode(try rawCall(HostRequest(.accountList), g).result ?? .null, [AccountRow].self, g)) ?? []).map(\.name))
        let name = asker.text("Account name", default: taken.contains(provider.id) ? "\(provider.id)-2" : provider.id) {
            (try? AccountStore.validateName($0)) == nil ? "1–40 of a-z 0-9 - (not default or none)" : (taken.contains($0) ? "\($0) exists" : nil)
        }
        var add = HostRequest.keyAccountAdd(name: name, provider: provider.id, secret: nil)
        var secret: String?
        if option.kind == "paste" {
            let s = try readSecret("\(provider.title) \(provider.title.contains("API") ? "key" : "API key") (not echoed): ", g)
            guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw fail(HostError(.invalid, "nothing pasted"), g) }
            add.secret = s
            secret = s.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let ref = asker.text("Where is it? op://VAULT/ITEM/FIELD, aws:arn:aws:secretsmanager:…, or a command that prints it", default: "") {
                $0.isEmpty ? "a reference or a command" : nil
            }
            do {
                if ref.hasPrefix("op://") || ref.hasPrefix("aws:") { add.secretSource = try SecretSource.parse(from: ref) } else {
                    let src = try SecretSource.parseCommand(ref, resolve: SecretSources.locate)
                    if case .command(let p, let a) = src {
                        let shown = ([p] + a).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
                        guard asker.yesNo("The key will be read on this Mac by running: \(shown) (no shell; its output is the key). Save it?", default: true) else {
                            Out.stderr("[doz] nothing saved\n")
                            throw ExitCode(DozerExit.declined)
                        }
                    }
                    add.secretSource = src
                }
            } catch let e as HostError { throw fail(e, g) }
        }
        let m = try rawCall(add, g)
        guard m.ok == true else {
            let why = (m.error?.message ?? "no reason")
            throw fail(HostError(.invalid, "could not add \(name): " + (secret.map { why.replacingOccurrences(of: $0, with: "…") } ?? why)), g)
        }
        Out.stderr("[doz] account \(name) added (\(provider.title) key) — this try uses it\n")
        return name
    }
}
