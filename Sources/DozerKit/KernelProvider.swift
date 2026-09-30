import ContainerizationArchive
import CryptoKit
import Foundation

/// A pinned Linux kernel: where the release archive is, what it must hash to, which member is
/// the kernel, and what THAT must hash to. Both hashes are checked — the archive's before
/// anything is extracted, the kernel's on every use.
public struct KernelArtifact: Sendable, Codable, Equatable {
    public var url: URL
    public var archiveSHA256: String
    /// Path of the kernel inside the archive.
    public var member: String
    public var kernelSHA256: String
    /// The cached file name under the kernel cache directory.
    public var fileName: String

    public init(url: URL, archiveSHA256: String, member: String, kernelSHA256: String, fileName: String) {
        self.url = url
        self.archiveSHA256 = archiveSHA256
        self.member = member
        self.kernelSHA256 = kernelSHA256
        self.fileName = fileName
    }

    /// The kernel Apple's `container` CLI 1.2.2 installs with `container system kernel set
    /// --recommended`: vmlinux 6.18.15 from the kata-containers 3.28.0 static release for arm64
    /// (the CLI's built-in `kernelTarURL` default and member path). GPL-2.0, redistributed
    /// unmodified from upstream — see LICENCES.md.
    public static let recommended = KernelArtifact(
        url: URL(string: "https://github.com/kata-containers/kata-containers/releases/download/3.28.0/kata-static-3.28.0-arm64.tar.zst")!,
        archiveSHA256: "f63d54507d1f18635d94475077e4c2330de4d8e05cedf25f7c38f063b0e66a91",
        member: "opt/kata/share/kata-containers/vmlinux-6.18.15-186",
        kernelSHA256: "2fe4a58d2885d623bcb4d705900ac8c1d4f02371152da8126b3b00c8c47fc3a1",
        fileName: "vmlinux-6.18.15-186")
}

/// Downloads a URL to a local file, reporting (bytes so far, total if known).
public protocol KernelFetching: Sendable {
    func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws
}

/// What can go wrong fetching or verifying the pinned Linux kernel (`KernelProvider`).
public enum KernelError: Error, LocalizedError, Equatable {
    case checksumMismatch(what: String, expected: String, actual: String)
    case overrideMissing(String)
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .checksumMismatch(let what, let e, let a): "\(what) sha256 mismatch: expected \(e), got \(a)"
        case .overrideMissing(let p): "no kernel at the explicit kernelPath \(p)"
        case .downloadFailed(let s): "kernel download failed: \(s)"
        }
    }
}

/// What the provider reports while it works.
public enum KernelEvent: Sendable, Equatable {
    case step(String, milliseconds: Double)
    case note(String)
    case progress(String, completedBytes: Int64, totalBytes: Int64?)
}

/// Resolves the Linux kernel a sandbox boots, so the library never depends on another tool
/// having installed one:
///
/// 1. an explicit `SandboxSpec.kernelPath` — used as given (must exist);
/// 2. the cached pinned kernel `<cache>/<fileName>`, if its sha256 matches;
/// 3. a SEED: an existing copy elsewhere on this Mac whose sha256 matches the pin exactly (the
///    `container` CLI's `kernels/vmlinux-…`) is copied into the cache — no network. Only a
///    byte-identical file is accepted, so this is not a fallback to "whatever kernel that tool
///    has": a different kernel there is ignored, never booted;
/// 4. otherwise download the pinned archive (once), verify it, extract the member, verify it,
///    and move it into the cache atomically.
public struct KernelProvider: Sendable {
    public var artifact: KernelArtifact
    public var cacheDirectory: URL
    public var seedCandidates: [URL]
    public var fetcher: any KernelFetching

    public init(artifact: KernelArtifact = .recommended, cacheDirectory: URL,
                seedCandidates: [URL] = KernelProvider.defaultSeedCandidates,
                fetcher: any KernelFetching = URLSessionKernelFetcher()) {
        self.artifact = artifact
        self.cacheDirectory = cacheDirectory
        self.seedCandidates = seedCandidates
        self.fetcher = fetcher
    }

    /// Where Apple's `container` CLI keeps its kernels.
    public static var defaultSeedCandidates: [URL] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.container/kernels")
        return [dir.appendingPathComponent(KernelArtifact.recommended.fileName),
                dir.appendingPathComponent("default.kernel-arm64")]
    }

    public var cachedKernel: URL { cacheDirectory.appendingPathComponent(artifact.fileName) }

    /// 594 W5/W7: a byte-identical copy of the pinned kernel already on this Mac (Apple's `container`
    /// kernels) — `resolve` copies it instead of downloading. nil: none (a download it is).
    public func localSeed() -> URL? {
        seedCandidates.first { FileManager.default.fileExists(atPath: $0.path) && (try? Self.sha256(of: $0)) == artifact.kernelSHA256 }
    }

    /// The kernel to boot. `override` is `SandboxSpec.kernelPath`.
    public func resolve(override: String? = nil, events: @escaping @Sendable (KernelEvent) -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        if let override, !override.isEmpty {
            guard fm.fileExists(atPath: override) else { throw KernelError.overrideMissing(override) }
            return URL(fileURLWithPath: override)
        }
        let target = cachedKernel
        if fm.fileExists(atPath: target.path) {
            let t0 = ContinuousClock.now
            let sum = try Self.sha256(of: target)
            if sum == artifact.kernelSHA256 {
                events(.step("kernel \(artifact.fileName) ready (cached, sha256 verified)", milliseconds: milliseconds(since: t0)))
                return target
            }
            events(.note("cached kernel \(target.lastPathComponent) failed its checksum — replacing it"))
            try? fm.removeItem(at: target)
        }
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        for seed in seedCandidates where fm.fileExists(atPath: seed.path) {
            guard (try? Self.sha256(of: seed)) == artifact.kernelSHA256 else { continue }
            try install(from: seed, copy: true)
            events(.note("kernel \(artifact.fileName) copied from \(seed.path) (byte-identical to the pin)"))
            return target
        }

        let archive = cacheDirectory.appendingPathComponent("download-\(UUID().uuidString.prefix(8)).partial")
        defer { try? fm.removeItem(at: archive) }
        events(.note("downloading the pinned kernel (one-time): \(artifact.url.absoluteString)"))
        let t0 = ContinuousClock.now
        let label = "kernel archive \(artifact.url.lastPathComponent)"
        let reporter = ProgressThrottle(label: label, events: events)
        do {
            try await fetcher.fetch(artifact.url, to: archive) { done, total in reporter.report(done, total) }
        } catch {
            throw KernelError.downloadFailed(error.localizedDescription)
        }
        events(.step("downloaded \(label) (\(Self.mib(archive)) MiB)", milliseconds: milliseconds(since: t0)))

        let t1 = ContinuousClock.now
        let archiveSum = try Self.sha256(of: archive)
        guard archiveSum == artifact.archiveSHA256 else {
            throw KernelError.checksumMismatch(what: "kernel archive", expected: artifact.archiveSHA256, actual: archiveSum)
        }
        let extracted = cacheDirectory.appendingPathComponent("extract-\(UUID().uuidString.prefix(8)).partial")
        defer { try? fm.removeItem(at: extracted) }
        let reader = try ArchiveReader(file: archive)
        let (_, data) = try reader.extractFile(path: artifact.member)
        try data.write(to: extracted)
        let kernelSum = try Self.sha256(of: extracted)
        guard kernelSum == artifact.kernelSHA256 else {
            throw KernelError.checksumMismatch(what: "kernel \(artifact.member)", expected: artifact.kernelSHA256, actual: kernelSum)
        }
        try install(from: extracted, copy: false)
        events(.step("verified and extracted \(artifact.fileName)", milliseconds: milliseconds(since: t1)))
        return target
    }

    /// Move (or copy) a verified file into place atomically — two processes filling one cache at
    /// once both end with a whole file.
    private func install(from source: URL, copy: Bool) throws {
        let fm = FileManager.default
        let staged = cacheDirectory.appendingPathComponent("stage-\(UUID().uuidString.prefix(8)).partial")
        if copy { try fm.copyItem(at: source, to: staged) } else { try fm.moveItem(at: source, to: staged) }
        if rename(staged.path, cachedKernel.path) != 0 {
            try? fm.removeItem(at: staged)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func mib(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1_048_576
    }
}

/// Emits a progress event at most every 5% (or every 32 MiB when the size is unknown).
private final class ProgressThrottle: @unchecked Sendable {
    let label: String
    let events: @Sendable (KernelEvent) -> Void
    private let lock = NSLock()
    private var lastBucket = -1
    init(label: String, events: @escaping @Sendable (KernelEvent) -> Void) {
        self.label = label
        self.events = events
    }
    func report(_ done: Int64, _ total: Int64?) {
        let bucket: Int = if let total, total > 0 { Int(done * 20 / total) } else { Int(done / (32 << 20)) }
        lock.lock()
        let emit = bucket != lastBucket
        if emit { lastBucket = bucket }
        lock.unlock()
        if emit { events(.progress(label, completedBytes: done, totalBytes: total)) }
    }
}

/// The real fetcher: a URLSession download task (streamed to a temporary file by the system),
/// with progress from the download delegate, moved to `destination` when complete.
public struct URLSessionKernelFetcher: KernelFetching {
    public init() {}

    public func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            delegate.continuation = c
            session.downloadTask(with: url).resume()
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Int64, Int64?) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?
    private var status = 0

    init(destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let c = continuation
        continuation = nil
        if let error { c?.resume(throwing: error) }
        else if let moveError { c?.resume(throwing: moveError) }
        else if !(200..<300).contains(status) { c?.resume(throwing: KernelError.downloadFailed("HTTP \(status) for \(task.originalRequest?.url?.absoluteString ?? "?")")) }
        else { c?.resume() }
    }
}
