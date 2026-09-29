# CLI reference

Every `doz` command, by task. New to it? <doc:DozerWalkthrough> is a first run, end to end.

## Overview

`doz` runs Linux sandboxes on your Mac that pause in a millisecond, hibernate to disk and wake
in about a third of a second, with the programs inside them still running where they were. It is
the command-line face of `DozerKit`.

```bash
cd repo/lib/DozerKit
make install-cli                  # PREFIX=~/.local by default → ~/.local/bin/doz
doz onboard                       # once: checks, the Claude account, settings, images (in the background)
```

A VM can only be booted by a binary signed with Apple's virtualization entitlement, and `make
install-cli` signs it. An unsigned build runs every command but cannot boot anything, and `doz
doctor` says so. `make cli` builds a signed debug binary at `.build/debug/doz` for development.

> This article's command list is checked against the CLI's real subcommand tree by
> `Scripts/docs-drift-check.sh` (`make docs-drift-check`) — see that script for how.

### Setting up: onboard, init, uninstall

```bash
doz onboard [--images claude-code,pi,lab | --all-images | --no-images] [--account mac|api-key|setup-token|later] [--yes]
            [--account-name NAME] [--plan PLAN] [--secret-stdin] [--force]
doz onboard --status        # the onboarding record and the images; follows a preparation that runs
doz onboard --cancel        # cancel the images being prepared
doz init [DIR] [--name N] [--image I] [--cpus N] [--memory M] [--network …] [--account A] [--yes] [--force]
doz up                      # in a folder with doz_project.yaml: that project's sandbox
doz uninstall [--keep-store] [--keep-config] [--yes]
```

- **`onboard`** sets up this Mac, once: the doctor's checks (a *required* one that fails —
  not Apple silicon, macOS too old, no virtualization, the entitlement, the store not on APFS, too
  little disk for the chosen images — stops it; the rest only warn), the **Claude account** (this
  Mac's Claude Code login when it is signed in; otherwise an API key or a setup token **pasted at a
  hidden prompt** and stored exactly as `doz account add` stores it — the login keychain, one tiny
  check request, `--plan` for a token — then made the default; or **Decide later**. It never logs in
  and never copies Claude Code's refresh token. Off a terminal a key is read from stdin only with
  `--secret-stdin`; otherwise that step is skipped and the command shown), the settings file and your prompt template (each written **only when
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
  `network`, `account`, `sessions`, `agent_prompt`, `agent_prompt_mode`; an unknown key or a bad
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
doz create NAME --image lab|claude-code|pi|<custom> \
    [--cpus 2] [--memory 2G] [--workspace ~/code/proj | --isolated] \
    [--network agent|bake|locked|open|nat|none] [--subnet CIDR]

doz up NAME [same options] [--session S] [-d] [-- CMD …]
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
| `attach NAME [SESSION] [--no-wake]` | Your terminal becomes that session. **Ctrl-]** detaches (`--detach-key ctrl-x\|none`). A paused or sleeping sandbox wakes first unless `--no-wake`. Hibernated while attached: the client waits and reattaches by itself on wake. |
| `run NAME [--session S] [-d] -- CMD …` | A **new** session running `CMD`, attached; exits with `CMD`'s exit code. No shell in front — write `bash -lc '…'` for one. |
| `exec NAME [--user U] [--workdir D] [-e K=V] [--timeout S] -- CMD …` | One-shot, no terminal: stdout, stderr and the exit code pass straight through (default timeout 120 s). Agent images run as the agent's user in `/workspace`; `--user root` for root. |
| `sessions NAME` | The sandbox's terminal sessions. |
| `ls` · `inspect NAME` | Every sandbox: image, phase, RAM held, disk, sessions, network · everything as JSON. |

**RAM held** in `ls` is what the VM costs the Mac right now: the allocation, less what the memory
balloon returned after a wake — shown as `—` when the sandbox is off or hibernated.

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
```

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
| `agent` | Anthropic's API and sign-in hosts; what Claude Code reaches on its own (`downloads.claude.ai` for updates, its two Datadog error-reporting intakes `http-intake.logs.us5.datadoghq.com` and `browser-intake-us5-datadoghq.com`); GitHub over HTTPS for git and Claude Code's plugin marketplace (`github.com`, `raw.githubusercontent.com`, `codeload.github.com`, `objects.githubusercontent.com`); plus package registries | `claude-code`, `pi` |
| `bake` | package registries only (npm, apt, apk, PyPI) | `lab` |
| `locked` | nothing | |
| `open` | everything, still proxied and logged | |
| `nat` | a normal NAT network card, not proxied, no log | |
| `none` | no network at all | |

```bash
doz net policy NAME                                  # show
doz net policy NAME --allow github.com --allow '*.githubusercontent.com'
doz net policy NAME --deny example.com --remove github.com
doz net policy NAME --preset open
doz net log NAME [--denied] [--follow]              # host, verdict, rule, bytes; never contents
```

A name the policy cannot allow does not even resolve. Current limits: IPv4 only, HTTP/1.1 on hosts
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

doz image ls                   # built-in images and templates, and whether each is baked here (for this build)
doz image ls --tree            # the lineage: OCI base → image → template → sandboxes, with sizes
doz image bake claude-code     # prepare it now (joins a preparation already running; minutes, needs network)
doz image rm NAME              # sandboxes already made from it keep working
```

`image pull` / `push` answer "not yet" (exit 7). `image ls --tree` shows each disk's size, the
bytes it shares with its parent (APFS clones) and its own (what removing it frees).

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

### The host

```bash
doz host [--foreground] [--idle-timeout MIN]   # run it by hand
doz host stop                                    # hibernates everything running, then exits
doz host status                                  # is one running, and what does it hold? never starts one
```

Started for you by the first command that needs it; runs detached (`<store>/host.log`,
`<store>/host.sock`); exits after 5 minutes idle (`$DOZ_HOST_IDLE`, 0 = never). `ls`,
`inspect`, `point ls`, `image ls`, `net policy` (shown) and `key ls` read the store directly when
no host runs, so **looking never starts one**. If it crashes, the next command starts a new one:
sleeping sandboxes are restored with their sessions, hibernated ones are untouched, and running
ones are reported as died with their disk checked at the next start.

### The web UI

```bash
doz ui [serve] [--open | --print-url] [--store DIR]   # a local dashboard for everything above; Ctrl-C stops it
doz ui link [--store DIR]                             # a fresh one-use sign-in link for the running UI
```

A browser dashboard for sandboxes, images, accounts, metrics, activity and doctor, with the
lifecycle and every other action. Each sandbox has its own page (a child of Sandboxes in the
navigation): a control bar, its terminals filling the page, and a details panel. **All sessions**
is a grid of live, read-only views of every session; **Images** has a Lineage view; **Operations**
lists what the UI asked the host to do. It listens on `127.0.0.1` only. Each link works once and is
exchanged for a strict session cookie; `Host` and `Origin` are checked exactly. An account's API key
or setup token may be typed in a masked field (the wizard, Accounts & keys) while
`ui.allow_secret_entry` is on (the default): one CSRF-checked POST body, stored as `doz account add`
stores it, never echoed; off, the page shows the command. A sandbox's own key (`doz key set NAME
--anthropic`) likewise, on its page (Keys & account; `POST /api/v1/sandboxes/NAME/key`, held by the
host as `doz key set` holds it). **Open in Terminal** runs
`doz attach` in your default terminal app. The UI is a client of the host, like any other
command, so it can't do anything the CLI can't.

A store that was never onboarded opens on the **setup wizard** — Welcome, Checks, Claude account,
Images, Preparing, First sandbox, Done — the same steps as `doz onboard` (always reachable again from
**Doctor › Run onboarding again**). Preparing runs in the host: **Continue in the background** leaves
it running, and **Operations** lists the host's image preparations whoever started them (the CLI
too). A sandbox's page shows its environment prompt as the next session gets it, and whether
`/workspace` is shared (or the **isolated** badge). New sandbox, Duplicate and the wizard's First
sandbox name the sandbox from its image (`claude-sandbox`, `-2` when taken) and offer **Shared
folder** — `<defaults.projects_dir>/<name>` by default, made when missing, with **Choose…** opening
the Mac's own folder picker — or **Isolated** (nothing on the Mac is shared).

### Settings

```bash
doz config [show]          # every setting: its effective value, its source (flag, env, file, default) and default
doz config get KEY         # one value (--json: with its source and default)
doz config set KEY VALUE   # write it to the file (checked against its type and range)
doz config unset KEY       # back to the default (commented out again)
doz config init            # write the file: every setting listed, commented out at its default
doz config path            # ${XDG_CONFIG_HOME:-~/.config}/dozer-sandbox/doz.toml
```

One settings file, `doz.toml`, lists every setting grouped in sections (`[ui]`, `[host]`,
`[store]`, `[claude]`, `[defaults]`, `[agent]`, `[images.lab]`, `[images.claude-code]`, `[images.pi]`,
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
| "cannot boot a VM" / entitlement | `doz doctor`; reinstall with `make install-cli` (it signs). |
| First start is slow | It is preparing the image, once per store — `doz onboard` (or `doz image bake …`) does it ahead of time; `-v` shows the steps. |
| An agent's sessions do not start: "the agent prompt does not render" | A `{{variable}}` that is not on the list in `agent-prompt.md` or the sandbox's own prompt — `doz inspect NAME --prompt` names it. |
| Start over from nothing | `doz uninstall` (it lists what goes), then `make install-cli` and `doz onboard`. |
| An agent says it has no key / 401 | `doz key ls NAME` — a stdin key is gone after the host stopped; set it again or use `--keychain`. |
| A package install fails | Check the policy: `doz net log NAME --denied`, then `doz net policy NAME --allow HOST`. |
| A sandbox shows as died | The host crashed while it ran — `doz start NAME` checks the disk and cold-boots it. |
| Anything else | `<store>/host.log` and `doz events`. |

### Not yet

Moving a *running* sandbox to another Mac (a cold move — shut down, copy, start — works but has no
command yet), image pull/push, port forwards, IPv6 and HTTP/2 through the proxy, and an idle
auto-suspend scheduler.
