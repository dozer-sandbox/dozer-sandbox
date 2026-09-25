import Containerization
import ContainerizationEXT4
import ContainerizationExtras
import Foundation
import SystemPackage
import Virtualization

/// One Linux container in its own VM, with the 576.03 sleep design:
///
///     start ─▶ running ⇄ paused (1 ms) ─▶ pausedSaved (+ snapshot, ~0.5 s)
///                 │                              │
///                 └──────────── sleepToDisk ─────┴─▶ onDisk (RAM freed) ─ wakeFromDisk (~0.35 s) ─▶ running
///     any ─ stop ─▶ off           a new process ─ restoreAfterCrash ─▶ running   (pinned machine id)
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
    private var busy = false
    private var snapshotBytes = 0

    private let broadcaster = EventBroadcaster<SandboxEvent>()
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

    /// Resolves the kernel on every boot (see `KernelProvider`).
    public nonisolated let kernelProvider: KernelProvider

    public init(spec: SandboxSpec, kernelProvider: KernelProvider? = nil) throws {
        try spec.validate()
        self.spec = spec
        self.layout = StoreLayout(spec: spec)
        self.kernelProvider = kernelProvider
            ?? KernelProvider(cacheDirectory: spec.kernelCacheDirectory ?? StoreLayout(spec: spec).kernels)
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
    /// would): the root disk is kept and the next Start cold-boots it. Only for a sandbox no
    /// process is running.
    public nonisolated static func discardRestorableState(for spec: SandboxSpec) {
        // Stop semantics: the snapshot goes; the root disk stays and the next Start cold-boots it.
        let layout = StoreLayout(spec: spec)
        try? FileManager.default.removeItem(at: layout.snapshot)
        if var p = PersistedSandbox.read(from: layout.persistedState) {
            p.phase = .off
            try? p.write(to: layout.persistedState)
        }
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
            for step in [LifecycleStep.resyncClock, .remountShares, .deleteSnapshot, .persistState] {
                try await run(step, target: .running)
            }
            note(String(format: "restored after a crash in %.2f s — sessions are where they were", seconds(since: t0)))
        } catch {
            abandonBoot()
            note("restore FAILED: \(error.localizedDescription) — the snapshot is kept; Stop discards it")
            setPhase(.failed)
            throw error
        }
    }

    static func disksStillHeld(_ error: Error) -> Bool {
        "\(error) \(error.localizedDescription)".contains("storage device attachment is invalid")
    }

    /// Drop a boot that failed part-way: its container may own vminitd clients that were never
    /// closed, and deallocating one is fatal — so it is kept (Graveyard), never freed.
    private func abandonBoot() {
        if let network { var n = network; try? n.releaseInterface(spec.name); self.network = nil }
        if container != nil || instance != nil { Graveyard.keep(container, instance) }
        container = nil; instance = nil; handle = nil; identity = nil
    }

    /// The identity persisted with a root disk that Stop kept, if both are there.
    static func keptRootDisk(_ layout: StoreLayout) -> PersistedSandbox? {
        guard FileManager.default.fileExists(atPath: layout.rootfs.path) else { return nil }
        return PersistedSandbox.read(from: layout.persistedState)
    }

    public func pause() async throws { try await perform(.pause) }
    public func resume() async throws { try await perform(.resume) }
    /// Pause + snapshot to disk; stays paused, RAM held. From here a crash is survivable.
    public func sleep() async throws { try await perform(.sleep) }
    /// Pause + snapshot + VM stop: RAM returned. Attached connections are detached with
    /// `.sandboxSleeping` first; attach again after `wakeFromDisk()`.
    public func sleepToDisk() async throws { try await perform(.sleepToDisk) }
    /// Restore + resume + clock resync + share re-mount + snapshot deleted.
    public func wakeFromDisk() async throws { try await perform(.wakeFromDisk) }
    /// Shut the VM down — gracefully, reviving a sleeping one first — and KEEP its root disk: the
    /// next `start()` cold-boots that same disk. No snapshot survives a Stop.
    public func stop() async throws { try await perform(.stop) }
    /// Stop if needed, then discard the root disk: the next `start()` begins from a fresh clone of
    /// the prepared disk.
    public func resetToImage() async throws { try await perform(.resetToImage) }
    /// Stop if needed, then remove everything this sandbox has on disk.
    public func delete() async throws { try await perform(.delete) }

    /// This sandbox has a root disk that the next `start()` will boot (rather than a fresh clone).
    public nonisolated var hasRootDisk: Bool { FileManager.default.fileExists(atPath: layout.rootfs.path) }

    /// What a host app should do at quit: keep a sleeping sandbox restorable (its VM dies with
    /// the process, its snapshot does not), stop anything else.
    public func prepareForExit() async {
        await acquire(); defer { release() }
        if phase.keepsSnapshot {
            for c in connections.values { c.detach(.sandboxSleeping) }
            connections.removeAll()
            note("left asleep with its snapshot on disk — restorable after relaunch")
        } else if phase != .off {
            await runStopSteps(from: phase)
            setPhase(.off)
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
        if [.stop, .resetToImage, .delete].contains(op) {
            // Best effort at every step: whatever state the VM is in, it ends stopped.
            for step in steps {
                do { try await run(step, target: .off) } catch { note("\(op.rawValue): \(step) — \(error.localizedDescription)") }
            }
            setPhase(.off)
            return
        }
        let target = LifecyclePlanner.target(of: op)
        do {
            for step in steps { try await run(step, target: target) }
            setPhase(target)
        } catch {
            note("\(op.rawValue) FAILED: \(error.localizedDescription)")
            throw error
        }
    }

    /// Stop is best effort at every step: whatever state the VM is in, it ends stopped and the
    /// runtime files are gone.
    private func runStopSteps(from: Phase) async {
        for step in LifecyclePlanner.plan(.stop, from: from) ?? [] {
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
        case .saveSnapshot:
            guard let handle else { throw SandboxError.vmUnavailable }
            try? FileManager.default.removeItem(at: layout.snapshot)
            try await timed("saved VM state to disk") { try await vz(handle, .save(layout.snapshot)) }
            snapshotBytes = fileSize(layout.snapshot)
            setPhase(.pausedSaved)
        case .detachSessions(let reason):
            let conns = Array(connections.values)
            connections.removeAll()
            for c in conns { c.detach(reason) }
            if !conns.isEmpty { note("detached \(conns.count) session connection(s): \(reason.rawValue)") }
        case .stopVMDirect:
            guard let handle else { return }
            if vzStateIsStopped(handle) { return }
            try await timed(target == .onDisk ? "stopped the VM — RAM freed, state on disk" : "stopped the VM") {
                try await vz(handle, .stop)
            }
            if target == .onDisk { setPhase(.onDisk) }
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
            try await timed("restored VM state from disk") { try await vz(handle, .restore(layout.snapshot)) }
            try await timed("resumed") { try await vz(handle, .resume) }
            setPhase(.running)
        case .resyncClock:
            guard let instance, let v = vzInstance(of: instance) else { throw SandboxError.vmUnavailable }
            try await timed("re-synced the guest clock") {
                let agent = try await v.dialAgent()
                let now = Date().timeIntervalSince1970
                do { try await agent.setTime(sec: Int64(now), usec: Int32((now - floor(now)) * 1_000_000)) } catch {
                    await closeKeepingOnFailure(agent)
                    throw error
                }
                await closeKeepingOnFailure(agent)
            }
        case .remountShares:
            let tags = (identity?.shareTags ?? [:]).map { (tag: $0.value, guestPath: $0.key) }.sorted { $0.guestPath < $1.guestPath }
            guard !tags.isEmpty else { return }
            try await timed("re-mounted \(tags.count) share(s) (virtio-fs does not survive a VM stop)") {
                let r = try await execInContainer(["sh", "-c", GuestCommand.remountShares(tags)], privileged: true, timeout: 30)
                if r.exitCode != 0 { throw SandboxError.commandFailed(command: "remount shares", exitCode: r.exitCode, output: r.output + r.errorOutput) }
            }
        case .deleteSnapshot:
            if FileManager.default.fileExists(atPath: layout.snapshot.path) {
                try? FileManager.default.removeItem(at: layout.snapshot)
                note("deleted the snapshot (it is valid only while the VM is paused)")
            }
            snapshotBytes = 0
        case .releaseRuntime:
            if let network { var n = network; try? n.releaseInterface(spec.name); self.network = nil }
            if !cleanlyStopped, let container {
                // Never let the package deallocate a vminitd client it did not close: that is a
                // fatal error in its gRPC transport. A container that was not stopped through
                // LinuxContainer.stop() is kept for the life of the process instead.
                Graveyard.keep(container, instance)
            }
            if var p = identity {
                p.phase = .off
                p.savedAt = Date()
                try? p.write(to: layout.persistedState)
            }
            container = nil; instance = nil; handle = nil; identity = nil; cleanlyStopped = false
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
        // What a fresh root disk would be cloned from: the prepared disk, or the recipe's bake.
        let wantedRoot: String = try spec.recipe.map {
            "\($0.name)@\($0.bakeKey(kernelSHA256: try KernelProvider.sha256(of: kernelURL), deckholdSHA256: try KernelProvider.sha256(of: deckhold)).prefix(12))"
        } ?? StoreLayout.goldenKey(for: spec)
        if let persisted {
            identity = persisted
        } else if var kept {
            // Stop kept this root disk: cold-boot it. Its snapshot, if one is lying around (a
            // crash while asleep, then Start instead of Restore), no longer matches a disk that
            // is about to move on — delete it, never restore it later.
            try? fm.removeItem(at: layout.snapshot)
            try? fm.removeItem(at: layout.bootLog)
            if let from = kept.rootImage, from != wantedRoot {
                note("the kept root disk was cloned from \(from), not \(wantedRoot) — Reset to image to start from the new one")
            }
            note("cold-booting the kept root disk (Stop keeps it; Reset to image starts afresh)")
            kept.spec = spec
            identity = kept
        } else {
            let golden: URL
            if let recipe = spec.recipe {
                let inputs = ImageBaker.BakeInputs(kernel: kernel, kernelSHA256: try KernelProvider.sha256(of: kernelURL),
                                                   deckholdSHA256: try KernelProvider.sha256(of: deckhold),
                                                   initfsReference: spec.initfsReference, dnsServers: spec.dnsServers)
                let broadcaster = self.broadcaster
                golden = try await ImageBaker(storeRoot: spec.storeRoot).ensure(recipe, inputs: inputs) { broadcaster.yield($0) }.root
            } else {
                golden = layout.golden(for: spec)
                if !fm.fileExists(atPath: golden.path) {
                    let hadImage = (try? await store.get(reference: spec.image, pull: false)) != nil
                    let image = try await timed("\(spec.image) ready\(hadImage ? " (cached)" : " (pulled)")") {
                        try await store.get(reference: spec.image, pull: true)
                    }
                    try await bake(image: image, kernel: kernel, store: store, into: golden)
                }
            }
            try? fm.removeItem(at: layout.rootfs)
            try? fm.removeItem(at: layout.bootLog)
            try? fm.removeItem(at: layout.snapshot)
            let rootfs = layout.rootfs
            try await timed("root disk cloned from the \(spec.recipe == nil ? "prepared disk" : "baked image \(spec.recipe!.name)") (APFS clone)") {
                try FileManager.default.copyItem(at: golden, to: rootfs)
                chmod(rootfs.path, 0o644)                   // the baked disk is read-only; its clone is not
            }
            identity = PersistedSandbox(spec: spec, phase: .running,
                                        machineIdentifier: VZGenericMachineIdentifier().dataRepresentation,
                                        macAddress: spec.networking ? PersistedSandbox.randomMAC() : nil,
                                        subnet: nil, shareTags: [:])
            identity.rootImage = wantedRoot
        }
        // The state disk outlives root disks (Stop, Reset to image, a re-bake); only Delete removes it.
        if spec.recipe != nil, !fm.fileExists(atPath: layout.stateDisk.path) {
            try await timed("created the empty state disk (\(spec.stateDiskMiB) MiB, sparse)") {
                let f = try EXT4.Formatter(FilePath(layout.stateDisk.path), minDiskSize: spec.stateDiskMiB * 1_048_576)
                try f.close()
            }
        }

        var iface: (any Interface)?
        var readdress: (address: String, gateway: String)?
        if spec.networking {
            var net = try await makeNetwork(persistedSubnet: persisted == nil ? nil : identity.subnet)
            guard let i = try net.createInterface(spec.name) else { throw SandboxError.vmUnavailable }
            if let old = identity.subnet, persisted != nil, old != net.subnet.description, let gw = i.ipv4Gateway {
                // The guest still has its old address; fix it once the restored guest runs.
                readdress = (i.ipv4Address.description, gw.description)
            }
            iface = i
            identity.subnet = net.subnet.description
            network = net
        }

        let flag = AdoptionFlag(persisted != nil)
        let initfs = Containerization.Mount.block(format: "ext4", source: layout.initfs.path, destination: "/", options: ["ro"])
        let vmm = SnoozeVMM(
            inner: VZVirtualMachineManager(kernel: kernel, initialFilesystem: initfs),
            identity: PinnedIdentity(machineIdentifier: identity.machineIdentifier, macAddress: identity.macAddress),
            adopt: persisted != nil ? (snapshot: layout.snapshot, flag: flag, containerID: spec.name) : nil)
        let spec = self.spec
        let bootLog = layout.bootLog
        let stateDisk = layout.stateDisk
        let c = try LinuxContainer(
            spec.name,
            rootfs: .block(format: "ext4", source: layout.rootfs.path, destination: "/", options: []),
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
            if spec.recipe != nil {
                cfg.mounts.append(.block(format: "ext4", source: stateDisk.path, destination: GuestCommand.stateMount))
            }
            if let iface { cfg.interfaces = [iface] }
            cfg.dns = DNS(nameservers: spec.dnsServers)
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

        let (inst, h): (any VirtualMachineInstance, VMHandle) = try await c.withVirtualMachineInstance { i in
            guard let v = vzInstance(of: i) else { throw SandboxError.vmUnavailable }
            return (i, VMHandle(vm: v.vzVirtualMachine, queue: v.vmQueue))
        }
        instance = inst
        handle = h
        if persisted == nil {
            if let v = vzInstance(of: inst) {
                for m in v.mounts[spec.name] ?? [] where m.type == "virtiofs" { identity.shareTags[m.destination] = m.source }
            }
            try await timed("installed deckhold (the guest PTY holder)") {
                try await c.copyIn(from: deckhold, to: URL(fileURLWithPath: GuestCommand.deckholdPath), mode: 0o755)
            }
            try await timed(spec.recipe == nil ? "prepared the guest" : "prepared the guest (persist dirs bound from the state disk)") {
                let r = try await Self.exec(on: c, ["sh", "-c", GuestCommand.prepareGuest(recipe: spec.recipe)], environment: [:],
                                            workingDirectory: "/", privileged: true, timeout: 30)
                if r.exitCode != 0 { throw SandboxError.commandFailed(command: "prepare guest", exitCode: r.exitCode, output: r.output + r.errorOutput) }
            }
        }
        identity.phase = .running
        self.identity = identity
        try identity.write(to: layout.persistedState)
    }

    /// The vmnet network. On a restore, the subnet the guest was addressed from — vmnet can take
    /// a moment to release a dead process's network, so retry briefly before settling for a new
    /// subnet (and re-addressing the guest).
    private func makeNetwork(persistedSubnet: String?) async throws -> VmnetNetwork {
        guard let persistedSubnet, let cidr = try? CIDRv4(persistedSubnet) else { return try VmnetNetwork() }
        for attempt in 1...10 {
            do { return try VmnetNetwork(subnet: cidr) } catch {
                if attempt == 10 { note("subnet \(persistedSubnet) unavailable (\(error.localizedDescription)); using a new one") }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        return try VmnetNetwork()
    }

    /// One-time per store and package set: boot the image, install the packages, keep the disk.
    private func bake(image: Containerization.Image, kernel: Kernel, store: ImageStore, into golden: URL) async throws {
        let pkgs = spec.bakePackages
        note("no prepared disk yet — baking one\(pkgs.isEmpty ? "" : " (\(pkgs.joined(separator: ", ")))") (one-time, needs network)…")
        let t0 = ContinuousClock.now
        var mgr = try await ContainerManager(kernel: kernel, initfsReference: spec.initfsReference, imageStore: store,
                                             network: spec.networking ? try VmnetNetwork() : nil)
        let id = layout.bakeContainerID
        try? mgr.delete(id)
        let spec = self.spec
        let b = try await mgr.create(id, image: image, rootfsSizeInBytes: spec.rootfsMiB * 1_048_576, readOnly: false,
                                     networking: spec.networking,
                                     vm: VMResources(cpus: spec.cpus, memoryInBytes: spec.memoryMiB * 1_048_576 + VMResources.guestMemoryOverhead)) { cfg in
            cfg.cpus = spec.cpus
            cfg.memoryInBytes = spec.memoryMiB * 1_048_576
            cfg.process.arguments = ["sleep", "infinity"]
            cfg.dns = DNS(nameservers: spec.dnsServers)
        }
        do {
            try await b.create()
            try await b.start()
            if !pkgs.isEmpty {
                let r = try await Self.exec(on: b, ["sh", "-c", "apk add --no-cache \(pkgs.joined(separator: " ")) >/dev/null && sync"],
                                            environment: [:], workingDirectory: "/", privileged: false, timeout: 300)
                guard r.exitCode == 0 else {
                    throw SandboxError.commandFailed(command: "apk add \(pkgs.joined(separator: " "))", exitCode: r.exitCode, output: r.output + r.errorOutput)
                }
            }
            try await b.stop()
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

    // MARK: guest commands

    /// Run `argv` in the guest (no shell unless you pass one) and collect its output.
    public func exec(_ argv: [String], environment: [String: String] = [:], workingDirectory: String = "/",
                     privileged: Bool = false, user: String? = nil, timeoutSeconds: Int64 = 120) async throws -> ExecResult {
        guard phase == .running else { throw SandboxError.notRunning(phase) }
        return try await execInContainer(argv, environment: environment, workingDirectory: workingDirectory,
                                         privileged: privileged, timeout: timeoutSeconds, user: user)
    }

    private func execInContainer(_ argv: [String], environment: [String: String] = [:], workingDirectory: String = "/",
                                 privileged: Bool = false, timeout: Int64, user: String? = nil) async throws -> ExecResult {
        guard let container else { throw SandboxError.vmUnavailable }
        return try await Self.exec(on: container, argv, environment: environment, workingDirectory: workingDirectory,
                                   privileged: privileged, timeout: timeout, user: user)
    }

    static func exec(on container: LinuxContainer, _ argv: [String], environment: [String: String],
                     workingDirectory: String, privileged: Bool, timeout: Int64, user: String? = nil) async throws -> ExecResult {
        let out = OutputCollector(), err = OutputCollector()
        let p = try await container.exec("x-\(UUID().uuidString.prefix(12).lowercased())") { cfg in
            cfg.arguments = argv
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
    /// In an image sandbox the session runs as the recipe's user (pass `user: "root"` to override),
    /// in its `workdir`, with its `sessionEnvironment` — and `environment` on top: this is where a
    /// credential such as `ANTHROPIC_API_KEY` goes. It reaches the program's environment only; it
    /// is never written to any disk by this library.
    public func openSession(_ name: String, argv: [String], environment: [String: String] = [:],
                            workingDirectory: String? = nil, user: String? = nil, size: TermSize = .standard,
                            scrollbackBytes: Int? = nil) async throws {
        try GuestCommand.validateSessionName(name)
        precondition(!argv.isEmpty, "a session needs a program")
        let (env, cwd, runAs) = Self.sessionContext(recipe: spec.recipe, environment: environment,
                                                    workingDirectory: workingDirectory, user: user)
        guard phase == .running else { throw SandboxError.notRunning(phase) }
        let r = try await execInContainer(GuestCommand.serve(name: name, size: size, argv: argv, scrollbackBytes: scrollbackBytes),
                                          environment: env, workingDirectory: cwd, privileged: false, timeout: 30, user: runAs)
        guard r.exitCode == 0 else {
            throw SandboxError.commandFailed(command: "open session \(name)", exitCode: r.exitCode, output: r.output + r.errorOutput)
        }
        note("opened session \(name)\(runAs.map { " as \($0)" } ?? ""): \(argv.joined(separator: " "))")
    }

    /// The environment, working directory and user a session runs with (see `openSession`).
    static func sessionContext(recipe: ImageRecipe?, environment: [String: String], workingDirectory: String?,
                               user: String?) -> (environment: [String: String], workingDirectory: String, user: String?) {
        guard let r = recipe else { return (environment, workingDirectory ?? "/root", user) }
        let runAs = user ?? r.user
        var env = r.sessionEnvironment
        if runAs == r.user { env["HOME"] = r.home; env["USER"] = r.user }
        env.merge(environment) { _, caller in caller }
        return (env, workingDirectory ?? r.workdir, runAs == "root" ? nil : runAs)
    }

    /// Attach a viewer to session `name` at `size`. The first output is the session's current
    /// screen (a SNAPSHOT), then live output. See `SessionConnection`.
    public func attach(_ name: String, size: TermSize) async throws -> SessionConnection {
        try GuestCommand.validateSessionName(name)
        guard phase == .running, let container else { throw SandboxError.notRunning(phase) }
        let conn = SessionConnection(session: name, size: size)
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

    /// The guest's sessions (`deckhold ls`), live and ended.
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

    // MARK: helpers

    private func acquire() async {
        if gateHeld { await withCheckedContinuation { gateWaiters.append($0) } } else { gateHeld = true }
    }

    private func release() {
        if gateWaiters.isEmpty { gateHeld = false } else { gateWaiters.removeFirst().resume() }
    }

    private func setPhase(_ p: Phase) {
        guard p != phase else { return }
        phase = p
        broadcaster.yield(.phase(p))
        emitStatus()
    }

    private func setBusy(_ b: Bool) {
        busy = b
        emitStatus()
    }

    private func emitStatus() { broadcaster.yield(.status(status)) }

    private func note(_ s: String) { broadcaster.yield(.note(s)) }

    private func timed<T>(_ label: String, _ body: () async throws -> T) async throws -> T {
        let t0 = ContinuousClock.now
        let v = try await body()
        broadcaster.yield(.step(label, milliseconds: milliseconds(since: t0)))
        return v
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
