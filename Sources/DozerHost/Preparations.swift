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
    private let board = ProgressBoard(tailLines: 3)
    private let formatter = ProgressTerminal(mode: .plain, color: false)
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var outcome: Result<Void, Error>?
    var task: Task<Void, Never>?

    static let maximumEvents = 600

    init(image: String, requestedBy: String) {
        id = String(UUID().uuidString.prefix(8)).lowercased()
        self.image = image
        _requestedBy = [requestedBy]
    }

    var state: String { lock.withLock { _state } }
    var isRunning: Bool { lock.withLock { _state == "running" || _state == "cancelling" } }

    func joined(by who: String) { lock.withLock { if !_requestedBy.contains(who) { _requestedBy.append(who) } } }

    /// An event of this preparation: kept, applied to the board, passed to every subscriber.
    func emit(_ e: HostEvent) {
        let subs: [@Sendable (HostEvent) -> Void] = lock.withLock {
            let finals = board.apply(e)
            for f in finals { finished.append(formatter.format(f)) }
            if finished.count > 40 { finished.removeFirst(finished.count - 40) }
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
            return PreparationInfo(id: id, image: image, state: _state, requestedBy: _requestedBy, startedAt: startedAt, finishedAt: _finishedAt,
                                   seconds: (_finishedAt ?? now).timeIntervalSince(startedAt), error: _error, step: step, stepSeconds: stepSeconds,
                                   transfer: transfer, output: output, lines: finished)
        }
    }
}

extension HostCore {
    /// Whether `image` is ready for this build: the guest init disk is there and so is a bake with
    /// the key this build makes (the kernel cached and hashed — an older build's bake does not count).
    /// The lab: its prepared disk for the default lab spec.
    @Sendable nonisolated static func isPrepared(_ image: String, _ store: DozerStore) -> Bool {
        guard FileManager.default.fileExists(atPath: store.layout("_").initfs.path),
              let spec = try? DozerImages.spec(name: "doz-prepare-\(image)", options: CreateOptions(image: image), store: store).0 else { return false }
        guard let imageSpec = spec.imageSpec else {
            return FileManager.default.fileExists(atPath: StoreLayout(spec: spec).golden(for: spec).path)
        }
        let kernel = spec.kernelPath.map { URL(fileURLWithPath: $0) }
            ?? KernelProvider(cacheDirectory: spec.kernelCacheDirectory ?? StoreLayout(spec: spec).kernels).cachedKernel
        guard FileManager.default.fileExists(atPath: kernel.path), let deckhold = DeckholdBinary.locate(),
              let k = try? KernelProvider.sha256(of: kernel), let d = try? KernelProvider.sha256(of: deckhold) else { return false }
        return ImageBaker(storeRoot: store.root).cached(imageSpec, key: imageSpec.bakeKey(kernelSHA256: k, deckholdSHA256: d)) != nil
    }

    /// What a start of `m` has to wait for: the image whose preparation it should join — one running
    /// now, or one not prepared for this build (then a preparation starts, which a second start
    /// joins). nil: nothing to wait for (a kept disk, a custom image, an image already prepared).
    func imageToPrepare(_ m: Managed) async -> String? {
        let spec = m.sandbox.spec
        guard spec.customImage == nil, !m.sandbox.hasRootDisk else { return nil }
        let image: String
        if let imageSpec = spec.imageSpec {
            guard DozerImages.builtIn.contains(imageSpec.name) else { return nil }
            image = imageSpec.name
        } else {
            // The lab: only when this sandbox's prepared disk is the one a lab preparation makes.
            guard let lab = try? DozerImages.spec(name: "doz-prepare-lab", options: CreateOptions(image: "lab"), store: store).0,
                  StoreLayout.goldenKey(for: lab) == StoreLayout.goldenKey(for: spec) else { return nil }
            image = "lab"
        }
        if runningPreparation(image) != nil { return image }
        let s = store
        let check = preparedCheck
        let ready = await Task.detached { check(image, s) }.value
        return ready ? nil : image
    }

    func runningPreparation(_ image: String) -> Preparation? {
        preparations[image].flatMap { $0.isRunning ? $0 : nil }
    }

    /// The preparation of `image`: the one running (joined), or a new one.
    func preparation(for image: String, requestedBy who: String) throws -> Preparation {
        guard DozerImages.builtIn.contains(image) else {
            throw HostError(.invalid, "only the built-in images are prepared (lab, claude-code, pi) — not \(image)")
        }
        if let p = runningPreparation(image) {
            p.joined(by: who)
            return p
        }
        guard !readOnly else { throw HostError(.unavailable, "preparing an image needs the host") }
        let p = Preparation(image: image, requestedBy: who)
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
        recordPreparation(p.image, started: started, t0: t0, ok: ok, error: i.error)
    }

    /// The work itself, off the actor: the kernel and guest init disk, then the image's bake (the lab:
    /// its prepared disk, made by booting a throwaway sandbox once).
    @Sendable static func runPreparation(_ image: String, _ store: DozerStore, _ emit: @escaping @Sendable (HostEvent) -> Void) async throws {
        let tmpName = "doz-prepare-\(image)"
        // A throwaway sandbox a crashed preparation left behind would cold-boot its kept disk
        // instead of baking: it goes first.
        try? FileManager.default.removeItem(at: store.layout(tmpName).sandboxDirectory)
        let spec = try DozerImages.spec(name: tmpName, options: CreateOptions(image: image), store: store).0
        let sb = try Sandbox(spec: spec)
        let stream = sb.events()
        let forward = Task { for await e in stream { if let he = HostEvent(e, sandbox: image) { emit(he) } } }
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
    static func preparableImages(_ names: [String]) throws -> [String] {
        var out: [String] = []
        for n in names {
            guard DozerImages.builtIn.contains(n) else { throw HostError(.invalid, "unknown image \(n) — lab, claude-code or pi") }
            if !out.contains(n) { out.append(n) }
        }
        return out
    }

    /// `prepare`: start (or join) the named images' preparations; with `follow` (the default) wait for
    /// them, their progress on `emit`. No images and `follow`: join whatever is running (`doz onboard
    /// --status`).
    func prepare(_ r: HostRequest, emit: @escaping @Sendable (HostEvent) -> Void, onboarding: Bool) async throws -> PrepareResult {
        let images = try Self.preparableImages(r.images ?? [])
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
                if runningPreparation(i) != nil { todo.append(i); continue }
                let ready = await Task.detached { check(i, s) }.value
                if ready { emit(HostEvent(kind: .note, sandbox: i, text: "\(i) is already prepared in this store — nothing to do")) }
                else { todo.append(i) }
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
        let names = try Self.preparableImages(r.images ?? [])
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
