# Workspace rules: `.dozignore` and `.dozreadonly`

A sandbox's `/workspace` is your Mac folder, live. Often you want the agent to see most of it but not
everything: not `secrets.env`, not your `doz_project.yaml`, not a folder of build output it would only
wade through. Two files at the root of the shared folder say so:

- **`.dozignore`** lists paths the agent must not use. By default they stay **listed but locked**: shown
  with no permissions (`----------`), and every read, write, rename or delete of them is refused — so a
  program that bumps into one by name sees why. With `workspace.ignore_mode = hide` they are **not there
  at all**.
- **`.dozreadonly`** lists paths the agent may read but not change.

Your Mac is never touched: you keep editing every file as before, and the sandbox sees your changes. With
neither file, every file is there as it is on your Mac (the folder still goes through
[the workspace view](21-the-workspace-view.md), which keeps programs in it working across a wake).

> **A convenience, not a security boundary.** The rules keep an agent from stumbling into files. Root in
> the sandbox — and the agent has `sudo` by default — can get around them. Anything that must not reach
> the sandbox at all belongs outside the shared folder (or in an isolated sandbox); see the
> [Security model](16-security-model.md).

## The syntax: Docker's `.dockerignore`

Both files use exactly the syntax of Docker's `.dockerignore` (and `docker build`'s behaviour):

```
# secrets and clutter (a comment: only when # is the first character of the line)
secrets.env
logs
!logs/keep.txt
**/*.key
**/node_modules
build/*.tmp
```

Line by line: `secrets.env` at the **top** of the workspace (not deeper); the folder `logs` and
everything in it; except `logs/keep.txt`, which stays usable; any `.key` file at any depth; every
`node_modules` folder; `.tmp` files directly in `build` (`*` and `?` never cross a `/`). A `#` later in
a line is part of the pattern, as in Docker.

- **Patterns are anchored at the root of the workspace.** `node_modules` means only the top one —
  unlike `.gitignore`. Write `**/node_modules` for every depth. `doz` warns when a name you wrote this
  way also exists deeper.
- A pattern matches a path **or any folder above it**, so listing a folder covers everything inside.
- **The last line that matches wins**; `!pattern` makes an exception. An exception can reach inside a
  listed folder: with `logs` then `!logs/keep.txt`, the folder `logs` stays visible holding only
  `keep.txt`.
- A trailing `/` changes nothing (`logs/` also covers a *file* named `logs`); a leading `/` or `./` is
  dropped.
- A line that is not a valid pattern is skipped, and `doz` tells you which (Docker would refuse the
  whole file).

**Names are compared without case** when your Mac's volume ignores case (every standard macOS volume):
`SECRETS.ENV` in the sandbox is the same file as `secrets.env` on the Mac, so the rules cover it — and
the same for accented letters written in either Unicode form. This only ever covers *more* than Docker
would.

## Always read-only

While a sandbox's rules apply, these are read-only even if your `.dozreadonly` does not list them:

| path | why |
|---|---|
| `.dozignore`, `.dozreadonly` | the agent must not change its own rules; they are always visible, so it can read why something is missing |
| `doz_project.yaml`, `doz_project.yml` | your project's sandbox settings — a `!doz_project.yaml` line in `.dozreadonly` lets the agent edit it |
| `.git/hooks/` | a hook the agent rewrote would run on your Mac at your next commit — `!.git/hooks` re-allows it |

## Lock or hide

```bash
doz config set workspace.ignore_mode hide                  # for every sandbox
doz config set --sandbox my-app workspace.ignore_mode lock  # for one
doz create my-app --workspace ~/code/app --ignore-mode hide
```

or `ignore_mode: hide` in `doz_project.yaml` (`doz init --ignore-mode hide` writes it).

Setting up this Mac asks the same question once — **Lock** (recommended) or **Hide** — for the default
(`doz onboard --ignore-mode hide`, or the dashboard's setup wizard), and only writes the setting when you
choose; the **New sandbox** wizard and `doz init` have a **Workspace rules** step that shows what the
chosen folder already has and asks for that sandbox.

| | **lock** (the default) | **hide** |
|---|---|---|
| `ls` | listed, as `----------` | not listed |
| reading, writing, deleting it | refused: *Permission denied* — for root too | *No such file or directory* |
| creating a file of that name | refused | refused |
| recursive tools (`grep -r`, `find`) | print a *Permission denied* line for it | quiet |

Lock is the default because an agent that writes to a file it cannot see would not know why it failed.
Hide suits clutter (build output, large data) that only gets in the way.

Read-only paths are visible and readable but every change fails: *Read-only file system* for root, *Permission
denied* for an ordinary user (their write bits are not shown).

## When the rules apply

- **Changes on the Mac apply within a second** — edit `.dozignore` while the sandbox runs, and the
  sandbox follows.
- A sandbox that **gains** its first rule file gets the rules at its next session start, wake or start.
  A program already inside `/workspace` keeps what it has open until it changes directory.
- Removing **both** files takes effect at the next start: until then the folder is served with no rules.
- A new `workspace.ignore_mode` applies at the next session start, wake or start.
- Pausing, sleeping, hibernating and waking keep the rules — and so does a sandbox restored after the
  host restarts.

The agent is told: its facts say that files shown with no permissions are blocked by your `.dozignore`
and must not be read or recreated, and which paths are read-only.

## Checking

```bash
doz ignore check my-app secrets.env logs/old.log /workspace/config/app.yaml
doz ignore show my-app
```

`doz ignore check` says, for each path (relative to the workspace, `/workspace/…`, or the Mac path), what
it is in the sandbox and which line of which file decides — no virtual machine is needed:

```
PATH                  IN THE SANDBOX  WHY
secrets.env           locked          .dozignore line 2 (`secrets.env`)
logs/old.log          locked          .dozignore line 3 (`logs`) — through logs
config/app.yaml       read-only       .dozreadonly line 1 (`config`) — through config
SECRETS.ENV           locked          .dozignore line 2 (`secrets.env`), matched case-insensitively
```

`doz ignore show` lists every rule with its line, the mode and where it is set, and whether the rules
are in force in the sandbox right now. Add `--json` to either for a script.

**Warnings** — `doz create`, `doz up` and `doz start` say which rules are in force and warn (they never
stop) when:

- a pattern locks or hides `.git` — git cannot work in the sandbox;
- git-tracked files are locked or hidden — `git status` in the sandbox shows them as deleted, and `git
  commit -a` or `git add -A` there would record their deletion;
- git-tracked files are read-only — a checkout, pull or merge that changes them fails in the sandbox;
- a root-anchored name also exists deeper (`node_modules` with a `web/node_modules`).

In the dashboard, a sandbox with rules shows **rules** beside its name, and its details say how many
patterns each file has and whether they are in force. A sandbox whose folder has no rule file says
*Workspace rules: none — the folder is shared as is*; an isolated sandbox shares no folder, so says
nothing.

## How it works

When the folder holds a rule file, the share is mounted privately inside the sandbox and `/workspace` is a
small filtering view of it, served by Dozer's own program in the sandbox. That view decides each name as
it is looked up — so a file created later, on either side, is covered at once. It costs a little on
metadata-heavy work: walking a tree of 2,000 files for the first time takes about 0.1 s more, reading
everything about 1.8× as long as without rules; once looked at, it is close to the plain share — and
hiding a big folder often makes a whole-tree walk faster than before. Without a rule file none of this
runs. [The workspace view](21-the-workspace-view.md) has the details.

## Troubleshooting

| what you see | what to do |
|---|---|
| a file you expected is `----------` or missing | `doz ignore check NAME PATH` names the line; edit the file on the Mac |
| `git status` in the sandbox shows files as deleted | they are tracked and locked or hidden — unlock them, or keep them out of git |
| a file stays visible though `.dozignore` lists `name` | the pattern is anchored at the top: write `**/name` |
| `/workspace` is empty in the sandbox | the view could not start; `doz ignore show NAME` says so — the next wake or start tries again |
| the rules seem to apply only part of the time | a long-running shell inside a folder from before the rules existed: `cd /workspace` again |

See also: [Projects](04-projects.md) · [Settings reference](15-settings-reference.md) ·
[Security model](16-security-model.md).
