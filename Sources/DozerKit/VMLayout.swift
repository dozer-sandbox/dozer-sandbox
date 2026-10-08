import CryptoKit
import Foundation
import Virtualization

/// 591 — the exact virtual machine a snapshot was taken with.
///
/// A VZ snapshot restores only into a VM with the same hardware: the same platform and machine
/// identifier, CPU count and memory, the same devices in the same order (disks and whether they are
/// read-only, the NIC and its MAC, the memory balloon, vsock, the console, the virtio-fs shares), and
/// the kernel it was booted from. Anything else fails deep inside VZ ("invalid argument", "Internal
/// Virtualization error") — and an update of doz or of the Containerization package can change a
/// default without anyone noticing. So every VM records its layout when it is built
/// (`PersistedSandbox.vmLayout`), a wake builds the new VM from what was RECORDED where this build
/// controls it (the balloon since 583, the kernel file since 591), and before VZ is asked to restore
/// the new VM is compared with the record: a difference refuses the wake with a plain message,
/// leaving the snapshot as it is.
public struct VMLayout: Codable, Equatable, Sendable {
    public struct Disk: Codable, Equatable, Sendable {
        /// The device class (`VZVirtioBlockDeviceConfiguration`, …).
        public var kind: String
        /// The image file's name (not its directory: a store may move).
        public var file: String
        public var readOnly: Bool
        public init(kind: String, file: String, readOnly: Bool) {
            self.kind = kind
            self.file = file
            self.readOnly = readOnly
        }
    }

    public struct NIC: Codable, Equatable, Sendable {
        public var kind: String
        public var attachment: String
        public var mac: String
        public init(kind: String, attachment: String, mac: String) {
            self.kind = kind
            self.attachment = attachment
            self.mac = mac
        }
    }

    public var platform: String
    /// sha256 (hex, 16) of the machine identifier's data representation.
    public var machineIdentifier: String
    public var cpus: Int
    public var memoryBytes: UInt64
    public var bootLoader: String
    /// The kernel the VM booted: its sha256, and the file it was read from (a wake prefers that file).
    public var kernelSHA256: String?
    public var kernelFile: String?
    public var disks: [Disk]
    public var nics: [NIC]
    public var memoryBalloons: Int
    public var sockets: Int
    public var serialPorts: Int
    public var consoles: Int
    /// The virtio-fs tags, in device order.
    public var shares: [String]
    public var entropy: Int
    /// Device kinds doz does not use (graphics, keyboards, pointing, audio, USB): their counts.
    public var otherDevices: [String: Int]
    /// Informational — never compared: the kernel command line, and who recorded the layout.
    public var commandLine: String?
    public var recordedBy: String?

    public init(platform: String, machineIdentifier: String, cpus: Int, memoryBytes: UInt64, bootLoader: String,
                kernelSHA256: String?, kernelFile: String?, disks: [Disk], nics: [NIC], memoryBalloons: Int, sockets: Int,
                serialPorts: Int, consoles: Int, shares: [String], entropy: Int, otherDevices: [String: Int],
                commandLine: String? = nil, recordedBy: String? = nil) {
        self.platform = platform
        self.machineIdentifier = machineIdentifier
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.bootLoader = bootLoader
        self.kernelSHA256 = kernelSHA256
        self.kernelFile = kernelFile
        self.disks = disks
        self.nics = nics
        self.memoryBalloons = memoryBalloons
        self.sockets = sockets
        self.serialPorts = serialPorts
        self.consoles = consoles
        self.shares = shares
        self.entropy = entropy
        self.otherDevices = otherDevices
        self.commandLine = commandLine
        self.recordedBy = recordedBy
    }

    /// Who records layouts (the host sets "doz 0.8.2"; a library user may set its own name).
    nonisolated(unsafe) public static var recorder: String?

    static func kind(_ o: Any) -> String { String(describing: type(of: o)) }

    /// The layout of a VZ configuration, as it will be built.
    public static func of(_ c: VZVirtualMachineConfiguration, kernelSHA256: String?, recordedBy: String? = VMLayout.recorder) -> VMLayout {
        let platform = kind(c.platform)
        var mid = ""
        if let g = c.platform as? VZGenericPlatformConfiguration {
            mid = SHA256.hash(data: g.machineIdentifier.dataRepresentation).map { String(format: "%02x", $0) }.joined().prefix(16).description
        }
        var loader = "none", kernelFile: String?, cmdline: String?
        if let b = c.bootLoader {
            loader = kind(b)
            if let l = b as? VZLinuxBootLoader {
                kernelFile = l.kernelURL.path
                cmdline = l.commandLine
            }
        }
        let disks: [Disk] = c.storageDevices.map { d in
            if let a = d.attachment as? VZDiskImageStorageDeviceAttachment {
                return Disk(kind: kind(d), file: a.url.lastPathComponent, readOnly: a.isReadOnly)
            }
            return Disk(kind: kind(d), file: kind(d.attachment), readOnly: false)
        }
        let nics: [NIC] = c.networkDevices.map { n in
            NIC(kind: kind(n), attachment: n.attachment.map(kind) ?? "none", mac: n.macAddress.string)
        }
        let shares: [String] = c.directorySharingDevices.map { ($0 as? VZVirtioFileSystemDeviceConfiguration)?.tag ?? kind($0) }
        var other: [String: Int] = [:]
        if !c.graphicsDevices.isEmpty { other["graphics"] = c.graphicsDevices.count }
        if !c.keyboards.isEmpty { other["keyboards"] = c.keyboards.count }
        if !c.pointingDevices.isEmpty { other["pointing"] = c.pointingDevices.count }
        if !c.audioDevices.isEmpty { other["audio"] = c.audioDevices.count }
        if !c.usbControllers.isEmpty { other["usb"] = c.usbControllers.count }
        return VMLayout(platform: platform, machineIdentifier: mid, cpus: c.cpuCount, memoryBytes: c.memorySize, bootLoader: loader,
                        kernelSHA256: kernelSHA256, kernelFile: kernelFile, disks: disks, nics: nics,
                        memoryBalloons: c.memoryBalloonDevices.count, sockets: c.socketDevices.count, serialPorts: c.serialPorts.count,
                        consoles: c.consoleDevices.count, shares: shares, entropy: c.entropyDevices.count, otherDevices: other,
                        commandLine: cmdline, recordedBy: recordedBy)
    }

    /// What differs between the VM this build is about to restore into (`self`) and the one the
    /// snapshot was taken with — one line each, empty when they match. The kernel FILE, the command
    /// line and who recorded it are not compared (the kernel is compared by its sha256).
    public func differences(from recorded: VMLayout) -> [String] {
        var d: [String] = []
        func cmp<T: Equatable>(_ what: String, _ a: T, _ b: T, _ show: (T) -> String = { "\($0)" }) {
            if a != b { d.append("\(what): slept with \(show(b)), this build makes \(show(a))") }
        }
        cmp("platform", platform, recorded.platform)
        cmp("machine identifier", machineIdentifier, recorded.machineIdentifier)
        cmp("CPUs", cpus, recorded.cpus)
        cmp("memory", memoryBytes, recorded.memoryBytes) { "\($0 / 1_048_576) MiB" }
        cmp("boot loader", bootLoader, recorded.bootLoader)
        if let a = kernelSHA256, let b = recorded.kernelSHA256 { cmp("kernel", a, b) { String($0.prefix(12)) } }
        cmp("disks", disks, recorded.disks) { $0.map { "\($0.file)\($0.readOnly ? " (ro)" : "")" }.joined(separator: ", ") }
        cmp("network devices", nics, recorded.nics) { $0.map { "\($0.kind) \($0.mac)" }.joined(separator: ", ") }
        cmp("memory balloon devices", memoryBalloons, recorded.memoryBalloons)
        cmp("vsock devices", sockets, recorded.sockets)
        cmp("serial ports", serialPorts, recorded.serialPorts)
        cmp("console devices", consoles, recorded.consoles)
        cmp("shares", shares, recorded.shares) { $0.joined(separator: ", ") }
        cmp("entropy devices", entropy, recorded.entropy)
        cmp("other devices", otherDevices, recorded.otherDevices) { $0.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ") }
        return d
    }

    /// Whether a snapshot may be restored into `actual`.
    public enum Compatibility: Equatable, Sendable {
        /// No layout was recorded (a snapshot from before 591): best effort, as before.
        case unrecorded
        case compatible
        case incompatible([String])
    }

    public static func check(recorded: VMLayout?, actual: VMLayout) -> Compatibility {
        guard let recorded else { return .unrecorded }
        let d = actual.differences(from: recorded)
        return d.isEmpty ? .compatible : .incompatible(d)
    }

    /// The kernel a wake must boot the restored VM with: the one it slept under. The current kernel
    /// when its sha256 is the recorded one (or nothing was recorded); else the recorded file, or any
    /// `vmlinux*` in `searchDirectories`, whose sha256 matches; nil when this Mac no longer has it.
    public static func kernelForRestore(recorded: VMLayout?, current: URL, currentSHA256: String,
                                        searchDirectories: [URL], sha256: (URL) -> String? = { try? KernelProvider.sha256(of: $0) }) -> URL? {
        guard let want = recorded?.kernelSHA256, want != currentSHA256 else { return current }
        var candidates: [URL] = []
        if let f = recorded?.kernelFile { candidates.append(URL(fileURLWithPath: f)) }
        for dir in searchDirectories {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("vmlinux") }.sorted()
            candidates += names.map { dir.appendingPathComponent($0) }
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) && sha256($0) == want }
    }
}

/// Where `PinnedIdentity` leaves the layout of the VM it just configured (read by `Sandbox`).
final class VMLayoutRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _layout: VMLayout?
    var layout: VMLayout? {
        get { lock.lock(); defer { lock.unlock() }; return _layout }
        set { lock.lock(); _layout = newValue; lock.unlock() }
    }
}
