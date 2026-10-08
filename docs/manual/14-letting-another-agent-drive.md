# Letting another agent drive Dozer

So far *you* have run `doz`. But the agent you already use on your Mac — Claude Code, Codex, Cursor —
can run it too: create a sandbox for a risky task, hand the work to an agent inside it, check how it's
going, and tidy up afterwards. Your Mac's agent plans and reviews; the sandboxed agents do the work
behind the proxy.

## Concepts

- **Every command works without a terminal to type into**, and **`--json`** gives machine-readable
  output on stdout (errors as `{"error":{"code","message"}}`; fields are only ever added).
- **Exit codes** say what happened: `0` ok · `1` failed · `2` not found · `3` not possible in this
  state · `4` already exists · `5` not confirmed · `6` host unavailable · `7` not implemented yet ·
  `64` usage. `exec`, `run` and `attach` exit with the program's own code (`125` when `doz` itself
  failed).
- **Destructive commands refuse without `--yes`** when there's no terminal, so a script can't delete
  something by accident.
- **Two agents, two sets of rules.** The agent on your Mac has *your* permissions: it can run `doz`, so
  treat it as you would at the keyboard. The agent inside a sandbox is fenced in by the proxy and
  can't reach Dozer at all.

## The briefing

Paste this into your project's `CLAUDE.md` (or `AGENTS.md` for other agents):

````markdown
## Sandboxes (Dozer)

This Mac has Dozer Sandbox (`doz`): Linux VMs for running agents and risky commands in isolation.
Use a sandbox for anything that installs packages, runs untrusted code, or should not touch this
Mac. Always pass `--json` and read the result; never use `doz attach` or `doz up` without `--detach`
(they are interactive).

- Create one for this project: `doz create NAME --image claude-code --workspace "$PWD" --json`
  (images: `claude-code`, `pi`, `lab`, or `--agent claude-code --base python|go|rust|…`; `doz base ls`).
  `/workspace` in the sandbox IS this folder, live.
  For throwaway work that must not touch this folder: `doz create NAME --isolated --json`.
- Run a command and get its output and exit code: `doz exec NAME --json -- sh -c '…'`
  (add `--timeout SECONDS` for long ones; the default is 120). It starts or wakes the sandbox if needed.
- Start a long-running agent or program and come back later:
  `doz run NAME --detach -- claude -p "…"`, then `doz sessions NAME --json` and
  `doz sessions NAME --screen SESSION` to see its terminal.
- Before anything risky: `doz point take NAME before-X`; undo with `doz point revert NAME before-X --yes`.
- Refused network: `doz net NAME --json` shows what the agent was refused and the permission that
  would allow it. Do NOT widen permissions yourself: tell me what and why, and I will run
  `doz net allow NAME …`.
- When done: `doz hibernate NAME` (keeps everything, frees memory; `doz wake NAME` brings it back).
  Ask me before `doz reset`, `doz rm` or `doz shutdown`.
- `doz ls --json` lists sandboxes; `doz doctor --json` diagnoses problems.
````

## Then ask for what you want

For example, to Claude Code on your Mac:

> Upgrade this project to React 19 in a sandbox. Take a restore point first, let a Claude in the
> sandbox do the upgrade and get the tests passing, check on it every few minutes, and show me the
> diff when it's done. Don't touch my Mac's node_modules.

Your agent will then typically run:

```sh
doz create react19 --image claude-code --workspace ~/code/my-app --json
doz point take react19 before-upgrade
doz run react19 --detach -- claude -p "Upgrade to React 19 and make npm test pass"
doz sessions react19 --screen claude          # every few minutes, to see how it's going
doz exec react19 --json -- sh -c 'cd /workspace && npm test'
doz hibernate react19
```

Because `/workspace` is your project folder, the changes are already on your Mac when it finishes:
review them with `git diff`. If they're not what you wanted, `git checkout .` puts your files back
and `doz point revert` resets the sandbox.

You can watch it all in the dashboard (`doz ui`): the sandbox appears under **Sandboxes**, and
**All sessions** shows the agent working, read-only.

## Guardrails

- **Keep permission changes and deletion for yourself.** The briefing asks for that; you can make it a
  rule in your agent's own settings too (for example, only allow it `doz` subcommands that don't
  change permissions or delete).
- **Prefer `--isolated`** for work that shouldn't touch your folder at all.
- **Use restore points** before each risky step; they cost almost nothing.
- **Watch the clipboard, browser and file notices.** A sandboxed agent can put text on your clipboard,
  open a page in your browser or open a workspace document on your Mac, and each time you're told.
  Turn any of them off for a sandbox with `doz config set --sandbox NAME sandbox.clipboard off`,
  `… sandbox.browser_bridge off` or `… sandbox.open_files off`.
- **Scripts on a schedule** should use exact agent versions (`images.claude_code_version`) so an image
  never needs the internet to prepare.

## Useful JSON

| command | gives |
|---|---|
| `doz ls --json` | every sandbox: name, image, phase, RAM, disk, network, isolated, … |
| `doz inspect NAME --json` | everything about one |
| `doz exec NAME --json -- CMD` | `exitCode`, `stdout`, `stderr`, and whether it had to start or wake the sandbox |
| `doz sessions NAME --json` | its sessions, running or saved |
| `doz net NAME --json` | its permissions and recent refusals, with the suggestion for each |
| `doz resources --json` | the whole disk account |
| `doz config show --json` | every setting, value and source |

## Troubleshooting

| symptom | what to do |
|---|---|
| The agent's `doz` command hangs | It used an interactive command (`attach`, `up` without `--detach`); use `exec`, `run --detach`, `sessions --screen`. |
| Exit code 5 | A destructive command without `--yes` and without a terminal: intended. Decide yourself, or add `--yes`. |
| Exit code 6 | The host couldn't be reached or started: `doz doctor --json`. |
| The sandboxed agent is refused a site | Expected: it tells your Mac's agent, which tells you. `doz net NAME` shows the suggestion. |
