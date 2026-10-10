import Foundation
import DozerKit

// 594 (D3, D4) — image preparation as a HOST operation. Preparing a built-in image is the kernel,
// the guest init disk, the base pull and the bake (lab: its prepared disk) — minutes on a first run.
// It runs in the host, not in the CLI process that asked: Ctrl-C in `doz onboard` detaches, a closed
// UI tab changes nothing, and the host stays up while one runs. ONE preparation per image at a time
// (single-flight on the image's name — its bake key is fixed for a build): `doz onboard`, `doz image
// bake`, the UI and a `start` that needs the image all join the one running, and see its progress
// from its start (the events so far are replayed to a joiner).

/// A transfer under way (a pull, the kernel download), for a view that draws its own bar.
public struct PreparationTransfer: Codable, Equatable, Sendable {
    public var label: String
    public var completedBytes: Int64
    public var totalBytes: Int64?
    public var completedItems: Int?
    public var totalItems: Int?
    /// The CLI's transfer line: label, bar, amount, rate, time left, layers.
    public var line: String

    public init(label: String, completedBytes: Int64, totalBytes: Int64?, completedItems: Int?, totalItems: Int?, line: String) {
        self.label = label
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.line = line
    }
}

/// One preparation, as `doz onboard --status`, the UI's wizard and its Operations page see it.
public struct PreparationInfo: Codable, Equatable, Sendable {
    public var id: String
    /// `lab`, `claude-code` or `pi`.
    public var image: String
    /// running · cancelling · done · failed · cancelled.
    public var state: String
    /// Who asked, in order (`onboard`, `image bake`, `start NAME`, …) — the first started it, the rest joined.
    public var requestedBy: [String]
    public var startedAt: Date
    public var finishedAt: Date?
    public var seconds: Double
    public var error: String?
    /// The step under way, and for how long.
    public var step: String?
    public var stepSeconds: Double?
    public var transfer: PreparationTransfer?
    /// The last lines the bake step printed (guest text, inert).
    public var output: [String]
    /// Finished lines, oldest first (the newest 40).
    public var lines: [String]
    /// 594 (owner: "more progress detail"): step N of M — N the timed steps done plus the one under
    /// way, M the plan (this store's last run of the image, else the image spec's) — never N > M.
    public var stepIndex: Int?
    public var plannedSteps: Int?
    /// Every finished step (and each download's summary), oldest first, as data.
    public var steps: [PreparationStep]?
    /// How long the step under way took last time, and about how long is left — only when this store
    /// prepared the image before; `estimateBasis` says which, or "first time: no estimate yet".
    public var stepUsualSeconds: Double?
    public var remainingSeconds: Double?
    public var estimateBasis: String?

    public var running: Bool { state == "running" || state == "cancelling" }

    public init(id: String, image: String, state: String, requestedBy: [String], startedAt: Date, finishedAt: Date?, seconds: Double,
                error: String?, step: String?, stepSeconds: Double?, transfer: PreparationTransfer?, output: [String], lines: [String]) {
        self.id = id
        self.image = image
        self.state = state
        self.requestedBy = requestedBy
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.seconds = seconds
        self.error = error
        self.step = step
        self.stepSeconds = stepSeconds
        self.transfer = transfer
        self.output = output
        self.lines = lines
    }
}

/// 594: one finished step of a preparation.
public struct PreparationStep: Codable, Equatable, Sendable {
    public var label: String
    /// step · failed · transfer (a download's summary — not one of the plan's steps)
    public var kind: String
    public var seconds: Double
    /// What it took the last time this store prepared the image.
    public var usualSeconds: Double?
    public var error: String?
    /// A failed step's last output lines (guest text, inert).
    public var output: [String]?

    public init(label: String, kind: String, seconds: Double, usualSeconds: Double? = nil, error: String? = nil, output: [String]? = nil) {
        self.label = label
        self.kind = kind
        self.seconds = seconds
        self.usualSeconds = usualSeconds
        self.error = error
        self.output = output?.isEmpty == true ? nil : output
    }
}

/// 594: the last SUCCESSFUL preparation of each image in this store — its timed steps and their
/// times (`<store>/preparations.json`), the plan and the estimates of the next one.
public struct PreparationRecord: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public var key: String
        public var label: String
        public var seconds: Double
    }
    public var image: String
    public var finishedAt: Date
    public var seconds: Double
    public var steps: [Step]

    /// A step's identity across runs: the label without what varies (cached or downloaded, sizes,
    /// durations in parentheses) — "base image node (cached)" and "pulled the base image node" are one.
    public static func key(_ fullLabel: String) -> String {
        // 594 W8: "verify: X → 2.1.285" is the step "verify: X" (its result varies).
        let label = fullLabel.range(of: " → ").map { String(fullLabel[..<$0.lowerBound]) } ?? fullLabel
        if label.hasPrefix("kernel ready") { return "kernel" }
        if label.hasPrefix("guest init image ready") { return "guest init" }
        // A bake's base image and base disk (the metrics' key folds both into "image …").
        if label.hasPrefix("pulled the base image") || label.hasPrefix("base image ") { return "base image" }
        if label.hasPrefix("base disk") { return "base disk" }
        let m = MetricsStepKey.key(for: label)
        switch m.hasPrefix("step: ") ? String(m.dropFirst(6)) : m {
        case "image pull", "image cached": return "base image"
        case "other", "network setup": break
        case let k: if !k.hasPrefix("bake step ") { return k }
        }
        let cut = label.range(of: " (")?.lowerBound ?? label.endIndex
        var k = String(label[..<cut])
        // 594: an agent's install step is the same step whatever version it installs.
        if let r = k.range(of: #"^step: npm install (@[a-z0-9-]+/)?[a-z0-9._-]+@"#, options: .regularExpression) {
            k = String(k[r]).dropLast() + "@version"
        }
        return k
    }

    public func usual(_ label: String) -> Double? {
        let k = Self.key(label)
        return steps.first { $0.key == k }.map(\.seconds)
    }

    /// About how long is left: the rest of the step under way (as long as it took last time, less what
    /// it has run) and every step after it, by the last run's order and times.
    public func remaining(after done: Int, current: String?, currentSeconds: Double) -> Double {
        var from = done
        var left = 0.0
        if let current {
            let k = Self.key(current)
            // The step's place in the last run: its first occurrence at or after the steps done now
            // (a key can recur — the lab's first boot times the guest init again).
            let lo = min(done, steps.count)
            if let i = steps[lo...].firstIndex(where: { $0.key == k }) ?? steps.firstIndex(where: { $0.key == k }) { from = i }
            left += max(0, (steps.indices.contains(from) ? steps[from].seconds : 0) - currentSeconds)
            from += 1
        }
        if from < steps.count { left += steps[from...].reduce(0) { $0 + $1.seconds } }
        return left
    }

    public static func url(_ store: DozerStore) -> URL { store.root.appendingPathComponent("preparations.json") }

    public static func all(_ store: DozerStore) -> [String: PreparationRecord] {
        guard let d = try? Data(contentsOf: url(store)) else { return [:] }
        return (try? HostWire.decoder.decode([String: PreparationRecord].self, from: d)) ?? [:]
    }

    public static func save(_ r: PreparationRecord, store: DozerStore) {
        var all = all(store)
        all[r.image] = r
        try? HostWire.prettyEncoder.encode(all).write(to: url(store), options: .atomic)
    }
}

/// `<store>/onboarded.json` (D8) — "this store was onboarded". The design said `state.json`; that
/// name is taken at the store's root by Containerization's image store (its index of pulled
/// images), so the record has a file of its own.
public struct OnboardingRecord: Codable, Equatable, Sendable {
    public var version = 1
    /// The doz that onboarded (or last re-ran onboarding).
    public var dozVersion: String
    public var date: Date
    /// Every image an onboarding prepared in this store (a re-run adds; nothing is removed).
    public var images: [String]

    public init(dozVersion: String, date: Date, images: [String]) {
        self.dozVersion = dozVersion
        self.date = date
        self.images = images
    }

    public static func url(_ store: DozerStore) -> URL { store.root.appendingPathComponent("onboarded.json") }

    public static func read(_ store: DozerStore) -> OnboardingRecord? {
        guard let d = try? Data(contentsOf: url(store)) else { return nil }
        return try? HostWire.decoder.decode(OnboardingRecord.self, from: d)
    }

    /// Record (or extend) the store's onboarding.
    @discardableResult
    public static func record(_ store: DozerStore, version: String, images: [String], now: Date = Date()) throws -> OnboardingRecord {
        var r = read(store) ?? OnboardingRecord(dozVersion: version, date: now, images: [])
        r.dozVersion = version
        r.date = now
        for i in images where !r.images.contains(i) { r.images.append(i) }
        try store.ensureDirectory()
        try HostWire.prettyEncoder.encode(r).write(to: url(store), options: .atomic)
        return r
    }
}

/// `prepare-status`.
public struct PrepareStatus: Codable, Equatable, Sendable {
    /// Running ones first, then the recent finished ones (newest first). Empty with no host.
    public var preparations: [PreparationInfo]
    public var onboarded: OnboardingRecord?
    public var images: [ImageRow]
    public var hostRunning: Bool

    public init(preparations: [PreparationInfo], onboarded: OnboardingRecord?, images: [ImageRow], hostRunning: Bool) {
        self.preparations = preparations
        self.onboarded = onboarded
        self.images = images
        self.hostRunning = hostRunning
    }
}

/// `onboard` / `prepare`.
public struct PrepareResult: Codable, Equatable, Sendable {
    public var preparations: [PreparationInfo]
    /// Set once the store is onboarded (`onboard` only; nil while its images are still preparing).
    public var onboarded: OnboardingRecord?

    public init(preparations: [PreparationInfo], onboarded: OnboardingRecord?) {
        self.preparations = preparations
        self.onboarded = onboarded
    }
}

/// sha256 of a file, remembered by (path, inode, size, mtime) — `image ls` and the UI's poll ask
/// whether each image is prepared for this build, which needs the kernel's and deckhold's digests.
final class FileDigests: @unchecked Sendable {
    static let shared = FileDigests()
    private let lock = NSLock()
    private var cache: [String: (stamp: [Int64], digest: String)] = [:]

    func sha256(_ url: URL) -> String? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        let stamp = [Int64(bitPattern: UInt64(st.st_ino)), Int64(st.st_size), Int64(st.st_mtimespec.tv_sec), Int64(st.st_mtimespec.tv_nsec)]
        if let hit = lock.withLock({ cache[url.path] }), hit.stamp == stamp { return hit.digest }
        guard let d = try? KernelProvider.sha256(of: url) else { return nil }
        lock.withLock { cache[url.path] = (stamp, d) }
        return d
    }
}

/// One image being prepared. Its events are kept (bounded) so a joiner sees it from the start.
final class Preparation: @unchecked Sendable {
    let id: String
    let image: String
    let startedAt = Date()
    private let lock = NSLock()
    private var _state = "running"
    private var _finishedAt: Date?
    private var _error: String?
    private var _requestedBy: [String]
    private var events: [HostEvent] = []
    private var dropped = 0
    private var subscribers: [UUID: @Sendable (HostEvent) -> Void] = [:]
    private var finished: [String] = []
    /// 594 (owner: "more progress detail"): the same model as 593's boot view and the CLI — with the
    /// output's last 6 lines — plus the steps as data: each finished one, the plan, the last run's times.
    private let board = ProgressBoard(tailLines: Preparation.tailLines)
    private let formatter = ProgressTerminal(mode: .plain, color: false)
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var outcome: Result<Void, Error>?
    private var steps: [PreparationStep] = []
    private var open: [String: Date] = [:]
    private var lastOutput: [String] = []
    /// Timed steps a run of this image takes (the last run's count, else the image spec's plan).
    let planned: Int?
    /// The last successful run of this image in this store (its steps' times) — nil: the first time.
    let previous: PreparationRecord?
    var task: Task<Void, Never>?

    static let maximumEvents = 600
    static let tailLines = 6

    init(image: String, requestedBy: String, planned: Int? = nil, previous: PreparationRecord? = nil) {
        id = String(UUID().uuidString.prefix(8)).lowercased()
        self.image = image
        _requestedBy = [requestedBy]
        self.planned = previous.map { $0.steps.count } ?? planned
        self.previous = previous
    }

    /// Timed steps, finished (ok or failed) — for the record of this run.
    var finishedSteps: [PreparationStep] { lock.withLock { steps.filter { $0.kind != "transfer" } } }

    var state: String { lock.withLock { _state } }
    var isRunning: Bool { lock.withLock { _state == "running" || _state == "cancelling" } }

    func joined(by who: String) { lock.withLock { if !_requestedBy.contains(who) { _requestedBy.append(who) } } }

    /// An event of this preparation: kept, applied to the board, passed to every subscriber.
    func emit(_ e: HostEvent) {
        let subs: [@Sendable (HostEvent) -> Void] = lock.withLock {
            let text = ProgressFormat.trimDigests(ProgressFormat.inert(e.text ?? "", limit: 400))
            // The steps as data: a timed step is one that STARTED and then ended (a bare step event —
            // "flattened the base once" inside a timed step — is not one of the plan's).
            switch e.kind {
            case .started:
                open[text] = e.time
                lastOutput = []
            case .output:
                if !text.isEmpty { lastOutput.append(text); if lastOutput.count > Self.tailLines { lastOutput.removeFirst() } }
            // (594 W8: "verify: X" may end as "verify: X → 2.1.285" — its result on the same line.)
            case .step where open.removeValue(forKey: text) != nil
                || open.keys.first(where: { text.hasPrefix($0 + " → ") }).map({ open.removeValue(forKey: $0) }) != nil:
                steps.append(PreparationStep(label: text, kind: "step", seconds: (e.milliseconds ?? 0) / 1000,
                                             usualSeconds: previous?.usual(text)))
            case .failed:
                open[text] = nil
                steps.append(PreparationStep(label: text, kind: "failed", seconds: (e.milliseconds ?? 0) / 1000,
                                             error: e.error.map { ProgressFormat.trimDigests(ProgressFormat.inert($0)) }, output: lastOutput))
            default: break
            }
            let finals = board.apply(e)
            for f in finals {
                finished.append(formatter.format(f))
                if case .transferDone(let label, let bytes, let secs) = f {
                    steps.append(PreparationStep(label: ProgressTerminal.pulled(label, bytes, secs), kind: "transfer", seconds: secs))
                }
            }
            if finished.count > 40 { finished.removeFirst(finished.count - 40) }
            if steps.count > 120 { steps.removeFirst(steps.count - 120) }
            // Keep what a joiner needs: every step and note; transfer ticks and output only as the latest.
            if e.kind == .progress || e.kind == .output, let last = events.last, last.kind == e.kind, last.text == e.text || e.kind == .output {
                events[events.count - 1] = e
            } else {
                events.append(e)
            }
            if events.count > Self.maximumEvents { events.removeFirst(events.count - Self.maximumEvents); dropped += 1 }
            return Array(subscribers.values)
        }
        for s in subs { s(e) }
    }

    /// Subscribe: the events so far first (a joiner sees the preparation from its start), then live.
    func subscribe(_ f: @escaping @Sendable (HostEvent) -> Void) -> UUID {
        let id = UUID()
        let replay: [HostEvent] = lock.withLock {
            subscribers[id] = f
            return events
        }
        for e in replay { f(e) }
        return id
    }

    func unsubscribe(_ id: UUID) { _ = lock.withLock { subscribers.removeValue(forKey: id) } }

    /// Wait for the end: returns when it succeeded, throws its error (or cancellation) otherwise.
    func wait() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let done: Result<Void, Error>? = lock.withLock {
                if let o = outcome { return o }
                waiters.append(c)
                return nil
            }
            if let done { c.resume(with: done) }
        }
    }

    func markCancelling() { lock.withLock { if _state == "running" { _state = "cancelling" } } }

    func finish(_ result: Result<Void, Error>, cancelled: Bool) {
        let ws: [CheckedContinuation<Void, Error>] = lock.withLock {
            _finishedAt = Date()
            switch result {
            case .success: _state = "done"
            case .failure(let e):
                _state = cancelled ? "cancelled" : "failed"
                _error = cancelled ? "cancelled" : HostError.from(e).message
            }
            for f in board.finishAll() { finished.append(formatter.format(f)) }
            outcome = cancelled ? .failure(HostError(.failed, "the preparation of \(image) was cancelled")) : result
            let w = waiters
            waiters = []
            return w
        }
        for w in ws { w.resume(with: outcome!) }
    }

    var info: PreparationInfo {
        lock.withLock {
            let now = Date()
            var step: String?, stepSeconds: Double?, output: [String] = []
            for l in board.live(now: now) {
                switch l {
                case .step(let s, let secs): step = s; stepSeconds = secs
                case .output(let o): output.append(o)
                case .transfer: break
                }
            }
            let transfer = board.currentTransfer.map {
                PreparationTransfer(label: $0.label, completedBytes: $0.done, totalBytes: $0.total, completedItems: $0.items,
                                    totalItems: $0.totalItems, line: ProgressBoard.transferLine($0, now: now))
            }
            var p = PreparationInfo(id: id, image: image, state: _state, requestedBy: _requestedBy, startedAt: startedAt, finishedAt: _finishedAt,
                                    seconds: (_finishedAt ?? now).timeIntervalSince(startedAt), error: _error, step: step, stepSeconds: stepSeconds,
                                    transfer: transfer, output: output, lines: finished)
            // Step N of M: the timed steps done, plus the one under way; M the plan (never below N).
            let done = steps.filter { $0.kind == "step" }.count
            let running = _state == "running" || _state == "cancelling"
            p.stepIndex = done + (running && step != nil ? 1 : 0)
            if let m = planned { p.plannedSteps = max(m, p.stepIndex ?? 0) }
            p.steps = steps
            // Estimates only from this store's last run of this image; none the first time.
            if let prev = previous {
                p.stepUsualSeconds = step.flatMap { prev.usual($0) }
                if running {
                    p.remainingSeconds = prev.remaining(after: done, current: step, currentSeconds: stepSeconds ?? 0)
                }
                p.estimateBasis = "from this store's last preparation of \(image) (\(prev.finishedAt.formatted(date: .abbreviated, time: .shortened)))"
            } else {
                p.estimateBasis = "first time: no estimate yet"
            }
            return p
        }
    }
}

extension HostCore {
    /// Whether `image` is ready for this build: the guest init disk is there and so is a bake with
    /// the key this build makes (the kernel cached and hashed — an older build's bake does not count).
    /// The lab: its prepared disk for the default lab spec.
    @Sendable nonisolated static func isPrepared(_ image: String, _ store: DozerStore) -> Bool {
        isUsable(image, store, currentRecipeOnly: true)
    }

    /// 594 W28: a start can use `image` without preparing anything — also an image an older doz's
    /// recipe made (it is used, and said to be stale; never rebuilt without asking).
    @Sendable nonisolated static func isUsable(_ image: String, _ store: DozerStore) -> Bool {
        isUsable(image, store, currentRecipeOnly: false)
    }

    nonisolated static func isUsable(_ image: String, _ store: DozerStore, currentRecipeOnly: Bool) -> Bool {
        guard FileManager.default.fileExists(atPath: store.layout("_").initfs.path),
              let spec = try? DozerImages.spec(name: "doz-prepare-\(image)", options: CreateOptions(image: image), store: store).0 else { return false }
        guard let imageSpec = spec.imageSpec else {
            return FileManager.default.fileExists(atPath: StoreLayout(spec: spec).golden(for: spec).path)
        }
        let kernel = spec.kernelPath.map { URL(fileURLWithPath: $0) }
            ?? KernelProvider(cacheDirectory: spec.kernelCacheDirectory ?? StoreLayout(spec: spec).kernels).cachedKernel
        guard FileManager.default.fileExists(atPath: kernel.path), let deckhold = DeckholdBinary.locate(),
              let k = FileDigests.shared.sha256(kernel), let d = FileDigests.shared.sha256(deckhold) else { return false }
        guard ImageBaker(storeRoot: store.root).cached(imageSpec, key: imageSpec.bakeKey(kernelSHA256: k, deckholdSHA256: d)) != nil else { return false }
        // 596: any base × agent image has a recipe to compare (no agent too); anything else does not.
        return !currentRecipeOnly || AgentVersions.currentRecipe(for: imageSpec) == nil || AgentVersions.isCurrentRecipe(imageSpec)
    }

    /// What a start of `m` has to wait for: the image whose preparation it should join — one running
    /// now, or one not prepared for this build (then a preparation starts, which a second start
    /// joins). nil: nothing to wait for (a kept disk, a custom image, an image already prepared).
    func imageToPrepare(_ m: Managed) async -> String? {
        let spec = m.sandbox.spec
        guard spec.customImage == nil, !m.sandbox.hasRootDisk else { return nil }
        let image: String
        if let imageSpec = spec.imageSpec {
            // 596: any base × agent image (a Dockerfile's: its build, then its bake).
            guard DozerImages.isPreparable(imageSpec.name, store: store) else { return nil }
            image = imageSpec.name
        } else {
            // The lab: only when this sandbox's prepared disk is the one a lab preparation makes.
            guard let lab = try? DozerImages.spec(name: "doz-prepare-lab", options: CreateOptions(image: "lab"), store: store).0,
                  StoreLayout.goldenKey(for: lab) == StoreLayout.goldenKey(for: spec) else { return nil }
            image = "lab"
        }
        if runningPreparation(image) != nil { return image }
        await freshen(image, update: false)
        let s = store
        let check = preparedCheck
        // 594 W28: an image an older doz (or an older agent release) made is USED — said, never rebuilt
        // without the user asking (owner ruling). Only an image never prepared is prepared now.
        let ready = await Task.detached { check(image, s) || HostCore.isUsable(image, s) }.value
        return ready ? nil : image
    }

    /// 594: an agent image's freshness — ask the registry for `latest` (at most hourly, never failing:
    /// offline means the image already prepared is used, noted in the log). 594 W28 (owner ruling: "i
    /// dont think we should rebuild images without the user agreeing … better to warn"): a newer release
    /// is only SAID (`image ls`, doctor, create, the Images page) — never prepared by itself; `update` is
    /// kept for its callers and does nothing more.
    @discardableResult
    func freshen(_ image: String, update: Bool) async -> AgentVersions.Freshness? {
        // 596: any base × agent image — the base's tag (hourly: its digest, for the next preparation and
        // "update available"; never a rebuild by itself), then the agent's version as before.
        guard let choice = ImageChoice.parse(image) else { return nil }
        if choice.name != "lab", BaseCatalogue.base(choice.base) != nil,
           let e = await BaseDigests.refresh(choice.base, store: store, registry: agentRegistry) {
            HostLog.line("\(choice.base): its tag could not be resolved (\(e)) — the digest resolved before (or the built-in pin) is used")
        }
        guard choice.agent != .none else { return nil }
        let agent = choice.agent.rawValue
        let settings = DozerSettings.load()
        let f = await AgentVersions.refresh(agent, store: store, settings: settings, registry: agentRegistry)
        if let e = f.error, f.looked {
            HostLog.line("\(agent): the npm registry could not be asked (\(e)) — the image already prepared is used")
        } else if f.looked, let v = f.latest {
            HostLog.line("\(agent): latest is \(v) (npm registry)")
        }
        if let e = f.nativeError { HostLog.line("claude-code: its native build's manifest could not be read (\(e))") }
        return f
    }

    func runningPreparation(_ image: String) -> Preparation? {
        preparations[image].flatMap { $0.isRunning ? $0 : nil }
    }

    /// The preparation of `image`: the one running (joined), or a new one.
    func preparation(for image: String, requestedBy who: String) throws -> Preparation {
        guard DozerImages.builtIn.contains(image) || DozerImages.isPreparable(image, store: store) else {
            throw HostError(.invalid, "only a base × agent image is prepared (lab, claude-code, pi, python-claude-code, … — doz base ls) — not \(image)")
        }
        if let p = runningPreparation(image) {
            p.joined(by: who)
            return p
        }
        guard !readOnly else { throw HostError(.unavailable, "preparing an image needs the host") }
        let p = Preparation(image: image, requestedBy: who, planned: Self.plannedSteps(image, store: store),
                            previous: PreparationRecord.all(store)[image])
        preparations[image] = p
        let store = self.store
        let hub = self.hub
        let emit: @Sendable (HostEvent) -> Void = { e in
            p.emit(e)
            hub.yield(e)
            if e.kind != .progress, e.kind != .output { HostLog.line(e.line) }
        }
        note(nil, "preparing \(image) (asked by \(who))")
        let t0 = ContinuousClock.now
        let started = Date()
        let run = preparationRunner
        p.task = Task.detached { [weak self] in
            var cancelled = false
            let result: Result<Void, Error>
            do {
                try await run(image, store, emit)
                result = .success(())
            } catch {
                cancelled = Task.isCancelled || error is CancellationError
                result = .failure(error)
            }
            p.finish(result, cancelled: cancelled)
            await self?.preparationEnded(p, ok: (try? result.get()) != nil, started: started, t0: t0)
        }
        return p
    }

    private func preparationEnded(_ p: Preparation, ok: Bool, started: Date, t0: ContinuousClock.Instant) {
        recentPreparations.insert(p, at: 0)
        if recentPreparations.count > 12 { recentPreparations.removeLast(recentPreparations.count - 12) }
        if preparations[p.image] === p { preparations[p.image] = nil }
        let i = p.info
        note(nil, "preparation of \(p.image) \(i.state)" + (i.error.map { ": \($0)" } ?? "") + String(format: " (%.0f s)", i.seconds))
        let failed = ok ? nil : p.finishedSteps.last(where: { $0.kind == "failed" }).map { PreparationStepID.of($0.label) }
        recordPreparation(p.image, started: started, t0: t0, ok: ok, error: i.error, failedStep: failed)
        // The next preparation's plan and estimates: this run's steps and times (successful runs only).
        let steps = p.finishedSteps.filter { $0.kind == "step" }
        if ok, !steps.isEmpty {
            PreparationRecord.save(PreparationRecord(image: p.image, finishedAt: Date(), seconds: i.seconds,
                                                     steps: steps.map { .init(key: PreparationRecord.key($0.label), label: $0.label, seconds: $0.seconds) }),
                                   store: store)
        }
    }

    /// The timed steps a FIRST preparation of `image` takes (a later one follows the last run):
    /// kernel + guest init, then — an image spec — base image, base disk, clone, bake VM boot, bake
    /// network, each of its steps and verify checks, trim and stop; the lab — its first boot
    /// (measured: 594.02-RESULTS.md).
    static func plannedSteps(_ image: String, store: DozerStore? = nil) -> Int? {
        if image == "lab" { return 2 + labBootSteps }
        // 596: any base × agent image, at the version a preparation would make (the pins without a store);
        // a Dockerfile's adds its build and its import.
        let spec = DozerImages.imageSpec(image)
            ?? store.flatMap { try? AgentVersions.spec(image, purpose: .prepare, store: $0, settings: DozerSettings.load()) }
        guard let spec else { return nil }
        let build = ImageChoice.parse(image)?.isDockerfile == true ? 2 : 0
        return 2 + build + 7 + spec.steps.count + spec.verify.count
    }

    /// The lab's first boot, counted on a real run (2026-09-29): guest init (again), alpine ready,
    /// flatten, root disk clone, VM boot, container start, deckhold, guest prep, network, container stop.
    static let labBootSteps = 10

    /// The work itself, off the actor: the kernel and guest init disk, then the image's bake (the lab:
    /// its prepared disk, made by booting a throwaway sandbox once).
    @Sendable static func runPreparation(_ image: String, _ store: DozerStore, _ emit: @escaping @Sendable (HostEvent) -> Void) async throws {
        let tmpName = "doz-prepare-\(image)"
        // A throwaway sandbox a crashed preparation left behind would cold-boot its kept disk
        // instead of baking: it goes first.
        try? FileManager.default.removeItem(at: store.layout(tmpName).sandboxDirectory)
        // 596 (B7, B8): a Dockerfile's image — its build first (every preparation: the builder's cache
        // makes an unchanged one take seconds, and unchanged layers keep the base — nothing re-baked).
        if let c = ImageChoice.parse(image), c.isDockerfile {
            try await buildDockerfile(c.base, image: image, store: store, emit: emit)
        }
        // 594: the version the settings name — latest as resolved (the host asked the registry first),
        // or the exact one.
        let spec = try DozerImages.spec(name: tmpName, options: CreateOptions(image: image), store: store, purpose: .prepare).0
        let sb = try Sandbox(spec: spec)
        let stream = sb.events()
        let relabel = installLabel(image, spec: spec)
        let forward = Task { for await e in stream { if let he = HostEvent(e, sandbox: image) { emit(relabel(he)) } } }
        defer { forward.cancel() }
        do {
            try Task.checkCancellation()
            try await sb.prepareAssets()
            try Task.checkCancellation()
            if spec.imageSpec != nil {
                _ = try await sb.ensureImage()
            } else {
                // The lab's prepared disk is made by its first boot.
                try await sb.start()
                try await sb.delete()
            }
            for _ in 0..<8 { await Task.yield() }
        } catch {
            // In a task of its own: a cancelled preparation still stops the lab's throwaway VM cleanly.
            if spec.imageSpec == nil { await Task { try? await sb.delete() }.value }
            try? FileManager.default.removeItem(at: store.layout(tmpName).sandboxDirectory)
            for _ in 0..<8 { await Task.yield() }
            throw error
        }
        try? FileManager.default.removeItem(at: store.layout(tmpName).sandboxDirectory)
    }

    /// 594: an agent's install step says which version and why — "npm install @anthropic-ai/claude-code@2.1.285
    /// (latest, resolved now)" when the setting is latest; the pinned label otherwise. 596: the native
    /// build's step too ("install Claude Code 2.1.285 (native build, latest, resolved now)").
    static func installLabel(_ image: String, spec: SandboxSpec) -> @Sendable (HostEvent) -> HostEvent {
        guard let a = spec.imageSpec?.agent, AgentVersions.setting(AgentVersions.agentOf(image), DozerSettings.load()) == "latest" else { return { $0 } }
        let pairs = [("npm install \(a.package)@\(a.version) (integrity-pinned)", "npm install \(a.package)@\(a.version) (latest, resolved now)"),
                     ("install Claude Code \(a.version) (native build, checksum-verified)", "install Claude Code \(a.version) (native build, latest, resolved now)")]
        return { e in
            guard let t = e.text, let (from, to) = pairs.first(where: { t.contains($0.0) }) else { return e }
            var e = e
            e.text = t.replacingOccurrences(of: from, with: to)
            return e
        }
    }

    /// 596 (B7–B9): build a Dockerfile's base with Apple's `container build` and import it — two timed
    /// steps, the build's output as the live tail, the network-policy note said first.
    static func buildDockerfile(_ base: String, image: String, store: DozerStore, emit: @escaping @Sendable (HostEvent) -> Void) async throws {
        guard var rec = Dockerfiles.record(base, store) else { throw HostError(.notFound, "no Dockerfile is known for \(base)") }
        let env = ProcessInfo.processInfo.environment
        let status = ContainerTool.status(env)
        if let p = ContainerTool.problem(status) { throw HostError(.unavailable, p) }
        emit(HostEvent(kind: .note, sandbox: image, text: Dockerfiles.outsidePolicyNote))
        let before = Dockerfiles.sha256(of: URL(fileURLWithPath: rec.dockerfile))
        guard before != nil else { throw HostError(.notFound, "the Dockerfile \(rec.dockerfile) cannot be read") }
        func timed<T: Sendable>(_ label: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
            let t0 = ContinuousClock.now
            emit(HostEvent(kind: .started, sandbox: image, text: label))
            do {
                let v = try await body()
                emit(HostEvent(kind: .step, sandbox: image, text: label, milliseconds: Self.buildMilliseconds(since: t0)))
                return v
            } catch {
                var e = HostEvent(kind: .failed, sandbox: image, text: label, milliseconds: Self.buildMilliseconds(since: t0))
                e.error = HostError.from(error).message
                emit(e)
                throw error
            }
        }
        let archive = store.root.appendingPathComponent(".dockerfile-build-\(UUID().uuidString.prefix(8)).tar")
        defer { try? FileManager.default.removeItem(at: archive) }
        let (dockerfile, context) = (rec.dockerfile, rec.context)
        try await timed("built the Dockerfile with Apple's container build (\((dockerfile as NSString).abbreviatingWithTildeInPath))") {
            let cancelled = CancelFlag()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global().async {
                        do {
                            try ContainerTool.build(dockerfile: dockerfile, context: context, tag: "dozer/\(base):latest", output: archive, env: env,
                                                    isCancelled: { cancelled.value }) { line in
                                emit(HostEvent(kind: .output, sandbox: image, text: ProgressFormat.inert(line, limit: 400)))
                            }
                            c.resume()
                        } catch { c.resume(throwing: error) }
                    }
                }
            } onCancel: { cancelled.set() }
            try Task.checkCancellation()
        }
        let previous = rec
        let r = try await timed("imported the built image into Dozer's store") {
            try await DockerfileImport.importArchive(archive, base: base, store: store, previous: previous)
        }
        emit(HostEvent(kind: .note, sandbox: image, text: r.unchanged
                       ? "the Dockerfile's image is unchanged (same layers) — the prepared image is reused, nothing is re-baked"
                       : "the Dockerfile's image is \(r.reference.split(separator: "@").last.map { String($0.prefix(19)) } ?? "") — a new base"))
        rec.reference = r.reference
        rec.layers = r.layers
        rec.environment = r.environment
        rec.path = r.path
        rec.builtAt = Date()
        rec.dockerfileSHA256 = before
        rec.builds = (rec.builds ?? 0) + 1
        rec.builtWith = status.version.map { "container \($0)" }
        try Dockerfiles.save(rec, store)
    }

    static func buildMilliseconds(since t0: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - t0
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    /// Follow `p` until it ends: its events so far and as they come go to `emit`.
    func follow(_ p: Preparation, emit: @escaping @Sendable (HostEvent) -> Void) async throws {
        let token = p.subscribe(emit)
        defer { p.unsubscribe(token) }
        try await p.wait()
    }

    /// Follow several at once (their events interleave, each carries its image's name).
    func follow(_ ps: [Preparation], emit: @escaping @Sendable (HostEvent) -> Void) async -> [Error] {
        let tokens = ps.map { $0.subscribe(emit) }
        defer { for (p, t) in zip(ps, tokens) { p.unsubscribe(t) } }
        var errors: [Error] = []
        for p in ps {
            do { try await p.wait() } catch { errors.append(error) }
        }
        return errors
    }

    func preparationInfos() -> [PreparationInfo] {
        let running = preparations.values.filter(\.isRunning).sorted { $0.startedAt < $1.startedAt }.map(\.info)
        let ids = Set(running.map(\.id))
        return running + recentPreparations.map(\.info).filter { !ids.contains($0.id) }
    }

    /// Images being prepared now.
    public func runningPreparations() -> [String] {
        preparations.values.filter(\.isRunning).map(\.image).sorted()
    }

    /// Validated image names, in the order given, without repeats.
    static func preparableImages(_ names: [String], store: DozerStore? = nil) throws -> [String] {
        var out: [String] = []
        for raw in names {
            // 596: any base × agent image, by any of its names.
            let n = DozerImages.canonicalName(raw)
            guard DozerImages.builtIn.contains(n) || store.map({ DozerImages.isPreparable(n, store: $0) }) == true else {
                throw HostError(.invalid, "unknown image \(raw) — lab, claude-code, pi, or a base × agent image (doz base ls)")
            }
            if !out.contains(n) { out.append(n) }
        }
        return out
    }

    /// `prepare`: start (or join) the named images' preparations; with `follow` (the default) wait for
    /// them, their progress on `emit`. No images and `follow`: join whatever is running (`doz onboard
    /// --status`).
    func prepare(_ r: HostRequest, emit: @escaping @Sendable (HostEvent) -> Void, onboarding: Bool) async throws -> PrepareResult {
        let images = try Self.preparableImages(r.images ?? [], store: store)
        let who = r.requestedBy.map { String($0.prefix(60)) } ?? (onboarding ? "onboard" : "prepare")
        let preps: [Preparation]
        if images.isEmpty && !onboarding {
            preps = preparations.values.filter(\.isRunning).sorted { $0.startedAt < $1.startedAt }
        } else {
            // An image already prepared for this build is not prepared again (a re-run of onboarding
            // prepares nothing); one being prepared is joined.
            var todo: [String] = []
            let s = store
            let check = preparedCheck
            for i in images {
                // 594: latest resolved first. (594 W28: an image already prepared by THIS doz is not
                // prepared again, even when a newer agent release is out — that is said, not done; one an
                // older doz made IS prepared here: preparing is what the user asked for.)
                await freshen(i, update: false)
                if runningPreparation(i) != nil { todo.append(i); continue }
                let ready = await Task.detached { check(i, s) }.value
                if ready {
                    emit(HostEvent(kind: .note, sandbox: i, text: "\(i) is already prepared in this store — nothing to do"))
                    await freshen(i, update: true)
                } else { todo.append(i) }
            }
            preps = try todo.map { try preparation(for: $0, requestedBy: who) }
        }
        var record: OnboardingRecord?
        if onboarding {
            let store = self.store, version = self.version
            if preps.isEmpty {
                record = try OnboardingRecord.record(store, version: version, images: images)
            } else {
                // The record is written when every image is ready — by the host, so a detached CLI
                // (Ctrl-C) or a closed wizard still completes the onboarding.
                let all = preps
                Task.detached {
                    for p in all { do { try await p.wait() } catch { return } }
                    _ = try? OnboardingRecord.record(store, version: version, images: images)
                }
            }
        }
        if r.follow ?? true, !preps.isEmpty {
            let errors = await follow(preps, emit: emit)
            if let e = errors.first { throw e }
            if onboarding {
                // The writer above runs beside this; write here too so the answer carries it.
                record = try OnboardingRecord.record(store, version: version, images: images)
            }
        }
        return PrepareResult(preparations: preps.map(\.info), onboarded: record ?? (onboarding ? OnboardingRecord.read(store) : nil))
    }

    /// `prepare-cancel`: the named images' preparations (all running ones with none named).
    func cancelPreparations(_ r: HostRequest) throws -> [PreparationInfo] {
        let names = try Self.preparableImages(r.images ?? [], store: store)
        let targets = preparations.values.filter { $0.isRunning && (names.isEmpty || names.contains($0.image)) }
        guard !targets.isEmpty else {
            throw HostError(.notFound, names.isEmpty ? "no image is being prepared" : "\(names.joined(separator: ", ")) \(names.count == 1 ? "is" : "are") not being prepared")
        }
        for p in targets {
            p.markCancelling()
            p.task?.cancel()
            note(nil, "cancelling the preparation of \(p.image)")
        }
        return targets.map(\.info)
    }

    func prepareStatus() throws -> PrepareStatus {
        PrepareStatus(preparations: preparationInfos(), onboarded: OnboardingRecord.read(store), images: try images(),
                      hostRunning: !readOnly)
    }

    /// Cancel every preparation and give them a moment to clean up (the host is exiting).
    func cancelAllPreparations(wait seconds: Double = 10) async {
        let running = preparations.values.filter(\.isRunning)
        guard !running.isEmpty else { return }
        for p in running { p.markCancelling(); p.task?.cancel() }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, running.contains(where: \.isRunning) { try? await Task.sleep(for: .milliseconds(100)) }
    }
}

/// A preparation step as a FIXED id (the usage statistics' `prep_failed`): the metrics' step keys, kebab-cased — a bake
/// step of an image recipe is `bake-step` (its label can carry a package or a version), anything else `other`.
public enum PreparationStepID {
    public static func of(_ label: String) -> String {
        let k = String(MetricsStepKey.key(for: label).dropFirst("step: ".count))
        if k.hasPrefix("bake step ") { return "bake-step" }
        return k.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
    }
}
