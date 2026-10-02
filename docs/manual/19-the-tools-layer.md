# The tools layer

Some settings need a tool inside the sandbox to be useful: "GitHub as you" is best with `gh`, SSH agent
forwarding needs an ssh client and GitHub's host keys, tmux sessions need tmux. Dozer puts them there for
you — the **tools layer**: the tools Dozer manages in each sandbox, chosen by its settings. It works on
every base (Debian, Ubuntu, Alpine, your own Dockerfile) and never rebuilds an image.

## Tools Dozer provides

| tool | when | how it gets there |
|---|---|---|
| `gh` (GitHub CLI) | **GitHub as you** is on | downloaded **once** to this Mac (a pinned version, its sha256 checked), then copied into the sandbox — the sandbox's network is not used. Removed again when GitHub as you is turned off. |
| ssh client | **SSH agent forwarding** is on | `apt` or `apk`, through the proxy, when the image lacks it |
| github.com's host keys | **SSH agent forwarding** is on | GitHub's published keys, built into Dozer, written to `/etc/ssh/ssh_known_hosts` — so `ssh -T git@github.com` never asks "are you sure?". Removed when forwarding is turned off. |
| `tmux` | **sessions.tmux** is on | `apt` or `apk`, through the proxy, when missing |
| `git`, `curl`, ca-certificates | always | `apt` or `apk`, through the proxy, when missing (every Dozer image already has them; a plain lab sandbox may not) |

`gh` lives at `/usr/local/lib/doz/bin/gh` (first on every session's `PATH`) and is linked as
`/usr/local/bin/gh` unless something else is already there. A `gh` you installed yourself is never touched.
It is signed in through the same placeholder as git: `gh auth status` shows your login, and `gh repo
view`, `gh pr list` and the rest work — read-only unless **Push to GitHub** is on.

## When it runs

- **The first start** of a sandbox sets the layer up and shows each tool as a step:

  ```
  ✓ tools: gh 2.102.0 on this Mac (downloaded once, sha256 checked)
  ✓ tools: installing ssh client with apk, through the proxy — 3.8 s
  ✓ tools: gh 2.102.0 — for GitHub as you (gh 2.102.0, from Dozer's cache on the Mac)
  ✓ tools: ssh client — for SSH agent forwarding (from apk)
  ✓ tools: github.com host keys — for SSH agent forwarding (github.com's published keys in /etc/ssh/ssh_known_hosts)
  ✓ tools: git — always (already in the image)
  ```

  `doz up`, `doz new`, `doz create --start` and Quick add show the same lines.
- **In the dashboard's New sandbox wizard**, the last step is **Setting up tools**: each tool with why it
  is there, the start's progress, then ✓ or ✗. A failure never stops you — **Retry**, or **Continue
  anyway**, then **Open the sandbox**.
- **Every later start and wake** checks the layer again, quietly: a setting you turned on while the
  sandbox slept is delivered then, one you turned off is removed. You see a notice only when something
  changed or failed. Changing a setting while the sandbox runs applies at once.
- **Never fatal.** An offline Mac, a refused download or a package mirror that doesn't answer is a ✗ with
  its reason; the sandbox starts anyway, and the next start or wake tries again.

## See it, set it up again

```sh
doz tools my-app             # each tool, why, its state, and what this Mac keeps
doz tools my-app --apply     # set it up again now (the sandbox must be running)
```

```
Tools layer of my-app — from its settings:
  ✓ gh 2.102.0             for GitHub as you          gh 2.102.0
  ✓ ssh client             for SSH agent forwarding   already in the image
  ✓ github.com host keys   for SSH agent forwarding   github.com's published keys
  ✓ git                    always                     already in the image
On this Mac: gh 2.102.0 (37 MB, sha256 7862c86c72f4…) — …/tools/gh/2.102.0/gh
```

`doz doctor` has a **tools layer** line; **Resources** lists the cache as **tools layer** (deleting it is
safe: it is downloaded again the next time a sandbox needs it).

## Limits and notes

- gh is pinned (2.102.0) and updated with Dozer, not by itself.
- Packages come from your image's own mirrors (Debian, Ubuntu, Alpine) — allowed by the **Install
  software › System packages** permission, on in Standard. With a network that can't reach them
  (`--network none`), a missing package is reported, not installed.
- Images are never rebuilt for the layer, and preparing an image never runs it: what an image holds stays
  exactly its recipe.

See also: [GitHub as you](18-github.md), [Terminals and sessions](07-terminals-and-sessions.md),
[Resources and disk space](13-resources-and-disk-space.md).
