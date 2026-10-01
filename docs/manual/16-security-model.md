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

- **Your shared folder.** It's the agent's to change. Commit often.
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
| `sandbox.agent_sudo` | `true` | The agent's sudo inside its sandbox. |
| `ui.allow_secret_entry` | `true` | The dashboard may take a key or token. |
| `claude.permissions` | `skip` | Claude Code's own permission prompts (`ask` to keep them). |
