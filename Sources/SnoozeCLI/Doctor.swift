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
        let kernelDir = SnoozeSettings.load().string(SettingKey.kernelCache).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
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
                // 591: its program changed under it — overwritten in place is a failure (its VMs are refused).
                if let note = st.executableNote {
                    status = st.executableChange == "overwritten" ? .fail : (status == .ok ? .warn : status)
                    detail += " — " + note
                }
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
        out += claudeChecks(store: store, keychain: SystemKeychain())
        return out
    }

    /// 588: the Mac's Claude Code, its login(s), and the store's accounts. Reads only: `claude
    /// --version`, the keychain item (parsed in memory, never printed), attributes of the others.
    static func claudeChecks(store: SnoozeStore, keychain: KeychainAccess, now: Date = Date(),
                             binary: (() -> String?)? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             listItems: Bool = true) -> [DoctorCheck] {
        var out: [DoctorCheck] = []
        let st = ClaudeLoginStatus.check(configDir: nil, keychain: keychain, probeBinary: true, home: home, binary: binary)
        if let b = st.binary {
            out.append(DoctorCheck(check: "claude", status: .ok, detail: "Claude Code \(st.version ?? "?") (\(b))"))
        } else {
            out.append(DoctorCheck(check: "claude", status: .warn, detail: "Claude Code isn't installed on this Mac — needed only for the mac account (the Mac's own login)"))
        }
        let accounts = AccountStore(store: store, settings: .load()).load()
        let macInUse = accounts.defaultAccount == "mac"
        switch st.state {
        case .signedIn:
            let expired = st.expiresAt.map { $0 <= now } ?? false
            let soon = st.expiresAt.map { !expired && $0.timeIntervalSince(now) < 15 * 60 } ?? false
            var detail = st.summary(now: now)
            if expired {
                detail += " — it renews only while Claude Code runs on this Mac: open it (any prompt); sandboxes using it get \"login expired\" until then"
            } else {
                detail += " · renews while Claude Code runs on this Mac"
                if soon, !ClaudeLogin.isClaudeRunning() { detail += " — and none is running now" }
            }
            out.append(DoctorCheck(check: "claude login", status: expired || soon ? .warn : .ok, detail: detail))
        default:
            let p = st.problem(now: now)?.message ?? st.state.rawValue
            out.append(DoctorCheck(check: "claude login", status: macInUse ? .warn : .ok, detail: p + (macInUse ? "" : " (not used: the default account is \(accounts.defaultAccount))")))
        }
        if listItems {
            let items = keychain.items(servicePrefix: ClaudeLogin.baseService)
            if items.count > 1 {
                var known: [String: String] = [ClaudeLogin.baseService: "~/.claude"]
                for a in accounts.accounts where a.kind == .mac { known[ClaudeLogin.service(configDir: a.configDir)] = a.configDir ?? "~/.claude" }
                let list = items.map { i -> String in
                    let name = i.service == ClaudeLogin.baseService ? "default" : String(i.service.dropFirst(ClaudeLogin.baseService.count + 1))
                    let modified = i.modified.map { " written \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
                    return "\(name) (\(known[i.service] ?? "unknown dir")\(modified.isEmpty ? "" : ",")\(modified))"
                }
                out.append(DoctorCheck(check: "claude logins", status: .ok, detail: "\(items.count) in the keychain: " + list.joined(separator: " · ")))
            }
        }
        let rows = accounts.accounts.map { a -> String in
            var s = a.name + (accounts.defaultAccount == a.name ? " (default)" : "")
            switch a.kind {
            case .mac: s += a.configDir.map { " (Mac login, \($0))" } ?? ""
            case .setupToken: s += " (setup-token" + (a.expiresAt.map { ", expires \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "") + ")"
            case .apiKey: s += " (api-key)"
            }
            return s
        }
        let expiring = accounts.accounts.filter { a in a.kind != .mac && (a.expiresAt.map { $0.timeIntervalSince(now) < 30 * 86_400 } ?? false) }
        out.append(DoctorCheck(check: "accounts", status: expiring.isEmpty ? .ok : .warn,
                               detail: rows.joined(separator: " · ") + (accounts.defaultAccount == "none" ? " · default: none" : "")
                               + (accounts.keepalive ? " · keep-alive on" : "")
                               + (expiring.isEmpty ? "" : " — \(expiring.map(\.name).joined(separator: ", ")) expire\(expiring.count == 1 ? "s" : "") within 30 days: claude setup-token, then snooze account add NAME --setup-token --force")))
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
