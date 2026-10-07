// `doz-vmtest ignore` (`make test-vm-ignore`) — workspace rules (.dozignore / .dozreadonly) in real VMs,
// through the LIBRARY as the host drives it: the share at /workspace, the view started by the boot itself,
// the wake's re-mount re-binding the private raw path and signalling the daemon, the session-time refresh.
// Evolved from the 599g lifecycle spike (workspace changes/599g-*/599g.03-SPIKE.md), whose matrix it keeps:
//
//   boot · pause→resume ×2 · sleep→wake ×2 · hibernate→wake ×2 · a restore by a NEW process (child 1
//   saves, child 2 restores + checks + quits, the parent restores — three processes)
//
// and after EACH: lock (as root and as nobody), hide (the mode switched live, then back), read-only
// (.dozreadonly, the implicit doz_project.yaml and .git/hooks, the rule files themselves), ordinary files
// both ways (the Mac's new file and in-place edit seen; the guest's write on the Mac), the raw share
// private, the same supervisor, the daemon never dropping its rules, case and Unicode folding. Then: live
// reload (a Mac edit of .dozignore, timed), a directory rename that would defeat an anchored rule, hard
// links, a killed worker restarted, a killed supervisor restarted at the next wake, no rule file → no
// daemon, a rule file appearing (at a session start and while hibernated), and the view's cost.
import Foundation
import DozerKit

let ignoreSandbox = "ign-a"

func ignoreSpec(_ name: String, share: URL, subnet: String? = testSubnet) -> SandboxSpec {
    SandboxSpec(name: name, storeRoot: storeRoot, kernelPath: kernelPath, kernelCacheDirectory: kernelCache, cpus: 2, memoryMiB: 512,
                rootfsMiB: 1024, bakePackages: ["bash", "ncurses"],
                shares: [Share(hostPath: share.path, guestPath: "/workspace")], subnet: subnet)
}

/// A fresh tree with rules. Returns the folder.
func ignorePrepareShare(_ name: String, rules: Bool = true) throws -> URL {
    let fm = FileManager.default
    let share = storeRoot.appendingPathComponent("share-\(name)")
    try? fm.removeItem(at: share)
    for d in ["lockdir", "config", "keys/sub", "logs", "nest", ".git/hooks", "bench"] {
        try fm.createDirectory(at: share.appendingPathComponent(d), withIntermediateDirectories: true)
    }
    var files: [String: String] = [
        "plain.txt": "plain-v1\n", "macedit.txt": "macedit-0\n", "secret.env": "SECRET=1\n", "lockdir/inner.txt": "inner\n",
        "keys/a.key": "KEY-A\n", "keys/sub/b.key": "KEY-B\n", "keys/readme.txt": "keys readme\n",
        "logs/keep.txt": "keep\n", "logs/other.log": "other\n", "nest/inner.secret": "NEST\n", "nest/ok.txt": "nest ok\n",
        "config/app.yaml": "ro: 1\n", "doz_project.yaml": "version: 1\n", ".git/hooks/pre-commit": "#!/bin/sh\n",
        "caf\u{E9}.env": "CAFE\n",
    ]
    if rules {
        files[".dozignore"] = ignoreRules
        files[".dozreadonly"] = "config\n"
    }
    for (p, s) in files { try s.write(to: share.appendingPathComponent(p), atomically: true, encoding: .utf8) }
    for i in 0..<2000 { try "f\(i)\n".write(to: share.appendingPathComponent("bench/f\(i).txt"), atomically: false, encoding: .utf8) }
    return share
}

/// The rules: a file, a folder, a pattern at any depth, a folder an exception re-includes from, an
/// ANCHORED path (a rename of its folder must not defeat it), and one written in NFD (the file is NFC).
let ignoreRules = "# test rules\nsecret.env\nlockdir\n**/*.key\nlogs\n!logs/keep.txt\nnest/inner.secret\ncafe\u{301}.env\n"

/// Everything the guest is asked after a transition, as root (a NON-privileged exec: the agent's sudo root)
/// and as nobody. `key rc=N output` lines.
func ignoreCheckScript(_ label: String, tag: String) -> String {
    """
    W=/workspace
    e() { n=$1; shift; o=$(sh -c "$*" 2>&1); rc=$?; echo "$n rc=$rc $(printf '%s' "$o" | tr '\\n' ' ')"; }
    u() { n=$1; shift; o=$(su nobody -s /bin/sh -c "$*" 2>&1); rc=$?; echo "$n rc=$rc $(printf '%s' "$o" | tr '\\n' ' ')"; }
    e ls "ls -a $W | tr '\\n' ' '"
    e mount "grep -c ' /workspace fuse.dozview ' /proc/mounts"
    e sv "cat \(WorkspaceView.pidPath(tag))"
    e lock_mode "stat -c %A $W/secret.env"
    e lock_cat "cat $W/secret.env"
    e lock_write "echo x > $W/secret.env"
    e lock_append "echo x >> $W/secret.env"
    e lock_rm "rm -f $W/secret.env"
    e lock_mv "mv $W/secret.env $W/secret2.env"
    e lock_chmod "chmod 644 $W/secret.env"
    e lock_dir_ls "ls $W/lockdir"
    e lock_dir_cat "cat $W/lockdir/inner.txt"
    e lock_deep "cat $W/keys/sub/b.key"
    e lock_new_key "touch $W/keys/new.key"
    e lock_case "cat $W/SECRET.ENV"
    e lock_case_dir "cat $W/LOCKDIR/inner.txt"
    e lock_nfd "cat $W/café.env"
    e lock_ln "ln $W/secret.env $W/s-link"
    e skel_ls "ls $W/logs | tr '\\n' ' '"
    e skel_keep "cat $W/logs/keep.txt"
    e skel_other "cat $W/logs/other.log"
    e keys_readme "cat $W/keys/readme.txt"
    e nest_cat "cat $W/nest/inner.secret"
    e nest_ok "cat $W/nest/ok.txt"
    e nest_mv "mv $W/nest $W/nest2"
    e ro_mode "stat -c %A $W/config/app.yaml"
    e ro_cat "cat $W/config/app.yaml"
    e ro_append "echo x >> $W/config/app.yaml"
    e ro_trunc ": > $W/config/app.yaml"
    e ro_rm "rm -f $W/config/app.yaml"
    e ro_mv "mv $W/config/app.yaml $W/config/b.yaml"
    e ro_new "touch $W/config/new.yaml"
    e ro_chmod "chmod 666 $W/config/app.yaml"
    e ro_dirmv "mv $W/config $W/cfg"
    e ro_ln "ln $W/config/app.yaml $W/app-link"
    e ro_dozignore "echo '!secret.env' >> $W/.dozignore"
    e ro_dozreadonly "rm -f $W/.dozreadonly"
    e ro_project "echo x >> $W/doz_project.yaml"
    e ro_hook "echo x >> $W/.git/hooks/pre-commit"
    e ro_hook_new "touch $W/.git/hooks/post-commit"
    e plain_cat "cat $W/plain.txt"
    e plain_write "echo guest-\(label) > $W/guest-\(label).txt && cat $W/guest-\(label).txt"
    e plain_mkdir "mkdir $W/d-\(label) && touch $W/d-\(label)/x && rm $W/d-\(label)/x && rmdir $W/d-\(label)"
    e plain_mv "echo mv > $W/mv-\(label).a && mv $W/mv-\(label).a $W/mv-\(label).b && cat $W/mv-\(label).b"
    e mac_new "cat $W/mac-\(label).txt"
    i=0; while [ $i -lt 100 ]; do grep -q 'macedit-\(label)' $W/macedit.txt 2>/dev/null && break; sleep 0.05; i=$((i+1)); done
    e mac_edit "cat $W/macedit.txt; echo waited-$((i*50))ms"
    u nobody_lock_cat "cat $W/secret.env"
    u nobody_ro_cat "cat $W/config/app.yaml"
    u nobody_ro_append "echo x >> $W/config/app.yaml"
    u nobody_plain_cat "cat $W/plain.txt"
    u nobody_raw "ls \(WorkspaceView.rawPath(tag))"
    e dropped "grep -c '.dozignore absent' \(WorkspaceView.logPath(tag))"
    """
}

/// The HIDE half (the mode switched live).
func ignoreHideScript() -> String {
    """
    W=/workspace
    e() { n=$1; shift; o=$(sh -c "$*" 2>&1); rc=$?; echo "$n rc=$rc $(printf '%s' "$o" | tr '\\n' ' ')"; }
    u() { n=$1; shift; o=$(su nobody -s /bin/sh -c "$*" 2>&1); rc=$?; echo "$n rc=$rc $(printf '%s' "$o" | tr '\\n' ' ')"; }
    e ls "ls -a $W | tr '\\n' ' '"
    e hide_cat "cat $W/secret.env"
    e hide_stat "stat $W/secret.env"
    e hide_case "cat $W/SECRET.ENV"
    e hide_dir "ls $W/lockdir"
    e hide_deep "cat $W/keys/sub/b.key"
    e hide_keys_ls "ls $W/keys/sub | tr '\\n' ' '"
    e hide_create "echo x > $W/secret.env"
    e hide_skel "ls $W/logs | tr '\\n' ' '"
    u nobody_hide_cat "cat $W/secret.env"
    e ro_append "echo x >> $W/config/app.yaml"
    e plain_cat "cat $W/plain.txt"
    """
}

typealias IgnoreResults = [String: (rc: Int, out: String)]

func ignoreParse(_ text: String) -> IgnoreResults {
    var d: IgnoreResults = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[1].hasPrefix("rc=") else { continue }
        d[String(parts[0])] = (Int(parts[1].dropFirst(3)) ?? -1, parts.count > 2 ? String(parts[2]) : "")
    }
    return d
}

let EACCES = "Permission denied", ENOENT = "No such file", EROFS = "Read-only file system"

/// `ls -a /workspace`'s names (space-separated) hold both "." and ".." (the share's root answered "."
/// alone, so the view's root listed one where every subfolder lists two).
func rootListsDots(_ out: String?) -> Bool {
    let names = Set((out ?? "").split(separator: " ").map(String.init))
    return names.contains(".") && names.contains("..")
}

func ignoreExpectLock(_ r: IgnoreResults, label: String, supervisor: String, share: URL) -> [(Bool, String)] {
    func has(_ k: String, _ s: String) -> Bool { r[k]?.out.contains(s) ?? false }
    func fail(_ k: String, _ s: String) -> Bool { (r[k]?.rc ?? 0) != 0 && has(k, s) }
    func ok(_ k: String) -> Bool { r[k]?.rc == 0 }
    func allFail(_ ks: [String], _ s: String) -> (Bool, String) {
        let bad = ks.filter { !fail($0, s) }
        return (bad.isEmpty, bad.isEmpty ? "" : " — off: " + bad.map { "\($0): rc=\(r[$0]?.rc ?? -9) \(r[$0]?.out ?? "?")" }.joined(separator: " | "))
    }
    let file = { (p: String) in (try? String(contentsOf: share.appendingPathComponent(p), encoding: .utf8)) ?? "" }
    let lock = allFail(["lock_cat", "lock_write", "lock_append", "lock_rm", "lock_mv", "lock_chmod", "lock_dir_ls", "lock_dir_cat",
                        "lock_deep", "lock_new_key", "lock_case", "lock_case_dir", "lock_nfd", "lock_ln", "skel_other", "nest_cat"], EACCES)
    let ro = allFail(["ro_append", "ro_trunc", "ro_rm", "ro_mv", "ro_new", "ro_chmod", "ro_dirmv", "ro_ln", "ro_dozignore", "ro_dozreadonly",
                      "ro_project", "ro_hook", "ro_hook_new"], EROFS)
    return [
        (has("mount", "1") && has("sv", supervisor) && !supervisor.isEmpty, "the view is mounted at /workspace, the SAME supervisor \(supervisor) (got \(r["sv"]?.out ?? "?"))"),
        (has("ls", "secret.env") && has("ls", "lockdir") && has("ls", "logs") && has("ls", "plain.txt") && has("ls", ".dozignore"),
         "LOCK: selected names stay listed (\(r["ls"]?.out.prefix(160) ?? "?"))"),
        (rootListsDots(r["ls"]?.out), "the view's root lists . and .. like every folder (\(r["ls"]?.out.prefix(40) ?? "?"))"),
        (has("lock_mode", "----------"), "LOCK: shown as ---------- (\(r["lock_mode"]?.out ?? "?"))"),
        (lock.0, "LOCK: read/write/append/rm/mv/chmod/link, a locked folder listed or read inside, **/*.key at depth, a new *.key, SECRET.ENV and LOCKDIR (case folded), café.env (NFC file, NFD rule) → EACCES as root" + lock.1),
        (fail("nobody_lock_cat", EACCES), "LOCK: EACCES as nobody too"),
        (file("secret.env") == "SECRET=1\n" && file("lockdir/inner.txt") == "inner\n", "LOCK: the Mac's files untouched"),
        (has("skel_ls", "keep.txt") && has("skel_keep", "keep") && ok("keys_readme") && ok("nest_ok"),
         "an exception re-includes inside a selected folder (logs/keep.txt readable, logs listed); unselected neighbours readable"),
        (fail("nest_mv", EACCES), "a folder whose rename would defeat an anchored rule (nest/inner.secret) cannot be renamed (\(r["nest_mv"]?.out ?? "?"))"),
        (has("ro_cat", "ro: 1") && has("nobody_ro_cat", "ro: 1") && !(r["ro_mode"]?.out.contains("w") ?? true),
         "READ-ONLY: readable (root, nobody), no write bits shown (\(r["ro_mode"]?.out ?? "?"))"),
        (ro.0, "READ-ONLY: append/truncate/rm/mv/new/chmod/folder rename/link in config/, .dozignore, .dozreadonly, doz_project.yaml, .git/hooks → EROFS as root" + ro.1),
        ((r["nobody_ro_append"]?.rc ?? 0) != 0, "READ-ONLY: nobody's append refused (\(r["nobody_ro_append"]?.out ?? "?"))"),
        (file("config/app.yaml") == "ro: 1\n" && file(".dozignore") == ignoreRules && file("doz_project.yaml") == "version: 1\n",
         "READ-ONLY: the Mac's config/app.yaml, .dozignore, doz_project.yaml untouched"),
        (has("plain_cat", "plain-v1") && has("plain_write", "guest-\(label)") && file("guest-\(label).txt") == "guest-\(label)\n"
            && ok("plain_mkdir") && has("plain_mv", "mv") && FileManager.default.fileExists(atPath: share.appendingPathComponent("mv-\(label).b").path),
         "ORDINARY: read, write (the Mac sees guest-\(label).txt), mkdir/rmdir, rename"),
        (has("mac_new", "mac-\(label)"), "ORDINARY: a file the Mac made meanwhile is seen (\(r["mac_new"]?.out ?? "?"))"),
        (has("mac_edit", "macedit-\(label)"), "ORDINARY: the Mac's in-place edit is seen (\(r["mac_edit"]?.out ?? "?"))"),
        (has("nobody_plain_cat", "plain-v1"), "ORDINARY: nobody reads an ordinary file"),
        (fail("nobody_raw", EACCES), "the raw share is unreachable for nobody (0700 /run/doz/raw)"),
        (r["dropped"]?.out.trimmingCharacters(in: .whitespaces) == "0", "the daemon never dropped its rules (a dead link keeps the last rules)"),
    ]
}

func ignoreExpectHide(_ r: IgnoreResults) -> [(Bool, String)] {
    func has(_ k: String, _ s: String) -> Bool { r[k]?.out.contains(s) ?? false }
    func fail(_ k: String, _ s: String) -> Bool { (r[k]?.rc ?? 0) != 0 && has(k, s) }
    let hidden = ["hide_cat", "hide_stat", "hide_case", "hide_dir", "hide_deep", "nobody_hide_cat"].filter { !fail($0, ENOENT) }
    return [
        (rootListsDots(r["ls"]?.out), "HIDE: the view's root still lists . and .."),
        (!has("ls", "secret.env") && !has("ls", "lockdir") && has("ls", "plain.txt") && has("ls", "logs"), "HIDE: selected names are not listed (\(r["ls"]?.out.prefix(160) ?? "?"))"),
        (hidden.isEmpty, "HIDE: cat/stat (and SECRET.ENV), a hidden folder, **/*.key at depth → ENOENT, root and nobody" + (hidden.isEmpty ? "" : " — off: \(hidden.map { "\($0): \(r[$0]?.out ?? "?")" })")),
        (!has("hide_keys_ls", "b.key"), "HIDE: a hidden file is not listed in its folder (\(r["hide_keys_ls"]?.out ?? "?"))"),
        (fail("hide_create", EACCES), "HIDE: creating the hidden name → EACCES (\(r["hide_create"]?.out ?? "?"))"),
        (has("hide_skel", "keep.txt") && !has("hide_skel", "other.log"), "HIDE: the re-included logs/keep.txt shows, logs/other.log does not (\(r["hide_skel"]?.out ?? "?"))"),
        (fail("ro_append", EROFS) && has("plain_cat", "plain-v1"), "HIDE: read-only and ordinary files as before"),
    ]
}

func ignoreMacSide(_ share: URL, _ label: String) throws {
    try "mac-\(label)\n".write(to: share.appendingPathComponent("mac-\(label).txt"), atomically: true, encoding: .utf8)
    let h = try FileHandle(forWritingTo: share.appendingPathComponent("macedit.txt"))
    try h.truncate(atOffset: 0); try h.write(contentsOf: Data("macedit-\(label)\n".utf8)); try h.close()
}

func ignoreTag(_ sb: Sandbox) -> String { sb.activeViews.first?.key ?? "?" }

func ignoreSupervisor(_ sb: Sandbox) async -> String {
    let r = try? await sb.exec(["sh", "-c", "cat \(WorkspaceView.pidPath(ignoreTag(sb)))"], privileged: true, timeoutSeconds: 15)
    return (r?.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

func ignoreSetMode(_ sb: Sandbox, _ mode: WorkspaceRuleMode) async {
    sb.setWorkspaceRuleMode(mode)
    await sb.refreshWorkspaceViews()
    await sleepS(0.3)
}

@discardableResult
func ignoreFullCheck(_ sb: Sandbox, _ label: String, supervisor: String, share: URL) async throws -> Bool {
    let tag = ignoreTag(sb)
    try ignoreMacSide(share, label)
    let r = try await sb.exec(["sh", "-c", ignoreCheckScript(label, tag: tag)], timeoutSeconds: 90)
    var ok = true
    for (pass, what) in ignoreExpectLock(ignoreParse(r.output), label: label, supervisor: supervisor, share: share) { check(pass, "[\(label)] " + what); ok = ok && pass }
    if !ok { info("raw output: \(r.output.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(4000)) \(r.errorOutput.prefix(300))") }
    await ignoreSetMode(sb, .hide)
    let h = try await sb.exec(["sh", "-c", ignoreHideScript()], timeoutSeconds: 60)
    var hok = true
    for (pass, what) in ignoreExpectHide(ignoreParse(h.output)) { check(pass, "[\(label)] " + what); hok = hok && pass }
    if !hok { info("raw output: \(h.output.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(2000))") }
    await ignoreSetMode(sb, .lock)
    let back = try await sb.exec(["sh", "-c", "stat -c %A /workspace/secret.env"], timeoutSeconds: 15)
    check(back.output.contains("----------"), "[\(label)] the mode switched back to lock live")
    return ok && hok
}

func ignoreLog(_ sb: Sandbox) async -> String {
    ((try? await sb.exec(["sh", "-c", "tail -15 \(WorkspaceView.logPath(ignoreTag(sb)))"], privileged: true, timeoutSeconds: 20))?.output ?? "?")
        .replacingOccurrences(of: "\n", with: " ⏎ ")
}

func ignoreSuite() async throws {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    print("ignore: the binary — \(DozviewBinary.locate()?.path ?? "MISSING")")
    check(DozviewBinary.locate() != nil, "the dozview guest binary is in the resource bundle")

    // ── A: the matrix ────────────────────────────────────────────────────────────────────────────
    let share = try ignorePrepareShare(ignoreSandbox)
    let sb = try Sandbox(spec: ignoreSpec(ignoreSandbox, share: share))
    let log = logEvents(sb)
    defer { log.cancel() }
    try? await sb.delete()
    print("ignore: boot (the rules are there: the boot serves /workspace through the view)")
    try await sb.start()
    check(!sb.activeViews.isEmpty && sb.viewedGuestPaths == ["/workspace"], "the boot started the view of /workspace (\(sb.activeViews.keys.sorted()))")
    let supervisor = await ignoreSupervisor(sb)
    check(!supervisor.isEmpty, "the supervisor runs after the boot's exec ended (pid \(supervisor))")
    try await ignoreFullCheck(sb, "boot", supervisor: supervisor, share: share)

    // live reload: a Mac edit of .dozignore, timed; then undone.
    try "two\n".write(to: share.appendingPathComponent("plain2.txt"), atomically: true, encoding: .utf8)
    let poll = { (want: String) in
        "i=0; while [ $i -lt 100 ]; do m=$(stat -c %A /workspace/plain2.txt 2>&1); case \"$m\" in \(want)) break;; esac; sleep 0.05; i=$((i+1)); done; echo \"$m $((i*50))\""
    }
    var t = Date()
    try (ignoreRules + "plain2.txt\n").write(to: share.appendingPathComponent(".dozignore"), atomically: true, encoding: .utf8)
    var r = try await sb.exec(["sh", "-c", poll("----------")], timeoutSeconds: 30)
    let addMs = Date().timeIntervalSince(t) * 1000
    check(r.output.hasPrefix("----------") && addMs < 3000, String(format: "live reload: a line added on the Mac locks plain2.txt in %.0f ms (%@)", addMs, r.output.trimmingCharacters(in: .whitespacesAndNewlines)))
    t = Date()
    try ignoreRules.write(to: share.appendingPathComponent(".dozignore"), atomically: true, encoding: .utf8)
    r = try await sb.exec(["sh", "-c", poll("-rw*")], timeoutSeconds: 30)
    let remMs = Date().timeIntervalSince(t) * 1000
    check(r.output.hasPrefix("-rw") && remMs < 3000, String(format: "live reload: the line removed unlocks it in %.0f ms (%@)", remMs, r.output.trimmingCharacters(in: .whitespacesAndNewlines)))

    // the cost: the view against the raw share, as root
    let tag = ignoreTag(sb)
    let bench = """
    t() { local s=$EPOCHREALTIME; "$@" >/dev/null 2>&1; local e=$EPOCHREALTIME; awk -v s="$s" -v e="$e" 'BEGIN { printf "%.0f", (e - s) * 1000 }'; }
    for p in /workspace/bench \(WorkspaceView.rawPath(tag))/bench; do
      f1=$(t find $p); f2=$(t find $p); c=$(t sh -c "cat $p/* > /dev/null"); s=$(t sh -c "ls $p | head -1000 | sed 's#^#'$p'/#' | xargs stat -c %s")
      pa=$(t sh -c "ls $p | sed 's#^#'$p'/#' | xargs -P 8 -n 100 stat -c %s")
      echo "$p find=$f1/$f2 cat-all=$c stat-1000=$s parallel-stat-2000=$pa"
    done
    """
    let b = try await sb.exec(["bash", "-c", bench], privileged: true, timeoutSeconds: 300)
    info("cost (ms; 2000 files): " + b.output.replacingOccurrences(of: "\n", with: " | "))

    var timings: [String: [Double]] = [:]
    for cycle in 1...2 {
        print("ignore: pause → resume (\(cycle))")
        try await sb.pause()
        t = Date(); try await sb.resume(); timings["pause→resume", default: []].append(Date().timeIntervalSince(t) * 1000)
        try await ignoreFullCheck(sb, "pause\(cycle)", supervisor: supervisor, share: share)

        print("ignore: sleep → wake (\(cycle))")
        try await sb.sleep()
        t = Date(); try await sb.wake(); timings["sleep→wake", default: []].append(Date().timeIntervalSince(t) * 1000)
        try await ignoreFullCheck(sb, "sleep\(cycle)", supervisor: supervisor, share: share)

        print("ignore: hibernate → wake, same process (\(cycle))")
        // a file held OPEN through the view across the hibernation: the view re-opens it by path
        _ = try await sb.exec(["sh", "-c", "setsid sh -c 'exec 3</workspace/plain.txt; while [ ! -e /tmp/go-\(cycle) ]; do sleep 0.1; done; cat <&3 > /tmp/held-\(cycle).out 2>&1' >/dev/null 2>&1 </dev/null &"],
                              privileged: true, timeoutSeconds: 20)
        await sleepS(0.4)
        try await sb.hibernate()
        try "pre\n".write(to: share.appendingPathComponent("mac-hib-pre\(cycle).txt"), atomically: true, encoding: .utf8)
        t = Date(); try await sb.wake(); timings["hibernate→wake", default: []].append(Date().timeIntervalSince(t) * 1000)
        let first = try await sb.exec(["sh", "-c", "ls /workspace >/dev/null && cat /workspace/mac-hib-pre\(cycle).txt"], timeoutSeconds: 20)
        check(first.exitCode == 0 && first.output.contains("pre"), "[hib\(cycle)] the FIRST request after the wake succeeds (the wake signalled the daemon in its re-mount)")
        let held = try await sb.exec(["sh", "-c", "touch /tmp/go-\(cycle); sleep 0.5; cat /tmp/held-\(cycle).out"], privileged: true, timeoutSeconds: 20)
        check(held.output.contains("plain-v1"),
              "[hib\(cycle)] a file held open through the view across the hibernation still reads (the view re-opens it by path; raw virtio-fs fails it): \(held.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        try await ignoreFullCheck(sb, "hib\(cycle)", supervisor: supervisor, share: share)
    }
    for (k, v) in timings.sorted(by: { $0.key < $1.key }) { info("\(k): " + v.map { String(format: "%.0f ms", $0) }.joined(separator: ", ")) }

    // a killed worker: the supervisor serves on (same connection); root's cwd at /workspace keeps working
    print("ignore: kill -9 the worker")
    let k = try await sb.exec(["sh", "-c", """
        cd /workspace; w=$(sed -n 's/^worker=//p' \(WorkspaceView.statePath(tag))); kill -9 $w; sleep 0.6
        echo "before=$w after=$(sed -n 's/^worker=//p' \(WorkspaceView.statePath(tag)))"; cat plain.txt; cat secret.env 2>&1; ls | head -2
        """], privileged: true, timeoutSeconds: 30)
    let kills = k.output.split(separator: "\n").map(String.init)
    let before = kills.first?.split(separator: " ").first.map { String($0.dropFirst(7)) } ?? "?"
    let after = kills.first?.split(separator: " ").last.map { String($0.dropFirst(6)) } ?? "?"
    check(before != after && !after.isEmpty && k.output.contains("plain-v1") && k.output.contains(EACCES),
          "a killed worker is replaced by the supervisor (worker \(before) → \(after)); a shell inside /workspace reads on, the lock holds (\(k.output.replacingOccurrences(of: "\n", with: " ⏎ ")))")
    try await ignoreFullCheck(sb, "killed", supervisor: supervisor, share: share)

    // a killed supervisor AND worker: the mount is dead until the next wake starts a new one
    print("ignore: kill -9 the supervisor and the worker, then hibernate → wake")
    _ = try await sb.exec(["sh", "-c", "w=$(sed -n 's/^worker=//p' \(WorkspaceView.statePath(tag))); kill -9 $(cat \(WorkspaceView.pidPath(tag))) $w; sleep 0.3"],
                          privileged: true, timeoutSeconds: 20)
    let dead = try await sb.exec(["sh", "-c", "ls /workspace 2>&1"], timeoutSeconds: 20)
    info("with no daemon: ls /workspace → \(dead.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)) (rc \(dead.exitCode))")
    check(dead.exitCode != 0, "with the daemon gone /workspace fails closed (it does not fall back to the raw share)")
    try await sb.hibernate()
    try await sb.wake()
    let sv2 = await ignoreSupervisor(sb)
    check(!sv2.isEmpty && sv2 != supervisor, "the wake started a new supervisor (\(supervisor) → \(sv2))")
    try await ignoreFullCheck(sb, "restarted", supervisor: sv2, share: share)
    info("daemon log: " + (await ignoreLog(sb)))
    try await sb.shutDown()
    try await sb.delete()

    // ── the three-process restore ───────────────────────────────────────────────────────────────
    for (n, child) in [("1", "ignore-crash-save"), ("2", "ignore-crash-restore")] {
        print("ignore: restore by a new process — child \(n) (\(child))")
        let p = Process(); p.executableURL = exe
        p.arguments = [child, "--store", storeRoot.path]
        try p.run(); p.waitUntilExit()
        check(p.terminationStatus == 0, "child \(n) (\(child)) exited 0 (\(p.terminationStatus))")
    }
    print("ignore: restore by a new process — the parent (third process)")
    try await ignoreCrashRestore(label: "crash3", thenQuit: false)

    // ── B: no rule file → no daemon; a rule file appearing ────────────────────────────────────────
    try await ignoreAppearing()
}

func ignoreCrashSpec() -> (SandboxSpec, URL) {
    let share = storeRoot.appendingPathComponent("share-ign-crash")
    return (ignoreSpec("ign-crash", share: share, subnet: "192.168.203.0/24"), share)
}

/// Child 1: start a sandbox with rules, check, quit like a host (Hibernate), exit WITHOUT stopping.
func ignoreCrashSave() async throws -> Int32 {
    _ = try ignorePrepareShare("ign-crash")
    let (spec, share) = ignoreCrashSpec()
    let sb = try Sandbox(spec: spec)
    try? await sb.delete()
    let log = logEvents(sb, prefix: "[child] ")
    try await sb.start()
    let sv = await ignoreSupervisor(sb)
    try sv.write(to: storeRoot.appendingPathComponent("ign-crash-supervisor.txt"), atomically: true, encoding: .utf8)
    try await ignoreFullCheck(sb, "crash0", supervisor: sv, share: share)
    await sb.prepareForExit()
    log.cancel()
    let parked = await sb.phase == .hibernated
    print("        · [child] quit with the view's supervisor \(sv) → \(await sb.phase.label)")
    return failures == 0 && parked ? 0 : 1
}

/// A restore in a NEW process (child 2: then quit again; the parent: then shut down + delete).
func ignoreCrashRestore(label: String, thenQuit: Bool) async throws {
    let (spec, share) = ignoreCrashSpec()
    check(Sandbox.restorableState(for: spec) != nil, "[\(label)] a new process sees a restorable sandbox")
    let sv = ((try? String(contentsOf: storeRoot.appendingPathComponent("ign-crash-supervisor.txt"), encoding: .utf8)) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    try "pre\n".write(to: share.appendingPathComponent("mac-pre-\(label).txt"), atomically: true, encoding: .utf8)
    let sb = try Sandbox(spec: spec)
    let log = logEvents(sb)
    defer { log.cancel() }
    let t = Date()
    try await sb.wake()
    check(await sb.phase == .running, String(format: "[\(label)] restored into a new process in %.0f ms", Date().timeIntervalSince(t) * 1000))
    check(!sb.activeViews.isEmpty, "[\(label)] the re-mount found the guest's view (no record needed) and signalled it")
    let first = try await sb.exec(["sh", "-c", "ls /workspace >/dev/null && cat /workspace/mac-pre-\(label).txt"], timeoutSeconds: 20)
    check(first.exitCode == 0 && first.output.contains("pre"), "[\(label)] the first request after the restore succeeds")
    try await ignoreFullCheck(sb, label, supervisor: sv, share: share)
    if thenQuit {
        await sb.prepareForExit()
        check(await sb.phase == .hibernated, "[\(label)] quit again (hibernated) for the next process")
    } else {
        try await sb.shutDown()
        try await sb.delete()
    }
}

/// No rule file: a PASSTHROUGH view (BUG cwd-after-wake — every share is served through the view so a
/// program's cwd survives a hibernation; it hides nothing) — or, with `passthroughViews` off (599g's rule),
/// the share bound as it always was and no daemon. A rule file appearing: at a session start
/// (`refreshWorkspaceViews`) and while hibernated (the wake's re-mount turns the view on).
func ignoreAppearing() async throws {
    let share = try ignorePrepareShare("ign-b", rules: false)
    let sb = try Sandbox(spec: ignoreSpec("ign-b", share: share, subnet: "192.168.204.0/24"))
    let log = logEvents(sb)
    defer { log.cancel() }
    try? await sb.delete()
    print("ignore: no rule file, passthroughViews off (599g's rule)")
    sb.passthroughViews = false
    try await sb.start()
    let none = try await sb.exec(["sh", "-c", "grep -c fuse.dozview /proc/mounts; pidof dozview | wc -w; grep -c ' /workspace virtiofs' /proc/mounts; cat /workspace/secret.env"], privileged: true, timeoutSeconds: 20)
    let lines = none.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    check(sb.activeViews.isEmpty && lines.count >= 4 && lines[0] == "0" && lines[1] == "0" && lines[2] == "1" && lines[3] == "SECRET=1",
          "no rule file, passthroughViews off → no view, no daemon: /workspace is the virtio-fs share itself (\(lines))")
    try await sb.shutDown()
    sb.passthroughViews = true

    print("ignore: no rule file — a passthrough view")
    try await sb.start()
    let pass = try await sb.exec(["sh", "-c", "grep -c ' /workspace fuse.dozview ' /proc/mounts; cat /workspace/secret.env; echo 'version: 9' > /workspace/doz_project.yaml && cat /workspace/doz_project.yaml; echo x > /workspace/.git/hooks/post-commit && echo hooks-ok"], timeoutSeconds: 20)
    check(sb.activeViews.count == 1 && sb.activeViews.values.allSatisfy(\.isPassthrough) && pass.output.hasPrefix("1") && pass.output.contains("SECRET=1")
          && pass.output.contains("version: 9") && pass.output.contains("hooks-ok"),
          "no rule file → a passthrough view: nothing hidden or read-only (\(pass.output.replacingOccurrences(of: "\n", with: " ⏎ "))\(pass.errorOutput))")

    print("ignore: a rule file appears — at the next session start")
    try ignoreRules.write(to: share.appendingPathComponent(".dozignore"), atomically: true, encoding: .utf8)
    await sb.refreshWorkspaceViews()
    let on = try await sb.exec(["sh", "-c", "grep -c ' /workspace fuse.dozview ' /proc/mounts; cat /workspace/secret.env 2>&1; cat /workspace/plain.txt"], timeoutSeconds: 20)
    check(!sb.activeViews.isEmpty && on.output.contains(EACCES) && on.output.contains("plain-v1"),
          "a .dozignore that appeared is in force from the next session start (\(on.output.replacingOccurrences(of: "\n", with: " ⏎ ")))")
    try await sb.shutDown()

    print("ignore: a rule file appears while it is hibernated")
    try FileManager.default.removeItem(at: share.appendingPathComponent(".dozignore"))
    try await sb.start()
    check(sb.activeViews.values.allSatisfy(\.isPassthrough), "a cold start without the rule file serves the share as it is (a passthrough view)")
    try await sb.hibernate()
    try "config\n".write(to: share.appendingPathComponent(".dozreadonly"), atomically: true, encoding: .utf8)
    try await sb.wake()
    let ro = try await sb.exec(["sh", "-c", "{ echo x >> /workspace/config/app.yaml; } 2>&1; cat /workspace/config/app.yaml; echo ok > /workspace/w.txt && cat /workspace/w.txt"], timeoutSeconds: 20)
    check(!sb.activeViews.isEmpty && ro.output.contains(EROFS) && ro.output.contains("ro: 1") && ro.output.contains("ok"),
          "a .dozreadonly that appeared while hibernated is in force at the wake (\(ro.output.replacingOccurrences(of: "\n", with: " ⏎ ")))")
    try await sb.shutDown()
    try await sb.delete()
}
