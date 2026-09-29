// `doz-vmtest pullbench [--rounds N] [--reference REF] [--store DIR]` (594, D12): how many layers a
// base pull should download at once. Containerization's default is 3; the node base (the agent
// images') has a handful of layers for linux/arm64. Each run pulls the digest-pinned reference for
// linux/arm64 into a FRESH image store (nothing cached), alternating 3 and 6 (and 6, 3 the next
// round, so neither always goes first), and prints the seconds and the bytes. No VM, no entitlement.
// The directories are under --store (default $TMPDIR/doz-pullbench) and removed after each pull.
import Foundation
import Containerization
import ContainerizationOCI
import DozerKit

final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    func add(_ n: Int64) { lock.withLock { bytes += n } }
    var total: Int64 { lock.withLock { bytes } }
}

func pullBench() async throws {
    let rounds = args.firstIndex(of: "--rounds").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 3
    let reference = args.firstIndex(of: "--reference").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? AgentImages.nodeBase
    let root = args.contains("--store") ? storeRoot : URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("doz-pullbench")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    print("pullbench: \(reference) (linux/arm64), \(rounds) round(s) of 3 and 6 concurrent layer downloads, fresh stores under \(root.path)")
    var times: [Int: [Double]] = [3: [], 6: []]
    for r in 0..<rounds {
        for c in (r % 2 == 0 ? [3, 6] : [6, 3]) {
            let dir = root.appendingPathComponent("r\(r)-c\(c)")
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = try ImageStore(path: dir)
            let counter = ByteCounter()
            let t0 = ContinuousClock.now
            _ = try await store.pull(reference: reference, platform: Platform(arch: "arm64", os: "linux"), progress: { batch in
                for e in batch { if case .addSize(let n) = e { counter.add(n) } }
            }, maxConcurrentDownloads: c)
            let d = ContinuousClock.now - t0
            let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            times[c, default: []].append(s)
            print(String(format: "pullbench: round %d, concurrency %d: %.1f s, %.1f MB (%.1f MB/s)", r + 1, c, s,
                         Double(counter.total) / 1e6, s > 0 ? Double(counter.total) / 1e6 / s : 0))
        }
    }
    func median(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
    let m3 = median(times[3] ?? []), m6 = median(times[6] ?? [])
    print(String(format: "pullbench: median — 3 at once: %.1f s · 6 at once: %.1f s → %@", m3, m6, m6 < m3 ? "6 is faster" : "3 is as fast or faster"))
    check(true, "pullbench done")
}
