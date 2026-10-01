# Projects

A **project** is a folder with a `doz_project.yaml` file in it. The file describes the folder's
sandbox — which agent, how much memory, what it may reach, which sessions to start — and `doz up` in
that folder creates, starts or wakes exactly that sandbox, with the folder shared at `/workspace`.
Use projects when you work on the same code day after day, or want everyone on a team to get the same
sandbox from a checkout.

## Concepts

- **The folder is the workspace.** A project's sandbox always shares its own folder at `/workspace`,
  live: what the agent writes is on your Mac at once, and the other way round.
- **The file holds choices, never secrets.** You can commit it. Credentials come from your
  [accounts](09-agents-and-accounts.md), which stay on your Mac.
- **Some choices are made when the sandbox is made.** Its image, CPUs and memory — and a `nat` or
  `none` network — are the virtual machine's make-up. Changing them in the file affects a **new**
  sandbox only; `doz up` tells you so. Other keys apply at once or from the next session (below).
- **Your projects folder is not a project.** The setting `defaults.projects_dir`
  (`~/Developer/dozer-sandbox-projects`) is where **Quick add**, **New sandbox** and `doz new` make a
  folder for each new sandbox that has none of its own — `claude-sandbox`, `claude-sandbox-2`, … —
  with no `doz_project.yaml`. Run `doz init` in one of them to make it a project. Change the folder in
  **Settings** › **Choose…** or with `doz config set defaults.projects_dir DIR`
  ([The quickest way](05-sandboxes-and-lifecycle.md#the-quickest-way-quick-add-and-doz-new)).

## Make a folder a project

```sh
cd ~/code/my-app
doz init
```

On a terminal `doz init` asks for the sandbox's name (suggested from the folder's) and its image
(suggested from the setting `defaults.image`); **Enter** takes the suggestion. It sets this Mac up
first if it never was. Then it writes `doz_project.yaml`, listing every key — the ones you didn't set
are commented out, showing their defaults.

```sh
doz init ~/code/other --name other --image python-claude-code --memory 4G --yes
doz init --force            # rewrite an existing doz_project.yaml
```

| option | what it does |
|---|---|
| `DIR` | The folder (default: the current one; made if missing). |
| `--name` · `--image` · `--cpus` · `--memory` · `--network` · `--account` | Answer the questions up front. |
| `--yes` | Ask nothing. `--json` and no terminal ask nothing too. |
| `--force` | Rewrite an existing file. |

## Use it

```sh
cd ~/code/my-app
doz up
```

With no sandbox name, in a project folder, `doz up`:

1. creates the sandbox if it doesn't exist (the folder becomes its `/workspace`);
2. starts it, or wakes it;
3. starts the file's `sessions` — the first one attached to your terminal, the others in the
   background;
4. brings the sandbox's own settings into line with the file (its agent prompt, sudo, clipboard,
   browser bridge, opening files, tmux), and says what it changed.

Options you give `up` win over the file's, for a new sandbox: `doz up --memory 8G`.
`doz up -d` does it all without attaching. When you detach (**Ctrl-]** twice), the line printed
names the shortest way back — in the project folder that is just `doz up`.

### In the dashboard

The dashboard has no project files of its own, but a project's sandbox is an ordinary sandbox there:
it appears under **Sandboxes**, and its page shows its workspace folder. **New sandbox** makes the
same kind of sandbox with a **Shared folder** of your choice (see [The dashboard](06-the-dashboard.md)).

## `doz_project.yaml` reference

```yaml
version: 1
name: webapp                # the sandbox
image: claude-code          # or: agent + base, or agent + dockerfile (below)
cpus: 4
memory: 4G
network: agent              # agent, bake, locked, open, nat, none
account: default            # default, none, or an account name
sessions:                   # what doz up starts; the first is attached
  - claude                  #   the image's own session
  - name: server            #   a session of your own
    command: npm run dev    #   split on spaces, no shell — or a list: [npm, run, dev]
agent_prompt: |             # this project's own lines for the agent
  The tests run with `make test`.
agent_prompt_mode: append   # or replace
agent_sudo: true
clipboard: write            # or off
browser_bridge: on          # or off
open_files: on              # or off
tmux: false                 # or true
```

| key | value | default | when a change applies |
|---|---|---|---|
| `version` | `1` | — | — |
| `name` | the sandbox: 1–40 of `a-z 0-9 -` | the folder's name | — |
| `image` | `claude-code`, `pi`, `lab`, a base × agent image (`python-claude-code`, `go-pi`, `debian`, …) or a template | `defaults.image` | when the sandbox is made |
| `agent` | `claude-code`, `pi` or `none` — instead of `image`, with `base` or `dockerfile` | `claude-code` | when made |
| `base` | a recommended base: `node`, `python`, `go`, `rust`, `java`, `ruby`, `dotnet`, `debian`, `ubuntu`, `alpine` | `node` | when made |
| `dockerfile` | your own Dockerfile, relative to the folder or absolute (see [Images and bases](08-images-and-bases.md#your-own-dockerfile)) | — | when made |
| `cpus` | 1–64 | `defaults.cpus` (2) | when made |
| `memory` | `2G`, `512M` or MiB, 256 MiB – 256 GiB | per image (settings) | when made |
| `network` | `agent`, `bake`, `locked`, `open`, `nat`, `none` | per image | `agent`/`bake`/`locked`/`open`: at the next `doz up`, live (unless you edited the sandbox's permissions since); `nat`/`none`: when made |
| `account` | `default`, `none` or an account name | follow the store's default | run `doz account use NAME ACCOUNT` |
| `sessions` | a list of session names, or `{name, command}` — at most 16 | the image's own session | every `doz up` |
| `agent_prompt` | text, at most 16 KiB | — | the next session |
| `agent_prompt_mode` | `append` or `replace` | `append` | the next session |
| `agent_sudo` | `true` or `false` | `sandbox.agent_sudo` (true) | the next session |
| `clipboard` | `write` or `off` | `sandbox.clipboard` (write) | at once |
| `browser_bridge` | `on` or `off` | `sandbox.browser_bridge` (on) | at once |
| `open_files` | `on` or `off` | `sandbox.open_files` (on) | at once |
| `tmux` | `true` or `false` | `sessions.tmux` (false) | the next session |

The schema is closed: an unknown key, a key given twice, a wrong type or a value out of range is an
error that names the line. One YAML document, no anchors or aliases, at most 64 KiB.

### When you change the file

`doz up` compares the file with the sandbox and says each difference and what it did, for example:

```
[doz] cpus 2 → 4 in doz_project.yaml: applies only when the sandbox is made — doz rm webapp && doz up recreates it (this folder is kept)
[doz] network agent → locked in doz_project.yaml: applied now (live — the next connection is judged by it)
[doz] clipboard off in doz_project.yaml — applies at once (the UI re-reads it)
```

To remake a sandbox with new make-up, `doz rm NAME` then `doz up`. Your folder is never touched; the
agent's history on the sandbox's state disk goes with the sandbox, so take a
[duplicate](12-restore-points-duplicates-templates.md) with `--copy-state` first if you want to keep it.

## Limits

- One sandbox per project file. Several folders can each have their own.
- The sandbox's name must be unique in the store. Two checkouts of the same project on one Mac need
  different `name`s.
- `permissions` are not a project key yet: set them with `network` (a preset) or `doz net allow`
  after the sandbox exists ([What the agent can do](10-permissions-and-network.md)).

## Troubleshooting

| symptom | what to do |
|---|---|
| "unknown key …" | The key isn't in the table above (check its spelling). |
| `doz up` says "which sandbox?" | There's no `doz_project.yaml` in this folder: `cd` into the project, or `doz init`. |
| "NAME was made from …, not this folder's doz_project.yaml — using it anyway" | Two projects use the same `name`, so they share one sandbox. Rename one. |
| A change in the file didn't apply | `doz up` prints when each change applies; image, CPUs and memory need a new sandbox. |
