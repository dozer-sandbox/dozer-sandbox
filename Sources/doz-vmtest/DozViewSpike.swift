// SPIKE (599g) — does an in-guest filtering FUSE view at /workspace survive every lifecycle transition?
//
// Temporary: this is the gating spike for `.dozignore` (workspace changes/599g-*/599g.03-SPIKE.md). It
// becomes the start of the real `ignore` suite (`make test-vm-ignore`) or is removed; it touches no
// library code.
//
//   doz-vmtest spike-dozview --dozview PATH [--store DIR]
//
// PATH is the probe daemon (workspace probes/599g-*/spike/out/dozview, a static aarch64-linux-musl
// binary). The sandbox's share is mounted by the library at /run/doz/raw/work — the PRIVATE raw path of
// the production design — so the library's own wake (`remountShares`) re-binds exactly that path and
// never /workspace; the spike mounts the view at /workspace with a privileged exec (the daemon is copied
// into the guest first, never run from the share it serves) and, after a re-mount, sends it SIGUSR1 (the
// production design does that at the end of remountShares).
//
// Matrix (each transition twice): pause → resume, sleep → wake (resume in place), hibernate → wake
// (same process: restore + re-mount), and the crash pattern — a CHILD process starts a sandbox with the
// view and quits it (prepareForExit = hibernate), a second child restores it (new process), checks and
// quits again, the parent restores it (third process). After each: the full check (lock · hide · read-only
// · ordinary both ways · same daemon pid). After every re-mount a light check runs BEFORE SIGUSR1 too,
// to learn what the daemon's old base fd does.
import Foundation
import DozerKit

let dzvRaw = "/run/doz/raw/work"

func dzvSpec(_ name: String, share: URL) -> SandboxSpec {
    SandboxSpec(name: name, storeRoot: storeRoot, kernelPath: kernelPath, kernelCacheDirectory: kernelCache, cpus: 2, memoryMiB: 512,
                rootfsMiB: 1024, bakePackages: ["bash", "ncurses"],
                shares: [Share(hostPath: share.path, guestPath: dzvRaw)], subnet: testSubnet)
}

/// A fresh tree: an ordinary file, a LOCKED file + dir (.dozignore, lock mode), a HIDDEN file
/// (.dozhide — spike-only, always hide), a READ-ONLY dir (.dozreadonly), and the daemon binary (hidden).
func dzvPrepareShare(_ name: String, dozview: URL) throws -> URL {
    let fm = FileManager.default
    let share = storeRoot.appendingPathComponent("share-\(name)")
    try? fm.removeItem(at: share)
    for d in ["lockdir", "config", ".dzv-bin"] { try fm.createDirectory(at: share.appendingPathComponent(d), withIntermediateDirectories: true) }
    let files: [String: String] = [
        "plain.txt": "plain-v1\n", "macedit.txt": "macedit-0\n", "secret.env": "SECRET=1\n", "lockdir/inner.txt": "inner\n",
        "hidden.key": "HIDDEN\n", "config/app.yaml": "ro: 1\n",
        ".dozignore": "secret.env\nlockdir\n", ".dozhide": "hidden.key\n.dzv-bin\n", ".dozreadonly": "config\n",
    ]
    for (p, s) in files { try s.write(to: share.appendingPathComponent(p), atomically: true, encoding: .utf8) }
    try fm.copyItem(at: dozview, to: share.appendingPathComponent(".dzv-bin/dozview"))
    return share
}

let dzvSetupScript = """
set -e
cp \(dzvRaw)/.dzv-bin/dozview /usr/local/bin/dozview; chmod 755 /usr/local/bin/dozview
chmod 700 /run/doz/raw
mkdir -p /workspace
echo "layout: $(stat -c '%A %U %n' /run/doz /run/doz/raw /workspace | tr '\\n' ' ')"
echo "mounts before: $(grep -E 'virtiofs|/run/doz|/workspace' /proc/self/mountinfo | awk '{print $4" "$5" "$9}' | tr '\\n' ';')"
/usr/local/bin/dozview \(dzvRaw) /workspace --mode=lock --timeout=1
sleep 0.3
echo "pid=$(pidof dozview)"
echo "mounts after: $(grep -E 'virtiofs|/run/doz|/workspace' /proc/self/mountinfo | awk '{print $4" "$5" "$9}' | tr '\\n' ';')"
"""

/// The full check, as root through a NON-privileged exec (the agent's sudo root) and as `nobody`.
/// Prints `key rc=N output` lines.
func dzvCheckScript(_ label: String) -> String {
    """
    W=/workspace
    e() { n=$1; shift; o=$(sh -c "$*" 2>&1); rc=$?; echo "$n rc=$rc $(printf '%s' "$o" | tr '\\n' ' ')"; }
    u() { n=$1; shift; o=$(su nobody -s /bin/sh -c "$*" 2>&1); rc=$?; echo "$n rc=$rc $(printf '%s' "$o" | tr '\\n' ' ')"; }
    e ls "ls -a $W | tr '\\n' ' '"
    e mount "grep -c ' /workspace .* fuse' /proc/self/mountinfo"
    e pid "pidof dozview"
    e lock_mode "stat -c %A $W/secret.env"
    e lock_cat "cat $W/secret.env"
    e lock_write "echo x > $W/secret.env"
    e lock_append "echo x >> $W/secret.env"
    e lock_rm "rm -f $W/secret.env"
    e lock_mv "mv $W/secret.env $W/secret2.env"
    e lock_chmod "chmod 644 $W/secret.env"
    e lock_dir_ls "ls $W/lockdir"
    e lock_dir_cat "cat $W/lockdir/inner.txt"
    e hide_listed "ls -a $W | grep -c '^hidden.key$'"
    e hide_cat "cat $W/hidden.key"
    e hide_stat "stat $W/hidden.key"
    e hide_case "cat $W/HIDDEN.KEY"
    e hide_create "echo x > $W/hidden.key"
    e ro_mode "stat -c %A $W/config/app.yaml"
    e ro_cat "cat $W/config/app.yaml"
    e ro_append "echo x >> $W/config/app.yaml"
    e ro_trunc ": > $W/config/app.yaml"
    e ro_rm "rm -f $W/config/app.yaml"
    e ro_mv "mv $W/config/app.yaml $W/config/b.yaml"
    e ro_new "touch $W/config/new.yaml"
    e ro_chmod "chmod 666 $W/config/app.yaml"
    e ro_dozignore "echo '!secret.env' >> $W/.dozignore"
    e plain_cat "cat $W/plain.txt"
    e plain_write "echo guest-\(label) > $W/guest-\(label).txt && cat $W/guest-\(label).txt"
    e plain_mkdir "mkdir $W/d-\(label) && rmdir $W/d-\(label)"
    e plain_mv "echo mv > $W/mv-\(label).a && mv $W/mv-\(label).a $W/mv-\(label).b && cat $W/mv-\(label).b"
    e mac_new "cat $W/mac-\(label).txt"
    s=$(date +%s%3N 2>/dev/null || echo 0); i=0; while [ $i -lt 100 ]; do grep -q 'macedit-\(label)' $W/macedit.txt 2>/dev/null && break; sleep 0.05; i=$((i+1)); done
    e mac_edit "cat $W/macedit.txt; echo waited-$((i*50))ms"
    u nobody_lock_cat "cat $W/secret.env"
    u nobody_hide_cat "cat $W/hidden.key"
    u nobody_ro_cat "cat $W/config/app.yaml"
    u nobody_ro_append "echo x >> $W/config/app.yaml"
    u nobody_plain_cat "cat $W/plain.txt"
    u nobody_raw "ls /run/doz/raw/work"
    """
}

/// What one check line must say. `pid` is compared to the daemon's pid.
func dzvExpect(_ r: [String: (rc: Int, out: String)], label: String, pid: String, share: URL) -> [(Bool, String)] {
    func has(_ k: String, _ s: String) -> Bool { r[k]?.out.contains(s) ?? false }
    func fail(_ k: String, _ s: String) -> Bool { (r[k]?.rc ?? 0) != 0 && has(k, s) }
    let EACCES = "Permission denied", ENOENT = "No such file", EROFS = "Read-only file system"
    let guestFile = (try? String(contentsOf: share.appendingPathComponent("guest-\(label).txt"), encoding: .utf8)) ?? ""
    let movedFile = FileManager.default.fileExists(atPath: share.appendingPathComponent("mv-\(label).b").path)
    let secret = (try? String(contentsOf: share.appendingPathComponent("secret.env"), encoding: .utf8)) ?? ""
    let ro = (try? String(contentsOf: share.appendingPathComponent("config/app.yaml"), encoding: .utf8)) ?? ""
    let ign = (try? String(contentsOf: share.appendingPathComponent(".dozignore"), encoding: .utf8)) ?? ""
    return [
        (has("mount", "1") && has("pid", pid) && !pid.isEmpty, "view mounted at /workspace, daemon is the SAME pid \(pid) (got \(r["pid"]?.out ?? "?"))"),
        (has("ls", "secret.env") && has("ls", "lockdir") && !has("ls", "hidden.key") && !has("ls", ".dzv-bin") && has("ls", "plain.txt"),
         "listing: locked names listed, hidden names absent (\(r["ls"]?.out ?? "?"))"),
        (has("lock_mode", "----------"), "LOCK: shown as ---------- (\(r["lock_mode"]?.out ?? "?"))"),
        (["lock_cat", "lock_write", "lock_append", "lock_rm", "lock_mv", "lock_chmod", "lock_dir_ls", "lock_dir_cat"].allSatisfy { fail($0, EACCES) },
         "LOCK: read/write/append/rm/mv/chmod, dir list + read inside → EACCES as root" + dzvDetail(r, ["lock_cat", "lock_write", "lock_rm", "lock_mv", "lock_chmod", "lock_dir_ls", "lock_dir_cat"], EACCES)),
        (fail("nobody_lock_cat", EACCES), "LOCK: EACCES as nobody too"),
        (secret == "SECRET=1\n", "LOCK: the Mac's secret.env untouched"),
        (has("hide_listed", "0") && fail("hide_cat", ENOENT) && fail("hide_stat", ENOENT) && fail("hide_case", ENOENT) && fail("nobody_hide_cat", ENOENT),
         "HIDE: not listed; cat/stat (and HIDDEN.KEY) → ENOENT, root and nobody"),
        (fail("hide_create", EACCES), "HIDE: creating the hidden name → EACCES (\(r["hide_create"]?.out ?? "?"))"),
        (has("ro_cat", "ro: 1") && has("nobody_ro_cat", "ro: 1") && !(r["ro_mode"]?.out.contains("w") ?? true),
         "READ-ONLY: readable (root, nobody), no write bits shown (\(r["ro_mode"]?.out ?? "?"))"),
        (["ro_append", "ro_trunc", "ro_rm", "ro_mv", "ro_new", "ro_chmod", "ro_dozignore"].allSatisfy { fail($0, EROFS) },
         "READ-ONLY: append/truncate/rm/mv/new file/chmod, .dozignore append → EROFS as root" + dzvDetail(r, ["ro_append", "ro_trunc", "ro_rm", "ro_mv", "ro_new", "ro_chmod", "ro_dozignore"], EROFS)),
        ((r["nobody_ro_append"]?.rc ?? 0) != 0, "READ-ONLY: nobody's append refused (\(r["nobody_ro_append"]?.out ?? "?"))"),
        (ro == "ro: 1\n" && ign == "secret.env\nlockdir\n",
         "READ-ONLY: the Mac's config/app.yaml and .dozignore untouched"),
        (has("plain_cat", "plain-v1") && has("plain_write", "guest-\(label)") && guestFile == "guest-\(label)\n" && (r["plain_mkdir"]?.rc == 0) && has("plain_mv", "mv") && movedFile,
         "ORDINARY: read, write (the Mac sees guest-\(label).txt), mkdir/rmdir, rename"),
        (has("mac_new", "mac-\(label)"), "ORDINARY: a file the Mac made while parked is seen (\(r["mac_new"]?.out ?? "?"))"),
        (has("mac_edit", "macedit-\(label)"), "ORDINARY: the Mac's in-place edit is seen (\(r["mac_edit"]?.out ?? "?"))"),
        (fail("nobody_raw", EACCES), "the raw share is unreachable for nobody (0700 /run/doz/raw)"),
    ]
}

func dzvDetail(_ r: [String: (rc: Int, out: String)], _ keys: [String], _ want: String) -> String {
    let bad = keys.filter { !((r[$0]?.rc ?? 0) != 0 && (r[$0]?.out.contains(want) ?? false)) }
    return bad.isEmpty ? "" : " — off: " + bad.map { "\($0): \(r[$0]?.out ?? "?")" }.joined(separator: " | ")
}

func dzvParse(_ text: String) -> [String: (rc: Int, out: String)] {
    var d: [String: (rc: Int, out: String)] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[1].hasPrefix("rc=") else { continue }
        d[String(parts[0])] = (Int(parts[1].dropFirst(3)) ?? -1, parts.count > 2 ? String(parts[2]) : "")
    }
    return d
}

/// The Mac's part before a check: a new file and an in-place edit (same inode).
func dzvMacSide(_ share: URL, _ label: String) throws {
    try "mac-\(label)\n".write(to: share.appendingPathComponent("mac-\(label).txt"), atomically: true, encoding: .utf8)
    let h = try FileHandle(forWritingTo: share.appendingPathComponent("macedit.txt"))
    try h.truncate(atOffset: 0); try h.write(contentsOf: Data("macedit-\(label)\n".utf8)); try h.close()
}

@discardableResult
func dzvFullCheck(_ sb: Sandbox, _ label: String, pid: String, share: URL) async throws -> Bool {
    let r = try await sb.exec(["sh", "-c", dzvCheckScript(label)], timeoutSeconds: 60)
    let parsed = dzvParse(r.output)
    var ok = true
    let drops = try await sb.exec(["sh", "-c", "grep -c 'rules: ignore=0' /run/doz/dozview.log"], privileged: true, timeoutSeconds: 20)
    check(drops.output.trimmingCharacters(in: .whitespacesAndNewlines) == "0", "[\(label)] the daemon never dropped its rules (stale base → last rules kept)")
    for (pass, what) in dzvExpect(parsed, label: label, pid: pid, share: share) { check(pass, "[\(label)] " + what); ok = ok && pass }
    if !ok { info("raw check output: \(r.output.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(3000)) \(r.errorOutput.prefix(300))") }
    return ok
}

/// After a re-mount, BEFORE SIGUSR1: what does the old base fd do? (informative, never a FAIL)
func dzvPreSignal(_ sb: Sandbox, _ label: String) async throws -> String {
    let s = """
    W=/workspace
    e() { n=$1; shift; o=$(sh -c "$*" 2>&1); rc=$?; printf '%s rc=%s %s · ' "$n" "$rc" "$(printf '%s' "$o" | tr '\\n' ' ' | cut -c1-80)"; }
    e ls "ls $W | head -3 | tr '\\n' ' '"; e cat "cat $W/plain.txt"; e new "cat $W/mac-pre-\(label).txt"; e write "echo pre > $W/pre-\(label).txt"
    e lock "cat $W/secret.env"; e hide "cat $W/hidden.key"; e ro "echo x >> $W/config/app.yaml"
    e fd "ls -l /proc/$(pidof dozview)/fd 2>/dev/null | grep -c raw"
    """
    let r = try await sb.exec(["sh", "-c", s], privileged: true, timeoutSeconds: 30)
    return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
}

func dzvSignal(_ sb: Sandbox) async throws -> String {
    let r = try await sb.exec(["sh", "-c", "kill -USR1 $(pidof dozview) && sleep 0.2 && kill -USR2 $(pidof dozview) && sleep 0.1 && tail -4 /run/doz/dozview.log"],
                              privileged: true, timeoutSeconds: 30)
    return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
}

func dzvSetup(_ sb: Sandbox) async throws -> String {
    let r = try await sb.exec(["sh", "-c", dzvSetupScript], privileged: true, timeoutSeconds: 60)
    for l in r.output.split(separator: "\n") { info(String(l)) }
    if r.exitCode != 0 { info("setup failed \(r.exitCode): \(r.errorOutput)") }
    return r.output.split(separator: "\n").first { $0.hasPrefix("pid=") }.map { String($0.dropFirst(4)) } ?? ""
}

func dzvLog(_ sb: Sandbox) async -> String {
    ((try? await sb.exec(["sh", "-c", "tail -12 /run/doz/dozview.log"], privileged: true, timeoutSeconds: 20))?.output ?? "?")
}

func dozViewSpike(dozview: URL) async throws {
    let share = try dzvPrepareShare("dzv", dozview: dozview)
    let sb = try Sandbox(spec: dzvSpec("dzv", share: share))
    let log = logEvents(sb)
    defer { log.cancel() }
    if await sb.phase != .off { try? await sb.shutDown() }
    print("spike: start")
    try await sb.start()

    // Wake cost WITHOUT a view first (the same sandbox, same share), so the comparison is fair.
    var plain: [Double] = []
    for i in 1...2 {
        try dzvMacSide(share, "base\(i)")
        try await sb.hibernate()
        let t = Date(); try await sb.wake(); plain.append(Date().timeIntervalSince(t) * 1000)
        check(await sb.phase == .running, String(format: "baseline (no view) hibernate → wake %d: %.0f ms", i, plain.last!))
    }

    print("spike: mount the view")
    let pid = try await dzvSetup(sb)
    check(!pid.isEmpty, "the daemon runs after the privileged exec that started it ended (pid \(pid))")
    try dzvMacSide(share, "boot")
    try await dzvFullCheck(sb, "boot", pid: pid, share: share)

    var timings: [String: [Double]] = [:]
    for cycle in 1...2 {
        print("spike: pause → resume (\(cycle))")
        try dzvMacSide(share, "pause\(cycle)")
        try await sb.pause()
        var t = Date(); try await sb.resume(); timings["pause→resume", default: []].append(Date().timeIntervalSince(t) * 1000)
        try await dzvFullCheck(sb, "pause\(cycle)", pid: pid, share: share)

        print("spike: sleep → wake (\(cycle))")
        try dzvMacSide(share, "sleep\(cycle)")
        try await sb.sleep()
        t = Date(); try await sb.wake(); timings["sleep→wake", default: []].append(Date().timeIntervalSince(t) * 1000)
        try await dzvFullCheck(sb, "sleep\(cycle)", pid: pid, share: share)

        print("spike: hibernate → wake, same process (\(cycle))")
        try dzvMacSide(share, "hib\(cycle)")
        try "pre\n".write(to: share.appendingPathComponent("mac-pre-hib\(cycle).txt"), atomically: true, encoding: .utf8)
        // Informative: a file held OPEN across the hibernation, through the view and on the raw share.
        let hold = "exec 3</workspace/plain.txt 4<\(dzvRaw)/plain.txt; while [ ! -e /tmp/go-\(cycle) ]; do sleep 0.1; done; "
            + "{ echo \"view: $(cat <&3 2>&1)\"; echo \"raw: $(cat <&4 2>&1)\"; } > /tmp/held-\(cycle).out"
        _ = try await sb.exec(["sh", "-c", "setsid sh -c '\(hold)' >/dev/null 2>&1 < /dev/null &"], privileged: true, timeoutSeconds: 20)
        await sleepS(0.5)
        try await sb.hibernate()
        t = Date(); try await sb.wake(); timings["hibernate→wake (view)", default: []].append(Date().timeIntervalSince(t) * 1000)
        info("BEFORE SIGUSR1: " + (try await dzvPreSignal(sb, "hib\(cycle)")))
        info("SIGUSR1: " + (try await dzvSignal(sb)).replacingOccurrences(of: "\n", with: " ⏎ "))
        let held = try await sb.exec(["sh", "-c", "touch /tmp/go-\(cycle); sleep 0.5; cat /tmp/held-\(cycle).out 2>&1"], privileged: true, timeoutSeconds: 20)
        info("held open across the hibernation: " + held.output.replacingOccurrences(of: "\n", with: " · "))
        try await dzvFullCheck(sb, "hib\(cycle)", pid: pid, share: share)
    }
    timings["hibernate→wake (no view)"] = plain
    for (k, v) in timings.sorted(by: { $0.key < $1.key }) { info("\(k): " + v.map { String(format: "%.0f ms", $0) }.joined(separator: ", ")) }
    info("daemon log: " + (await dzvLog(sb)).replacingOccurrences(of: "\n", with: " ⏎ "))
    try await sb.shutDown()
    try await sb.delete()

    // The crash pattern: three processes.
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    for (n, child) in [("1", "spike-dozview-crash-save"), ("2", "spike-dozview-crash-restore")] {
        print("spike: crash pattern — child process \(n) (\(child))")
        let p = Process(); p.executableURL = exe
        p.arguments = [child, "--store", storeRoot.path, "--dozview", dozview.path]
        try p.run(); p.waitUntilExit()
        check(p.terminationStatus == 0, "child \(n) (\(child)) exited 0 (\(p.terminationStatus))")
    }
    print("spike: crash pattern — the parent restores (third process)")
    try await dzvCrashRestore(label: "crash3", thenQuit: false)
}

/// Child 1: start a sandbox with the view, check, quit like a host (Hibernate), exit WITHOUT stopping.
func dzvCrashSave(dozview: URL) async throws -> Int32 {
    let share = try dzvPrepareShare("dzv-crash", dozview: dozview)
    let sb = try Sandbox(spec: dzvSpec("dzv-crash", share: share))
    let log = logEvents(sb, prefix: "[child] ")
    try await sb.start()
    let pid = try await dzvSetup(sb)
    try "\(pid)".write(to: storeRoot.appendingPathComponent("dzv-crash-pid.txt"), atomically: true, encoding: .utf8)
    try dzvMacSide(share, "crash0")
    try await dzvFullCheck(sb, "crash0", pid: pid, share: share)
    await sb.prepareForExit()
    log.cancel()
    print("        · [child] quit with the view's daemon \(pid) → \(await sb.phase.label)")
    let parked = await sb.phase == .hibernated
    return failures == 0 && parked ? 0 : 1
}

/// A restore in a NEW process (child 2: then quit again; the parent: then shut down + delete).
func dzvCrashRestore(label: String, thenQuit: Bool) async throws {
    let share = storeRoot.appendingPathComponent("share-dzv-crash")
    let spec = dzvSpec("dzv-crash", share: share)
    check(Sandbox.restorableState(for: spec) != nil, "[\(label)] a new process sees a restorable sandbox")
    let pid = ((try? String(contentsOf: storeRoot.appendingPathComponent("dzv-crash-pid.txt"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    try dzvMacSide(share, label)
    try "pre\n".write(to: share.appendingPathComponent("mac-pre-\(label).txt"), atomically: true, encoding: .utf8)
    let sb = try Sandbox(spec: spec)
    let log = logEvents(sb)
    defer { log.cancel() }
    let t = Date()
    try await sb.wake()
    check(await sb.phase == .running, String(format: "[\(label)] restored into a new process in %.0f ms", Date().timeIntervalSince(t) * 1000))
    info("[\(label)] BEFORE SIGUSR1: " + (try await dzvPreSignal(sb, label)))
    info("[\(label)] SIGUSR1: " + (try await dzvSignal(sb)).replacingOccurrences(of: "\n", with: " ⏎ "))
    try await dzvFullCheck(sb, label, pid: pid, share: share)
    if thenQuit {
        await sb.prepareForExit()
        check(await sb.phase == .hibernated, "[\(label)] quit again (hibernated) for the next process")
    } else {
        info("daemon log: " + (await dzvLog(sb)).replacingOccurrences(of: "\n", with: " ⏎ "))
        try await sb.shutDown()
        try await sb.delete()
    }
}

func dzvBinaryArg() -> URL {
    guard let i = args.firstIndex(of: "--dozview"), i + 1 < args.count else { print("spike-dozview needs --dozview PATH"); exit(2) }
    return URL(fileURLWithPath: args[i + 1])
}
