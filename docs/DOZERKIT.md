# DozerKit — the engine, for developers

The `doz` program is built on **DozerKit**, a Swift package in this repository: a pausable Linux sandbox for
macOS — one Linux container in its own VM, built on Apple's
[Containerization](https://github.com/apple/containerization) framework — that pauses in about a millisecond,
sleeps to disk to give its RAM back, wakes in about a third of a second, and restores into a new process after
the host app crashes, with terminal sessions that survive every one of those. This page is for people who want
to use the library directly or understand how `doz` drives it. Using Dozer itself: the [user manual](manual/README.md).

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
else; a program a session started less than `settle` — 3 s — ago gets the rest of it first) · `resetToImage` · `delete`. **Stop keeps the root disk**: the next Start cold-boots the same
disk (what you installed is still there); Reset to image starts again from a fresh clone of the
prepared disk; Delete removes everything the sandbox has on disk. A disk that was not cleanly
unmounted — `Sandbox.discardRestorableState(for:)` (a hibernated VM is stopped without unmounting it),
a failed restore, a crash while running — is replayed from its **journal** on the next cold boot, or,
on a journal-less disk, checked with `e2fsck` first (see **Journal** below). Hibernate and Stop
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

**Lineage: base → image → sandbox, as APFS clones.**

```
<store>/images/bases/<key12>/root.ext4 + manifest.json   an OCI base, flattened ONCE (digest + capacity + journal + formatter)
<store>/images/<name>/<key12>/root.ext4 + manifest.json  an image: a clone of its base + the bake (manifest.parent = the base key)
<store>/sandboxes/<name>/rootfs.ext4                     a sandbox: a clone of its image (PersistedSandbox.rootImage)
```

- Measured (M3, `make test-vm-lineage`): with the `node` base flattened (33 s, once), claude-code
  bakes in **16 s** and pi in **15 s** (a fresh flatten each was ~50 s before). Both images share
  **256 MiB** of the 278 MiB base; each further image on it costs only its own blocks.
- Children never depend on their parent's FILE: deleting or re-baking a base or an image leaves every
  image and sandbox cloned from it exactly as it was (`ImageBaker.deleteBase`, `lineage children`).
- Every image key resolves to its disk: `StoreLayout.imageDisk(forKey:)` (`name@key12`, `custom:…`,
  `base:…`, a prepared-disk key). `CustomImage.baseImage` is such a key.
- A older store re-bakes each image once (the key includes the lineage format and the journal).

**Journal: on by default, 16 MiB — a toggle.** `ImageSpec.journalMiB` (the image's root and
every sandbox's state disk) and `SandboxSpec.journalMiB` (the lab's prepared disk): default 16, `nil`
= no journal. Measured: after Hibernate → discard, a journaled disk cold-boots by
journal replay in **~380 ms** with no e2fsck (15/15 `e2fsck -fn` clean afterwards); a journal-less
one goes through the helper VM's `e2fsck` (~1,030 ms), as before 587. The cost: 16 MiB per base
(shared) and up to 16 MiB per sandbox once the ring wraps; `fsync`-heavy work ~1.7× slower
(0.16 vs 0.09 ms per fsync), metadata-heavy work (many small files + `sync`) ~3× faster. Records
written by older builds decode as journal-less (their disks are); `PersistedSandbox.rootJournaled` /
`stateJournaled` say what each disk has. A copy taken while running (a running restore point, a
custom image from one) is still e2fsck'd on its first boot, journal or not.

**TRIM.** The root and state disks mount with `discard`: a block the guest frees is punched
out of the host file at once (300 MiB written and deleted in a running sandbox leaves 0 MiB behind).
Every bake ends with `fstrim /` — claude-code's image came out 89 MiB (14 %) and pi's 81 MiB (16 %)
smaller for ~60 ms.

**Accounting: `DiskAccounting.measure(store:)`** — every disk of a store (bases, images, custom
images, prepared disks, sandbox root and state disks, restore points) with its `allocatedBytes`,
`uniqueBytes` (what deleting it frees), `sharedWithParentBytes` (its lineage parent), `privateBytes`
(APFS's own number — they agree to 0.0 MiB on every disk, unless a file outside the store is a clone
of one inside it: `uniqueBytes` is scoped to the STORE, APFS's number to the whole volume), `extentsPerGiB`, and `garbageBytes`: the
host file's data in blocks ext4 considers free (exact, from the disk's bitmaps, on a cleanly unmounted
disk; otherwise allocated − the guest's `df` recorded at the last Stop / Hibernate,
`PersistedSandbox.guestUsedMiB`). It reads APFS's extent map (`F_LOG2PHYS_EXT`): ~5 ms per disk.
Measure stopped disks, on one volume.

**Maintenance, stopped sandboxes only** (a running or sleeping one, or a disk not cleanly
unmounted, is refused):

- `reclaim()` punches ext4's free blocks out of the root and state disks' host files — the churn a
  guest deleted without discard (a older disk, or a remount). 800 MiB → 0 in ~25 ms; the free list
  equals `dumpe2fs`'s, the disk boots identically, `e2fsck -fn` is clean.
- `rederive()` rebuilds the root disk as a fresh clone of its image plus only the blocks whose
  content differs, skipping free blocks — re-sharing blocks that were rewritten with the image's own
  bytes and dropping the garbage (147 MiB shared again, 200 MiB of garbage gone, in 0.8 s). The new
  disk is verified (every in-use block reads the same; `e2fsck -fn` clean) before an atomic rename;
  any failure leaves the original. The state disk and restore points are untouched.
- `maintenanceAdvice()` says which is worth it (`MaintenanceAdvice.thresholds`, measured): garbage
  > 25 % of the allocation or > 512 MiB → reclaim; lost identical sharing > 64 MiB or > 10 % of the
  image → rederive. Fragmentation never triggers anything (1000 extents/GiB cost no boot, wake
  or read time on the SSD).
- `checkDisks()` runs `e2fsck -fn` (read-only) on the disks in the helper VM.

**Memory: a woken sandbox gives back what it does not use.** The Mac charges a VM for every
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
(`PersistedSandbox.memoryBalloon`) and gets one at its next cold boot.
`make test-vm-hardening` (`hardening memory`) is the regression test.

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

**NAT subnets.** A `.nat` sandbox whose spec names no `subnet` gets a free vmnet /24 of its
own from 192.168.100–199.0/24 — never one a network interface of the Mac is already on (the LAN, a
VPN, another process's vmnet bridge), never one this process holds — instead of vmnet's default,
which two processes could both take (the NAT then silently drops one). `SandboxSpec.subnet` stays an
override; a restore keeps the subnet its guest was addressed from. Proxied sandboxes have no NIC.

**Network: proxied sandboxes.** `SandboxSpec(…, network: .proxied(.agent))` boots a VM with
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


## The doz host

A running VM lives in the process that started it, so one process per user and store owns them
all: **`doz host`** (a lazy per-user host). It owns every running VM, each
proxied sandbox's egress proxy (its policy, connection log and credential vault), the metrics
writer, and the shared event-loop group, and serves `<store>/host.sock`. Every command is a
thin client of that socket.

- **Lazy.** The first command that needs it starts it **fully detached** — through an intermediate
  that exits, so its parent is launchd and it is in no caller's process tree (stopping a client, its
  group or its tree never stops the host), its own session (`setsid`), stdin `/dev/null`,
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
  `0xFF 'H'|'R' cols rows` frames from the client (the attach wire); the end of a session is
  a notice carrying `ESC ] 777;doz;ended;<code> BEL`. `events` and `net-log --follow` stream event
  lines. Fields are only ever added; a host answers a newer `v` with `error.code = "version"`.


## Dependencies

| Package | Pin | Why |
|---|---|---|
| apple/containerization | **exact** 0.47.0 | the VM runtime; the sleep design leans on its internals' shape |
| apple/swift-nio (NIOCore, NIOEmbedded, NIOPosix; NIOHTTP1) | from 2.103.0 | drives TLS synchronously on the proxy's connection threads (`EmbeddedChannel`); one shared `MultiThreadedEventLoopGroup` for every VM's vminitd clients; `doz ui`'s HTTP/1.1 server (`NIOHTTP1` is a module of the same package — no new dependency; imported only by `Sources/DozerWeb`, which the audit enforces) |
| apple/swift-nio-ssl (NIOSSL) | from 2.37.5 | terminates and re-originates TLS for bound hosts with **in-memory** keys — Network.framework and Secure Transport need a `SecIdentity`, i.e. a keychain (prompts for an ad-hoc-signed app, and a leaf key per host on disk) |
| apple/swift-certificates (X509), apple/swift-asn1 | from 1.21.0 / 1.7.3 | issues the per-sandbox CA and its per-host leaves |
| apple/swift-argument-parser (ArgumentParser) | from 1.5.0 (resolved 1.8.2) | the `doz` CLI's subcommands, aliases, options and `--help`. Imported ONLY by the CLI's command targets (`Sources/DozerCLI`, `Sources/doz`) — never by the library or the host; the audit enforces it. Hand-rolling a parser for ~40 subcommands with aliases and `--` passthrough would be more code to get wrong than this Apple package. |

| jpsim/Yams (Yams) | **exact** 6.2.2 | the project file `doz_project.yaml` is YAML, like dbt's `dbt_project.yml`. Yams (MIT, libyaml inside) is the standard Swift YAML library; pinned exactly and imported ONLY by `Sources/DozerCLI` (the audit enforces both). The project file's schema is closed and checked by hand on Yams's node tree; anchors/aliases and multiple documents are refused. |

The five apple/* packages are ones containerization 0.47.0 already resolves, so declaring them
changed nothing in `Package.resolved`; Yams is the one package that is not. The CLI's host also uses the system `SQLite3` module for its
metrics (no package). Upstream certificates are verified with the
Mac's own trust store (Security.framework, `SecTrustEvaluateWithError`). `Scripts/audit.sh` holds
the import and dependency allowlists.


## Consuming the library

`DozerKit` is a product of this package (it becomes its own library in a later version). Until then, depend on
this repository:

```swift
dependencies: [
    .package(url: "https://github.com/dozer-sandbox/dozer-sandbox.git", from: "0.31.0"),
],
targets: [
    .target(name: "YourTarget", dependencies: [
        .product(name: "DozerKit", package: "dozer-sandbox"),
    ]),
]
```

**Resources in an app bundle:** copy `DozerKit_DozerKit.bundle` from the build directory into
`Contents/Resources`. The library finds `deckhold` there (or beside the executable, or at `$DOZ_DECKHOLD`) and
never uses SwiftPM's trapping `Bundle.module` accessor. A host that boots VMs needs the
`com.apple.security.virtualization` entitlement on its own binary.

## Storage / identity is configured by the host, not by this package

This package owns no brand and no directory name: the host passes `storeRoot`. Nothing in
`Sources/` may hardcode a consumer's bundle id, product name, or storage directory —
`Scripts/audit.sh` fails the build if one appears.

