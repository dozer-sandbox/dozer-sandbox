import Darwin
import Foundation
import DozerKit

// 583 — the hardening suite (`doz-vmtest hardening`, or one of its parts by name). Each part is
// the regression test for a hazard the 582 scaling probe found:
//
//   discard     582 §8: `discardRestorableState` + `start()` cold-booted a root disk its hibernated
//               VM never unmounted (ext4, no journal) — 12 of 15 boots failed. N cycles of
//               start → write → Hibernate → discard (a NEW Sandbox object, as a new process)
//               → start, each boot checked for ext4 errors. Must be 0 failures.
//   leak        582 §7: every VM instance the host made kept an 8-thread NIO event-loop group
//               after Hibernate (~5 threads, ~6 kqueue fds, ~1 MiB per cycle, never returned).
//               N Hibernate → Wake cycles, alternating a same-object wake with a wake through a
//               NEW Sandbox object (a new VM instance — the path that leaked); the host's thread,
//               fd and footprint counts must stay flat.
//   concurrent  582 §8: 2 of 31 concurrent wakes threw "The channel was closed" although the
//               sandbox came up. N sandboxes hibernated together and woken together, same-object
//               and new-object rounds; 0 errors, and every one answers an exec afterwards.
//
// Inputs: the suite's usual --store / $DOZ_SUBNET; HARDEN_CYCLES (discard, default 15),
// HARDEN_LEAK_CYCLES (default 200), HARDEN_CONCURRENT (default 16), HARDEN_ROUNDS (default 3).

func envInt(_ k: String, _ d: Int) -> Int { ProcessInfo.processInfo.environment[k].flatMap(Int.init) ?? d }

// MARK: host measurement (the 580.06 / 582 method: this process's own counters)

func hostFootprintMiB(_ p: pid_t = getpid()) -> Double {
    var ri = rusage_info_v4()
    let r = withUnsafeMutablePointer(to: &ri) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(p, RUSAGE_INFO_V4, $0) }
    }
    return r == 0 ? Double(ri.ri_phys_footprint) / 1_048_576 : -1
}

func hostThreads(_ p: pid_t = getpid()) -> Int {
    var ti = proc_taskinfo()
    return proc_pidinfo(p, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 ? Int(ti.pti_threadnum) : -1
}

func hostFDs(_ p: pid_t = getpid()) -> Int {
    let size = proc_pidinfo(p, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return -1 }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 16)
    return Int(proc_pidinfo(p, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))) / MemoryLayout<proc_fdinfo>.stride
}

/// Sandboxes a part created but may not drop: a hibernated `Sandbox` object still owns the
/// package's objects for its VM (as a host's registry would keep it).
nonisolated(unsafe) var hardeningKeep: [Sandbox] = []

func hardenSpec(_ name: String, memoryMiB: UInt64 = 512) throws -> SandboxSpec {
    let share = try prepareShare(name)
    var s = makeSpec(name, share: share)
    s.memoryMiB = memoryMiB
    return s
}

/// A fresh sandbox of this name: whatever an earlier run left is shut down and deleted.
func freshSandbox(_ spec: SandboxSpec) async throws -> Sandbox {
    let old = try Sandbox(spec: spec)
    if Sandbox.restorableState(for: spec) != nil { Sandbox.discardRestorableState(for: spec) }
    try? await old.delete()
    hardeningKeep.append(old)
    return try Sandbox(spec: spec)
}

func bootLogExt4Errors(_ sb: Sandbox) -> [String] {
    let log = (try? String(contentsOf: sb.bootLogURL, encoding: .utf8)) ?? ""
    return log.split(separator: "\n").filter { $0.contains("EXT4-fs error") || $0.contains("I/O error") }.map { String($0.suffix(160)) }
}

// MARK: discard → cold boot (item 1)

func discardSuite() async throws {
    let cycles = envInt("HARDEN_CYCLES", 15)
    // 587: the journal-less path — the one that needs e2fsck (a journaled disk is replayed by the
    // kernel instead; `lineage journal` tests that one).
    var spec = try hardenSpec("harden-discard")
    spec.journalMiB = nil
    var sb = try await freshSandbox(spec)
    print("vmtest[hardening]: discard → cold boot × \(cycles)")
    try await sb.start()
    var failed = 0, fscks = 0
    for i in 1...cycles {
        // Dirty the disk the way a session does: create files, leave them in the page cache.
        let w = try await sb.exec(["sh", "-c", "mkdir -p /root/d\(i) && for n in $(seq 1 40); do echo \(i)-$n > /root/d\(i)/f$n; done; echo ok"])
        if !w.output.contains("ok") { info("cycle \(i): write failed \(w.errorOutput)") }
        try await sb.openSession("s\(i)", argv: ["bash", "-l"], size: .standard)
        try await sb.hibernate()
        // What a host does when a wake failed or the user chose to start fresh: throw the
        // snapshot away (as a new process would) and cold-boot the kept disk.
        Sandbox.discardRestorableState(for: spec)
        hardeningKeep.append(sb)
        sb = try Sandbox(spec: spec)
        let notes = NoteLog(sb)
        let t0 = Date()
        var err: String?
        do { try await sb.start() } catch { err = "\(error)" }
        let ms = Date().timeIntervalSince(t0) * 1000
        let bad = bootLogExt4Errors(sb)
        var dmesg = "-"
        if err == nil {
            dmesg = (try? await sb.exec(["sh", "-c", "dmesg | grep -c 'EXT4-fs error' || true"], timeoutSeconds: 15))?
                .output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        }
        let fsck = notes.lines.contains { $0.hasPrefix("fsck rootfs.ext4") }
        if fsck { fscks += 1 }
        notes.stop()
        let ok = err == nil && bad.isEmpty && dmesg == "0"
        if !ok { failed += 1 }
        info(String(format: "cycle %d: start %@ in %.0f ms · e2fsck ran %@ · boot-log ext4 errors %d · dmesg ext4 errors %@",
                    i, err == nil ? "ok" : "FAILED \(err!)", ms, fsck ? "yes" : "no", bad.count, dmesg))
        if !ok, let first = bad.first { info("  \(first)") }
        if err != nil {
            // Leave the next cycle a sandbox that can boot: reset to the image.
            try? await sb.shutDown()
            try? await sb.resetToImage()
            try await sb.start()
        }
    }
    check(failed == 0, "discard → cold boot × \(cycles): \(failed) failures (e2fsck ran on \(fscks))")
    check(fscks == cycles, "every cold boot after a discard ran e2fsck first (\(fscks)/\(cycles))")
    try? await sb.shutDown()
    try? await sb.delete()
}

/// Collects a sandbox's notes (the suite checks for the e2fsck report).
final class NoteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private var task: Task<Void, Never>?
    init(_ sb: Sandbox) {
        let stream = sb.events()
        task = Task.detached { [weak self] in
            for await e in stream { if case .note(let s) = e { self?.add(s) } }
        }
    }
    private func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return items }
    func stop() { task?.cancel() }
}

// MARK: Hibernate → Wake cycles: threads, fds, footprint (item 2)

struct HostSample: CustomStringConvertible {
    let threads: Int, fds: Int, footprintMiB: Double
    static func now() -> HostSample { HostSample(threads: hostThreads(), fds: hostFDs(), footprintMiB: hostFootprintMiB()) }
    var description: String { String(format: "threads %d · fds %d · footprint %.1f MiB", threads, fds, footprintMiB) }
}

func leakSuite() async throws {
    // A: what a long-lived host does — one Sandbox object per sandbox, cycled.
    // B: a NEW Sandbox object (a new VM instance — the path that stranded an event-loop group) every
    //    cycle; the old object is kept, as a host registry would keep it (dropping a hibernated one
    //    is not supported), so each still holds its VM's boot-log file: +1 fd per object, expected.
    try await leakCycles("A same object", cycles: envInt("HARDEN_LEAK_CYCLES", 200), newObjects: false)
    try await leakCycles("B new object", cycles: envInt("HARDEN_LEAK_NEW_CYCLES", 60), newObjects: true)
}

func leakCycles(_ label: String, cycles: Int, newObjects: Bool) async throws {
    // No NIC: a new Sandbox object must not fight the old one for a pinned vmnet subnet.
    var spec = try hardenSpec("harden-leak")
    spec.network = .none
    var sb = try await freshSandbox(spec)
    print("vmtest[hardening]: leak \(label): \(cycles) Hibernate → Wake cycles")
    try await sb.start()
    try await sb.openSession("tick", argv: ["bash", "/work/tick.sh"], size: .standard)
    let pid = try await sb.sessions().first { $0.name == "tick" }?.pid
    try await sb.hibernate()
    let start = HostSample.now()
    info("before the cycles: \(start)")
    let warmup = min(20, cycles / 2)
    var base = start, errors = 0, objects = 0
    var wakeMs: [Double] = []
    for i in 1...cycles {
        if newObjects {
            hardeningKeep.append(sb)
            sb = try Sandbox(spec: spec)
            if i > warmup { objects += 1 }
        }
        let t0 = Date()
        do {
            try await sb.wake()
            wakeMs.append(Date().timeIntervalSince(t0) * 1000)
            try await sb.hibernate()
        } catch {
            errors += 1
            info("cycle \(i): \(error)")
            if await sb.phase != .hibernated { break }
        }
        if i == warmup { try? await Task.sleep(for: .seconds(1)); base = HostSample.now(); info("after \(i) cycles (baseline): \(base)") }
        if i % 50 == 0 { info("after \(i) cycles: \(HostSample.now())") }
    }
    try? await Task.sleep(for: .seconds(2))
    let end = HostSample.now()
    let n = cycles - warmup
    info("after \(cycles) cycles: \(end)")
    info(String(format: "wake p50 %.0f ms · max %.0f ms", wakeMs.sorted()[wakeMs.count / 2], wakeMs.max() ?? 0))
    check(errors == 0, "leak \(label): \(cycles) Hibernate → Wake cycles, \(errors) errors")
    check(end.threads - base.threads <= 4, "leak \(label): threads flat over the last \(n) cycles: \(base.threads) → \(end.threads) (from \(start.threads) before any)")
    check(end.fds - base.fds <= 4 + objects,
          "leak \(label): fds flat over the last \(n) cycles: \(base.fds) → \(end.fds) (from \(start.fds))" + (newObjects ? " — \(objects) kept objects' boot-log files allowed" : ""))
    check(end.footprintMiB - base.footprintMiB <= 16, String(format: "leak %@: footprint flat over the last %d cycles: %.1f → %.1f MiB (from %.1f)", label, n, base.footprintMiB, end.footprintMiB, start.footprintMiB))
    try await sb.wake()
    let s = try await sb.sessions().first { $0.name == "tick" }
    check(s != nil && s?.pid == pid && s?.isEnded == false, "leak \(label): the session survived all \(cycles) cycles (pid \(pid.map(String.init) ?? "?"))")
    try await sb.shutDown()
    try? await sb.delete()
}

// MARK: concurrent wakes (item 3)

func concurrentSuite() async throws {
    let n = envInt("HARDEN_CONCURRENT", 16), rounds = envInt("HARDEN_ROUNDS", 3)
    // Proxied (no NIC), as SandboxLab's sandboxes are: the wake re-registers the proxy listener too.
    let specs: [SandboxSpec] = try (1...n).map { i in
        var s = try hardenSpec(String(format: "harden-cc-%02d", i), memoryMiB: 256)
        s.network = .proxied(.locked)
        return s
    }
    print("vmtest[hardening]: \(n) sandboxes woken concurrently × \(rounds) rounds (+1 round through new objects)")
    var sbs: [Sandbox] = []
    for s in specs {
        let sb = try await freshSandbox(s)
        try await sb.start()
        try await sb.openSession("tick", argv: ["bash", "/work/tick.sh"], size: .standard)
        try await sb.hibernate()
        sbs.append(sb)
    }
    info("\(n) sandboxes hibernated")
    var wakeErrors = 0, sleepErrors = 0, deadAfter = 0, total = 0
    func all(_ label: String, _ op: @escaping @Sendable (Sandbox) async throws -> Void) async -> [(Int, Double, String?)] {
        await withTaskGroup(of: (Int, Double, String?).self) { g in
            for (i, sb) in sbs.enumerated() {
                g.addTask {
                    let t0 = Date()
                    do { try await op(sb); return (i, Date().timeIntervalSince(t0) * 1000, nil) } catch {
                        return (i, Date().timeIntervalSince(t0) * 1000, "\(error)")
                    }
                }
            }
            var out: [(Int, Double, String?)] = []
            for await r in g { out.append(r) }
            return out
        }
    }
    for round in 1...(rounds + 1) {
        let newObjects = round == rounds + 1
        if newObjects {
            hardeningKeep.append(contentsOf: sbs)
            sbs = try specs.map { try Sandbox(spec: $0) }
        }
        let notes = sbs.map { NoteLog($0) }
        let t0 = Date()
        let w = await all("wake") { try await $0.wake() }
        let ms = Date().timeIntervalSince(t0) * 1000
        total += w.count
        let errs = w.filter { $0.2 != nil }
        wakeErrors += errs.count
        for e in errs { info("round \(round): \(specs[e.0].name) wake threw: \(e.2!)") }
        for (i, nl) in notes.enumerated() {
            for l in nl.lines where l.contains("FAILED") || l.contains("retrying") { info("round \(round): \(specs[i].name): \(l)") }
            nl.stop()
        }
        // Every one must be up and answering, whatever the wake reported.
        var dead = 0
        for sb in sbs {
            let r = try? await sb.exec(["sh", "-c", "echo up"], timeoutSeconds: 20)
            if r?.output.contains("up") != true { dead += 1 }
        }
        deadAfter += dead
        let d = await all("hibernate") { try await $0.hibernate() }
        let dErr = d.filter { $0.2 != nil }
        sleepErrors += dErr.count
        for e in dErr { info("round \(round): \(specs[e.0].name) hibernate threw: \(e.2!)") }
        let per = w.map(\.1).sorted()
        info(String(format: "round %d%@: %d woken together in %.0f ms (each p50 %.0f · max %.0f ms) · wake errors %d · not answering %d · hibernate errors %d",
                    round, newObjects ? " (new objects: restore)" : "", n, ms, per[per.count / 2], per.last ?? 0, errs.count, dead, dErr.count))
    }
    check(wakeErrors == 0, "\(total) concurrent wakes (\(n) at a time): \(wakeErrors) errors")
    check(deadAfter == 0, "every woken sandbox answered an exec (\(deadAfter) did not)")
    check(sleepErrors == 0, "concurrent hibernations: \(sleepErrors) errors")
    for sb in sbs { try? await sb.shutDown(); try? await sb.delete() }
}

// MARK: wake memory (item 4)

/// The VM helper serving sandbox `name`: a com.apple.Virtualization.VirtualMachine process with its
/// `sandboxes/<name>/rootfs.ext4` open (the 582 method).
func vmHelper(of name: String) -> pid_t? {
    let n = proc_listallpids(nil, 0)
    var pids = [pid_t](repeating: 0, count: Int(n) + 256)
    let m = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    for p in pids.prefix(max(m, 0)) {
        var b = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(p, &b, 4096) > 0, String(cString: b).hasSuffix("com.apple.Virtualization.VirtualMachine") else { continue }
        let size = proc_pidinfo(p, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { continue }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 16)
        let k = Int(proc_pidinfo(p, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))) / MemoryLayout<proc_fdinfo>.stride
        for fd in fds.prefix(k) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vi = vnode_fdinfowithpath()
            let sz = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(p, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, sz) == sz else { continue }
            let path = withUnsafeBytes(of: &vi) { raw in
                let off = MemoryLayout<vnode_fdinfowithpath>.size - 1024
                return String(decoding: raw[off..<(off + 1024)].prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if path.hasSuffix("/sandboxes/\(name)/rootfs.ext4") { return p }
        }
    }
    return nil
}

func memorySuite() async throws {
    print("vmtest[hardening]: a woken sandbox gives its untouched RAM back (memory balloon)")
    var spec = try hardenSpec("harden-mem", memoryMiB: 1024)
    spec.network = .none
    let sb = try await freshSandbox(spec)
    try await sb.start()
    try await sb.openSession("tick", argv: ["bash", "/work/tick.sh"], size: .standard)
    func footprint() async -> Double {
        try? await Task.sleep(for: .seconds(4))
        return vmHelper(of: spec.name).map { hostFootprintMiB($0) } ?? -1
    }
    let cold = await footprint()
    try await sb.hibernate()
    await sb.setReturnsFreeMemoryOnWake(false)
    try await sb.wake()
    let plain = await footprint()
    try await sb.hibernate()
    await sb.setReturnsFreeMemoryOnWake(true)
    let t0 = Date()
    try await sb.wake()
    let wakeMs = Date().timeIntervalSince(t0) * 1000
    let held = await sb.memoryReturnedMiB
    let ballooned = await footprint()
    info(String(format: "helper footprint: cold-booted %.0f MiB · woken without the balloon %.0f · woken %.0f (%llu MiB held; wake %.0f ms)",
                cold, plain, ballooned, held, wakeMs))
    check(plain > 1000, String(format: "woken without the balloon the VM holds its allocation (%.0f MiB)", plain))
    check(held > 500 && ballooned < plain * 0.6, String(format: "woken, it gives %llu MiB back: %.0f → %.0f MiB", held, plain, ballooned))
    // Every snapshot path deflates first — from running (Sleep, Hibernate) and from Pause.
    try await sb.pause()
    try await sb.sleep()
    try await sb.wake()
    try await sb.hibernate()
    try await sb.wake()
    let s = try await sb.sessions().first { $0.name == "tick" }
    check(await sb.phase == .running && s?.isEnded == false, "Pause → Sleep → Wake → Hibernate → Wake with the balloon held: running, session alive")
    try await sb.restoreGuestMemory()
    check(await sb.memoryReturnedMiB == 0, "restoreGuestMemory gives the guest its whole allocation back")
    let r = try await sb.returnFreeMemory()
    check((r?.heldMiB ?? 0) > 500, "returnFreeMemory on demand: \(r?.heldMiB ?? 0) MiB held (\(Int(r?.milliseconds ?? -1)) ms)")
    try await sb.shutDown()
    try? await sb.delete()
}

// MARK: automatic subnets (item 6)

func subnetSuite() async throws {
    print("vmtest[hardening]: automatic vmnet subnets")
    func natSpec(_ name: String, subnet: String?) throws -> SandboxSpec {
        var s = try hardenSpec(name, memoryMiB: 256)
        s.subnet = subnet
        return s
    }
    let a = try await freshSandbox(try natSpec("harden-net-a", subnet: nil))
    let b = try await freshSandbox(try natSpec("harden-net-b", subnet: nil))
    // Not `testSubnet`: the other parts' NAT sandboxes (kept alive, as a host's registry keeps them)
    // hold it in this process, and a taken subnet — rightly — falls back to a free one.
    let override = ProcessInfo.processInfo.environment["HARDEN_OVERRIDE_SUBNET"] ?? "192.168.223.0/24"
    let c = try await freshSandbox(try natSpec("harden-net-c", subnet: override))
    var subnets: [String] = []
    for sb in [a, b, c] {
        try await sb.start()
        let s = PersistedSandbox.read(from: sb.layout.persistedState)?.subnet ?? "?"
        subnets.append(s)
        let r = try await sb.exec(["sh", "-c", "ip -4 addr show eth0 | awk '/inet/{print $2}'; for n in 1 2 3; do wget -q -T 4 -O /dev/null http://1.1.1.1 && { echo NET-OK; exit 0; }; sleep 1; done; echo NET-FAIL"],
                                  timeoutSeconds: 40)
        info("\(sb.spec.name): subnet \(s) · guest \(r.output.replacingOccurrences(of: "\n", with: " "))")
        check(r.output.contains("NET-OK"), "\(sb.spec.name) reaches the internet through NAT on \(s)")
    }
    let pool = (100...199).map { "192.168.\($0).0/24" }
    check(pool.contains(subnets[0]) && pool.contains(subnets[1]), "no subnet asked for → one from the pool (\(subnets[0]), \(subnets[1]))")
    check(subnets[0] != subnets[1], "two sandboxes in one process get different subnets")
    check(subnets[2] == override, "an explicit SandboxSpec.subnet stays an override (\(subnets[2]))")
    // Hibernate → Wake keeps the subnet (a restore needs its guest's addresses).
    try await a.hibernate()
    try await a.wake()
    let after = PersistedSandbox.read(from: a.layout.persistedState)?.subnet
    check(after == subnets[0], "a wake keeps the automatic subnet (\(after ?? "?"))")
    for sb in [a, b, c] { try? await sb.shutDown(); try? await sb.delete() }
}

// MARK: quit settle (item 5)

func settleSuite() async throws {
    print("vmtest[hardening]: prepareForExit lets a just-started program settle")
    let sb = try await freshSandbox(try hardenSpec("harden-settle", memoryMiB: 256))
    try await sb.start()
    try await sb.openSession("tick", argv: ["bash", "/work/tick.sh"], size: .standard)
    let t0 = Date()
    await sb.prepareForExit()
    let waited = Date().timeIntervalSince(t0)
    check(await sb.phase == .hibernated && waited >= 2.3, String(format: "a session opened just now: the quit waited %.1f s, then hibernated", waited))
    try await sb.wake()
    let s = try await sb.sessions().first { $0.name == "tick" }
    check(s != nil && s?.isEnded == false, "the program is alive after the wake")
    try? await Task.sleep(for: .seconds(3))
    let t1 = Date()
    await sb.prepareForExit()
    let waited2 = Date().timeIntervalSince(t1)
    check(waited2 < 2.0, String(format: "a session older than the settle time: no wait (quit took %.1f s)", waited2))
    try await sb.shutDown()
    try? await sb.delete()
}

func hardeningSuite(_ part: String?) async throws {
    switch part {
    case "discard": try await discardSuite()
    case "leak": try await leakSuite()
    case "concurrent": try await concurrentSuite()
    case "subnets": try await subnetSuite()
    case "settle": try await settleSuite()
    case "memory": try await memorySuite()
    default:
        try await discardSuite()
        try await leakSuite()
        try await concurrentSuite()
        try await memorySuite()
        try await settleSuite()
        try await subnetSuite()
    }
}
