# CLAUDE.md

Guidance for Claude Code when working in this repo.

**Process lives one level up.** `/feature`, `/plan`, `/ship`, `/fleet`, the `changes/` ledger,
`ROADMAP.md`, `BACKLOG.md`, and `CHANGELOG.md` are workspace-level and run from `deck-factory`,
not from here. This file holds only the code rules specific to `SnoozeContainerKit`.

## This is a sovereign library — release discipline is different from an app

`SnoozeContainerKit` ships by **semver tag**, not by app version bumps. `swift build && swift test`
at the root is the whole story for a consumer.

- **A library never depends on an app**, and never on anything under `repo/app/*`. It has no
  sibling-library dependency at all (so no `lib()` helper and no prelaunch mirror here).
- **A library never claims a fleet instance token.** A worktree of this library
  (`.claude/worktrees/slot-<token>/SnoozeContainerKit`) reuses the SAME token an app slot already
  claimed.
- **This package's directory basename and the last path component of its remote URL must both be
  `SnoozeContainerKit`.** SwiftPM derives package identity from them.
- **A library's slot worktree is one level deeper than an app's** — ancestor-walk depth 3/7.

## Dependencies

| Product | Targets | Depends on |
|---|---|---|
| `SnoozeContainerKit` | `SnoozeContainerKit` (+ resources `deckhold`, `snoozenet`) | `apple/containerization` **exact** `0.47.0`: `Containerization`, `ContainerizationArchive` (the kernel tarball), `ContainerizationExtras`, `ContainerizationOCI`, `ContainerizationOS`; since 580 `swift-nio` (`NIOCore`, `NIOEmbedded`; 583 `NIOPosix`), `swift-nio-ssl` (`NIOSSL`), `swift-certificates` (`X509`), `swift-asn1` — apple/* packages containerization already resolves (README "Dependencies") |
| — (not a product) | `snooze-vmtest` — the entitled VM test host | `SnoozeContainerKit` |

The Containerization pin is EXACT on purpose: the sleep design leans on its internals' shape —
`LinuxContainer.withVirtualMachineInstance` handing out a `VZVirtualMachineInstance`, the
`VZInstanceExtension` hook, the public `VirtualMachineManager` / `VirtualMachineAgent` protocols,
and how `LinuxContainer.create()/start()/stop()` call them. A bump is a deliberate re-verification:
`make test-vm` green twice.

## Where the code lives

| Path | What |
|---|---|
| `Sources/SnoozeContainerKit/Sandbox.swift` | The `Sandbox` actor: boot (images, golden-disk bake, APFS clone, VM), lifecycle via the planner, exec, sessions/attach |
| `Phase.swift` | `Phase` and `LifecyclePlanner` — each operation's steps as DATA (incl. stop / resetToImage / delete), so the invariants are unit tests |
| `VirtualMachine.swift` | Direct VZ ops; `PinnedIdentity` (machine id + MAC); `SnoozeVMM`, `AdoptingInstance`, `AdoptingAgent` — restore into a new process |
| `SessionConnection.swift` | One viewer's connection: HELLO/DATA/RESIZE out, SNAPSHOT/DATA/EXIT in; never delivers or sends after close |
| `DeckholdProtocol.swift` | Frame codec, `deckhold ls` parser, `GuestCommand` (every guest argv; the share re-mount script) |
| `StoreLayout.swift` | Storage layout under `storeRoot`; `PersistedSandbox` (what a new process needs to restore) |
| `DeckholdBinary.swift` | Finds the resource without `Bundle.module` |
| `ImageRecipe.swift`, `ImageBaker.swift` | Recipes (base@digest + steps + verify + persist dirs), the two agent recipes, the baked-disk cache |
| `RestorePoints.swift`, `FsckHelper.swift` | Restore points, custom images; e2fsck of a running-taken copy in a helper VM (on the file, over virtio-fs) |
| `KernelProvider.swift` | The pinned Linux kernel (`KernelArtifact.recommended`): override → verified cache → byte-identical seed → download + verify archive + extract + verify kernel |
| `Resources/deckhold` | The committed static aarch64-linux-musl guest binary — see `Guest/deckhold/PROVENANCE.md` |
| `Guest/deckhold/` | deckhold's C source, `build.sh` (pinned Zig 0.16.0 + ghostty `b988efc`), `PROVENANCE.md` |
| `NetworkPolicy.swift` | 580: `NetworkMode`, `NetworkPolicy` (presets, ordered rules, DNS gating), `EgressRule`, IPv4 CIDR |
| `EgressProxy.swift` | 580: the host proxy (vsock listener; CONNECT / plain HTTP / redirected TCP / DNS; decrypted tunnels via NIOSSL on `EmbeddedChannel`; `TLSUpstream` verified by Security.framework); `Wire` socket plumbing; `DNSMessage` |
| `Credentials.swift` | 580: `CredentialBinding`, `CredentialVault` (secrets in memory, placeholders, the byte-exact head rewrite); `HTTPHead` |
| `SandboxCA.swift`, `HTTPRequestReader.swift`, `ConnectionLog.swift` | 580: the per-sandbox CA + leaves; request/body framing; the metadata-only log |
| `Resources/snoozenet`, `Guest/snoozenet/` | 580: the guest half of a proxied network — C source, `build.sh` (the same pinned Zig), `PROVENANCE.md` |
| `Sources/snooze-vmtest/` | The VM integration suite (entitled executable); `NetworkSuite.swift` is `network` |
| `Tests/SnoozeContainerKitTests/` | Unit tests — no VM |

## Rules that each cost a bug to learn (keep them, and keep their tests)

- **Sessions start WITHOUT `sh -c`.** BusyBox ash leaks an ignored SIGQUIT into what it execs, and a
  program cannot trap a signal ignored on entry (576: the screensaver's `m` menu). `GuestCommand.serve`
  builds argv; deckhold additionally resets every signal to default before exec. Utility execs
  (`exec(["sh","-c",…])`) may use a shell — never a session.
- **Stop keeps the root disk** (owner ruling 2026-09-25, after the 578 smoke found `apk add`ed
  packages gone): Stop shuts the VM down and persists the phase as `off`; the next Start cold-boots
  the SAME disk and clones the prepared disk only when none exists. `resetToImage()` discards the
  root disk; `delete()` removes the sandbox's whole directory. No Stop leaves a snapshot, and a
  snapshot found beside a kept disk on a cold Start is deleted — never restored onto a disk that
  has moved on.
- **One vmnet network per `Sandbox`, and never vmnet's default subnet beside another process.** Each
  Start used to create a new vmnet network (after a handful the guest had no route out); it is now
  created once and reused. Two processes that both take the default can get the same subnet and the
  same guest addresses — the NAT then silently drops one (the gateway still answers ping). Hosts that
  run beside others set `SandboxSpec.subnet`; the test hosts pin 192.168.201/202.0/24.
- **Every sandbox VM uses the ONE shared event-loop group** (`SharedEventLoop.group`, 583). Left to
  itself `VZVirtualMachineInstance` makes an 8-thread group and shuts it down only in its own `stop()`,
  which Deep Sleep never calls — each VM instance a host made kept 8 threads + 8 kqueues forever (582;
  thread cap 6,144). `hardening leak` is the regression test (threads, fds, footprint flat).
- **Stop decides from the phase it was CALLED in** (`perform()` reads `phase` before going busy).
- **Stop is always graceful.** A paused VM is resumed and a VM on disk restored (silently — no phase
  event) and then `LinuxContainer.stop()` runs. Stopping at the VZ level instead leaves the package's
  vminitd gRPC clients unclosed, and deallocating one is a FATAL error
  (`Deinited NIOAsyncWriter without calling finish()`, seen in the 578 suite). Anything that could
  not be stopped through the package goes to `Graveyard` rather than being deallocated. Every exec
  is `delete()`d, including on error paths — deletion is what closes its client.
- **A wake's first guest calls are retried on a closed channel** (583). A restored guest resets its
  vsock transport as it resumes; a vminitd connection dialled in that moment can be closed under its
  first call (`unavailable: "The channel was closed"` — 582: 2 of 31 concurrent wakes; 583: always
  `resyncClock`). `resyncClock` and `remountShares` are idempotent, so `retryingFirstGuestCall` retries
  them on a fresh connection. `hardening concurrent` (16 at once) is the regression test.
- **The snapshot is deleted the moment the VM runs again** (resume, wake, restore) and on stop.
- **Wake re-syncs the guest clock and re-mounts every share.** The re-mount lists the fresh virtio-fs
  root (READDIRPLUS) before binding: the "fresh" mount reuses the live superblock, and without the
  listing the bind picks up a stale dentry — the suite's SECOND wake lost `/work`.
- **Connections are identified by object, never by a file descriptor number,** and a closed
  connection never delivers or sends a byte (the 576 recycled-fd Stop bug).
- **Crash restore = identical VM + adoption.** The machine identifier and the NIC's MAC are pinned
  (`PinnedIdentity`), the vmnet subnet reused, and `AdoptingAgent` answers `LinuxContainer`'s
  guest SET-UP calls as already done while the restored guest is adopted.
- **The library owns its kernel.** Never read `~/Library/Application Support/com.apple.container`
  as a source of truth (the runners have no `container` CLI; that file is another tool's to change).
  A file there is used only as a SEED, and only when its sha256 equals the pin. A kernel change is a
  new `KernelArtifact` (URL + archive sha256 + member + kernel sha256) and `make test-vm` twice — a
  snapshot must be restored with the kernel it was taken under.
- **Restore points are disk-only APFS clones** (owner ruling: no live forks). A copy of a RUNNING
  VM is crash-consistent at best — the ext4 disks have no journal — so it is marked `needsFsck` and
  the next boot from it runs e2fsck first (`FsckHelper`). e2fsck runs on the image FILE over virtio-fs:
  a container's device cgroup refuses a raw block node even to a privileged exec.
- **A kept disk that was not cleanly unmounted is e2fsck'd before it cold-boots** (583). Deep Sleep
  stops the VM at the VZ level, so a discarded snapshot (`discardRestorableState`), a failed restore,
  a crash while running or a VZ-level stop fallback leaves a disk that was never unmounted — and the
  ext4 has no journal (582: 12 of 15 such cold boots failed with `EXT4-fs error … doubly allocated`).
  `keptDiskNeedsFsck` decides (last durable phase ≠ off, a snapshot beside the disk, or the mark);
  `hardening discard` is the regression test.
- **Metadata dates have fractional seconds** (`ImageBaker.encoder`): restore points taken within one
  second must sort in the order they were taken.
- **A proxied VM has NO NIC; the host proxy is the only way out** (580). The guest shim decides
  nothing. Every boot, crash restore and wake re-registers the proxy's vsock listener
  (`listenForEgress`) — the listener happened to survive a same-process wake in the probe, but a
  crash restore is a new VM.
- **`lo` needs a global-scope source address** (`lo:snz`, 169.254.255.254/32, set by snoozenet):
  lo's 127.0.0.1 is host-scoped, so without it an outbound socket gets source 0.0.0.0, its SYN is
  still redirected, and every later segment is dropped — a silent stall, not an error.
- **Never `EmbeddedChannel.writeOutbound` / `.finish()` / `close().wait()` with NIOSSL in the
  pipeline.** `writeOutbound` waits on a write promise NIOSSL completes only after the handshake;
  `finish()` waits on close, which waits for the peer's close_notify. Each hung a proxy thread
  forever. Use `writeAndFlush(_, promise: nil)` and `close(promise: nil)`, then drain.
- **A real key given to `openSession`/`exec` is moved into the vault** and replaced by a
  placeholder; keep it that way — "keys never enter the sandbox" rests on it.
- **virtio-fs caches:** deleting a file on the HOST that the guest has cached is not visible at once
  — tests use fresh file names (this cost an afternoon of chasing a non-bug).

## Verifying changes

```bash
make build     # swift build — Xcode 27 needs the --build-system native pin the Makefile probes for
make test      # unit tests: no VM, no entitlement. Never --parallel.
make audit     # Scripts/audit.sh
make test-vm   # the VM integration suite — see below
```

### The VM integration tests need an ENTITLED host — how

`swift test` runs an XCTest bundle inside `xctest`, which does not (and cannot be made to) carry
`com.apple.security.virtualization`, so no VM can start there. The integration suite is therefore
an executable target, `snooze-vmtest`, that `make test-vm`:

1. builds (`swift build --product snooze-vmtest`),
2. ad-hoc signs with `Scripts/vmtest.entitlements` (`codesign --force --sign - --entitlements …`),
3. runs under a watchdog (`perl -e 'alarm 420; exec @ARGV' …`) so a VM op that never completes
   fails the run instead of wedging it; stdout is line-buffered so a hang shows where it stopped.

It prints one `PASS`/`FAIL` line per check and `vmtest: ALL PASS` last. Modes: `all` (default),
`network` (580, `make test-vm-network`: the claude-code image proxied; live-prompt check SKIPs
without `ANTHROPIC_API_KEY`), `netdebug --script '…'`, `lifecycle`, `crash` (spawns itself as `crash-save` — start, session, sleep to disk, exit without
stopping — then restores in the parent), `crash-restore`.

- **Store:** `VMTEST_STORE` (default `$TMPDIR/snooze-vmtest-store`) — a SCRATCH store, never an app's
  storage root. The first run in a new store pulls images and bakes `bash ncurses` (~40 s, network).
- **Coexistence:** sandboxes are named `vmtest` / `vmtest-crash`; the suite touches nothing outside
  its store and never kills a process it did not start, so SandboxLab or a probe can run beside it.
- **Kernel:** the library's pinned kernel via `KernelProvider`, cached in `KERNEL_CACHE` (exported
  as `$SNOOZE_KERNEL_CACHE`; default: under the store). `make kernel` fetches it alone.
  `SNOOZE_KERNEL=<path>` boots an explicit kernel instead.
- A VM test is green when it is green **twice in a row**.

## Contributing

Issues and fixes are welcome directly; see `CONTRIBUTING.md`.
