import Foundation
import Virtualization
import XCTest
@testable import DozerKit

/// 591 — the VM layout a snapshot was taken with, and the decision a wake makes from it.
final class VMLayoutTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vmlayout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func file(_ name: String, _ bytes: String = "x") throws -> URL {
        let u = dir.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: u)
        return u
    }

    /// A raw disk image VZ accepts (a whole number of sectors; sparse).
    func disk(_ name: String) throws -> URL {
        let u = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: u.path, contents: nil)
        let h = try FileHandle(forWritingTo: u)
        try h.truncate(atOffset: 1 << 20)
        try h.close()
        return u
    }

    /// A configuration shaped like a sandbox's: platform + machine id, kernel, initfs + root + state
    /// disks, a NAT NIC, a balloon, vsock, a console, one share.
    func config(balloon: Bool = true, stateReadOnly: Bool = false, swapDisks: Bool = false, mac: String = "02:11:22:33:44:55",
                cpus: Int = 2, machine: VZGenericMachineIdentifier? = nil) throws -> VZVirtualMachineConfiguration {
        let c = VZVirtualMachineConfiguration()
        let p = VZGenericPlatformConfiguration()
        p.machineIdentifier = machine ?? Self.machine
        c.platform = p
        c.cpuCount = cpus
        c.memorySize = 1 << 30
        let boot = VZLinuxBootLoader(kernelURL: try file("vmlinux", "kernel"))
        boot.commandLine = "console=hvc0"
        c.bootLoader = boot
        var disks = [
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: try disk("initfs.ext4"), readOnly: true)),
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: try disk("rootfs.ext4"), readOnly: false)),
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: try disk("state.ext4"), readOnly: stateReadOnly)),
        ]
        if swapDisks { disks.swapAt(1, 2) }
        c.storageDevices = disks
        let nic = VZVirtioNetworkDeviceConfiguration()
        nic.attachment = VZNATNetworkDeviceAttachment()
        nic.macAddress = VZMACAddress(string: mac)!
        c.networkDevices = [nic]
        if balloon { c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()] }
        c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        let share = VZVirtioFileSystemDeviceConfiguration(tag: "a")
        share.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: dir, readOnly: false))
        c.directorySharingDevices = [share]
        c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        return c
    }
    static let machineData = VZGenericMachineIdentifier().dataRepresentation
    static var machine: VZGenericMachineIdentifier { VZGenericMachineIdentifier(dataRepresentation: machineData)! }

    func testTheLayoutRecordsTheDevicesAsBuilt() throws {
        let l = VMLayout.of(try config(), kernelSHA256: "k1", recordedBy: "doz 0.8.1")
        XCTAssertEqual(l.platform, "VZGenericPlatformConfiguration")
        XCTAssertEqual(l.machineIdentifier.count, 16)
        XCTAssertEqual(l.cpus, 2)
        XCTAssertEqual(l.memoryBytes, 1 << 30)
        XCTAssertEqual(l.bootLoader, "VZLinuxBootLoader")
        XCTAssertEqual(l.kernelFile, dir.appendingPathComponent("vmlinux").path)
        XCTAssertEqual(l.commandLine, "console=hvc0")
        XCTAssertEqual(l.disks.map(\.file), ["initfs.ext4", "rootfs.ext4", "state.ext4"])
        XCTAssertEqual(l.disks.map(\.readOnly), [true, false, false])
        XCTAssertEqual(l.nics, [VMLayout.NIC(kind: "VZVirtioNetworkDeviceConfiguration", attachment: "VZNATNetworkDeviceAttachment", mac: "02:11:22:33:44:55")])
        XCTAssertEqual(l.memoryBalloons, 1)
        XCTAssertEqual(l.sockets, 1)
        XCTAssertEqual(l.shares, ["a"])
        XCTAssertEqual(l.entropy, 1)
        XCTAssertEqual(l.otherDevices, [:])
        XCTAssertEqual(l.recordedBy, "doz 0.8.1")
        // Round trip, as PersistedSandbox stores it.
        let d = try JSONEncoder().encode(l)
        XCTAssertEqual(try JSONDecoder().decode(VMLayout.self, from: d), l)
    }

    func testTheSameVMIsCompatibleAndWhoRecordedItIsNotALayout() throws {
        let slept = VMLayout.of(try config(), kernelSHA256: "k1", recordedBy: "doz 0.8.1")
        var now = VMLayout.of(try config(), kernelSHA256: "k1", recordedBy: "doz 0.8.2")
        now.commandLine = "console=hvc0 quiet"
        now.kernelFile = "/elsewhere/vmlinux"
        XCTAssertEqual(VMLayout.check(recorded: slept, actual: now), .compatible)
        XCTAssertEqual(VMLayout.check(recorded: nil, actual: now), .unrecorded, "a pre-591 snapshot: best effort, as before")
    }

    func testEveryRestoreRelevantDifferenceRefuses() throws {
        let slept = VMLayout.of(try config(), kernelSHA256: "k1")
        func diff(_ c: VZVirtualMachineConfiguration, kernel: String? = "k1") -> [String] {
            guard case .incompatible(let d) = VMLayout.check(recorded: slept, actual: VMLayout.of(c, kernelSHA256: kernel)) else { return [] }
            return d
        }
        XCTAssertTrue(diff(try config(balloon: false)).contains { $0.hasPrefix("memory balloon devices: slept with 1, this build makes 0") })
        XCTAssertTrue(diff(try config(stateReadOnly: true)).contains { $0.hasPrefix("disks:") && $0.contains("state.ext4 (ro)") })
        XCTAssertTrue(diff(try config(swapDisks: true)).contains { $0.hasPrefix("disks:") }, "device order is part of the layout")
        XCTAssertTrue(diff(try config(mac: "02:99:99:99:99:99")).contains { $0.hasPrefix("network devices:") })
        XCTAssertTrue(diff(try config(cpus: 4)).contains { $0.hasPrefix("CPUs: slept with 2, this build makes 4") })
        XCTAssertTrue(diff(try config(machine: VZGenericMachineIdentifier())).contains { $0.hasPrefix("machine identifier:") })
        XCTAssertTrue(diff(try config(), kernel: "k2").contains { $0.hasPrefix("kernel: slept with k1, this build makes k2") })
        XCTAssertEqual(diff(try config(), kernel: nil), [], "an unknown kernel sha is not a difference")
    }

    func testAWakeUsesTheKernelItSleptUnderOrRefuses() throws {
        let current = try file("vmlinux-new", "new")
        let old = try file("vmlinux-old", "old")
        let sha: (URL) -> String? = { (try? String(contentsOf: $0, encoding: .utf8)).map { "sha-" + $0 } }
        func recorded(_ k: String?, file: String? = nil) -> VMLayout {
            var l = VMLayout(platform: "p", machineIdentifier: "m", cpus: 1, memoryBytes: 1, bootLoader: "b", kernelSHA256: k, kernelFile: file,
                             disks: [], nics: [], memoryBalloons: 0, sockets: 0, serialPorts: 0, consoles: 0, shares: [], entropy: 0, otherDevices: [:])
            l.recordedBy = "doz 0.8.1"
            return l
        }
        XCTAssertEqual(VMLayout.kernelForRestore(recorded: nil, current: current, currentSHA256: "sha-new", searchDirectories: [dir], sha256: sha), current)
        XCTAssertEqual(VMLayout.kernelForRestore(recorded: recorded("sha-new"), current: current, currentSHA256: "sha-new", searchDirectories: [], sha256: sha), current)
        XCTAssertEqual(VMLayout.kernelForRestore(recorded: recorded("sha-old", file: old.path), current: current, currentSHA256: "sha-new", searchDirectories: [], sha256: sha), old,
                       "the recorded file, when it is still the same kernel")
        XCTAssertEqual(VMLayout.kernelForRestore(recorded: recorded("sha-old", file: "/gone/vmlinux"), current: current, currentSHA256: "sha-new", searchDirectories: [dir], sha256: sha), old,
                       "else any cached vmlinux with that sha256")
        XCTAssertNil(VMLayout.kernelForRestore(recorded: recorded("sha-older"), current: current, currentSHA256: "sha-new", searchDirectories: [dir], sha256: sha),
                     "a kernel this Mac no longer has: refuse")
    }

    func testARecordWithoutALayoutStillDecodesAndOneWithItRoundTrips() throws {
        let spec = SandboxSpec(name: "a", storeRoot: dir)
        var p = PersistedSandbox(spec: spec, phase: .hibernated, machineIdentifier: Data([1, 2]), macAddress: nil, subnet: nil, shareTags: [:])
        let url = dir.appendingPathComponent("state.json")
        try p.write(to: url)
        XCTAssertNil(PersistedSandbox.read(from: url)?.vmLayout, "a pre-591 record: no layout")
        p.vmLayout = VMLayout.of(try config(), kernelSHA256: "k1", recordedBy: "doz 0.8.2")
        try p.write(to: url)
        XCTAssertEqual(PersistedSandbox.read(from: url)?.vmLayout, p.vmLayout)
    }

    func testTheRefusalSaysWhatToDo() {
        let e = SandboxError.snapshotNeedsOtherBuild(sandbox: "box", recordedBy: "doz 0.8.1", differences: ["memory balloon devices: slept with 0, this build makes 1"])
        let m = e.localizedDescription
        for part in ["box was put to sleep by doz 0.8.1", "memory balloon devices", "snapshot was not restored and is kept",
                     "wake it with doz 0.8.1", "Shut Down (discards the snapshot"] {
            XCTAssertTrue(m.contains(part), part + " — " + m)
        }
    }
}
