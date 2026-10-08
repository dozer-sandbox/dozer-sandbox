import ArgumentParser
import Darwin
import Foundation
import Security
import DozerKit
import DozerHost
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
        let checks = Self.checks(store: g.dozerStore)
        if g.json { Out.json(checks) } else {
            for c in checks {
                let mark = switch c.status { case .ok: "ok  "; case .warn: "warn"; case .fail: "FAIL" }
                Out.stdout("\(mark)  \(c.check.padding(toLength: 15, withPad: " ", startingAt: 0)) \(c.detail)\n")
            }
        }
        if checks.contains(where: { $0.status == .fail }) { throw ExitCode(DozerExit.failed) }
        // 594: a store never onboarded says how to start.
        if !g.json, OnboardingRecord.read(g.dozerStore) == nil {
            Out.stdout("\nthis store has not been onboarded — doz onboard sets up this Mac (checks, account, settings, images)\n")
        }
    }

    /// `claude: false` (594: `doz onboard --account …`) leaves out the Claude Code checks — the ones
    /// that run `claude --version` and read the Mac login's keychain item.
    static func checks(store: DozerStore, claude: Bool = true) -> [DoctorCheck] {
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
                                           : "this binary lacks com.apple.security.virtualization: build it with `make cli` (it signs), or codesign --entitlements Scripts/doz.entitlements"))
        let deckhold = DeckholdBinary.locate(), net = DoznetBinary.locate()
        out.append(DoctorCheck(check: "guest tools", status: deckhold != nil && net != nil ? .ok : .fail,
                               detail: deckhold != nil && net != nil ? "deckhold + doznet found (\(deckhold!.deletingLastPathComponent().path))"
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
                                   detail: "\(store.root.path) — \(format), \(DozerImages.formatBytes(free)) free, \(store.sandboxNames().count) sandbox(es)"
                                   + (apfs ? "" : " — not APFS: disks are copied instead of cloned") + (free > 10 << 30 ? "" : " — under 10 GiB free")))
        } else {
            out.append(DoctorCheck(check: "store", status: .ok, detail: "\(store.root.path) — not created yet (the first create makes it)"))
        }
        if !store.socketPathFits {
            out.append(DoctorCheck(check: "socket", status: .fail, detail: "\(store.socket.path) is over 103 bytes — use a shorter --store"))
        }
        let kernelDir = DozerSettings.load().string(SettingKey.kernelCache).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? store.layout("_").kernels
        let provider = KernelProvider(cacheDirectory: kernelDir)
        let kernel = provider.cachedKernel
        if fm.fileExists(atPath: kernel.path) {
            out.append(DoctorCheck(check: "kernel", status: .ok, detail: "\(KernelArtifact.recommended.fileName) cached (\(kernelDir.path))"))
        } else if provider.localSeed() != nil {
            // 594 W5: Apple's container kernels hold a byte-identical copy: it is copied, not downloaded.
            out.append(DoctorCheck(check: "kernel", status: .ok,
                                   detail: "found locally (Apple's container kernels, byte-identical to the pin) — no download needed"))
        } else {
            out.append(DoctorCheck(check: "kernel", status: .warn, detail: "not cached yet — the first start downloads it (~570 MiB, once)"))
        }
        // 599h: the tools layer's downloads on this Mac (gh, for sandboxes with GitHub as you).
        let toolsCache = ToolsCache(root: store.root.appendingPathComponent("tools"))
        if let e = toolsCache.entries().first {
            out.append(DoctorCheck(check: "tools layer", status: .ok,
                                   detail: "\(e.id) \(e.version) cached (\(e.bytes / 1_048_576) MiB, sha256 checked) — copied into sandboxes with GitHub as you"))
        } else {
            out.append(DoctorCheck(check: "tools layer", status: .ok,
                                   detail: "gh \(ToolsLayer.ghVersion) not downloaded yet — the first sandbox with GitHub as you fetches it (~14 MB, once)"))
        }
        // EXPERIMENTAL: audio sandboxes — the sound kernel this doz carries, and who macOS asks about the microphone.
        do {
            let carried = MacAudio.bundledSoundKernel()
            let ok = carried.map(SoundKernel.isVerified) ?? false
            let who = MacAudio.responsibleApp()?.description ?? "an app macOS did not name"
            out.append(DoctorCheck(check: "audio", status: .ok,
                                   detail: "experimental — " + (ok ? "the sound kernel is here (\(SoundKernel.fileName), sha256 checked) — doz create --audio works"
                                               : carried == nil ? "this doz carries no sound kernel — doz create --audio is not available"
                                                                : "the sound kernel beside this doz is damaged (sha256 differs) — reinstall doz")
                                       + "; a host started from here asks macOS for the microphone as \(who)"))
        }
        // 594 W28: an agent image an older doz made, or a newer agent release — said, never rebuilt by itself.
        let settings = DozerSettings.load()
        for image in ["claude-code", "pi", "codex"] {
            let s = AgentVersions.standing(image, store: store, settings: settings)
            guard s.version != nil else { continue }
            var parts: [String] = []
            if let o = s.olderRecipeLine { parts.append(o) }
            if let a = s.available, let v = s.version { parts.append("\(AgentImages.agentName(image) ?? image) \(a) is available (image has \(v))") }
            out.append(parts.isEmpty
                ? DoctorCheck(check: "image \(image)", status: .ok, detail: "up to date (\(s.version!))")
                : DoctorCheck(check: "image \(image)", status: .warn, detail: parts.joined(separator: "; ") + " — rebuild when ready: doz image bake \(image) (existing sandboxes keep their disks)"))
        }
        out.append(DoctorCheck(check: "vmnet", status: .ok,
                               detail: "needed only for --network nat (a free 192.168.100–199.0/24 subnet is picked); proxied sandboxes have no interface"))
        // The host.
        if store.hostIsRunning() {
            var detail = "running, pid \(store.hostPID().map(String.init) ?? "?")"
            var status = DoctorCheck.Status.ok
            if let m = try? HostClient.request(HostRequest(.ping), store: store, autostart: false),
               let st = try? m.result?.decode(HostStatus.self) {
                detail += ", \(st.version), \(st.liveSandboxes.count) running, idle timeout \(st.idleTimeoutMinutes.formatted()) min"
                if st.version != DozerCommand.version { status = .warn; detail += " — this CLI is \(DozerCommand.version): doz host stop" }
                // 593: a host never lives in a client's process tree (stopping that tree killed one mid-save).
                if let pp = st.parentPid {
                    if pp == 1 {
                        detail += ", parent launchd (detached)"
                    } else if st.launchedDetached == false {
                        detail += ", parent \(pp) — run in the foreground on purpose (doz host start --foreground)"
                    } else {
                        if status == .ok { status = .warn }
                        detail += ", parent \(pp), NOT launchd — it lives in another process's tree, and stopping that tree stops it: doz host stop, then let a command start it again"
                    }
                }
                if let app = st.microphoneApp { detail += ", microphone asked as \(app) (audio sandboxes)" }
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
            // 608: a sandbox whose live view of its workspace could not start is shared directly — say so.
            var ls = HostRequest(.ls); ls.withSessions = false
            if let m = try? HostClient.request(ls, store: store, autostart: false), let rows = try? m.result?.decode([SandboxInfo].self) {
                let fb = rows.filter { $0.workspaceView == "fallback" }.map(\.name)
                if !fb.isEmpty {
                    out.append(DoctorCheck(check: "workspace view", status: .warn,
                                           detail: "\(fb.joined(separator: ", ")): the live view of /workspace could not start, so the folder is shared directly — a program working there loses its folder at a wake from hibernation. The sandbox's boot log says why; a restart (doz shutdown + start) tries again"))
                }
            }
        } else {
            let recover = store.needsRecovery()
            out.append(DoctorCheck(check: "host", status: recover.isEmpty ? .ok : .warn,
                                   detail: recover.isEmpty ? "not running (nothing is — the next command that needs it starts it)"
                                                           : "not running, and \(recover.joined(separator: ", ")) had a VM when the last host went away — the next command recovers it"))
        }
        let metricsOK = fm.fileExists(atPath: store.metrics.path)
        out.append(DoctorCheck(check: "metrics", status: .ok, detail: metricsOK ? store.metrics.path : "none yet"))
        // 611: under a test seam the Mac's own Claude login (keychain, ~/.claude, its binary) is never looked at.
        if claude, ProcessInfo.processInfo.environment["DOZ_TEST_NO_MAC_LOGIN"] == "1" {
            out.append(DoctorCheck(check: "claude login", status: .ok, detail: "not looked at (DOZ_TEST_NO_MAC_LOGIN=1)"))
        } else if claude { out += claudeChecks(store: store, keychain: macLoginKeychain()) }
        out.append(codexLoginCheck(home: CodexMacLogin.resolveHome(), settings: .load()))
        out += ServeDoctor.checks(store: store, settings: .load())
        return out
    }

    /// 599i rc.3: this Mac's Codex login (`mac` for Codex) — read-only: its state and expiry, never a token.
    static func codexLoginCheck(home: URL?, settings: DozerSettings, now: Date = Date()) -> DoctorCheck {
        let r = CodexMacLogin.read(home, now: now)
        let keep = settings.bool(SettingKey.codexKeepAlive)
        switch r.state {
        case .ok:
            let exp = r.token?.expiresAt.map { " — access token until \(CredentialVaultClock.hm($0))" } ?? ""
            return DoctorCheck(check: "codex login", status: .ok, detail: "this Mac's Codex is signed in (ChatGPT)\(exp) · Codex sandboxes can use it as mac · renews while Codex runs on this Mac"
                               + (keep ? " · keep-alive on" : ""))
        case .expired:
            return DoctorCheck(check: "codex login", status: .warn, detail: "this Mac's Codex login has expired — run codex on the Mac (it renews it), or turn on codex.keep_alive")
        case .signedOut:
            return DoctorCheck(check: "codex login", status: .ok, detail: "this Mac's Codex is not signed in — Codex sandboxes need another account (doz account add NAME --chatgpt)")
        case .keyring, .apiKey, .unreadable:
            return DoctorCheck(check: "codex login", status: .warn, detail: CodexMacSession(codexHome: home, keepaliveEnabled: { false }).problem(now: now) ?? r.state.label)
        }
    }

    /// 588: the Mac's Claude Code, its login(s), and the store's accounts. Reads only: `claude
    /// --version`, the keychain item (parsed in memory, never printed), attributes of the others.
    static func claudeChecks(store: DozerStore, keychain: KeychainAccess, now: Date = Date(),
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
            var s = a.name + (accounts.defaultAccount == a.name || accounts.openaiDefault == a.name ? " (default)" : "")
            switch a.kind {
            case .mac: s += a.configDir.map { " (Mac login, \($0))" } ?? ""
            case .setupToken: s += " (setup-token" + (a.expiresAt.map { ", expires \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "") + ")"
            case .apiKey: s += " (api-key)"
            case .openaiKey: s += " (openai-key)"
            case .chatgpt: s += " (chatgpt" + (a.plan.map { ", \($0)" } ?? "") + ")"
            case .codexMac: s += " (codex-mac)"
            }
            return s
        }
        let expiring = accounts.accounts.filter { a in a.kind != .mac && (a.expiresAt.map { $0.timeIntervalSince(now) < 30 * 86_400 } ?? false) }
        out.append(DoctorCheck(check: "accounts", status: expiring.isEmpty ? .ok : .warn,
                               detail: rows.joined(separator: " · ") + (accounts.defaultAccount == "none" ? " · default: none" : "")
                               + (accounts.keepalive ? " · keep-alive on" : "")
                               + (expiring.isEmpty ? "" : " — \(expiring.map(\.name).joined(separator: ", ")) expire\(expiring.count == 1 ? "s" : "") within 30 days: claude setup-token, then doz account add NAME --setup-token --force")))
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
