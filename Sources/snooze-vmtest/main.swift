// snooze-vmtest — SnoozeContainerKit's VM integration suite, as an ENTITLED executable.
//
// `swift test` binaries cannot carry `com.apple.security.virtualization`, so these checks run
// here instead: `make test-vm` builds this target, ad-hoc signs it with Scripts/vmtest.entitlements,
// and runs it under a watchdog. It is a trimmed port of the 576 sleep POC's selftest + keytest,
// driven through the library's public API only, plus the crash-restore case (two processes).
//
// Usage: snooze-vmtest [all|lifecycle|crash|crash-restore|kernel] [--store DIR] [--no-seed]
//          kernel         only resolve the pinned kernel (fetch + verify into the cache; no VM,
//                         no entitlement needed) — `make kernel`, and CI's first step.
//                         --no-seed skips copying a byte-identical local kernel, forcing the
//                         real download path.
//          all (default)  the lifecycle suite, then the crash-restore case
//          crash-restore  only the restoring half (after a crash-save left a sandbox asleep)
//          crash-save     (internal) the child half of the crash case
// Inputs: --store DIR or $SNOOZE_VMTEST_STORE (default $TMPDIR/snooze-vmtest-store) — a scratch
//   store, never an app's; network on the first run (kernel, images, one package bake); the
//   library's pinned kernel, cached in $SNOOZE_KERNEL_CACHE if set ($SNOOZE_KERNEL = explicit path).
//   Prints one PASS/FAIL line per check and
//   exits 0 only when all pass.
import Darwin
import Foundation
import SnoozeContainerKit

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

let args = Array(CommandLine.arguments.dropFirst())
let mode = args.first.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? "all"
let storeRoot: URL = {
    if let i = args.firstIndex(of: "--store"), i + 1 < args.count { return URL(fileURLWithPath: args[i + 1]) }
    if let s = ProcessInfo.processInfo.environment["SNOOZE_VMTEST_STORE"], !s.isEmpty { return URL(fileURLWithPath: s) }
    return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snooze-vmtest-store")
}()
// Kernel: the library's pinned one (fetched once), cached in $SNOOZE_KERNEL_CACHE when set (CI
// shares one cache across runs and repos), else under the store. $SNOOZE_KERNEL = explicit path.
let kernelPath = ProcessInfo.processInfo.environment["SNOOZE_KERNEL"].flatMap { $0.isEmpty ? nil : $0 }
let kernelCache = ProcessInfo.processInfo.environment["SNOOZE_KERNEL_CACHE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

// MARK: harness

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "  PASS  " : "  FAIL  ") + what)
    if !ok { failures += 1 }
}
func info(_ s: String) { print("        · \(s)") }

/// Records everything a connection delivers, with arrival times.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Date, SessionOutput)] = []
    private var done = false
    let started = Date()

    init(_ c: SessionConnection) {
        Task.detached { [self] in
            for await o in c.output { append(o) }
            markDone()
        }
    }

    private func append(_ o: SessionOutput) { lock.lock(); items.append((Date(), o)); lock.unlock() }
    private func markDone() { lock.lock(); done = true; lock.unlock() }

    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return done }
    var all: [SessionOutput] { lock.lock(); defer { lock.unlock() }; return items.map(\.1) }
    var first: (Date, SessionOutput)? { lock.lock(); defer { lock.unlock() }; return items.first }
    var last: SessionOutput? { lock.lock(); defer { lock.unlock() }; return items.last?.1 }

    /// Snapshot + data bytes from item `from` on, as text.
    func text(from: Int = 0) -> String {
        lock.lock(); defer { lock.unlock() }
        var d = Data()
        for (_, o) in items.dropFirst(from) {
            switch o { case .snapshot(let x), .data(let x): d.append(x); default: break }
        }
        return String(decoding: d, as: UTF8.self)
    }

    func bytes(from: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return items.dropFirst(from).reduce(0) { n, e in
            switch e.1 { case .snapshot(let x), .data(let x): n + x.count; default: n }
        }
    }

    func wait(_ seconds: Double, until pred: @escaping (Recorder) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if pred(self) { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return pred(self)
    }
}

func sleepS(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }

/// Test program: streams ticks, traps SIGQUIT (the terminal's quit key is set to `m`, as the
/// codecks screensaver does) and exits 7 on SIGINT. A signal ignored on entry cannot be trapped,
/// so "[QUIT-TRAPPED]" appearing proves the session was not started through BusyBox `sh -c`.
let tickScript = """
#!/bin/bash
stty quit m
trap 'echo "[QUIT-TRAPPED]"' QUIT
trap 'echo "[INT] bye"; exit 7' INT
i=0
while :; do i=$((i+1)); printf 'tick %d\\r\\n' "$i"; sleep 0.2; done
"""

func makeSpec(_ name: String, share: URL) -> SandboxSpec {
    SandboxSpec(name: name, storeRoot: storeRoot, kernelPath: kernelPath, kernelCacheDirectory: kernelCache, cpus: 2, memoryMiB: 512,
                rootfsMiB: 1024, bakePackages: ["bash", "ncurses"],
                shares: [Share(hostPath: share.path, guestPath: "/work")])
}

func prepareShare(_ name: String) throws -> URL {
    let share = storeRoot.appendingPathComponent("share-\(name)")
    try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
    try tickScript.write(to: share.appendingPathComponent("tick.sh"), atomically: true, encoding: .utf8)
    return share
}

func logEvents(_ sb: Sandbox, prefix: String = "") -> Task<Void, Never> {
    let stream = sb.events()
    return Task.detached {
        for await e in stream {
            switch e {
            case .step(let s, let ms): info(prefix + String(format: "%@ — %.0f ms", s, ms))
            case .note(let s): info(prefix + s)
            case .progress(let s, let done, let total):
                info(prefix + "\(s): \(done / 1_048_576) MiB" + (total.map { " of \($0 / 1_048_576) MiB" } ?? ""))
            default: break
            }
        }
    }
}

// MARK: the lifecycle suite

func lifecycleSuite() async throws {
    let share = try prepareShare("vmtest")
    let sb = try Sandbox(spec: makeSpec("vmtest", share: share))
    let log = logEvents(sb)
    defer { log.cancel() }
    if await sb.phase != .off { try? await sb.stop() }

    print("vmtest: start")
    let t0 = Date()
    try await sb.start()
    check(await sb.phase == .running, String(format: "sandbox running (start %.2f s)", Date().timeIntervalSince(t0)))

    try await sb.openSession("tick", argv: ["bash", "/work/tick.sh"], size: TermSize(cols: 100, rows: 30))
    let tickPid = try await sb.sessions().first { $0.name == "tick" }?.pid
    check(tickPid != nil, "session tick is listed by deckhold ls (pid \(tickPid.map(String.init) ?? "?"))")

    // Signal hygiene: the program starts with nothing ignored.
    if let pid = tickPid {
        let st = try await sb.exec(["cat", "/proc/\(pid)/status"]).output
        let ign = st.split(separator: "\n").first { $0.hasPrefix("SigIgn:") }.map { $0.split(separator: "\t").last.map(String.init) ?? "" } ?? "?"
        let mask = UInt64(ign.trimmingCharacters(in: .whitespaces), radix: 16) ?? .max
        check(mask & 0x4 == 0, "the session's program does not start with SIGQUIT ignored (SigIgn \(ign))")
    }

    print("vmtest: attach")
    var conn = try await sb.attach("tick", size: TermSize(cols: 100, rows: 30))
    var rec = Recorder(conn)
    let gotSnapshot = await rec.wait(2) { $0.count > 0 }
    if case .snapshot = rec.first?.1 {
        check(gotSnapshot, String(format: "the first output is a SNAPSHOT (%.0f ms after attach)",
                                  (rec.first!.0.timeIntervalSince(rec.started)) * 1000))
    } else { check(false, "the first output is a SNAPSHOT (got \(String(describing: rec.first?.1)))") }
    check(await rec.wait(3) { $0.text().contains("tick ") && $0.count > 3 }, "live output follows (\(rec.bytes(from: 0)) bytes)")

    print("vmtest: pause / resume")
    try await sb.pause()
    await sleepS(0.3)
    var mark = rec.count
    await sleepS(2)
    check(await sb.phase == .paused && rec.bytes(from: mark) == 0, "paused: no output for 2 s (\(rec.bytes(from: mark)) bytes)")
    try await sb.resume()
    mark = rec.count
    check(await rec.wait(3) { $0.bytes(from: mark) > 0 }, "resumed: output flows again on the SAME connection")

    print("vmtest: keys reach the program")
    mark = rec.count
    conn.send(Data("m".utf8))
    check(await rec.wait(4) { $0.text(from: mark).contains("[QUIT-TRAPPED]") }, "`m` (the tty quit key) reaches the program's SIGQUIT trap")

    print("vmtest: resize")
    let beforeResize = rec.count
    conn.resize(TermSize(cols: 80, rows: 24))
    var sized = false
    for _ in 0..<20 where !sized {
        await sleepS(0.2)
        sized = (try? await sb.sessions().first { $0.name == "tick" }?.size) == TermSize(cols: 80, rows: 24)
    }
    check(sized, "a RESIZE frame resizes the holder's pty and model to 80×24")
    check(await rec.wait(2) { r in r.all.dropFirst(beforeResize).contains { if case .snapshot = $0 { true } else { false } } },
          "a fresh SNAPSHOT follows once the resize settles")

    print("vmtest: sleep (pause + snapshot) / resume")
    let snap = StoreLayout(spec: sb.spec).snapshot
    try await sb.sleep()
    let st1 = await sb.status
    check(st1.phase == .pausedSaved && FileManager.default.fileExists(atPath: snap.path) && st1.snapshotBytes > 0,
          "asleep with a snapshot on disk (\(st1.snapshotBytes / 1_048_576) MiB), RAM held (\(st1.ramHeldMiB) MiB)")
    try await sb.resume()
    check(!FileManager.default.fileExists(atPath: snap.path), "resume deleted the snapshot")
    mark = rec.count
    check(await rec.wait(3) { $0.bytes(from: mark) > 0 }, "output flows again on the same connection after sleep/resume")

    for cycle in 1...2 {
        print("vmtest: sleep to disk / wake (cycle \(cycle))")
        let t1 = Date()
        try await sb.sleepToDisk()
        let sleepMs = Date().timeIntervalSince(t1) * 1000
        let st2 = await sb.status
        check(st2.phase == .onDisk && st2.ramHeldMiB == 0, String(format: "asleep on disk, RAM freed (%.0f ms)", sleepMs))
        _ = await rec.wait(2) { $0.finished }
        check(rec.last == .detached(.sandboxSleeping), "the attached connection was told the sandbox is sleeping")
        var attachRefused = false
        do { _ = try await sb.attach("tick", size: .standard) } catch SandboxError.notRunning { attachRefused = true }
        check(attachRefused, "attach is refused while on disk (a front end holds its viewer until the wake)")

        let hostFile = share.appendingPathComponent("host-\(cycle).txt")
        try "from the host \(cycle)\n".write(to: hostFile, atomically: true, encoding: .utf8)
        let t2 = Date()
        try await sb.wakeFromDisk()
        let wakeMs = Date().timeIntervalSince(t2) * 1000
        check(await sb.phase == .running && !FileManager.default.fileExists(atPath: snap.path),
              String(format: "awake from disk in %.0f ms, snapshot deleted", wakeMs))
        let clock = try await sb.exec(["date", "+%s"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let skew = abs((Double(clock) ?? 0) - Date().timeIntervalSince1970)
        check(skew < 3, String(format: "guest clock re-synced (skew %.1f s)", skew))
        let seen = try await sb.exec(["cat", "/work/host-\(cycle).txt"]).output
        _ = try await sb.exec(["sh", "-c", "echo from-the-guest-\(cycle) > /work/guest-\(cycle).txt"])
        let back = (try? String(contentsOf: share.appendingPathComponent("guest-\(cycle).txt"), encoding: .utf8)) ?? ""
        check(seen.contains("from the host \(cycle)") && back.contains("from-the-guest-\(cycle)"),
              "the /work share works both ways after the wake")
        if !(seen.contains("from the host \(cycle)") && back.contains("from-the-guest-\(cycle)")) {
            info("guest saw: \(seen.prefix(80)) · host saw: \(back.prefix(80))")
            let m = try await sb.exec(["sh", "-c", "grep -E 'virtiofs|/work' /proc/mounts; ls -la /work /run/snooze-vfs 2>&1 | head -20"])
            info("mounts: \(m.output) \(m.errorOutput)")
        }

        let t3 = Date()
        conn = try await sb.attach("tick", size: TermSize(cols: 100, rows: 30))
        rec = Recorder(conn)
        _ = await rec.wait(2) { $0.count > 0 }
        if case .snapshot(let d) = rec.first?.1 {
            let ms = rec.first!.0.timeIntervalSince(t3) * 1000
            check(String(decoding: d, as: UTF8.self).contains("tick"), String(format: "a new viewer gets a SNAPSHOT of the live session %.0f ms after attach", ms))
        } else { check(false, "a new viewer gets a SNAPSHOT first (got \(String(describing: rec.first?.1)))") }
        mark = rec.count
        check(await rec.wait(3) { $0.bytes(from: mark) > 0 }, "the session kept running through the sleep: live output")
    }

    print("vmtest: a shell session beside it")
    try await sb.openSession("shell", argv: ["bash", "-l"], size: TermSize(cols: 100, rows: 30))
    let sh = try await sb.attach("shell", size: TermSize(cols: 100, rows: 30))
    let shRec = Recorder(sh)
    _ = await shRec.wait(3) { $0.text().contains("#") || $0.text().contains("$") }
    sh.send(Data("echo hi-from-$((40+2))\r".utf8))
    check(await shRec.wait(5) { $0.text().contains("hi-from-42") }, "bash -l: `echo hi` is answered")
    check(await sb.attachedConnectionCount == 2, "two sessions attached at once (tick + shell)")
    mark = rec.count
    check(await rec.wait(2) { $0.bytes(from: mark) > 0 }, "tick keeps streaming while the shell is used")
    sh.send(Data("exit 3\r".utf8))
    _ = await shRec.wait(5) { $0.finished }
    check(shRec.last == .ended(exitCode: 3), "`exit 3` ends the session with .ended(3) (got \(String(describing: shRec.last)))")
    let late = Recorder(try await sb.attach("shell", size: .standard))
    _ = await late.wait(5) { $0.finished }
    check(late.last == .ended(exitCode: 3), "a late viewer of the ended session learns its exit code")
    let nope = Recorder(try await sb.attach("nope", size: .standard))
    _ = await nope.wait(5) { $0.finished }
    check(nope.last == .ended(exitCode: nil), "attaching to a session that never existed ends with .ended(nil)")
    let listed = try await sb.sessions()
    check(listed.contains { $0.name == "shell" && $0.exitCode == 3 }, "deckhold ls lists the ended session with its code")

    print("vmtest: Ctrl-C ends the program")
    conn.send(Data([0x03]))
    _ = await rec.wait(8) { $0.finished }
    check(rec.last == .ended(exitCode: 7), "Ctrl-C → the program's INT trap exits 7 → .ended(7) (got \(String(describing: rec.last)))")

    print("vmtest: stop with a viewer attached")
    try await sb.openSession("tick2", argv: ["bash", "/work/tick.sh"])
    let c2 = try await sb.attach("tick2", size: .standard)
    let r2 = Recorder(c2)
    _ = await r2.wait(3) { $0.count > 2 }
    let stopEvents = sb.events()
    let stopLog = Task { () -> [String] in
        var lines: [String] = []
        for await e in stopEvents {
            if case .step(let s, _) = e { lines.append(s) }
            if case .note(let s) = e { lines.append(s) }
            if case .phase(.off) = e { break }
        }
        return lines
    }
    try await sb.stop()
    let lines = await stopLog.value
    check(await sb.phase == .off, "stopped")
    check(lines.contains { $0.hasPrefix("stopped the container") || $0.hasPrefix("stopped the VM") },
          "the VM was really stopped (\(lines.filter { $0.contains("stopped") }.joined(separator: "; ")))")
    _ = await r2.wait(2) { $0.finished }
    check(r2.last == .detached(.sandboxStopped), "the viewer was told the sandbox stopped (got \(String(describing: r2.last)))")
    let n = r2.count
    await sleepS(1.5)
    check(r2.count == n, "no byte reaches a closed connection after Stop")
    var refused = false
    do { _ = try await sb.attach("tick2", size: .standard) } catch SandboxError.notRunning { refused = true }
    check(refused, "a reconnecting viewer gets nothing: attach is refused once stopped")

    print("vmtest: Stop keeps the root disk; Reset to image and Delete sandbox discard it")
    try await sb.start()
    let keep = "kept-\(UUID().uuidString.prefix(8))"
    _ = try await sb.exec(["sh", "-c", "echo \(keep) > /root/snooze-keep && apk add --no-cache jq >/dev/null && sync"], timeoutSeconds: 120)
    try await sb.stop()
    check(sb.hasRootDisk && Sandbox.restorableState(for: sb.spec) == nil, "Stop kept the root disk and left no snapshot")
    try await sb.start()
    let kept1 = try await sb.exec(["sh", "-c", "cat /root/snooze-keep; command -v jq"]).output
    check(kept1.contains(keep) && kept1.contains("/usr/bin/jq"), "Stop → Start: the marker file and the apk-added package are still there")
    try await sb.pause()
    try await sb.resetToImage()
    check(await sb.phase == .off && !sb.hasRootDisk, "Reset to image (from paused) stopped the VM and discarded the root disk")
    try await sb.start()
    let fresh = try await sb.exec(["sh", "-c", "cat /root/snooze-keep 2>/dev/null; command -v jq || echo no-jq"]).output
    check(!fresh.contains(keep) && fresh.contains("no-jq"), "after Reset, Start begins from a fresh clone of the prepared disk")
    try await sb.delete()
    let dirGone = !FileManager.default.fileExists(atPath: StoreLayout(spec: sb.spec).sandboxDirectory.path)
    check(await sb.phase == .off && dirGone, "Delete sandbox (from running) stopped it and removed its whole directory")

    for (label, park) in [("paused", { try await sb.pause() }), ("on disk", { try await sb.sleepToDisk() })] as [(String, () async throws -> Void)] {
        print("vmtest: stop while \(label) (revived, then stopped gracefully)")
        try await sb.start()
        try await sb.openSession("tick", argv: ["bash", "/work/tick.sh"])
        try await park()
        let ev = sb.events()
        let evLog = Task { () -> [String] in
            var l: [String] = []
            for await e in ev {
                if case .step(let s, _) = e { l.append(s) }
                if case .note(let s) = e { l.append(s) }
                if case .phase(let p) = e { l.append("phase \(p.rawValue)"); if p == .off { break } }
            }
            return l
        }
        try await sb.stop()
        let pl = await evLog.value
        check(await sb.phase == .off && pl.contains { $0.hasPrefix("stopped the container") } && !pl.contains("phase running"),
              "Stop while \(label): the VM is revived without a phase change and stopped through the package (\(pl.joined(separator: "; ")))")
        check(!FileManager.default.fileExists(atPath: snap.path), "no snapshot left behind")
    }
}

// MARK: crash restore (two processes)

func crashSave() async throws -> Int32 {
    let share = try prepareShare("vmtest-crash")
    let sb = try Sandbox(spec: makeSpec("vmtest-crash", share: share))
    let log = logEvents(sb, prefix: "[child] ")
    try await sb.start()
    try await sb.openSession("tick", argv: ["bash", "/work/tick.sh"], size: TermSize(cols: 100, rows: 30))
    await sleepS(1)
    let pid = try await sb.sessions().first { $0.name == "tick" }?.pid ?? -1
    try "\(pid)".write(to: storeRoot.appendingPathComponent("crash-pid.txt"), atomically: true, encoding: .utf8)
    try await sb.sleepToDisk()
    log.cancel()
    print("        · [child] asleep on disk with session tick (pid \(pid)); exiting WITHOUT stop, like a crash")
    return 0
}

func crashSuite(skipChild: Bool = false) async throws {
  if !skipChild {
    print("vmtest: crash restore — the child starts, opens a session, sleeps to disk and exits")
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let child = Process()
    child.executableURL = exe
    child.arguments = ["crash-save", "--store", storeRoot.path]
    try child.run()
    child.waitUntilExit()
    check(child.terminationStatus == 0, "the child process slept its sandbox to disk and exited (\(child.terminationStatus))")
  }

    let spec = makeSpec("vmtest-crash", share: storeRoot.appendingPathComponent("share-vmtest-crash"))
    check(Sandbox.restorableState(for: spec) != nil, "a new process sees a restorable sandbox")
    let sb = try Sandbox(spec: spec)
    let log = logEvents(sb)
    defer { log.cancel() }
    let t0 = Date()
    try await sb.restoreAfterCrash()
    check(await sb.phase == .running, String(format: "restored into this process in %.2f s (pinned machine id)", Date().timeIntervalSince(t0)))
    let pid = Int((try? String(contentsOf: storeRoot.appendingPathComponent("crash-pid.txt"), encoding: .utf8)) ?? "")
    let s = try await sb.sessions().first { $0.name == "tick" }
    check(s != nil && s?.pid == pid && s?.isEnded == false, "the session survived the crash (same pid \(pid.map(String.init) ?? "?"))")
    let c = try await sb.attach("tick", size: TermSize(cols: 100, rows: 30))
    let r = Recorder(c)
    _ = await r.wait(2) { $0.count > 0 }
    if case .snapshot = r.first?.1 { check(true, "a viewer reattaches with a SNAPSHOT") } else { check(false, "a viewer reattaches with a SNAPSHOT") }
    let m = r.count
    check(await r.wait(3) { $0.bytes(from: m) > 0 }, "and the session's output is live")
    // A name no run has used: deleting a marker on the HOST while the guest still caches its
    // dentry is ordinary virtio-fs caching, not a remount failure (it cost an afternoon).
    let markerName = "after-crash-\(UUID().uuidString.prefix(8)).txt"
    let marker = storeRoot.appendingPathComponent("share-vmtest-crash/\(markerName)")
    let w = try await sb.exec(["sh", "-c", "echo restored > /work/\(markerName)"])
    if w.exitCode != 0 { info("write exit \(w.exitCode): \(w.errorOutput)") }
    let shareOK = FileManager.default.fileExists(atPath: marker.path)
    check(shareOK, "the share was re-mounted after the restore")
    if !shareOK {
        let m = try await sb.exec(["sh", "-c", "grep -E 'virtiofs|work|vfs' /proc/self/mountinfo; ls -la /work 2>&1 | head"])
        info("diagnostics: \(m.output) \(m.errorOutput)")
    }
    check(!FileManager.default.fileExists(atPath: StoreLayout(spec: spec).snapshot.path), "the snapshot was deleted after the restore")
    try await sb.stop()
    check(await sb.phase == .off && Sandbox.restorableState(for: spec) == nil, "stopped; nothing left to restore")
}

// MARK: main

Task {
    do {
        switch mode {
        case "crash-save":
            exit(try await crashSave())
        case "kernel":
            let spec = makeSpec("vmtest", share: storeRoot)
            var provider = try Sandbox(spec: spec).kernelProvider
            if args.contains("--no-seed") { provider.seedCandidates = [] }
            let t0 = Date()
            let url = try await provider.resolve(override: spec.kernelPath) { e in
                switch e {
                case .step(let s, let ms): info(String(format: "%@ — %.0f ms", s, ms))
                case .note(let s): info(s)
                case .progress(let s, let done, let total):
                    info("\(s): \(done / 1_048_576) MiB" + (total.map { " of \($0 / 1_048_576) MiB" } ?? ""))
                }
            }
            check(true, String(format: "kernel ready at %@ (%.1f s)", url.path, Date().timeIntervalSince(t0)))
            print("vmtest: ALL PASS")
            exit(0)
        case "lifecycle":
            try await lifecycleSuite()
        case "crash":
            try await crashSuite()
        case "crash-restore":
            try await crashSuite(skipChild: true)
        default:
            try await lifecycleSuite()
            try await crashSuite()
        }
    } catch {
        print("  FAIL  aborted: \(error.localizedDescription)")
        failures += 1
    }
    print(failures == 0 ? "vmtest: ALL PASS" : "vmtest: \(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
