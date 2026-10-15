import ArgumentParser
import Foundation
import DozerKit
import DozerHost

// 617 (616.07) — `doz search [THING]`: is it supported here? Agents, key providers and bases this Dozer knows (the
// directory index, `dozer-directory/v1`, built from the compiled-in recipes), with your key and the try command. For
// scripts: --json and the exit code. `doz agent ls|show` are its hidden aliases.

/// What THIS Mac has for a hit — never in the index (no user state there).
struct SearchLocal: Codable, Equatable {
    /// The account a try would use (the provider's default, else one of its keys).
    var haveKey: String?
    /// Where that key comes from ("1Password: op://…", "keychain").
    var source: String?
    /// The agent's own image: `prepared` | `older` | `unprepared`.
    var image: String?
}

struct SearchHitJSON: Codable, Equatable {
    var entry: DirectoryIndex.Entry
    var outcome: String
    var limit: String?
    var local: SearchLocal?
}

struct SearchJSON: Codable, Equatable {
    var verdict: String
    var hits: [SearchHitJSON]
    var suggestion: String?
}

/// The local facts for every agent hit (one read of the accounts and the images).
func searchLocals(_ g: GlobalOptions) async -> (accounts: [AccountRow], images: [ImageRow]) {
    let a = (try? decode(try await query(HostRequest(.accountList), g), [AccountRow].self, g)) ?? []
    let i = (try? decode(try await query(HostRequest(.imageList), g), [ImageRow].self, g)) ?? []
    return (a, i)
}

func searchLocal(_ e: DirectoryIndex.Entry, accounts: [AccountRow], images: [ImageRow]) -> SearchLocal? {
    guard e.kind == "agent", e.status == "supported" else { return nil }
    var l = SearchLocal()
    if let p = e.keys.first?.provider {
        let mine = accounts.filter { $0.provider == p && $0.kind != AccountKind.codexMac.rawValue }
        if let a = mine.first(where: \.isDefault) ?? mine.first {
            l.haveKey = a.name
            l.source = a.sourceLabel ?? (a.kind == AccountKind.mac.rawValue ? "this Mac's Claude login" : a.keychainService.map { _ in "keychain" })
        }
    }
    let row = images.first { $0.name == e.id }
    l.image = row?.baked != true ? "unprepared" : (row?.olderRecipe == nil && row?.current != false ? "prepared" : "older")
    return l
}

/// One hit, one line.
func searchLine(_ h: SearchHit, local: SearchLocal?, base: String?) -> String {
    let e = h.entry
    switch e.kind {
    case "provider":
        return "\(e.title) (key provider) — supported · agents: \((e.agents ?? []).joined(separator: ", "))" + (e.homepage.map { " · keys: \($0)" } ?? "")
    case "base":
        let not = e.limits.compactMap { $0.with["agent"] }
        return "\(e.title) (base \(e.id)) — runs \((e.agents ?? []).joined(separator: ", "))" + (not.isEmpty ? "" : "; not \(not.joined(separator: ", ")) (no musl build)")
    default: break
    }
    switch h.outcome {
    case "supported":
        // 618: a family's major says which it is and the others ("recommended; also @1").
        let fam = AgentRecipes.recipe(e.id).flatMap { AgentRef.choicesLine($0) }.map { " (\($0))" } ?? ""
        var s = "\(e.title)\(fam) — supported" + (e.checked.map { " · checked \($0)" } ?? "")
        if let p = e.keys.first?.provider {
            let title = KeyProviders.provider(p)?.title ?? p
            s += " · key: \(title)" + (local?.haveKey.map { " (you have \($0)" + (local?.source.map { ", \($0)" } ?? "") + ")" } ?? " (none yet — doz try asks)")
        }
        if let i = local?.image { s += " · image: " + (i == "prepared" ? "ready" : i == "older" ? "ready (older)" : "prepares on first use") }
        let limits = e.limits.filter { $0.with["base"] != nil }
        if !limits.isEmpty { s += " · not on " + limits.compactMap { $0.with["base"] }.joined(separator: ", ") }
        s += e.tryCommand.map { " · try it: \($0)" } ?? ""
        // 617: its latest release as this Mac last saw it, and its standing with its maker.
        s += "\n    " + latestLine(e.latest, agent: e.id)
        if let l = e.lifecycle, !l.isCurrent { s += "\n    " + standingLine(l) }
        return s
    case "limited":
        return "\(e.title) on \(base ?? "this base") — not supported here: \(h.limit ?? "")"
    default:
        return "\(e.title) — \(h.outcome == "coming" ? "coming" : "not possible"): \(e.reason ?? "")"
    }
}

/// 617: the measured line (`latest 1.3.3 · released 10 Oct 2026 (2 days ago) · active`). A tool installed from a pinned
/// release download or a hash-locked PyPI set is never looked up (`AgentRecipe.pinnedOnlyKinds`): its line says the pin,
/// never "not checked yet" — no check is coming.
func latestLine(_ l: DirectoryIndex.Latest?, agent: String? = nil) -> String {
    if l == nil, let id = agent, let r = AgentRecipes.recipe(id), AgentRecipe.pinnedOnlyKinds.contains(r.install.kind) {
        return "pinned \(r.install.pinned.version) — Dozer installs exactly this release; a newer one comes with a Dozer update"
    }
    guard let l else { return "latest: not checked yet (the host checks hourly while it runs)" }
    var s = "latest \(l.version)"
    if let r = l.released, let d = ISO8601DateFormatter().date(from: r + "T00:00:00Z") {
        s += " · released \(AgentCurrency.day(d)) (\(AgentCurrency.age(max(0, Int(Date().timeIntervalSince(d) / 86_400)))))"
    }
    switch l.freshness {
    case "active"?: s += " · active"
    case "quiet"?: s += " · quiet (no release in 3 months)"
    case "stale"?: s += " · stale (no release in 6 months)"
    case "deprecated"?: s += " · deprecated by its maker" + (l.deprecated.map { ": \($0)" } ?? "")
    default: break
    }
    return s
}

/// 617: the recorded standing (`superseded by Antigravity CLI — …`).
func standingLine(_ l: AgentLifecycle) -> String {
    let instead = l.by.flatMap { AgentRecipes.recipe($0) }.map { " · instead: doz try \($0.id)" } ?? ""
    return (l.note ?? l.status) + instead
}

/// 617 (owner): "AI tool · terminal tool, personal agent".
func categoryLine(kind: String, categories: [String]?) -> String {
    let k = Categories.kind(kind).map { String($0.title.dropLast()) } ?? kind          // "Coding agents" → "Coding agent"
    let c = (categories ?? []).filter { $0 != kind }.compactMap { Categories.category($0)?.title.lowercased() }
    return k + (c.isEmpty ? "" : " · " + c.joined(separator: ", "))
}

/// `--details`: the plain-language consent view of one agent.
func searchDetails(_ e: DirectoryIndex.Entry) -> String {
    var s = "\(e.title)" + (e.publisher.map { " · \($0)" } ?? "") + (e.homepage.map { " · \($0)" } ?? "") + "\n"
    if e.status != "supported" { return s + "  \(e.status): \(e.reason ?? "")\n" + (e.lifecycle.map { "  standing: \(standingLine($0))\n" } ?? "") }
    s += "  \(latestLine(e.latest, agent: e.id))\n"
    if let l = e.lifecycle, !l.isCurrent { s += "  standing: \(standingLine(l))\n" }
    if let i = e.install { s += "  installs: \(i.kind) \(i.source ?? "") \(i.version) (checksum-verified; its default base: \(e.defaultBase ?? "?"))\n" }
    if let r = e.reach {
        for h in r.model { s += "  may reach: \(h.host)" + (h.paths.map { " (only \($0.joined(separator: ", ")))" } ?? "") + " — its model\n" }
        for h in r.update { s += "  may reach: \(h.host)" + (h.paths.map { " (only \($0.joined(separator: ", ")))" } ?? "") + " — to update itself, when allowed\n" }
        if !r.excluded.isEmpty { s += "  kept out, whatever you choose: \(r.excluded.joined(separator: ", "))\n" }
    }
    for k in e.keys { s += "  keys: \(KeyProviders.provider(k.provider)?.title ?? k.provider) (\(k.accounts.joined(separator: ", "))) — the sandbox only gets a placeholder\n" }
    for a in e.auth {
        s += "  way in: \(a.kind)" + (a.provider.map { " (\($0))" } ?? "") + (a.account.map { " — \($0)" } ?? "") + (a.keysPage.map { " — get one at \($0)" } ?? "")
            + (a.note.map { " — \($0)" } ?? "") + "\n"
    }
    for l in e.limits { s += "  limit: \(l.with.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", ")) — \(l.reason)\n" }
    if !e.gateways.isEmpty {
        s += "  model gateways: " + e.gateways.map { "\($0.gateway) \($0.level)" + ($0.offered == true ? " (doz try --gateway \($0.gateway))" : "") }
            .joined(separator: " · ") + "\n"
    }
    let tags = e.tags.filter { ["documented", "verified"].contains($0.level) }.map(\.tag)
    if let k = e.catalogKind { s += "  what it is: " + categoryLine(kind: k, categories: e.categories) + "\n" }
    if !tags.isEmpty { s += "  tags: \(tags.joined(separator: ", "))\n" }
    if let t = e.terms { s += "  terms: \(t)\n" }
    if let c = e.tryCommand { s += "  try it: \(c)\n" }
    return s
}

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search",
        abstract: "Is it supported here? The agents, key providers and bases this Dozer knows — with your key, and the command to try it.",
        discussion: """
        doz search grok · doz search tag:multi-vendor-models · doz search --tag api-key --level any · doz search gemini --base alpine. \
        With nothing to look for it lists everything: supported, then coming. \
        Exit codes: 0 supported · 8 supported, but not with what you asked (a base it does not run on) · \
        6 known, but not in this Dozer (coming, or not possible) · 2 nothing by that name (did you mean …?) · 64 usage.
        """)

    @OptionGroup var g: GlobalOptions
    @Argument(help: "An agent, a key provider or a base (an id, an alias, a title or the start of one); tag:TAG terms filter by capability.")
    var terms: [String] = []
    @Option(name: .long, help: "Only agents with this tag (repeatable): a kind — coding-agent, ai-tool — a category — \(Categories.all.map(\.id).filter { $0 != "coding-agent" }.joined(separator: ", ")) — or a capability: \(CapabilityTags.all.map(\.id).joined(separator: ", ")).")
    var tag: [String] = []
    @Option(name: .long, help: "The tag levels that count: documented, verified, experimental, no, unknown (comma-separated) or any. Default: documented,verified.")
    var level: String?
    @Option(name: .long, help: "Is it supported on this base? (doz base ls)") var base: String?
    @Flag(name: .long, help: "One agent in full: what it installs, which hosts it may reach, its keys, what is kept out, gateway levels, tags.")
    var details = false
    @Option(name: .long, help: ArgumentHelp("Write the whole directory index (dozer-directory/v1, unsigned) to FILE.", visibility: .hidden))
    var index: String?
    @Flag(name: .long, help: ArgumentHelp("With --index: replace FILE.", visibility: .hidden)) var force = false

    /// 618: `opencode@1` / `opencode@2.0.28` search for that major's recipe (a term without @ is searched as it is).
    var resolvedTerms: [String] { terms.map { t in t.contains("@") ? ((try? AgentRef.resolve(t)).flatMap { $0?.recipe.id } ?? t) : t } }

    func validate() throws {
        let known = Set(CapabilityTags.all.map(\.id) + Categories.kinds.map(\.id) + Categories.all.map(\.id))
        let q = SearchQuery.parse(resolvedTerms, tags: tag, level: level, base: base)
        for t in q.tags where !known.contains(t) { throw ValidationError("no tag \(t) — the tags: \(known.sorted().joined(separator: ", "))") }
        for l in q.levels where !AgentRecipe.GatewaySupport.levels.contains(l) { throw ValidationError("--level: documented, verified, experimental, no, unknown or any") }
        if let b = base, BaseCatalogue.base(b) == nil { throw ValidationError("--base: \(BaseCatalogue.ids.joined(separator: ", "))") }
    }

    func run() async throws {
        // 617: the measured latest of each agent (the host's hourly check; a look never asks the registry).
        let built = DirectoryIndex.build(version: DozerCommand.version,
                                         latest: AgentCurrency.all(store: g.dozerStore).compactMapValues(\.indexLatest))
        if let path = index {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path), !force { throw fail(HostError(.exists, "\(url.path) exists — --force replaces it"), g) }
            do { try built.encoded().write(to: url, options: .atomic) } catch { throw fail(HostError(.failed, "could not write \(url.path): \(error.localizedDescription)"), g) }
            if !g.json { Out.stdout("wrote \(url.path) — \(built.entries.count) entries, \(DirectoryIndex.format), unsigned\n") }
            return
        }
        let q = SearchQuery.parse(resolvedTerms, tags: tag, level: level, base: base)
        var result = DirectorySearch.search(q, in: built)
        // 617: a superseded agent brings what replaces it (doz search gemini lists Antigravity CLI too).
        for h in result.hits {
            guard let by = h.entry.lifecycle?.by, !result.hits.contains(where: { $0.entry.id == by }),
                  let e = built.entries.first(where: { $0.kind == "agent" && $0.id == by }) else { continue }
            result.hits.append(SearchHit(outcome: e.status == "supported" ? "supported" : e.status, limit: nil, entry: e))
        }
        let (accounts, images) = await searchLocals(g)
        let everything = q.terms.isEmpty && q.tags.isEmpty
        if g.json {
            Out.json(SearchJSON(verdict: everything ? "supported" : result.verdict,
                                hits: result.hits.map { SearchHitJSON(entry: $0.entry, outcome: $0.outcome, limit: $0.limit,
                                                                      local: searchLocal($0.entry, accounts: accounts, images: images)) },
                                suggestion: result.suggestion))
        } else if result.hits.isEmpty {
            let what = q.terms.isEmpty ? "with " + q.tags.map { "tag:\($0)" }.joined(separator: " ") : "called '\(q.terms.joined(separator: " "))'"
            Out.stdout("nothing \(what)" + (result.suggestion.map { " — did you mean \($0)? (doz search \($0))" } ?? " — doz search lists everything") + "\n")
        } else if details {
            for h in result.hits.prefix(3) { Out.stdout(searchDetails(h.entry)) }
        } else if everything {
            // 617 (owner: "split them"): the agents by kind — coding agents, then AI tools — then providers and bases.
            for (title, keep) in [("Supported", ["supported"]), ("Coming", ["coming"]), ("Not possible", ["not-possible"])] {
                let hits = result.hits.filter { keep.contains($0.outcome) }
                guard !hits.isEmpty else { continue }
                let groups: [(String, [SearchHit])] = Categories.kinds.map { k in (k.title, hits.filter { $0.entry.kind == "agent" && $0.entry.catalogKind == k.id }) }
                    + [("", hits.filter { $0.entry.kind != "agent" || $0.entry.catalogKind == nil })]
                for (sub, gh) in groups where !gh.isEmpty {
                    Out.stdout("\(title)\(sub.isEmpty ? "" : " — " + sub.lowercased()):\n")
                    for h in gh { Out.stdout("  " + searchLine(h, local: searchLocal(h.entry, accounts: accounts, images: images), base: q.base) + "\n") }
                }
            }
        } else {
            for h in result.hits { Out.stdout(searchLine(h, local: searchLocal(h.entry, accounts: accounts, images: images), base: q.base) + "\n") }
        }
        guard !everything else { return }
        switch result.verdict {
        case "supported": return
        case "limited": throw ExitCode(DozerExit.limited)
        case "coming": throw ExitCode(DozerExit.unavailable)
        default: throw ExitCode(DozerExit.notFound)
        }
    }
}

/// `doz agent ls` / `doz agent show ID` — the earlier verbs, kept as hidden aliases of `doz search`.
struct AgentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "agent", abstract: "The agents this Dozer can run (doz search).",
        shouldDisplay: false, subcommands: [AgentList.self, AgentShow.self], defaultSubcommand: AgentList.self)
}

struct AgentList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "Every agent (doz search).")
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        var s = try SearchCommand.parse(g.json ? ["--json"] : [])
        s.g = g
        try await s.run()
    }
}

struct AgentShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "One agent in full (doz search ID --details).")
    @OptionGroup var g: GlobalOptions
    @Argument var id: String
    func run() async throws {
        var s = try SearchCommand.parse([id, "--details"] + (g.json ? ["--json"] : []))
        s.g = g
        try await s.run()
    }
}
