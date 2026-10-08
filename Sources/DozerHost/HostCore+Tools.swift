import Foundation
import DozerKit

// 599h — the tools layer in the host: what each sandbox's settings call for (`ToolInputs`, set beside the
// GitHub setup — whenever a permission or setting changes), where gh comes from (the store's `ToolsCache`:
// downloaded once, pinned, sha256-checked), and the `tools` / `tools-apply` ops (the plan + the last apply;
// apply again now — the wizard's Retry, `doz tools NAME --apply`).

/// One cache per tools directory in this process (callers of a download join it).
enum ToolsCacheRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var caches: [String: ToolsCache] = [:]
    static func cache(for root: URL) -> ToolsCache {
        lock.lock(); defer { lock.unlock() }
        if let c = caches[root.path] { return c }
        let c = ToolsCache(root: root)
        caches[root.path] = c
        return c
    }
}

/// `doz tools NAME`: the plan (each tool, why, from where) and the last apply's results.
public struct ToolsLayerReport: Codable, Equatable, Sendable {
    public var sandbox: String
    public var inputs: ToolInputs
    public var plan: ToolPlan
    /// The last apply in this host (nil: none yet — it runs at every start and wake).
    public var last: ToolsReport?
    /// What this Mac's store keeps (gh's verified copy).
    public var cached: [ToolsCache.Entry]
}

extension HostCore {
    /// What the sandbox's settings call for now.
    func toolInputs(_ m: Managed) -> ToolInputs {
        let proxied = m.sandbox.egress != nil
        let mode = proxied ? AgentPermissions.gitHubMode(m.sandbox.egress?.policy.permissions) : nil
        return ToolInputs(github: mode != nil,
                          ssh: proxied && Self.sandboxValue(m.config, SettingKey.sshAgent) == .string("on"),
                          tmux: Self.sandboxValue(m.config, SettingKey.tmux) == .bool(true),
                          audio: m.config.spec.audio == true, audioApp: Self.microphoneApp?.name)
    }

    /// EXPERIMENTAL (604): the Mac app macOS asks about the microphone for, for this process (looked up once).
    nonisolated static let microphoneApp: MacAudio.ResponsibleApp? = MacAudio.responsibleApp()

    /// Give the sandbox its tool inputs and gh's source; on a RUNNING sandbox whose inputs changed, apply the
    /// layer now (quietly — the viewers are told when something changed or failed).
    func applyToolInputs(_ m: Managed) {
        guard !readOnly else { return }
        let inputs = toolInputs(m)
        let before = m.sandbox.toolInputs
        m.sandbox.setToolInputs(inputs)
        let cache = toolsCache
        m.sandbox.setGhFetcher({ await cache.ensureGh() })
        guard before != inputs else { return }
        let sb = m.sandbox, name = m.name
        Task { [weak self] in
            guard await sb.status.phase == .running else { return }
            guard let r = await sb.applyToolsNow(loud: false), r.changed || r.failed else { return }
            await self?.toolsChanged(name, r)
        }
    }

    /// A quiet apply that changed or failed something: one notice to the sandbox's viewers.
    func toolsChanged(_ name: String, _ r: ToolsReport) {
        let text = "\(name): tools layer — \(r.summary)"
        note(name, text)
        bridgeState.notifyViewers(name, BridgeNotice("tools", text))
    }

    /// `tools` (read) and `tools-apply` (apply again now, shown as steps).
    func tools(_ m: Managed, apply: Bool, emit: @escaping @Sendable (HostEvent) -> Void) async -> ToolsLayerReport {
        applyToolInputs(m)
        var last = m.sandbox.lastToolsReport
        if apply {
            let events = m.sandbox.events()
            let name = m.name
            let relay = Task {
                for await e in events {
                    switch e {
                    case .step(let s, _), .stepStarted(let s), .stepFailed(let s, _, _):
                        if s.hasPrefix("tools: "), let h = HostEvent(e, sandbox: name) { emit(h) }
                    default: break
                    }
                }
            }
            last = await m.sandbox.applyToolsNow(loud: true) ?? last
            try? await Task.sleep(for: .milliseconds(50))
            relay.cancel()
        }
        let inputs = m.sandbox.toolInputs ?? toolInputs(m)
        return ToolsLayerReport(sandbox: m.name, inputs: inputs, plan: ToolsLayer.plan(inputs), last: last, cached: toolsCache.entries())
    }
}

extension HostCore {
    /// 606 (rc.2): the app macOS attributes THIS process to ("Name (bundle id)") — what Local Network privacy asks on
    /// behalf of for doz serve's Bonjour announcement (it survives the detached double spawn, as the microphone's does).
    public static var responsibleAppDescription: String? { microphoneApp?.description }
}
