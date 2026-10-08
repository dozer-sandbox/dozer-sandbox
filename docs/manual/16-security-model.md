# Security model

Dozer's job is to let an AI agent work freely — install things, run code, make a mess — without
putting your Mac, your credentials or your data at risk. This page explains what protects you, what
each boundary does and doesn't cover, and the few ways a sandbox can reach your Mac by design.

## The boundaries

### 1. A virtual machine, not a container

Each sandbox is a real Linux VM with its own kernel, run by Apple's Virtualization framework. A
program in it — root included — sees only the VM: its own disks, and nothing of your Mac except the one
folder you chose to share at `/workspace`. An isolated sandbox shares nothing at all.

- The shared folder is live in both directions: **the agent can change or delete anything in it.** Use
  git (or `--isolated`, or a copy) for anything you can't afford to lose.
- A sandbox's disks are its own files in the store; restore points copy them.

### 2. No network card: everything goes through the proxy

A proxied sandbox (the default for every image) has no network interface. Its only way out is Dozer's
proxy, in the host on your Mac, which checks every connection — DNS included — against the sandbox's
[permissions](10-permissions-and-network.md), and logs it (host, verdict, bytes; never contents).

- The agent can't change its own permissions, and root inside the VM can't get around them: there is
  no route out but the proxy.
- **Browse the web** and **Open** let the agent reach anything, so it could send your code anywhere.
  They warn before you turn them on. Prefer `site:HOST` for what's really needed.
- `--network nat` gives a sandbox a real network card, **not filtered or logged**; `--network none`
  gives it none. Use `nat` only when you mean it.

### 3. Credentials never enter the sandbox

The proxy holds your Claude login, token or API key and adds it to requests to Anthropic on their way
out. Inside the sandbox the agent sees a placeholder (`doz_cred_…`), so there's nothing to steal:

- a secret is never written into the VM, never a command-line argument, never in a log, an event or an
  error message;
- your Mac login's refresh token is never read — only the short-lived access token;
- a credential the agent brings itself is flagged or refused (the [key policy](09-agents-and-accounts.md#a-credential-the-agent-brings-itself));
- accounts are stored in your login keychain, and the dashboard never shows a secret.

**Codex's ChatGPT plan** works the same way ([Codex](24-codex.md)): Dozer's own ChatGPT sign-in is kept in
your login keychain; the sandbox's `~/.codex/auth.json` holds placeholders (and the sign-in's details
without their signature); the proxy puts the access token into requests to `chatgpt.com` only, and
renews it on your Mac — Codex's own renewal request is answered by the proxy, never sent on. Your
Mac's own Codex login (`~/.codex`) is never read or changed.

**Your GitHub login** works the same way, and only when you choose it — for new sandboxes in setup's
Access step, or for one sandbox ([GitHub as you](18-github.md)):

- the token (your Mac's `gh` login, read when used and kept in the proxy's memory a few minutes, or a
  token you gave the sandbox) never enters the VM, the store or a log — the sandbox's `GH_TOKEN` and
  git's login are placeholders, swapped only on the way to `github.com`, `api.github.com`,
  `uploads.github.com` and `codeload.github.com` (git's `Basic` login is decoded, swapped and
  re-encoded there, and nowhere else);
- **read-only is enforced by the proxy**, request by request: `git-receive-pack` (a push) is refused,
  and so is every request to the API that isn't a read — except a GraphQL request whose document holds
  only queries. Dozer reads that document conservatively: anything it can't tell is read-only is refused;
- turning the permission off (or `gh auth logout` on the Mac) ends it at once: every placeholder already
  issued is refused;
- with **Push to GitHub** on, the agent can push and act on GitHub as you, within what your token may
  do — so prefer a fine-grained token limited to the repositories it works on (`doz key set NAME
  --github`). Every change it makes is in the network log;
- with **SSH agent forwarding** on (`sandbox.ssh_agent`), the agent can ask your Mac's ssh-agent to sign
  — and so authenticate as you to github.com — while it's on; your keys never leave the Mac, it can't
  add, remove or lock keys in your agent (only list and sign get through), and only `github.com:22` is
  reachable over SSH.

**Access — every credential is a purposeful choice.** Setup's Access step (and `doz access`) puts the
Claude account, GitHub as you and SSH agent forwarding side by side, each with what it means. GitHub
and SSH are **off** until you choose them, and nothing is turned on silently — not by `doz onboard
--yes`, not by the **Open** preset. Each choice is confirmed live, on your Mac:

- GitHub: the real token is read the way a sandbox would get it and sent to `api.github.com` (`GET
  /user`, plus `/user/repos` for a fine-grained token) over the proxy's own TLS connection, verified
  against your Mac's trust store. The answer you see is the login and the scopes or a repository count —
  never the token;
- SSH: your agent is asked for its list of keys — nothing is signed;
- the result is kept in `access.json` in the store: states and reasons only, never a secret. A pasted
  GitHub token goes straight to the host and into your login keychain (`doz-github`) — the dashboard
  takes it only while `ui.allow_secret_entry` is on, in a masked field it empties at once, and never
  shows it again.

A check that fails never turns anything on or off by itself: **Skip** keeps your choice, marked *not
confirmed*; turning it off is yours to do.

### 4. Root inside is not root outside

The agent has passwordless `sudo` inside its sandbox by default. That's deliberate: root inside the VM
reaches no more than the agent does — the same proxy, no credentials, only the shared folder. It lets
the agent install what it needs. Turn it off with `sandbox.agent_sudo` if you prefer.

### 5. The host and the dashboard are yours alone

- The host listens on a socket in your store, readable only by you.
- The dashboard listens on your Mac's loopback only, signs a browser in with a one-use link, checks the
  exact host and origin and a CSRF token on every change, and runs each terminal in an isolated frame:
  whatever a sandbox prints can't reach the dashboard's session or other terminals.
- The dashboard never sets a folder of your Mac from what the page sends: the projects folder's
  **Choose…** opens your Mac's own folder picker, and the folder you pick there is what is saved
  (never a folder inside the store, never `/`).
- A dashboard link is a key: don't paste it anywhere.
- `doz serve` (the dashboard for your other devices — [its page](25-doz-serve.md)) is a separate process you
  start yourself. A browser needs an invite to get in (a link, a code or a QR code — one browser each, five
  minutes) and stays in until you remove it; every request's host and origin are checked against this Mac's names
  and addresses (or your proxy's address, only from a proxy you named in `serve.trusted_proxies`); keys and
  tokens are never taken over plain HTTP; and a sandbox can never reach it — a sandbox network's connection is
  dropped, and the proxy refuses the dashboards' ports on your Mac's own addresses. What other browsers do is in
  `doz serve log`.

## The bridges — deliberate ways in to your Mac

A session's terminal lets a program in the sandbox do three things on your Mac, because agents need
them. Each is announced every time it's used, rate-limited, works only while a terminal is attached,
and can be turned off per sandbox or for all. All three travel the same way — a private escape
sequence in the session's output, which Dozer's host takes out and decides on; the sandbox has no other
channel to your Mac.

| bridge | what the sandbox can do | what it can't | the risk | turn it off |
|---|---|---|---|---|
| **Clipboard** | put text on your Mac's clipboard (up to 1 MiB, 10 copies per 10 s) | **read** your clipboard — ever | an agent could plant a command for you to paste | `sandbox.clipboard = off` |
| **Browser** | open an http(s) page in your default browser (3 per 10 s); during a sign-in, receive the redirect on one loopback port for up to 10 minutes | open `file:` or other schemes, reach your Mac's own `localhost`, forward any other port | an agent could open a misleading page | `sandbox.browser_bridge = off` |
| **Files** | open a document from its shared `/workspace` in its default app, or in an app you listed in `bridges.open_apps`; open the workspace or a folder in it in the Finder; show a file selected in its folder (`--reveal`) — 3 per 10 s | open anything outside the shared folder (paths are resolved on the Mac — `..` and links that lead out are refused), an app or package folder (not even in the Finder — only revealed), a folder as an app, an app, script, installer or link file, an executable, a program or `#!` script renamed as a document (the first bytes are checked), or an app you didn't list; anything at all in an isolated sandbox | an agent could open a misleading page or document (an html file runs its scripts in your browser, as a local page) | `sandbox.open_files = off` |

The agent is told about all three, including that you see a notice every time.

One limit of the files bridge, stated plainly: the file is checked and then handed to macOS to open,
so an agent racing that moment (a few milliseconds) could swap in another file from your shared
folder. It can only ever name something the shared folder reaches, and macOS is only ever given a
fully resolved path.

## Things that run outside a sandbox

- **Dockerfile builds** run in Apple's `container` builder, **outside Dozer's network policy**: their
  `RUN` steps reach the internet directly. Only build Dockerfiles you trust. See
  [Images and bases](08-images-and-bases.md#your-own-dockerfile).
- **Image preparation** runs in a temporary VM with the `bake` permissions (package registries only),
  logged like any sandbox.
- **Keep-alive**, when you turn it on, runs your Mac's own `claude` once near expiry.

## What Dozer can't protect

- **Your shared folder.** It's the agent's to change. Commit often. [Workspace rules](20-workspace-rules.md)
  (`.dozignore`, `.dozreadonly`) keep an agent from stumbling into files there, but they are a convenience,
  not a boundary: root in the sandbox can get around them. A secret that must not reach a sandbox does
  not belong in the folder it shares.
- **What you allow.** A permission or a site you allow is reachable; data can go there.
- **What you paste or open.** Read clipboard, browser and file notices, and don't run what an agent put
  on your clipboard without looking.
- **Another agent driving `doz` on your Mac** has your permissions: brief it to leave permissions and
  deletion to you ([Letting another agent drive Dozer](14-letting-another-agent-drive.md)).
- **Secrets you put on a sandbox's disk yourself** travel with its restore points and templates.

## Settings

| key | default | what it does |
|---|---|---|
| `defaults.permissions` | `standard` | What a new sandbox's agent may reach. |
| `sandbox.clipboard` | `write` | The clipboard bridge. |
| `sandbox.browser_bridge` | `on` | The browser bridge. |
| `sandbox.open_files` | `on` | The files bridge. |
| `bridges.open_apps` | `""` | The apps a sandbox may name for the files bridge (none: default apps only). |
| `defaults.github` | `off` | "Use GitHub as you" for new sandboxes: `off`, `read` or `push`. |
| `github.credentials` | `gh` | Where "Use GitHub as you" gets your login: `gh`, `key` or `off`. |
| `sandbox.ssh_agent` | `off` | Forward your Mac's ssh-agent (github.com:22 only). |
| `sandbox.agent_sudo` | `true` | The agent's sudo inside its sandbox. |
| `ui.allow_secret_entry` | `true` | The dashboard may take a key or token. |
| `claude.permissions` | `skip` | Claude Code's own permission prompts (`ask` to keep them). |
