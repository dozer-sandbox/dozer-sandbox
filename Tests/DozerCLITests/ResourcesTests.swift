import Darwin
import Foundation
import XCTest
@testable import DozerKit
@testable import DozerHost

/// 595 — Resources: every byte of a (synthetic) store on a row, the three numbers, the refusals, the
/// safe set, the plan and the deletion. No VM, no host, no keychain: a throwaway store under /tmp
/// (APFS, so the clones share blocks as real images and sandboxes do).
final class ResourcesTests: XCTestCase {
    private var root: URL!
    private var store: DozerStore!
    private let labKey = "alpine-3.20-aaaaaaaaaaaa"
    private let ccKey = "abcdefabcdef"
    private let ccOld = "111111111111"
    /// This build's pinned kernel (fetched again when missing) — the current one here.
    private let pinned = KernelArtifact.recommended.fileName
    private var pinnedID: String { "kernel:" + Resources.kernelVersion(pinned) }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/d595u-\(UUID().uuidString.prefix(8))")
        store = DozerStore(root: root)
        try build()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: the synthetic store

    private func write(_ rel: String, bytes n: Int, seed: UInt8 = 1) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var d = Data(count: n)
        d.withUnsafeMutableBytes { p in for i in 0..<n { p[i] = UInt8(truncatingIfNeeded: i &* 31 &+ Int(seed)) } }
        try d.write(to: url)
    }

    private func clone(_ from: String, _ to: String) throws {
        let dst = root.appendingPathComponent(to)
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(Darwin.clonefile(root.appendingPathComponent(from).path, dst.path, 0), 0, "APFS clone")
    }

    private func build() throws {
        try write("golden/\(labKey).ext4", bytes: 1 << 20, seed: 2)
        try clone("golden/\(labKey).ext4", "sandboxes/a/rootfs.ext4")
        try write("sandboxes/a/state.ext4", bytes: 64 << 10, seed: 3)
        try write("sandboxes/a/sandbox.json", bytes: 300)
        try write("sandboxes/a/screens/shell.vt", bytes: 5000)
        try write("sandboxes/a/boots/1.json", bytes: 7000)
        try clone("sandboxes/a/rootfs.ext4", "sandboxes/a/restore-points/rp1/root.ext4")
        try write("images/bases/f97ac66c1d54/root.ext4", bytes: 256 << 10, seed: 4)
        try clone("images/bases/f97ac66c1d54/root.ext4", "images/claude-code/\(ccKey)/root.ext4")
        try write("images/claude-code/\(ccKey)/manifest.json", bytes: 200)
        try write("images/claude-code/\(ccKey).lock", bytes: 0)
        try write("images/claude-code/\(ccOld)/root.ext4", bytes: 128 << 10, seed: 5)
        try write("images/custom/tpl/id1/root.ext4", bytes: 96 << 10, seed: 6)
        try write("content/blobs/sha256/x", bytes: 300 << 10, seed: 7)
        try write("state.json", bytes: 900)
        try write("initfs.ext4", bytes: 200 << 10, seed: 8)
        try write("kernels/vmlinux-6.1-1", bytes: 40 << 10, seed: 9)
        try write("kernels/\(pinned)", bytes: 44 << 10, seed: 10)
        try write("kernels/vmlinux-9.9-custom", bytes: 36 << 10, seed: 12)
        try write("containers/claude-code-bake/scratch.ext4", bytes: 48 << 10, seed: 11)
        try write("host.log", bytes: 9000)
        try write("metrics.sqlite", bytes: 12000)
        try write("accounts.json", bytes: 100)
        try write("stray.txt", bytes: 3000)
        try write("junk/deep/file", bytes: 4000)
    }

    private func facts(phase: Phase = .off, created: Date = Date(), preparing: Set<String> = [], snapshotKernel: String? = nil,
                       workspace: String? = nil, kernelPath: String? = nil, current: String? = nil) -> ResourceFacts {
        ResourceFacts(sandboxes: [.init(name: "a", phase: phase, image: "lab", createdAt: created, rootImage: labKey, workspace: workspace,
                                        memoryMiB: 1024, ramHeldMiB: phase.holdsRAM ? 1000 : 0, cpus: 2, snapshotKernelFile: snapshotKernel,
                                        kernelPath: kernelPath)],
                      currentImageKeys: ["claude-code": ccKey, "lab": labKey], preparing: preparing,
                      kernelCache: root.appendingPathComponent("kernels"), currentKernel: root.appendingPathComponent("kernels/" + (current ?? pinned)),
                      unusedDays: 30, preparationSeconds: ["claude-code": 150], hostFootprintBytes: 5 << 20,
                      settingsFile: URL(fileURLWithPath: "/tmp/d595u-none/doz.toml"), accounts: ["work"], executable: "/usr/local/bin/doz")
    }

    private func du(_ url: URL) throws -> Int64 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-sk", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (Int64(out.split(separator: "\t").first ?? "0") ?? 0) * 1024
    }

    private func item(_ r: ResourceReport, _ id: String) -> ResourceItem? { r.items.first { $0.id == id } }

    // MARK: tests

    func testIDsAreValidated() {
        for ok in ["initfs", "logs", "metrics", "cache:downloads", "image:pi", "image:claude-code@abcdefabcdef", "image:lab@alpine-3.20-aaaa",
                   "template:my-tpl", "point:web/rp-20260930-1", "kernel:6.18.15-186", "stray:notes.txt", "leftover:pi-bake", "base:f97ac66c1d54"] {
            XCTAssertTrue(Resources.isValidID(ok), ok)
        }
        for bad in ["", "image:", "image:../etc", "stray:..", "point:a/../../b", "/etc/passwd", "Image:pi", "image:pi x", "image:-x",
                    "stray:a\nb", String(repeating: "a", count: 241), "stray:.hidden"] {
            XCTAssertFalse(Resources.isValidID(bad), bad)
        }
    }

    func testEveryEntryHasExactlyOneLeaf() {
        let c = { (s: String) in Resources.classify(s.split(separator: "/").map(String.init), currentLabKey: nil) }
        XCTAssertEqual(c("sandboxes/a/rootfs.ext4"), "sandbox:a/root")
        XCTAssertEqual(c("sandboxes/a/state.ext4"), "sandbox:a/state")
        XCTAssertEqual(c("sandboxes/a/vm.state"), "sandbox:a/snapshot")
        XCTAssertEqual(c("sandboxes/a/restore-points/rp1/root.ext4"), "point:a/rp1")
        XCTAssertEqual(c("sandboxes/a/screens/x.vt"), "screens:a")
        XCTAssertEqual(c("sandboxes/a/boots/1.json"), "boots:a")
        XCTAssertEqual(c("sandboxes/a/egress-ca.pem"), "sandbox:a/files")
        XCTAssertEqual(c("images/claude-code/\(ccKey).lock"), "image:claude-code@\(ccKey)", "a key's lock goes with its key")
        XCTAssertEqual(c("images/claude-code"), "image:claude-code")
        XCTAssertEqual(c("images/bases/f97ac66c1d54.lock"), "base:f97ac66c1d54")
        XCTAssertEqual(c("images/custom/tpl/id1/root.ext4"), "template:tpl")
        XCTAssertEqual(c("golden/\(labKey).ext4"), "image:lab@\(labKey)")
        XCTAssertEqual(c("golden/alpine-3.20-76cd0f8d470b.fsck.ext4"), "helper:fsck", "the e2fsck helper's disk is not the lab's")
        XCTAssertEqual(c("content/blobs/x"), "cache:downloads")
        XCTAssertEqual(c("state.json"), "cache:downloads")
        XCTAssertEqual(c("kernels/vmlinux-6.18.15-186"), "kernel:6.18.15-186")
        XCTAssertEqual(c("containers/pi-bake"), "leftover:pi-bake")
        XCTAssertEqual(c("metrics.sqlite-wal"), "metrics")
        XCTAssertEqual(c("host.log"), "logs")
        XCTAssertEqual(c("host.sock"), "store")
        // 606: doz serve's lock, socket and folder (devices, audit log, port); 605's doz ui files.
        for f in ["serve.lock", "serve.sock", "serve/devices.json", "serve/audit.jsonl", "serve/port", "ui.port", "ui.sessions", "ui.revoked", "ui.operations.json"] {
            XCTAssertEqual(c(f), "store", f)
        }
        XCTAssertEqual(c("notes.txt"), "stray:notes.txt")
        XCTAssertEqual(c("junk/deep/file"), "stray:junk")
    }

    func testExclusiveCountsOnlyWhatOneGroupHolds() {
        typealias E = DiskAccounting.Extent
        let a = [E(logical: 0, physical: 0, length: 100)], b = [E(logical: 0, physical: 50, length: 100)]
        let split = DiskAccounting.exclusive([a, b], groups: [0, 1])
        XCTAssertEqual(split.freed[0], 50)
        XCTAssertEqual(split.freed[1], 50)
        XCTAssertEqual(split.union, 150)
        XCTAssertEqual(DiskAccounting.exclusive([a, b], groups: [7, 7]).freed[7], 150, "together they free everything")
        XCTAssertNil(DiskAccounting.exclusive([a, a], groups: [0, 1]).freed[0], "a clone frees nothing alone")
    }

    func testTheAccountAddsUpToDuAndEveryByteIsOnARow() throws {
        let r = Resources.inventory(store: store, facts: facts())
        XCTAssertEqual(r.totalBytes, try du(root), "the total is what du counts")
        XCTAssertEqual(r.unattributedBytes, 0, "every byte is on a row")
        XCTAssertEqual(r.attributedBytes, r.totalBytes)
        // Parents fold their parts: the top-level rows add up to the total too.
        let top = r.items.filter { $0.parent == nil && $0.group != "outside" }.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
        XCTAssertEqual(top, r.totalBytes)
        XCTAssertLessThan(r.occupiedBytes, r.totalBytes, "clones are counted once on the volume")
        // Freed: a clone frees only what it does not share.
        let golden = try XCTUnwrap(item(r, "image:lab@\(labKey)"))
        XCTAssertEqual(golden.sizeBytes, 1 << 20)
        XCTAssertEqual(golden.freedBytes, 0, "the sandbox and its restore point share every block")
        XCTAssertEqual(golden.usedBy, ["a"])
        XCTAssertEqual(item(r, "image:claude-code@\(ccOld)")?.freedBytes, 128 << 10)
        XCTAssertEqual(item(r, "base:f97ac66c1d54")?.freedBytes, 0, "the image cloned from it holds its blocks")
        XCTAssertEqual(item(r, "image:claude-code")?.freedBytes, (128 << 10) + 4096, "both keys' own blocks + the manifest")
        XCTAssertEqual(item(r, "stray:junk")?.sizeBytes, 4096)
        XCTAssertEqual(item(r, "sandbox:a/root")?.link, "sandbox:a")
        XCTAssertEqual(item(r, "image:claude-code")?.link, "images")
        XCTAssertEqual(item(r, "outside:keychain")?.link, "accounts")
        XCTAssertTrue(item(r, "outside:keychain")?.detail?.contains("work") ?? false)
        XCTAssertNil(item(r, "outside:keychain")?.sizeBytes)
        // Memory, CPUs, kernels.
        XCTAssertEqual(r.memory.map(\.kind), ["host"], "a shut-down sandbox holds no memory")
        XCTAssertEqual(Set(r.kernels.map(\.id)), ["kernel:6.1-1", pinnedID, "kernel:9.9-custom"])
        XCTAssertEqual(r.kernels.filter(\.current).map(\.id), [pinnedID])
        XCTAssertEqual(r.kernels.filter(\.pinned).map(\.id), [pinnedID])
        XCTAssertEqual(item(r, "image:claude-code@\(ccKey)")?.current, true)
        XCTAssertTrue(item(r, "image:claude-code")?.later?.contains("3 min") ?? false, "re-prepared in about the time it took")
        let running = Resources.inventory(store: store, facts: facts(phase: .running))
        XCTAssertEqual(running.memory.first?.heldBytes, 1000 << 20)
        XCTAssertEqual(running.allocatedCPUs, 2)
    }

    func testRefusals() throws {
        // A hibernated sandbox's snapshot needs the current kernel and the guest init.
        let f = facts(phase: .hibernated, snapshotKernel: pinned)
        let r = Resources.inventory(store: store, facts: f)
        XCTAssertNotNil(item(r, "initfs")?.refusal)
        XCTAssertNotNil(item(r, pinnedID)?.refusal)
        XCTAssertNil(item(r, "kernel:6.1-1")?.refusal, "a kernel no snapshot needs and new boots do not use can go")
        XCTAssertEqual(r.kernels.first { $0.id == pinnedID }?.usedBy, ["a"])
        let p = Resources.plan(store: store, facts: f, ids: ["initfs", pinnedID, "kernel:6.1-1", "sandbox:a", "sandbox:a/root",
                                                            "template:tpl", "outside:settings", "store", "unattributed", "image:nope"], clean: false)
        XCTAssertEqual(p.items.map(\.id), ["kernel:6.1-1", "template:tpl"])
        XCTAssertEqual(Set(p.refused.map(\.id)), ["initfs", pinnedID, "sandbox:a", "sandbox:a/root", "outside:settings", "store", "unattributed", "image:nope"])
        XCTAssertTrue(p.refused.first { $0.id == "initfs" }!.reason.contains("a is hibernated"))
        XCTAssertEqual(p.items.first { $0.id == "template:tpl" }?.warning, "a template cannot be re-created")
        // Running is refused too (its VM has the guest init attached; the next pause would snapshot it).
        let running = Resources.plan(store: store, facts: facts(phase: .running), ids: ["initfs", pinnedID], clean: false)
        XCTAssertEqual(running.items.map(\.id), [])
        // All off: the guest init and the pinned kernel can go (re-created at the next start).
        let off = Resources.plan(store: store, facts: facts(), ids: ["initfs", pinnedID], clean: false)
        XCTAssertEqual(off.items.map(\.id), ["initfs", pinnedID])
        XCTAssertTrue(off.items[0].later?.contains("rebuilt") ?? false)
        XCTAssertTrue(off.items[1].later?.contains("re-downloaded") ?? false)
        // A kernel chosen with kernel.path is not fetched again: refused while new sandboxes boot it, and
        // while a sandbox created with it would boot it.
        let custom = root.appendingPathComponent("kernels/vmlinux-9.9-custom").path
        let chosen = Resources.plan(store: store, facts: facts(current: "vmlinux-9.9-custom"), ids: ["kernel:9.9-custom", pinnedID], clean: false)
        XCTAssertEqual(chosen.items.map(\.id), [pinnedID], "the pinned one is not current then: it can go")
        XCTAssertTrue(chosen.refused.first?.reason.contains("new sandboxes boot it") ?? false)
        let bootsIt = Resources.plan(store: store, facts: facts(kernelPath: custom), ids: ["kernel:9.9-custom"], clean: false)
        XCTAssertEqual(bootsIt.items.map(\.id), [])
        XCTAssertTrue(bootsIt.refused.first?.reason.contains("a needs it") ?? false)
        XCTAssertFalse(Set(Resources.cleanIDs(Resources.inventory(store: store, facts: facts(kernelPath: custom)).items)).contains("kernel:9.9-custom"))
        // An image being prepared, and everything a preparation reads, waits for it.
        let prep = Resources.plan(store: store, facts: facts(preparing: ["claude-code"]),
                                  ids: ["image:claude-code", "image:claude-code@\(ccOld)", "cache:downloads", "base:f97ac66c1d54", "image:lab"], clean: false)
        XCTAssertEqual(prep.items.map(\.id), ["image:lab"], "another image is not being prepared")
        XCTAssertEqual(Set(prep.refused.map(\.id)), ["image:claude-code", "image:claude-code@\(ccOld)", "cache:downloads", "base:f97ac66c1d54"])
        // A stray folder that is a sandbox's workspace is never deleted here.
        let ws = Resources.plan(store: store, facts: facts(workspace: root.appendingPathComponent("junk/deep").path), ids: ["stray:junk", "stray:stray.txt"], clean: false)
        XCTAssertEqual(ws.items.map(\.id), ["stray:stray.txt"])
    }

    func testCleanUpIsTheSafeSet() throws {
        let long = Date().addingTimeInterval(-40 * 86_400)
        let r = Resources.inventory(store: store, facts: facts(created: long))
        let clean = Set(Resources.cleanIDs(r.items))
        XCTAssertEqual(clean, ["cache:downloads", "base:f97ac66c1d54", "kernel:6.1-1", "kernel:9.9-custom", "image:claude-code@\(ccKey)",
                               "image:claude-code@\(ccOld)", "image:lab@\(labKey)", "leftover:claude-code-bake"])
        for never in ["template:tpl", "sandbox:a", "point:a/rp1", "screens:a", "boots:a", "logs", "metrics", "initfs", pinnedID, "stray:junk",
                      "outside:settings", "outside:keychain", "store"] {
            XCTAssertFalse(clean.contains(never), never)
        }
        // A sandbox created from the lab's disk within the window keeps it.
        let recent = Set(Resources.cleanIDs(Resources.inventory(store: store, facts: facts()).items))
        XCTAssertFalse(recent.contains("image:lab@\(labKey)"))
        let p = Resources.plan(store: store, facts: facts(), ids: [], clean: true)
        XCTAssertTrue(p.clean)
        XCTAssertEqual(Set(p.items.map(\.id)), recent)
        XCTAssertEqual(p.freedBytes, Resources.inventory(store: store, facts: facts()).cleanableBytes)
    }

    /// The host's ops: the account and a dry run are read-only (answered in-process with no host); a
    /// deletion needs the host; the ids and the kernel are checked before anything is read.
    func testTheHostOpsAndTheirReadOnlyRules() async throws {
        let ro = HostCore(store: store, readOnly: true, version: "test")
        await ro.load()
        let rep = await ro.handle(HostRequest(.resources))
        XCTAssertEqual(rep.ok, true, "\(String(describing: rep.error))")
        let report = try XCTUnwrap(rep.result).decode(ResourceReport.self)
        XCTAssertEqual(report.unattributedBytes, 0)
        XCTAssertEqual(report.totalBytes, try du(root))
        var dry = HostRequest(.resourcesRemove)
        dry.ids = ["logs", "sandbox:a"]
        dry.dryRun = true
        let dryAnswer = await ro.handle(dry)
        let plan = try XCTUnwrap(dryAnswer.result).decode(ResourcePlan.self)
        XCTAssertEqual(plan.items.map(\.id), ["logs"])
        XCTAssertEqual(plan.refused.map(\.id), ["sandbox:a"])
        XCTAssertTrue(plan.dryRun)
        var real = dry
        real.dryRun = nil
        let refused = await ro.handle(real)
        XCTAssertEqual(refused.error?.code, .unavailable, "a deletion needs the host")
        var clean = HostRequest(.resourcesClean)
        clean.dryRun = true
        let cleanAnswer = await ro.handle(clean)
        XCTAssertEqual(try XCTUnwrap(cleanAnswer.result).decode(ResourcePlan.self).clean, true)
        XCTAssertEqual(try du(root), report.totalBytes, "reading changes nothing")

        let core = HostCore(store: store, readOnly: false, version: "test", services: .forHost(environment: ["DOZ_TEST_CREDENTIALS": "memory"]))
        await core.load()
        var bad = HostRequest(.resourcesRemove)
        bad.ids = ["image:../x"]
        let e1 = await core.handle(bad)
        XCTAssertEqual(e1.error?.code, .invalid)
        let e2 = await core.handle(HostRequest(.resourcesRemove))
        XCTAssertEqual(e2.error?.code, .invalid, "which resources?")
        var k = HostRequest(.resourcesKernel)
        k.kernel = "/tmp/vmlinux"
        let e3 = await core.handle(k)
        XCTAssertEqual(e3.error?.code, .invalid)
        var real2 = HostRequest(.resourcesRemove)
        real2.ids = ["stray:stray.txt", "cache:downloads"]
        let realAnswer = await core.handle(real2)
        let done = try XCTUnwrap(realAnswer.result).decode(ResourcePlan.self)
        XCTAssertEqual(Set(done.deleted), ["stray:stray.txt", "cache:downloads"])
        XCTAssertFalse(done.dryRun)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("stray.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("content").path))
    }

    func testAPlanDeletesExactlyWhatItSaysAndFreesWhatItSaid() throws {
        let before = Resources.inventory(store: store, facts: facts())
        let ids = ["image:claude-code", "image:claude-code@\(ccOld)", "cache:downloads", "logs", "metrics", "point:a/rp1", "stray:stray.txt",
                   "screens:a", "boots:a", "kernel:6.1-1", "leftover:claude-code-bake"]
        let plan = Resources.plan(store: store, facts: facts(), ids: ids, clean: false)
        XCTAssertFalse(plan.items.contains { $0.id == "image:claude-code@\(ccOld)" }, "a part whose whole is selected goes with it")
        XCTAssertTrue(plan.refused.isEmpty, "\(plan.refused)")
        var metricsCleared = false
        let done = Resources.execute(plan, store: store) { metricsCleared = true }
        XCTAssertEqual(Set(done.deleted), Set(plan.items.map(\.id)))
        XCTAssertTrue(done.failed.isEmpty, "\(done.failed)")
        XCTAssertTrue(metricsCleared)
        let fm = FileManager.default
        for gone in ["images/claude-code", "content", "state.json", "sandboxes/a/restore-points/rp1", "stray.txt", "sandboxes/a/screens",
                     "sandboxes/a/boots", "kernels/vmlinux-6.1-1", "containers/claude-code-bake"] {
            XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(gone).path), gone)
        }
        for kept in ["golden/\(labKey).ext4", "sandboxes/a/rootfs.ext4", "images/bases/f97ac66c1d54/root.ext4", "images/custom/tpl/id1/root.ext4",
                     "kernels/\(pinned)", "initfs.ext4", "accounts.json", "junk/deep/file", "host.log"] {
            XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent(kept).path), kept)
        }
        XCTAssertEqual(try fm.attributesOfItem(atPath: root.appendingPathComponent("host.log").path)[.size] as? Int, 0, "a log is cleared, not removed")
        let after = Resources.inventory(store: store, facts: facts())
        XCTAssertEqual(after.unattributedBytes, 0)
        XCTAssertEqual(after.totalBytes, try du(root))
        // What it said it would free is what the volume got back (metrics are the closure's, so not counted here).
        let metricsBytes = before.items.first { $0.id == "metrics" }?.freedBytes ?? 0
        XCTAssertEqual(before.occupiedBytes - after.occupiedBytes, plan.freedBytes - metricsBytes)
    }
}
