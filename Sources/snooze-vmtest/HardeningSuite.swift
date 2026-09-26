import Darwin
import Foundation
import SnoozeContainerKit

// 583 — the hardening suite (`snooze-vmtest hardening`, or one of its parts by name). Each part is
// the regression test for a hazard the 582 scaling probe found:
//
//   discard     582 §8: `discardRestorableState` + `start()` cold-booted a root disk its deep-slept
//               VM never unmounted (ext4, no journal) — 12 of 15 boots failed. N cycles of
//               start → write → Deep Sleep → discard (a NEW Sandbox object, as a new process)
//               → start, each boot checked for ext4 errors. Must be 0 failures.
//   leak        582 §7: every VM instance the host made kept an 8-thread NIO event-loop group
//               after Deep Sleep (~5 threads, ~6 kqueue fds, ~1 MiB per cycle, never returned).
//               N Deep Sleep → Wake cycles, alternating a same-object wake with a wake through a
//               NEW Sandbox object (a new VM instance — the path that leaked); the host's thread,
//               fd and footprint counts must stay flat.
//   concurrent  582 §8: 2 of 31 concurrent wakes threw "The channel was closed" although the
//               sandbox came up. N sandboxes deep-slept together and woken together, same-object
//               and new-object rounds; 0 errors, and every one answers an exec afterwards.
//
// Inputs: the suite's usual --store / $SNOOZE_SUBNET; HARDEN_CYCLES (discard, default 15),
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

/// Sandboxes a part created but may not drop: a deep-asleep `Sandbox` object still owns the
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
    let spec = try hardenSpec("harden-discard")
    var sb = try await freshSandbox(spec)
    print("vmtest[hardening]: discard → cold boot × \(cycles)")
    try await sb.start()
    var failed = 0, fscks = 0
    for i in 1...cycles {
        // Dirty the disk the way a session does: create files, leave them in the page cache.
        let w = try await sb.exec(["sh", "-c", "mkdir -p /root/d\(i) && for n in $(seq 1 40); do echo \(i)-$n > /root/d\(i)/f$n; done; echo ok"])
        if !w.output.contains("ok") { info("cycle \(i): write failed \(w.errorOutput)") }
        try await sb.openSession("s\(i)", argv: ["bash", "-l"], size: .standard)
        try await sb.deepSleep()
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

func hardeningSuite(_ part: String?) async throws {
    switch part {
    case "discard": try await discardSuite()
    default:
        try await discardSuite()
    }
}
