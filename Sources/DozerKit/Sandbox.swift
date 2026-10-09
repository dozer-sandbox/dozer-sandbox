import Containerization
import ContainerizationEXT4
import ContainerizationExtras
import ContainerizationOCI
import CryptoKit
import Darwin
import Foundation
import SystemPackage
import Virtualization

/// One Linux container in its own VM, with the 576.03 sleep design:
///
///     start ─▶ running ⇄ paused (1 ms) ─ sleep ─▶ asleep (+ snapshot, ~0.5 s) ─ wake ─▶ running
///                 │                                   │
///                 └────────── hibernate ──────────────┴─▶ hibernated (RAM freed) ─ wake (~0.35 s) ─▶ running
///     any ─ shutDown ─▶ off (disk kept)    a new process ─ wake / restoreAfterCrash ─▶ running   (pinned machine id)
///
/// Terminal sessions live in the guest under `deckhold`, so they survive every transition;
/// `attach` returns a `SessionConnection` that a front end reattaches after a wake.
///
/// Every lifecycle call is serialised: a second call waits for the first to finish, and
/// decides what to do from the phase it then observes.
public actor Sandbox {
    public nonisolated let spec: SandboxSpec
    public nonisolated let layout: StoreLayout

    public private(set) var phase: Phase = .off
    var busy = false
    private var snapshotBytes = 0

    let broadcaster = EventBroadcaster<SandboxEvent>()
    private var gateHeld = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    private var container: LinuxContainer?
    private var instance: (any VirtualMachineInstance)?
    private var handle: VMHandle?
    private var network: VmnetNetwork?
    private var identity: PersistedSandbox?
    private var connections: [UUID: SessionConnection] = [:]
    /// Set once `LinuxContainer.stop()` has shut the VM down through the package.
    private var cleanlyStopped = false
    /// When `openSession` last started a program (583: `prepareForExit` lets a new one settle).
    private var lastSessionStart: ContinuousClock.Instant?

    /// Resolves the kernel on every boot (see `KernelProvider`).
    public nonisolated let kernelProvider: KernelProvider

    /// 580: the host proxy of a PROXIED sandbox (`spec.network = .proxied(…)`), nil otherwise. Its
    /// policy can change while the sandbox runs; its log and credential vault live as long as this
    /// object. The VM has no network interface: this is its only way out.
    public nonisolated let egress: EgressProxy?

    public init(spec: SandboxSpec, kernelProvider: KernelProvider? = nil) throws {
        try spec.validate()
        self.spec = spec
        self.layout = StoreLayout(spec: spec)
        self.kernelProvider = kernelProvider
            ?? KernelProvider(cacheDirectory: spec.kernelCacheDirectory ?? StoreLayout(spec: spec).kernels)
        if let policy = spec.network.policy {
            let proxy = try EgressProxy(policy: policy, ca: nil)
            proxy.vault.set(.anthropic, secret: nil)
            proxy.vault.set(.claudeOAuth, secret: nil)   // so a real token passed in the environment is vaulted too
            proxy.ownName = spec.name                     // 594 W29: its hostname, answered locally
            egress = proxy
        } else {
            egress = nil
        }
    }

    // MARK: observing

    /// A fresh stream of everything this sandbox does from now on (one per subscriber).
    public nonisolated func events() -> AsyncStream<SandboxEvent> { broadcaster.subscribe() }

    public var status: SandboxStatus {
        SandboxStatus(phase: phase, busy: busy, ramHeldMiB: phase.holdsRAM ? spec.memoryMiB : 0, snapshotBytes: snapshotBytes)
    }

    /// Viewers attached right now through THIS sandbox object.
    public var attachedConnectionCount: Int { connections.count }

    /// The guest serial console (kernel + vminitd) — a file the VM appends to.
    public nonisolated var bootLogURL: URL { layout.bootLog }

    /// The last `lines` lines of the boot console, re-emitted whenever it grows.
    public nonisolated func bootConsole(lines: Int = 600, every seconds: Double = 0.25) -> AsyncStream<[String]> {
        let url = bootLogURL
        return AsyncStream { cont in
            let task = Task {
                var lastSize = -1
                while !Task.isCancelled {
                    let d = (try? Data(contentsOf: url)) ?? Data()
                    if d.count != lastSize {
                        lastSize = d.count
                        cont.yield(String(decoding: d, as: UTF8.self)
                            .split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).map(String.init))
                    }
                    try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// What a NEW process could restore for this spec (asleep, with its snapshot on disk), or nil.
    public nonisolated static func restorableState(for spec: SandboxSpec) -> PersistedSandbox? {
        let layout = StoreLayout(spec: spec)
        guard let p = PersistedSandbox.read(from: layout.persistedState), p.isRestorable(layout: layout) else { return nil }
        return p
    }

    /// Throw away the snapshot a previous process left instead of restoring it (as a Stop
    /// would): the root disk is kept and the next Start cold-boots it — after e2fsck, because the
    /// VM that slept was stopped without unmounting it. Only for a sandbox no process is running.
    public nonisolated static func discardRestorableState(for spec: SandboxSpec) {
        // Stop semantics: the snapshot goes; the root disk stays and the next Start cold-boots it.
        // 583: the disk was never unmounted (Hibernate stops the VM at the VZ level), and a
        // journal-less ext4 booted as it is corrupts (582: 12 of 15 boots failed) — mark it (and
        // the state disk) for e2fsck on that boot. 587: a journaled disk needs no mark — the
        // kernel replays its journal on mount (586: 0 of 45 boots needed more).
        let layout = StoreLayout(spec: spec)
        try? FileManager.default.removeItem(at: layout.snapshot)
        if var p = PersistedSandbox.read(from: layout.persistedState) {
            p.phase = .off
            if FileManager.default.fileExists(atPath: layout.rootfs.path), !disksJournaled(layout) { p.fsckOnNextBoot = true }
            try? p.write(to: layout.persistedState)
        }
    }

    /// A kept root disk needs e2fsck before it boots unless the last VM that ran it was shut down
    /// through the package (which unmounts it). A record whose last durable phase is not `off`
    /// (a crash while running, a snapshot discarded or a restore that failed), a snapshot lying
    /// beside the disk, or an explicit mark all mean it was not. 587: when every disk is journaled
    /// (`journaled`), only the explicit mark (a copy taken while running) still asks for e2fsck —
    /// the rest is journal replay's job.
    static func keptDiskNeedsFsck(_ kept: PersistedSandbox, snapshotPresent: Bool, journaled: Bool = false) -> Bool {
        kept.fsckOnNextBoot == true || (!journaled && (kept.phase != .off || snapshotPresent))
    }

    /// 587: every disk this sandbox has (root, and state if any) carries an ext4 journal.
    nonisolated static func disksJournaled(_ layout: StoreLayout) -> Bool {
        let disks = [layout.rootfs, layout.stateDisk].filter { FileManager.default.fileExists(atPath: $0.path) }
        return !disks.isEmpty && disks.allSatisfy(EXT4Inspector.hasJournal)
    }

    // MARK: lifecycle

    /// Boot a fresh sandbox: images and the guest init disk (downloaded once per store), the
    /// prepared disk (baked once per store and package set), then an APFS clone of it booted.
    public func start() async throws {
        await acquire(); defer { release() }
        guard phase == .off || phase == .failed else { throw SandboxError.invalidPhase(operation: "start", phase: phase) }
        if phase == .failed { await runStopSteps(from: .failed) }
        let t0 = ContinuousClock.now
        setBusy(true); defer { setBusy(false) }
        setPhase(.booting)
        do {
            try await boot(restoring: nil)
            setPhase(.running)
            // 599h: the tools layer — after the network is up; shown as steps the first time, quiet after; never fatal.
            await applyToolsLayer()
            note(String(format: "ready in %.1f s total", seconds(since: t0)))
        } catch {
            note("start FAILED: \(error.localizedDescription)")
            setPhase(.failed)
            throw error
        }
    }

    /// In a NEW process (the host crashed, or quit, while the sandbox slept): rebuild the
    /// identical VM from the persisted spec and identity, restore the snapshot, and adopt the
    /// restored guest. Sessions come back where they were.
    public func restoreAfterCrash() async throws {
        await acquire(); defer { release() }
        guard phase == .off else { throw SandboxError.invalidPhase(operation: "restore", phase: phase) }
        guard let persisted = PersistedSandbox.read(from: layout.persistedState), persisted.isRestorable(layout: layout) else {
            throw SandboxError.noSnapshot
        }
        let t0 = ContinuousClock.now
        setBusy(true); defer { setBusy(false) }
        setPhase(.booting)
        snapshotBytes = fileSize(layout.snapshot)
        do {
            // Right after the previous owner exits, its VM process can still hold the disks for a
            // moment ("The storage device attachment is invalid"): retry briefly.
            var attempt = 0
            while true {
                do { try await boot(restoring: persisted); break } catch where attempt < 20 && Self.disksStillHeld(error) {
                    attempt += 1
                    abandonBoot()
                    if attempt == 1 { note("the disks are still held by the previous process — retrying") }
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            setPhase(.running)
            for step in [LifecycleStep.resyncClock, .applyGuestFixes, .remountShares,.deleteSnapshot, .returnFreeMemory, .persistState] {
                try await run(step, target: .running)
            }
            note(String(format: "restored after a crash in %.2f s — sessions are where they were", seconds(since: t0)))
        } catch {
            abandonBoot()
            note("restore FAILED: \(error.localizedDescription) — the snapshot is kept; Shut Down discards it")
            setPhase(.failed)
            throw error
        }
    }

    static func disksStillHeld(_ error: Error) -> Bool {
        "\(error) \(error.localizedDescription)".contains("storage device attachment is invalid")
    }

    /// 583 (582: 2 of 31 concurrent wakes threw `unavailable: "The channel was closed"` although the
    /// sandbox came up). A restored guest resets its vsock transport as it resumes, and a vminitd
    /// connection the host dials in that moment can be closed under its first call — the wider the
    /// window, the busier the Mac (16 concurrent wakes: 1 in 64–80, always the wake's FIRST guest
    /// call, `resyncClock`). The first guest calls of a wake are idempotent, so they are retried,
    /// each attempt on a fresh connection.
    static func isTransientGuestTransportError(_ error: Error) -> Bool {
        let s = "\(error) \(error.localizedDescription)"
        return s.contains("The channel was closed") || s.contains("unavailable:") || s.contains("Connection reset by peer")
    }

    private func retryingFirstGuestCall<T>(_ what: String, attempts: Int = 5, _ body: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do { return try await body() } catch where attempt < attempts && Self.isTransientGuestTransportError(error) {
                note("\(what): \(error) — retrying on a fresh connection (\(attempt))")
                try await Task.sleep(for: .milliseconds(50 * attempt))
                attempt += 1
            }
        }
    }

    /// Drop a boot that failed part-way: its container may own vminitd clients that were never
    /// closed, and deallocating one is fatal — so it is kept (Graveyard), never freed.
    private func abandonBoot() {
        // Release the address, but KEEP the vmnet network for the next Start: creating a new one
        // per boot left the guest without a route out after a handful of Starts in one process.
        try? network?.releaseInterface(spec.name)
        if container != nil || instance != nil { Graveyard.keep(container, instance) }
        container = nil; instance = nil; handle = nil; identity = nil
    }

    /// The identity persisted with a root disk that Stop kept, if both are there.
    static func keptRootDisk(_ layout: StoreLayout) -> PersistedSandbox? {
        guard FileManager.default.fileExists(atPath: layout.rootfs.path) else { return nil }
        return PersistedSandbox.read(from: layout.persistedState)
    }

    // The owner's vocabulary (2026-09-25): Pause (Suspend) → Resume · Sleep → Wake ·
    // Hibernate → Wake · Shut Down → Start (Cold Boot).

    /// Pause: VZ pause, guest CPU 0, RAM kept (~1 ms). `resume()` continues.
    public func pause() async throws { try await perform(.pause) }
    /// Suspend — the same as `pause()`.
    public func suspend() async throws { try await pause() }
    /// Resume after `pause()`. (From Sleep it still works — the pre-rename spelling of `wake()`.)
    public func resume() async throws { try await perform(.resume) }
    /// Sleep: pause + snapshot to disk; RAM kept. From here a crash is survivable. `wake()` resumes it in place.
    public func sleep() async throws { try await perform(.sleep) }
    /// Hibernate: pause + snapshot + VM stop — RAM returned. Attached connections are detached with
    /// `.sandboxSleeping` first; attach again after `wake()`.
    public func hibernate() async throws { try await perform(.hibernate) }
    /// Wake from Sleep (resume in place, snapshot deleted) or from hibernation (restore + resume +
    /// clock re-sync + share re-mount + snapshot deleted). In a NEW process — the app quit or crashed
    /// while the sandbox slept — this adopts it (`restoreAfterCrash()`), sessions and all.
    public func wake() async throws {
        if phase == .off, Self.restorableState(for: spec) != nil { try await restoreAfterCrash(); return }
        try await perform(.wake)
    }
    /// Shut Down: a cold stop — gracefully, reviving a sleeping VM first — that KEEPS the root
    /// disk; running programs end. The next `start()` (`coldBoot()`) boots that same disk. No
    /// snapshot survives a Shut Down.
    public func shutDown() async throws { try await perform(.shutDown) }
    /// Cold Boot — the same as `start()`.
    public func coldBoot() async throws { try await start() }

    @available(*, deprecated, renamed: "wake()")
    public func wakeFromDisk() async throws { try await wake() }
    @available(*, deprecated, renamed: "shutDown()")
    public func stop() async throws { try await shutDown() }
    /// Stop if needed, then discard the root disk: the next `start()` begins from a fresh clone of
    /// the prepared disk.
    public func resetToImage() async throws { try await perform(.resetToImage) }
    /// Stop if needed, then remove everything this sandbox has on disk.
    public func delete() async throws { try await perform(.delete) }

    // MARK: restore points (disk only — see RestorePoints.swift)

    /// This sandbox's restore points, oldest first.
    public nonisolated func restorePoints() -> [RestorePoint] { layout.restorePoints() }

    /// Clone the root disk (and the state disk) into a new restore point. Stopped: an exact copy.
    /// Running: guest `sync`, pause, clone, resume — crash-consistent (no journal), recorded as
    /// `takenWhile: running`, and the first boot from it runs e2fsck. Paused / asleep: cloned as
    /// they are, also recorded as running.
    public func takeRestorePoint(name: String, note: String = "") async throws -> RestorePoint {
        // 594 W25: a name that cannot be stored as given is refused — never cut.
        if let problem = RestorePoint.nameProblem(name) { throw SandboxError.invalidSpec(problem) }
        await acquire(); defer { release() }
        return try await takeRestorePointLocked(name: name, note: note, automatic: false)
    }

    private func takeRestorePointLocked(name: String, note: String, automatic: Bool) async throws -> RestorePoint {
        let fm = FileManager.default
        guard fm.fileExists(atPath: layout.rootfs.path) else {
            throw SandboxError.invalidPhase(operation: "take a restore point (there is no root disk yet)", phase: phase)
        }
        let taken: RestorePoint.TakenWhile
        switch phase {
        case .off: taken = .stopped
        case .running, .paused, .asleep, .hibernated: taken = .running
        case .booting, .failed: throw SandboxError.invalidPhase(operation: "take a restore point", phase: phase)
        }
        let persisted = identity ?? PersistedSandbox.read(from: layout.persistedState)
        var point = RestorePoint(id: RestorePoint.newID(), name: name, note: note, createdAt: Date(), parent: persisted?.restorePoint,
                                 sourceImage: persisted?.rootImage, takenWhile: taken,
                                 hasStateDisk: fm.fileExists(atPath: layout.stateDisk.path), automatic: automatic)
        // A journaled disk replays on its first boot; only a journal-less one needs e2fsck (587).
        point.journaled = EXT4Inspector.hasJournal(layout.rootfs)
            && (!point.hasStateDisk || EXT4Inspector.hasJournal(layout.stateDisk))
        let rp = point
        let dir = layout.restorePointDirectory(rp.id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let clone: () throws -> Void = { [layout] in
            try cloneFile(layout.rootfs, to: dir.appendingPathComponent("root.ext4"))
            if rp.hasStateDisk { try cloneFile(layout.stateDisk, to: dir.appendingPathComponent("state.ext4")) }
        }
        do {
            if phase == .running, let instance {
                _ = try? await execInContainer(["sync"], timeout: 30)
                try await timed("restore point \"\(name)\": sync → pause → APFS clone → resume") {
                    try await instance.pause()
                    do { try clone() } catch {
                        try? await instance.resume()
                        throw error
                    }
                    try await instance.resume()
                }
            } else {
                try await timed("restore point \"\(name)\": APFS clone of the \(taken == .stopped ? "stopped" : "sleeping VM's") disk") { try clone() }
            }
            try ImageBaker.encoder.encode(rp).write(to: dir.appendingPathComponent("meta.json"))
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
        return rp
    }

    /// Revert to a restore point: Stop if needed (keeping the disk), take an automatic "before revert
    /// to …" restore point of the current disk (unless told not to), then replace the root disk
    /// (and the state disk, if the point has one) with clones of it. The next Start cold-boots it —
    /// after e2fsck, if the point was taken while running.
    public func revert(to id: String, takeBeforeRevert: Bool = true) async throws {
        await acquire(); defer { release() }
        guard let rp = layout.restorePoints().first(where: { $0.id == id }) else { throw SandboxError.restorePointNotFound(id) }
        if phase != .off {
            setBusy(true)
            await runStopStepsBestEffort(from: phase)
            setPhase(.off)
            setBusy(false)
        }
        let fm = FileManager.default
        if takeBeforeRevert, fm.fileExists(atPath: layout.rootfs.path) {
            _ = try await takeRestorePointLocked(name: "before revert to \(rp.name)", note: "taken automatically", automatic: true)
        }
        let dir = layout.restorePointDirectory(rp.id)
        try await timed("reverted to \"\(rp.name)\" (APFS clone; Start cold-boots it)") {
            try fm.createDirectory(at: layout.sandboxDirectory, withIntermediateDirectories: true)
            try cloneFile(dir.appendingPathComponent("root.ext4"), to: layout.rootfs)
            if rp.hasStateDisk { try cloneFile(dir.appendingPathComponent("state.ext4"), to: layout.stateDisk) }
            try? fm.removeItem(at: layout.snapshot)
        }
        var p = PersistedSandbox.read(from: layout.persistedState)
            ?? PersistedSandbox(spec: spec, phase: .off, machineIdentifier: VZGenericMachineIdentifier().dataRepresentation,
                                macAddress: spec.networking ? PersistedSandbox.randomMAC() : nil, subnet: nil, shareTags: [:])
        p.phase = .off
        p.rootImage = rp.sourceImage
        p.restorePoint = rp.id
        p.fsckOnNextBoot = rp.needsFsck ? true : nil
        try p.write(to: layout.persistedState)
        emitStatus()
    }

    /// A new sandbox, `newName`, whose disks are clones of restore point `id` — cold-booted on its
    /// first Start (after e2fsck if the point was taken while running). Same spec otherwise (the
    /// same shares). Returns its spec; make a `Sandbox` from it.
    public nonisolated func fork(_ id: String, as newName: String) throws -> SandboxSpec {
        guard let rp = layout.restorePoints().first(where: { $0.id == id }) else { throw SandboxError.restorePointNotFound(id) }
        var s = spec
        s.name = newName
        try s.validate()
        let nl = StoreLayout(spec: s)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: nl.sandboxDirectory.path) else { throw SandboxError.alreadyExists("sandbox \(newName)") }
        try fm.createDirectory(at: nl.sandboxDirectory, withIntermediateDirectories: true)
        let dir = layout.restorePointDirectory(rp.id)
        try cloneFile(dir.appendingPathComponent("root.ext4"), to: nl.rootfs)
        if rp.hasStateDisk { try cloneFile(dir.appendingPathComponent("state.ext4"), to: nl.stateDisk) }
        var p = PersistedSandbox(spec: s, phase: .off, machineIdentifier: VZGenericMachineIdentifier().dataRepresentation,
                                 macAddress: s.networking ? PersistedSandbox.randomMAC() : nil, subnet: nil, shareTags: [:])
        p.rootImage = rp.sourceImage
        p.restorePoint = rp.id
        p.fsckOnNextBoot = rp.needsFsck ? true : nil
        try p.write(to: nl.persistedState)
        return s
    }

    /// 593: a new sandbox from this one's disk — restore point `restorePoint`, or (nil) the current
    /// root disk of this STOPPED sandbox — with its own spec `newSpec` (the caller changes the name,
    /// shares, CPUs, memory, network; everything else is this one's). The root disk is an APFS clone;
    /// the state disk (the agent's logins and history) starts FRESH — the image spec's empty one is
    /// made on its first boot — unless `copyState`. Cold-booted on its first Start (after e2fsck when
    /// the source was taken while running). `fork` is this with the same spec and the state copied.
    public nonisolated func duplicate(from restorePoint: String?, as newSpec: SandboxSpec, copyState: Bool) throws {
        try newSpec.validate()
        let nl = StoreLayout(spec: newSpec)
        let fm = FileManager.default
        guard newSpec.name != spec.name else { throw SandboxError.alreadyExists("sandbox \(newSpec.name)") }
        let root: URL, state: URL?, sourceImage: String?, pointID: String?, fsck: Bool
        if let restorePoint {
            guard let rp = layout.restorePoints().first(where: { $0.id == restorePoint }) else { throw SandboxError.restorePointNotFound(restorePoint) }
            let dir = layout.restorePointDirectory(rp.id)
            root = dir.appendingPathComponent("root.ext4")
            state = rp.hasStateDisk ? dir.appendingPathComponent("state.ext4") : nil
            sourceImage = rp.sourceImage
            pointID = rp.id
            fsck = rp.needsFsck
        } else {
            guard let p = PersistedSandbox.read(from: layout.persistedState), p.phase == .off, fm.fileExists(atPath: layout.rootfs.path) else {
                throw SandboxError.invalidSpec("duplicate the current disk only while the sandbox is stopped (or from a restore point)")
            }
            root = layout.rootfs
            state = fm.fileExists(atPath: layout.stateDisk.path) ? layout.stateDisk : nil
            sourceImage = p.rootImage
            pointID = p.restorePoint
            fsck = p.fsckOnNextBoot == true
        }
        guard !fm.fileExists(atPath: nl.sandboxDirectory.path) else { throw SandboxError.alreadyExists("sandbox \(newSpec.name)") }
        try fm.createDirectory(at: nl.sandboxDirectory, withIntermediateDirectories: true)
        do {
            try cloneFile(root, to: nl.rootfs)
            if copyState, let state { try cloneFile(state, to: nl.stateDisk) }
            var p = PersistedSandbox(spec: newSpec, phase: .off, machineIdentifier: VZGenericMachineIdentifier().dataRepresentation,
                                     macAddress: newSpec.networking ? PersistedSandbox.randomMAC() : nil, subnet: nil, shareTags: [:])
            p.rootImage = sourceImage
            p.restorePoint = pointID
            p.fsckOnNextBoot = fsck ? true : nil
            try p.write(to: nl.persistedState)
        } catch {
            try? fm.removeItem(at: nl.sandboxDirectory)
            throw error
        }
    }

    /// Delete a restore point. Any one, in any order: each is a set of independent APFS clones —
    /// there is no chain of deltas to merge.
    public nonisolated func deleteRestorePoint(_ id: String) throws {
        let dir = layout.restorePointDirectory(id)
        guard FileManager.default.fileExists(atPath: dir.path) else { throw SandboxError.restorePointNotFound(id) }
        try FileManager.default.removeItem(at: dir)
    }

    /// Promote a restore point — or, with `restorePoint: nil`, the stopped sandbox's current root
    /// disk — to a CUSTOM image other sandboxes can start from (`SandboxSpec.customImage`). Not
    /// reproducible like a imageSpec bake, so it records `origin: custom` and its provenance.
    public nonisolated func saveAsImage(_ restorePoint: String?, name: String, note: String = "") throws -> CustomImage {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard (1...40).contains(name.count), name.allSatisfy(allowed.contains) else {
            throw SandboxError.invalidSpec("custom image names are 1–40 characters of [a-z0-9-]")
        }
        let fm = FileManager.default
        let source: URL, taken: Bool, chainStart: String?, base: String?, suffix: String
        if let restorePoint {
            guard let rp = layout.restorePoints().first(where: { $0.id == restorePoint }) else { throw SandboxError.restorePointNotFound(restorePoint) }
            source = layout.restorePointDirectory(rp.id).appendingPathComponent("root.ext4")
            taken = rp.needsFsck
            chainStart = rp.id
            base = rp.sourceImage
            suffix = rp.id
        } else {
            guard let p = PersistedSandbox.read(from: layout.persistedState), p.phase == .off,
                  fm.fileExists(atPath: layout.rootfs.path) else {
                throw SandboxError.invalidSpec("save the current disk as an image only while the sandbox is stopped")
            }
            source = layout.rootfs
            taken = p.fsckOnNextBoot == true
            chainStart = p.restorePoint
            base = p.rootImage
            suffix = "disk-" + String(RestorePoint.newID().dropFirst(3))
        }
        let key = "\(name)/\(suffix)"
        let dir = layout.customImageDirectory(key)
        guard !fm.fileExists(atPath: dir.path) else { throw SandboxError.alreadyExists("custom image \(key)") }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let root = dir.appendingPathComponent("root.ext4")
        try cloneFile(source, to: root)
        chmod(root.path, 0o444)
        let (apparent, allocated) = ImageBaker.sizes(root)
        var chain = layout.restorePointChain(from: chainStart)
        if restorePoint == nil, chain.isEmpty, let c = chainStart { chain = [c] }
        var img = CustomImage(key: key, name: name, note: note, createdAt: Date(), fromSandbox: spec.name, baseImage: base,
                              restorePointChain: chain, imageSpec: spec.imageSpec, needsFsck: taken,
                              apparentBytes: apparent, allocatedBytes: allocated)
        img.journaled = EXT4Inspector.hasJournal(root)
        try ImageBaker.encoder.encode(img).write(to: dir.appendingPathComponent("image.json"))
        return img
    }

    /// Remove a custom image (sandboxes already cloned from it are unaffected).
    public nonisolated static func deleteCustomImage(_ key: String, storeRoot: URL) throws {
        try FileManager.default.removeItem(at: StoreLayout(root: storeRoot, name: "_").customImageDirectory(key))
    }

    private func runStopStepsBestEffort(from p: Phase) async {
        for step in LifecyclePlanner.stopSteps(from: p) ?? [] {
            do { try await run(step, target: .off) } catch { note("stop: \(step) — \(error.localizedDescription)") }
        }
    }

    // MARK: memory (583)

    /// Whether every wake from hibernation ends with `returnFreeMemory()` (default: true).
    public private(set) var returnsFreeMemoryOnWake = true

    public func setReturnsFreeMemoryOnWake(_ on: Bool) { returnsFreeMemoryOnWake = on }

    /// Guest RAM the balloon holds right now (handed back to the Mac), bytes.
    private var balloonHeld: UInt64 = 0

    /// Guest RAM, MiB, the balloon currently holds for the Mac (0: the guest has its whole allocation).
    public var memoryReturnedMiB: UInt64 { balloonHeld / 1_048_576 }

    /// The free guest RAM `returnFreeMemory()` leaves the guest by default: a quarter of the
    /// allocation, at least 256 MiB.
    public nonisolated var defaultFreeReserveMiB: UInt64 { max(256, spec.memoryMiB / 4) }

    /// Hand the Mac back guest RAM the guest is not using: inflate the VM's memory balloon over the
    /// guest's free pages, leaving it `keepingFreeMiB` free (default `defaultFreeReserveMiB`). The
    /// page cache and every process are untouched.
    ///
    /// Why: the Mac charges a VM for every guest page it has EVER touched. After a wake from
    /// hibernation that is the whole allocation (restoring a snapshot faults every page in — 582: a 1 GiB
    /// Lab held 1,273 MiB woken vs 215 MiB cold-booted), and after work it is the high-water mark.
    /// Ballooned pages leave the VM's footprint at once and are the first the Mac takes back.
    ///
    /// The balloon STAYS inflated — deflating it would charge the pages to the VM again. The guest
    /// still has its whole allocation in an emergency (VZ's balloon deflates on guest OOM, slowly), and
    /// gets it back at once with `restoreGuestMemory()`. Sleep and Hibernate deflate it first (a
    /// snapshot of an inflated balloon does not restore). `wake()` calls this by itself
    /// (`setReturnsFreeMemoryOnWake`). nil when the sandbox is not running or its VM has no balloon
    /// (one hibernated by a build before 583, until its next cold boot).
    @discardableResult
    public func returnFreeMemory(keepingFreeMiB: UInt64? = nil) async throws -> MemoryReturn? {
        await acquire(); defer { release() }
        return try await returnFreeMemoryLocked(keepingFreeMiB: keepingFreeMiB)
    }

    /// Deflate the balloon: the guest has its whole allocation again (and the Mac is charged for it).
    public func restoreGuestMemory() async throws {
        await acquire(); defer { release() }
        guard phase == .running else { return }
        try await deflateBalloon()
    }

    /// `wait: false` (the wake): set the balloon's target and return — the guest fills it in the
    /// next ~100 ms on its own, so the wake does not wait; the result reports what was asked for.
    private func returnFreeMemoryLocked(keepingFreeMiB: UInt64? = nil, wait: Bool = true) async throws -> MemoryReturn? {
        guard phase == .running, let handle, let current = balloonTarget(handle) else { return nil }
        let full = current + balloonHeld
        let t0 = ContinuousClock.now
        let reserve = (keepingFreeMiB ?? defaultFreeReserveMiB) * 1024
        let m = try await guestMeminfo()
        let free0 = m["MemFree"] ?? 0, before = m["Balloon"] ?? 0
        guard free0 > reserve + 16 * 1024 else {
            return MemoryReturn(returnedMiB: 0, heldMiB: before / 1024, guestFreeMiB: free0 / 1024, milliseconds: milliseconds(since: t0))
        }
        let more = ((free0 - reserve) * 1024) & ~UInt64(1_048_575)
        let floor = (full / 8) & ~UInt64(1_048_575)          // never ask for more than 7/8 of the VM
        let target = current > more + floor ? current - more : floor
        guard target < current else {
            return MemoryReturn(returnedMiB: 0, heldMiB: before / 1024, guestFreeMiB: free0 / 1024, milliseconds: milliseconds(since: t0))
        }
        _ = balloonTarget(handle, set: target)
        balloonHeld = full - target
        guard wait else {
            return MemoryReturn(returnedMiB: (current - target) / 1_048_576, heldMiB: balloonHeld / 1_048_576, guestFreeMiB: free0 / 1024,
                                milliseconds: milliseconds(since: t0))
        }
        // The guest fills the balloon at its own pace; its /proc/meminfo `Balloon:` line says how far.
        let now = try await waitForBalloon(kiB: balloonHeld / 1024)
        return MemoryReturn(returnedMiB: (now - min(before, now)) / 1024, heldMiB: now / 1024, guestFreeMiB: free0 / 1024,
                            milliseconds: milliseconds(since: t0))
    }

    /// Deflate the balloon completely (the VM must be running) and wait for the guest to take it back.
    private func deflateBalloon() async throws {
        guard balloonHeld > 0, let handle else { balloonHeld = 0; return }
        let t0 = ContinuousClock.now
        let held = try await guestBalloonKiB()
        if let current = balloonTarget(handle) { _ = balloonTarget(handle, set: current + balloonHeld) }
        balloonHeld = 0
        _ = try await waitForBalloon(kiB: 0)
        broadcaster.yield(.step("gave the guest back \(held / 1024) MiB (memory balloon deflated)", milliseconds: milliseconds(since: t0)))
    }

    /// Poll the guest's balloon (kB) until it is within 2% of `kiB`, stops moving, or 5 s pass.
    private func waitForBalloon(kiB goal: UInt64) async throws -> UInt64 {
        var b: UInt64 = 0, last: UInt64 = .max, still = 0
        let tolerance = max(goal / 50, 4 * 1024)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            b = try await guestBalloonKiB()
            if b + tolerance >= goal && b <= goal + tolerance { break }
            if b == last { still += 1; if still >= 10 { break } } else { still = 0 }
            last = b
            try await Task.sleep(for: .milliseconds(20))
        }
        return b
    }

    /// What the guest's balloon holds right now, kB (/proc/meminfo `Balloon:`).
    private func guestBalloonKiB() async throws -> UInt64 { try await guestMeminfo()["Balloon"] ?? 0 }

    /// The guest's /proc/meminfo, kB.
    private func guestMeminfo() async throws -> [String: UInt64] {
        let r = try await execInContainer(["cat", "/proc/meminfo"], timeout: 10)
        var m: [String: UInt64] = [:]
        for line in r.output.split(separator: "\n") {
            let p = line.split(whereSeparator: { $0 == ":" || $0 == " " })
            if p.count >= 2, let v = UInt64(p[1]) { m[String(p[0])] = v }
        }
        return m
    }

    /// This sandbox has a root disk that the next `start()` will boot (rather than a fresh clone).
    public nonisolated var hasRootDisk: Bool { FileManager.default.fileExists(atPath: layout.rootfs.path) }

    /// What a host app does at quit (owner ruling 2026-09-25): **Hibernate**, never a cold stop.
    /// A running, paused or sleeping sandbox is snapshotted and its VM stopped, so the next launch
    /// `wake()`s it with every session and pid where it was. Hibernated: left as it is. Booting or
    /// failed (nothing worth keeping): shut down. If hibernating itself fails, it shuts down.
    ///
    /// 583: a program a session started less than `settle` ago is given the rest of that time before
    /// it hibernates (580: Claude Code hibernated within ~1 s of launching exited after the wake in
    /// 2 of ~7 runs). Pass `.zero` not to wait.
    ///
    /// 594 W22: what it did, for a caller that reports it (`doz host stop`'s progress).
    public enum ExitOutcome: Equatable, Sendable {
        /// Snapshotted and stopped: the next launch wakes it.
        case hibernated
        /// Hibernating failed (why): it was shut down instead (its disk kept).
        case hibernateFailed(String)
        /// A failed wake's snapshot was kept for the next launch to try again.
        case keptFailedWake
        /// Booting or failed: shut down.
        case shutDown
        /// Nothing to do (off, or already hibernated).
        case unchanged
    }

    @discardableResult
    public func prepareForExit(settle: Duration = .seconds(3)) async -> ExitOutcome {
        await acquire(); defer { release() }
        if phase == .running {
            let wait = Self.exitSettleDelay(sinceLastSessionStart: lastSessionStart.map { ContinuousClock.now - $0 }, settle: settle)
            if wait > .zero {
                let s = { (d: Duration) in Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
                note(String(format: "a session's program started %.1f s ago — letting it settle for %.1f s before hibernating",
                            s(settle - wait), s(wait)))
                try? await Task.sleep(for: wait)
            }
        }
        switch phase {
        case .running, .paused, .asleep:
            let from = phase
            do {
                for step in LifecyclePlanner.plan(.hibernate, from: from) ?? [] { try await run(step, target: .hibernated) }
                setPhase(.hibernated)
                note("hibernated for the quit — the next launch wakes it, sessions and all")
                return .hibernated
            } catch {
                note("hibernate at quit FAILED (\(error.localizedDescription)) — shutting down instead")
                await runStopSteps(from: phase)
                setPhase(.off)
                return .hibernateFailed(error.localizedDescription)
            }
        case .hibernated:
            for c in connections.values { c.detach(.sandboxSleeping) }
            connections.removeAll()
            return .unchanged
        case .failed where Self.restorableState(for: spec) != nil:
            // A wake that FAILED keeps its snapshot ("Shut Down discards it"), and a quit is not a
            // Shut Down: leave the snapshot and the record alone so the next process tries the wake
            // again. (591: a host whose own executable had been replaced under it could start no VM;
            // quitting it ran the stop steps here and deleted two sandboxes' snapshots — their
            // running sessions were lost.) The failed boot was already abandoned.
            for c in connections.values { c.detach(.sandboxSleeping) }
            connections.removeAll()
            note("quit after a failed wake: the snapshot is kept — the next launch tries the wake again (Shut Down discards it)")
            return .keptFailedWake
        case .booting, .failed:
            await runStopSteps(from: phase)
            setPhase(.off)
            return .shutDown
        case .off:
            return .unchanged
        }
    }

    private func perform(_ op: LifecycleOperation) async throws {
        await acquire(); defer { release() }
        // Decide from the phase observed NOW — before anything marks the sandbox busy. (The 576
        // POC once read it after going busy, and Stop skipped stopping the VM.)
        let from = phase
        guard let steps = LifecyclePlanner.plan(op, from: from) else {
            throw SandboxError.invalidPhase(operation: op.rawValue, phase: from)
        }
        setBusy(true); defer { setBusy(false) }
        if [.shutDown, .resetToImage, .delete].contains(op) {
            // Best effort at every step: whatever state the VM is in, it ends stopped.
            for step in steps {
                do { try await run(step, target: .off) } catch { note("\(op.rawValue): \(step) — \(error.localizedDescription)") }
            }
            setPhase(.off)
            return
        }
        let target = LifecyclePlanner.target(of: op)
        for step in steps {
            do { try await run(step, target: target) } catch {
                note("\(op.rawValue) FAILED at \(step): \(error.localizedDescription)")
                throw error
            }
        }
        setPhase(target)
    }

    /// Stop is best effort at every step: whatever state the VM is in, it ends stopped and the
    /// runtime files are gone.
    /// How long `prepareForExit` waits: the rest of `settle` since the last session's program started.
    static func exitSettleDelay(sinceLastSessionStart since: Duration?, settle: Duration) -> Duration {
        guard let since, since >= .zero, since < settle else { return .zero }
        return settle - since
    }

    private func runStopSteps(from: Phase) async {
        for step in LifecyclePlanner.plan(.shutDown, from: from) ?? [] {
            do { try await run(step, target: .off) } catch { note("stop: \(step) — \(error.localizedDescription)") }
        }
    }

    private func run(_ step: LifecycleStep, target: Phase) async throws {
        switch step {
        case .pauseVM:
            guard let instance else { throw SandboxError.vmUnavailable }
            try await timed("paused the VM (guest CPU 0, memory kept)") { try await instance.pause() }
            setPhase(.paused)
        case .resumeVM:
            guard let instance else { throw SandboxError.vmUnavailable }
            try await timed("resumed the VM") { try await instance.resume() }
            setPhase(.running)
        case .restoreGuestMemory:
            if balloonHeld > 0 { try await deflateBalloon() }
        case .syncGuest:
            guard container != nil else { return }
            do {
                let t0 = ContinuousClock.now
                let r = try await execInContainer(["sh", "-c", GuestCommand.syncAndMeasure], timeout: 20)
                let usage = GuestCommand.parseDiskUsage(r.output)
                if var p = identity {
                    p.guestUsedMiB = usage["/"]
                    p.stateGuestUsedMiB = usage[GuestCommand.stateMount]
                    identity = p
                }
                broadcaster.yield(.step("synced the guest's file systems (\(usage["/"].map { String(format: "%.0f MiB in use", $0) } ?? "usage unknown"))",
                                        milliseconds: milliseconds(since: t0)))
            } catch {
                note("could not sync the guest (\(error.localizedDescription)) — continuing")
            }
        case .saveSnapshot:
            guard let handle else { throw SandboxError.vmUnavailable }
            if balloonHeld > 0, let instance {
                // A snapshot taken with the balloon inflated does not restore ("invalid argument"):
                // let the guest take it back first. (Sleep from Pause lands here; from running,
                // `.restoreGuestMemory` already did it before the pause.)
                try await instance.resume()
                try await deflateBalloon()
                try await instance.pause()
            }
            try? FileManager.default.removeItem(at: layout.snapshot)
            try await timed("saved VM state to disk") { try await vz(handle, .save(layout.snapshot)) }
            snapshotBytes = fileSize(layout.snapshot)
            setPhase(.asleep)
        case .detachSessions(let reason):
            let conns = Array(connections.values)
            connections.removeAll()
            for c in conns { c.detach(reason) }
            if !conns.isEmpty { note("detached \(conns.count) session connection(s): \(reason.rawValue)") }
        case .stopVMDirect:
            guard let handle else { return }
            if vzStateIsStopped(handle) { return }
            try await timed(target == .hibernated ? "hibernate: stopped the VM — RAM freed, state on disk" : "stopped the VM") {
                try await vz(handle, .stop)
            }
            if target == .hibernated { setPhase(.hibernated) }
        case .reviveForStop:
            guard let handle else { return }
            let vmState = handle.queue.sync { handle.vm.state }
            if vmState == .paused {
                try await timed("resumed the VM to stop it gracefully") { try await vz(handle, .resume) }
            } else if vmState == .stopped, FileManager.default.fileExists(atPath: layout.snapshot.path) {
                try await timed("restored the VM to stop it gracefully") {
                    try await vz(handle, .restore(layout.snapshot))
                    try await vz(handle, .resume)
                }
            }
        case .stopContainer:
            guard let container else { return }
            do {
                try await timed("stopped the container") { try await container.stop() }
                cleanlyStopped = true
            } catch {
                // LinuxContainer.stop() tries every step and reports the first error — typically
                // "Client has been stopped" from an exec that was attached before a sleep to disk.
                // It still stops the VM through the instance; only if it did not is the VM
                // stopped here, at the VZ level.
                if let handle, !vzStateIsStopped(handle) {
                    try? await vz(handle, .stop)
                    note("stopped the VM at the VZ level (the container's stop reported: \(error.localizedDescription))")
                } else {
                    cleanlyStopped = true
                    note("stopped the container (it reported: \(error.localizedDescription))")
                }
            }
        case .restoreSnapshot:
            guard let handle else { throw SandboxError.vmUnavailable }
            balloonHeld = 0                             // snapshots are only ever taken deflated
            try await timed("restored VM state from disk") { try await vz(handle, .restore(layout.snapshot)) }
            try await timed("resumed") { try await vz(handle, .resume) }
            setPhase(.running)
            try listenForEgress()
        case .resyncClock:
            guard let instance, let v = vzInstance(of: instance) else { throw SandboxError.vmUnavailable }
            try await timed("re-synced the guest clock") {
                try await retryingFirstGuestCall("re-sync the guest clock") {
                    let agent = try await v.dialAgent()
                    let now = Date().timeIntervalSince1970
                    do { try await agent.setTime(sec: Int64(now), usec: Int32((now - floor(now)) * 1_000_000)) } catch {
                        await closeKeepingOnFailure(agent)
                        throw error
                    }
                    await closeKeepingOnFailure(agent)
                }
            }
        case .applyGuestFixes:
            // 594 W34: what a fresh boot applies, at every wake too — the time zone among them (W10:
            // the Mac may have changed zone while this sandbox slept). ONE root exec; best effort: a
            // wake never fails for it, a failure is noted.
            let script = GuestCommand.guestFixes(imageSpec: spec.imageSpec, agentSudo: agentSudo, timeZone: timeZone,
                                                 git: gitSetup, sshAgent: sshAgentSocket != nil)
            let t0 = ContinuousClock.now
            do {
                let r = try await retryingFirstGuestCall("apply the guest fixes") {
                    try await execInContainer(["sh", "-c", script], privileged: true, timeout: 15)
                }
                if r.exitCode != 0 {
                    note("the guest fixes exited \(r.exitCode): \(String((r.output + r.errorOutput).suffix(200))) — the wake goes on")
                } else {
                    note(String(format: "applied the guest fixes in %.0f ms", seconds(since: t0) * 1000))
                }
            } catch {
                note("could not apply the guest fixes: \(error.localizedDescription) — the wake goes on")
            }
            // 610: this build's deckhold on the guest's disk for the sessions opened from now on.
            await refreshDeckhold()
            // 599h: the tools layer, re-checked quietly (a setting switched on while it slept arrives now).
            await applyToolsLayer()
        case .remountShares:
            let tags = (identity?.shareTags ?? [:]).map { (tag: $0.value, guestPath: $0.key) }.sorted { $0.guestPath < $1.guestPath }
            guard !tags.isEmpty else { return }
            // 599g: a share with workspace rules is re-bound privately and its view's daemon signalled in
            // the same script; a share that gained a rule file while asleep gets its view now.
            let views = wantedViews(shareTags: identity?.shareTags ?? [:])
            if views.keys.contains(where: { activeViews[$0] == nil }) { await copyViewBinary() }
            let out = try await timed("re-mounted \(tags.count) share(s) (virtio-fs does not survive a VM stop)") {
                // The re-mount script is idempotent (it unmounts before it mounts).
                let r = try await retryingFirstGuestCall("re-mount the shares") {
                    try await execInContainer(["sh", "-c", GuestCommand.remountShares(tags, views: views)], privileged: true, timeout: 30)
                }
                if r.exitCode != 0 { throw SandboxError.commandFailed(command: "remount shares", exitCode: r.exitCode, output: r.output + r.errorOutput) }
                return r.output
            }
            recordViewStatus(out, wanted: views, guestPaths: Dictionary(tags.map { ($0.tag, $0.guestPath) }, uniquingKeysWith: { a, _ in a }))
        case .deleteSnapshot:
            if FileManager.default.fileExists(atPath: layout.snapshot.path) {
                try? FileManager.default.removeItem(at: layout.snapshot)
                note("deleted the snapshot (it is valid only while the VM is paused)")
            }
            snapshotBytes = 0
        case .returnFreeMemory:
            guard returnsFreeMemoryOnWake else { return }
            do {
                if let r = try await returnFreeMemoryLocked(wait: false) {
                    broadcaster.yield(.step(String(format: "returning %llu MiB of untouched guest RAM to the Mac (memory balloon; the guest had %llu MiB free, keeps %llu)",
                                                   r.heldMiB, r.guestFreeMiB, defaultFreeReserveMiB), milliseconds: r.milliseconds))
                }
            } catch {
                note("could not return free guest RAM (\(error.localizedDescription)) — the wake is unaffected")
            }
        case .releaseRuntime:
            // Release the address, but KEEP the vmnet network for the next Start: creating a new one
        // per boot left the guest without a route out after a handful of Starts in one process.
        try? network?.releaseInterface(spec.name)
            if !cleanlyStopped, let container {
                // Never let the package deallocate a vminitd client it did not close: that is a
                // fatal error in its gRPC transport. A container that was not stopped through
                // LinuxContainer.stop() is kept for the life of the process instead.
                Graveyard.keep(container, instance)
            }
            // 583: a VM that was not stopped through the package (the VZ-level fallback, a boot or
            // restore abandoned part-way) never unmounted its disks: e2fsck them on the next boot.
            let unclean = !cleanlyStopped && container != nil
            if var p = identity ?? (unclean ? PersistedSandbox.read(from: layout.persistedState) : nil) {
                p.phase = .off
                p.savedAt = Date()
                if unclean, FileManager.default.fileExists(atPath: layout.rootfs.path), !Self.disksJournaled(layout) { p.fsckOnNextBoot = true }
                try? p.write(to: layout.persistedState)
            }
            container = nil; instance = nil; handle = nil; identity = nil; cleanlyStopped = false; balloonHeld = 0
            egress?.stopListening()
            sshRelayBox.withLock { $0 }?.stop()          // 599d: listens again at the next boot
            egress?.vault.revokeAll()
        case .removeRootDisk:
            for url in [layout.rootfs, layout.persistedState, layout.snapshot] { try? FileManager.default.removeItem(at: url) }
            note("reset to image: the root disk was discarded — the next Start clones the prepared disk")
        case .removeSandboxFiles:
            try? FileManager.default.removeItem(at: layout.sandboxDirectory)
            note("deleted the sandbox and everything it had on disk")
        case .persistState:
            guard var p = identity else { return }
            p.phase = target
            p.savedAt = Date()
            identity = p
            try p.write(to: layout.persistedState)
        case .captureScreens:
            let reason = switch target {
            case .paused: "pause"
            case .asleep: "sleep"
            case .hibernated: "hibernate"
            default: "capture"               // (the planner captures before those three only)
            }
            _ = await captureScreensLocked(reason: reason, changedOnly: false)
        case .removeSavedScreens:
            // Shut down, reset, remove: the sessions are gone — so are their screens (owner, 2026-09-30).
            if !SavedScreens.remove(layout).isEmpty { note("deleted the sessions' saved screens (the sessions are gone)") }
        }
        emitStatus()
    }

    // MARK: boot

    private func boot(restoring persisted: PersistedSandbox?) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.sandboxDirectory, withIntermediateDirectories: true)
        guard let deckhold = DeckholdBinary.locate() else { throw SandboxError.deckholdMissing }
        let broadcaster = self.broadcaster
        let kernelURL = try await kernelProvider.resolve(override: spec.kernelPath) { e in
            switch e {
            case .step(let s, let ms): broadcaster.yield(.step(s, milliseconds: ms))
            case .note(let s): broadcaster.yield(.note(s))
            case .progress(let s, let done, let total): broadcaster.yield(.progress(s, completedBytes: done, totalBytes: total))
            }
        }
        let kernel = Kernel(path: kernelURL, platform: .linuxArm)
        let store = try ImageStore(path: spec.storeRoot)
        let firstRun = !fm.fileExists(atPath: layout.initfs.path)
        if firstRun { note("first start in this store: downloading images (one-time, needs network)…") }
        try await timed("guest init image ready (vminit\(firstRun ? ": pulled + built its disk" : ", cached"))") {
            _ = try await ContainerManager(kernel: kernel, initfsReference: spec.initfsReference, imageStore: store)
        }

        var identity: PersistedSandbox
        let kept = persisted == nil ? Self.keptRootDisk(layout) : nil
        // What a fresh root disk would be cloned from: the prepared disk, or the imageSpec's bake.
        let custom: CustomImage? = try spec.customImage.map { key in
            guard let c = layout.customImages().first(where: { $0.key == key }) else {
                throw SandboxError.invalidSpec("no custom image \(key) in this store")
            }
            return c
        }
        let wantedRoot: String = try custom.map { "custom:\($0.key)" } ?? spec.imageSpec.map {
            "\($0.name)@\($0.bakeKey(kernelSHA256: try KernelProvider.sha256(of: kernelURL), deckholdSHA256: try KernelProvider.sha256(of: deckhold)).prefix(12))"
        } ?? StoreLayout.goldenKey(for: spec)
        if let persisted {
            identity = persisted
        } else if let kept {
            // Stop kept this root disk: cold-boot it. Its snapshot, if one is lying around (a
            // crash while asleep, then Start instead of Restore), no longer matches a disk that
            // is about to move on — delete it, never restore it later.
            let dirty = Self.keptDiskNeedsFsck(kept, snapshotPresent: fm.fileExists(atPath: layout.snapshot.path),
                                               journaled: Self.disksJournaled(layout))
            try? fm.removeItem(at: layout.snapshot)
            try? fm.removeItem(at: layout.bootLog)
            if let from = kept.rootImage, from != wantedRoot {
                note("the kept root disk was cloned from \(from), not \(wantedRoot) — Reset to image to start from the new one")
            }
            note("cold-booting the kept root disk (Stop keeps it; Reset to image starts afresh)")
            // A cold boot restores no snapshot, so it needs none of the old VM identity — and
            // reusing the old MAC with a newly allocated address broke the guest's networking
            // (579: `apk add` could not reach the mirror on every Start of a kept disk).
            identity = PersistedSandbox(spec: spec, phase: .running,
                                        machineIdentifier: VZGenericMachineIdentifier().dataRepresentation,
                                        macAddress: spec.networking ? PersistedSandbox.randomMAC() : nil,
                                        subnet: nil, shareTags: [:])
            identity.rootImage = kept.rootImage
            identity.restorePoint = kept.restorePoint
            identity.fsckOnNextBoot = dirty ? true : nil
        } else {
            let golden: URL
            if let custom {
                golden = layout.customImageDirectory(custom.key).appendingPathComponent("root.ext4")
            } else if let imageSpec = spec.imageSpec {
                golden = try await ensureImage(imageSpec, kernel: kernel, kernelURL: kernelURL, deckhold: deckhold).root
            } else {
                golden = layout.golden(for: spec)
                if !fm.fileExists(atPath: golden.path) {
                    let hadImage = (try? await store.get(reference: spec.image, pull: false)) != nil
                    let broadcaster = self.broadcaster
                    let reference = spec.image
                    let image = try await timed("\(spec.image) ready\(hadImage ? " (cached)" : " (pulled)")") {
                        if let cached = try? await store.get(reference: reference) { return cached }
                        return try await ImageBaker.pull(reference, store: store) { broadcaster.yield($0) }
                    }
                    try await bake(image: image, kernel: kernel, store: store, into: golden)
                }
            }
            try? fm.removeItem(at: layout.rootfs)
            try? fm.removeItem(at: layout.bootLog)
            try? fm.removeItem(at: layout.snapshot)
            let rootfs = layout.rootfs
            try await timed("root disk cloned from the \(spec.imageSpec == nil ? "prepared disk" : "baked image \(spec.imageSpec!.name)") (APFS clone)") {
                try FileManager.default.copyItem(at: golden, to: rootfs)
                chmod(rootfs.path, 0o644)                   // the baked disk is read-only; its clone is not
            }
            identity = PersistedSandbox(spec: spec, phase: .running,
                                        machineIdentifier: VZGenericMachineIdentifier().dataRepresentation,
                                        macAddress: spec.networking ? PersistedSandbox.randomMAC() : nil,
                                        subnet: nil, shareTags: [:])
            identity.rootImage = wantedRoot
            if custom?.needsFsck == true { identity.fsckOnNextBoot = true }
        }
        // A cold boot builds a new VM, with a memory balloon; a restore keeps what the snapshot had.
        if persisted == nil { identity.memoryBalloon = true }
        // 591: a restore boots the VM from what was RECORDED where this build controls it — the
        // balloon (above) and the kernel file the snapshot was taken under (a later build may pin a
        // newer kernel). A kernel this Mac no longer has refuses the wake; the snapshot is kept.
        // EXPERIMENTAL (604): an audio sandbox's VM boots the sound kernel (verified, from the kernel cache — the
        // host puts it there); everything above (bakes, image keys) used the pinned kernel.
        var bootKernelURL = kernelURL
        if spec.audio == true {
            let sound = SoundKernel.path(inCache: kernelProvider.cacheDirectory)
            guard SoundKernel.isVerified(sound) else {
                throw SandboxError.invalidSpec("\(spec.name) is an audio sandbox (experimental), and its sound kernel \(SoundKernel.fileName) is missing or damaged in \(kernelProvider.cacheDirectory.path) — a doz that carries it puts it there when the sandbox starts")
            }
            bootKernelURL = sound
        }
        var vmKernel = Kernel(path: bootKernelURL, platform: .linuxArm)
        let currentKernelSHA = bootKernelURL == kernelURL ? try KernelProvider.sha256(of: kernelURL) : SoundKernel.sha256
        var vmKernelSHA = currentKernelSHA
        if let persisted, let recorded = persisted.vmLayout {
            guard let k = VMLayout.kernelForRestore(recorded: recorded, current: bootKernelURL, currentSHA256: currentKernelSHA,
                                                    searchDirectories: [kernelProvider.cacheDirectory, layout.kernels]) else {
                throw SandboxError.snapshotNeedsOtherBuild(
                    sandbox: spec.name, recordedBy: recorded.recordedBy,
                    differences: ["kernel: slept with \(recorded.kernelSHA256?.prefix(12) ?? "?"), which this Mac no longer has; this build's is \(currentKernelSHA.prefix(12))"])
            }
            if k != bootKernelURL {
                note("restoring with the kernel it slept under (\(k.lastPathComponent)) — a cold boot would use this build's")
                vmKernel = Kernel(path: k, platform: .linuxArm)
                vmKernelSHA = recorded.kernelSHA256 ?? currentKernelSHA
            }
        }
        // The state disk outlives root disks (Stop, Reset to image, a re-bake); only Delete removes it.
        if let imageSpec = spec.imageSpec, !fm.fileExists(atPath: layout.stateDisk.path) {
            // 587: the state disk gets the imageSpec's journal setting.
            let journal = imageSpec.journalMiB
            try await timed("created the empty state disk (\(spec.stateDiskMiB) MiB, sparse\(journal.map { ", \($0) MiB journal" } ?? ", no journal"))") {
                let f = try EXT4.Formatter(FilePath(layout.stateDisk.path), minDiskSize: spec.stateDiskMiB * 1_048_576,
                                           journal: ImageSpec.journalConfig(journal))
                try f.close()
            }
        }

        if persisted == nil, identity.fsckOnNextBoot == true {
            // This disk was not cleanly unmounted (a copy taken while its VM ran, a discarded
            // snapshot, a crash) — see `keptDiskNeedsFsck`.
            let helper = FsckHelper(storeRoot: spec.storeRoot, kernel: kernel, initfsReference: spec.initfsReference,
                                    dnsServers: spec.dnsServers, events: { [broadcaster] in broadcaster.yield($0) })
            for disk in [layout.rootfs, layout.stateDisk] where fm.fileExists(atPath: disk.path) {
                let kind = EXT4Inspector.hasJournal(disk) ? "journaled ext4" : "ext4 without a journal"
                let report = try await timed("e2fsck \(disk.lastPathComponent) (not cleanly unmounted; \(kind))") {
                    try await helper.check(disk)
                }
                note("fsck \(disk.lastPathComponent): " + (report.split(separator: "\n").suffix(2).joined(separator: " · ")))
            }
            identity.fsckOnNextBoot = nil
        }
        if persisted == nil {
            identity.rootJournaled = EXT4Inspector.hasJournal(layout.rootfs)
            identity.stateJournaled = fm.fileExists(atPath: layout.stateDisk.path) ? EXT4Inspector.hasJournal(layout.stateDisk) : nil
        }

        var iface: (any Interface)?
        var readdress: (address: String, gateway: String)?
        if spec.networking {
            var net: VmnetNetwork
            if let existing = network, persisted == nil || existing.subnet.description == identity.subnet {
                net = existing                      // one vmnet network per Sandbox, reused across Starts
            } else {
                net = try await makeNetwork(persistedSubnet: persisted == nil ? spec.subnet : identity.subnet, restoring: persisted != nil)
            }
            try? net.releaseInterface(spec.name)
            guard let i = try net.createInterface(spec.name) else { throw SandboxError.vmUnavailable }
            if let old = identity.subnet, persisted != nil, old != net.subnet.description, let gw = i.ipv4Gateway {
                // The guest still has its old address; fix it once the restored guest runs.
                readdress = (i.ipv4Address.description, gw.description)
            }
            iface = i
            identity.subnet = net.subnet.description
            if let old = network, old.subnet != net.subnet { SubnetPool.release(old.subnet.description) }
            network = net
        }

        let flag = AdoptionFlag(persisted != nil)
        let initfs = Containerization.Mount.block(format: "ext4", source: layout.initfs.path, destination: "/", options: ["ro"])
        let recorder = VMLayoutRecorder()
        let vmm = DozerVMM(
            inner: VZVirtualMachineManager(kernel: vmKernel, initialFilesystem: initfs, group: SharedEventLoop.group),
            identity: PinnedIdentity(machineIdentifier: identity.machineIdentifier, macAddress: identity.macAddress,
                                     memoryBalloon: identity.memoryBalloon == true, audio: spec.audio == true, kernelSHA256: vmKernelSHA,
                                     expected: persisted?.vmLayout, sandboxName: spec.name, recorder: recorder),
            adopt: persisted != nil ? (snapshot: layout.snapshot, flag: flag, containerID: spec.name) : nil)
        let spec = self.spec
        let bootLog = layout.bootLog
        let stateDisk = layout.stateDisk
        let c = try LinuxContainer(
            spec.name,
            // 587: `discard` — a block the guest frees is punched out of the host file at once
            // (586: VZ's virtio-blk passes discards through). A guest mount option, not a VM input.
            rootfs: .block(format: "ext4", source: layout.rootfs.path, destination: "/", options: GuestCommand.diskMountOptions),
            vmm: vmm,
            vm: VMResources(cpus: spec.cpus, memoryInBytes: spec.memoryMiB * 1_048_576 + VMResources.guestMemoryOverhead)
        ) { cfg in
            // Everything here is a VM input: a restore rebuilds it byte-for-byte from the spec.
            cfg.cpus = spec.cpus
            cfg.memoryInBytes = spec.memoryMiB * 1_048_576
            cfg.hostname = spec.name
            cfg.process.arguments = ["sleep", "infinity"]
            cfg.process.environmentVariables = GuestCommand.environment()
            for s in spec.shares { cfg.mounts.append(.share(source: s.hostPath, destination: s.guestPath)) }
            // The state disk comes AFTER the shares, always: device order is a VM input that a
            // snapshot restore must reproduce exactly.
            if spec.imageSpec != nil {
                cfg.mounts.append(.block(format: "ext4", source: stateDisk.path, destination: GuestCommand.stateMount,
                                         options: GuestCommand.diskMountOptions))
            }
            if let iface { cfg.interfaces = [iface] }
            // A proxied sandbox asks its shim (127.0.0.1:53), which asks the Mac.
            cfg.dns = DNS(nameservers: spec.isProxied ? ["127.0.0.1"] : spec.dnsServers)
            cfg.bootLog = BootLog.file(path: bootLog)
        }
        container = c
        if persisted != nil {
            try await timed("restored the VM from its snapshot into this process (pinned machine id)") { try await c.create() }
            try await timed("adopted the restored container") { try await c.start() }
            flag.adopting = false
            if let readdress {
                let script = "ip addr flush dev eth0 && ip addr add \(readdress.address) dev eth0 && ip link set eth0 up && ip route replace default via \(readdress.gateway)"
                let r = try await Self.exec(on: c, ["sh", "-c", script], environment: [:], workingDirectory: "/", privileged: true, timeout: 15)
                note(r.exitCode == 0 ? "re-addressed the guest NIC to \(readdress.address) (its old subnet was not available)"
                                     : "could not re-address the guest NIC: \(r.errorOutput)")
            }
        } else {
            try await timed("VM created and booted (VZ start + Linux kernel + vminitd)") { try await c.create() }
            if let k = kernelBootMilliseconds() { note(String(format: "  of which: kernel start → init %.0f ms (kernel clock; see the boot console)", k)) }
            try await timed("container process started") { try await c.start() }
        }

        // 591: this VM's layout is what its next snapshot will be taken with.
        if let l = recorder.layout { identity.vmLayout = l }
        let (inst, h): (any VirtualMachineInstance, VMHandle) = try await c.withVirtualMachineInstance { i in
            guard let v = vzInstance(of: i) else { throw SandboxError.vmUnavailable }
            return (i, VMHandle(vm: v.vzVirtualMachine, queue: v.vmQueue))
        }
        instance = inst
        handle = h
        balloonHeld = 0
        try listenForEgress()
        if persisted == nil {
            if let v = vzInstance(of: inst) {
                for m in v.mounts[spec.name] ?? [] where m.type == "virtiofs" { identity.shareTags[m.destination] = m.source }
            }
            try await timed("installed deckhold (the guest PTY holder)") {
                try await c.copyIn(from: deckhold, to: URL(fileURLWithPath: GuestCommand.deckholdPath), mode: 0o755)
            }
            try await timed(spec.imageSpec == nil ? "prepared the guest" : "prepared the guest (persist dirs bound from the state disk)") {
                let r = try await Self.exec(on: c, ["sh", "-c", GuestCommand.prepareGuest(imageSpec: spec.imageSpec, agentSudo: agentSudo, timeZone: timeZone,
                                                                                         git: gitSetup)], environment: [:],
                                            workingDirectory: "/", privileged: true, timeout: 30)
                if r.exitCode != 0 { throw SandboxError.commandFailed(command: "prepare guest", exitCode: r.exitCode, output: r.output + r.errorOutput) }
            }
            if let egress {
                let ca = try SandboxCA.loadOrCreate(in: layout.sandboxDirectory, sandbox: spec.name)
                egress.ca = ca
                try await timed("network: no interface; doznet + the sandbox CA installed, DNS and egress via the Mac's proxy (\(egress.policy.preset ?? "custom") policy)") {
                    try await Self.startEgressShim(on: c, caFile: layout.sandboxDirectory.appendingPathComponent("egress-ca.pem"))
                }
                // 599d (G4): doznet is in place only now — the forwarded SSH agent's guest half starts here.
                if sshAgentSocket != nil {
                    _ = try? await Self.exec(on: c, ["sh", "-c", GuestCommand.sshAgentScript(on: true)], environment: [:],
                                             workingDirectory: "/", privileged: true, timeout: 15)
                }
            }
            // 599g: workspace rules — a share whose Mac folder holds .dozignore/.dozreadonly is served
            // through the view. Never fatal: a failure is said (and the share is then EMPTY, not open).
            setActiveViews([:])
            fallbackBox.withLock { $0 = [] }
            let views = wantedViews(shareTags: identity.shareTags)
            if !views.isEmpty { await startViews(views, on: c, quiet: false) }
        } else if let egress, egress.ca == nil {
            // Adopted after a crash: the guest still runs its shim and trusts this sandbox's CA.
            egress.ca = try? SandboxCA.loadOrCreate(in: layout.sandboxDirectory, sandbox: spec.name)
        }
        identity.phase = .running
        self.identity = identity
        try identity.write(to: layout.persistedState)
    }

    /// The vmnet network. On a restore, the subnet the guest was addressed from — vmnet can take
    /// a moment to release a dead process's network, so retry briefly before settling for a new
    /// subnet (and re-addressing the guest). With no subnet asked for (583): a free one of its own
    /// (`SubnetPool`), never vmnet's shared default.
    private func makeNetwork(persistedSubnet: String?, restoring: Bool) async throws -> VmnetNetwork {
        if let persistedSubnet, let cidr = try? CIDRv4(persistedSubnet) {
            // A restore must get its old subnet back (vmnet may still be releasing it: retry); a fresh
            // start that asked for one that is taken falls back to a free one.
            let attempts = restoring ? 10 : 1
            for attempt in 1...attempts {
                do {
                    let net = try VmnetNetwork(subnet: cidr)
                    SubnetPool.reserve(net.subnet.description)
                    return net
                } catch {
                    if attempt == attempts { note("subnet \(persistedSubnet) unavailable (\(error.localizedDescription)); using a new one") }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }
        let net = try SubnetPool.makeNetwork()
        note("network: vmnet subnet \(net.subnet.description) (picked automatically — free on this Mac)")
        return net
    }

    deinit {
        if let n = network { SubnetPool.release(n.subnet.description) }
    }

    /// 594: what every boot of this store needs before any image — the pinned kernel (downloaded and
    /// verified into the cache once) and the guest init disk (vminit, pulled and built once) — as
    /// timed steps with the download's progress in the event stream. Onboarding runs it ahead of
    /// the first start. Never touches this sandbox's own VM or disks.
    public func prepareAssets() async throws {
        let broadcaster = self.broadcaster
        // ONE timed step, whatever the provider does (a preparation counts its steps — 594); what it did
        // inside (cached and verified, copied from a seed, downloaded and extracted) is said as notes,
        // and a download's progress passes through.
        let cachedKernel = FileManager.default.fileExists(atPath: kernelProvider.cachedKernel.path)
        // 594 W7: say where it came from — a copy of Apple's container kernel is not a download.
        let how = spec.kernelPath != nil ? ", explicit" : cachedKernel ? ", cached"
            : kernelProvider.localSeed() != nil ? ": copied from Apple's container kernels (byte-identical to the pin)" : ": downloaded"
        let kernelURL = try await timed("kernel ready (\(KernelArtifact.recommended.fileName)\(how))") {
            try await kernelProvider.resolve(override: spec.kernelPath) { e in
                switch e {
                case .step(let s, let ms): broadcaster.yield(.note(String(format: "%@ — %.0f ms", s, ms)))
                case .note(let s): broadcaster.yield(.note(s))
                case .progress(let s, let done, let total): broadcaster.yield(.progress(s, completedBytes: done, totalBytes: total))
                }
            }
        }
        let kernel = Kernel(path: kernelURL, platform: .linuxArm)
        let store = try ImageStore(path: spec.storeRoot)
        // The init image itself is fetched by ContainerManager even when its disk exists — silently and
        // for every platform. Pull it here first (linux/arm64, metered) so the manager finds it;
        // "cached" only when both the image and its disk are there.
        let reference = spec.initfsReference
        let haveImage = (try? await store.get(reference: reference)) != nil
        let cached = haveImage && FileManager.default.fileExists(atPath: layout.initfs.path)
        try await timed("guest init image ready (vminit\(cached ? ", cached" : haveImage ? ": built its disk" : ": pulled + built its disk"))") {
            if !haveImage {
                _ = try await ImageBaker.pull(reference, store: store, label: "pulling the guest init image") { broadcaster.yield($0) }
            }
            _ = try await ContainerManager(kernel: kernel, initfsReference: reference, imageStore: store)
        }
    }

    /// The baked disk for this sandbox's imageSpec — a cache hit, or a bake (timed events, progress in
    /// the event stream). nil for a sandbox without a imageSpec. Safe to call in any phase; it never
    /// touches this sandbox's own VM or disks.
    public func ensureImage() async throws -> BakedImage? {
        guard let imageSpec = spec.imageSpec else { return nil }
        guard let deckhold = DeckholdBinary.locate() else { throw SandboxError.deckholdMissing }
        let kernelURL = try await kernelProvider.resolve(override: spec.kernelPath)
        return try await ensureImage(imageSpec, kernel: Kernel(path: kernelURL, platform: .linuxArm), kernelURL: kernelURL, deckhold: deckhold)
    }

    private func ensureImage(_ imageSpec: ImageSpec, kernel: Kernel, kernelURL: URL, deckhold: URL) async throws -> BakedImage {
        let inputs = ImageBaker.BakeInputs(kernel: kernel, kernelSHA256: try KernelProvider.sha256(of: kernelURL),
                                           deckholdSHA256: try KernelProvider.sha256(of: deckhold),
                                           initfsReference: spec.initfsReference, dnsServers: spec.dnsServers,
                                           // A proxied sandbox's image is baked through the proxy too — registries only.
                                           // 596: plus the spec's own bake hosts (Claude Code's native build, pi's Node).
                                           egress: spec.isProxied ? NetworkPolicy.bake(adding: imageSpec.bakeHosts) : nil, egressLog: egress?.log)
        let broadcaster = self.broadcaster
        return try await ImageBaker(storeRoot: spec.storeRoot).ensure(imageSpec, inputs: inputs) { broadcaster.yield($0) }
    }

    /// One-time per store and package set: boot the image, install the packages, keep the disk.
    private func bake(image: Containerization.Image, kernel: Kernel, store: ImageStore, into golden: URL) async throws {
        let pkgs = spec.bakePackages
        note("no prepared disk yet — baking one\(pkgs.isEmpty ? "" : " (\(pkgs.joined(separator: ", ")))") (one-time, needs network)…")
        let t0 = ContinuousClock.now
        let proxy = try spec.isProxied ? EgressProxy(policy: .bake, ca: nil, log: egress?.log ?? ConnectionLog()) : nil
        let bakeNet = spec.networking ? try SubnetPool.makeNetwork() : nil
        defer { if let bakeNet { SubnetPool.release(bakeNet.subnet.description) } }
        var mgr = try await ContainerManager(kernel: kernel, initfsReference: spec.initfsReference, imageStore: store,
                                             network: bakeNet)
        let id = layout.bakeContainerID
        try? mgr.delete(id)
        let spec = self.spec
        // 587: flattened here (not by the package) so the disk gets `spec.journalMiB`'s journal.
        let bakeDir = spec.storeRoot.appendingPathComponent("containers/\(id)")
        try? FileManager.default.removeItem(at: bakeDir)
        try FileManager.default.createDirectory(at: bakeDir, withIntermediateDirectories: true)
        let bakeDisk = bakeDir.appendingPathComponent("rootfs.ext4")
        try await timed("flattened \(spec.image) to one ext4 disk (\(spec.rootfsMiB) MiB\(spec.journalMiB.map { ", \($0) MiB journal" } ?? ", no journal"))") {
            _ = try await EXT4Unpacker(capacityInBytes: spec.rootfsMiB * 1_048_576, journal: ImageSpec.journalConfig(spec.journalMiB))
                .unpack(image, for: .current, at: bakeDisk)
        }
        let b = try await mgr.create(id, image: image, rootfs: .block(format: "ext4", source: bakeDisk.path, destination: "/"),
                                     networking: spec.networking,
                                     vm: VMResources(cpus: spec.cpus, memoryInBytes: spec.memoryMiB * 1_048_576 + VMResources.guestMemoryOverhead)) { cfg in
            cfg.cpus = spec.cpus
            cfg.memoryInBytes = spec.memoryMiB * 1_048_576
            cfg.process.arguments = ["sleep", "infinity"]
            cfg.dns = DNS(nameservers: proxy != nil ? ["127.0.0.1"] : spec.dnsServers)
        }
        do {
            try await b.create()
            try await b.start()
            if let proxy {
                try await b.withVirtualMachineInstance { i in
                    guard let v = vzInstance(of: i) else { throw SandboxError.vmUnavailable }
                    try proxy.listen(on: v)
                }
                try await Self.startEgressShim(on: b, caFile: nil)
            }
            defer { proxy?.stopListening() }
            if !pkgs.isEmpty {
                let r = try await Self.exec(on: b, ["sh", "-c", "apk add --no-cache \(pkgs.joined(separator: " ")) >/dev/null && sync"],
                                            environment: proxy?.guestEnvironment ?? [:], workingDirectory: "/", privileged: false, timeout: 300)
                guard r.exitCode == 0 else {
                    throw SandboxError.commandFailed(command: "apk add \(pkgs.joined(separator: " "))", exitCode: r.exitCode, output: r.output + r.errorOutput)
                }
            }
            try await trimBakeDisk(b, disk: bakeDisk)
        } catch {
            try? await b.stop()
            try? mgr.delete(id)
            throw error
        }
        try FileManager.default.createDirectory(at: layout.goldenDirectory, withIntermediateDirectories: true)
        let tmp = golden.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.copyItem(at: spec.storeRoot.appendingPathComponent("containers/\(id)/rootfs.ext4"), to: tmp)
        try FileManager.default.moveItem(at: tmp, to: golden)
        try? mgr.delete(id)
        note(String(format: "prepared disk baked and kept at golden/%@ — %.1f s (never again for this store)",
                    golden.lastPathComponent, seconds(since: t0)))
    }

    /// 587: `fstrim /` as a bake's last step (586: −11 % for 56 ms), then the clean stop — timed with
    /// what it returned.
    private func trimBakeDisk(_ c: LinuxContainer, disk: URL) async throws {
        let t0 = ContinuousClock.now
        let before = try await ImageBaker.settledAllocation(c, disk)
        let r = try await Self.exec(on: c, ["sh", "-c", GuestCommand.trimRoot], environment: [:], workingDirectory: "/",
                                    privileged: true, timeout: 120)
        try await c.stop()
        let (_, after) = ImageBaker.sizes(disk)
        broadcaster.yield(.step(String(format: "trimmed the disk (fstrim /): %d → %d MiB allocated — %@", ImageBaker.mib(before), ImageBaker.mib(after),
                                       r.output.trimmingCharacters(in: .whitespacesAndNewlines)), milliseconds: milliseconds(since: t0)))
    }

    // MARK: network (580)

    /// (Re)register the proxy's vsock listener on the current VM. A VM stop drops host vsock
    /// listeners, so this runs after every boot, restore and wake.
    private func listenForEgress() throws {
        guard let egress, let instance, let v = vzInstance(of: instance) else { return }
        try egress.listen(on: v)
        // 599d (G4): the forwarded SSH agent's listener, while it is on.
        if let relay = sshRelayBox.withLock({ $0 }) { try? relay.listen(on: v) }
    }

    // MARK: 599d — GitHub as the user

    /// The user's GitHub setup in the guest (identity + helper config, or none), applied at every fresh
    /// boot and wake (`guestFixes`); `applyGitHubToGuest` applies it to a running guest at once.
    public nonisolated var gitSetup: GitGuestSetup { gitSetupBox.withLock { $0 } }
    public nonisolated func setGitSetup(_ s: GitGuestSetup) { gitSetupBox.withLock { $0 = s } }
    private nonisolated let gitSetupBox = LockedBox<GitGuestSetup>(.off)

    // MARK: 599h — the tools layer

    /// What the tools layer follows (the host sets it from the settings), and where gh comes from on the Mac
    /// (the host's `ToolsCache` — it downloads once; nil: gh cannot be had).
    /// nil (the default): no tools layer — an image's preparation VM, a helper; the host sets it for every
    /// sandbox it manages, so a baked image never carries what the layer adds.
    public nonisolated var toolInputs: ToolInputs? { toolInputsBox.withLock { $0 } }
    public nonisolated func setToolInputs(_ i: ToolInputs?) { toolInputsBox.withLock { $0 = i } }
    private nonisolated let toolInputsBox = LockedBox<ToolInputs?>(nil)
    public typealias GhFetcher = @Sendable () async -> Result<URL, CheckFailure>
    public nonisolated func setGhFetcher(_ f: GhFetcher?) { ghFetcherBox.withLock { $0 = f } }
    private nonisolated let ghFetcherBox = LockedBox<GhFetcher?>(nil)
    /// The last apply of the layer (nil until one ran in this process).
    public nonisolated var lastToolsReport: ToolsReport? { toolsReportBox.withLock { $0 } }
    private nonisolated let toolsReportBox = LockedBox<ToolsReport?>(nil)

    /// Apply the tools layer to the running guest: check, copy gh in (from the Mac, never the guest's network),
    /// install what is missing (apt/apk through the proxy), remove what a setting turned off. `loud`: each tool
    /// as a step (the first apply in a sandbox, a retry); else quiet — one note, and the report says whether
    /// something changed or failed. Never throws.
    @discardableResult
    public func applyToolsNow(loud: Bool) async -> ToolsReport? {
        await acquire(); defer { release() }
        return await applyToolsLayer(loud: loud)
    }

    @discardableResult
    func applyToolsLayer(loud: Bool? = nil) async -> ToolsReport? {
        guard phase == .running, container != nil, let inputs = toolInputs else { return nil }
        let plan = ToolsLayer.plan(inputs)
        let t0 = ContinuousClock.now
        let state: ToolsLayer.GuestState
        do {
            let r = try await execInContainer(["sh", "-c", ToolsLayer.checkScript], privileged: true, timeout: 15)
            state = .parse(r.output)
        } catch {
            note("tools layer: could not look at the guest (\(error.localizedDescription)) — next start or wake")
            return nil
        }
        let shout = loud ?? state.first
        // gh: from the Mac's cache (downloaded once), copied in only when the guest's copy is another version.
        var ghCopied = false
        var ghProblem: String?
        if plan.items.contains(where: { $0.id == "gh" }), state.gh != ToolsLayer.ghVersion {
            if let fetch = ghFetcherBox.withLock({ $0 }) {
                let label = "tools: gh \(ToolsLayer.ghVersion) on this Mac (downloaded once, sha256 checked)"
                let ft = ContinuousClock.now
                if shout { broadcaster.yield(.stepStarted(label)) }
                switch await fetch() {
                case .success(let url):
                    if shout { broadcaster.yield(.step(label, milliseconds: milliseconds(since: ft))) }
                    do {
                        try await container!.copyIn(from: url, to: URL(fileURLWithPath: ToolsLayer.guestGhPath + ".tmp"), mode: 0o755)
                        ghCopied = true
                    } catch {
                        ghProblem = "could not copy gh into the guest: \(error.localizedDescription)"
                    }
                case .failure(let f):
                    if shout { broadcaster.yield(.stepFailed(label, milliseconds: milliseconds(since: ft), error: f.reason)) }
                    ghProblem = f.reason
                }
            } else {
                ghProblem = "no gh on this Mac for it"
            }
        }
        let script = ToolsLayer.applyScript(plan, state: state, ghCopied: ghCopied, ghProblem: ghProblem, audioApp: inputs.audioApp)
        let missing = ToolsLayer.missingPackages(plan, state)
        let installLabel = "tools: installing " + missing.map(\.title).joined(separator: ", ") + " with \(state.packageManager), through the proxy"
        if shout && !missing.isEmpty { broadcaster.yield(.stepStarted(installLabel)) }
        let it0 = ContinuousClock.now
        let out: String
        do {
            let r = try await execInContainer(["sh", "-c", script], privileged: true, timeout: missing.isEmpty ? 30 : 300)
            out = r.output
        } catch {
            out = ""
            note("tools layer: \(error.localizedDescription)")
        }
        if shout && !missing.isEmpty {
            let failedPkgs = missing.filter { item in !out.contains("doz-tool \(item.id) installed") }
            if failedPkgs.isEmpty { broadcaster.yield(.step(installLabel, milliseconds: milliseconds(since: it0))) }
            else { broadcaster.yield(.stepFailed(installLabel, milliseconds: milliseconds(since: it0), error: "not installed: " + failedPkgs.map(\.title).joined(separator: ", ") + " — see \(ToolsLayer.guestLog)")) }
        }
        let report = ToolsReport(results: ToolsLayer.results(out, plan: plan), first: state.first)
        toolsReportBox.withLock { $0 = report }
        let ms = milliseconds(since: t0)
        if shout {
            for r in report.results {
                if r.ok { broadcaster.yield(.step(ToolsLayer.label(r) + " (\(r.detail))", milliseconds: 0)) }
                else { broadcaster.yield(.stepFailed(ToolsLayer.label(r), milliseconds: 0, error: r.detail)) }
            }
            note(String(format: "tools layer: %@ (%.0f ms)", report.summary, ms))
        } else {
            note(String(format: "tools layer re-checked%@: %@ (%.0f ms)", report.changed || report.failed ? "" : " (no change)", report.summary, ms))
        }
        return report
    }

    /// The Mac's agent socket while the SSH agent is forwarded (nil: not forwarded).
    public nonisolated var sshAgentSocket: String? { sshRelayBox.withLock { $0?.agentSocket } }
    private nonisolated let sshRelayBox = LockedBox<SSHAgentRelay?>(nil)

    /// Forward the Mac's SSH agent at `socket` into the sandbox (nil: stop). A proxied sandbox only (the
    /// guest half is doznet). Applied at once to a running VM, and at every later boot and wake.
    public func setSSHAgent(socket: String?, onConnect: (@Sendable () -> Void)? = nil) async {
        guard let egress else { return }
        let old = sshRelayBox.withLock { r -> SSHAgentRelay? in
            let o = r
            r = socket.map { SSHAgentRelay(agentSocket: $0) }
            r?.onConnect = onConnect
            return o
        }
        old?.stop()
        egress.sshToGitHub = socket != nil
        guard phase == .running, let instance, let v = vzInstance(of: instance) else { return }
        if let relay = sshRelayBox.withLock({ $0 }) { try? relay.listen(on: v) }
        await applyGitHubToGuest()
    }

    /// Apply the GitHub setup and the SSH agent's guest half to the RUNNING guest now (best effort).
    public func applyGitHubToGuest() async {
        guard phase == .running else { return }
        let script = GuestCommand.gitCredentialInstall + "; " + GuestCommand.gitConfigScript(gitSetup)
            + "; " + GuestCommand.sshAgentScript(on: sshAgentSocket != nil)
        do {
            let r = try await execInContainer(["sh", "-c", script], privileged: true, timeout: 15)
            if r.exitCode != 0 { note("the GitHub setup exited \(r.exitCode): \(String((r.output + r.errorOutput).suffix(200)))") }
        } catch {
            note("could not apply the GitHub setup: \(error.localizedDescription)")
        }
    }

    /// Install and start the guest half of a proxied network in a freshly booted container: the
    /// shim, the CA certificate (optional — a bake needs none), and the trust-store setup.
    static func startEgressShim(on c: LinuxContainer, caFile: URL?) async throws {
        guard let shim = DoznetBinary.locate() else { throw SandboxError.invalidSpec("the doznet guest binary is missing from the resource bundle") }
        try await c.copyIn(from: shim, to: URL(fileURLWithPath: EgressProxy.guestShimPath), mode: 0o755)
        if let caFile {
            try await c.copyIn(from: caFile, to: URL(fileURLWithPath: EgressProxy.guestCAPath), mode: 0o644)
        }
        let r = try await exec(on: c, ["sh", "-c", EgressProxy.guestSetupScript(withCA: caFile != nil)], environment: [:],
                               workingDirectory: "/", privileged: true, timeout: 30)
        if r.exitCode != 0 { throw SandboxError.commandFailed(command: "start doznet", exitCode: r.exitCode, output: r.output + r.errorOutput) }
    }

    /// 594 W23: whether an image sandbox's user gets passwordless sudo — applied at every fresh boot
    /// (`GuestCommand.prepareGuest`). Default true (owner ruling 2026-09-30). A caller that wants it
    /// applied to a RUNNING guest runs `GuestCommand.agentSudoScript` itself (the host does, at each
    /// agent session start).
    public nonisolated var agentSudo: Bool { agentSudoFlag.value }
    public nonisolated func setAgentSudo(_ on: Bool) { agentSudoFlag.value = on }
    private nonisolated let agentSudoFlag = LockedFlag(true)

    /// 594 W10: the guest's time zone, written at every fresh boot and every wake (nil: left as the
    /// image has it — UTC). The host sets it from the Mac's zone or the setting.
    public nonisolated var timeZone: GuestTimeZone? { timeZoneBox.withLock { $0 } }
    public nonisolated func setTimeZone(_ tz: GuestTimeZone?) { timeZoneBox.withLock { $0 = tz } }
    private nonisolated let timeZoneBox = LockedBox<GuestTimeZone?>(nil)

    // MARK: 599g — workspace rules

    /// What `.dozignore` does in this sandbox's view (the host sets it from `workspace.ignore_mode`).
    public nonisolated var workspaceRuleMode: WorkspaceRuleMode { ruleModeBox.withLock { $0 } }
    public nonisolated func setWorkspaceRuleMode(_ m: WorkspaceRuleMode) { ruleModeBox.withLock { $0 = m } }
    private nonisolated let ruleModeBox = LockedBox<WorkspaceRuleMode>(.lock)

    /// The views running in the guest, by share tag (as the last boot, wake or session start found them).
    public nonisolated var activeViews: [String: WorkspaceViewConfig] { activeViewsBox.withLock { $0 } }
    private nonisolated let activeViewsBox = LockedBox<[String: WorkspaceViewConfig]>([:])
    private nonisolated func setActiveViews(_ v: [String: WorkspaceViewConfig]) { activeViewsBox.withLock { $0 = v } }
    /// The guest paths (e.g. /workspace) that are served through a view right now.
    public nonisolated var viewedGuestPaths: [String] { activeViews.values.map(\.guestPath).sorted() }

    /// Serve EVERY share through the view, a passthrough one where the folder has no rule file (BUG
    /// cwd-after-wake): a hibernation's re-mount detaches the raw share at its guest path and gives the
    /// fresh mount new node ids, so a program whose cwd was inside (Codex validates its cwd per turn) gets
    /// ENOENT from getcwd. The view is never re-mounted — its daemon lives in guest memory and re-opens its
    /// link to the share — so a cwd inside it survives. Default true; false = 599g's rule (views only with
    /// rule files).
    public nonisolated var passthroughViews: Bool {
        get { passthroughBox.withLock { $0 } }
        set { passthroughBox.withLock { $0 = newValue } }
    }
    private nonisolated let passthroughBox = LockedBox<Bool>(true)

    /// 608: the guest paths whose PASSTHROUGH view could not start this boot — served as the plain share
    /// instead (the host's `SandboxInfo.workspaceView` = "fallback", and doctor warns). Cleared at a fresh boot.
    public nonisolated var viewFallbacks: Set<String> { fallbackBox.withLock { $0 } }
    private nonisolated let fallbackBox = LockedBox<Set<String>>([])

    /// The views the host wants now: every share whose Mac folder holds a rule file (two `stat`s each), and
    /// — `includePassthrough` and `passthroughViews` — every other share as a passthrough view.
    nonisolated func wantedViews(shareTags: [String: String], includePassthrough: Bool = true) -> [String: WorkspaceViewConfig] {
        var out: [String: WorkspaceViewConfig] = [:]
        for share in spec.shares {
            guard let tag = shareTags[share.guestPath] else { continue }
            let folder = URL(fileURLWithPath: share.hostPath)
            let rules = WorkspaceRules.present(in: folder)
            guard rules || (includePassthrough && passthroughViews) else { continue }
            out[tag] = WorkspaceViewConfig(tag: tag, guestPath: share.guestPath, mode: workspaceRuleMode,
                                           fold: WorkspaceRules.caseInsensitive(folder), passthrough: !rules)
        }
        return out
    }

    /// 610: a wake brings THIS build's deckhold to the guest's disk. deckhold is copied in at every fresh boot only, so
    /// a sandbox that slept under an older doz kept that doz's holder for every session opened after the wake, until a
    /// shutdown — and a deckhold fix (610's snapshot) reached it only then. A session's RUNNING holder is a process
    /// in the guest's memory: it keeps its own binary (the rename leaves its file alone) until the session restarts
    /// (`doz sessions restart`) or ends. Best effort: a wake never fails for it; nothing runs when the guest's
    /// deckhold is already this one (one sha256sum).
    private func refreshDeckhold() async {
        guard container != nil, let bin = DeckholdBinary.locate(), let want = Self.digest(bin) else { return }
        do {
            let have = try await execInContainer(["sh", "-c", GuestCommand.deckholdDigestScript], privileged: true, timeout: 10)
            guard have.output.trimmingCharacters(in: .whitespacesAndNewlines) != want else { return }
            // Through an exec's stdin, not copyIn: copyIn needs vminitd's own agent, and a VM a NEW host restored (an
            // upgrade's first wake — exactly when this matters) is adopted through AdoptingAgent.
            let data = try Data(contentsOf: bin)
            let staged = try await Self.exec(on: container!, ["sh", "-c", "umask 022; cat > \(GuestCommand.deckholdStagingPath)"], environment: [:],
                                             workingDirectory: "/", privileged: true, timeout: 30, stdin: data)
            guard staged.exitCode == 0 else { throw SandboxError.commandFailed(command: "stage deckhold", exitCode: staged.exitCode, output: staged.output + staged.errorOutput) }
            let r = try await execInContainer(["sh", "-c", GuestCommand.refreshDeckholdScript(sha256: want)], privileged: true, timeout: 10)
            note(r.output.contains("deckhold=updated")
                 ? "updated deckhold (the guest's session holder) to this build's — sessions opened from now on use it; a running session keeps its own until it restarts"
                 : "could not update deckhold in the guest (\(String((r.output + r.errorOutput).suffix(120)))) — the wake goes on")
        } catch {
            note("could not update deckhold in the guest: \(error.localizedDescription) — the wake goes on")
        }
    }

    /// The sha256 of a local file, hex (~5 ms for deckhold's 1.6 MB — once per wake).
    public static func digest(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func copyViewBinary() async {
        guard let container else { return }
        guard let bin = DozviewBinary.locate() else { note("workspace rules: the dozview guest binary is missing from the resource bundle"); return }
        do { try await container.copyIn(from: bin, to: URL(fileURLWithPath: WorkspaceView.binaryGuestPath), mode: 0o755) }
        catch { note("workspace rules: could not copy the view into the guest: \(error.localizedDescription)") }
    }

    /// Copy the daemon in and turn the views on (a fresh boot, or a share that gained a rule file).
    private func startViews(_ views: [String: WorkspaceViewConfig], on c: LinuxContainer, quiet: Bool) async {
        guard let bin = DozviewBinary.locate() else {
            note("workspace rules: the dozview guest binary is missing from the resource bundle — the shares are served without their rules")
            return
        }
        let label = views.values.sorted { $0.guestPath < $1.guestPath }
            .map { $0.isPassthrough ? "\($0.guestPath) (no rules)" : "\($0.guestPath) (\($0.mode.rawValue)\($0.fold ? ", case-insensitive" : ""))" }.joined(separator: ", ")
        let work: () async throws -> String = {
            try await c.copyIn(from: bin, to: URL(fileURLWithPath: WorkspaceView.binaryGuestPath), mode: 0o755)
            let script = views.values.sorted { $0.guestPath < $1.guestPath }.map(WorkspaceView.startScript).joined(separator: "; ")
            let r = try await Self.exec(on: c, ["sh", "-c", script], environment: [:], workingDirectory: "/", privileged: true, timeout: 30)
            return r.output + r.errorOutput
        }
        do {
            let title = views.values.allSatisfy(\.isPassthrough)
                ? "workspace: \(views.values.map(\.guestPath).sorted().joined(separator: ", ")) through the live view (programs there keep their folder across a wake)"
                : "workspace rules: \(label) served through the view"
            let out = quiet ? try await work() : try await timed(title, work)
            recordViewStatus(out, wanted: views, guestPaths: [:])
        } catch {
            note("workspace rules: the view could not start: \(error.localizedDescription)")
        }
    }

    /// Fold a script's `doz-view` lines into `activeViews`; a failure is said.
    private func recordViewStatus(_ output: String, wanted: [String: WorkspaceViewConfig], guestPaths: [String: String]) {
        var active = activeViews
        for st in WorkspaceView.parse(output) {
            switch st.state {
            case .running, .started, .restarted:
                let gp = wanted[st.tag]?.guestPath ?? active[st.tag]?.guestPath ?? guestPaths[st.tag] ?? "?"
                active[st.tag] = wanted[st.tag] ?? active[st.tag] ?? WorkspaceViewConfig(tag: st.tag, guestPath: gp, mode: workspaceRuleMode, fold: true)
                fallbackBox.withLock { _ = $0.remove(gp) }
                if st.state == .restarted { note("workspace rules: the view of \(gp) was not running — started it again") }
            case .failed:
                let gp = wanted[st.tag]?.guestPath ?? guestPaths[st.tag] ?? st.tag
                active[st.tag] = nil
                if wanted[st.tag]?.isPassthrough == true {
                    fallbackBox.withLock { _ = $0.insert(gp) }
                    note("workspace: the view of \(gp) could not start — \(gp) is the share as it is (a program inside loses its directory at a hibernation)")
                } else {
                    note("workspace rules: the view of \(gp) could not start — \(gp) is EMPTY in the sandbox until it does (the next wake or start tries again)")
                }
            case .off:
                active[st.tag] = nil
            }
        }
        setActiveViews(active)
    }

    /// At a session start (the host's open-session): a share that gained a rule file gets its view now, and
    /// a changed mode reaches a running view. Nothing runs in the guest when nothing changed. Never throws.
    public func refreshWorkspaceViews() async {
        await acquire(); defer { release() }
        guard phase == .running, let c = container else { return }
        let wanted = wantedViews(shareTags: identity?.shareTags ?? [:])
        let active = activeViews
        // A passthrough view is started only at a fresh boot or a hibernation's wake (where the raw share's
        // cwds are cut anyway) — never live under a running program, whose cwd it would cut.
        let new = wanted.filter { active[$0.key] == nil && !$0.value.isPassthrough }
        if !new.isEmpty {
            note("workspace rules: a rule file appeared — serving \(new.values.map(\.guestPath).sorted().joined(separator: ", ")) through the view (a program already inside keeps what it has open until it changes directory)")
            await startViews(new, on: c, quiet: true)
        }
        for (tag, w) in wanted where active[tag] != nil && active[tag] != w {
            if let r = try? await Self.exec(on: c, ["sh", "-c", WorkspaceView.reloadScript(w)], environment: [:], workingDirectory: "/",
                                             privileged: true, timeout: 15) {
                recordViewStatus(r.output, wanted: [tag: w], guestPaths: [:])
            }
        }
    }

    /// What the guest says about each share's view, and its daemon's state (`doz ignore show`).
    public func workspaceViewReport() async -> [(status: WorkspaceViewStatus, state: [String: String])] {
        guard phase == .running, let c = container else { return [] }
        let tags = (identity?.shareTags ?? [:]).values.sorted()
        guard !tags.isEmpty, let r = try? await Self.exec(on: c, ["sh", "-c", WorkspaceView.statusScript(tags)], environment: [:],
                                                          workingDirectory: "/", privileged: true, timeout: 15) else { return [] }
        return WorkspaceView.parse(r.output).map { ($0, WorkspaceView.parseState(r.output, tag: $0.tag)) }
    }

    /// The guest path a share tag is mounted at.
    public func guestPath(ofTag tag: String) -> String? { identity?.shareTags.first { $0.value == tag }?.key }

    final class LockedBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var v: T
        init(_ v: T) { self.v = v }
        func withLock<R>(_ f: (inout T) -> R) -> R { lock.withLock { f(&v) } }
    }

    final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var v: Bool
        init(_ v: Bool) { self.v = v }
        var value: Bool {
            get { lock.withLock { v } }
            set { lock.withLock { v = newValue } }
        }
    }

    /// Change the running (or next) policy of a proxied sandbox.
    public nonisolated func setNetworkPolicy(_ policy: NetworkPolicy) {
        egress?.policy = policy
    }

    /// Give the proxy a secret for `binding` (memory only; never written to disk, never sent into
    /// the guest). Sessions started from now on get a fresh placeholder in the binding's variable.
    public nonisolated func setCredential(_ binding: CredentialBinding, secret: String?) {
        egress?.vault.set(binding, secret: secret)
    }

    /// 588: a secret with its expiry, the non-secret variables a session gets beside its
    /// placeholder, and — without a secret — why (the proxy's 401 text).
    public nonisolated func setCredential(_ binding: CredentialBinding, secret: String?, expiresAt: Date?,
                                          environment: [String: String], notice: String?) {
        egress?.vault.set(binding, secret: secret, expiresAt: expiresAt, environment: environment, notice: notice)
    }

    /// The environment a proxied sandbox's command gets: the proxy + CA variables, then the
    /// caller's (which win) — except that a real credential in a bound variable is moved into the
    /// vault and replaced by a placeholder, so it never reaches the guest.
    nonisolated func guestEnvironment(_ caller: [String: String], placeholders: Bool) -> [String: String] {
        guard let egress else { return caller }
        var env = egress.guestEnvironment
        var callerEnv = caller
        for b in egress.vault.allBindings where b.swapOnly != true {
            guard let v = b.environmentVariable, let value = callerEnv[v], !value.isEmpty,
                  !value.hasPrefix(CredentialVault.placeholderPrefix) else { continue }
            egress.vault.set(b, secret: value)
            callerEnv[v] = egress.vault.mint(b.id)          // the guest sees a placeholder, never the key
        }
        if placeholders {
            // 599d: a binding read on use (GitHub) issues placeholders too; one token in every variable it names.
            for b in egress.vault.allBindings where egress.vault.issuesPlaceholder(b.id) {
                if !b.placeholderVariables.isEmpty, let t = egress.vault.mint(b.id) { for v in b.placeholderVariables { env[v] = t } }
                env.merge(egress.vault.sessionExtras(b.id)) { a, _ in a }
            }
            // 599d (G4): the forwarded SSH agent's socket, while it is on.
            if sshAgentSocket != nil { env["SSH_AUTH_SOCK"] = GuestCommand.sshAgentGuestSocket }
        }
        env.merge(callerEnv) { _, caller in caller }
        return env
    }

    // MARK: guest commands

    /// Run `argv` in the guest (no shell unless you pass one) and collect its output.
    public func exec(_ argv: [String], environment: [String: String] = [:], workingDirectory: String = "/",
                     privileged: Bool = false, user: String? = nil, timeoutSeconds: Int64 = 120) async throws -> ExecResult {
        guard phase == .running else { throw SandboxError.notRunning(phase) }
        return try await execInContainer(argv, environment: guestEnvironment(environment, placeholders: true), workingDirectory: workingDirectory,
                                         privileged: privileged, timeout: timeoutSeconds, user: user)
    }

    private func execInContainer(_ argv: [String], environment: [String: String] = [:], workingDirectory: String = "/",
                                 privileged: Bool = false, timeout: Int64, user: String? = nil) async throws -> ExecResult {
        guard let container else { throw SandboxError.vmUnavailable }
        return try await Self.exec(on: container, argv, environment: environment, workingDirectory: workingDirectory,
                                   privileged: privileged, timeout: timeout, user: user)
    }

    static func exec(on container: LinuxContainer, _ argv: [String], environment: [String: String],
                     workingDirectory: String, privileged: Bool, timeout: Int64, user: String? = nil,
                     onOutput: (@Sendable (Data) -> Void)? = nil, stdin: Data? = nil) async throws -> ExecResult {
        let out = OutputCollector(onData: onOutput), err = OutputCollector(onData: onOutput)
        // 610: bytes for the program's stdin, then EOF (what copyIn cannot do in a VM a new host adopted).
        let input: AsyncStream<Data>? = stdin.map { bytes in
            let (stream, cont) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
            var at = 0
            while at < bytes.count { let end = min(at + 65_536, bytes.count); cont.yield(bytes.subdata(in: at..<end)); at = end }
            cont.finish()
            return stream
        }
        let p = try await container.exec("x-\(UUID().uuidString.prefix(12).lowercased())") { cfg in
            cfg.arguments = argv
            if let input { cfg.stdin = ConnectionReader(source: input) }
            cfg.environmentVariables = GuestCommand.environment(environment)
            cfg.workingDirectory = workingDirectory
            cfg.stdout = out
            cfg.stderr = err
            if let user, user != "root" { cfg.user = .init(username: user) }
            if privileged { cfg.capabilities = .allCapabilities }
        }
        // Every exec is deleted, whatever happens: deletion is what closes its vminitd client.
        do {
            try await p.start()
            let st = try await p.wait(timeoutInSeconds: timeout)
            try? await p.delete()
            return ExecResult(exitCode: st.exitCode, stdout: out.data, stderr: err.data)
        } catch {
            try? await p.delete()
            throw error
        }
    }

    /// Copy a host file onto the guest's root disk (e.g. a program a session will run). Prefer
    /// this to running a program straight from a share: a share is re-mounted on every wake, and
    /// a file a process had open across that is gone from under it.
    public func copyIn(_ source: URL, to guestPath: String, mode: UInt32 = 0o644) async throws {
        guard phase == .running, let container else { throw SandboxError.notRunning(phase) }
        try await container.copyIn(from: source, to: URL(fileURLWithPath: guestPath), mode: mode)
    }

    // MARK: sessions

    /// Start `argv` (NOT through a shell — see `GuestCommand`) as the guest session `name`, held
    /// by deckhold at `size`. Returns once the session's socket is listening.
    ///
    /// In an image sandbox the session runs as the imageSpec's user (pass `user: "root"` to override),
    /// in its `workdir`, with its `sessionEnvironment` — and `environment` on top: this is where a
    /// credential such as `ANTHROPIC_API_KEY` goes. It reaches the program's environment only; it
    /// is never written to any disk by this library.
    public func openSession(_ name: String, argv: [String], environment: [String: String] = [:],
                            workingDirectory: String? = nil, user: String? = nil, size: TermSize = .standard,
                            scrollbackBytes: Int? = nil) async throws {
        try GuestCommand.validateSessionName(name)
        precondition(!argv.isEmpty, "a session needs a program")
        let (env, cwd, runAs) = Self.sessionContext(imageSpec: spec.imageSpec, environment: guestEnvironment(environment, placeholders: true),
                                                    workingDirectory: workingDirectory, user: user)
        guard phase == .running else { throw SandboxError.notRunning(phase) }
        let r = try await execInContainer(GuestCommand.serve(name: name, size: size, argv: argv, scrollbackBytes: scrollbackBytes),
                                          environment: env, workingDirectory: cwd, privileged: false, timeout: 30, user: runAs)
        guard r.exitCode == 0 else {
            throw SandboxError.commandFailed(command: "open session \(name)", exitCode: r.exitCode, output: r.output + r.errorOutput)
        }
        lastSessionStart = ContinuousClock.now
        note("opened session \(name)\(runAs.map { " as \($0)" } ?? ""): \(argv.joined(separator: " "))")
    }

    /// Whether a session started with `program` (as `openSession` would: its environment, working
    /// directory and user) would find it — `command -v` in the guest. nil: the guest could not be asked.
    /// Returns the user it would run as (nil = root) beside the answer.
    public func sessionFinds(_ program: String, environment: [String: String] = [:], workingDirectory: String? = nil,
                             user: String? = nil) async -> (found: Bool, runsAs: String?)? {
        // Only PATH decides: no credential is moved or placeholder minted for a lookup.
        let (env, cwd, runAs) = Self.sessionContext(imageSpec: spec.imageSpec, environment: environment.filter { $0.key == "PATH" },
                                                    workingDirectory: workingDirectory, user: user)
        guard phase == .running,
              let r = try? await execInContainer(["sh", "-c", "command -v \"$1\" >/dev/null 2>&1", "sh", program],
                                                 environment: env, workingDirectory: cwd, privileged: false, timeout: 10, user: runAs)
        else { return nil }
        return (r.exitCode == 0, runAs)
    }

    /// The environment, working directory and user a session runs with (see `openSession`).
    static func sessionContext(imageSpec: ImageSpec?, environment: [String: String], workingDirectory: String?,
                               user: String?) -> (environment: [String: String], workingDirectory: String, user: String?) {
        // 599 (594.B2): the browser bridge's xdg-open first on every session's PATH, and $BROWSER — unless
        // the caller gave its own.
        let bridge = [GuestCommand.openShimDirectory, GuestCommand.openShimPath]
        guard let r = imageSpec else {
            var env = environment
            if env["PATH"] == nil { env["PATH"] = bridge[0] + ":" + GuestCommand.path }
            if env["BROWSER"] == nil { env["BROWSER"] = bridge[1] }
            return (env, workingDirectory ?? "/root", user)
        }
        let runAs = user ?? r.user
        var env = r.sessionEnvironment
        if let p = env["PATH"] { env["PATH"] = GuestCommand.withOpenShim(withGames(p)) }
        env["BROWSER"] = bridge[1]
        if runAs == r.user { env["HOME"] = r.home; env["USER"] = r.user }
        env.merge(environment) { _, caller in caller }
        return (env, workingDirectory ?? r.workdir, runAs == "root" ? nil : runAs)
    }

    /// 594 W30: apt puts some programs in /usr/games (cowsay, fortune): a session's PATH has it, after
    /// /usr/bin — added at session time, so no image is rebuilt for it. Idempotent.
    public static func withGames(_ path: String) -> String {
        let parts = path.split(separator: ":").map(String.init)
        guard !parts.contains("/usr/games") else { return path }
        var out = parts
        let at = (out.firstIndex(of: "/bin") ?? out.firstIndex(of: "/usr/bin")).map { $0 + 1 } ?? out.count
        out.insert("/usr/games", at: at)
        return out.joined(separator: ":")
    }

    /// Attach a viewer to session `name` at `size`. The first output is the session's current
    /// screen (a SNAPSHOT), then live output. See `SessionConnection`.
    public func attach(_ name: String, size: TermSize) async throws -> SessionConnection {
        try await connect(name, SessionConnection(session: name, size: size))
    }

    /// 612: watch session `name`'s program status (OSC 7501, as deckhold keeps it): the connection's output is
    /// `.status` — now, then at each change — and one final `ended`/`detached`, like a viewer's. It is not a
    /// viewer (no size, no screen, no keys) and, like a viewer, is detached when the sandbox sleeps or stops.
    public func watchStatus(_ name: String) async throws -> SessionConnection {
        try await connect(name, SessionConnection(statusOf: name))
    }

    private func connect(_ name: String, _ conn: SessionConnection) async throws -> SessionConnection {
        try GuestCommand.validateSessionName(name)
        guard phase == .running, let container else { throw SandboxError.notRunning(phase) }
        conn.setOnClose { [weak self] c in
            Task { await self?.forget(c) }
        }
        let proc = try await container.exec("a-\(UUID().uuidString.prefix(12).lowercased())") { cfg in
            cfg.arguments = GuestCommand.pipe(name: name)
            cfg.environmentVariables = GuestCommand.environment()
            cfg.terminal = false
            cfg.stdin = ConnectionReader(source: conn.input)
            cfg.stdout = ConnectionWriter(connection: conn)
            cfg.stderr = OutputCollector()
        }
        do { try await proc.start() } catch {
            conn.detach(.transportLost)
            try? await proc.delete()
            throw error
        }
        if !conn.isClosed { connections[conn.id] = conn }
        Task.detached {
            // The pipe exits when the holder closes it (after EXIT), when its stdin closes (the
            // viewer detached), or when the VM stops under it. By the time wait() returns, all
            // of its stdout has been delivered, so an EXIT frame has already ended the
            // connection; anything else is a lost transport.
            _ = try? await proc.wait()
            conn.detach(.transportLost)
            try? await proc.delete()
        }
        return conn
    }

    private func forget(_ c: SessionConnection) { connections.removeValue(forKey: c.id) }

    /// 599: run `argv` (as root, no terminal) with its stdin and stdout as a byte stream — the browser
    /// bridge's `deckhold connect -p PORT`. The stream's `output` finishes when the program exits (or
    /// the VM stops under it); `finishInput()` closes its stdin.
    public func openGuestStream(_ argv: [String]) async throws -> GuestStream {
        guard phase == .running, let container else { throw SandboxError.notRunning(phase) }
        let stream = GuestStream()
        let proc = try await container.exec("g-\(UUID().uuidString.prefix(12).lowercased())") { cfg in
            cfg.arguments = argv
            cfg.environmentVariables = GuestCommand.environment()
            cfg.terminal = false
            cfg.stdin = ConnectionReader(source: stream.input)
            cfg.stdout = GuestStreamWriter(stream: stream)
            cfg.stderr = OutputCollector()
        }
        do { try await proc.start() } catch {
            stream.ended(nil)
            try? await proc.delete()
            throw error
        }
        Task.detached {
            let code = try? await proc.wait().exitCode
            stream.ended(code)
            try? await proc.delete()
        }
        return stream
    }

    /// The guest's sessions (`deckhold ls`), live and ended.
    /// 608: how `endSession` ended a session's program.
    public enum SessionEnd: String, Codable, Sendable {
        case hangup, terminate, kill
        /// It was not running (ended already, or never opened).
        case notRunning = "not-running"
        /// Even SIGKILL did not end it within the time (a process stuck in the kernel).
        case stuck
    }

    /// 608: end session `name`'s program (its process group: HUP, then TERM, then KILL — `GuestCommand.endSession`).
    /// Viewers get the program's EXIT, as when it exits by itself. Running sandboxes only — ending a program
    /// is never a reason to wake one.
    public func endSession(_ name: String) async throws -> SessionEnd {
        try GuestCommand.validateSessionName(name)
        guard phase == .running else { throw SandboxError.notRunning(phase) }
        let r = try await execInContainer(["sh", "-c", GuestCommand.endSession(name: name)], privileged: true, timeout: 20)
        let word = r.output.split(separator: "\n").last { $0.hasPrefix("doz-end ") }.map { String($0.dropFirst(8)) }
        guard let w = word, let how = SessionEnd(rawValue: w.trimmingCharacters(in: .whitespaces)) else {
            throw SandboxError.commandFailed(command: "end session \(name)", exitCode: r.exitCode, output: r.output + r.errorOutput)
        }
        note("session \(name): " + (how == .notRunning ? "was not running" : how == .stuck ? "did NOT end (stuck)" : "ended (\(how.rawValue))"))
        return how
    }

    public func sessions() async throws -> [SessionInfo] {
        let r = try await exec(GuestCommand.list(), timeoutSeconds: 15)
        return SessionInfo.parseList(r.output)
    }

    /// The holder's model of session `name`'s active screen as plain text, plus a final
    /// `cursor=X,Y size=CxR screen=…` line (`deckhold dump`) — for tests and diagnostics.
    public func screenText(_ name: String) async throws -> String {
        try GuestCommand.validateSessionName(name)
        return try await exec(GuestCommand.dump(name: name), timeoutSeconds: 15).output
    }

    // MARK: saved screens (593 §9)

    /// Save every session's screen now (`SavedScreens`) — the periodic capture: only while running and
    /// not busy, serialised with the lifecycle; with `changedOnly`, only sessions that wrote something
    /// since their last saved screen. Never throws: a session that cannot be captured keeps its file.
    public func captureScreens(changedOnly: Bool, reason: String = "periodic") async -> ScreenCaptureReport? {
        await acquire(); defer { release() }
        guard phase == .running, !busy else { return nil }
        return await captureScreensLocked(reason: reason, changedOnly: changedOnly)
    }

    /// The saved screens (read from the sandbox's directory — any phase, no guest involved).
    public nonisolated func savedScreens() -> [SavedScreenInfo] { SavedScreens.list(layout) }

    /// List the guest's sessions, then attach to each for a moment: its SNAPSHOT (VT) and DUMP (text).
    /// Bounded per session and in all; a failure is logged and keeps the previous file. A saved screen
    /// of a session the guest no longer runs — gone, or its program exited — is removed (593, owner
    /// 2026-09-30: only live sessions have a saved screen).
    func captureScreensLocked(reason: String, changedOnly: Bool) async -> ScreenCaptureReport {
        var report = ScreenCaptureReport()
        let t0 = ContinuousClock.now
        guard phase == .running, let container else { return report }
        let deadline = t0 + .milliseconds(Int(SavedScreens.totalBudgetSeconds * 1000))
        let list: [SessionInfo]
        do {
            let r = try await execInContainer(GuestCommand.list(), timeout: SavedScreens.perSessionTimeoutSeconds)
            list = SessionInfo.parseList(r.output)
        } catch {
            note("saved screens: could not list the sessions (\(error.localizedDescription)) — the last saved screens are kept")
            return report
        }
        let saved = Dictionary(SavedScreens.list(layout).map { ($0.session, $0) }, uniquingKeysWith: { a, _ in a })
        report.removed = SavedScreens.remove(layout, keeping: Set(list.filter { !$0.isEnded }.map(\.name)))
        report.ended = list.filter(\.isEnded).map(\.name)
        for s in list.filter({ !$0.isEnded }).prefix(SavedScreens.maximumSessions) {
            if changedOnly, let i = saved[s.name], i.bytesOut == s.bytesOut {
                report.unchanged.append(s.name)
                continue
            }
            guard ContinuousClock.now < deadline else { report.failed.append(s.name); continue }
            do {
                guard let shot = try await Self.captureScreen(on: container, session: s.name,
                                                              timeout: SavedScreens.perSessionTimeoutSeconds) else {
                    report.failed.append(s.name)
                    continue
                }
                if shot.exitCode != nil {
                    // It ended between the listing and the attach: no live session, no saved screen.
                    SavedScreens.remove(layout, keeping: Set(SavedScreens.list(layout).map(\.session)).subtracting([s.name]))
                    report.ended.append(s.name)
                    continue
                }
                let d = SavedScreens.parseDump(shot.dump)
                let info = SavedScreenInfo(session: s.name, savedAt: Date(), reason: reason, cols: d.cols ?? s.size?.cols,
                                           rows: d.rows ?? s.size?.rows, screen: d.screen ?? s.screen, command: s.command,
                                           pid: s.pid, bytesOut: s.bytesOut)
                try SavedScreens.write(layout, info: info, vt: shot.snapshot, text: d.text)
                report.captured.append(s.name)
            } catch {
                report.failed.append(s.name)
            }
        }
        report.milliseconds = milliseconds(since: t0)
        if !report.failed.isEmpty {
            note("saved screens: could not capture \(report.failed.joined(separator: ", ")) — their last saved screens are kept")
        }
        if !report.captured.isEmpty || !report.failed.isEmpty {
            broadcaster.yield(.step("saved \(report.captured.count) session screen(s)\(report.failed.isEmpty ? "" : ", \(report.failed.count) failed")",
                                    milliseconds: report.milliseconds))
        }
        return report
    }

    /// What one momentary attach brought back.
    struct CapturedScreen: Sendable {
        var snapshot = Data()
        var dump = ""
        /// Set when the session had already ended (no screen).
        var exitCode: Int32?
    }

    /// One capture: `deckhold pipe` as a non-terminal exec, written `DeckholdFrame.captureRequest`
    /// (HELLO 0×0 — the session keeps its size, nothing is typed — then DUMP); read until the DUMP's
    /// answer, then its stdin closes and the pipe exits. Nil: the session does not exist (or answered
    /// nothing in time). The exec is always deleted (deletion closes its vminitd client).
    static func captureScreen(on container: LinuxContainer, session: String, timeout: Int64) async throws -> CapturedScreen? {
        let collector = ScreenCollector()
        let (input, cont) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        collector.onDone = { cont.finish() }
        cont.yield(DeckholdFrame.captureRequest)
        let p = try await container.exec("s-\(UUID().uuidString.prefix(12).lowercased())") { cfg in
            cfg.arguments = GuestCommand.pipe(name: session)
            cfg.environmentVariables = GuestCommand.environment()
            cfg.terminal = false
            cfg.stdin = ConnectionReader(source: input)
            cfg.stdout = collector
            cfg.stderr = OutputCollector()
        }
        do {
            try await p.start()
            // The guest answers in milliseconds; past the timeout, stdin closes (the pipe exits on EOF).
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(Double(timeout)))
                cont.finish()
            }
            _ = try? await p.wait(timeoutInSeconds: timeout + 2)
            watchdog.cancel()
            cont.finish()
            try? await p.delete()
        } catch {
            cont.finish()
            try? await p.delete()
            throw error
        }
        return collector.result
    }

    // MARK: helpers

    func acquire() async {
        if gateHeld { await withCheckedContinuation { gateWaiters.append($0) } } else { gateHeld = true }
    }

    func release() {
        if gateWaiters.isEmpty { gateHeld = false } else { gateWaiters.removeFirst().resume() }
    }

    private func setPhase(_ p: Phase) {
        guard p != phase else { return }
        phase = p
        broadcaster.yield(.phase(p))
        emitStatus()
    }

    func setBusy(_ b: Bool) {
        busy = b
        emitStatus()
    }

    private func emitStatus() { broadcaster.yield(.status(status)) }

    func note(_ s: String) { broadcaster.yield(.note(s)) }

    /// A timed step: `.stepStarted` now, then `.step` (or `.stepFailed`) with the same label.
    func timed<T>(_ label: String, _ body: () async throws -> T) async throws -> T {
        let t0 = ContinuousClock.now
        broadcaster.yield(.stepStarted(label))
        do {
            let v = try await body()
            broadcaster.yield(.step(label, milliseconds: milliseconds(since: t0)))
            return v
        } catch {
            broadcaster.yield(.stepFailed(label, milliseconds: milliseconds(since: t0), error: error.localizedDescription))
            throw error
        }
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// The kernel's own timestamp on the line where it hands over to init — pure kernel boot time.
    private func kernelBootMilliseconds() -> Double? {
        guard let d = try? Data(contentsOf: layout.bootLog) else { return nil }
        for line in String(decoding: d, as: UTF8.self).split(separator: "\n") where line.contains("as init process") {
            let t = line.drop(while: { $0 == "[" || $0 == " " }).prefix(while: { $0 != "]" })
            if let s = Double(t) { return s * 1000 }
        }
        return nil
    }
}

/// Containers that could not be stopped through `LinuxContainer.stop()` (see `.releaseRuntime`).
enum Graveyard {
    nonisolated(unsafe) private static var bodies: [Any] = []
    private static let lock = NSLock()
    static func keep(_ items: Any?...) {
        lock.lock(); bodies.append(contentsOf: items.compactMap { $0 }); lock.unlock()
    }
}

func milliseconds(since t0: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - t0
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

func seconds(since t0: ContinuousClock.Instant) -> Double { milliseconds(since: t0) / 1000 }
