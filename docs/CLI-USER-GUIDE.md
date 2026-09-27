# `snooze` user guide

`snooze` runs Linux sandboxes on your Mac that pause in a millisecond, deep-sleep to disk and wake
in about a third of a second, with the programs inside them still running where they were. It is
the command-line face of SnoozeContainerKit. New to it? Start with the
[walkthrough](CLI-WALKTHROUGH.md).

## Concepts

| | |
|---|---|
| **Sandbox** | One Linux VM with its own disk, named by you (`a-z 0-9 -`, 1–40 characters). |
| **Image** | What a sandbox starts from: a baked, read-only disk. Built in: `lab` (Alpine + bash, 1 GiB RAM), `claude-code` and `pi` (Debian `node` + the agent, 2 GiB). Custom images are saved from a sandbox. |
| **Session** | A terminal program living in the sandbox (a shell, `claude`, `pi`). It survives pause, sleep and deep sleep. You *attach* to it and *detach* from it; it keeps running either way. |
| **Workspace** | A folder of your Mac shared into the sandbox at `/workspace`. |
| **Host** | One background `snooze` process per user and store. It owns every running VM, the network proxy and the keys. It starts when needed and exits when idle, so you never manage it. |
| **Store** | Where everything lives on disk: `~/Library/Application Support/SnoozeContainerKit` unless `--store` or `$SNOOZE_STORE` says otherwise. Each store has its own images, sandboxes and host. |

## Install

```bash
cd repo/lib/SnoozeContainerKit
make install-cli                  # PREFIX=~/.local by default → ~/.local/bin/snooze
snooze doctor
```

A VM can only be booted by a binary signed with Apple's virtualization entitlement, and
`make install-cli` signs it. An unsigned build runs every command but cannot boot anything, and
`snooze doctor` says so. `make cli` builds a signed debug binary at `.build/debug/snooze` for
development.

## The lifecycle

```
            start / cold-boot                      pause / suspend
   off  ──────────────────────►  running  ◄──────────────────────►  paused
    ▲                             │  ▲                 resume
    │ shutdown (keeps the disk)   │  │ wake
    └─────────────────────────────┤  ├──────────── asleep       (sleep: snapshot, RAM kept)
                                  │  └──────────── deep asleep  (deep-sleep / hibernate: snapshot, RAM returned)
```

| command | does | typical time | RAM | programs |
|---|---|---|---|---|
| `start NAME` (`cold-boot`) | boots; wakes it if asleep, resumes it if paused | ~0.4 s (the first ever start also bakes the image) | allocated as used | start fresh |
| `pause NAME` (`suspend`) · `resume NAME` | stops the guest CPU | ~1 ms | kept | frozen, then continue |
| `sleep NAME` · `wake NAME` | pause + snapshot to disk; survives the host crashing | ~0.3 s | kept | continue |
| `deep-sleep NAME` (`hibernate`) · `wake NAME` | snapshot, then the VM stops | ~0.35 s / ~0.3 s | **returned** | continue: same PIDs, same screens |
| `shutdown NAME` | a cold stop; the disk is kept | | returned | end |
| `reset NAME` | shut down and go back to a fresh copy of the image (restore points and the agent's state disk stay) | | | end |
| `rm NAME` | remove the sandbox and everything it has on disk | | | end |

`shutdown`, `reset` and `rm` ask first. `--yes` skips the question. Without a terminal and without
`--yes` they refuse (exit 5), so a script can never destroy something by accident.

A program started less than 3 s before a deep sleep gets the rest of those 3 s first. Programs cut
off mid-startup (Claude Code's first network calls, for example) can otherwise fail on wake.

## Creating and entering sandboxes

```bash
snooze create NAME --image lab|claude-code|pi|<custom> \
    [--cpus 2] [--memory 2G] [--workspace ~/code/proj] \
    [--network agent|bake|locked|open|nat|none] [--subnet CIDR]

snooze up NAME [same options] [--session S] [-d] [-- CMD …]
```

- **`up`** is the everyday command, in the manner of `vagrant up` and `docker compose up`: create
  if missing, start or wake, then attach to the image's own session (`claude`, `pi`, or a
  `bash -l` shell called `shell`), opening it if needed. With `-d` it does all that without
  attaching. With `-- CMD …` it opens a new session running CMD instead.
- On an existing sandbox, `up`'s create options are ignored, and it says so. A sandbox keeps the
  image and settings it was created with.
- `up` defaults to `--image lab` when it creates a sandbox. `create` requires `--image`.

## Working inside

| | |
|---|---|
| `snooze attach NAME [SESSION]` | Your terminal becomes that session. **Ctrl-]** detaches (`--detach-key ctrl-x` or `none`). A paused or sleeping sandbox is woken first (`--no-wake` waits instead). If the sandbox deep-sleeps while you are attached, the client waits and reattaches by itself when it wakes. |
| `snooze run NAME [--session S] [-d] -- CMD …` | Open a **new** session running CMD and attach. It exits with CMD's exit code. There is no shell in front, so write `bash -lc '…'` if you want one. |
| `snooze exec NAME [--user U] [--workdir D] [-e K=V] [--timeout S] -- CMD …` | One-shot, no terminal: stdout, stderr and the exit code pass straight through (default timeout 120 s). On agent images it runs as the agent's user in `/workspace`; `--user root` for root. |
| `snooze sessions NAME` | The sandbox's sessions. |
| `snooze ls` · `snooze inspect NAME` | Every sandbox: image, phase, RAM held, disk, sessions, network · everything about one, as JSON. |

**RAM held** in `ls` is what the VM costs your Mac right now: the allocation, less what the memory
balloon handed back after a wake. It is shown as `—` when the sandbox is off or deep asleep.

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

`-e SNOOZE_CLAUDE_PERMISSIONS=ask` (on `run` or `exec`) keeps Claude Code's own prompts, and a
`claude` run as root always keeps them.

Keys never enter the sandbox. The host's proxy holds each credential and puts it into requests to
Anthropic on their way out. Inside the sandbox, `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` is
a `snz_cred_…` placeholder. A credential is never a command-line argument, so it never lands in
shell history or `ps`.

### Claude accounts

A sandbox on a proxied network uses one **account**:

| kind | what it is | where the secret lives | renewal |
|---|---|---|---|
| `mac` (built in) | this Mac's own Claude Code login | Claude Code's own keychain item, read-only for snooze | the Mac's Claude Code renews it |
| `setup-token` | a `claude setup-token` token (a Claude subscription, valid 1 year) | the login keychain, `snooze-claude:NAME` | none: add a new one before it expires |
| `api-key` | an Anthropic API key | the login keychain, `snooze-anthropic:NAME` (or an item you name) | none |

```bash
snooze account ls                                   # accounts, state, expiry, which sandboxes use them — never a secret
snooze account add work --setup-token --plan max    # paste the token `claude setup-token` printed (no echo), or pipe it in
snooze account add ci --api-key                     # an API key (prompt or stdin), or: --keychain SERVICE
snooze account use NAME work                        # this sandbox uses work; open sessions switch on their next request
snooze account use NAME default                     # follow the store's default again (none: no credential)
snooze account default work                         # every sandbox that follows the default moves to work
snooze account verify work                          # one tiny request to api.anthropic.com
snooze account rm work [--force]                    # also deletes the keychain item snooze made
snooze create NAME --image claude-code --account work
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
- `snooze key set NAME --claude-login` still works: it is `account use NAME mac`.
  `key set NAME --anthropic` gives the sandbox a key of its own and takes it off its account.

### The Mac's login: how renewal works

Snooze reads only the **access token** of the Mac's Claude Code login, never the refresh token.
The Mac's Claude Code is the one program that renews the login, so the two can never fork it. The
access token lives about 8 hours. Claude Code renews it when a `claude` process runs on the Mac
within 5 minutes of expiry; `claude auth status` does not renew it.

- The host re-reads the login every 2 minutes: one read per login, however many sandboxes use it.
  A renewed token reaches every sandbox, and their sessions keep working without a restart.
- **The login expired** (say, nothing ran Claude Code on the Mac overnight). The proxy re-reads
  once. If the login is still expired, it answers with a message that Claude Code in the sandbox
  shows: "this Mac's Claude login expired at 04:59 — open Claude Code on the Mac (any prompt), then
  retry". The session recovers by itself when the Mac renews.
- **Keep-alive (off by default):** `snooze account keepalive on`. Within 10 minutes of expiry, if a
  sandbox used the Mac login in the last 15 minutes and no Claude Code runs on the Mac, the host
  runs the Mac's own `claude -p ok --model haiku` once. Claude Code's normal startup renews the login
  under its own lock, at the cost of one tiny turn on your subscription.
- **The Mac signs out:** the sandboxes' token is cleared at once, and requests get "this Mac's Claude
  Code signed out".
- **A different account signs in on the Mac:** sandboxes on `mac` are **held** and don't silently
  switch identity or billing. `snooze account use NAME mac` follows the new account.
- **A locked keychain** keeps the last token and warns (`snooze events`).
- **Several Claude config dirs** (`CLAUDE_CONFIG_DIR`): Claude Code keeps one keychain item per
  directory. `snooze account add work-mac --claude-login --config-dir ~/.claude-work` adds another
  one. `snooze doctor` lists every Claude login item in the keychain (attributes only).

`snooze doctor` checks that Claude Code is installed, whether it is signed in with a subscription
(or an API key, or not at all), the plan, who is signed in, and when the access token expires.
`account use … mac` makes the same checks and changes nothing when they fail.

### A credential the guest brings itself

The proxy decrypts api.anthropic.com anyway, so it sees every credential. A **credential snooze
never issued**, such as a guest `/login` or a pasted key, is classified by the **key policy**:

```bash
snooze key policy NAME allow    # pass it, and flag it
snooze key policy NAME strict   # refuse it
snooze key policy NAME auto     # the default: strict for a setup-token or api-key account, allow for mac
```

- **allow:** the request goes through. The net log says `own credential (oauth sk-ant-oat01…, fp
  ab12cd34ef56)`, `ls` marks the sandbox `own key`, `key ls` lists the fingerprints, and an event is
  recorded once per credential. A fingerprint is the first 12 hex of the credential's sha256,
  never the value. Snooze's own credential is never added to a request that carries the guest's.
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
snooze key set NAME --anthropic                       # prompt (no echo), or: … < keyfile
snooze key set NAME --anthropic --keychain SERVICE    # read from a keychain generic password
snooze key ls NAME                                    # keys, account, state, expiry, policy, foreign fingerprints
snooze key rm NAME --anthropic
```

- **A key from stdin or the prompt lasts while the host runs.** When the host stops (idle exit,
  `host stop`, a reboot), set it again. Accounts and keychain keys are read again whenever a new
  host loads the sandbox.
- **Sessions survive a host restart with their credentials.** The sandbox's `snooze.json` keeps
  a sha256 of each live placeholder, never the placeholder itself, so a session that deep-slept
  through `host stop` keeps working in the new host. `shutdown`, `reset` and `rm` revoke them.
- To store a key in the keychain yourself: `security add-generic-password -s snooze-anthropic -a
  "$USER" -w` (it prompts for the key).

## Network

A sandbox has **no network card**. Its only way out is a proxy in the host that checks every
connection against a policy and logs it.

| `--network` | allows | default for |
|---|---|---|
| `agent` | Anthropic's API and sign-in hosts, plus package registries | `claude-code`, `pi` |
| `bake` | package registries only (npm, apt, apk, PyPI) | `lab` |
| `locked` | nothing | |
| `open` | everything, still proxied and logged | |
| `nat` | a normal NAT network card, not proxied, no log | |
| `none` | no network at all | |

```bash
snooze net policy NAME                                  # show
snooze net policy NAME --allow github.com --allow '*.githubusercontent.com'
snooze net policy NAME --deny example.com --remove github.com
snooze net policy NAME --preset open
snooze net log NAME [--denied] [--follow]              # host, verdict, rule, bytes; never contents
```

Policy changes apply to the next connection and are kept for the next start. A name the policy
cannot allow doesn't even resolve. Current limits: IPv4 only, HTTP/1.1 on the hosts whose traffic
the proxy decrypts, UDP refused (clients fall back to TCP), and no port forwards from the Mac into
a sandbox yet.

## Restore points and custom images

Restore points are instant, disk-only copies (APFS clones). They cover the disks, not memory.

```bash
snooze point take NAME [POINT] [--note …]      # a running sandbox pauses for milliseconds
snooze point ls NAME
snooze point revert NAME POINT                 # shuts down; a "before revert" point is taken first
snooze point fork NAME POINT NEWNAME           # a new sandbox from that point (cold-boots on start)
snooze point rm NAME POINT
snooze point save-image NAME [POINT] --as myimage [--note …]    # a custom image
snooze up other --image myimage
```

```bash
snooze image ls                   # built-in and custom images, and whether each is baked here
snooze image bake claude-code     # bake now rather than at the first start (minutes, needs network)
snooze image rm NAME              # sandboxes already made from it keep working
```

`image pull` / `push` are not built yet (exit 7).

## The host

The host is started for you by the first command that needs it. It runs detached, logs to
`<store>/host.log` and listens on `<store>/host.sock`.

| | |
|---|---|
| **Idle exit** | It exits after 5 minutes with no running, paused or sleeping VM and no attached client (`$SNOOZE_HOST_IDLE` minutes, 0 = never). |
| **Looking never starts it** | `ls`, `inspect`, `point ls`, `image ls`, `net policy` (shown) and `key ls` read the store directly when no host runs. |
| `snooze host status` | Is one running, and what does it hold? Never starts one. |
| `snooze host stop` | Deep-sleeps everything that runs, then exits. The next command starts a new host; `wake`, `attach`, `up` and `exec` bring each sandbox back. |
| `snooze host [--foreground] [--idle-timeout MIN]` | Run it by hand (in the foreground, it logs to the terminal). |
| **If it crashes** | The next command starts a new one. Sleeping sandboxes are restored with their sessions. Deep-sleeping ones are untouched. Ones that were running are reported as died (`ls`; `inspect` shows `diedWithHost`), and their disk is checked with `e2fsck` at the next start. |

## The web UI

`snooze ui` is a dashboard in your browser for everything in the store, and it can do most of
what the CLI does. (The maintenance and disk-accounting views come later.)

```bash
snooze ui                 # serve it, and open it in your default browser
snooze ui --print-url     # the same, but print the link instead of opening a browser
snooze ui link            # another browser or tab on the UI that is already running
```

It shows every sandbox (phase, RAM held, disk, sessions, network, account), each sandbox's
sessions, restore points, network policy and connection log, keys and their state, the images,
the Claude accounts, the metrics, `snooze doctor`, and the host's activity as it happens.

What you can do from it:

| Page | Actions |
|---|---|
| **Sandboxes** | New sandbox (image, network, account, CPUs, memory, workspace folder). Per sandbox: start, pause, resume, sleep, deep sleep, wake, shut down, reset, remove. |
| **A sandbox** | Open in Terminal (Terminal.app attaches to a session); open the image's session, or run a command in a new detached session; take a restore point, and revert, fork, save as an image or delete one; edit the network policy, with a preview of exactly what changes; set the key policy and the account; remove a key. |
| **Images** | Bake a built-in image; remove one. |
| **Accounts & keys** | Make an account the default; verify one; remove one; keep-alive on or off. |
| **Metrics** | Filter by image, time and steps; download the rows as CSV. |

Shut down, reset, remove, revert and every delete ask you to **type the name** first. An
operation's progress shows in the sandbox's row and in the Operations list while it runs (the
host's latest step and the seconds so far — a first start in a store downloads and bakes its image
and can take two minutes), and the page updates when it ends. The session buttons wait until the
sandbox can take a session, and clicking an action again while it runs does nothing more (it is
already under way). The list has no session count, since counting asks every session inside the
guest; each sandbox's page lists its sessions.

Two things are CLI-only on purpose: **a secret is never typed into the browser**. Add an account
(`snooze account add`) or set a key (`snooze key set`) in a terminal; the page shows the command.
And there is no shell in the browser. **Open in Terminal** opens `snooze attach` in your default
terminal app: whatever opens `.command` files on this Mac (Terminal, or iTerm2 / Ghostty if you've
made them the handler). No permission prompt.

| | |
|---|---|
| **Where** | `http://127.0.0.1:<port>`, a port the system picks. Only this Mac can reach it. |
| **Signing in** | The link it opens (or prints) works **once**, for **five minutes**. It signs that browser in until you close the UI or sign out. Another browser or tab needs another link: `snooze ui link`, or run `snooze ui` again. Treat a printed link like a password — anyone with it signs in to your UI. |
| **Stopping** | Ctrl-C in the terminal that runs it. Signing out and stopping both end every browser's session. |
| **One per store** | Each store has at most one UI. `--store` (or `$SNOOZE_STORE`) picks the store, as for every command. |
| **The host** | The UI is a client of the host, like the CLI. Looking never starts a host: with none running, the UI reads the store (nothing is live). It follows the host's events only while a sandbox is live, so an open UI never keeps an idle host from exiting. |
| **Terminals** | Open in Terminal runs `snooze attach NAME [SESSION] --store …` in a new Terminal tab (waking the sandbox if it sleeps). The page also shows that command to copy. |
| **Secrets** | Never shown. Keys and accounts appear as a state, a source name (`keychain:…`, `account:mac`) and a fingerprint. |

`--print-url` prints only to a terminal (not with `--json`, not into a pipe or a file), because the
link is a key to the UI.

## Scripting

- `--json` on every command: JSON on stdout; errors as `{"error":{"code","message"}}`. Fields are
  only ever added.
- `-q` prints no progress. `-v` prints every step (by default only operations slower than a second
  show their steps, on stderr).
- `snooze events [NAME]` follows phases and timed steps live. `snooze metrics [--csv] [--image X]
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
| *program's own* | `exec`, `run`, `attach` (125 = snooze itself failed) |

| environment | |
|---|---|
| `SNOOZE_STORE` | the store directory |
| `SNOOZE_HOST_IDLE` | host idle timeout, minutes |
| `SNOOZE_KERNEL_CACHE` / `SNOOZE_KERNEL` | a shared kernel cache / an explicit kernel |
| `SNOOZE_SUBNET` | default subnet for `--network nat` |

The kernel and subnet variables are read when a sandbox is created, and become part of it.

## Troubleshooting

| symptom | try |
|---|---|
| "cannot boot a VM" / entitlement | `snooze doctor`. Reinstall with `make install-cli` (it signs). |
| First start is slow | It is baking the image, once per store. `snooze image bake …` ahead of time; `-v` shows the steps. |
| An agent says it has no key / 401 | `snooze key ls NAME`. A stdin key is gone after the host stopped, so set it again or use `--keychain`. |
| A package install fails | The policy: `snooze net log NAME --denied`, then `snooze net policy NAME --allow HOST`. |
| A sandbox shows as died | The host crashed while it ran. `snooze start NAME` checks the disk and cold-boots it. |
| The UI says "sign in with a new link" | Its link was used or expired, or the UI restarted. `snooze ui link`. |
| Open in Terminal says no app opened it | Make a terminal app the handler for `.command` files (Finder › Get Info on any `.command` file › Open with › Change All…). |
| `snooze ui` says the resources are missing | `SnoozeContainerKit_SnoozeWeb.bundle` must sit beside the executable. Reinstall with `make install-cli`. |
| Anything else | `<store>/host.log` and `snooze events`. |

## Not yet

- Moving a *running* sandbox to another Mac: the snapshot is encrypted with a key specific to each
  Mac. A cold move (shut down, copy, start) works but has no command yet.
- Image pull/push.
- Port forwards.
- IPv6 and HTTP/2 through the proxy.
- An idle auto-suspend scheduler: today nothing pauses or sleeps a sandbox by itself.
