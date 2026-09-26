import ArgumentParser
import Darwin
import Foundation
import Security
import SnoozeContainerKit
import SnoozeHost
import Virtualization

/// One `doctor` finding.
struct DoctorCheck: Codable, Equatable {
    enum Status: String, Codable { case ok, warn, fail }
    var check: String
    var status: Status
    var detail: String
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check this Mac and the store: macOS, Apple silicon, the entitlement, the kernel, vmnet, disk, the host.")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        let checks = Self.checks(store: g.snoozeStore)
        if g.json { Out.json(checks) } else {
            for c in checks {
                let mark = switch c.status { case .ok: "ok  "; case .warn: "warn"; case .fail: "FAIL" }
                Out.stdout("\(mark)  \(c.check.padding(toLength: 15, withPad: " ", startingAt: 0)) \(c.detail)\n")
            }
        }
        if checks.contains(where: { $0.status == .fail }) { throw ExitCode(SnoozeExit.failed) }
    }

    static func checks(store: SnoozeStore) -> [DoctorCheck] {
        var out: [DoctorCheck] = []
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var uts = utsname()
        uname(&uts)
        let machine = withUnsafeBytes(of: &uts.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let release = withUnsafeBytes(of: &uts.release) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        out.append(DoctorCheck(check: "macOS", status: v.majorVersion >= 26 ? .ok : .fail,
                               detail: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion) (Darwin \(release))" + (v.majorVersion >= 26 ? "" : " — macOS 26 or later is needed")))
        out.append(DoctorCheck(check: "chip", status: machine == "arm64" ? .ok : .fail,
                               detail: "\(machine) · \(sysctl("machdep.cpu.brand_string")) · \(sysctl("hw.model"))" + (machine == "arm64" ? "" : " — Apple silicon is needed")))
        out.append(DoctorCheck(check: "virtualization", status: VZVirtualMachine.isSupported ? .ok : .fail,
                               detail: VZVirtualMachine.isSupported ? "supported (up to \(VZVirtualMachineConfiguration.maximumAllowedCPUCount) CPUs per VM)" : "Virtualization.framework reports no support"))
        let ent = hasVirtualizationEntitlement()
        out.append(DoctorCheck(check: "entitlement", status: ent ? .ok : .fail,
                               detail: ent ? "com.apple.security.virtualization — \(HostLauncher.executablePath)"
                                           : "this binary lacks com.apple.security.virtualization: build it with `make cli` (it signs), or codesign --entitlements Scripts/snooze.entitlements"))
        let deckhold = DeckholdBinary.locate(), net = SnoozenetBinary.locate()
        out.append(DoctorCheck(check: "guest tools", status: deckhold != nil && net != nil ? .ok : .fail,
                               detail: deckhold != nil && net != nil ? "deckhold + snoozenet found (\(deckhold!.deletingLastPathComponent().path))"
                                                                    : "\(DeckholdBinary.bundleName) is not beside the executable (make install-cli copies it)"))
        // The store.
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: store.root.path, isDirectory: &isDir), isDir.boolValue {
            let writable = fm.isWritableFile(atPath: store.root.path)
            let vals = try? store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedFormatDescriptionKey])
            let free = vals?.volumeAvailableCapacityForImportantUsage ?? 0
            let format = vals?.volumeLocalizedFormatDescription ?? "?"
            let apfs = format.contains("APFS")
            out.append(DoctorCheck(check: "store", status: writable && free > 10 << 30 && apfs ? .ok : (writable ? .warn : .fail),
                                   detail: "\(store.root.path) — \(format), \(SnoozeImages.formatBytes(free)) free, \(store.sandboxNames().count) sandbox(es)"
                                   + (apfs ? "" : " — not APFS: disks are copied instead of cloned") + (free > 10 << 30 ? "" : " — under 10 GiB free")))
        } else {
            out.append(DoctorCheck(check: "store", status: .ok, detail: "\(store.root.path) — not created yet (the first create makes it)"))
        }
        if !store.socketPathFits {
            out.append(DoctorCheck(check: "socket", status: .fail, detail: "\(store.socket.path) is over 103 bytes — use a shorter --store"))
        }
        let kernelDir = ProcessInfo.processInfo.environment["SNOOZE_KERNEL_CACHE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? store.layout("_").kernels
        let kernel = KernelProvider(cacheDirectory: kernelDir).cachedKernel
        out.append(DoctorCheck(check: "kernel", status: fm.fileExists(atPath: kernel.path) ? .ok : .warn,
                               detail: fm.fileExists(atPath: kernel.path) ? "\(KernelArtifact.recommended.fileName) cached (\(kernelDir.path))"
                                                                         : "not cached yet — the first start downloads it (~570 MiB, once)"))
        out.append(DoctorCheck(check: "vmnet", status: .ok,
                               detail: "needed only for --network nat (a free 192.168.100–199.0/24 subnet is picked); proxied sandboxes have no interface"))
        // The host.
        if store.hostIsRunning() {
            var detail = "running, pid \(store.hostPID().map(String.init) ?? "?")"
            var status = DoctorCheck.Status.ok
            if let m = try? HostClient.request(HostRequest(.ping), store: store, autostart: false),
               let st = try? m.result?.decode(HostStatus.self) {
                detail += ", \(st.version), \(st.liveSandboxes.count) running, idle timeout \(st.idleTimeoutMinutes.formatted()) min"
                if st.version != SnoozeCommand.version { status = .warn; detail += " — this CLI is \(SnoozeCommand.version): snooze host stop" }
            } else {
                status = .warn
                detail += " but it does not answer its socket"
            }
            out.append(DoctorCheck(check: "host", status: status, detail: detail))
        } else {
            let recover = store.needsRecovery()
            out.append(DoctorCheck(check: "host", status: recover.isEmpty ? .ok : .warn,
                                   detail: recover.isEmpty ? "not running (nothing is — the next command that needs it starts it)"
                                                           : "not running, and \(recover.joined(separator: ", ")) had a VM when the last host went away — the next command recovers it"))
        }
        let metricsOK = fm.fileExists(atPath: store.metrics.path)
        out.append(DoctorCheck(check: "metrics", status: .ok, detail: metricsOK ? store.metrics.path : "none yet"))
        return out
    }

    static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "?" }
        return String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    /// Whether this process's own signature carries com.apple.security.virtualization.
    static func hasVirtualizationEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let v = SecTaskCopyValueForEntitlement(task, "com.apple.security.virtualization" as CFString, nil)
        return (v as? Bool) == true
    }
}
