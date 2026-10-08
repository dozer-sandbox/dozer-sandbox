# Troubleshooting and FAQ

## Start here

```sh
doz doctor
```

`doz doctor` checks everything Dozer depends on — macOS and Apple silicon, the virtualization
permission, the Linux kernel, the NAT helper, disk space, the host, your Claude login and your images
— and says what to do about anything that fails. The dashboard's **Doctor** page shows the same.

Then, depending on what's wrong:

| to see | run |
|---|---|
| What the host is doing, live | `doz events` (or `doz events NAME`), or the dashboard's **Activity** |
| How a start or wake went | `doz console NAME --list`, then `doz console NAME --steps` — or **⋯** › **Boot log** on the sandbox's page |
| What the agent was refused | `doz net NAME` (the suggestions), `doz net log NAME --denied` |
| Everything about a sandbox | `doz inspect NAME` |
| What the agent is told | `doz inspect NAME --prompt` |
| The host's log | `<store>/host.log` (the store is `~/Library/Application Support/dozer-sandbox` by default) |
| Where the disk went | `doz resources` |

Add `-v` to any command to see every step it takes.

## Common problems

### Installing and upgrading

| symptom | what to do |
|---|---|
| `doz: command not found` | `brew list doz`, then open a new terminal window. |
| "cannot boot a VM", or about the entitlement | `doz doctor`; `brew reinstall doz`. A self-built copy must be signed (`make install-cli`). |
| "this host's program … is gone — an upgrade removed it" | `doz host stop`, then retry. |
| "this host's program was updated underneath it" | `doz host stop`, then retry. |
| "note: the doz host is X (this doz is Y)" | A host of the previous version still runs and answered: `doz host stop` (sandboxes hibernate, and wake on the new version). |

### Starting and waking

| symptom | what to do |
|---|---|
| The first start takes minutes | It's preparing the image, once. `doz onboard --status` shows it. |
| A start fails | `doz console NAME --steps`: the failing step is marked ✕, with why. |
| A wake fails | `doz host stop`, then wake again (a failed wake keeps its snapshot). If it says it was put to sleep by another version in a machine this one can't rebuild, wake it with that version, or shut it down. |
| Last resort for a stuck sandbox | `doz shutdown NAME` then `doz start NAME`: programs end, the disks are kept. `claude --continue` resumes Claude Code's last conversation. |
| A sandbox shows as died | The host crashed while it ran; `doz start NAME` checks its disk and boots it. |
| "not possible in this phase" | `doz ls` shows its state; e.g. `resume` only works on a paused sandbox. |

### Agents and accounts

| symptom | what to do |
|---|---|
| The agent says it has no key, or gets 401 | `doz account ls`, `doz key ls NAME`. A typed key is gone after the host stopped. |
| "this Mac's Claude login expired" | Run `claude` on your Mac once, or `doz account keepalive on`. |
| pi can't be created | pi needs an API key account: `doz account add NAME --api-key`. |
| "the agent prompt does not render" | `doz inspect NAME --prompt` names the unknown `{{variable}}`; fix it or `doz config set agent.prompt false`. |
| `sudo apt-get install` fails with a network error | `doz net NAME`: system packages need `install:system` (on in Standard). |

### Network

| symptom | what to do |
|---|---|
| A package install or download fails | `doz net NAME` shows the refusal and the permission that allows it. |
| A site works in your browser but not in the sandbox | `doz net log NAME --denied`: it often needs a second host. |
| Everything is refused | The sandbox may be `locked`: `doz net NAME`, then `doz net allow NAME standard`. |

### Terminals and the dashboard

| symptom | what to do |
|---|---|
| Ctrl-] doesn't detach | Once opens the menu on the bottom row; press it again (or `d`). |
| "Sign in with a new link" | Paste a link from `doz ui link --print-url` into the page, or open one with `doz ui link`. |
| A browser terminal says "Disconnected" | It was silent a long time or could not reattach: **Reconnect**. After `doz ui` restarts it reattaches by itself. |
| The installed dashboard app says "Dozer isn't running on this Mac" | Run `doz ui`; the window comes back by itself. |
| The dashboard is paused under an overlay | `doz ui` stopped: start it again and the page reconnects. |
| Open in Terminal does nothing | Make a terminal app the handler for `.command` files (Finder › Get Info › Open with › Change All…). |
| A copy didn't reach the clipboard | Look at the notice (off, too big, too many); `doz config show --sandbox NAME`. |
| A sign-in page didn't open | Is a terminal attached? Is `sandbox.browser_bridge` on? See [Signing in from a sandbox](11-signing-in-from-a-sandbox.md#troubleshooting). |
| A workspace file didn't open on the Mac | Read the notice (and the program's own message): outside `/workspace`, not a document type, executable, an app not in `bridges.open_apps`, an isolated sandbox, or `sandbox.open_files` off. See [Opening workspace files](07-terminals-and-sessions.md#opening-workspace-files-on-your-mac). |

### Images and disk space

| symptom | what to do |
|---|---|
| An image says "older recipe" or "update available" | Rebuild when it suits you (`doz image bake NAME`, or **Rebuild**); `doz reset` the sandboxes you want on it. |
| The disk is filling up | `doz resources`, then `doz resources clean --dry-run`. |
| "Dockerfile changed — rebuild available" | `doz image bake df-…`, then `doz reset NAME`. |

### Sessions after a wake

| symptom | what to do |
|---|---|
| Codex: `turn/start failed: invalid cwd: No such file or directory` after a wake; a shell's `ls .` says `No such file or directory` | The program's folder was cut off by a wake from hibernation — a sandbox still on the plain share (`workspace.view` off, or started before 0.30.0). Restart the session: `doz sessions restart NAME SESSION` (the conversation continues), or **⋯ › Restart session** on its tab. From its next start the sandbox uses [the workspace view](21-the-workspace-view.md) and this does not happen again. |
| `doz doctor` warns "workspace view" | The live view of `/workspace` could not start, so the folder is shared directly. `doz console NAME --steps` shows why; `doz shutdown NAME` and `doz start NAME` try again. |
| A program is stuck | `doz sessions restart NAME SESSION`, or `doz sessions end NAME SESSION`. |

## FAQ

**Is a sandbox a container?**
No. Each is a Linux virtual machine with its own kernel, run by Apple's Virtualization framework.

**Does a sandbox slow my Mac down when I'm not using it?**
A running sandbox holds its memory; a paused or sleeping one holds it but uses no CPU; a hibernated
one holds nothing. `doz hibernate NAME` when you're done for the day.

**Will I lose work when a sandbox sleeps or hibernates?**
No: programs, sessions and screens come back exactly where they were.

**Where are my files?**
Your project folder stays on your Mac (the sandbox sees it at `/workspace`). Everything else is on the
sandbox's disks in the store.

**Can the agent see my other files, my keychain or my clipboard?**
No. It sees only the folder you shared, never a credential, and never your clipboard (it can only
*write* to it, with a notice, if you let it).

**Can I use Dozer offline?**
Mostly. Sandboxes start, sleep and wake offline; preparing an image needs the internet the first time,
and `latest` agent versions need it to be resolved (set an exact version to avoid that). The agent
itself needs its AI model, of course.

**Can I move a sandbox to another Mac?**
Not yet with a command. A snapshot (sleep, hibernate) is encrypted with a key specific to this Mac.

**Why does `doz` say "the next command starts a new host"?**
The host is a background process that runs your sandboxes and exits when idle. You never need to start
it: any command that needs it does.

**How do I start completely fresh?**
`doz uninstall`, then `brew uninstall doz`, `brew install doz` and `doz onboard`. Your project folders
and keychain are untouched.

**Exit codes?**
`0` ok · `1` failed · `2` not found · `3` not possible in this state · `4` already exists · `5` not
confirmed · `6` host unavailable · `7` not implemented yet · `64` usage. `exec`, `run` and `attach`
exit with the program's own code (`125` when `doz` itself failed).
