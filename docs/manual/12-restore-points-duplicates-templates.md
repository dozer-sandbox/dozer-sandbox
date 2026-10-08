# Restore points, duplicates and templates

Three ways to copy a sandbox's disk, each instant (they're APFS clones, sharing space until
something changes):

| | what it is | use it to |
|---|---|---|
| **Restore point** | a copy of a sandbox's disks at a moment, kept with the sandbox | undo: go back, or fork a new sandbox from that moment |
| **Duplicate** | a new sandbox from an existing one's disk | run the same setup on another project, or with more memory |
| **Template** | a sandbox's system disk saved as an image | make many new sandboxes that start set up your way |

None of them copies your workspace folder (it's on your Mac — use git) or memory (a restored or
forked sandbox cold-boots).

## Restore points

```sh
doz point take my-app before-refactor --note "tests green"   # a running sandbox pauses for milliseconds
doz point ls my-app
doz point revert my-app before-refactor                       # shuts down and goes back; start boots it
doz point fork my-app before-refactor try-2                   # a new sandbox from that moment
doz point rm my-app before-refactor
```

- A point covers the sandbox's **disks** — the system disk and the agent's state disk — not what's
  running.
- **Revert takes a point first** ("before revert"), so a revert can itself be undone.
- Name a point with anything up to 64 characters (kept exactly as you type it). Wherever a command
  takes a point, you can give its name, its id (`rp-…`) or the start of either, as long as only one
  matches.
- Commands that ask first (`revert`, `rm`) check the point exists before asking, and the question
  names it, its id and when it was taken.

**In the dashboard:** a sandbox's details › **Points** has **Take a restore point…**, and per point
**Revert**, and under its **⋯** **Fork…**, **Save as template…**, **Duplicate…** and **Delete…** (revert
and delete ask you to type the name).

## Duplicates

```sh
doz duplicate my-app my-app-2 --workspace ~/code/other-project --cpus 4 --memory 4G
doz duplicate my-app my-app-3 --from-point before-refactor --network locked
doz duplicate my-app my-app-4 --copy-state        # the agent's logins and history too
```

- The new sandbox is **off** until you start it. Anything you don't give is the source's, its
  permissions included.
- A `--workspace` that doesn't exist is made; `--isolated` shares no folder.
- The agent's **state disk starts fresh** unless `--copy-state`.
- Keys given with `doz key set` are not copied; the account follows `--account` or the source's.

**In the dashboard:** **⋯** › **Duplicate…** on the sandbox's page (or from a restore point): new name, from
the current disk or a point, workspace, CPUs, memory, network, account, and "Copy the agent's state
disk too".

## Templates

```sh
doz template create my-app --as node-tools --note "node 22 + pnpm"   # now (a live sandbox pauses for ms)
doz template create my-app --from-point before-upgrade --as base-2   # or from a restore point
doz point save-image my-app before-upgrade --as base-3               # the same, from the point command
doz template ls
doz create beta --image node-tools
doz template rm node-tools                                           # sandboxes made from it keep working
```

- **Everything on the system disk is in it**: what you installed or wrote in `/root`, `/etc`,
  `/usr`, `/opt`, caches. **Don't save a secret you put there.**
- **The agent's state disk is never in it** (logins, history, tokens), so a template can be shared.
  A sandbox made from a template starts with a fresh state disk.
- A sandbox from a template gets the agent and settings of the image the template came from.

**In the dashboard:** **⋯** › **Save as template…** on a sandbox's page (now, or from a restore point); New
sandbox › **Base** › **Template** uses one; **Images** lists templates and removes them.

## Seeing the family tree

```sh
doz image ls --tree
```

```
IMAGE / SANDBOX   KIND      SIZE    SHARED  OWN
alpine-3.20       prepared  34 MiB  —       116 KiB
├─ tpl-a          template  36 MiB  33 MiB  160 KiB  from alpha
├─ alpha          sandbox   36 MiB  33 MiB  0 B
└─ beta           sandbox   34 MiB  34 MiB  224 KiB
```

**Shared** is what a disk shares with its parent (counted once on disk); **Own** is what removing it
would free. The dashboard's **Images** › **Lineage** draws the same tree.

## Limits

- Restore points are disk-only: a revert or fork cold-boots, and running programs start fresh.
- A template can't be exported to another Mac yet (no registry push).
- A sandbox's saved screens and boot logs aren't copied by duplicate, fork or templates.

## Troubleshooting

| symptom | what to do |
|---|---|
| "more than one point matches" | Give more of the name or id; the message lists the matches. |
| A reverted sandbox doesn't have my latest code | The workspace is on your Mac and isn't part of a point: use git for it. |
| A duplicate's agent has none of the conversation history | Its state disk started fresh: duplicate again with `--copy-state`. |
| Disk space after many points | Each point costs only what changed since; `doz resources` shows each one, and `doz point rm` frees it. |
