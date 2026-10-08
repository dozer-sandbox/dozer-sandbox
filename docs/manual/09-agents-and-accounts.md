# Agents and accounts

Dozer runs three AI coding agents out of the box — **Claude Code**, **pi** and OpenAI's **Codex** — and
gives each one the account it should use, without the secret ever entering the sandbox. Codex has its
own page: [Codex](24-codex.md). This page covers which
agent can use which account, how to add accounts, the agent's versions and its `sudo`, and what the
agent is told about where it runs.

## Concepts

- **The agent runs as a normal user** (`agent`) in `/workspace`. Its own settings, logins and
  history (`~/.claude`, `~/.pi/agent`, Codex's `~/.codex`) are on a separate **state disk** that survives shutdown and
  reset.
- **An account** is how the agent pays for its model. Dozer's proxy on your Mac holds the secret and
  adds it to requests to Anthropic on their way out. Inside the sandbox, `ANTHROPIC_API_KEY` or
  `CLAUDE_CODE_OAUTH_TOKEN` is only a placeholder (`doz_cred_…`). A secret is never a command-line
  argument, so it never lands in shell history or `ps`.
- **Three kinds of account:**

  | kind | what it is | where the secret lives | renewal |
  |---|---|---|---|
  | `mac` (built in) | your Mac's own Claude Code login | Claude Code's own keychain item, read-only for Dozer | your Mac's Claude Code renews it |
  | setup token | a `claude setup-token` token (a Claude subscription, valid a year) | your login keychain, `doz-claude:NAME` | none — add a new one before it expires |
  | API key | an Anthropic API key | your login keychain, `doz-anthropic:NAME` | none |

  For **Codex**, OpenAI's kinds: **this Mac's Codex login** (`mac` — read-only, nothing to add; the
  default while Codex is signed in on this Mac), a **ChatGPT sign-in** (builds from source only: `doz account add NAME --chatgpt`
  — Dozer's own, in your browser; renewed by Dozer on your Mac) and an **OpenAI API key**
  (`--openai-key`). See [Codex](24-codex.md).

- **Which agent can use which:**

  | agent | accounts it can use |
  |---|---|
  | Claude Code | `mac`, a setup token, an API key |
  | pi | an API key only (a Claude subscription is never given to it) |
  | Codex | `mac` (this Mac's Codex login), a ChatGPT sign-in or an OpenAI API key — never an Anthropic account (and no Claude agent ever gets an OpenAI one) |

  This is checked **before** a sandbox is made. With no account pi can use, Dozer stops and tells you
  the next step (or, on a terminal and in the dashboard, offers to take a key right there).

## Claude Code in a sandbox

Claude Code starts ready to work: its first-run screens are done, the working folder is trusted, and
it runs without asking permission for each command (the VM and its network are the boundary). It
also shows your real plan ("Claude Max") and picks the same default model as on your Mac.

To have it ask first, set `claude.permissions` to `ask`, or for one session:
`doz run NAME -e DOZ_CLAUDE_PERMISSIONS=ask -- claude`. A `claude` run as root always asks.

Inside a sandbox Claude Code never updates itself; the image decides its version (below).

## Accounts — in the terminal

```sh
doz account ls                                    # accounts, state, expiry, which sandboxes use them — never a secret
doz account add work --setup-token --plan max     # paste the token (no echo), or pipe it in
doz account add ci --api-key                      # an API key (prompt or stdin), or --keychain SERVICE
doz account default work                          # every sandbox that follows the default moves to work
doz account use my-app work                       # this sandbox uses work (open sessions switch on their next request)
doz account use my-app default                    # follow the store's default again
doz account verify work                           # one tiny request to api.anthropic.com
doz account rm work                               # also deletes the keychain item Dozer made
doz create my-app --image claude-code --account work
```

A new sandbox follows the store's default account — `mac` out of the box. Sign in to Claude Code on
your Mac once, and every sandbox can use your subscription with nothing to paste.

## Accounts — in the dashboard

**Accounts & keys** lists your accounts with their state and expiry: **Add account** (a masked field
for a key or token, with the plan for a token), **Verify** (or **Make default**) on each row with the
rest — **Remove…** too — under its **⋯**, and keep-alive on or off. A sandbox's page shows its account,
with **Account…** (the details' **Keys** tab) to change it; New sandbox
offers only the accounts its agent can use.

## How the Mac login stays fresh

Dozer reads only the **access token** of your Mac's Claude Code login — never the refresh token — so
your Mac's Claude Code stays the one program that renews it. The access token lives about 8 hours;
Claude Code renews it whenever it runs on your Mac near expiry.

- The host re-reads the login every 2 minutes; a renewed token reaches every sandbox without a
  restart.
- **If it expired** (nothing ran Claude Code on the Mac overnight), Claude Code in the sandbox shows
  "this Mac's Claude login expired at 04:59 — open Claude Code on the Mac (any prompt), then retry",
  and recovers by itself once the Mac renews.
- **Keep-alive** (off by default): `doz account keepalive on`. Near expiry, if a sandbox used the Mac
  login recently and no Claude Code runs on the Mac, the host runs the Mac's `claude` once — one tiny
  turn on your subscription.
- **If you sign out on the Mac**, sandboxes stop getting a token at once. **If a different account
  signs in**, sandboxes on `mac` are held rather than silently switching who pays;
  `doz account use NAME mac` follows the new one.
- **Several Claude config folders:** `doz account add work-mac --claude-login --config-dir ~/.claude-work`.

**No silent fallback:** a missing or expired credential is refused with a message saying what to do.
A sandbox never switches account by itself.

## A credential the agent brings itself

If someone signs in inside the sandbox (`/login`) or pastes a key, the proxy sees it. The **key
policy** decides what happens:

```sh
doz key policy my-app allow     # let it through, and flag it
doz key policy my-app strict    # refuse it (and block the sign-in pages, so /login can't finish)
doz key policy my-app auto      # the default: strict for a token or API-key account, allow for mac
```

With `allow`, `doz key ls` lists the credential's fingerprint (never its value) and `doz ls` marks the
sandbox. Dozer never adds its own credential to a request that carries the agent's.

## A key for one sandbox

```sh
doz key set my-app --anthropic                      # prompt (no echo), or: … < keyfile
doz key set my-app --anthropic --keychain SERVICE   # read it from a keychain item
doz key ls my-app                                   # never the value
doz key rm my-app --anthropic
```

A key typed or piped in lasts while the host runs; after the host stops, set it again (or use
`--keychain`, which is read again by each new host).

## Agent versions

An agent image installs its agent at one exact version, chosen by `images.claude_code_version` and
`images.pi_version`:

- **`latest`** (the default) is resolved **when the image is prepared** — never while a sandbox runs —
  and installed at that exact version, integrity-checked.
- **A newer release is only announced** (`doz image ls`, `doz doctor`, the Images page, `doz create`):
  "Claude Code 2.1.290 is available (image has 2.1.285)". Rebuild when it suits you:
  `doz image bake claude-code`, then `doz reset NAME` for the sandboxes you want on it.
- **An exact version** (`doz config set images.claude_code_version 2.1.227`) never asks the internet,
  so it works offline.

## Sudo inside the sandbox

The agent has **passwordless `sudo`** in its sandbox, so it can install what a task needs:
`sudo apt-get install -y PACKAGE` (Debian-based images keep the package lists, and never stop to
ask configuration questions) or `sudo apk add PACKAGE` on Alpine. Root inside the VM reaches no more
than the agent: there's no network card, every connection still goes through your permissions, no
credential is inside, and nothing of your Mac but the workspace. `doz reset` or a restore point
undoes what it installed.

Turn it off for every sandbox (`doz config set sandbox.agent_sudo false`) or one
(`doz create --no-agent-sudo`, `agent_sudo: false` in `doz_project.yaml`, or
`doz config set --sandbox NAME sandbox.agent_sudo false`). It applies from the next session and boot.

## The agent's environment facts

At every session start, Dozer tells the agent where it is:

- a short **facts block**, added to its system prompt: that it's in a Dozer sandbox (a Linux VM on
  your Mac, not a container) with its name, image, CPUs and memory; whether `/workspace` is your Mac
  folder (and which) or isolated; how its network works and what to do when refused; that its
  credentials are supplied by the proxy; whether it has sudo; its time zone; what the clipboard does;
  one line on what it can show you on your Mac — a URL in your browser, a workspace document in its
  app, a workspace folder in the Finder — saying only what is on (the `dozer` skill has the details:
  types, apps, refusals); and, only when you turned it on, one line saying `git` and `gh` are signed in
  as you on GitHub, read-only or with push ([GitHub as you](18-github.md));
- the **`dozer` skill** (`~/.claude/skills/dozer/SKILL.md`, pi: `~/.pi/agent/skills/dozer/SKILL.md`,
  Codex: `~/.agents/skills/dozer/SKILL.md`),
  which it reads when a question is about the machine: what persists, the network, credentials,
  sleep, and what it can't do from inside (and must ask you for).

```sh
doz inspect my-app --prompt          # exactly what the next session gets
doz config set agent.prompt false    # off: the next session start removes both
```

**Your own words**, in three layers: the built-in text < your **`agent-prompt.md`** (beside
`doz.toml`; text outside an HTML comment replaces the built-in text for every sandbox) < a sandbox's
own (`doz create --agent-prompt FILE`, or `agent_prompt` in `doz_project.yaml`), appended or
replacing (`--agent-prompt-mode replace`). Your text may use `{{variables}}` from a fixed list —
`sandbox.name`, `sandbox.image`, `sandbox.base`, `sandbox.cpus`, `sandbox.memory`,
`workspace.shared`, `workspace.host_path`, `workspace.guest_path`, `workspace.description`, `workspace.rules`,
`network.mode`, `network.allowed_hosts`, `network.description`, `network.permissions`,
`account.name`, `agent.state`, `credentials.description`, `sandbox.sudo`, `sandbox.timezone`, `sudo.description`,
`clipboard.description`, `browser.description`, `files.description`, `mac.open`, `github.facts`, `github.description`, `mac.hostname`, `dozer.version` (the template
`agent-prompt.md` lists them with what each says). `doz inspect NAME --prompt` shows any mistake: an unknown variable is an error that stops the
agent's sessions from starting until it's fixed, never silently blank.

Dozer owns only those two files. The agent's own memory files (`CLAUDE.md`, `AGENTS.md`) are never
touched.

## Settings

| key | default | what it does |
|---|---|---|
| `defaults.account` | `mac` | The account of a store that hasn't chosen one. |
| `host.keepalive` | `false` | Keep-alive for a store that hasn't chosen (`doz account keepalive`). |
| `claude.permissions` | `skip` | Claude Code's own permission prompts in a sandbox: `skip` or `ask`. |
| `images.claude_code_version` · `images.pi_version` · `images.codex_version` | `latest` | The agent version an image is prepared with. |
| `sandbox.agent_sudo` | `true` | The agent's passwordless sudo. Per sandbox too. |
| `agent.prompt` | `true` | Give the agent its facts block and the `dozer` skill. |
| `ui.allow_secret_entry` | `true` | The dashboard may take a key or token. |

## Troubleshooting

| symptom | what to do |
|---|---|
| The agent says it has no key, or gets 401 | `doz key ls NAME` and `doz account ls`. A typed key is gone after the host stopped: set it again, or use an account. |
| "this Mac's Claude login expired" | Run `claude` on your Mac once (any prompt), or turn on keep-alive. |
| pi can't be created: no account it can use | `doz account add NAME --api-key`, then `--account NAME`. |
| "the agent prompt does not render" | `doz inspect NAME --prompt` names the unknown `{{variable}}` and the file. |
| The agent doesn't know where it runs | `doz inspect NAME --prompt`. An image prepared by a much older Dozer may need `doz reset NAME` after a rebuild. |
| `/login` inside the sandbox never finishes | The key policy is `strict` (it blocks the sign-in pages). That's usually what you want; to allow it: `doz key policy NAME allow`. |
