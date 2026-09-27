# CLI reference

Every `snooze` command, by task. New to it? <doc:SnoozeWalkthrough> is a first run, end to end.

## Overview

`snooze` runs Linux sandboxes on your Mac that pause in a millisecond, deep-sleep to disk and wake
in about a third of a second, with the programs inside them still running where they were. It is
the command-line face of `SnoozeContainerKit`.

```bash
cd repo/lib/SnoozeContainerKit
make install-cli                  # PREFIX=~/.local by default → ~/.local/bin/snooze
snooze doctor
```

A VM can only be booted by a binary signed with Apple's virtualization entitlement, and `make
install-cli` signs it. An unsigned build runs every command but cannot boot anything, and `snooze
doctor` says so. `make cli` builds a signed debug binary at `.build/debug/snooze` for development.

> This article's command list is checked against the CLI's real subcommand tree by
> `Scripts/docs-drift-check.sh` (`make docs-drift-check`) — see that script for how.

### The lifecycle

See <doc:Concepts> for what each word means.

| command | does | typical time | RAM | programs |
|---|---|---|---|---|
| `start NAME` (`cold-boot`) | boots; wakes it if asleep, resumes it if paused | ~0.4 s | allocated as used | start fresh |
| `pause NAME` (`suspend`) · `resume NAME` | stops the guest CPU | ~1 ms | kept | frozen, then continue |
| `sleep NAME` · `wake NAME` | pause + snapshot to disk; survives the host crashing | ~0.3 s | kept | continue |
| `deep-sleep NAME` (`hibernate`) · `wake NAME` | snapshot, then the VM stops | ~0.35 s / ~0.3 s | **returned** | continue: same PIDs, same screens |
| `shutdown NAME` | a cold stop; the disk is kept | | returned | end |
| `reset NAME` | shut down and go back to a fresh copy of the image (restore points and the agent's state disk stay) | | | end |
| `rm NAME` | remove the sandbox and everything it has on disk | | | end |

`shutdown`, `reset` and `rm` ask first; `--yes` skips the question; with no terminal and no
`--yes` they refuse (exit 5). A program started less than 3 s before a deep sleep gets the rest of
those 3 s first (Claude Code's first network calls, for example, can otherwise fail on wake).

### Creating and entering sandboxes

```bash
snooze create NAME --image lab|claude-code|pi|<custom> \
    [--cpus 2] [--memory 2G] [--workspace ~/code/proj] \
    [--network agent|bake|locked|open|nat|none] [--subnet CIDR]

snooze up NAME [same options] [--session S] [-d] [-- CMD …]
```

- **`up`** is the everyday command, in the manner of `vagrant up` and `docker compose up`: create
  if missing, start or wake, then attach to the image's own session (`claude`, `pi`, or a
  `bash -l` shell called `shell`), opening it if needed. `-d` does all that without attaching;
  `-- CMD …` opens a new session running `CMD` instead.
- On an existing sandbox, `up`'s create options are ignored (and it says so) — a sandbox keeps the
  image and settings it was created with. `up` defaults to `--image lab`; `create` requires
  `--image`.

### Working inside

| command | what |
|---|---|
| `attach NAME [SESSION] [--no-wake]` | Your terminal becomes that session. **Ctrl-]** detaches (`--detach-key ctrl-x\|none`). A paused or sleeping sandbox wakes first unless `--no-wake`. Deep-sleeps while attached: the client waits and reattaches by itself on wake. |
| `run NAME [--session S] [-d] -- CMD …` | A **new** session running `CMD`, attached; exits with `CMD`'s exit code. No shell in front — write `bash -lc '…'` for one. |
| `exec NAME [--user U] [--workdir D] [-e K=V] [--timeout S] -- CMD …` | One-shot, no terminal: stdout, stderr and the exit code pass straight through (default timeout 120 s). Agent images run as the agent's user in `/workspace`; `--user root` for root. |
| `sessions NAME` | The sandbox's terminal sessions. |
| `ls` · `inspect NAME` | Every sandbox: image, phase, RAM held, disk, sessions, network · everything as JSON. |

**RAM held** in `ls` is what the VM costs the Mac right now: the allocation, less what the memory
balloon returned after a wake — shown as `—` when the sandbox is off or deep asleep.

### Agents, keys and accounts

The agent images (`claude-code`, `pi`) run as a normal user in `/workspace` and keep the agent's
login and history on a separate **state disk**, which survives shutdown, reset and re-bakes.
**Claude Code starts ready to work**: its launcher marks first-run setup done and passes
`--dangerously-skip-permissions` (the VM, proxy and key vault are the boundary). Keys never enter
the sandbox — inside it, `ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN` is a `snz_cred_…`
placeholder, never a command-line argument.

`-e SNOOZE_CLAUDE_PERMISSIONS=ask` (on `run`/`exec`) keeps Claude Code's own prompts; a `claude`
run as root always keeps them.

### Accounts

A proxied sandbox uses one **account**: `mac` (this Mac's own Claude Code login, read-only,
renewed by the Mac's Claude Code), `setup-token` (`claude setup-token`, valid one year, in the
keychain), or `api-key` (an Anthropic API key).

```bash
snooze account ls                                   # accounts, state, expiry, which sandboxes use them
snooze account add work --setup-token --plan max    # paste the token (no echo), or pipe it in
snooze account add ci --api-key                     # an API key (prompt or stdin), or: --keychain SERVICE
snooze account use NAME work                        # this sandbox uses work
snooze account use NAME default                     # follow the store's default again (none: no credential)
snooze account default work                         # every sandbox on the default moves to work
snooze account verify work                          # one tiny request to api.anthropic.com
snooze account rm work [--force]                    # also deletes the keychain item snooze made
snooze account keepalive on                          # off by default: runs `claude -p` near expiry
snooze create NAME --image claude-code --account work
```

A new proxied sandbox follows the store's default account (`mac` out of the box); Claude Code in
the sandbox shows the real plan (`CLAUDE_CODE_SUBSCRIPTION_TYPE`); there is **no silent fallback**
— a missing, expired or held credential is refused with a message saying what to do, never
switched to another account or an API key by itself. `snooze key set NAME --claude-login` is
still `account use NAME mac`.

### A credential the guest brings itself

```bash
snooze key policy NAME allow    # pass it, and flag it
snooze key policy NAME strict   # refuse it (and deny the sign-in hosts too)
snooze key policy NAME auto     # default: strict for a setup-token/api-key account, allow for mac
```

`allow` shows in the net log as `own credential (…, fp ab12cd34ef56)` — a fingerprint, never the
value — and flags the sandbox in `ls`/`key ls`. `strict` refuses with 403 and denies the Claude
sign-in hosts too, so a guest `/login` cannot finish.

### Keys given directly

```bash
snooze key set NAME --anthropic                       # prompt (no echo), or: … < keyfile
snooze key set NAME --anthropic --keychain SERVICE    # read from a keychain generic password
snooze key ls NAME                                    # keys, account, state, expiry, policy, foreign fingerprints
snooze key rm NAME --anthropic
```

A key from stdin or the prompt lasts only while the host runs — set it again after `host stop`.
Sessions survive a host restart with their credentials (a sha256 of each live placeholder is kept,
never the placeholder itself); `shutdown`, `reset` and `rm` revoke them.

### Network

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

A name the policy cannot allow does not even resolve. Current limits: IPv4 only, HTTP/1.1 on hosts
the proxy decrypts, UDP refused, no port forwards from the Mac into a sandbox yet.

### Restore points and images

Restore points are instant, disk-only copies (APFS clones) — they cover the disks, not memory.

```bash
snooze point take NAME [POINT] [--note …]      # a running sandbox pauses for milliseconds
snooze point ls NAME
snooze point revert NAME POINT                 # shuts down; a "before revert" point is taken first
snooze point fork NAME POINT NEWNAME           # a new sandbox from that point (cold-boots on start)
snooze point rm NAME POINT
snooze point save-image NAME [POINT] --as myimage [--note …]    # a custom image
snooze up other --image myimage

snooze image ls                   # built-in and custom images, and whether each is baked here
snooze image bake claude-code     # bake now rather than at the first start (minutes, needs network)
snooze image rm NAME              # sandboxes already made from it keep working
```

`image pull` / `push` answer "not yet" (exit 7).

### The host

```bash
snooze host [--foreground] [--idle-timeout MIN]   # run it by hand
snooze host stop                                    # deep-sleeps everything running, then exits
snooze host status                                  # is one running, and what does it hold? never starts one
```

Started for you by the first command that needs it; runs detached (`<store>/host.log`,
`<store>/host.sock`); exits after 5 minutes idle (`$SNOOZE_HOST_IDLE`, 0 = never). `ls`,
`inspect`, `point ls`, `image ls`, `net policy` (shown) and `key ls` read the store directly when
no host runs, so **looking never starts one**. If it crashes, the next command starts a new one:
sleeping sandboxes are restored with their sessions, deep-sleeping ones are untouched, and running
ones are reported as died with their disk checked at the next start.

### The web UI

```bash
snooze ui [serve] [--open | --print-url] [--store DIR]   # a local dashboard for everything above; Ctrl-C stops it
snooze ui link [--store DIR]                             # a fresh one-use sign-in link for the running UI
```

A browser dashboard for sandboxes, images, accounts, metrics, activity and doctor, with the
lifecycle and every other action. It listens on `127.0.0.1` only. Each link works once and is
exchanged for a strict session cookie; `Host` and `Origin` are checked exactly. Secrets are never
entered in the browser: add keys and accounts with the CLI. **Open in Terminal** runs
`snooze attach` in your default terminal app. The UI is a client of the host, like any other
command, so it can't do anything the CLI can't.

### Numbers and diagnostics

```bash
snooze metrics [--csv] [--image X] [--days N] [--no-steps]   # count, median, p90, min, max, failures
snooze doctor                                                  # macOS, Apple silicon, entitlement, kernel, store, host, Claude login
snooze events [NAME]                                           # follow phases and timed steps live
```

### Scripting

Every command takes `--json` (machine-readable output; errors as
`{"error":{"code","message"}}`), `--store DIR` (default `$SNOOZE_STORE`, else
`~/Library/Application Support/SnoozeContainerKit`), `-v` (every progress step) and `-q` (none).
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
| *program's own* | `exec`, `run`, `attach` (125 = snooze itself failed) |

| environment | |
|---|---|
| `SNOOZE_STORE` | the store directory |
| `SNOOZE_HOST_IDLE` | host idle timeout, minutes |
| `SNOOZE_KERNEL_CACHE` / `SNOOZE_KERNEL` | a shared kernel cache / an explicit kernel |
| `SNOOZE_SUBNET` | default subnet for `--network nat` |

### Troubleshooting

| symptom | try |
|---|---|
| "cannot boot a VM" / entitlement | `snooze doctor`; reinstall with `make install-cli` (it signs). |
| First start is slow | It is baking the image, once per store — `snooze image bake …` ahead of time; `-v` shows the steps. |
| An agent says it has no key / 401 | `snooze key ls NAME` — a stdin key is gone after the host stopped; set it again or use `--keychain`. |
| A package install fails | Check the policy: `snooze net log NAME --denied`, then `snooze net policy NAME --allow HOST`. |
| A sandbox shows as died | The host crashed while it ran — `snooze start NAME` checks the disk and cold-boots it. |
| Anything else | `<store>/host.log` and `snooze events`. |

### Not yet

Moving a *running* sandbox to another Mac (a cold move — shut down, copy, start — works but has no
command yet), image pull/push, port forwards, IPv6 and HTTP/2 through the proxy, and an idle
auto-suspend scheduler.
