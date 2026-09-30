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
| `doz` (executable, 585) | `doz` → `DozerCLI` (commands) → `DozerHost` (the host + its client) | `DozerKit`; `swift-argument-parser` (`ArgumentParser`) in `DozerCLI`/`doz` ONLY; the system `SQLite3` in `DozerHost` (metrics); 594: `jpsim/Yams` **exact** `6.2.2` in `DozerCLI` ONLY (`doz_project.yaml`, owner ruling D9 — the audit enforces the pin and the confinement) |
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
| `Sources/DozerHost/Preparations.swift`, `Onboarding.swift`, `AgentPrompt.swift`; `Sources/DozerCLI/OnboardCommands.swift`, `ProjectFile.swift`, `Prompting.swift`, `UninstallCommand.swift`; `Sources/doz-vmtest/OnboardingSuite.swift`, `PullBench.swift` | 594: image preparation in the host (single-flight, joined, cancelled) + `onboarded.json`; onboarding's checks / account step / settings-only-when-missing; the agent's environment prompt + the `dozer` skill; `doz onboard`/`init`/`uninstall`, `doz_project.yaml` (Yams), TTY questions; `make test-cli`'s onboarding part (`make test-cli-onboarding`); `make pullbench` (D12) |
| `Sources/DozerKit/SavedScreens.swift`; `Sources/DozerHost/TerminalLayout.swift`; `Sources/DozerWeb/WebSessionMemory.swift` | 593 §9: the sessions' saved screens (`<sandbox>/screens/NAME.{vt,txt,json}`; the capture is `Sandbox.captureScreensLocked`, the `.captureScreens` step); the web UI's terminal layout kept by the host (`terminal-layout.json`); their web projections and the layout's strict decoder |
| `Sources/DozerHost/BootLogs.swift`; `Sources/DozerWeb/WebBootLogs.swift` | 593: each sandbox's kept boots (`<sandbox>/boots/`), the recorder, the one renderer; the web's Boot log projections |
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
  2.1.227's own screens, so re-check them when the pin moves — and since 594 images install
  `latest` by default, `make test-cli-onboarding` re-checks the launcher (argv, skill, a session with
  a key) on whatever the registry's latest is.
- **Agent credentials (594, `AgentCredentials.swift`; the table is `AgentImages.credentials`):**
  Claude Code: `mac`, `setup-token`, `api-key`; pi: `api-key` ONLY (it reads `ANTHROPIC_API_KEY`;
  never hand it a Claude subscription — `applyAccount` clears both bindings, with a notice, for an
  account the agent cannot use). `createProblem` runs in `HostCore.create` and `duplicate` (proxied
  networks only; an explicit `none` is allowed, the default resolving to none is not for pi), in the
  CLI's `preflightAgentAccount` (create/up/init; on a TTY it offers a fitting account or the hidden
  paste of a key) and, through `WebAccounts.agents`, in the web forms (`accountChooser`).
  `useAccount` refuses an incompatible account. `SandboxInfo.credentialProblem` is the page's
  banner and switches the facts block to "no credential you can use is attached". Room for other
  providers: `AgentCredentialSupport(provider:accountKinds:)`.
- **The agent has passwordless sudo by default** (594 W23, owner ruling 2026-09-30). The dev baseline
  installs `sudo` and KEEPS apt's package lists (~18 MiB, shared by APFS clones; `apt-get clean` only),
  and `apt-utils` FIRST (W24: otherwise every install says "debconf: delaying package configuration");
  the rule itself is never baked: `GuestCommand.agentSudoScript` writes `/etc/sudoers.d/dozer-agent`
  (0440, root, `user ALL=(ALL) NOPASSWD:ALL`, put in place only after `/usr/sbin/visudo -cf` accepts it;
  absolute paths — a utility exec's PATH may lack sbin) or removes it — at every fresh boot
  (`prepareGuest`, from `Sandbox.agentSudo`) and every agent session start (`deliverAgentPrompt`), so a
  toggle needs no rebake. The value: `SandboxConfig.agentSudo` (`--[no-]agent-sudo`, `agent_sudo` in
  doz_project.yaml, synced by `doz up` through `agent-prompt`'s `agentSudo`/`clearAgentSudo`) else the
  setting `sandbox.agent_sudo` (read per request — `HostCore.agentSudo`). The facts block and skill say
  it (`sandbox.sudo`, `sudo.description`). **Security: root inside the VM must reach nothing the agent
  cannot** — the boundary is the VM (no NIC; the only way out is the proxy's vsock listener, where the
  policy is judged), the proxy/allow list and the absent credentials (the vault stays on the Mac).
  Root must never reach: the host's socket or the store (never shared; `Workspace` refuses the store as
  a workspace), another sandbox (separate VMs, no network between them), the Mac's keychain or login
  (read only by the host), any other vsock listener on the Mac. `make test-cli-agentsudo` checks:
  sudo apt-get install as the agent, `--no-agent-sudo`, the setting at the next boot, and as root: only
  `lo`, a denied host still denied, no vsock listener but the proxy (5800, the positive control), no
  store or host socket in the guest. Keep any new host-side vsock listener, share or credential path
  out of the guest's reach, and extend that check when one is added.
- **Agent tools:** the dev baseline bakes `fd-find` (+ `/usr/local/bin/fd`) and `ripgrep`, the lab
  `fd` — agents (pi) download them from GitHub otherwise; `api.github.com` stays out of the agent
  preset, `pi.dev` is in it.
- **Agent versions (594, `AgentVersions.swift`):** `images.claude_code_version` / `images.pi_version`
  = `latest` (default) or exact. `latest` is resolved on the MAC at preparation time
  (`NpmRegistry`: `<registry>/<package>/latest` → version + sha512 integrity, both validated —
  they go into a bake script) and installed at that exact version by `AgentImages.claudeCode(_:)` /
  `pi(_:)`; `ImageSpec.agent` records it, so it is in the bake key. `AgentVersions.spec(purpose:)`
  is synchronous and uses only the store: `.create` → the newest image PREPARED for this build (no
  waiting), `.prepare` → the version the setting names (cached latest, a known exact, else the pin
  when the registry was never asked, else a clear error). `HostCore.freshen` is the only thing that
  asks the registry (hourly cache in `<store>/agent-versions.json`, 5-min back-off after a failure)
  and, when the prepared image is behind, starts a background preparation ("update to X"). Only the
  real host asks (`HostServer` passes `.fromEnvironment()`; `DOZ_TEST_NPM_REGISTRY=offline|URL` for
  tests); in-process hosts and unit tests have `.disabled` and resolve to the pin. Claude Code's own
  updater is off in sessions (`DISABLE_AUTOUPDATER`, `DISABLE_UPDATES` — both honoured by 2.1.227).
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
- **A host never lives in a client's process tree** (593 incident, 2026-09-29: a host auto-started by
  `doz ui` was the UI's CHILD — own session, but its descendant; a tool that stopped the UI's tree
  SIGTERMed the host mid-hibernate and a sandbox lost its programs). `HostLauncher.spawn` is the ONE
  way a host is started for a client (`HostClient.connect(autostart:)`, `doz host start`): a double
  spawn — an intermediate `doz host start --launch-detached` (own session) spawns the host
  (`--foreground --launched`, own session and group, stdin /dev/null, stdout+stderr the log, no other
  descriptor), prints its pid and exits, so the host's parent is launchd (1). The client still waits
  for its socket. Only a person's `doz host start --foreground` runs in a caller's tree. `host status`
  carries `parentPid`, `sessionID`, `launchedDetached`; `doctor` warns when a launched host's parent
  isn't 1. `make test-cli` (`cliHostDetachChecks`) kills a client's group and every descendant (TERM,
  then KILL) and checks the host, a running sandbox and its session survive.
- **A host stop shows its progress** (594 W22, `HostStop.swift`): `host-stop` streams, per sandbox, a
  `started` "hibernating X" and a `step` "hibernated X (snapshot …)" / `failed` (why + "shut down
  instead") — `HostEvent.startedAs` ties an end to its differently-worded start — then the host's own
  last step, and answers `HostStopResult` (rows; an older host answers the string "stopped", still
  read). `Sandbox.prepareForExit` returns its `ExitOutcome`. Every stopping client uses
  `stopHostShowingProgress` (the CLI's progress view: animated on a tty, plain lines else) or, in the
  UI, Restart host's operation (`WebOperation.lines`). A host that dies mid-stop: the client reports
  what it saw (`HostStopView.seen`), never hangs. `make test-cli-hoststop` (in `test-cli` too).
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
  environment variable or config may bind another address or a fixed port. The one exception (594
  W18/W19): the port the OS gave this store's LAST UI (`<store>/ui.port`), asked for again when
  nothing listens there (`WebLoopbackAddress(reusing:)`: ≥ 1024, else the OS picks).
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
  through the ticketed terminal socket below; 594 W20: `host-stop` only inside `host-restart`, which
  `HostWebData.restartHost` refuses unless the running host is an OLDER build than the UI). Destructive ones (reset, rm,
  point revert/rm, image rm, account rm) carry `confirm` equal to the name. Shutdown keeps the disk,
  so it carries no `confirm` (owner, 591): the page asks with a plain dialog that can stop asking
  (the setting `ui.confirm_shutdown`, doz.toml — no longer localStorage). **No secret is ever an
  action's input** (590's D3). Since 594 (owner ruling) an ACCOUNT's key or token may be typed in a
  masked field — through the one typed route `POST /api/v1/accounts`, never an action, while
  `ui.allow_secret_entry` (see the 594 section); and a sandbox's own key through `POST
  /api/v1/sandboxes/NAME/key` (owner ruling, same setting and rules).
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
- **The UI watches the host** (594 W18, `WebHostWatch` — pure, unit-tested): before each overview the
  monitor PROBES without starting anything (`hostProbe`: the lock, a stale `host.pid` = killed, records
  left live, the last host's own exit line in `host.log` — `HostExitReason`), because the overview
  starts a host to recover a crash and that gap is the only thing that tells a kill from a clean stop.
  Each transition — running (with `previousVersion` on another build), stopped (hibernated), died
  (the sandboxes that ran) — is told ONCE as SSE `host` (also to Activity). The poll never autostarts
  a host that holds its lock (it may be stopping: an open page must never undo `doz host stop`), and a
  terminal's REattach waits for a host rather than start one. "Start host" is the `host-start` action
  = the CLI's `ping` with autostart (HostLauncher, detached); `host stop` stays out of the browser
  except W20's guarded Restart host. The mismatch note (`WebVersionNote`, semver with pre-release
  order — `WebVersion`) advises the OLDER side.
- **`doz ui` gone = the page paused** (594 W21): after 1.5 s of failed reconnects (never on a blip)
  everything but `#banners` is `inert` under `#ui-overlay` (alertdialog, focus inside, Try now — the
  one retry control); the banner strip stays in front (z-order) and live — the banner says what
  happened, the overlay that the page is paused. The overlay is BUILT on `hello`: its icon is a
  `<use>` of the served sprite, which a page without its server cannot fetch. A rotated link turns
  it into "This page was signed out". The HOST stopping stays a banner (the page still works).
- **One UI per store, one tab** (594 W19): `ui.sock` answers `link`, `rotate` and `status` (origin +
  open pages — no key). `doz ui` while one runs opens a tab only per `ui.open_browser` (auto: when no
  page is open) / `--open` / `--no-open`. A restarted UI binds the last port and loads
  `<store>/ui.sessions` (0600: SHA-256 of each cookie + its CSRF token, for that port only) so an open
  page reconnects silently; it then waits ≤ 2.5 s for a page before opening a tab, and tells it
  (`notice`). `--new-link` / `ui link --rotate` revoke every session (`end: rotated`). The reasoning is
  on `WebSessionStore` — keep it with any change. `DOZ_TEST_BROWSER_LOG` (records the origin a tab
  would open, never the link) and `DOZ_TEST_VERSION` (stamps a build) are the probes' seams.
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
  `copyState`; `isolated` drops the source's workspace.
- **A workspace that does not exist is MADE** (594, `Workspace.swift`): `Workspace.prepare` (normalize —
  absolute or `~/`, links in the existing part resolved — then `refusal`, then `mkdir -p`) runs in
  `create` and `duplicate` BEFORE the VM is configured; `Workspace.undo` removes, innermost first, only
  folders it made and only while empty, when the create fails. Refused, never made: an existing file, a
  missing folder in the store or under a system location (`Workspace.systemPrefixes`), `/`, home.
  No workspace = **isolated** (the one word: `ls`, `--json` `"isolated": true` with `"workspace": null`,
  the UI badge, the agent's facts). The UI's defaults (`Workspace.suggestedName`/`defaultPath`,
  `defaults.projects_dir` — a path, so `doz config set` only) and the Mac's folder picker are
  `WebWorkspace.swift`: `POST /api/v1/workspace/check` (makes nothing) and `/choose` (a FIXED
  AppleScript run by `/usr/bin/osascript`, the start folder its argv; one at a time → 409; tests use
  `DOZ_TEST_FOLDER_PICKER=/path|cancel` or `setRunner` — never a real dialog).

### Onboarding, projects, the agent's environment prompt (594) — design: workspace `changes/594-*/594.01-DESIGN.md`

- **Image preparation is the HOST's** (`Preparations.swift`): kernel + guest init (`Sandbox.prepareAssets`)
  + base pull + bake (the lab: its prepared disk). ONE per image name at a time (`HostCore.preparations`);
  `onboard`, `prepare`, `image bake`, the UI and a cold `start` needing the image all JOIN the running one
  (`follow` subscribes; the bounded event buffer is replayed to a joiner). A client going away never
  cancels it; `prepare-cancel` does (checked between bake steps; the VM is stopped in a task of its own
  so cancellation cannot skip the clean stop). A running preparation keeps the host up (`idleLoop`);
  quitting the host cancels it. "Prepared" means THIS build's bake key (`HostCore.isPrepared`,
  `ImageRow.current`) — a re-run prepares nothing. Tests substitute the work: `setPreparationRunner`.
  **Its progress as data** (`PreparationInfo`): `stepIndex`/`plannedSteps` (N of M — M from the last
  run's step count, else `HostCore.plannedSteps(image)`), `steps` (finished: step · failed with its last
  output · transfer), the 593 `ProgressBoard` tail (6 lines), and estimates ONLY from
  `<store>/preparations.json` (`PreparationRecord`, saved on success; steps keyed so a digest or a
  size in the label does not break the match). The UI's `prepCard` renders it; the probe
  `probes/594-*/progress.mjs` pins it. A bake step's output is the tail, so keep steps' output visible
  (the dev baseline's apt is not silenced).
- **`<store>/onboarded.json`, never `state.json`** — that name at the store's root is Containerization's
  image-store index. The HOST writes the record once every chosen image is ready, so a detached CLI
  (Ctrl-C = detach, exit 130) or a closed wizard still completes the onboarding.
- **Settings and the prompt template are written ONLY when missing** (`Onboarding.write…IfMissing`) — an
  existing file is never touched, by the CLI or the UI's `POST /api/v1/onboarding/config`.
- **The account step never logs in and never reads a refresh token for use.** Options: `mac`, `api-key`,
  `setup-token`, `later` ("Decide later" — owner ruling: one option for none/skip). A key or a token goes
  ONLY through `HostRequest.accountAdd` — the request `doz account add` sends (the login keychain, the one
  check request, `--plan`) — from `doz onboard`'s no-echo prompt (off a TTY only with `--secret-stdin`) or
  the web UI's masked field. `doz onboard --account …` skips the Claude Code checks entirely; `doz ui`
  under `DOZ_TEST_NO_MAC_LOGIN=1` (a test seam, the probes') never looks at the Mac's login.
- **Secret entry in the browser** (owner ruling, 594): `ui.allow_secret_entry` (default on; the UI can turn
  it off, never on — a reset would turn it on, so that is refused too). On: `POST /api/v1/accounts` — a
  typed route, deliberately NOT a `WebAction` (an action is an operation: a title, progress, SSE); strict
  body `{name, kind, secret, plan?}`; the page empties the masked field before the request; refusals never
  echo; a failure's message is scrubbed (`WebAccountAdd.scrub`); `WebAccountAdd`'s description is redacted.
  Off: 403 `secret-entry-off` and the page shows the command. `account-add` stays OUT of the action set.
  A sandbox's own key: `POST /api/v1/sandboxes/NAME/key`, strict `{secret}` (the binding — anthropic —
  and the sandbox are not the body's), `HostRequest.keySet` (source `browser`) — `doz key set`'s own
  request; `WebKeySet` redacted, errors scrubbed (`WebSecretText`); `key-set` stays OUT of the action set.
- **Unattended tests never touch the login keychain**: a real host under `DOZ_TEST_CREDENTIALS=memory`
  keeps accounts' secrets in its memory and verifies nothing (`CredentialServices.forHost`, said in
  host.log). `make test-cli`'s onboarding part and the wizard probe use it.
- **The environment prompt** (`AgentPrompt.swift`) is rendered from the sandbox's CURRENT facts at every
  `open-session` of a claude-code/pi sandbox and written by a root utility exec (contents base64 in the
  script): `/run/dozer/agent-prompt.md` and ONLY the skill dir `~/.claude/skills/dozer` (pi:
  `~/.pi/agent/skills/dozer`) — never CLAUDE.md/AGENTS.md. Claude Code gets it through its launcher
  (`--append-system-prompt "$(cat …)"`, not for subcommands nor when the caller gives a system prompt —
  a bake-key change); pi's own session gets `--append-system-prompt FILE` (pi reads an existing path).
  Variables are a CLOSED list; an unknown one refuses the session with its name and file. `agent.prompt
  = false` removes both at the next session.
- **`doz_project.yaml`** is parsed by hand on Yams's node tree with the parser kept alive (anchors are
  weak): a closed key set, errors with the line, anchors/aliases refused top-down (no alias expansion
  is ever walked), one document, 64 KiB. Yams only in `Sources/DozerCLI` (audit).
- **`doz uninstall`** removes a store only if it looks like one, the settings dir only if named
  `dozer-sandbox`, and the installed doz only when THIS executable is `<prefix>/libexec/doz/doz` (the
  `bin/doz` link only if it resolves to it). Never the keychain; a running `doz ui` refuses it.
- **Tests on throwaway paths only**: `make test-cli`'s onboarding part uses `/tmp/dzo-<pid>-*` stores (a
  socket path under 104 bytes) seeded from the vmtest store, each with its own XDG_CONFIG_HOME; the
  wizard probe (`probes/594-*/run-wizard-probe.sh`) a fresh `/tmp/dzw-*` store.

### Session memory and saved screens (593 §9, owner 2026-09-29 — S1–S6; amended 2026-09-30)

- **Saved screens exist ONLY for a sandbox one wakes back into** — paused, asleep, hibernated (owner,
  2026-09-30: "when i shutdown the new sandbox, i should not still see the claude terminal screen").
  A SHUT-DOWN sandbox shows no session screens anywhere: shutdown, reset, rm and a host that died with
  the VM (`recoverAfterStart`) DELETE them (`.removeSavedScreens`; the host also clears the terminal
  layout on shutdown, reset and death), `sessions`/`session-screen`/`inspect` list nothing for it, and
  the page shows the plain off state (its panes close, none is persisted, no grid tile). There is no
  "ended" screen: a session whose program exited has none (the next capture removes it).
- **Screens are saved while the guest can still answer**: `.captureScreens` is the FIRST step of
  pause, sleep and hibernate from RUNNING (planner data — `LifecycleTests`); never a shutdown, never
  from another phase (the guest cannot answer). It is best effort and bounded (3 s a session, 8 s in
  all): a failure keeps the previous file and is a note — it never fails or holds up the lifecycle
  action. Quit = Hibernate captures too.
- **A capture is a momentary attach that disturbs nothing**: `deckhold pipe` as a non-terminal
  exec, written `DeckholdFrame.captureRequest` in one go — HELLO **0×0** (keep the session's size:
  no SIGWINCH, no reflow) then DUMP — read until DUMP's answer (then stdin closes and the pipe exits),
  and always `delete()`d. Nothing is typed; no focus report is sent. While attached (milliseconds)
  deckhold counts it as a viewer, so it does not answer a program's terminal query itself — accepted.
- **Stored as text, not an image**: `NAME.vt` (the SNAPSHOT: VT that redraws the screen, capped at
  2 MiB keeping the newest lines after a soft reset), `NAME.txt` (DUMP's text, every control
  character removed — what the CLI prints) and `NAME.json` (`SavedScreenInfo`). 0600 files in a 0700
  `screens/`, written atomically, and never into a sandbox directory that is gone. A capture drops the
  screens of sessions the guest no longer runs. Duplicate, fork, restore points and templates copy
  disks BY NAME — never the screens (`SavedScreensTests`).
- **The periodic capture** (`host.screen_capture_minutes`, 5; 0 = off; read at host start): each
  running, not-busy sandbox — ONE `deckhold ls`, then an attach only for sessions whose `bytes=`
  moved since their saved screen. It is serialised with the lifecycle (the sandbox's gate).
- **Looking never wakes**: `sessions` answers from the saved screens (`saved: true`, `savedAt`,
  `savedReason`) while the sandbox is paused, asleep or hibernated — in-process too; `session-screen` (read-only)
  gives one back. The CLI prints the TEXT; `--vt` writes the guest's bytes only when stdout is not a
  terminal.
- **The layout is the host's** (`terminal-layout.json` beside `doz.json`, `TerminalLayout`: one or
  two panes, ≤ 16 tabs, session names by the host's rule, mode interactive|watch). `terminal-layout`
  is a read; `terminal-layout-set` goes through the host when one runs (serialised with `rm`) and is
  otherwise answered IN-PROCESS (it is UI state, like doz.toml — writing it never starts a host); it
  refuses to create a directory. Reset clears it. The web route decodes the body STRICTLY
  (`WebTerminalLayout.decode`) and the host validates again.
- **The page** restores the stored layout once per page load (`restorePanes`) — not while the sandbox
  is under way (it waits for the next settled refresh) — and writes its panes back (debounced) only
  after that, so arriving never overwrites the stored layout with an empty page. Restored tabs load
  their engine the first time they are SHOWN (a hidden frame has no size, and an interactive attach at
  no size would resize the session). A sandbox that does not run shows its saved screens in the
  frame's `saved` mode: read-only and selectable, sending NOTHING (no keys, reports, focus reports or
  paste); a key is only announced (`{t:'key'}`) and the page starts the ordinary wake/resume action.
  Once it runs, each saved pane (and grid tile) goes live IN PLACE (`{t:'live', mode}`, then the
  attach's SNAPSHOT). A saved pane holds no socket, so it keeps no host alive (T3).
- **New is new (S4)**: New shell (shell-N, the next free name — saved names count as taken) and the
  Terminal… dialog (a new shell, or a new session running a command) never attach to a running
  session; a running one is reached through its pane, the empty area's "Open NAME" or Details ›
  Sessions. Split's watch/attach kinds stay: they name the left pane's session explicitly.

### Boot logs (593, owner 2026-09-30 — "where is the bootup terminal output stored…")

- **Every boot is kept** — each Start (`cold boot`), wake (`wake`, also a wake on use) and restore after
  a crash — by the HOST (`BootRecorder` from `beginBoot` to `endBoot` around the library call in
  `HostCore`): the sandbox's own host events of that boot (exactly what the boot view draws; never a
  connection record or a console line), that boot's part of `bootlog.log` (from its size at the start
  of a wake; all of it for a cold boot, which starts the file afresh), and `BootLogInfo` (started, kind,
  duration, result, failure). `<sandbox>/boots/b-<epoch ms>/{boot.json,events.jsonl,console.log}`,
  0700/0600, written atomically (a temporary directory renamed), never into a removed sandbox; the
  newest `host.boot_logs_kept` (5) are kept. Kept across reset, gone with `rm`, never copied by
  duplicate/fork/templates. Recording never fails a boot.
- **One renderer**: `BootLogs.render` replays the events through `ProgressBoard` +
  `ProgressTerminal.format` — the boot view's finished lines (✓/✗ with times) — then the console made
  inert (every control character removed). The CLI (`doz console --steps`, plain off a terminal) and
  the web's Boot log (`GET …/boots`, `GET …/boots/N`, rendered on the server, drawn in the frame's saved
  mode — read-only, no socket, any phase) use it. `boot-log` is a read-only host op (in-process when no
  host runs; the host adds the boot under way as number 1).

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
  anything else is dropped and counted. Page → frame: init (mode interactive | watch | saved) / write /
  paste / focus / keep-scrollback / live (593: saved → interactive | watch only) / top (593: a Boot log
  opens at its first line).
  Frame → page: ready / opened / data / resize / title / paste / paste-too-big / failed / key (593: a
  key on a saved screen, no content).
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
make test-cli-onboarding # 594: test-cli's onboarding part alone (onboard, a joining start, detach/cancel, init/up, the agent prompt, uninstall)
make test-cli-agentsudo # 594 W23: the agent's sudo in a fresh claude-code sandbox (prepares it; network), --no-agent-sudo, the setting at the next boot, root reaches no more
make test-cli-hoststop # 594 W22: test-cli's host-stop part alone (per-sandbox progress plain/animated, --json, nothing running, a host killed mid-stop)
make pullbench       # 594 D12: the node base pulled with 3 vs 6 concurrent layer downloads, fresh stores (network)
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
