import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import NIOCore
import NIOPosix
import Virtualization

// The VM plumbing under `Sandbox`: identity pinning, restore-into-a-new-process, and direct VZ
// operations. Everything here is public Containerization API (0.47.0) — no forks, no SPI.

/// The ONE event-loop group every sandbox VM instance in this process uses (its vminitd gRPC
/// clients and time syncer run on it). 583: `VZVirtualMachineInstance` otherwise makes its own
/// `MultiThreadedEventLoopGroup(numberOfThreads: coreCount)` and shuts it down only in its own
/// `stop()` — which Hibernate never calls (it stops the VM at the VZ level and keeps the instance
/// for the wake). Every instance a host made therefore kept 8 threads and 8 kqueue fds for the life
/// of the process (582 churn: +~5 threads, +~6 fds, +~1 MiB per wake/hibernate cycle; the
/// per-process thread cap is 6,144). A group the instance did not create is never shut down by it.
enum SharedEventLoop {
    static let group: any EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
}

/// `VZVirtualMachine` is touched only on its own queue, which VZ enforces.
struct VMHandle: @unchecked Sendable {
    let vm: VZVirtualMachine
    let queue: DispatchQueue
}

enum VZOp: Sendable { case stop, save(URL), restore(URL), resume, pause }

/// Run one VZ operation on the VM's own queue.
func vz(_ h: VMHandle, _ op: VZOp) async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        h.queue.async {
            let done: @Sendable (Error?) -> Void = { e in if let e { c.resume(throwing: e) } else { c.resume() } }
            switch op {
            case .stop: h.vm.stop(completionHandler: done)
            case .save(let u): h.vm.saveMachineStateTo(url: u, completionHandler: done)
            case .restore(let u): h.vm.restoreMachineStateFrom(url: u, completionHandler: done)
            case .resume: h.vm.resume { r in if case .failure(let e) = r { done(e) } else { done(nil) } }
            case .pause: h.vm.pause { r in if case .failure(let e) = r { done(e) } else { done(nil) } }
            }
        }
    }
}

func vzStateIsStopped(_ h: VMHandle) -> Bool {
    h.queue.sync { h.vm.state == .stopped || h.vm.state == .error }
}

/// Pins what the package would otherwise randomise, and what VZ checks when restoring a
/// snapshot: the platform's machine identifier (576.02 — a mismatch fails "invalid argument")
/// and the NIC's MAC address.
struct PinnedIdentity: VZInstanceExtension {
    let machineIdentifier: Data
    let macAddress: String?
    /// 583: a virtio memory balloon (`returnFreeMemory`). A device is a VM input: a snapshot must be
    /// restored into a VM with exactly the devices it was taken with, so this is persisted per
    /// sandbox (`PersistedSandbox.memoryBalloon`) and a VM slept by an older build restores without.
    let memoryBalloon: Bool
    /// EXPERIMENTAL (604): the audio device (an audio sandbox). A VM input like the balloon; the layout records it.
    var audio: Bool = false
    /// 591: the kernel's sha256 (recorded in the layout).
    var kernelSHA256: String? = nil
    /// 591: on a restore, the layout the snapshot was taken with — the new VM must match it.
    var expected: VMLayout? = nil
    var sandboxName: String = ""
    /// 591: receives the layout of the VM as configured.
    var recorder: VMLayoutRecorder? = nil

    func configureVZ(_ config: inout VZVirtualMachineConfiguration, allocator: any AddressAllocator<Character>,
                     storageDeviceCount: Int, mountsByID: [String: [Containerization.Mount]]) throws {
        guard let platform = config.platform as? VZGenericPlatformConfiguration,
              let mid = VZGenericMachineIdentifier(dataRepresentation: machineIdentifier)
        else { throw SandboxError.invalidSpec("cannot pin the VM's machine identifier") }
        platform.machineIdentifier = mid
        if let macAddress, let mac = VZMACAddress(string: macAddress) {
            for device in config.networkDevices { device.macAddress = mac }
        }
        if memoryBalloon { config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()] }
        if audio { AudioDevice.add(to: config) }
        // SPIKE (604): extra devices from the audio spike (doz-vmtest spike-audio) — BEFORE the layout,
        // so a sound device is recorded (`otherDevices["audio"]`) and compared on a restore like any device.
        SpikeVMDevices.configure?(config)
        // 591: the VM as it will be built; a restore into a different one is refused HERE, before VZ
        // is asked (its own refusal is an opaque "invalid argument" or "Internal Virtualization error").
        let actual = VMLayout.of(config, kernelSHA256: kernelSHA256)
        recorder?.layout = actual
        if case .incompatible(let d) = VMLayout.check(recorded: expected, actual: actual) {
            throw SandboxError.snapshotNeedsOtherBuild(sandbox: sandboxName, recordedBy: expected?.recordedBy, differences: d)
        }
    }
}

/// SPIKE (604, workspace changes/604-*/604.01-SPIKE.md) — a TEST-ONLY seam: when set, every VM this
/// process configures gets the devices it adds (the audio spike adds a `VZVirtioSoundDeviceConfiguration`).
/// Nothing in doz sets it; it exists only so `doz-vmtest spike-audio` can drive the real library. Remove
/// it (or replace it with a real per-sandbox device setting) when stage 2 decides.
public enum SpikeVMDevices {
    nonisolated(unsafe) public static var configure: (@Sendable (VZVirtualMachineConfiguration) -> Void)?
}

/// The VM's balloon target (bytes): read, or set and read back. nil without a balloon device.
func balloonTarget(_ h: VMHandle, set bytes: UInt64? = nil) -> UInt64? {
    h.queue.sync {
        guard let b = h.vm.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice else { return nil }
        if let bytes { b.targetVirtualMachineMemorySize = bytes }
        return b.targetVirtualMachineMemorySize
    }
}

/// Set while a restored VM is being adopted by a fresh `LinuxContainer` (see `AdoptingAgent`).
final class AdoptionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _adopting: Bool
    init(_ v: Bool) { _adopting = v }
    var adopting: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _adopting }
        set { lock.lock(); _adopting = newValue; lock.unlock() }
    }
}

/// The VMM every sandbox VM is created through. Normal mode: the package's own VZ manager plus
/// `PinnedIdentity`. Adopt mode (restore after a crash): the created instance is wrapped so that
/// "starting" it RESTORES the snapshot instead of booting.
struct DozerVMM: VirtualMachineManager {
    let inner: VZVirtualMachineManager
    let identity: PinnedIdentity
    /// Non-nil in adopt mode: the snapshot to restore, and the flag the agent wrapper reads.
    let adopt: (snapshot: URL, flag: AdoptionFlag, containerID: String)?

    func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
        var c = config.configuration
        c.extensions.append(identity)
        let vm = try inner.create(config: StandardVMConfig(configuration: c))
        guard let adopt else { return vm }
        guard let vz = vm as? VZVirtualMachineInstance else { throw SandboxError.vmUnavailable }
        return AdoptingInstance(inner: vz, snapshot: adopt.snapshot, flag: adopt.flag, containerID: adopt.containerID)
    }
}

/// A VZ instance whose `start()` restores a snapshot (and resumes) rather than booting.
///
/// Why this works (576.02 crash case): a snapshot restored into an identical VM brings back the
/// whole guest — vminitd, the container, its processes, the holder's sessions. The package's
/// `LinuxContainer.create()`/`start()` would then try to set that guest up again (mount the
/// root disk, configure the NIC, create the init process); during adoption `AdoptingAgent`
/// answers those calls as already done, so the fresh `LinuxContainer` ends in `started` state,
/// bound to the restored guest, and every later exec is ordinary package code.
struct AdoptingInstance: VirtualMachineInstance {
    typealias Agent = AdoptingAgent
    let inner: VZVirtualMachineInstance
    let snapshot: URL
    let flag: AdoptionFlag
    let containerID: String

    var state: VirtualMachineInstanceState { inner.state }
    var mounts: [String: [AttachedFilesystem]] { inner.mounts }

    func dialAgent() async throws -> AdoptingAgent {
        let inner = self.inner
        return AdoptingAgent(dial: { try await inner.dialAgent() }, flag: flag, containerID: containerID)
    }
    func dial(_ port: UInt32) async throws -> FileHandle { try await inner.dial(port) }
    func listen(_ port: UInt32) throws -> VsockListener { try inner.listen(port) }

    func start() async throws {
        let h = VMHandle(vm: inner.vzVirtualMachine, queue: inner.vmQueue)
        try await vz(h, .restore(snapshot))
        try await vz(h, .resume)
    }
    func stop() async throws { try await inner.stop() }
    func pause() async throws { try await inner.pause() }
    func resume() async throws { try await inner.resume() }
}

/// Pass-through agent that, while adopting, treats guest SET-UP as already done (see
/// `AdoptingInstance`). Everything else — and everything once adoption ends — goes to vminitd.
///
/// The vminitd connection is dialled LAZILY, on the first call that needs the guest: adoption's
/// set-up calls are all answered locally, so no gRPC client exists during them. (578/579: a client
/// dialled straight after a restore could fail, its `close()` then threw, and deallocating a gRPC
/// client that never finished is a fatal error in the transport.) A client whose `close()` fails
/// is kept for the life of the process instead of being freed.
struct AdoptingAgent: VirtualMachineAgent {
    let dialer: @Sendable () async throws -> Vminitd
    let flag: AdoptionFlag
    let containerID: String
    private let box = AgentBox()

    init(dial: @escaping @Sendable () async throws -> Vminitd, flag: AdoptionFlag, containerID: String) {
        self.dialer = dial
        self.flag = flag
        self.containerID = containerID
    }

    private var inner: Vminitd {
        get async throws { try await box.get(dialer) }
    }

    private var adopting: Bool { flag.adopting }

    func standardSetup() async throws { if !adopting { try await (try await inner).standardSetup() } }
    func close() async throws { await box.close() }
    func filesystemOperation(operation: FilesystemOperation, path: String, containerID: String?) async throws {
        try await (try await inner).filesystemOperation(operation: operation, path: path, containerID: containerID)
    }
    func getenv(key: String) async throws -> String { try await (try await inner).getenv(key: key) }
    func setenv(key: String, value: String) async throws { try await (try await inner).setenv(key: key, value: value) }
    func mount(_ mount: ContainerizationOCI.Mount) async throws { if !adopting { try await (try await inner).mount(mount) } }
    func umount(path: String, flags: Int32) async throws { try await (try await inner).umount(path: path, flags: flags) }
    func mkdir(path: String, all: Bool, perms: UInt32) async throws {
        if !adopting { try await (try await inner).mkdir(path: path, all: all, perms: perms) }
    }
    @discardableResult
    func kill(pid: Int32, signal: Int32) async throws -> Int32 { try await (try await inner).kill(pid: pid, signal: signal) }
    func sync() async throws { try await (try await inner).sync() }
    func writeFile(path: String, data: Data, flags: WriteFileFlags, mode: UInt32) async throws {
        if !adopting { try await (try await inner).writeFile(path: path, data: data, flags: flags, mode: mode) }
    }

    /// The container's init process already exists in the restored guest.
    private func isInit(_ id: String, _ cid: String?) -> Bool { adopting && id == containerID && (cid == nil || cid == containerID) }

    func createProcess(id: String, containerID: String?, stdinPort: UInt32?, stdoutPort: UInt32?, stderrPort: UInt32?,
                       ociRuntimePath: String?, configuration: ContainerizationOCI.Spec, options: Data?) async throws {
        if isInit(id, containerID) { return }
        try await (try await inner).createProcess(id: id, containerID: containerID, stdinPort: stdinPort, stdoutPort: stdoutPort,
                                      stderrPort: stderrPort, ociRuntimePath: ociRuntimePath,
                                      configuration: configuration, options: options)
    }
    func startProcess(id: String, containerID: String?) async throws -> Int32 {
        if isInit(id, containerID) { return 1 }
        return try await (try await inner).startProcess(id: id, containerID: containerID)
    }
    func signalProcess(id: String, containerID: String?, signal: Int32) async throws {
        try await (try await inner).signalProcess(id: id, containerID: containerID, signal: signal)
    }
    func resizeProcess(id: String, containerID: String?, columns: UInt32, rows: UInt32) async throws {
        try await (try await inner).resizeProcess(id: id, containerID: containerID, columns: columns, rows: rows)
    }
    func waitProcess(id: String, containerID: String?, timeoutInSeconds: Int64?) async throws -> ExitStatus {
        try await (try await inner).waitProcess(id: id, containerID: containerID, timeoutInSeconds: timeoutInSeconds)
    }
    func deleteProcess(id: String, containerID: String?) async throws {
        try await (try await inner).deleteProcess(id: id, containerID: containerID)
    }
    func closeProcessStdin(id: String, containerID: String?) async throws {
        try await (try await inner).closeProcessStdin(id: id, containerID: containerID)
    }
    func up(name: String, mtu: UInt32?) async throws { if !adopting { try await (try await inner).up(name: name, mtu: mtu) } }
    func down(name: String) async throws { try await (try await inner).down(name: name) }
    func addressAdd(name: String, address: InterfaceAddress) async throws {
        if !adopting { try await (try await inner).addressAdd(name: name, address: address) }
    }
    func routeAddLink(name: String, route: LinkRoute) async throws {
        if !adopting { try await (try await inner).routeAddLink(name: name, route: route) }
    }
    func routeAddDefault(name: String, route: DefaultRoute) async throws {
        if !adopting { try await (try await inner).routeAddDefault(name: name, route: route) }
    }
    func configureDNS(config: DNS, location: String) async throws {
        if !adopting { try await (try await inner).configureDNS(config: config, location: location) }
    }
    func configureHosts(config: Hosts, location: String) async throws {
        if !adopting { try await (try await inner).configureHosts(config: config, location: location) }
    }
    func containerStatistics(containerIDs: [String], categories: StatCategory) async throws -> [ContainerStatistics] {
        try await (try await inner).containerStatistics(containerIDs: containerIDs, categories: categories)
    }
}

/// Holds a lazily dialled vminitd client; closing a client that never connected is free.
actor AgentBox {
    private var agent: Vminitd?
    func get(_ dial: @Sendable () async throws -> Vminitd) async throws -> Vminitd {
        if let agent { return agent }
        let a = try await dial()
        agent = a
        return a
    }
    func close() async {
        guard let a = agent else { return }
        agent = nil
        await closeKeepingOnFailure(a)
    }
}

/// Close a vminitd client; if that fails, keep it alive forever rather than let it deallocate
/// unfinished (a fatal error in the gRPC transport).
func closeKeepingOnFailure(_ agent: Vminitd) async {
    do { try await agent.close() } catch { Graveyard.keep(agent) }
}

/// The concrete VZ instance under whatever `LinuxContainer.withVirtualMachineInstance` hands out.
func vzInstance(of vm: any VirtualMachineInstance) -> VZVirtualMachineInstance? {
    if let v = vm as? VZVirtualMachineInstance { return v }
    if let a = vm as? AdoptingInstance { return a.inner }
    return nil
}
