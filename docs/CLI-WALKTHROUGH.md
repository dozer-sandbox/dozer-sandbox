# `doz` walkthrough

A first run of the `doz` CLI, start to finish. It takes about 20 minutes, most of it one-time
image bakes. By the end you will have:

- booted, paused, slept and woken a sandbox;
- used a restore point;
- run Claude Code with a key the sandbox never sees;
- stopped the host and come back to the same conversation.

The reference for every command is the [user guide](CLI-USER-GUIDE.md).

You need an Apple-silicon Mac on macOS 26 or later, network access for the first bakes, and an
Anthropic API key for part 4.

## 0. Install (2–4 min, once)

```bash
cd ~/Developer/deck-factory/repo/lib/DozerKit
make install-cli                  # release build, signed with the virtualization entitlement
doz doctor
```

`make install-cli` installs `~/.local/bin/doz`, which must be on your `PATH`. `doctor` checks the
macOS version, Apple silicon, the entitlement, the Linux kernel, the store and the host. Everything
should say ok. If the kernel is missing, the first start fetches it.

Nothing runs in the background yet, and nothing is ever installed in `~/Library/LaunchAgents`.

## 1. A first sandbox (1 min; ~40 s of it is the one-time lab bake)

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

Press **Ctrl-]** to detach. Your terminal comes back, and `top` keeps running in the sandbox.

```bash
doz ls                             # lab1  lab  running  …RAM held…  1 session
doz sessions lab1                  # shell  (the top you left running)
```

The first command also started the **host**: one background process per user that owns the
running VMs. It started itself and will exit by itself.

## 2. The lifecycle (3 min)

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
Detach with **Ctrl-]**.

Commands without a terminal:

```bash
doz exec lab1 -- cat /etc/os-release
doz exec lab1 -- sh -c 'exit 3'; echo "exit code $?"      # 3 passes through
```

## 3. Restore points (2 min)

```bash
doz point take lab1 clean          # instant: an APFS clone of the disk
doz exec lab1 -- rm -rf /usr/bin/vi /root/marker
doz point revert lab1 clean        # asks first; shuts the sandbox down
doz start lab1
doz exec lab1 -- cat /root/marker  # "I was here" is back, and so is vi
doz point ls lab1                  # clean, plus the automatic "before revert" point
```

Also try `doz point fork lab1 clean lab2`, which makes a second sandbox from that point.

## 4. Claude Code, with a key it never sees (5–8 min; mostly the one-time bake)

Bake the image first, so the bake does not happen inside `up`:

```bash
doz image bake claude-code         # a few minutes, once per store
```

Create a sandbox on a folder of yours. The folder is shared at `/workspace`:

```bash
mkdir -p ~/doz-try && cd ~/doz-try
doz create try --image claude-code --workspace ~/doz-try
```

**Signed in to Claude Code on this Mac with a Claude subscription?** Then there is nothing to do:
a new sandbox uses the Mac's own login (the account `mac`), and Claude Code in it shows your plan.
Check with `doz doctor` (the `claude login` line) and `doz account ls`. Skip to `doz up
try` below. To use an API key instead, give it your key. Pick one of the two ways; the key is
**never** typed as an argument.

```bash
# (a) for this session: paste at the prompt (no echo), or pipe it from a file
doz key set try --anthropic

# (b) kept in the login keychain, re-read whenever a new host loads the sandbox
security add-generic-password -s doz-anthropic -a "$USER" -w     # prompts for the key
doz key set try --anthropic --keychain doz-anthropic
```

With (a), the host holds the key in memory only, so it is gone once the host stops (part 5). Then
start Claude Code:

```bash
doz up try
```

Claude Code opens straight at its prompt in `/workspace`, with no first-run setup screens: the
image's launcher marks onboarding done, approves this session's key placeholder and trusts the
folder. It runs with **bypass permissions on** (the status line says so), because the sandbox is
the safety boundary. It won't stop to ask before writing files or running commands.

Ask it something, for example "create hello.txt saying hi, then run ls -l". The file appears in
`~/doz-try` on your Mac.

To keep Claude Code's own permission prompts, start it with
`doz run try -e DOZ_CLAUDE_PERMISSIONS=ask -- claude`.

**Ctrl-]** detaches. Then check what the sandbox actually has:

```bash
doz exec try -- printenv ANTHROPIC_API_KEY     # doz_cred_… , a placeholder, not your key
doz net log try                                # allowed/denied connections, metadata only
doz exec try -- getent hosts example.com       # nothing: the agent policy allows only Anthropic + package registries, so the name doesn't resolve
doz net log try --denied
```

The sandbox has no network card. Every connection goes through a proxy in the host, which applies
the policy, logs the connection and swaps in the real key on the way to Anthropic.

## 5. Quit and come back (2 min)

```bash
doz hibernate try
doz host stop                      # hibernates anything still running, then exits
doz host status                    # no host
doz ls                             # still answers (read from the store, no host started)
```

If you used key option (a), set the key again now. The host that held it is gone. (The Mac login
and a keychain key are read again by the new host, and a session that was running keeps working.)

```bash
doz up try                         # a new host starts, wakes `try`, reattaches
```

You are back in the **same Claude Code conversation**, on the same screen, with the same process.
Hibernate keeps the running program itself, not just its files.

## 6. Numbers and clean-up (1 min)

```bash
doz metrics                        # every action's count, median, p90 … for this store
doz rm lab2 --yes
doz rm lab1 --yes
doz rm try                         # asks first; ~/doz-try on your Mac is untouched
```

The baked images stay, so the next sandbox starts in under a second (`doz image ls`,
`doz image rm`). The host exits by itself 5 minutes after nothing is running.

## What to report back

- Did part 4 answer with your real key, and did `printenv` show only the placeholder? (This is
  acceptance item 1.)
- Which key option you used, and whether (b) raised a keychain prompt.
- Did part 5 bring back the same conversation?
- Anything confusing in the output wording, and any command you expected that was missing.
