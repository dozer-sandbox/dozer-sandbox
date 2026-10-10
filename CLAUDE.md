# CLAUDE.md

The engineering guide to Dozer Sandbox — for contributors and for coding agents alike: what each part is, where
the code lives, the rules that each cost a bug to learn (keep them, and their tests), and how a change is verified.
The user manual is `docs/manual/`; the developer view of the engine is `docs/DOZERKIT.md`.

**Reading the history in this repository.** Dozer is developed in a private workspace and released from here. Code
comments and a few notes below cite the feature that introduced something by its number (`591`, `599i`) and the
design notes or probes it came from (`changes/591-*/…`, `probes/…`) — those live in that workspace, not here; the
rule they explain is always stated where it is cited. "SandboxLab" is the earlier prototype app the engine grew out
of; "DeckStack" and "Deckosaurus" are sibling projects some techniques were taken from (never a dependency).

## This is an APP — the `doz` product

- **It ships as an app:** its own `VERSION` (CI's `version-check` enforces VERSION strictly greater than `main`'s);
  a release tags `v<VERSION>` and attaches `doz-<VERSION>-macos-arm64.tar.gz` (`make release`), and the update feed
  and the Homebrew formulas follow (`make publish` / `make promote` — see "Updates").
- **The Swift package is named `DozerKit`** (products `DozerKit` and `doz`). A later version moves the engine (the
  `DozerKit` target, `Guest/`, the in-VM helpers) into a library of its own; until then nothing else consumes it.
- `make audit-resolved` exists for the release gate: this repo pins no sibling library.

## Dependencies

| Product | Targets | Depends on |
|---|---|---|
| `DozerKit` | `DozerKit` (+ resources `deckhold`, `doznet`, `dozview`); test-only C target `DozMatch` (`Guest/dozview/match`) | `apple/containerization` **exact** `0.47.0`: `Containerization`, `ContainerizationArchive` (the kernel tarball), `ContainerizationExtras`, `ContainerizationOCI`, `ContainerizationOS`; since 580 `swift-nio` (`NIOCore`, `NIOEmbedded`; 583 `NIOPosix`), `swift-nio-ssl` (`NIOSSL`), `swift-certificates` (`X509`), `swift-asn1` — apple/* packages containerization already resolves (README "Dependencies") |
| `doz` (executable, 585) | `doz` → `DozerCLI` (commands) → `DozerHost` (the host + its client) | `DozerKit`; `swift-argument-parser` (`ArgumentParser`) in `DozerCLI`/`doz` ONLY; the system `SQLite3` in `DozerHost` (metrics); `jpsim/Yams` **exact** `6.2.2` in `DozerCLI` ONLY (`doz_project.yaml` — the audit enforces the pin and the confinement) |
| — (not a product) | `DozerWeb` — `doz ui`'s server and page (606: and `doz serve`'s) | `DozerHost`; `swift-nio` `NIOCore`/`NIOPosix`/**`NIOHTTP1`**/**`NIOWebSocket`** (both ONLY here — the audit enforces it); the system's **`dnssd`** (Bonjour) in `WebBonjour.swift` ONLY (audit); resource `Resources/Web` (generated, committed). `DozerCLI`'s `UICommand.swift` alone imports `CoreServices` (LaunchServices opens the browser) |
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
| `ImageSpec.swift`, `ImageBaker.swift` | Image specs (base@digest + steps + verify + persist dirs + `journalMiB`), the two agent image specs, the baked-disk cache; base disks (`images/bases/`, flattened once per base key) and clone-tree bakes (`ImageManifest.parent`) |
| `EXT4Inspector.swift` | an ext4 image FILE read on the host — `has_journal`, clean state, the free-block bitmaps (== `dumpe2fs`'s list) |
| `DiskAccounting.swift` | per-disk unique / shared-with-parent / garbage / extents from APFS's extent map (`F_LOG2PHYS_EXT`), PRIVATESIZE cross-check; range helpers |
| `Maintenance.swift` | `reclaim()`, `rederive()`, `maintenanceAdvice()` (586's thresholds), `checkDisks()` — stopped sandboxes only |
| `RestorePoints.swift`, `FsckHelper.swift` | Restore points, custom images; e2fsck of a running-taken copy in a helper VM (on the file, over virtio-fs) |
| `KernelProvider.swift` | The pinned Linux kernel (`KernelArtifact.recommended`): override → verified cache → byte-identical seed → download + verify archive + extract + verify kernel |
| `Resources/deckhold` | The committed static aarch64-linux-musl guest binary — see `Guest/deckhold/PROVENANCE.md` |
| `Guest/deckhold/` | deckhold's C source, `build.sh` (pinned Zig 0.16.0 + ghostty `b988efc`), `PROVENANCE.md` |
| `SubnetPool.swift` | automatic vmnet subnets for NAT sandboxes and bakes (free on the Mac, unique in the process) |
| `NetworkPolicy.swift` | `NetworkMode`, `NetworkPolicy` (presets, ordered rules, DNS gating), `EgressRule`, IPv4 CIDR |
| `EgressProxy.swift` | the host proxy (vsock listener; CONNECT / plain HTTP / redirected TCP / DNS; decrypted tunnels via NIOSSL on `EmbeddedChannel`; `TLSUpstream` verified by Security.framework); `Wire` socket plumbing; `DNSMessage` |
| `Credentials.swift` | `CredentialBinding`, `CredentialVault` (secrets in memory, placeholders, the byte-exact head rewrite); `HTTPHead` |
| `SandboxCA.swift`, `HTTPRequestReader.swift`, `ConnectionLog.swift` | the per-sandbox CA + leaves; request/body framing; the metadata-only log |
| `Resources/doznet`, `Guest/doznet/` | the guest half of a proxied network — C source, `build.sh` (the same pinned Zig), `PROVENANCE.md` |
| `Sources/doz-vmtest/` | The VM integration suite (entitled executable); `NetworkSuite.swift` is `network`; `CLISuite.swift` is `cli` (`make test-cli`); `ClaudeSuite.swift` is `claude` (`make test-vm-claude`) |
| `Sources/DozerHost/ClaudeLogin.swift`, `Accounts.swift`, `LoginWatcher.swift`, `HostCore+Accounts.swift` | the Mac's Claude Code login (read-only), the keychain through `/usr/bin/security`, accounts (`<store>/accounts.json`, never a secret), ONE watcher per Mac login, the keep-alive, key policy |
| `Sources/DozerHost/HostProtocol.swift` | the host protocol (JSON lines, `HostOp`, results) — fields only ever added |
| `Sources/DozerHost/HostCore.swift` | the host's model — every sandbox as a `Sandbox`, every operation, crash recovery, metrics rows; also used read-only in-process |
| `Sources/DozerHost/HostServer.swift` | `doz host` — the lock, the socket, the attach relay (held clients), streams, idle exit, quit = Hibernate |
| `Sources/DozerHost/HostClient.swift`, `UnixSocket.swift` | the detached-child launcher, the client, socket plumbing, `ClientWire` (SandboxLab's attach wire) |
| `Sources/DozerHost/DozerStore.swift`, `Metrics.swift` | the CLI store's files, `SandboxConfig` (`doz.json`), images → specs; the metrics DB (SandboxLab's schema) |
| `Sources/DozerCLI/` | the commands (ArgumentParser), the attach client, `doctor`; `UICommand.swift` (`doz ui`, `ui link`) |
| `Sources/DozerWeb/` | `doz ui` — `WebServer` (NIOHTTP1 on 127.0.0.1:0, SSE), `WebSecurity` + `WebSessions` + `WebConfiguration` (the checks, as pure functions), `WebRoutes` (the CLOSED route table), `WebModels` (field-by-field projections of host results), `WebDataSource` (the host client), `WebEvents` (bounded SSE hub, the monitor), `WebControl` (`ui.lock`, `ui.sock` → `ui link`), `WebAssets` (manifest + digests); phase 2: `WebActions` (the closed action enum → one HostOp each), `WebOperations` (running them, progress over SSE), `WebTerminal` (Terminal.app hand-off; CSV defusing) |
| `Sources/DozerWeb/WebSource/` → `Resources/Web/` | the page as authored (vanilla HTML/CSS/JS) → generated by `Scripts/build-web-assets.swift` (content-hashed, manifest), committed; `vendor/ghostty-web/` (pinned, `VENDOR.json`); `offline.{html,css,js}`, `sw.js`, `app.webmanifest`, `icons/` (SVG masters + PNGs, `PROVENANCE.json`; `Scripts/render-web-icons.mjs` renders them); the page script is native ES modules — `app.js` (the entry) + `app/<layer>/*.js` (the module map below) |
| `WebSource/app.js` | the entry — imports every module, the shell's own wiring (quick add, sign out, nav icons, the rail), `startApp`, `provide({…})` (every call up the layers), `expose({…})` (the probes' names), then the bootstrap |
| `WebSource/app/dom/` | `h.js` (`h`, `$` — text only), `icons.js` (`icon`, `iconFor`, `withIcon`, `setButton`, the glyph maps) |
| `WebSource/app/core/` | `state.js` (THE `state` object — one export), `hooks.js` (`upcall`/`provide`/`expose`), `format.js`, `util.js`, `api.js` (fetch + CSRF, `HttpError`), `settings.js`, `agents.js`, `sandboxes.js` (phase, busy, verbs), `measure.js`, `operations.js` (`act`, `actOrThrow`, `trackOp`, transitions, waits), `wizards.js` (`WIZ`), `terminals.js` (`terminals`, `termUI`, `sview`), `session.js` (bootstrap, renewal, the worker, the sign-in inside the page), `reconnect.js` (605: calm reconnect, the paused overlay, a newer build, moved), `router.js` (`route`, `routePage`, `refresh`), `events.js` (SSE `connect`) |
| `WebSource/app/components/` | `blocks.js` (card, table, panel, meter, chip, stat, `pageIndex`, determinate), `button.js` (`btn`), `callout.js`, `menus.js` (`menuButton`, `moreMenu`), `keyboard.js`, `notices.js` (toast, page notices, status slots, banners), `pills.js`, `dialog.js` (`dialog`, `confirmAction`), `stepper.js`, `modal.js` (the wizards' modal), `nav.js`, `host.js`, `terminal.js` (one pane: the frame protocol, socket, cover, paste, saved screen, boot log), `lifecycle.js`, `workspace-chooser.js`, `image-picker.js`, `permissions.js`, `accounts.js`, `access-step.js` (`renderAccessStep`), `rules-step.js`, `prep-card.js`, `create-dialog.js`, `quick-add.js` |
| `WebSource/app/views/` | one per page: `overview`, `sandbox` (+ `sandbox-terminals` the strip, `sandbox-layout` the kept layout, `sandbox-network`, `sandbox-dialogs`), `sessions` (the grid), `images` (+ lineage), `resources`, `operations`, `accounts`, `settings`, `metrics`, `activity`, `doctor`, `onboarding`, `new-sandbox` (+ its tools step), `shortcuts` |
| `Sources/DozerWeb/WebTerminal{Tickets,Wire,Attach,Bridge}.swift` | browser terminals — the ticket store, frames + the 541 classifier + the cover, the host attach connection, the bridge and hub (NIOWebSocket ONLY here — the audit enforces it) |
| `Sources/DozerHost/Settings.swift`, `TOML.swift`; `Sources/DozerCLI/ConfigCommands.swift`; `Sources/DozerWeb/WebSettings.swift` | 591 settings: the CLOSED schema (`DozerSettings.schema`), `${XDG_CONFIG_HOME:-~/.config}/dozer-sandbox/doz.toml` generated from it, our own strict TOML subset (no dependency), precedence flag > env > file > default with a source per value; `doz config`; the UI's Settings page route (`GET`/`POST /api/v1/settings`) |
| `Sources/DozerHost/ImageTree.swift`; `Sources/DozerCLI/TemplateCommands.swift`; `Sources/doz-vmtest/TemplatesSuite.swift` | the lineage (`image-tree`, built from `DiskAccounting`; `doz image ls --tree`, Images › Lineage); templates (`template-create`) and `duplicate` (`Sandbox.duplicate`); `make test-vm-templates` |
| `Sources/DozerHost/Preparations.swift`, `Onboarding.swift`, `AgentPrompt.swift`; `Sources/DozerCLI/OnboardCommands.swift`, `ProjectFile.swift`, `Prompting.swift`, `UninstallCommand.swift`; `Sources/doz-vmtest/OnboardingSuite.swift`, `PullBench.swift` | image preparation in the host (single-flight, joined, cancelled) + `onboarded.json`; onboarding's checks / account step / settings-only-when-missing; the agent's environment prompt + the `dozer` skill; `doz onboard`/`init`/`uninstall`, `doz_project.yaml` (Yams), TTY questions; `make test-cli`'s onboarding part (`make test-cli-onboarding`); `make pullbench` (D12) |
| `Sources/DozerKit/SavedScreens.swift`; `Sources/DozerHost/TerminalLayout.swift`; `Sources/DozerWeb/WebSessionMemory.swift` | 593 §9: the sessions' saved screens (`<sandbox>/screens/NAME.{vt,txt,json}`; the capture is `Sandbox.captureScreensLocked`, the `.captureScreens` step); the web UI's terminal layout kept by the host (`terminal-layout.json`); their web projections and the layout's strict decoder |
| `Sources/DozerHost/BootLogs.swift`; `Sources/DozerWeb/WebBootLogs.swift` | each sandbox's kept boots (`<sandbox>/boots/`), the recorder, the one renderer; the web's Boot log projections |
| `Scripts/release.sh` (`make release`), `Makefile.config.example`; `ReleaseStamp` in `Sources/DozerCLI/DozerCommand.swift`; `HostUpgradeCheck` in `GroupCommands.swift`; `HostCore.programGone`; `Tests/DozerCLITests/ReleaseTests.swift` | the Homebrew artefact (signed; Developer ID + notarised when configured), the version stamp, `doz host upgrade-check`, the refusal when an upgrade removed a running host's keg |
| `Sources/DozerHost/Resources.swift`, `HostCore+Resources.swift`; `Sources/DozerCLI/ResourcesCommands.swift`; `Sources/DozerWeb/WebResources.swift`; `Tests/DozerCLITests/ResourcesTests.swift` | the account of everything Dozer uses (the walk, one leaf per entry, the three numbers from `DiskAccounting.exclusive`), refusals, the plan and the deletion; the host ops `resources` / `resources-rm` / `resources-clean` / `resources-kernel`; `doz resources`; the web projection + preview route |
| `Sources/DozerKit/BaseCatalogue.swift`, `OCIImport.swift`; `Sources/DozerHost/BaseImages.swift`, `ContainerTool.swift`, `AppleContainerResources.swift`; `Sources/DozerCLI/BaseCommands.swift`; `Sources/DozerWeb/WebBases.swift`; `Sources/doz-vmtest/BasesSuite.swift` | base × agent images — the catalogue, `ImageChoice` names, `ImageComposer` (+ `recompose` for W28), native Claude Code, pi's Node, digests; the store's base digests and Dockerfiles; Apple's `container` (status/start/install/build) and its storage in Resources; `doz base`, `doz builder`; the bases route and the Dockerfile picker; `make test-cli-bases` |
| `Guest/dozview/` (`dozview.c`, `match/`, `build.sh`, `PROVENANCE.md`), `Resources/dozview` | the guest view daemon of workspace rules (raw /dev/fuse, supervised) and its matcher in C (`match/dozmatch.c` + `dozre.c` RE2 subset + `dozfold.c`; `match/` is also the SwiftPM C target `DozMatch` the unit tests run); `make dozview` / `dozview-verify` |
| `Sources/DozerKit/DockerIgnore.swift`, `WorkspaceRules.swift`, `WorkspaceView.swift`, `DozFoldTables.swift` (generated by `Scripts/gen-dozfold-tables.py`); `Sources/DozerHost/WorkspaceRulesHost.swift`; `Sources/DozerCLI/IgnoreCommands.swift`; `Sources/doz-vmtest/IgnoreSuite.swift`; `Tests/Fixtures/` | `.dockerignore` semantics in Swift (the C matcher's twin), the rules as the Mac reads them (which line decides), the guest layout + scripts, folding tables; the host op `workspace-rules`, warnings; `doz ignore check|show`; `make test-vm-ignore`; the real-Docker vectors |
| `Sources/DozerKit/OpenAIAccess.swift`; `Sources/DozerHost/ChatGPTAccounts.swift`, `ChatGPTSignIn.swift`; `Sources/doz-vmtest/CodexSuite.swift` | Codex — the proxy's OpenAI side (claims, the guest's auth.json, the renewal answer, `HTTPSOnce`, the sign-in's and refresh's requests); the host's sessions, `applyOpenAIAccount`, the guest auth.json; Dozer's own ChatGPT sign-in; `make test-cli-codex` |
| `Sources/DozerKit/AgentPermissions.swift`; `Sources/DozerHost/Permissions.swift`; `Sources/DozerCLI/NetPermissionCommands.swift`; `Sources/doz-vmtest/PermissionsSuite.swift` | agent permissions — the catalogue and presets per base, `NetworkPolicy.permissions` (stored by name, `effectiveRules`); edits/report/suggestions/facts; `doz net NAME/allow/deny/permissions`, `--allow`; `make test-cli-permissions` |
| `Sources/DozerWeb/WebServe*.swift`, `WebExposure.swift`, `WebQR.swift`, `WebBonjour.swift`; `Sources/DozerCLI/ServeCommand.swift`; `Sources/DozerKit/LocalDashboards.swift` | `doz serve` — the rules (`WebServe`: addresses, the accept gate, the request's own origin), devices + invites (`WebServeDevices`), the audit log, `serve.sock` (`WebServeControl`), the server's serve side (`WebServeServer`, `WebServeState`), the capability table, our QR encoder, Bonjour; the CLI (`doz serve …`, doctor's public-origin check); the egress proxy's refusal of the dashboards' ports |
| `Guest/deckhold/deckhold.c` (`ps_*`), `Sources/DozerKit/ProgramStatus.swift`; `Sources/DozerHost/SessionStatus.swift`, `HostCore+Status.swift`; `Sources/DozerWeb/WebSource/app/components/agent-status.js`; `Sources/doz-vmtest/StatusSuite.swift` | 612: what the agent is doing (OSC 7501) — deckhold's consumer (answers the query, keeps the records, WATCH/STATUS), the parsed record, the host's model + watchers + events, the page's chips and notices; `make test-vm-status`, `make deckhold-status-check` |
| `Sources/DozerHost/Usage.swift`; `Sources/DozerCLI/UsageCommands.swift`; `Sources/doz/DozerMain.swift` | anonymous usage statistics and the sign-up — the open half: the closed list, the switches, the local record, `doz telemetry`, `doz signup`, the hook; the bridge to the official builds' closed package (`#if DOZ_CLOUD`) |
| `Tests/DozerWebTests/` | the security rules one by one, and a real listener driven with raw HTTP; `Serve*Tests` |
| `Tests/DozerKitTests/` | Unit tests — no VM |

## Rules that each cost a bug to learn (keep them, and keep their tests)

- **Sessions start WITHOUT `sh -c`.** BusyBox ash leaks an ignored SIGQUIT into what it execs, and a
  program cannot trap a signal ignored on entry (576: the screensaver's `m` menu). `GuestCommand.serve`
  builds argv; deckhold additionally resets every signal to default before exec. Utility execs
  (`exec(["sh","-c",…])`) may use a shell — never a session.
- **Stop keeps the root disk**: Stop shuts the VM down and persists the phase as `off`; the next Start cold-boots
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
- **Quit lets a just-started program settle**. `prepareForExit(settle:)` waits out the rest of 3 s
  since the last `openSession` before it hibernates (580: Claude Code hibernated within ~1 s of its
  launch exited after the wake in 2 of ~7 runs). `hardening settle` is the test.
- **Stop decides from the phase it was CALLED in** (`perform()` reads `phase` before going busy).
- **Every VM has a memory balloon; a snapshot is never taken with it inflated**. A device is a
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
- **A wake's first guest calls are retried on a closed channel**. A restored guest resets its
  vsock transport as it resumes; a vminitd connection dialled in that moment can be closed under its
  first call (`unavailable: "The channel was closed"` — 582: 2 of 31 concurrent wakes; always
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
- **Restore points are disk-only APFS clones — never live forks**. A copy of a RUNNING
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
- **The journal is a key input**: `ImageSpec.journalMiB` is in the bake key and the base key,
  `SandboxSpec.journalMiB` in the prepared-disk key (a journal-less one keeps its pre-587 key, and so
  does the e2fsck helper's). A record written before 587 decodes as `nil` = no journal — its disks
  have none. Never default a DECODED value to 16.
- **Hibernate and Stop sync the guest first** (`.syncGuest`, best effort): a discarded
  hibernation lost the last ~5 s of writes in every journal mode. It also records `df` usage for
  `DiskAccounting`'s fallback garbage.
- **Mount options are not VM inputs**: `discard` on the root and state disks goes to the guest's
  mount only (Containerization maps only `ro` into the VZ attachment), so a snapshot taken before 587
  restores unchanged (587 proved it with `lineage compat-wake`, retired in 592).
- **Children never depend on a parent's FILE**: a base, an image and a sandbox are APFS clones;
  deleting or re-deriving a parent never changes a child (`lineage children`). Maintenance
  (`reclaim`/`rederive`) touches only blocks ext4 marks free, refuses any disk that is not cleanly
  unmounted (its bitmaps would be stale), and `rederive` replaces the root disk only by an atomic
  rename after verifying the new one.
- **Metadata dates have fractional seconds** (`ImageBaker.encoder`): restore points taken within one
  second must sort in the order they were taken.
- **A proxied VM has NO NIC; the host proxy is the only way out**. The guest shim decides
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
- **Claude Code starts set up and without permission prompts**.
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
- **Agent credentials (`AgentCredentials.swift`; the table is `AgentImages.credentials`):**
  Claude Code: `mac`, `setup-token`, `api-key`; pi: `api-key` ONLY (it reads `ANTHROPIC_API_KEY`;
  never hand it a Claude subscription — `applyAccount` clears both bindings, with a notice, for an
  account the agent cannot use). `createProblem` runs in `HostCore.create` and `duplicate` (proxied
  networks only; an explicit `none` is allowed, the default resolving to none is not for pi), in the
  CLI's `preflightAgentAccount` (create/up/init; on a TTY it offers a fitting account or the hidden
  paste of a key) and, through `WebAccounts.agents`, in the web forms (`accountChooser`).
  `useAccount` refuses an incompatible account. `SandboxInfo.credentialProblem` is the page's
  banner and switches the facts block to "no credential you can use is attached". Room for other
  providers: `AgentCredentialSupport(provider:accountKinds:)`.
- **The agent has passwordless sudo by default**. The dev baseline
  installs `sudo` and KEEPS apt's package lists (~18 MiB, shared by APFS clones; `apt-get clean` only),
  and `apt-utils` FIRST (W24: otherwise every install says "debconf: delaying package configuration");
  the rule itself is never baked: `GuestCommand.agentSudoScript` writes `/etc/sudoers.d/dozer-agent`
  (0440, root, `user ALL=(ALL) NOPASSWD:ALL`, put in place only after `/usr/sbin/visudo -cf` accepts it;
  absolute paths — a utility exec's PATH may lack sbin) or removes it — at every fresh boot
  (`prepareGuest`, from `Sandbox.agentSudo`), every wake (W34: `GuestCommand.guestFixes` — the live-safe
  part of `prepareGuest`: /etc/hosts, debconf Noninteractive, the open-URL shim, the time zone, the sudo
  rule — run as ONE root exec by `LifecycleStep.applyGuestFixes` after a wake from sleep, from
  hibernation and a restore after a host restart; never on a resume from Pause; best effort, a failure
  is noted; NOT the deckhold socket reset or the bind mounts) and every agent session start (`deliverAgentPrompt`), so a
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
- **Agent versions (`AgentVersions.swift`):** `images.claude_code_version` / `images.pi_version`
  = `latest` (default) or exact. `latest` is resolved on the MAC at preparation time
  (`NpmRegistry`: `<registry>/<package>/latest` → version + sha512 integrity, both validated —
  they go into a bake script) and installed at that exact version by `AgentImages.claudeCode(_:)` /
  `pi(_:)`; `ImageSpec.agent` records it, so it is in the bake key. `AgentVersions.spec(purpose:)`
  is synchronous and uses only the store: `.create` → the newest image PREPARED for this build, else
  the newest `usable` one an older doz's recipe made (no waiting), `.prepare` → the version the
  setting names (cached latest, a known exact, else the pin when the registry was never asked, else a
  clear error). `HostCore.freshen` is the only thing that asks the registry (hourly cache in
  `<store>/agent-versions.json`, 5-min back-off after a failure). Only the
  real host asks (`HostServer` passes `.fromEnvironment()`; `DOZ_TEST_NPM_REGISTRY=offline|URL` for
  tests); in-process hosts and unit tests have `.disabled` and resolve to the pin. Claude Code's own
  updater is off in sessions (`DISABLE_AUTOUPDATER`, `DISABLE_UPDATES` — both honoured by 2.1.227).
- **An image is NEVER rebuilt without the user**.
  W28's bug: "prepared for this build" compared a bake with ITS OWN recorded recipe, so an image rc.1
  baked (no sudo, no lists) still counted after the recipe changed. Now `prepared` = baked by THIS doz's
  recipe for that agent release (`AgentVersions.isCurrentRecipe`: `AgentImages.spec(name, release) ==
  the bake's spec`); `usable` = any bake this build can start. A stale image is USED and SAID:
  `ImageRow.olderRecipe` ("this doz's image adds: sudo, package lists" — `AgentImages.recipeChanges`),
  `available` (a newer release, no background preparation any more), `status`/`standing`; `image ls`
  STATUS, the Images page (badge, Rebuild with the consequences), `doctor` (warn), `SandboxInfo.olderImage`
  (`doz ls`, the sandbox page), create/up/init (`--rebuild` → `CreateOptions.rebuild`: the host
  prepares first; `--use-current`; a TTY asks, default use-current; `--json`: `imageNotice`), the New
  Sandbox form's choice. `doz reset` moves a sandbox to the image a create takes now
  (`moveToCurrentImage`). The facts never claim sudo the guest lacks (checked at session start).
  `DOZ_TEST_OLDER_RECIPE=1` (a TEST seam) bakes rc.1's recipe. Only an image NEVER prepared is
  prepared on first use. `make test-cli-images` checks it.
- **The `doz` host is the ONE owner of a store's VMs.** It holds `<store>/host.lock` for its
  whole life and loads nothing before it has it (a new host waits for an exiting one — otherwise it
  would read a record still saying `running` and report a live sandbox as died). The launcher is a
  detached child with ONLY stdin/stdout/stderr (`POSIX_SPAWN_CLOEXEC_DEFAULT`): a host that inherited
  a caller's pipe kept a test harness waiting on EOF. No launchd agent.
- **An update must never cost a sleeping sandbox its sessions** (an earlier incident: `make install-cli`
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
    expected to be compatible) sleeps a lab and a pi sandbox with a running session and markers; this build wakes them — same session pid, screen,
    file — and then its own recorded layout; then the incident (the running host's file overwritten
    in place: the host says so, `host stop` keeps the snapshot, this build wakes it) and an idle host
    replaced by rename exiting by itself.
- **Settings are ONE closed schema**. A new user-facing knob is a new entry there — its type,
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
- **A host never lives in a client's process tree** (an earlier incident, 2026-09-29: a host auto-started by
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
- **A host stop shows its progress** (`HostStop.swift`): `host-stop` streams, per sandbox, a
  `started` "hibernating X" and a `step` "hibernated X (snapshot …)" / `failed` (why + "shut down
  instead") — `HostEvent.startedAs` ties an end to its differently-worded start — then the host's own
  last step, and answers `HostStopResult` (rows; an older host answers the string "stopped", still
  read). `Sandbox.prepareForExit` returns its `ExitOutcome`. Every stopping client uses
  `stopHostShowingProgress` (the CLI's progress view: animated on a tty, plain lines else) or, in the
  UI, Restart host's operation (`WebOperation.lines`). A host that dies mid-stop: the client reports
  what it saw (`HostStopView.seen`), never hangs. `make test-cli-hoststop` (in `test-cli` too).
- **The sandbox follows the Mac's time zone**: `GuestTimeZone` — the zone's TZif bytes from
  THIS Mac's `/usr/share/zoneinfo` (portable to glibc and musl; the Alpine lab has no tzdata) — written to
  `/etc/localtime` (+ `/etc/timezone`) by `prepareGuest` at every fresh boot and by `.resyncClock` at
  every wake (best effort; no new planner step). The host sets it (`HostCore.guestTimeZone`: the setting
  `sandbox.timezone` = `mac`, read NOW with `NSTimeZone.resetSystemTimeZone()`, or a zone) at adopt,
  every named request and every `ensureRunning`. The facts say it (`sandbox.timezone`).
  `DOZ_TEST_MAC_TIMEZONE` (a name, or a file holding one, read at each look) stubs the Mac's zone;
  `make test-cli-timezone`.
- **Names are never cut; a point is found by what a person types**: a restore point's name is
  stored as given, ≤ `RestorePoint.maximumNameLength` (64; longer is refused with the limit — names live
  only in meta.json, a point's directory is its id). `RestorePoint.resolve`: exact id, exact name
  (newest), else the ONE point whose id or name starts with it — several is an error listing them
  (`HostCore.resolvePoint`, used by the host and the CLI).
- **Check, then ask**: a confirming command resolves what it is about first — the sandbox
  (`requireSandbox`), the point (`resolvePointFirst`, then the question names name, id, when; the
  request carries the id), the image/template — so a `[y/N]` is never offered for what would fail.
- **`exec` and `run` start an off sandbox**: `HostRequest.start` (the CLI sends it unless
  `--no-start`; an older client never does) → `ensureRunning(start:)` runs `lifecycle(.start)` (boot
  view, boot log, metrics); `ExecOutput`/`SessionOpened` carry `started`/`woke`/`bootMilliseconds`.
  `doz create --start`. `make test-cli-points` covers W25–W27.
- **Looking never starts the host.** Read-only commands answer from the store in-process
  (`HostCore(readOnly: true)`) unless a host runs — or a record says a VM was live when its host went
  away, which only a host can recover. A short request does not reset the idle clock; an open
  attach or stream does.
- **The attach relay adopts the session BEFORE it answers**, and the client sends what was typed
  ahead of its first connection once it reads that answer (keys typed right after `up` were lost
  otherwise — the first `test-cli` run). After that, keys for a held (sleeping) sandbox are dropped, never queued for a frozen guest.
- **One keychain item holds at most `Keychain.maximumSecretBytes` (1800)** (599i rc.2: `security -i` cuts an input line at
  ~4096 bytes; a 4.2 KB ChatGPT sign-in was stored TRUNCATED with rc 1 on a real Mac). `SystemKeychain.write` refuses
  more before `security` runs, reads the item back and deletes it unless it is the secret whole — never a partial item; the
  in-memory test keychains (`MemoryKeychain`, the tests' `FakeKeychain`) enforce the same limit. Store less, or use
  `KeychainChunks`. `RealKeychainLimitTests` checks the real keychain (`DOZ_TEST_REAL_KEYCHAIN=1`, a throwaway
  `doz-test-limit-*` item, always deleted); the fake OpenAI issues real-sized tokens (~6 KB with a 2.1 KB refresh token).
- **Dozer never holds, uses or writes Claude Code's refresh token, and never writes a
  `Claude Code-credentials*` item**. It reads the Mac login's ACCESS token only; the Mac's
  Claude Code is the one writer of that token family (a second holder forks it — a copied
  `.credentials.json` was rejected for this in an earlier project, and for its silent fall-through to API billing).
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

### EXPERIMENTAL audio sandboxes

- **`doz create --audio` only**: `SandboxSpec.audio` (nil = no audio: no device, the pinned kernel, and the spec and
  `ToolInputs` encode byte-identically — `AudioTests`). `PinnedIdentity.audio` adds the virtio-snd device (Mac mic in,
  speakers out); `VMLayout` records it, so a mismatched restore is refused. The VM boots `SoundKernel` (kata
  6.18.15-186 + sound.conf, sha256 pinned in `Audio.swift`) from the kernel CACHE — the host copies it there, verified,
  at create and before every boot (`MacAudio.installSoundKernel`); bakes and image keys keep the pinned kernel. Never
  downloaded: `release.sh` ships it (`SOUND_KERNEL`, sha256-checked, `libexec/doz/kernels/`); dev: `DOZ_TEST_SOUND_KERNEL`.
- **The tools layer** (audio only): alsa-utils, `/etc/asound.conf` (stamp v2: `default` = asym of the card's
  playback/capture devices — NOT dmix, which stalls on this card), and the TEMPORARY `doz-sound` (`DozSound.swift`).
- **macOS asks about the microphone for the host's RESPONSIBLE app** (the app that started doz — survives the detached
  double spawn), named in host.log, `host status` `microphoneApp`, `doctor` and doz-sound's hint. Known defects: VZ can
  stop the VM on pause/save while a capture waits on an unanswered prompt; an open stream stalls after a restore.

### The web layer (`doz ui`)

- **Loopback only, nothing else representable** (`WebLoopbackAddress`: 127.0.0.1 and a port). No flag,
  environment variable or setting may bind another address. (606's `doz serve` is a SEPARATE process and profile —
  `DozerWebServer.bindServe`; the audit keeps it out of `UICommand.swift`.) The PORT is the
  setting `ui.port` (`doz ui start --port N`, `$DOZ_UI_PORT`): `0` (the default) = the reuse —
  the port this store's LAST UI had (`<store>/ui.port`), asked for again when nothing listens there
  (`WebLoopbackAddress(reusing:)`: ≥ 1024), else the OS picks and `doz ui` SAYS so (naming the holder,
  `PortHolder`: `/usr/sbin/lsof`, read-only); or a fixed port 1024–65535, never silently swapped (taken →
  `doz ui` refuses, naming the holder; `bind(fixedPort:)` has no OS fallback). The port is no secret and
  grants nothing — an installed dashboard app belongs to one, which is why it may be fixed.
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
  through the ticketed terminal socket below; `host-stop` only inside `host-restart`, which
  `HostWebData.restartHost` refuses unless the running host is an OLDER build than the UI). Destructive ones (reset, rm,
  point revert/rm, image rm, account rm) carry `confirm` equal to the name. Shutdown keeps the disk,
  so it carries no `confirm`: the page asks with a plain dialog that can stop asking
  (the setting `ui.confirm_shutdown`, doz.toml — no longer localStorage). **No secret is ever an
  action's input** (590's D3). Since 594 an ACCOUNT's key or token may be typed in a
  masked field — through the one typed route `POST /api/v1/accounts`, never an action, while
  `ui.allow_secret_entry` (see the 594 section); and a sandbox's own key through `POST
  /api/v1/sandboxes/NAME/key`.
- **An action is an operation**: 202 at once, the host call in `WebOperations` (≤ 8 running), its
  progress and outcome as SSE `op` events. The outcome is a line written from the result — never
  the result passed through.
- **Open in Terminal** writes a one-shot `.command` file (0700, in a 0700 per-user directory; it
  runs `rm -f -- "$0"` then `exec '<doz>' attach NAME [SESSION] --store '<store>'`, names
  allowlisted, paths quoted) and `open`s it, so the user's DEFAULT app for `.command` files runs it
  (Terminal, iTerm2, Ghostty). No AppleScript, so no Automation permission and no second window
  (the AppleScript version opened two when Terminal was not running). Never a command from the browser.
- **End / Restart session (`SessionRestart.swift`)**: host ops `session-end` / `session-restart`, held under
  the SAME `sessionGate` as `open-session`, RUNNING sandboxes only (never a wake). Ending is
  `GuestCommand.endSession` (root): the session's tmux server (`/tmp/tmux-*/doz-NAME`) killed first, then
  HUP → TERM → KILL of the program's PROCESS GROUP (forkpty made it a leader), done when deckhold's socket is
  gone (`doz-end hangup|terminate|kill|not-running|stuck`). A restart reopens through `openSessionLocked` from
  `<sandbox>/sessions.json` (`SessionRecords`: argv as CHOSEN — before pi's prompt file, tmux and a resume —
  workdir, user, variable NAMES only; ≤ 64; 0600; cleared with the sessions: shutdown, reset, died-with-host;
  fields only ever added). No record: the default session's argv, else refused. The default session of an agent
  image (argv == the default) gets `SessionResume.arguments` as `extraArguments` (never recorded): Claude Code
  `--continue` (only after `SessionResume.check` finds ~/.claude/projects/<cwd, non-alnum→'-'>/*.jsonl — it
  refuses without one), Codex `resume --last` (0.160.1: newest in the cwd, else a new one; `--all` would ignore
  the folder), pi `--continue` (newest else new); `fresh` = none. CLI `doz sessions end|restart NAME SESSION`
  (`sessions` became a group whose default subcommand `ls` keeps `doz sessions NAME`; `restart` attaches afterwards
  only when stdin AND stdout are a terminal — a script's `--yes` restarted and then attached forever — never with `-d` or
  `--json`, and `--attach` forces it: `SessionsRestart.attaches`); web actions
  `session-end` / `session-restart` (one HostOp each; `components/session-actions.js`: a tab's ⋯ and the
  Sessions tab's ⋯; a restarting pane (`t.restarting`) ignores the `ended` frame and the socket's close, shows
  "Restarting the session…", and reattaches with its scrollback when the operation is done).
- **`open-session` is serialized per sandbox** (`HostCore.sessionGate`, a `KeyedGate` held across
  its awaits — the actor alone is re-entrant) and idempotent: a concurrent or repeated open of one
  session answers "already running", and a deckhold "Address in use" re-lists and answers with the
  session that won. (590: two clicks during a first boot started two `deckhold serve`s.)
  `KeyedGateTests`, and `test-cli`'s "concurrent opens of one session".
- **A cold start is JOINED, never raced** (610, 590.B3: an open during a first start's image preparation ran while the
  sandbox was still OFF and failed "… is off"). `HostCore.coldStarts` (`ColdStarts`, a lock like `KeyedGate`) holds a
  sandbox from the moment `start` decides to boot it from off/failed — its preparation included — to the boot's end.
  `ensureRunning` (open-session, attach with wake, exec/run) waits for it and then looks again (a fresh `get`: a
  Dockerfile sandbox is re-adopted mid-start); `open-session` joins it BEFORE queueing at `sessionGate`, so every open
  made during it ends with the start; a second `start` joins the first. A failed start fails every joiner with
  "NAME did not start — <the start's reason>". With no start under way an off sandbox is refused as before (nothing
  starts unless asked). `ColdStartJoinTests` (no VM: a gated preparation); `probes/590-*/browser-repro-open-during-boot.mjs`
  (a real claude-code first start, two opens during it: both wait, one session).
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
  style, event-handler attributes and external URLs (the CSP would refuse them anyway) — in every module.
- **The page script is native ES modules, layered** (v1: no framework, no bundler; that is v2). `index.html`
  loads `<script type="module" src="/app.js">` (the CSP's `script-src 'self'` covers modules). Layers:
  `dom` < `core` < `components` < `views` < `app.js` — a module imports only from its own layer or below
  (components never import a view; core never imports a component or a view), never in a cycle. A call UP the
  layers (the router dispatching to its views, an operation's end re-rendering, the SSE handler) is
  `const name = upcall('name')` at the top of the lower module, and `app.js` provides every one with
  `provide({…})` before anything runs (`core/hooks.js`); only functions go up — a VALUE a lower layer needs moves
  down (the terminals' data is `core/terminals.js`, the wizard's steps `core/wizards.js`). The single `state`
  object is ONE export of `core/state.js`, mutated in place (an import binding cannot be assigned: a top-level
  `let` stays in the module that assigns it). The compiler (`Scripts/build-web-assets.swift`) CHECKS the graph:
  relative specifiers only (`./x.js`, `../core/x.js`), a module that exists, no dynamic `import()`, the layers, no
  cycle, no module the entry does not reach, every `upcall('x')` provided and nothing provided that nobody
  upcalls. It hashes bottom-up — each module's specifiers rewritten to its dependencies' hashed names, then the
  module hashed (`/assets/app/<layer>/<name>-<sha16>.js`, immutable, in the manifest; the route table admits
  exactly `/assets/app/<layer>/<file>`) — so `app-<sha16>.js` changes whenever any module does and `hello.script`
  still names "this build's page". `WebModulesTests` checks what ships and the compiler's refusals. JSDoc
  `@typedef`s document the shared components' parameters (`btn`, `callout`, `dialog`, `menuButton`/`moreMenu`,
  `renderAccessStep`); there is no `tsc` check (no pinned TypeScript without an npm install).
- **The probes' names**: the one script's top-level names were globals and the workspace's browser probes
  read and call some (`state`, `terminals`, `sview`, `act`, `saveSetting`, `gridRefresh` …). `app.js`'s
  `expose({…})` keeps exactly those reachable by name (one a lower layer upcalls is its hook — so a probe that
  wraps it, 594 host-watch's `gridRefresh`, wraps what the page calls). Nothing in the page uses them; a probe
  that needs another name adds it there. A probe cannot wrap a function a module calls internally (593
  boot-progress wrapped `toFrame` — it would need its capture moved into the frame).
- **The split was a MOVE**: `probes/607-*/split-app.mjs` cut the 0.28.0 `app.js` into its top-level
  statements and wrote each, byte for byte, into the module `map.mjs` names; `verify-move.mjs` proves every
  statement and comment line is kept exactly once. New code goes into the module of its area; a new module is a
  file in its layer's directory, imported by what uses it (and by `app.js` if nothing else does).
- **The look is the 603 style guide** (the design notes; its decisions in
  603.02-PLAN.md). Keep to it when adding UI:
  - **Tokens** only (`app.css` `:root`): every colour once, with `light-dark()` — `color-scheme` IS the theme
    (`ui.theme` sets `data-theme`); never a literal colour outside `:root` (the terminal chrome is `--term-*`;
    `frame.css` has its own `--term-bg`). Type `--fs-*` (13 px is THE UI size), space `--sp-*`, radii `--r-*`,
    elevations `--shadow-*`, layers `--z-*`. A comment in a stylesheet never contains `*/` (a path like
    `changes/603-*/…` closed one and dropped the whole token block).
  - **One button family**: `btn(label, fn, {primary, quiet, danger, small, lg, iconOnly, icon})` — ONE primary per
    view (the verb that moves things forward: Start/Wake/Resume, Next, Create; a running sandbox has none);
    icon-only only where the icon is unambiguous (it gets aria-label + title). Menus: `menuButton(trigger, items)`
    / `moreMenu(label, items)` (⋯) — in the DOM beside the button, fixed and kept on screen; an item's text is
    exactly its label (its description is drawn from `data-desc`), destructive items last, a disabled one says
    why. Rows: one next verb + ⋯.
  - **One notice surface**: `callout(tone, {title, body, actions, dismiss, compact, banner, cls, attrs})`; the old
    classes stay on elements as hooks. **A failure is never only a toast**: it is said where
    the action was started and stays until dismissed or fixed — the dialog's `.dlg-error`, the sandbox's status
    line (`[data-op-for]`, `failureFor(name, text)`, `opFailed`), a step's/row's own slot (`wizFail`,
    `settingFailed`, `state.permErr`), else the page notices (`pageFailure` → `#notice`). `toast()` is for
    successes; `toast(text, true)` routes to the page notices.
  - **Never `append`/`replaceChildren` a `null`** — the DOM writes it as the text "null" (the Split menu's bug);
    `h()` skips nulls, those do not.
  - **Structure**: the sidebar's four groups are static markup in `index.html` (`#nav > a[data-view]` stay direct
    children; the rail below 980 px). The sandbox page: `lifecycleBar` (the group + Shut down) + ⋯ + the status
    slot + the details toggle; the terminal strip's actions (`termUI.acts`, `paintStripActs`) on the rightmost
    pane; the inspector's tabs `INSP_TABS`, the chosen tab per sandbox in `sview(name).inspTab` (page memory, no
    setting); its width in this browser's storage. The wizards (`#/new`, `#/onboarding`) are a MODAL over the page
   : `state.modal` is the wizard, `state.view`/`state.bgHash` stay the page under it, which is never
    re-rendered or torn down by opening or closing (inert meanwhile); `wizHead()` (title, ✕, the horizontal
    `stepperNode()` strip) + `wizMount()`; ✕/Escape ask before losing choices (`wizDirty`), Back keeps them. Long pages: `pageIndex()`;
    Settings' filter; Resources' folding groups (browser storage). Page shortcuts only `g s`,
    `/`, `?` — never while a terminal (its iframe), a field, a menu or a dialog has the focus.
- **Edit `WebSource/`, then `make web-assets`, and commit `Resources/Web`.** `make web-assets-check`
  (run by `make test` and `Scripts/audit.sh`) fails on drift — every module included; `WebAssets` refuses to
  start on a digest mismatch. `make install-cli` copies `DozerKit_DozerWeb.bundle` beside the binary.
- **`app.css` is in cascade layers**: `@layer tokens, base, components, views;` — tokens (the `:root`
  custom properties, the themes, reduced motion), base (box-sizing, html/body, body type, links), components (code
  and the focus ring; the building blocks — the terminal pane, pills, cards, forms (zero-specificity `:where`),
  menus, callouts, notices, dialogs, tables, progress — and a feature's own blocks), views (the page layouts: the
  sidebar, the sandbox page, the wizards' modal, long pages). The rules are in their 0.28.0 order, only wrapped
  (several blocks per layer). Between layers the later one wins WHATEVER the specificity, so a rule put in another
  layer can change who wins (`th, td` in views beat `.res-child .res-name`; the base focus ring lost to the forms'
  `:where` — both found and kept apart): `probes/607-*/run-cascade.sh` compares every element's computed style
  (the 603 harness's states, light/dark, 1280/900 px, every interactive element forced into :hover, :focus and
  :active) of the sheet before against a candidate — keep it at 0 differences. A new rule goes in its layer's block.
- **The UI watches the host** (`WebHostWatch` — pure, unit-tested): before each overview the
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
- **`doz ui` gone = the page paused** (594 W21; CALM first — see the 605 section): after 1.5 s of failed reconnects (never on a blip)
  everything but `#banners` is `inert` under `#ui-overlay` (alertdialog, focus inside, Try now — the
  one retry control); the banner strip stays in front (z-order) and live — the banner says what
  happened, the overlay that the page is paused. The overlay is BUILT on `hello`: its icon is a
  `<use>` of the served sprite, which a page without its server cannot fetch. A rotated link turns
  it into "This page was signed out". The HOST stopping stays a banner (the page still works).
- **One UI per store, one tab**: `ui.sock` answers `link`, `rotate` and `status` (origin +
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

### The installable dashboard, graceful restarts

- **An installable web app, loopback only** (606's `doz serve` is the LAN side). `app.webmanifest` is hashed like the
  css/js (`/assets/app-<h>.webmanifest`, `application/manifest+json`) with a FIXED `id` (`/?app=dozer`) so a new hash is
  the same app; `index.html` links it, the SVG favicon, the 180 px `apple-touch-icon` and a `theme-color` per scheme.
  The page CSP gained ONLY `manifest-src 'self'; worker-src 'self'`.
- **Icons are admitted by provenance**: `WebSource/icons/` holds two SVG masters (`icon.svg` — served, the favicon and
  the manifest's — and `icon-maskable.svg`, full-bleed, the drawing inside the 80 % circle) and the PNGs rendered from
  them by `node Scripts/render-web-icons.mjs` (headless Chrome), recorded in `icons/PROVENANCE.json` (each file's sha256
  and its master's). The compiler refuses an edited master without a re-render, an unlisted file, a PNG of the wrong
  size, and an SVG with anything but drawing elements and literal colours (no `<text>`: no font). Never edit a PNG; edit
  a master and re-render. `image/png` is served only under `/assets/icon-*` (`WebAssets.isIconPNG`).
- **Four documents** (stable paths, `no-store`, no session, no data): `/`, `/terminal-frame`, `/offline` (Dozer isn't
  running — it polls `/api/v1/session` and reloads the SAME address once doz ui answers 200 or 401) and `/sw.js`
  (its own CSP, `default-src 'none'; connect-src 'self'`). Closed routes `.offline`, `.serviceWorker`, GET/HEAD only.
- **The service worker has ONE job**: a failed top-level navigation of `/` gets the cached `/offline`; the precached
  files (`/offline`, its css/js, the icon — the list and the cache's name `doz-offline-<digest>` are WRITTEN by the
  compiler) come from its cache. Everything else gets no `respondWith` — `/api/**` (the event stream included),
  `/terminal-frame`, any response with a cookie are never cached or answered (`installable.mjs`, `restart-vm.mjs`
  check CacheStorage and `fromServiceWorker`). The compiler refuses `importScripts`/`eval`/`Function` in it. Registered
  after sign-in, `updateViaCache: 'none'`.
- **Remember this browser**: a session lasts 14 days unused (`WebLimits.rememberedSession`; the limit's max
  is 30 days), renewed at each page load and at half-life. Why a page must sign in again is SAID — `<store>/ui.revoked`
  (0600, cookie digests + reason, 30 days) → 401 `session-rotated` | `session-expired` | `signed-out`, else
  `unauthenticated`. `doz ui --new-link` with no UI running ends the kept sessions as rotated
  (`WebSessionStore.revokeKept`, and `ui.sessions` still goes).
- **`doz ui restart`** (`ui.sock` line `restart` → `restarting ORIGIN` | `refused WHY`): streams end `restarting`,
  terminals close `restarting`, then the SAME process re-executes (`execvp` of its argv[0] — by name through the PATH,
  so an upgrade's new `bin/doz` runs — with `start` and `--restarted`, never `--open`/`--print-url`/`--new-link`;
  every fd but 0–2 CLOEXEC; signals back to default). While it restarts, the main flow must not return (it would exit
  before the exec: `ControlFDs.restarting`). The restarted one waits for its pages, never opens a tab — except after a
  MOVE: when `ui.port` changed, pages are told `end: moved {origin}` (an origin, never a link) and the new doz ui opens
  the dashboard on its port (`ui.open_browser`). A page CANNOT follow by itself: a script's navigation to another
  loopback port is `Sec-Fetch-Site: same-site`, which the Fetch-Metadata rule refuses — keep that rule.
  `doz ui serve` is the hidden earlier name of `doz ui start` (a note on stderr).
- **The page outlives its server** (`core/reconnect.js`, `core/events.js`, `core/session.js`): a CALM "Reconnecting to Dozer…" (neutral banner) for 15 s (60 s after
  `end: restarting`), today's alarming wording at once on `end: shutdown`, the port it expected after a minute.
  Terminals REATTACH by themselves after a restart, a stop, a dropped socket (code 1006) or a sign-in again
  (`reattachTerminals`: on `hello`, one at a time, ≤ 16, a back-off on 503; the ticket's `reattach: true` makes the
  first SNAPSHOT keep the scrollback, `WebTerminalWire.keepingScrollback`) — never after an end, idle or a refusal;
  input typed in the gap is dropped. The sign-in is INSIDE the page (`showSignIn` over `#ui-overlay`): the view,
  an open wizard and the terminal layout stay; a password-type paste field (emptied before the request; a link of
  another origin refused with a reason); `<dialog>`s are closed as before. `hello` carries this build's page script
  and style (`WebHello`): a page whose own differ shows "Dozer was updated to vX — Reload" and reloads by itself only
  when `pageIsIdle` (no wizard or dialog, no focused field or interactive terminal, nothing the person typed).
  Socket URLs follow `location.protocol` (`wss:` for 606).
- **Operations survive a restart** (`WebOperations`, `<store>/ui.operations.json`, 0600, written at each start/end —
  lines this file wrote, never a host result): a new UI marks a running one `interrupted` and RESOLVES it from the
  monitor's overview (`reconcile` via `WebMonitor.overviewHook`): the lifecycle target phase → done "finished while
  doz ui restarted", failed → failed, else the ended state `interrupted` (neutral, never ✕), 30 min at most. The page
  takes the server's list on `hello`.
- **A STOPPING host's sandboxes are busy, never shut down** (`HostWebData.overview`/`sandbox`): while `doz host stop`
  hibernates, its socket is closed and its lock held, so the UI reads the store in-process — a record still saying
  live read as `off`, and a page closes a shut-down sandbox's panes. Such rows are `busy` until the host is gone.
- **Tests**: `WebInstallableTests`, the 605 HTTP tests in `WebHTTPIntegrationTests`, `CommandTests` (alias, `--port`);
  probes `probes/605-*/` (`installable.mjs`, `restart-ui.mjs`, `restart-vm.mjs`; `guard-doz.sh` runs the earlier
  features' probes with the scratch-only rules enforced).

### `doz serve` — the dashboard for the other browsers of the LAN

- **A separate process, the same DozerWeb code**. `doz serve` holds `<store>/serve.lock`, answers `serve.sock` (one line in,
  one JSON line out: status, devices, share, revoke, rename, probe, stop — `WebServeControl`), keeps `<store>/serve/`
  (0700: `devices.json`, `audit.jsonl`, `port` — 0600). `DozerWebServer.bindServe` + `WebServeState`; `WebAuth` is
  `.browser(WebSessionStore)` (doz ui) or `.devices(WebDeviceStore)` (doz serve). Never let `UICommand.swift` reach it.
- **`--detach`** (rc.2): `DetachedLauncher` — the host's double spawn (`HostLauncher`'s pattern, untouched): an intermediate
  `serve start --launch-detached` (own session) spawns `serve start --launched --no-invite` (own session/group, parent
  launchd, stdin /dev/null, stdout+stderr `<store>/serve/serve.log`, no inherited fd, signals default), prints its pid,
  exits; the CLI waits for `serve.sock` to answer, then prints the addresses + an invite (a TTY only). `status` carries
  pid, since, version, detached, log, responsibleApp (the app macOS attributes it to — it survives the double spawn, as
  604 found for the microphone; Bonjour's Local Network ask is on its behalf). `probes/606-*/serve-detach.mjs`.
- **Loopback is served under `lan`** (rc.1 bug: on the Mac, `<mac>.local` resolved to ::1 and the silent drop read as
  "no response"): the Mac's own browser — 127.0.0.1, [::1], localhost, by name — with the same invite rules. **Only a
  sandbox's connection is dropped silently**; any other refusal (an address not served, the per-address cap) is
  answered over HTTP (`refusedConnections` → `refuse`). Invites print their LAN-address forms beside `.local`
  (`WebServeInviteAnswer.alternates`). `probes/606-*/serve-mac.mjs`.
- **Where it listens** (`serve.bind`): `lan` = the wildcard `[::]` with an accept gate on each connection's LOCAL address
  (`WebServeRules.isServed`: `en*`, `bridge0–99`, the `utun` holding a Tailscale address; a LAN interface's link-local
  too — m1a reached `<mac>.local` over fe80::), re-read every 3 s; `loopback` (127.0.0.1 + ::1, a proxy on this Mac);
  or the Mac's addresses. The port (`serve.port`, 7443) never moves: taken → refused, naming the holder.
- **Sandboxes NEVER reach it** (non-negotiable; `nat-source.md` measured that a NAT guest arrives with its OWN address):
  a peer in a vmnet bridge's (`bridge100`+) networks, Dozer's automatic NAT range 192.168.100–199.0/24 where no LAN
  interface is, or `defaults.nat_subnet` is dropped before a byte is read, and so is a connection to a bridge's own
  address. A bridge's link-local prefix is NOT a sandbox network (fe80::/64 is every interface's). Proxied sandboxes
  have no NIC — their traffic leaves from the host: `LocalDashboards` (DozerKit) makes `Wire.connectTCP` refuse the
  Mac's own addresses on the dashboards' ports (`<store>/ui.port`, `<store>/serve/port`, `serve.port`; the host sets
  it, 5 s cache) whatever the policy, `open` included. `probes/606-*/serve-sandbox.mjs` (NAT + proxied-open, with
  positive controls) is the test.
- **Admission**: an invite = a 256-bit link token (`#cap=`, posted as Bearer — the doz ui model) + an 8-char Crockford
  code (`{"code"}` on `POST /api/v1/session`) + the QR of the link; first use wins and kills the rest; 5 minutes; ≤ 8
  open. Wrong attempts: 10 per address / 10 min → 429; 20 wrong codes in all cancel every open code. A device's cookie
  is never stored (digest + CSRF only); its 401s say `not-admitted` / `device-revoked`; revoke ends its streams
  (`end: revoked`) and terminals (1008) at once. The cookie's Max-Age is 400 days, re-set at every renewal.
- **The request's own origin** (`WebServeRules.requestOrigin`, pure): `http://<Host>` when Host is one of the Mac's names
  (`<LocalHostName>.local`, gethostname) or served address literals (never link-local); else, ONLY from a
  `serve.trusted_proxies` peer, `X-Forwarded-Proto` (ws/wss count as http/https — Traefik sends wss on upgrades) +
  `X-Forwarded-Host` naming a `serve.public_origins` entry. `Origin` must EQUAL it. Over https: `__Host-doz_serve_<port>`
  + Secure; else `doz_serve_<port>`. A trusted proxy is exempt from the per-address connection cap (32): every browser
  behind it shares its address (an HTTP/2 page's module burst starved through Caddy before that fix).
- **`WebExposure`** — the closed table (a `switch` with no `default`; `ServeExposureTests` pins every route): remote may do
  everything except `secretEntry` over plain HTTP (403 `secret-over-http`; the page shows the reason instead of the field —
  `secretEntryAllowed()`) and `macScreen` (pickers, Open in Terminal: 403 `mac-screen`; hidden by `isRemote()`).
  `serve.*` settings are `ui: false`. A new route needs a decision there.
- **The page**: `state.serve` (from `sessionInfo.serve`), `core/session.js`'s serve sign-in (code or pasted link — the
  router's `#cap=` hand-off still works), `views/devices.js`, `components/share.js` + `components/qr.js` (the server
  sends the QR matrix as rows; SVG by createElementNS; `--qr-light/--qr-dark` tokens). An http page is not a secure
  context: guard `navigator.clipboard` (no service worker there either — `registerWorker` already checks).
- **The audit log** (`WebServeAudit`): admissions, shares, revokes, renames, every unsafe remote request (route, action,
  sandbox, outcome), terminal open/close, refusals, drops — collapsed per minute for the noisy kinds; never a body,
  cookie, token, code or header value. Rotated at 1 MiB × 3. `doz serve log`.
- **Doctor**: `ServeDoctor` fetches each public origin's `/api/v1/serve/probe` with a one-use token (serve.sock `probe`);
  `DOZ_TEST_SERVE_CA` (tests) trusts only a scratch CA. Bonjour failures are said, never fatal.
- **Tests**: `ServeQRTests` (ISO vectors + CoreImage round trips), `ServeRulesTests`, `ServeDevicesTests`,
  `ServeExposureTests`, `ServeHTTPTests`, `LocalDashboardsTests`; probes `probes/606-*/` — `serve-lan.mjs` (two Chrome
  devices on the LAN address), `serve-proxy.mjs` (Caddy + Traefik, a scratch CA, doctor), `serve-sandbox.mjs`,
  `serve-m1a.mjs` (curl + m1a's own Chrome over an ssh-tunnelled DevTools port). Probes use ports 17606–17609, never 7443.

### Sandbox pages, All sessions, Lineage, Operations, templates

- **The page is built around the sandbox.** The nav has a child per sandbox (from the overview —
  `ls` without session counts, re-read on `hello`, `changed` and an operation's end). A sandbox's page
  is a PERSISTENT section (`#sbx`): the control bar (`#sbx-bar`) and the inspector (`#sbx-details`, 603's tabs) re-render; `#terminals` never
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
- **Progress is ONE view in two terminals**: `ProgressBoard` + `ProgressTerminal`
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
  **The CLI's one-second hold ends by the CLOCK** (`Progress.holdTimer`), never at the next event, and
  **every pull is metered** (`ImageBaker.pull`: linux/arm64, `PullMeter`) — the lab's alpine and the guest
  init image (pulled first in `prepareAssets`; ContainerManager would fetch it silently, every platform)
  included. Together they made a first `doz exec` silent for 18 s (`ProgressHoldTests`, test-cli's
  "first exec … shows its progress").
- **Every button has an icon**: Lucide (`vendor/lucide-static/`, pinned like ghostty-web;
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
- **A workspace that does not exist is MADE** (`Workspace.swift`): `Workspace.prepare` (normalize —
  absolute or `~/`, links in the existing part resolved — then `refusal`, then `mkdir -p`) runs in
  `create` and `duplicate` BEFORE the VM is configured; `Workspace.undo` removes, innermost first, only
  folders it made and only while empty, when the create fails. Refused, never made: an existing file, a
  missing folder in the store or under a system location (`Workspace.systemPrefixes`), `/`, home.
  No workspace = **isolated** (the one word: `ls`, `--json` `"isolated": true` with `"workspace": null`,
  the UI badge, the agent's facts). The UI's defaults (`Workspace.suggestedName`/`defaultPath`,
  `defaults.projects_dir` — a path, so `doz config set` only) and the Mac's folder picker are
  `WebWorkspace.swift`: `POST /api/v1/workspace/check` (makes nothing) and `/choose` (a FIXED
  AppleScript run by `/usr/bin/osascript`, the start folder and one of the FIXED prompts its argv; one
  at a time → 409; tests use `DOZ_TEST_FOLDER_PICKER=/path|cancel` or `setRunner` — never a real dialog).
- **Quick add / `doz new`** (`DozerHost/QuickAdd.swift`): ONE plan for both — `QuickAdd.plan`
  (the image `defaults.image` or given; the name `Workspace.suggestedName` past sandboxes and non-empty
  folders, or a given one — taken → `.exists`; the workspace `<projects_dir>/<name>`, nil when isolated)
  and `QuickAdd.requirement` (what one click cannot decide: the agent's account via
  `AgentCredentials.createProblem` unless the image's network is nat/none, then an out-of-date image).
  The UI: `POST /api/v1/quick-add` {image?, isolated?} (CSRF, makes nothing; `WebQuickAdd.swift`) →
  the page runs the ordinary `create` action, waits for its end (`waitOp`), then `startWithBootView`;
  a requirement opens `createDialog({why, kind, image})` instead. The CLI: `New` (LifecycleCommands) —
  create → start → open the session → attach; `preflightAgentAccount` + `chooseImage` as `create`.
  **`defaults.projects_dir` stays read-only to `POST /settings`** (a host path); its Settings-page
  **Choose…** is `POST /api/v1/settings/projects-dir/choose` `{}`: the Mac's picker with the projects
  prompt, and the SERVER writes what was chosen (`WebSettingsStore.applyProjectsDir` → `applyHostPath`;
  never `/` or inside the store; env/flag/unreadable file refused as in `apply`).

### Onboarding, projects, the agent's environment prompt

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
  `setup-token`, `later` ("Decide later": one option for none/skip). A key or a token goes
  ONLY through `HostRequest.accountAdd` — the request `doz account add` sends (the login keychain, the one
  check request, `--plan`) — from `doz onboard`'s no-echo prompt (off a TTY only with `--secret-stdin`) or
  the web UI's masked field. `doz onboard --account …` skips the Claude Code checks entirely; `doz ui`
  under `DOZ_TEST_NO_MAC_LOGIN=1` (a test seam, the probes') never looks at the Mac's login.
- **Secret entry in the browser**: `ui.allow_secret_entry` (default on; the UI can turn
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
- **The New Sandbox wizard and `doz init` share ONE model** — `DozerHost/Project.swift`: `DozerProject`
  (every key, `render`, `createOptions`, `problem(effectiveNetwork:)` the whole-project check, `dropDefaults`
  — a pre-filled value equal to the setting's is left commented unless `explicit`, `lineDiff`, `find(in:)`
  which reads `doz_project.yml` too and throws when BOTH exist) and `ProjectWizard.steps` (the 10 steps both
  walk). READING stays in the CLI (`ProjectFile.swift`, `extension DozerProject { parse/load }`); `doz ui`
  installs that parser into `WebProjectFiles` so the dashboard never imports Yams. The dashboard
  (`WebProject.swift`): `POST /api/v1/project/open|preview|write` (CSRF, strict bodies) and the action
  `project-create {folder}` → `.create` with `DozerProject.createOptions` (exactly `doz up`'s). The review is
  `render()` READ BACK by the parser; a write replaces an existing file only when `replace` = SHA-256 of what
  is there (the page showed the diff and the person confirmed), else 409. Key `permissions`: the
  `defaults.permissions` words, given to the host as `allow = ["standard"] + words` (a preset alone as is);
  `permissions`/`github` with a network of bake/nat/none is refused. `agent_prompt` renders `|-` when it has
  no final newline (exact round-trip). The page: `#/new` (`viewNew`, `nw*` in `views/new-sandbox.js`; never re-rendered
  by a live refresh); only `explicit` keys are sent. Its Access step IS 599e's `renderAccessStep` (mode
  'sandbox', state `nw.access`, pre-filled from the file else `defaults.github`/`sandbox.ssh_agent`; Next
  confirms, Back does not) — the choices become the file's `github`/`ssh_agent`; `doz init` uses 599e's
  `AccessStep` (`subject` "this sandbox", no source question — the token source is the Mac's). A file with
  `permissions` but no `github` keeps `defaults.github` (`createOptions(…settings:)`). `make test-cli-projectwizard` drives an interactive
  `doz init` through `script(1)` (the Asker needs a controlling terminal).
- **`doz uninstall`** removes a store only if it looks like one, the settings dir only if named
  `dozer-sandbox`, and the installed doz only when THIS executable is `<prefix>/libexec/doz/doz` (the
  `bin/doz` link only if it resolves to it). Never the keychain; a running `doz ui` refuses it.
- **Tests on throwaway paths only**: `make test-cli`'s onboarding part uses `/tmp/dzo-<pid>-*` stores (a
  socket path under 104 bytes) seeded from the vmtest store, each with its own XDG_CONFIG_HOME; the
  wizard probe (`probes/594-*/run-wizard-probe.sh`) a fresh `/tmp/dzw-*` store.

### Session memory and saved screens

- **Saved screens exist ONLY for a sandbox one wakes back into** — paused, asleep, hibernated.
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
  session; a running one is reached through its pane, the empty area's "Open NAME" or the inspector's
  Sessions tab. Split's watch/attach kinds stay: they name the left pane's session explicitly.

### Boot logs

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

### Public builds — `BuildFlavor`

- **`make release` builds the PUBLIC flavor by default** (`PUBLIC=1` → `-DDOZ_PUBLIC_BUILD`; `PUBLIC=0` only for a private
  rc, which then needs `SOUND_KERNEL=<file>` or `NO_SOUND_KERNEL=1`). A public build has NO Dozer-own ChatGPT sign-in
  (it uses Codex's public client id — Codex's to use): `doz account add --chatgpt`, `onboard --openai-account chatgpt`,
  the create preflight and the dashboard never offer it, the host refuses `account-add` of kind `chatgpt`, and a
  ChatGPT account an earlier build stored is KEPT but never used (`unsupported` in `account ls`; every request says
  why — `ChatGPTSession.unsupported`). Codex keeps `mac` (the Mac's own Codex login) and OpenAI API keys. And NO sound
  kernel: `--audio` is refused with `BuildFlavor.audioMissing`. `release.sh` proves the flavor on the packed binary.
- Every decision takes a `BuildFlavor` (`HostCore.setBuildFlavor`, `OpenAIChoices`); a real process can be told with
  the TEST seam `DOZ_TEST_PUBLIC_BUILD=1|0`. `BuildFlavorTests` runs both modes in one `swift test`.

### Anonymous usage statistics and the sign-up — the open half

- **This repository holds the open half ONLY**: `Sources/DozerHost/Usage.swift` decides WHAT may be sent and WHETHER;
  the official builds' closed package (statistics sender + sign-up client, private, Foundation-only) only SENDS what
  it is handed. Never put the sender, an endpoint, a key or any closed code here. It joins a build only through
  `DOZ_CLOUD_PACKAGE` (Package.swift adds the dependency and defines `DOZ_CLOUD`; `Sources/doz/DozerMain.swift` calls
  `Usage.install(send:flush:signup:)` under `#if DOZ_CLOUD` — `canImport` alone is wrong: a module left in `.build` by
  an earlier official build makes it true in a build that does not link it). The audit allows `DozerCloud` in that
  file only. Without it (`make cli`, `make test`, CI, forks) `Usage.isOfficial` is false: nothing is recorded or sent.
- **The closed list** (`UsageSchema`): messages `installed`, `upgraded`, `daily`; every key in `UsageSchema.keys`/`nested`,
  every value a count, an ASCII range (`<=8`, `9-11`, `5-30m`), a time rounded to 50 ms (≤ 1 h, p50 ≤ p90) or a word of
  Dozer's own vocabulary (command names from the CLI's own tree — `UsageCommandName`, never an argument; agent ids;
  base CATALOGUE ids — a Dockerfile base is `dockerfile`, never its `df-<hash>` (a hash of the user's path), a
  template is not counted; network presets). `UsageSchema.problems` is the receiving side's validator ported, and
  `UsageRecorder.handOver` drops any message it does not accept. A new field is a schema change on BOTH sides and in
  the privacy policy — never just a new key here.
- **Nothing private is collected for it**: the day's numbers come from what the host already records (`metrics.sqlite`
  action rows — phases with their times, creates, removals, preparations; the network table's minutes; the store's
  sandboxes, restore points, workspace rule files, permissions, doz serve's devices; `onboarded.json`) and the commands'
  own counts, computed on the Mac (`UsageStoreFacts`, `UsageTimeline`, `UsageDailyBuilder` — pure, tested on a fixed
  history). What the host did not record before, it now writes to the SAME local metrics, as times only: rows `attach`,
  `exec` (activity), `agent status` / `agent working` (612's status; working time from when `working` began), the create
  row's detail `account` (the KIND: mac, api-key, setup-token, none — never a name), and a failed preparation's
  `failedStep` (`PreparationStepID`: the metrics' fixed step keys, a recipe's bake step only as `bake-step`). The page sends
  `X-Doz-Display: standalone|browser` with its page-load renewal; only `standalone` is recorded (`app`), only while on.
- **How the time block reads**: a running or asleep stretch is counted ONCE, on the day it ends, by its whole length (a
  host crash ends one when the next host notices; a stretch still open is counted when it ends); `running_total` is the
  running time within the day; `removed_age` is from the sandbox's create row; `idle_running_8h` counts sandboxes with a gap
  of 8 h or more between activity (attach, exec, a session opened or restarted, agent status, network use) inside a running
  stretch, ending that day — an attach held open for hours counts only at its start. `first_sandbox` and
  `time_to_first_session` (from `firstSeen` in usage.json) are each sent once.
- **The off switches, checked before anything is recorded** (`UsageSwitches.decide`): not official → off; a guarded test
  run → off; a development build (`InstallMethod.development`) → off; `DO_NOT_TRACK` (anything but empty/0/false) →
  off, even against the flag; else the setting `telemetry.send_anonymous_usage_stats` (flag > `$DOZ_SEND_ANONYMOUS_USAGE_STATS`
  > file > default true). Turned off for good (setting/env/DNT), the recorded days are forgotten.
- **What is kept**: `<settings dir>/usage-id` (random lower-case UUID, `doz telemetry reset`) and `usage.json` (today's
  counts, a closed day, the last version, the notice) under a `flock`. **When**: `DozerEntry` counts the command BEFORE
  it runs (`UsageHook.before`) and after it records a failure's exit code and hands over what is due — `installed` /
  `upgraded` once per version, the `daily` of a closed day (≤ 7 days old) on the first command of a later day — then
  `flush(1 s)` only when something was handed over. Never for `telemetry`, help/`--version`, internal re-launches
  (`--launched`, `--launch-detached`, `--restarted`) or `host upgrade-check`. The one-line notice: once, official and
  on, stderr on a terminal, never `--json`/`-q`.
- **The sign-up** (`SignupRequest`: email + `release-news`/`early-access`/`support` + source): `doz signup`, `doz onboard`'s
  Stay in touch (terminal only; `--yes` skips), the wizard's Stay in touch step → `POST /api/v1/signup` (strict
  `{email, interests}`, CSRF; the source is the server's; a failure is ONE fixed message; 404 `signup-unavailable` in an
  open build, whose page hides the step and shows `sessionInfo.signupPage`). The email is never logged, echoed or kept;
  `SignupRequest`'s description is redacted. Independent of the statistics switch and never linked to them.
- **Release**: `make release` passes `DOZ_CLOUD_PACKAGE`/`DOZ_CLOUD_REF` from `Makefile.config` (never exported to other
  targets); `release.sh` refuses a PUBLIC release without it (TEST_BUILD=1 excepted), checks the packed binary's
  `doz telemetry show --json` says `"official": true` (scratch folders; looking never sends), restores
  `Package.resolved` if a URL pinned the package, and writes `RELEASE` = `public+cloud` (`publish.sh` accepts `public*`).
- **Tests**: `UsageTests` (the encoder vs the list byte for byte, refusals, buckets, the daily from metrics rows, the
  switches, once a day/version, the notice, a FAKE installed sender), `WebSignupTests`. A fake closed package for an
  end-to-end look lives in the workspace's probes (`DOZ_CLOUD_PACKAGE=<it> swift build --product doz`); never point a
  test at the live endpoint.

### Updates: the signed feed, channels, `doz upgrade`

- **ONE feed, frozen, compiled in**: `https://updates.dozersandbox.com/v1/feed.json` (`Distribution.feedURL` in
  `Sources/DozerHost/Updates.swift` — with `tap`, `repository`, `teamID` and `updatePublicKey`, the ONE place these
  names live; the scripts read them with `sed`, and `docs-drift-check` fails on a doc naming another tap/repo). `/v1/`
  is the FORMAT — a new format is `/v2/` beside it, never a change to v1. All three channels in one file, each entry
  tagged; stable ⊂ beta ⊂ canary.
- **Each entry is signed with DOZER's own Ed25519 key** (never Deckosaurus's): the private key lives ONLY in the
  publishing Mac's login keychain (`make doz-update-keys` makes it, once, after asking; `Scripts/update-key.swift`;
  through `security -i` stdin) + an offline backup. Never rotate it — every installed doz trusts the public
  key compiled in. The signed message (`UpdateSignature.message`, and the script's twin) covers version, build, the
  archive's FILE NAME, sha256 and size — NOT the channel (a promotion needs no key). An entry that does not verify is
  dropped; a feed that is not one is ignored; each said ONCE (`UpdateState.reportedProblem`). Tests use a throwaway key.
- **The client** (`UpdateChecker`): at most daily (a failed check retried after an hour) + forced when `doz ui`
  starts (and daily while it runs); conditional (If-None-Match/If-Modified-Since); offline silent; state in
  `<settings dir>/updates.json`. Never a downgrade (`SemVer`; `WebVersion` delegates to it). Never in a guarded test
  run without its own feed (`DOZ_TEST_UPDATE_FEED`), never for a development build (`InstallMethod`: a Homebrew keg
  by its Cellar path; a tarball install by `libexec/doz/{VERSION,RELEASE}` — `release.sh` writes `RELEASE`,
  `make install-cli` does not). Settings `updates.mode` (off | notify | auto) and `updates.channel` (a Homebrew
  install's formula decides while it is unset).
- **After a command** (`DozerEntry` in `UpdateCommands.swift` is `doz`'s main: ArgumentParser's parse-and-run, then
  `UpdateHook.afterCommand`): only on a terminal (stdout AND stderr), never `--json`/`-q`, never for
  update/host/serve/uninstall/config; one stderr line per version per day. `auto` installs only when
  `UpdateInstaller.busyReason` is nil (no host, or one with no live sandbox and no other client) — else the line says
  why not. Homebrew: `brew upgrade <formula>`; a tarball: download → size + sha256 of the SIGNED entry → unpack →
  `codesign --verify --strict` + team `KJ8QMLWB97` → its `--version` → ONE `renamex_np(RENAME_SWAP)` of `libexec/doz`,
  the previous kept as `libexec/doz.previous` (a running host keeps its inode — the 591 rule). Then "Updated to X —
  restart to apply: doz host restart" (`doz host restart` = stop with progress + start). The dashboard's banner reads
  `UpdateChecker.remembered` (no network per page) via `WebSessionInfo.update`.
- **`doz upgrade [--check] [--channel X]`**: `--check` exits 10 when one is available; `--channel` writes the setting
  and, for Homebrew, switches formulas (`brew uninstall` then `brew install <tap>/<formula>`, reinstalling the old one
  if that fails) — refused when the new channel's newest is not newer (never a downgrade).
- **Publishing** (`make publish VERSION= NOTES= CHANNEL=canary`, `make promote BUILD= CHANNEL=`; `Scripts/publish.sh`,
  `promote.sh`, `feed.py` — Deckosaurus's appcast design as JSON): per-build fragments `v1/items/build-N.json` → the
  generated, deterministic `v1/feed.json` + `v1/notes/V.html` in `UPDATES_DIR`; the three formulas (each channel's
  newest; `Scripts/homebrew/doz.rb.tmpl`, conflicting with each other) in `TAP_DIR`. Idempotent; a published version
  is never re-cut; promote never rebuilds and only widens; nothing is pushed without `PUSH=1`; the GitHub release
  command is printed, never run. A publish refuses a key that doz does not trust. Seams: `TEST_PUBLISH`,
  `UPDATE_KEY_FILE`, `UPDATE_PUBLIC_KEY`, `ARCHIVE_BASE`; client `DOZ_TEST_UPDATE_{FEED,KEY,EXECUTABLE,TTY,ALLOW_ADHOC}`,
  `DOZ_TEST_BREW`.
- **Channels in practice**: stable (`doz`) is the published, recommended channel; development happens on canary. The
  workspace's `Scripts/doz-rc` (an rc) and `Scripts/ship` (a shipped version, a GitHub PRE-release) both publish to
  CANARY only (`make publish CHANNEL=canary PUSH=1`); stable moves only when the owner says so: `make promote
  VERSION=… CHANNEL=stable PUSH=1`, then `gh release edit vX.Y.Z --prerelease=false --latest`. (`PUSH=1` refuses
  UPDATES_DIR/TAP_DIR that are not git checkouts with an origin.) Before the unveil, releases went to a private
  prelaunch repo + tap (now archived; `DOZ_PUBLIC=0` in `_ship_common.dozer_profile` still names that era).
- **Tests**: `UpdatesTests` (unit), `make test-updates` (the real binary: release-shaped tarballs → publish → promote →
  a local feed server → check/notify/silence/off/channels/downgrade/tampered/auto swap/fake brew).

### The release and Homebrew

- **`make release VERSION=X.Y.Z`** (`Scripts/release.sh`) is the ONE way the artefact is made:
  release build → `dist/stage/doz-X.Y.Z/{bin/doz → ../libexec/doz/doz, libexec/doz/{doz, VERSION,
  DozerKit_*.bundle}}` → signed → `dist/doz-X.Y.Z-macos-arm64.tar.gz` + `.sha256`. It checks the
  signature (`--verify --strict`), the virtualization entitlement, and that the packed `doz --version`
  says X.Y.Z. `Scripts/ship` (the workspace) runs it after tagging DozerKit, attaches both files to the
  tag's GitHub Release and moves the tap's formula (`RELEASES` in the ship).
- **The version comes from the tag, never a hand-edited constant**: the tarball carries
  `libexec/doz/VERSION`; `DozerCommand.version` reads it beside the resolved executable
  (`ReleaseStamp`) and falls back to `builtVersion` for `make cli` / `install-cli` / tests.
- **Signing**: a Developer ID (`SIGN_IDENTITY`, and `NOTARY_PROFILE` for `notarytool`) comes ONLY
  from the gitignored `Makefile.config` (`Makefile.config.example`); then `--options runtime
  --timestamp` (the entitlements work under the hardened runtime — measured, cold boot and wake), every
  Mach-O in the bundles signed too (the guest binaries are Linux ELF: left alone), notarised, checked
  with `spctl`. A bare CLI cannot be stapled. Never a password in a file, never `notarytool` without a
  profile. `DRY_RUN=1` prints every command. 611: a PUBLIC release refuses to build unsigned or
  unnotarised (`TEST_BUILD=1` is a local test build, never published); a preflight asks the keychain for
  the identity and the profile authenticates BEFORE the build; the signed binary is checked for the
  authority, the team id, the hardened-runtime flag, a secure timestamp and both entitlements
  (virtualization, audio-input); notarisation must answer `Accepted` (else its log is fetched) and Apple's ticket service must hold a ticket for
  the binary's CDHash (`Scripts/notary-ticket.sh` — NOT `spctl`: a bare CLI cannot be stapled, and spctl answers from a
  stapled ticket or Gatekeeper's local cache, "Unnotarized Developer ID" for a freshly notarised tool — 0.31.0); and the TARBALL is unpacked afresh and checked (`codesign --verify --strict`,
  `doz --version`). Never edit sources while `make release` builds (SwiftPM stops: "modified during the build").
- **Resources are found beside the RESOLVED executable** (`DeckholdBinary.candidateBundleDirectories`,
  `WebAssets`, `HostLauncher.executablePath`): the Homebrew keg (`Cellar/doz/V/libexec/doz`, reached
  through `bin/doz` links) works with no path hard-coded — keep it that way.
- **An upgrade removes the previous keg under a running host** (`brew upgrade` runs `brew cleanup`):
  the host keeps its open program and its VMs, but a boot would fail on a missing guest binary. So
  `HostCore.programGone()` (the executable removed, or deckhold/doznet not found) refuses every
  `bootOps` op and a wake-by-use with "this host's program … is gone — `doz host stop`, then retry";
  `host status`/`doctor` say so; the idle loop exits it once nothing is live. `doz host upgrade-check`
  (the formula's post-install) says when a host of another build runs — via the socket, else the pid
  file + `proc_pidpath` (Homebrew's post-install sandbox) — never starts/stops one, always exits 0.
- **`doz uninstall` never removes a Homebrew keg** (`Uninstall.homebrewKeg` — any channel's formula: doz,
  doz-beta, doz-canary): it removes the store and settings and names `brew uninstall <formula>`.
- **The tap** (`Distribution.tap`, `dozer-sandbox/tap` → the repository `dozer-sandbox/homebrew-tap`): one
  formula per channel, `Formula/doz.rb`, `doz-beta.rb`, `doz-canary.rb`, GENERATED by `make publish`/`promote`
  from `Scripts/homebrew/doz.rb.tmpl` (arm64, macOS 26+, conflicting with each other, `post_install_steps` →
  `host upgrade-check`, a `test do` that runs `--version` and `doctor --json` in a scratch store).

### Resources

- **Everything adds up.** `Resources.walk` measures the store as `du` does (allocated blocks, `lstat`,
  a hard link once) and `classify` puts EVERY entry on exactly one leaf row; the report's
  `unattributedBytes` = the walk's total − the entries of the rows shown, and must be 0 (the page shows
  it red otherwise; `ResourcesTests` checks it against `/usr/bin/du`). A new kind of file in the store
  gets its leaf in `classify` — never a silent fall-through (anything unknown is `stray:<top name>`).
- **Three numbers**: size (allocated — a clone in full), freed if deleted (`DiskAccounting.exclusive`:
  the blocks only that group's disks reference, plus the allocation of its non-disk files), used by.
  Reuse 587's extents (`F_LOG2PHYS_EXT`); never re-measure differently. "Freed" of a selection is one
  sweep over the whole selection (blocks shared between its items counted once).
- **Deleting never breaks a sandbox**: a sandbox's disks are refused (its page removes it); the
  current kernel and `initfs.ext4` are refused while any sandbox is paused/asleep/hibernated (their
  snapshots need them) or running; any kernel a snapshot needs or a sandbox's spec names
  (`SandboxSpec.kernelPath`, from `kernel.path` at its create), and a current kernel that is not this
  build's pinned one (only the pinned one is fetched again); images being prepared, and the download cache/base disks while any
  is; a stray folder that is a sandbox's workspace or share; anything outside the store; Dozer's own
  records. A parent with a refused part is refused whole.
- **Paths come from ids, never from a request.** Ids are `Resources.isValidID` (and the web's strict
  decoders); `plan` validates them against a FRESH inventory; `execute` removes only the entries its
  own walk classifies under the leaves (top-most first) or the fixed places (restore point dir, screens,
  boots, `content` + `state.json`, `initfs.ext4`); logs are truncated, metrics cleared through
  `MetricsStore.clearHistory` (the running host's own run kept).
- **Serialised with the lifecycle**: `resources-rm`/`-clean` wait (≤ 2 min, a `note` event says why)
  until `diskOpsInFlight` is 0 (every op in `HostCore.diskOps` counts itself in `handle`; a wake by
  use counts in `ensureRunning`), no preparation runs and no sandbox is busy or booting — then read the
  facts, re-check synchronously, and plan + delete with NO suspension point (the actor runs nothing
  else). A dry run is read-only (in-process with no host); a deletion needs the host.
- **Clean up** = `cleanIDs`: cleanable (re-creatable AND unused — an image key no sandbox was created
  from in `resources.clean_unused_days`), deletable, not refused — and never templates, sandboxes,
  points, screens, boots, logs, metrics, the guest init, stray or outside rows, or an image parent. The
  page and the CLI delete exactly the ids the preview showed (`resources-rm`), never a re-computed set.
- **The page measures on arrival, Refresh and an operation's end** — never on a live `changed` event
  (it reads every disk's extent map). The web projection drops `path`; the preview is a CSRF-checked
  POST that changes nothing; there is no delete ROUTE — only the typed actions.
- **"Use this kernel"** writes `kernel.path` (nil = the pinned one): new sandboxes only (the kernel is
  baked into a sandbox's spec at create); refused when `DOZ_KERNEL` sets it.

### Base images: agent × base

- **An image is two choices** (`ImageChoice`): the AGENT (claude-code · pi · none) and the BASE (a
  `BaseCatalogue` id, or `df-<12 hex of the Dockerfile's path>`). Its name is `<base>-<agent>` (`<base>`
  alone for none) — except the three that existed: `claude-code` (Node · Claude Code), `pi` (Node · pi),
  `lab` (Alpine · none, its own `bakePackages` path). Every switch on an image NAME goes through
  `ImageChoice.parse(…)?.agent` (credentials, the default session, the agent prompt, settings sections,
  `withClaudePermissions`) — never `== "claude-code"`.
- **The Node images are byte-identical to before 596** (`BaseImagesTests.test_nodeImagesAreByteIdentical`
  pins their canonical JSON): `ImageComposer` returns `AgentImages.claudeCode/.pi(release, base:)` for
  the catalogue's Node, `ImageSpec.bakeHosts` is nil for them (absent from the canonical JSON), and the
  launcher's `.node` script is the old one. Keep that test green: a key change re-bakes every store.
- **Claude Code on a base without Node is its NATIVE build** (`NativeClaudeBuild`: the sha256 of
  linux-arm64 and linux-arm64-musl from `downloads.claude.ai/claude-code-releases/<v>/manifest.json`,
  resolved on the Mac — `AgentVersions.refresh` remembers it per version in agent-versions.json; the pin
  for 2.1.227 is built in), its setup in python3 (`claudeSetupPython` — the same keys as the JS). pi on a
  base without Node: Node's official tarball under /opt/node (`NodeRuntime`, checksum-verified; Alpine:
  apk nodejs), and `/usr/local/bin/pi` puts it first on pi's PATH only. Steps before the baseline run in
  POSIX `sh` on apk/auto bases (Alpine has no bash).
- **Bases are digest-resolved, never followed silently**: `BaseDigests` (`<store>/base-digests.json`)
  asks the tag's registry at most hourly (`freshen`; `DOZ_TEST_BASE_REGISTRY=offline|pinned`), a
  preparation uses the last digest (else the catalogue's pin). A prepared image made from an older digest
  is `ImageRow.baseUpdate` / `BaseRow.updateAvailable` — offered, never rebuilt. The W28 recipe check
  is `ImageComposer.recompose(spec)` (same base, same release) — it works for every pair.
- **A base's language registries join a proxied policy** (`NetworkPolicy.adding(registries:)`, HTTPS,
  appended, preset name kept; locked/open untouched); a bake reaches the spec's `bakeHosts` too
  (`NetworkPolicy.bake(adding:)`).
- **Dockerfiles** (`Dockerfiles`, `<store>/dockerfiles.json`): a create registers it (validated: absolute,
  a file ≤ 1 MiB, not in the store); a sandbox made before its first build holds a placeholder base
  (`dozer.local/df-…@sha256:0…`) and its start builds, then `rebindDockerfileImage` re-adopts it with the
  built spec (only with no root disk). A preparation runs `container build -t dozer/<base>:latest` then
  `container image save --platform linux/arm64 -o` (1.2.2's `-o type=oci,dest=` fails after exporting),
  `DockerfileImport` → `OCIImport.load` into Dozer's store as `dozer.local/<base>@<digest>`; the SAME
  LAYERS keep the previous reference (nothing re-baked — B8). The image's ENV reaches sessions (PATH
  entries ahead of the defaults). "Dockerfile changed — rebuild available" comes from the file's sha256.
- **Apple's `container` is started or installed only because a person asked** (`ContainerTool`):
  `builder-start` = `container system start --enable-kernel-install`, `builder-install` = the pinned signed
  pkg, sha256-checked, `pkgutil --check-signature`, opened in Installer — never sudo. The CLI asks (or
  `--yes`); the page shows what each does before its button. Seams: `DOZ_TEST_CONTAINER` (a fake; a
  non-executable path = not installed), `DOZ_TEST_CONTAINER_INSTALL` (records, never downloads/opens),
  `DOZ_TEST_FILE_PICKER`, `DOZ_TEST_APPLE_CONTAINER_ROOT`. **B9: a Dockerfile build runs OUTSIDE Dozer's
  network policy** — said on the card, by the CLI, and in the preparation's log (`Dockerfiles.outsidePolicyNote`).
- **Apple's storage is shown, never deleted** (`Resources.appleContainerItems`): an `outside:apple-container`
  row (its data folder by part, the program, Dozer's own `dozer/…` images), not in Dozer's total or the
  unattributed check, no checkbox on the page.
- **Never rebuild a running test's `doz` in place**: a long VM run (the matrix) runs from a COPY of the
  binary and its bundles — `make cli` under a running host is an earlier incident.

### Agent permissions

- **A proxied policy is permissions, stored BY NAME** (`NetworkPolicy.permissions`; the catalogue is
  `AgentPermissions.all` in the library). Evaluation uses `effectiveRules` (the user's own `rules` FIRST,
  so they win, then the hosts of each permission as THIS build defines them) and `effectiveDefault`
  (`web` → allow). Anything that reads a policy's hosts must use those two, never `rules` /
  `defaultAction` directly — a permissions policy's `rules` are only the user's sites. A pre-597 policy
  (`permissions == nil`) evaluates exactly as before; `PermissionPolicy.inferred` shows it as
  permissions and its first permission edit converts it (`asPermissions`: what it allowed stays allowed).
- **Presets `locked` / `agent` (Standard) / `open` are sets of permissions per base**
  (`AgentPermissions.preset(_:base:)`, Standard = model, update, `install:system` + the base's
  ecosystems, github, error-reports); `bake` stays a policy of RULES (preparation). `DozerImages.spec`
  gives a new proxied sandbox: the form's exact `permissions`, else the preset named by `--network` or
  the image's network setting (resolved `source != .default` — `settings.string` returns defaults too),
  else `defaults.permissions`; `--allow` words on top (`site:HOST` → a user rule).
- **Claude Code's hosts must keep working** under Standard: api/statsig (model), downloads.claude.ai +
  pi.dev + the agents' own npm packages by path (update), the Datadog intakes (error-reports), GitHub
  (github). `AgentPermissionsTests.testClaudeCodesOwnHostsBelongToItsPermissionsAndKeepWorking` and
  `make test-cli-permissions` (real curls from the guest) pin it. "Update itself"'s npm rule is
  path-conditioned (the proxy decrypts) — dropped when `install:node` allows npm whole.
- `model` cannot be revoked; `web` / `open` warn and ask (CLI `confirm`, page `confirmWeb`). Sign in is
  off in Standard; the strict sign-in block still applies on top when it is on.
- Edits: `HostRequest.grant/revoke` on `net-policy` (`PermissionPolicy.edited`, pure — the web preview
  uses it too); the checklist + suggestions from the log are `net-permissions` (read-only,
  `PermissionReport`). The facts block's `network.permissions` / `network.description` list them in
  plain words (`PermissionPolicy.facts`).

### Session bridges

- **One place: the host's attach relay.** Every terminal (`doz attach`/`run`/`up`, every `doz ui` pane)
  reads a session through `HostServer.pump`, so the bridges live there: `SessionBridgeScanner` takes
  OSC 52 and OSC 6340 (`doz-open`) out of DATA frames (never a SNAPSHOT — a replayed screen must not
  re-copy; `reset()` on each), `HostCore.bridge` decides (nonisolated — pbcopy and `open` never run on
  the actor), and each viewer is told with `ClientWire.notice` (`ESC]777;doz;notice;KIND;TEXT BEL`,
  every control character stripped). Both clients take notices out BEFORE `findEnding`, and hold an
  unfinished one (`ClientWire.unfinishedNotice`) — a notice split by a read must never reach a screen.
- **Two viewers of one session see every sequence twice**: `BridgeState.once` acts once (the copy's
  hash within 2 s — serialised, so two pumps cannot both act) and both get the notice.
- **An OSC 52 READ is never answered and never forwarded** (the outer terminal would answer it with the
  Mac's clipboard); logged once per session. Everything a scanner does not own passes through byte for
  byte (`SessionBridgeTests` cuts at every offset).
- **The CLI's drawn line** (a notice; B4's menu) is DECSC → bottom row → reverse video → DECRC, removed
  by a REPAINT (`ClientWire.repaint`, `0xFF 'S'`): the host sends deckhold HELLO 0×0 on the live
  connection (`SessionConnection.repaint`) — a fresh snapshot, no resize, no deckhold change.
- **Per-sandbox settings** (`DozerSettings.perSandbox`): `SandboxConfig.settings[key]` wins over the
  file (`HostCore.sandboxValue`); `sandbox-settings` reads (in-process when no host) and sets;
  `doz config … --sandbox`, `doz create` flags, `doz_project.yaml` keys (`DozerProject.settingKeys`,
  synced by `doz up`). `sandbox.agent_sudo` keeps its own field.
- **The browser bridge (B2)** is DeckStack's technique, re-done (never a DeckStack dependency): the
  guest shim (`GuestCommand.openShim`, `/usr/local/lib/doz/bin`, written by `prepareGuest` AND at each
  session open — a woken sandbox predates it) writes ONLY `ESC]6340;doz-open;URL BEL` to `/dev/tty`, else
  `$DOZ_TTY` (deckhold exports the session's pty: a `setsid` opener has no ctty), else stdout when it IS a
  terminal, else refuses (exit 1) — `2>/dev/null` BEFORE `>` on each rung. **Never a line a person sees**
 : text written behind an
  agent's TUI desynchronises its cursor-relative redraw (Claude Code draws blanks as cursor jumps — the
  shim's leftovers showed where spaces should be: "space doesn't work" in the web pane, which attaches at
  the session's size and so never makes the TUI redraw); the Dozer notice tells the person, stderr + the
  exit status tell the caller. Every viewer reads the host's stream through ONE `ClientWire.ViewerStream`
  (notices out, the end found, a notice's start held — `XdgOpenSilenceTests` cuts at every offset). `BrowserBridge.check` = http/https only, never
  the Mac's loopback; `callback(in:)` reads ONLY `redirect_uri` (http, `localhost`/`127.0.0.1` exactly,
  explicit port ≥ 1024). `LoopbackForward` binds the Mac's 127.0.0.1 (+ [::1]) BEFORE the URL opens,
  relays each connection through `Sandbox.openGuestStream([deckhold, connect, -p, PORT])` (no NIC
  needed), ends 3 s after the first answered callback or at 10 min; one per sandbox. Notices and the
  host log show `BrowserBridge.shown` (scheme, host, path) — never the query (a sign-in's state).
- **A login shell resets PATH** (/etc/profile on Alpine and Debian): the shim's dir comes back through
  `/etc/profile.d/doz-browser-bridge.sh` (written with the shim). A test in `bash --norc -i` would not
  have caught it — `test-cli-browser` checks `bash -lc`.
- **tmux (B3) runs INSIDE deckhold**, never instead of it: `GuestCommand.inTmux` = `tmux -L doz-NAME -f
  tmuxConfPath new-session -A -s NAME ARGV…` — a server PER SESSION (a shared server would give a later
  session the first one's environment: its placeholders, its `$DOZ_TTY`). `tmuxPrepare` writes the conf
  and answers `tmux=yes|no` in the one root exec the session open already makes; no tmux → run without
  it + `SessionOpened.notice`. The conf keeps the bridges alive (`set-clipboard on` + the clipboard
  feature: tmux passes OSC 52 out; the shim sends its marker to `$DOZ_TTY` when `$TMUX` is set, because
  tmux drops a sequence it does not know). The "already running" check compares the wrapped argv too.
  tmux is in `devBaselinePackages` and `labPackages` — a recipe change: W28's "older recipe" names it.
- **The title and the Ctrl-] menu (B4)**: no reserved rows. The attach client pushes the
  terminal's title (CSI 22;0 t) the first time it sets one, re-renders `TerminalTitle` each minute and
  on every attach answer (a switch, a hold: the host's attach answer now carries `image`), and pops it
  (CSI 23;0 t) with W13's restore; `TitleFilter` keeps the session's OSC 0/1/2 out while it does. The
  menu: the FIRST detach-key press (any W16 encoding — `DetachKeyScanner` now returns what followed it
  in the read) opens it when stdin AND stdout are terminals; while it shows, `writeSession` drops the
  session's bytes (a notice waits in `pendingNotices`); closing it asks for a REPAINT. A second press
  within 0.5 s or at the menu detaches. n/p/s set `switchTarget` and shut the socket: the main loop
  reattaches THAT session in the same client. `MenuKey.decode` reads keys in plain, kitty CSI-u (a
  release is not a press) and modifyOtherKeys form. The web pane's tab renders the same template
  (`terminalTitle(t)` in `components/terminal.js`).
- **What a person reads carries no internal numbers**: no feature numbers or walkthrough IDs in
  `--help`, setting descriptions, messages or the dashboard's strings — they belong in comments.
  `make docs-drift-check` runs `Scripts/user-text-check.swift` (and `Scripts/manual-check.swift` on
  `docs/manual`). Shell comments inside guest scripts are exempt: they are part of an image's recipe.
- **A host of another build is said**: `noteHostBuild` — once per command, on stderr before the
  answer, never with `-q`, never on stdout; `rawCall` (every host request but ping/host-stop) and
  `doz attach` call it. `hostBuildNote` uses the web UI's `WebVersion.compare` (a newer host: upgrade
  this doz). `image ls` STATUS is always a word (W32; a template is `up to date`).
- **Workspace folders**: a FOLDER — /workspace itself (relative path "") or any
  child, the same mapping and Mac-side `realpath` — opens with `open -a Finder` (never as an app); a
  package folder (`URLResourceValues.isPackage`, or a never-list extension) is refused even then.
  `doz-open --reveal` (`doz-reveal;PATH`, `BridgeEvent.revealFile`) is `open -R` — nothing opens, so a
  file's type is not checked and a package may be revealed; never outside, never with `--app`. Seam
  lines `open-folder PATH` / `reveal PATH`. The facts block has ONE `{{mac.open}}` line for every open
  bridge (only what is on; empty → the bullet is dropped by `AgentPrompt.render`); the skill keeps
  `{{browser.description}}` and `{{files.description}}`.
- **Workspace files ride the SAME shim and marker** — never a second guest→host channel. The shim
  (`openShim`, stamp `doz:open-url-shim:vN` — bump it on ANY change, so a wake's `guestFixes` re-installs
  it) takes a file as well as a URL and sends `ESC]6340;doz-file;APP;/workspace/… BEL` (made absolute and
  resolved in the GUEST, only so the agent hears refusals at once — the notice goes to the person). The
  HOST decides in `WorkspaceFiles` and trusts nothing the guest said: lexical normalisation under
  /workspace → the Mac folder from the sandbox's SPEC (`shares`, never a guest path) → `realpath` ON THE
  MAC, inside the shared folder's own realpath → a regular file (a folder, so any bundle, never) → the
  document allow-list / never-list (`GuestCommand.openFileDocumentTypes` / `openFileNeverTypes`, shared
  with the shim) → no executable bit → the content (`O_NOFOLLOW` descriptor, same dev/ino as the lstat,
  no `com.apple.ResourceFork`, no Mach-O/ELF/`#!` in the first bytes). A named app must be in
  `bridges.open_apps` and the LISTED spelling reaches `open -a`. `sandbox.open_files` per sandbox; its own
  rate limit (`BridgeState.fileOpens`). Notices are one terminal row (the CLI cuts at the width): keep
  every refusal short, the key fact first. The notice names the default app through LaunchServices,
  read-only (`MacDefaultApp` — the audit allows CoreServices there and in `UICommand.swift` only).
  `make test-cli-openfiles`.
- **Tests never touch the Mac**: `DOZ_TEST_PASTEBOARD=<file>` replaces pbcopy; `DOZ_TEST_OPEN_URL=<file>`
  replaces `/usr/bin/open` and plays the browser's last step (GET the callback on the Mac's port); a
  workspace file is recorded there as `open-file APP|default MACPATH`.
  A fake OAuth server must READ before it answers (busybox `nc -e`), as a real one does.

### What the agent is doing (OSC 7501)

- **deckhold is the consumer of the program-status protocol** (OSC 7501 —
  https://www.superlogical.com/rex/docs/build/program-status). Claude Code (≥ 2.1.295) and pi (≥ 1.1.0) report
  ONLY after the terminal answers `ESC]7501;?ST`; deckhold reads every byte its program writes (attached or not), so
  `ps_scan` in `pump_master` answers the query at once — always (a viewer's own terminal may answer too: a program
  takes the first), at most 16 answers a second (an answer echoed back as output must not loop) — and keeps the
  records by the spec (a report REPLACES its record; clear by id and below, or all; RIS clears; ≤ 256, LRU; a
  malformed pair skipped, a report over a limit / bad base64 / control characters discarded whole). The bytes are
  NOT changed: the emulator and every viewer get them as written (`SessionBridgeScanner` does not own 7501 —
  `SessionStatusTests` cuts it at every offset). OSC 133 `A` deliberately does NOT end working/blocked: Claude
  Code writes it at its own turn start and reports only on change. Codex does not report (nothing shown).
- **What deckhold exposes is the ROOT record**: in `deckhold ls`'s INFO (`status=<canonical report body>\tstatus_age=S`,
  BEFORE the command — an older parser takes an unknown field for the command, which comes last) and as STATUS
  ('T') frames to a client that sent WATCH ('W'). Frame types are only ever appended (the header comment). An
  older holder (a session started before an update keeps its binary) drops a WATCH client: the host's watcher then
  ends with no STATUS frame (`SessionConnection.sawStatus`) and that session is not asked again until the next run.
- **The host holds it in memory** (`HostCore+Status`): one watcher per session of a RUNNING sandbox
  (`Sandbox.watchStatus` — `deckhold pipe` + WATCH: not a viewer, no size), opened on open-session, on an attach,
  and for every live session when the sandbox comes to run (ONE `deckhold ls` per transition — never on a poll);
  the library detaches it with the viewers on sleep/stop. `ls` reads memory only (`sessionStatuses`,
  `agentStatus` = `SessionStatus.mostUrgent`: blocked > error > working > done > idle, `agentWorking` — the
  signal an idle sleep must respect). working/blocked end with the program; done/error survive it until the
  session is opened again or the sandbox stops. Each change is ONE `session-status` HostEvent (deduplicated:
  `sameReport`), sent only to an `events` stream that set `HostRequest.sessionStatus` (an older client cannot
  decode the kind). **The program's `msg`/`title` are untrusted guest text: never in host.log** (`logLine` is
  metadata only), capped in `WebAgentStatus`, textContent only on the page.
- **The page** (`components/agent-status.js`): chips on tabs, tiles and the Sessions tab's rows (`data-agent-for`,
  painted in place after every overview), the sidebar's dot, and a page notice per transition to done / blocked /
  error (dropped when no longer true). The UI's monitor pokes its poll on a `session-status` event; it is not an
  Activity line. `probes/612-*/browser-status.mjs` checks it in a real Chrome (scratch store and profile).

### GitHub as the user

- **Proxy insertion, like the Anthropic credential — and nothing more.** `CredentialBinding.github`
  (hosts `GitHubAccess.credentialHosts`: github.com, api.github.com, uploads.github.com, codeload.github.com)
  is **swap-only** (`swapOnly`: never injected into a request without its placeholder) and puts ONE placeholder
  in `GH_TOKEN` and `GITHUB_TOKEN` (`alsoEnvironmentVariables`). The vault finds a placeholder inside an
  `Authorization: Basic` login too (`basicDecoded`/`searchable`/`placeholders(inHead:)` — the leak guard and
  the plain-HTTP guard see it) and swaps it there by decode → swap → re-encode. "strict" pins the
  ANTHROPIC credential only: a guest's own GitHub token is flagged, never refused by it.
- **The token is READ ON USE** (`CredentialVault.setProvider`): `gh auth token` (or the sandbox's own key —
  memory `HostCore.githubKeys`, or a keychain item re-read), cached `GitHubLogin.cacheSeconds` in the vault's
  memory only; the provider's `version` (the `github.credentials` value) drops the cache the moment the source
  changes. Never in `doz.json` (only `credentialSources["github"] = stdin|keychain:…`), a log, an event or the
  guest. Turning the permission off = `vault.remove("github")`: every placeholder issued is refused at once.
- **Read-only is the PROXY's** (`GitHubAccess.classify`, in `EgressProxy.intercept` for requests whose decision
  swapped the github binding): receive-pack anywhere (decoded, case-folded) refused; api.github.com only
  GET/HEAD, plus `POST /graphql` whose BODY is held (≤ 256 KiB, Content-Length only — chunked refused) and
  parsed by `graphQLIsQuery` (top-level definitions only; anything unsure → refused); LFS batch only
  `"operation": "download"`. The 403 is `text/plain` so git shows it as `remote: …`. Keep the parser
  conservative: a new GraphQL construct is refused until a test says it is a read.
- **The state is the policy's permissions** — `github:as-you`, `github:push` (`AgentPermissions.gitHubMode`;
  push needs as-you; never in a preset, Open included; a preset choice keeps them; never inferred from a
  pre-597 policy, never suggested for a denied host). `--github`/`github:` are sugar for them. `HostCore.applyGitHub`
  applies everything (vault provider, `EgressProxy.github` gate, identity, SSH agent) — at load/create, on a
  `net-policy` change, `sandbox.ssh_agent`, `key set --github`.
- **The guest half is in `guestFixes`** (boot AND wake): `git-credential-doz` (stamp `doz:git-credential:vN` — bump
  on any change; it answers ONLY a `doz_cred_` placeholder, ONLY for https://github.com), `/etc/dozer/gitconfig`
  (helper + the Mac's identity, or a comment when off) included once from `/etc/gitconfig`, and the SSH agent.
  `Sandbox.applyGitHubToGuest` applies them to a running guest.
- **SSH agent (G4)**: `SSHAgentRelay` (host vsock 5801 → the Mac's agent socket) only while `sandbox.ssh_agent`
  is on; it FILTERS the guest's requests (`allowed`: list 11, sign 13, the session-bind extension 27 — anything
  else, e.g. add/remove/lock, is answered SSH_AGENT_FAILURE and never reaches the Mac's agent); `doznet agent` (guest, `/run/doz/ssh-agent.sock`) — started after doznet is copied at a fresh boot,
  by guestFixes at a wake; `EgressProxy.sshToGitHub` allows github.com:22 (and its DNS) and nothing else; port
  22 is never decrypted. Off = no listener (the agent-sudo suite's "no vsock listener but 5800" holds).
- **Notices** that come from the proxy (not a session's output) go through `BridgeState.notifyViewers`: the
  attach relay registers every attached terminal per sandbox. First use per apply (`firstUse`/`resetFirstUse`).
- **Tests never use the user's GitHub, gh, ssh-agent or git identity**: `DOZ_TEST_GH` (a fake gh),
  `DOZ_TEST_GITHUB_UPSTREAM` + `DOZ_TEST_GITHUB_CA` (the upstream leg goes to a fake GitHub, trusting ONLY that
  CA), `DOZ_TEST_SSH_AUTH_SOCK` (a throwaway agent), `GIT_CONFIG_GLOBAL` (a scratch identity).
  `make test-cli-github` runs a python3 `git http-backend` over TLS as the fake GitHub.

### Workspace rules — `.dozignore` / `.dozreadonly`

- **Every share is served through `dozview`** (BUG cwd-after-wake, the design notes): a
  hibernation's re-mount detaches the RAW share and the new virtio-fs server knows none of the old node ids, so a
  program whose cwd was inside got ENOENT from getcwd (Codex: "invalid cwd"); the view is never re-mounted.
  A share whose MAC folder holds `.dozignore` or `.dozreadonly` (`WorkspaceRules.present`) gets a view WITH rules;
  any other a PASSTHROUGH one (`WorkspaceViewConfig.passthrough`; dozview ≥ 1.1.0 applies nothing — not even the
  implicit read-only names — until a rule file exists; one that cannot start leaves the share bound, never an
  empty folder). `Sandbox.passthroughViews = false` is 599g's old rule (no rule file → no view, no daemon).
  The decision is re-made at every fresh boot, wake and session start (`Sandbox.wantedViews`,
  `refreshWorkspaceViews` from the host's open-session) — but a passthrough view is started only at a fresh
  boot or a hibernation's wake, never live under a running program (it would cut that program's cwd). Turning
  a view OFF waits for the next cold start. The facts' rules line ignores passthrough views. `make test-vm-cwd`.
  608: the knob is the setting **`workspace.view`** (on|off, per sandbox: `--workspace-view`, `workspace_view` in
  doz_project.yaml; `HostCore.workspaceViewOn` → `Sandbox.passthroughViews`, read at load and per request,
  applies `.nextStart`). `SandboxInfo.workspaceView` (`HostCore.workspaceViewState`, pure): live | rules | direct |
  next-start | fallback — a passthrough view that failed to start is `Sandbox.viewFallbacks` (the boot says so,
  `doctor` warns "workspace view"). The manual's cost table (21-the-workspace-view.md) is from `make test-vm-cwd`.
- **Semantics are Docker's, and ONE contract in two languages**: `DockerIgnore` (Swift) and
  `Guest/dozview/match` (C) both pass `Tests/Fixtures/dozignore-vectors.json` (real moby/BuildKit output) and
  agree on `WorkspaceRulesTests.testSwiftAndCAgreeOnADifferentialFuzz`. BuildKit's walker (D1: `d`, `!d/f`, `d`
  SENDS d/f). Go's escape bitset lets `|` `{` `}` reach RE2 raw — both follow Go. Change one side, change and
  test both. Folding (D2): on a case-insensitive volume a path is selected when the plain OR the folded
  (NFD + simple case fold, `DozFold`/`dm_fold`, one generated table) evaluation selects it — only ever more.
- **Modes**: `workspace.ignore_mode` (per sandbox) `lock` (listed, mode 000, EVERY uid refused by the view —
  root too) or `hide` (ENOENT, unlisted; creating the name EACCES). `.dozreadonly`: write bits hidden, EROFS
  for root (a non-root user gets the kernel's EACCES first — accepted). Implicit read-only, overridable by a
  `!` line: doz_project.yaml/.yml, .git/hooks. ALWAYS visible + read-only: the two rule files.
- **The guest layout** (`WorkspaceView`): the share bound at `/run/doz/raw/<tag>` with ONLY `/run/doz/raw`
  0700 (`/run/doz` stays 0755 — the SSH agent's socket), the view mounted over the guest path's EMPTY root-disk
  folder (never stacked on the share — a dead view shows nothing, not the share). The daemon is COPIED in
  (`/usr/local/lib/doz/bin/dozview`), never run from the share. `/run` is on the ROOT disk: a fresh boot
  deletes `/run/doz/view` and only `rmdir`s raw mount points — never a recursive delete there.
- **The wake** (spike): the FUSE connection and the daemon survive pause, sleep, hibernate and a restore into
  a new process (guest memory) — the view is NEVER re-mounted. The daemon's link to the share dies in a
  hibernation and `fstat` on it still succeeds: `remountShares` re-binds the RAW path (never the guest path)
  and SIGUSR1s the supervisor IN THE SAME root script; the guest's own conf file decides the layout (no
  record needed after a crash restore). Liveness is `/proc/PID` not a zombie and dozview's — never `kill -0`:
  the container's PID 1 never reaps (a killed supervisor stays a zombie; found by the suite).
- **The daemon's guards** (keep them): never re-read rules through an unhealthy base (open "." + the virtio-fs
  magic) — keep the last rules; never adopt a re-opened base that is not the share; self-repair on a failing
  request is a backup; a handle that died in a hibernation is re-opened by path (EBADF included). A dir rename
  that would change what an anchored rule matches, and a hard link to a locked/read-only file, are refused.
  Node ids and file handles carry the worker generation (a restarted worker never mistakes a dead one's).
- **Not a security boundary** — said in the setting, `--help`, the manual and the facts. Root in the guest can
  kill the daemon or read through its fds; the view keeps an agent from stumbling into files.
- **Explaining them**: ONE text, `WorkspaceRulesGuide` (DozerHost) — `doz onboard`'s step 3 and
  `doz init`'s `rules` step (`RulesStep`, DozerCLI), the dashboard's onboarding (`wizStepRules`, steps named in
  `WIZ`) and New Sandbox (`nwRules`), both drawn by `rulesStep()` (`components/rules-step.js`) from the served `rulesGuide`
  (`GET onboarding`, `POST project/open` — which also lists the folder's `rules`, inert). The onboarding writes
  `workspace.ignore_mode` ONLY when chosen (`Onboarding.writeIgnoreMode`, the Access rule; `--ignore-mode`,
  `onboarding/config {ignoreMode}`). The sandbox page says "Workspace rules: none — the folder is shared as is"
  for a workspace without a rule file (isolated: nothing).
- **Tests**: `WorkspaceRulesTests`, `DozMatchCTests` (vectors, fold vectors, threads), `WorkspaceRulesHostTests`
  (setting, project key, facts, warnings, in-process op, projection); `make test-vm-ignore` (the spike's
  matrix through the library, live reload, folding, kills, rule files appearing, cost) — green twice.

### The tools layer — tools follow settings, on every base, no rebuild

- **One model** (`ToolsLayer.swift`): `ToolInputs` (github, ssh, tmux — from the settings) → `ToolPlan`
  (`ToolItem`: id, title, reason, kind binary|package|file, source; plus `removals`) → a guest check script →
  `applyScript` (one `doz-tool ID STATE DETAIL` line per tool) → `ToolsReport`. Pins: gh 2.102.0 + its tarball
  sha256; GitHub's three published SSH host keys (`ToolsLayerTests` checks them against the published
  fingerprints).
- **gh** comes from `ToolsCache` (`<store>/tools/gh/<ver>/gh`, one download per store, sha256 or refused;
  seam `DOZ_TEST_TOOLS_URL=http://127.0.0.1:PORT`) and is COPIED in (`copyIn`, no guest network) to
  `/usr/local/lib/doz/bin/gh`, linked `/usr/local/bin/gh` only when free; REMOVED when off (only Dozer's copy
  and link). Packages (openssh-client, tmux, git, curl, ca-certificates) — apt/apk through the proxy, only
  when missing. github.com's keys — a managed block in `/etc/ssh/ssh_known_hosts`.
- **When**: `Sandbox.start()` after the boot, and `applyGuestFixes` (wakes); the FIRST apply in a sandbox (no
  `/var/lib/doz/tools`) is loud (`tools: …` steps), later ones quiet (a note; the host tells viewers on a
  change/failure). Never fatal. `toolInputs == nil` (the default) = no layer: preparation VMs and helpers
  never run it — the host sets inputs for every managed sandbox (`applyToolInputs`, beside `applyGitHub`;
  a live change on a running sandbox applies at once). Recipes untouched (`ToolsLayerTests` pins bake keys).
- **Surfaces**: `doz tools NAME [--apply]` (host ops `tools`, `tools-apply`), `GET /api/v1/sandboxes/{n}/tools`,
  the web action `tools-apply`, the New Sandbox wizard's last step "Setting up tools" (`nwToolsNode`: start →
  ✓/✗ → Retry · Continue anyway → Open the sandbox), doctor's "tools layer" line, Resources' `cache:tools`.
  The facts' GitHub line says "(installed by Dozer)" / why gh is not there, and that the ssh client + host
  keys are in place.
- **Tests**: `ToolsLayerTests`, `ToolsHostTests`, `make test-cli-tools` (needs `make tools-fixture` once: the
  real tarball in the vmtest store; a local server serves it — tests never reach github.com), the workspace
  probe `probes/599h-*/run-wizard-probe.sh`.

### Access — every credential a purposeful choice, each confirmed

- **One step, three places**: `doz onboard`'s "2. Access" (`AccessStep` in `AccessCommands.swift`, shared with
  `doz access` / `doz access set`), the wizard's step 2 and **Settings › Access** — both drawn by ONE
  self-contained component, `renderAccessStep(container, {mode: 'onboarding'|'sandbox'|'settings', state,
  claude, choices, onChange})` in `components/access-step.js` (599f's New Sandbox wizard reuses it). It writes NOTHING but the default
  GitHub key; the caller writes the choices (onboarding: `POST onboarding/config {access}`; sandbox: its create).
- **The host's `access` op** (`Access.swift`): the report (choice, source, state confirmed|failed|off|unchecked,
  detail, consequence) and, with `check`, a LIVE check of `items`, of `accessChoices` when given (the onboarding
  confirms before it writes). Read-only (no `check`) is answered in-process; `check` needs the host. The record
  is `<store>/access.json` — states and reasons, NEVER a secret; an answer counts only for the choice (and
  source) it was given for. `access-github-key` sets/removes the default key (keychain `doz-github`), which
  `applyGitHub`'s provider reads after a sandbox's own key when `github.credentials = key`.
- **The checks**: GitHub — the token as a sandbox gets it (`Access.githubToken`), then `GitHubAccess.confirm`:
  `GET /user` over `TLSUpstream` (the proxy's leg; the test upstream seam), login + `X-OAuth-Scopes`, or for a
  scope-less token `GET /user/repos?per_page=100`'s count. SSH — `SSHAgentRelay.listKeys` (REQUEST_IDENTITIES,
  nothing signed). Claude — the store default: `ClaudeLoginStatus` for `mac`, `services.verifier` for a key.
- **Never blocks, never silent**: a failure KEEPS the choice (Skip; "not confirmed") — turning it off is the
  person's. `--yes`/no TTY skips with a note, exit 0. The onboarding writes `defaults.github` /
  `github.credentials` / `sandbox.ssh_agent` only when CHOSEN (a flag or a TTY answer) — `--yes` alone changes
  nothing. `defaults.github` (off|read|push, default off) joins the permissions only where `defaults.permissions`
  applies (no `--network`, not the form's exact list); `WebBases.github` seeds New Sandbox's switches.
- **Web**: `GET /api/v1/access` (never starts a host), `POST /api/v1/access/check` (CSRF, strict
  `WebAccessCheck`), `POST /api/v1/access/github-key` (`WebAccessGitHubKey`, redacted, `allow_secret_entry`).
- **Tests**: `AccessTests` (a scratch env passed to `access(_:environment:)` — never the process's XDG/agent),
  `AccessWebTests`, `make test-cli-access` (no VM: a fake GitHub API with its own CA, a fake gh, a throwaway
  agent; SSH_AUTH_SOCK removed), the workspace probe `probes/599e-*/run-access-probe.sh`.

### Codex as a first-class agent

- **The agent `codex`** (`AgentKind.codex`, added LAST to `allCases`): `codex` = Node · Codex, `<base>-codex` on every
  other base and a Dockerfile's. ONE recipe on every base (`ImageComposer`, `AgentImages.codexInstall`): the npm
  registry's `@openai/codex/-/codex-<v>-linux-arm64.tgz` (a STATIC musl binary — Debian and Alpine alike), its sha512
  checked against `AgentRelease.integrity`, unpacked to `/opt/codex`, `/usr/local/bin/codex` linked; on a musl base the
  bundled glibc `codex-path/rg` is removed (the baseline's ripgrep is used). `CODEX_HOME=~/.codex` (state disk). The
  release for codex is the MAIN package's version and the PLATFORM package's integrity (`AgentVersions.refreshPackage`
  looks up `latest`, then `<v>-linux-arm64`); the pin is 0.160.1 (`AgentImages.codexPinned`). Codex has no pre-596 Node
  image: `codex` is composed like any pair. **Claude Code's and pi's recipes are untouched** — `RecipePinTests` pins
  every catalogue base × claude-code/pi/none spec and bake key as they were before 599i; keep it green.
- **The launcher** (`AgentImages.codexLauncherScript`, `~/.local/bin/codex`): agent runs (no subcommand, a prompt,
  `exec`/`e`/`resume`/`fork`) get `--dangerously-bypass-approvals-and-sandbox` (+ `notice.hide_full_access_warning`)
  unless `DOZ_CODEX_PERMISSIONS=ask` (the setting `codex.permissions`, `HostCore.withClaudePermissions`) or root; every
  run gets `-c check_for_update_on_startup=false -c cli_auth_credentials_store=file`; the facts file as
  `-c developer_instructions=<TOML string>` (python3 `codex-setup.py prompt`; not when the caller gives
  `developer_instructions`); `codex-setup.py trust` appends `[projects."<cwd>"] trust_level = "trusted"` only when the
  folder has no entry. `review` gets no bypass flag (it has none); `login`, `mcp`, `--version` … run as they are. The
  launcher names no credential (`testTheLauncherSkipsApprovalsAndDeliversTheFacts`). Re-check the flags when the pin moves.
- **Accounts** (`AccountKind.openaiKey` = `openai-key`, `.chatgpt`): Codex accepts ONLY these; Claude Code and pi never
  get them, Codex never an Anthropic one (`AgentCredentials` — `provider`). The store has TWO defaults:
  `AccountsFile.defaultAccount` (Anthropic) and `openaiDefault` (Codex; nil = none — never the Anthropic one);
  `doz account default NAME` with an OpenAI account sets the latter; `resolvedAccount` and `createProblem(…openaiDefault:)`
  follow the sandbox's provider. `AccountRow.isDefault` is true for both defaults (callers pick by kind's provider).
- **Dozer's OWN ChatGPT sign-in** (`ChatGPTSignIn`, run in the CLI process by `doz account add NAME --chatgpt`, `doz
  onboard --openai-account chatgpt`, the create preflight): Codex's own browser flow (0.160.1 `login/src/server.rs`) —
  PKCE S256, Codex's public client id, its scopes and parameters, a loopback listener on **127.0.0.1:1455, else 1457**,
  `redirect_uri=http://127.0.0.1:PORT/auth/callback`, the browser opened by `BrowserBridge.open` — then the code is
  exchanged (FORM post) over `HTTPSOnce` (the proxy's `TLSUpstream` leg). NO token exchange for an API key. The tokens go
  to the host in `account-add` (`ChatGPTTokens.json`); the keychain keeps ONLY `ChatGPTRecord` (the refresh token, the
  account id, the id_token claims Codex reads — `OpenAIAccess.keptClaims`) in `doz-chatgpt:NAME`, through `KeychainChunks`
  (parts `NAME#1…#8` + a `doz-chunks:n:<sha256>` header written last, only when it does not fit one item); the ACCESS
  token lives in the host's memory only (a new host renews on first use). `accounts.json` gets plan/email/account
  id/fingerprint, never a token. **Dozer never reads or writes the Mac's `~/.codex`**
  (`testDozerNeverTouchesTheMacsCodexHome` scans DozerHost/CLI/Web).
- **The refresh is the host's** (`ChatGPTSession`, ONE per account in `HostCore.chatgptSessions`): the vault's provider
  (`setProvider(.chatgpt, ttl: 60, version: generation)`) reads the access token; it renews when its JWT `exp` is
  within 5 minutes or after an upstream 401 (`vault.onStale` → `markStale`, which bumps the generation so the vault re-reads
  at once); one refresh at a time; the ROTATED refresh token is written to the keychain BEFORE the new access token is
  used — a write that fails REMOVES the item (never a spent token left to try later): the sign-in then lives in that host's
  memory only, said in the log. A permanent refusal (401, `refresh_token_reused|expired|invalidated`, `invalid_grant`) = signed out → every read
  and renewal answer is a notice naming `doz account add NAME --chatgpt --force`. A network failure keeps an unexpired
  token working and retries after 30 s. **No silent fallback** — never another account's token or a key.
- **The proxy** (`OpenAIAccess`, `EgressProxy`): bindings `.openai` (Bearer, `api.openai.com`, `OPENAI_API_KEY`) and
  `.chatgpt` (Bearer, `chatgpt.com` + `auth.openai.com`, **swap-only**, no variable — its placeholder lives in auth.json).
  **Codex's own refresh** (`POST auth.openai.com/oauth/token`) is ANSWERED by the proxy (`EgressProxy.chatgptRenewal`,
  body held ≤ 64 KiB, Content-Length only): a placeholder of this sandbox's chatgpt binding → 200 with the SAME placeholder
  for both tokens and the guest id_token (the Mac renews first when due); another doz placeholder → 401; no placeholder →
  judged by the policy (auth.openai.com is NOT in any permission) and forwarded only if allowed. `connectionVerdict` makes
  auth.openai.com `.inspect` only while a renewal gate is set. Refusals on OpenAI hosts are OpenAI-shaped
  (`OpenAIAccess.refusal`). WebSockets (Codex dials `wss://chatgpt.com/…/responses` first) are swapped in the upgrade's
  head, then raw. Test seam: `DOZ_TEST_OPENAI_UPSTREAM` + `DOZ_TEST_OPENAI_CA` (`OpenAISeam`) — the proxy's OpenAI leg,
  the sign-in's exchange, the host's refresh and the key check go to a fake, trusting ONLY its CA.
- **The guest's `~/.codex/auth.json`** (`HostCore.codexAuthScript`, a root utility exec at every open-session of a Codex
  sandbox and before `doz exec … codex`): ChatGPT — `auth_mode: chatgpt`, `OPENAI_API_KEY: null`, ONE fresh placeholder
  (`vault.mintForFile`) for access and refresh token, the id_token with its real claims and the signature replaced by
  `doz-unsigned` (`OpenAIAccess.guestIDToken` — the real id_token is a credential: Codex trades it for an API key),
  `account_id`, `last_refresh = now`; API key — `auth_mode: apikey` + placeholder. 0600, the agent's. No OpenAI account →
  only a file holding a doz placeholder is removed; an account whose credential is unusable leaves the file (its
  placeholders get the proxy's reason).
- **`mac` for Codex (rc.3, `CodexMacLogin.swift`) — THIS Mac's own Codex login, 588's `mac` rules as the template.**
  `AccountKind.codexMac` (`codex-mac`, never in accounts.json; `AccountRecord.codexMac`): a Codex sandbox's account
  `mac` resolves to it (`resolvedAccount` by provider — Claude's `mac` is untouched). Dozer READS ONLY the access token
  and the kept claims/account id from `$CODEX_HOME/auth.json` (else `~/.codex`; `CodexMacLogin.read` takes those fields
  out of the parse — never the refresh token), NEVER writes CODEX_HOME (`testDozerNeverTouchesTheMacsCodexHome` allows
  only this file, read-only). Re-read on use: the vault provider's version is the file's inode/size/mtime
  (`CodexMacSession.version`). Expired / signed out / keyring store (`cli_auth_credentials_store` keyring|auto) /
  an API-key login → `problem()`: the proxy's 401, never another account. It is the DEFAULT Codex account while the
  Mac's Codex is signed in (`effectiveOpenAIDefault`: `openaiDefault` else mac-if-signed-in; compute it ONLY for an
  OpenAI agent — it reads the Mac's file); `doz account default NAME --codex` sets it by name. Keep-alive
  (`codex.keep_alive`, off): `codex doctor` (no model call — its websocket check asks for the auth, which refreshes)
  once per expiry when the token is within `keepaliveWindow` (270 s; Codex refreshes within 5 min) and a sandbox used
  it within 15 min. Freshness otherwise: the Codex app's server lists models every 4½ min (0.160.1
  `models_refresh_worker.rs`), which refreshes. **Tests never read the real ~/.codex**: `CredentialServices.codexHome`
  (memory seam: `DOZ_TEST_CODEX_HOME` or none; `CodexMacLogin.resolveHome` STOPS the process inside XCTest without it),
  `DOZ_TEST_CODEX_BIN` (a fake codex); CLIHarness sets both to scratch paths. `CodexMacLoginTests`, the suite's part 6b.
- **Permission `model:openai`** "Talk to OpenAI" (chatgpt.com, api.openai.com, ab.chatgpt.com): an AGENT permission
  (`AgentPermissions.agentPermissions(.codex)`) — added at create (`DozerImages.spec`), kept by every preset change and
  edit (`editedPolicy(…agent:)`, `PermissionPolicy.edited(…agent:)` refuses revoking it for Codex), never in a preset
  (Open included), never inferred, never suggested, and absent from another agent's checklist and facts.
- **The environment prompt**: `AgentPrompt.agent(of:)` = `codex`; the skill in `~/.agents/skills/dozer` (Codex's user
  skills — never AGENTS.md); new variable `agent.state` (renders exactly as before for Claude Code/pi); the credentials
  sentence says OpenAI for Codex.
- **Tests**: `OpenAIAccessTests`, `EgressProxyTests` (renewal answered / refused / policy), `CodexHostTests`,
  `RecipePinTests`; `make test-cli-codex` — a python3 fake OpenAI over TLS (`probes/599i-*/fake_openai.py` is the same
  server), the real Codex in VMs (codex + alpine-codex): the sign-in through the browser seam, the swap, a renewal on the
  Mac, the guest's renewal answered, no token anywhere in the guest, no silent fallback, the API key. `CODEX_KEEP=1`
  keeps its store (`/tmp/dzo-codex-keep`) and the prepared images.

### Browser terminals

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
- **The viewer a person types in owns the session's size**: a session has ONE size and the last viewer
  to send one set it; `doz attach` from a terminal of another size left a web pane showing a TUI drawn for the
  other width (stray text, stale glyphs where it draws blanks) until the pane's own size changed. The relay
  (`HostServer`'s attach, `HostCore.sizeOwners`, `SessionSizeOwners`) re-applies a viewer's size before its
  keys when another viewer sized the session since (a watcher's 0×0 never owns it). 609's residue — deckhold's snapshot after a narrowing reflow
  dropped an EMPTY soft-wrapped row, so a TUI's prompt sat a row off on that viewer — is fixed in deckhold (below).
- **deckhold's SNAPSHOT is placed run by run**: libghostty-vt's formatter, unwrapping, counts a line's newline only at
  its last row, but counts an EMPTY row (no text) as blank before that — a wrap into or out of an empty row lost a
  newline and every row below landed one high on the viewer. `send_snapshot` now formats the active area in runs (a row
  with text and the rows with text it soft-wraps into; a run also ends at an orphaned spacer head, and stops its
  selection before it), each after a CUP to its own row; the modes go with the first run, every other extra with the
  last. `make deckhold-snapshot-check` (`Guest/deckhold/test/`: deckhold.c itself against a Mac build of the SAME
  ghostty commit) replays every snapshot on a fresh emulator and compares cell by cell (fixed cases + a seeded fuzz of
  screens × size changes; 0.30.1's source failed ~45 %). Run it on any change to `send_snapshot` or the ghostty pin.
- **A wake brings this build's deckhold** (`Sandbox.refreshDeckhold` in `.applyGuestFixes`): deckhold is copied in at
  a fresh boot; a wake compares the guest's `sha256sum` with this build's and, when they differ, stages it beside
  (`GuestCommand.deckholdStagingPath`) and RENAMES it over (only when the staged copy is exactly this build's). A
  session's running holder keeps its own binary (the old inode) until it restarts (`doz sessions restart`) or ends;
  sessions opened after the wake run the new one. Best effort — a wake never fails for it. `test-vm-upgrade` checks it.
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
  the page's own rules are unchanged for `index.html`/`app.css`/`app.js` and its modules. `application/wasm` is served
  only for a `vendor` manifest entry. To update: new tarball from the registry → same files → new
  `VENDOR.json` → `make web-assets` → the browser probe. The page has TWO documents (`index.html` → `/`,
  `terminal.html` → `/terminal-frame`), each with its one script and style (607: the page's script is a module graph — app.js and app/**);
  the page-code rules apply to all of them.
- **An open terminal keeps the host alive** (T3: an explicit attach, like `doz attach` — even held on
  a hibernated sandbox); the dashboard alone still lets it idle out (`t3-host-alive.mjs`).
- **The engine runs ONLY in a sandboxed, opaque-origin iframe**: `/terminal-frame`
  (`terminal.html` + `frame.js` + `frame.css`), loaded with `sandbox="allow-scripts"` only — no cookie,
  storage, same-origin access, popups or forms. Its CSP (`WebSecurity.frameHeaders`) allows
  `'wasm-unsafe-eval'` and `connect-src 'none'`: the PAGE fetches the vendored `.wasm` and posts each
  frame its own copy (one instance per terminal), and keeps the WebSocket. The page's CSP gained only
  `frame-src 'self'` (no WebAssembly in the page). The frame's script/style and the engine's script are
  served to the opaque origin without the Origin/Fetch-Metadata checks and with CORP `cross-origin`
  (`WebAssets.isFrameAsset`); every other file keeps the page's rules. A response's own header
  REPLACES a default of that name (the frame's CSP/XFO) — never a second copy.
- **The frame protocol is closed and checked on both sides** (frame.js `valid`, `components/terminal.js`
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
- **The boot view**: an off/failed/booting sandbox's terminal waits (cover with Start),
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
make test-cli-timezone # 594 W10: the Mac's (stubbed) zone at boot and every wake, or sandbox.timezone
make test-cli-bases  # 596: base × agent — cli, Dockerfiles via a fake container, the real container build (SKIPs unless Apple's services run; BASES_START_BUILDER=1), the VM matrix (BASES_PARTS=…)
make test-cli-permissions # 597: agent permissions — net show/allow/deny/permissions, create --allow, Claude Code's hosts reached under Standard, suggestions, live changes, facts, stored by name (prepares claude-code; network)
make test-cli-points # 594 W25–W27: point names/lookup, check before asking, exec/run start an off sandbox
make test-cli-agentsudo # 594 W23: the agent's sudo in a fresh claude-code sandbox (prepares it; network), --no-agent-sudo, the setting at the next boot, root reaches no more
make test-cli-codex # 599i: Codex through seams (a fake OpenAI over TLS, the browser seam): Dozer's own ChatGPT sign-in, the swap, the Mac's renewal, no token in the guest, an API key, Alpine (prepares codex + alpine-codex)
make test-cli-github # 599d: GitHub as the user through seams (a fake GitHub, a fake gh, a throwaway ssh-agent): swap, read-only, push, no leak, identity, key source, off, SSH
make test-cli-openfiles # 599b: workspace files opened on the Mac through the opener seam — every refusal, isolated, off, --app, URLs as before
make test-vm-cwd     # BUG cwd-after-wake: a program's cwd in /workspace across sleep, hibernate and a new-process restore (the raw share as the control); the passthrough view's cost
make test-vm-ignore  # 599g: workspace rules (.dozignore lock/hide, .dozreadonly) across boot/pause/sleep/hibernate/new-process restore, reload, folding, kills (scratch store)
make dozview / dozview-verify # 599g: rebuild the guest view daemon (pinned Zig) / check the committed bytes
make deckhold / deckhold-verify / deckhold-snapshot-check # the guest PTY holder: rebuild (pinned Zig + ghostty) / check the committed bytes / 610: its snapshot equals its screen, cell by cell
make deckhold-status-check # 612: deckhold's OSC 7501 consumer — the query answered, the records' rules and limits, invalid input, every cut offset + a fuzz
make test-vm-status  # 612: a FAKE agent's status through deckhold, the host and the CLI — no viewer and a viewer, sleep/hibernate + wake, the exit, shutdown (scratch store)
make test-cli-hoststop # 594 W22: test-cli's host-stop part alone (per-sandbox progress plain/animated, --json, nothing running, a host killed mid-stop)
make pullbench       # 594 D12: the node base pulled with 3 vs 6 concurrent layer downloads, fresh stores (network)
```

### Test safety is the default

Every `make test*` target (and the probes' `guard-doz.sh`) runs with `DOZ_TEST_GUARD=1`,
`DOZ_TEST_NO_MAC_LOGIN=1`, `DOZ_TEST_CREDENTIALS=memory`, a scratch `DOZ_TEST_CODEX_HOME` and a scratch
`XDG_CONFIG_HOME` whose `doz.toml` sets `store.path` and `defaults.projects_dir` to scratch folders — forced,
whatever the environment says. `TestSafety` (DozerHost) STOPS a guarded process (and any XCTest run) that
would use the default store, read the Mac's real `~/.codex`, or touch the login keychain's `Claude Code-credentials*`
items. The only way out is explicit: `DOZ_TEST_REAL_MAC=1`. A new code path that reads something of the
Mac's own must go through a seam the Makefile sets (`CredentialServices.forHost`, `macLoginKeychain`) —
`TestSafetyTests` pins the decisions.

### The VM integration tests need an ENTITLED host — how

`swift test` runs an XCTest bundle inside `xctest`, which does not (and cannot be made to) carry
`com.apple.security.virtualization`, so no VM can start there. The integration suite is therefore
an executable target, `doz-vmtest`, that `make test-vm`:

1. builds (`swift build --product doz-vmtest`),
2. ad-hoc signs with `Scripts/vmtest.entitlements` (`codesign --force --sign - --entitlements …`),
3. runs under a watchdog (`perl -e 'alarm 420; exec @ARGV' …`) so a VM op that never completes
   fails the run instead of wedging it; stdout is line-buffered so a hang shows where it stopped.

It prints one `PASS`/`FAIL` line per check and `vmtest: ALL PASS` last. Modes: `all` (default),
`network` (`make test-vm-network`: the claude-code image proxied; live-prompt check SKIPs
without `ANTHROPIC_API_KEY`), `lineage [part]` (`make test-vm-lineage`: bake, discard, sync,
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
