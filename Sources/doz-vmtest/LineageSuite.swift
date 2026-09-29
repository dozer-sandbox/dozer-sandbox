import Containerization
import Darwin
import Foundation
@_spi(Testing) import DozerKit

// 587 — the image-lineage suite (`doz-vmtest lineage [part]`, `make test-vm-lineage`). One part
// per acceptance item of 587.01-PLAN.md, each printing its numbers:
//
//   bake        1  claude-code and pi bake on a WARM base in ≤ 20 s each; ≥ 250 MiB of the base
//                  shared by both images (DiskAccounting); each image's fstrim share (item 4)
//   discard     4  a 300 MiB file deleted inside a running sandbox leaves < 32 MiB of garbage
//   sync        5  a file written but not synced survives Hibernate → discard → cold boot
//   journal     2  root + state journaled; 15 × (Hibernate → discard → cold boot): no e2fsck,
//                  15/15 clean `e2fsck -fn`, median cold boot < 600 ms
//   nojournal   3  journalMiB nil: the 583 e2fsck path, 15/15 (the hardening discard test)
//   accounting  6  unique == PRIVATESIZE (±1 MiB) on every disk of the store; deleting a disk frees
//                  what it predicted (a quiet sparse-bundle volume, so the free-space delta is exact)
//   reclaim     7  a churned disk (online discard off): reclaim() → garbage < 5 % in < 1 s; the
//                  free list equals dumpe2fs's; identical content; clean e2fsck -fn
//   rederive    8  image blocks rewritten with identical bytes: rederive() raises sharing, cuts
//                  garbage, identical content; a failure part-way leaves the original disk
//   children    P2 deleting an image and its base leaves a sandbox cloned from it working
//
// Item 10 (a sandbox hibernated by v0.4.0 wakes under this build) was retired by 592: the product was
// renamed with no backward compatibility (owner ruling), so an older release's store is not expected
// to wake. The journal-less e2fsck path it also covered is `nojournal` (item 3).
//
// Item 9 (advice thresholds at / below / above) is the unit test DiskTests.test_advice*; the
// reclaim and rederive parts also check the advice on real disks.

nonisolated(unsafe) var lineageKeep: [Sandbox] = []
nonisolated(unsafe) var lineageVariantPi: ImageSpec?

func lineageSpec(_ name: String, imageSpec: ImageSpec? = AgentImages.pi) -> SandboxSpec {
    guard let imageSpec else {
        // The lab sandbox (its prepared disk is baked with `apk add`, so it keeps its NAT network).
        var s = makeSpec(name, share: storeRoot)
        s.shares = []
        return s
    }
    var s = agentSpec(name, imageSpec: imageSpec)
    s.network = .none                 // no NIC: new Sandbox objects never compete for a subnet
    s.subnet = nil
    s.memoryMiB = 1024
    return s
}

func mb(_ b: Int64) -> String { String(format: "%.1f MiB", Double(b) / 1_048_576) }
func mbD(_ b: Int64) -> Double { Double(b) / 1_048_576 }

/// A running VM's disk as the host really holds it: guest sync, host flush, allocation.
func settledAllocation(_ sb: Sandbox, _ disk: URL) async throws -> Int64 {
    _ = try await sb.exec(["sync"], privileged: true)
    let fd = open(disk.path, O_RDONLY)
    if fd >= 0 { fsync(fd); close(fd) }
    return ImageBaker.sizes(disk).allocated
}

func lineageFresh(_ spec: SandboxSpec) async throws -> Sandbox {
    let sb = try await freshSandbox(spec)
    lineageKeep.append(sb)
    return sb
}

/// Every file of the guest's own trees, hashed — "identical content" from inside.
func guestFingerprint(_ sb: Sandbox) async throws -> String {
    try await sb.exec(["sh", "-c", "find /usr /etc /root /home /opt -xdev -type f 2>/dev/null | sort | xargs -d '\\n' sha256sum 2>/dev/null | sha256sum"],
                      privileged: true, timeoutSeconds: 600).output.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Run `script` as root in a tool sandbox (Alpine + e2fsprogs + e2fsprogs-extra, for dumpe2fs) that
/// sees `dir` at /t — on the image FILE, never mounted (the 586 probe's method).
func diskTool(_ dir: URL, _ script: String) async throws -> ExecResult {
    var spec = makeSpec("lineage-tool", share: dir)
    spec.bakePackages = ["e2fsprogs", "e2fsprogs-extra"]
    spec.shares = [Share(hostPath: dir.path, guestPath: "/t")]
    spec.rootfsMiB = 512
    let t = try Sandbox(spec: spec)
    lineageKeep.append(t)
    try? await t.resetToImage()
    try await t.start()
    let r = try await t.exec(["sh", "-c", script], privileged: true, timeoutSeconds: 600)
    try await t.shutDown()
    return r
}

/// ext4's free list as `dumpe2fs` prints it, as merged byte ranges.
func dumpe2fsFree(_ sb: Sandbox, _ file: String) async throws -> [(Int64, Int64)] {
    let r = try await diskTool(sb.layout.sandboxDirectory, "dumpe2fs '/t/\(file)' 2>/dev/null | grep -E '^ *Free blocks: [0-9]' | sed 's/.*Free blocks: //' | tr ',' '\\n' | tr -d ' ' | grep -v '^$'")
    var ranges: [(Int64, Int64)] = []
    for l in r.output.split(separator: "\n") {
        let p = l.split(separator: "-").compactMap { Int64($0) }
        if p.count == 1 { ranges.append((p[0] * 4096, 4096)) } else if p.count == 2 { ranges.append((p[0] * 4096, (p[1] - p[0] + 1) * 4096)) }
    }
    return DiskAccounting.merge(ranges)
}

func median(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? -1 : s[s.count / 2] }

// MARK: 1 — bakes on a warm base

func lineageBake() async throws {
    print("vmtest[lineage]: 1 — claude-code and pi bake on a warm base")
    let pi = AgentImages.pi, cc = AgentImages.claudeCode
    let baker = ImageBaker(storeRoot: storeRoot)
    // Warm the base (not timed): flattened once per base key.
    if baker.cachedBase(pi.baseKey) == nil {
        let t = Date()
        let store = try ImageStore(path: storeRoot)
        let image = try await store.get(reference: pi.base, pull: true)
        _ = try await baker.ensureBase(pi, image: image)
        info(String(format: "warm-up: the node base flattened once in %.1f s", Date().timeIntervalSince(t)))
    }
    let base = try XCTUnwrapOrThrow(baker.cachedBase(pi.baseKey), "the node base")
    check(cc.baseKey == pi.baseKey, "claude-code and pi share one base key (\(pi.baseKey.prefix(12)))")
    var baked: [(ImageSpec, BakedImage)] = []
    for r in [cc, pi] {
        var v = r
        v.steps.append(BakeStep("lineage variant \(UUID().uuidString.prefix(8))", argv: ["true"], needsNetwork: false))
        let sb = try Sandbox(spec: lineageSpec("lineage-bake-\(r.name)", imageSpec: v))
        let t0 = Date()
        let img = try await bakeImage(sb, v)
        let s = Date().timeIntervalSince(t0)
        check(s <= 20, String(format: "%@ baked on the warm base in %.1f s (≤ 20 s; 586 fresh flatten ~50 s) — %@", r.name, s,
                              img.manifest.timings.map { "\($0.step) \(Int($0.milliseconds)) ms" }.joined(separator: " · ")))
        check(img.manifest.parent == base.key, "\(r.name)'s manifest names its parent, the base \(base.key.prefix(12))")
        let trimmed = img.manifest.trimmedBytes ?? 0
        check(trimmed > 0, "item 4: \(r.name) is smaller by fstrim's share — \(mb(img.manifest.allocatedBytes + trimmed)) → \(mb(img.manifest.allocatedBytes)) (−\(mb(trimmed)), \(String(format: "%.0f", Double(trimmed) / Double(img.manifest.allocatedBytes + trimmed) * 100)) %)")
        baked.append((v, img))
        if r.name == "pi" { lineageVariantPi = v }
    }
    let rep = try DiskAccounting.measure(store: storeRoot)
    for (v, img) in baked {
        let d = rep.disk(img.root)
        check((d?.sharedWithParentBytes ?? 0) >= 250 << 20,
              "DiskAccounting: \(v.name) shares \(mb(d?.sharedWithParentBytes ?? 0)) with the base (≥ 250 MiB); unique \(mb(d?.uniqueBytes ?? 0)) of \(mb(d?.allocatedBytes ?? 0))")
    }
    // Bytes of the base that BOTH images still reference (the same physical blocks in all three).
    func phys(_ u: URL) throws -> [(Int64, Int64)] { DiskAccounting.merge(try DiskAccounting.extents(of: u).map { ($0.physical, $0.length) }) }
    let all3 = DiskAccounting.total(DiskAccounting.intersect(DiskAccounting.intersect(try phys(base.root), try phys(baked[0].1.root)), try phys(baked[1].1.root)))
    check(all3 >= 250 << 20, "\(mb(all3)) of the base (\(mb(ImageBaker.sizes(base.root).allocated))) is shared by both images at once (≥ 250 MiB)")
    info("each further image on this base costs its own unique bytes only — ~\(mb(all3)) saved per image vs a fresh flatten")
}

// MARK: 4 — online discard

func lineageDiscard() async throws {
    print("vmtest[lineage]: 4 — online discard reaches the host file")
    let sb = try await lineageFresh(lineageSpec("lineage-discard"))
    try await sb.start()
    let mounts = try await sb.exec(["sh", "-c", "grep -E ' / | /state ' /proc/mounts"]).output
    info("mounts: " + mounts.replacingOccurrences(of: "\n", with: " | "))
    check(mounts.split(separator: "\n").filter { $0.contains("discard") }.count >= 2, "the root and state disks are mounted with discard")
    let root = sb.layout.rootfs
    let a0 = try await settledAllocation(sb, root)
    _ = try await sb.exec(["sh", "-c", "head -c 300M /dev/urandom > /root/big.bin && sync"], privileged: true, timeoutSeconds: 300)
    let a1 = try await settledAllocation(sb, root)
    _ = try await sb.exec(["sh", "-c", "rm -f /root/big.bin && sync && sleep 1 && sync"], privileged: true)
    let a2 = try await settledAllocation(sb, root)
    check(a1 - a0 >= 280 << 20, "writing 300 MiB grew the host file by \(mb(a1 - a0))")
    check(a2 - a0 < 32 << 20, "after deleting it, the host file holds \(mb(a2 - a0)) more than before (< 32 MiB; 586 without discard: the full 300)")
    try await sb.shutDown()
    let g = try DiskAccounting.garbage(of: root)
    check(g < 32 << 20, "stopped: the root disk's garbage is \(mb(g)) (< 32 MiB) of \(mb(ImageBaker.sizes(root).allocated)) allocated")
    try await sb.delete()
}

// MARK: 5 — sync before Hibernate

func lineageSync() async throws {
    print("vmtest[lineage]: 5 — a file written (not synced) right before hibernating survives a discard")
    for (label, spec) in [("journaled pi", lineageSpec("lineage-sync")), ("journal-less lab", { var s = lineageSpec("lineage-sync-nj", imageSpec: nil); s.journalMiB = nil; return s }())] {
        var sb = try await lineageFresh(spec)
        try await sb.start()
        var kept = 0
        let n = 3
        for i in 1...n {
            let token = UUID().uuidString
            _ = try await sb.exec(["sh", "-c", "echo \(token) > /root/unsynced-\(i).txt"])     // no sync
            try await sb.hibernate()
            Sandbox.discardRestorableState(for: spec)
            lineageKeep.append(sb)
            sb = try Sandbox(spec: spec)
            try await sb.start()
            let got = try await sb.exec(["sh", "-c", "cat /root/unsynced-\(i).txt 2>/dev/null || echo MISSING"]).output
            if got.contains(token) { kept += 1 } else { info("\(label) cycle \(i): \(got)") }
        }
        check(kept == n, "\(label): \(kept)/\(n) files written without sync survived Hibernate → discard → cold boot (586: 0/40 without the sync)")
        try await sb.shutDown()
        try await sb.delete()
    }
}

// MARK: 2 — the journal, on by default

func lineageJournal() async throws {
    let cycles = envInt("LINEAGE_CYCLES", 15)
    print("vmtest[lineage]: 2 — journaled root + state: \(cycles) × Hibernate → discard → cold boot")
    let spec = lineageSpec("lineage-journal")
    var sb = try await lineageFresh(spec)
    try await sb.start()
    let l = sb.layout
    let rj = (try? EXT4Inspector(l.rootfs))?.hasJournal == true, sj = (try? EXT4Inspector(l.stateDisk))?.hasJournal == true
    check(rj && sj, "a new sandbox's root and state disks are journaled (root \(rj), state \(sj); 16 MiB by default)")
    let p = PersistedSandbox.read(from: l.persistedState)
    check(p?.rootJournaled == true && p?.stateJournaled == true, "the record says so too (rootJournaled / stateJournaled)")
    var boots: [Double] = [], clean = 0, fscks = 0, failed = 0
    for i in 1...cycles {
        _ = try await sb.exec(["sh", "-c", "mkdir -p /root/d\(i) && for n in $(seq 1 40); do echo \(i)-$n > /root/d\(i)/f$n; done; head -c 32M /dev/urandom > /home/agent/.pi/agent/blob\(i); echo ok"], privileged: true)
        try await sb.openSession("s\(i)", argv: ["bash", "-l"], size: .standard)
        try await sb.hibernate()
        Sandbox.discardRestorableState(for: spec)
        let marked = PersistedSandbox.read(from: l.persistedState)?.fsckOnNextBoot == true
        lineageKeep.append(sb)
        sb = try Sandbox(spec: spec)
        let notes = NoteLog(sb)
        let t0 = Date()
        var err: String?
        do { try await sb.start() } catch { err = "\(error)" }
        let ms = Date().timeIntervalSince(t0) * 1000
        notes.stop()
        let fsck = notes.lines.contains { $0.hasPrefix("fsck ") }
        if fsck || marked { fscks += 1 }
        let bad = bootLogExt4Errors(sb)
        let replayed = ((try? String(contentsOf: sb.bootLogURL, encoding: .utf8)) ?? "").contains("recovery complete")
        if err != nil || !bad.isEmpty { failed += 1 }
        boots.append(ms)
        try? await sb.shutDown()
        let checks = try await sb.checkDisks()
        let ok = checks.count == 2 && checks.allSatisfy(\.clean)
        if ok { clean += 1 } else { info("cycle \(i) e2fsck -fn: " + checks.map { "\($0.disk) exit \($0.exitCode): \($0.report.split(separator: "\n").suffix(3).joined(separator: " · "))" }.joined(separator: " | ")) }
        info(String(format: "cycle %d: cold boot %@ in %.0f ms · e2fsck mark %@ · e2fsck ran %@ · journal replay %@ · ext4 errors %d · e2fsck -fn %@",
                    i, err == nil ? "ok" : "FAILED \(err!)", ms, marked ? "set" : "none", fsck ? "yes" : "no", replayed ? "yes" : "no", bad.count, ok ? "clean" : "NOT clean"))
        if i < cycles { try await sb.start() }
    }
    check(failed == 0, "\(cycles) discards → cold boots, \(failed) failures")
    check(fscks == 0, "no cold boot needed e2fsck (\(fscks)/\(cycles) did) — journal replay instead")
    check(clean == cycles, "e2fsck -fn clean on root and state after \(clean)/\(cycles) cycles")
    let med = median(boots)
    check(med < 600, String(format: "median cold boot after a discard %.0f ms (< 600; 583's e2fsck path ~1030) — all: %@", med,
                            boots.map { String(format: "%.0f", $0) }.joined(separator: " ")))
    try await sb.delete()
}

// MARK: 6 — accounting

func lineageAccounting() async throws {
    print("vmtest[lineage]: 6 — DiskAccounting vs APFS")
    // A store with every kind of disk: a sandbox (root + state) that has worked, and a restore point.
    let sb = try await lineageFresh(lineageSpec("lineage-acct"))
    try await sb.start()
    _ = try await sb.exec(["sh", "-c", "head -c 100M /dev/urandom > /root/work.bin && head -c 20M /dev/urandom > /home/agent/.pi/agent/s.bin && sync"], privileged: true)
    try await sb.shutDown()
    _ = try await sb.takeRestorePoint(name: "acct")
    let rep = try DiskAccounting.measure(store: storeRoot)
    try await sb.delete()
    let kinds = Set(rep.disks.map(\.kind))
    check([.base, .image, .preparedDisk, .sandboxRoot, .sandboxState, .restorePointRoot].allSatisfy(kinds.contains),
          "the store has every kind of disk: \(kinds.map(\.rawValue).sorted())")
    if let r = rep.disks.first(where: { $0.name == "sandbox lineage-acct" }) {
        // Its own 100 MiB is shared with its restore point (a clone), so neither holds it uniquely.
        let own = r.allocatedBytes - (r.sharedWithParentBytes ?? 0)
        check(r.parent != nil && (r.sharedWithParentBytes ?? 0) > 300 << 20 && own >= 100 << 20 && r.uniqueBytes < 1 << 20,
              "the sandbox's root shares \(mb(r.sharedWithParentBytes ?? 0)) with its image; its own \(mb(own)) is shared with its restore point (unique \(mb(r.uniqueBytes)))")
    }
    var worst: Int64 = 0, compared = 0, outside = 0
    for d in rep.disks {
        let priv = d.privateBytes ?? -1
        // DiskAccounting is per STORE; APFS's private size is per VOLUME. Other suites' scratch
        // stores (test-cli, test-vm-claude) clone their images from this store, so such a file is
        // fully shared outside it: APFS says 0 private while the store-scoped answer is "unique".
        // Only whole files that this suite does not create can be in that state; they are named, not compared.
        let sharedOutside = priv == 0 && d.uniqueBytes > 0
            && ![.sandboxRoot, .sandboxState, .restorePointRoot].contains(d.kind)
        if sharedOutside { outside += 1; info("  \(d.name): fully shared with a file outside this store (another store's clone) — not compared") }
        let diff = priv < 0 || sharedOutside ? 0 : abs(d.uniqueBytes - priv)
        if priv >= 0 && !sharedOutside { compared += 1; worst = max(worst, diff) }
        info(String(format: "%-44@ %-17@ alloc %8.1f  unique %8.1f  private %8.1f  shared-w-parent %8@  garbage %8@  %5.0f ext/GiB",
                    String(d.name.prefix(44)), d.kind.rawValue, mbD(d.allocatedBytes), mbD(d.uniqueBytes), mbD(priv),
                    d.sharedWithParentBytes.map { String(format: "%.1f", mbD($0)) } ?? "-",
                    d.garbageBytes.map { String(format: "%.1f", mbD($0)) } ?? "-", d.extentsPerGiB))
        if diff > 1 << 20 { info("  ↑ differs by \(mb(diff))") }
    }
    check(compared + outside == rep.disks.count && compared > 0 && worst <= 1 << 20,
          "unique bytes match APFS PRIVATESIZE within 1 MiB on all \(compared) store-local disks (worst \(mb(worst)); \(outside) shared with another store, not compared)")
    let per10 = rep.milliseconds / Double(max(rep.disks.count, 1)) * 10
    check(per10 < 100, String(format: "measured %d disks (%.0f MiB allocated, union %.0f MiB) in %.1f ms — %.1f ms per 10 disks (< 100)",
                              rep.disks.count, mbD(rep.disks.reduce(0) { $0 + $1.allocatedBytes }), mbD(rep.unionBytes), rep.milliseconds, per10))

    // Deleting frees what was predicted: a quiet APFS volume (a sparse bundle nothing else writes),
    // so the free-space delta is the deletion's alone.
    let bundle = storeRoot.deletingLastPathComponent().appendingPathComponent("doz-lineage-vol-\(getpid()).sparsebundle")
    let mount = storeRoot.deletingLastPathComponent().appendingPathComponent("doz-lineage-vol-\(getpid())")
    try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    func run(_ argv: [String]) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = argv
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }
    let c = run(["hdiutil", "create", "-quiet", "-size", "16g", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-volname", "dozlin", bundle.path])
    let a = c.0 == 0 ? run(["hdiutil", "attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, bundle.path]) : c
    guard a.0 == 0 else { check(false, "a quiet volume for the deletion check (hdiutil: \(a.1))"); return }
    defer { _ = run(["hdiutil", "detach", "-quiet", "-force", mount.path]); try? FileManager.default.removeItem(at: bundle); try? FileManager.default.removeItem(at: mount) }
    func free() async -> Int64 {
        var last: Int64 = -1
        for _ in 0..<30 {
            Darwin.sync()
            var s = statfs()
            let v = statfs(mount.path, &s) == 0 ? Int64(s.f_bavail) * Int64(s.f_bsize) : -1
            if v == last { return v }
            last = v
            try? await Task.sleep(for: .milliseconds(700))
        }
        return last
    }
    // A mini store: an image (a real copy of the pi image), a child with 300 MiB rewritten, a child
    // with one block rewritten, a plain clone.
    guard let piImage = ImageBaker(storeRoot: storeRoot).all(AgentImages.pi).first?.root else { check(false, "the pi image is in the store"); return }
    let img = mount.appendingPathComponent("image.ext4"), heavy = mount.appendingPathComponent("heavy.ext4")
    let light = mount.appendingPathComponent("light.ext4"), plain = mount.appendingPathComponent("plain.ext4")
    // A real (non-clone, hole-preserving) copy: another volume.
    guard copyfile(piImage.path, img.path, nil, copyfile_flags_t(COPYFILE_DATA) | copyfile_flags_t(COPYFILE_DATA_SPARSE)) == 0 else {
        check(false, "copy the image to the quiet volume: \(String(cString: strerror(errno)))"); return
    }
    chmod(img.path, 0o644)
    for u in [heavy, light, plain] { _ = clonefile(img.path, u.path, 0) }
    func overwrite(_ u: URL, at off: UInt64, _ n: Int) throws {
        var d = Data(count: n); d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, n) }
        let h = try FileHandle(forWritingTo: u); try h.seek(toOffset: off); try h.write(contentsOf: d); try h.synchronize(); try h.close()
    }
    try overwrite(heavy, at: 64 << 20, 300 << 20)
    try overwrite(light, at: 128 << 20, 4096)
    var files = [img, heavy, light, plain]
    var worstDelta: Int64 = 0
    for victim in [heavy, light, plain, img] {
        let v = try DiskAccounting.share(files)
        let i = files.firstIndex(of: victim)!
        let predicted = v.unique[i]
        let f0 = await free()
        try FileManager.default.removeItem(at: victim)
        let f1 = await free()
        let freed = f1 - f0
        worstDelta = max(worstDelta, abs(freed - predicted))
        info("deleted \(victim.lastPathComponent): predicted \(mb(predicted)), the volume gained \(mb(freed))")
        files.remove(at: i)
    }
    check(worstDelta <= 1 << 20, "deleting each disk freed what DiskAccounting predicted, within 1 MiB (worst \(mb(worstDelta)))")
}

// MARK: 7 — reclaim

func lineageReclaim() async throws {
    print("vmtest[lineage]: 7 — reclaim() on a churned disk")
    let sb = try await lineageFresh(lineageSpec("lineage-reclaim"))
    try await sb.start()
    // Churn with online discard OFF (as a pre-587 sandbox, or a remount): the host keeps what was deleted.
    _ = try await sb.exec(["sh", "-c", "mount -o remount,nodiscard / && head -c 800M /dev/urandom > /root/churn.bin && head -c 5M /dev/urandom > /root/keep.bin && sync && rm -f /root/churn.bin && sync"],
                          privileged: true, timeoutSeconds: 600)
    let before = try await guestFingerprint(sb)
    try await sb.shutDown()
    let root = sb.layout.rootfs
    for file in ["rootfs.ext4", "state.ext4"] {
        let mine = try EXT4Inspector(sb.layout.sandboxDirectory.appendingPathComponent(file)).freeRanges()
        let theirs = try await dumpe2fsFree(sb, file)
        let same = mine.count == theirs.count && zip(mine, theirs).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        check(same, "\(file): EXT4Inspector's free list equals dumpe2fs's (\(mine.count) ranges, \(mb(DiskAccounting.total(mine))) free; dumpe2fs \(theirs.count) ranges, \(mb(DiskAccounting.total(theirs))))")
        if !same {
            let onlyMine = DiskAccounting.subtract(mine, theirs), onlyTheirs = DiskAccounting.subtract(theirs, mine)
            info("only EXT4Inspector: \(mb(DiskAccounting.total(onlyMine))) \(onlyMine.prefix(6).map { "\($0.0 / 4096)+\($0.1 / 4096)" }) · only dumpe2fs: \(mb(DiskAccounting.total(onlyTheirs))) \(onlyTheirs.prefix(6).map { "\($0.0 / 4096)+\($0.1 / 4096)" })")
        }
    }
    let advice = try await sb.maintenanceAdvice()
    info("advice: " + advice.reasons.joined(separator: "; "))
    check(advice.actions.contains(.reclaim), "advice on the churned disk: \(advice.actions.map(\.rawValue)) — garbage \(mb(advice.garbageBytes)) of \(mb(advice.allocatedBytes))")
    let t0 = Date()
    let r = try await sb.reclaim()
    let s = Date().timeIntervalSince(t0)
    for x in r { info("\(x.disk): \(mb(x.allocatedBefore)) → \(mb(x.allocatedAfter)) allocated, garbage \(mb(x.garbageBefore)) → \(mb(x.garbageAfter)), \(x.punchedRanges) punches, \(String(format: "%.0f", x.milliseconds)) ms") }
    let rootR = r.first { $0.disk == "rootfs.ext4" }!
    let frac = Double(rootR.garbageAfter) / Double(rootR.allocatedAfter)
    check(rootR.garbageBefore >= 700 << 20 && frac < 0.05 && s < 1,
          String(format: "reclaim(): garbage %@ → %@ (%.2f %% of %@; < 5 %%) in %.0f ms (< 1 s)", mb(rootR.garbageBefore), mb(rootR.garbageAfter), frac * 100, mb(rootR.allocatedAfter), s * 1000))
    let checks = try await sb.checkDisks()
    check(checks.allSatisfy(\.clean), "e2fsck -fn clean after the reclaim (" + checks.map { "\($0.disk) exit \($0.exitCode)" }.joined(separator: ", ") + ")")
    try await sb.start()
    let after = try await guestFingerprint(sb)
    check(!before.isEmpty && after == before, "the sandbox boots with identical content (fingerprint \(after.prefix(16)))")
    try await sb.shutDown()
    try await sb.delete()
}

// MARK: 8 — rederive

func lineageRederive() async throws {
    print("vmtest[lineage]: 8 — rederive() on a disk whose image blocks were rewritten with identical bytes")
    let spec = lineageSpec("lineage-rederive")
    let sb = try await lineageFresh(spec)
    try await sb.start()
    // Identical in-place rewrites of the image's own files (dd conv=notrunc: same bytes, same
    // blocks, new physical copies on the host), and some garbage with online discard off.
    let rw = try await sb.exec(["sh", "-c", """
        n=0; for f in $(find /usr -xdev -type f -size +256k 2>/dev/null | head -n 400); do
          dd if="$f" of="$f" bs=1M conv=notrunc status=none 2>/dev/null && n=$((n + $(stat -c %s "$f")))
          [ $n -gt 157286400 ] && break
        done; echo rewrote=$n
        mount -o remount,nodiscard / && head -c 200M /dev/urandom > /root/g.bin && sync && rm -f /root/g.bin && sync
        """], privileged: true, timeoutSeconds: 900)
    info(rw.output.trimmingCharacters(in: .whitespacesAndNewlines) + " " + rw.errorOutput.suffix(200))
    let before = try await guestFingerprint(sb)
    try await sb.shutDown()
    let advice = try await sb.maintenanceAdvice()
    info("advice: " + advice.reasons.joined(separator: "; "))
    check(advice.actions.contains(.rederive), "advice: \(advice.actions.map(\.rawValue)) — lost identical sharing \(mb(advice.lostSharingBytes ?? 0)) of a \(mb(advice.imageBytes ?? 0)) image")

    // A failure part-way leaves the original disk in place.
    let root = sb.layout.rootfs
    let orig = sb.layout.sandboxDirectory.appendingPathComponent("orig-copy.ext4")
    try? FileManager.default.removeItem(at: orig)
    _ = clonefile(root.path, orig.path, 0)
    let extBefore = try DiskAccounting.extents(of: root)
    for point in ["after-write", "before-swap"] {
        MaintenanceFaults.failAt = point
        var threw = false
        do { _ = try await sb.rederive() } catch { threw = true }
        MaintenanceFaults.failAt = nil
        let untouched = try DiskAccounting.extents(of: root) == extBefore
            && !FileManager.default.fileExists(atPath: sb.layout.sandboxDirectory.appendingPathComponent("rootfs.rederive.ext4").path)
        check(threw && untouched, "a failure at \(point) left the original disk exactly in place (same extents, no partial disk)")
    }

    let r = try await sb.rederive()
    info(String(format: "rederive: %.0f ms · wrote %@ · zeroed %@ · identical blocks shared again %@ · %@", r.milliseconds, mb(r.writtenBytes), mb(r.zeroedBytes), mb(r.identicalBytes), r.fsckReport))
    check(r.sharedWithImageAfter > r.sharedWithImageBefore,
          "shared with the image \(mb(r.sharedWithImageBefore)) → \(mb(r.sharedWithImageAfter)) (+\(mb(r.sharedWithImageAfter - r.sharedWithImageBefore)))")
    check(r.garbageAfter < r.garbageBefore, "garbage \(mb(r.garbageBefore)) → \(mb(r.garbageAfter)); allocated \(mb(r.allocatedBefore)) → \(mb(r.allocatedAfter))")
    let i = try EXT4Inspector(root)
    check(try DiskAccounting.identical(orig, root, over: DiskAccounting.complement(try i.freeRanges(), size: i.capacityBytes)),
          "every block ext4 uses reads the same as before the re-derive")
    let checks = try await sb.checkDisks()
    check(checks.allSatisfy(\.clean), "e2fsck -fn clean after the re-derive")
    try await sb.start()
    let after = try await guestFingerprint(sb)
    check(!before.isEmpty && after == before, "the sandbox boots with identical content (fingerprint \(after.prefix(16)))")
    try await sb.shutDown()
    try? FileManager.default.removeItem(at: orig)
    let again = try await sb.maintenanceAdvice()
    check(!again.actions.contains(.rederive), "advice afterwards: \(again.actions.map(\.rawValue)) (lost identical sharing \(mb(again.lostSharingBytes ?? 0)))")
    try await sb.delete()
}

// MARK: P2 — children never depend on their parent's file

func lineageChildren() async throws {
    print("vmtest[lineage]: P2 — deleting an image and its base leaves a sandbox cloned from it working")
    var v = lineageVariantPi ?? AgentImages.pi
    if lineageVariantPi == nil { v.steps.append(BakeStep("lineage variant \(UUID().uuidString.prefix(8))", argv: ["true"], needsNetwork: false)) }
    let spec = lineageSpec("lineage-child", imageSpec: v)
    let sb = try await lineageFresh(spec)
    let img = try await bakeImage(sb, v)
    try await sb.start()
    let token = UUID().uuidString
    let w = try await sb.exec(["sh", "-c", "echo \(token) > /root/child.txt && sync && cat /root/child.txt"], privileged: true)
    check(w.output.contains(token), "wrote a marker into the sandbox (exit \(w.exitCode) \(w.errorOutput.prefix(120)))")
    try await sb.shutDown()
    let baker = ImageBaker(storeRoot: storeRoot)
    try FileManager.default.removeItem(at: img.root.deletingLastPathComponent())
    try baker.deleteBase(v.baseKey)
    check(baker.cachedBase(v.baseKey) == nil && !FileManager.default.fileExists(atPath: img.root.path), "deleted the image and its base")
    let sb2 = try Sandbox(spec: spec)
    lineageKeep.append(sb2)
    let log = logEvents(sb2)
    try await sb2.start()
    log.cancel()
    let got = try await sb2.exec(["sh", "-c", "cat /root/child.txt 2>&1; pi --version"], environment: v.sessionEnvironment, privileged: true).output
    check(got.contains(token) && got.contains("0.84.1"), "the sandbox still cold-boots with its data and its agent (\(got.split(separator: "\n").last ?? ""))")
    try await sb2.shutDown()
    let checks = try await sb2.checkDisks()
    check(checks.allSatisfy(\.clean), "and its disks are clean")
    try await sb2.delete()
}

// MARK: dispatch

func lineageSuite(_ part: String?) async throws {
    switch part {
    case "bake": try await lineageBake()
    case "discard": try await lineageDiscard()
    case "sync": try await lineageSync()
    case "journal": try await lineageJournal()
    case "nojournal": try await discardSuite()
    case "accounting": try await lineageAccounting()
    case "reclaim": try await lineageReclaim()
    case "rederive": try await lineageRederive()
    case "children": try await lineageChildren()
    default:
        try await lineageBake()
        try await lineageDiscard()
        try await lineageSync()
        try await lineageJournal()
        print("vmtest[lineage]: 3 — journalMiB nil: the 583 e2fsck path")
        try await discardSuite()
        try await lineageReclaim()
        try await lineageRederive()
        try await lineageAccounting()
        try await lineageChildren()
    }
}

struct Missing: Error, CustomStringConvertible { let description: String }
func XCTUnwrapOrThrow<T>(_ v: T?, _ what: String) throws -> T {
    guard let v else { throw Missing(description: "missing: \(what)") }
    return v
}
