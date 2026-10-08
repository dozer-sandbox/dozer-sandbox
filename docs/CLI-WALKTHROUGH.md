# `doz` walkthrough

> The [user manual](manual/README.md) covers every topic here in depth, for the command line and the
> dashboard; start with its [Getting started](manual/01-getting-started.md) if you prefer the browser.

A first run of the `doz` CLI, start to finish, from nothing installed. It takes about 25 minutes,
most of it the one-time image preparation (which runs in the background while you read on). By the
end you will have:

- set up this Mac with `doz onboard`, and a project folder with `doz init` + `doz up`;
- booted, paused, slept and woken a sandbox;
- used a restore point;
- run Claude Code with a key the sandbox never sees, and seen what it is told about where it runs;
- stopped the host and come back to the same conversation;
- removed everything with `doz uninstall`, and set it up again in the browser.

The reference for every command is the [user guide](CLI-USER-GUIDE.md).

You need an Apple-silicon Mac on macOS 26 or later and network access for the first preparation.
Claude Code signed in on this Mac (or an Anthropic API key) for part 4.

## 0. From a clean slate (optional)

If Dozer Sandbox was on this Mac before, start from nothing: `doz uninstall` lists exactly what it
removes — the store (every sandbox and image), the settings (`~/.config/dozer-sandbox`) and a
`make install-cli` `doz` — and asks once. A `doz` Homebrew installed is Homebrew's: it tells you to
finish with `brew uninstall doz`. It never touches the keychain or Claude Code's own files.

```bash
doz uninstall                      # read the list, answer y
```

## 1. Install and onboard (seconds to install; 5–8 min of preparation, once)

```bash
brew install dozer-sandbox/tap/doz   # the prebuilt release, signed and notarised, with the virtualization entitlement
doz onboard
```

Homebrew installs the prebuilt `doz` in seconds — no compiler, no clone. `brew upgrade doz` (or
`doz update`) later brings a new release; doz says when one is out. Nothing is ever installed in `~/Library/LaunchAgents`.
(From a source checkout, `make install-cli` builds and installs `~/.local/bin/doz` instead — for
contributors; don't have both on your `PATH`.) `doz onboard` sets up this Mac, once, and asks as it goes —
Enter takes the recommended answer:

1. **Checks** — the doctor's: macOS, Apple silicon, virtualization, the entitlement, the store's
   disk (APFS, room for the images), the kernel, vmnet, Claude Code. A *required* one that fails
   stops here, with the reason; the others only warn.
2. **Claude account** — if Claude Code is signed in on this Mac, sandboxes can use that login
   (nothing is copied into them; the Mac's proxy adds it and the Mac keeps renewing it). Otherwise:
   an API key or a setup token (`claude setup-token`), **pasted right there at a hidden prompt** — it
   is stored exactly as `doz account add` stores it (the login keychain, one tiny check request) and
   becomes the default — or **Decide later**. Onboarding never logs in for you.
3. **Images** — a checklist: `claude-code` ticked; `pi` and `lab` optional, each with its download
   and an estimate.
4. **Settings** — `~/.config/dozer-sandbox/doz.toml` (every setting listed at its default; your
   answers are the only lines set) and `agent-prompt.md` beside it (your own version of what agents
   are told about where they run — all commented out for now). An existing file is never touched.
5. **Preparing** — the kernel, the guest init disk, the base image and the bake, with the same
   progress as every start: a spinner on the step under way, a bar on a download, the last lines of
   output. This is the waiting a first start would otherwise make you do.

The preparation runs **in the host**, not in your terminal: press **Ctrl-C** and onboarding
detaches — it goes on. Try it:

```bash
doz onboard --status               # joins it again: the same progress, from where it is
doz image ls                       # claude-code 2.1.285 (latest), once it is done
```

The Claude Code installed is the **latest** one, asked of the npm registry while the image is
prepared, then installed at that exact version (integrity-checked). When a newer one comes out, the
next `doz create` or `doz up` still starts at once on the image you have, and `doz image ls` says the
newer version is available — `doz image bake claude-code` rebuilds when you are ready (nothing is
rebuilt without you). For a fixed version:
`doz config set images.claude_code_version 2.1.227`.

(`doz onboard --cancel` would stop it.) A `doz up` of that image meanwhile would *join* the same
preparation — one download, one bake. Re-running `doz onboard` later is safe: it prepares only what
is missing and leaves your settings alone.

## 1b. A project folder: init + up (1 min)

```bash
mkdir -p ~/doz-try && cd ~/doz-try
doz init                           # sandbox name (from the folder) and image — Enter, Enter
cat doz_project.yaml
```

`doz_project.yaml` is this folder's sandbox: its name, image and, commented out, everything else
you may set (CPUs, memory, network, account, which sessions start, the project's own lines for the
agent). The folder itself is shared at `/workspace`.

```bash
doz up                             # no name: this folder's sandbox — created, started, attached
```

That is Claude Code, in a VM, in your folder. **Ctrl-] Ctrl-]** detaches. Part 4 comes back to it; next, a
plain shell sandbox to learn the lifecycle on.

## 2. A first sandbox (1 min; ~40 s of it is the one-time lab bake)

```bash
doz up lab1 --image lab
```

`up` creates `lab1`, boots it and attaches your terminal to a `bash` shell in it. The first time,
it also bakes the lab image (Alpine + bash). Later starts take about 0.4 s.

Inside the sandbox:

```bash
uname -a
echo "I was here" > /root/marker
top                                   # leave it running
```

Press **Ctrl-]** twice to detach (once opens a one-line menu at the bottom: `d detach · n next · p prev ·
s sessions · Esc back`). Your terminal comes back, and `top` keeps running in the sandbox.

```bash
doz ls                             # lab1  lab  running  …RAM held…  1 session
doz sessions lab1                  # shell  (the top you left running)
```

The first command also started the **host**: one background process per user that owns the
running VMs. It started itself and will exit by itself.

The boot flew past? It is kept:

```bash
doz console lab1 --list            # 1  …  cold boot  0.5 s  ✓   (each start and wake is kept — the last 5)
doz console lab1 --steps           # doz's steps as they happened, then the kernel's console
```

## 3. The lifecycle (3 min)

Try each step and watch `doz ls` between them:

```bash
doz pause lab1                     # ~1 ms. CPU stops; RAM is kept.
doz resume lab1

doz sleep lab1                     # pause + snapshot to disk; RAM still held
doz wake lab1

doz hibernate lab1                 # snapshot, then the VM stops: RAM held goes to —
doz ls
doz attach lab1                    # wakes it (~0.3 s) and reattaches: top is still running
```

`top` never stopped counting from its own point of view: same process, same PID, same screen.
Detach with **Ctrl-] Ctrl-]**.

Commands without a terminal:

```bash
doz exec lab1 -- cat /etc/os-release
doz exec lab1 -- sh -c 'exit 3'; echo "exit code $?"      # 3 passes through
```

## 4. Restore points (2 min)

```bash
doz point take lab1 clean          # instant: an APFS clone of the disk
doz exec lab1 -- rm -rf /usr/bin/vi /root/marker
doz point revert lab1 clean        # asks first; shuts the sandbox down
doz start lab1
doz exec lab1 -- cat /root/marker  # "I was here" is back, and so is vi
doz point ls lab1                  # clean, plus the automatic "before revert" point
```

Also try `doz point fork lab1 clean lab2`, which makes a second sandbox from that point.

## 5. Claude Code, with a key it never sees (3 min — the image was prepared in part 1)

Back to the project from part 1b: the sandbox `doz-try` (named after the folder), with `~/doz-try`
shared at `/workspace`.

**Signed in to Claude Code on this Mac with a Claude subscription, and chose "Use this Mac's Claude
Code login" in `doz onboard`?** Then there is nothing to do: the sandbox uses the Mac's own login
(the account `mac`), and Claude Code in it shows your plan. Check with `doz account ls`. Otherwise
give it a key — pick one of the two ways; the key is **never** typed as an argument:

```bash
# (a) for this session: paste at the prompt (no echo), or pipe it from a file
doz key set doz-try --anthropic

# (b) kept in the login keychain, re-read whenever a new host loads the sandbox
security add-generic-password -s doz-anthropic -a "$USER" -w     # prompts for the key
doz key set doz-try --anthropic --keychain doz-anthropic
```

With (a), the host holds the key in memory only, so it is gone once the host stops (part 6). Then:

```bash
cd ~/doz-try && doz up
```

**What Claude is told about where it runs.** Every session starts with a short facts block appended
to Claude Code's system prompt, and a `dozer` skill with the details — see it:

```bash
doz inspect doz-try --prompt
```

Ask Claude: *"What is the host path of /workspace?"* — it answers `~/doz-try` (the full path) from
the facts block, without looking around. Ask *"Where are you running — what is this machine?"* — a
Dozer Sandbox VM on your Mac, how its disks persist, that the network goes through your Mac's proxy.
(A sandbox made without a workspace is **isolated**: its agent is told no folder is shared with the
Mac, and `doz ls` says `isolated`. A `--workspace` folder that does not exist yet is made for you.)

Claude Code opens straight at its prompt in `/workspace`, with no first-run setup screens: the
image's launcher marks onboarding done, approves this session's key placeholder and trusts the
folder. It runs with **bypass permissions on** (the status line says so), because the sandbox is
the safety boundary. It won't stop to ask before writing files or running commands.

Ask it something, for example "create hello.txt saying hi, then run ls -l". The file appears in
`~/doz-try` on your Mac.

To keep Claude Code's own permission prompts, start it with
`doz run doz-try -e DOZ_CLAUDE_PERMISSIONS=ask -- claude`.

**Ctrl-] Ctrl-]** detaches. Then check what the sandbox actually has:

```bash
doz exec doz-try -- printenv ANTHROPIC_API_KEY     # doz_cred_… , a placeholder, not your key
doz net log doz-try                                # allowed/denied connections, metadata only
doz exec doz-try -- getent hosts example.com       # nothing: the agent policy allows only Anthropic, Claude Code's own hosts, GitHub + package registries, so the name doesn't resolve
doz net log doz-try --denied
```

The sandbox has no network card. Every connection goes through a proxy in the host, which applies
the policy, logs the connection and swaps in the real key on the way to Anthropic.

## 6. Quit and come back (2 min)

```bash
doz hibernate doz-try
doz host stop                      # hibernates anything still running, then exits
doz host status                    # no host
doz ls                             # still answers (read from the store, no host started)
```

If you used key option (a), set the key again now. The host that held it is gone. (The Mac login
and a keychain key are read again by the new host, and a session that was running keeps working.)

```bash
cd ~/doz-try && doz up             # a new host starts, wakes `doz-try`, reattaches
```

You are back in the **same Claude Code conversation**, on the same screen, with the same process.
Hibernate keeps the running program itself, not just its files.

## 7. Numbers and clean-up (1 min)

```bash
doz metrics                        # every action's count, median, p90 … for this store
doz rm lab2 --yes
doz rm lab1 --yes
doz rm doz-try                     # asks first; ~/doz-try on your Mac (and its doz_project.yaml) is untouched
```

The prepared images stay, so the next sandbox starts in under a second (`doz image ls`,
`doz image rm`). The host exits by itself 5 minutes after nothing is running.

## 8. The same in the browser: uninstall, then the setup wizard (10 min)

Start over once more, this time setting up in the browser:

```bash
doz uninstall                      # the list, then y: the store and the settings (doz stays — Homebrew's)
brew reinstall doz                 # (not needed — shown to prove it takes seconds)
doz ui                             # opens the browser, signed in (one-use link)
```

A store that was never onboarded opens on the **setup wizard**: Welcome → Checks (the doctor's, the
required ones marked) → Claude account → Images (sizes and estimates; claude-code ticked) →
Preparing (the host's progress; **Continue in the background** leaves it running — **Operations**
shows it) → First sandbox (a name, an image and a workspace folder typed or pasted — a browser cannot
pick a local folder for the host) → Done. The account
step takes an API key or a setup token in a masked field (sent once, stored as `doz account add`
stores it, and cleared from the page) — or, with `doz config set ui.allow_secret_entry false`, shows
the CLI command instead. Afterwards the wizard is always under **Onboarding** in the navigation (a
dot marks it until setup is done), or **Doctor › Run onboarding again**.

Try **Continue in the background**, then open the new sandbox's page while the image still prepares:
its Start joins the same preparation. A sandbox's page shows its **Environment prompt** and whether
`/workspace` is shared.

## What to report back

- Did `doz onboard` explain each step, and did Ctrl-C + `--status` behave as described?
- Did Claude answer the host path of `/workspace` straight from its prompt, and describe the machine
  (VM on your Mac, disks, proxy)?
- Did part 5 answer with your real key, and did `printenv` show only the placeholder?
- Which key option you used, and whether (b) raised a keychain prompt.
- Did part 6 bring back the same conversation?
- Did `doz uninstall` remove exactly what it listed, and the wizard get you back to a first sandbox?
- Anything confusing in the output wording, and any command you expected that was missing.
