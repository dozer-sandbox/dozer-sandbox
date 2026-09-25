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
else) · `resetToImage` · `delete`. **Stop keeps the root disk**: the next Start cold-boots the same
disk (what you installed is still there); Reset to image starts again from a fresh clone of the
prepared disk; Delete removes everything the sandbox has on disk. Guest: `exec(argv)` (no shell unless you pass one), `sessions()` (`deckhold ls`),
`screenText(name)` (`deckhold dump`), `bootConsole()`.

**Images** (`ImageRecipe`, `ImageBaker`, `AgentRecipes.claudeCode` / `.pi`): no layered images and
no Dockerfile — a digest-pinned OCI base is read once and flattened to one ext4 disk, the install
steps run inside a VM booted from it, a credential-free check verifies the result, and the disk is
kept read-only in the store, keyed by recipe + kernel + deckhold. A sandbox with `spec.recipe`
APFS-clones it as its root and gets a per-sandbox **state disk** for the agent's login/state (it
survives Stop, Reset to image and re-bakes). Credentials go to `openSession(environment:)` only.

**Restore points** (disk only, no memory): `takeRestorePoint` (an APFS clone of the root + state
disks — instant; from a running VM: sync → pause → clone → resume, marked for `e2fsck` on the next
boot, since the ext4 has no journal), `revert(to:)` (takes a "before revert" point first),
`fork(_:as:)` (a new, cold-booted sandbox), `deleteRestorePoint` (any, in any order), and
`saveAsImage` (a read-only **custom** image with its provenance, bootable via `spec.customImage`).

**Sessions** live in the guest under `deckhold`, a PTY holder on headless libghostty-vt: it owns
the PTY, keeps an emulator model of the screen, and on attach sends a rendered SNAPSHOT reflowed to
the viewer's size, then the program's own bytes. That is why a session survives a sleep to disk
(which severs every exec's stdio) — the viewer simply reattaches. Programs are started **without**
`sh -c` and with every signal reset to default (BusyBox `sh` leaks an ignored SIGQUIT, which a
program cannot trap). The wire protocol and the snapshot recipe are documented in
[`Guest/deckhold/deckhold.c`](Guest/deckhold/deckhold.c).

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

## Dependencies

| Package | Pin | Why |
|---|---|---|
| apple/containerization | **exact** 0.47.0 | the VM runtime; the sleep design leans on its internals' shape |
| apple/swift-nio (NIOCore, NIOEmbedded) | from 2.103.0 | 580: drives TLS synchronously on the proxy's connection threads (`EmbeddedChannel`) |
| apple/swift-nio-ssl (NIOSSL) | from 2.37.5 | 580: terminates and re-originates TLS for bound hosts with **in-memory** keys — Network.framework and Secure Transport need a `SecIdentity`, i.e. a keychain (prompts for an ad-hoc-signed app, and a leaf key per host on disk) |
| apple/swift-certificates (X509), apple/swift-asn1 | from 1.21.0 / 1.7.3 | 580: issues the per-sandbox CA and its per-host leaves |

All four 580 additions are apple/* packages that containerization 0.47.0 already resolves, so
declaring them changed nothing in `Package.resolved`. Upstream certificates are verified with the
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
make test             # unit tests — no VM
make test-vm          # the VM integration suite: lifecycle, crash restore, restore points (entitled test host)
make test-vm-agents   # the claude-code and pi images: bake/cache, start, sessions, sleep → wake, state disk
make kernel           # fetch + verify the pinned kernel into the cache (KERNEL_CACHE=dir), no VM
make audit            # import allowlist, one exact dependency, no host brand, deckhold == PROVENANCE
make deckhold         # rebuild the guest binary (pinned Zig + ghostty; first run ~3.5 min)
make deckhold-verify  # rebuild from scratch and check the committed bytes match
make test-vm-network  # 580: a proxied (no-NIC) sandbox end to end, then a bake under the bake preset
make snoozenet        # rebuild the snoozenet guest binary (pinned Zig; no ghostty) + refresh PROVENANCE.md
make snoozenet-verify # rebuild snoozenet and check the committed bytes match
```

## Contributing

This package was productised from a probe with its harness app (SandboxLab) built alongside it,
so a change usually arrives already exercised. Issues and fixes are welcome directly — a bug
report, a reproduction, a fix, a documentation correction. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Licence

MIT (see [`LICENSE`](LICENSE)); third-party licences, including what is statically linked into
the guest binary, are inventoried in [`LICENCES.md`](LICENCES.md).
