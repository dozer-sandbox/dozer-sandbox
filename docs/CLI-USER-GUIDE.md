# `doz` user guide

`doz` runs Linux sandboxes on your Mac that pause in a millisecond, hibernate to disk and wake
in about a third of a second, with the programs inside them still running where they were. It is
the command-line face of DozerKit. New to it? Start with the
[walkthrough](CLI-WALKTHROUGH.md). The [user manual](manual/README.md) covers the same ground by
task, for the CLI and the dashboard side by side; this guide is the terse command-line companion.

## Concepts

| | |
|---|---|
| **Sandbox** | One Linux VM with its own disk, named by you (`a-z 0-9 -`, 1–40 characters). |
| **Image** | What a sandbox starts from: a baked, read-only disk. Built in: `lab` (Alpine + bash and `fd`, 1 GiB RAM), `claude-code` and `pi` (Debian `node` + the agent and a developer baseline — git, curl, jq, `rg`, `fd`, python3, … — 2 GiB). Custom images are saved from a sandbox. |
| **Session** | A terminal program living in the sandbox (a shell, `claude`, `pi`). It survives pause, sleep and hibernate. You *attach* to it and *detach* from it; it keeps running either way. |
| **Workspace** | A folder of your Mac shared into the sandbox at `/workspace`. |
| **Host** | One background `doz` process per user and store. It owns every running VM, the network proxy and the keys. It starts when needed and exits when idle, so you never manage it. |
| **Store** | Where everything lives on disk: `~/Library/Application Support/dozer-sandbox` unless `--store` or `$DOZ_STORE` says otherwise. Each store has its own images, sandboxes and host. |

## Install

With Homebrew (Apple silicon, macOS 26 or later) — seconds, no compiler:

```bash
brew install dozer-sandbox/tap/doz
doz onboard                       # once: set up this Mac
```

Afterwards: `brew upgrade doz` (or `doz update`) for a new release — doz tells you when one is out — safe with a host running (below) — and `brew uninstall doz` to remove it.

A VM can only be booted by a binary signed with Apple's virtualization entitlement; the release is
signed with it (ad hoc today — enough for Homebrew, which never quarantines a formula's download;
with a Developer ID and notarised once one is configured, see *Building from source*). An unsigned
build runs every command but cannot boot anything, and `doz doctor` (and `doz onboard`) say so.

### Building from source (contributors)

```bash
git clone https://github.com/dozer-sandbox/dozer-sandbox.git && cd dozer-sandbox
make install-cli                  # PREFIX=~/.local by default → ~/.local/bin/doz (signed)
make cli                          # a signed debug binary at .build/debug/doz, for development
make release VERSION=X.Y.Z        # the Homebrew artefact: dist/doz-X.Y.Z-macos-arm64.tar.gz + .sha256
```

`make release` builds release, packs the install layout (`bin/doz` → `libexec/doz/{doz, VERSION,
resource bundles}`) and signs it — with the Developer ID in a gitignored `Makefile.config`
(`SIGN_IDENTITY`, and `NOTARY_PROFILE` to notarise with `xcrun notarytool`; see
`Makefile.config.example`), else ad hoc, and says which. The hardened runtime is used with a
Developer ID (the virtualization entitlement works under it). A bare command-line tool cannot be
stapled: Gatekeeper checks a notarised `doz`'s ticket online the first time it runs.
`make release … DRY_RUN=1` prints every command it would run. Do not mix a Homebrew `doz` and a
`make install-cli` one on the same `PATH`.

## Setting up this Mac: `doz onboard`

```bash
doz onboard                                   # asks on a terminal; Enter takes the recommended answer
doz onboard --images claude-code,pi --yes     # scripts: ask nothing (--yes, --json or no terminal)
doz onboard --all-images | --no-images        # every image (~15+ min the first time) · none now
doz onboard --account mac|api-key|setup-token|later   # answer the account step (and skip the Claude Code checks)
doz onboard --account setup-token --account-name work --plan max --secret-stdin --yes < token.txt   # scripts: the token from stdin
doz onboard --github off|read|push [--github-source gh|key] [--github-key-stdin] --ssh-agent on|off   # answer the rest of Access
doz onboard --status                          # the record and the images; follows a preparation that runs
doz onboard --cancel                          # stop the images being prepared
```

It does, in order:

1. **Checks** — the doctor's. The *required* ones stop it when they fail: Apple silicon, macOS 26+,
   virtualization, the entitlement, the guest tools, the store on APFS with room for the chosen
   images, a store path short enough for its socket. The rest only warn: Claude Code missing or
   signed out (a claude-code sandbox still works with an account added later), vmnet (only
   `--network nat` needs it).
2. **Access** — every credential sandboxes may use as you, each a purposeful choice, then each
   **confirmed live**; a failure says why and is **skipped** (the choice kept, *not confirmed*) — the
   onboarding never blocks, and `--yes` off a terminal never asks (exit 0, a note per skip). `doz
   access` shows and confirms them again later; `doz access set` changes one.
   - **GitHub as you** — off (the default), read or push (`defaults.github`), the token from this Mac's
     `gh` login or a token you give (`github.credentials`): confirmed by `GET https://api.github.com/user`
     over the proxy's own TLS leg — *signed in as LOGIN* with a classic token's scopes, or how many
     repositories a fine-grained token sees.
   - **SSH agent forwarding** — off (the default) or on (`sandbox.ssh_agent`): confirmed by asking
     the Mac's ssh-agent for its keys (*the ssh-agent has N keys*).
   - The choices are the **defaults for new sandboxes** (written even into an existing `doz.toml`, but
     only when chosen — a flag or an answer; `--yes` alone changes nothing).
   - **The Claude account** — offered, never logged in for you. Claude Code signed in on this Mac: "use
   this Mac's login" (the account `mac`) is the default. Otherwise: **an API key or a setup token,
   pasted right there** at a no-echo prompt (with its account name, and the plan for a token) and
   stored exactly as `doz account add` stores it — the login keychain (`doz-anthropic:NAME`,
   `doz-claude:NAME`) after one tiny check request — then made the store's default; or **Decide
   later** (nothing changes). Off a terminal the key is read from stdin only with `--secret-stdin`
   (as `doz account add` reads it); otherwise the step is skipped and the command shown. Onboarding
   never touches Claude Code's refresh token. The account chosen is confirmed too (this Mac's login
   signed in; a key or token by `doz account verify`'s check) — "Decide later" is not checked.
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
- **Images are never rebuilt without you** (owner ruling, 594). `doz onboard`, the wizard, `doz
  image bake`, `doz create` and a first start ask the registry (one small request, remembered for an
  hour in `<store>/agent-versions.json`). A newer release is only **said** — `doz image ls` (a STATUS
  column: `update available`), the Images page (a badge), `doz doctor` and `doz create`: "Claude Code
  2.1.290 is available (image has 2.1.285)". So is an image **an older doz made** ("prepared by an
  older doz — this doz's image adds: sudo, package lists"). The image you have keeps being used until
  you rebuild it: `doz image bake claude-code` (or Rebuild on the Images page) — existing sandboxes
  keep their disks; new sandboxes and `doz reset NAME` use the new image.
- **Creating with an out-of-date image** says so and lets you choose: on a terminal `doz create` /
  `doz up` ask "Rebuild it first (~2 min, needs network; existing sandboxes are NOT affected)?"
  (Enter: use the current image); `--rebuild` or `--use-current` decide up front; off a terminal or
  with `--json` the current image is used, with a warning (`imageNotice` in the JSON). The New
  Sandbox form shows the same choice. `doz ls` and a sandbox's page name a sandbox made from an older
  doz's image; `doz reset NAME` (after a rebuild) moves it to the new one — it keeps the agent's own
  state (`~/.claude`, `~/.pi`) and `/workspace`, and drops everything else installed on its system disk.
- **Preparing at create time:** `doz create NAME … --prepare` prepares what the sandbox's first start
  would wait for — its image, downloaded and baked once, with the same progress `doz onboard` shows (a
  preparation already running for that image is joined) — and leaves the sandbox off. With `--json`
  the answer carries `"imagePreparation": "prepared"` (it ran, or was joined, to the end) or `"ready"`
  (nothing to prepare). Ctrl-C stops watching; the preparation goes on in the host.
- **Offline:** the registry not answering is noted in `host.log` and the image already prepared is
  used. `latest` with no network and **no image yet** fails, saying so — set an exact version
  (`doz config set images.claude_code_version 2.1.227`). An exact version this store knows (the
  built-in one, or one it prepared or resolved before) always works without asking.
- **A sandbox keeps its version.** Its root disk is the image it was created from; `doz reset NAME`
  gives it the image's current version (and a fresh root disk). Inside a sandbox Claude Code never
  updates itself (`DISABLE_AUTOUPDATER=1`, `DISABLE_UPDATES=1` in its sessions).

## Projects: `doz init` and `doz_project.yaml`

```bash
doz init [DIR] [--name N] [--image I] [--cpus N] [--memory M] [--network …] [--permissions W] [--account A]
         [--github off|read|push] [--ssh-agent on|off] [--clipboard write|off] [--browser-bridge on|off]
         [--open-files on|off] [--[no-]tmux] [--[no-]agent-sudo] [--yes] [--force]
cd DIR && doz up             # no name: this folder's sandbox
```

`init` makes a folder (made when missing) a project: it writes `doz_project.yaml`; it onboards this Mac
first if it never was. **599f: on a terminal it walks the dashboard's New Sandbox wizard's ten steps**
(`ProjectWizard.steps`, one list for both — "Step N of 10"): folder and name, agent and base, account,
access (GitHub, SSH agent), workspace rules (599g: the folder's .dozignore/.dozreadonly and `ignore_mode`),
permissions and network, resources (CPUs, memory — the disk is the image's),
bridges, session (tmux, sudo), review (the file shown, then "Write?"). Each question's default is the
setting's (Enter keeps it); a flag answers its question. Only what differs from the settings — or was set
by a flag — is written; the rest stays commented. In a folder with a project file it starts from that file
and replaces it only after printing the diff and a yes (`--force`: without asking; off a terminal without
`--force`: refused). `--yes`, `--json` or no terminal: every default, no questions. `doz_project.yml` is
read too; a folder with both is an error. The dashboard's **New sandbox** is the same wizard: its review
shows the exact file (rendered and read back by this CLI's own parser, which `doz ui` hands it), writes it
(an existing file only after its diff is confirmed), then makes the sandbox as `doz up` would and opens it. **`doz up` with no name**, in that folder, creates, starts or wakes exactly
that sandbox — the folder is its `/workspace` — starts its `sessions` (the first is attached, the
others detached) and keeps the sandbox's own agent prompt in step with the file (it applies from the
next session). Options given to `up` win over the file's, for a new sandbox.

**When a change to the file applies** (the file's comments say it too): `image`, `cpus`, `memory`,
and a `network` of `nat` or `none` are the VM's make-up — only a new sandbox gets them (`doz rm NAME
&& doz up` recreates it; the folder is kept); a proxied `network` preset (`agent`, `bake`, `locked`,
`open`) is applied by the next `doz up`, live — unless you edited the policy since; `account`: `doz
account use NAME ACCOUNT`; `sessions` at every `doz up`; `agent_prompt` and `agent_sudo` from the next
session. `doz up` says each difference and what it did ("cpus 2 → 4 in doz_project.yaml: applies only
when the sandbox is made — …", "network agent → locked …: applied now (live …)").

```yaml
# doz_project.yaml
version: 1
name: webapp                # the sandbox
image: claude-code          # claude-code, pi, lab or a template (an image from a Dockerfile: not yet)
cpus: 4                     # optional, like the rest below (the settings' defaults otherwise)
memory: 4G
network: agent              # agent, bake, locked, open, nat, none
permissions: "+web"         # standard, locked, open, or changes on Standard (a network with permissions only)
account: default            # default, none, or an account name
sessions:                   # what `doz up` starts; the first is attached
  - claude                  #   the image's own session
  - name: server            #   a session of your own (no shell: the command is split on spaces,
    command: npm run dev    #   or give a list: [npm, run, dev])
agent_prompt: |             # this project's own lines for the agent
  The tests run with `make test`.
agent_prompt_mode: append   # or replace
agent_sudo: true            # the agent's passwordless sudo (default: the setting sandbox.agent_sudo)
clipboard: write            # a copy in the sandbox reaches the Mac clipboard, with a notice; off: never (applies at once)
browser_bridge: on          # xdg-open opens http(s) URLs in the Mac's browser, a sign-in's callback forwarded; off: never
open_files: on              # xdg-open FILE opens a /workspace document in the Mac's default app, with a notice; off: never
ssh_agent: off              # on: forward this Mac's SSH agent (keys stay on the Mac; github.com:22 only)
github: off                 # read or push: git and gh signed in as you on GitHub (the token never enters the sandbox)
tmux: false                 # true: sessions run inside tmux (from the next session)
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
installed; a `doz` Homebrew installed is Homebrew's — it says so, and ends with `brew uninstall
doz`) — and asks once; no terminal and no `--yes` refuses (exit 5). A running host is stopped
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
doz create NAME --image lab|claude-code|pi|<base>-<agent>|<custom> \
    [--cpus 2] [--memory 2G] [--workspace ~/code/proj | --isolated] \
    [--network agent|bake|locked|open|nat|none] [--subnet CIDR]
doz create NAME --agent claude-code|pi|none --base python     # or --dockerfile ./Dockerfile

doz up NAME [same options] [--session S] [-d] [-- CMD …]
doz new [--image I] [--name N] [--isolated] [-d]
```

- **`doz new` — the quickest way in (599c).** Every default: the image `defaults.image`, the image's
  name (`claude-sandbox`; `-2`, `-3` when a sandbox has it or its folder is not empty), its workspace
  `<defaults.projects_dir>/<name>` (made), the default account and permissions. It prints what it
  chose (`claude-sandbox-2 · claude-code · ~/Developer/dozer-sandbox-projects/claude-sandbox-2`),
  starts it and attaches. `--image`, `--name`, `--isolated` and `-d` change just that one thing;
  `--json` answers `{name, image, workspace, phase, session, milliseconds}` without attaching. The
  prerequisites are `doz create`'s: pi's API-key account (on a terminal: chosen or added; off one: the
  next step, nothing made — `doz new` uses the store's default account), an out-of-date image (asked).
  The web UI's **Quick add** (Sandboxes, and the **+** beside Sandboxes in the sidebar) is the same
  in one click: made, started with the boot view, its page open — or, when one click cannot decide,
  the New sandbox form with the requirement said.
- **The agent and the base (596).** A sandbox's image is two choices: the agent (`--agent
  claude-code`, `pi`, or `none` for a shell only) and the base — a recommended one (`--base node`,
  `python`, `go`, `rust`, `java`, `ruby`, `dotnet`, `debian`, `ubuntu`, `alpine`; `doz base ls` shows
  each image, its download and its first-prepare time) or **your own Dockerfile** (`--dockerfile
  PATH`). Dozer adds its developer baseline and the agent on top — Claude Code as its standalone
  native build on a base without Node (no Node is added for it), pi with Node under `/opt/node`. The
  image is named `<base>-<agent>` (`python-claude-code`; `debian` for no agent); `claude-code`, `pi`
  and `lab` are Node · Claude Code, Node · pi and Alpine · none, as before.
- **A Dockerfile** is built with Apple's `container build` — `doz builder status` says whether it is
  installed and running; `doz builder install` opens Apple's signed installer package in macOS
  Installer (you approve it; doz never uses sudo); `doz builder start` starts its services (they
  register with launchd and run in the background). The Dockerfile's folder is the build context and
  the workspace unless you give one. **Its `RUN` steps run in Apple's builder, outside Dozer's
  network policy** — they reach the internet directly; the sandbox made from the image is under the
  policy as usual. An unchanged Dockerfile re-prepares in seconds and bakes nothing; a changed one is
  said ("Dockerfile changed — rebuild available"): `doz image bake df-…` rebuilds, `doz reset NAME`
  takes the new image.
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
  `defaults.projects_dir` (`doz config set defaults.projects_dir PATH`, or Settings › **Choose…** in
  the web UI — the Mac's folder picker, whose answer the server writes) — with **Isolated** one
  click away; `doz new` uses the same folder; `doz create` has no default folder, and `doz init`
  uses the folder it runs in.
- `--agent-prompt FILE [--agent-prompt-mode append|replace]` gives the sandbox its own part of the
  agent's environment prompt (below).
- `--no-agent-sudo` (or `--agent-sudo`) decides the agent's sudo for this sandbox (below); without
  it, the setting `sandbox.agent_sudo` decides.

**The agent has passwordless sudo** (owner ruling, 594): in a claude-code or pi sandbox the agent
(the `agent` user) can `sudo apt-get install -y PACKAGE` — the image keeps apt's package lists
(~18 MiB, shared by every sandbox of the image; `sudo apt-get update` refreshes them) and the
`agent` network preset allows Debian's archive. Root inside the VM reaches no more than the agent:
the VM has no network interface (every connection still goes through your policy), no credential
is inside it, and nothing of your Mac but the `/workspace` share. `doz reset` or a restore point
undoes what it installed. Turn it off for every sandbox with `doz config set sandbox.agent_sudo
false`, or for one with `doz create --no-agent-sudo` / `agent_sudo: false` in `doz_project.yaml`;
it applies at the sandbox's next session and every boot — no image is rebuilt. (The first
preparation after 594 rebuilds the agent images once: they gained `sudo` and keep apt's lists.)

## Working inside

| | |
|---|---|
| `doz attach NAME [SESSION]` | Your terminal becomes that session (without SESSION: the sandbox's own — `claude`, `pi` or `shell`). **Ctrl-]** opens a one-line menu over the bottom row — `d detach · n next · p prev · s sessions · Esc back` — and **a second Ctrl-]** (or `d`) detaches, however the program has set up your terminal's keyboard (plain, the kitty keyboard protocol, xterm's modifyOtherKeys); `--detach-key ctrl-x` or `none` choose another (see "The title and the Ctrl-] menu"). On the way out your terminal is put back as it was (mouse, paste and keyboard modes), and the line names the shortest command that comes back: `doz up` in the sandbox's project folder, `doz attach NAME` for its own session, else `doz attach NAME SESSION`. A paused or sleeping sandbox is woken first (`--no-wake` waits instead). If the sandbox hibernates while you are attached, the client waits and reattaches by itself when it wakes. |
| `doz run NAME [--session S] [-d] -- CMD …` | Open a **new** session running CMD and attach. It exits with CMD's exit code. There is no shell in front, so write `bash -lc '…'` if you want one. A sandbox that is off is started first (`--no-start` refuses instead). |
| `doz exec NAME [--user U] [--workdir D] [-e K=V] [--timeout S] -- CMD …` | One-shot, no terminal: stdout, stderr and the exit code pass straight through (default timeout 120 s). On agent images it runs as the agent's user in `/workspace`; `--user root` for root. A paused or sleeping sandbox is woken and one that is off is **started** first (its progress on stderr; `--no-wake`, `--no-start` refuse instead); `--json` says so: `"started"`, `"woke"`, `"bootMilliseconds"`. So `doz create NAME … && doz exec NAME -- CMD` just works (or `doz create --start`). |
| `doz sessions restart NAME SESSION [--fresh] [-d] [--yes]` | End the session's program (hung up, then terminated, then killed if it must be) and start the same program again in the same session, folder and user; then attach (`-d`: not). The sandbox's own agent session continues its conversation (Claude Code `--continue`, Codex `resume --last`, pi `--continue`); `--fresh` starts a new one. A running sandbox only — it never wakes one. Asks first on a terminal. |
| `doz sessions end NAME SESSION [--yes]` | End the session's program, the same way. Anything attached sees it end. |
| `doz sessions NAME [--screen SESSION [--vt]]` | The sandbox's sessions. While it is paused, asleep or hibernated they are listed from their **saved screens**, and nothing is woken. A shut-down sandbox has none ("no sessions — NAME is shut down"): Start boots it fresh, with new sessions. `--screen SESSION` prints that session's last saved screen as text; `--vt` writes its terminal bytes instead — to a file or a pipe (`> s.vt`, then `cat s.vt` in a terminal redraws it), never straight to a terminal. |
| `doz ls` · `doz inspect NAME` | Every sandbox: image, phase, RAM held, disk, sessions, network · everything about one, as JSON. |

**RAM held** in `ls` is what the VM costs your Mac right now: the allocation, less what the memory
balloon handed back after a wake. It is shown as `—` when the sandbox is off or hibernated.

**Saved screens.** Before a sandbox pauses, sleeps or hibernates, doz saves the screen of each of its
sessions — and every `host.screen_capture_minutes` (5) while it runs, for the sessions that printed
something since, which is what a sleep or hibernation falls back on. Saving is a moment's look at the
session (it is not resized, nothing is typed), limited to a few seconds, and a screen that cannot be
saved keeps the previous one — it never holds up the sleep. Each screen is kept as text (the
terminal's own bytes, and plain text) in the sandbox's directory (`screens/`, readable only by you).
Saved screens exist only while you can wake the sandbox back: **shut down, reset, remove — or a host
that died with the VM — delete them**, and a shut-down sandbox shows no session screens anywhere (its
sessions ended with the VM; Start boots it fresh). A session whose program exited has none either.
Duplicate, fork and templates never copy them.

### The title and the Ctrl-] menu

doz keeps no rows of your terminal for itself. Instead:

- **The title.** While attached, `doz attach` sets your terminal's own title (the window or tab) from
  `ui.terminal_title` — by default `{sandbox} · {session} · {time}`, e.g. `webapp · claude · 14:05`;
  the variables are `{sandbox}` `{session}` `{image}` `{time}` (this Mac's, refreshed each minute)
  `{phase}`. When you detach, the terminal's previous title comes back (iTerm2, Ghostty, kitty and
  xterm keep a title stack; Terminal.app keeps doz's until something sets another). While doz sets
  it, the session's own title (Claude Code sets one) is not shown; `doz config set ui.terminal_title
  ""` leaves the title to the session. A terminal's tab in `doz ui` shows the same text.
- **The menu.** **Ctrl-]** draws one line over the bottom row: `d detach · n next · p prev · s
  sessions · Esc back`. `n` / `p` move this same terminal to the sandbox's next / previous session;
  `s` lists them (`1 shell* · 2 claude · …`) and a number switches; `Esc` (or any other key) goes back.
  The screen is held while the menu shows and then redrawn cleanly from the session's own screen, so
  nothing of the menu is left behind. A second **Ctrl-]** — quickly, or at the menu — detaches. With
  a pipe for input (not a terminal), Ctrl-] detaches at once, as before.

## Session bridges

A session's terminal — `doz attach`/`run`/`up`, or a terminal in `doz ui` — is also how a program in
the sandbox reaches your Mac for the few things it needs one for. Each bridge goes through the host
(the one place every terminal passes), is shown to you every time it is used, and can be turned off
for one sandbox (`doz config set --sandbox NAME KEY VALUE`, a flag of `doz create`, a key in
`doz_project.yaml`) or for all (`doz config set KEY VALUE`). A bridge acts only while a terminal is
attached to the session: a program that copies with nobody watching copies nothing.

### The clipboard

When a program copies — Claude Code's copy command, a yank in vim or tmux: the terminal's OSC 52 — the
text goes on **your Mac's clipboard**, and a notice says so: `SANDBOX copied N chars`, drawn over the
bottom row of `doz attach` for 3 seconds (then the screen is redrawn), or a message in the corner of
`doz ui`. Off a terminal (`doz run … > file`) the notice is a line on stderr.

- **A sandbox can never read your clipboard.** A program's request to read it is dropped — it never
  reaches your terminal either, so no terminal app can answer it for the sandbox — and logged once.
- **Limits:** 1 MiB per copy; at most 10 copies in 10 seconds per sandbox. More is refused, and said.
- **The risk:** an agent could put a command on your clipboard for you to paste. The notice tells you
  every time (the agent's facts say so too); turn the bridge off where you do not want it:

```bash
doz config set --sandbox NAME sandbox.clipboard off   # this sandbox (applies at once)
doz config set sandbox.clipboard off                  # every sandbox without its own choice
doz create NAME --clipboard off …                     # from the start; or `clipboard: off` in doz_project.yaml
doz config show --sandbox NAME                        # its per-sandbox settings, and whose value each is
doz config unset --sandbox NAME sandbox.clipboard     # follow the setting again
```

### The browser, and sign-ins

A sandbox has no browser. Its `xdg-open` (and `$BROWSER`, `open`, `sensible-browser` — every session's
PATH leads with doz's own, installed at each boot) hands an **http or https** URL to your Mac, which
opens it in your default browser, and says so: `SANDBOX opened https://… in your browser`. The session
shows the URL in plain text too.

**Sign-ins that come back to the sandbox.** An agent's browser sign-in (Claude Code's `/login`, most
OAuth CLIs) listens on the SANDBOX's `localhost:PORT` and asks the provider to send the browser back
there (`redirect_uri=http://localhost:PORT/…`). When the URL says so, doz forwards your Mac's
`localhost:PORT` into the sandbox before opening it — the notice says `sign-in callback localhost:PORT
forwarded (10 min)` — so the browser's last redirect reaches the agent and the login completes. The
forward is loopback only, one per sandbox (a new sign-in replaces it), and closes 3 s after the callback
was answered or after 10 minutes. If that port is already in use on your Mac, the notice says the
sign-in cannot come back.

- **Refused, and said:** anything but http and https (`file:`, `javascript:` …), a URL naming the Mac's
  own loopback (`http://localhost:3000` from inside is the sandbox's own server — tell the user the
  address instead), more than 3 URLs in 10 seconds, anything over 2048 bytes.
- **Off:** `doz config set --sandbox NAME sandbox.browser_bridge off` (or for all, or
  `doz create --browser-bridge off`, `browser_bridge: off` in `doz_project.yaml`): nothing opens, and
  the notice says so. A later "Sign in" permission (feature 597) can build on this switch.
- The shim and the forward helper (`deckhold connect`) arrive with the sandbox's next start; a sandbox
  woken from before gets the shim at its next session.

### Workspace files, opened on the Mac

The same `xdg-open` (and `open`, and `doz-open`) takes a **file** too: a document under `/workspace`
(relative names are the caller's folder's) opens on your Mac — the shared folder's own file — in its
default app, and the notice says which: `SANDBOX opened report.html in Safari`. A **folder** under
`/workspace` (`open .` — the workspace itself — or any child) opens in the **Finder** (`open -a Finder`,
never as an app): `SANDBOX opened src/ in the Finder`; `doz-open --reveal PATH` shows a file selected
in its folder (`open -R`; nothing is opened): `SANDBOX showed app.zip in the Finder`. A package folder
(`.app`, a bundle, anything macOS calls a package) is refused even for the Finder — `--reveal` can show
it; `--app` with a folder is refused.

```sh
xdg-open report.html                 # inside the sandbox: the Mac's default app for .html (your browser)
open docs/notes.md                   # the same
doz-open --app Typora notes.md       # a named app — only one listed in bridges.open_apps (also: open -a NAME FILE)
```

- **The path** is mapped to the shared folder and resolved on the Mac; it must stay inside it (`..`, a
  link made in the sandbox or on the Mac that leads out: refused).
- **Documents only:** html/htm, md/markdown, pdf, png/jpg/jpeg/gif/webp/svg/bmp/tiff/heic, txt/log,
  csv/tsv, json/yaml/xml/toml. Never a folder or app bundle; never `.app`, `.command`, `.sh`, `.pkg`,
  `.dmg`, `.webloc` and the like; never an executable file; never a Mach-O/ELF program or `#!` script
  whatever it is named (the first bytes are read).
- **Named apps:** `doz config set bridges.open_apps "Typora, Visual Studio Code"` (names, not paths; empty
  by default — then only default apps). Any other name is refused, naming the setting.
- **Refused, and said:** an isolated sandbox (nothing is shared), `sandbox.open_files` off
  (`doz config set --sandbox NAME sandbox.open_files off`, `doz create --open-files off`,
  `open_files: off` in `doz_project.yaml`), more than 3 files in 10 seconds. The shim refuses what it
  can tell itself first, so the program (or agent) hears why too.

### The tools layer

`doz tools NAME` lists the tools Dozer manages in a sandbox because of its settings — `gh` (GitHub as you;
pinned, downloaded once to the store's `tools/` with its sha256 checked, copied in over the host→guest
path, removed when off), an ssh client + github.com's published host keys (SSH agent forwarding), tmux
(`sessions.tmux`), and always git, curl and ca-certificates (apt/apk through the proxy when missing) — each
with why and its state; `--apply` sets them up again now. On every base, no image rebuild; the first start
shows each as a progress line (`tools: gh 2.102.0 — for GitHub as you`), later starts and wakes re-check
quietly, a failure is never fatal. The New Sandbox wizard's last step, **Setting up tools**, shows the same
(Retry · Continue anyway).

### GitHub as you

Off until you choose it — for new sandboxes (the onboarding's Access step, `doz access set --github
read|push`: the setting `defaults.github`) or per sandbox (`doz net allow NAME github:as-you`, `doz create --github read|push`,
`github:` in `doz_project.yaml`, or the switch in `doz ui`): `git` and `gh` in the sandbox are then signed in
to github.com as you, while the token stays on the Mac — `GH_TOKEN`/`GITHUB_TOKEN` and git's credential helper
(`git-credential-doz`) hold a `doz_cred_` placeholder, which the proxy swaps for the real token on the way to
github.com, api.github.com, uploads.github.com and codeload.github.com (git's Basic login decoded, swapped,
re-encoded), and nowhere else.

- **Read-only** unless `github:push` is on too: the proxy refuses `git-receive-pack` and every non-read API
  call (a GraphQL request passes only when its document holds queries alone — anything unsure is refused),
  with a 403 that says how to allow it. With push, every change is in `doz net log`.
- **The token**: `github.credentials` = `gh` (the Mac's `gh auth token`, read on use, kept in memory a few
  minutes), `key` (a sandbox's `doz key set NAME --github`, stdin or `--keychain`, else the default one from
  `doz access set --github-key` — the login keychain, `doz-github`), or `off`. A sandbox's own key wins.
- **Confirmed**: `doz access` reads the token as a sandbox would and asks `GET /user` — *signed in as LOGIN*
  and the scopes (or, fine-grained, how many repositories it sees); a failure says why (`<store>/access.json`
  keeps the answer, never the token).
- **Identity**: the Mac's global `user.name`/`user.email` in the sandbox's git config while it's on.
- **Off** (`doz net deny NAME github:as-you`) revokes every placeholder at once and removes the identity.
- **SSH**: `doz config set --sandbox NAME sandbox.ssh_agent on` forwards the Mac's ssh-agent (vsock; the keys
  stay on the Mac) and allows github.com:22 only.
- A notice the first time it's used: `NAME used your GitHub login (read-only)`.

### tmux inside a session

Off by default. With `sessions.tmux` on — for every sandbox (`doz config set sessions.tmux true`),
or one (`doz create --tmux`, `tmux: true` in `doz_project.yaml`, `doz config set --sandbox NAME
sessions.tmux true`) — each **new** session runs its program inside tmux: windows, panes, copy mode,
its status bar and its prefix key, **Ctrl-b**. tmux runs *within* doz's own session holder, so
everything else is unchanged: `doz attach` and **Ctrl-]**, sleep and wake (tmux and its programs
are where they were), saved screens (tmux's screen, status bar included), browser terminals, and the
clipboard and browser bridges (a copy and an `xdg-open` from inside tmux reach the Mac). Each session
has a tmux server of its own (`tmux -L doz-SESSION`), and reopening a session finds a program tmux
still holds.

Limits: tmux takes Ctrl-b and the mouse (in `doz ui`, Shift+drag still selects text); the kitty
keyboard protocol and xterm's modifyOtherKeys do not fully pass through tmux, so a program that relies
on them (Claude Code's richer key handling) sees less; the session's exit code is tmux's (0), not the
program's. tmux must be in the image: the built-in images this doz prepares have it; a sandbox on an
image an older doz prepared runs the session without it and says how to get it (`doz image bake`,
then `doz reset`).

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
  (injected by the proxy; the placeholders are expected; never log in or ask for keys); whether it
  has passwordless sudo (and that the policy still applies to root); sleep and hibernation between turns. Claude Code gets it through its launcher (`/run/dozer/agent-prompt.md`
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
`sandbox.sudo`, `sudo.description`, `sandbox.timezone`,
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

- **Which accounts an agent can use** (594):

  | agent | accounts it can use |
  |---|---|
  | Claude Code (`claude-code`) | `mac`, `setup-token`, `api-key` |
  | pi (`pi`) | `api-key` only — pi reads `ANTHROPIC_API_KEY`, the proxy's placeholder for the key; a Claude subscription is never given to it |

  This is checked **before a sandbox is made**, in `doz create`/`up`/`init`/`duplicate`, New
  sandbox, the wizard's First sandbox and Duplicate. With no account pi can use, the CLI stops with
  the next step (`doz account add NAME --api-key`, or `--account NAME`); on a terminal it offers the
  accounts that fit, or a hidden paste of a key right there. The web forms offer only the accounts
  the agent can use, with the masked key field in the form when there are none (or the commands,
  with `ui.allow_secret_entry` off); Create waits until it is met. `--account none` is an explicit
  choice. An existing sandbox whose account does not fit (or has none) says so on its page — "pi
  can't use the account mac — choose an API-key account" — with a picker; the change applies to its
  next session. Its agent is told plainly that no credential is attached (and never to log in).
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

### Codex: OpenAI accounts

Codex sandboxes (`--agent codex`, image `codex` or `<base>-codex`) use OpenAI accounts only — never an
Anthropic one, and no Claude agent ever gets an OpenAI one:

```sh
doz account add chatgpt --chatgpt       # Dozer's OWN ChatGPT sign-in: your browser opens (your Mac's ~/.codex is never touched)
doz account add openai --openai-key     # an OpenAI API key (prompt or stdin)
doz account default chatgpt             # the store's OpenAI default — what Codex sandboxes follow
doz create cx --agent codex --base python
```

The sandbox's `~/.codex/auth.json` holds placeholders; the proxy puts the access token into requests to
`chatgpt.com` (a key: `api.openai.com`) and renews the sign-in on the Mac — Codex's own renewal is
answered by the proxy. Codex runs without approval prompts (`codex.permissions = ask` keeps them). The
manual's [Codex](manual/24-codex.md) page has the details.

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
| `agent` | Anthropic's API and sign-in hosts; what Claude Code reaches on its own (`downloads.claude.ai` for updates, its two Datadog error-reporting intakes `http-intake.logs.us5.datadoghq.com` and `browser-intake-us5-datadoghq.com`); GitHub over HTTPS for git and Claude Code's plugin marketplace (`github.com`, `raw.githubusercontent.com`, `codeload.github.com`, `objects.githubusercontent.com`); `pi.dev` (pi's updates and model catalog); plus package registries — never `api.github.com` (the tools agents fetch from GitHub, `fd` and `rg`, are in the image) | `claude-code`, `pi` |
| `bake` | package registries only (npm, apt, apk, PyPI) | `lab` |
| `locked` | nothing | |
| `open` | everything, still proxied and logged | |
| `nat` | a normal NAT network card, not proxied, no log | |
| `none` | no network at all | |

Since 597 the proxied presets (`agent` = Standard, `locked`, `open`) are sets of **permissions**,
below, stored by name — a Dozer update that adds a host to a permission reaches every sandbox that
has it. A sandbox made before 597 keeps its rules: `doz net NAME` shows them as the permissions they
amount to, and its first permission change stores them as permissions (anything no permission covers
stays as your own site rules).

### What the agent can do — permissions

Most of the time you do not need hosts at all. A proxied sandbox's network is a short list of
permissions, each a switch:

| permission | id | Standard |
|---|---|---|
| Talk to its AI model | `model` | always on |
| Sign in | `sign-in` | off (Dozer's proxy supplies the credential) |
| Update itself | `update` | on |
| Install software — system packages, Node, Python, Go, Rust, Java, Ruby, .NET | `install:system`, `install:node`, … (`install` = all) | system packages + your base's language |
| Use GitHub | `github` | on |
| Send error reports | `error-reports` | on |
| Browse the web | `web` | off — the agent could send your code anywhere |
| Sites you allow | `site:HOST` | none |

Presets: **locked** (the model only), **standard**, **open** (everything). The default for new
sandboxes is the setting `defaults.permissions`.

```bash
doz net NAME                                         # the checklist, and what the agent was refused lately
doz net allow NAME install:python                    # live: the next connection
doz net allow NAME site:api.example.com
doz net deny NAME github
doz net allow NAME web --yes                         # asks first without --yes
doz net permissions                                  # every permission and the hosts behind it
doz create NAME --allow install:rust,site:api.example.com
```

When the agent is refused something a permission would allow, `doz net NAME` (and the sandbox page
in `doz ui`) says so — "the agent tried to install Python packages (PyPI), 3 times" — with the
command (or button) that allows it. A sandbox stores its permissions by name, so a Dozer update that
adds a host to "Update itself" fixes every sandbox that has it.

The raw rules are still there:

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
a sandbox yet (apart from a sign-in's callback, briefly — "The browser, and sign-ins").

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

A point's name is kept exactly as you type it, up to **64 characters** (a longer one is refused,
never cut). Wherever a command takes a POINT — revert, fork, rm, save-image, the web UI — it takes
the name, the id (`rp-…`) or the start of either, as long as only one point matches (otherwise it
lists the ones that do). Commands that ask first (`point revert`, `point rm`, `reset`, `rm`,
`shutdown`, `image rm`, `template rm`) check that what you named exists **before** asking, and the
question names the point's name, id and when it was taken.

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
| `doz host stop` | Hibernates everything that runs, then exits. The next command starts a new host; `wake`, `attach`, `up` and `exec` bring each sandbox back. It shows each sandbox as it hibernates (`✓ hibernated hello-dozer (snapshot 69 MB) — 412 ms`; plain lines off a terminal or with `--progress plain`; a sandbox that cannot be hibernated says why and that it was shut down, its disk kept), then `host stopped — 2 sandboxes hibernated (hello-dozer, lab1) in 1.2 s; the next command starts a new host` — or `host stopped (nothing was running)`. `--json` gives each sandbox's row. If the host dies part way, it says what it saw. `doz uninstall` and the web UI's **Restart host** show the same. |
| `doz host [--foreground] [--idle-timeout MIN]` | Run it by hand (in the foreground, it logs to the terminal). |
| **If it crashes** | The next command starts a new one. Sleeping sandboxes are restored with their sessions. Hibernated ones are untouched. Ones that were running are reported as died (`ls`; `inspect` shows `diedWithHost`), and their disk is checked with `e2fsck` at the next start. |
| **If its program changes** | A host knows the file it runs from. If an update wrote into that file while it ran, macOS stops trusting it and refuses its virtual machines: every start or wake then says "this host's program was updated underneath it — `doz host stop`, then retry", and `host status` and `doctor` say so too. An update that puts a new file in place (as `make install-cli` does) is harmless: the host keeps running its own copy, `host status` notes it, and once nothing runs and nobody is attached it exits by itself so the next command runs the new build. |

### Updating doz

```bash
brew upgrade doz       # (or make install-cli) — the new build goes in next to the running one
doz host stop          # sandboxes that run hibernate; the host of the old build exits
doz wake NAME          # (or attach / up / the web UI) — each wakes on the new build, sessions and all
```

Until then every command that a host of another build answers says so once, on stderr (never stdout,
not with `-q`): `note: the doz host is X (this doz is Y) — doz host stop switches to Y; sandboxes
hibernate and wake` (or, for a NEWER host, to upgrade this doz). `brew upgrade` says when a host of
the previous build is still running (`doz host upgrade-check`,
which you can run yourself). Homebrew then removes the previous version (`brew cleanup`) — the
program that host runs and its resources. The host keeps running, and so does every sandbox it
runs, but it can no longer boot one: a start, a wake or a new sandbox is refused with "this host's
program … is gone — an upgrade removed it — `doz host stop`, then retry", and `host status` and
`doctor` say so. Once nothing runs and nobody is attached, it exits by itself.

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
doz ui restart         # restart the running UI (the same port; open pages carry on by themselves)
doz ui start --port 7443   # (doz ui start is doz ui) a fixed port, this run; the setting ui.port keeps it
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
| **Images** | Bake a built-in image; remove an image or a template. **Version** says an agent image's version (and a newer one available, and being prepared). **Own / Shared**: each image's own blocks and the blocks it reuses from the disk it was made from, as a size and a % of its size, in a two-colour bar. **Lineage** shows the tree. |
| **Resources** | Everything Dozer uses, and deleting what has no other home (below). Its total size is beside it in the navigation. |
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

**The mouse in a browser terminal** works as in a native terminal. A program that tracks the mouse
(Claude Code does) gets the wheel as wheel events, and clicks and drags as mouse events, in the
encoding it asked for. Hold **Shift** to select text instead, or to scroll the pane itself. A program
that does not track the mouse gets nothing from it: the wheel scrolls the pane's own scrollback. In
a full-screen program the wheel becomes arrow keys only if the program asked for that
(alternate scroll, `?1007`).

**A sandbox's panes are remembered** — which terminals it shows, split or not, which session each
tab shows — by the host, beside the sandbox (not in the browser): after `doz ui` restarts, after a
reload or in another browser the page shows the same panes, attached. While a sandbox is paused,
asleep or hibernated its page shows every session as a pane with its **saved screen** (read-only; you can select and copy
from it) under "Hibernated 2 h ago — its saved screen · press any key to wake": a key (or Wake)
wakes it, and each pane becomes the live session in place. It holds no connection until then. A
shut-down sandbox shows none: its page is "Shut down — Starting boots it fresh — new sessions" with
Start, its Sessions list is empty, and its panes are forgotten.
**New shell** and **Terminal…** always start a **new** session; a session that already runs is
opened from its pane, the empty area's "Open NAME", or Details › Sessions.

**All sessions** is a grid: a tile per session of every running sandbox, each a live, read-only
view (a watch — nothing reaches the session, and it never resizes it), named sandbox · session. A
sandbox that is paused, asleep or hibernated shows a tile per session with its saved screen (a
shut-down one, or one with none, is one tile with its state) and a button (Wake, Resume or Start); it holds no connection, so the grid never
keeps the host running for it — woken, its tiles go live in place. Click a tile to open that
session on its sandbox's page. Filter by sandbox and phase; pick a tile size (`ui.grid_tile_size`).
Each live tile is a terminal engine and a connection, so only the tiles **on screen** are live, and
at most `ui.grid_live_tiles` (8) at once — the others say "Not live" and how many are. The list of
sessions is read when you open the page, on Refresh, and at most every 10 seconds as sandboxes
change.

**Images › Lineage** draws the tree — OCI base → image → template → the sandboxes on each — with
each disk's size, what it shares with its parent and its own bytes, the same as `doz image ls
--tree`, each also as a % of the disk's size (■ Own ■ Shared in the bar). It is measured when you
open it (Refresh measures again).

**Resources** is `doz resources` as a page (595). It is an account first: every byte of the store
on a row, grouped — Sandboxes (each one's root disk, state disk, snapshot, restore points, saved
screens and boot logs), Images & templates, Caches (the download cache, base disks, the guest init,
kernels, preparation leftovers), Logs & metrics, Stray files, Dozer's own records — and Outside the
store (the settings file, the keychain entries by name, the CLI, project folders: shown, never
deleted here). Each row has its size on disk, what deleting it would free (a clone frees only what
it does not share) and what uses it, and links to where it is managed: an image to **Images**, a
sandbox's parts to **its page**, accounts to **Accounts & keys**. The rows add up to the total
(what `du` counts); a last row, **unattributed**, is what no row explains — it should be 0 and is
red when it is not. The bar on top is Dozer's own total split into what it keeps, what **Clean up**
would free and the blocks APFS clones share (which `du` counts again); the volume's free space is
written beside it. Below: the memory each sandbox with a VM holds, the host's and this UI's, the
CPUs given to sandboxes, each sandbox's proxy traffic (today and in all) and the kernels — with
**Use this kernel** for the one new sandboxes boot (existing ones keep theirs).

Tick what should go (or **Select all re-creatable**), then **Delete selected…**: one plain
confirmation lists each item, what it frees, what it costs later ("re-prepared when next needed
(about 3 min, needs network)") and what is refused and why, and the deletion runs as one operation
(Operations shows it) — the host waits until nothing that uses the disks is under way. **Clean up…**
is the safe set: what is re-creatable AND unused (the download cache, base disks, kernels nothing
needs, images no sandbox was created from in `resources.clean_unused_days` days, leftovers) — never
templates, sandboxes, restore points, settings or keys; logs and metrics are kept (select them to
clear them). The page is measured when you open it, on
Refresh and when an operation ends.

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
  terminal; the whole boot is kept afterwards (**Boot log** on the control bar, `doz console NAME
  --steps` — below). Turn it off with the setting `ui.boot_view_on_start = false`: Start then just starts.
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
  your clipboard (it can set it only through the clipboard bridge, with a notice each time — "Session
  bridges"). Cmd-C copies a selection (so does selecting with the mouse); Cmd-V pastes.
  Cmd shortcuts belong to the browser (Cmd-W closes the tab — the session runs on).
- An open terminal keeps the host running, as `doz attach` does; the dashboard alone does not.
- The terminal itself runs in an isolated frame of the page: whatever a sandbox prints can never
  reach your UI session, its cookie or the other terminals.

**Open in Terminal** opens `doz attach` in your default terminal app instead: whatever opens
`.command` files on this Mac (Terminal, or iTerm2 / Ghostty if you've made them the handler). No
permission prompt.

| | |
|---|---|
| **Where** | `http://127.0.0.1:<port>`: the port this store's last UI had when it is free, else one the system picks. Only this Mac can reach it. |
| **Signing in** | The link it opens (or prints) works **once**, for **five minutes**. It signs that browser in until you sign out or leave it unused for 14 days (each visit renews it) — also across a restart of `doz ui` on the same port. Another browser or tab needs another link: `doz ui link`, or run `doz ui` again. A page that must sign in again says why and takes a pasted link (`doz ui link --print-url`) inside the page, keeping what it showed. Treat a printed link like a password — anyone with it signs in to your UI. |
| **An installable app** | The page has a web app manifest: Chrome installs it (*Install Dozer Sandbox*), Safari adds it to the Dock. While `doz ui` is not running the app (or a reload) shows "Dozer isn't running on this Mac" — a service worker that keeps only that page; it never stores an answer of the dashboard — and comes back by itself. An app belongs to one port: set `ui.port` (a fixed port, 127.0.0.1 only; `0` = the last one when free). |
| **Stopping** | Ctrl-C in the terminal that runs it. Signing out ends that browser's session; `doz ui --new-link` ends every one. Stopping `doz ui` keeps them for the next `doz ui` on the same port (below). |
| **One per store** | Each store has at most one UI. `--store` (or `$DOZ_STORE`) picks the store, as for every command. |
| **The host** | The UI is a client of the host, like the CLI. Looking never starts a host: with none running, the UI reads the store (nothing is live). It follows the host's events only while a sandbox is live, so an open UI never keeps an idle host from exiting. |
| **Watching the host** | The sidebar's footer shows two facts: the page's link to `doz ui`, and the host's state and build. When the host stops cleanly (`doz host stop`, idle, SIGTERM) a banner says your sandboxes were hibernated and offers **Start host**; when it is killed or crashes, a banner names the sandboxes that were running (they are shut down: start them again); when a host of another build takes over, a banner says so — and, once, which side is the older build: an older host ("The host is still 0.12.0-rc.3 — `doz host stop` … and the next action runs 0.12.0-rc.5", with a **Restart host** button that asks first, hibernates the running sandboxes, and starts the newer build; they wake when you use them), or an older `doz ui` (restart `doz ui`). Every page's phases follow at once. Any action starts a host when none runs, as the CLI does. |
| **When `doz ui` stops** | A banner says so, and after a second and a half without it the page is paused under an overlay — nothing behind it can be clicked (navigating or starting a sandbox could not work anyway). For 15 seconds (a minute for `doz ui restart`) it calmly says it is reconnecting; then, or at once after Ctrl-C, what to run, when it was last connected and whether the host was running as far as it knew, with **Try now**; the banners stay on top and usable. The page retries every second. The next `doz ui` listens on the same port when it can and keeps its pages' sessions, so the page reconnects by itself, still signed in — its terminals reattach, an operation that was running ends with its outcome, a newer build offers **Reload** — and `doz ui` then opens no new tab (the page shows "doz ui restarted"). After `--new-link`, the page asks for a link inside itself. `doz ui restart` does all this on purpose (the same process re-executed, so an upgrade's new `doz` runs); onto a changed `ui.port` it opens the dashboard on the new port and the old page says where it went. |
| **One tab, not one per start** | Running `doz ui` while one runs reuses it: it opens a tab only when none of its pages is open, else it just says where it runs. `ui.open_browser` (`auto`, the default; `always`; `never`) sets when a tab opens; `--open` and `--no-open` override it for one run. |
| **A new link for every page** | `doz ui --new-link` (or `doz ui link --rotate` on a running UI) signs every page out and makes a new link; each open page says so. Kept sessions live in `<store>/ui.sessions` (0600) as digests of their cookies, never the cookies: the file signs nobody in, and it has the store's own trust. |
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
| `[ui]` | `terminal_title` (`{sandbox} · {session} · {time}` — see "The title and the Ctrl-] menu"; `""` leaves the title to the session), `boot_view_on_start` (true), `confirm_shutdown` (true), `split_default` (`shell` · `watch` · `attach` · `dialog`), `terminals` (true), `terminal_font_size` (13), `theme` (`auto` · `light` · `dark`), `details_open` (true), `grid_live_tiles` (8, 1–12), `grid_tile_size` (`small` · `medium` · `large`), `progress` (`animated` · `plain`; `$DOZ_PROGRESS`, `--progress auto\|plain`), `open_browser` (`auto` · `always` · `never`; `doz ui --open\|--no-open` — when `doz ui` opens a tab; applies to the next `doz ui`) |
| `[host]` | `idle_timeout_minutes` (5; `$DOZ_HOST_IDLE`), `boot_logs_kept` (5, 1–50; `$DOZ_BOOT_LOGS` — boots kept per sandbox for `doz console --boot N` and the Boot log), `screen_capture_minutes` (5, 0–1440; `$DOZ_SCREEN_CAPTURE` — how often a running sandbox's changed session screens are saved; 0 = only at pause, sleep and hibernate), `keepalive` (false — for a store that has not chosen with `doz account keepalive`) |
| `[store]` | `path` (`--store`, `$DOZ_STORE`) |
| `[claude]` | `permissions` (`skip` · `ask`) — Claude Code's own prompts in a claude-code sandbox; `-e DOZ_CLAUDE_PERMISSIONS=…` on `run`/`exec` still wins |
| `[defaults]` | `cpus` (2), `nat_subnet` (a free one; `$DOZ_SUBNET`) |
| `[sandbox]` | `agent_sudo` (true — the agent's passwordless sudo inside claude-code and pi sandboxes; a sandbox's `--no-agent-sudo` / `agent_sudo` wins; from its next session and boot), `timezone` (`mac` — the Mac's zone, read again at every start and wake, so a sandbox that slept while you travelled wakes in your new zone — or a zone like `Australia/Sydney`; the agent's facts say it), `clipboard` (`write` · `off` — the clipboard bridge, see "Session bridges"; applies at once), `browser_bridge` (`on` · `off` — xdg-open to the Mac's browser and a sign-in's callback; applies at once), `open_files` (`on` · `off` — xdg-open FILE opens a /workspace document on the Mac; see "Workspace files, opened on the Mac"; applies at once), `ssh_agent` (`off` · `on` — forward the Mac's SSH agent, github.com:22 only; see "GitHub as you") |
| `[github]` | `credentials` (`gh` · `key` · `off` — where "Use GitHub as you" gets your login; see "GitHub as you"; applies at once) |
| `[sessions]` | `tmux` (false — new sessions run inside tmux; see "tmux inside a session"; from the next session) |
| `[bridges]` | `open_apps` (`""` — the Mac apps a sandbox may name to open a workspace file in, comma-separated; empty: default apps only; applies at once) |
| `[images]` | `claude_code_version`, `pi_version` (`latest`, or an exact version like `2.1.227` — see "Agent versions" below) |
| `[images.lab]` · `[images.claude-code]` · `[images.pi]` | `memory_mib` (1024 · 2048 · 2048), `network` (`bake` · `agent` · `agent`) — a custom image follows the image it was saved from |
| `[kernel]` | `path` (`$DOZ_KERNEL`), `cache` (`$DOZ_KERNEL_CACHE`) |

- **Per sandbox:** `sandbox.clipboard`, `sandbox.browser_bridge`, `sandbox.open_files`, `sandbox.ssh_agent`, `sessions.tmux` and `sandbox.agent_sudo` can also be one sandbox's own
  (`doz config set|get|unset|show --sandbox NAME …`, `doz create` flags, `doz_project.yaml`); its
  value wins over the file's.
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
- **Boot logs.** Every boot of a sandbox — each Start (a cold boot), each wake, a restore after a
  crash — is kept: doz's timed steps exactly as the boot view showed them, that boot's kernel
  console, when it started, how long it took and whether it failed (and why). The last
  `host.boot_logs_kept` (5) are kept per sandbox, in its directory (readable only by you); they stay
  across a reset and go with `doz rm`.
  - `doz console NAME --list` — the kept boots: when, what, how long, ✓ or ✗.
  - `doz console NAME --steps` — the latest boot's steps, then its console; `--boot N` picks an older
    one (1 = the latest, 2 = the one before …). `--json` gives the record (its events and console).
  - In the web UI, **Boot log** on a sandbox's control bar shows the same thing, drawn as the boot
    view drew it — read-only, selectable — with a picker for the kept boots (the latest opens; a
    failed one says ✕). It works in any phase: nothing is woken.
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
| "cannot boot a VM" / entitlement | `doz doctor`. Reinstall (`brew reinstall doz`, or `make install-cli` — both are signed). |
| "this host's program … is gone" | An upgrade removed the previous version under a running host: `doz host stop`, then retry. |
| First start is slow | It is preparing the image, once per store. `doz onboard` (or `doz image bake …`) does it ahead of time; `-v` shows the steps. |
| A start or wake failed, or the boot scrolled past too fast | `doz console NAME --list`, then `doz console NAME --steps [--boot N]` (or **Boot log** in the web UI): each kept boot's steps (the failing one marked ✗, with why) and its kernel console. |
| An agent's sessions do not start: "the agent prompt does not render" | A `{{variable}}` not on the list, in `agent-prompt.md` or the sandbox's own prompt. `doz inspect NAME --prompt` names it; or `doz config set agent.prompt false`. |
| The agent does not know where it runs | `doz inspect NAME --prompt`. A claude-code sandbox from an image baked before 594 lacks the launcher part: `doz reset NAME`. |
| Start over from nothing | `doz uninstall` (it lists what goes), `brew uninstall doz`, then `brew install doz`, `doz onboard`. |
| An agent says it has no key / 401 | `doz key ls NAME`. A stdin key is gone after the host stopped, so set it again or use `--keychain`. |
| A package install fails | `doz net NAME` says what was refused and the permission that allows it (`doz net allow NAME install:python`, or `site:HOST`); the raw log is `doz net log NAME --denied`. |
| A sandbox shows as died | The host crashed while it ran. `doz start NAME` checks the disk and cold-boots it. |
| The UI says "sign in with a new link" | Its link was used or expired, or every page was signed out. Paste a link from `doz ui link --print-url` into the page, or `doz ui link`. |
| A browser terminal says "Disconnected" | The tab was silent for a long time, or it could not reattach. Reconnect. (After a restart or a sign-in it reattaches by itself.) |
| A browser terminal will not type Chinese/Japanese/Korean | Its engine's input-method support is incomplete; use Open in Terminal for now. |
| Open in Terminal says no app opened it | Make a terminal app the handler for `.command` files (Finder › Get Info on any `.command` file › Open with › Change All…). |
| `doz ui` says the resources are missing | `DozerKit_DozerWeb.bundle` must sit beside the executable. Reinstall (`brew reinstall doz`, or `make install-cli`). |
| Anything else | `<store>/host.log` and `doz events`. |

## Not yet

- Moving a *running* sandbox to another Mac: the snapshot is encrypted with a key specific to each
  Mac. A cold move (shut down, copy, start) works but has no command yet.
- Image pull/push.
- Port forwards (beyond a sign-in's callback).
- IPv6 and HTTP/2 through the proxy.
- An idle auto-suspend scheduler: today nothing pauses or sleeps a sandbox by itself.
