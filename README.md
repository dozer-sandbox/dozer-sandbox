# DozerKit

**Dozer Sandbox — fast, suspendable micro-VMs for your Mac.** DozerKit is its library, and `doz`
its command-line tool.

DozerKit is a pausable Linux sandbox for macOS: one Linux container in its own VM,
built on Apple's [Containerization](https://github.com/apple/containerization) framework, that
pauses in about a millisecond, sleeps to disk to give its RAM back, wakes in about a third of a
second, and restores into a new process after the host app crashes — with terminal sessions that
survive every one of those.

**macOS 26+ only**, Apple silicon. It is built on Virtualization.framework and vmnet, which have no
Linux equivalent, so there is no Linux build and no Linux CI job. The VM needs the
`com.apple.security.virtualization` entitlement on whatever binary hosts it.

## Products

| Product | What it is |
|---|---|
| `DozerKit` | `Sandbox` (the actor that owns one VM and its lifecycle), `SandboxSpec`, `SessionConnection` (one viewer's connection to a guest terminal session), the `deckhold` wire protocol, and the committed `deckhold` guest binary as a resource. |
| `doz` (executable, 585) | The command-line tool: create, start, pause, sleep, hibernate and wake sandboxes, attach to their sessions, restore points, network policy, metrics — see [The `doz` CLI](#the-doz-cli). Built on the library; the library does not depend on it. |

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
import DozerKit

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
    case .detached(.sandboxSleeping): break        // attach again after wake()
    case .detached: break
    }
}}
conn.send(Data("ls\r".utf8)); conn.resize(TermSize(cols: 100, rows: 30))

try await sandbox.hibernate()                      // RAM freed; the session keeps its state
try await sandbox.wake()
// …a later process, after a crash or quit while asleep:
if Sandbox.restorableState(for: spec) != nil { try await sandbox.restoreAfterCrash() }
```

Lifecycle: `start` · `pause` / `resume` · `sleep` (pause + snapshot) · `hibernate` · `wake`
· `stop` · `restoreAfterCrash` · `prepareForExit` (keep a sleeping sandbox restorable, stop anything
else; 583: a program a session started less than `settle` — 3 s — ago gets the rest of it first) · `resetToImage` · `delete`. **Stop keeps the root disk**: the next Start cold-boots the same
disk (what you installed is still there); Reset to image starts again from a fresh clone of the
prepared disk; Delete removes everything the sandbox has on disk. A disk that was not cleanly
unmounted — `Sandbox.discardRestorableState(for:)` (a hibernated VM is stopped without unmounting it),
a failed restore, a crash while running — is replayed from its **journal** on the next cold boot, or,
on a journal-less disk, checked with `e2fsck` first (583; see **Journal** below). Hibernate and Stop
`sync` the guest first, so a discarded hibernation loses nothing written before it. Guest: `exec(argv)`
(no shell unless you pass one), `sessions()` (`deckhold ls`), `screenText(name)` (`deckhold dump`),
`bootConsole()`.

**Images** (`ImageSpec`, `ImageBaker`, `AgentImages.claudeCode` / `.pi`): no layered images and
no Dockerfile — a digest-pinned OCI base is flattened to one ext4 **base disk** once, every bake
starts from an APFS clone of it, the install steps run inside a VM booted from that clone, a
credential-free check verifies the result, `fstrim /` runs last, and the disk is kept read-only in
the store, keyed by image spec + kernel + deckhold. A sandbox with `spec.imageSpec` APFS-clones it as its
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

**Journal (587): on by default, 16 MiB — a toggle.** `ImageSpec.journalMiB` (the image's root and
every sandbox's state disk) and `SandboxSpec.journalMiB` (the lab's prepared disk): default 16, `nil`
= no journal. 586/587 measured it: after Hibernate → discard, a journaled disk cold-boots by
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
disk; otherwise allocated − the guest's `df` recorded at the last Stop / Hibernate,
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
guest page it has ever touched, and restoring a snapshot touches them all: woken from hibernation, a
1 GiB Lab held **1,273 MiB** (cold-booted: 213) and a 2 GiB claude-code **2,340 MiB** (cold: 645).
Every VM now has a virtio memory balloon, and `wake()` inflates it over the guest's free pages,
leaving the guest `defaultFreeReserveMiB` free (¼ of the allocation, ≥ 256 MiB): woken, the Lab holds
**~585 MiB** and claude-code **~1,310 MiB** (−54% / −44%), for **+25–40 ms** of wake. The balloon
stays inflated (deflating would charge the pages again); the guest's page cache and processes are
untouched, and a guest that needs more still gets it (VZ deflates on guest OOM — a 512 MiB
allocation above the reserve took ~0.35–0.5 s instead of ~0.12 s). `returnFreeMemory(keepingFreeMiB:)`
does it on demand (e.g. after heavy work: −130–160 MiB after a 300 MiB turn), `restoreGuestMemory()`
gives the guest everything back, `setReturnsFreeMemoryOnWake(false)` turns the wake's off, and
`memoryReturnedMiB` reads it. Sleep and Hibernate deflate first (+~80–150 ms): a snapshot of an
inflated balloon does not restore. A sandbox hibernated by an older build wakes without a balloon
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
program cannot trap). The wire protocol and the snapshot image spec are documented in
[`Guest/deckhold/deckhold.c`](Guest/deckhold/deckhold.c).

**NAT subnets (583).** A `.nat` sandbox whose spec names no `subnet` gets a free vmnet /24 of its
own from 192.168.100–199.0/24 — never one a network interface of the Mac is already on (the LAN, a
VPN, another process's vmnet bridge), never one this process holds — instead of vmnet's default,
which two processes could both take (the NAT then silently drops one). `SandboxSpec.subnet` stays an
override; a restore keeps the subnet its guest was addressed from. Proxied sandboxes have no NIC.

**Network (580): proxied sandboxes.** `SandboxSpec(…, network: .proxied(.agent))` boots a VM with
**no network interface** — only `lo`. The guest's only way out is `doznet` (a small static guest
binary, `Guest/doznet/`) relaying over vsock to `sandbox.egress`, an `EgressProxy` running in
the host process, where root in the guest cannot reach:

```swift
var spec = SandboxSpec(name: "agent", storeRoot: root, imageSpec: AgentImages.claudeCode,
                       network: .proxied(.agent))        // .locked · .bake · .agent · .open, or your own
let sandbox = try Sandbox(spec: spec)
sandbox.setCredential(.anthropic, secret: key)          // memory only; the guest gets doz_cred_… placeholders
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
  (Anthropic's API and sign-in hosts, Claude Code's updates and error reporting, pi's updates,
  GitHub over HTTPS + registries), `open` (everything, still proxied and logged).
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

## The `doz` CLI

```bash
export HOMEBREW_GITHUB_API_TOKEN=$(gh auth token)      # while the repositories are private
brew tap johnoscott/dozer git@github.com:johnoscott/homebrew-dozer-prelaunch.git
brew install doz                    # the prebuilt release, signed with the virtualization entitlement — seconds
doz onboard                         # once: checks, the Claude account, settings, images prepared in the background
cd ~/code/myproj && doz init        # this folder is a project: doz_project.yaml
doz up                              # create → boot → attach to Claude Code, the folder at /workspace
```

Homebrew installs `libexec/doz/{doz, VERSION, its resource bundles}` in the keg and links `bin/doz`
(Apple silicon, macOS 26+); `brew upgrade doz` is safe with a host running. The tap
(`johnoscott/homebrew-dozer-prelaunch`) is private until the unveil, so it is tapped by URL and the
release downloaded with `HOMEBREW_GITHUB_API_TOKEN`. From a checkout, contributors use `make
install-cli` (below) — and `make release VERSION=X.Y.Z` builds the artefact the tap installs.

New to it: the [walkthrough](docs/CLI-WALKTHROUGH.md) (~25 min, from nothing installed to
uninstalling again) and the [user guide](docs/CLI-USER-GUIDE.md) (concepts, every command by task,
keys, network, troubleshooting). `doz ui` opens on a setup wizard when this Mac was never onboarded.

`make cli` builds and signs `.build/debug/doz` for development. An unsigned `doz` runs every
command but cannot boot a VM (`doz doctor` says so).

### Commands (the owner's vocabulary; aliases in brackets)

| | |
|---|---|
| `doz onboard [--images …\|--all-images\|--no-images] [--account mac\|api-key\|setup-token\|later] [--secret-stdin] [--yes]` · `--status` · `--cancel` | 594: set up this Mac, once — the doctor's checks (required ones stop it), the Claude account (the Mac's login; an API key or setup token pasted at a hidden prompt and stored exactly as `doz account add` stores it; or Decide later — never a login), `doz.toml` + `agent-prompt.md` (only when missing), and the images prepared **in the host** (kernel, guest init, base pull, bake) with the progress view: Ctrl-C detaches, `--status` re-attaches, `--cancel` cancels. A start of an image being prepared joins that preparation. Asks on a terminal; `--yes`/`--json`/no terminal never ask. |
| `doz init [DIR]` · `doz up` (no name) | 594: `doz_project.yaml` (YAML, closed schema: name, image, cpus, memory, network, account, sessions, agent_prompt); `up` in that folder creates/starts/wakes that sandbox with the folder at `/workspace` and starts its sessions. |
| `doz uninstall [--keep-store] [--keep-config] [--yes]` | 594: lists exactly what goes (the store, the settings, the installed doz) and asks once; never the keychain or Claude Code's files. 598: a Homebrew `doz` is left to `brew uninstall doz`, which it names. |
| `doz create NAME --image lab\|claude-code\|pi\|<custom> [--cpus N] [--memory 2G] [--workspace DIR \| --isolated] [--network agent\|bake\|locked\|open\|nat\|none] [--subnet CIDR] [--agent-prompt FILE]` | Make a sandbox (off until started). `lab` is Alpine + bash (1 GiB); the agent images get 2 GiB. The workspace is shared at `/workspace`, made when it does not exist (594); without one the sandbox is **isolated** — `/workspace` is private to the VM, said by `create`, `ls` and the agent's prompt. The network defaults to **proxied** — no network interface, every connection judged by the Mac's policy and logged: `agent` for an agent image, `bake` (package registries only) for the lab. |
| `doz up NAME [create options] [--session S] [-d] [-- CMD…]` | Create if missing → start or wake → attach to the image's session (`claude`, `pi`, or a `bash -l` shell), opening it if it is not running (`vagrant up` / `compose up`). |
| `doz inspect NAME --prompt` | 594: the agent's environment prompt as its next session gets it — a short facts block (the VM, `/workspace` shared or not, the proxied network, injected credentials) appended to its system prompt, plus the `dozer` skill; rendered at every session start; your `agent-prompt.md` and the sandbox's own layer; `agent.prompt = false` turns it off. |
| `doz start NAME` [`cold-boot`] | Boot — or wake it if it is asleep, resume it if paused. |
| `doz pause NAME` [`suspend`] · `doz resume NAME` | Guest CPU to 0 in ~1 ms, RAM kept. |
| `doz sleep NAME` | Pause + snapshot to disk: RAM kept, and it survives a host crash. |
| `doz hibernate NAME` · `doz wake NAME` | Snapshot + VM stopped: RAM returned. Wake ~0.3 s, sessions and pids where they were. A program started less than 3 s ago gets the rest of that time first (583). |
| `doz shutdown NAME` · `doz reset NAME` · `doz rm NAME` | Cold stop keeping the disk · discard the disk (back to the image) · remove everything. Each asks first on the terminal; `--yes` skips; with no terminal and no `--yes` they refuse (exit 5). |
| `doz ls` · `doz inspect NAME` · `doz sessions NAME [--screen S [--vt]]` | Name, image, phase, RAM held (the allocation less what the balloon returned; 0 hibernated or off), disk, sessions, network · everything as JSON · the guest's terminal sessions — while it is paused, asleep or hibernated, from their saved screens (593: saved at pause, sleep, hibernate and every `host.screen_capture_minutes`; shutdown, reset and rm delete them — a shut-down sandbox has no sessions); `--screen` prints one (text; `--vt` the bytes, to a file or pipe). |
| `doz attach NAME [SESSION] [--no-wake]` | A raw-tty client of a guest session. **Ctrl-]** detaches (`--detach-key ctrl-x\|none`); the session keeps running. Hibernating disconnects you and the client waits, then reattaches by itself when the sandbox runs again. A paused or sleeping sandbox is woken first unless `--no-wake`. |
| `doz run NAME [--session S] [-d] -- CMD…` | A NEW session running CMD (no shell in front — say `bash -lc '…'` for one), attached; exits with the program's exit code. |
| `doz exec NAME [--user U] [--workdir D] [-e K=V] [--timeout S] -- CMD…` | One-shot and non-interactive: stdout, stderr and the exit code pass through. Runs like a session (an agent image's user in `/workspace`). |
| `doz image ls\|bake NAME\|rm NAME` | The built-in images and templates; bake now rather than at the first start; `ls --tree`: the lineage with each disk's size, shared and own bytes. `pull`/`push` answer "not yet" (584.B2). 594: an agent image installs the **latest** Claude Code / pi by default (`images.claude_code_version`, `images.pi_version` = `latest` or an exact version), resolved from the npm registry when the image is prepared and installed at that exact version, integrity-checked; a newer one is prepared in the background — `ls` says `claude-code 2.1.227 (2.1.285 available — preparing)`. |
| `doz resources [--json]` · `resources rm ID… [--dry-run] [--yes]` · `resources clean [--dry-run] [--yes]` · `resources kernel kernel:V\|pinned` | 595: everything Dozer uses — every byte of the store on a row (size, freed if deleted, used by; the total is `du`'s and an **unattributed** row shows what no row explains, ~0), the memory each sandbox with a VM, the host and the UI hold, CPUs, each sandbox's proxy traffic, the kernels. `rm` / `clean` show the plan (each item, what it frees, what it costs later, what is refused and why), ask once, and delete as one host operation serialised with the lifecycle. `clean` is the safe set (re-creatable AND unused; never templates, sandboxes, restore points, settings or keys). `kernel` picks the kernel NEW sandboxes boot. The web UI's **Resources** page is the same. |
| `doz template create NAME --as T [--from-point P]` · `template ls\|rm` | 593: a sandbox's ROOT disk as an image (never its state disk: logins and history). |
| `doz duplicate NAME NEW [--workspace DIR \| --isolated] [--cpus N] [--memory M] [--network …] [--account A] [--from-point P] [--copy-state]` | 593: a new sandbox from an existing one's disk (APFS clone); a fresh state disk unless `--copy-state`. |
| `doz point take\|ls\|revert\|fork\|rm\|save-image NAME …` | Restore points (disk-only APFS clones): `take NAME [POINT]`, `revert NAME POINT` (shuts down; a "before revert" point is taken first), `fork NAME POINT NEW`, `save-image NAME [POINT] --as IMAGE`. A point is named by its name or id. |
| `doz net policy NAME [--preset P] [--allow HOST…] [--deny HOST…] [--remove HOST…]` · `doz net log NAME [--denied] [--follow]` | A proxied sandbox's policy, changed live and kept for the next start · its connection log (metadata only). |
| `doz key set NAME --anthropic [--keychain SERVICE]` · `key set NAME --claude-login` · `key rm` · `key ls` | The key is read from stdin (or a no-echo prompt, or a keychain generic password) — **never an argument** — and held by the host's proxy in memory; the guest's `ANTHROPIC_API_KEY` is a placeholder. A key from stdin lasts while the host runs; one from the keychain is read again when a new host loads the sandbox. `--claude-login` = `account use NAME mac`. `key ls` shows the account, state, expiry, policy and the fingerprints of credentials the guest brought itself. |
| `doz account ls\|add\|verify\|rm\|default\|use\|keepalive` · `create --account NAME` | 588: Anthropic accounts the host holds — `mac` (built in: this Mac's own Claude Code login, read-only, renewed by the Mac's Claude Code), `setup-token` (`claude setup-token`, 1 year, in the keychain as `doz-claude:NAME`), `api-key`. A proxied sandbox follows the store's default (`mac`) or pins one; the guest sees a placeholder plus the plan (`CLAUDE_CODE_SUBSCRIPTION_TYPE`), so Claude Code shows "Claude Max" and defaults to Opus. No silent fallback. `keepalive on` (off by default) runs the Mac's own `claude -p` near expiry while a sandbox uses the login. |
| `doz key policy NAME allow\|strict\|auto` | 588: a credential the guest brings itself (a guest `/login`, a pasted key) — allow and flag it (fingerprint in `net log`, `ls`, `key ls`, events), or refuse it with an explanation and deny the sign-in hosts. `auto`: strict for a non-`mac` account. |
| `doz metrics [--csv] [--image X] [--days N] [--no-steps]` | Every action's timing (count, median, p90, min, max, failures) from `<store>/metrics.sqlite` — SandboxLab's schema. |
| `doz doctor` · `doz events [NAME]` | Checks · follow the host's phases, steps and notes. |
| `doz console NAME [--follow]` · `--list` · `--steps [--boot N]` | The boot console (kernel + init), or follow it as the sandbox boots · 593: the kept boots (the last `host.boot_logs_kept`, 5: each start, wake, restore) · a boot's steps as the boot view showed them, then its console (1 = the latest). The web UI's **Boot log** shows the same. |
| `doz ui [--open\|--print-url]` · `doz ui link` | 590: a local web UI of the whole store — sandboxes, sessions, restore points, network policy and log, keys and accounts (fingerprints only), images, metrics (filters, CSV), doctor, live activity — and its actions: create and the whole lifecycle, sessions (open, run detached), Open in Terminal (Terminal.app), restore points (take, revert, fork, delete, save as image), policy edits with a preview, key policy, account use/default/verify/remove/keep-alive, image bake/remove. Destructive actions need the name typed; an action never carries a secret — an account's key or setup token, and a sandbox's own key, each have a masked field and a route of their own while `ui.allow_secret_entry` (594, default on; stored as `doz account add` / `doz key set` store them). Loopback only, on a port the OS picks; the browser signs in with a one-use, five-minute link (opened for you, or printed on the terminal with `--print-url`); `ui link` mints another for the running UI. A client of the host like every command; one UI per store; Ctrl-C stops it. |
| `doz host [--foreground] [--idle-timeout MIN]` · `host stop` · `host status` · `host upgrade-check` | The host (normally started for you) · hibernate everything and stop it · is one running (never starts one) · 598: after an upgrade, is a host of an older build still running (Homebrew's post-install runs it; never starts or stops one, always exits 0). |

Every command takes `--json` (machine-readable output on stdout; errors as `{"error":{"code","message"}}`),
`--store DIR` (default `$DOZ_STORE`, else the settings' `store.path`, else `~/Library/Application Support/dozer-sandbox`),
`-v` (every progress step; by default only an operation slower than a second shows its steps, on
stderr) and `-q`. JSON documents only ever gain fields. Phases on the wire are `off`, `booting`,
`running`, `paused`, `asleep`, `hibernated`, `failed`.

**Exit codes:** 0 ok · 1 failed · 2 not found · 3 not possible in this phase · 4 already exists ·
5 not confirmed · 6 host unavailable · 7 not implemented yet · 64 usage. `exec`, `run` and
`attach` exit with the program's own code, and 125 when doz itself fails.

**Environment:** `DOZ_STORE`; `DOZ_HOST_IDLE` (minutes, the host's idle timeout; default 5, 0 =
never); `DOZ_KERNEL_CACHE` / `DOZ_KERNEL` (a shared kernel cache / an explicit kernel, as for
the library's tests); `DOZ_SUBNET` (the default subnet of a `--network nat` sandbox). They are
read when a sandbox is created (the kernel and subnet are then part of its spec).

**Settings (591):** `${XDG_CONFIG_HOME:-~/.config}/dozer-sandbox/doz.toml` — every setting listed
with its default commented out; `doz config show|get|set|unset|init|path`, and the web UI's
Settings page. Precedence: a flag, then the environment variable above, then the file, then the
default (`doz config show` names each value's source). The docs: `docs/CLI-USER-GUIDE.md`
"Settings".

### The host

A running VM lives in the process that started it, so one process per user and store owns them
all: **`doz host`** (owner ruling, 585: a lazy per-user host). It owns every running VM, each
proxied sandbox's egress proxy (its policy, connection log and credential vault), the metrics
writer, and the shared event-loop group (583), and serves `<store>/host.sock`. Every command is a
thin client of that socket.

- **Lazy.** The first command that needs it starts it **fully detached** — through an intermediate
  that exits, so its parent is launchd and it is in no caller's process tree (stopping a client, its
  group or its tree never stops the host — 593), its own session (`setsid`), stdin `/dev/null`,
  output appended to `<store>/host.log`, none of the caller's other file descriptors. `doz doctor`
  shows its parent. No launchd agent: nothing is installed in `~/Library/LaunchAgents`. It holds
  `<store>/host.lock` (flock) for its whole life, so there is never a second host for a store, and a
  new one waits for an exiting one to finish before it loads anything.
- **Idle exit.** It exits once no sandbox has a VM (booting, running, paused or asleep) and no
  client is connected, for `--idle-timeout` minutes (default 5; `$DOZ_HOST_IDLE`). Read-only
  commands — `ls`, `inspect`, `point ls`, `image ls`, `net policy` (shown), `key ls` — answer from the
  store in-process when no host runs, so **no daemon runs when no sandbox is running**, and looking
  never starts one.
- **Quit = Hibernate.** `doz host stop`, SIGTERM and SIGINT hibernate every running, paused or
  sleeping sandbox (the library's `prepareForExit`, with its settle delay) and then exit. The next
  command starts a new host; `wake` (or `attach`, `up`, `exec`) brings each back, sessions and pids
  intact.
- **Crash.** After `kill -9` (or a crash) the next command starts a new host, which, for each
  sandbox: **asleep** (its VM died with the host, the snapshot is on disk) → restored and put back to
  sleep, sessions intact; **hibernated** → nothing to do, `wake` adopts it in the new process;
  **running** → reported as died (`ls` shows it; `inspect` has `diedWithHost`), its disk — never
  unmounted, and the ext4 has no journal — marked for e2fsck at the next start. A read-only command
  that finds such a record starts the host so it can recover.
- **The protocol** (`Sources/DozerHost/HostProtocol.swift`) is JSON lines: one request line
  (`{"v":1,"op":"hibernate","name":"myproj"}`), then zero or more `{"event":…}` progress lines and one
  final `{"ok":true,"result":…}` / `{"ok":false,"error":{"code","message"}}`. `attach` switches to raw
  after its `ok` line (`{"state":"attached"|"held"}`): VT bytes from the host; keystrokes plus in-band
  `0xFF 'H'|'R' cols rows` frames from the client (SandboxLab's attach wire); the end of a session is
  a notice carrying `ESC ] 777;doz;ended;<code> BEL`. `events` and `net-log --follow` stream event
  lines. Fields are only ever added; a host answers a newer `v` with `error.code = "version"`.

## Dependencies

| Package | Pin | Why |
|---|---|---|
| apple/containerization | **exact** 0.47.0 | the VM runtime; the sleep design leans on its internals' shape |
| apple/swift-nio (NIOCore, NIOEmbedded, NIOPosix; 590: NIOHTTP1) | from 2.103.0 | 580: drives TLS synchronously on the proxy's connection threads (`EmbeddedChannel`); 583: one shared `MultiThreadedEventLoopGroup` for every VM's vminitd clients; 590: `doz ui`'s HTTP/1.1 server (`NIOHTTP1` is a module of the same package — no new dependency; imported only by `Sources/DozerWeb`, which the audit enforces) |
| apple/swift-nio-ssl (NIOSSL) | from 2.37.5 | 580: terminates and re-originates TLS for bound hosts with **in-memory** keys — Network.framework and Secure Transport need a `SecIdentity`, i.e. a keychain (prompts for an ad-hoc-signed app, and a leaf key per host on disk) |
| apple/swift-certificates (X509), apple/swift-asn1 | from 1.21.0 / 1.7.3 | 580: issues the per-sandbox CA and its per-host leaves |
| apple/swift-argument-parser (ArgumentParser) | from 1.5.0 (resolved 1.8.2) | 585: the `doz` CLI's subcommands, aliases, options and `--help`. Imported ONLY by the CLI's command targets (`Sources/DozerCLI`, `Sources/doz`) — never by the library or the host; the audit enforces it. Hand-rolling a parser for ~40 subcommands with aliases and `--` passthrough would be more code to get wrong than this Apple package. |

| jpsim/Yams (Yams) | **exact** 6.2.2 | 594 (owner ruling D9): the project file `doz_project.yaml` is YAML, like dbt's `dbt_project.yml`. Yams (MIT, libyaml inside) is the standard Swift YAML library; pinned exactly and imported ONLY by `Sources/DozerCLI` (the audit enforces both). The project file's schema is closed and checked by hand on Yams's node tree; anchors/aliases and multiple documents are refused. |

The five apple/* packages are ones containerization 0.47.0 already resolves, so declaring them
changed nothing in `Package.resolved`; Yams is the one package that is not. The CLI's host also uses the system `SQLite3` module for its
metrics (no package). Upstream certificates are verified with the
Mac's own trust store (Security.framework, `SecTrustEvaluateWithError`). `Scripts/audit.sh` holds
the import and dependency allowlists.

## Consuming

```swift
dependencies: [
    .package(url: "https://github.com/johnoscott/DozerKit.git", from: "0.1.0"),
],
targets: [
    .target(name: "YourTarget", dependencies: [
        .product(name: "DozerKit", package: "DozerKit"),
    ]),
]
```

The package identity SwiftPM derives is the lowercased last URL component — which must stay
`DozerKit`.

> **Prelaunch note.** Until this repo is unveiled publicly, the URL above is not yet reachable.
> Consumers keep the public URL in their manifest and redirect it with a SwiftPM mirror supplied
> only in remote mode (`--config-path Scripts/swiftpm-remote-config` in the consuming app).
> SwiftPM derives identity from the original URL, not the mirror, so the mirror entry is simply
> deleted at unveil. It must **not** live at `.swiftpm/configuration/mirrors.json` — a mirror there
> applies in every mode and rewrites package identity, which breaks path-dependency (local) mode.

**Resources in an app bundle:** copy `DozerKit_DozerKit.bundle` from the build
directory into `Contents/Resources`. The library finds `deckhold` there (or beside the executable,
or at `$DOZ_DECKHOLD`) and never uses SwiftPM's trapping `Bundle.module` accessor.

## Storage / identity is configured by the host, not by this package

This package owns no brand and no directory name: the host passes `storeRoot`. Nothing in
`Sources/` may hardcode a consumer's bundle id, product name, or storage directory —
`Scripts/audit.sh` fails the build if one appears.

## Development

```bash
make build            # swift build (with the build-system pin Xcode 27 needs)
make test             # unit tests — no VM (runs make web-assets-check first)
make web-assets       # 590: rebuild doz ui's content-hashed assets from Sources/DozerWeb/WebSource (commit them)
make web-assets-check # 590: fail when the committed web assets are not exactly what WebSource/ builds
make test-vm          # the VM integration suite: lifecycle, crash restore, restore points (entitled test host)
make test-vm-agents   # the claude-code and pi images: bake/cache, start, sessions, sleep → wake, state disk
make kernel           # fetch + verify the pinned kernel into the cache (KERNEL_CACHE=dir), no VM
make audit            # import allowlist, one exact dependency, no host brand, deckhold == PROVENANCE
make deckhold         # rebuild the guest binary (pinned Zig + ghostty; first run ~3.5 min)
make deckhold-verify  # rebuild from scratch and check the committed bytes match
make test-vm-network  # 580: a proxied (no-NIC) sandbox end to end, then a bake under the bake preset
make test-vm-lineage  # 587: warm-base bakes, journal / discard / sync, accounting, reclaim, rederive, children
                      #      — LINEAGE=part for one
make doznet        # rebuild the doznet guest binary (pinned Zig; no ghostty) + refresh PROVENANCE.md
make doznet-verify # rebuild doznet and check the committed bytes match
make cli              # 585: build .build/debug/doz and sign it with the virtualization entitlement
make install-cli      # release build, signed, into PREFIX (default ~/.local): bin/doz → libexec/doz/
make release VERSION=X.Y.Z  # 598: dist/doz-X.Y.Z-macos-arm64.tar.gz + .sha256 — what the GitHub Release carries and
                      #      Homebrew installs; Developer ID + notarised via Makefile.config, else ad hoc; DRY_RUN=1
make test-cli         # 585: the signed doz driven from separate processes against a scratch store
make test-vm-claude   # 588: the credential proxy's classifier, strict, a placeholder across a host restart — a fake key (DOZ_TEST_CLAUDE_LOGIN=1: + this Mac's login)
                      #      (up/exec/run/attach, lifecycle, points, two sandboxes, kill -9 the host, idle exit)
```

## Contributing

This package was productised from a probe with its harness app (SandboxLab) built alongside it,
so a change usually arrives already exercised. Issues and fixes are welcome directly — a bug
report, a reproduction, a fix, a documentation correction. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Licence

MIT (see [`LICENSE`](LICENSE)); third-party licences, including what is statically linked into
the guest binary, are inventoried in [`LICENCES.md`](LICENCES.md).
