# SnoozeContainerKit

SnoozeContainerKit is a pausable Linux sandbox for macOS: one Linux container in its own VM,
driven through Apple's [Containerization](https://github.com/apple/containerization) package, that
pauses in about a millisecond, sleeps to disk to give its RAM back, wakes in about a third of a
second, and restores into a new process after the host app crashes — with terminal sessions that
survive every one of those.

**macOS 26+ only**, Apple silicon. It is built on Virtualization.framework and vmnet, which have no
Linux equivalent, so there is no Linux build and no Linux CI job. The VM needs the
`com.apple.security.virtualization` entitlement on whatever binary hosts it.

## Products

| Product | What it is |
|---|---|
| `SnoozeContainerKit` | `Sandbox` (the actor that owns one VM and its lifecycle), `SandboxSpec`, `SessionConnection` (one viewer's connection to a guest terminal session), the `deckhold` wire protocol, and the committed `deckhold` guest binary as a resource. |
| `snooze` (executable, 585) | The command-line tool: create, start, pause, sleep, deep-sleep and wake sandboxes, attach to their sessions, restore points, network policy, metrics — see [The `snooze` CLI](#the-snooze-cli). Built on the library; the library does not depend on it. |

## What it does, measured

M3, macOS 27, Alpine 3.20 guest with 512 MiB–1 GiB, `make test-vm` on 2026-09-25 (the 576 probe
measured the same design first):

| | |
|---|---|
| start, warm store | **~0.3–0.4 s** to a running guest with deckhold installed (VM create + boot ~280 ms, of which kernel → init ~70 ms; root disk is an APFS clone of a prepared disk, 0 ms) |
| start, first ever in a store | ~40 s once: guest init image + OCI image pulls, then the package bake (`apk add …`), kept as a "golden" disk |
| pause / resume | **0–1 ms** each; attached terminals freeze and continue on the same connection |
| sleep (pause + snapshot) | ~0.3 s; 66 MiB snapshot for a 512 MiB guest; RAM still held — crash insurance |
| sleep to disk | **~0.35 s** (pause + snapshot + VM stop); RAM returned |
| wake from disk | **~0.27–0.34 s** (restore ~235 ms + clock resync + share re-mount ~35 ms); snapshot deleted |
| reattach after a wake | first SNAPSHOT frame **8–16 ms** after `attach` |
| restore after a crash (new process) | **~0.3 s** (plus up to ~0.3 s while vmnet releases the dead process's subnet); sessions keep their pids |

## Using it

```swift
import SnoozeContainerKit

let spec = SandboxSpec(name: "lab", storeRoot: myAppSupport.appendingPathComponent("sandboxes"),
                       bakePackages: ["bash", "ncurses"],
                       shares: [Share(hostPath: workDir.path, guestPath: "/work")])
let sandbox = try Sandbox(spec: spec)
for await event in sandbox.events() { … }          // phase changes, timed steps, readouts

try await sandbox.start()
try await sandbox.openSession("shell", argv: ["bash", "-l"], size: TermSize(cols: 120, rows: 36))
let conn = try await sandbox.attach("shell", size: TermSize(cols: 120, rows: 36))
Task { for await out in conn.output {               // .snapshot first, then .data …
    switch out {                                   // … and one final .ended / .detached
    case .snapshot(let vt), .data(let vt): terminal.write(vt)
    case .ended(let code): print("exited \(code.map(String.init) ?? "—")")
    case .detached(.sandboxSleeping): break        // attach again after wakeFromDisk()
    case .detached: break
    }
}}
conn.send(Data("ls\r".utf8)); conn.resize(TermSize(cols: 100, rows: 30))

try await sandbox.sleepToDisk()                    // RAM freed; the session keeps its state
try await sandbox.wakeFromDisk()
// …a later process, after a crash or quit while asleep:
if Sandbox.restorableState(for: spec) != nil { try await sandbox.restoreAfterCrash() }
```

Lifecycle: `start` · `pause` / `resume` · `sleep` (pause + snapshot) · `sleepToDisk` · `wakeFromDisk`
· `stop` · `restoreAfterCrash` · `prepareForExit` (keep a sleeping sandbox restorable, stop anything
else; 583: a program a session started less than `settle` — 3 s — ago gets the rest of it first) · `resetToImage` · `delete`. **Stop keeps the root disk**: the next Start cold-boots the same
disk (what you installed is still there); Reset to image starts again from a fresh clone of the
prepared disk; Delete removes everything the sandbox has on disk. A disk that was not cleanly
unmounted — `Sandbox.discardRestorableState(for:)` (a deep-slept VM is stopped without unmounting it),
a failed restore, a crash while running — is replayed from its **journal** on the next cold boot, or,
on a journal-less disk, checked with `e2fsck` first (583; see **Journal** below). Deep Sleep and Stop
`sync` the guest first, so a discarded Deep Sleep loses nothing written before it. Guest: `exec(argv)`
(no shell unless you pass one), `sessions()` (`deckhold ls`), `screenText(name)` (`deckhold dump`),
`bootConsole()`.

**Images** (`ImageRecipe`, `ImageBaker`, `AgentRecipes.claudeCode` / `.pi`): no layered images and
no Dockerfile — a digest-pinned OCI base is flattened to one ext4 **base disk** once, every bake
starts from an APFS clone of it, the install steps run inside a VM booted from that clone, a
credential-free check verifies the result, `fstrim /` runs last, and the disk is kept read-only in
the store, keyed by recipe + kernel + deckhold. A sandbox with `spec.recipe` APFS-clones it as its
root and gets a per-sandbox **state disk** for the agent's login/state (it survives Stop, Reset to
image and re-bakes). Credentials go to `openSession(environment:)` only.

**Lineage (587): base → image → sandbox, as APFS clones.**

```
<store>/images/bases/<key12>/root.ext4 + manifest.json   an OCI base, flattened ONCE (digest + capacity + journal + formatter)
<store>/images/<name>/<key12>/root.ext4 + manifest.json  an image: a clone of its base + the bake (manifest.parent = the base key)
<store>/sandboxes/<name>/rootfs.ext4                     a sandbox: a clone of its image (PersistedSandbox.rootImage)
```

- Measured (M3, `make test-vm-lineage`): with the `node` base flattened (33 s, once), claude-code
  bakes in **16 s** and pi in **15 s** (a fresh flatten each was ~50 s in 586). Both images share
  **256 MiB** of the 278 MiB base; each further image on it costs only its own blocks.
- Children never depend on their parent's FILE: deleting or re-baking a base or an image leaves every
  image and sandbox cloned from it exactly as it was (`ImageBaker.deleteBase`, `lineage children`).
- Every image key resolves to its disk: `StoreLayout.imageDisk(forKey:)` (`name@key12`, `custom:…`,
  `base:…`, a prepared-disk key). `CustomImage.baseImage` is such a key.
- A pre-587 store re-bakes each image once (the key includes the lineage format and the journal).

**Journal (587): on by default, 16 MiB — a toggle.** `ImageRecipe.journalMiB` (the image's root and
every sandbox's state disk) and `SandboxSpec.journalMiB` (the lab's prepared disk): default 16, `nil`
= no journal. 586/587 measured it: after Deep Sleep → discard, a journaled disk cold-boots by
journal replay in **~380 ms** with no e2fsck (15/15 `e2fsck -fn` clean afterwards); a journal-less
one goes through the helper VM's `e2fsck` (~1,030 ms), as before 587. The cost: 16 MiB per base
(shared) and up to 16 MiB per sandbox once the ring wraps; `fsync`-heavy work ~1.7× slower
(0.16 vs 0.09 ms per fsync), metadata-heavy work (many small files + `sync`) ~3× faster. Records
written before 587 decode as journal-less (their disks are); `PersistedSandbox.rootJournaled` /
`stateJournaled` say what each disk has. A copy taken while running (a running restore point, a
custom image from one) is still e2fsck'd on its first boot, journal or not.

**TRIM (587).** The root and state disks mount with `discard`: a block the guest frees is punched
out of the host file at once (300 MiB written and deleted in a running sandbox leaves 0 MiB behind).
Every bake ends with `fstrim /` — claude-code's image came out 89 MiB (14 %) and pi's 81 MiB (16 %)
smaller for ~60 ms.

**Accounting (587): `DiskAccounting.measure(store:)`** — every disk of a store (bases, images, custom
images, prepared disks, sandbox root and state disks, restore points) with its `allocatedBytes`,
`uniqueBytes` (what deleting it frees), `sharedWithParentBytes` (its lineage parent), `privateBytes`
(APFS's own number — they agree to 0.0 MiB on every disk, unless a file outside the store is a clone
of one inside it: `uniqueBytes` is scoped to the STORE, APFS's number to the whole volume), `extentsPerGiB`, and `garbageBytes`: the
host file's data in blocks ext4 considers free (exact, from the disk's bitmaps, on a cleanly unmounted
disk; otherwise allocated − the guest's `df` recorded at the last Stop / Deep Sleep,
`PersistedSandbox.guestUsedMiB`). It reads APFS's extent map (`F_LOG2PHYS_EXT`): ~5 ms per disk.
Measure stopped disks, on one volume.

**Maintenance (587), stopped sandboxes only** (a running or sleeping one, or a disk not cleanly
unmounted, is refused):

- `reclaim()` punches ext4's free blocks out of the root and state disks' host files — the churn a
  guest deleted without discard (a pre-587 disk, or a remount). 800 MiB → 0 in ~25 ms; the free list
  equals `dumpe2fs`'s, the disk boots identically, `e2fsck -fn` is clean.
- `rederive()` rebuilds the root disk as a fresh clone of its image plus only the blocks whose
  content differs, skipping free blocks — re-sharing blocks that were rewritten with the image's own
  bytes and dropping the garbage (147 MiB shared again, 200 MiB of garbage gone, in 0.8 s). The new
  disk is verified (every in-use block reads the same; `e2fsck -fn` clean) before an atomic rename;
  any failure leaves the original. The state disk and restore points are untouched.
- `maintenanceAdvice()` says which is worth it (`MaintenanceAdvice.thresholds`, from 586): garbage
  > 25 % of the allocation or > 512 MiB → reclaim; lost identical sharing > 64 MiB or > 10 % of the
  image → rederive. Fragmentation never triggers anything (586: 1000 extents/GiB cost no boot, wake
  or read time on the SSD).
- `checkDisks()` runs `e2fsck -fn` (read-only) on the disks in the helper VM.

**Memory (583): a woken sandbox gives back what it does not use.** The Mac charges a VM for every
guest page it has ever touched, and restoring a snapshot touches them all: woken from Deep Sleep, a
1 GiB Lab held **1,273 MiB** (cold-booted: 213) and a 2 GiB claude-code **2,340 MiB** (cold: 645).
Every VM now has a virtio memory balloon, and `wake()` inflates it over the guest's free pages,
leaving the guest `defaultFreeReserveMiB` free (¼ of the allocation, ≥ 256 MiB): woken, the Lab holds
**~585 MiB** and claude-code **~1,310 MiB** (−54% / −44%), for **+25–40 ms** of wake. The balloon
stays inflated (deflating would charge the pages again); the guest's page cache and processes are
untouched, and a guest that needs more still gets it (VZ deflates on guest OOM — a 512 MiB
allocation above the reserve took ~0.35–0.5 s instead of ~0.12 s). `returnFreeMemory(keepingFreeMiB:)`
does it on demand (e.g. after heavy work: −130–160 MiB after a 300 MiB turn), `restoreGuestMemory()`
gives the guest everything back, `setReturnsFreeMemoryOnWake(false)` turns the wake's off, and
`memoryReturnedMiB` reads it. Sleep and Deep Sleep deflate first (+~80–150 ms): a snapshot of an
inflated balloon does not restore. A sandbox deep-slept by an older build wakes without a balloon
(`PersistedSandbox.memoryBalloon`) and gets one at its next cold boot. Measured by
`probes/583-*/wake-memory` in the workspace; `hardening memory` is the regression test.

**Restore points** (disk only, no memory): `takeRestorePoint` (an APFS clone of the root + state
disks — instant; from a running VM: sync → pause → clone → resume, crash-consistent at best, so
marked for `e2fsck` on the next boot), `revert(to:)` (takes a "before revert" point first),
`fork(_:as:)` (a new, cold-booted sandbox), `deleteRestorePoint` (any, in any order), and
`saveAsImage` (a read-only **custom** image with its provenance, bootable via `spec.customImage`).

**Sessions** live in the guest under `deckhold`, a PTY holder on headless libghostty-vt: it owns
the PTY, keeps an emulator model of the screen, and on attach sends a rendered SNAPSHOT reflowed to
the viewer's size, then the program's own bytes. That is why a session survives a sleep to disk
(which severs every exec's stdio) — the viewer simply reattaches. Programs are started **without**
`sh -c` and with every signal reset to default (BusyBox `sh` leaks an ignored SIGQUIT, which a
program cannot trap). The wire protocol and the snapshot recipe are documented in
[`Guest/deckhold/deckhold.c`](Guest/deckhold/deckhold.c).

**NAT subnets (583).** A `.nat` sandbox whose spec names no `subnet` gets a free vmnet /24 of its
own from 192.168.100–199.0/24 — never one a network interface of the Mac is already on (the LAN, a
VPN, another process's vmnet bridge), never one this process holds — instead of vmnet's default,
which two processes could both take (the NAT then silently drops one). `SandboxSpec.subnet` stays an
override; a restore keeps the subnet its guest was addressed from. Proxied sandboxes have no NIC.

**Network (580): proxied sandboxes.** `SandboxSpec(…, network: .proxied(.agent))` boots a VM with
**no network interface** — only `lo`. The guest's only way out is `snoozenet` (a small static guest
binary, `Guest/snoozenet/`) relaying over vsock to `sandbox.egress`, an `EgressProxy` running in
the host process, where root in the guest cannot reach:

```swift
var spec = SandboxSpec(name: "agent", storeRoot: root, recipe: AgentRecipes.claudeCode,
                       network: .proxied(.agent))        // .locked · .bake · .agent · .open, or your own
let sandbox = try Sandbox(spec: spec)
sandbox.setCredential(.anthropic, secret: key)          // memory only; the guest gets snz_cred_… placeholders
try await sandbox.start()
for await r in sandbox.egress!.log.stream() { … }        // ConnectionRecord: host, verdict, rule, bytes, ms
sandbox.setNetworkPolicy(newPolicy)                      // live; e.g. policy.allow(host: "example.com")
let jsonl = sandbox.egress!.log.exportJSONLines()
```

- **Policy** (`NetworkPolicy`): default deny; rules checked in order, first match wins, by exact
  host, `*.domain` (subdomains), IPv4 CIDR/address (IP-literal destinations) or `*`, optional
  ports, and optional **methods / path prefixes** — enforceable only on requests the proxy reads,
  so a host with such a rule is decrypted. DNS is gated too: a name no rule could allow gets
  NXDOMAIN. Presets: `locked` (nothing), `bake` (npm, apt, apk, PyPI registries), `agent`
  (Anthropic's API and sign-in hosts + registries), `open` (everything, still proxied and logged).
- **What reaches the proxy:** `HTTP(S)_PROXY` (set for every `exec` and session) → CONNECT tunnels
  and plain HTTP; **any other TCP** is redirected in the guest (nat REDIRECT) and judged by the name
  its address was resolved from (a bare IP no DNS answer produced is denied); **DNS** is answered
  from the Mac's resolver (A records only — the guest has no IPv6 path); **UDP is rejected** (QUIC
  and outside DNS fail fast and clients fall back to TCP).
- **Credentials:** a `CredentialBinding` names a secret's hosts and header (`x-api-key`,
  `Authorization: Bearer`). TLS is decrypted **only** for bound hosts (and hosts with HTTP rules),
  with a **per-sandbox CA** (`SandboxCA`: P-256, key `0600` in the sandbox's directory, certificate
  installed in the guest's trust store at every fresh boot and pointed to by `NODE_EXTRA_CA_CERTS`,
  `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`, `GIT_SSL_CAINFO`). On each request: a
  placeholder minted for that host is swapped for the secret; no auth header → the secret is
  injected; a placeholder for another host, or an unknown/revoked one → **403** and a log entry; a
  credential the tool supplied itself passes through untouched. A real key passed to `openSession`
  or `exec` in a bound variable is moved into the vault and replaced by a placeholder — **keys never
  enter the sandbox**. Placeholders are issued fresh per session/exec and revoked on Stop.
- **Log** (`ConnectionLog`): metadata only — kind, host:port, method + path *without the query*,
  rule, verdict, credential action, bytes each way, latency, duration. Never bodies, header values,
  prompts or keys. `exportJSONLines()` doubles as test fixtures.
- **Limits, by design:** hosts that are not decrypted pass through by name untouched — WebSockets,
  HTTP/2 and gRPC included — so the proxy cannot see a placeholder sent to them (it has no power
  there anyway). Decrypted tunnels offer only HTTP/1.1 (ALPN), so HTTP/2-only or gRPC clients of a
  *bound* host fail, and **a client that pins certificates fails loudly on a decrypted host** —
  which is why only bound hosts are decrypted. A proxied bake runs under the `bake` preset.

**Requirements on the host:** the `com.apple.security.virtualization` entitlement, and network on
the first start in a store. Nothing else to install: the library owns its **Linux kernel** —
`KernelProvider` fetches one pinned artifact (the kata-containers 3.28.0 static release for arm64,
the same kernel Apple's `container` CLI 1.2.2 recommends: `vmlinux-6.18.15-186`), checks the archive's
and the kernel's sha256, and caches it in `<storeRoot>/kernels` (or `SandboxSpec.kernelCacheDirectory`).
First fetch ~90 s (a 569 MiB archive); every later start verifies the cached 15 MiB kernel in ~10 ms.
A byte-identical copy already on the Mac (the `container` CLI's) seeds the cache with no network;
`SandboxSpec.kernelPath` boots any kernel you choose instead.

## The `snooze` CLI

```bash
make install-cli PREFIX=~/.local       # release build, signed with the virtualization entitlement
snooze doctor                          # macOS, Apple silicon, the entitlement, kernel, store, host
snooze up myproj --image claude-code --workspace ~/code/myproj   # create → boot → attach to Claude Code
```

New to it: the [walkthrough](docs/CLI-WALKTHROUGH.md) (~20 min, first run end to end) and the
[user guide](docs/CLI-USER-GUIDE.md) (concepts, every command by task, keys, network, troubleshooting).

`make cli` builds and signs `.build/debug/snooze` for development. An unsigned `snooze` runs every
command but cannot boot a VM (`snooze doctor` says so).

### Commands (the owner's vocabulary; aliases in brackets)

| | |
|---|---|
| `snooze create NAME --image lab\|claude-code\|pi\|<custom> [--cpus N] [--memory 2G] [--workspace DIR] [--network agent\|bake\|locked\|open\|nat\|none] [--subnet CIDR]` | Make a sandbox (off until started). `lab` is Alpine + bash (1 GiB); the agent images get 2 GiB. The workspace is shared at `/workspace`. The network defaults to **proxied** — no network interface, every connection judged by the Mac's policy and logged: `agent` for an agent image, `bake` (package registries only) for the lab. |
| `snooze up NAME [create options] [--session S] [-d] [-- CMD…]` | Create if missing → start or wake → attach to the image's session (`claude`, `pi`, or a `bash -l` shell), opening it if it is not running (`vagrant up` / `compose up`). |
| `snooze start NAME` [`cold-boot`] | Boot — or wake it if it is asleep, resume it if paused. |
| `snooze pause NAME` [`suspend`] · `snooze resume NAME` | Guest CPU to 0 in ~1 ms, RAM kept. |
| `snooze sleep NAME` | Pause + snapshot to disk: RAM kept, and it survives a host crash. |
| `snooze deep-sleep NAME` [`hibernate`] · `snooze wake NAME` | Snapshot + VM stopped: RAM returned. Wake ~0.3 s, sessions and pids where they were. A program started less than 3 s ago gets the rest of that time first (583). |
| `snooze shutdown NAME` · `snooze reset NAME` · `snooze rm NAME` | Cold stop keeping the disk · discard the disk (back to the image) · remove everything. Each asks first on the terminal; `--yes` skips; with no terminal and no `--yes` they refuse (exit 5). |
| `snooze ls` · `snooze inspect NAME` · `snooze sessions NAME` | Name, image, phase, RAM held (the allocation less what the balloon returned; 0 deep asleep or off), disk, sessions, network · everything as JSON · the guest's terminal sessions. |
| `snooze attach NAME [SESSION] [--no-wake]` | A raw-tty client of a guest session. **Ctrl-]** detaches (`--detach-key ctrl-x\|none`); the session keeps running. A Deep Sleep disconnects you and the client waits, then reattaches by itself when the sandbox runs again. A paused or sleeping sandbox is woken first unless `--no-wake`. |
| `snooze run NAME [--session S] [-d] -- CMD…` | A NEW session running CMD (no shell in front — say `bash -lc '…'` for one), attached; exits with the program's exit code. |
| `snooze exec NAME [--user U] [--workdir D] [-e K=V] [--timeout S] -- CMD…` | One-shot and non-interactive: stdout, stderr and the exit code pass through. Runs like a session (an agent image's user in `/workspace`). |
| `snooze image ls\|bake NAME\|rm NAME` | The built-in images and custom ones; bake now rather than at the first start. `pull`/`push` answer "not yet" (584.B2). |
| `snooze point take\|ls\|revert\|fork\|rm\|save-image NAME …` | Restore points (disk-only APFS clones): `take NAME [POINT]`, `revert NAME POINT` (shuts down; a "before revert" point is taken first), `fork NAME POINT NEW`, `save-image NAME [POINT] --as IMAGE`. A point is named by its name or id. |
| `snooze net policy NAME [--preset P] [--allow HOST…] [--deny HOST…] [--remove HOST…]` · `snooze net log NAME [--denied] [--follow]` | A proxied sandbox's policy, changed live and kept for the next start · its connection log (metadata only). |
| `snooze key set NAME --anthropic [--keychain SERVICE]` · `key set NAME --claude-login` · `key rm` · `key ls` | The key is read from stdin (or a no-echo prompt, or a keychain generic password) — **never an argument** — and held by the host's proxy in memory; the guest's `ANTHROPIC_API_KEY` is a placeholder. A key from stdin lasts while the host runs; one from the keychain is read again when a new host loads the sandbox. `--claude-login` = `account use NAME mac`. `key ls` shows the account, state, expiry, policy and the fingerprints of credentials the guest brought itself. |
| `snooze account ls\|add\|verify\|rm\|default\|use\|keepalive` · `create --account NAME` | 588: Anthropic accounts the host holds — `mac` (built in: this Mac's own Claude Code login, read-only, renewed by the Mac's Claude Code), `setup-token` (`claude setup-token`, 1 year, in the keychain as `snooze-claude:NAME`), `api-key`. A proxied sandbox follows the store's default (`mac`) or pins one; the guest sees a placeholder plus the plan (`CLAUDE_CODE_SUBSCRIPTION_TYPE`), so Claude Code shows "Claude Max" and defaults to Opus. No silent fallback. `keepalive on` (off by default) runs the Mac's own `claude -p` near expiry while a sandbox uses the login. |
| `snooze key policy NAME allow\|strict\|auto` | 588: a credential the guest brings itself (a guest `/login`, a pasted key) — allow and flag it (fingerprint in `net log`, `ls`, `key ls`, events), or refuse it with an explanation and deny the sign-in hosts. `auto`: strict for a non-`mac` account. |
| `snooze metrics [--csv] [--image X] [--days N] [--no-steps]` | Every action's timing (count, median, p90, min, max, failures) from `<store>/metrics.sqlite` — SandboxLab's schema. |
| `snooze doctor` · `snooze events [NAME]` | Checks · follow the host's phases, steps and notes. |
| `snooze ui [--open\|--print-url]` · `snooze ui link` | 590: a local web dashboard of the whole store — sandboxes, sessions, restore points, network policy and log, keys and accounts (fingerprints only), images, metrics, doctor, live activity. **Read-only** (phase 1). Loopback only, on a port the OS picks; the browser signs in with a one-use, five-minute link (opened for you, or printed on the terminal with `--print-url`); `ui link` mints another for the running UI. A client of the host like every command; one UI per store; Ctrl-C stops it. |
| `snooze host [--foreground] [--idle-timeout MIN]` · `host stop` · `host status` | The host (normally started for you) · Deep Sleep everything and stop it · is one running (never starts one). |

Every command takes `--json` (machine-readable output on stdout; errors as `{"error":{"code","message"}}`),
`--store DIR` (default `$SNOOZE_STORE`, else `~/Library/Application Support/SnoozeContainerKit`),
`-v` (every progress step; by default only an operation slower than a second shows its steps, on
stderr) and `-q`. JSON documents only ever gain fields. Phases on the wire are `off`, `booting`,
`running`, `paused`, `asleep`, `deepAsleep`, `failed`.

**Exit codes:** 0 ok · 1 failed · 2 not found · 3 not possible in this phase · 4 already exists ·
5 not confirmed · 6 host unavailable · 7 not implemented yet · 64 usage. `exec`, `run` and
`attach` exit with the program's own code, and 125 when snooze itself fails.

**Environment:** `SNOOZE_STORE`; `SNOOZE_HOST_IDLE` (minutes, the host's idle timeout; default 5, 0 =
never); `SNOOZE_KERNEL_CACHE` / `SNOOZE_KERNEL` (a shared kernel cache / an explicit kernel, as for
the library's tests); `SNOOZE_SUBNET` (the default subnet of a `--network nat` sandbox). They are
read when a sandbox is created (the kernel and subnet are then part of its spec).

### The host

A running VM lives in the process that started it, so one process per user and store owns them
all: **`snooze host`** (owner ruling, 585: a lazy per-user host). It owns every running VM, each
proxied sandbox's egress proxy (its policy, connection log and credential vault), the metrics
writer, and the shared event-loop group (583), and serves `<store>/host.sock`. Every command is a
thin client of that socket.

- **Lazy.** The first command that needs it starts it as a **detached child** — its own session
  (`setsid`), stdin `/dev/null`, output appended to `<store>/host.log`, none of the caller's other
  file descriptors. No launchd agent: nothing is installed in `~/Library/LaunchAgents`. It holds
  `<store>/host.lock` (flock) for its whole life, so there is never a second host for a store, and a
  new one waits for an exiting one to finish before it loads anything.
- **Idle exit.** It exits once no sandbox has a VM (booting, running, paused or asleep) and no
  client is connected, for `--idle-timeout` minutes (default 5; `$SNOOZE_HOST_IDLE`). Read-only
  commands — `ls`, `inspect`, `point ls`, `image ls`, `net policy` (shown), `key ls` — answer from the
  store in-process when no host runs, so **no daemon runs when no sandbox is running**, and looking
  never starts one.
- **Quit = Deep Sleep.** `snooze host stop`, SIGTERM and SIGINT deep-sleep every running, paused or
  sleeping sandbox (the library's `prepareForExit`, with its settle delay) and then exit. The next
  command starts a new host; `wake` (or `attach`, `up`, `exec`) brings each back, sessions and pids
  intact.
- **Crash.** After `kill -9` (or a crash) the next command starts a new host, which, for each
  sandbox: **asleep** (its VM died with the host, the snapshot is on disk) → restored and put back to
  sleep, sessions intact; **deep asleep** → nothing to do, `wake` adopts it in the new process;
  **running** → reported as died (`ls` shows it; `inspect` has `diedWithHost`), its disk — never
  unmounted, and the ext4 has no journal — marked for e2fsck at the next start. A read-only command
  that finds such a record starts the host so it can recover.
- **The protocol** (`Sources/SnoozeHost/HostProtocol.swift`) is JSON lines: one request line
  (`{"v":1,"op":"deep-sleep","name":"myproj"}`), then zero or more `{"event":…}` progress lines and one
  final `{"ok":true,"result":…}` / `{"ok":false,"error":{"code","message"}}`. `attach` switches to raw
  after its `ok` line (`{"state":"attached"|"held"}`): VT bytes from the host; keystrokes plus in-band
  `0xFF 'H'|'R' cols rows` frames from the client (SandboxLab's attach wire); the end of a session is
  a notice carrying `ESC ] 777;snooze;ended;<code> BEL`. `events` and `net-log --follow` stream event
  lines. Fields are only ever added; a host answers a newer `v` with `error.code = "version"`.

## Dependencies

| Package | Pin | Why |
|---|---|---|
| apple/containerization | **exact** 0.47.0 | the VM runtime; the sleep design leans on its internals' shape |
| apple/swift-nio (NIOCore, NIOEmbedded, NIOPosix; 590: NIOHTTP1) | from 2.103.0 | 580: drives TLS synchronously on the proxy's connection threads (`EmbeddedChannel`); 583: one shared `MultiThreadedEventLoopGroup` for every VM's vminitd clients; 590: `snooze ui`'s HTTP/1.1 server (`NIOHTTP1` is a module of the same package — no new dependency; imported only by `Sources/SnoozeWeb`, which the audit enforces) |
| apple/swift-nio-ssl (NIOSSL) | from 2.37.5 | 580: terminates and re-originates TLS for bound hosts with **in-memory** keys — Network.framework and Secure Transport need a `SecIdentity`, i.e. a keychain (prompts for an ad-hoc-signed app, and a leaf key per host on disk) |
| apple/swift-certificates (X509), apple/swift-asn1 | from 1.21.0 / 1.7.3 | 580: issues the per-sandbox CA and its per-host leaves |

| apple/swift-argument-parser (ArgumentParser) | from 1.5.0 (resolved 1.8.2) | 585: the `snooze` CLI's subcommands, aliases, options and `--help`. Imported ONLY by the CLI's command targets (`Sources/SnoozeCLI`, `Sources/snooze`) — never by the library or the host; the audit enforces it. Hand-rolling a parser for ~40 subcommands with aliases and `--` passthrough would be more code to get wrong than this Apple package. |

All five are apple/* packages that containerization 0.47.0 already resolves, so declaring them
changed nothing in `Package.resolved`. The CLI's host also uses the system `SQLite3` module for its
metrics (no package). Upstream certificates are verified with the
Mac's own trust store (Security.framework, `SecTrustEvaluateWithError`). `Scripts/audit.sh` holds
the import and dependency allowlists.

## Consuming

```swift
dependencies: [
    .package(url: "https://github.com/johnoscott/SnoozeContainerKit.git", from: "0.1.0"),
],
targets: [
    .target(name: "YourTarget", dependencies: [
        .product(name: "SnoozeContainerKit", package: "SnoozeContainerKit"),
    ]),
]
```

The package identity SwiftPM derives is the lowercased last URL component — which must stay
`SnoozeContainerKit`.

> **Prelaunch note.** Until this repo is unveiled publicly, the URL above is not yet reachable.
> Consumers keep the public URL in their manifest and redirect it with a SwiftPM mirror supplied
> only in remote mode (`--config-path Scripts/swiftpm-remote-config` in the consuming app).
> SwiftPM derives identity from the original URL, not the mirror, so the mirror entry is simply
> deleted at unveil. It must **not** live at `.swiftpm/configuration/mirrors.json` — a mirror there
> applies in every mode and rewrites package identity, which breaks path-dependency (local) mode.

**Resources in an app bundle:** copy `SnoozeContainerKit_SnoozeContainerKit.bundle` from the build
directory into `Contents/Resources`. The library finds `deckhold` there (or beside the executable,
or at `$SNOOZE_DECKHOLD`) and never uses SwiftPM's trapping `Bundle.module` accessor.

## Storage / identity is configured by the host, not by this package

This package owns no brand and no directory name: the host passes `storeRoot`. Nothing in
`Sources/` may hardcode a consumer's bundle id, product name, or storage directory —
`Scripts/audit.sh` fails the build if one appears.

## Development

```bash
make build            # swift build (with the build-system pin Xcode 27 needs)
make test             # unit tests — no VM (runs make web-assets-check first)
make web-assets       # 590: rebuild snooze ui's content-hashed assets from Sources/SnoozeWeb/WebSource (commit them)
make web-assets-check # 590: fail when the committed web assets are not exactly what WebSource/ builds
make test-vm          # the VM integration suite: lifecycle, crash restore, restore points (entitled test host)
make test-vm-agents   # the claude-code and pi images: bake/cache, start, sessions, sleep → wake, state disk
make kernel           # fetch + verify the pinned kernel into the cache (KERNEL_CACHE=dir), no VM
make audit            # import allowlist, one exact dependency, no host brand, deckhold == PROVENANCE
make deckhold         # rebuild the guest binary (pinned Zig + ghostty; first run ~3.5 min)
make deckhold-verify  # rebuild from scratch and check the committed bytes match
make test-vm-network  # 580: a proxied (no-NIC) sandbox end to end, then a bake under the bake preset
make test-vm-lineage  # 587: warm-base bakes, journal / discard / sync, accounting, reclaim, rederive, then a
                      #      sandbox deep-slept by v0.4.0 (its test host built once from the tag) — LINEAGE=part for one
make snoozenet        # rebuild the snoozenet guest binary (pinned Zig; no ghostty) + refresh PROVENANCE.md
make snoozenet-verify # rebuild snoozenet and check the committed bytes match
make cli              # 585: build .build/debug/snooze and sign it with the virtualization entitlement
make install-cli      # release build, signed, into PREFIX (default ~/.local): bin/snooze → libexec/snooze/
make test-cli         # 585: the signed snooze driven from separate processes against a scratch store
make test-vm-claude   # 588: the credential proxy's classifier, strict, a placeholder across a host restart — a fake key (SNOOZE_TEST_CLAUDE_LOGIN=1: + this Mac's login)
                      #      (up/exec/run/attach, lifecycle, points, two sandboxes, kill -9 the host, idle exit)
```

## Contributing

This package was productised from a probe with its harness app (SandboxLab) built alongside it,
so a change usually arrives already exercised. Issues and fixes are welcome directly — a bug
report, a reproduction, a fix, a documentation correction. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Licence

MIT (see [`LICENSE`](LICENSE)); third-party licences, including what is statically linked into
the guest binary, are inventoried in [`LICENCES.md`](LICENCES.md).
