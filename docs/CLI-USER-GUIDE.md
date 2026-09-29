# `doz` user guide

`doz` runs Linux sandboxes on your Mac that pause in a millisecond, hibernate to disk and wake
in about a third of a second, with the programs inside them still running where they were. It is
the command-line face of DozerKit. New to it? Start with the
[walkthrough](CLI-WALKTHROUGH.md).

## Concepts

| | |
|---|---|
| **Sandbox** | One Linux VM with its own disk, named by you (`a-z 0-9 -`, 1–40 characters). |
| **Image** | What a sandbox starts from: a baked, read-only disk. Built in: `lab` (Alpine + bash, 1 GiB RAM), `claude-code` and `pi` (Debian `node` + the agent, 2 GiB). Custom images are saved from a sandbox. |
| **Session** | A terminal program living in the sandbox (a shell, `claude`, `pi`). It survives pause, sleep and hibernate. You *attach* to it and *detach* from it; it keeps running either way. |
| **Workspace** | A folder of your Mac shared into the sandbox at `/workspace`. |
| **Host** | One background `doz` process per user and store. It owns every running VM, the network proxy and the keys. It starts when needed and exits when idle, so you never manage it. |
| **Store** | Where everything lives on disk: `~/Library/Application Support/dozer-sandbox` unless `--store` or `$DOZ_STORE` says otherwise. Each store has its own images, sandboxes and host. |

## Install

```bash
cd repo/lib/DozerKit
make install-cli                  # PREFIX=~/.local by default → ~/.local/bin/doz
doz onboard                       # once: set up this Mac
```

A VM can only be booted by a binary signed with Apple's virtualization entitlement, and
`make install-cli` signs it. An unsigned build runs every command but cannot boot anything, and
`doz doctor` (and `doz onboard`) say so. `make cli` builds a signed debug binary at
`.build/debug/doz` for development.

## Setting up this Mac: `doz onboard`

```bash
doz onboard                                   # asks on a terminal; Enter takes the recommended answer
doz onboard --images claude-code,pi --yes     # scripts: ask nothing (--yes, --json or no terminal)
doz onboard --all-images | --no-images        # every image (~15+ min the first time) · none now
doz onboard --account mac|api-key|setup-token|later   # answer the account step (and skip the Claude Code checks)
doz onboard --account setup-token --account-name work --plan max --secret-stdin --yes < token.txt   # scripts: the token from stdin
doz onboard --status                          # the record and the images; follows a preparation that runs
doz onboard --cancel                          # stop the images being prepared
```

It does, in order:

1. **Checks** — the doctor's. The *required* ones stop it when they fail: Apple silicon, macOS 26+,
   virtualization, the entitlement, the guest tools, the store on APFS with room for the chosen
   images, a store path short enough for its socket. The rest only warn: Claude Code missing or
   signed out (a claude-code sandbox still works with an account added later), vmnet (only
   `--network nat` needs it).
2. **Claude account** — offered, never logged in for you. Claude Code signed in on this Mac: "use
   this Mac's login" (the account `mac`) is the default. Otherwise: **an API key or a setup token,
   pasted right there** at a no-echo prompt (with its account name, and the plan for a token) and
   stored exactly as `doz account add` stores it — the login keychain (`doz-anthropic:NAME`,
   `doz-claude:NAME`) after one tiny check request — then made the store's default; or **Decide
   later** (nothing changes). Off a terminal the key is read from stdin only with `--secret-stdin`
   (as `doz account add` reads it); otherwise the step is skipped and the command shown. Onboarding
   never touches Claude Code's refresh token.
3. **Images** — `claude-code` is prepared by default; `pi` and `lab` are opt-in.
4. **Settings** — `doz.toml` (every setting at its default, with `defaults.image` and
   `defaults.account` from your answers) and `agent-prompt.md` beside it (see "The agent's
   environment prompt"), each written **only when missing**. An existing file is left exactly as it is.
5. **Preparing** — the kernel, the guest init disk, the base image and the bake. It runs **in the
   host**: the progress is 593's view, **Ctrl-C detaches** (it goes on), `--status` re-attaches,
   `--cancel` cancels. The store is marked onboarded (`<store>/onboarded.json`) by the host when every
   chosen image is ready — even if you detached.

**One preparation per image.** A `doz start` (or `up`, `image bake`, the web UI) of an image being
prepared **joins** that preparation — it shows the same progress from its start, and there is one
download and one bake. A start of an image never prepared starts the preparation itself, and a
second start joins it. Re-running `doz onboard` prepares only what is missing for this build.

**What a preparation shows** (the web UI's preparation card — the wizard's Preparing step, a row of
**Operations** — in the same terms as the CLI's progress): **Step N of M** with a bar of the steps done
(M is the plan for the image: kernel, guest init, base pull, base disk, the bake's steps, the checks);
the step under way with its time and an animated strip (never a full bar — its length is not known);
during a download, its own bar with bytes and speed; the **last 6 lines of output** of the step under
way (a bake step's own output, e.g. apt's `Get:` and `Setting up` lines); and the finished steps, each
✓ with its time (✕ with its last output lines when one failed). **Estimates** come only from this
store's last successful preparation of the same image (`<store>/preparations.json`: each step's
time): "usually ~37 s" for the step under way and "about 2 min left" overall. The first time there
is nothing to go on, and it says so: "first time: no estimate yet".

**Agent versions: latest by default.** The claude-code and pi images install their agent at one
exact version. Which one is the setting `images.claude_code_version` (and `images.pi_version`):
`latest` — the default — or an exact version such as `2.1.227`.

- **`latest` is resolved when the image is prepared**, never while a sandbox runs: the host asks
  the npm registry for the package's latest version and its sha512 integrity, and the bake installs
  THAT version, integrity-checked. The preparation's step says so — `npm install
  @anthropic-ai/claude-code@2.1.285 (latest, resolved now)` — and the version is part of the image
  (and of its bake key): an image is always one exact version.
- **Nobody waits for a newer version.** `doz onboard`, the wizard, `doz image bake`, `doz create`
  and a first start ask the registry (one small request, remembered for an hour in
  `<store>/agent-versions.json`). When the prepared image is behind, a **new preparation starts in
  the background** (Operations shows it); the sandbox being created now uses the image already
  prepared, and the next one gets the new version. `doz image ls` and the Images page say
  `claude-code 2.1.227 (2.1.285 available — preparing)`, then `claude-code 2.1.285 (latest)`.
- **Offline:** the registry not answering is noted in `host.log` and the image already prepared is
  used. `latest` with no network and **no image yet** fails, saying so — set an exact version
  (`doz config set images.claude_code_version 2.1.227`). An exact version this store knows (the
  built-in one, or one it prepared or resolved before) always works without asking.
- **A sandbox keeps its version.** Its root disk is the image it was created from; `doz reset NAME`
  gives it the image's current version (and a fresh root disk). Inside a sandbox Claude Code never
  updates itself (`DISABLE_AUTOUPDATER=1`, `DISABLE_UPDATES=1` in its sessions).

## Projects: `doz init` and `doz_project.yaml`

```bash
doz init [DIR] [--name N] [--image I] [--cpus N] [--memory M] [--network …] [--account A] [--yes] [--force]
cd DIR && doz up             # no name: this folder's sandbox
```

`init` makes a folder (made when missing) a project: it writes `doz_project.yaml`, asking for the
sandbox's name (from the folder's) and image (the settings' `defaults.image`); it onboards this Mac
first if it never was. **`doz up` with no name**, in that folder, creates, starts or wakes exactly
that sandbox — the folder is its `/workspace` — starts its `sessions` (the first is attached, the
others detached) and keeps the sandbox's own agent prompt in step with the file (it applies from the
next session). Options given to `up` win over the file's, for a new sandbox.

```yaml
# doz_project.yaml
version: 1
name: webapp                # the sandbox
image: claude-code          # claude-code, pi, lab or a template (an image from a Dockerfile: not yet)
cpus: 4                     # optional, like the rest below (the settings' defaults otherwise)
memory: 4G
network: agent              # agent, bake, locked, open, nat, none
account: default            # default, none, or an account name
sessions:                   # what `doz up` starts; the first is attached
  - claude                  #   the image's own session
  - name: server            #   a session of your own (no shell: the command is split on spaces,
    command: npm run dev    #   or give a list: [npm, run, dev])
agent_prompt: |             # this project's own lines for the agent
  The tests run with `make test`.
agent_prompt_mode: append   # or replace
```

The schema is closed: an unknown key, a key given twice, a wrong type or a value out of range is an
error naming its line. No anchors or aliases, one document, 64 KiB at most.

## Removing it: `doz uninstall`

```bash
doz uninstall [--keep-store] [--keep-config] [--yes]
```

It lists exactly what goes — the store (every sandbox, image, kernel and restore point, the host's
log and metrics), the settings directory (`doz.toml`, `agent-prompt.md`), and the installed `doz`
(`<prefix>/libexec/doz/` and the `<prefix>/bin/doz` link, when this `doz` is one `make install-cli`
installed) — and asks once; no terminal and no `--yes` refuses (exit 5). A running host is stopped
first; a running `doz ui` must be stopped by you. It never touches the keychain — it names any item
`doz account add` made (`doz account rm NAME` removes one; do it before uninstalling) — nor Claude
Code's own files or login. A store directory that does not look like a store is refused.

## The lifecycle

```
            start / cold-boot                      pause / suspend
   off  ──────────────────────►  running  ◄──────────────────────►  paused
    ▲                             │  ▲                 resume
    │ shutdown (keeps the disk)   │  │ wake
    └─────────────────────────────┤  ├──────────── asleep       (sleep: snapshot, RAM kept)
                                  │  └──────────── hibernated   (hibernate: snapshot, RAM returned)
```

| command | does | typical time | RAM | programs |
|---|---|---|---|---|
| `start NAME` (`cold-boot`) | boots; wakes it if asleep, resumes it if paused | ~0.4 s (the first ever start also bakes the image) | allocated as used | start fresh |
| `pause NAME` (`suspend`) · `resume NAME` | stops the guest CPU | ~1 ms | kept | frozen, then continue |
| `sleep NAME` · `wake NAME` | pause + snapshot to disk; survives the host crashing | ~0.3 s | kept | continue |
| `hibernate NAME` · `wake NAME` | snapshot, then the VM stops | ~0.35 s / ~0.3 s | **returned** | continue: same PIDs, same screens |
| `shutdown NAME` | a cold stop; the disk is kept | | returned | end |
| `reset NAME` | shut down and go back to a fresh copy of the image (restore points and the agent's state disk stay) | | | end |
| `rm NAME` | remove the sandbox and everything it has on disk | | | end |

`shutdown`, `reset` and `rm` ask first. `--yes` skips the question. Without a terminal and without
`--yes` they refuse (exit 5), so a script can never destroy something by accident.

A program started less than 3 s before hibernating gets the rest of those 3 s first. Programs cut
off mid-startup (Claude Code's first network calls, for example) can otherwise fail on wake.

## Creating and entering sandboxes

```bash
doz create NAME --image lab|claude-code|pi|<custom> \
    [--cpus 2] [--memory 2G] [--workspace ~/code/proj | --isolated] \
    [--network agent|bake|locked|open|nat|none] [--subnet CIDR]

doz up NAME [same options] [--session S] [-d] [-- CMD …]
```

- **`up`** is the everyday command, in the manner of `vagrant up` and `docker compose up`: create
  if missing, start or wake, then attach to the image's own session (`claude`, `pi`, or a
  `bash -l` shell called `shell`), opening it if needed. With `-d` it does all that without
  attaching. With `-- CMD …` it opens a new session running CMD instead.
- On an existing sandbox, `up`'s create options are ignored, and it says so. A sandbox keeps the
  image and settings it was created with.
- `up` defaults to the settings' `defaults.image` when it creates a sandbox (`doz onboard` sets it;
  `lab` otherwise). `create` requires `--image`. With no NAME, in a project folder, `up` uses
  `doz_project.yaml`.
- **`--workspace DIR`** shares a folder of this Mac at `/workspace`. When it does not exist, doz
  **makes it** (`mkdir -p`, your permissions) before the VM is configured and says
  `[doz] created ~/…` (`"workspaceCreated": true` in `--json`); if the create then fails, a folder
  doz made is removed again while it is still empty. A relative path is this folder's. Refused, and
  never made: an existing file, a folder inside the store, a system location (`/System`, `/usr`,
  `/bin`, `/sbin`, `/private/var`, `/Library`, …), `/` and your home folder itself.
- **Without `--workspace` the sandbox is isolated**: `/workspace` is a directory on the VM's own
  disk and nothing on this Mac is shared. That is allowed and said — `create` notes
  `isolated: nothing on this Mac is shared; /workspace is private to the sandbox`, `ls` shows
  `isolated` (`--json`: `"workspace": null, "isolated": true`), and the agent is told.
  `--isolated` asks for it on purpose (no note; not together with `--workspace`). The web UI's New
  sandbox, Duplicate and the wizard default to a **Shared folder** instead —
  `<defaults.projects_dir>/<name>`, `~/Developer/dozer-sandbox-projects/<name>` unless you set
  `defaults.projects_dir` (`doz config set defaults.projects_dir PATH`) — with **Isolated** one
  click away; `doz create` has no default folder, and `doz init` uses the folder it runs in.
- `--agent-prompt FILE [--agent-prompt-mode append|replace]` gives the sandbox its own part of the
  agent's environment prompt (below).

## Working inside

| | |
|---|---|
| `doz attach NAME [SESSION]` | Your terminal becomes that session. **Ctrl-]** detaches (`--detach-key ctrl-x` or `none`). A paused or sleeping sandbox is woken first (`--no-wake` waits instead). If the sandbox hibernates while you are attached, the client waits and reattaches by itself when it wakes. |
| `doz run NAME [--session S] [-d] -- CMD …` | Open a **new** session running CMD and attach. It exits with CMD's exit code. There is no shell in front, so write `bash -lc '…'` if you want one. |
| `doz exec NAME [--user U] [--workdir D] [-e K=V] [--timeout S] -- CMD …` | One-shot, no terminal: stdout, stderr and the exit code pass straight through (default timeout 120 s). On agent images it runs as the agent's user in `/workspace`; `--user root` for root. |
| `doz sessions NAME [--screen SESSION [--vt]]` | The sandbox's sessions. While it is not running (paused, asleep, hibernated, shut down) they are listed from their **saved screens**, and nothing is woken. `--screen SESSION` prints that session's last saved screen as text; `--vt` writes its terminal bytes instead — to a file or a pipe (`> s.vt`, then `cat s.vt` in a terminal redraws it), never straight to a terminal. |
| `doz ls` · `doz inspect NAME` | Every sandbox: image, phase, RAM held, disk, sessions, network · everything about one, as JSON. |

**RAM held** in `ls` is what the VM costs your Mac right now: the allocation, less what the memory
balloon handed back after a wake. It is shown as `—` when the sandbox is off or hibernated.

**Saved screens.** Before a sandbox pauses, sleeps, hibernates or shuts down, doz saves the screen of
each of its sessions — and every `host.screen_capture_minutes` (5) while it runs, for the sessions
that printed something since, so a crash still leaves a recent copy. Saving is a moment's look at
the session (it is not resized, nothing is typed), limited to a few seconds, and a screen that
cannot be saved keeps the previous one — it never holds up the sleep. Each screen is kept as text
(the terminal's own bytes, and plain text) in the sandbox's directory (`screens/`, readable only by
you). After a shutdown the last screens stay, marked ended. Reset and remove delete them; duplicate,
fork and templates never copy them.

## Agents and keys

The agent images run their agent as a normal user in `/workspace`, and they keep the agent's login
and history (`~/.claude`, `~/.pi/agent`) on a separate state disk. That disk survives shutdown,
reset and re-bakes.

**Claude Code starts ready to work.** The claude-code image's `claude` is a small launcher. Before
running the real Claude Code it:

- marks the first-run setup done: onboarding, this session's key placeholder approved, and the
  working folder trusted;
- passes `--dangerously-skip-permissions`, so there are no approval prompts. The VM, the proxy and
  the key vault are the boundary.

`-e DOZ_CLAUDE_PERMISSIONS=ask` (on `run` or `exec`) keeps Claude Code's own prompts, and a
`claude` run as root always keeps them.

Keys never enter the sandbox. The host's proxy holds each credential and puts it into requests to
Anthropic on their way out. Inside the sandbox, `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` is
a `doz_cred_…` placeholder. A credential is never a command-line argument, so it never lands in
shell history or `ps`.

### The agent's environment prompt

Asked "what is the host path of /workspace?", an agent used to have to read `/proc/self/mountinfo`
to find out — it was told nothing about where it runs. Now, **at every session start**, the host
renders from the sandbox's current facts (so it stays true after a duplicate, a policy edit or a
new workspace) and writes into the guest:

- a short **facts block**, appended to the agent's system prompt: that it is in a Dozer Sandbox (a
  Linux VM on the user's Mac, not a container) — name, image, CPUs, memory; `/workspace` shared from
  the Mac folder *X* (live) or **isolated** (no folder is shared with the Mac); the network (no interface; deny by default through
  the Mac's proxy; a refused host needs the user's rule — do not retry around it); credentials
  (injected by the proxy; the placeholders are expected; never log in or ask for keys); sleep and
  hibernation between turns. Claude Code gets it through its launcher (`/run/dozer/agent-prompt.md`
  → `--append-system-prompt`); pi's session is `pi --append-system-prompt /run/dozer/agent-prompt.md`.
- the **`dozer` skill** — `~/.claude/skills/dozer/SKILL.md` (pi: `~/.pi/agent/skills/dozer/SKILL.md`),
  rewritten every start: what persists (root disk, state disk, restore points), the network policy
  and how the user changes it, credentials, sleep and hibernate, the workspace, and what the agent
  cannot do from inside (take a restore point, change the policy, add a key — it asks the user).

Dozer owns only those two; the agent's own memory files (`CLAUDE.md`, `AGENTS.md`,
`APPEND_SYSTEM.md`) are never touched.

```bash
doz inspect NAME --prompt           # what the next session gets — or why it does not render (--json: with the skill)
doz config set agent.prompt false   # off: the next session start removes both
```

**Your own text, in three layers:** the built-in template < **`agent-prompt.md`** beside
`doz.toml` (`doz onboard` writes it with everything inside an HTML comment, so it changes nothing
until you write text outside one — that text then replaces the built-in template) < the sandbox's
own (`--agent-prompt FILE`, or `agent_prompt` in `doz_project.yaml`), appended (default) or
replacing (`agent_prompt_mode: replace`). Text may use `{{variables}}` from a closed list:
`sandbox.name`, `sandbox.image`, `sandbox.cpus`, `sandbox.memory`, `workspace.shared`,
`workspace.host_path`, `workspace.guest_path`, `workspace.description`, `network.mode`,
`network.allowed_hosts`, `network.description`, `account.name`, `credentials.description`,
`mac.hostname`, `dozer.version`. An unknown variable is an **error**: the agent's sessions do not
start (the message names the variable and the file) until it is fixed or the prompt is turned off —
never silently blank.

A claude-code image baked before this release has no launcher support for the facts block (the skill
still arrives): `doz reset NAME` (or a new sandbox) moves to the new image.

### Claude accounts

A sandbox on a proxied network uses one **account**:

| kind | what it is | where the secret lives | renewal |
|---|---|---|---|
| `mac` (built in) | this Mac's own Claude Code login | Claude Code's own keychain item, read-only for doz | the Mac's Claude Code renews it |
| `setup-token` | a `claude setup-token` token (a Claude subscription, valid 1 year) | the login keychain, `doz-claude:NAME` | none: add a new one before it expires |
| `api-key` | an Anthropic API key | the login keychain, `doz-anthropic:NAME` (or an item you name) | none |

```bash
doz account ls                                   # accounts, state, expiry, which sandboxes use them — never a secret
doz account add work --setup-token --plan max    # paste the token `claude setup-token` printed (no echo), or pipe it in
doz account add ci --api-key                     # an API key (prompt or stdin), or: --keychain SERVICE
doz account use NAME work                        # this sandbox uses work; open sessions switch on their next request
doz account use NAME default                     # follow the store's default again (none: no credential)
doz account default work                         # every sandbox that follows the default moves to work
doz account verify work                          # one tiny request to api.anthropic.com
doz account rm work [--force]                    # also deletes the keychain item doz made
doz create NAME --image claude-code --account work
```

- **A new proxied sandbox follows the store's default account, `mac` out of the box.** Sign in
  on the Mac once (`claude`) and every sandbox can use your subscription, with nothing to paste.
- **Claude Code in the sandbox shows your plan.** The guest gets `CLAUDE_CODE_SUBSCRIPTION_TYPE`
  and `CLAUDE_CODE_RATE_LIMIT_TIER` (not secrets). So a Max login shows "Claude Max" and defaults
  to Opus, as it does on the Mac. For a setup token, say the plan with `--plan`.
- **A setup token needs no Mac login and no renewal for a year.** Use one for long-running
  sandboxes, or when a sandbox should bill another subscription. `doctor` warns 30 days before it
  expires.
- **No silent fallback.** A missing, expired or held credential is refused with a message saying
  what to do. The sandbox never switches to another account or to an API key by itself.
- `doz key set NAME --claude-login` still works: it is `account use NAME mac`.
  `key set NAME --anthropic` gives the sandbox a key of its own and takes it off its account.

### The Mac's login: how renewal works

Dozer reads only the **access token** of the Mac's Claude Code login, never the refresh token.
The Mac's Claude Code is the one program that renews the login, so the two can never fork it. The
access token lives about 8 hours. Claude Code renews it when a `claude` process runs on the Mac
within 5 minutes of expiry; `claude auth status` does not renew it.

- The host re-reads the login every 2 minutes: one read per login, however many sandboxes use it.
  A renewed token reaches every sandbox, and their sessions keep working without a restart.
- **The login expired** (say, nothing ran Claude Code on the Mac overnight). The proxy re-reads
  once. If the login is still expired, it answers with a message that Claude Code in the sandbox
  shows: "this Mac's Claude login expired at 04:59 — open Claude Code on the Mac (any prompt), then
  retry". The session recovers by itself when the Mac renews.
- **Keep-alive (off by default):** `doz account keepalive on`. Within 10 minutes of expiry, if a
  sandbox used the Mac login in the last 15 minutes and no Claude Code runs on the Mac, the host
  runs the Mac's own `claude -p ok --model haiku` once. Claude Code's normal startup renews the login
  under its own lock, at the cost of one tiny turn on your subscription.
- **The Mac signs out:** the sandboxes' token is cleared at once, and requests get "this Mac's Claude
  Code signed out".
- **A different account signs in on the Mac:** sandboxes on `mac` are **held** and don't silently
  switch identity or billing. `doz account use NAME mac` follows the new account.
- **A locked keychain** keeps the last token and warns (`doz events`).
- **Several Claude config dirs** (`CLAUDE_CONFIG_DIR`): Claude Code keeps one keychain item per
  directory. `doz account add work-mac --claude-login --config-dir ~/.claude-work` adds another
  one. `doz doctor` lists every Claude login item in the keychain (attributes only).

`doz doctor` checks that Claude Code is installed, whether it is signed in with a subscription
(or an API key, or not at all), the plan, who is signed in, and when the access token expires.
`account use … mac` makes the same checks and changes nothing when they fail.

### A credential the guest brings itself

The proxy decrypts api.anthropic.com anyway, so it sees every credential. A **credential doz
never issued**, such as a guest `/login` or a pasted key, is classified by the **key policy**:

```bash
doz key policy NAME allow    # pass it, and flag it
doz key policy NAME strict   # refuse it
doz key policy NAME auto     # the default: strict for a setup-token or api-key account, allow for mac
```

- **allow:** the request goes through. The net log says `own credential (oauth sk-ant-oat01…, fp
  ab12cd34ef56)`, `ls` marks the sandbox `own key`, `key ls` lists the fingerprints, and an event is
  recorded once per credential. A fingerprint is the first 12 hex of the credential's sha256,
  never the value. Dozer's own credential is never added to a request that carries the guest's.
- **strict:** refused with 403 and an explanation that Claude Code shows. The Claude sign-in hosts
  are denied too, so a `/login` in the sandbox can't finish. This pins a sandbox to its account,
  for billing and multi-account setups.

What Claude Code in a sandbox does:

- It never tries to refresh the placeholder (it holds no refresh token).
- `/logout` only clears local files. It has no effect on the Mac or the sandbox's credential.
- `/login` warns that `CLAUDE_CODE_OAUTH_TOKEN` overrides it. A login it completes is ignored while
  the placeholder is set, and the key policy flags or refuses it once used.

### Keys given directly, and restarts

```bash
doz key set NAME --anthropic                       # prompt (no echo), or: … < keyfile
doz key set NAME --anthropic --keychain SERVICE    # read from a keychain generic password
doz key ls NAME                                    # keys, account, state, expiry, policy, foreign fingerprints
doz key rm NAME --anthropic
```

- **A key from stdin or the prompt lasts while the host runs.** When the host stops (idle exit,
  `host stop`, a reboot), set it again. Accounts and keychain keys are read again whenever a new
  host loads the sandbox.
- **Sessions survive a host restart with their credentials.** The sandbox's `doz.json` keeps
  a sha256 of each live placeholder, never the placeholder itself, so a session that hibernated
  through `host stop` keeps working in the new host. `shutdown`, `reset` and `rm` revoke them.
- To store a key in the keychain yourself: `security add-generic-password -s doz-anthropic -a
  "$USER" -w` (it prompts for the key).

## Network

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

A sandbox keeps the policy it was created with: when a preset gains a host (the `agent` preset's
Claude Code and GitHub hosts came in 594), a sandbox made before gets it with
`doz net policy NAME --preset agent` — which replaces any rules you added by hand.

```bash
doz net policy NAME                                  # show
doz net policy NAME --allow github.com --allow '*.githubusercontent.com'
doz net policy NAME --deny example.com --remove github.com
doz net policy NAME --preset open
doz net log NAME [--denied] [--follow]              # host, verdict, rule, bytes; never contents
```

Policy changes apply to the next connection and are kept for the next start. A name the policy
cannot allow doesn't even resolve. Current limits: IPv4 only, HTTP/1.1 on the hosts whose traffic
the proxy decrypts, UDP refused (clients fall back to TCP), and no port forwards from the Mac into
a sandbox yet.

## Restore points, templates and duplicates

Restore points are instant, disk-only copies (APFS clones). They cover the disks, not memory.

```bash
doz point take NAME [POINT] [--note …]      # a running sandbox pauses for milliseconds
doz point ls NAME
doz point revert NAME POINT                 # shuts down; a "before revert" point is taken first
doz point fork NAME POINT NEWNAME           # a new sandbox from that point (cold-boots on start)
doz point rm NAME POINT
doz point save-image NAME [POINT] --as myimage [--note …]    # a custom image (a template)
doz up other --image myimage
```

```bash
doz image ls                   # built-in images and templates, and whether each is baked here
doz image ls --tree            # the lineage, with each disk's size, shared bytes and own bytes
doz image bake claude-code     # bake now rather than at the first start (minutes, needs network)
doz image rm NAME              # sandboxes already made from it keep working
```

`image pull` / `push` are not built yet (exit 7).

`doz image ls --tree` draws the lineage — OCI base → baked image → template → the sandboxes on
each — with each disk's size, the bytes it shares with its parent (APFS clones: counted once on
disk) and its own bytes (what removing it frees):

```
IMAGE / SANDBOX   KIND      SIZE    SHARED  OWN
alpine-3.20       prepared  34 MiB  —       116 KiB  prepared disk e998d5b4deb3
├─ tpl-a          template  36 MiB  33 MiB  160 KiB  from alpha
├─ alpha          sandbox   36 MiB  33 MiB  0 B
└─ beta           sandbox   34 MiB  34 MiB  224 KiB
```

### Templates

A **template** is a sandbox's root disk saved as an image other sandboxes are created from:

```bash
doz template create alpha --as node-tools --note "node 22 + pnpm"   # now (a live sandbox pauses for ms)
doz template create alpha --from-point before-upgrade --as base-2   # or from a restore point
doz template ls
doz create beta --image node-tools
doz template rm node-tools
```

- **Everything on the ROOT disk is in it**: what you installed or wrote in `/root`, `/etc`, `/usr`,
  `/opt`, caches. Don't save a secret you put there.
- **The state disk is never in it.** An agent image keeps the agent's state (`~/.claude`,
  `~/.pi/agent`: logins, history, tokens) on a separate state disk; a template never includes it, so a
  template can be shared. A sandbox created from a template starts with a fresh state disk.

### Duplicating a sandbox

```bash
doz duplicate alpha alpha-2 --workspace ~/code/other-project --cpus 4 --memory 4G
doz duplicate alpha alpha-3 --from-point before-upgrade --network locked
doz duplicate agent agent-2 --copy-state      # its logins and history too
```

A new sandbox from an existing one's disk (an instant APFS clone), off until you start it. Anything
not given is the source's (its network policy included). A `--workspace` that does not exist is
made (like `create`'s); `--isolated` shares none. The state disk starts **fresh** unless `--copy-state`. Keys (`doz key set`) are not
copied; the account follows `--account`, or the source's.

## The host

The host is started for you by the first command that needs it. It runs detached, logs to
`<store>/host.log` and listens on `<store>/host.sock`.

| | |
|---|---|
| **Idle exit** | It exits after 5 minutes with no running, paused or sleeping VM and no attached client (`$DOZ_HOST_IDLE` minutes, 0 = never). |
| **Looking never starts it** | `ls`, `inspect`, `point ls`, `image ls`, `net policy` (shown) and `key ls` read the store directly when no host runs. |
| `doz host status` | Is one running, and what does it hold? Never starts one. |
| `doz host stop` | Hibernates everything that runs, then exits. The next command starts a new host; `wake`, `attach`, `up` and `exec` bring each sandbox back. |
| `doz host [--foreground] [--idle-timeout MIN]` | Run it by hand (in the foreground, it logs to the terminal). |
| **If it crashes** | The next command starts a new one. Sleeping sandboxes are restored with their sessions. Hibernated ones are untouched. Ones that were running are reported as died (`ls`; `inspect` shows `diedWithHost`), and their disk is checked with `e2fsck` at the next start. |
| **If its program changes** | A host knows the file it runs from. If an update wrote into that file while it ran, macOS stops trusting it and refuses its virtual machines: every start or wake then says "this host's program was updated underneath it — `doz host stop`, then retry", and `host status` and `doctor` say so too. An update that puts a new file in place (as `make install-cli` does) is harmless: the host keeps running its own copy, `host status` notes it, and once nothing runs and nobody is attached it exits by itself so the next command runs the new build. |

### Updating doz

```bash
make install-cli          # the new build goes in next to the running one — nothing running is touched
doz host stop          # sandboxes that run hibernate; the host of the old build exits
doz wake NAME          # (or attach / up / the web UI) — each wakes on the new build, sessions and all
```

A sandbox that was asleep when you updated wakes on the new build with its programs and sessions
where they were. Each snapshot records the exact virtual machine it was taken in (CPUs, memory,
disks, network card, devices, the kernel), and a wake rebuilds that machine — with the kernel it
slept under, even after an update pins a newer one. If a new build can no longer build the same
machine, the wake refuses instead of risking the snapshot, and says so: keep it asleep and wake it
with the doz that slept it, or Shut Down (below).

### If a wake fails

1. `doz host stop`, then wake again. Nothing is lost by trying: a wake that fails keeps its
   snapshot, and so does quitting the host after it.
2. Read what it says. "Updated underneath it" is the host's own program (step 1 fixes it). "Put to
   sleep by doz X in a virtual machine this build cannot rebuild" means waking it needs doz X.
3. Last resort: `doz shutdown NAME`, then `doz start NAME`. This discards the snapshot, so
   running programs and their sessions end, but the disk is kept — files, installed packages, and an
   agent's own history on the state disk. For Claude Code, `claude --continue` in the new session
   picks the last conversation back up.

## The web UI

`doz ui` is a dashboard in your browser for everything in the store, and it can do most of
what the CLI does. (The maintenance and disk-accounting views come later.)

```bash
doz ui                 # serve it, and open it in your default browser
doz ui --print-url     # the same, but print the link instead of opening a browser
doz ui link            # another browser or tab on the UI that is already running
```

It shows every sandbox (phase, RAM held, disk, sessions, network, account), each sandbox's
sessions, restore points, network policy and connection log, keys and their state, the images,
the Claude accounts, the metrics, `doz doctor`, and the host's activity as it happens.

**The setup wizard** (594). A store that was never onboarded opens on it — the steps of
`doz onboard`: **Welcome → Checks** (the doctor's, the required ones marked; a failing one stops it,
with Check again) **→ Claude account** (the Mac's login when it is signed in; an API key or a setup
token in a masked field — or, with `ui.allow_secret_entry` off, the CLI command; or Decide later) **→ Images** (a checklist,
claude-code ticked, each with its download, an estimate and the disk it needs) **→ Preparing** (the
host's progress, a card per image: Step N of M, the step under way, a download bar, the last lines of
output, estimates from this store's last run, the finished steps with their times;
**Continue in the background** leaves it running, **Cancel preparation** stops it) **→ First
sandbox** (optional: a name from the image — `claude-sandbox`, `pi-sandbox`, `lab-sandbox`, `-2`
when taken — and its workspace: **Shared folder** `~/Developer/dozer-sandbox-projects/<name>` by
default, made when it does not exist, typed, pasted or picked with **Choose…** (the Mac's own folder
picker) — or **Isolated**) **→ Done**. The settings file
and your prompt template are written only when missing. The wizard is always reachable again from
**Onboarding** in the navigation (with a dot beside it until the store is onboarded) or **Doctor ›
Run onboarding again**, and **Operations** lists the host's image preparations whoever
started them (`doz onboard` in a terminal too); the badge counts them while they run.

**The navigation.** **Sandboxes** opens the table of every sandbox; under it, each sandbox has its
own entry (its name and a dot in its phase's colour) that opens **its page**:

- a **control bar** across the top — its name, phase, image, RAM held, network (and denied
  connections), account; the lifecycle buttons; Open in Terminal, New shell, Terminal… (attach,
  watch, or a command), Split; Duplicate…, Save as template…; and Details;
- its **terminals**, filling the page — tabs, the split, the boot view, the covers. Arriving at a
  running sandbox whose own session runs attaches to it; otherwise the area offers Start, Open, and
  the running sessions. The address names the session shown (`#/sandbox/NAME/SESSION`);
- a **details** panel beside them (below, in a narrow window): sessions, restore points, the
  network policy and connection log, keys and account, configuration. **Details** hides it; the
  choice is the setting `ui.details_open`.

What you can do from it:

| Page | Actions |
|---|---|
| **Sandboxes** | New sandbox (image or template, network, account, CPUs, memory, workspace folder). Per sandbox: start, pause, resume, sleep, hibernate, wake, shut down, reset, remove. |
| **A sandbox** | The lifecycle; browser terminals; Open in Terminal; run a command in a new detached session; take a restore point, and revert, fork, save as a template, duplicate or delete one; **Duplicate…** and **Save as template…** (below); edit the network policy, with a preview of exactly what changes; set the key policy and the account; remove a key. |
| **All sessions** | A live, read-only view of every session of every running sandbox (below). |
| **Images** | Bake a built-in image; remove an image or a template. **Version** says an agent image's version (and a newer one available, and being prepared). **Lineage** shows the tree. |
| **Onboarding** | The setup wizard again (a dot beside it until this store is onboarded) — the same as Doctor › Run onboarding again. |
| **Operations** | Every action this UI started, newest first, with its live progress, how long it took and its result; filter by sandbox. |
| **Accounts & keys** | Make an account the default; verify one; remove one; keep-alive on or off. |
| **Metrics** | Filter by image, time and steps; download the rows as CSV. |

Reset, remove, revert and every delete ask you to **type the name** first. Shut down keeps the
disk, so it asks with a plain confirmation; "don't ask again" sets the setting
`ui.confirm_shutdown = false` (the **Settings** page turns it back on). An
operation's progress shows in the sandbox's row and in its control bar while it runs (the
host's latest step and the seconds so far — a first start in a store downloads and bakes its image
and can take two minutes), and the page updates when it ends. **Operations** in the navigation
shows how many run (with a spinner) and a red dot when one failed since you last looked (a failure
also shows a message).

**A sandbox's panes are remembered** — which terminals it shows, split or not, which session each
tab shows — by the host, beside the sandbox (not in the browser): after `doz ui` restarts, after a
reload or in another browser the page shows the same panes, attached. While a sandbox is not running
its page shows every session as a pane with its **saved screen** (read-only; you can select and copy
from it) under "Hibernated 2 h ago — its saved screen · press any key to wake": a key (or Wake)
wakes it, and each pane becomes the live session in place. It holds no connection until then.
**New shell** and **Terminal…** always start a **new** session; a session that already runs is
opened from its pane, the empty area's "Open NAME", or Details › Sessions.

**All sessions** is a grid: a tile per session of every running sandbox, each a live, read-only
view (a watch — nothing reaches the session, and it never resizes it), named sandbox · session. A
sandbox that is not running shows a tile per session with its saved screen (or, with none, one tile
with its state) and a button (Wake, Resume or Start); it holds no connection, so the grid never
keeps the host running for it — woken, its tiles go live in place. Click a tile to open that
session on its sandbox's page. Filter by sandbox and phase; pick a tile size (`ui.grid_tile_size`).
Each live tile is a terminal engine and a connection, so only the tiles **on screen** are live, and
at most `ui.grid_live_tiles` (8) at once — the others say "Not live" and how many are. The list of
sessions is read when you open the page, on Refresh, and at most every 10 seconds as sandboxes
change.

**Images › Lineage** draws the tree — OCI base → image → template → the sandboxes on each — with
each disk's size, what it shares with its parent and its own bytes, the same as `doz image ls
--tree`. It is measured when you open it (Refresh measures again).

**Save as template…** saves the sandbox's root disk (now — a running sandbox pauses for
milliseconds — or a restore point's) as a template: everything installed or written on the root
disk, **never the state disk** (the agent's logins and history). **Duplicate…** makes a new
sandbox from its disk with a new name, workspace, CPUs, memory, network or account; the state disk
starts fresh unless you tick "Copy the agent's state disk too". Both are `doz template create` and
`doz duplicate`. The session buttons wait until the
sandbox can take a session, and clicking an action again while it runs does nothing more (it is
already under way). The list has no session count, since counting asks every session inside the
guest; each sandbox's page lists its sessions.

**Keys and tokens in the browser** (594, owner ruling; the setting `ui.allow_secret_entry`, on by
default). The setup wizard's account step and **Accounts & keys › Add an account** take an Anthropic
API key or a Claude setup token (with its plan) in a masked field (`type=password`, no autocomplete, no
spellcheck). The page reads it once and empties the field at once; it goes out only in the body of one
CSRF-checked `POST /api/v1/accounts` — never a URL, a log line, an event, an Operation or an error
message — and the host stores it exactly as `doz account add` does (the login keychain, one tiny check
request). With `doz config set ui.allow_secret_entry false` the page shows the `doz account add` command
instead, and the route refuses; the browser can turn the setting off but never on.

A **sandbox's own key** (what `doz key set NAME --anthropic` does) is taken the same way, under the same
setting: its page, **Keys & account**, has a masked field — one CSRF-checked
`POST /api/v1/sandboxes/NAME/key` body, stored exactly as `doz key set` from a prompt stores it (held by
the host in memory, source `browser`; the guest sees a placeholder; it replaces the sandbox's account and
lasts while the host runs). Off: the page shows the `doz key set` commands. A key from a keychain item
(`--keychain SERVICE`) is still a terminal command.

**Terminals in the browser** (on each sandbox's page). **Open** in the empty terminal area attaches
to its own session (starting it if needed); each session row has **Open** and **Watch**;
**Terminal…** attaches to any session or starts a new one running a command. Terminals are tabs, and
**Split** shows two side by side (⇄ moves a tab to the other side). Closing a tab only closes the
view — the session keeps running, as Ctrl-] does in `doz attach`.

- **Watch** is read-only: nothing you type reaches the session, and it never resizes it.
- **Watch it boot.** **Start** opens a terminal on the sandbox's page that shows
  the start as it happens — doz's timed steps (on a first start, the download and the bake) and
  the kernel's boot console — and then becomes the image's own session in the same pane, with the
  boot log kept in the scrollback. `doz console NAME [--follow]` shows the same console in a
  terminal. Turn it off with the setting `ui.boot_view_on_start = false`: Start then just starts.
  While a step runs it shows a spinner and its seconds so far, and becomes "✓ step — 1.2 s" (or
  "✗ step — why") when it ends; a first start's image pull shows a bar ("pulling node@1a2b3c4d5e6f
  ██████░░░░ 87 / 142 MB 6.1 MB/s ~9 s (3/5 layers)") and then "pulled … : 142 MB in 23 s"; a bake
  step's last two output lines show dimmed beneath. Only finished lines stay in the scrollback. The
  setting `ui.progress = "plain"` shows one line per step instead.
- **A new terminal is a new shell.** **New shell**, **Terminal…** and **Split** start a new shell session
  (`shell-2`, `shell-3`, …); attaching to or watching a session that already runs is a choice in the
  New terminal dialog. Two tabs on one session are marked "shared with tab N".
- **A sleeping sandbox.** When the sandbox is paused, asleep, hibernated or shut down, the
  terminal is covered with its state and one button. **Any key you type wakes it** (or resumes it)
  and the screen comes back where it was, with a note of how long it took ("woke in 0.5 s"). What your terminal answers by itself — focus changes,
  cursor-position and colour replies — never wakes it. A watcher's keys never wake it either.
- **Paste** is filtered like Ghostty's: control characters that could run commands become spaces.
  A paste with line breaks into a program that did not ask for bracketed paste, or over 64 KiB,
  asks first; over 1 MiB is refused.
- **Links** in terminal output are not clickable, and a program inside the sandbox can never read
  or set your clipboard. Cmd-C copies a selection (so does selecting with the mouse); Cmd-V pastes.
  Cmd shortcuts belong to the browser (Cmd-W closes the tab — the session runs on).
- An open terminal keeps the host running, as `doz attach` does; the dashboard alone does not.
- The terminal itself runs in an isolated frame of the page: whatever a sandbox prints can never
  reach your UI session, its cookie or the other terminals.

**Open in Terminal** opens `doz attach` in your default terminal app instead: whatever opens
`.command` files on this Mac (Terminal, or iTerm2 / Ghostty if you've made them the handler). No
permission prompt.

| | |
|---|---|
| **Where** | `http://127.0.0.1:<port>`, a port the system picks. Only this Mac can reach it. |
| **Signing in** | The link it opens (or prints) works **once**, for **five minutes**. It signs that browser in until you close the UI or sign out. Another browser or tab needs another link: `doz ui link`, or run `doz ui` again. Treat a printed link like a password — anyone with it signs in to your UI. |
| **Stopping** | Ctrl-C in the terminal that runs it. Signing out and stopping both end every browser's session. |
| **One per store** | Each store has at most one UI. `--store` (or `$DOZ_STORE`) picks the store, as for every command. |
| **The host** | The UI is a client of the host, like the CLI. Looking never starts a host: with none running, the UI reads the store (nothing is live). It follows the host's events only while a sandbox is live, so an open UI never keeps an idle host from exiting. |
| **Terminals** | In the page: each terminal is opened with a one-use ticket over a WebSocket on the same loopback address, and only for a signed-in browser. Open in Terminal runs `doz attach NAME [SESSION] --store …` in a new Terminal tab (waking the sandbox if it sleeps). The page also shows that command to copy. |
| **Secrets** | Never shown. Keys and accounts appear as a state, a source name (`keychain:…`, `account:mac`) and a fingerprint. |

`--print-url` prints only to a terminal (not with `--json`, not into a pipe or a file), because the
link is a key to the UI.

## Settings

Settings live in one file, `~/.config/dozer-sandbox/doz.toml` (under `$XDG_CONFIG_HOME` when that
is set). It lists every setting, grouped in sections, each with a description and its default
commented out:

```toml
[ui]

# Start opens a terminal on the boot sequence (the kernel console) until the sandbox is up; false:
# Start just starts it.
# (boolean; applies at once (the UI re-reads it))
# boot_view_on_start = true
```

Uncomment a line to set it — or let doz write it:

```bash
doz config                               # every setting: value, source (flag / env / file / default), default
doz config set ui.boot_view_on_start false
doz config get ui.boot_view_on_start     # false
doz config unset ui.boot_view_on_start   # back to the default
doz config init                          # write the file with everything commented out
doz config path
```

The web UI's **Settings** page shows the same list — each setting's value, default, description
and where the value came from — and changes a value in place. A `[ui]` setting applies at once;
the others say when they apply (the next sandbox created, the next session, or after
`doz host stop`).

| Section | Settings |
|---|---|
| `[ui]` | `boot_view_on_start` (true), `confirm_shutdown` (true), `split_default` (`shell` · `watch` · `attach` · `dialog`), `terminals` (true), `terminal_font_size` (13), `theme` (`auto` · `light` · `dark`), `details_open` (true), `grid_live_tiles` (8, 1–12), `grid_tile_size` (`small` · `medium` · `large`), `progress` (`animated` · `plain`; `$DOZ_PROGRESS`, `--progress auto\|plain`) |
| `[host]` | `idle_timeout_minutes` (5; `$DOZ_HOST_IDLE`), `screen_capture_minutes` (5, 0–1440; `$DOZ_SCREEN_CAPTURE` — how often a running sandbox's changed session screens are saved; 0 = only at pause, sleep, hibernate and shutdown), `keepalive` (false — for a store that has not chosen with `doz account keepalive`) |
| `[store]` | `path` (`--store`, `$DOZ_STORE`) |
| `[claude]` | `permissions` (`skip` · `ask`) — Claude Code's own prompts in a claude-code sandbox; `-e DOZ_CLAUDE_PERMISSIONS=…` on `run`/`exec` still wins |
| `[defaults]` | `cpus` (2), `nat_subnet` (a free one; `$DOZ_SUBNET`) |
| `[images]` | `claude_code_version`, `pi_version` (`latest`, or an exact version like `2.1.227` — see "Agent versions" below) |
| `[images.lab]` · `[images.claude-code]` · `[images.pi]` | `memory_mib` (1024 · 2048 · 2048), `network` (`bake` · `agent` · `agent`) — a custom image follows the image it was saved from |
| `[kernel]` | `path` (`$DOZ_KERNEL`), `cache` (`$DOZ_KERNEL_CACHE`) |

- **Precedence:** a command-line flag, then its environment variable, then the file, then the
  default. A value the environment sets is read-only on the Settings page (change it where it is
  set), and so is a host path (`store.path`, `kernel.*`: `doz config set`).
- **The file is doz's.** `set`, `unset`, `init` and the Settings page rewrite it whole from the
  list of settings (atomically, readable only by you): comments you add are not kept. A key it
  doesn't know is a warning and is kept; a file that doesn't parse is ignored — with the line that
  is wrong — and never overwritten until you fix it.
- **Not settable, on purpose:** the web UI's limits and checks (session and link lifetimes, request
  and connection caps, Host/Origin/CSRF, the content policy), the terminal's one-use tickets and
  paste limits, the guest binaries, and any credential. `ui.terminals` can only take something away.

## Scripting

- `--json` on every command: JSON on stdout; errors as `{"error":{"code","message"}}`. Fields are
  only ever added.
- `-q` prints no progress. `-v` prints every step (by default only operations slower than a second
  show their steps, on stderr).
- **Progress on a terminal is animated** (`--progress auto`, the default): a spinner on the step
  under way, redrawn in place, then "✓ step — 1.2 s"; a download as a bar with bytes, speed and time
  left, then its summary; a bake step's last output lines, dimmed. `--progress plain` (or
  `DOZ_PROGRESS=plain`, or the setting `ui.progress = "plain"`) prints one line per step and a
  summary per download. When stderr is not a terminal, with `--json`, or with `NO_COLOR` set, it is
  always plain — nothing is redrawn and no escape sequence is written.
- `doz console NAME [--follow]` prints the sandbox's boot console (the kernel and init); with
  `--follow` it keeps printing as it boots (the web UI's boot view shows the same lines).
- `doz events [NAME]` follows phases and timed steps live. `doz metrics [--csv] [--image X]
  [--days N]` shows every action's count, median, p90, min, max and failures.

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
| `DOZ_PROGRESS` | `ui.progress` | `animated` or `plain` progress (the CLI on a terminal, the web UI's boot view) |
| `XDG_CONFIG_HOME` | — | where `dozer-sandbox/doz.toml` is (default `~/.config`) |

The kernel, subnet and `[defaults]` / `[images.*]` settings are read (by the host) when a sandbox
is created, and become part of it.

## Troubleshooting

| symptom | try |
|---|---|
| "cannot boot a VM" / entitlement | `doz doctor`. Reinstall with `make install-cli` (it signs). |
| First start is slow | It is preparing the image, once per store. `doz onboard` (or `doz image bake …`) does it ahead of time; `-v` shows the steps. |
| An agent's sessions do not start: "the agent prompt does not render" | A `{{variable}}` not on the list, in `agent-prompt.md` or the sandbox's own prompt. `doz inspect NAME --prompt` names it; or `doz config set agent.prompt false`. |
| The agent does not know where it runs | `doz inspect NAME --prompt`. A claude-code sandbox from an image baked before 594 lacks the launcher part: `doz reset NAME`. |
| Start over from nothing | `doz uninstall` (it lists what goes), `make install-cli`, `doz onboard`. |
| An agent says it has no key / 401 | `doz key ls NAME`. A stdin key is gone after the host stopped, so set it again or use `--keychain`. |
| A package install fails | The policy: `doz net log NAME --denied`, then `doz net policy NAME --allow HOST`. |
| A sandbox shows as died | The host crashed while it ran. `doz start NAME` checks the disk and cold-boots it. |
| The UI says "sign in with a new link" | Its link was used or expired, or the UI restarted. `doz ui link`. |
| A browser terminal says "Disconnected" | The UI stopped, the browser signed out, or the tab was silent for a long time. Reconnect (or a new link: `doz ui link`). |
| A browser terminal will not type Chinese/Japanese/Korean | Its engine's input-method support is incomplete; use Open in Terminal for now. |
| Open in Terminal says no app opened it | Make a terminal app the handler for `.command` files (Finder › Get Info on any `.command` file › Open with › Change All…). |
| `doz ui` says the resources are missing | `DozerKit_DozerWeb.bundle` must sit beside the executable. Reinstall with `make install-cli`. |
| Anything else | `<store>/host.log` and `doz events`. |

## Not yet

- Moving a *running* sandbox to another Mac: the snapshot is encrypted with a key specific to each
  Mac. A cold move (shut down, copy, start) works but has no command yet.
- Image pull/push.
- Port forwards.
- IPv6 and HTTP/2 through the proxy.
- An idle auto-suspend scheduler: today nothing pauses or sleeps a sandbox by itself.
