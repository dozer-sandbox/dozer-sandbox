# The recipe format (schema 2)

A **recipe** tells Dozer Sandbox how to install a coding agent, launch it, keep its state, give it its key without
the key ever entering the sandbox, and decide what it may reach. Each agent is one YAML file:

```
Sources/DozerKit/Recipes/agents/VENDOR/PRODUCT.yaml      ← what you edit
Sources/DozerKit/Recipes/compiled/PRODUCT.json           ← the same tree as JSON (generated, committed, embedded)
schema/dozer-recipe-2.schema.json                         ← the contract (JSON Schema, draft 2020-12)
```

The layout follows **Docker Sandbox Kit v3** (its `workload` descriptor): Kit's top-level fields, a `capabilities:`
list, Kit's own capability types where Kit has one, and Dozer's additions kept apart (under `dozer:` keys and in
`com.dozersandbox/*` types). A Kit-shaped descriptor can therefore be produced from a recipe mechanically — see
[Kit v3, and exporting to it](#kit-v3-and-exporting-to-it).

**Contents:** [an example](#an-example) · [the top level](#the-top-level) · [capabilities](#capabilities) ·
[templating](#templating) · [strictness](#strictness) · [versioning](#versioning) ·
[Kit v3, and exporting to it](#kit-v3-and-exporting-to-it) · [adding a recipe](#adding-a-recipe)

## An example

Abridged from `Recipes/agents/xai/grok.yaml`:

```yaml
# yaml-language-server: $schema=../../../../../schema/dozer-recipe-2.schema.json
schema: 2
kind: workload
id: xai/grok
displayName: Grok Build
description: xAI's coding agent, on an xAI API key.
author: xAI
sourceUrl: https://github.com/xai-org/grok-build
licenses:
- Apache-2.0
args:
  version:
    default: 1.0.52
    pattern: '[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?'
    buildArg: GROK_VERSION
provides:
- com.dozersandbox/grok@${{ kit.args.version }}
capabilities:
- type: com.docker.sandbox/network-policy@1
  config:
    runtime:
      allow: [api.x.ai:443, x.ai:443]                 # derived — see below
      deny: [cli-chat-proxy.grok.com:443, auth.x.ai:443, accounts.x.ai:443, console.x.ai:443]
    dozer:
      model:
        id: model:xai
        title: Talk to xAI
        hosts:
        - host: api.x.ai
          paths: [/v1/models, /v1/api-key, /v1/chat/completions, /v1/responses]
      update: []
      excluded: [cli-chat-proxy.grok.com, auth.x.ai, accounts.x.ai, console.x.ai]
- type: com.docker.sandbox/credential@1
  config:
    service: xai
    phase: runtime
    apiKey:                                           # derived from the key provider
      name: XAI_API_KEY
      proxyManaged: true
      inject: [{domain: api.x.ai, header: authorization, format: Bearer %s}]
    dozer:
      accounts: [key]
- type: com.docker.sandbox/volume@1
  config:
    path: /home/agent/.grok
- type: com.dozersandbox/install@1
  config:
    kind: npm-platform-binary
    package: '@xai-official/grok'
    platform_package: '@xai-official/grok-linux-arm64'
    payload: bin/grok.br
    compression: brotli
    binary: grok
    integrity: sha512-GeIlno…
- type: com.dozersandbox/launch@1
  config:
    command: [grok]
    no_prompts_args: [--always-approve]
    passthrough: [--version, -v, --help, -h, login, logout]
    env: {GROK_DISABLE_AUTOUPDATER: '1'}
    state_env: {GROK_HOME: /home/agent/.grok}
    status: none
    verify:
    - argv: [grok, --version]
      expect: grok ${{ kit.args.version }}
    check:
      argv: [grok, -p, say ok]
      expect: DOZ_FAKE_OK
# … auth@1, gateways@1, currency@1, directory@1
```

The files in the repository are written in block style (one value per line); any YAML that means the same is
accepted.

## The top level

Every key is required. Kit's own names, with Kit's meaning:

| Field | Meaning | Example |
|---|---|---|
| `schema` | This format's version: `2`. | `2` |
| `kind` | Kit's kind. A recipe is the agent a sandbox runs: `workload`. | `workload` |
| `id` | `VENDOR/PRODUCT`: the file's path under `Recipes/agents/`. `PRODUCT` is the agent's id (`doz try PRODUCT`), `[a-z][a-z0-9-]*`. | `anthropic/claude-code` |
| `displayName` | The agent's name as people read it. | `Claude Code` |
| `description` | One sentence. | `Anthropic's coding agent in your terminal.` |
| `author` | Kit's `author`: the publisher's name. | `Anthropic` |
| `sourceUrl` | Its source or documentation (https). | `https://code.claude.com` |
| `licenses` | SPDX identifiers. A licence SPDX has no id for is `LicenseRef-…` (SPDX's own form), with its words in `directory@1`'s `licence`. | `[Apache-2.0]`, `[LicenseRef-proprietary]` |
| `args.version` | Kit's arg for the version Dozer installs: `default` (the pinned release), `pattern` (the shape of a release), `buildArg` (its build-argument name in an exported Dockerfile), `description`. | `default: 2.1.227` |
| `provides` | Kit's `provides`, one entry, in Dozer's namespace: `com.dozersandbox/PRODUCT@${{ kit.args.version }}`. | |
| `capabilities` | The list below. | |

## Capabilities

Each entry is `{type, description?, config}`. `type` says how `config` is read. A recipe has exactly one
network-policy, install, launch, auth, gateways and directory entry; at most one agent-context and currency entry;
one credential entry per key it uses, and one volume entry per state folder (in order).

### Kit's own types

Their `config` is Kit's shape exactly. Dozer's additions sit only under `config.dozer`, which an export removes.

**`com.docker.sandbox/network-policy@1`** — what the sandbox may reach.

| Field | Meaning |
|---|---|
| `runtime.allow` | **Derived.** `host:443` for each host of its model (the recipe's `dozer.model.hosts`, or its key provider's hosts for the shared Anthropic model) and each `dozer.vendor` host — in order, once each. |
| `runtime.deny` | **Derived.** `host:443` for each `dozer.excluded` and `dozer.quiet` host. |
| `dozer.model` | Its model permission: `id` (`model` — Anthropic's, shared — or `model:NAME`), `shared`, `title`, `summary`, `phrase`, `hosts`. |
| `dozer.update` | The hosts "Update itself" opens in its sandbox only. |
| `dozer.excluded` | Hosts kept out whatever is chosen (a sign-in Dozer does not offer, a host it must not use). |
| `dozer.vendor` | Hosts on its own maker's sites it calls at a normal start, each with its `reason`; allowed in its sandbox only. |
| `dozer.quiet` | Hosts it calls that no setting of its own turns off and that Dozer keeps out without counting a refusal (promptfoo's telemetry event; start-up requests of Kimi Code, Cline, Letta Code, Docker Agent, Nanocoder, CodeWhale, Maki and oh-my-pi). |
| `dozer.off_without` | Its own switches, set when a permission is off: `permission`, `env`, `says`. |

A host entry is `{host, paths?, exact_paths?, reason?}`: `paths` are prefixes (the proxy decrypts the connection to
judge them), `exact_paths` match exactly.

There is no `install` phase: Dozer's image preparation is not Kit's install hook. The bake reaches the base image's
registries and the recipe's `bake_hosts`.

**`com.docker.sandbox/credential@1`** — one per key the agent uses.

| Field | Meaning |
|---|---|
| `service` | The key provider (`providers.json`): `anthropic`, `openai`, `xai`, `google`. |
| `phase` | `runtime`. |
| `apiKey` | **Derived** from the provider: `name` (the variable holding Dozer's placeholder), `proxyManaged: true` (the proxy swaps the placeholder for the key, so the key never enters the sandbox), `inject` (one `{domain, header, format}` per provider host). |
| `dozer.accounts` | The Dozer account kinds that serve it (`mac`, `setup-token`, `api-key`, `codex-mac`, `chatgpt`, `openai-key`, `key`). |
| `dozer.env_aliases` | A recipe agent's: more guest variables that hold the same placeholder, for a tool that reads its key under another name (`OPENAI_API_KEY` beside an OpenAI-compatible base URL that points at the provider, `LLM_GEMINI_KEY`). Credential-shaped names, never the provider's own, never one the recipe sets. The placeholder works only on the provider's hosts, whatever the name it rides in. |

**`com.docker.sandbox/volume@1`** — one state folder kept with the sandbox: `path`, absolute (`/home/agent/…`).

**`com.docker.sandbox/agent-context@1`** — where Dozer writes the facts the agent reads about its sandbox:
`directory` and `filename` (`SKILL.md` for a skill); `dozer.kind` (`skill` or `context-file`), `dozer.manifest` (a
file written beside it: `{file, json}`), `dozer.launcher_arg` (the flag that also passes the facts on the command
line).

### Dozer's types

Kit has no type for these. An export keeps them as `optional: true` entries, which a Kit host skips.

**`com.dozersandbox/install@1`** — how the agent is installed. The version is `args.version`.

| Field | Meaning |
|---|---|
| `kind` | `builtin` (Dozer's own installer: Claude Code, pi, Codex), `npm`, `npm-platform-binary` (the linux-arm64 program from a platform package), `manifest-binary` (the maker's release manifest), `pypi` (a Python tool and every dependency, hash-pinned — below), `release-binary` (one program from a release download — below). |
| `builtin` | `true` for the three agents Dozer's own code installs and launches. |
| `package`, `platform_package`, `payload`, `compression` | The npm package(s), the program inside, and `brotli` when it is compressed. |
| `manifest`, `url` | `manifest-binary`: the manifest's URL; the archive URL, a template with `${{ dozer.build }}`. |
| `binary` | The program, at `/usr/local/bin/BINARY`. |
| `needs_node`, `npm_args` | The Node major an npm install needs; extra `npm install` flags. Above 22 (the bases' Node), `24`: Dozer installs Node 24 under `/opt/node` for it on every glibc base, the Node base included, and runs the program on it (`platforms.musl: false`). |
| `bake_hosts` | Hosts the image preparation reaches beyond the base's registries. |
| `integrity` | The pinned release's sha512 (`sha512-…`). |
| `requirements` | `pypi` only: every distribution the tool's venv holds, one string each, `name==version --hash=sha256:<64 hex>` — the package itself and all its dependencies. |
| `extras` | Files the tool needs beside its program, from a pinned archive: `{url, sha256, path, to, what}` — an https `.tar.gz` (`${{ kit.args.version }}` in `url` and `path`), its sha256 (checked in the bake), the folder `path` inside it, unpacked to `to` (under `/opt/PRODUCT/`, root's, read-only to the agent). Fabric's patterns: `to: /opt/fabric/patterns`, and `launch.env` points the tool at them. Its host joins the bake's. |

**`pypi`** installs a Python tool from PyPI. The image gets Dozer's own Python (python-build-standalone CPython 3.13 for
aarch64 glibc, checksum-pinned, under `/opt/python` — the base's python3 is left alone, so the same wheels fit every
glibc base), a venv at `/opt/PRODUCT/venv`, and in it exactly the `requirements`: pip with `--require-hashes --no-deps`
downloads each one, checks its sha256, and installs nothing else; the package's own file is also checked against
`integrity` (its sha512, computed from the download when the recipe is written). `binary` is linked as
`/usr/local/bin/BINARY`. The lock is written once, in a scratch VM, from pip's own resolver (`pip install --dry-run
--report` against Dozer's Python, which lists each file and its PyPI sha256). The bake reaches PyPI
(`pypi.org`, `files.pythonhosted.org`) and GitHub's release hosts for the Python download. glibc only
(`platforms.musl: false`). A `pypi` recipe is prepared at its pin only: the lock belongs to that release, so nothing is
looked up and `latest` means the pin.

**`release-binary`** installs one program from a release download: `url` (https, with `${{ kit.args.version }}` in it);
when it ends in `.tar.gz`/`.tgz` or `.zip` it is unpacked and `payload` names the program inside, otherwise the download
is the program. Its sha512 is checked against `integrity`; it is placed under `/opt/PRODUCT` and linked as
`/usr/local/bin/BINARY`. Its download hosts go in `bake_hosts` (GitHub: `github.com` and
`release-assets.githubusercontent.com`). Like `pypi`, it is prepared at its pin only.

**`com.dozersandbox/launch@1`** — how the agent runs.

| Field | Meaning |
|---|---|
| `command` | The program and its first arguments. |
| `no_prompts_args` | What turns its own approval prompts off (the sandbox is the boundary). |
| `no_prompts_env` | Variables set only when `no_prompts_args` would be put first (not with `ID.permissions = ask`, nor as root) — for an agent whose approval switch is a variable: MiMo Code's flag asks again on a terminal, its variable does not. |
| `passthrough` | First arguments that run it as it is (`--version`, `login`). |
| `env`, `state_env` | Environment of every run; of its state folders (both baked). |
| `first_run` | Settings written into its config files, only the keys not there yet: `{file: ~/….json or ~/….toml, set: {dotted.key: value}}`; in a TOML file a key with no table (`schema_version`) is a top-level key, written above the first table; or a dotenv file, `{file: ~/…/.env, set: {KEY: value}}` (`KEY=value` lines — a key the file already has, even commented out, is kept; the file is made when missing; never a credential's name); a TOML key segment in double quotes is one key (`'projects."/workspace".trust_level': trusted` → `[projects."/workspace"]`); `format: json` for a JSON file whose name has no extension (Kimi Code's per-folder trust record); or a YAML file, `{file: ~/….yaml, set: {KEY: value}}` (top-level `KEY: value` lines only, each a string, number or bool — a key the file already has at the top level, even commented out, is kept; the file is made when missing). |
| `session_env` | Environment Dozer gives each session when it opens (never baked). |
| `session` | `shell` for a command-line tool that answers and exits (Fabric, llm): the default session is a login shell (`bash -l`) with the program on its PATH, named for the program. Absent: the session runs `command`. A shell session has no `resume`. |
| `service` | A background service the program starts and keeps, which holds the environment of the run that started it (OpenCode 2's `opencode serve --service`): `{args, restart, start?, env}` — its arguments after the program, what restarts it, what starts it when the restart fails (a stopped server the VM's init leaves as a zombie), and the variables compared (`[DOZ_MODEL]`; never a key's: placeholders differ per run). Before every run, the launcher restarts a service of the same user running with another value of one of `env` than the run sets, so a model or source chosen since applies. Plain words only (it is written into the launcher). |
| `status` | `osc7501` (it reports its state to Dozer) or `none`. |
| `resume`, `resume_check` | Arguments that continue its last conversation after a restart, and a check that there is one. |
| `verify` | Checks after preparation: `{argv, expect}`; `expect` may hold `${{ kit.args.version }}`. |
| `check` | Required. One headless turn `make recipe-check` runs in a fresh try: `{argv, expect, exit?, timeout?}` — `argv` runs as the agent through its launcher (approval prompts off), with fake keys and a stand-in model that answers `DOZ_FAKE_OK`; its output must contain `expect`, it must exit `exit` (default 0) within `timeout` seconds (default 240). `screen` (optional, `{expect?, refuse?, allow?, wait?}`): what the default session's first screen must show (`expect`, regular expressions) and must not (`refuse`, on top of the generic setup/sign-in/consent list), the lines the generic list excuses (`allow` — a ready screen's own banner), how long it settles (`wait`, default 15 s), and keys typed first (`keys`: `enter`, `esc`, `up`, `down`, `tab`, `space` — only for a choice nothing skips that is not the person's decision, to reach the screen checked: Antigravity CLI's colour scheme before its terms). See "Checking a recipe" below. |
| `settings` | Its settings keys, when not the defaults (`images.ID_version`, `ID.permissions`). |

**`com.dozersandbox/auth@1`** — `methods`: the ways a person lets it reach its model, recommended first. Each is
`{kind, provider?, account?, accounts?, keys_page?, free_tier?, free_tier_note?, in_sandbox?, gateways?, note?,
checked?}`; `kind` is `api-key`, `vendor-sign-in`, `none` or `gateway`.

**`com.dozersandbox/gateways@1`** — `entries`: how it works through each model gateway in Dozer's catalogue: `{gateway,
level (documented | verified | experimental | no | unknown), shape?, endpoint?, how?, proxy_route?, limits?, notes?,
evidence?, source?, checked?, reason?}`. `how` is `{env?, config?, args?, model_args?}`, whose values may hold
`${{ dozer.placeholder }}`, `${{ dozer.model }}` and `${{ dozer.gateway.endpoint.ID }}`. A gateway that `models@1` offers
needs no entry: it is `documented`, citing the shape's `source` (or the native entry's `docs`). An entry for it only
overrides that — `verified` with its evidence once `make recipe-check` has run the tool through it — and needs no `how`.
Every gateway models@1 does not offer has an entry (`no` with its reason, or `unknown`); a recipe with models@1 may not
call one `documented`/`verified`/`experimental` that a try cannot use, nor `no` one it offers.

**`com.dozersandbox/models@1`** — which model sources it can be tried with, and how a choice reaches its own settings.
See [Model sources](#model-sources-providers-and-gateways).

**`com.dozersandbox/currency@1`** — `checked` (when the recipe was last checked against the real agent) and
`lifecycle` (`{status: current | superseded | retired | discontinued, by?, note?, source?, checked?}`). How fresh the
agent's releases are is measured on each Mac, never recorded here.

**`com.dozersandbox/directory@1`** — what the directory index, `doz search` and the Quick try show: `kind` and
`categories` (see [Kinds and categories](#kinds-and-categories)), `aliases`,
`icon` (a product in the icon registry), `default_base`, `platforms {glibc, musl}`, `limits` (`{musl?, base?,
reason}`), `tags` (`{tag, level, evidence?, source?, notes?, checked?}` — the tags no other field can derive),
`terms`, `licence` (the licence in words, when it is not just the SPDX id).

**`com.dozersandbox/guide@1`** (optional, at most one; every shipped recipe has one) — its companion guide: intro, first
steps (the first with a command is its check turn), tips, docs, a notice. See [The guide](#the-guide).

**`com.dozersandbox/ports@1`** (optional, at most one) — the web ports the program serves inside the sandbox, each
forwarded to the Mac's loopback (`127.0.0.1`) while the sandbox runs, with an Open button ([Web
ports](../manual/29-web-ports.md)). `ports`: 1–16 of `{port, title, path?, protocol?, auth?, token_hint?, check?}` —
`port` the guest port its program listens on (its own localhost), `title` the button's label (1–40 characters),
`path` what Open opens (default `/`), `protocol` `http` (default) or `ws` (forwarded, no button), `auth` `none`
(default), `token` (the program prints a token — `token_hint` says where) or `login`, `check` what `make recipe-check`
GETs (default `path`; any HTTP status line passes). `serve`: the command that serves them when the session's program
does not (`[aichat, --serve]`) — `make recipe-check` runs it in the background before it GETs each http port through a
real forward. The forward is inbound only: it is not egress, the network policy and the proxy do not apply to it, and
no credential crosses it.

```yaml
- type: com.dozersandbox/ports@1
  config:
    ports:
    - port: 8000
      title: AIChat web
      path: /playground
    serve: [aichat, --serve]
```


## The guide

`com.dozersandbox/guide@1` is the recipe's companion guide: the Guide tab of the sandbox page (first, and chosen, on a
try), `doz guide NAME`, the "Start here" `doz try` prints before it attaches a tool whose session is a shell, and a
one-time note in that shell's first login.

```yaml
- type: com.dozersandbox/guide@1
  config:
    intro: "Fabric applies ready-made prompts — patterns — to text you pipe into it. It is not a chat: it answers in your shell and exits."
    steps:
    - text: "Check it answers."
      command: 'echo hello | fabric "say ok"'       # the check turn, as a person types it
    - text: "See the patterns it has."
      command: "fabric -l"
    - text: "Use a file from your folder — put it there first, then change the name:"
      command: "fabric -p extract_wisdom < notes.md"
      edit: true                                     # typed, never run: the person changes it first
    tips:
    - "`fabric -s` streams the answer as it comes."
    docs: https://github.com/danielmiessler/Fabric
```

- **`intro`** — one or two sentences: what it is, and whether it is a chat, an agent with its own screen, or a tool
  that answers in the shell and exits (≤ 400 characters).
- **`steps`** — 1 to 8 `{text, command?, edit?}`. The first step WITH a command is the recipe's `launch@1.check` turn as a
  person types it (`sh -c X` is X; `${{ dozer.model }}` is the variable models@1 sets to it, `"$DOZ_MODEL"`), so the
  first thing a person runs is known to work. Every command starts with the tool's program, its session's command, its
  short name, or a plain shell builtin (`echo`, `printf`, `cat`, `ls`, `cd`, `mkdir`, `head`, `tail`, `export`), is one
  line, its quotes closed. `edit: true`: the page types it and never presses Enter. A step without a command may come
  before it — what the person meets at the first start that Dozer leaves to them (Antigravity CLI: Google's terms).
- **`notice`** — optional, one line (≤ 200 characters) `doz try` says first: that same thing, in short.
- **`tips`** — at most 6, `code` in backquotes (the page draws it as code, never as markup); **`docs`** — https.

Dozer adds the rest, never the recipe: the preamble (what kind of thing it is, how to use it here) and "This try" —
the version (the pin), the provider and model with the account's NAME ("your key stays on the Mac"), the network, the
folder (the Mac's path) and where its settings live. `make recipe-check` runs every step with a command after the check
turn's that is not an edit, in a shell in the try (exit 0).

## Families: a tool's majors

When a tool's new major release line is a different program (OpenCode 2: another npm package, another config, a
background server), each major is a recipe of its own, and `com.dozersandbox/family@1` ties them together:

```yaml
- type: com.dozersandbox/family@1
  config:
    family: opencode          # what a person types: the recommended major
    major: 2
    title: OpenCode 2
    recommended: true         # exactly one per family
```

- `NAME` is the family's recommended major, `NAME@MAJOR` a major, `NAME@VERSION` an exact release of the major it
  belongs to (`AgentRef`). A member named by its own id (`opencode2`) is that major.
- The family's name is the id of one of its members — the one that predates the family. Its sandboxes, image, settings
  and statistics keep that id, so an existing sandbox never changes major. No other recipe or alias may use the name.
- Each member pins a release of its own major. Its `latest` stays within that major: when the package's `latest` tag is
  another major's, Dozer takes the newest stable release of its own.
- Each major has its own guide, check, network profile and statistics id.
- Move `recommended` to a new major only once its recipe passes `make recipe-check`, in a commit of its own. It is
  "recommended", never "latest".

## Kinds and categories

Every recipe says what it is, in `directory@1` — declared, because nothing else in its data can say it:

```yaml
- type: com.dozersandbox/directory@1
  config:
    kind: ai-tool                # coding-agent | ai-tool: the two sections of New Sandbox, the Quick try and doz try's list
    categories:                  # one or more, from the vocabulary; the Quick try's filter pills, doz search --tag
    - terminal-tool
```

The vocabulary is `Recipes/tags.json` (`kinds`, `categories`, beside the capability tags), each word with a title and
what it means:

| Category | For | Kind |
|---|---|---|
| `coding-agent` | edits and runs code in its folder, turn by turn | coding agents only |
| `personal-agent` | a general assistant acting with shell, file and web tools | either |
| `terminal-tool` | a command-line helper: chat REPL, one answer, a shell command | AI tools |
| `framework` | a library or kit for building agents and LLM apps | AI tools |
| `browser-agent` | drives a web browser | AI tools |
| `mcp` | Model Context Protocol servers, gateways, inspectors | AI tools |
| `research` | searches, reads and reports | AI tools |
| `evaluation` | tests and red-teams prompts and models | AI tools |
| `workflow` | builds automations and pipelines | AI tools |
| `local-models` | runs models inside the sandbox | AI tools |
| `chat-app` | a chat web app for your models | AI tools |

The loader refuses a recipe without a kind or a category, a word that is not in the vocabulary, a category twice, or a
category of the other kind. An entry of `Recipes/known.json` (one that is coming) carries `kind` and `categories` too,
so the directory, `doz search --tag` and the Quick try's sections include it. A new word is a change to tags.json, the
schema's enum and this table together (`CategoriesTests` holds them to each other).

## Model sources: providers and gateways

A **model source** is where a key goes: a provider (`anthropic`, `openai`, `xai`, `google`) or a gateway
(`openrouter`, `vercel-ai-gateway`). Each is a key provider in `Recipes/providers.json` — its hosts, the header its key
rides in, the variable its placeholder is in, its check — and each lists its **endpoints**: the API shapes it serves
(`openai-chat`, `openai-responses`, `anthropic-messages`, `gemini`), the base URL of each, and a default model (a
gateway's is `creator/name`). Gateways take their endpoints from `Recipes/gateways.json`.

A recipe says what it can speak, and nothing about keys:

```yaml
- type: com.dozersandbox/models@1
  config:
    default: xai                         # the source a try uses when none is chosen
    shapes:                              # the shapes it speaks to ANY source's base URL, preferred first
    - shape: openai-chat
      env: {API_BASE_URL: '${{ dozer.base_url }}', DEFAULT_MODEL: '${{ dozer.model }}'}
      key_env: [OPENAI_API_KEY]          # where it reads the key for this shape
      source: https://…                  # where the tool documents taking a base URL, key and model
    native:                              # the sources it reaches through its own client (no base URL)
    - source: anthropic
      env: {DEFAULT_MODEL: 'anthropic/${{ dozer.model }}'}
      docs: https://…                    # optional: where the tool documents this source
    models:                              # optional: a default model per source, over the source's own
      openrouter: openai/gpt-5.4-mini
```

`launch@1.check.argv` may name `${{ dozer.model }}` too: `make recipe-check` runs the check turn once per source the
recipe is offered (in a fresh try with that source's fake key) and puts that source's model there.

- **What it is offered:** every source with an endpoint speaking one of `shapes` (the first shape listed that the source
  serves wins), and every source named in `native`. So a tool that takes an OpenAI-compatible base URL (`openai-chat`
  or `openai-responses`) is offered OpenRouter and Vercel AI Gateway without naming them; its gateway entries follow
  (see `gateways@1`), and so do `--gateway`, the plan, the Quick try's "Through a gateway" and `doz search`. `except` (a list of source ids) leaves sources out a shape would
  offer. The try setup, New Sandbox, `doz try --provider SOURCE` (`--gateway` is the same flag) and `doz create` offer
  exactly these.
- **What a choice does:** at every session open and every `doz exec`, Dozer sets the chosen entry's `env` (never over a
  value the caller gave), with `${{ dozer.base_url }}` = the source endpoint's base URL and `${{ dozer.model }}` = the
  sandbox's model (`--model`, else `models.<source>` here, else the source endpoint's default). Nothing is baked: one
  image serves every source.
- **The key is Dozer's, never the recipe's.** The sandbox's account decides the source (its kind and provider); the
  proxy holds that source's key and swaps it ONLY into requests to that source's own hosts (providers.json /
  gateways.json — a recipe cannot add one). The placeholder is put in the source's own variable
  (`OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `AI_GATEWAY_API_KEY` …) and in the chosen entry's `key_env` names
  (credential-shaped, validated). A recipe-chosen base URL is therefore harmless: the placeholder sent anywhere else is
  refused by the leak guard, and the key never leaves the Mac.
- **Its model permission** reaches the hosts of every source it is offered (validated), so a sandbox can use the source
  its account names.
- **Accounts:** an Anthropic source takes an Anthropic API-key account (`--api-key`; never a Claude subscription), an
  OpenAI source an OpenAI API-key account (`--openai-key`; never a ChatGPT sign-in), every other source a `key` account
  of that provider (`doz account add NAME --provider openrouter`).
- A recipe without `models@1` keeps its one credential exactly as before (the built-in three; Claude Code's and Codex's
  own account flows are untouched).

## Templating

Kit's syntax, `${{ NAME }}`. A recipe may use exactly these, and only in the fields named above:

| Template | Where | Value |
|---|---|---|
| `${{ kit.args.version }}` | `provides`, `launch@1.verify.expect` | The release (in `expect`, without a `+build` part). |
| `${{ dozer.build }}` | `install@1.url` | The release's `VERSION-BUILD` path segment (`manifest-binary`). |
| `${{ dozer.placeholder }}` | `gateways@1` `how` | The gateway key's placeholder. |
| `${{ dozer.model }}` | `gateways@1` `how` | The model chosen. |
| `${{ dozer.gateway.endpoint.ID }}` | `gateways@1` `how` | The gateway endpoint's base URL. |

Any other name is an error, and so is the old `{name}` form.

## Strictness

As in Kit: **an unknown key anywhere is an error**. That covers the top level, every capability entry, every Kit
config and every `dozer:` block. A capability type this build does not know is an error, and so is a second copy of
a single one. The **derived** parts (`runtime.allow`, `runtime.deny`, a credential's `apiKey`) must equal what Dozer
derives, so they can never drift from the data they describe; the error says the expected value.

The JSON Schema states the shape. The loader (`RecipeDocument` in DozerKit) refuses whatever the schema refuses, and
also checks what only Dozer can: the derived parts, the templates, and the agent's own rules (exact host names, no
credential in an environment variable, a pinned release that is well formed). The tests hold the two together.

The YAML is read with YAML 1.2's core schema: `true` and `false` are the only booleans (`no` and `on` are words),
and a date stays a string. Anchors, aliases and merge keys are refused, so a recipe is plain data.

## Versioning

`schema: 2` promises the shape `schema/dozer-recipe-2.schema.json` describes. Within schema 2:

- A new **optional** field, or a new capability type, may be added. An older Dozer refuses a recipe that uses it,
  because unknown keys are errors. Dozer's own recipes ship with Dozer, so they always match.
- A field is never renamed, removed or given a new meaning. That needs `schema: 3`, with a new schema file beside
  this one.
- Kit's capability versions (`network-policy@1`, …) are Kit's. When Kit moves one (`network-policy@2` exists), a
  recipe moves to it in a new schema version, not silently.

## Kit v3, and exporting to it

| Dozer recipe | Kit v3 descriptor |
|---|---|
| `schema: 2` | `schemaVersion: "3"` |
| `id` (`VENDOR/PRODUCT`) | the image reference the kit is published under |
| `kind`, `displayName`, `description`, `author`, `sourceUrl`, `licenses`, `args`, `provides` | the same fields |
| `network-policy@1`, `credential@1`, `volume@1`, `agent-context@1` | the same entries, each `config.dozer` removed |
| `com.dozersandbox/*@1` | kept as `optional: true` entries (a Kit host skips an optional type it does not know); `${{ dozer.NAME }}` written as `{dozer.NAME}` |
| `install@1` + `launch@1` | a generated Dockerfile: `ARG` from `args.version.buildArg`, the install steps, `ENV`, `ENTRYPOINT` |
| `directory@1` `icon` | `iconUrl` (the registry's published https URL) |

Kit has no type for first-run settings that **merge** into a config file: `lifecycle@1`'s `files` write whole
files. So `first_run` lives in `launch@1`, and a recipe has no `lifecycle@1` entry. A `lifecycle@1` holding only a
`dozer:` block would be empty after export, which Kit refuses.

A test builds this view of every recipe in memory and validates it against Kit v3's own published JSON Schema,
vendored in `Tests/Fixtures/kit-v3/`. It also checks Kit's cross-entry rule that every credential inject domain is
allowed. An export command that writes the descriptor and its Dockerfile comes later, once Kit's specification is
final.

## Adding a recipe

1. **Write `Recipes/agents/VENDOR/PRODUCT.yaml`**, starting with the `# yaml-language-server:` line (editors then
   check it against the schema as you type). Copy the closest existing recipe.
2. **Its key provider** must be in `Recipes/providers.json`. The credential's `apiKey` is derived from it.
3. **Its mark:** add a product (and its vendor, if new) to the icon registry, `Recipes/icons/icons.json`, and name
   it in `directory@1`'s `icon` (docs/DOZERKIT.md, *The icon registry*).
4. **Embed it:** add `.embedInCode("Recipes/compiled/PRODUCT.json")` to Package.swift, and the file to the two lists
   in `AgentRecipes` (`compiled` and `compiledFiles`, AgentRecipe.swift). `AgentKind` follows the recipes by itself.
5. **`make recipes`** writes `Recipes/compiled/PRODUCT.json`. Commit both files.
6. **Profile its network:** `make profile-agents AGENTS=PRODUCT` records every endpoint its first start calls
   (`profiles/PRODUCT.json`). Decide each one, then allow it (vendor, model), keep it out (`excluded`), or turn it off
   with its own setting (`first_run`, `off_without`).
7. **Its currency:** `make agent-currency` records its latest release and how fresh it is.
8. **Test:** `make test` checks the schema, the loader, the Kit view, the profile decisions and the first-run
   settings. `make recipe-check RECIPES=PRODUCT` proves it builds, starts and answers in a real sandbox (below).

## Checking a recipe

`make recipe-check RECIPES="grok gemini"` (`RECIPES=all`: every recipe) runs each recipe for real, in a scratch store
(`RECIPE_STORE`, default `/tmp/doz-recipe-check`; prepared images are kept there between runs, sandboxes never are):

1. **Build** its image at the pinned release (the registries are not asked for a newer one) — the bake checks the
   pin's integrity and runs `verify`.
2. **Verify** — each `verify` command again, in a sandbox, its output compared with `expect`.
3. **A fresh try** with fake keys held in the host's memory; the model's hosts (xAI, Google, Anthropic, OpenAI) go to
   a stand-in on this Mac (`Scripts/fake-provider.py`, TLS with its own throwaway CA) that answers `DOZ_FAKE_OK`.
4. **The smoke turn** — `check.argv` as the agent; its output must contain `check.expect`, its exit status be
   `check.exit`. The stand-in must have seen the fake key, swapped in by Dozer's proxy, while the guest holds only a
   placeholder.
5. **No key in the guest** (its processes' environments, home folders, `/tmp`, `/run`, `/etc`), and **the leak
   guard**: the placeholder sent to another provider's host is refused and never reaches it.
6. **Its status** — for `status: osc7501`, an interactive turn in its default session: Dozer must see it report at
   least `idle`, `working` and `done`.

Before any of the try's commands run (step 3 onwards), **its first screen**: every recipe whose default session is the
agent (not `session: shell`) has that session opened on a terminal, nothing typed, left to settle (`check.screen.wait`,
default 15 s), and its screen read back. It must be the agent ready to work: no setup wizard, onboarding, sign-in,
usage-data consent, trust or theme question, no request for a key (a generic list in `Scripts/recipe-check.py`,
`SETUP_SCREEN`; a line `check.screen.allow` matches is excused), each `check.screen.expect` found and no
`check.screen.refuse`. A headless check turn never sees such a screen — a person's first try does (Goose ran its own
setup whenever its `config.yaml` was missing, whatever the environment said). `RECIPE_ONLY=screen` runs this check
alone, for a quick look at every agent's first screen.

It exits non-zero when any step fails and writes a JSON report (`RECIPE_REPORT`, default
`$RECIPE_STORE/report.json`): per recipe pass/fail, the version, each step's duration, the states seen and the
failures. The **Recipes** workflow (`.github/workflows/recipes.yml`) runs it on a self-hosted Mac for every change to
a recipe, the stand-in or the harness, and every night for all of them with `make agent-currency` and
`make profile-agents DIFF=1`.
