# Trying agents, and what Dozer supports

`doz try` takes you from nothing to talking to an agent in one command. `doz search` tells you whether Dozer runs
something, and how. Both use the same choices as `doz new`, `doz create` and `doz up`, and `--dry-run` shows what any
of them would make before anything is made.

## Try an agent: `doz try`

```sh
doz try grok                       # Grok Build, from nothing: prepared, made, started and attached
doz try gemini --base python       # any choice option works (here: Gemini CLI on the Python base)
doz try                            # a numbered list of the agents — coding agents, then AI tools — with your keys and whether each is ready
doz try --tag terminal-tool        # only those of a kind (coding-agent, ai-tool) or a category
doz try grok --dry-run             # make nothing: print the plan
doz try grok --rm                  # delete it when you leave, without asking
doz try grok --keep                # keep it running when you leave, without asking
doz try grok -d                    # make and start it, but don't attach (it is kept)
```

A try is a throwaway sandbox with safe defaults:

- **A new empty folder of its own** — Dozer makes `try-<agent>` in your projects folder (`defaults.projects_dir`,
  `~/dozer-sandbox-workspaces` unless you set another) and shares it at `/workspace`, so what the agent makes is on
  your Mac. It is never one of your folders: a folder of that name that holds anything is skipped (the try is named
  `try-<agent>-2`). `--isolated` shares no folder at all (`doz get try-grok /workspace/FILE` copies a file out —
  see [Terminals and sessions](07-terminals-and-sessions.md)); `--workspace DIR` uses a folder you choose.
- **Your Mac's clipboard and its apps**, as in any sandbox: what the agent copies reaches your Mac's clipboard (also
  from agents that copy with `xclip`, `xsel` or `wl-copy`), and it can open a file it made, or a link, on your Mac.
  The try's first line says so:

  ```
  try-grok · Debian · Grok Build · a new empty folder ~/dozer-sandbox-workspaces/try-grok (not one of yours), at
  /workspace · copy to your Mac's clipboard: on · open files on your Mac: on · open links in your Mac's browser: on
  ```
- **Locked, plus the agent's own model** — it can talk to its AI model and nothing else. `--permissions standard`
  opens package installs; every other choice option works too.
- **The agent's own base** (Grok Build: Debian; Gemini CLI: Node), and its approval prompts off.
- **Your key for its provider** — the provider's default account.
- **Named `try-<agent>`**, then `try-<agent>-2`, …, and shown as a try in `doz ls`.

**When you have no key yet**, a terminal shows **What you need**, the same card for every agent, made from the agent's
recipe:

1. **Paste a key** (hidden) — kept in your Mac's login keychain; the sandbox only ever gets a placeholder.
2. **A key you keep in 1Password, AWS Secrets Manager or a program** — `op://…`, `aws:arn:…`, or a command; read on
   your Mac when needed, never stored (see [Agents and accounts](09-agents-and-accounts.md)).
3. **Signing in inside the agent** — offered only where that sign-in can work in a sandbox, and labelled: the sign-in
   lives in that sandbox, and deleting the try deletes it. (Grok Build's own sign-in uses hosts Dozer keeps out, so
   it is shown, not offered.)

It also says where to get a key. While you deal with the key, the image is already being prepared.

**When you leave** (the agent exits, or you detach with Ctrl-] twice), it asks:

```
Keep this try? [S]leep / [d]elete / [k]eep running [S]:
```

**Sleep** (Enter) hibernates it: everything is kept on disk and it holds no memory; `doz wake try-grok` (or
`doz attach try-grok`) brings it back where it was.
**Delete** removes it and everything in it. Its folder goes too when it is empty; when the agent left files there,
it asks (the default keeps the folder and says where it is), and off a terminal it keeps it and says so. `--rm` and
`doz rm` of a try do the same; the dashboard's Delete removes an empty one. **Keep running** leaves it as it is.

**Off a terminal** (a script, `--json`, `-d`) `doz try` asks nothing and does not attach: it makes and starts the try,
keeps it, and prints how to attach. With no key it stops and says how to add one.

## In the dashboard: Quick try

**Quick try** (beside New sandbox on the Sandboxes page, or `#/try` and `#/try/grok` in the address bar) is the same
try in the browser, with the same defaults and the same plan. It covers the whole window; **Close** (or Esc) returns
to where you opened it.

- **Two sections** at the top of the left pane: **Coding agents** and **AI tools**, each with how many it holds. A
  search that matches something in the other section says so ("2 in AI tools"), one click away.
- **Search and filters** below: type a name, a maker, an alias, `tag:headless` or `tag:terminal-tool` — the same
  matching as `doz search`, and forgiving (`agy` finds Antigravity CLI). The pills narrow the section — **Ready** (its
  key is here), then the section's categories (a terminal tool, a personal agent, a framework, evaluation, MCP …): any
  of the categories you press. The count says how many match; when none do, it says so, suggests a near name, and
  clears in one click. Superseded agents, then the ones that are coming, come last.
- **Cards or a list**: the toggle beside the count; the dashboard remembers your choice in this browser.
- **Each agent's mark** is a plain black-and-white sign — a neutral lettermark, not the maker's logo (their brand terms
  do not allow it here).
- **The chosen agent** on the right: its version and how long ago it was released, whether it is current (a
  superseded one says what replaced it, with a link to try that instead), **What you need** — its key, or, when there
  is none: paste one in a masked field (kept in your Mac's keychain; turned off with `ui.allow_secret_entry = false`),
  or the command to run for a key you keep in 1Password, AWS or a program. Then **the plan** (its name, base, network,
  its new empty folder — not one of yours — and what reaches your Mac), the same as a command to copy (`doz try grok`),
  and what it can reach.
- **Where it gets its model** — **Try…** opens its setup. A tool that can use more than one provider (pi, OpenCode, and
  most of the recipe tools) shows ONE list: its providers, then the gateways (OpenRouter, Vercel AI Gateway — one key,
  models from many makers), each with its key status. Its own provider is chosen; choose any other the same way. The
  chosen one shows its key (a choice when you have several, or "Add another key"), or a field to paste one, where to get
  a key and the command for a key kept in 1Password, AWS or a program. Then **Model**: the source's own list —
  a gateway's public list, read by Dozer on this Mac once a day — to search by name, maker or id, with each model's
  context and price per million tokens and the default marked; an id it does not list can still be typed. The plan
  names the model, and **Same in Terminal** is the command (`doz try pi --gateway openrouter --model …`). New Sandbox
  asks the same in its Account step, and writes the choice to `doz_project.yaml` (`model_source:`, `model:`).
  OpenCode 2 also lists **OpenCode Zen** (free models), marked "no key needed": chosen, it needs no key and no account,
  Start is ready at once, and its model list shows each free model with its data terms as OpenCode's docs state them
  (`doz try opencode --provider opencode-zen`).
- **Nothing is prepared while you browse.** **Start** makes it, starts it and opens its session: a first start
  prepares its image, and its terminal area shows the progress (the steps, the one under way and the last lines of the
  build) until the session is there. A try's page says **Sleep (hibernate)** · **Delete…** · **Keep** — Delete removes
  its folder too when it is empty.
- **Keyboard:** `/` searches, ↑ and ↓ move through the results, Enter starts. On a phone the list comes first and an
  agent opens its details, with a back control.

`doz try --ui grok` opens it from a terminal: it starts `doz ui` in the background when none runs; with a dashboard
page already open, that page goes to the Quick try (no new tab, as `ui.open_browser` says); otherwise a new one opens
there.

## The guide

Every agent and tool comes with a **guide**: what it is, the facts of your sandbox, the first steps and some tips.

- **In the dashboard**, the sandbox page's details have a **Guide** tab — first, and open, on a try; last elsewhere. It
  says what kind of thing it is and how to use it here; **This try**: its version (Dozer's pin), the provider and model
  with the account it uses (your key stays on the Mac), what the network lets it reach (with a link to Network), the
  folder and where its settings live; **Start here**: the first steps, each command with **Copy** and **Run** — Run
  types it into the sandbox's session and presses Enter (for an agent with its own screen, into a shell beside it: open
  one with New shell), **Type** types a command you change first; **Good to know**: tips, its docs, and when Dozer last
  checked the recipe. The first step is always the one Dozer checks the recipe with, so it is known to work.
- **In a terminal**, `doz guide NAME` prints the same (`--json` as data). `doz try` prints "Start here" before it
  attaches to a tool whose session is a shell, and the first login shell in such a sandbox shows the steps once.
- **Fabric** comes with its patterns (some 260, from its own release, checksum-verified when the image is prepared):
  `fabric -l` lists them, `fabric -p summarize` uses one — nothing to download first.

## Is it supported? `doz search`

```sh
doz search grok                          # Grok Build — supported · key: xAI (you have work-xai) · try it: doz try grok
doz search grokk                         # nothing called 'grokk' — did you mean grok?
doz search cursor-cli                    # Cursor CLI — coming: …
doz search                               # everything: supported, then coming
doz search tag:multi-vendor-models       # agents with a capability
doz search --tag api-key --level any     # every agent, with that tag at any level
doz search grok --base alpine            # is it supported on that base?
doz search grok --details                # what it installs, the hosts it may reach, its keys, what is kept out, tags
doz search grok --json                   # the directory entry, and your key and image state beside it
```

It matches agents (by id, alias, title or publisher), key providers (`xai`, `google`, …) and bases (`alpine`, …).

**Is it current?** Under each agent, a second line says its latest release as your Mac last saw it — `latest 1.3.3 ·
released 10 Oct 2026 (2 days ago) · active` — and, when its maker has moved on, its standing:

```
Gemini CLI — supported · key: Google AI (Gemini API) (you have google) · try it: doz try gemini
    latest 0.63.0 · released 6 Oct 2026 (6 days ago) · active
    Superseded by Antigravity CLI — Google retired Gemini CLI for personal accounts; it still works with a paid Gemini API key · instead: doz try antigravity
```

- **active**: a release in the last 3 months; **quiet**: none for 3 months; **stale**: none for 6 months;
  **deprecated**: its maker marked that release deprecated (that wins).
- The Dozer host looks up each agent's latest release about once an hour while it runs (the same check that keeps
  images up to date). Looking — `doz search`, `doz try`, the Quick try — never asks the internet; before the first
  check it says *not checked yet*.
- A tool Dozer installs from one pinned release download or a hash-locked set of Python packages (Fabric, AIChat,
  Goose, Crush, Tau, …) is not looked up: its line says the pin — *pinned 1.4.518 — Dozer installs exactly this
  release* — and a newer one comes with a Dozer update.
- **Superseded** agents still work and stay selectable; they are listed after the current ones, and `doz search` of
  one lists what replaces it too. `doz try` of one says so first. Today: **Antigravity CLI** (`doz try antigravity`,
  alias `agy`) is Google's lead agent; **Gemini CLI** is superseded by it.

### Antigravity CLI

Google's terminal agent, installed from Google's own release (checked against its published SHA-512), on Debian-based
bases (not Alpine yet). It uses a **Gemini API key** (`doz account add google --provider google`); Dozer never offers the
Google sign-in. Its approval prompts are off (`antigravity.permissions = ask` keeps them), its updater is off, and its
telemetry setting is off. It reads Google's feature switches at start-up, and sends its usage log to
`play.googleapis.com` every few seconds (its own setting does not stop it); both are allowed.

**What it is**: every agent, and every one that is coming, is a **coding agent** or an **AI tool**, with one or more
categories — `personal-agent`, `terminal-tool`, `framework`, `browser-agent`, `mcp`, `research`, `evaluation`,
`workflow`, `local-models`, `chat-app` (and `coding-agent`). `doz search --tag ai-tool`, `doz search --tag mcp`
(coming ones included), `doz search NAME --details` ("what it is: AI tool · terminal tool").

**Tags** describe capabilities (`multi-vendor-models`, `api-key`, `vendor-sign-in`, `free-tier`, `resume`, `musl`,
`open-source`, `headless`, `gateway:openrouter`, …). Each tag has a level per agent: `documented`, `verified`,
`experimental`, `no` or `unknown`. By default only `documented` and `verified` count; `--level` changes that.

**Exit codes**, for scripts and for agents on your Mac:

| code | meaning |
|---|---|
| 0 | supported (or a plain `doz search`) |
| 8 | supported, but not with what you asked (a base it does not run on) |
| 6 | known, but not in this Dozer: coming, or not possible |
| 2 | nothing by that name (it suggests the closest) |
| 64 | usage |

## A tool's major version

Some tools come in more than one major release line, each a recipe of its own — OpenCode 1 and OpenCode 2. The tool's
name is the one Dozer recommends; you can always choose another:

```sh
doz try opencode                   # the major Dozer recommends (a release it checked)
doz try opencode@1                 # OpenCode 1, kept up to date within 1.x
doz try opencode@2.0.28            # exactly that release (checked against the registry before anything is made)
doz create my-app --agent opencode@1      # the same in new, create and up — and in doz_project.yaml: agent: opencode@1
```

- **Recommended, never "latest"**: the recommended major is one whose recipe passed Dozer's checks; Dozer moves it to a
  new major only once that one has.
- **A sandbox keeps its major.** It records what it was made as (`opencode@2.0.29`). Later recommendations never move
  it, and a reset keeps its major. The other major is a new sandbox.
- **A project file keeps its major too.** What Dozer writes for later — a plan's `doz_project.yaml`, `doz init`, New
  Sandbox — records the major the name resolved to (`agent: opencode@2`), so `doz up` on it next year makes the same
  major. A file you write by hand with the bare name (`agent: opencode`) keeps meaning the recommended major; `doz up`
  says which one when it makes the sandbox.
- **Where you see them**: a try's first line, `--dry-run` and the sandbox's Guide say which release it is and how to get
  the other one (`OpenCode 1 1.19.0 (recommended) — OpenCode 2: doz try opencode@2`). `doz search` marks each major
  (`(recommended; also @2)`), and the `doz try` list shows the tool once. In the dashboard, Quick try has one card per
  tool, with a **Version** choice in its Try setup; New Sandbox shows the tool once, with its majors under it.
- An exact release that does not exist, or a major that does not, is refused with the choices there are
  (`opencode has opencode@1 (recommended) and opencode@2 — not @9`).

## One set of choices

`doz new`, `doz create`, `doz up` and `doz try` take the same choice options, named after the keys of
[`doz_project.yaml`](04-projects.md):

| option | what it chooses |
|---|---|
| `--agent`, `--base`, `--dockerfile` | the agent and its base (`--image` is the shorthand for both); a tool's major or release: `--agent opencode@1` |
| `--permissions` | what the agent may do: `standard`, `locked`, `open`, `+web`, `-error-reports`, `site:HOST` (`--allow` is the same) |
| `--network` | `agent`, `locked`, `open`, `bake`, `nat` or `none` |
| `--account`, `--key` | the account, and custom keys beside it |
| `--github`, `--ssh-agent` | GitHub as you, your SSH agent |
| `--workspace`, `--isolated` | a folder of your Mac at `/workspace`, or none |
| `--cpus`, `--memory` | resources |
| `--clipboard`, `--browser-bridge`, `--open-files`, `--tmux`, `--ignore-mode`, `--workspace-view`, `--agent-sudo` | the per-sandbox settings |

`doz new my-app` names the sandbox (`--name` still works). `doz init` takes `--agent`, `--base` and `--dockerfile`
and writes them as the file's own keys.

## See it first: `--dry-run`

```sh
doz new --agent grok --dry-run
doz create my-app --agent gemini --base python --permissions +web --dry-run
doz up my-app --dry-run
doz try grok --dry-run --json
```

The plan has three parts:

- **the command** that makes it, showing only what differs from your defaults;
- **the same choices as `doz_project.yaml`**, so a sandbox you like can become a project;
- **what it can reach**, in plain words, from the same rules the proxy will apply ("Talk to xAI (api.x.ai, 4 API
  paths)", "No package installs (Locked)", "Kept out whatever you choose: …", "A new empty folder … (not one of
  yours)", "Copy to your Mac's clipboard: on", "Open files on your Mac: on").

It also says whether the image is ready, which account and key it uses (where the key comes from, never the key),
and anything in the way, with the fix. `--json` gives the same plan as data. Looking never starts the host.
