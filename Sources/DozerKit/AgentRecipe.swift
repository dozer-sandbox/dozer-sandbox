import Foundation

// 617 (616.03 §4) — every agent is a RECIPE: data that says how to install it, how to turn its own approval prompts
// off, which keys and hosts it uses, where its state lives and what it reaches. The recipes are YAML files
// (`Recipes/agents/VENDOR/PRODUCT.yaml`, schema 2 — RecipeDocument.swift) compiled to JSON and into DozerKit
// (`Recipes/compiled/*.json`, SwiftPM `.embedInCode` — no `Bundle.module`), decoded once and validated;
// an invalid built-in recipe is a test failure, never a runtime fallback.
//
// The three agents that existed before (Claude Code, pi, Codex) are `builtin`: their recipe DESCRIBES them (title,
// credentials, permissions, settings, state, prompt, resume) while their install steps and launchers stay in
// `AgentImages`' Swift — so their images keep every byte (RecipePinTests) — and `RecipeTruthTests` proves each
// describes its image truthfully. Every other recipe (Gemini CLI, Grok Build, …) is composed from its data alone.
//
// Rules a recipe can never break (validated here): it names no credential (no env key a bake would scrub), its
// hosts are exact names, the hosts it keeps out (`excluded`) are in no permission, and its pins are well-formed
// (they go into a bake script).

/// A JSON value inside a recipe (first-run settings, a manifest) — data only.
public enum RecipeValue: Codable, Sendable, Equatable {
    case string(String), bool(Bool), number(Double), object([String: RecipeValue]), array([RecipeValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([RecipeValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: RecipeValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        case .number(let n): if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    /// Every string inside (for the quote checks of what goes into a script).
    var strings: [String] {
        switch self {
        case .string(let s): [s]
        case .object(let o): o.keys.map { $0 } + o.values.flatMap(\.strings)
        case .array(let a): a.flatMap(\.strings)
        default: []
        }
    }
}

public struct AgentRecipe: Codable, Sendable, Equatable {
    public var schema: Int
    /// `[a-z][a-z0-9-]*` — the agent's id: `gemini`, `grok`; never a base id, `lab`, `none` or `custom`.
    public var id: String
    public var title: String
    /// 617: one sentence (the recipe file's `description`; the Quick try's details show it).
    public var description: String?
    public var publisher: String
    public var licence: String
    public var homepage: String
    /// What a person may also type for it (`claude`).
    public var aliases: [String]?
    /// true: install and launcher are `AgentImages`' Swift (Claude Code, pi, Codex).
    public var builtin: Bool?
    /// The base whose image is named `id` alone (D9) — Quick try's base.
    public var defaultBase: String
    public var platforms: Platforms
    /// Supported, with a limit: on which bases, and why (the index's `limits`).
    public var limits: [Limit]?
    public var install: Install
    public var launch: Launch
    public var state: State
    public var credentials: [CredentialUse]
    public var network: Network
    /// `osc7501` (Dozer's status protocol) | `none`.
    public var status: String
    /// Where Dozer's facts go (nil: nowhere).
    public var prompt: Prompt?
    /// Appended to the default session's argv on a restart (nil: it restarts fresh).
    public var resume: [String]?
    /// A guest check that there is a conversation to resume (an agent that refuses its resume flag without one).
    public var resumeCheck: String?
    /// Credential-free checks after the bake (`{version}` is the installed version).
    public var verify: [Check]
    /// 617: the smoke turn `make recipe-check` runs in a fresh try against the stand-in provider (the file's
    /// `launch@1.check`; every recipe file has one — the document refuses one without).
    public var smoke: Smoke?
    /// Shown where an account is chosen.
    public var terms: String?
    /// 617: where it stands with its maker (nil: current).
    public var lifecycle: AgentLifecycle?
    /// 617: its product mark in the icon registry (`Recipes/icons/icons.json`) — resolved product → vendor → a lettermark.
    public var icon: String?
    /// The date the recipe was last checked against the real agent.
    public var checked: String?
    /// The settings keys it uses (nil: derived — `images.<id>_version`, `<id>.permissions`).
    public var settings: SettingKeys?
    /// 617 (owner, "the try experience = a hybrid"): the ways a person can let this agent talk to its model, in order —
    /// the recommended first. Data for `doz try` / `doz search` / the Kitchen (stage C); `credentials` stays what the
    /// proxy and the account checks use today.
    public var auth: Auth
    /// 617 (owner): how this agent works through each model gateway of the catalogue (`Gateways.all`) — one entry per
    /// gateway, always. Data only in phase 1; phase 2 applies `how` mechanically (`experimental` only behind an opt-in).
    public var gateways: [GatewaySupport]
    /// 617 (owner): the capability tags with NO underlying field (`headless`) — declared, one per such tag of the
    /// vocabulary. Every other tag is derived (`capabilityTags`), so it cannot drift from the data.
    public var tags: [RecipeTag]
    /// 617 (owner: "split them, also use tags to classify them"): what it is, DECLARED (`directory@1` `kind`,
    /// `categories`; the vocabulary is tags.json's `kinds` and `categories`): `coding-agent` | `ai-tool`, and its
    /// categories (`terminal-tool`, `personal-agent` …) — the lists' sections and the Quick try's filter pills.
    public var catalogKind: String? = nil
    public var categories: [String]? = nil
    /// 617.11 (owner: "our companion guide"): its guide — intro, first steps (the first is its check turn), tips, docs
    /// (`com.dozersandbox/guide@1`; RecipeGuide.swift). nil: none.
    public var guide: Guide? = nil
    /// 617 (models@1): the model sources it can be tried with and how a choice reaches its settings; nil: its one
    /// credential, as before.
    public var models: Models? = nil

    /// 617 (RP-1, owner: "web port forwarding first"): the web ports its program serves in the sandbox, each forwarded
    /// to the Mac's loopback while the sandbox runs (`com.dozersandbox/ports@1`). nil: none.
    public var ports: WebPorts? = nil
    /// 618 (owner: "make sure there is a way the user can chose an earlier major version"): the major release line this
    /// recipe is of a family whose majors are separate recipes (`com.dozersandbox/family@1`; AgentRef.swift). nil: none.
    public var family: Family? = nil

    public struct Family: Codable, Sendable, Equatable {
        /// What a person types (`opencode`): the recommended major's recipe.
        public var family: String
        public var major: Int
        /// "OpenCode 2".
        public var title: String
        /// The major the family's name means — exactly one per family, moved by Dozer only once the new major passes
        /// `make recipe-check`. Labelled "recommended", never "latest".
        public var recommended: Bool? = nil
        public var isRecommended: Bool { recommended == true }
    }

    /// The web ports a recipe declares, and how its web part is started when the session's program is not it.
    public struct WebPorts: Codable, Sendable, Equatable {
        public var ports: [WebPort]
        /// The command that serves them when the session's program does not (`aichat --serve`): `make recipe-check`
        /// runs it in the background for its port check, and the manual tells people to run it. nil: the program does.
        public var serve: [String]?
        public init(ports: [WebPort], serve: [String]? = nil) { self.ports = ports; self.serve = serve }
    }

    /// One web port: the guest port its program listens on (its localhost), and what the Open button shows.
    public struct WebPort: Codable, Sendable, Equatable {
        public var port: Int
        public var title: String
        /// What Open opens (default `/`).
        public var path: String?
        /// `http` (the default; an Open button) or `ws` (a WebSocket endpoint: forwarded, no button).
        public var `protocol`: String?
        /// `none` (the default), `token` (the program prints a token to sign in with — `tokenHint` says where) or
        /// `login` (its own account sign-in page).
        public var auth: String?
        public var tokenHint: String?
        /// What `make recipe-check` GETs (default: `path`); any HTTP status line passes.
        public var check: String?
        enum CodingKeys: String, CodingKey {
            case port, title, path, `protocol`, auth, check
            case tokenHint = "token_hint"
        }
        public init(port: Int, title: String, path: String? = nil, protocol: String? = nil, auth: String? = nil,
                    tokenHint: String? = nil, check: String? = nil) {
            self.port = port; self.title = title; self.path = path; self.protocol = `protocol`; self.auth = auth
            self.tokenHint = tokenHint; self.check = check
        }
        public var isHTTP: Bool { (`protocol` ?? "http") == "http" }
        public var openPath: String { path ?? "/" }
    }

    enum CodingKeys: String, CodingKey {
        case lifecycle, icon, description, schema, id, title, publisher, licence, homepage, aliases, builtin, platforms, limits, install, launch, state, credentials,
             network, status, prompt, resume, verify, smoke, terms, checked, settings, auth, gateways, tags, models, categories, guide
        case catalogKind = "catalog_kind", ports
        case defaultBase = "default_base", resumeCheck = "resume_check"
    }

    public struct Platforms: Codable, Sendable, Equatable {
        public var glibc: Bool
        public var musl: Bool
    }

    public struct Limit: Codable, Sendable, Equatable {
        public var musl: Bool?
        public var base: String?
        public var reason: String
    }

    public struct Install: Codable, Sendable, Equatable {
        /// `builtin` | `npm` | `npm-platform-binary` | `manifest-binary` | 617: `pypi` (a Python package and every
        /// dependency, hash-pinned, in its own venv on Dozer's pinned Python) | `release-binary` (one program from a
        /// release download at `url`, `{version}` in it).
        public var kind: String
        /// manifest-binary (617, Antigravity CLI): the vendor's release manifest for linux-arm64 (`{"version", "url",
        /// "sha512"}`), read on the Mac at preparation; the version recorded is `<version>+<build>` from its url.
        public var manifest: String?
        /// manifest-binary: the archive's URL with `{build}` (the release's `<version>-<build>` path segment) — the url
        /// the manifest names must be exactly this, else the release is refused.
        public var url: String?
        /// The npm package (its version is the agent's version).
        public var package: String?
        /// npm-platform-binary: the package holding the linux-arm64 program, published at the SAME version.
        public var platformPackage: String?
        /// npm-platform-binary: the program inside that package (`bin/grok.br`).
        public var payload: String?
        /// `brotli` when the payload is compressed (nil: as it is).
        public var compression: String?
        /// The program the launcher runs, at `/usr/local/bin/<binary>`.
        public var binary: String
        /// The Node major an npm install needs on a base without Node.
        public var needsNode: String?
        public var npmArgs: [String]?
        public var pinned: Pin
        /// Hosts a bake reaches beyond the bake preset's registries.
        public var bakeHosts: [String]?
        /// 617 (pypi): every distribution the install puts in its venv, each `name==version --hash=sha256:<hex>` — the
        /// package itself and all its dependencies, resolved once in a scratch VM; pip installs exactly these, hash-checked.
        public var requirements: [String]? = nil
        /// 617.11: file sets beside the program (Fabric's patterns), each from a sha256-pinned archive, in the bake.
        public var extras: [Extra]? = nil

        enum CodingKeys: String, CodingKey {
            case kind, package, payload, compression, binary, pinned, manifest, url, requirements, extras
            case platformPackage = "platform_package", needsNode = "needs_node", npmArgs = "npm_args", bakeHosts = "bake_hosts"
        }

        /// 617 (release-binary): how the download is unpacked, read from the url's end — `tar.gz`, `zip`, or `none` (the
        /// download is the program).
        public var archive: String {
            let u = (url ?? "").lowercased()
            if u.hasSuffix(".tar.gz") || u.hasSuffix(".tgz") { return "tar.gz" }
            if u.hasSuffix(".zip") { return "zip" }
            return "none"
        }

        /// 617 (pypi): a distribution's name as wheel file names spell it (PEP 503 normalised, `-` → `_`).
        public static func wheelName(_ name: String) -> String {
            name.lowercased().replacingOccurrences(of: #"[-_.]+"#, with: "_", options: .regularExpression)
        }
    }

    /// 617: install kinds whose release is the recipe's pin only — nothing is looked up for them (`latest` is the pin).
    public static let pinnedOnlyKinds: Set<String> = ["pypi", "release-binary"]

    public struct Pin: Codable, Sendable, Equatable {
        public var version: String
        /// npm's sha512 integrity of the tarball a bake downloads (the platform package's, for npm-platform-binary).
        public var integrity: String?
    }

    public struct Launch: Codable, Sendable, Equatable {
        public var command: [String]
        /// What the launcher puts first unless `DOZ_<ID>_PERMISSIONS=ask` or root.
        public var noPromptsArgs: [String]
        /// 617: environment the launcher sets only when it puts `noPromptsArgs` first (same rule) — for an agent whose
        /// approval switch is a variable rather than a flag (MiMo Code's flag asks again on a terminal; its variable
        /// does not).
        public var noPromptsEnv: [String: String]? = nil
        /// First arguments that run the program as it is (no flags, no first-run settings).
        public var passthrough: [String]
        /// Non-credential environment of every run.
        public var env: [String: String]
        /// Settings the launcher writes into the agent's config — ONLY those not there yet.
        public var firstRun: [FirstRun]?
        /// 617: environment the HOST gives every session at open (never baked — a built-in's image stays byte-identical):
        /// the agent's own switch for its self-update check (pi's `PI_SKIP_VERSION_CHECK`). Never over the caller's value.
        public var sessionEnv: [String: String]?
        /// 617: `shell` — the default session is a login shell with the program on its PATH, for a command-line tool that
        /// answers and exits (Fabric, llm) rather than an interactive program; nil: the session runs `command`.
        public var session: String? = nil
        /// 618: a background service the program starts and keeps (OpenCode 2's `opencode serve --service`) — it holds
        /// the environment of the command that started it, so the launcher restarts it first when it runs with another
        /// value of `env` than this run has (a model or source chosen since). Emitted only into such a recipe's launcher.
        public var service: Service? = nil
        /// 618: the arguments that choose its model when the tool takes it ONLY on its command line (`[-m, $DOZ_MODEL]`):
        /// the launcher puts them first when `DOZ_MODEL` is set (models@1 sets it per source — `xai/${{ dozer.model }}`)
        /// and the run gives no flag of its own. Emitted only into such a recipe's launcher.
        public var modelArgs: [String]? = nil
        /// 618: subcommands whose own flags they are (`exec`, `run`): there the arguments go AFTER the subcommand.
        public var modelArgsAfter: [String]? = nil

        public struct Service: Codable, Sendable, Equatable {
            /// The service process's arguments after the program (`[serve, --service]`).
            public var args: [String]
            /// What restarts it, after the program (`[service, restart]`) — run with this run's environment.
            public var restart: [String]
            /// 618: what starts it when the restart fails — OpenCode 2 waits for the old server to go, and in the VM it stays a
            /// zombie (the init never reaps it) after it stopped: start it then (`[service, start]`).
            public var start: [String]? = nil
            /// The variables compared (`[DOZ_MODEL]`); one this run does not set is not compared.
            public var env: [String]
        }

        enum CodingKeys: String, CodingKey {
            case command, passthrough, env, session, service
            case noPromptsArgs = "no_prompts_args", firstRun = "first_run", sessionEnv = "session_env", noPromptsEnv = "no_prompts_env",
                 modelArgs = "model_args", modelArgsAfter = "model_args_after"
        }
    }

    public struct FirstRun: Codable, Sendable, Equatable {
        /// `~/…json`, `~/…toml`, `~/….yaml` or `~/…/.env`.
        public var file: String
        /// Dotted key → value (`general.enableAutoUpdate` → false; TOML: `[general] enableAutoUpdate = false`; a TOML
        /// segment in double quotes is one key: `projects."/workspace".trust_level`).
        public var set: [String: RecipeValue]
        /// 617: `json` — a JSON file whose name has no extension (Kimi Code's `workspace-trust/wd_workspace_…` record);
        /// nil: the kind of file follows from its name.
        public var format: String? = nil
        /// 618: written at EVERY run, its keys set (not only when absent), each `$DOZ_…` in a value replaced by the
        /// run's own (models@1 sets them per source) — for a tool that takes its model only from its settings file
        /// (Crush's `models.large`). A JSON file; skipped when the run has no model source chosen.
        public var eachRun: Bool? = nil

        enum CodingKeys: String, CodingKey { case file, set, format, eachRun = "each_run" }
    }

    public struct State: Codable, Sendable, Equatable {
        public var persist: [String]
        public var env: [String: String]
    }

    public struct CredentialUse: Codable, Sendable, Equatable {
        public var provider: String
        public var accounts: [String]
        /// 617: more guest variables holding the same placeholder (the tool reads its key under another name).
        public var envAliases: [String]? = nil
        enum CodingKeys: String, CodingKey { case provider, accounts, envAliases = "env_aliases" }
    }

    public struct Network: Codable, Sendable, Equatable {
        public var model: Model
        /// Folded into "Update itself" in this agent's sandbox only (a hidden `update:<id>`).
        public var update: [Host]
        /// Hosts the agent is known to call that Dozer keeps out, whatever is chosen.
        public var excluded: [String]
        /// 617 (owner: a fresh try shows no refusal): what the agent calls on its OWN vendor's sites at a normal start
        /// (release notes, its model list, its plugin list) — each with its reason, allowed in its sandbox by a hidden
        /// `vendor:<id>` added at create (new sandboxes only). GitHub-hosted vendor content by exact path only.
        public var vendor: [Host]?
        /// 617: what the agent is told when a permission is OFF — its own switch, so it does not call what is refused
        /// (Claude Code's error reports and usage data without "Send error reports").
        public var offWithout: [OffWithout]?
        /// 617 (owner: no setting → refuse quietly): hosts the agent calls that no setting of its own turns off and that
        /// Dozer keeps out (telemetry); denied before everything like `excluded`, logged, never counted as a refusal.
        public var quiet: [Host]?

        enum CodingKeys: String, CodingKey { case model, update, excluded, vendor, quiet, offWithout = "off_without" }
    }

    public struct OffWithout: Codable, Sendable, Equatable {
        public var permission: String
        public var env: [String: String]
        /// Plain words for the facts and the plan ("error reports and usage data are off").
        public var says: String
    }

    public struct Model: Codable, Sendable, Equatable {
        /// `model` (Anthropic's, shared by Claude Code and pi) or `model:<provider>`.
        public var id: String
        public var shared: Bool?
        public var title: String?
        public var summary: String?
        public var phrase: String?
        public var hosts: [Host]?
    }

    public struct Host: Codable, Sendable, Equatable {
        public var host: String
        /// Path prefixes (the proxy decrypts to judge them); nil: the whole host.
        public var paths: [String]?
        /// 617: paths allowed EXACTLY (`/`: the root only), beside the prefixes.
        public var exactPaths: [String]?
        /// 617: why the agent calls it (what a person reads in the plan's reach) — required for a host beside the model's
        /// API (its own site, a start-up check).
        public var reason: String?
        enum CodingKeys: String, CodingKey { case host, paths, exactPaths = "exact_paths", reason }

        /// The proxy's path conditions: the prefixes, then each exact path marked (`EgressRule.isExactPath`).
        public var conditions: [String]? {
            let all = (paths ?? []) + (exactPaths ?? []).map { $0 + "$" }
            return all.isEmpty ? nil : all
        }
    }

    public struct Prompt: Codable, Sendable, Equatable {
        /// `skill` (a SKILL.md in `dir`) | `context-file` (the facts as `dir/file`, plus an optional manifest).
        public var kind: String
        public var dir: String?
        public var file: String?
        public var manifest: Manifest?
        public var launcherArg: [String]?

        enum CodingKeys: String, CodingKey {
            case kind, dir, file, manifest
            case launcherArg = "launcher_arg"
        }
    }

    public struct Manifest: Codable, Sendable, Equatable {
        public var file: String
        public var json: RecipeValue
    }

    public struct Check: Codable, Sendable, Equatable {
        public var argv: [String]
        public var expect: String?
    }

    /// 617: one headless turn — `argv` run as the agent through its launcher in a fresh try (keys fake, the model a
    /// stand-in that answers DOZ_FAKE_OK); its output must contain `expect` and it must exit `exit` (default 0) within
    /// `timeout` seconds (default 240).
    public struct Smoke: Codable, Sendable, Equatable {
        public var argv: [String]
        public var expect: String
        public var exit: Int?
        public var timeout: Int?
        /// 617 (the owner's first `doz try goose` opened Goose's own setup wizard; the headless check never sees it):
        /// what the default session's FIRST screen must and must not show, beside the generic setup/sign-in/consent
        /// patterns `make recipe-check` refuses (`Scripts/recipe-check.py`, `SETUP_SCREEN`).
        public var screen: Screen?
        public init(argv: [String], expect: String, exit: Int? = nil, timeout: Int? = nil, screen: Screen? = nil) {
            self.argv = argv; self.expect = expect; self.exit = exit; self.timeout = timeout; self.screen = screen
        }
    }

    /// The first screen of an agent's default session (no keys typed): `expect` — regular expressions each of which must
    /// match it; `refuse` — ones none may match (on top of the generic list); `allow` — a line matching one of these is
    /// not held against the generic list (a ready screen's own "Welcome to …" banner); `wait` — seconds to let it
    /// settle (default 15).
    public struct Screen: Codable, Sendable, Equatable {
        public var expect: [String]?
        public var refuse: [String]?
        public var allow: [String]?
        public var wait: Int?
        /// 617: keys typed (`enter`, `esc`, `up`, `down`, `tab`, `space`), each then left to settle, before the screen is
        /// read — a choice nothing can skip that is not the person's decision (Antigravity CLI's colour scheme), to reach
        /// the screen the check is about.
        public var keys: [String]?
    }

    public struct SettingKeys: Codable, Sendable, Equatable {
        public var version: String?
        public var permissions: String?
    }

    /// One agent × one gateway. `level`: `documented` (the vendor documents it: `source`) · `verified` (Dozer proved it:
    /// `evidence`) · `experimental` (plausible, unproven — only ever an explicit opt-in, always shown as "not supported by
    /// the vendor": `evidence`) · `no` (`reason`) · `unknown` (not looked at yet). `how` is machine-applicable: values are
    /// templates over `{gateway.endpoint.<id>}`, `{placeholder}` (the gateway key's doz placeholder) and `{model}`.
    public struct GatewaySupport: Codable, Sendable, Equatable {
        public var gateway: String
        public var level: String
        /// `openai-chat` | `openai-responses` | `anthropic-messages` | `gemini` — what the agent speaks to it.
        public var shape: String?
        /// The gateway endpoint (`Gateway.endpoints[].id`) it is pointed at.
        public var endpoint: String?
        public var how: GatewayHow?
        /// A candidate for routing by Dozer's proxy itself (phase 2 idea): the agent's own host and the path mapping.
        public var proxyRoute: ProxyRoute?
        public var limits: [String]?
        public var notes: [String]?
        public var evidence: String?
        public var source: String?
        public var checked: String?
        public var reason: String?

        enum CodingKeys: String, CodingKey {
            case gateway, level, shape, endpoint, how, limits, notes, evidence, source, checked, reason
            case proxyRoute = "proxy_route"
        }

        public static let levels = ["documented", "verified", "experimental", "no", "unknown"]
        /// A level phase 2 may apply (experimental only behind an opt-in).
        public var isApplicable: Bool { ["documented", "verified", "experimental"].contains(level) }

        /// `how` with every template filled in. Throws on a placeholder this vocabulary does not have, or an endpoint
        /// the gateway does not have.
        public func resolved(placeholder: String, model: String) throws -> GatewayHow? {
            guard let how else { return nil }
            guard let g = Gateways.gateway(gateway) else { throw SandboxError.invalidSpec("no gateway \(gateway)") }
            func fill(_ s: String) throws -> String {
                var out = ""
                var rest = Substring(s)
                while let open = rest.firstIndex(of: "{") {
                    out += rest[..<open]
                    guard let close = rest[open...].firstIndex(of: "}") else { throw SandboxError.invalidSpec("\(gateway): an unclosed { in \(s)") }
                    let name = String(rest[rest.index(after: open)..<close])
                    if name == "placeholder" { out += placeholder }
                    else if name == "model" { out += model }
                    else if name.hasPrefix("gateway.endpoint."), let e = g.endpoints.first(where: { $0.id == String(name.dropFirst(17)) }) { out += e.baseUrl }
                    else { throw SandboxError.invalidSpec("\(gateway): {\(name)} is not a template of the gateway vocabulary") }
                    rest = rest[rest.index(after: close)...]
                }
                return out + rest
            }
            var r = how
            r.env = try how.env.map { try $0.mapValues(fill) }
            r.args = try how.args?.map(fill)
            r.modelArgs = try how.modelArgs?.map(fill)
            r.config = try how.config?.map { c in
                var x = c
                x.set = try c.set.mapValues { v in if case .string(let s) = v { return .string(try fill(s)) }; return v }
                return x
            }
            return r
        }
    }

    /// The machine-applicable part: session environment, config-file merges (absent keys only, as `first_run`), extra
    /// arguments, and how a model is chosen.
    public struct GatewayHow: Codable, Sendable, Equatable {
        public var env: [String: String]?
        public var config: [FirstRun]?
        public var args: [String]?
        public var modelArgs: [String]?

        enum CodingKeys: String, CodingKey {
            case env, config, args
            case modelArgs = "model_args"
        }
    }

    public struct ProxyRoute: Codable, Sendable, Equatable {
        public var fromHost: String
        /// The agent's path → the gateway's.
        public var paths: [String: String]
        /// Vendor-only paths with no gateway equivalent.
        public var unmapped: [String]?

        enum CodingKeys: String, CodingKey {
            case paths, unmapped
            case fromHost = "from_host"
        }
    }

    public struct Auth: Codable, Sendable, Equatable {
        /// Recommended first.
        public var methods: [AuthMethod]
    }

    /// One way in. `kind`: `api-key` (a key of `provider`, made at `keys_page`) · `vendor-sign-in` (the agent maker's
    /// own account — `account` says which, in words) · `none` (keyless or free) · `gateway` (through one of `gateways`;
    /// declared now, used in phase 2).
    public struct AuthMethod: Codable, Sendable, Equatable {
        public var kind: String
        public var provider: String?
        public var keysPage: String?
        /// Only when it can be cited with a date (`checked`); unset otherwise.
        public var freeTier: Bool?
        public var freeTierNote: String?
        /// The ISO date this method's facts were last checked.
        public var checked: String?
        /// vendor-sign-in: "an x.ai or X account", "a Claude subscription".
        public var account: String?
        /// The Dozer account kinds this method maps to today (`mac`, `setup-token`, `api-key`, `chatgpt`, …); nil: none yet.
        public var accounts: [String]?
        /// gateway: `openrouter`, …
        public var gateways: [String]?
        /// Plain words: where the sign-in lives, why a method is missing, what phase uses it.
        public var note: String?
        /// vendor-sign-in without Dozer accounts: the agent's own sign-in works INSIDE a sandbox (its sign-in hosts are
        /// reachable — none of them excluded). `doz try` offers it (labelled: the sign-in lives in that sandbox) only when
        /// true; nil/false: shown as not offered, with `note`.
        public var inSandbox: Bool?

        enum CodingKeys: String, CodingKey {
            case kind, provider, checked, account, accounts, gateways, note
            case keysPage = "keys_page", freeTier = "free_tier", freeTierNote = "free_tier_note", inSandbox = "in_sandbox"
        }
    }

    // MARK: derived

    public var isBuiltin: Bool { builtin == true }

    /// The release the recipe pins.
    public var pinnedRelease: AgentRelease? {
        install.pinned.integrity.map { AgentRelease(version: install.pinned.version, integrity: $0) }
    }

    /// The default session's name and the image-name suffix (`claude` for Claude Code, `gemini`).
    public var shortName: String { launch.command.first.map { ($0 as NSString).lastPathComponent } ?? id }

    /// `DOZ_GEMINI_PERMISSIONS` — what the launcher reads (ask / skip); by the short name, so Claude Code's is
    /// `DOZ_CLAUDE_PERMISSIONS` as it always was.
    public var permissionsVariable: String { "DOZ_" + shortName.uppercased().replacingOccurrences(of: "-", with: "_") + "_PERMISSIONS" }

    /// The settings key of the agent's version (`images.gemini_version`).
    public var versionSettingKey: String { settings?.version ?? "images.\(id.replacingOccurrences(of: "-", with: "_"))_version" }
    /// The settings key of its prompts (`gemini.permissions`); nil for an agent with none to skip.
    public var permissionsSettingKey: String? {
        if let p = settings?.permissions { return p }
        return isBuiltin || (launch.noPromptsArgs.isEmpty && (launch.noPromptsEnv ?? [:]).isEmpty) ? nil : "\(id).permissions"
    }

    /// The key provider the agent uses (its first credential's).
    public var provider: String? { credentials.first?.provider }

    /// The sentence a musl base gets when the agent has no musl build.
    public var muslRefusal: String { "\(title) has no musl build — choose a Debian-based base (not Alpine)" }

    /// `2026-10-12`: a real calendar date.
    static func isISODate(_ s: String) -> Bool {
        guard s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s).map { f.string(from: $0) == s } ?? false
    }

    /// The verify checks with the version filled in.
    public func verifyChecks(version: String) -> [VerifyCheck] {
        // `{version}` is the version a program prints: without a release's build part (`1.3.3+5524…` → `1.3.3`).
        verify.map { VerifyCheck($0.argv, expect: $0.expect?.replacingOccurrences(of: "{version}", with: String(version.split(separator: "+").first ?? Substring(version)))) }
    }
}

/// 617 (owner: "make Antigravity the leading Google agent; keep Gemini but mark it as superseded"; "record … is it
/// current"): where an agent stands with its maker — RECORDED in the data (a recipe's or a known entry's `lifecycle`),
/// beside what is MEASURED (the latest release and its age — the host's registry cache).
public struct AgentLifecycle: Codable, Sendable, Equatable {
    /// `current` | `superseded` (by another agent) | `retired` (its maker stopped it for some users) | `discontinued`.
    public var status: String
    /// superseded: the recipe or known id that replaces it.
    public var by: String?
    /// Plain words a person reads (required unless current).
    public var note: String?
    public var source: String?
    public var checked: String?

    public init(status: String, by: String? = nil, note: String? = nil, source: String? = nil, checked: String? = nil) {
        self.status = status; self.by = by; self.note = note; self.source = source; self.checked = checked
    }
    public static let statuses = ["current", "superseded", "retired", "discontinued"]
    public static let current = AgentLifecycle(status: "current")
    public var isCurrent: Bool { status == "current" }

    /// Well formed alone; `by` is checked against every recipe and known id by `AgentLifecycle.validate(recipes:known:)`.
    public func validate(_ what: String) throws {
        func bad(_ s: String) -> SandboxError { SandboxError.invalidSpec("\(what): lifecycle \(s)") }
        guard Self.statuses.contains(status) else { throw bad("status \(Self.statuses.joined(separator: ", "))") }
        if status != "current" { guard let n = note, !n.isEmpty else { throw bad("\(status) says why (note)") } }
        if status == "superseded" { guard let b = by, !b.isEmpty else { throw bad("superseded names what replaces it (by)") } }
        if let s = source, !s.hasPrefix("https://") { throw bad("source is an https URL") }
        if let d = checked, !AgentRecipe.isISODate(d) { throw bad("checked is an ISO date") }
    }

    /// Every `by` names a recipe or a known entry (and never itself).
    public static func validate(recipes: [AgentRecipe], known: [KnownThing]) throws {
        let ids = Set(recipes.map(\.id) + known.map(\.id))
        let all: [(String, AgentLifecycle?)] = recipes.map { ($0.id, $0.lifecycle) } + known.map { ($0.id, $0.lifecycle) }
        for (id, l) in all {
            guard let l else { continue }
            try l.validate(id)
            if let b = l.by, !ids.contains(b) || b == id { throw SandboxError.invalidSpec("\(id): lifecycle by \(b) names no other recipe or known entry") }
        }
    }
}

// MARK: - key providers

/// 617 (616.03 §4.1): one provider of API keys — which hosts a key may go to, in which header, under which guest
/// variable its placeholder lives, how a key is checked, and the proxy's refusal shape.
public struct KeyProvider: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    /// Exact hosts the key may go to (the proxy decrypts these and only these for it).
    public var hosts: [String]
    public var inject: Inject
    /// The guest variable holding the placeholder (`XAI_API_KEY`).
    public var env: String
    public var alsoEnv: [String]?
    /// The provider's binding is one that existed before 617 (`anthropic`, `openai`) — its id kept, so placeholder
    /// hashes and stored credential sources keep working.
    public var builtinBinding: String?
    /// What a key usually starts with — a hint at add time, never a refusal.
    public var keyHint: String?
    public var check: KeyCheck?
    /// `anthropic` | `openai` | `google` — the proxy's own 401/403 body on these hosts.
    public var errorShape: String
    /// 617: the key goes ONLY into a request that carried its placeholder — never added to one without (a key-less
    /// call the agent makes on purpose, Grok Build's start-up check, stays key-less).
    public var swapOnly: Bool?
    /// 617: a provider's API endpoints by shape (a gateway's are in gateways.json — `gateway: true`).
    public var endpoints: [Gateway.Endpoint]? = nil
    /// 617: a model gateway (OpenRouter, Vercel AI Gateway): its key is this provider's, its endpoints the gateway's.
    public var gateway: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, hosts, inject, env, check, endpoints, gateway
        case alsoEnv = "also_env", builtinBinding = "builtin_binding", keyHint = "key_hint", errorShape = "error_shape"
        case swapOnly = "swap_only"
    }

    public struct Inject: Codable, Sendable, Equatable {
        public var header: String
        /// `%s` or `Bearer %s`.
        public var format: String
    }

    public struct KeyCheck: Codable, Sendable, Equatable {
        public var method: String
        public var url: String
        /// Statuses that mean the key is bad (xAI and Google answer a bad key with 400).
        public var rejected: [Int]
    }

    /// The vault binding a key of this provider goes in.
    public var binding: CredentialBinding {
        switch builtinBinding {
        case "anthropic"?: return .anthropic
        case "openai"?: return .openai
        default:
            let header: CredentialHeader = inject.format == "Bearer %s" && inject.header.lowercased() == "authorization" ? .bearer : .apiKey(name: inject.header)
            return CredentialBinding(id: "key:" + id, hosts: hosts, header: header, environmentVariable: env, alsoEnvironmentVariables: alsoEnv,
                                     swapOnly: swapOnly == true ? true : nil)
        }
    }

    /// The header a check sends (name, value).
    public func header(for key: String) -> (String, String) {
        (inject.header, inject.format.replacingOccurrences(of: "%s", with: key))
    }

    /// 617: one check request from the Mac over the proxy's own leg (`HTTPSOnce`; with `override`, ONLY the test seam's
    /// CA): 200 → good, a `rejected` status → bad (xAI and Google answer a bad key with 400), anything else → unknown.
    public func checkKey(_ key: String, override: EgressProxy.UpstreamOverride? = nil) -> Result<(good: Bool, status: Int), CheckFailure> {
        guard let c = check, let u = URL(string: c.url), let host = u.host else { return .failure(CheckFailure("\(title) keys have no check")) }
        let path = u.path.isEmpty ? "/" : u.path + (u.query.map { "?" + $0 } ?? "")
        switch HTTPSOnce.request(host: host, method: c.method, path: path, headers: [header(for: key)], override: override, timeout: 20) {
        case .failure(let f): return .failure(f)
        case .success(let r):
            if r.status == 200 { return .success((true, 200)) }
            if c.rejected.contains(r.status) { return .success((false, r.status)) }
            return .failure(CheckFailure("HTTP \(r.status)"))
        }
    }
}

public enum KeyProviders {
    struct File: Codable { var schema: Int; var providers: [KeyProvider] }

    public static let all: [KeyProvider] = {
        do {
            let f = try JSONDecoder().decode(File.self, from: Data(PackageResources.providers_json))
            return f.providers
        } catch {
            fatalError("617: the built-in providers.json does not decode: \(error)")
        }
    }()

    public static func provider(_ id: String) -> KeyProvider? { all.first { $0.id == id } }

    /// The provider whose hosts include `host` (its key goes there).
    public static func owning(host: String) -> KeyProvider? {
        let h = host.lowercased()
        return all.first { $0.hosts.contains(h) }
    }

    /// The hosts of the providers that are new in 617 (their upstream leg goes to the test seam's fake).
    public static var seamHosts: Set<String> { Set(all.filter { $0.builtinBinding == nil }.flatMap(\.hosts)) }

    /// Every binding a key provider defines (the new ones; Anthropic's and OpenAI's are the existing bindings).
    public static var keyBindings: [CredentialBinding] { all.filter { $0.builtinBinding == nil }.map(\.binding) }

    public static func validate(_ providers: [KeyProvider]) throws {
        var ids = Set<String>(), hosts = Set<String>()
        for p in providers {
            guard p.id.range(of: "^[a-z][a-z0-9-]{0,23}$", options: .regularExpression) != nil, ids.insert(p.id).inserted, p.id != "custom" else {
                throw SandboxError.invalidSpec("provider id \(p.id): [a-z][a-z0-9-]*, unique, not custom")
            }
            guard !p.hosts.isEmpty else { throw SandboxError.invalidSpec("provider \(p.id) has no hosts") }
            for h in p.hosts {
                guard AgentRecipes.isExactHost(h) else { throw SandboxError.invalidSpec("provider \(p.id): \(h) is not an exact host name") }
                guard hosts.insert(h).inserted else { throw SandboxError.invalidSpec("provider \(p.id): \(h) is another provider's host") }
            }
            guard p.inject.header.range(of: "^[A-Za-z][A-Za-z0-9-]*$", options: .regularExpression) != nil,
                  ["%s", "Bearer %s"].contains(p.inject.format) else {
                throw SandboxError.invalidSpec("provider \(p.id): inject is a header name and %s or Bearer %s")
            }
            for v in [p.env] + (p.alsoEnv ?? []) where v.range(of: "^[A-Z][A-Z0-9_]*$", options: .regularExpression) == nil || !BakeEnvironment.isCredential(v) {
                throw SandboxError.invalidSpec("provider \(p.id): \(v) must be a credential-shaped variable name (…_API_KEY)")
            }
            guard ["anthropic", "openai", "google"].contains(p.errorShape) else { throw SandboxError.invalidSpec("provider \(p.id): error_shape anthropic, openai or google") }
            if let b = p.builtinBinding, !["anthropic", "openai"].contains(b) { throw SandboxError.invalidSpec("provider \(p.id): builtin_binding anthropic or openai") }
            if let c = p.check {
                guard ["GET", "POST"].contains(c.method), let u = URL(string: c.url), u.scheme == "https", let h = u.host, p.hosts.contains(h), !c.rejected.isEmpty else {
                    throw SandboxError.invalidSpec("provider \(p.id): check is GET/POST https on one of its hosts, with rejected statuses")
                }
            }
            // 617: a model source — a provider's endpoints on its own hosts; a gateway's are gateways.json's, on the same hosts.
            if p.gateway == true {
                guard p.endpoints == nil, p.builtinBinding == nil, let g = Gateways.gateway(p.id), Set(g.hosts) == Set(p.hosts), g.keyEnv == p.env else {
                    throw SandboxError.invalidSpec("provider \(p.id): a gateway names its gateway in gateways.json (same id, hosts and key variable) and no endpoints of its own")
                }
            }
            for e in p.endpoints ?? [] {
                guard !e.shapes.isEmpty, e.shapes.allSatisfy(Gateway.shapes.contains), let u = URL(string: e.baseUrl), u.scheme == "https",
                      let h = u.host, p.hosts.contains(h), e.defaultModel.map(ModelSelection.isModelID) ?? true else {
                    throw SandboxError.invalidSpec("provider \(p.id): endpoint \(e.id): known shapes, an https base URL on its hosts, a model id")
                }
            }
        }
    }
}

// MARK: - capability tags

/// 617 (owner): one searchable capability (`Recipes/tags.json`, a CLOSED vocabulary).
public struct CapabilityTag: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var meaning: String
    /// true: computed from recipe data (`AgentRecipe.capabilityTags`); false: declared in each recipe's `tags`.
    public var derived: Bool
}

/// A tag on one recipe: supported or not, at a level (the gateway levels) with its evidence — a `no` is a fact too.
public struct RecipeTag: Codable, Sendable, Equatable {
    public var tag: String
    public var level: String
    public var evidence: String?
    public var source: String?
    public var notes: [String]?
    public var checked: String?
}

public enum CapabilityTags {
    struct File: Codable { var schema: Int; var tags: [CapabilityTag] }

    public static let all: [CapabilityTag] = {
        do { return try JSONDecoder().decode(File.self, from: Data(PackageResources.tags_json)).tags } catch {
            fatalError("617: the built-in tags.json does not decode: \(error)")
        }
    }()

    public static func tag(_ id: String) -> CapabilityTag? { all.first { $0.id == id } }

    /// Licences counted as open source.
    static let openSourceLicences: Set<String> = ["MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "MPL-2.0", "GPL-3.0", "AGPL-3.0"]

    public static func validate(_ tags: [CapabilityTag]) throws {
        var ids = Set<String>()
        for t in tags where t.id.range(of: "^[a-z][a-z0-9-]*(:[a-z][a-z0-9-]*)?$", options: .regularExpression) == nil || !ids.insert(t.id).inserted || t.title.isEmpty || t.meaning.isEmpty {
            throw SandboxError.invalidSpec("tag \(t.id): an id, unique, with a title and a meaning")
        }
        // gateway:<id> for exactly the catalogue's gateways.
        let gw = Set(tags.filter { $0.id.hasPrefix("gateway:") }.map { String($0.id.dropFirst(8)) })
        guard gw == Set(Gateways.all.map(\.id)) else { throw SandboxError.invalidSpec("tags: one gateway:<id> per catalogue gateway") }
    }
}

extension AgentRecipe {
    /// Every tag of the vocabulary for this recipe, in the vocabulary's order — derived from its data, or declared.
    public var capabilityTags: [RecipeTag] {
        let rank = ["documented": 0, "verified": 1, "experimental": 2, "no": 3, "unknown": 4]
        func derived(_ id: String) -> RecipeTag? {
            func fact(_ yes: Bool, _ what: String, unknown: Bool = false, level: String = "documented") -> RecipeTag {
                RecipeTag(tag: id, level: unknown ? "unknown" : yes ? level : "no", evidence: "the recipe's \(what)", checked: checked)
            }
            if id.hasPrefix("gateway:") {
                guard let s = gatewaySupport.first(where: { "gateway:" + $0.gateway == id }) else { return nil }
                return RecipeTag(tag: id, level: s.level, evidence: s.evidence ?? s.reason, source: s.source, notes: s.limits, checked: s.checked)
            }
            switch id {
            case "multi-vendor-models":
                let gateways = gatewaySupport
                let best = gateways.min { rank[$0.level, default: 9] < rank[$1.level, default: 9] }
                let level = gateways.contains(where: \.isApplicable) ? best!.level : gateways.allSatisfy { $0.level == "no" } ? "no" : "unknown"
                let via = gateways.filter { $0.level == level }.map(\.gateway)
                return RecipeTag(tag: id, level: level, evidence: "through \(via.joined(separator: ", ")) (its gateways)", source: best?.source, checked: best?.checked)
            case "api-key": return fact(auth.methods.contains { $0.kind == "api-key" }, "auth methods")
            case "vendor-sign-in": return fact(auth.methods.contains { $0.kind == "vendor-sign-in" }, "auth methods")
            case "no-account": return fact(auth.methods.contains { $0.kind == "none" }, "auth methods")
            case "free-tier":
                let f = auth.methods.compactMap(\.freeTier)
                return fact(f.contains(true), "auth methods' free tier", unknown: f.isEmpty)
            case "status": return fact(status == "osc7501", "status", level: "verified")
            case "resume": return fact(resume != nil, "resume", unknown: resume == nil, level: "verified")
            case "musl": return fact(platforms.musl, "platforms", level: "verified")
            case "open-source": return fact(CapabilityTags.openSourceLicences.contains(licence), "licence (\(licence))")
            default: return nil
            }
        }
        return CapabilityTags.all.compactMap { t in t.derived ? derived(t.id) : tags.first { $0.tag == t.id } }
    }

    /// The recipe's tags at `levels` (default: the supported ones) — what `doz search --tag` filters on.
    public func hasTag(_ id: String, levels: Set<String> = ["documented", "verified"]) -> Bool {
        capabilityTags.contains { $0.tag == id && levels.contains($0.level) }
    }
}

// MARK: - model gateways

/// 617 (owner): a model gateway — one key, many models (`Recipes/gateways.json`). Data in phase 1; a gateway key
/// binding and the proxy's routing are phase 2.
public struct Gateway: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var homepage: String
    public var hosts: [String]
    public var endpoints: [Endpoint]
    /// The variable its own docs use for the key (`OPENROUTER_API_KEY`).
    public var keyEnv: String
    public var keysPage: String
    /// How it names a model (`{creator}/{name}`).
    public var modelId: String
    public var source: String
    public var checked: String

    enum CodingKeys: String, CodingKey {
        case id, title, homepage, hosts, endpoints, source, checked
        case keyEnv = "key_env", keysPage = "keys_page", modelId = "model_id"
    }

    public struct Endpoint: Codable, Sendable, Equatable {
        public var id: String
        public var shapes: [String]
        public var baseUrl: String
        /// 617: the model a recipe is given on this endpoint when nobody chose one (a gateway's: `creator/name`). Only an
        /// endpoint with one is offered to recipes (`ModelSources`) — the coding-agent variants are not generic.
        public var defaultModel: String? = nil
        enum CodingKeys: String, CodingKey {
            case id, shapes
            case baseUrl = "base_url", defaultModel = "default_model"
        }
    }

    public static let shapes = ["openai-chat", "openai-responses", "anthropic-messages", "gemini"]
}

public enum Gateways {
    struct File: Codable { var schema: Int; var gateways: [Gateway] }

    public static let all: [Gateway] = {
        do { return try JSONDecoder().decode(File.self, from: Data(PackageResources.gateways_json)).gateways } catch {
            fatalError("617: the built-in gateways.json does not decode: \(error)")
        }
    }()

    public static func gateway(_ id: String) -> Gateway? { all.first { $0.id == id } }

    public static func validate(_ gateways: [Gateway]) throws {
        var ids = Set<String>()
        for g in gateways {
            func bad(_ s: String) -> SandboxError { SandboxError.invalidSpec("gateway \(g.id): \(s)") }
            guard g.id.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil, ids.insert(g.id).inserted else { throw bad("an id, unique") }
            guard !g.hosts.isEmpty, g.hosts.allSatisfy(AgentRecipes.isExactHost) else { throw bad("exact hosts") }
            guard !g.endpoints.isEmpty else { throw bad("no endpoints") }
            var eids = Set<String>()
            for e in g.endpoints {
                guard eids.insert(e.id).inserted, !e.shapes.isEmpty, e.shapes.allSatisfy(Gateway.shapes.contains),
                      let u = URL(string: e.baseUrl), u.scheme == "https", let h = u.host, g.hosts.contains(h) else {
                    throw bad("endpoint \(e.id): a unique id, known shapes, an https base URL on its hosts")
                }
            }
            guard g.keysPage.hasPrefix("https://"), g.source.hasPrefix("https://"), g.homepage.hasPrefix("https://") else { throw bad("https URLs") }
            guard AgentRecipe.isISODate(g.checked) else { throw bad("checked is an ISO date") }
            guard g.keyEnv.range(of: "^[A-Z][A-Z0-9_]*$", options: .regularExpression) != nil else { throw bad("key_env") }
        }
    }
}

// MARK: - the recipes

public enum AgentRecipes {
    /// The compiled-in recipes, in this order: the three that existed, then the new ones (AgentKind.allCases' order).
    static let compiled: [AgentRecipe] = {
        let files: [(String, [UInt8])] = [("claude-code.json", PackageResources.claude_code_json), ("pi.json", PackageResources.pi_json),
                                          ("codex.json", PackageResources.codex_json), ("antigravity.json", PackageResources.antigravity_json), ("gemini.json", PackageResources.gemini_json),
                                          ("grok.json", PackageResources.grok_json), ("fabric.json", PackageResources.fabric_json), ("openclaw.json", PackageResources.openclaw_json), ("nanobot.json", PackageResources.nanobot_json), ("gptme.json", PackageResources.gptme_json), ("llm.json", PackageResources.llm_json), ("shell-gpt.json", PackageResources.shell_gpt_json), ("zeroclaw.json", PackageResources.zeroclaw_json), ("aichat.json", PackageResources.aichat_json), ("tgpt.json", PackageResources.tgpt_json),
                                          ("opencode.json", PackageResources.opencode_json), ("smolagents.json", PackageResources.smolagents_json), ("adk.json", PackageResources.adk_json), ("promptfoo.json", PackageResources.promptfoo_json), ("clai.json", PackageResources.clai_json),
                                          ("copilot.json", PackageResources.copilot_json),
                                          ("qwen-code.json", PackageResources.qwen_code_json),
                                          ("goose.json", PackageResources.goose_json),
                                          ("kilo.json", PackageResources.kilo_json),
                                          ("mistral-vibe.json", PackageResources.mistral_vibe_json),
                                          ("droid.json", PackageResources.droid_json),
                                          ("dirac.json", PackageResources.dirac_json),
                                          ("kimi-code.json", PackageResources.kimi_code_json),
                                          ("cline.json", PackageResources.cline_json),
                                          ("openhands.json", PackageResources.openhands_json),
                                          ("letta-code.json", PackageResources.letta_code_json),
                                          ("docker-agent.json", PackageResources.docker_agent_json),
                                          ("nanocoder.json", PackageResources.nanocoder_json),
                                          ("mini-swe-agent.json", PackageResources.mini_swe_agent_json),
                                          ("open-interpreter.json", PackageResources.open_interpreter_json),
                                          ("crush.json", PackageResources.crush_json),
                                          ("mimo-code.json", PackageResources.mimo_code_json),
                                          ("codewhale.json", PackageResources.codewhale_json),
                                          ("maki.json", PackageResources.maki_json),
                                          ("omp.json", PackageResources.omp_json),
                                          ("tau.json", PackageResources.tau_json),
                                          ("stitch.json", PackageResources.stitch_json),
                                          ("opencode2.json", PackageResources.opencode2_json)]
        do {
            // 617: each is a schema-2 document (Recipes/compiled/PRODUCT.json — its YAML as JSON), mapped to the model.
            return try files.map { name, bytes in
                do { return try RecipeDocument.decode(Data(bytes)).recipe() } catch { throw SandboxError.invalidSpec("\(name): \(error)") }
            }
        } catch {
            fatalError("617: a built-in agent recipe does not decode: \(error)")
        }
    }()

    /// The names of the compiled-in files (a test ties them to `Recipes/` and Package.swift).
    public static let compiledFiles = ["claude-code.json", "pi.json", "codex.json", "antigravity.json", "gemini.json", "grok.json", "fabric.json", "openclaw.json", "nanobot.json", "gptme.json", "llm.json", "shell-gpt.json", "zeroclaw.json", "aichat.json", "tgpt.json", "opencode.json", "smolagents.json", "adk.json", "promptfoo.json", "clai.json", "copilot.json", "qwen-code.json", "goose.json", "kilo.json", "mistral-vibe.json", "droid.json", "dirac.json", "kimi-code.json", "cline.json", "openhands.json", "letta-code.json", "docker-agent.json", "nanocoder.json", "mini-swe-agent.json", "open-interpreter.json", "crush.json", "mimo-code.json", "codewhale.json", "maki.json", "omp.json", "tau.json", "stitch.json", "opencode2.json"]

    nonisolated(unsafe) private static var registered: [AgentRecipe] = []
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _generation = 0

    /// Every recipe this build knows (and, in tests, the ones registered).
    public static var all: [AgentRecipe] {
        lock.lock(); defer { lock.unlock() }
        return compiled + registered
    }

    /// Bumped by every registration — what caches derived from the recipes check.
    public static var generation: Int {
        lock.lock(); defer { lock.unlock() }
        return _generation
    }

    public static func recipe(_ id: String) -> AgentRecipe? { all.first { $0.id == id } }

    /// By id or alias.
    public static func matching(_ s: String) -> AgentRecipe? {
        let k = s.lowercased()
        return all.first { $0.id == k || ($0.aliases ?? []).contains(k) }
    }

    /// TEST SEAM (616.03 §5, acceptance 9): a recipe registered at run time, as if compiled in. Validated like one.
    /// No environment variable ever reaches this — a shipped build has only its compiled recipes.
    public static func registerForTests(_ r: AgentRecipe) throws {
        try validate(all + [r])
        lock.lock()
        registered.removeAll { $0.id == r.id }
        registered.append(r)
        _generation += 1
        lock.unlock()
    }

    public static func unregisterForTests(_ id: String) {
        lock.lock()
        registered.removeAll { $0.id == id }
        _generation += 1
        lock.unlock()
    }

    /// A recipe from its JSON: decoded, and refused when it carries a key this build does not know (a typo
    /// would otherwise be silently ignored).
    public static func decode(_ data: Data) throws -> AgentRecipe {
        let r = try JSONDecoder().decode(AgentRecipe.self, from: data)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let back = try JSONSerialization.jsonObject(with: try enc.encode(r))
        let original = try JSONSerialization.jsonObject(with: data)
        if let unknown = unknownKey(original, back, path: "") { throw SandboxError.invalidSpec("unknown key \(unknown)") }
        try r.validate()
        return r
    }

    /// The first key of `a` that `b` (the decoded value encoded again) does not have — a null in `a` may be absent.
    static func unknownKey(_ a: Any, _ b: Any, path: String) -> String? {
        if let x = a as? [String: Any] {
            let y = b as? [String: Any] ?? [:]
            for (k, v) in x {
                guard let w = y[k] else {
                    if v is NSNull { continue }
                    return path.isEmpty ? k : path + "." + k
                }
                if let u = unknownKey(v, w, path: path.isEmpty ? k : path + "." + k) { return u }
            }
        } else if let x = a as? [Any], let y = b as? [Any], x.count == y.count {
            for (i, v) in x.enumerated() { if let u = unknownKey(v, y[i], path: "\(path)[\(i)]") { return u } }
        }
        return nil
    }

    static func isExactHost(_ h: String) -> Bool {
        h.range(of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#, options: .regularExpression) != nil
    }

    /// The rules between recipes: unique ids and aliases, model permissions, providers' hosts.
    public static func validate(_ recipes: [AgentRecipe]) throws {
        var names = Set<String>(), models = Set<String>()
        for r in recipes {
            try r.validate()
            for n in [r.id] + (r.aliases ?? []) where !names.insert(n).inserted {
                throw SandboxError.invalidSpec("\(r.id): \(n) is another recipe's id or alias")
            }
            if r.network.model.shared != true, !models.insert(r.network.model.id).inserted {
                throw SandboxError.invalidSpec("\(r.id): its model permission \(r.network.model.id) is another recipe's")
            }
            if let i = r.icon, AgentIcons.entry(i)?.kind != "product" {
                throw SandboxError.invalidSpec("\(r.id): icon \(i) is not a product in Recipes/icons/icons.json")
            }
        }
        try validateFamilies(recipes)
    }

    /// 618: a family's majors are separate recipes — one recommended, majors once each, the family's name the id of one
    /// of them (the one that predates the family: its sandboxes, image, settings and statistics keep that id) and no other
    /// recipe's id or alias, each member's pin of its own major, the same kind of tool.
    static func validateFamilies(_ recipes: [AgentRecipe]) throws {
        let byFamily = Dictionary(grouping: recipes.filter { $0.family != nil }, by: { $0.family!.family })
        for (name, members) in byFamily {
            func bad(_ s: String) -> SandboxError { SandboxError.invalidSpec("family \(name): \(s)") }
            guard members.filter({ $0.family!.isRecommended }).count == 1 else { throw bad("exactly one recommended major") }
            guard Set(members.map { $0.family!.major }).count == members.count else { throw bad("each major once") }
            guard members.contains(where: { $0.id == name }) else { throw bad("its name is the id of one of its majors") }
            for r in recipes where r.family?.family != name && (r.id == name || (r.aliases ?? []).contains(name)) {
                throw bad("\(r.id) is outside the family but answers to its name")
            }
            for r in members {
                guard AgentRef.major(of: r.install.pinned.version) == r.family!.major else {
                    throw bad("\(r.id) pins \(r.install.pinned.version), not a release of major \(r.family!.major)")
                }
                guard r.catalogKind == members[0].catalogKind else { throw bad("its majors are one kind of tool") }
            }
        }
    }
}

extension AgentRecipe {
    /// Whether the recipe sets `name` itself (its launch, state or session environment).
    func everyEnvName(_ name: String) -> Bool {
        launch.env[name] != nil || state.env[name] != nil || launch.sessionEnv?[name] != nil
    }

    /// 617: the vault binding a recipe agent's key goes in — its provider's, plus the recipe's own env aliases.
    public func keyBinding(_ p: KeyProvider) -> CredentialBinding {
        var b = p.binding
        // 617: and the chosen models@1 entry's key_env (the tool's own name for the key, for this source).
        let aliases = (credentials.first { $0.provider == p.id }?.envAliases ?? []) + (selection(source: p.id)?.keyEnv ?? [])
        for a in aliases where a != b.environmentVariable && !(b.alsoEnvironmentVariables ?? []).contains(a) {
            b.alsoEnvironmentVariables = (b.alsoEnvironmentVariables ?? []) + [a]
        }
        return b
    }

    /// One recipe's own rules (see the file's header).
    public func validate() throws {
        func bad(_ s: String) -> SandboxError { SandboxError.invalidSpec("recipe \(id): \(s)") }
        guard schema == 1 else { throw bad("schema \(schema) — this build reads 1") }
        let idRule = "^[a-z][a-z0-9-]{0,23}$"
        for n in [id] + (aliases ?? []) {
            guard n.range(of: idRule, options: .regularExpression) != nil else { throw bad("\(n): an id is [a-z][a-z0-9-]*, at most 24") }
            guard BaseCatalogue.base(n) == nil, !["lab", "none", "custom", "shell"].contains(n), !ImageChoice.isDockerfileBase(n) else {
                throw bad("\(n) is a base or a reserved name")
            }
        }
        guard !title.isEmpty, !publisher.isEmpty, !licence.isEmpty, homepage.hasPrefix("https://") else { throw bad("title, publisher, licence and an https homepage") }
        guard BaseCatalogue.base(defaultBase) != nil else { throw bad("default_base \(defaultBase) is not a catalogue base") }
        guard platforms.glibc || platforms.musl else { throw bad("it runs nowhere (platforms)") }
        if !platforms.musl, BaseCatalogue.base(defaultBase)?.musl == true { throw bad("its default base is musl, which it does not support") }
        guard ["osc7501", "none"].contains(status) else { throw bad("status osc7501 or none") }
        // 617 (RP-1): web ports
        if let w = ports {
            guard !w.ports.isEmpty, w.ports.count <= PortForwarding.maximumPerSandbox else { throw bad("ports@1: 1–\(PortForwarding.maximumPerSandbox) ports") }
            var seen = Set<Int>()
            for p in w.ports {
                guard (1...65_535).contains(p.port), seen.insert(p.port).inserted else { throw bad("ports@1: port \(p.port) (1–65535, once each)") }
                guard !p.title.isEmpty, p.title.count <= 40 else { throw bad("ports@1 \(p.port): a title of 1–40 characters") }
                guard ["http", "ws"].contains(p.protocol ?? "http") else { throw bad("ports@1 \(p.port): protocol http or ws") }
                guard ["none", "token", "login"].contains(p.auth ?? "none") else { throw bad("ports@1 \(p.port): auth none, token or login") }
                for path in [p.path, p.check].compactMap({ $0 }) where !PortForwarding.isPath(path) {
                    throw bad("ports@1 \(p.port): \(path) — a path starts with / and has no spaces")
                }
                if p.auth == "token", (p.tokenHint ?? "").isEmpty { throw bad("ports@1 \(p.port): auth token says where the token is (token_hint)") }
            }
            if let s = w.serve, s.isEmpty || s.contains(where: \.isEmpty) { throw bad("ports@1 serve: a command") }
        }
        // install
        let release = AgentRelease(version: install.pinned.version, integrity: install.pinned.integrity ?? "sha512-A")
        guard release.isWellFormed else { throw bad("pinned \(install.pinned.version) / its integrity are not well-formed") }
        let packageRule = #"^(@[a-z0-9-]+/)?[a-z0-9._-]+$"#
        for p in [install.package, install.platformPackage].compactMap({ $0 }) where p.range(of: packageRule, options: .regularExpression) == nil {
            throw bad("package \(p) is not an npm package name")
        }
        guard install.binary.range(of: "^[a-z][a-z0-9_-]{0,31}$", options: .regularExpression) != nil else { throw bad("binary \(install.binary)") }
        switch install.kind {
        case "builtin":
            guard isBuiltin else { throw bad("install kind builtin is only for the built-in agents") }
        case "npm":
            guard !isBuiltin, install.package != nil, install.pinned.integrity != nil else { throw bad("an npm install names its package and pins an integrity") }
        case "npm-platform-binary":
            guard !isBuiltin, install.package != nil, install.platformPackage != nil, install.pinned.integrity != nil,
                  let p = install.payload, p.range(of: "^[A-Za-z0-9._/-]+$", options: .regularExpression) != nil, !p.contains("..") else {
                throw bad("an npm-platform-binary install names its package, platform package, payload and integrity")
            }
            if let c = install.compression, c != "brotli" { throw bad("compression: brotli (or none)") }
        case "manifest-binary":
            guard !isBuiltin, install.package == nil, install.pinned.integrity != nil,
                  let m = install.manifest, m.hasPrefix("https://"), !m.contains("'"),
                  let u = install.url, u.hasPrefix("https://"), u.contains("{build}"), !u.contains("'"),
                  let p = install.payload, p.range(of: "^[A-Za-z0-9._/-]+$", options: .regularExpression) != nil, !p.contains("..") else {
                throw bad("a manifest-binary install names its manifest, its archive url (with {build}), payload and integrity")
            }
            guard !platforms.musl else { throw bad("a manifest-binary install pins the glibc build only (platforms.musl false)") }
            guard install.pinned.version.contains("+") else { throw bad("a manifest-binary pin is <version>+<build>") }
        case "pypi":
            // 617: the package and every dependency, each pinned with its sha256 (pip --require-hashes), on Dozer's
            // pinned glibc Python; the package's own distribution also checked against the sha512 integrity.
            guard !isBuiltin, let p = install.package, install.pinned.integrity != nil, install.platformPackage == nil, install.payload == nil,
                  install.manifest == nil, install.url == nil, install.compression == nil, install.needsNode == nil, install.npmArgs == nil,
                  let reqs = install.requirements, !reqs.isEmpty else {
                throw bad("a pypi install names its package, its integrity and its requirements (and nothing of npm's)")
            }
            guard p.range(of: #"^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil else { throw bad("package \(p) is not a PyPI name") }
            let line = #"^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?==[A-Za-z0-9.+!_-]+ --hash=sha256:[0-9a-f]{64}$"#
            var names = Set<String>()
            for r in reqs {
                guard r.range(of: line, options: .regularExpression) != nil else { throw bad("requirement \(r): name==version --hash=sha256:<64 hex>") }
                guard names.insert(Install.wheelName(String(r.split(separator: "=")[0]))).inserted else { throw bad("requirement \(r) names a distribution twice") }
            }
            guard reqs.contains(where: { Install.wheelName(String($0.split(separator: "=")[0])) == Install.wheelName(p) && $0.contains("==" + install.pinned.version + " ") }) else {
                throw bad("the requirements pin \(p) at \(install.pinned.version) (the recipe's version)")
            }
            guard !platforms.musl else { throw bad("a pypi install runs on Dozer's glibc Python (platforms.musl false)") }
        case "release-binary":
            guard !isBuiltin, install.package == nil, install.platformPackage == nil, install.manifest == nil, install.requirements == nil,
                  install.pinned.integrity != nil, install.compression == nil,
                  let u = install.url, u.hasPrefix("https://"), u.contains("{version}"), !u.contains("'"), !u.contains(" ") else {
                throw bad("a release-binary install names its url (https, with {version}) and its integrity")
            }
            if install.archive != "none" {
                guard let p = install.payload, p.range(of: "^[A-Za-z0-9._/-]+$", options: .regularExpression) != nil, !p.contains("..") else {
                    throw bad("a release-binary archive names the program inside it (payload)")
                }
            } else if install.payload != nil {
                throw bad("a release-binary download that is the program itself has no payload")
            }
        default:
            throw bad("install kind builtin, npm, npm-platform-binary, manifest-binary, pypi or release-binary")
        }
        if install.requirements != nil, install.kind != "pypi" { throw bad("requirements are a pypi install's") }
        for a in install.npmArgs ?? [] where a.range(of: "^--[a-z][a-z-]*$", options: .regularExpression) == nil { throw bad("npm_args: \(a)") }
        if let n = install.needsNode, Int(n) == nil { throw bad("needs_node is a Node major version") }
        if let n = install.needsNode.flatMap(Int.init), n > NodeRuntime.major {
            // 617: Dozer's Node 24 (glibc only: Node publishes no musl arm64 build).
            guard n <= 24, install.kind == "npm", !platforms.musl else { throw bad("needs_node \(n): an npm install on glibc, Node 24 at most") }
        }
        for h in install.bakeHosts ?? [] where !AgentRecipes.isExactHost(h) { throw bad("bake host \(h) is not an exact host name") }
        // launch
        guard let first = launch.command.first, !first.isEmpty else { throw bad("launch.command is empty") }
        if !isBuiltin, first != install.binary { throw bad("launch.command runs \(first), not its binary \(install.binary)") }
        if let s = launch.session {
            guard s == "shell", !isBuiltin else { throw bad("launch.session is shell (a recipe agent's), or absent") }
            guard resume == nil else { throw bad("a shell session has nothing to resume") }
        }
        let scriptSafe = { (s: String) in !s.contains("'") && !s.contains("\n") && !s.contains("\\") }
        for a in launch.command + launch.noPromptsArgs + launch.passthrough + (resume ?? []) where !scriptSafe(a) || a.isEmpty {
            throw bad("an argument holds a quote, a backslash or a newline: \(a)")
        }
        if let m = launch.modelArgs {
            // 618: plain words written into the launcher; `$DOZ_…` variables in them are the selection's (every models@1
            // entry sets each one named), exactly one word names the model ($DOZ_MODEL), none names a credential.
            let vars = { (w: String) -> [String] in
                let ns = w as NSString
                return (try! NSRegularExpression(pattern: "\\$(DOZ_[A-Z0-9_]+)")).matches(in: w, range: NSRange(location: 0, length: ns.length))
                    .map { ns.substring(with: $0.range(at: 1)) }
            }
            let word = { (w: String) in
                w.replacingOccurrences(of: "\\$DOZ_[A-Z0-9_]+", with: "x", options: .regularExpression)
                    .range(of: "^[A-Za-z0-9-][A-Za-z0-9._=:/@-]*$", options: .regularExpression) != nil
            }
            let named = Set(m.flatMap(vars))
            // (A built-in agent's are put on its default session by the host at session open — never baked.)
            guard let models, let flag = m.first, flag.hasPrefix("-"), !flag.contains("$"), m.allSatisfy(word),
                  m.filter({ vars($0).contains("DOZ_MODEL") }).count == 1, !named.contains(where: BakeEnvironment.isCredential) else {
                throw bad("launch.model_args: a recipe agent with models@1; a flag first, plain words, one naming $DOZ_MODEL, no credential")
            }
            for a in launch.modelArgsAfter ?? [] where a.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) == nil {
                throw bad("launch.model_args_after: subcommand words")
            }
            let envs = (models.shapes ?? []).map(\.env) + (models.native ?? []).map(\.env)
            guard envs.allSatisfy({ e in named.allSatisfy { e[$0] != nil } }) else {
                throw bad("launch.model_args: every models@1 entry sets each variable it names (\(named.sorted().joined(separator: ", ")))")
            }
        }
        if let s = launch.service {
            // 618: plain words only — they are written into the launcher (a shell script).
            let word = { (w: String) in w.range(of: "^[A-Za-z0-9-][A-Za-z0-9._=-]*$", options: .regularExpression) != nil }
            guard !isBuiltin, !s.args.isEmpty, !s.restart.isEmpty, s.start?.isEmpty != true, (s.args + s.restart + (s.start ?? [])).allSatisfy(word) else {
                throw bad("launch.service: a recipe agent's, its args and restart plain words (letters, digits, . _ = -)")
            }
            guard !s.env.isEmpty, Set(s.env).count == s.env.count, s.env.allSatisfy({
                $0.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil && !BakeEnvironment.isCredential($0)
            }) else { throw bad("launch.service env: variable names, once each, none a credential (placeholders differ per run)") }
        }
        var everyEnv = launch.env.merging(state.env, uniquingKeysWith: { a, _ in a }).merging(launch.noPromptsEnv ?? [:], uniquingKeysWith: { a, _ in a })
        for (k, v) in (launch.sessionEnv ?? [:]).merging((network.offWithout ?? []).flatMap(\.env), uniquingKeysWith: { a, _ in a }) { everyEnv[k] = everyEnv[k] ?? v }
        for (k, v) in everyEnv {
            guard k.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil, !BakeEnvironment.isCredential(k), scriptSafe(v) else {
                throw bad("env \(k): a variable name that names no credential, and a value with no quote")
            }
        }
        for f in launch.firstRun ?? [] where f.eachRun == true {
            // 618: a JSON file, its `$DOZ_…` values the selection's (every models@1 entry sets each), never a credential's.
            let named = Set(f.set.values.flatMap(\.strings).flatMap { s -> [String] in
                let ns = s as NSString
                return (try! NSRegularExpression(pattern: "\\$(DOZ_[A-Z0-9_]+)")).matches(in: s, range: NSRange(location: 0, length: ns.length))
                    .map { ns.substring(with: $0.range(at: 1)) }
            })
            let envs = (models?.shapes ?? []).map(\.env) + (models?.native ?? []).map(\.env)
            guard !isBuiltin, models != nil, f.file.hasSuffix(".json") || f.format == "json", named.contains("DOZ_MODEL"),
                  !named.contains(where: BakeEnvironment.isCredential), envs.allSatisfy({ e in named.allSatisfy { e[$0] != nil } }) else {
                throw bad("first_run each_run \(f.file): a JSON file of a recipe agent with models@1, naming $DOZ_MODEL, each $DOZ_… set by every models@1 entry, none a credential")
            }
        }
        for f in launch.firstRun ?? [] {
            let yaml = f.file.hasSuffix(".yaml") || f.file.hasSuffix(".yml")
            if let fmt = f.format, fmt != "json" { throw bad("first_run format \(fmt): only json") }
            guard f.file.hasPrefix("~/"), f.format == "json" || f.file.hasSuffix(".json") || f.file.hasSuffix(".toml") || f.file.hasSuffix("/.env") || yaml,
                  !f.file.contains(".."), !f.file.contains("\""), scriptSafe(f.file) else {
                throw bad("first_run file \(f.file): ~/….json, ~/….toml, ~/….yaml or ~/…/.env (or format: json)")
            }
            for (k, v) in f.set {
                // 617: a dotenv file (Fabric's ~/.config/fabric/.env): KEY=value lines, never a credential's name.
                if f.file.hasSuffix("/.env") {
                    guard k.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil, !BakeEnvironment.isCredential(k) else {
                        throw bad("first_run .env key \(k): a variable name that names no credential")
                    }
                    guard case .string(let s) = v, scriptSafe(s), !s.contains("\""), !s.contains("$") else { throw bad("first_run .env value of \(k) is a plain string") }
                    continue
                }
                // A TOML key may hold a segment in double quotes (a path: `projects."/workspace".trust_level`).
                let segment = f.file.hasSuffix(".toml") ? "([A-Za-z0-9_-]+|\"[A-Za-z0-9_./-]+\")" : "[A-Za-z0-9_-]+"
                guard k.range(of: "^\(segment)(\\.\(segment))*$", options: .regularExpression) != nil else { throw bad("first_run key \(k)") }
                if yaml {
                    // 617 (Goose's ~/.config/goose/config.yaml): top-level keys only, each a string, a number or a bool.
                    guard !k.contains(".") else { throw bad("first_run YAML key \(k) is a top-level key (no dots)") }
                    if case .object = v { throw bad("first_run YAML value of \(k) is a string, a number or a bool") }
                    if case .array = v { throw bad("first_run YAML value of \(k) is a string, a number or a bool") }
                }
                if f.file.hasSuffix(".toml") {
                    // 617: a key with no table is a top-level key (ZeroClaw's schema_version), written above the first table.
                    if case .object = v { throw bad("first_run TOML value of \(k) is a string, a number or a bool") }
                    if case .array = v { throw bad("first_run TOML value of \(k) is a string, a number or a bool") }
                }
                for s in v.strings where !scriptSafe(s) { throw bad("first_run value of \(k) holds a quote") }
            }
        }
        // state
        for d in state.persist where !(d.hasPrefix("~/") || d.hasPrefix("/")) || !scriptSafe(d) { throw bad("persist dir \(d)") }
        // credentials
        guard !credentials.isEmpty else { throw bad("no credentials") }
        for c in credentials {
            guard KeyProviders.provider(c.provider) != nil || c.provider == "custom" else { throw bad("provider \(c.provider) is not in providers.json") }
            // 617: a recipe agent takes its source's API key — a `key` account, an Anthropic or an OpenAI API key; never a
            // subscription.
            if !isBuiltin, c.accounts != [ModelSources.accountKind(c.provider)] { throw bad("a recipe agent takes \(ModelSources.accountKind(c.provider)) accounts of \(c.provider) only") }
            for a in c.envAliases ?? [] {
                // 617: the same placeholder under another name — credential-shaped, never the provider's own name, never
                // a variable the recipe sets itself.
                guard !isBuiltin, a.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil, BakeEnvironment.isCredential(a) || a.hasSuffix("_KEY"),
                      a != KeyProviders.provider(c.provider)?.env, everyEnvName(a) == false else {
                    throw bad("env alias \(a): a credential-shaped variable (…_KEY), not the provider's own, not one the recipe sets")
                }
            }
            if let a = c.envAliases, Set(a).count != a.count { throw bad("an env alias is named twice") }
        }
        // network
        let m = network.model
        if m.shared == true {
            guard m.id == "model", m.hosts == nil else { throw bad("the shared model permission is `model`, with no hosts of its own") }
            guard isBuiltin else { throw bad("a recipe agent has its own model permission") }
        } else {
            guard m.id.hasPrefix("model:"), m.id.dropFirst(6).range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil,
                  m.title != nil, let hosts = m.hosts, !hosts.isEmpty else {
                throw bad("its model permission is model:<name>, with a title and hosts")
            }
        }
        let modelHosts = (m.hosts ?? []).map(\.host), updateHosts = network.update.map(\.host)
        let vendor = network.vendor ?? [], vendorHosts = vendor.map(\.host)
        for h in modelHosts + updateHosts + vendorHosts + network.excluded where !AgentRecipes.isExactHost(h) { throw bad("\(h) is not an exact host name") }
        for p in ((m.hosts ?? []) + vendor).flatMap({ ($0.paths ?? []) + ($0.exactPaths ?? []) }) + network.update.flatMap({ $0.paths ?? [] }) where !p.hasPrefix("/") || p.hasSuffix("$") {
            throw bad("a path prefix starts with /: \(p)")
        }
        for v in vendor {
            guard let r = v.reason, !r.isEmpty else { throw bad("vendor host \(v.host) says why the agent calls it (reason)") }
            // Never a code host whole: GitHub-hosted vendor content is allowed by its path.
            if ["github.com", "api.github.com", "raw.githubusercontent.com", "codeload.github.com"].contains(v.host), v.conditions == nil {
                throw bad("vendor host \(v.host) is allowed by path only")
            }
        }
        for q in network.quiet ?? [] {
            guard AgentRecipes.isExactHost(q.host), q.conditions == nil, let r = q.reason, !r.isEmpty else {
                throw bad("quiet host \(q.host): an exact host, whole, with its reason")
            }
            guard !(modelHosts + updateHosts + vendorHosts).contains(q.host) else { throw bad("quiet host \(q.host) is also one it may reach") }
        }
        for o in network.offWithout ?? [] {
            guard AgentPermissions.basePermissions.contains(where: { $0.id == o.permission }), !o.env.isEmpty, !o.says.isEmpty else {
                throw bad("off_without \(o.permission): a permission, its variables and what it says")
            }
        }
        let excluded = Set(network.excluded)
        guard excluded.isDisjoint(with: modelHosts), excluded.isDisjoint(with: updateHosts), excluded.isDisjoint(with: vendorHosts) else {
            throw bad("an excluded host is also one it may reach")
        }
        if !isBuiltin {
            let everyPermissionHost = Set(AgentPermissions.basePermissions.flatMap { $0.hosts.map(\.host) })
            guard excluded.isDisjoint(with: everyPermissionHost) else {
                throw bad("an excluded host is in a permission: \(excluded.intersection(everyPermissionHost).sorted().joined(separator: ", "))")
            }
            // A key's hosts are its provider's, and its model reaches them.
            for c in credentials { if let p = KeyProviders.provider(c.provider), !Set(p.hosts).isSubset(of: Set(modelHosts)) {
                throw bad("its model permission does not reach its provider \(p.id)'s hosts")
            } }
        }
        try validateModels(bad)
        try validateGuide(bad)              // 617.11
        try validateExtras(bad)
        // prompt, resume, verify
        if let p = prompt {
            switch p.kind {
            case "skill": guard p.dir?.hasPrefix("~/") == true else { throw bad("a skill prompt names its ~/ dir") }
            case "context-file":
                guard let d = p.dir, d.hasPrefix("~/"), let f = p.file, f.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil, scriptSafe(d) else {
                    throw bad("a context-file prompt names its ~/ dir and its file")
                }
                if let mf = p.manifest {
                    guard mf.file.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil, mf.file != f else { throw bad("the prompt's manifest file") }
                }
            default: throw bad("prompt kind skill or context-file")
            }
        }
        guard !verify.isEmpty, verify.allSatisfy({ !$0.argv.isEmpty }) else { throw bad("no verify check") }
        if let c = smoke {
            guard !c.argv.isEmpty, c.argv.allSatisfy({ !$0.isEmpty }), !c.expect.isEmpty else { throw bad("check: an argv and the text to expect") }
            if let e = c.exit, !(0...255).contains(e) { throw bad("check: exit is 0–255") }
            if let t = c.timeout, !(10...1800).contains(t) { throw bad("check: timeout is 10–1800 seconds") }
        }
        if let d = checked, !Self.isISODate(d) { throw bad("checked \(d) is not an ISO date (YYYY-MM-DD)") }
        // tags (owner, 617): exactly the vocabulary's declared tags, each once; never a derivable one.
        for t in tags {
            guard let v = CapabilityTags.tag(t.tag) else { throw bad("tag \(t.tag) is not in the vocabulary (tags.json)") }
            guard !v.derived else { throw bad("tag \(t.tag) is derived from the recipe's data — it is never declared") }
            guard GatewaySupport.levels.contains(t.level) else { throw bad("tag \(t.tag): level \(t.level)") }
            if let d = t.checked, !Self.isISODate(d) { throw bad("tag \(t.tag): checked is not an ISO date") }
            if let u = t.source, !u.hasPrefix("https://") { throw bad("tag \(t.tag): source is an https URL") }
            if t.level == "documented", t.source == nil { throw bad("tag \(t.tag): documented cites its source") }
            if ["verified", "experimental"].contains(t.level), t.evidence == nil { throw bad("tag \(t.tag): \(t.level) says its evidence") }
        }
        let declared = CapabilityTags.all.filter { !$0.derived }.map(\.id)
        guard tags.map(\.tag).sorted() == declared.sorted() else {
            throw bad("tags: one entry for each declared tag (\(declared.joined(separator: ", "))) — unknown is allowed, said explicitly")
        }
        // 617 (owner): what it is — a kind and its categories, declared.
        try Categories.validate(kind: catalogKind, categories: categories, what: "recipe \(id)")
        // gateways (owner, 617): one entry per catalogue gateway, each with its evidence and machine-applicable how.
        // 618: a gateway models@1 offers is derived (gatewaySupport) — an entry for it only overrides; every other
        // catalogue gateway is said explicitly. What a try can do and what the entry says never disagree.
        let catalogue = Gateways.all.map(\.id)
        let entries = gateways.map(\.gateway)
        guard Set(entries).count == entries.count, Set(entries).isSubset(of: catalogue) else {
            throw bad("gateways: at most one entry for each of \(catalogue.joined(separator: ", "))")
        }
        for g in catalogue where !entries.contains(g) && derivedGateway(g) == nil {
            throw bad(offersGateway(g)
                ? "gateways[\(g)]: models@1 offers it — cite where the tool documents it (the shape's source, the native entry's docs) or give an entry"
                : "gateways: one entry for each of \(catalogue.joined(separator: ", ")) that models@1 does not offer (unknown is allowed, said explicitly)")
        }
        for s in gateways {
            let at = "gateways[\(s.gateway)]"
            guard GatewaySupport.levels.contains(s.level) else { throw bad("\(at).level: \(GatewaySupport.levels.joined(separator: ", "))") }
            if models != nil {
                let offered = offersGateway(s.gateway)
                if offered, !s.isApplicable { throw bad("\(at): models@1 offers it, so it is not \(s.level)") }
                if !offered, s.isApplicable { throw bad("\(at): \(s.level), but models@1 does not offer it — add it to models@1, or say no and why") }
            }
            if let d = s.checked, !Self.isISODate(d) { throw bad("\(at).checked is not an ISO date") }
            if let u = s.source, !u.hasPrefix("https://") { throw bad("\(at).source is an https URL") }
            if let sh = s.shape, !Gateway.shapes.contains(sh) { throw bad("\(at).shape \(sh)") }
            if let e = s.endpoint {
                guard let ep = Gateways.gateway(s.gateway)?.endpoints.first(where: { $0.id == e }) else { throw bad("\(at).endpoint \(e) is not the gateway's") }
                if let sh = s.shape, !ep.shapes.contains(sh) { throw bad("\(at): endpoint \(e) does not serve \(sh)") }
            }
            switch s.level {
            case "documented", "verified", "experimental":
                // models@1 says how a try reaches an offered gateway; `how` is then optional.
                let how = s.how ?? GatewayHow()
                if !offersGateway(s.gateway), (how.env ?? [:]).isEmpty, (how.config ?? []).isEmpty { throw bad("\(at): how (env or config) is required") }
                guard s.checked != nil else { throw bad("\(at): checked is required") }
                if s.level == "documented", s.source == nil { throw bad("\(at): a documented entry cites its source") }
                if s.level != "documented", s.evidence?.isEmpty != false { throw bad("\(at): a \(s.level) entry says its evidence") }
                for c in how.config ?? [] where !c.file.hasPrefix("~/") { throw bad("\(at): a config file is ~/…") }
                _ = try s.resolved(placeholder: "doz_cred_x", model: "m/m")
            case "no":
                guard s.reason?.isEmpty == false else { throw bad("\(at): a no says why (reason)") }
            default:
                break
            }
        }
        // auth (owner, 617): at least one way in; each well-formed.
        guard !auth.methods.isEmpty else { throw bad("auth.methods is empty — say how a person lets it talk to its model") }
        for (i, a) in auth.methods.enumerated() {
            let at = "auth.methods[\(i)]"
            if let d = a.checked, !Self.isISODate(d) { throw bad("\(at).checked \(d) is not an ISO date (YYYY-MM-DD)") }
            if let u = a.keysPage, !(u.hasPrefix("https://") && URL(string: u)?.host != nil) { throw bad("\(at).keys_page is an https URL") }
            if a.freeTierNote != nil, a.freeTier == nil { throw bad("\(at): a free-tier note without free_tier") }
            if a.freeTier != nil, a.checked == nil { throw bad("\(at): free_tier is only said with the date it was checked") }
            // 617 (models@1): and the key kind of every model source it is offered.
            let takes = Set(credentials.flatMap(\.accounts)).union(models == nil ? [] : offeredSources.map(ModelSources.accountKind))
            for k in a.accounts ?? [] where !takes.contains(k) { throw bad("\(at).accounts: \(k) is not an account kind it takes (credentials)") }
            switch a.kind {
            case "api-key":
                guard let p = a.provider, KeyProviders.provider(p) != nil else { throw bad("\(at): an api-key method names a provider of providers.json") }
                guard a.keysPage != nil else { throw bad("\(at): an api-key method says where the key is made (keys_page)") }
            case "vendor-sign-in":
                guard let acc = a.account, !acc.isEmpty else { throw bad("\(at): a vendor sign-in says which account (account)") }
            case "none":
                break
            case "gateway":
                guard let g = a.gateways, !g.isEmpty, g.allSatisfy({ $0.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil }) else {
                    throw bad("\(at): a gateway method names its gateways")
                }
            default:
                throw bad("\(at).kind: api-key, vendor-sign-in, none or gateway")
            }
        }
        if let s = settings {
            for k in [s.version, s.permissions].compactMap({ $0 }) where k.range(of: "^[a-z_]+(\\.[a-z_]+)+$", options: .regularExpression) == nil {
                throw bad("settings key \(k)")
            }
        }
    }
}
