# `snooze` walkthrough

A first run of the `snooze` CLI, start to finish. It takes about 20 minutes, most of it one-time
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
cd ~/Developer/deck-factory/repo/lib/SnoozeContainerKit
make install-cli                  # release build, signed with the virtualization entitlement
snooze doctor
```

`make install-cli` installs `~/.local/bin/snooze`, which must be on your `PATH`. `doctor` checks the
macOS version, Apple silicon, the entitlement, the Linux kernel, the store and the host. Everything
should say ok. If the kernel is missing, the first start fetches it.

Nothing runs in the background yet, and nothing is ever installed in `~/Library/LaunchAgents`.

## 1. A first sandbox (1 min; ~40 s of it is the one-time lab bake)

```bash
snooze up lab1 --image lab
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
snooze ls                             # lab1  lab  running  …RAM held…  1 session
snooze sessions lab1                  # shell  (the top you left running)
```

The first command also started the **host**: one background process per user that owns the
running VMs. It started itself and will exit by itself.

## 2. The lifecycle (3 min)

Try each step and watch `snooze ls` between them:

```bash
snooze pause lab1                     # ~1 ms. CPU stops; RAM is kept.
snooze resume lab1

snooze sleep lab1                     # pause + snapshot to disk; RAM still held
snooze wake lab1

snooze deep-sleep lab1                # snapshot, then the VM stops: RAM held goes to —
snooze ls
snooze attach lab1                    # wakes it (~0.3 s) and reattaches: top is still running
```

`top` never stopped counting from its own point of view: same process, same PID, same screen.
Detach with **Ctrl-]**.

Commands without a terminal:

```bash
snooze exec lab1 -- cat /etc/os-release
snooze exec lab1 -- sh -c 'exit 3'; echo "exit code $?"      # 3 passes through
```

## 3. Restore points (2 min)

```bash
snooze point take lab1 clean          # instant: an APFS clone of the disk
snooze exec lab1 -- rm -rf /usr/bin/vi /root/marker
snooze point revert lab1 clean        # asks first; shuts the sandbox down
snooze start lab1
snooze exec lab1 -- cat /root/marker  # "I was here" is back, and so is vi
snooze point ls lab1                  # clean, plus the automatic "before revert" point
```

Also try `snooze point fork lab1 clean lab2`, which makes a second sandbox from that point.

## 4. Claude Code, with a key it never sees (5–8 min; mostly the one-time bake)

Bake the image first, so the bake does not happen inside `up`:

```bash
snooze image bake claude-code         # a few minutes, once per store
```

Create a sandbox on a folder of yours. The folder is shared at `/workspace`:

```bash
mkdir -p ~/snooze-try && cd ~/snooze-try
snooze create try --image claude-code --workspace ~/snooze-try
```

Give it your key. Pick one of the two ways; the key is **never** typed as an argument.

```bash
# (a) for this session: paste at the prompt (no echo), or pipe it from a file
snooze key set try --anthropic

# (b) kept in the login keychain, re-read whenever a new host loads the sandbox
security add-generic-password -s snooze-anthropic -a "$USER" -w     # prompts for the key
snooze key set try --anthropic --keychain snooze-anthropic
```

With (a), the host holds the key in memory only, so it is gone once the host stops (part 5). Then
start Claude Code:

```bash
snooze up try
```

Claude Code starts in `/workspace`. Answer its first-run questions, then ask it something, for
example "create hello.txt saying hi". The file appears in `~/snooze-try` on your Mac.

**Ctrl-]** detaches. Then check what the sandbox actually has:

```bash
snooze exec try -- printenv ANTHROPIC_API_KEY     # snz_cred_… , a placeholder, not your key
snooze net log try                                # allowed/denied connections, metadata only
snooze exec try -- getent hosts example.com       # nothing: the agent policy allows only Anthropic + package registries, so the name doesn't resolve
snooze net log try --denied
```

The sandbox has no network card. Every connection goes through a proxy in the host, which applies
the policy, logs the connection and swaps in the real key on the way to Anthropic.

## 5. Quit and come back (2 min)

```bash
snooze deep-sleep try
snooze host stop                      # deep-sleeps anything still running, then exits
snooze host status                    # no host
snooze ls                             # still answers (read from the store, no host started)
```

If you used key option (a), set the key again now. The host that held it is gone.

```bash
snooze up try                         # a new host starts, wakes `try`, reattaches
```

You are back in the **same Claude Code conversation**, on the same screen, with the same process.
A Deep Sleep keeps the running program itself, not just its files.

## 6. Numbers and clean-up (1 min)

```bash
snooze metrics                        # every action's count, median, p90 … for this store
snooze rm lab2 --yes
snooze rm lab1 --yes
snooze rm try                         # asks first; ~/snooze-try on your Mac is untouched
```

The baked images stay, so the next sandbox starts in under a second (`snooze image ls`,
`snooze image rm`). The host exits by itself 5 minutes after nothing is running.

## What to report back

- Did part 4 answer with your real key, and did `printenv` show only the placeholder? (This is
  acceptance item 1.)
- Which key option you used, and whether (b) raised a keychain prompt.
- Did part 5 bring back the same conversation?
- Anything confusing in the output wording, and any command you expected that was missing.
