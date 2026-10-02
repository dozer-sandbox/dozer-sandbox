# Prompts for your agent

Your Mac's own coding agent — Claude Code, Codex, Cursor — can install Dozer, set it up and run
sandboxes for you. This page gives you prompts to paste, in order: install, set up, brief it once, then
three things worth using sandboxes for. [Letting another agent drive Dozer](14-letting-another-agent-drive.md)
explains the rules underneath (`--json`, exit codes, why destructive commands need `--yes`).

**Keep the decisions yours.** Every prompt below tells the agent to stop and ask before it chooses an
account, widens network permissions, or deletes anything. Your Mac's agent runs `doz` with *your*
permissions — treat it as you would at the keyboard.

## 1. Install

Paste:

> Install Dozer Sandbox (the `doz` command) on this Mac with Homebrew, following
> https://github.com/johnoscott/dozer-sandbox-prelaunch/blob/main/docs/manual/02-install-upgrade-uninstall.md.
> It is in private preview: the tap is a private GitHub repository, so use my `gh` login for the download
> (`HOMEBREW_GITHUB_API_TOKEN="$(gh auth token)"` for the brew command only — never print the token or write
> it to a file). If `gh` is not logged in, stop and tell me. When it is installed, run `doz --version` and
> `doz doctor --json` and tell me what they say.

What it will run:

```sh
brew tap johnoscott/dozer git@github.com:johnoscott/homebrew-dozer-prelaunch.git
brew trust johnoscott/dozer
HOMEBREW_GITHUB_API_TOKEN="$(gh auth token)" brew install doz
doz --version
doz doctor --json
```

## 2. Set up

Onboarding checks the Mac, chooses how sandboxes sign in to Claude, writes the settings and prepares images.
The account is your choice, so the prompt makes the agent ask:

> Set up Dozer with `doz onboard`. Before you run it, ask me which Claude account the sandboxes should use
> (this Mac's login, an API key, a setup token, or later) and which images to prepare (claude-code is the
> default; lab is small and quick; pi is the other agent). Then run it without questions, using my answers,
> and show me `doz onboard --status` when the images are ready. Do not change any other setting.

What it will run (for example):

```sh
doz onboard --yes --account mac --images claude-code,lab
doz onboard --status
```

Preparing claude-code the first time takes several minutes (a download and a bake); it happens once.

## 3. Brief it once

Paste the briefing from [Letting another agent drive Dozer](14-letting-another-agent-drive.md#the-briefing)
into your project's `CLAUDE.md` (or `AGENTS.md`). From then on, every session in that project knows how to
use `doz` safely, and the prompts below can stay short.

## Three use cases

### A. A risky change, done by an agent in a sandbox

A dependency upgrade, a big refactor, a migration: let a sandboxed agent do the work on your project folder
while your Mac's agent watches, with a restore point to fall back to.

> In a Dozer sandbox called `upgrade`, upgrade this project to the latest major version of our test
> framework and get the test suite passing. Take a restore point before you start. Let a Claude inside the
> sandbox do the work (run it detached) and check on it every few minutes. When the tests pass, show me
> the diff on my Mac and a summary of what changed. If the sandboxed agent is refused a website, tell me
> which and why — don't allow it yourself. Hibernate the sandbox at the end.

What it will typically run:

```sh
doz create upgrade --image claude-code --workspace "$PWD" --json
doz point take upgrade before-upgrade
doz run upgrade --detach -- claude -p "Upgrade the test framework to its latest major version and make the tests pass"
doz sessions upgrade --screen claude
doz exec upgrade --json --timeout 1200 -- sh -c 'cd /workspace && npm test'
doz hibernate upgrade
```

The changes land in your folder as they are made (`/workspace` is your project), so you review them with
`git diff` — and `git checkout .` undoes them if you don't like them.

### B. Try out code you don't trust

A repository someone sent you, an install script, a package you're not sure about: run it where it can't
reach your files.

> I want to try https://github.com/OWNER/REPO but I don't trust it. Make an **isolated** Dozer sandbox
> (no folder of mine shared) called `trial` with the lab image, clone it inside, read its install
> instructions and run them, then run its tests or its demo. Tell me what it did: what it installed, what
> it tried to reach on the network (`doz net trial --json` shows refusals), and anything that looked
> suspicious. Don't widen network permissions. When I say so, delete the sandbox with `doz rm trial --yes`.

What it will typically run:

```sh
doz create trial --image lab --isolated --json
doz exec trial --json --timeout 300 -- sh -c 'cd ~ && git clone https://github.com/OWNER/REPO && cd REPO && cat README*'
doz exec trial --json --timeout 900 -- sh -c 'cd ~/REPO && ./install.sh'
doz net trial --json
```

Nothing it does reaches your Mac's files; the network goes through Dozer's proxy, so every site it tried
is on record.

### C. Let an agent work on a project that holds secrets

Your project folder has an `.env`, credentials or customer data the sandboxed agent should never read.
[Workspace rules](20-workspace-rules.md) keep it out of them, without moving anything.

> Before we use a sandbox on this project, add a `.dozignore` at the project root that keeps the agent out
> of `.env*`, `secrets/` and `*.pem`, and a `.dozreadonly` that lets it read but not change `deploy/`.
> Show me what each path resolves to with `doz ignore check` before creating anything. Then create a
> sandbox called `feature` on this folder, confirm in the sandbox that `.env` is listed with no
> permissions and can't be read, and start a Claude in it on this task: <your task>.

What it will typically run:

```sh
printf '.env*\nsecrets/\n*.pem\n' > .dozignore
printf 'deploy/\n' > .dozreadonly
doz create feature --image claude-code --workspace "$PWD" --json
doz ignore check feature .env secrets/api.key deploy/prod.yaml src/app.ts
doz exec feature --json -- sh -c 'ls -la /workspace; cat /workspace/.env'
doz run feature --detach -- claude -p "<your task>"
```

Locked files stay visible as `----------` so the agent knows they exist and leaves them alone (the
sandboxed agent is told so). The rules are a guard against accidents, not a security boundary — see
[The workspace view](21-the-workspace-view.md).

## When something goes wrong

| what happened | what to tell your agent |
|---|---|
| a `doz` command seems to hang | "Use `doz exec`, `doz run --detach` and `doz sessions --screen`, never an interactive `doz attach` or `doz up`." |
| exit code 6 (host unavailable) | "Run `doz doctor --json` and tell me what it says." |
| a site is refused | "Show me `doz net NAME --json` and the suggestion; I'll decide." |
| the sandbox is in a state you didn't expect | "Show me `doz ls --json` and `doz inspect NAME --json`." |

See also: [Letting another agent drive Dozer](14-letting-another-agent-drive.md) ·
[Getting started](01-getting-started.md) · [Troubleshooting and FAQ](17-troubleshooting-and-faq.md).
