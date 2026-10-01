# Sandboxes and their lifecycle

A **sandbox** is one Linux virtual machine with its own disks. This page covers making one, the
states it can be in — running, paused, asleep, hibernated, shut down — and moving between them, and
the background **host** that runs them all.

## Concepts

- **Name.** 1–40 characters of `a-z 0-9 -`, unique in the store.
- **Image.** What the sandbox starts from (Claude Code, pi, a plain shell, a template…). See
  [Images and bases](08-images-and-bases.md).
- **Three kinds of storage**, each kept differently:

  | | what's on it | kept through |
  |---|---|---|
  | the **root disk** | the system and anything installed or written outside the next two | shutdown; gone with `reset` (back to the image) and `rm` |
  | the **state disk** (agent images) | the agent's own settings, logins and history (`~/.claude`, `~/.pi/agent`) | shutdown **and** reset; gone with `rm` |
  | the **workspace** | your Mac folder shared at `/workspace` | everything — it's on your Mac |

- **Isolated.** A sandbox with no shared folder: `/workspace` is a folder on its own disk, and nothing
  on your Mac is shared. `doz ls` shows `isolated`, and the agent is told.
- **Sessions.** The terminal programs running inside (a shell, `claude`, `pi`). They survive pause,
  sleep and hibernate. See [Terminals and sessions](07-terminals-and-sessions.md).
- **The host.** One background `doz` process per store. It owns every running VM, the network proxy
  and the credentials. The first command that needs it starts it, and it exits when idle, so you
  normally never think about it.

## The states

```mermaid
stateDiagram-v2
    direction LR
    [*] --> off: doz create
    off --> booting: doz start
    booting --> running
    booting --> failed
    failed --> booting: doz start
    running --> paused: doz pause
    paused --> running: doz resume
    running --> asleep: doz sleep
    asleep --> running: doz wake
    running --> hibernated: doz hibernate
    hibernated --> running: doz wake
    running --> off: doz shutdown
    running --> off: doz reset (a fresh disk)
    off --> [*]: doz rm

    note right of paused: frozen · memory kept · back in ~1 ms
    note right of asleep: frozen and saved to disk · memory kept · back in ~0.3 s
    note right of hibernated: saved to disk · memory given back · back in ~0.3 s
    note left of off: powered off · disks kept · programs ended
```

`doz ls` and the dashboard show which of these states each sandbox is in. `doz up` also wakes an
asleep or hibernated sandbox and resumes a paused one, so it's the one command to remember.

| command | what happens | typical time | memory | programs |
|---|---|---|---|---|
| `doz start NAME` | boots (or wakes it if asleep, resumes it if paused) | ~0.4 s (a first start may prepare the image) | used as needed | start fresh |
| `doz pause NAME` · `doz resume NAME` | the CPU stops | ~1 ms | kept | frozen, then carry on |
| `doz sleep NAME` · `doz wake NAME` | paused **and** saved to disk — survives a crash of the host | ~0.3 s | kept | carry on |
| `doz hibernate NAME` · `doz wake NAME` | saved to disk, then the VM stops | ~0.35 s / ~0.3 s | **given back** | carry on: same processes, same screens |
| `doz shutdown NAME` | a cold stop; the disks are kept | | given back | end |
| `doz reset NAME` | shut down and go back to a fresh copy of the image (the state disk and restore points stay) | | | end |
| `doz rm NAME` | remove the sandbox and everything it has on disk | | | end |

`start` has an alias, `cold-boot`; `pause` has `suspend`.

`shutdown`, `reset` and `rm` ask first. `--yes` skips the question; without a terminal and without
`--yes` they refuse, so a script can't destroy something by accident. The question names what you
asked for — and checks it exists — before you answer.

A program started less than three seconds before a hibernate gets the rest of those three seconds
first, so a program in the middle of starting up isn't frozen at a bad moment.

## Create and start — in the terminal

```sh
doz create my-box --image lab --isolated            # made, and off
doz start my-box
doz create my-app --image claude-code --workspace ~/code/my-app --start
doz up my-app                                        # create if missing, start or wake, attach
```

| option | what it does |
|---|---|
| `--image` | `lab`, `claude-code`, `pi`, a base × agent image, or a template. Or `--agent` with `--base` / `--dockerfile` ([Images and bases](08-images-and-bases.md)). |
| `--workspace DIR` | Share this Mac folder at `/workspace`. Made if it doesn't exist; refused for your home folder itself, system locations and the store. |
| `--isolated` | Share nothing (the default without `--workspace`; this says it on purpose). |
| `--cpus` · `--memory` | Virtual CPUs (default 2) · RAM (`2G`, `512M`; default 1 GiB for lab, 2 GiB for an agent image). |
| `--network` · `--allow` | What the agent may reach ([What the agent can do](10-permissions-and-network.md)). |
| `--account` | Which Claude account it uses ([Agents and accounts](09-agents-and-accounts.md)). |
| `--start` | Start it straight away. |
| `--rebuild` · `--use-current` | When the image is out of date: rebuild it first, or use it as it is. |

`doz up` is the everyday command, like `vagrant up` or `docker compose up`: create if missing, start
or wake, then attach to the image's own session (`claude`, `pi`, or a shell called `shell`). `-d`
does all that without attaching. On an existing sandbox, create options are ignored (it says so).

## Create and start — in the dashboard

1. **Sandboxes** › **New sandbox**.
2. Name it; choose the **Agent** and the **Base** (or a **Template**); decide what the agent can do,
   the account, CPUs and memory; choose a **Shared folder** (suggested:
   `~/Developer/dozer-sandbox-projects/NAME`) or **Isolated**.
3. **Create**. It is made off; **Start** boots it. With the setting `ui.boot_view_on_start` on (the
   default), Start opens a terminal that shows the boot as it happens, then becomes the sandbox's own
   session.

![New sandbox](images/new-sandbox.png)

Each sandbox has an entry under **Sandboxes** in the sidebar, with a dot in its state's colour. Its
page has the lifecycle buttons across the top — **Start**, **Pause**, **Resume**, **Sleep**,
**Hibernate**, **Wake**, **Shut down**, **Reset**, **Remove** — showing only those that make sense
in its state. **Reset** and **Remove** ask you to type the sandbox's name; **Shut down** asks with a
plain confirmation ("Don't ask again" sets `ui.confirm_shutdown` to `false`).

## See what you have

```sh
doz ls                  # every sandbox: image, state, RAM held, disk, sessions, network
doz inspect my-app      # everything about one, as JSON
doz sessions my-app     # its terminal sessions
```

**RAM held** is what the VM costs your Mac right now: its allocation, less what it handed back after
a wake. It shows `—` for a sandbox that is off or hibernated. Looking never starts a host: with none
running, these commands read the store directly.

## Saved screens

Before a sandbox pauses, sleeps or hibernates, Dozer saves the screen of each of its sessions — and
every `host.screen_capture_minutes` (5) while it runs, for sessions that printed something since. So
you can see what a sleeping sandbox was doing without waking it:

```sh
doz sessions my-app                     # listed from their saved screens while it sleeps
doz sessions my-app --screen claude     # that session's last screen, as text
```

In the dashboard, a sleeping sandbox's page shows each session's saved screen, read-only (you can
select and copy from it), with "press any key to wake". Saved screens exist only while you can wake
the sandbox: shutdown, reset and remove delete them.

![A hibernated sandbox's saved screens](images/saved-screens.png)

## Boot logs

Every boot of a sandbox — each start, each wake, a recovery after a crash — is kept: Dozer's timed
steps as the boot view showed them, and the Linux kernel's own messages.

```sh
doz console my-app --list               # the kept boots: when, what, how long, ✓ or ✕
doz console my-app --steps              # the latest boot's steps, then its kernel console
doz console my-app --boot 2             # the one before
doz console my-app --follow             # watch the console live as it boots
```

In the dashboard: **Boot log** on the sandbox's page (it works in any state; nothing is woken).

![A kept boot](images/boot-log.png)

## The host

```sh
doz host status          # is one running, and what does it hold? (never starts one)
doz host stop            # hibernate everything that runs, then stop the host
doz events               # follow what the host does, live (Ctrl-C stops)
doz events my-app        # only this sandbox
```

- **Idle exit.** The host exits after `host.idle_timeout_minutes` (5) with nothing running, paused
  or asleep and nobody attached. The next command starts a new one.
- **`doz host stop`** shows each sandbox as it hibernates, then a summary. Everything wakes on the
  next `wake`, `attach`, `up` or `exec`, sessions and all.
- **If the host crashes**, the next command starts a new one. Sleeping sandboxes come back with their
  sessions; hibernated ones are untouched. Ones that were running are marked as having died with the
  host (`doz ls`), and their disk is checked at the next start.
- **Logs** are in `<store>/host.log`. `doz metrics` shows how long each kind of action takes.

## Time zone

A sandbox follows your Mac's time zone, read again at every start and wake — so a sandbox that slept
while you travelled wakes in your new zone. The agent is told its time zone too. To pin one:
`doz config set sandbox.timezone Australia/Sydney`.

## Settings

| key | default | what it does |
|---|---|---|
| `defaults.cpus` | `2` | CPUs of a new sandbox (`--cpus`). |
| `images.lab.memory_mib` · `images.claude-code.memory_mib` · `images.pi.memory_mib` | `1024` · `2048` · `2048` | Memory of a new sandbox of each image (`--memory`); other images follow the one they're based on. |
| `defaults.projects_dir` | `~/Developer/dozer-sandbox-projects` | Where the dashboard suggests a new sandbox's shared folder. |
| `sandbox.timezone` | `mac` | `mac` (follow this Mac) or a zone like `Australia/Sydney`. Applies at each start or wake. |
| `host.idle_timeout_minutes` | `5` | Minutes with nothing running before the host exits; `0` = never (`$DOZ_HOST_IDLE`). |
| `host.screen_capture_minutes` | `5` | How often a running sandbox's changed screens are saved; `0` = only at pause, sleep and hibernate. |
| `host.boot_logs_kept` | `5` | Boots kept per sandbox (1–50). |
| `ui.boot_view_on_start` | `true` | The dashboard's Start opens a terminal on the boot. |
| `ui.confirm_shutdown` | `true` | The dashboard's Shut down asks first. |

## Limits

- Memory is reserved up to the sandbox's allocation while it runs; hibernate gives it all back.
- A snapshot (sleep, hibernate) can't be moved to another Mac: it is encrypted with a key specific
  to this Mac.
- Nothing pauses or sleeps a sandbox by itself yet; you (or a script) decide.

## Troubleshooting

| symptom | what to do |
|---|---|
| The first start is slow | It's preparing the image, once per store. `doz onboard` or `doz image bake NAME` does it ahead of time; `-v` shows the steps. |
| A start or wake failed | `doz console NAME --list`, then `doz console NAME --steps`: the failing step is marked ✕, with why. |
| A wake fails again and again | `doz host stop`, then wake again (a failed wake keeps its snapshot). Last resort: `doz shutdown NAME` then `doz start NAME` — programs end, the disks are kept. For Claude Code, `claude --continue` picks the conversation back up. |
| A sandbox shows as died | The host crashed while it ran. `doz start NAME` checks its disk and boots it. |
| "not possible in this phase" | The action doesn't fit the sandbox's state (e.g. `resume` on one that isn't paused). `doz ls` shows its state. |
