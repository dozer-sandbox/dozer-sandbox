# The workspace view (`dozview`)

When a sandbox's shared folder holds a `.dozignore` or a `.dozreadonly`, `/workspace` inside the sandbox is
not the shared folder itself: it is a filtering view of it, served by a small Dozer program, **`dozview`**.
This page is what that program is, what it does, and how to look inside it. What the rules mean is in
[Workspace rules](20-workspace-rules.md).

**No rule file, no view.** Without a `.dozignore` or `.dozreadonly`, the folder is shared exactly as it
always was: `dozview` does not run and nothing costs anything.

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

Looking at many files for the first time is slower than the plain share — a tree of 2,000 files takes about
0.1 s more to walk the first time. Once looked at (for about a second), names are close to the plain share's
speed. Hiding a big folder often makes a whole-tree walk faster than before.

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
