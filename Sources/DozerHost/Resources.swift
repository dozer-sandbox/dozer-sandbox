import Darwin
import Foundation
import DozerKit

// 595 (owner, 2026-09-30): "add a Resources section … that shows all the resources used by Dozer and a
// way to manage them". Resources is first an ACCOUNT of everything Dozer uses (R0): every byte of the
// store attributed to a row — a final "unattributed" row that must be ~0 — plus the memory and CPUs it
// holds and the traffic through its proxy. Management stays where it lives (Images, a sandbox's page,
// Accounts & keys); Resources' own deletions are for what has no other home (caches, base disks, the
// guest init, kernels, logs, metrics, leftovers, stray files) — R2–R5.
//
// Three honest numbers per row (R1): SIZE on disk (allocated blocks, as `du` counts them — an APFS
// clone counts in full each time), FREED if deleted (the blocks only it references: 587's
// `DiskAccounting` extents for disks, the allocation for anything else), USED BY. The inventory is
// PURE over the store's files and a few facts the host supplies (`ResourceFacts`), so it is a unit test.

/// One row (a group's parent, or a leaf).
public struct ResourceItem: Codable, Equatable, Sendable {
    public var id: String
    /// sandboxes · images · caches · logs · store · stray · outside
    public var group: String
    public var parent: String?
    public var name: String
    public var detail: String?
    public var sizeBytes: Int64?
    public var freedBytes: Int64?
    public var usedBy: [String]
    /// Where it is managed: `images`, `sandbox:NAME`, `accounts`, `settings` (nil: here).
    public var link: String?
    public var deletable: Bool
    /// Why it cannot be deleted (here, or now).
    public var refusal: String?
    public var recreatable: Bool
    /// What deleting it costs later.
    public var later: String?
    /// In "Clean up"'s safe set (R4): re-creatable and unused.
    public var cleanable: Bool
    /// A kernel / an image key new boots and new sandboxes use.
    public var current: Bool?
    public var warning: String?
    /// Where it is (the CLI shows it; never projected to the browser).
    public var path: String?

    public init(id: String, group: String, parent: String? = nil, name: String, detail: String? = nil, sizeBytes: Int64? = 0,
                freedBytes: Int64? = nil, usedBy: [String] = [], link: String? = nil, deletable: Bool = false, refusal: String? = nil,
                recreatable: Bool = false, later: String? = nil, cleanable: Bool = false, current: Bool? = nil, warning: String? = nil,
                path: String? = nil) {
        self.id = id; self.group = group; self.parent = parent; self.name = name; self.detail = detail
        self.sizeBytes = sizeBytes; self.freedBytes = freedBytes; self.usedBy = usedBy; self.link = link
        self.deletable = deletable; self.refusal = refusal; self.recreatable = recreatable; self.later = later
        self.cleanable = cleanable; self.current = current; self.warning = warning; self.path = path
    }
}

/// Memory Dozer holds (R0): each sandbox with a VM, the host, the UI.
public struct ResourceMemory: Codable, Equatable, Sendable {
    /// `sandbox`, `host` or `ui`.
    public var kind: String
    public var name: String
    public var phase: String?
    /// What it costs the Mac now (a VM: its allocation less what the balloon returned).
    public var heldBytes: Int64
    public var allocationBytes: Int64?
    public var cpus: Int?
    public init(kind: String, name: String, phase: String? = nil, heldBytes: Int64, allocationBytes: Int64? = nil, cpus: Int? = nil) {
        self.kind = kind; self.name = name; self.phase = phase; self.heldBytes = heldBytes
        self.allocationBytes = allocationBytes; self.cpus = cpus
    }
}

/// Proxy traffic per sandbox (R0), from the metrics.
public struct ResourceNetwork: Codable, Equatable, Sendable {
    public var sandbox: String
    public var upToday: Int64
    public var downToday: Int64
    public var upTotal: Int64
    public var downTotal: Int64
    public var connectionsTotal: Int
    public init(sandbox: String, upToday: Int64 = 0, downToday: Int64 = 0, upTotal: Int64 = 0, downTotal: Int64 = 0, connectionsTotal: Int = 0) {
        self.sandbox = sandbox; self.upToday = upToday; self.downToday = downToday
        self.upTotal = upTotal; self.downTotal = downTotal; self.connectionsTotal = connectionsTotal
    }
}

/// A kernel (R5).
public struct ResourceKernel: Codable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var sha256: String?
    public var sizeBytes: Int64
    /// New sandboxes boot it (the setting `kernel.path`, else the pinned kernel).
    public var current: Bool
    /// The pinned kernel of this build.
    public var pinned: Bool
    public var inStore: Bool
    /// Sandboxes whose snapshot needs it, or whose spec boots it (created with `kernel.path` naming it).
    public var usedBy: [String]
    public init(id: String, version: String, sha256: String?, sizeBytes: Int64, current: Bool, pinned: Bool, inStore: Bool, usedBy: [String]) {
        self.id = id; self.version = version; self.sha256 = sha256; self.sizeBytes = sizeBytes
        self.current = current; self.pinned = pinned; self.inStore = inStore; self.usedBy = usedBy
    }
}

public struct ResourceReport: Codable, Equatable, Sendable {
    public var store: String
    public var measuredAt: Date
    public var milliseconds: Double
    /// The store measured as `du` does (allocated blocks, a hard link once).
    public var totalBytes: Int64
    /// What the rows add up to; `unattributedBytes` = the difference (R0: ~0).
    public var attributedBytes: Int64
    public var unattributedBytes: Int64
    /// What the store occupies with shared blocks counted once (APFS clones).
    public var occupiedBytes: Int64
    /// What "Clean up" would free now.
    public var cleanableBytes: Int64
    public var volumeFreeBytes: Int64?
    public var volumeTotalBytes: Int64?
    public var items: [ResourceItem]
    public var memory: [ResourceMemory]
    public var machineCPUs: Int
    public var allocatedCPUs: Int
    public var network: [ResourceNetwork]
    public var kernels: [ResourceKernel]
    public var unusedDays: Int

    public init(store: String, measuredAt: Date, milliseconds: Double, totalBytes: Int64, attributedBytes: Int64, unattributedBytes: Int64,
                occupiedBytes: Int64, cleanableBytes: Int64, volumeFreeBytes: Int64?, volumeTotalBytes: Int64?, items: [ResourceItem],
                memory: [ResourceMemory], machineCPUs: Int, allocatedCPUs: Int, network: [ResourceNetwork], kernels: [ResourceKernel], unusedDays: Int) {
        self.store = store; self.measuredAt = measuredAt; self.milliseconds = milliseconds; self.totalBytes = totalBytes
        self.attributedBytes = attributedBytes; self.unattributedBytes = unattributedBytes; self.occupiedBytes = occupiedBytes
        self.cleanableBytes = cleanableBytes; self.volumeFreeBytes = volumeFreeBytes; self.volumeTotalBytes = volumeTotalBytes
        self.items = items; self.memory = memory; self.machineCPUs = machineCPUs; self.allocatedCPUs = allocatedCPUs
        self.network = network; self.kernels = kernels; self.unusedDays = unusedDays
    }
}

/// A deletion's plan (and, when run, its outcome) — R3.
public struct ResourcePlan: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var freedBytes: Int64
        public var later: String?
        public var warning: String?
        public init(id: String, name: String, freedBytes: Int64, later: String? = nil, warning: String? = nil) {
            self.id = id; self.name = name; self.freedBytes = freedBytes; self.later = later; self.warning = warning
        }
    }
    public struct Refused: Codable, Equatable, Sendable {
        public var id: String
        public var reason: String
        public init(id: String, reason: String) { self.id = id; self.reason = reason }
    }
    public var items: [Entry]
    public var refused: [Refused]
    /// What the whole selection frees (shared blocks between its items counted once).
    public var freedBytes: Int64
    public var dryRun: Bool
    public var deleted: [String]
    public var failed: [Refused]
    /// `clean`: the safe set (R4).
    public var clean: Bool
    public init(items: [Entry], refused: [Refused] = [], freedBytes: Int64, dryRun: Bool, deleted: [String] = [], failed: [Refused] = [], clean: Bool = false) {
        self.items = items; self.refused = refused; self.freedBytes = freedBytes; self.dryRun = dryRun
        self.deleted = deleted; self.failed = failed; self.clean = clean
    }
}

/// What the host knows that the files do not say.
public struct ResourceFacts: Sendable {
    public struct SandboxFact: Sendable {
        public var name: String
        public var phase: Phase
        public var busy: Bool
        public var image: String
        public var createdAt: Date
        public var rootImage: String?
        public var workspace: String?
        public var shares: [String]
        public var memoryMiB: UInt64
        public var ramHeldMiB: UInt64
        public var cpus: Int
        /// The kernel its snapshot needs (a paused, asleep or hibernated sandbox's `VMLayout`).
        public var snapshotKernelSHA256: String?
        public var snapshotKernelFile: String?
        /// The explicit kernel its spec boots (`SandboxSpec.kernelPath`; nil: the build's pinned one).
        public var kernelPath: String?
        public init(name: String, phase: Phase, busy: Bool = false, image: String, createdAt: Date, rootImage: String? = nil,
                    workspace: String? = nil, shares: [String] = [], memoryMiB: UInt64 = 0, ramHeldMiB: UInt64 = 0, cpus: Int = 0,
                    snapshotKernelSHA256: String? = nil, snapshotKernelFile: String? = nil, kernelPath: String? = nil) {
            self.name = name; self.phase = phase; self.busy = busy; self.image = image; self.createdAt = createdAt
            self.rootImage = rootImage; self.workspace = workspace; self.shares = shares; self.memoryMiB = memoryMiB
            self.ramHeldMiB = ramHeldMiB; self.cpus = cpus; self.snapshotKernelSHA256 = snapshotKernelSHA256
            self.snapshotKernelFile = snapshotKernelFile; self.kernelPath = kernelPath
        }
    }
    public var sandboxes: [SandboxFact]
    /// Image name → the key12 a new sandbox gets (lab: its prepared disk's key).
    public var currentImageKeys: [String: String]
    /// Images being prepared now.
    public var preparing: Set<String>
    /// The kernel cache directory, and the kernel new sandboxes boot.
    public var kernelCache: URL
    public var currentKernel: URL
    public var unusedDays: Int
    /// Rough preparation times (seconds) per image, from `preparations.json`.
    public var preparationSeconds: [String: Double]
    public var hostFootprintBytes: Int64?
    public var network: [ResourceNetwork]
    public var settingsFile: URL?
    public var accounts: [String]
    public var executable: String?
    public var now: Date
    /// 596: Apple's container tool (Dockerfile builds) — shown outside the store; nil: not looked at.
    public var appleContainer: AppleContainerFacts?

    public init(sandboxes: [SandboxFact] = [], currentImageKeys: [String: String] = [:], preparing: Set<String> = [],
                kernelCache: URL, currentKernel: URL, unusedDays: Int = 30, preparationSeconds: [String: Double] = [:],
                hostFootprintBytes: Int64? = nil, network: [ResourceNetwork] = [], settingsFile: URL? = nil, accounts: [String] = [],
                executable: String? = nil, now: Date = Date()) {
        self.sandboxes = sandboxes; self.currentImageKeys = currentImageKeys; self.preparing = preparing
        self.kernelCache = kernelCache; self.currentKernel = currentKernel; self.unusedDays = unusedDays
        self.preparationSeconds = preparationSeconds; self.hostFootprintBytes = hostFootprintBytes; self.network = network
        self.settingsFile = settingsFile; self.accounts = accounts; self.executable = executable; self.now = now
    }
}

public enum Resources {
    /// Store-root files that are Dozer's own records (never deleted here).
    static let storeRecords: Set<String> = ["accounts.json", "onboarded.json", "preparations.json", "agent-versions.json",
                                            "host.lock", "host.pid", "host.sock", "ui.lock", "ui.sock",
                                            // 605: doz ui's port, kept sessions, ended sessions' reasons, operations.
                                            "ui.port", "ui.sessions", "ui.revoked", "ui.operations.json",
                                            // 606: doz serve's lock and socket (its devices, audit log and port: serve/).
                                            "serve.lock", "serve.sock",
                                            // 596: the bases' resolved digests, the Dockerfiles and their builds.
                                            "base-digests.json", "dockerfiles.json",
                                            // 599e: the Access step's last checks (never a secret).
                                            "access.json"]
    static let builtInImages = ["lab", "claude-code", "pi", "codex"]
    /// 596: an image a preparation makes again (any base × agent — a template is not).
    static func isPreparedImage(_ name: String) -> Bool { builtInImages.contains(name) || ImageChoice.parse(name)?.name == name }
    /// The ids a person may name (`doz resources rm`, the page): a word, then `:` and a name.
    public static func isValidID(_ s: String) -> Bool {
        guard (1...240).contains(s.utf8.count) else { return false }
        return s.range(of: #"^(initfs|logs|metrics|cache:downloads|[a-z]+:[A-Za-z0-9][A-Za-z0-9._@/+-]*)$"#, options: .regularExpression) != nil
            && !s.contains("..")
    }

    // MARK: the walk

    /// One file (or directory) of the store, as `du` sees it.
    struct Entry {
        var rel: [String]
        var url: URL
        var allocated: Int64
        var isDisk: Bool
    }

    /// Every entry under `root` (not following links), each hard link once.
    static func walk(_ root: URL) -> (entries: [Entry], total: Int64) {
        var out: [Entry] = []
        var total: Int64 = 0
        var seen = Set<[UInt64]>()
        let base = root.standardizedFileURL.path
        func visit(_ path: String, _ rel: [String]) {
            var st = stat()
            guard lstat(path, &st) == 0 else { return }
            let kind = st.st_mode & S_IFMT
            let key = [UInt64(st.st_dev), st.st_ino]
            var alloc = Int64(st.st_blocks) * 512
            if st.st_nlink > 1, kind != S_IFDIR {
                if seen.contains(key) { alloc = 0 } else { seen.insert(key) }
            }
            total += alloc
            if !rel.isEmpty {
                out.append(Entry(rel: rel, url: URL(fileURLWithPath: path), allocated: alloc,
                                 isDisk: kind == S_IFREG && path.hasSuffix(".ext4")))
            }
            guard kind == S_IFDIR else { return }
            for n in ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted() {
                visit(path + "/" + n, rel + [n])
            }
        }
        visit(base, [])
        return (out, total)
    }

    /// The LEAF row an entry belongs to (every entry belongs to exactly one).
    static func classify(_ rel: [String], currentLabKey: String?) -> String {
        let c = rel
        let first = c[0]
        func trimLock(_ s: String) -> String { s.hasSuffix(".lock") ? String(s.dropLast(5)) : s }
        switch first {
        case "sandboxes":
            guard c.count >= 2 else { return "store" }
            let n = c[1]
            guard c.count >= 3 else { return "sandbox:\(n)/files" }
            switch c[2] {
            case "rootfs.ext4": return "sandbox:\(n)/root"
            case "state.ext4": return "sandbox:\(n)/state"
            case "vm.state": return "sandbox:\(n)/snapshot"
            case "restore-points": return c.count >= 4 ? "point:\(n)/\(c[3])" : "sandbox:\(n)/files"
            case "screens": return "screens:\(n)"
            case "boots": return "boots:\(n)"
            default: return "sandbox:\(n)/files"
            }
        case "images":
            guard c.count >= 2 else { return "store" }
            switch c[1] {
            case "bases": return c.count >= 3 ? "base:\(trimLock(c[2]))" : "store"
            case "custom": return c.count >= 3 ? "template:\(c[2])" : "store"
            default:
                return c.count >= 3 ? "image:\(c[1])@\(trimLock(c[2]))" : "image:\(c[1])"
            }
        case "golden":
            guard c.count >= 2 else { return "store" }
            let key = c[1].hasSuffix(".ext4") ? String(c[1].dropLast(5)) : trimLock(c[1])
            // The e2fsck helper's prepared disk (`FsckHelper`: `golden/<key>.fsck.ext4`).
            if trimLock(key).hasSuffix(".fsck") { return "helper:fsck" }
            return "image:lab@\(key)"
        case "content", "state.json": return "cache:downloads"
        case "tools": return "cache:tools"                       // 599h: the tools layer's downloads (gh)
        case "serve": return "store"                             // 606: doz serve's devices, audit log, port
        case "initfs.ext4": return "initfs"
        case "kernels": return c.count >= 2 ? "kernel:\(kernelVersion(c[1]))" : "store"
        case "containers": return c.count >= 2 ? "leftover:\(c[1])" : "store"
        case "metrics.sqlite", "metrics.sqlite-wal", "metrics.sqlite-shm": return "metrics"
        default:
            if c.count == 1, first.hasSuffix(".log") { return "logs" }
            if storeRecords.contains(first) { return "store" }
            // 596: a Dockerfile build's archive or import folder (removed when the build ends).
            if first.hasPrefix(".dockerfile-build-") || first.hasPrefix(".dockerfile-import-") { return "leftover:\(first)" }
            return "stray:\(first)"
        }
    }

    /// `vmlinux-6.18.15-186` → `6.18.15-186`.
    public static func kernelVersion(_ file: String) -> String { file.hasPrefix("vmlinux-") ? String(file.dropFirst(8)) : file }

    // MARK: the inventory

    public static func inventory(store: DozerStore, facts f: ResourceFacts) -> ResourceReport {
        let t0 = ContinuousClock.now
        let root = store.root.standardizedFileURL
        let labKey = f.currentImageKeys["lab"]
        let (entries, total) = walk(root)
        var byLeaf: [String: [Entry]] = [:]
        for e in entries { byLeaf[classify(e.rel, currentLabKey: labKey), default: []].append(e) }

        // Freed if deleted: disks by their extents (leaf groups and parent groups), the rest by allocation.
        let disks = entries.filter(\.isDisk)
        let lists = DiskAccounting.extentLists(disks.map(\.url))
        let leafOf = disks.map { classify($0.rel, currentLabKey: labKey) }
        var ids: [String: Int] = [:]
        func gid(_ s: String) -> Int { if let i = ids[s] { return i }; ids[s] = ids.count; return ids.count - 1 }
        let leafFreed = DiskAccounting.exclusive(lists, groups: leafOf.map(gid))
        let parentFreed = DiskAccounting.exclusive(lists, groups: leafOf.map { gid("P|" + parentID($0)) })
        let unreadable = zip(disks, lists).filter { $0.1.isEmpty }.reduce(Int64(0)) { $0 + $1.0.allocated }
        func nonDisk(_ es: [Entry]) -> Int64 { es.filter { !$0.isDisk }.reduce(0) { $0 + $1.allocated } }
        func unreadableDisks(_ es: [Entry]) -> Int64 {
            es.filter(\.isDisk).reduce(Int64(0)) { acc, e in acc + (lists[disks.firstIndex { $0.url == e.url }!].isEmpty ? e.allocated : 0) }
        }

        let sandboxes = Dictionary(f.sandboxes.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let snapshotHolders = f.sandboxes.filter { [.paused, .asleep, .hibernated].contains($0.phase) }
        let live = f.sandboxes.filter { ![.off, .failed].contains($0.phase) }
        let sandboxesUsingKey: (String) -> [String] = { key in
            f.sandboxes.filter { ($0.rootImage ?? "") == key || ($0.rootImage ?? "").hasPrefix(key) }.map(\.name)
        }
        func recentlyUsed(_ key: String) -> Bool {
            let horizon = f.now.addingTimeInterval(-Double(f.unusedDays) * 86_400)
            return f.sandboxes.contains { (($0.rootImage ?? "") == key || ($0.rootImage ?? "").hasPrefix(key)) && $0.createdAt >= horizon }
        }
        func minutes(_ image: String) -> String {
            guard let s = f.preparationSeconds[image] else { return "a few minutes" }
            return s < 90 ? "about \(max(1, Int((s / 60).rounded(.up)))) min" : "about \(Int((s / 60).rounded())) min"
        }

        var items: [ResourceItem] = []
        func add(_ it: ResourceItem) { items.append(it) }
        func leaf(_ id: String) -> (size: Int64, freed: Int64, paths: [Entry]) {
            let es = byLeaf[id] ?? []
            let size = es.reduce(Int64(0)) { $0 + $1.allocated }
            let freed = (leafFreed.freed[ids[id] ?? -1] ?? 0) + nonDisk(es) + unreadableDisks(es)
            return (size, freed, es)
        }
        func parentTotals(_ pid: String, _ leaves: [String]) -> (Int64, Int64) {
            let es = leaves.flatMap { byLeaf[$0] ?? [] }
            let size = es.reduce(Int64(0)) { $0 + $1.allocated }
            return (size, (parentFreed.freed[ids["P|" + pid] ?? -1] ?? 0) + nonDisk(es) + unreadableDisks(es))
        }
        // Where a leaf is: its top-most entry (a key's directory, a template's, a kernel file, …).
        func rel(_ id: String) -> String? { byLeaf[id]?.min { $0.rel.count < $1.rel.count }.map { $0.rel.joined(separator: "/") } }

        // Sandboxes (link to their page; restore points, saved screens and boot logs deletable).
        let sandboxNames = Set(byLeaf.keys.compactMap { k -> String? in
            for p in ["sandbox:", "point:", "screens:", "boots:"] where k.hasPrefix(p) {
                return String(k.dropFirst(p.count).split(separator: "/").first ?? "")
            }
            return nil
        }).union(f.sandboxes.map(\.name)).sorted()
        for n in sandboxNames {
            let s = sandboxes[n]
            var leaves: [String] = []
            var children: [ResourceItem] = []
            for (suffix, label) in [("root", "root disk"), ("state", "state disk (the agent's logins and history)"), ("snapshot", "snapshot (asleep or hibernated)"), ("files", "records, CA, console")] {
                let id = "sandbox:\(n)/\(suffix)"
                guard byLeaf[id] != nil else { continue }
                let l = leaf(id)
                leaves.append(id)
                children.append(ResourceItem(id: id, group: "sandboxes", parent: "sandbox:\(n)", name: label, sizeBytes: l.size, freedBytes: l.freed,
                                             usedBy: [n], link: "sandbox:\(n)", refusal: "part of \(n) — remove the sandbox on its page"))
            }
            let points = byLeaf.keys.filter { $0.hasPrefix("point:\(n)/") }.sorted()
            for id in points {
                let l = leaf(id)
                leaves.append(id)
                let meta = StoreLayout(root: root, name: n).restorePoints().first { "point:\(n)/\($0.id)" == id }
                children.append(ResourceItem(id: id, group: "sandboxes", parent: "sandbox:\(n)", name: "restore point \(meta?.name ?? String(id.split(separator: "/").last ?? ""))",
                                             detail: meta.map { "taken " + ISO8601DateFormatter().string(from: $0.createdAt) }, sizeBytes: l.size, freedBytes: l.freed,
                                             usedBy: [n], link: "sandbox:\(n)", deletable: true, later: "gone for good (a restore point cannot be re-created)",
                                             warning: "a restore point cannot be re-created"))
            }
            for (id, label, later) in [("screens:\(n)", "saved screens", "saved again at its next pause, sleep or hibernation"),
                                       ("boots:\(n)", "boot logs", "the next boot is kept again")] where byLeaf[id] != nil {
                let l = leaf(id)
                leaves.append(id)
                children.append(ResourceItem(id: id, group: "sandboxes", parent: "sandbox:\(n)", name: label, sizeBytes: l.size, freedBytes: l.freed,
                                             usedBy: [n], link: "sandbox:\(n)", deletable: true, later: later))
            }
            let (size, freed) = parentTotals("sandbox:\(n)", leaves)
            let detail = s.map { "\($0.image) · \(PhaseName.label($0.phase))" }
            add(ResourceItem(id: "sandbox:\(n)", group: "sandboxes", name: n, detail: detail, sizeBytes: size, freedBytes: freed, usedBy: [],
                             link: "sandbox:\(n)", refusal: "a sandbox is removed on its page (Remove)", path: "sandboxes/\(n)"))
            items += children
        }

        // Images and templates (managed on the Images page; deletable here too — R2).
        var imageNames = Set(byLeaf.keys.compactMap { $0.hasPrefix("image:") ? String($0.dropFirst(6).split(separator: "@").first ?? "") : nil })
        imageNames.formUnion(Self.builtInImages.filter { byLeaf.keys.contains("image:\($0)") })
        for name in imageNames.sorted() {
            let keys = byLeaf.keys.filter { $0.hasPrefix("image:\(name)@") }.sorted()
            var leaves = keys
            if byLeaf["image:\(name)"] != nil { leaves.append("image:\(name)") }
            let preparing = f.preparing.contains(name)
            let later = Self.isPreparedImage(name) ? "re-prepared when next needed (\(minutes(name)), needs network)" : nil
            var children: [ResourceItem] = []
            var allClean = !keys.isEmpty
            for id in keys {
                let key = String(id.dropFirst("image:\(name)@".count))
                let l = leaf(id)
                let usedKey = name == "lab" ? key : "\(name)@\(key)"
                let current = f.currentImageKeys[name].map { $0 == key || $0.hasPrefix(key) || key.hasPrefix($0) } ?? false
                let clean = !preparing && !recentlyUsed(usedKey)
                if !clean { allClean = false }
                children.append(ResourceItem(id: id, group: "images", parent: "image:\(name)", name: "\(name)@\(key.suffix(12))",
                                             detail: current ? "what a new \(name) sandbox gets" : "an older preparation",
                                             sizeBytes: l.size, freedBytes: l.freed, usedBy: sandboxesUsingKey(usedKey), link: "images",
                                             deletable: true, refusal: preparing ? "\(name) is being prepared — wait for it or cancel it" : nil,
                                             recreatable: current, later: current ? later : "nothing — a newer one is in use", cleanable: clean,
                                             current: current, path: rel(id)))
            }
            let (size, freed) = parentTotals("image:\(name)", leaves)
            add(ResourceItem(id: "image:\(name)", group: "images", name: name, detail: "\(keys.count) prepared disk\(keys.count == 1 ? "" : "s")",
                             sizeBytes: size, freedBytes: freed, usedBy: Array(Set(children.flatMap(\.usedBy))).sorted(), link: "images",
                             deletable: true, refusal: preparing ? "\(name) is being prepared — wait for it or cancel it" : nil,
                             recreatable: true, later: later, cleanable: allClean, path: name == "lab" ? "golden" : "images/\(name)"))
            items += children
        }
        let customs = StoreLayout(root: root, name: "_").customImages()
        for id in byLeaf.keys.filter({ $0.hasPrefix("template:") }).sorted() {
            let name = String(id.dropFirst(9))
            let l = leaf(id)
            let used = f.sandboxes.filter { ($0.rootImage ?? "").hasPrefix("custom:\(name)/") || $0.image == name || $0.image == "custom:\(name)" }.map(\.name)
            let c = customs.first { $0.name == name }
            add(ResourceItem(id: id, group: "images", name: "\(name) (template)", detail: c.map { "from \($0.fromSandbox)" },
                             sizeBytes: l.size, freedBytes: l.freed, usedBy: used, link: "images", deletable: true,
                             later: "gone for good", warning: "a template cannot be re-created", path: rel(id)))
        }

        // Caches: the download cache, base disks, the guest init, kernels.
        let quietRefusal: String? = {
            if let s = snapshotHolders.first { return "\(s.name) is \(PhaseName.label(s.phase).lowercased()) — its snapshot needs it; wake and shut it down (or shut it down) first" }
            if let s = live.first { return "\(s.name) is \(PhaseName.label(s.phase).lowercased()) — shut it down first" }
            return nil
        }()
        let preparingAny = f.preparing.isEmpty ? nil : "\(f.preparing.sorted().joined(separator: ", ")) \(f.preparing.count == 1 ? "is" : "are") being prepared"
        if byLeaf["cache:downloads"] != nil {
            let l = leaf("cache:downloads")
            add(ResourceItem(id: "cache:downloads", group: "caches", name: "download cache", detail: "OCI layers (base images, the guest init)",
                             sizeBytes: l.size, freedBytes: l.freed, usedBy: ["the next preparation"], deletable: true, refusal: preparingAny,
                             recreatable: true, later: "re-downloaded when an image is next prepared (needs network)", cleanable: preparingAny == nil,
                             path: "content, state.json"))
        }
        if byLeaf["cache:tools"] != nil {
            // 599h: the tools layer's downloads — gh, pinned and sha256-checked, copied into sandboxes from here.
            let l = leaf("cache:tools")
            add(ResourceItem(id: "cache:tools", group: "caches", name: "tools layer",
                             detail: "gh \(ToolsLayer.ghVersion) (linux-arm64, sha256 checked) — copied into sandboxes with GitHub as you",
                             sizeBytes: l.size, freedBytes: l.freed, usedBy: [], deletable: true, recreatable: true,
                             later: "downloaded again (once) when a sandbox with GitHub as you next starts or wakes", cleanable: true, path: "tools"))
        }
        for id in byLeaf.keys.filter({ $0.hasPrefix("base:") }).sorted() {
            let key = String(id.dropFirst(5))
            let l = leaf(id)
            add(ResourceItem(id: id, group: "caches", name: "base disk \(key.prefix(12))", detail: "a flattened OCI base",
                             sizeBytes: l.size, freedBytes: l.freed, usedBy: [], deletable: true, refusal: preparingAny,
                             recreatable: true, later: "re-flattened from the download cache when an image is next prepared", cleanable: preparingAny == nil,
                             path: rel(id)))
        }
        if byLeaf["initfs"] != nil {
            let l = leaf("initfs")
            add(ResourceItem(id: "initfs", group: "caches", name: "guest init", detail: "vminit's disk — every VM boots it",
                             sizeBytes: l.size, freedBytes: l.freed, usedBy: live.map(\.name), deletable: true,
                             refusal: quietRefusal ?? preparingAny, recreatable: true,
                             later: "rebuilt at the next start (needs the download cache or network)", current: true, path: "initfs.ext4"))
        }
        // Kernels — in the store's cache (rows), and the effective cache when it is elsewhere (shown, never deleted).
        var kernels: [ResourceKernel] = []
        let cacheInStore = f.kernelCache.standardizedFileURL.path.hasPrefix(root.path + "/")
        let kernelFiles = ((try? FileManager.default.contentsOfDirectory(atPath: f.kernelCache.path)) ?? []).filter { $0.hasPrefix("vmlinux") && !$0.hasSuffix(".tmp") }.sorted()
        for file in kernelFiles {
            let url = f.kernelCache.appendingPathComponent(file)
            let v = kernelVersion(file)
            let sha = try? KernelProvider.sha256(of: url)
            let current = url.standardizedFileURL.path == f.currentKernel.standardizedFileURL.path
            let snapshotUsers = snapshotHolders.filter { s in
                if let k = s.snapshotKernelSHA256, let sha { return k == sha }
                return s.snapshotKernelFile.map { URL(fileURLWithPath: $0).lastPathComponent == file } ?? current
            }.map(\.name)
            // A sandbox created with an explicit kernel (kernel.path at its create) boots that file.
            let bootUsers = f.sandboxes.filter { s in
                s.kernelPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path == url.standardizedFileURL.path } ?? false
            }.map(\.name)
            let users = Array(Set(snapshotUsers + bootUsers)).sorted()
            kernels.append(ResourceKernel(id: "kernel:\(v)", version: v, sha256: sha.map { String($0.prefix(12)) }, sizeBytes: allocatedBytes(url),
                                          current: current, pinned: file == KernelArtifact.recommended.fileName, inStore: cacheInStore, usedBy: users))
        }
        for id in byLeaf.keys.filter({ $0.hasPrefix("kernel:") }).sorted() {
            let l = leaf(id)
            let k = kernels.first { $0.id == id }
            let current = k?.current ?? false
            let pinned = k?.pinned ?? false
            let users = k?.usedBy ?? []
            // The pinned kernel is fetched again (digest-verified) when missing; any other is not.
            let refusal: String? = current && !pinned ? "new sandboxes boot it (kernel.path) — use another kernel first"
                : !users.isEmpty ? "\(users.joined(separator: ", ")) \(users.count == 1 ? "needs" : "need") it (a snapshot, or created with it)"
                : current ? quietRefusal.map { "the kernel new boots use — \($0)" } : nil
            add(ResourceItem(id: id, group: "caches", name: "kernel \(String(id.dropFirst(7)))",
                             detail: [current ? "current" : nil, pinned ? "this build's" : nil, k?.sha256.map { "sha256 \($0)" }].compactMap { $0 }.joined(separator: " · "),
                             sizeBytes: l.size, freedBytes: l.freed, usedBy: users, deletable: true, refusal: refusal, recreatable: pinned,
                             later: pinned ? "re-downloaded and verified at the next start (needs network)" : "nothing — new boots use another",
                             cleanable: !current && users.isEmpty, current: current, path: rel(id)))
        }
        if !cacheInStore {
            for k in kernels {
                add(ResourceItem(id: "outside:kernel-" + k.version, group: "outside", name: "kernel \(k.version)", detail: "the kernel cache is outside this store (kernel.cache)",
                                 sizeBytes: nil, usedBy: k.usedBy, link: "settings", refusal: "shared outside this store — not deleted here",
                                 current: k.current, path: f.kernelCache.path))
            }
        }
        if byLeaf["helper:fsck"] != nil {
            let l = leaf("helper:fsck")
            add(ResourceItem(id: "helper:fsck", group: "caches", name: "e2fsck helper disk", detail: "checks a disk copied while its VM ran",
                             sizeBytes: l.size, freedBytes: l.freed, deletable: true, refusal: preparingAny, recreatable: true,
                             later: "prepared again when a copied disk next needs a check (about a minute, needs network)",
                             cleanable: preparingAny == nil, path: rel("helper:fsck")))
        }
        // Leftovers of preparations (a bake's scratch).
        for id in byLeaf.keys.filter({ $0.hasPrefix("leftover:") }).sorted() {
            let l = leaf(id)
            add(ResourceItem(id: id, group: "caches", name: "preparation leftover \(id.dropFirst(9))", detail: "a bake's scratch space",
                             sizeBytes: l.size, freedBytes: l.freed, deletable: true, refusal: preparingAny, recreatable: true,
                             later: "nothing", cleanable: preparingAny == nil, path: rel(id)))
        }

        // Logs, metrics, the store's own records.
        if byLeaf["logs"] != nil {
            let l = leaf("logs")
            add(ResourceItem(id: "logs", group: "logs", name: "logs", detail: (l.paths.map { $0.rel.joined(separator: "/") }).joined(separator: ", "),
                             sizeBytes: l.size, freedBytes: l.freed, deletable: true, later: "cleared — they start again", path: "*.log"))
        }
        if byLeaf["metrics"] != nil {
            let l = leaf("metrics")
            add(ResourceItem(id: "metrics", group: "logs", name: "metrics", detail: "every action's timings, sessions, traffic by minute",
                             sizeBytes: l.size, freedBytes: l.freed, deletable: true, later: "the history is cleared (Metrics starts again)",
                             path: "metrics.sqlite"))
        }
        if byLeaf["store"] != nil {
            let l = leaf("store")
            add(ResourceItem(id: "store", group: "store", name: "Dozer's own records", detail: "accounts (names only), onboarding, preparations, the host's lock and socket",
                             sizeBytes: l.size, freedBytes: l.freed, link: "accounts", refusal: "Dozer's own state — not deleted here"))
        }
        // Stray files: anything else in the store.
        for id in byLeaf.keys.filter({ $0.hasPrefix("stray:") }).sorted() {
            let l = leaf(id)
            let path = root.appendingPathComponent(String(id.dropFirst(6))).standardizedFileURL.path
            let users = f.sandboxes.filter { s in ([s.workspace].compactMap { $0 } + s.shares).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                .contains { $0 == path || $0.hasPrefix(path + "/") } }.map(\.name)
            add(ResourceItem(id: id, group: "stray", name: String(id.dropFirst(6)), detail: "not something Dozer made — found in the store",
                             sizeBytes: l.size, freedBytes: l.freed, usedBy: users, deletable: true,
                             refusal: users.isEmpty ? nil : "the workspace (or a share) of \(users.joined(separator: ", "))",
                             later: "gone for good", warning: "Dozer did not make it: check what it is first", path: rel(id)))
        }

        // Outside the store (shown, never deleted here).
        if let s = f.settingsFile {
            add(ResourceItem(id: "outside:settings", group: "outside", name: "settings", detail: s.path, sizeBytes: FileManager.default.fileExists(atPath: s.path) ? allocatedBytes(s) : nil,
                             link: "settings", refusal: "your choices — Settings, or doz uninstall", path: s.path))
        }
        add(ResourceItem(id: "outside:keychain", group: "outside", name: "keychain entries",
                         detail: f.accounts.isEmpty ? "none" : "accounts: " + f.accounts.joined(separator: ", ") + " (names only; never a value)",
                         sizeBytes: nil, link: "accounts", refusal: "managed in Accounts & keys"))
        if let exe = f.executable {
            add(ResourceItem(id: "outside:cli", group: "outside", name: "the doz program", detail: exe, sizeBytes: nil,
                             refusal: "doz uninstall removes it", path: exe))
        }
        // 596: Apple's container tool (Dockerfile builds) — outside, never in the total, never deleted.
        if let a = f.appleContainer { for it in appleContainerItems(a) { add(it) } }
        for s in f.sandboxes where s.workspace != nil {
            add(ResourceItem(id: "outside:project:\(s.name)", group: "outside", name: "project folder of \(s.name)", detail: s.workspace, sizeBytes: nil,
                             usedBy: [s.name], link: "sandbox:\(s.name)", refusal: "your files — never deleted here", path: s.workspace))
        }

        // R0: everything adds up — every entry belongs to exactly one leaf; leaves are items (or folded
        // into their sandbox/image parent) — anything a row does not show is "unattributed".
        let shown = Set(items.map(\.id))
        let attributed = byLeaf.filter { shown.contains($0.key) }.values.flatMap { $0 }.reduce(Int64(0)) { $0 + $1.allocated }
        let unattributed = total - attributed
        items.append(ResourceItem(id: "unattributed", group: "store", name: "unattributed",
                                  detail: unattributed == 0 ? "every byte of the store is on a row above" : "bytes no row accounts for — a leak or a file Dozer does not know",
                                  sizeBytes: unattributed, freedBytes: nil, refusal: "nothing to delete"))
        let nonDiskAll = entries.filter { !$0.isDisk }.reduce(Int64(0)) { $0 + $1.allocated }
        let cleanSet = cleanIDs(items)
        let cleanFreed = planFreed(cleanSet, byLeaf: byLeaf, disks: disks, lists: lists, items: items)

        var memory: [ResourceMemory] = f.sandboxes.filter { $0.phase.holdsRAM }.map {
            ResourceMemory(kind: "sandbox", name: $0.name, phase: $0.phase.rawValue, heldBytes: Int64($0.ramHeldMiB) * 1_048_576,
                           allocationBytes: Int64($0.memoryMiB) * 1_048_576, cpus: $0.cpus)
        }
        if let h = f.hostFootprintBytes { memory.append(ResourceMemory(kind: "host", name: "doz host", heldBytes: h)) }
        let vals = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return ResourceReport(store: root.path, measuredAt: f.now, milliseconds: ms(since: t0), totalBytes: total,
                              attributedBytes: attributed, unattributedBytes: unattributed,
                              occupiedBytes: leafFreed.union + nonDiskAll + unreadable, cleanableBytes: cleanFreed,
                              volumeFreeBytes: vals?.volumeAvailableCapacityForImportantUsage, volumeTotalBytes: vals?.volumeTotalCapacity.map(Int64.init),
                              items: items, memory: memory, machineCPUs: ProcessInfo.processInfo.activeProcessorCount,
                              allocatedCPUs: f.sandboxes.filter { $0.phase.holdsRAM }.reduce(0) { $0 + $1.cpus },
                              network: f.network, kernels: kernels, unusedDays: f.unusedDays)
    }

    /// A leaf's parent row (sandbox and image leaves fold into one).
    static func parentID(_ leaf: String) -> String {
        if leaf.hasPrefix("sandbox:") { return String(leaf.split(separator: "/").first!) }
        for p in ["point:", "screens:", "boots:"] where leaf.hasPrefix(p) {
            return "sandbox:" + String(leaf.dropFirst(p.count).split(separator: "/").first!)
        }
        if leaf.hasPrefix("image:"), let at = leaf.firstIndex(of: "@") { return String(leaf[..<at]) }
        return leaf
    }

    /// R4's safe set: re-creatable AND unused leaves, never templates, sandboxes, restore points, settings or keys.
    public static func cleanIDs(_ items: [ResourceItem]) -> [String] {
        items.filter { it in
            it.cleanable && it.deletable && it.refusal == nil
                && !(it.id.hasPrefix("image:") && !it.id.contains("@"))        // an image by its keys
                && !["template:", "sandbox:", "point:", "screens:", "boots:", "stray:", "outside:"].contains { it.id.hasPrefix($0) }
                && !["logs", "metrics", "initfs", "store", "unattributed"].contains(it.id)
        }.map(\.id)
    }

    /// What deleting these leaves (and parents: all their leaves) frees together.
    static func planFreed(_ selected: [String], byLeaf: [String: [Entry]], disks: [Entry], lists: [[DiskAccounting.Extent]], items: [ResourceItem]) -> Int64 {
        let leaves = expand(selected, keys: Array(byLeaf.keys))
        let groups = disks.map { leaves.contains(classify($0.rel, currentLabKey: nil)) ? 0 : 1 }
        let freedDisks = DiskAccounting.exclusive(lists, groups: groups).freed[0] ?? 0
        let es = leaves.flatMap { byLeaf[$0] ?? [] }
        let nonDisk = es.filter { !$0.isDisk }.reduce(Int64(0)) { $0 + $1.allocated }
        let unreadable = es.filter(\.isDisk).reduce(Int64(0)) { acc, e in acc + (lists[disks.firstIndex { $0.url == e.url }!].isEmpty ? e.allocated : 0) }
        return freedDisks + nonDisk + unreadable
    }

    /// The leaf ids an id covers: itself, or (a parent) all its leaves.
    static func expand(_ ids: [String], keys: [String]) -> Set<String> {
        var out = Set<String>()
        for id in ids {
            if keys.contains(id) { out.insert(id) }
            for k in keys where k != id && parentID(k) == id { out.insert(k) }
        }
        return out
    }

    // MARK: plans and deletion (R2, R3, R4)

    /// A plan for `ids` (or the safe set when `clean`) against a fresh inventory: what goes, what it frees
    /// (exact for the whole selection), what each costs later, and what is refused and why.
    public static func plan(store: DozerStore, facts: ResourceFacts, ids requested: [String], clean: Bool) -> ResourcePlan {
        let report = inventory(store: store, facts: facts)
        let ids = clean ? cleanIDs(report.items) : requested
        var entries: [ResourcePlan.Entry] = []
        var refused: [ResourcePlan.Refused] = []
        var accepted: [String] = []
        for id in ids {
            guard isValidID(id), let it = report.items.first(where: { $0.id == id }) else {
                refused.append(.init(id: id, reason: "no such resource (doz resources lists them)"))
                continue
            }
            guard it.deletable else { refused.append(.init(id: id, reason: it.refusal ?? "not deleted here")); continue }
            if let r = it.refusal { refused.append(.init(id: id, reason: r)); continue }
            // A parent whose children are refused: refuse it whole (never half an image).
            if it.parent == nil, let child = report.items.first(where: { $0.parent == id && $0.deletable && $0.refusal != nil }) {
                refused.append(.init(id: id, reason: child.refusal!))
                continue
            }
            accepted.append(id)
            entries.append(.init(id: id, name: it.name, freedBytes: it.freedBytes ?? 0, later: it.later, warning: it.warning))
        }
        // Drop a leaf whose parent is also selected.
        let parents = Set(accepted)
        entries.removeAll { e in let p = parentID(e.id); return p != e.id && parents.contains(p) }
        let (walked, _) = walk(store.root.standardizedFileURL)
        var byLeaf: [String: [Entry]] = [:]
        for e in walked { byLeaf[classify(e.rel, currentLabKey: nil), default: []].append(e) }
        let disks = walked.filter(\.isDisk)
        let freed = planFreed(entries.map(\.id), byLeaf: byLeaf, disks: disks, lists: DiskAccounting.extentLists(disks.map(\.url)), items: report.items)
        return ResourcePlan(items: entries, refused: refused, freedBytes: freed, dryRun: true, deleted: [], failed: [], clean: clean)
    }

    /// Delete a plan's items (the host calls this with nothing else running — `HostCore.resourcesRemove`).
    /// Paths come from the ids, never from a request. `clearMetrics` clears the metrics database.
    static func execute(_ plan: ResourcePlan, store: DozerStore, clearMetrics: () throws -> Void) -> ResourcePlan {
        var p = plan
        p.dryRun = false
        let root = store.root.standardizedFileURL
        let (walked, _) = walk(root)
        var byLeaf: [String: [Entry]] = [:]
        for e in walked { byLeaf[classify(e.rel, currentLabKey: nil), default: []].append(e) }
        for e in plan.items {
            do {
                switch e.id {
                case "logs":
                    for f in byLeaf["logs"] ?? [] { try truncate(f.url) }
                case "metrics":
                    try clearMetrics()
                case "cache:downloads":
                    for n in ["content", "state.json"] { try removeIfPresent(root.appendingPathComponent(n)) }
                case "cache:tools":
                    try removeIfPresent(root.appendingPathComponent("tools"))
                case "initfs":
                    try removeIfPresent(root.appendingPathComponent("initfs.ext4"))
                default:
                    if e.id.hasPrefix("point:") {
                        let parts = e.id.dropFirst(6).split(separator: "/", maxSplits: 1).map(String.init)
                        guard parts.count == 2 else { throw HostError(.invalid, "bad restore point id") }
                        try removeIfPresent(StoreLayout(root: root, name: parts[0]).restorePointDirectory(parts[1]))
                    } else if e.id.hasPrefix("screens:") {
                        SavedScreens.remove(StoreLayout(root: root, name: String(e.id.dropFirst(8))))
                    } else if e.id.hasPrefix("boots:") {
                        try removeIfPresent(BootLogs.directory(StoreLayout(root: root, name: String(e.id.dropFirst(6)))))
                    } else {
                        // Images, keys, templates, bases, kernels, leftovers, stray entries: every entry of the id's
                        // leaves, top-most first (a directory takes its contents with it).
                        let leaves = expand([e.id], keys: Array(byLeaf.keys))
                        let entries = leaves.flatMap { byLeaf[$0] ?? [] }.sorted { $0.rel.count < $1.rel.count }
                        var gone: [[String]] = []
                        for x in entries where !gone.contains(where: { x.rel.starts(with: $0) }) {
                            // Never the containing directory of another id (images/NAME is shared by its keys only).
                            try removeIfPresent(x.url)
                            gone.append(x.rel)
                        }
                    }
                }
                p.deleted.append(e.id)
            } catch {
                p.failed.append(.init(id: e.id, reason: error.localizedDescription))
            }
        }
        // An image directory its keys' deletion left empty goes too (no "0 prepared disks" row left behind).
        for id in p.deleted where id.hasPrefix("image:") && id.contains("@") && !id.hasPrefix("image:lab@") {
            let name = String(id.dropFirst(6).split(separator: "@").first ?? "")
            guard !name.isEmpty, !["bases", "custom"].contains(name) else { continue }
            let dir = root.appendingPathComponent("images/\(name)")
            if (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? removeIfPresent(dir) }
        }
        return p
    }

    static func removeIfPresent(_ url: URL) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func truncate(_ url: URL) throws {
        guard Darwin.truncate(url.path, 0) == 0 else { throw HostError(.failed, "could not clear \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
    }

    /// The physical memory this process costs (its footprint, as Activity Monitor shows it).
    public static func footprint() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : nil
    }
}
