# CLAUDE.md

Guidance for Claude Code when working in this repo.

**Process lives one level up.** `/feature`, `/plan`, `/ship`, `/fleet`, the `changes/` ledger,
`ROADMAP.md`, `BACKLOG.md`, and `CHANGELOG.md` are workspace-level and run from `deck-factory`,
not from here. This file holds only the code rules specific to `DozerKit`.

## This is a sovereign library — release discipline is different from an app

`DozerKit` ships by **semver tag**, not by app version bumps. `swift build && swift test`
at the root is the whole story for a consumer.

- **A library never depends on an app**, and never on anything under `repo/app/*`. It has no
  sibling-library dependency at all (so no `lib()` helper and no prelaunch mirror here).
- **A library never claims a fleet instance token.** A worktree of this library
  (`.claude/worktrees/slot-<token>/DozerKit`) reuses the SAME token an app slot already
  claimed.
- **This package's directory basename and the last path component of its remote URL must both be
  `DozerKit`.** SwiftPM derives package identity from them.
- **A library's slot worktree is one level deeper than an app's** — ancestor-walk depth 3/7.

## Dependencies

| Product | Targets | Depends on |
|---|---|---|
| `DozerKit` | `DozerKit` (+ resources `deckhold`, `doznet`) | `apple/containerization` **exact** `0.47.0`: `Containerization`, `ContainerizationArchive` (the kernel tarball), `ContainerizationExtras`, `ContainerizationOCI`, `ContainerizationOS`; since 580 `swift-nio` (`NIOCore`, `NIOEmbedded`; 583 `NIOPosix`), `swift-nio-ssl` (`NIOSSL`), `swift-certificates` (`X509`), `swift-asn1` — apple/* packages containerization already resolves (README "Dependencies") |
| `doz` (executable, 585) | `doz` → `DozerCLI` (commands) → `DozerHost` (the host + its client) | `DozerKit`; `swift-argument-parser` (`ArgumentParser`) in `DozerCLI`/`doz` ONLY; the system `SQLite3` in `DozerHost` (metrics) |
| — (not a product) | `DozerWeb` (590) — `doz ui`'s server and page | `DozerHost`; `swift-nio` `NIOCore`/`NIOPosix`/**`NIOHTTP1`**/**`NIOWebSocket`** (591) (both ONLY here — the audit enforces it); resource `Resources/Web` (generated, committed). `DozerCLI`'s `UICommand.swift` alone imports `CoreServices` (LaunchServices opens the browser) |
| — (not a product) | `doz-vmtest` — the entitled VM test host | `DozerKit`, `DozerHost` (the `cli` mode decodes `--json` with its types) |

The Containerization pin is EXACT on purpose: the sleep design leans on its internals' shape —
`LinuxContainer.withVirtualMachineInstance` handing out a `VZVirtualMachineInstance`, the
`VZInstanceExtension` hook, the public `VirtualMachineManager` / `VirtualMachineAgent` protocols,
and how `LinuxContainer.create()/start()/stop()` call them. A bump is a deliberate re-verification:
`make test-vm` green twice.

## Where the code lives

| Path | What |
|---|---|
| `Sources/DozerKit/Sandbox.swift` | The `Sandbox` actor: boot (images, golden-disk bake, APFS clone, VM), lifecycle via the planner, exec, sessions/attach |
| `Phase.swift` | `Phase` and `LifecyclePlanner` — each operation's steps as DATA (incl. stop / resetToImage / delete), so the invariants are unit tests |
| `VirtualMachine.swift` | Direct VZ ops; `PinnedIdentity` (machine id + MAC); `DozerVMM`, `AdoptingInstance`, `AdoptingAgent` — restore into a new process |
| `SessionConnection.swift` | One viewer's connection: HELLO/DATA/RESIZE out, SNAPSHOT/DATA/EXIT in; never delivers or sends after close |
| `DeckholdProtocol.swift` | Frame codec, `deckhold ls` parser, `GuestCommand` (every guest argv; the share re-mount script) |
| `StoreLayout.swift` | Storage layout under `storeRoot`; `PersistedSandbox` (what a new process needs to restore) |
| `DeckholdBinary.swift` | Finds the resource without `Bundle.module` |
| `ImageSpec.swift`, `ImageBaker.swift` | Image specs (base@digest + steps + verify + persist dirs + `journalMiB`), the two agent image specs, the baked-disk cache; 587: base disks (`images/bases/`, flattened once per base key) and clone-tree bakes (`ImageManifest.parent`) |
| `EXT4Inspector.swift` | 587: an ext4 image FILE read on the host — `has_journal`, clean state, the free-block bitmaps (== `dumpe2fs`'s list) |
| `DiskAccounting.swift` | 587: per-disk unique / shared-with-parent / garbage / extents from APFS's extent map (`F_LOG2PHYS_EXT`), PRIVATESIZE cross-check; range helpers |
| `Maintenance.swift` | 587: `reclaim()`, `rederive()`, `maintenanceAdvice()` (586's thresholds), `checkDisks()` — stopped sandboxes only |
| `RestorePoints.swift`, `FsckHelper.swift` | Restore points, custom images; e2fsck of a running-taken copy in a helper VM (on the file, over virtio-fs) |
| `KernelProvider.swift` | The pinned Linux kernel (`KernelArtifact.recommended`): override → verified cache → byte-identical seed → download + verify archive + extract + verify kernel |
| `Resources/deckhold` | The committed static aarch64-linux-musl guest binary — see `Guest/deckhold/PROVENANCE.md` |
| `Guest/deckhold/` | deckhold's C source, `build.sh` (pinned Zig 0.16.0 + ghostty `b988efc`), `PROVENANCE.md` |
| `SubnetPool.swift` | 583: automatic vmnet subnets for NAT sandboxes and bakes (free on the Mac, unique in the process) |
| `NetworkPolicy.swift` | 580: `NetworkMode`, `NetworkPolicy` (presets, ordered rules, DNS gating), `EgressRule`, IPv4 CIDR |
| `EgressProxy.swift` | 580: the host proxy (vsock listener; CONNECT / plain HTTP / redirected TCP / DNS; decrypted tunnels via NIOSSL on `EmbeddedChannel`; `TLSUpstream` verified by Security.framework); `Wire` socket plumbing; `DNSMessage` |
| `Credentials.swift` | 580: `CredentialBinding`, `CredentialVault` (secrets in memory, placeholders, the byte-exact head rewrite); `HTTPHead` |
| `SandboxCA.swift`, `HTTPRequestReader.swift`, `ConnectionLog.swift` | 580: the per-sandbox CA + leaves; request/body framing; the metadata-only log |
| `Resources/doznet`, `Guest/doznet/` | 580: the guest half of a proxied network — C source, `build.sh` (the same pinned Zig), `PROVENANCE.md` |
| `Sources/doz-vmtest/` | The VM integration suite (entitled executable); `NetworkSuite.swift` is `network`; `CLISuite.swift` is `cli` (585, `make test-cli`); `ClaudeSuite.swift` is `claude` (588, `make test-vm-claude`) |
| `Sources/DozerHost/ClaudeLogin.swift`, `Accounts.swift`, `LoginWatcher.swift`, `HostCore+Accounts.swift` | 588: the Mac's Claude Code login (read-only), the keychain through `/usr/bin/security`, accounts (`<store>/accounts.json`, never a secret), ONE watcher per Mac login, the keep-alive, key policy |
| `Sources/DozerHost/HostProtocol.swift` | 585: the host protocol (JSON lines, `HostOp`, results) — fields only ever added |
| `Sources/DozerHost/HostCore.swift` | 585: the host's model — every sandbox as a `Sandbox`, every operation, crash recovery, metrics rows; also used read-only in-process |
| `Sources/DozerHost/HostServer.swift` | 585: `doz host` — the lock, the socket, the attach relay (held clients), streams, idle exit, quit = Hibernate |
| `Sources/DozerHost/HostClient.swift`, `UnixSocket.swift` | 585: the detached-child launcher, the client, socket plumbing, `ClientWire` (SandboxLab's attach wire) |
| `Sources/DozerHost/DozerStore.swift`, `Metrics.swift` | 585: the CLI store's files, `SandboxConfig` (`doz.json`), images → specs; the metrics DB (SandboxLab's schema) |
| `Sources/DozerCLI/` | 585: the commands (ArgumentParser), the attach client, `doctor`; 590: `UICommand.swift` (`doz ui`, `ui link`) |
| `Sources/DozerWeb/` | 590: `doz ui` — `WebServer` (NIOHTTP1 on 127.0.0.1:0, SSE), `WebSecurity` + `WebSessions` + `WebConfiguration` (the checks, as pure functions), `WebRoutes` (the CLOSED route table), `WebModels` (field-by-field projections of host results), `WebDataSource` (the host client), `WebEvents` (bounded SSE hub, the monitor), `WebControl` (`ui.lock`, `ui.sock` → `ui link`), `WebAssets` (manifest + digests); phase 2: `WebActions` (the closed action enum → one HostOp each), `WebOperations` (running them, progress over SSE), `WebTerminal` (Terminal.app hand-off; CSV defusing) |
| `Sources/DozerWeb/WebSource/` → `Resources/Web/` | 590: the page as authored (vanilla HTML/CSS/JS) → generated by `Scripts/build-web-assets.swift` (content-hashed, manifest), committed; 591: `vendor/ghostty-web/` (pinned, `VENDOR.json`) |
| `Sources/DozerWeb/WebTerminal{Tickets,Wire,Attach,Bridge}.swift` | 591: browser terminals — the ticket store, frames + the 541 classifier + the cover, the host attach connection, the bridge and hub (NIOWebSocket ONLY here — the audit enforces it) |
| `Sources/DozerHost/Settings.swift`, `TOML.swift`; `Sources/DozerCLI/ConfigCommands.swift`; `Sources/DozerWeb/WebSettings.swift` | 591 settings: the CLOSED schema (`DozerSettings.schema`), `${XDG_CONFIG_HOME:-~/.config}/dozer-sandbox/doz.toml` generated from it, our own strict TOML subset (no dependency), precedence flag > env > file > default with a source per value; `doz config`; the UI's Settings page route (`GET`/`POST /api/v1/settings`) |
| `Sources/DozerHost/ImageTree.swift`; `Sources/DozerCLI/TemplateCommands.swift`; `Sources/doz-vmtest/TemplatesSuite.swift` | 593: the lineage (`image-tree`, built from `DiskAccounting`; `doz image ls --tree`, Images › Lineage); templates (`template-create`) and `duplicate` (`Sandbox.duplicate`); `make test-vm-templates` |
| `Tests/DozerWebTests/` | 590: the security rules one by one, and a real listener driven with raw HTTP |
| `Tests/DozerKitTests/` | Unit tests — no VM |

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
  same guest addresses — the NAT then silently drops one (the gateway still answers ping). Since 583
  the library never takes the default: with no `SandboxSpec.subnet` a NAT sandbox (and a NAT bake)
  gets a free /24 from 192.168.100–199 (`SubnetPool`: none a host interface is on, none this process
  holds, tried from a random start); an explicit subnet stays an override. The test hosts still pin
  192.168.201/202.0/24. `hardening subnets` is the test.
- **Every sandbox VM uses the ONE shared event-loop group** (`SharedEventLoop.group`, 583). Left to
  itself `VZVirtualMachineInstance` makes an 8-thread group and shuts it down only in its own `stop()`,
  which Hibernate never calls — each VM instance a host made kept 8 threads + 8 kqueues forever (582;
  thread cap 6,144). `hardening leak` is the regression test (threads, fds, footprint flat).
- **Quit lets a just-started program settle** (583). `prepareForExit(settle:)` waits out the rest of 3 s
  since the last `openSession` before it hibernates (580: Claude Code hibernated within ~1 s of its
  launch exited after the wake in 2 of ~7 runs). `hardening settle` is the test.
- **Stop decides from the phase it was CALLED in** (`perform()` reads `phase` before going busy).
- **Every VM has a memory balloon; a snapshot is never taken with it inflated** (583). A device is a
  VM input: `PinnedIdentity.memoryBalloon` comes from `PersistedSandbox.memoryBalloon` on a restore
  (nil = an older build's VM — restore it WITHOUT one) and is true on every cold boot. `wake()`
  inflates it over free guest pages and it STAYS inflated (VZ charges the pages again on deflate —
  measured). `.restoreGuestMemory` runs before every pause-for-snapshot, and `saveSnapshot` deflates
  a paused one (resume → deflate → pause): a snapshot of an inflated balloon fails to restore
  (`VZErrorDomain 12 invalid argument`). Progress is read from the guest's `/proc/meminfo`
  `Balloon:` line — VZ offers DEFLATE_ON_OOM, so MemTotal never moves.
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
  VM is crash-consistent at best, so it is marked `needsFsck` and the next boot from it runs e2fsck
  first (`FsckHelper`) — journal or not. e2fsck runs on the image FILE over virtio-fs: a container's
  device cgroup refuses a raw block node even to a privileged exec.
- **A kept disk that was not cleanly unmounted is replayed or e2fsck'd before it cold-boots** (583,
  587). Hibernate stops the VM at the VZ level, so a discarded snapshot (`discardRestorableState`),
  a failed restore, a crash while running or a VZ-level stop fallback leaves a disk that was never
  unmounted. A JOURNALED disk (587's default, 16 MiB) is replayed by the kernel on mount — no mark,
  no e2fsck (`lineage journal`: 15/15 clean, ~380 ms). A journal-less one (`journalMiB: nil`, and
  every pre-587 disk) is marked and e2fsck'd (582: 12 of 15 such cold boots failed with `EXT4-fs
  error … doubly allocated`). `keptDiskNeedsFsck(_:snapshotPresent:journaled:)` decides from the
  disks' superblocks (`disksJournaled`); `hardening discard` pins the journal-less path.
- **The journal is a key input** (587): `ImageSpec.journalMiB` is in the bake key and the base key,
  `SandboxSpec.journalMiB` in the prepared-disk key (a journal-less one keeps its pre-587 key, and so
  does the e2fsck helper's). A record written before 587 decodes as `nil` = no journal — its disks
  have none. Never default a DECODED value to 16.
- **Hibernate and Stop sync the guest first** (587, `.syncGuest`, best effort): a discarded
  hibernation lost the last ~5 s of writes in every journal mode (586). It also records `df` usage for
  `DiskAccounting`'s fallback garbage.
- **Mount options are not VM inputs** (587): `discard` on the root and state disks goes to the guest's
  mount only (Containerization maps only `ro` into the VZ attachment), so a snapshot taken before 587
  restores unchanged (587 proved it with `lineage compat-wake`, retired in 592).
- **Children never depend on a parent's FILE** (587): a base, an image and a sandbox are APFS clones;
  deleting or re-deriving a parent never changes a child (`lineage children`). Maintenance
  (`reclaim`/`rederive`) touches only blocks ext4 marks free, refuses any disk that is not cleanly
  unmounted (its bitmaps would be stale), and `rederive` replaces the root disk only by an atomic
  rename after verifying the new one.
- **Metadata dates have fractional seconds** (`ImageBaker.encoder`): restore points taken within one
  second must sort in the order they were taken.
- **A proxied VM has NO NIC; the host proxy is the only way out** (580). The guest shim decides
  nothing. Every boot, crash restore and wake re-registers the proxy's vsock listener
  (`listenForEgress`) — the listener happened to survive a same-process wake in the probe, but a
  crash restore is a new VM.
- **`lo` needs a global-scope source address** (`lo:doz`, 169.254.255.254/32, set by doznet):
  lo's 127.0.0.1 is host-scoped, so without it an outbound socket gets source 0.0.0.0, its SYN is
  still redirected, and every later segment is dropped — a silent stall, not an error.
- **Never `EmbeddedChannel.writeOutbound` / `.finish()` / `close().wait()` with NIOSSL in the
  pipeline.** `writeOutbound` waits on a write promise NIOSSL completes only after the handshake;
  `finish()` waits on close, which waits for the peer's close_notify. Each hung a proxy thread
  forever. Use `writeAndFlush(_, promise: nil)` and `close(promise: nil)`, then drain.
- **A real key given to `openSession`/`exec` is moved into the vault** and replaced by a
  placeholder; keep it that way — "keys never enter the sandbox" rests on it.
- **Claude Code starts set up and without permission prompts** (owner ruling 2026-09-27, 585).
  The claude-code image spec's `claudeLauncher` step installs `~/.local/bin/claude` (first on the
  agent's PATH). It pre-seeds `hasCompletedOnboarding`, the SESSION's placeholder in
  `customApiKeyResponses.approved` (placeholders are minted per session, so a fixed approval can
  never work), `projects[cwd].hasTrustDialogAccepted`, and `settings.json`
  `skipDangerousModePermissionPrompt`, then execs `/usr/local/bin/claude
  --dangerously-skip-permissions`. `DOZ_CLAUDE_PERMISSIONS=ask` and root keep the prompts.
  The script spells the key variable's name apart, because no image spec may name a credential
  (`ImageSpecTests`). These keys were found by diffing the config before and after Claude Code
  2.1.227's own screens, so re-check them when the pin moves.
- **The `doz` host (585) is the ONE owner of a store's VMs.** It holds `<store>/host.lock` for its
  whole life and loads nothing before it has it (a new host waits for an exiting one — otherwise it
  would read a record still saying `running` and report a live sandbox as died). The launcher is a
  detached child with ONLY stdin/stdout/stderr (`POSIX_SPAWN_CLOEXEC_DEFAULT`): a host that inherited
  a caller's pipe kept a test harness waiting on EOF. No launchd agent.
- **An update must never cost a sleeping sandbox its sessions** (591 incident: `make install-cli`
  overwrote the installed `doz` IN PLACE while a host ran from it; macOS invalidated the process's
  code and VZ refused every VM with "Internal Virtualization error"; quitting that host then ran the stop
  steps on two failed wakes and deleted their snapshots). The rules that came of it:
  - **Install by rename, never in place** (`install-cli`: copy + sign as `.doz.new`, `mv` over): a
    running host keeps its own file (inode). e1af862.
  - **A quit keeps a failed wake's snapshot** (`prepareForExit`, `.failed` with a restorable state) —
    only Shut Down discards one. e1af862.
  - **A host knows its own program** (`ExecutableIdentity`: path, inode, device, size, mtime, cdhash at
    start; `SecCodeCheckValidity` of itself). Overwritten (or its code invalid) → every error of a VM op
    becomes "this host's program was updated underneath it — `doz host stop`, then retry"
    (`HostCore.explain`, also on attach), `host status` carries `executableChange`/`executableNote`, and
    `doctor` FAILS. Replaced by rename → a note; and a host whose program changed exits by itself once
    nothing is live and no client is connected (`idleLoop`), so the next command runs the new build.
  - **Every snapshot records its VM** (`PersistedSandbox.vmLayout`, `VMLayout.of` in
    `PinnedIdentity.configureVZ`: platform + machine id, CPUs, memory, kernel sha256 + file, disks in
    order with read-only, NICs + MAC, balloon, vsock, serial/console, share tags, entropy, other devices;
    the command line and `recordedBy` are informational). A wake builds FROM THE RECORD where this build
    controls it (583's balloon; 591's kernel: the recorded file, or any cached `vmlinux*` with its sha256
    — `VMLayout.kernelForRestore`) and compares the VM it is about to restore into with the record
    BEFORE VZ is asked: a difference throws `snapshotNeedsOtherBuild` (keep it asleep and wake it with
    the build that slept it, or Shut Down), and the snapshot is kept. A record without a layout (pre-591)
    is best effort, as before. `VMLayoutTests`.
  - **`make test-vm-upgrade`** (a /ship gate for any release that touches the VM, the host or the
    install): the previous DozerKit release tag's `doz` (built once from the tag, `prev-cli`; until
    the first DozerKit tag exists, a COPY of this build — 592: the pre-rename releases are not
    expected to be compatible, owner ruling) sleeps a lab and a pi sandbox with a running session and markers; this build wakes them — same session pid, screen,
    file — and then its own recorded layout; then the incident (the running host's file overwritten
    in place: the host says so, `host stop` keeps the snapshot, this build wakes it) and an idle host
    replaced by rename exiting by itself.
- **Settings are ONE closed schema** (591, owner request: `DozerSettings.schema` in
  `Sources/DozerHost/Settings.swift`). A new user-facing knob is a new entry there — its type,
  default, description, env var, flag and when it applies — never a new ad-hoc env read, localStorage
  key or file. The file (`${XDG_CONFIG_HOME:-~/.config}/dozer-sandbox/doz.toml` — Dozer Sandbox since
  592) is GENERATED from the schema on every write (all settings listed, defaults commented, only set
  values uncommented; atomic, 0600 in a 0700 dir); the reader is our own strict TOML subset (strings,
  bools, ints; anything else refused with its line). An unknown key or bad value is a warning (the
  default applies); a file that does not parse is ignored whole and NEVER overwritten. Precedence
  everywhere: flag > env > file > default, and every value carries its source. The web route
  (`/api/v1/settings`) takes one `{key, value}` or `{key, reset: true}`, strictly decoded, CSRF-checked;
  the UI never sets a host path (`store.path`, `kernel.*`) nor a value the environment or a flag
  sets. NOT settable (security): the web limits and checks, tickets, paste caps, guest-binary
  overrides, credentials; `ui.terminals` can only take away. Tests use a scratch XDG_CONFIG_HOME
  (the Makefile's test targets export one; the CLI harness sets its own under its store); the web
  server's default `WebSettingsStore(environment: [:])` reads no file.
- **Looking never starts the host.** Read-only commands answer from the store in-process
  (`HostCore(readOnly: true)`) unless a host runs — or a record says a VM was live when its host went
  away, which only a host can recover. A short request does not reset the idle clock; an open
  attach or stream does.
- **The attach relay adopts the session BEFORE it answers**, and the client sends what was typed
  ahead of its first connection once it reads that answer (keys typed right after `up` were lost
  otherwise — the first `test-cli` run). After that, keys for a held (sleeping) sandbox are dropped, never queued for a frozen guest.
- **Dozer never holds, uses or writes Claude Code's refresh token, and never writes a
  `Claude Code-credentials*` item** (588). It reads the Mac login's ACCESS token only; the Mac's
  Claude Code is the one writer of that token family (a second holder forks it — codecks 488
  rejected a copied `.credentials.json` for this, and for its silent fall-through to API billing).
  Renewal is the Mac's: the only thing doz may do is run the Mac's own `claude -p` (the
  keep-alive, opt-in). Every secret doz writes to the keychain goes on `security -i`'s STDIN.
- **Never inject our credential beside the guest's own** (588: the prototype added the Mac's bearer
  token next to a guest `x-api-key`). Every auth header a host's bindings use counts as "a
  credential is present"; a connection that carried the guest's own credential gets nothing
  injected afterwards. `testNeverInjectBesideTheGuestsOwnCredential` and `make test-vm-claude`.
- **A foreign credential is a fingerprint, never a value** — 12 hex of sha256, kind, a prefix of at
  most 13 characters — in the log, events, `key ls` and `ls`.
- **Placeholders persist as sha256 hashes** (`doz.json` `placeholderHashes`, D8) so a session
  survives a host restart; `shutdown`/`reset`/`rm` revoke them. A stdin key is still memory-only:
  after a host restart a sandbox holding only one has no secret, and the proxy stops decrypting.
- **No silent fallback between accounts.** A missing, expired, signed-out or held credential is
  answered by the proxy itself (401, an Anthropic-shaped JSON error Claude Code shows) with what
  to do — never another account's or an API key's.
- **virtio-fs caches:** deleting a file on the HOST that the guest has cached is not visible at once
  — tests use fresh file names (this cost an afternoon of chasing a non-bug).

### The web layer (`doz ui`, 590) — its security design is workspace `changes/590-*/590.01-DESIGN.md`

- **Loopback only, an OS-picked port, nothing else representable** (`WebLoopbackAddress`). No flag,
  environment variable or config may bind another address or a fixed port.
- **Every request: exact `Host` first** (`127.0.0.1:<port>`, the DNS-rebinding defence), then the
  closed route table, then the session. `Origin`, when present, must be exact (required on every
  unsafe method); `Sec-Fetch-Site` other than `same-origin`/`none` is refused. No response carries
  `Access-Control-Allow-*`, ever; no response reflects a request value.
- **The link's capability lives only in a URL FRAGMENT**, is exchanged ONCE (`POST /api/v1/session`,
  `Authorization: Bearer`) for an HttpOnly `SameSite=Strict` cookie named for the port, plus a CSRF
  token the page keeps in memory and sends as `X-Doz-CSRF` on every unsafe request. It never
  enters a log, a file, an event, a JSON field or a process argument — the browser is opened through
  LaunchServices (`LSOpenCFURLRef`), never `/usr/bin/open URL`; `--print-url` prints only to a TTY.
  `WebBootstrapCapability`'s description and mirror are redacted (a struct's default description
  prints its fields — DeckStack's never-conformed version still printed through `"\(cap)"`).
- **Typed routes only.** A new capability is a new `WebRoute` case and a typed `DozerWebData`
  method. Never a generic command, exec, file-read, URL-open, proxy or PTY route.
- **Actions (phase 2) are `WebAction`: a closed enum, decoded STRICTLY** (unknown action or field,
  wrong type, out-of-rule value → 400 with a fixed message that never echoes the value), each
  **exactly one `HostOp`** the CLI also sends — the web layer adds no host operation.
  `WebActionTests.testEveryActionIsExactlyOneAllowedHostOp` pins the set; `exec`, `attach`, `key-set`,
  `account-add` and `host-stop` are never reachable AS AN ACTION (591: `attach` is reachable only
  through the ticketed terminal socket below). Destructive ones (reset, rm,
  point revert/rm, image rm, account rm) carry `confirm` equal to the name. Shutdown keeps the disk,
  so it carries no `confirm` (owner, 591): the page asks with a plain dialog that can stop asking
  (the setting `ui.confirm_shutdown`, doz.toml — no longer localStorage). **No secret is ever an
  input** (owner ruling D3): keys and accounts are added with the CLI.
- **An action is an operation**: 202 at once, the host call in `WebOperations` (≤ 8 running), its
  progress and outcome as SSE `op` events. The outcome is a line written from the result — never
  the result passed through.
- **Open in Terminal** writes a one-shot `.command` file (0700, in a 0700 per-user directory; it
  runs `rm -f -- "$0"` then `exec '<doz>' attach NAME [SESSION] --store '<store>'`, names
  allowlisted, paths quoted) and `open`s it, so the user's DEFAULT app for `.command` files runs it
  (Terminal, iTerm2, Ghostty). No AppleScript, so no Automation permission and no second window
  (the AppleScript version opened two when Terminal was not running). Never a command from the browser.
- **`open-session` is serialized per sandbox** (`HostCore.sessionGate`, a `KeyedGate` held across
  its awaits — the actor alone is re-entrant) and idempotent: a concurrent or repeated open of one
  session answers "already running", and a deckhold "Address in use" re-lists and answers with the
  session that won. (590: two clicks during a first boot started two `deckhold serve`s.)
  `KeyedGateTests`, and `test-cli`'s "concurrent opens of one session".
- **A poller never counts sessions**: `ls` with `withSessions: false`. Counting runs `deckhold ls`,
  which connects to every session's holder — each connect is a line in the guest's
  `/run/deckhold/NAME.log` (tmpfs); the UI's 3 s poll grew one by 600 KB in 9 hours. A repeat of an
  in-flight action (same `WebAction.dedupeKey`) is 409.
- **The policy preview is the host's own function** (`HostCore.editedPolicy`), so the preview is
  exactly what `net-policy` applies. **Metrics CSV cells are defused** against spreadsheet formulas.
- **The UI is a CLIENT of the host** (host.sock) in its own process — it never owns a VM, and the
  host never imports `DozerWeb` (audit). Looking never starts a host (the CLI's rule, incl. its
  recovery exception); the host's event stream is followed only while a sandbox is live, so an open
  UI never keeps an idle host alive.
- **The API returns projections** (`WebModels.swift`), field by field — never a host result passed
  through. A new host field reaches the browser only when added there on purpose; no field may hold a
  secret (`testNoAPIModelHasASecretShapedField`).
- **The page renders with `textContent` only.** Hostnames, paths, session commands and notes come
  from inside a sandbox, which is untrusted. The asset compiler refuses `innerHTML`, inline script or
  style, event-handler attributes and external URLs (the CSP would refuse them anyway).
- **Edit `WebSource/`, then `make web-assets`, and commit `Resources/Web`.** `make web-assets-check`
  (run by `make test` and `Scripts/audit.sh`) fails on drift; `WebAssets` refuses to start on a
  digest mismatch. `make install-cli` copies `DozerKit_DozerWeb.bundle` beside the binary.
- **SSE is bounded**: ≤ `maximumSSEClients` streams (a same-session reconnect replaces its oldest),
  a bounded queue per stream that ends in `resync` (never a silent drop), heartbeats that re-check
  the session.

### Sandbox pages, All sessions, Lineage, Operations, templates (593) — design: workspace `changes/593-*/593.01-DESIGN.md`

- **The page is built around the sandbox.** The nav has a child per sandbox (from the overview —
  `ls` without session counts, re-read on `hello`, `changed` and an operation's end). A sandbox's page
  is a PERSISTENT section (`#sbx`): the control bar and the details panel re-render; `#terminals` never
  does (591's rule). Terminals are per sandbox (`termUI.by[name]`: split, selected, focused pane); another
  sandbox's stay open, hidden (the 16-per-UI cap is the server's, unchanged). Arriving attaches to the
  sandbox's own session ONLY when the sandbox runs and that session runs — never a session opened, never a
  sleeping sandbox's (it would keep the host alive: T3). `#/sandbox/NAME/SESSION` addresses a tab; a tab
  change `replaceState`s it (no route).
- **All sessions (the grid) holds engines only on screen**: a tile is a WATCH terminal (same ticket,
  socket and frame), laid out at 960 × 560 and CSS-scaled; an `IntersectionObserver` attaches and
  detaches, and at most `ui.grid_live_tiles` are live. A non-running sandbox is a static tile — no
  terminal, so an open grid never keeps a host alive. Sessions are listed (`deckhold ls` in the guest)
  on entry, Refresh, and `changed` at most every 10 s — never on the 3 s poll.
- **Operations is its own page** (no block on top of other pages); the nav badge counts running
  operations and shows a dot for a failure that ended after the page was last viewed.
- **`image-tree` is a read** (answered in-process when no host runs), measured OFF the host actor;
  the page fetches it only when Lineage is shown. `ImageTree.build` is pure (unit-tested).
- **Progress is ONE view in two terminals** (owner, 593): `ProgressBoard` + `ProgressTerminal`
  (`Sources/DozerHost/ProgressView.swift`) render the host's events for the web boot view (the
  bridge, ticking every 120 ms) AND the CLI's stderr (a 100 ms timer while the request blocks).
  Animated: the step under way (`started` … `step`/`failed`, same label), a transfer's bar, the last 2
  output lines — a live block ERASED and redrawn under each finished line, so the scrollback holds
  finished lines only. Plain (`ui.progress`, `$DOZ_PROGRESS`, `--progress plain`; always off a TTY, with
  --json or NO_COLOR): one line per step + a download summary, no redraw. The library emits
  `.stepStarted/.stepFailed` from every `timed`, `.transfer` from an OCI pull (`PullMeter`) and `.output`
  from a bake step (`OutputTail`): both ≤ 4 events/s; guest output is made inert (`InertText`: CSI,
  OSC/DCS/APC strings and every control character removed) in the library and again in the view.
  Digests are trimmed to 12 hex for people. Output lines are live-only: not in host.log or Activity.
- **Every button has an icon** (owner, 593): Lucide (`vendor/lucide-static/`, pinned like ghostty-web;
  `serve: icon`) compiled by `build-web-assets.swift` into ONE sprite of `<symbol>`s — the compiler
  admits an icon file only as geometry (path/circle/ellipse/line/polyline/polygon/rect with geometry
  attributes, `fill` only currentColor/none), never script, style, links or handlers; the page names the
  hashed sprite in `<meta name="doz-icons">`. `icon(name)` builds `<svg class="icon"><use href>` with
  `createElementNS` (aria-hidden; the button keeps its text or aria-label); `btn()` takes `opts.icon`,
  else `iconFor(label)` (ONE map: the exact label, then its first word). The fallback `circle-dot` is a
  bug the probe fails on. Colour is CSS (`stroke: currentColor`). The CSP is unchanged (`img-src 'self'`
  covers `<use>`). The compiler's external-URL rule ignores only the SVG namespace string.
- **A template NEVER contains the state disk** (the agent's logins and history) — `saveAsImage` clones
  the root only; `RestorePointTests.test_aTemplateNeverHoldsTheStateDisk` and `make test-vm-templates`
  keep it. From a live sandbox, `template-create` and `duplicate` go through a TEMPORARY restore point
  (sync, pause, clone, resume), deleted afterwards. `duplicate`'s state disk starts fresh unless
  `copyState`; its workspace must exist and be readable (`HostCore.validatedWorkspace`) — never created.

### Browser terminals (591, on by default — owner ruling) — design: workspace `changes/591-*/591.01-DESIGN.md`

- **A terminal is two steps.** `POST …/terminal-ticket` (CSRF, strict body) mints a 256-bit ticket that
  works ONCE within 30 s, bound to the browser session's cookie, the sandbox, the session and the mode
  (`WebTerminalTicketStore`); `GET …/terminal-socket` upgrades only with exact Host, Origin REQUIRED,
  Fetch Metadata, the cookie and exactly one `doz-ticket.<t>` in `Sec-WebSocket-Protocol` (never the
  URL; the answer echoes only `doz-terminal.v1`). A ticket presented wrongly is spent.
- **NIO's typed upgrader drops a refused request's head** (only what followed it reaches the HTTP
  channel): a refusal is stashed by `shouldUpgrade` and answered from there (`UpgradeGate`), with
  `Connection: close`. `WebTerminalHTTPTests.testTheUpgradeRefuses…` hangs if that regresses.
- **The bridge adds no HostOp**: it sends the CLI's `attach` with `wake: false` (a watcher: size 0×0 =
  keep the session's size), relays PULLED reads (backpressure — no queue grows), strips `0xFF` from
  input (the attach wire's frame byte), turns the host's end notice into an `ended` frame (never on
  screen — `holdBack` covers the `ESC[0m` in front), and reattaches across a hibernation.
- **The 541 rule lives in the UI process** (`TerminalInputClassifier`, SandboxLab's cases as tests):
  while not running, a keystroke starts `resume`/`wake` as an ordinary operation and is DROPPED; a
  control report is dropped and counted. Input for a running sandbox goes straight through. Phases come
  from the monitor (which terminals keep polling); a hibernated or off phase reported while a terminal is
  attached with its screen is stale and ignored.
- **The cover is derived here** (`WebTerminalCover`, SandboxLab's PaneCover wording); the page only draws
  it. Reattaching lasts until the first bytes, ≤ 10 s.
- **Caps**: 64 KiB frames (NIO answers 1009), a 1 MiB-burst / 256 KiB/s input budget per terminal
  counting watchers too (1008 `input-over-cap`), 16 terminals per UI, 16 pending tickets per session,
  90 s liveness (the page pings every 25 s), sign-out → 1008, shutdown → 1001.
- **Vendored assets are a separate class**: `WebSource/vendor/<pkg>/` holds registry-tarball files
  byte-for-byte with `VENDOR.json` (tarball URL + integrity, each file's sha256, SPDX licence on the
  allowlist). The compiler checks the pins, refuses unlisted files and never rewrites vendored bytes;
  the page's own rules are unchanged for `index.html`/`app.css`/`app.js`. `application/wasm` is served
  only for a `vendor` manifest entry. To update: new tarball from the registry → same files → new
  `VENDOR.json` → `make web-assets` → the browser probe. The page has TWO documents (`index.html` → `/`,
  `terminal.html` → `/terminal-frame`), each with its one script and style; the page-code rules apply to
  all six files.
- **An open terminal keeps the host alive** (T3: an explicit attach, like `doz attach` — even held on
  a hibernated sandbox); the dashboard alone still lets it idle out (`t3-host-alive.mjs`).
- **The engine runs ONLY in a sandboxed, opaque-origin iframe** (owner ruling T2): `/terminal-frame`
  (`terminal.html` + `frame.js` + `frame.css`), loaded with `sandbox="allow-scripts"` only — no cookie,
  storage, same-origin access, popups or forms. Its CSP (`WebSecurity.frameHeaders`) allows
  `'wasm-unsafe-eval'` and `connect-src 'none'`: the PAGE fetches the vendored `.wasm` and posts each
  frame its own copy (one instance per terminal), and keeps the WebSocket. The page's CSP gained only
  `frame-src 'self'` (no WebAssembly in the page). The frame's script/style and the engine's script are
  served to the opaque origin without the Origin/Fetch-Metadata checks and with CORP `cross-origin`
  (`WebAssets.isFrameAsset`); every other file keeps the page's rules. A response's own header
  REPLACES a default of that name (the frame's CSP/XFO) — never a second copy.
- **The frame protocol is closed and checked on both sides** (frame.js `valid`, app.js
  `validFrameMessage`): source window, opaque origin, known type, exact fields, typed and capped;
  anything else is dropped and counted. Page → frame: init / write / paste / focus / keep-scrollback.
  Frame → page: ready / opened / data / resize / title / paste / paste-too-big / failed.
- **The frame wraps the engine** (ghostty-web 0.4.0 fails the bar alone): Cmd/Ctrl-clicks dropped and
  `window.open` refused (no link opens; the sandbox has no popups either), the engine's paste handler
  never runs (the frame sends the text to the page, which applies our port of Ghostty 1.3.0's paste
  `encode` and the confirm/refuse thresholds, then posts it back), drops refused, focus reports sent
  by the frame (the engine does not), `scrollback` given in BYTES (upstream #140). The browser probe
  (`probes/591-*/browser-terminal.mjs`) proves each, and that the frame cannot
  read a cookie, fetch, open a socket or reach the page; re-run it on any engine bump.
- **The boot view** (owner request): an off/failed/booting sandbox's terminal waits (cover with Start),
  follows the host's events BEFORE saying so (the page starts the sandbox only once the terminal waits —
  `startWithBootView`), then writes the host's steps/progress and — from "VM created" — the `console
  --follow` stream into the pane as inert text (`WebTerminalWire.bootText`: every control character
  removed; 1000 B lines; 1 MiB in all). When it runs: the image's own session is opened (`open-session`,
  when the terminal asked for none), the streams are stopped AND drained, `boot-done` tells the page to
  scroll the screen into the scrollback, and the first SNAPSHOT's full reset is rewritten to a soft
  reset + clear screen (`keepingScrollback`) — the boot log stays above the session. A wake reports
  "woke in N s" (a state `notice`).
- **`console` is a host op and a CLI command** (`doz console NAME [--follow]`, D5): the lines so far
  (in-process when no host runs), or a stream of `console` events tailing `Sandbox.bootLogURL` across a
  cold boot's recreated log (`BootConsoleTail`). The CLI never prints the guest's control characters.

## Verifying changes

```bash
make build     # swift build — Xcode 27 needs the --build-system native pin the Makefile probes for
make test      # unit tests: no VM, no entitlement. Never --parallel. (web-assets-check first)
make web-assets        # 590: regenerate Sources/DozerWeb/Resources/Web after editing WebSource/ (commit it)
make audit     # Scripts/audit.sh
make test-vm   # the VM integration suite — see below
make cli       # 585: build + sign .build/debug/doz
make test-cli  # 585: the signed doz from separate processes, scratch store $TMPDIR/doz-clitest-store
make test-vm-claude  # 588: Claude credentials through the proxy with a FAKE key (DOZ_TEST_CLAUDE_LOGIN=1 adds this Mac's login, read-only)
make test-vm-upgrade # 591: the previous release sleeps sandboxes, this build wakes them; the in-place overwrite incident (scratch store $TMPDIR/doz-upgrade-store)
make test-vm-templates # 593: templates and duplicates on pi — no state disk in a template; duplicate's workspace and fresh/copied state disk
```

### The VM integration tests need an ENTITLED host — how

`swift test` runs an XCTest bundle inside `xctest`, which does not (and cannot be made to) carry
`com.apple.security.virtualization`, so no VM can start there. The integration suite is therefore
an executable target, `doz-vmtest`, that `make test-vm`:

1. builds (`swift build --product doz-vmtest`),
2. ad-hoc signs with `Scripts/vmtest.entitlements` (`codesign --force --sign - --entitlements …`),
3. runs under a watchdog (`perl -e 'alarm 420; exec @ARGV' …`) so a VM op that never completes
   fails the run instead of wedging it; stdout is line-buffered so a hang shows where it stopped.

It prints one `PASS`/`FAIL` line per check and `vmtest: ALL PASS` last. Modes: `all` (default),
`network` (580, `make test-vm-network`: the claude-code image proxied; live-prompt check SKIPs
without `ANTHROPIC_API_KEY`), `lineage [part]` (587, `make test-vm-lineage`: bake, discard, sync,
journal, nojournal, accounting, reclaim, rederive, children; 587's v0.4.0 compatibility item was
retired by 592), `netdebug --script '…'`, `lifecycle`, `crash` (spawns itself as `crash-save` — start, session, sleep to disk, exit without
stopping — then restores in the parent), `crash-restore`.

- **Store:** `VMTEST_STORE` (default `$TMPDIR/doz-vmtest-store`) — a SCRATCH store, never an app's
  storage root. The first run in a new store pulls images and bakes `bash ncurses` (~40 s, network).
- **Coexistence:** sandboxes are named `vmtest` / `vmtest-crash`; the suite touches nothing outside
  its store and never kills a process it did not start, so SandboxLab or a probe can run beside it.
- **Kernel:** the library's pinned kernel via `KernelProvider`, cached in `KERNEL_CACHE` (exported
  as `$DOZ_KERNEL_CACHE`; default: under the store). `make kernel` fetches it alone.
  `DOZ_KERNEL=<path>` boots an explicit kernel instead.
- A VM test is green when it is green **twice in a row**.

## Contributing

Issues and fixes are welcome directly; see `CONTRIBUTING.md`.
