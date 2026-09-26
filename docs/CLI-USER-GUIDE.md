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

Keys never enter the sandbox:

```bash
snooze key set NAME --anthropic                       # prompt (no echo), or: … < keyfile
snooze key set NAME --anthropic --keychain SERVICE    # read from a keychain generic password
snooze key ls NAME                                    # which keys it has, never their values
snooze key rm NAME --anthropic
```

The host's proxy holds the key and adds it to requests to Anthropic on their way out. Inside,
`ANTHROPIC_API_KEY` is a `snz_cred_…` placeholder. The key is never accepted as a command-line
argument, so it never lands in shell history or `ps`.

- **A key from stdin or the prompt lasts while the host runs.** When the host stops (idle exit,
  `host stop`, a reboot), set it again.
- **A keychain key** is read again whenever a new host loads the sandbox. To store one:
  `security add-generic-password -s snooze-anthropic -a "$USER" -w` (it prompts for the key).

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
| Anything else | `<store>/host.log` and `snooze events`. |

## Not yet

- Moving a *running* sandbox to another Mac: the snapshot is encrypted with a key specific to each
  Mac. A cold move (shut down, copy, start) works but has no command yet.
- Image pull/push.
- Port forwards.
- IPv6 and HTTP/2 through the proxy.
- An idle auto-suspend scheduler: today nothing pauses or sleeps a sandbox by itself.
