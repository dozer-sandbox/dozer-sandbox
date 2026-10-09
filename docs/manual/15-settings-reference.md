# Settings reference

Every setting Dozer has is in one file, **`~/.config/dozer-sandbox/doz.toml`** (under
`$XDG_CONFIG_HOME` when that is set). The file lists every setting with a description and its
default, commented out; only the values you set are uncommented. The dashboard's **Settings** page
shows and edits the same file.

## Where a value comes from

For each setting, the first of these that says something wins:

1. **a command-line flag** (for the few settings that have one — `--store`, `--progress`,
   `doz create --cpus`, …);
2. **its environment variable** (`DOZ_STORE`, `DOZ_PROGRESS`, `DOZ_HOST_IDLE`, `DOZ_SCREEN_CAPTURE`,
   `DOZ_BOOT_LOGS`, `DOZ_SUBNET`, `DOZ_KERNEL`, `DOZ_KERNEL_CACHE`);
3. **the file**;
4. **the default**.

`doz config show` names the source of every value. A few settings can also be **one sandbox's own**
(below); a sandbox's own value wins over the file's.

## Read and change settings

```sh
doz config                                  # every setting: value, source, default
doz config get ui.theme                     # one value (--json adds its source and default)
doz config set ui.theme dark                # write it to the file (checked against its type first)
doz config unset ui.theme                   # back to the default (commented out again)
doz config init                             # write the file with every setting commented out
doz config path                             # where the file is
```

In the dashboard: **Settings** lists every setting with its value, default, description and source,
and changes it in place (**Default** puts one back). A value set by an environment variable, and the
settings that name a folder on your Mac, are shown read-only there — change them with
`doz config set`.

### Per sandbox

`sandbox.clipboard`, `sandbox.browser_bridge`, `sandbox.open_files`, `sandbox.ssh_agent`,
`sessions.tmux` and `sandbox.agent_sudo` can also be set for one sandbox:

```sh
doz config show --sandbox my-app                          # its values, and whose value each is
doz config set --sandbox my-app sandbox.clipboard off
doz config get --sandbox my-app sessions.tmux
doz config unset --sandbox my-app sandbox.clipboard       # follow the setting again
```

Or when you create it (`doz create --clipboard off --browser-bridge off --open-files off --ssh-agent on --tmux --no-agent-sudo`),
or in its `doz_project.yaml` (`clipboard:`, `browser_bridge:`, `open_files:`, `ssh_agent:`, `tmux:`, `agent_sudo:`).

"Use GitHub as you" is a permission, not a setting: `doz net allow NAME github:as-you` (and
`github:push`), `doz create --github read|push`, `github:` in `doz_project.yaml` — see
[GitHub as you](18-github.md).

## About the file

- **The file is Dozer's.** `set`, `unset`, `init` and the Settings page rewrite it whole, atomically,
  readable only by you. Comments you add aren't kept.
- **A mistake never breaks Dozer.** An unknown key or a value of the wrong type is a warning (that line
  is ignored, the default applies). A file that doesn't parse at all is ignored — with the line that's
  wrong — and never overwritten until you fix it.
- **When a change applies** is part of each setting: at once, for the next command, the next sandbox
  created, the next session, the next start or wake, or after `doz host stop`.

## Not settable, on purpose

The dashboard's security limits and checks (session and link lifetimes, request and connection caps,
the Host/Origin/CSRF checks, the content policy); a browser terminal's one-use tickets and paste
limits; the guest programs; and any credential. `ui.terminals` can only take something away.

## Every setting

This table is generated from `doz config show` and checked against it on every build.

<!-- settings:begin -->
### `[ui]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `ui.boot_view_on_start` | `true` | boolean | at once | — | Start opens a terminal on the boot sequence (the kernel console) until the sandbox is up; false: Start just starts it. |
| `ui.confirm_shutdown` | `true` | boolean | at once | — | Shut Down asks first (its dialog's "don't ask again" sets this to false). Reset and Remove always ask for the name. |
| `ui.split_default` | `shell` | shell \| watch \| attach \| dialog | at once | — | What a terminal's Split opens: shell (a new shell session), watch (a read-only view of the left terminal's session), attach (a second, shared view of it), dialog (choose each time). |
| `ui.terminals` | `true` | boolean | at once | — | Terminals in the browser. false: the UI opens none and refuses a terminal ticket (Terminal.app still works). |
| `ui.terminal_title` | `{sandbox} · {session} · {time}` | a title with {sandbox} {session} {image} {time} {phase} ("" = leave the title alone) | at once | — | The title doz attach gives your terminal (window or tab) while attached, and a doz ui terminal's tab: {sandbox} {session} {image} {time} (this Mac's, HH:MM, refreshed each minute) {phase}. The terminal's own title comes back when you detach (where the terminal keeps a title stack: iTerm2, Ghostty, kitty, xterm). While doz sets it, a session's own title is not shown; "" leaves the title to the session. |
| `ui.terminal_font_size` | `13` | integer 9–32 | at once | — | The browser terminal's font size, in points (a terminal opened from now on). |
| `ui.theme` | `auto` | auto \| light \| dark | at once | — | The UI's colours: auto follows macOS. |
| `ui.details_open` | `true` | boolean | at once | — | A sandbox's page shows its details panel (sessions, restore points, network, keys) beside the terminals; false: collapsed. |
| `ui.allow_secret_entry` | `true` | boolean | at once | — | The web UI takes an Anthropic API key or a Claude setup token in a masked field — an account (the setup wizard, Accounts & keys: stored exactly as doz account add stores it, the login keychain) or a sandbox's own key (its page: exactly as doz key set does, held by the host) — sent once, in a request body. false: the pages show the command instead. The UI can turn this off, never on. |
| `ui.open_browser` | `auto` | auto \| always \| never | next command | — | When doz ui opens a browser tab: auto (only when no page of this store's UI is open — an open page reconnects by itself instead), always (every start), never (it prints the address; doz ui link opens a page). --open and --no-open override it. |
| `ui.port` | `0` | integer 0–65535 | ui-restart | `$DOZ_UI_PORT`, `--port N` | The port doz ui listens on, always on 127.0.0.1 (this Mac only): 0 = automatic (the port this store's last doz ui had, when it is free — else one the system picks, and doz ui says so), or a fixed port 1024–65535 (doz ui refuses to start, naming the program, when another holds it). An installed dashboard app belongs to one port: keep it fixed for one. |
| `ui.grid_live_tiles` | `8` | integer 1–12 | at once | — | All sessions: at most this many tiles show their session live at once (each is a terminal engine and a socket); the rest say so. |
| `ui.grid_tile_size` | `medium` | small \| medium \| large | at once | — | All sessions: the size of a tile. |
| `ui.progress` | `animated` | animated \| plain | at once | `$DOZ_PROGRESS`, `--progress auto\|plain` | How a start, wake or bake shows its progress — in the web UI's boot view and in the CLI on a terminal: animated (a spinner on the step under way, download bars, the output's last lines) or plain (one line per step, and a summary line per download). Not a terminal, --json or NO_COLOR: always plain. |

### `[serve]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `serve.port` | `7443` | integer 1024–65535 | serve-restart | `$DOZ_SERVE_PORT`, `doz serve --port N` | The port doz serve listens on — the dashboard for the other browsers of your network. It stays the same (an installed app and a bookmark belong to it): when another program holds it, doz serve refuses and names it. |
| `serve.bind` | `lan` | lan \| loopback \| the Mac's addresses, comma-separated | serve-restart | `$DOZ_SERVE_BIND`, `doz serve --bind lan\|loopback\|ADDRESSES` | Where doz serve listens: lan (every network interface of this Mac and Tailscale — never a sandbox's network), loopback (127.0.0.1 and ::1 only: for a reverse proxy on this Mac), or this Mac's own addresses separated by commas (for a reverse proxy elsewhere on your network). |
| `serve.public_origins` | `""` | origins like https://doz.home.example, comma-separated ("" = none) | serve-restart | — | The addresses your reverse proxy serves the dashboard at, like https://doz.home.example (comma-separated). A browser may use one only through a proxy listed in serve.trusted_proxies. Over https, keys and tokens may be typed in the dashboard; over plain http they never are. |
| `serve.trusted_proxies` | `""` | addresses or networks like 127.0.0.1, 192.168.1.0/24, comma-separated ("" = none) | serve-restart | — | The reverse proxies whose X-Forwarded-Proto, X-Forwarded-Host and X-Forwarded-For doz serve believes — their addresses or networks, comma-separated (a proxy on this Mac: 127.0.0.1, ::1). From anyone else those headers are ignored. |
| `serve.advertise` | `true` | boolean | serve-restart | — | Announce doz serve on your network with Bonjour ("Dozer on <this Mac>", http://<this Mac>.local:<port>), so other Macs and phones can find it. |

### `[host]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `host.idle_timeout_minutes` | `5` | integer 0–10080 | after `doz host stop` | `$DOZ_HOST_IDLE`, `doz host start --idle-timeout` | Minutes with nothing running before the host exits; 0 = never. |
| `host.screen_capture_minutes` | `5` | integer 0–1440 | after `doz host stop` | `$DOZ_SCREEN_CAPTURE` | Every this many minutes, save the screen of each running sandbox's sessions that printed something since (what a sleep or hibernation falls back on); 0 = only when it pauses, sleeps or hibernates. |
| `host.boot_logs_kept` | `5` | integer 1–50 | next boot | `$DOZ_BOOT_LOGS` | How many boots of each sandbox to keep (its steps and kernel console — the web UI's Boot log, doz console --boot N); the oldest goes. |
| `host.keepalive` | `false` | boolean | a store that hasn't chosen | — | Near a Mac login's expiry, while a sandbox uses it and no Claude Code runs, the host runs the Mac's claude once to renew it. |

### `[store]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `store.path` | `~/Library/Application Support/dozer-sandbox` | path ("" = automatic) | next command | `$DOZ_STORE`, `--store` | The store: images, kernels, sandboxes and the host's files. |

### `[claude]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `claude.permissions` | `skip` | skip \| ask | next session | `-e DOZ_CLAUDE_PERMISSIONS=… on run/exec` | Claude Code in a claude-code sandbox: skip its permission prompts (the sandbox is the boundary), or ask as on a Mac. |

### `[codex]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `codex.permissions` | `skip` | skip \| ask | next session | `-e DOZ_CODEX_PERMISSIONS=… on run/exec` | Codex in a codex sandbox: skip its approvals and its own Linux sandbox (the VM is the boundary), or ask as on a Mac. |
| `codex.keep_alive` | `false` | boolean | at once | — | Codex sandboxes on the account mac (this Mac's own Codex login): when its access token is about to expire and a sandbox used it in the last 15 minutes, run this Mac's codex doctor once — no model call — which renews the login the way Codex itself does. Off: the login renews only while Codex (the app or a codex session) runs on this Mac; when it has expired, Codex in a sandbox says so. |

### `[defaults]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `defaults.cpus` | `2` | integer 1–64 | new sandboxes | `doz create --cpus` | CPUs of a new sandbox. |
| `defaults.nat_subnet` | `""` | IPv4 subnet, a.b.c.d/nn ("" = a free one) | new sandboxes | `$DOZ_SUBNET`, `doz create --subnet` | The vmnet subnet of a new --network nat sandbox. |
| `defaults.image` | `lab` | lab \| claude-code \| pi \| codex | new sandboxes | `doz create --image` | The image of a new sandbox when none is named (doz up NAME, doz init, the UI's New sandbox). doz onboard writes the one you chose. |
| `defaults.projects_dir` | `~/dozer-sandbox-workspaces` | path ("" = automatic) | new sandboxes | — | The base folder of new sandboxes' workspaces: the web UI's New sandbox and Quick add, and doz new, share <projects_dir>/<sandbox name> (created when missing, like any workspace). doz create is isolated unless --workspace; doz init uses the folder it runs in. In the web UI, Settings › Choose… sets it with the Mac's folder picker. |
| `defaults.account` | `mac` | mac \| none | a store that hasn't chosen | — | The Anthropic account of a store that has not chosen one: mac (this Mac's Claude Code login) or none. doz account default decides for a store once it has. |
| `defaults.permissions` | `standard` | standard \| locked \| open, or permissions like +web,-error-reports (doz net permissions) | new sandboxes | `doz create --allow / --network` | What a new sandbox's agent may do (its network, as permissions — doz net permissions): standard (talk to its AI model, update itself, install system packages and its base's language packages, use GitHub, send error reports), locked (its AI model only), open (everything, the web included), or standard with changes like +web,-error-reports. Stored by name: a Dozer update that adds a host to a permission reaches every sandbox that has it. |
| `defaults.github` | `off` | off \| read \| push | new sandboxes | `doz create --github off\|read\|push` | "Use GitHub as you" for new sandboxes: off, read (git and gh signed in as you on GitHub, read-only) or push (also push and make changes) — the Access step's choice (doz access set --github). A sandbox can differ: doz create --github, github: in doz_project.yaml, or its permissions later (doz net allow\|deny NAME github:as-you). Proxied sandboxes only. |

### `[agent]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `agent.prompt` | `true` | boolean | next session | — | Tell the agent where it runs: a short facts block appended to its system prompt (the sandbox, its /workspace share, the network, credentials) and the dozer skill, written at every session start. Your own template: agent-prompt.md beside this file. |

### `[updates]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `updates.mode` | `notify` | off \| notify \| auto | next command | `$DOZ_UPDATES` | Updates: notify (at most once a day, and when doz ui opens, look for a newer doz and say how to upgrade — one line on a terminal, a banner on the dashboard), auto (also install it: brew upgrade, or the signed download for a tarball install — only while no sandbox runs and no session is attached, else it notifies; then: restart to apply, doz host restart), or off (never look). Never a downgrade; a feed that does not verify is ignored. |
| `updates.channel` | `stable` | stable \| beta \| canary | next command | — | Which releases you are offered: stable, beta (beta and stable) or canary (every build, first). A Homebrew install's own formula (doz, doz-beta, doz-canary) decides while this is not set; doz upgrade --channel switches both. |

### `[resources]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `resources.clean_unused_days` | `30` | integer 1–3650 | at once | — | Clean up (the Resources page, doz resources clean) removes a prepared image no sandbox was created from in this many days; it is prepared again when next needed. |

### `[sandbox]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `sandbox.agent_sudo` | `true` | boolean | next session | `doz create --no-agent-sudo / --agent-sudo` | The agent (the image's user in claude-code and pi sandboxes) has passwordless sudo inside its sandbox, so it can install system packages (sudo apt-get install …). The VM, the network policy and the absent credentials are the boundary — root inside reaches no more than the agent does. Applied at every boot and every agent session start (no image is rebuilt); a sandbox's own choice (doz create --no-agent-sudo, agent_sudo in doz_project.yaml) wins over this. |
| `sandbox.timezone` | `mac` | mac, or a time zone like Australia/Sydney | next start or wake | — | The sandboxes' time zone: mac (this Mac's, read again at every boot and wake — a laptop that travels while a sandbox sleeps is followed) or a zone like Australia/Sydney. Written to the guest's /etc/localtime; the agent's facts say it. |
| `sandbox.clipboard` | `write` | write \| off | at once | `doz create --clipboard write\|off` | The clipboard bridge: a program in a sandbox that copies (OSC 52 — Claude Code, vim, tmux) puts the text on this Mac's clipboard, and every copy shows a notice (SANDBOX copied N chars) in doz attach and doz ui. At most 1 MiB a copy and 10 copies in 10 s. A sandbox can never READ the Mac clipboard. The risk: an agent could put a command there for you to paste — off turns the bridge off (copies are dropped, and said). A sandbox's own choice (doz config set --sandbox NAME, clipboard in doz_project.yaml) wins over this. |
| `sandbox.browser_bridge` | `on` | on \| off | at once | `doz create --browser-bridge on\|off` | The browser bridge: xdg-open (and $BROWSER, open, sensible-browser) in a sandbox opens an http or https URL in this Mac's default browser, with a notice every time (at most 3 in 10 s). A sign-in whose redirect is the sandbox's localhost (Claude Code's /login) gets that port forwarded from the Mac into the sandbox for up to 10 minutes, so the login completes. Never file: or other schemes, never the Mac's own localhost. off: nothing opens (said). A sandbox's own choice (doz config set --sandbox NAME, browser_bridge in doz_project.yaml) wins over this. |
| `sandbox.open_files` | `on` | on \| off | at once | `doz create --open-files on\|off` | Open workspace files on this Mac: xdg-open PATH (and open PATH, doz-open PATH) in a sandbox opens a document from its /workspace in the Mac's default app — an html page in your browser, markdown in your editor — or a folder (the workspace itself, open .) in the Finder, and doz-open --reveal PATH shows a file selected in its folder; a notice every time (at most 3 in 10 s). Only the shared folder's own files (a link or .. that leads out is refused), only documents (html, md, pdf, images, txt, csv, json, yaml, xml…) — never an app or package folder, a script, an installer or an executable. An isolated sandbox has no file to open. An app other than the default only when it is in bridges.open_apps. off: nothing opens (said). A sandbox's own choice (doz config set --sandbox NAME, open_files in doz_project.yaml) wins over this. |
| `sandbox.ssh_agent` | `off` | off \| on | at once | `doz create --ssh-agent on\|off` | Forward this Mac's SSH agent into the sandbox (proxied sandboxes): ssh and git over SSH there can ask your agent to sign — your keys never enter the sandbox — and only github.com:22 is reachable over SSH. A notice on first use. While it is on, the agent can authenticate as you to github.com. A sandbox's own choice (doz create --ssh-agent on, ssh_agent in doz_project.yaml, doz config set --sandbox NAME) wins over this. |

### `[sessions]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `sessions.tmux` | `false` | boolean | next session | `doz create --tmux / --no-tmux` | Run each new session inside tmux (within Dozer's own session holder, so saved screens, sleep and wake, browser terminals and Ctrl-] detach keep working): tmux's windows, panes and copy mode, its status bar and prefix key (Ctrl-b). tmux takes the mouse, and the kitty keyboard protocol and modifyOtherKeys do not fully pass through it; the session's exit code is tmux's. Needs tmux in the image (the built-in images this doz prepares have it; on an image an older doz prepared the session runs without it, and says so). A sandbox's own choice (doz create --tmux, tmux: true in doz_project.yaml, doz config set --sandbox) wins over this. |

### `[bridges]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `bridges.open_apps` | `""` | app names, comma-separated, like "Typora, Visual Studio Code" ("" = none) | at once | — | The Mac apps a sandbox may name to open a workspace file in (doz-open --app NAME FILE, or open -a NAME FILE in the sandbox), comma-separated — e.g. "Typora, Visual Studio Code". Empty: a file opens only in its default app, and naming an app is refused. Never a path, only an app's name. For every sandbox. |

### `[workspace]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `workspace.ignore_mode` | `lock` | lock \| hide | next start or wake | `doz create --ignore-mode lock\|hide` | What a .dozignore at the root of a sandbox's workspace folder does to the paths it lists (Docker's .dockerignore syntax): lock (they stay listed, shown with no permissions, and every read, write, rename or delete of them is refused — so a program that bumps into one by name sees why) or hide (they are not there at all). A .dozreadonly beside it (same syntax) makes paths visible but read-only; doz_project.yaml, .git/hooks and the two rule files are read-only too. Without either file the folder is shared as it is. A convenience mask, not a security boundary: root in the sandbox can get around it. A sandbox's own choice (doz create --ignore-mode, ignore_mode in doz_project.yaml, doz config set --sandbox NAME) wins over this. |
| `workspace.view` | `on` | on \| off | next-start | `doz create --workspace-view on\|off` | How a sandbox's workspace folder reaches it. on: through Dozer's live view of the folder, so a program working in /workspace (an agent, a shell) keeps its folder when the sandbox wakes from hibernation or after a host restart. The view costs a little: the first scan of a big folder after a start or a wake is slower (e.g. git status on a large repository, or find), later ones are about as fast as without it. off: the folder is shared directly (a little faster) — but a program working inside /workspace loses its folder at such a wake and must be restarted (Codex says "invalid cwd"). A folder with a .dozignore or .dozreadonly always uses the view. Changes take effect at the sandbox's next start. A sandbox's own choice (doz create --workspace-view, workspace_view in doz_project.yaml, doz config set --sandbox NAME) wins over this. |

### `[github]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `github.credentials` | `gh` | gh \| key \| off | at once | — | Where "Use GitHub as you" (a permission, off by default) gets your GitHub login: gh (this Mac's gh login, read when used — gh auth token — and kept in memory a few minutes, never written anywhere; gh auth logout revokes it), key (only a token you give a sandbox with doz key set NAME --github — a fine-grained token limited to some repositories is best), or off (never, even with the permission on). The sandbox only ever sees a placeholder; Dozer's proxy puts the real token in on the way to GitHub. |

### `[images]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `images.claude_code_version` | `latest` | latest, or an exact version like 2.1.227 | new sandboxes | — | The Claude Code the claude-code image is prepared with: latest (asked of the npm registry when the image is prepared, then installed at that exact version, integrity-checked; a newer one is only said — doz image bake claude-code rebuilds when you choose) or an exact version like 2.1.227. A sandbox keeps the version it was created with; doz reset NAME moves it to the image's current one. |
| `images.pi_version` | `latest` | latest, or an exact version like 2.1.227 | new sandboxes | — | The pi coding agent the pi image is prepared with: latest or an exact version, as images.claude_code_version. |
| `images.codex_version` | `latest` | latest, or an exact version like 2.1.227 | new sandboxes | — | The OpenAI Codex CLI the codex image (and every base's Codex image) is prepared with: latest or an exact version like 0.160.1, as images.claude_code_version. |

### `[images.lab]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `images.lab.memory_mib` | `1024` | integer 256–262144 | new sandboxes | `doz create --memory` | Memory (MiB) of a new lab sandbox (a custom image follows the image it was saved from). |
| `images.lab.network` | `bake` | agent \| bake \| locked \| open \| nat \| none | new sandboxes | `doz create --network` | The network of a new lab sandbox: agent, bake, locked, open (proxied presets), nat or none. |

### `[images.claude-code]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `images.claude-code.memory_mib` | `2048` | integer 256–262144 | new sandboxes | `doz create --memory` | Memory (MiB) of a new claude-code sandbox (a custom image follows the image it was saved from). |
| `images.claude-code.network` | `agent` | agent \| bake \| locked \| open \| nat \| none | new sandboxes | `doz create --network` | The network of a new claude-code sandbox: agent, bake, locked, open (proxied presets), nat or none. |

### `[images.pi]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `images.pi.memory_mib` | `2048` | integer 256–262144 | new sandboxes | `doz create --memory` | Memory (MiB) of a new pi sandbox (a custom image follows the image it was saved from). |
| `images.pi.network` | `agent` | agent \| bake \| locked \| open \| nat \| none | new sandboxes | `doz create --network` | The network of a new pi sandbox: agent, bake, locked, open (proxied presets), nat or none. |

### `[images.codex]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `images.codex.memory_mib` | `2048` | integer 256–262144 | new sandboxes | `doz create --memory` | Memory (MiB) of a new codex sandbox (a custom image follows the image it was saved from). |
| `images.codex.network` | `agent` | agent \| bake \| locked \| open \| nat \| none | new sandboxes | `doz create --network` | The network of a new codex sandbox: agent, bake, locked, open (proxied presets), nat or none. |

### `[kernel]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `kernel.path` | `""` | path ("" = automatic) | new sandboxes | `$DOZ_KERNEL` | An explicit Linux kernel for new sandboxes ("": the pinned kernel, fetched into the cache). |
| `kernel.cache` | `""` | path ("" = automatic) | new sandboxes | `$DOZ_KERNEL_CACHE` | Where the pinned kernel is cached ("": the store's own); share one between stores. |

<!-- settings:end -->

## Environment variables

| variable | overrides | |
|---|---|---|
| `DOZ_STORE` | `store.path` | the store folder |
| `DOZ_PROGRESS` | `ui.progress` | `animated` or `plain` progress |
| `DOZ_HOST_IDLE` | `host.idle_timeout_minutes` | host idle timeout, minutes (fractions allowed) |
| `DOZ_SCREEN_CAPTURE` | `host.screen_capture_minutes` | how often screens are saved |
| `DOZ_BOOT_LOGS` | `host.boot_logs_kept` | boots kept per sandbox |
| `DOZ_SUBNET` | `defaults.nat_subnet` | subnet of a new `nat` sandbox |
| `DOZ_KERNEL` · `DOZ_KERNEL_CACHE` | `kernel.path` · `kernel.cache` | an explicit kernel · a shared kernel cache |
| `XDG_CONFIG_HOME` | — | where `dozer-sandbox/doz.toml` is (default `~/.config`) |
| `NO_COLOR` | — | plain progress, no colours |
