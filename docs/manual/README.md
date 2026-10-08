# The Dozer Sandbox manual

Dozer Sandbox runs AI coding agents in small Linux virtual machines on your Mac: each agent gets its
own disk, a network that only reaches what you allow, and your project folder if you share it. A
sandbox pauses in a millisecond and wakes from disk in a third of a second, with everything where you
left it.

You drive it with the `doz` command or its dashboard in your browser (`doz ui`). Every page here shows
both.

## Reading order

**New to Dozer?** Read these first, in order:

1. [Getting started](01-getting-started.md) — install, set up, and talk to Claude in a sandbox in 15 minutes.
2. [Sandboxes and their lifecycle](05-sandboxes-and-lifecycle.md) — pause, sleep, hibernate, wake; what's kept where.
3. [Terminals and sessions](07-terminals-and-sessions.md) — attaching, the Ctrl-] menu, the clipboard, tmux.
4. [What the agent can do](10-permissions-and-network.md) — permissions and the network.

**Then, as you need them:**

| page | read it when you want to… |
|---|---|
| [Installing, upgrading and uninstalling](02-install-upgrade-uninstall.md) | install with Homebrew, upgrade safely, remove Dozer |
| [Setting up](03-setting-up.md) | (re)run onboarding in the terminal or the wizard |
| [Projects](04-projects.md) | give a folder its own sandbox with `doz_project.yaml` and `doz up` |
| [The dashboard](06-the-dashboard.md) | use `doz ui`: its pages, banners, sign-in links |
| [The dashboard on your other devices](25-doz-serve.md) | use the dashboard from another computer, a tablet or a phone on your network (`doz serve`) — and behind your own HTTPS reverse proxy |
| [Images and bases](08-images-and-bases.md) | pick a language base, use your own Dockerfile, rebuild an out-of-date image |
| [Agents and accounts](09-agents-and-accounts.md) | use Claude Code or pi, add accounts, change what the agent is told |
| [Codex](24-codex.md) | run OpenAI's Codex on your ChatGPT plan (Dozer's own sign-in) or an OpenAI key — the token never enters the sandbox |
| [Signing in from a sandbox](11-signing-in-from-a-sandbox.md) | let a tool in a sandbox sign in through your Mac's browser |
| [GitHub as you](18-github.md) | let git and gh in a sandbox use your GitHub login — read-only or with push — without the token entering it |
| [The tools layer](19-the-tools-layer.md) | know which tools Dozer puts in a sandbox for its settings (gh, the ssh client, tmux …) and check them |
| [Workspace rules](20-workspace-rules.md) | keep the agent out of some files in your shared folder (`.dozignore`), or let it read but not change them (`.dozreadonly`) |
| [The workspace view](21-the-workspace-view.md) | `dozview`, the small program in the sandbox every workspace goes through: why (programs keep their folder across a wake), what it costs, `workspace.view`, the rules it enforces, its two processes, sleep and wake, how to look inside. |
| [Prompts for your agent](22-prompts-for-your-agent.md) | prompts to paste into Claude Code, Codex or Cursor on your Mac: install, set up, and three uses — a risky change, jailing an untrusted agent, a project with secrets |
| [Restore points, duplicates and templates](12-restore-points-duplicates-templates.md) | undo, copy a sandbox, make your own starting image |
| [Resources and disk space](13-resources-and-disk-space.md) | see where the disk went and free some |
| [Letting another agent drive Dozer](14-letting-another-agent-drive.md) | have the agent on your Mac run sandboxes for you |
| [Settings reference](15-settings-reference.md) | look up any setting, its default and when it applies |
| [Security model](16-security-model.md) | understand what protects your Mac, and what doesn't |
| [Troubleshooting and FAQ](17-troubleshooting-and-faq.md) | fix something, or find a quick answer |
| [Audio sandboxes (EXPERIMENTAL)](23-audio-experimental.md) | try a sandbox with your Mac's microphone and speakers |

## Conventions

- Commands are shown as you type them: `doz up`. `NAME` is a sandbox's name; `my-app` is an example.
- Every command takes `--json` (machine-readable output), `--store DIR`, `-v` (every step) and `-q`
  (no progress). `doz help COMMAND` shows a command's options.
- Settings are named `section.name`, like `sandbox.clipboard`; see the
  [Settings reference](15-settings-reference.md).
- Screenshots use the light theme; the dashboard follows your Mac's appearance.

This manual is checked against `doz` itself on every build: every command, flag and setting it names
exists, and the settings reference is generated from the program.

The command-line [user guide](../CLI-USER-GUIDE.md) and the [walkthrough](../CLI-WALKTHROUGH.md) cover
the same ground for command-line users, more tersely.
