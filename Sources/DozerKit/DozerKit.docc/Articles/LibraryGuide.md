# Library guide

Drive a sandbox from Swift: create it, attach a terminal, sleep it and wake it.

## Overview

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

`sandbox.events()` is an `AsyncStream<SandboxEvent>`: phase changes, timed steps, download
progress, and readouts (``SandboxStatus``). See <doc:Concepts> for the lifecycle vocabulary these
calls use.

### The sandbox and its spec

- ``SandboxSpec`` is the imageSpec: name, store root, image or `bakePackages`, ``Share``s, network
  mode, CPU/memory, and (587) journal size.
- ``Sandbox`` is the actor that owns one VM and its lifecycle: `start`, `pause`/`resume`, `sleep`,
  `hibernate`/`wake`, `shutDown`, `resetToImage`, `delete`, `restoreAfterCrash`,
  `prepareForExit(settle:)` (keep a sleeping sandbox restorable, stop anything else). Guest-facing
  calls: `exec(argv:)` (no shell unless you pass one), `openSession`/`attach`, `sessions()`
  (`deckhold ls`), `screenText(name:)` (`deckhold dump`), `bootConsole()`.
- ``SandboxStatus`` and ``SandboxEvent`` are what you read back; ``SandboxError`` is everything a
  call can throw; ``Phase`` is the state machine (``LifecyclePlanner`` turns an operation into
  ordered ``LifecycleStep``s — the source of the lifecycle rules being unit tests, not prose).

### Sessions

``SessionConnection`` is one viewer's connection to a guest terminal session; ``SessionOutput`` is
what it delivers (a snapshot first, then live data, then exactly one `ended` or ``DetachReason``).
A session survives hibernation because it lives inside the guest (deckhold), not on the connection
— see <doc:HowItWorks>. One-shot, non-interactive commands use ``ExecResult`` instead.

### Images

No Dockerfile: ``ImageSpec`` (base digest + ``BakeStep``s + ``VerifyCheck``) describes a bake,
``ImageBaker`` runs it once and caches the result, and ``AgentImages`` has the two built-in agent
image specs (`claudeCode`, `pi` — at their built-in pins; `claudeCode(_:)` / `pi(_:)` make one at
any ``AgentRelease``: an exact version and the registry's sha512 integrity, installed and checked
in the bake). An agent spec records its ``AgentPackage`` (package and version), so the version is
part of the bake key: a spec is always one exact version. ``StoreLayout`` resolves every image key to its disk on disk;
``RestorePoint`` and ``CustomImage`` are instant APFS-clone snapshots you can revert to, fork from,
or save as a new image.

### Network and credentials

`SandboxSpec(…, network: .proxied(.agent))` boots a VM with **no network interface**; the only way
out is ``EgressProxy``, judging every connection against a ``NetworkPolicy`` of ``EgressRule``s.
Bind a secret to the hosts it belongs to with a ``CredentialBinding`` and hand it to
`sandbox.setCredential(_:secret:)`; the ``CredentialVault`` holds it in memory only and the guest
never sees the real value — only a `doz_cred_…` placeholder. A credential the guest supplies
itself surfaces as a ``ForeignCredential``.

```swift
var spec = SandboxSpec(name: "agent", storeRoot: root, imageSpec: AgentImages.claudeCode,
                       network: .proxied(.agent))
let sandbox = try Sandbox(spec: spec)
sandbox.setCredential(.anthropic, secret: key)          // memory only
try await sandbox.start()
for await r in sandbox.egress!.log.stream() { … }        // ConnectionRecord: host, verdict, rule, bytes, ms
sandbox.setNetworkPolicy(newPolicy)                      // live
```

### Maintenance and accounting

For a **stopped** sandbox: ``DiskAccounting/measure(store:)`` reports what each disk actually
costs; ``MaintenanceAdvice`` says whether ``ReclaimResult`` or ``RederiveResult`` is worth running,
and ``DiskCheck`` runs a read-only `e2fsck` in a helper VM.

### See also

- <doc:CLIReference> — the same lifecycle and concepts, as `doz` subcommands.
- <doc:HowItWorks> — the mechanism underneath these calls.
