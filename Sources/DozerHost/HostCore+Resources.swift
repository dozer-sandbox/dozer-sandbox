import Foundation
import DozerKit

// 595 — Resources in the host: the facts the inventory needs, the report, deletions (one host
// operation, run with nothing that touches the store's disks under way — serialised with the
// lifecycle, R3), and which kernel new sandboxes boot (R5).
extension HostCore {
    /// Operations that create, boot, clone or remove disks: a resource deletion never runs beside one.
    static let diskOps: Set<HostOp> = [.create, .start, .wake, .pause, .resume, .sleep, .hibernate, .shutdown, .reset, .rm,
                                       .pointTake, .pointRevert, .pointFork, .pointRm, .pointSaveImage, .templateCreate, .duplicate,
                                       .imageBake, .imageRm, .prepare, .onboard, .openSession]

    /// What the files do not say: phases, what new sandboxes get, what is being prepared, the kernels, …
    func resourceFacts() async -> ResourceFacts {
        let settings = DozerSettings.load()
        var sbx: [ResourceFacts.SandboxFact] = []
        for m in managed.values {
            let phase = await effectivePhase(m)
            let busy = await m.sandbox.status.busy
            let returned = await m.sandbox.memoryReturnedMiB
            let spec = m.sandbox.spec
            let p = PersistedSandbox.read(from: m.sandbox.layout.persistedState)
            let snapshot = [.paused, .asleep, .hibernated].contains(phase)
            sbx.append(.init(name: m.name, phase: phase, busy: busy, image: m.config.image, createdAt: m.config.createdAt,
                             rootImage: p?.rootImage, workspace: m.config.workspace, shares: spec.shares.map(\.hostPath),
                             memoryMiB: spec.memoryMiB, ramHeldMiB: phase.holdsRAM ? spec.memoryMiB - min(spec.memoryMiB, returned) : 0,
                             cpus: spec.cpus, snapshotKernelSHA256: snapshot ? p?.vmLayout?.kernelSHA256 : nil,
                             snapshotKernelFile: snapshot ? p?.vmLayout?.kernelFile : nil, kernelPath: spec.kernelPath))
        }
        var keys: [String: String] = [:]
        for row in (try? images()) ?? [] where row.kind == "builtin" { if let k = row.key { keys[row.name] = k } }
        let cache = settings.string(SettingKey.kernelCache).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? store.layout("_").kernels
        let current = settings.string(SettingKey.kernelPath).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? cache.appendingPathComponent(KernelArtifact.recommended.fileName)
        let midnight = Calendar.current.startOfDay(for: Date())
        let sinceMinute = Int64(midnight.timeIntervalSince1970 / 60)
        let network: [ResourceNetwork] = metrics?.networkTotals(sinceMinute: sinceMinute)
            ?? (FileManager.default.fileExists(atPath: store.metrics.path) ? (try? MetricsStore(url: store.metrics))?.networkTotals(sinceMinute: sinceMinute) : nil)
            ?? []
        var facts = ResourceFacts(sandboxes: sbx.sorted { $0.name < $1.name }, currentImageKeys: keys, preparing: Set(runningPreparations()),
                                  kernelCache: cache, currentKernel: current,
                                  unusedDays: settings.int(SettingKey.resourcesUnusedDays),
                                  preparationSeconds: PreparationRecord.all(store).mapValues(\.seconds),
                                  hostFootprintBytes: readOnly ? nil : Resources.footprint(), network: network,
                                  settingsFile: DozerSettings.fileURL(), accounts: accountStore.load().accounts.map(\.name).sorted(),
                                  executable: HostLauncher.executablePath)
        // 596: Apple's container tool, measured off the actor (its data folder can be gigabytes).
        facts.appleContainer = await Task.detached { AppleContainerFacts.current() }.value
        return facts
    }

    /// The inventory (every disk's extent map is read: off the actor).
    func resourceReport() async -> ResourceReport {
        let facts = await resourceFacts()
        let s = store
        return await Task.detached { Resources.inventory(store: s, facts: facts) }.value
    }

    /// Why a deletion cannot run NOW (something that touches the store's disks is under way), or nil.
    func resourcesBusy() async -> String? {
        if diskOpsInFlight > 0 { return "an operation on a sandbox or an image is under way" }
        if let p = runningPreparations().first { return "\(p) is being prepared" }
        for m in managed.values {
            if await m.sandbox.status.busy { return "\(m.name) is busy" }
            if await m.sandbox.phase == .booting { return "\(m.name) is starting" }
        }
        return nil
    }

    /// `resources-rm` / `resources-clean`: plan (dry run), or delete — waiting (≤ 2 min) until nothing
    /// that touches the store's disks is under way, then deciding and deleting with no suspension in
    /// between (the actor runs nothing else meanwhile).
    func resourcesRemove(_ r: HostRequest, emit: @escaping @Sendable (HostEvent) -> Void) async throws -> ResourcePlan {
        let clean = r.op == .resourcesClean
        let ids = r.ids ?? []
        if !clean {
            guard !ids.isEmpty else { throw HostError(.invalid, "which resources? (doz resources lists their ids)") }
            guard ids.count <= 500 else { throw HostError(.invalid, "at most 500 resources at once") }
            for id in ids where !Resources.isValidID(id) { throw HostError(.invalid, "not a resource id: \(id.prefix(80)) (doz resources lists them)") }
        }
        if r.dryRun == true {
            let facts = await resourceFacts()
            let s = store
            return await Task.detached { Resources.plan(store: s, facts: facts, ids: ids, clean: clean) }.value
        }
        let deadline = Date().addingTimeInterval(120)
        var said = false
        while true {
            if let busy = await resourcesBusy() {
                guard Date() < deadline else { throw HostError(.invalidPhase, "\(busy) — nothing was deleted; try again when it has finished") }
                if !said { emit(HostEvent(kind: .note, sandbox: nil, text: "waiting: \(busy)")); said = true }
                try await Task.sleep(for: .milliseconds(300))
                continue
            }
            let facts = await resourceFacts()
            // Nothing may have started while the facts were read: then decide and delete at once.
            guard diskOpsInFlight == 0, runningPreparations().isEmpty else { continue }
            let plan = Resources.plan(store: store, facts: facts, ids: ids, clean: clean)
            let metrics = self.metrics, run = self.metricsRun, url = store.metrics, readOnly = self.readOnly
            let done = Resources.execute(plan, store: store) {
                if let metrics { try metrics.clearHistory(keepingRun: readOnly ? nil : run) }
                else if FileManager.default.fileExists(atPath: url.path) { try MetricsStore(url: url).clearHistory(keepingRun: nil) }
            }
            for id in done.deleted { emit(HostEvent(kind: .step, sandbox: nil, text: "deleted \(id)", milliseconds: 0)) }
            note(nil, "resources: deleted \(done.deleted.joined(separator: ", "))"
                 + (done.refused.isEmpty ? "" : "; refused \(done.refused.map(\.id).joined(separator: ", "))")
                 + (done.failed.isEmpty ? "" : "; failed \(done.failed.map(\.id).joined(separator: ", "))")
                 + " — freed \(DozerImages.formatBytes(done.freedBytes))")
            return done
        }
    }

    /// `resources-kernel`: the kernel NEW sandboxes boot — `kernel:<version>` from the kernel cache, or
    /// `pinned` (this build's). Existing sandboxes keep theirs; a wake always restores into the kernel its
    /// snapshot was taken with (591's layout check).
    func resourcesKernel(_ r: HostRequest) async throws -> ResourceKernelChoice {
        guard let k = r.kernel, k == "pinned" || (k.hasPrefix("kernel:") && Resources.isValidID(k)) else {
            throw HostError(.invalid, "which kernel? (kernel:<version> as doz resources lists it, or pinned)")
        }
        let settings = DozerSettings.load()
        guard settings.resolve(SettingKey.kernelPath).source != .env else {
            throw HostError(.invalid, "DOZ_KERNEL sets the kernel in this host's environment — change it there")
        }
        let cache = settings.string(SettingKey.kernelCache).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? store.layout("_").kernels
        var path: String?
        if k != "pinned" {
            let file = cache.appendingPathComponent("vmlinux-" + String(k.dropFirst(7)))
            guard FileManager.default.fileExists(atPath: file.path) else { throw HostError(.notFound, "no \(k) in the kernel cache (doz resources lists the kernels)") }
            path = file.path
            if file.lastPathComponent == KernelArtifact.recommended.fileName { path = nil }
        }
        do { try settings.writing(SettingKey.kernelPath, path.map(TOMLValue.string)) } catch let e as SettingsError { throw HostError(.invalid, e.message) }
        note(nil, "new sandboxes boot \(path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "the pinned kernel (\(KernelArtifact.recommended.fileName))") — existing ones keep theirs")
        return ResourceKernelChoice(kernel: path == nil ? "pinned" : k, note: "new sandboxes boot it; existing ones keep theirs, and a wake keeps its snapshot's kernel")
    }
}

/// `resources-kernel`'s answer.
public struct ResourceKernelChoice: Codable, Equatable, Sendable {
    public var kernel: String
    public var note: String
}
