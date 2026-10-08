# CLI reference

Every `doz` command, by task. New to it? <doc:DozerWalkthrough> is a first run, end to end.

## Overview

`doz` runs Linux sandboxes on your Mac that pause in a millisecond, hibernate to disk and wake
in about a third of a second, with the programs inside them still running where they were. It is
the command-line face of `DozerKit`.

```bash
brew install dozer-sandbox/tap/doz   # the prebuilt, signed release: seconds, no compiler (Apple silicon, macOS 26+)
doz onboard                       # once: checks, the Claude account, settings, images (in the background)
```

A VM can only be booted by a binary signed with Apple's virtualization entitlement; the release
carries it. An unsigned build runs every command but cannot boot anything, and `doz doctor` says
so. `brew upgrade doz` installs a new release (safe with a host running — see *The host*);
`brew uninstall doz` removes it.

**From source (contributors):** in a clone of this repository, `make install-cli` (release, signed, into
`~/.local`), `make cli` (a signed debug build at `.build/debug/doz`), and `make release
VERSION=X.Y.Z` — the Homebrew artefact, `dist/doz-X.Y.Z-macos-arm64.tar.gz` and its SHA-256, signed
with a Developer ID and notarised when `Makefile.config` configures one (`SIGN_IDENTITY`,
`NOTARY_PROFILE`), ad hoc otherwise; `DRY_RUN=1` prints its commands. A bare command-line tool
cannot be stapled: Gatekeeper checks a notarised `doz` online the first time it runs.

> This article's command list is checked against the CLI's real subcommand tree by
> `Scripts/docs-drift-check.sh` (`make docs-drift-check`) — see that script for how.

### Setting up: onboard, init, uninstall

```bash
doz onboard [--images claude-code,pi,lab | --all-images | --no-images] [--account mac|api-key|setup-token|later] [--yes]
            [--account-name NAME] [--plan PLAN] [--secret-stdin] [--force]
            [--github off|read|push] [--github-source gh|key] [--github-key-stdin] [--ssh-agent on|off]
            [--ignore-mode lock|hide]   # the Workspace rules step: the default workspace.ignore_mode
doz onboard --status        # the onboarding record and the images; follows a preparation that runs
doz onboard --cancel        # cancel the images being prepared
doz init [DIR] [--name N] [--image I] [--cpus N] [--memory M] [--network …] [--permissions W] [--account A]
         [--github off|read|push] [--ssh-agent on|off] [--ignore-mode lock|hide] [--clipboard …] [--browser-bridge …]
         [--open-files …] [--[no-]tmux] [--[no-]agent-sudo] [--yes] [--force]   # 599f: on a terminal, the wizard's 10 steps
doz up                      # in a folder with doz_project.yaml (or .yml): that project's sandbox
doz uninstall [--keep-store] [--keep-config] [--yes]
```

- **`onboard`** sets up this Mac, once: the doctor's checks (a *required* one that fails —
  not Apple silicon, macOS too old, no virtualization, the entitlement, the store not on APFS, too
  little disk for the chosen images — stops it; the rest only warn), **Access** (every
  credential sandboxes may use as you, each a purposeful choice and each **confirmed live**; see
  [Access](#Access) below): the **Claude account** (this
  Mac's Claude Code login when it is signed in; otherwise an API key or a setup token **pasted at a
  hidden prompt** and stored exactly as `doz account add` stores it — the login keychain, one tiny
  check request, `--plan` for a token — then made the default; or **Decide later**. It never logs in
  and never copies Claude Code's refresh token. Off a terminal a key is read from stdin only with
  `--secret-stdin`; otherwise that step is skipped and the command shown), **GitHub as you**
  (off, read-only or read and push; the token from this Mac's gh login or a key you give —
  `--github`, `--github-source`, `--github-key-stdin`) and **SSH agent forwarding** (`--ssh-agent`);
  each is confirmed, and one that cannot be is **skipped with its reason** — the choice kept, not
  confirmed — so the onboarding never blocks (`--yes` or no terminal: skipped with a note, exit 0).
  The GitHub and SSH choices are written as the defaults for new sandboxes even into an existing
  settings file, but only when chosen (a flag, or answered on a terminal) — `--yes` alone changes
  nothing. Then the settings file and your prompt template (each written **only when
  missing**), then **prepares the images** — the kernel, the guest init disk, the base image and
  the bake, the waiting a first start would do. `claude-code` is prepared by default; `pi` and
  `lab` are opt-in. The preparation runs **in the host**: Ctrl-C detaches (it goes on; `--status`
  follows it again, `--cancel` stops it), and a `start` of that image meanwhile **joins it** —
  one download, one bake. On a terminal it asks, the recommended answer pre-selected (Enter keeps
  it); `--yes`, `--json` or no terminal ask nothing. Re-running is safe: it prepares only what is
  missing. The store records it in `<store>/onboarded.json`.
- **`init`** makes a folder a project: it writes **`doz_project.yaml`** (onboarding this Mac
  first if it never was). **`up` with no name**, in that folder, creates, starts or wakes exactly
  that sandbox, with the folder at `/workspace`, starts its `sessions` and attaches to the first.
  The file is YAML with a closed set of keys — `version`, `name`, `image`, `cpus`, `memory`,
  `network`, `account`, `sessions`, `agent_prompt`, `agent_prompt_mode`, `agent_sudo`, `clipboard`, `browser_bridge`, `tmux`; an unknown key or a bad
  value is an error naming its line.

  ```yaml
  version: 1
  name: webapp
  image: claude-code
  memory: 4G
  sessions:
    - claude
    - name: server
      command: npm run dev
  agent_prompt: |
    The tests run with `make test`; never push to main.
  ```
- **`uninstall`** lists exactly what it removes — the store (every sandbox and image), the
  settings directory, and the installed `doz` (`<prefix>/libexec/doz/` and the `<prefix>/bin/doz`
  link) — and asks once (no terminal and no `--yes`: it refuses). It never touches the keychain
  (it names the items `doz account add` made, and how to remove them) or Claude Code's own files.

### The lifecycle

See <doc:Concepts> for what each word means.

| command | does | typical time | RAM | programs |
|---|---|---|---|---|
| `start NAME` (`cold-boot`) | boots; wakes it if asleep, resumes it if paused | ~0.4 s | allocated as used | start fresh |
| `pause NAME` (`suspend`) · `resume NAME` | stops the guest CPU | ~1 ms | kept | frozen, then continue |
| `sleep NAME` · `wake NAME` | pause + snapshot to disk; survives the host crashing | ~0.3 s | kept | continue |
| `hibernate NAME` · `wake NAME` | snapshot, then the VM stops | ~0.35 s / ~0.3 s | **returned** | continue: same PIDs, same screens |
| `shutdown NAME` | a cold stop; the disk is kept | | returned | end |
| `reset NAME` | shut down and go back to a fresh copy of the image (restore points and the agent's state disk stay) | | | end |
| `rm NAME` | remove the sandbox and everything it has on disk | | | end |

`shutdown`, `reset` and `rm` ask first; `--yes` skips the question; with no terminal and no
`--yes` they refuse (exit 5). A program started less than 3 s before hibernating gets the rest of
those 3 s first (Claude Code's first network calls, for example, can otherwise fail on wake).

### Creating and entering sandboxes

```bash
doz new [--image I] [--name N] [--isolated] [-d]     # 599c: every default — created, started, attached
doz create NAME --image lab|claude-code|pi|<base>-<agent>|<template> \
    [--cpus 2] [--memory 2G] [--workspace ~/code/proj | --isolated] \
    [--network agent|bake|locked|open|nat|none] [--subnet CIDR]
doz create NAME --agent claude-code|pi|codex|none --base node|python|go|rust|java|ruby|dotnet|debian|ubuntu|alpine
doz create NAME --agent claude-code --dockerfile ./Dockerfile      # 596: your own base (workspace = its folder)

doz up NAME [same options] [--session S] [-d] [-- CMD …]
```

- **599c: `doz new` — the quickest way in.** The image is `defaults.image`; the name is the image's
  (`claude-sandbox`, then `-2`, `-3`, … when a sandbox has it or its folder under the projects folder
  is not empty); the workspace is `<defaults.projects_dir>/<name>`, made now; the default account and
  permissions. It prints what it chose (`claude-sandbox-2 · claude-code · ~/dozer-sandbox-workspaces/claude-sandbox-2`),
  starts it and attaches. `--image`, `--name`, `--isolated` and `-d` change just that one thing;
  `--json` answers `{name, image, workspace, phase, session, milliseconds}` without attaching. The
  prerequisites are `doz create`'s (pi's API-key account, an out-of-date image) — asked on a terminal.
  The web UI's **Quick add** is the same.
- **596: two choices — the agent and the base.** `--agent` (Claude Code, pi, or none: a shell only)
  and `--base` (a recommended base: `doz base ls`) name the image `<base>-<agent>`
  (`python-claude-code`, `go-pi`; `debian` for no agent). The three old names stay:
  `claude-code` = Node · Claude Code, `pi` = Node · pi, `lab` = Alpine · none — `--image claude-code`
  is the shorthand for `--agent claude-code --base node`. The image is the base + the developer
  baseline (apt or apk) + the agent: Claude Code on a base without Node is its standalone native
  build (downloads.claude.ai, `latest` resolved at preparation, sha256-checked — no Node added for
  it); pi gets Node under `/opt/node` (Node's official tarball, checksum-verified; Alpine's own
  `nodejs`), on pi's PATH only. A base's language registries join the sandbox's policy (Go's module
  proxy, crates.io, Maven Central, RubyGems, NuGet). Each base's tag is resolved to a digest when an
  image is prepared (hourly after; the catalogue's pin offline) and `image ls` says when the tag has
  moved on — never rebuilt by itself.
- **`--dockerfile PATH`**: your Dockerfile is the base, built with Apple's `container build`
  (installed on demand — `doz builder`), and Dozer still adds the baseline and the agent (you need
  not install Claude Code in it). Its folder is the build context and, unless `--workspace` says
  otherwise, the workspace. **The build runs in Apple's builder, OUTSIDE Dozer's network policy:**
  its `RUN` steps reach the internet directly. Every preparation builds it again (Apple's cache
  makes an unchanged one take seconds) and re-bakes only when the built image's layers changed; a
  sandbox says "Dockerfile changed — rebuild available" and keeps its disk until `doz reset`.
- **`doz_project.yaml`** takes `agent:`, `base:` and `dockerfile:` (relative to the project folder)
  instead of `image:`.

```bash
doz base ls                    # the recommended bases: image, digest, download, first prepare, registries
doz builder status             # Apple's container tool: missing, stopped or ready — and what each step does
doz builder install [--yes]    # Apple's signed package (pinned, sha256-checked) opened in macOS Installer; never sudo
doz builder start [--yes]      # container system start --enable-kernel-install (launchd services, its kernel)
```

- **`up`** is the everyday command, in the manner of `vagrant up` and `docker compose up`: create
  if missing, start or wake, then attach to the image's own session (`claude`, `pi`, or a
  `bash -l` shell called `shell`), opening it if needed. `-d` does all that without attaching;
  `-- CMD …` opens a new session running `CMD` instead.
- On an existing sandbox, `up`'s create options are ignored (and it says so) — a sandbox keeps the
  image and settings it was created with. `up` defaults to the settings' `defaults.image`
  (`doz onboard` sets it; `lab` otherwise); `create` requires `--image`. With no NAME, in a
  project folder, `up` uses `doz_project.yaml`.
- **`--workspace DIR`** is made when it does not exist (`mkdir -p`; `[doz] created ~/…`) — never an
  existing file, a folder in the store, a system location, `/` or the home folder itself; a folder
  doz made is removed again, while empty, if the create fails.
- **Without `--workspace`** the sandbox is **isolated**: `/workspace` is private to the VM — nothing
  on this Mac is shared. That is allowed, and said: `create` notes it, `ls` shows `isolated`
  (`--json`: `"workspace": null, "isolated": true`); `--isolated` asks for it on purpose.

### Working inside

| command | what |
|---|---|
| `attach NAME [SESSION] [--no-wake]` | Your terminal becomes that session. **Ctrl-]** opens a one-line menu over the bottom row (`d detach · n next · p prev · s sessions · Esc back`; n/p/s move this terminal to another session of the sandbox; removed by a clean redraw from the session's snapshot); a second Ctrl-] (quickly, or at the menu) detaches — in every keyboard encoding (`--detach-key ctrl-x\|none`; a pipe on stdin detaches at once). The terminal's title is `ui.terminal_title` (`{sandbox} · {session} · {time}`; `{image}` `{phase}` too), refreshed each minute, the terminal's own pushed and popped (CSI 22/23 t); the session's own title is kept out meanwhile (`""`: leave it to the session). A paused or sleeping sandbox wakes first unless `--no-wake`. Hibernated while attached: the client waits and reattaches by itself on wake. |
| `run NAME [--session S] [-d] -- CMD …` | A **new** session running `CMD`, attached; exits with `CMD`'s exit code. No shell in front — write `bash -lc '…'` for one. |
| `exec NAME [--user U] [--workdir D] [-e K=V] [--timeout S] -- CMD …` | One-shot, no terminal: stdout, stderr and the exit code pass straight through (default timeout 120 s). Agent images run as the agent's user in `/workspace`; `--user root` for root. A sleeping sandbox is woken and an off one started first (594; `--no-wake`, `--no-start`; `--json` has `started`, `woke`, `bootMilliseconds`) — `run` starts one too. |
| `sessions NAME` | The sandbox's terminal sessions. |
| `sessions restart NAME SESSION [--fresh] [-d]` | End the session's program and start the same one again, in the same session and folder (an agent's own session continues its conversation; `--fresh`: a new one), then attach. Running sandboxes only. |
| `sessions end NAME SESSION` | End the session's program (hung up, then terminated, then killed). |
| `ls` · `inspect NAME` | Every sandbox: image, phase, RAM held, disk, sessions, network · everything as JSON. |

**RAM held** in `ls` is what the VM costs the Mac right now: the allocation, less what the memory
balloon returned after a wake — shown as `—` when the sandbox is off or hibernated.

### Session bridges

The host reads every attached terminal's output (`attach`/`run`/`up`, `doz ui`) for the sequences a
bridge owns and takes them out; each use is shown as a notice (over the bottom row for 3 s, then a
redraw; a toast in `doz ui`; a stderr line off a terminal). A bridge acts only while a terminal is
attached.

- **Clipboard (599):** OSC 52 copies reach the Mac clipboard — `SANDBOX copied N chars`. A READ is
  never answered and never reaches the outer terminal (logged once per session). 1 MiB per copy, 10
  copies per 10 s per sandbox. `sandbox.clipboard = write | off`; per sandbox with
  `doz config set --sandbox NAME sandbox.clipboard off`, `doz create --clipboard off`, or
  `clipboard: off` in `doz_project.yaml`. The risk — an agent can put a command on the clipboard — is
  why every copy is shown, and why the agent's facts say so.
- **Browser and sign-ins (599):** the guest's `xdg-open` (`$BROWSER`, `open`, `sensible-browser`;
  `/usr/local/lib/doz/bin`, first on every session's PATH, written at each boot) hands an http(s)
  URL to the Mac's default browser — `SANDBOX opened https://… in your browser`. A URL whose
  `redirect_uri` is `http://localhost:PORT` or `127.0.0.1:PORT` (1024–65535) gets the Mac's
  `localhost:PORT` forwarded into the sandbox's (each connection a guest `deckhold connect -p PORT`)
  until 3 s after the callback was answered, 10 min at most; one per sandbox. Refused: other
  schemes, the Mac's own loopback, > 3 per 10 s, > 2048 bytes. `sandbox.browser_bridge = on | off`,
  per sandbox as the clipboard (`--browser-bridge`, `browser_bridge:`). A login shell finds the shim
  through `/etc/profile.d/doz-browser-bridge.sh`.
- **tmux (599):** `sessions.tmux` (default off; `doz create --tmux`, `tmux: true`, per sandbox) runs each
  new session as `tmux -L doz-SESSION -f /usr/local/lib/doz/tmux.conf new-session -A -s SESSION CMD…`
  inside deckhold: attach/detach, sleep/wake, saved screens, browser terminals and both bridges keep
  working (mouse on, set-clipboard on). Limits: Ctrl-b and the mouse are tmux's; the kitty keyboard
  protocol and modifyOtherKeys do not fully pass through; the exit code is tmux's. No tmux in the
  image (an older doz's): the session runs without it and `run`/`up` say so.

### Agents, keys and accounts

The agent images (`claude-code`, `pi`) run as a normal user in `/workspace` and keep the agent's
login and history on a separate **state disk**, which survives shutdown, reset and re-bakes.
**Claude Code starts ready to work**: its launcher marks first-run setup done and passes
`--dangerously-skip-permissions` (the VM, proxy and key vault are the boundary). Keys never enter
the sandbox — inside it, `ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN` is a `doz_cred_…`
placeholder, never a command-line argument.

`-e DOZ_CLAUDE_PERMISSIONS=ask` (on `run`/`exec`) keeps Claude Code's own prompts; a `claude`
run as root always keeps them.

### The agent's environment prompt

At every session start the host tells the agent where it runs, from the sandbox's **current**
facts: a short **facts block** — a Dozer Sandbox VM (not a container) on the user's Mac, its name
and size, `/workspace` shared from the Mac folder *X* or **isolated** (no folder is shared with the Mac), the network (deny by
default through the Mac's proxy; a refused host needs the user's rule), credentials (injected; never
log in) — appended to the agent's system prompt (Claude Code's launcher passes
`/run/dozer/agent-prompt.md` with `--append-system-prompt`; pi's session gets
`--append-system-prompt /run/dozer/agent-prompt.md`), and the **`dozer` skill**
(`~/.claude/skills/dozer/SKILL.md`, pi: `~/.pi/agent/skills/dozer/`) with the details: what persists,
restore points, the network policy, sleep and hibernation, and what the agent cannot do from
inside. Dozer writes only those; the agent's own `CLAUDE.md` / `AGENTS.md` are never touched.

```bash
doz inspect NAME --prompt                           # what the next session gets (or why it does not render)
doz create NAME … --agent-prompt FILE [--agent-prompt-mode append|replace]
doz config set agent.prompt false                   # off: no facts block, no skill (removed at the next session)
doz create NAME … --no-agent-sudo                   # 594: no passwordless sudo for this sandbox's agent
doz config set sandbox.agent_sudo false             # …or for every sandbox without its own choice (next session / boot)
```

The agent has **passwordless sudo** by default (594, owner ruling): `sudo apt-get install -y PKG`
works in a fresh claude-code or pi sandbox (the images keep apt's package lists; the `agent` preset
allows Debian's archive). The rule is written at every boot and agent session start from the
sandbox's choice (`--no-agent-sudo`, `agent_sudo` in `doz_project.yaml`) or the setting — no image
is rebuilt to change it. Root inside the VM reaches no more than the agent: no network interface,
the same proxy and policy, no credential inside. (594 rebuilds the agent images once.)

Three layers: the built-in template, then **your own** — `agent-prompt.md` beside `doz.toml`
(`doz onboard` writes it all commented out; text outside a comment replaces the built-in one) — then
the sandbox's own (`--agent-prompt FILE`, or `agent_prompt` in `doz_project.yaml`), appended or
replacing. Variables are `{{name}}` from a closed list (`sandbox.name`, `sandbox.image`,
`sandbox.cpus`, `sandbox.memory`, `workspace.shared`, `workspace.host_path`, `workspace.guest_path`,
`workspace.description`, `network.mode`, `network.allowed_hosts`, `network.description`,
`account.name`, `credentials.description`, `mac.hostname`, `dozer.version`); an unknown one is an
error — the session does not start, and `inspect --prompt` says why — never silently blank. A
claude-code image baked before 594 has no launcher support: `doz reset NAME` (or a new sandbox)
takes the new image.

### Accounts

A proxied sandbox uses one **account**: `mac` (this Mac's own Claude Code login, read-only,
renewed by the Mac's Claude Code), `setup-token` (`claude setup-token`, valid one year, in the
keychain), or `api-key` (an Anthropic API key).

```bash
doz account ls                                   # accounts, state, expiry, which sandboxes use them
doz account add work --setup-token --plan max    # paste the token (no echo), or pipe it in
doz account add ci --api-key                     # an API key (prompt or stdin), or: --keychain SERVICE
doz account use NAME work                        # this sandbox uses work
doz account use NAME default                     # follow the store's default again (none: no credential)
doz account default work                         # every sandbox on the default moves to work
doz account verify work                          # one tiny request to api.anthropic.com
doz account rm work [--force]                    # also deletes the keychain item doz made
doz account keepalive on                          # off by default: runs `claude -p` near expiry
doz create NAME --image claude-code --account work
```

A new proxied sandbox follows the store's default account (`mac` out of the box); Claude Code in
the sandbox shows the real plan (`CLAUDE_CODE_SUBSCRIPTION_TYPE`); there is **no silent fallback**
— a missing, expired or held credential is refused with a message saying what to do, never
switched to another account or an API key by itself. `doz key set NAME --claude-login` is
still `account use NAME mac`.

**Each agent says which accounts it can use** (``AgentImages/credentials(_:)``): Claude Code — `mac`,
`setup-token`, `api-key`; **pi — an `api-key` account only** (it reads `ANTHROPIC_API_KEY`, the
proxy's placeholder; a Claude subscription is never given to it). A create, `up`, `init` or
`duplicate` of pi with no such account stops before anything is made, saying what to do (`doz
account add NAME --api-key`, or `--account NAME`); on a terminal it offers the accounts that fit or a
hidden paste of a key. `--account none` is an explicit choice. The web forms offer only the accounts
that fit (the key field in the form when none do); an existing sandbox whose account does not fit
shows a banner with a picker, and its agent is told that no credential is attached.

### Access

Every credential sandboxes may use as you, in one place — the onboarding's Access step, again
whenever you like:

```bash
doz access                                       # each choice and its state, after a LIVE check (= doz access show)
doz access --no-check                            # the last confirmation only (starts no host)
doz access set --github read                     # new sandboxes: git and gh signed in as you, read-only (push: also push)
doz access set --github push --github-source gh  # the token from this Mac's gh login (gh auth token)
doz access set --github read --github-key        # a token you give (no-echo prompt, or stdin): github.credentials = key
doz access set --remove-github-key
doz access set --ssh-agent on                    # forward this Mac's ssh-agent (github.com only)
```

- **Claude account** — the store's default account: this Mac's login is checked signed in; a key
  or a token gets the account check `doz account verify` makes. Choose it with `doz account default`.
- **GitHub as you** — `defaults.github` (`off`, `read`, `push`) with `github.credentials` (`gh` or
  `key`). The check reads the token the way a sandbox gets it, then asks `GET
  https://api.github.com/user` over the proxy's own TLS leg: **signed in as LOGIN** and the classic
  token's scopes, or — for a fine-grained token — how many repositories it can see.
- **SSH agent forwarding** — `sandbox.ssh_agent`: the Mac's ssh-agent is asked for its keys (what
  `ssh-add -l` shows): "the ssh-agent has N keys".

A check that fails says why and **keeps the choice** (not confirmed) — `doz access set` turns it
off. The last answers are in `<store>/access.json` (states and reasons, never a token); an answer
counts only for the choice it was given for. The default GitHub key is in the login keychain as
`doz-github` (a sandbox's own `doz key set NAME --github` wins over it). The choices are the
**defaults for new sandboxes** — `doz new`, `create`, `up`, Quick add, the forms; one sandbox can
differ (`doz create --github off|read|push`, `--allow`/`--network`, `doz net allow|deny NAME
github:as-you`, `doz config set --sandbox NAME sandbox.ssh_agent on`).

### Workspace rules

```bash
doz ignore check NAME PATH…  # what each path is in the sandbox (locked, hidden, read-only, visible) and which line decides
doz ignore show NAME         # every rule with its line, the mode, warnings, whether the rules are in force now
```

A `.dozignore` at the root of a sandbox's workspace folder (Docker's `.dockerignore` syntax and
`docker build`'s semantics: anchored at the root, `**` for any depth, `!` exceptions, the last match wins)
selects paths the agent must not use — `workspace.ignore_mode` `lock` (the default: listed with no
permissions, every access refused, root too) or `hide` (not there). A `.dozreadonly` (same syntax) makes
paths read-only; `doz_project.yaml`, `.git/hooks` and the two rule files are read-only too. Names are
compared without case or Unicode form on a case-insensitive Mac volume. Served by a filtering view
inside the sandbox; no rule file, no view. `doz create`/`up`/`start` warn when a rule locks `.git` or
git-tracked files. Not a security boundary: root in the sandbox can get around it.

### The tools layer

```bash
doz tools NAME             # the tools Dozer manages in NAME from its settings: each one, why, its state
doz tools NAME --apply     # set them up again now (NAME must be running), shown as steps
```

The **tools layer** — tools a sandbox gets because of its settings, on every base, with no image
rebuild: `gh` for "Use GitHub as you" (a pinned linux-arm64 release, downloaded ONCE to the store's
`tools/` and accepted only with its pinned sha256, then copied in — no guest network; at
`/usr/local/lib/doz/bin/gh`, linked as `/usr/local/bin/gh` when free; removed when the setting is off), an
ssh client and github.com's published host keys (`/etc/ssh/ssh_known_hosts`, a managed block) for SSH
agent forwarding, tmux for `sessions.tmux`, and always git, curl and ca-certificates — packages from
apt/apk through the proxy, only when missing. A sandbox's first start shows each tool as a progress step
(`tools: gh 2.102.0 — for GitHub as you`); later starts and wakes re-check quietly (a setting turned on
while it slept is delivered then); never fatal. An image's preparation never runs it.

### A credential the guest brings itself

```bash
doz key policy NAME allow    # pass it, and flag it
doz key policy NAME strict   # refuse it (and deny the sign-in hosts too)
doz key policy NAME auto     # default: strict for a setup-token/api-key account, allow for mac
```

`allow` shows in the net log as `own credential (…, fp ab12cd34ef56)` — a fingerprint, never the
value — and flags the sandbox in `ls`/`key ls`. `strict` refuses with 403 and denies the Claude
sign-in hosts too, so a guest `/login` cannot finish.

### Keys given directly

```bash
doz key set NAME --anthropic                       # prompt (no echo), or: … < keyfile
doz key set NAME --anthropic --keychain SERVICE    # read from a keychain generic password
doz key ls NAME                                    # keys, account, state, expiry, policy, foreign fingerprints
doz key rm NAME --anthropic
```

A key from stdin or the prompt lasts only while the host runs — set it again after `host stop`.
Sessions survive a host restart with their credentials (a sha256 of each live placeholder is kept,
never the placeholder itself); `shutdown`, `reset` and `rm` revoke them.

### Network

A sandbox has **no network card**. Its only way out is a proxy in the host that checks every
connection against a policy and logs it.

| `--network` | allows | default for |
|---|---|---|
| `agent` | Anthropic's API and sign-in hosts; what Claude Code reaches on its own (`downloads.claude.ai` for updates, its two Datadog error-reporting intakes `http-intake.logs.us5.datadoghq.com` and `browser-intake-us5-datadoghq.com`); GitHub over HTTPS for git and Claude Code's plugin marketplace (`github.com`, `raw.githubusercontent.com`, `codeload.github.com`, `objects.githubusercontent.com`); `pi.dev` (pi's updates); plus package registries — never `api.github.com` (`fd` and `rg` are in the image) | `claude-code`, `pi` |
| `bake` | package registries only (npm, apt, apk, PyPI) | `lab` |
| `locked` | nothing | |
| `open` | everything, still proxied and logged | |
| `nat` | a normal NAT network card, not proxied, no log | |
| `none` | no network at all | |

**What the agent can do (597).** A proxied sandbox's policy is a set of plain-language
**permissions**, each a switch: *Talk to its AI model* (`model`, always on), *Sign in* (`sign-in`),
*Update itself* (`update` — downloads.claude.ai, pi.dev, the agents' own npm packages), *Install
software* per ecosystem (`install:system` apt/apk, `install:node`, `install:python`, `install:go`,
`install:rust`, `install:java`, `install:ruby`, `install:dotnet`; `install` = all), *Use GitHub*
(`github`), *Send error reports* (`error-reports` — Claude Code's Datadog intake), *Browse the web*
(`web`, any site — warns first), plus sites you allow (`site:HOST`). Presets are combinations:
**locked** = the model only; **standard** (`agent`) = model, update, system packages + the base's
language packages, GitHub, error reports; **open** = everything. A policy stores the permission
NAMES — the hosts behind them come from the running doz, so an update that adds a host reaches every
sandbox that has the permission. Your own site rules win over permissions. `--network bake` stays a
policy of rules (image preparation).

```bash
doz net NAME                                         # the checklist (= doz net show NAME), and what was refused lately
doz net allow NAME install:python site:api.example.com   # live; web / open ask first (--yes)
doz net deny NAME update github site:example.com
doz net allow NAME standard|locked|open              # a preset
doz net permissions                                  # every permission, what it means, its hosts
doz create NAME --allow web,site:api.example.com --allow=-error-reports   # on top of defaults.permissions
doz net policy NAME                                  # the raw rules (every rule evaluated, yours first)
doz net policy NAME --allow github.com --allow '*.githubusercontent.com'
doz net policy NAME --deny example.com --remove github.com
doz net policy NAME --preset open
doz net log NAME [--denied] [--follow]              # host, verdict, rule, bytes; never contents
```

A refused connection to a known permission's host is offered as "the agent tried to install Python
packages (PyPI) — doz net allow NAME install:python"; an unknown host as `site:HOST`. The setting
`defaults.permissions` (standard · locked · open, or `+web,-error-reports`) is what a new proxied
sandbox gets. A name the policy cannot allow does not even resolve. Current limits: IPv4 only, HTTP/1.1 on hosts
the proxy decrypts, UDP refused, no port forwards from the Mac into a sandbox yet.

### Restore points and images

Restore points are instant, disk-only copies (APFS clones) — they cover the disks, not memory.

```bash
doz point take NAME [POINT] [--note …]      # a running sandbox pauses for milliseconds
doz point ls NAME
doz point revert NAME POINT                 # shuts down; a "before revert" point is taken first
doz point fork NAME POINT NEWNAME           # a new sandbox from that point (cold-boots on start)
doz point rm NAME POINT
doz point save-image NAME [POINT] --as myimage [--note …]    # a custom image (a template)
doz up other --image myimage
# 594: a POINT is its name (≤ 64 characters, stored as typed — longer is refused), its id, or the start
# of either when only one point matches; revert / rm check the point exists BEFORE asking.

doz image ls                   # built-in images and templates, whether each is baked here (for this build),
                               # and an agent image's version: claude-code 2.1.227 (2.1.285 available — preparing)
doz image ls --tree            # the lineage: OCI base → image → template → sandboxes, with sizes
doz image bake claude-code     # prepare it now (joins a preparation already running; minutes, needs network)
doz image rm NAME              # sandboxes already made from it keep working
```

`image pull` / `push` answer "not yet" (exit 7). `image ls --tree` shows each disk's size, the
bytes it shares with its parent (APFS clones) and its own (what removing it frees).

**Agent versions.** `images.claude_code_version` and `images.pi_version` are `latest` (the default)
or an exact version. `latest` is resolved when the image is PREPARED — one npm registry lookup
(remembered for an hour, `<store>/agent-versions.json`) for the version and its sha512 integrity;
the bake installs that exact version, integrity-checked, and the version is in the image spec and
its bake key. A create or a first start uses the image already prepared. 594 W28 (owner ruling): an
image is never rebuilt by itself — a newer release, or an image an older doz made ("prepared by an
older doz — this doz's image adds: sudo, package lists"), is said by `image ls` (STATUS), the Images
page, `doctor` and `create` (`--rebuild` / `--use-current`; a terminal asks); `doz image bake NAME`
rebuilds (existing sandboxes keep their disks; new ones and `doz reset` use it). Offline, the
prepared image is used; `latest` with no image and no network fails, naming an exact version to set.
A sandbox keeps its root disk: `doz reset NAME` moves it to the image's current version. Claude Code
never updates itself inside a sandbox (`DISABLE_AUTOUPDATER`, `DISABLE_UPDATES`).

### Templates and duplicates

```bash
doz template create NAME [--from-point P] --as TEMPLATE [--note …]   # the root disk, now (a live sandbox pauses for ms) or a point's
doz template ls
doz template rm TEMPLATE [--yes]
doz create other --image TEMPLATE

doz duplicate NAME NEW [--from-point P] [--workspace DIR | --isolated] [--cpus N] [--memory M]
                       [--network agent|bake|locked|open|nat|none] [--account A] [--copy-state]
```

A **template** is a sandbox's ROOT disk saved as an image: everything installed or written there
(`/root`, `/etc`, `/usr`, `/opt`, caches) — **never its state disk** (the agent's logins and
history). **Duplicate** makes a new sandbox from an existing one's disk (an APFS clone) with a new
name and any of a new workspace (made when it does not exist) or `--isolated`, CPUs, memory, network or
account; its state disk starts fresh unless `--copy-state`. Keys are not copied.

### Resources

```bash
doz resources [ls] [--json]                        # everything Dozer uses: disk to the byte, memory, CPUs, traffic, kernels
doz resources rm ID… [--dry-run] [--yes] [--json]  # delete what can go (ids as doz resources lists them)
doz resources clean [--dry-run] [--yes] [--json]   # the safe set: re-creatable AND unused
doz resources kernel kernel:VERSION|pinned          # the kernel NEW sandboxes boot
```

`doz resources` is an **account**: every byte of the store is on a row — sandboxes (root disk, state
disk, snapshot, restore points, saved screens, boot logs), images and templates, caches (the download
cache, base disks, the guest init, kernels, preparation leftovers), logs and metrics, stray files,
Dozer's own records — and the total is what `du` counts; a last row, **unattributed**, is what no
row explains and should be 0. Each row has three numbers: its **size** (allocated, as `du` counts
it — an APFS clone in full each time), what deleting it **frees** (the blocks only it holds —
a clone frees only what it does not share) and what **uses** it. Outside the store it shows the
settings file, the keychain entries (names only), the CLI and the project folders — never deleted
here. Then the memory each sandbox with a VM holds (after the balloon), the host's and the UI's, the
CPUs given to sandboxes, each sandbox's proxy traffic (today and in all) and the kernels (version,
digest, size, current, and the snapshots that need each).

`rm` and `clean` first show the plan — each item, what it frees, what it costs later
("re-prepared when next needed (about 3 min, needs network)") and what is refused and why — and ask
once (`--yes` skips it; `--dry-run` deletes nothing). The deletion runs in the host as one operation,
waiting until nothing that uses the store's disks is under way. What is refused: a sandbox and its
disks (remove it with `doz rm`), anything outside the store, Dozer's own records; the current kernel
and the guest init while any sandbox is paused, asleep or hibernated (their snapshots need them —
allowed once all are off); an image while it is being prepared (and the download cache and base
disks while any is); a stray folder that is a sandbox's workspace. Restore points, saved screens and
boot logs are deletable; templates too, with a warning that they cannot be re-created; logs are
cleared and metrics' history is cleared. **clean** deletes only what is re-creatable and unused — the
download cache, base disks, kernels no snapshot needs and new boots do not use, images no sandbox was
created from in `resources.clean_unused_days` (30) days, leftovers — never templates, sandboxes,
restore points, logs, settings or keys. `resources kernel` changes `kernel.path`: it applies to
sandboxes created from now on; existing ones keep theirs, and a wake keeps its snapshot's kernel.
`doz image rm` stays as it was.

### The host

```bash
doz host [--foreground] [--idle-timeout MIN]   # run it by hand
doz host stop                                    # hibernates everything running (a line each, then a summary), then exits
doz host restart                                 # stop it (sandboxes hibernate) and start it again — on this doz's build, after an update
doz host status                                  # is one running, and what does it hold? never starts one
doz host upgrade-check                           # after an upgrade: is a host of an older build still running?
```

**Upgrades.** `brew upgrade doz` (or `make install-cli`) puts the new build next to the running
one; the host keeps running its own copy until `doz host stop`, and Homebrew's post-install runs
`doz host upgrade-check` to say so. When Homebrew then removes the previous version (`brew
cleanup`), the running host and its sandboxes keep running, but a start, a wake or a new sandbox is
refused plainly ("this host's program … is gone — `doz host stop`, then retry"), and the host
exits by itself once nothing runs.

Started for you by the first command that needs it; runs detached (`<store>/host.log`,
`<store>/host.sock`); exits after 5 minutes idle (`$DOZ_HOST_IDLE`, 0 = never). `ls`,
`inspect`, `point ls`, `image ls`, `net policy` (shown) and `key ls` read the store directly when
no host runs, so **looking never starts one**. If it crashes, the next command starts a new one:
sleeping sandboxes are restored with their sessions, hibernated ones are untouched, and running
ones are reported as died with their disk checked at the next start.

### Updates

```bash
doz update --check                               # is a newer doz available on your channel? (exit 10 when it is)
doz update                                       # install it: brew upgrade for Homebrew, the signed download for a tarball install
doz update --channel beta                        # switch channel (stable, beta, canary) — for Homebrew, the formula
```

doz looks for a newer release at most once a day (and when `doz ui` starts) in a feed signed with Dozer's own
key, and installs only what verifies — never an older build. The setting `updates.mode` decides what happens:
`notify` (the default — one line on your terminal and a banner on the dashboard, with the command to run), `auto`
(it also installs the update, only while no sandbox runs and no session is attached; then: restart to apply,
`doz host restart`) or `off`. `updates.channel` is stable, beta (beta and stable releases) or canary (every build
first); a Homebrew install has one formula per channel — `doz`, `doz-beta`, `doz-canary` — and `doz update
--channel` switches between them, keeping your store, sandboxes and settings. Never with `--json`, `-q`, or when
not on a terminal.

### The web UI

```bash
doz ui [serve] [--open | --no-open | --print-url] [--new-link] [--store DIR]   # a local dashboard for everything above; Ctrl-C stops it
doz ui link [--rotate] [--store DIR]                  # a fresh one-use sign-in link for the running UI
```

One UI per store, one tab (594 W19): `doz ui` while one runs reuses it, opening a tab only when none
of its pages is open; a restarted `doz ui` takes the store's last port and keeps its pages' sessions
(`<store>/ui.sessions`, 0600; the cookies' digests, never the cookies), so an open page reconnects by itself and no tab
opens. `ui.open_browser` = `auto` (default) | `always` | `never`; `--open` / `--no-open` override it.
`--new-link` (or `doz ui link --rotate`) signs every page out for a new link. The page watches the host
(594 W18): its footer shows the link to `doz ui` and the host's state and build, and a banner says when
the host stopped (hibernated; Start host), died (the sandboxes that were running are shut down) or
came back as another build — and, when the host and `doz ui` differ, which is the older (594 W20: an
older host gets Restart host, which hibernates its sandboxes and starts `doz ui`'s build; an older
`doz ui` is to be restarted). While `doz ui` itself is gone the page is paused under an overlay (594
W21) and reconnects by itself; the banners stay in front of it.

A browser dashboard for sandboxes, images, accounts, metrics, activity and doctor, with the
lifecycle and every other action. Each sandbox has its own page (a child of Sandboxes in the
navigation): a control bar, its terminals filling the page, and a details panel. **All sessions**
is a grid of live, read-only views of every session; **Images** has a Lineage view, and both views show
each image's own and shared size and %; **Resources** is `doz resources` as a page (its total in the
navigation), with multi-select, one confirmation and **Clean up**; **Operations**
lists what the UI asked the host to do. It listens on `127.0.0.1` only. Each link works once and is
exchanged for a strict session cookie; `Host` and `Origin` are checked exactly. An account's API key
or setup token may be typed in a masked field (the wizard, Accounts & keys) while
`ui.allow_secret_entry` is on (the default): one CSRF-checked POST body, stored as `doz account add`
stores it, never echoed; off, the page shows the command. A sandbox's own key (`doz key set NAME
--anthropic`) likewise, on its page (Keys & account; `POST /api/v1/sandboxes/NAME/key`, held by the
host as `doz key set` holds it). **Open in Terminal** runs
`doz attach` in your default terminal app. The UI is a client of the host, like any other
command, so it can't do anything the CLI can't.

A store that was never onboarded opens on the **setup wizard** — Welcome, Checks, Access, Workspace
rules, Images, Preparing, First sandbox, Done — the same steps as `doz onboard` (always reachable again from
**Onboarding** in the navigation — marked with a dot until the store is onboarded — or **Doctor ›
Run onboarding again**). Preparing runs in the host: **Continue in the background** leaves
it running, and **Operations** lists the host's image preparations whoever started them (the CLI
too). A sandbox's page shows its environment prompt as the next session gets it, and whether
`/workspace` is shared (or the **isolated** badge). New sandbox, Duplicate and the wizard's First
sandbox name the sandbox from its image (`claude-sandbox`, `-2` when taken) and offer **Shared
folder** — `<defaults.projects_dir>/<name>` by default, made when missing, with **Choose…** opening
the Mac's own folder picker — or **Isolated** (nothing on the Mac is shared).

### The dashboard for your other browsers

```bash
doz serve [start] [--detach|-d] [--port N] [--bind lan|loopback|ADDRESSES] [--no-invite] [--store DIR]   # serve the dashboard on your network; Ctrl-C (or doz serve stop) stops it; --detach: in the background
doz serve share [--store DIR]                          # an invite for one more browser: a QR code, a code and a link (a terminal only)
doz serve devices [--json] [--store DIR]               # the browsers let in: name, first and last seen, from where, which browser
doz serve revoke ID | --all [--store DIR]              # remove a browser: signed out at once (its terminals close)
doz serve rename ID NAME [--store DIR]                 # name a browser
doz serve status [--json] [--store DIR]                # running? where, how many browsers, open invites
doz serve log [-n N] [--json] [--store DIR]            # what the other browsers did (the audit log)
doz serve stop [--store DIR]                           # stop the running doz serve
```

`doz serve` is a separate process from `doz ui` (which stays on `127.0.0.1`): its own lock, socket, port
(`serve.port`, 7443) and devices (`<store>/serve/`, 0700 — `devices.json` holds each browser's cookie digest, never
the cookie). It listens on every network interface of the Mac and Tailscale (`serve.bind = lan`) — never on a
sandbox's network, and a connection from a sandbox network is dropped before a byte is read; the host's egress
proxy refuses the dashboards' ports on the Mac's own addresses to proxied sandboxes. A browser gets in once with
an invite (a 256-bit link token in the URL fragment, an 8-character code, the QR code of the link — whichever is
used first, within five minutes) and stays in until it is revoked. Everything the Mac's dashboard does works,
except typing a key or token over plain HTTP (403 `secret-over-http`) and what opens a window on the Mac's own
screen (the folder pickers, Open in Terminal: 403 `mac-screen`). Each request's own origin is derived from its
`Host` (the Mac's names and addresses) or, only from a `serve.trusted_proxies` peer, from `X-Forwarded-Proto` /
`X-Forwarded-Host` (a `serve.public_origins` entry); `Origin` must equal it; `Sec-Fetch-Site` same-origin or none.
Over https through a trusted proxy the cookie is `__Host-` and `Secure`, and keys may be typed. `doz doctor`
fetches each public origin with a one-use token to prove it reaches this `doz serve`. Announced with Bonjour
(`serve.advertise`). Remote changes, terminals, admissions and refusals go to `<store>/serve/audit.jsonl`.

### Settings

```bash
doz config [show]          # every setting: its effective value, its source (flag, env, file, default) and default
doz config get KEY         # one value (--json: with its source and default)
doz config set KEY VALUE   # write it to the file (checked against its type and range)
doz config unset KEY       # back to the default (commented out again)
doz config init            # write the file: every setting listed, commented out at its default
doz config path            # ${XDG_CONFIG_HOME:-~/.config}/dozer-sandbox/doz.toml
doz config show|get|set|unset --sandbox NAME …   # 599: one sandbox's own value of a per-sandbox setting
                                                  # (sandbox.clipboard, sandbox.browser_bridge, sessions.tmux,
                                                  #  sandbox.agent_sudo) — it wins over the file
```

One settings file, `doz.toml`, lists every setting grouped in sections (`[ui]`, `[host]`,
`[store]`, `[claude]`, `[defaults]`, `[agent]`, `[resources]`, `[sandbox]`, `[images.lab]`, `[images.claude-code]`, `[images.pi]`,
`[kernel]`), each with a description and `# key = default` commented out; only what you set is
uncommented. Precedence: a command-line flag, then its environment variable, then the file, then
the default. `ui.boot_view_on_start` (default `true`) makes Start in the web UI open a terminal on
the boot; the UI's **Settings** page edits the same file (a host path, or a value the environment
sets, is read-only there). The file is written whole, atomically, `0600`; an unknown key is a
warning, and a file that doesn't parse is ignored (and never overwritten) until it's fixed. Not
settable, by design: the web UI's security limits and checks, the terminal's paste cap and tickets,
the guest binaries, and credentials.

### Numbers and diagnostics

```bash
doz metrics [--csv] [--image X] [--days N] [--no-steps]   # count, median, p90, min, max, failures
doz doctor                                                  # macOS, Apple silicon, entitlement, kernel, store, host, Claude login
doz events [NAME]                                           # follow phases and timed steps live
doz console NAME [--follow]                                 # the boot console (kernel + init); --follow keeps printing it
doz console NAME --list | --steps [--boot N] [--json]       # the kept boots (host.boot_logs_kept, 5): steps + console of boot N (1 = latest)
```

### Scripting

Every command takes `--json` (machine-readable output; errors as
`{"error":{"code","message"}}`), `--store DIR` (default `$DOZ_STORE`, else the settings'
`store.path`, else `~/Library/Application Support/dozer-sandbox`), `-v` (every progress step),
`-q` (none) and `--progress auto|plain` (on a terminal: a spinner and download bars, or one line
per step; not a terminal, `--json` or `NO_COLOR`: always plain).
JSON documents only ever gain fields.

| exit code | meaning |
|---|---|
| 0 | ok |
| 1 | failed |
| 2 | not found |
| 3 | not possible in this phase |
| 4 | already exists |
| 5 | not confirmed |
| 6 | host unavailable |
| 7 | not implemented yet |
| 64 | usage |
| *program's own* | `exec`, `run`, `attach` (125 = doz itself failed) |

| environment | overrides the setting | |
|---|---|---|
| `DOZ_STORE` | `store.path` | the store directory |
| `DOZ_HOST_IDLE` | `host.idle_timeout_minutes` | host idle timeout, minutes |
| `DOZ_KERNEL_CACHE` / `DOZ_KERNEL` | `kernel.cache` / `kernel.path` | a shared kernel cache / an explicit kernel |
| `DOZ_SUBNET` | `defaults.nat_subnet` | default subnet for `--network nat` |
| `DOZ_PROGRESS` | `ui.progress` | `animated` or `plain` progress |
| `XDG_CONFIG_HOME` | — | where `dozer-sandbox/doz.toml` is (default `~/.config`) |

### Troubleshooting

| symptom | try |
|---|---|
| "cannot boot a VM" / entitlement | `doz doctor`; reinstall (`brew reinstall doz`, or `make install-cli` — both are signed). |
| "this host's program … is gone" | An upgrade removed the previous version under a running host: `doz host stop`, then retry. |
| First start is slow | It is preparing the image, once per store — `doz onboard` (or `doz image bake …`) does it ahead of time; `-v` shows the steps. |
| A start or wake failed, or its boot flew past | `doz console NAME --list`, then `doz console NAME --steps [--boot N]` — each kept boot's steps (✗ with why) and its kernel console; **Boot log** in the web UI. |
| An agent's sessions do not start: "the agent prompt does not render" | A `{{variable}}` that is not on the list in `agent-prompt.md` or the sandbox's own prompt — `doz inspect NAME --prompt` names it. |
| Start over from nothing | `doz uninstall` (it lists what goes; a Homebrew `doz` is left to `brew uninstall doz`), then `brew install dozer-sandbox/tap/doz` and `doz onboard`. |
| An agent says it has no key / 401 | `doz key ls NAME` — a stdin key is gone after the host stopped; set it again or use `--keychain`. |
| A package install fails | `doz net NAME` names what was refused and the permission that allows it (`doz net allow NAME install:python`, or `site:HOST`); the raw log is `doz net log NAME --denied`. |
| A sandbox shows as died | The host crashed while it ran — `doz start NAME` checks the disk and cold-boots it. |
| Anything else | `<store>/host.log` and `doz events`. |

### Not yet

Moving a *running* sandbox to another Mac (a cold move — shut down, copy, start — works but has no
command yet), image pull/push, port forwards, IPv6 and HTTP/2 through the proxy, and an idle
auto-suspend scheduler.
