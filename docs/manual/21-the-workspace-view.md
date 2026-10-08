# The workspace view (`dozview`)

`/workspace` inside a sandbox is not your shared folder itself: it is a live view of it, served by a small
Dozer program, **`dozview`**. This page is what that program is, what it does, and how to look inside it.
When the folder holds a `.dozignore` or a `.dozreadonly`, the view also applies those rules — see
[Workspace rules](20-workspace-rules.md). Without either file it applies nothing: every file is there, as on
your Mac.

## Why every workspace goes through it

A program working inside `/workspace` — an agent, a shell, a dev server — **keeps its folder when the
sandbox wakes from hibernation** (and after a host restart, which hibernates). The plain share cannot do
that: a hibernation disconnects it, and the sandbox has to connect it again on wake, so a program that was
inside it is left in a folder that no longer exists. Codex then fails every turn with
`invalid cwd: No such file or directory`; a shell says `No such file or directory` for `ls .`. The view is
never disconnected — it reconnects to your folder underneath — so nothing inside notices the wake.

**What it costs.** Most of the time nothing you would notice. The first look at many files after a start or
a wake is slower — measured on 2,000 small files:

| | through the view | the plain share |
|---|---|---|
| the first `find` of the tree after a start | about 0.19 s | about 0.02 s |
| `stat` of 1,000 files not looked at in the last second | about 0.1 s | about 0.02 s |
| reading every file | about 0.4 s | about 0.25 s |
| the same `find` again, or 8 programs reading at once | about the same | |

So a `git status` on a big repository, right after a start or a wake, takes noticeably longer the first
time; after that it is about as fast as before.

**Turning it off.** `doz config set workspace.view off` (every sandbox), or for one sandbox
`doz create … --workspace-view off`, `workspace_view: off` in its `doz_project.yaml`, or
`doz config set --sandbox NAME workspace.view off`. The folder is then shared directly — a little faster,
but a program working inside `/workspace` loses its folder at every wake from hibernation and has to be
restarted ([Restart session](07-terminals-and-sessions.md#restarting-or-ending-a-session)). A folder with a
`.dozignore` or `.dozreadonly` always uses the view.

**When it takes effect.** At the sandbox's next start — never under programs that are running. A sandbox
that was already running when you upgraded (or turned the setting on) changes over at its next start, or at
its next wake from hibernation (whose wake would have cut its programs off anyway). Its first such wake is
still the old one; restart the session if a program complains.

**If the view cannot start**, the folder is shared directly instead (never an empty `/workspace`): the
start says so, and `doz doctor` warns "workspace view" for that sandbox. `doz ls --json` reports how each
running sandbox's workspace is served (`workspaceView`: `live`, `rules`, `direct`, `next-start` or
`fallback`).

## What it does

- Your Mac folder reaches the sandbox as usual, but it is mounted privately at `/run/doz/raw/<id>`, inside
  a folder only root can enter.
- `dozview` presents that folder at `/workspace` (Linux FUSE — a program acting as a file system). Every
  file operation in `/workspace` goes through it, and it checks the path against the rules first:

  | the path is | what happens |
  |---|---|
  | in `.dozignore`, mode **lock** (the default) | listed as `----------`; every read, write, rename and listing is refused — "Permission denied", for root too |
  | in `.dozignore`, mode **hide** | not listed; "No such file or directory" |
  | in `.dozreadonly` | listed and readable; every change is refused (an ordinary user sees "Permission denied", root "Read-only file system") |
  | anything else | passed straight through to your Mac folder, both ways |

- **Always read-only**, whatever the rules say: `.dozignore` and `.dozreadonly` themselves (an agent cannot
  edit its own rules), and — unless your `.dozreadonly` says `!name` — `doz_project.yaml`,
  `doz_project.yml` and `.git/hooks`.
- **Rules are read from the shared folder itself.** Edit `.dozignore` on the Mac and the sandbox follows
  within about a quarter of a second; `dozview` also drops anything the sandbox's kernel had cached about
  the affected names.
- **On a case-insensitive Mac volume** (every default one), matching ignores case and Unicode form, so
  `cat SECRET.ENV` does not read a locked `secret.env`. That only ever covers more than Docker would.

## Two processes

`ps` in the sandbox shows `dozview` twice. They are one daemon in two parts:

| process | job |
|---|---|
| the **supervisor** (the lower pid) | holds the connection to the kernel. If the worker dies — a crash, or someone killing it — it starts a new one within about 0.1 s and `/workspace` stays mounted. If the mount itself goes, it mounts a fresh view. |
| the **worker** | answers the file requests, on 6 threads, so a busy agent is not served one request at a time. |

A shell whose current folder is a *subfolder* of `/workspace` may need to `cd` again after a worker restart;
a request in flight at that moment is lost.

## Sleep, hibernate and wake

`dozview` is an ordinary process in the sandbox, so pause, sleep and hibernate keep it, with its rules.
After a hibernation the share underneath must be connected again: on wake, Dozer re-mounts the private
share and signals `dozview` to reconnect, in the same step. Three safeguards make that safe:

1. It never re-reads the rules over a broken connection — it keeps the last rules.
2. If a request finds the connection broken before the signal arrives, it repairs it itself and retries.
3. It never reconnects to anything that is not your shared folder — during the moment of the re-mount the
   path is an empty folder, and adopting it would show an empty `/workspace` with no rules.

A wake takes no measurably longer with the view than without.

## Cost

As above: looking at many files for the first time is slower than the plain share — a tree of 2,000 files
takes about 0.1–0.2 s more to walk the first time. Once looked at (for about a second), names are close to the
plain share's speed. With rules, hiding a big folder often makes a whole-tree walk faster than before.

## Looking inside

| to see | run |
|---|---|
| the rules, the mode and whether the view is running | `doz ignore show NAME` |
| which line decides a path | `doz ignore check NAME PATH` |
| the processes | `doz exec NAME -- ps` |
| the mode and case setting Dozer gave it | `doz exec NAME -- sh -c 'cat /run/doz/view/*.conf'` |
| its log (rule reloads, reconnects, worker restarts, lines that did not parse) | `doz exec NAME -- sh -c 'tail /run/doz/view/*.log'` |

Its files are in `/run/doz/view/`: the `.conf` Dozer writes (the mode, and whether matching ignores case),
its `.state`, its `.pid` (the supervisor's) and its `.log`. The program is copied into the sandbox at
`/usr/local/lib/doz/bin/dozview` — it never runs from your shared folder.

## Not a security boundary

Root in the sandbox can stop `dozview`, or reach the private share directly. The view keeps an agent from
stumbling into files you listed; the virtual machine is the boundary. See [Security model](16-security-model.md).

## About the program

A small static Linux program written in C, with no outside libraries — it speaks the kernel's FUSE protocol
itself rather than using the usual FUSE library (whose licence would complicate shipping it inside Dozer).
The copy Dozer ships is checked to rebuild byte for byte from its source.

See also: [Workspace rules](20-workspace-rules.md) · [Troubleshooting and FAQ](17-troubleshooting-and-faq.md).
