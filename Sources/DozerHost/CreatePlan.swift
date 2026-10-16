import Foundation
import DozerKit

// 617 (616.03 §6 step 2b, D13, D14) — ONE plan for every way a sandbox is made: `doz new`, `create`, `up`, `try` (and
// the wizard's review, stage D). The host's read-only op `plan` (answered in-process when no host runs) turns what a
// person chose into what will be made:
//   · the command that makes it — only what differs from their defaults;
//   · the `doz_project.yaml` text of the same choices;
//   · what it can reach, in plain words, from the SAME policy the proxy will judge with (`DozerImages.spec`);
//   · whether its image is ready; the account and its key's source (never a value); the problems in the way.
// The planner is pure given its facts (`PlanFacts`), so it is unit-tested without a host.

/// What a person chose. `create.image` empty: not chosen (the defaults decide).
public struct PlanRequest: Codable, Equatable, Sendable {
    /// `new` | `create` | `up` | `init` | `try`.
    public var purpose: String
    /// A name given on purpose (nil: the defaults name it).
    public var name: String?
    public var create: CreateOptions
    /// 617: a try's own flags that change nothing in the sandbox but belong to the command a person runs — `--rm`,
    /// `--keep`, `-d` — echoed at the end of the plan's command (`doz try grok --rm`). Only those three.
    public var tryFlags: [String]?

    public init(purpose: String, name: String? = nil, create: CreateOptions, tryFlags: [String]? = nil) {
        self.purpose = purpose
        self.name = name
        self.create = create
        self.tryFlags = tryFlags
    }

    public static let tryFlagWords: Set<String> = ["--rm", "--keep", "-d"]

    public static let purposes = ["new", "create", "up", "init", "try"]
}

/// One line of "what it can reach" — `kind` lets a page style it.
public struct ReachLine: Codable, Equatable, Sendable {
    /// `model` | `packages` | `github` | `web` | `folder` | `key` | `excluded` | `denied` | `other`.
    public var kind: String
    public var text: String
    public init(_ kind: String, _ text: String) { self.kind = kind; self.text = text }
}

public struct PlanImage: Codable, Equatable, Sendable {
    public var name: String
    /// "Debian · Grok Build".
    public var title: String?
    /// `prepared` (ready now) | `older` (prepared by an older recipe — used as it is) | `unprepared` (prepared on first use).
    public var state: String
}

public struct PlanAccount: Codable, Equatable, Sendable {
    /// nil: none.
    public var name: String?
    public var kind: String?
    public var provider: String?
    /// Where its key comes from ("1Password: op://…", "keychain") — never a value.
    public var sourceLabel: String?
}

/// 617 (models@1): the model source and model a recipe agent will use, and every source it could use instead.
public struct PlanModel: Codable, Equatable, Sendable {
    /// `xai`, `openai`, `openrouter` …
    public var source: String
    /// "OpenRouter".
    public var title: String
    public var gateway: Bool
    public var model: String
    /// The API shape spoken (nil: the tool's own client).
    public var shape: String?
    /// Every source it can be tried with, its default first.
    public var offered: [PlanSource]
}

public struct PlanSource: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var gateway: Bool
    /// The model it gets when none is chosen.
    public var defaultModel: String
    /// The account kind its key is added as (`key` with the provider, `api-key`, `openai-key`).
    public var accountKind: String
    /// Where such a key starts (`sk-or-`), when it is known — a hint only.
    public var keyHint: String?
    /// The base URL its endpoint for the recipe's shape has (nil: the tool's own client).
    public var baseURL: String? = nil
}

public struct PlanProblem: Codable, Equatable, Sendable {
    /// `key` | `key-host` | `image` | `name` | `invalid`.
    public var code: String
    public var text: String
    /// The command (or flag) that fixes it.
    public var fix: String?
}

/// The plan (fields only ever added).
public struct CreatePlan: Codable, Equatable, Sendable {
    public var purpose: String
    public var name: String
    public var image: String
    /// The Mac folder at /workspace; nil: isolated.
    public var workspace: String?
    public var trial: Bool?
    /// `doz try grok --base alpine` — only what differs from the defaults.
    public var command: String
    public var argv: [String]
    /// The same choices as `doz_project.yaml` (with `yamlNote` when the file would differ: isolated, sites).
    public var yaml: String
    public var yamlNote: String?
    public var reach: [ReachLine]
    public var imageState: PlanImage
    public var account: PlanAccount?
    public var problems: [PlanProblem]
    /// 617 (models@1): the model source and model (nil: an agent without a choice of source).
    public var model: PlanModel? = nil
    /// 618: the release it installs and, for a family, its majors (the Version choice; "also @1").
    public var version: PlanVersion? = nil
    /// What the create will send.
    public var create: CreateOptions
}

/// 618: what release a create installs, and a family's majors to choose from.
public struct PlanVersion: Codable, Equatable, Sendable {
    /// The release (nil: not known before its preparation).
    public var version: String?
    /// What it is made as: `opencode`, `opencode@1`, `opencode@2.0.28` (the typed reference, else the family's name).
    public var ref: String
    /// "OpenCode 2" (a family member) or the tool's title.
    public var title: String
    /// Every major of its family, oldest first (empty: not a family).
    public var majors: [Major] = []
    public struct Major: Codable, Equatable, Sendable {
        public var major: Int
        public var title: String
        /// `opencode@1`.
        public var ref: String
        public var recommended: Bool
        /// The one this plan is of.
        public var chosen: Bool
        /// Its pinned release (what Dozer checked).
        public var pinned: String
    }

    /// "OpenCode 2 2.0.29 (recommended) — OpenCode 1: doz try opencode@1" — a try's first line and its Guide (nil: not a
    /// family). Never "latest": the recommended major is a pin Dozer checked.
    public func familyLine(command: String = "doz try") -> String? {
        guard let c = majors.first(where: \.chosen) else { return nil }
        let head = "\(c.title)" + (version.map { " \($0)" } ?? "") + (c.recommended ? " (recommended)" : "")
        let others = majors.filter { !$0.chosen }.map { "\($0.title)" + ($0.recommended ? " (recommended)" : "") + ": \(command) \($0.ref)" }
        return others.isEmpty ? head : head + " — " + others.joined(separator: " · ")
    }
}

/// What the planner reads (the host fills it; tests make it).
public struct PlanFacts: Sendable {
    public var settings: DozerSettings
    public var accounts: AccountsFile
    /// The store's sandbox names.
    public var taken: Set<String>
    public var images: [ImageRow]
    /// account name → its source's label, for accounts that read their key on use.
    public var sourceLabels: [String: String]
    public var store: DozerStore
    /// The OpenAI default that applies (the Mac's Codex login when signed in), and whether the Mac's Codex is signed in.
    public var openaiDefault: String?
    public var codexMac: Bool
    /// `defaults.projects_dir`, expanded; nil: from the settings.
    public var projectsDir: String?

    public init(settings: DozerSettings, accounts: AccountsFile, taken: Set<String>, images: [ImageRow], sourceLabels: [String: String] = [:],
                store: DozerStore, openaiDefault: String? = nil, codexMac: Bool = false, projectsDir: String? = nil) {
        self.settings = settings
        self.accounts = accounts
        self.taken = taken
        self.images = images
        self.sourceLabels = sourceLabels
        self.store = store
        self.openaiDefault = openaiDefault
        self.codexMac = codexMac
        self.projectsDir = projectsDir
    }
}

public enum CreatePlanner {
    /// The image a request gets: the chosen one, else `defaults.image` (lab when none).
    public static func image(_ r: PlanRequest, settings: DozerSettings) -> String {
        r.create.image.isEmpty ? (settings.string(SettingKey.defaultImage) ?? "lab") : r.create.image
    }

    /// The name a try gets: `try-<agent>`, then `-2`, `-3` … — a name no sandbox has and, with `projects`, whose folder
    /// there is missing or empty (a try's folder is always a NEW empty one, never one of yours).
    public static func tryName(agent: AgentKind, taken: Set<String>, projects: String? = nil) -> String {
        let base = "try-" + (agent.recipe?.shortName ?? agent.rawValue)
        func free(_ n: String) -> Bool {
            if taken.contains(n) { return false }
            guard let projects else { return true }
            return Workspace.isEmptyOrMissing((projects as NSString).appendingPathComponent(n))
        }
        if free(base) { return base }
        var i = 2
        while !free("\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }

    public static func plan(_ r: PlanRequest, facts f: PlanFacts) -> CreatePlan {
        var problems: [PlanProblem] = []
        var o = r.create
        let image = Self.image(r, settings: f.settings)
        o.image = image
        let choice = ImageChoice.parse(image)
        let isTry = r.purpose == "try"
        let projects = f.projectsDir ?? (Workspace.defaultPath(name: "x", settings: f.settings) as NSString).deletingLastPathComponent

        // D14 (owner ruling after the demo): a try's defaults — a NEW empty folder of its own (files it makes are on the
        // Mac, the open-files bridge works), Locked + its own model, marked as a try. `--isolated` keeps no folder.
        if isTry {
            if o.network == nil { o.network = "locked" }
            o.trial = true
            if choice?.agent == nil || choice?.agent == AgentKind.none {
                problems.append(PlanProblem(code: "invalid", text: "a try is of an agent — doz search lists them", fix: "doz try AGENT"))
            }
        }

        // The name.
        let name: String
        if let n = r.name {
            name = n
            if !WebNameCheck.isSandboxName(n) {
                problems.append(PlanProblem(code: "name", text: "the name: 1–40 of a-z 0-9 - (not starting with -) — not \(n)", fix: nil))
            } else if f.taken.contains(n), r.purpose != "up" {
                problems.append(PlanProblem(code: "name", text: "sandbox \(n) already exists", fix: "doz up \(n) attaches to it"))
            }
        } else if isTry, let a = choice?.agent {
            name = tryName(agent: a, taken: f.taken, projects: r.create.workspace == nil && r.create.isolated != true ? projects : nil)
        } else {
            name = Workspace.suggestedName(image: image, taken: f.taken, projects: r.purpose == "new" ? projects : nil)
        }

        // The workspace: `doz new` makes `<projects_dir>/<name>` unless isolated or given.
        if r.purpose == "new" || isTry, o.workspace == nil, o.isolated != true {
            o.workspace = (projects as NSString).appendingPathComponent(name)
            if isTry {
                let w = o.workspace!
                if !Workspace.isEmptyOrMissing(w) {
                    problems.append(PlanProblem(code: "name", text: "\(w) is there and not empty — a try's folder is always a new empty one", fix: "--isolated, or --workspace DIR"))
                }
            }
        }
        // A folder Dozer would refuse to make or share (inside the store, a system location, a file): said by the plan,
        // before a try asks for a key — never after.
        if let w = o.workspace, let path = try? Workspace.normalize(w), let why = Workspace.refusal(path, store: f.store) {
            problems.append(PlanProblem(code: "invalid", text: why, fix: isTry || r.purpose == "new" ? "--isolated, or --workspace DIR" : nil))
        }
        let isolated = o.workspace == nil

        // The policy the proxy will judge with — the create's own function, without the folder (it may not exist yet).
        var specOptions = o
        specOptions.workspace = nil
        var policy: NetworkPolicy?
        var specVersion: String?        // 618: the release the create installs
        var networkMode: NetworkMode?
        do {
            let (spec, _) = try DozerImages.spec(name: WebNameCheck.isSandboxName(name) ? name : "plan", options: specOptions, store: f.store)
            networkMode = spec.network
            specVersion = spec.imageSpec?.agent?.version
            policy = spec.network.policy
        } catch {
            problems.append(PlanProblem(code: "invalid", text: (error as? HostError)?.message ?? "\(error)", fix: nil))
        }
        if let c = choice, c.agent != .none, let r = c.agent.recipe, BaseCatalogue.base(c.base)?.musl == true, !r.platforms.musl {
            problems.append(PlanProblem(code: "invalid", text: r.muslRefusal, fix: "--base \(r.defaultBase)"))
        }

        // 617 (models@1): a model source chosen — the account is a key of that source (the one given, else its default).
        let modelSource = o.modelSource ?? (o.model != nil ? AgentCredentials.sources(image)?.first : nil)
        var accountChoice = o.account
        var sourceProblem = false
        if let source = modelSource, policy != nil {
            let found = AgentCredentials.account(forSource: source, model: o.model, image: image, account: o.account, file: f.accounts)
            if let p = found.problem {
                problems.append(PlanProblem(code: p.fix.hasPrefix("doz account add") ? "key" : "invalid", text: p.text, fix: p.fix))
                sourceProblem = true
            } else if let n = found.name { accountChoice = n }
        } else if modelSource != nil {
            problems.append(PlanProblem(code: "invalid", text: "a model provider needs a proxied network: its key lives in the host's proxy", fix: nil))
        }

        // The account and its key.
        var kinds: [String: AccountKind] = ["mac": .mac]
        var providers: [String: String] = [:]
        for a in f.accounts.accounts {
            kinds[a.name] = a.kind
            if let p = a.provider { providers[a.name] = p }
        }
        var account: PlanAccount?
        if policy != nil, AgentCredentials.kinds(image) != nil {
            if !sourceProblem, let p = AgentCredentials.createProblem(image: image, account: accountChoice, defaultAccount: f.accounts.defaultAccount, kinds: kinds,
                                                      openaiDefault: f.openaiDefault, codexMac: f.codexMac,
                                                      providers: providers, providerDefaults: f.accounts.providerDefaults ?? [:]) {
                problems.append(PlanProblem(code: "key", text: p, fix: AgentCredentials.addCommand(image)))
            }
            let requested = accountChoice ?? "default"
            let resolved = requested == "default"
                ? AgentCredentials.defaultAccount(for: image, anthropic: f.accounts.defaultAccount, openai: f.openaiDefault ?? f.accounts.openaiDefault,
                                                  providers: f.accounts.providerDefaults ?? [:], kinds: kinds)
                : requested
            if resolved != "none" {
                let rec = f.accounts.accounts.first { $0.name == resolved }
                account = PlanAccount(name: resolved, kind: rec?.kind.rawValue ?? (resolved == "mac" ? (AgentCredentials.codexFlow(image) ? "codex-mac" : "mac") : nil),
                                      provider: rec?.providerID ?? AgentCredentials.provider(image),
                                      sourceLabel: f.sourceLabels[resolved] ?? rec?.keychainService.map { _ in "keychain" })
            } else {
                account = PlanAccount(name: nil, kind: nil, provider: AgentCredentials.provider(image), sourceLabel: nil)
            }
        }

        // A source chosen with no key of it yet: no account (the try setup offers that source's key).
        if sourceProblem, let s = modelSource, policy != nil { account = PlanAccount(name: nil, kind: nil, provider: s, sourceLabel: nil) }
        // 618: a key-less source (OpenCode Zen's free models): no account, and none is needed.
        if !sourceProblem, let s = modelSource, ModelSources.isKeyless(s), policy != nil { account = PlanAccount(name: nil, kind: "none", provider: s, sourceLabel: nil) }

        // 617 (models@1): which source and model — the account's source (the chosen one's when it has no key yet).
        var planModel: PlanModel?
        if let r = choice?.agent.recipe, r.models != nil {
            var source = modelSource ?? r.offeredSources.first ?? ""
            if modelSource == nil, let n = account?.name, let rec = f.accounts.accounts.first(where: { $0.name == n }),
               AgentCredentials.accepts(image, rec), let s = AgentCredentials.source(of: rec) { source = s }
            if let sel = r.selection(source: source, model: o.model.flatMap { ModelSelection.isModelID($0) ? $0 : nil }) {
                let offered = r.offeredSources.compactMap { id -> PlanSource? in
                    guard let d = r.selection(source: id) else { return nil }
                    return PlanSource(id: id, title: ModelSources.title(id), gateway: ModelSources.isGateway(id), defaultModel: d.model,
                                      accountKind: ModelSources.accountKind(id), keyHint: KeyProviders.provider(id)?.keyHint, baseURL: d.baseURL)
                }
                planModel = PlanModel(source: source, title: ModelSources.title(source), gateway: ModelSources.isGateway(source), model: sel.model,
                                      shape: sel.shape, offered: offered)
            }
        }

        // Custom keys: each must exist and each of its hosts be allowed.
        for k in o.keys ?? [] {
            guard let c = f.accounts.accounts.first(where: { $0.name == k })?.custom else {
                problems.append(PlanProblem(code: "key-host", text: "no custom key \(k)", fix: "doz account add \(k) --custom --host HOST --env-var VAR"))
                continue
            }
            if let p = policy {
                let refused = c.hosts.filter { p.evaluateConnection(host: $0, port: 443).kind == .deny }
                if !refused.isEmpty {
                    problems.append(PlanProblem(code: "key-host", text: "the custom key \(k) goes to \(refused.joined(separator: ", ")), which this sandbox may not reach",
                                                fix: refused.map { "--allow site:\($0)" }.joined(separator: " ")))
                }
            } else {
                problems.append(PlanProblem(code: "key-host", text: "a custom key needs a proxied network", fix: nil))
            }
        }

        // The image's readiness.
        let row = f.images.first { $0.name == image }
        let state = row?.baked != true ? "unprepared" : (row?.olderRecipe == nil && row?.current != false ? "prepared" : "older")
        let imageState = PlanImage(name: image, title: choice?.title, state: state)

        let newFolder = (r.purpose == "new" || isTry) && r.create.workspace == nil && o.workspace.map(Workspace.isEmptyOrMissing) == true
        var reach = Self.reach(networkMode, policy: policy, workspace: o.workspace, account: account, keys: o.keys ?? [], accounts: f.accounts,
                               newFolder: newFolder, settings: f.settings,
                               bridgeSettings: o.settings, agent: choice?.agent)
        if let m = planModel {
            // 618: a built-in agent (pi) on another source than Anthropic keeps its shared Anthropic model permission (an
            // account switched back needs it), so those hosts stay reachable — but this run's key is the source's, which the
            // proxy swaps in only on that source's hosts, and the Anthropic binding is gone: say exactly that.
            if m.source != "anthropic", let r = choice?.agent.recipe, r.isBuiltin, let perm = AgentPermissions.permission("model") {
                let hosts = perm.hosts.map(\.host).joined(separator: ", ")
                for i in reach.indices where reach[i].kind == "model" && reach[i].text.hasPrefix(perm.title) {
                    reach[i].text = "Anthropic, \(r.title)'s default provider (\(hosts)): reachable; no key goes there on this run"
                }
            }
            let hosts = ModelSources.hosts(m.source).joined(separator: ", ")
            reach.insert(ReachLine("model", ModelSources.isKeyless(m.source)
                ? "Model: \(m.model) through \(m.title) (\(hosts)) — no key needed: no key of yours goes there"
                : "Model: \(m.model) through \(m.title) (\(hosts)) — its key only ever goes there"), at: 0)
        }
        var argv = Self.argv(purpose: r.purpose, name: r.name, options: o, given: r.create, choice: choice, settings: f.settings)
        if r.purpose == "try" { argv += (r.tryFlags ?? []).filter { PlanRequest.tryFlagWords.contains($0) } }
        let (yaml, note) = Self.yaml(name: name, options: o, choice: choice, isolated: isolated)
        var plan = CreatePlan(purpose: r.purpose, name: name, image: image, workspace: o.workspace, trial: o.trial, command: Self.shellLine(argv),
                              argv: argv, yaml: yaml, yamlNote: note, reach: reach, imageState: imageState, account: account,
                              problems: problems, create: o)
        plan.model = planModel
        plan.version = Self.version(choice: choice, given: o, release: specVersion)
        return plan
    }

    /// 618: the release and, for a family, its majors (nil: no agent).
    static func version(choice: ImageChoice?, given o: CreateOptions, release: String?) -> PlanVersion? {
        guard let r = choice?.agent.recipe else { return nil }
        let v = o.agentVersion ?? release?.split(separator: "+").first.map(String.init)      // what was asked, else what it gets
        guard let f = r.family else {
            return PlanVersion(version: v, ref: o.agentRef ?? r.id, title: r.title)
        }
        let majors = AgentRef.members(f.family).map { m in
            PlanVersion.Major(major: m.family!.major, title: m.family!.title, ref: "\(f.family)@\(m.family!.major)",
                              recommended: m.family!.isRecommended, chosen: m.id == r.id, pinned: m.install.pinned.version)
        }
        return PlanVersion(version: v, ref: o.agentRef ?? (f.isRecommended ? f.family : "\(f.family)@\(f.major)"), title: f.title, majors: majors)
    }

    // MARK: the command

    /// `doz <purpose> [NAME] --flag …`: only what differs from the defaults (a try: from the try's own).
    static func argv(purpose: String, name: String?, options o: CreateOptions, given: CreateOptions, choice: ImageChoice?, settings: DozerSettings) -> [String] {
        var a = ["doz", purpose]
        let isTry = purpose == "try"
        if isTry {
            a.append(o.agentRef ?? choice.flatMap { $0.agent.recipe.map(AgentRef.typed) ?? $0.agent.rawValue } ?? o.image)   // 618: what was typed (opencode@1)
            if let c = choice, let r = c.agent.recipe, c.base != r.defaultBase, o.dockerfile == nil { a += ["--base", c.base] }
        } else {
            if let n = name { a.append(n) }
            let defaultImage = settings.string(SettingKey.defaultImage) ?? "lab"
            if o.dockerfile != nil {
                if let c = choice { a += ["--agent", o.agentRef ?? c.agent.recipe.map(AgentRef.typed) ?? c.agent.rawValue] }
            } else if purpose != "new" || o.image != defaultImage {
                if let c = choice, c.name == o.image, o.image != "lab", c.agent != .none || BaseCatalogue.base(o.image) == nil {
                    a += ["--agent", o.agentRef ?? c.agent.recipe.map(AgentRef.typed) ?? c.agent.rawValue]
                    if c.base != (c.agent.recipe?.defaultBase ?? "node") { a += ["--base", c.base] }
                } else if let c = choice, c.agent == .none, c.name == o.image, o.image != "lab" {
                    a += ["--agent", "none", "--base", c.base]
                } else {
                    a += ["--image", o.image]
                }
            }
        }
        if let d = o.dockerfile { a += ["--dockerfile", d] }
        // The folder: as given (`doz new`'s own `<projects_dir>/<name>` and a try's isolation are defaults).
        if let w = given.workspace { a += ["--workspace", w] }
        if given.isolated == true { a.append("--isolated") }
        if let c = o.cpus { a += ["--cpus", String(c)] }
        if let m = o.memoryMiB { a += ["--memory", m % 1024 == 0 ? "\(m / 1024)G" : "\(m)M"] }
        if let n = o.network, !(isTry && n == "locked") { a += ["--network", n] }
        if let s = o.subnet { a += ["--subnet", s] }
        let (words, github) = splitGitHub(o.allow ?? [])
        if !words.isEmpty { a += ["--permissions", words.joined(separator: ",")] }
        if let g = github { a += ["--github", g] }
        if let acc = o.account { a += ["--account", acc] }
        // 617 (models@1): the source (a gateway by its own flag) and the model.
        if let s = o.modelSource { a += [ModelSources.isGateway(s) ? "--gateway" : "--provider", s] }
        if let m = o.model { a += ["--model", m] }
        for k in o.keys ?? [] { a += ["--key", k] }
        if let s = o.agentSudo { a.append(s ? "--agent-sudo" : "--no-agent-sudo") }
        for (key, flag) in settingFlags {
            guard let v = o.settings?[key] else { continue }
            if key == SettingKey.tmux { a.append(v == .bool(true) ? "--tmux" : "--no-tmux") } else { a += [flag, v.plain] }
        }
        return a
    }

    /// The per-sandbox settings' flags, in the file's order.
    static let settingFlags: [(String, String)] = [
        (SettingKey.clipboard, "--clipboard"), (SettingKey.browserBridge, "--browser-bridge"), (SettingKey.openFiles, "--open-files"),
        (SettingKey.sshAgent, "--ssh-agent"), (SettingKey.tmux, "--tmux"), (SettingKey.ignoreMode, "--ignore-mode"),
        (SettingKey.workspaceView, "--workspace-view"),
    ]

    /// The permission words without GitHub's two, and those two as `--github`'s word (nil: not given).
    static func splitGitHub(_ allow: [String]) -> (words: [String], github: String?) {
        let asYou = AgentPermissions.gitHubAsYou, push = AgentPermissions.gitHubPush
        let gh = allow.filter { [asYou, push].contains($0.hasPrefix("+") || $0.hasPrefix("-") ? String($0.dropFirst()) : $0) }
        let words = allow.filter { !gh.contains($0) }
        guard !gh.isEmpty else { return (words, nil) }
        let on = Set(gh.filter { !$0.hasPrefix("-") }.map { $0.hasPrefix("+") ? String($0.dropFirst()) : $0 })
        return (words, on.contains(push) ? "push" : on.contains(asYou) ? "read" : "off")
    }

    static func shellLine(_ argv: [String]) -> String {
        argv.map { $0.range(of: #"^[A-Za-z0-9._/:=,@+-]+$"#, options: .regularExpression) != nil ? $0 : "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
    }

    // MARK: doz_project.yaml

    static func yaml(name: String, options o: CreateOptions, choice: ImageChoice?, isolated: Bool) -> (String, String?) {
        var p = DozerProject(name: WebNameCheck.isSandboxName(name) ? name : "sandbox", image: o.image)
        if let d = o.dockerfile { p.agent = choice.map { DozerProject.fileAgent($0.agent.rawValue) }; p.dockerfile = d }
        // 618: a tool's major or release as typed (`agent: opencode@1`) — and a family's bare name with the major it
        // resolved to (`opencode` → `opencode@2`): the file outlives this plan and must never change major by itself.
        if let ref = o.agentRef {
            if o.dockerfile == nil, let c = choice, c.base != c.agent.recipe?.defaultBase { p.base = c.base }
            p.agent = DozerProject.fileAgent(ref)
        }
        p.cpus = o.cpus
        p.memoryMiB = o.memoryMiB
        p.network = o.network
        p.account = o.account
        p.agentSudo = o.agentSudo
        p.agentPrompt = o.agentPrompt
        p.agentPromptMode = o.agentPromptMode
        p.settings = o.settings ?? [:]
        p.keys = o.keys
        p.modelSource = o.modelSource             // 618: project keys now
        p.model = o.model
        let (words, github) = splitGitHub(o.allow ?? [])
        p.github = github
        let sites = words.filter { $0.hasPrefix("site:") }
        var perms = words.filter { !$0.hasPrefix("site:") }
        if perms.first == "standard", perms.count > 1 { perms.removeFirst() }
        if !perms.isEmpty, SettingType.permissionWords(perms.joined(separator: ",")) != nil { p.permissions = perms }
        var notes: [String] = []
        if isolated { notes.append("in a folder, doz up shares that folder at /workspace; this sandbox has none (isolated)") }
        if !sites.isEmpty {
            notes.append("a site is not a project key — after doz up: " + sites.map { "doz net allow \(p.name) \($0)" }.joined(separator: "; "))
        }
        return (p.render(), notes.isEmpty ? nil : notes.joined(separator: " · "))
    }

    // MARK: what it can reach

    static func reach(_ mode: NetworkMode?, policy: NetworkPolicy?, workspace: String?, account: PlanAccount?, keys: [String],
                      accounts: AccountsFile, newFolder: Bool = false, settings: DozerSettings? = nil,
                      bridgeSettings: [String: TOMLValue]? = nil, agent: AgentKind? = nil) -> [ReachLine] {
        var out: [ReachLine] = []
        switch mode {
        case .nat?: out.append(ReachLine("web", "A real network interface: every host, unfiltered and unlogged (nat)"))
        case .none?: out.append(ReachLine("denied", "No network at all"))
        case .proxied?, nil: break
        }
        if let p = policy {
            let (names, own) = PermissionPolicy.inferred(p)
            // 617: an agent's own vendor sites (hidden) — a line per host, with its reason.
            for perm in AgentPermissions.all where names.contains(perm.id) && AgentPermissions.isAgentVendor(perm.id) {
                for h in perm.hosts {
                    let exact = (h.pathPrefixes ?? []).filter(EgressRule.isExactPath).map { String($0.dropLast()) }
                    let what = h.host + (exact.isEmpty ? "" : " (" + exact.joined(separator: ", ") + " only)")
                    out.append(ReachLine("model", "\(what) — \(h.reason ?? perm.summary)"))
                }
            }
            // 617: what the agent is told to turn off because a permission is off.
            if p.permissions != nil, let r = agent?.recipe {
                for o in r.network.offWithout ?? [] where !names.contains(o.permission) { out.append(ReachLine("denied", o.says)) }
            }
            for perm in AgentPermissions.all where names.contains(perm.id) && perm.hidden != true {
                let kind = perm.id.hasPrefix("model") ? "model" : perm.id.hasPrefix("install") ? "packages"
                    : perm.id.hasPrefix("github") ? "github" : perm.id == "web" ? "web" : "other"
                // 617: a host the recipe gives a reason for (its vendor's own site, a start-up check) is its own line, with
                // the reason; the summary names the rest.
                let plain = perm.hosts.filter { $0.reason == nil }
                var hosts: [String] = []
                for h in plain where !hosts.contains(h.host) { hosts.append(h.host) }
                let paths = plain.reduce(0) { $0 + ($1.pathPrefixes?.count ?? 0) }
                var where_ = hosts.prefix(3).joined(separator: ", ") + (hosts.count > 3 ? " +\(hosts.count - 3)" : "")
                if paths > 0 { where_ += ", \(paths) API path\(paths == 1 ? "" : "s")" }
                out.append(ReachLine(kind, hosts.isEmpty ? perm.title : "\(perm.title) (\(where_))"))
                for h in perm.hosts {
                    guard let why = h.reason else { continue }
                    let exact = (h.pathPrefixes ?? []).filter(EgressRule.isExactPath).map { String($0.dropLast()) }
                    let what = h.host + (exact.isEmpty ? "" : " (" + exact.joined(separator: ", ") + " only)")
                    out.append(ReachLine(kind, "\(what) — \(why)"))
                }
            }
            if !names.contains(where: { $0.hasPrefix("install") }) { out.append(ReachLine("packages", "No package installs\(p.preset == "locked" ? " (Locked)" : "")")) }
            for r in own where r.action == .allow && !r.hasHTTPConditions { out.append(ReachLine("web", "A site you allowed: \(r.host)")) }
            let excluded = AgentPermissions.excludedHosts(names)
            if !excluded.isEmpty { out.append(ReachLine("excluded", "Kept out whatever you choose: " + excluded.joined(separator: ", "))) }
            if !names.contains("web") { out.append(ReachLine("denied", "Every other host: refused and logged")) }
        }
        func tilde(_ p: String) -> String { DisplayPath.tilde(p) }
        if let w = workspace {
            out.append(ReachLine("folder", newFolder ? "A new empty folder \(tilde(w)) (not one of yours), at /workspace" : "Your folder \(tilde(w)) at /workspace"))
        } else {
            out.append(ReachLine("folder", "No folder of this Mac (isolated)"))
        }
        // 617 (owner): what reaches the Mac besides the network — said, on or off.
        if let settings {
            func value(_ key: String) -> String { (bridgeSettings?[key] ?? settings.resolve(key).value).plain }
            out.append(ReachLine("bridge", "Copy to your Mac's clipboard: " + (value(SettingKey.clipboard) == "off" ? "off" : "on")))
            out.append(ReachLine("bridge", "Open files on your Mac: " + (workspace == nil ? "off (no folder)" : value(SettingKey.openFiles))))
            out.append(ReachLine("bridge", "Open links in your Mac's browser: " + value(SettingKey.browserBridge)))
        }
        if let a = account {
            if let n = a.name {
                out.append(ReachLine("key", "Key: \(n)" + (a.sourceLabel.map { " from \($0)" } ?? "") + " — the sandbox gets a placeholder, the key stays on this Mac"))
            } else if a.kind == "none", let s = a.provider {
                out.append(ReachLine("key", "Key: none needed — \(ModelSources.title(s)) takes none, and nothing of yours is added to its requests"))   // 618
            } else if a.provider != nil {
                out.append(ReachLine("key", "No key yet"))
            }
        }
        for k in keys {
            if let c = accounts.accounts.first(where: { $0.name == k })?.custom {
                out.append(ReachLine("key", "Custom key \(k): only to \(c.hosts.joined(separator: ", ")), as a placeholder"))
            }
        }
        return out
    }
}
