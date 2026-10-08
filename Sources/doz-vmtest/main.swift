// doz-vmtest — DozerKit's VM integration suite, as an ENTITLED executable.
//
// `swift test` binaries cannot carry `com.apple.security.virtualization`, so these checks run
// here instead: `make test-vm` builds this target, ad-hoc signs it with Scripts/vmtest.entitlements,
// and runs it under a watchdog. It is a trimmed port of the 576 sleep POC's selftest + keytest,
// driven through the library's public API only, plus the crash-restore case (two processes).
//
// Usage: doz-vmtest [all|lifecycle|crash|crash-restore|agents|agent NAME|bake NAME|network|kernel] [--store DIR] [--no-seed]
//          restore        579 §D: restore points — take / revert / fork / delete / save as image
//          agents         579: bake (or cache-hit) the claude-code and pi images and run the agent suite
//                         on each (start, verify, /workspace, state disk, session, snapshot sizes, sleep
//                         to disk → wake with the same pid, crash restore, Stop → Start, re-bake)
//          network        580: a proxied sandbox (no NIC) on the claude-code image — policy, DNS, redirected
//                         TCP, UDP blocked, placeholder credentials + the sandbox CA, method/path rules,
//                         sleep to disk → wake, Stop → Start, the log's export; then a bake under the bake preset
//          cli            585: the doz CLI end to end — the real signed binary (--doz PATH), every
//                         call a separate process (CLISuite.swift; `make test-cli`)
//          templates      593: templates and duplicates on pi (a state disk) — a template holds the root
//                         disk only; duplicate's new workspace and fresh (or copied) state disk
//                         (TemplatesSuite.swift; `make test-vm-templates`)
//          hardening [discard|leak|concurrent]
//                         583: the regression tests for the 582 hazards (HardeningSuite.swift)
//          lineage [part] 587: image lineage — base disks, journal, discard, sync, accounting,
//                         reclaim, rederive, children (LineageSuite.swift)
//          kernel         only resolve the pinned kernel (fetch + verify into the cache; no VM,
//                         no entitlement needed) — `make kernel`, and CI's first step.
//                         --no-seed skips copying a byte-identical local kernel, forcing the
//                         real download path.
//          all (default)  the lifecycle suite, the crash-restore case, then restore points
//          crash-restore  only the restoring half (after a crash-save left a sandbox asleep)
//          crash-save     (internal) the child half of the crash case
// Inputs: --store DIR or $DOZ_VMTEST_STORE (default $TMPDIR/doz-vmtest-store) — a scratch
//   store, never an app's; network on the first run (kernel, images, one package bake); the
//   library's pinned kernel, cached in $DOZ_KERNEL_CACHE if set ($DOZ_KERNEL = explicit path).
//   Prints one PASS/FAIL line per check and
//   exits 0 only when all pass.
import Darwin
import Foundation
import Containerization
import DozerKit

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

let args = Array(CommandLine.arguments.dropFirst())
let mode = args.first.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? "all"
let storeRoot: URL = {
    if let i = args.firstIndex(of: "--store"), i + 1 < args.count { return URL(fileURLWithPath: args[i + 1]) }
    if let s = ProcessInfo.processInfo.environment["DOZ_VMTEST_STORE"], !s.isEmpty { return URL(fileURLWithPath: s) }
    return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("doz-vmtest-store")
}()
// Kernel: the library's pinned one (fetched once), cached in $DOZ_KERNEL_CACHE when set (CI
// shares one cache across runs and repos), else under the store. $DOZ_KERNEL = explicit path.
let kernelPath = ProcessInfo.processInfo.environment["DOZ_KERNEL"].flatMap { $0.isEmpty ? nil : $0 }
/// Its own vmnet subnet, so a run never shares one with a SandboxLab (or another run) on this Mac.
let testSubnet = ProcessInfo.processInfo.environment["DOZ_SUBNET"] ?? "192.168.201.0/24"
let kernelCache = ProcessInfo.processInfo.environment["DOZ_KERNEL_CACHE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

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
/// a terminal screensaver does) and exits 7 on SIGINT. A signal ignored on entry cannot be trapped,
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
                shares: [Share(hostPath: share.path, guestPath: "/work")], subnet: testSubnet)
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
    if await sb.phase != .off { try? await sb.shutDown() }

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
    check(st1.phase == .asleep && FileManager.default.fileExists(atPath: snap.path) && st1.snapshotBytes > 0,
          "asleep with a snapshot on disk (\(st1.snapshotBytes / 1_048_576) MiB), RAM held (\(st1.ramHeldMiB) MiB)")
    try await sb.resume()
    check(!FileManager.default.fileExists(atPath: snap.path), "resume deleted the snapshot")
    mark = rec.count
    check(await rec.wait(3) { $0.bytes(from: mark) > 0 }, "output flows again on the same connection after sleep/resume")

    for cycle in 1...2 {
        print("vmtest: sleep to disk / wake (cycle \(cycle))")
        let t1 = Date()
        try await sb.hibernate()
        let sleepMs = Date().timeIntervalSince(t1) * 1000
        let st2 = await sb.status
        check(st2.phase == .hibernated && st2.ramHeldMiB == 0, String(format: "asleep on disk, RAM freed (%.0f ms)", sleepMs))
        _ = await rec.wait(2) { $0.finished }
        check(rec.last == .detached(.sandboxSleeping), "the attached connection was told the sandbox is sleeping")
        var attachRefused = false
        do { _ = try await sb.attach("tick", size: .standard) } catch SandboxError.notRunning { attachRefused = true }
        check(attachRefused, "attach is refused while on disk (a front end holds its viewer until the wake)")

        let hostFile = share.appendingPathComponent("host-\(cycle).txt")
        try "from the host \(cycle)\n".write(to: hostFile, atomically: true, encoding: .utf8)
        let t2 = Date()
        try await sb.wake()
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
            let m = try await sb.exec(["sh", "-c", "grep -E 'virtiofs|/work' /proc/mounts; ls -la /work /run/dozer-vfs 2>&1 | head -20"])
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
    try await sb.shutDown()
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
    // The package install needs the network; an intermittent vmnet loss right after boot is not what
    // this checks, so it retries (and says so).
    let inst = try await sb.exec(["sh", "-c", "echo \(keep) > /root/doz-keep; for n in 1 2 3 4; do apk add --no-cache jq >/dev/null 2>&1 && { [ $n -gt 1 ] && echo \"apk needed $n tries\"; sync; exit 0; }; sleep 3; done; exit 1"], timeoutSeconds: 180)
    if inst.output.contains("tries") { info(inst.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
    if inst.exitCode != 0 {
        let d = try await sb.exec(["sh", "-c", "ip -4 addr show eth0 | awk '/inet/{print $2}'; ip route | head -1; wget -q -T 4 -O /dev/null http://1.1.1.1 && echo NET-OK || echo NET-FAIL"])
        info("install failed (\(inst.exitCode)): \(inst.errorOutput.prefix(200)) · net: \(d.output.replacingOccurrences(of: "\n", with: " "))")
    }
    try await sb.shutDown()
    check(sb.hasRootDisk && Sandbox.restorableState(for: sb.spec) == nil, "Stop kept the root disk and left no snapshot")
    try await sb.start()
    let kept1 = try await sb.exec(["sh", "-c", "cat /root/doz-keep; command -v jq"]).output
    check(kept1.contains(keep) && kept1.contains("/usr/bin/jq"), "Stop → Start: the marker file and the apk-added package are still there")
    try await sb.pause()
    try await sb.resetToImage()
    check(await sb.phase == .off && !sb.hasRootDisk, "Reset to image (from paused) stopped the VM and discarded the root disk")
    try await sb.start()
    let fresh = try await sb.exec(["sh", "-c", "cat /root/doz-keep 2>/dev/null; command -v jq || echo no-jq"]).output
    check(!fresh.contains(keep) && fresh.contains("no-jq"), "after Reset, Start begins from a fresh clone of the prepared disk")
    try await sb.delete()
    let dirGone = !FileManager.default.fileExists(atPath: StoreLayout(spec: sb.spec).sandboxDirectory.path)
    check(await sb.phase == .off && dirGone, "Delete sandbox (from running) stopped it and removed its whole directory")

    for (label, park) in [("paused", { try await sb.pause() }), ("on disk", { try await sb.hibernate() })] as [(String, () async throws -> Void)] {
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
        try await sb.shutDown()
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
    // Quit the way a host app does: prepareForExit from RUNNING — Hibernate, never a cold stop.
    await sb.prepareForExit()
    log.cancel()
    print("        · [child] quit with session tick (pid \(pid)) running → \(await sb.phase.label); exiting WITHOUT shutting down")
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
    try await sb.wake()                       // in a new process: adopts the hibernated VM
    check(await sb.phase == .running, String(format: "woke into this process in %.2f s (pinned machine id)", Date().timeIntervalSince(t0)))
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
    try await sb.shutDown()
    check(await sb.phase == .off && Sandbox.restorableState(for: spec) == nil, "stopped; nothing left to restore")
}

// MARK: agent images

func agentImageSpec(_ name: String) -> ImageSpec? {
    switch name { case "claude-code": AgentImages.claudeCode; case "pi": AgentImages.pi; default: nil }
}

func agentSpec(_ name: String, imageSpec: ImageSpec, workspace: URL? = nil) -> SandboxSpec {
    SandboxSpec(name: name, storeRoot: storeRoot, kernelPath: kernelPath, kernelCacheDirectory: kernelCache,
                cpus: 2, memoryMiB: 2048, shares: workspace.map { [Share(hostPath: $0.path, guestPath: "/workspace")] } ?? [],
                subnet: testSubnet, imageSpec: imageSpec)
}

/// Bake (or cache-hit) through the Sandbox's own API, echoing its events.
func bakeImage(_ sb: Sandbox, _ imageSpec: ImageSpec) async throws -> BakedImage {
    let stream = sb.events()
    let echo = Task.detached {
        for await e in stream {
            switch e {
            case .step(let s, let ms): info(String(format: "%@ — %.0f ms", s, ms))
            case .note(let s): info(s)
            default: break
            }
        }
    }
    defer { echo.cancel() }
    guard let img = try await sb.ensureImage() else { throw SandboxError.invalidSpec("no image spec") }
    return img
}


/// The session-start credential. A real key from the environment is used only for the live
/// prompt check and is never printed; without one, a SENTINEL stands in, so the "never on any
/// disk" check still has something to look for.
let realKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
let sentinelKey = "sk-ant-api03-DOZ-SENTINEL-\(UUID().uuidString.prefix(8))-NOT-A-KEY"

/// Bytes of `needle` anywhere in `file` (streamed; holes read as zeros).
func fileContains(_ file: URL, _ needle: String) -> Bool {
    guard let h = try? FileHandle(forReadingFrom: file) else { return false }
    defer { try? h.close() }
    let n = Data(needle.utf8)
    var carry = Data()
    while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty {
        let window = carry + chunk
        if window.range(of: n) != nil { return true }
        carry = window.suffix(n.count)
    }
    return false
}

func mib(_ b: Int64) -> String { "\(b / 1_048_576) MiB" }

func agentSuite(_ imageSpec: ImageSpec) async throws {
    let agentArgv = imageSpec.name == "pi" ? ["pi"] : ["claude"]
    let versionArgv = imageSpec.verify[0].argv
    let persist = imageSpec.resolvedPersistDirs[0]
    let ws = storeRoot.appendingPathComponent("workspace-\(imageSpec.name)")
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    let name = "agent-\(imageSpec.name)"

    print("vmtest[\(imageSpec.name)]: bake (or cache hit)")
    var sb = try Sandbox(spec: agentSpec(name, imageSpec: imageSpec, workspace: ws))
    if await sb.phase != .off { try? await sb.shutDown() }
    let tb = Date()
    let img = try await bakeImage(sb, imageSpec)
    let m = img.manifest
    check(m.verifyOutput.first?.contains(imageSpec.verify[0].expect ?? "") == true,
          "baked image \(imageSpec.name) \(m.key.prefix(12)): verify → \(m.verifyOutput.first ?? "?") (bake took \(String(format: "%.1f", m.totalMilliseconds / 1000)) s)")
    info("disk: \(mib(m.apparentBytes)) apparent, \(mib(m.allocatedBytes)) allocated; timings: " + m.timings.map { "\($0.step) \(Int($0.milliseconds)) ms" }.joined(separator: " · "))
    let tc = Date()
    _ = try await bakeImage(sb, imageSpec)
    check(Date().timeIntervalSince(tc) < 2, String(format: "a second ensure is a cache hit (%.0f ms)", Date().timeIntervalSince(tc) * 1000))
    _ = tb

    print("vmtest[\(imageSpec.name)]: start from the baked disk")
    let log = logEvents(sb)
    let t0 = Date()
    try await sb.start()
    let v = try await sb.exec(versionArgv, environment: imageSpec.sessionEnvironment, workingDirectory: imageSpec.workdir, user: imageSpec.user)
    let readyS = Date().timeIntervalSince(t0)
    check(v.exitCode == 0 && v.output.contains(imageSpec.verify[0].expect ?? ""),
          String(format: "cold start → `%@` answers in %.2f s (%@)", versionArgv.joined(separator: " "), readyS, v.output.trimmingCharacters(in: .whitespacesAndNewlines)))
    let os = try await sb.exec(["sh", "-c", "grep PRETTY_NAME /etc/os-release; node --version; id agent; df -h / | tail -1"]).output
    info(os.replacingOccurrences(of: "\n", with: " | "))
    check(os.contains("Debian"), "the guest is the Debian node base (glibc)")

    let wsFile = "from-agent-\(UUID().uuidString.prefix(6)).txt"
    let w = try await sb.exec(["sh", "-c", "echo hello > /workspace/\(wsFile) && id -un"], user: imageSpec.user)
    check(w.exitCode == 0 && w.output.contains(imageSpec.user) && FileManager.default.fileExists(atPath: ws.appendingPathComponent(wsFile).path),
          "the \(imageSpec.user) user writes /workspace and the host sees it")
    let mp = try await sb.exec(["sh", "-c", "mountpoint '\(persist)' && stat -c %U '\(persist)'"])
    check(mp.exitCode == 0 && mp.output.contains(imageSpec.user), "\(persist) is bound from the state disk, owned by \(imageSpec.user)")
    let marker = "marker-\(UUID().uuidString.prefix(8))"
    _ = try await sb.exec(["sh", "-c", "echo \(marker) > '\(persist)/doz-marker'"], user: imageSpec.user)

    print("vmtest[\(imageSpec.name)]: the agent session (key at session start only)")
    let key = realKey ?? sentinelKey
    let ts = Date()
    try await sb.openSession("agent", argv: agentArgv, environment: ["ANTHROPIC_API_KEY": key], size: TermSize(cols: 120, rows: 36))
    let conn = try await sb.attach("agent", size: TermSize(cols: 120, rows: 36))
    let rec = Recorder(conn)
    var painted = false
    var paintS = 0.0
    for _ in 0..<150 where !painted {
        let t = (try? await sb.screenText("agent")) ?? ""
        let text = t.split(separator: "\n").filter { !$0.hasPrefix("cursor=") }.joined()
        if text.filter({ $0.isLetter }).count > 20 { painted = true; paintS = Date().timeIntervalSince(ts) } else { await sleepS(0.2) }
    }
    check(painted, String(format: "the %@ TUI painted its first screen %.2f s after the session opened", agentArgv[0], paintS))
    let screen = (try? await sb.screenText("agent")) ?? ""
    info("screen: " + screen.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("cursor=") }.prefix(6).joined(separator: " / "))
    let pid = try await sb.sessions().first { $0.name == "agent" }?.pid ?? -1
    let envCheck = try await sb.exec(["sh", "-c", "tr '\\0' '\\n' < /proc/\(pid)/environ | grep -c '^ANTHROPIC_API_KEY=' ; stat -c %U /proc/\(pid)"], privileged: true)
    if !envCheck.output.hasPrefix("1") { info("env check: \(envCheck.output) \(envCheck.errorOutput) · ps: \((try? await sb.exec(["ps", "-eo", "pid,ppid,user,rss,args"]).output) ?? "")") }
    check(envCheck.output.hasPrefix("1") && envCheck.output.contains(imageSpec.user),
          "the key reached the agent's environment (pid \(pid), user \(imageSpec.user)) — and nowhere else")
    check(!fileContains(img.root, key), "the key is not on the baked disk")

    if let realKey, imageSpec.name == "claude-code" {
        let r = try await sb.exec(["claude", "-p", "Reply with exactly the word PONG and nothing else."],
                                  environment: imageSpec.sessionEnvironment.merging(["ANTHROPIC_API_KEY": realKey]) { $1 },
                                  workingDirectory: imageSpec.workdir, user: imageSpec.user, timeoutSeconds: 120)
        check(r.exitCode == 0 && r.output.contains("PONG"), "live prompt: claude -p answers from the guest")
    } else {
        print("  SKIP  live prompt — \(realKey == nil ? "no ANTHROPIC_API_KEY in the environment" : "no automated prompt for \(imageSpec.name)"); the owner checks this by hand")
    }

    await sleepS(5)
    let rss = try await sb.exec(["sh", "-c", """
        for d in /proc/[0-9]*; do awk '/^PPid:/{pp=$2} /^VmRSS:/{r=$2} END{print FILENAME, pp, r+0}' $d/status 2>/dev/null; done \\
          | sed 's#/proc/##; s#/status##' | awk -v root=\(pid) '{ p[$1]=$2; r[$1]=$3 } END {
            t=0; n=0; for (x in p) { y=x; while (y != "" && y != 0 && y != root) y=p[y]; if (y == root) { t+=r[x]; n++ } }
            print "tree_kib=" t " procs=" n }'
        awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END { print "guest_used_mib=" int((t-a)/1024) }' /proc/meminfo
        """], privileged: true).output
    info("idle: " + rss.replacingOccurrences(of: "\n", with: " "))
    check(!rss.contains("tree_kib=0 ") && rss.contains("guest_used_mib="), "idle RSS measured: \(rss.replacingOccurrences(of: "\n", with: " "))")

    print("vmtest[\(imageSpec.name)]: sleep (pause + snapshot) with the agent idle")
    try await sb.sleep()
    let snapIdle = await sb.status.snapshotBytes
    check(snapIdle > 0, "snapshot with the agent running idle: \(mib(Int64(snapIdle)))")
    try await sb.resume()

    print("vmtest[\(imageSpec.name)]: sleep to disk → wake mid-session")
    let t1 = Date()
    try await sb.hibernate()
    let sleepMs = Date().timeIntervalSince(t1) * 1000
    _ = await rec.wait(2) { $0.finished }
    let t2 = Date()
    try await sb.wake()
    let wakeMs = Date().timeIntervalSince(t2) * 1000
    check(await sb.phase == .running, String(format: "slept to disk in %.0f ms, woke in %.0f ms", sleepMs, wakeMs))
    let pidAfter = try await sb.sessions().first { $0.name == "agent" }?.pid ?? -2
    check(pidAfter == pid, "the same \(agentArgv[0]) process after the wake (pid \(pid) → \(pidAfter))")
    let t3 = Date()
    let c2 = try await sb.attach("agent", size: TermSize(cols: 120, rows: 36))
    let r2 = Recorder(c2)
    _ = await r2.wait(3) { $0.count > 0 }
    if case .snapshot(let d) = r2.first?.1 {
        check(d.count > 200, String(format: "a viewer reattaches with a SNAPSHOT of the agent's screen %.0f ms after attach (%d bytes)",
                                    r2.first!.0.timeIntervalSince(t3) * 1000, d.count))
    } else { check(false, "a viewer reattaches with a SNAPSHOT") }
    let before = r2.count
    c2.send(Data("\u{1B}[B".utf8))                    // a key the TUI redraws for
    let reacted = await r2.wait(4) { $0.bytes(from: before) > 0 }
    check(reacted, "the agent's TUI reacts to a key after the wake")
    c2.close()

    print("vmtest[\(imageSpec.name)]: state survives Stop → Start and a re-bake")
    try await sb.shutDown()
    try await sb.start()
    let m1 = try await sb.exec(["cat", "\(persist)/doz-marker"], user: imageSpec.user).output
    check(m1.contains(marker), "Stop → Start: the state disk kept \(persist)")
    try await sb.shutDown()
    log.cancel()

    print("vmtest[\(imageSpec.name)]: crash restore with the state disk attached (two processes)")
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    child.arguments = ["agent-crash-save", imageSpec.name, "--store", storeRoot.path]
    let childLog = storeRoot.appendingPathComponent("agent-crash-child.log")
    FileManager.default.createFile(atPath: childLog.path, contents: nil)
    let childOut = try FileHandle(forWritingTo: childLog)
    child.standardOutput = childOut
    child.standardError = childOut
    try child.run(); child.waitUntilExit()
    try? childOut.close()
    if child.terminationStatus != 0 {
        info("child exited \(child.terminationStatus): " + ((try? String(contentsOf: childLog, encoding: .utf8)) ?? "").split(separator: "\n").suffix(8).joined(separator: " | "))
    }
    let crashPid = Int((try? String(contentsOf: storeRoot.appendingPathComponent("agent-crash-pid.txt"), encoding: .utf8)) ?? "")
    let rsb = try Sandbox(spec: agentSpec(name, imageSpec: imageSpec, workspace: ws))
    let tcr = Date()
    try await rsb.wake()
    let restoredPid = try await rsb.sessions().first { $0.name == "agent" }?.pid
    let still = try await rsb.exec(["cat", "\(persist)/doz-marker"], user: imageSpec.user).output
    check(child.terminationStatus == 0 && restoredPid != nil && restoredPid == crashPid && still.contains(marker),
          String(format: "restored in a new process in %.2f s: the same agent pid (%@) and the state disk mounted", Date().timeIntervalSince(tcr),
                 restoredPid.map(String.init) ?? "none"))
    try await rsb.shutDown()

    var variant = imageSpec
    variant.steps.append(BakeStep("re-bake \(UUID().uuidString.prefix(8))", argv: ["true"], needsNetwork: false))
    sb = try Sandbox(spec: agentSpec(name, imageSpec: variant, workspace: ws))
    try await sb.resetToImage()           // Stop keeps the old root; a new image needs Reset to image
    check(!sb.hasRootDisk && FileManager.default.fileExists(atPath: StoreLayout(spec: sb.spec).stateDisk.path),
          "Reset to image discarded the root disk and kept the state disk")
    let tr = Date()
    let img2 = try await bakeImage(sb, variant)
    check(img2.key != img.key, String(format: "a changed image spec re-bakes (new key %@, %.1f s with the base cached)", String(img2.key.prefix(12)), Date().timeIntervalSince(tr)))
    try await sb.start()
    let m2 = try await sb.exec(["cat", "\(persist)/doz-marker"], user: imageSpec.user).output
    check(m2.contains(marker), "after the re-bake, the new root still sees the same state disk")
    try await sb.shutDown()
    try? FileManager.default.removeItem(at: img2.root.deletingLastPathComponent())
}

// MARK: restore points (579 §D)

func restorePointSuite() async throws {
    let share = try prepareShare("vmtest-rp")
    let sb = try Sandbox(spec: makeSpec("vmtest-rp", share: share))
    let log = logEvents(sb)
    defer { log.cancel() }
    try await sb.delete()                                    // a clean slate each run
    for rp in sb.restorePoints() { try? sb.deleteRestorePoint(rp.id) }
    func has(_ file: String) async throws -> Bool {
        try await sb.exec(["sh", "-c", "test -f /root/\(file) && echo yes || echo no"]).output.contains("yes")
    }

    print("vmtest: restore points — take (stopped) → change → revert → the change is gone")
    try await sb.start()
    _ = try await sb.exec(["sh", "-c", "echo A > /root/A && sync"])
    try await sb.shutDown()
    let t0 = Date()
    let rp1 = try await sb.takeRestorePoint(name: "has-A", note: "stopped")
    check(rp1.takenWhile == .stopped && sb.restorePoints().count == 1,
          String(format: "took restore point has-A while stopped in %.0f ms (APFS clone)", Date().timeIntervalSince(t0) * 1000))
    try await sb.start()
    _ = try await sb.exec(["sh", "-c", "echo B > /root/B && apk add --no-cache jq >/dev/null 2>&1; sync"])
    let t1 = Date()
    let rp2 = try await sb.takeRestorePoint(name: "has-A-B", note: "running")
    let stillRunning = await sb.phase == .running
    check(rp2.takenWhile == .running && rp2.parent == nil && stillRunning,
          String(format: "took restore point has-A-B while RUNNING (sync → pause → clone → resume) in %.0f ms; still running", Date().timeIntervalSince(t1) * 1000))
    _ = try await sb.exec(["sh", "-c", "echo C > /root/C && sync"])
    try await sb.revert(to: rp1.id)
    let auto = sb.restorePoints().first { $0.automatic }
    let offNow = await sb.phase == .off
    check(offNow && auto?.name == "before revert to has-A", "revert stopped the VM and first took an automatic \"before revert to has-A\" restore point")
    try await sb.start()
    let a1 = try await has("A"), b1 = try await has("B"), c1 = try await has("C")
    check(a1 && !b1 && !c1, "after revert to has-A: A is there, B and C are gone")

    print("vmtest: revert to a restore point taken while running → e2fsck on the next boot")
    try await sb.revert(to: rp2.id, takeBeforeRevert: false)
    let fsckEvents = sb.events()
    let fsckLog = Task { () -> [String] in
        var l: [String] = []
        for await e in fsckEvents {
            if case .step(let s, _) = e { l.append(s) }
            if case .note(let s) = e { l.append(s) }
            if case .phase(.running) = e { break }
        }
        return l
    }
    try await sb.start()
    let fl = await fsckLog.value
    let a2 = try await has("A"), b2 = try await has("B"), c2 = try await has("C")
    // 587 (ca4b86a): a restore point of a JOURNALED disk needs no e2fsck — the kernel replays the
    // journal on mount; only a journal-less one (`journalMiB: nil`) is checked first. This check
    // still expected e2fsck for every running-taken point, and failed since 587; 592 aligns it.
    if rp2.journaled == true {
        check(!rp2.needsFsck && !fl.contains { $0.hasPrefix("e2fsck rootfs.ext4") } && bootLogExt4Errors(sb).isEmpty,
              "the first boot from the running-taken point of a journaled disk needed no e2fsck, and the kernel reported no ext4 errors")
    } else {
        check(fl.contains { $0.hasPrefix("e2fsck rootfs.ext4") }, "the first boot from the running-taken point ran e2fsck (\(fl.first { $0.hasPrefix("fsck rootfs") } ?? "no report"))")
    }
    check(a2 && b2 && !c2, "after revert to has-A-B: A and B are there, C is not")
    try await sb.shutDown()

    print("vmtest: fork a restore point into a second sandbox; both run independently")
    try? await Sandbox(spec: { var s = sb.spec; s.name = "vmtest-rp-fork"; return s }()).delete()
    let forkSpec = try sb.fork(rp1.id, as: "vmtest-rp-fork")
    var fspec = forkSpec
    fspec.subnet = nil                                        // the original holds the test subnet
    let fork = try Sandbox(spec: fspec)
    try await sb.start()
    try await fork.start()
    _ = try await fork.exec(["sh", "-c", "echo F > /root/F && sync"])
    let fa = try await fork.exec(["sh", "-c", "ls /root"]).output
    let oa = try await has("F")
    let origRunning = await sb.phase == .running
    check(fa.contains("A") && fa.contains("F") && !fa.contains("B") && !oa && origRunning,
          "the fork booted from has-A and runs beside the original; its changes stay its own")
    try await fork.delete()
    try await sb.shutDown()

    print("vmtest: delete restore points in any order")
    let before = sb.restorePoints().map(\.id)
    try sb.deleteRestorePoint(rp2.id)                       // the middle one
    let after = sb.restorePoints().map(\.id)
    check(after.count == before.count - 1 && after.contains(rp1.id) && !after.contains(rp2.id), "deleted the middle restore point; the others are intact")
    try await sb.revert(to: rp1.id, takeBeforeRevert: false)
    try await sb.start()
    let a3 = try await has("A"), b3 = try await has("B")
    check(a3 && !b3, "the earlier restore point still reverts correctly")
    try await sb.shutDown()

    print("vmtest: save a restore point as a custom image, then start a new sandbox from it")
    let imgName = "vmtest-custom"
    for c in StoreLayout(spec: sb.spec).customImages() where c.name == imgName { try? Sandbox.deleteCustomImage(c.key, storeRoot: storeRoot) }
    let custom = try sb.saveAsImage(rp1.id, name: imgName, note: "A only")
    check(custom.origin == "custom" && custom.restorePointChain.first == rp1.id && custom.fromSandbox == "vmtest-rp",
          "saved has-A as custom image \(custom.key) (origin custom, from vmtest-rp, chain \(custom.restorePointChain))")
    var cspec = makeSpec("vmtest-rp-custom", share: share)
    cspec.customImage = custom.key
    cspec.subnet = nil
    let fromCustom = try Sandbox(spec: cspec)
    try? await fromCustom.delete()
    try await fromCustom.start()
    let cl = try await fromCustom.exec(["sh", "-c", "ls /root"]).output
    check(cl.contains("A") && !cl.contains("B"), "a new sandbox started from the custom image has its contents")
    try await fromCustom.delete()
    try Sandbox.deleteCustomImage(custom.key, storeRoot: storeRoot)
    for rp in sb.restorePoints() { try sb.deleteRestorePoint(rp.id) }
    try await sb.delete()
    check(sb.restorePoints().isEmpty, "cleaned up")
}

// MARK: main

Task {
    do {
        switch mode {
        case "crash-save":
            exit(try await crashSave())
        case "probe":
            // doz-vmtest probe --script '<sh>' : start the lab sandbox, run the script as root, stop.
            guard let i = args.firstIndex(of: "--script"), i + 1 < args.count else { print("probe needs --script"); exit(2) }
            let share = try prepareShare("vmtest")
            let sb = try Sandbox(spec: makeSpec("vmtest", share: share))
            try await sb.start()
            let r = try await sb.exec(["sh", "-c", args[i + 1]], privileged: true)
            print(r.output + r.errorOutput)
            try await sb.shutDown()
            exit(r.exitCode)
        case "bake":
            // doz-vmtest bake claude-code|pi — bake (or cache-hit) one agent image, print the manifest.
            let imageSpec = args.dropFirst().first { !$0.hasPrefix("-") && $0 != "bake" }.flatMap(agentImageSpec) ?? AgentImages.claudeCode
            let sb = try Sandbox(spec: agentSpec("bake-\(imageSpec.name)", imageSpec: imageSpec))
            let log = logEvents(sb)
            let img = try await bakeImage(sb, imageSpec)
            log.cancel()
            print(String(decoding: try JSONEncoder().encode(img.manifest.timings), as: UTF8.self))
            check(true, "image \(imageSpec.name) at \(img.root.path)")
            print("vmtest: ALL PASS"); exit(0)
        case "agent-crash-save":
            // Child half of the agent crash case: start, open the agent session, sleep to disk, exit.
            guard let r = args.dropFirst().first(where: { !$0.hasPrefix("-") && $0 != "agent-crash-save" }).flatMap(agentImageSpec) else { exit(2) }
            let ws = storeRoot.appendingPathComponent("workspace-\(r.name)")
            let sb = try Sandbox(spec: agentSpec("agent-\(r.name)", imageSpec: r, workspace: ws))
            let clog = logEvents(sb, prefix: "[child] ")
            try await sb.start()
            try await sb.openSession("agent", argv: r.name == "pi" ? ["pi"] : ["claude"], environment: ["ANTHROPIC_API_KEY": sentinelKey])
            clog.cancel()
            await sleepS(2)
            let pid = try await sb.sessions().first { $0.name == "agent" }?.pid ?? -1
            try "\(pid)".write(to: storeRoot.appendingPathComponent("agent-crash-pid.txt"), atomically: true, encoding: .utf8)
            await sb.prepareForExit()            // quit with the agent RUNNING: Hibernate, not a cold stop
            guard await sb.phase == .hibernated else { exit(4) }
            exit(0)
        case "agent-crash-restore":
            guard let r = args.dropFirst().first(where: { !$0.hasPrefix("-") && $0 != "agent-crash-restore" }).flatMap(agentImageSpec) else { exit(2) }
            let ws = storeRoot.appendingPathComponent("workspace-\(r.name)")
            let sb = try Sandbox(spec: agentSpec("agent-\(r.name)", imageSpec: r, workspace: ws))
            let log = logEvents(sb)
            try await sb.restoreAfterCrash()
            print("sessions: \(try await sb.sessions())")
            try await sb.shutDown()
            log.cancel()
            print("vmtest: ALL PASS"); exit(0)
        case "restore":
            try await restorePointSuite()
        case "hardening":
            try await hardeningSuite(args.dropFirst().first { !$0.hasPrefix("-") && !$0.hasPrefix("/") })
        case "lineage":
            try await lineageSuite(args.dropFirst().first { !$0.hasPrefix("-") && !$0.hasPrefix("/") })
        case "network":
            try await networkSuite()
        case "net-crash-save":
            exit(try await networkCrashSave())
        case "netdebug":
            // doz-vmtest netdebug --script '<sh>' : a proxied (agent policy) claude-code sandbox; run the script as root; stop.
            guard let i = args.firstIndex(of: "--script"), i + 1 < args.count else { print("netdebug needs --script"); exit(2) }
            let sb = try Sandbox(spec: netSpec("net-debug", policy: .agent))
            try await sb.start()
            let r = try await sb.exec(["sh", "-c", args[i + 1]], privileged: true, timeoutSeconds: 60)
            print(r.output + r.errorOutput)
            for rec in sb.egress?.log.records ?? [] where rec.kind != .http { print("  log \(rec.kind) \(rec.target) \(rec.verdict) \(rec.rule) up=\(rec.bytesUp) down=\(rec.bytesDown) lat=\(rec.latencyMs ?? -1) dur=\(rec.durationMs ?? -1) open=\(rec.open) \(rec.detail ?? "")") }
            try await sb.shutDown()
            try await sb.delete()
            exit(r.exitCode)
        case "agents":
            try await agentSuite(AgentImages.claudeCode)
            try await agentSuite(AgentImages.pi)
        case "agent":
            guard let r = args.dropFirst().first(where: { !$0.hasPrefix("-") && $0 != "agent" }).flatMap(agentImageSpec) else {
                print("usage: doz-vmtest agent claude-code|pi"); exit(2)
            }
            try await agentSuite(r)
        case "netprobe":
            let share = try prepareShare("vmtest")
            let sb = try Sandbox(spec: makeSpec("netprobe", share: share))
            let withSleep = args.contains("--sleep")
            func net(_ label: String) async throws {
                let r = try await sb.exec(["sh", "-c", "ip -4 addr show eth0 | awk '/inet/{print $2}'; for n in 1 2 3; do wget -q -T 3 -O /dev/null http://1.1.1.1 && { echo NET-OK-try$n; exit 0; }; sleep 2; done; echo NET-FAIL"])
                print("\(label): \(r.output.replacingOccurrences(of: "\n", with: " "))")
            }
            for i in 1...6 {
                try await sb.start()
                try await net("cycle \(i) boot")
                if withSleep {
                    try await sb.hibernate(); try await sb.wake()
                    try await net("cycle \(i) after wake")
                }
                try await sb.shutDown()
            }
            try await sb.delete()
            exit(0)
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
        case "cli":
            try await cliSuite()
        case "upgrade":
            try await upgradeSuite()
        case "claude":
            try await claudeSuite()
        case "templates":
            try await templatesSuite()
        case "pullbench":
            try await pullBench()
        case "cli-terminal":
            // 594 (W13): only the terminal-restore part of `cli` (a store of its own).
            let binary = args.firstIndex(of: "--doz").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ".build/debug/doz"
            await cliTerminalRestoreSuite(binary: URL(fileURLWithPath: binary).standardizedFileURL.path)
        case "cli-hoststop":
            // 594 W22: only `doz host stop`'s progress part of `cli` (a store of its own).
            let binary = args.firstIndex(of: "--doz").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ".build/debug/doz"
            await cliHostStopSuite(binary: URL(fileURLWithPath: binary).standardizedFileURL.path)
        case "cli-images":
            // 594 W28–W30: out-of-date images said, never rebuilt by themselves; own hostname; /usr/games.
            let binary = args.firstIndex(of: "--doz").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ".build/debug/doz"
            await cliImagesSuite(binary: URL(fileURLWithPath: binary).standardizedFileURL.path)
        case "cli-clipboard":
            // 599 (594.B1): the clipboard bridge.
            let binary = args.firstIndex(of: "--doz").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ".build/debug/doz"
            await cliClipboardSuite(binary: URL(fileURLWithPath: binary).standardizedFileURL.path)
        case "cli-browser":
            // 599 (594.B2): the browser bridge and a sign-in's callback.
            let binary = args.firstIndex(of: "--doz").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ".build/debug/doz"
            await cliBrowserSuite(binary: URL(fileURLWithPath: binary).standardizedFileURL.path)
        case "cli-github":
            // 599d: GitHub as the user — a fake GitHub, a fake gh, a throwaway ssh-agent (seams only).
            let binary = args.firstIndex(of: "--doz").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ".build/debug/doz"
            await cliGitHubSuite(binary: URL(fileURLWithPath: binary).standardizedFileURL.path)
        case "cli-codex":
            // 599i: Codex — Dozer's own ChatGPT sign-in, the proxy's swap and renewal, an API key (a fake OpenAI).
            let binary = args.firstIndex(of: "--doz").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ".build/debug/doz"
            await cliCodexSuite(binary: URL(fileURLWithPath: binary).standardizedFileURL.path)
        case "cli-tools":
            // 599h: the tools layer — gh, the ssh client + host keys, packages; every base (seams only).
            let binary = args.firstIndex(of: "--doz").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ".build/debug/doz"
            await cliToolsSuite(binary: URL(fileURLWithPath: binary).standardizedFileURL.path)
        case "cli-access":
            // 599e: the Access step — onboarding confirms each credential, skips failures, never blocks (no VM).
            let binary = args.firstIndex(of: "--doz").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ".build/debug/doz"
            await cliAccessSuite(binary: URL(fileURLWithPath: binary).standardizedFileURL.path)
        case "cli-openfiles":
            // 599b: workspace files opened on the Mac (through the opener seam).
            let binary = args.firstIndex(of: "--doz").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ".build/debug/doz"
            await cliOpenFilesSuite(binary: URL(fileURLWithPath: binary).standardizedFileURL.path)
        case "cli-projectwizard":
            // 599f: doz init's steps and the project file — doz up makes what it says.
            let binary = args.firstIndex(of: "--doz").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ".build/debug/doz"
            await cliProjectWizardSuite(binary: URL(fileURLWithPath: binary).standardizedFileURL.path)
        case "cli-quickadd":
            // 599c: doz new — every default, created, started, attached.
            let binary = args.firstIndex(of: "--doz").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ".build/debug/doz"
            await cliQuickAddSuite(binary: URL(fileURLWithPath: binary).standardizedFileURL.path)
        case "cli-tmux":
            // 599 (594.B3): sessions inside tmux.
            let binary = args.firstIndex(of: "--doz").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ".build/debug/doz"
            await cliTmuxSuite(binary: URL(fileURLWithPath: binary).standardizedFileURL.path)
        case "cli-sessions":
            // 608: sessions survive every wake; End / Restart session (SessionsSuite.swift).
            let binary = args.firstIndex(of: "--doz").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ".build/debug/doz"
            await cliSessionsSuite(binary: URL(fileURLWithPath: binary).standardizedFileURL.path)
        case "cli-timezone":
            // 594 W10: the sandbox follows the Mac's time zone at boot and wake.
            let binary = args.firstIndex(of: "--doz").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ".build/debug/doz"
            await cliTimeZoneSuite(binary: URL(fileURLWithPath: binary).standardizedFileURL.path)
        case "cli-points":
            // 594 W25–W27: point names and lookups, check-before-asking, exec starts an off sandbox.
            let binary = args.firstIndex(of: "--doz").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ".build/debug/doz"
            await cliPointsSuite(binary: URL(fileURLWithPath: binary).standardizedFileURL.path)
        case "cli-agentsudo":
            // 594 W23: only the agent-sudo part of `cli` (a store of its own; prepares claude-code).
            let binary = args.firstIndex(of: "--doz").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ".build/debug/doz"
            await cliAgentSudoSuite(binary: URL(fileURLWithPath: binary).standardizedFileURL.path)
        case "cli-bases":
            // 596: base × agent images — cli, dockerfile (a fake container), real (Apple's), matrix
            // (BASES_PARTS=cli,dockerfile,real,matrix; default all).
            let binary = args.firstIndex(of: "--doz").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ".build/debug/doz"
            let parts = Set((ProcessInfo.processInfo.environment["BASES_PARTS"].flatMap { $0.isEmpty ? nil : $0 } ?? "cli,dockerfile,real,matrix")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            await cliBasesSuite(binary: URL(fileURLWithPath: binary).standardizedFileURL.path, parts: parts)
        case "cli-permissions":
            // 597: agent permissions (a store of its own; prepares claude-code; network).
            let binary = args.firstIndex(of: "--doz").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ".build/debug/doz"
            await cliPermissionsSuite(binary: URL(fileURLWithPath: binary).standardizedFileURL.path)
        case "cli-onboarding":
            // 594: only the onboarding part of `cli` (its stores are its own).
            let binary = args.firstIndex(of: "--doz").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ".build/debug/doz"
            await cliOnboardingSuite(binary: URL(fileURLWithPath: binary).standardizedFileURL.path)
        case "ignore":
            // 599g: workspace rules (.dozignore / .dozreadonly) — IgnoreSuite.swift (`make test-vm-ignore`).
            try await ignoreSuite()
        case "cwd-wake":
            // BUG cwd-after-wake: a program's cwd in /workspace across sleep, hibernate and a new-process restore — CwdWakeSuite.swift (`make test-vm-cwd`).
            try await cwdWakeSuite()
        case "cwd-wake-save":
            exit(try await cwdWakeSave())
        case "ignore-crash-save":
            exit(try await ignoreCrashSave())
        case "ignore-crash-restore":
            try await ignoreCrashRestore(label: "crash2", thenQuit: true)
        case "spike-audio":
            // SPIKE (604): the Mac's microphone + speakers as a virtio-snd device — AudioSpike.swift.
            try await audioSpike()
        case "spike-build":
            // SPIKE (604 stage 1b): run a root script in a big throwaway sandbox (the sound kernel's build).
            try await spikeBuild()
        case "spike-audio-live":
            // SPIKE (604 stage 1b): tone, microphone, latency, streams open across the lifecycle (DOZ_KERNEL = a sound kernel).
            try await audioLiveSpike()
        case "spike-audio-live-save":
            exit(try await liveCrashSave())
        case "spike-audio-live-restore":
            try await liveCrashRestore(thenQuit: true)
        case "spike-audio-crash-save":
            exit(try await audCrashSave())
        case "spike-audio-crash-restore":
            try await audCrashRestore(thenQuit: true)
        case "lifecycle":
            try await lifecycleSuite()
        case "crash":
            try await crashSuite()
        case "crash-restore":
            try await crashSuite(skipChild: true)
        default:
            try await lifecycleSuite()
            try await crashSuite()
            try await restorePointSuite()
        }
    } catch {
        print("  FAIL  aborted: \(error.localizedDescription)")
        failures += 1
    }
    print(failures == 0 ? "vmtest: ALL PASS" : "vmtest: \(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
