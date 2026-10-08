import Foundation
import XCTest
@testable import DozerKit

/// `KernelProvider` with no network: a fake fetcher serves a locally built archive.
final class KernelProviderTests: XCTestCase {
    private var dir: URL!
    private var archive: URL!
    private var kernelBytes = Data("pretend vmlinux \(UUID())".utf8)
    private let member = "opt/kata/share/kata-containers/vmlinux-test"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-kernel-\(UUID().uuidString)")
        let src = dir.appendingPathComponent("src/opt/kata/share/kata-containers")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try kernelBytes.write(to: src.appendingPathComponent("vmlinux-test"))
        try Data("another file".utf8).write(to: src.appendingPathComponent("other"))
        archive = dir.appendingPathComponent("release.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", dir.appendingPathComponent("src").path, "."]
        try tar.run(); tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func sha(_ d: Data) throws -> String {
        let u = dir.appendingPathComponent("h-\(UUID())"); try d.write(to: u); return try KernelProvider.sha256(of: u)
    }

    private func artifact(archiveSHA: String? = nil, kernelSHA: String? = nil) throws -> KernelArtifact {
        KernelArtifact(url: URL(string: "https://example.invalid/release.tar.gz")!,
                       archiveSHA256: try archiveSHA ?? KernelProvider.sha256(of: archive),
                       member: member, kernelSHA256: try kernelSHA ?? sha(kernelBytes), fileName: "vmlinux-test")
    }

    private func provider(_ a: KernelArtifact, seeds: [URL] = [], fetcher: FakeFetcher) -> KernelProvider {
        KernelProvider(artifact: a, cacheDirectory: dir.appendingPathComponent("cache"), seedCandidates: seeds, fetcher: fetcher)
    }

    func test_downloadVerifiesExtractsAndCaches() async throws {
        let f = FakeFetcher(serving: archive)
        let p = provider(try artifact(), fetcher: f)
        let events = EventLog()
        let url = try await p.resolve { events.add($0) }
        XCTAssertEqual(url, p.cachedKernel)
        XCTAssertEqual(try Data(contentsOf: url), kernelBytes)
        XCTAssertEqual(f.calls, 1)
        XCTAssertTrue(events.all.contains { if case .progress = $0 { true } else { false } }, "progress is reported")
        XCTAssertTrue(events.all.contains { if case .step(let s, _) = $0 { s.hasPrefix("verified and extracted") } else { false } })
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: p.cacheDirectory.path).filter { $0.hasSuffix(".partial") }
        XCTAssertEqual(leftovers, [], "no partial files left behind")
    }

    func test_cacheHitNeedsNoNetwork() async throws {
        let f = FakeFetcher(serving: archive)
        let p = provider(try artifact(), fetcher: f)
        _ = try await p.resolve()
        _ = try await p.resolve()
        _ = try await p.resolve()
        XCTAssertEqual(f.calls, 1, "downloaded once, then served from the cache")
    }

    func test_corruptedCacheIsReplaced() async throws {
        let f = FakeFetcher(serving: archive)
        let p = provider(try artifact(), fetcher: f)
        _ = try await p.resolve()
        try Data("bit rot".utf8).write(to: p.cachedKernel)
        let url = try await p.resolve()
        XCTAssertEqual(try Data(contentsOf: url), kernelBytes)
        XCTAssertEqual(f.calls, 2)
    }

    func test_archiveChecksumMismatchIsRefusedAndNothingIsCached() async throws {
        let p = provider(try artifact(archiveSHA: String(repeating: "0", count: 64)), fetcher: FakeFetcher(serving: archive))
        do { _ = try await p.resolve(); XCTFail("expected a checksum error") } catch let e as KernelError {
            guard case .checksumMismatch(let what, _, _) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(what, "kernel archive")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.cachedKernel.path))
    }

    func test_kernelChecksumMismatchIsRefused() async throws {
        let p = provider(try artifact(kernelSHA: String(repeating: "f", count: 64)), fetcher: FakeFetcher(serving: archive))
        do { _ = try await p.resolve(); XCTFail("expected a checksum error") } catch let e as KernelError {
            guard case .checksumMismatch(let what, _, _) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(what.hasPrefix("kernel opt/"), what)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.cachedKernel.path))
    }

    func test_explicitOverrideWinsAndMustExist() async throws {
        let f = FakeFetcher(serving: archive)
        let p = provider(try artifact(), fetcher: f)
        let mine = dir.appendingPathComponent("my-kernel")
        try Data("mine".utf8).write(to: mine)
        let got = try await p.resolve(override: mine.path)
        XCTAssertEqual(got, mine)
        XCTAssertEqual(f.calls, 0)
        do { _ = try await p.resolve(override: "/nonexistent/vmlinux"); XCTFail() } catch let e as KernelError {
            XCTAssertEqual(e, .overrideMissing("/nonexistent/vmlinux"))
        }
    }

    /// A byte-identical copy elsewhere (the `container` CLI's) seeds the cache offline; a
    /// DIFFERENT kernel there is ignored, never booted.
    func test_seedIsUsedOnlyWhenByteIdentical() async throws {
        let wrong = dir.appendingPathComponent("cli-kernel-wrong")
        try Data("some other kernel".utf8).write(to: wrong)
        let right = dir.appendingPathComponent("cli-kernel-right")
        try kernelBytes.write(to: right)

        let f1 = FakeFetcher(serving: archive)
        let p1 = provider(try artifact(), seeds: [wrong], fetcher: f1)
        // 594 W5/W7: what doctor and the step's label ask — is there a local, byte-identical copy?
        XCTAssertNil(p1.localSeed(), "a different kernel is no seed")
        XCTAssertEqual(provider(try artifact(), seeds: [wrong, right], fetcher: f1).localSeed(), right)
        _ = try await p1.resolve()
        XCTAssertEqual(f1.calls, 1, "a mismatching seed falls through to the pinned download")

        try FileManager.default.removeItem(at: p1.cachedKernel)
        let f2 = FakeFetcher(serving: archive)
        let p2 = provider(try artifact(), seeds: [wrong, right], fetcher: f2)
        let url = try await p2.resolve()
        XCTAssertEqual(f2.calls, 0, "an identical seed needs no network")
        XCTAssertEqual(try Data(contentsOf: url), kernelBytes)
    }

    func test_downloadFailureIsReported() async throws {
        let p = provider(try artifact(), fetcher: FakeFetcher(serving: nil))
        do { _ = try await p.resolve(); XCTFail() } catch let e as KernelError {
            guard case .downloadFailed = e else { return XCTFail("\(e)") }
        }
    }

    func test_recommendedPinIsTheContainerCLIKernel() {
        let r = KernelArtifact.recommended
        XCTAssertEqual(r.url.absoluteString, "https://github.com/kata-containers/kata-containers/releases/download/3.28.0/kata-static-3.28.0-arm64.tar.zst")
        XCTAssertEqual(r.member, "opt/kata/share/kata-containers/vmlinux-6.18.15-186")
        XCTAssertEqual(r.kernelSHA256, "2fe4a58d2885d623bcb4d705900ac8c1d4f02371152da8126b3b00c8c47fc3a1")
        XCTAssertEqual(r.archiveSHA256, "f63d54507d1f18635d94475077e4c2330de4d8e05cedf25f7c38f063b0e66a91")
        XCTAssertEqual(r.fileName, "vmlinux-6.18.15-186")
    }

    func test_specDefaultsToTheProviderUnderTheStore() throws {
        let spec = SandboxSpec(name: "lab", storeRoot: dir)
        XCTAssertNil(spec.kernelPath)
        let sb = try Sandbox(spec: spec)
        XCTAssertEqual(sb.kernelProvider.cacheDirectory, dir.appendingPathComponent("kernels"))
        var shared = spec
        shared.kernelCacheDirectory = dir.appendingPathComponent("shared")
        XCTAssertEqual(try Sandbox(spec: shared).kernelProvider.cacheDirectory, dir.appendingPathComponent("shared"))
    }
}

final class FakeFetcher: KernelFetching, @unchecked Sendable {
    let serving: URL?
    private let lock = NSLock()
    private var _calls = 0
    init(serving: URL?) { self.serving = serving }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        lock.withLock { _calls += 1 }
        guard let serving else { throw URLError(.notConnectedToInternet) }
        let size = Int64((try FileManager.default.attributesOfItem(atPath: serving.path)[.size] as? Int) ?? 0)
        progress(0, size)
        try FileManager.default.copyItem(at: serving, to: destination)
        progress(size, size)
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [KernelEvent] = []
    func add(_ e: KernelEvent) { lock.lock(); items.append(e); lock.unlock() }
    var all: [KernelEvent] { lock.lock(); defer { lock.unlock() }; return items }
}
