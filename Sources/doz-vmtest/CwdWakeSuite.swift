// `doz-vmtest cwd-wake` (`make test-vm-cwd`) — BUG cwd-after-wake (0.29.0-rc.1, a Codex sandbox: "turn/start
// failed: invalid cwd: No such file or directory"). A program whose cwd is inside /workspace must keep it
// across every lifecycle transition. A hibernation's re-mount (`remountShares`) detaches the raw virtio-fs
// share at its guest path and gives the fresh mount new node ids, so on the RAW share getcwd() fails with
// ENOENT afterwards; through the view (dozview — never re-mounted, its daemon lives in guest memory) the
// cwd survives. Since the fix every share is served through the view, a PASSTHROUGH one when the folder has
// no rule file.
//
//   two sandboxes, no rule file: `cwr` (passthroughViews = false — the raw share, the control) and `cwv`
//   (the default — a passthrough view); in each two looping programs, cwd /workspace and /workspace/sub,
//   each tick writing `realpath .` (getcwd — bash's `pwd -P` resolves $PWD instead) and `ls .`;
//   sleep→wake ×2 · hibernate→wake ×2 · a restore by a NEW process (child: start + loops + quit like a
//   host; the parent: wake) — after each, the view's loops (the SAME pids) still answer, and see a file
//   the Mac wrote after the wake;
//   the passthrough view hides nothing and makes nothing read-only (doz_project.yaml, .git/hooks, a new
//   repository's hooks); the cost against the raw share (2,000 files).
import Foundation
import DozerKit

let cwdLoop = """
echo $$ > /tmp/cwdloop-$N.pid
while :; do p=$(realpath . 2>&1); r1=$?; l=$(ls . 2>&1 | tr '\\n' ' '); r2=$?; echo "getcwd[$r1]=$p ls[$r2]=$l" > /tmp/cwdloop-$N.now.tmp; mv /tmp/cwdloop-$N.now.tmp /tmp/cwdloop-$N.now; sleep 0.5; done
"""

func cwdSpec(_ name: String, subnet: String) -> (SandboxSpec, URL) {
    let share = storeRoot.appendingPathComponent("share-\(name)")
    return (SandboxSpec(name: name, storeRoot: storeRoot, kernelPath: kernelPath, kernelCacheDirectory: kernelCache, cpus: 2, memoryMiB: 512,
                        rootfsMiB: 1024, bakePackages: ["bash", "ncurses"],
                        shares: [Share(hostPath: share.path, guestPath: "/workspace")], subnet: subnet), share)
}

func cwdPrepareShare(_ share: URL) throws {
    let fm = FileManager.default
    try? fm.removeItem(at: share)
    for d in ["sub", ".git/hooks", "bench"] { try fm.createDirectory(at: share.appendingPathComponent(d), withIntermediateDirectories: true) }
    for (p, s) in ["a.txt": "a\n", "sub/b.txt": "b\n", "secret.env": "SECRET=1\n", "doz_project.yaml": "version: 1\n",
                   ".git/hooks/pre-commit": "#!/bin/sh\n"] {
        try s.write(to: share.appendingPathComponent(p), atomically: true, encoding: .utf8)
    }
    for i in 0..<2000 { try "f\(i)\n".write(to: share.appendingPathComponent("bench/f\(i).txt"), atomically: false, encoding: .utf8) }
}

func cwdStartLoops(_ sb: Sandbox) async throws {
    try await sb.openSession("top", argv: ["bash", "-c", cwdLoop], environment: ["N": "top"], workingDirectory: "/workspace", size: .standard)
    try await sb.openSession("sub", argv: ["bash", "-c", cwdLoop], environment: ["N": "sub"], workingDirectory: "/workspace/sub", size: .standard)
    try await Task.sleep(for: .seconds(1))
}

/// The loops' state: [top/sub: (pid, last line)], read after the Mac wrote `marker` and a tick has passed.
func cwdLoops(_ sb: Sandbox, share: URL, marker: String) async throws -> [String: (pid: String, line: String)] {
    try "m\n".write(to: share.appendingPathComponent(marker), atomically: true, encoding: .utf8)
    try "m\n".write(to: share.appendingPathComponent("sub/\(marker)"), atomically: true, encoding: .utf8)
    try await Task.sleep(for: .milliseconds(2500))     // virtio-fs's / the view's 1 s entry cache, plus a tick
    let r = try await sb.exec(["sh", "-c", "for n in top sub; do echo \"$n $(cat /tmp/cwdloop-$n.pid) $(cat /tmp/cwdloop-$n.now)\"; done"],
                              privileged: true, timeoutSeconds: 20)
    var out: [String: (pid: String, line: String)] = [:]
    for l in r.output.split(separator: "\n") {
        let f = l.split(separator: " ", maxSplits: 2).map(String.init)
        if f.count == 3 { out[f[0]] = (f[1], f[2]) }
    }
    return out
}

/// Did both loops keep a working cwd (getcwd answers the path, `ls .` lists the Mac's new file)?
func cwdHealthy(_ s: [String: (pid: String, line: String)], marker: String) -> Bool {
    guard let t = s["top"], let u = s["sub"] else { return false }
    return t.line.hasPrefix("getcwd[0]=/workspace ls[0]=") && t.line.contains(marker)
        && u.line.hasPrefix("getcwd[0]=/workspace/sub ls[0]=") && u.line.contains(marker)
}

func cwdDescribe(_ s: [String: (pid: String, line: String)]) -> String {
    ["top", "sub"].map { "\($0) pid \(s[$0]?.pid ?? "?"): \(String((s[$0]?.line ?? "—").prefix(90)))" }.joined(separator: " | ")
}

func cwdWakeSuite() async throws {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let (rawSpec, rawShare) = cwdSpec("cwr", subnet: "192.168.205.0/24")
    let (viewSpec, viewShare) = cwdSpec("cwv", subnet: "192.168.206.0/24")
    try cwdPrepareShare(rawShare); try cwdPrepareShare(viewShare)
    let raw = try Sandbox(spec: rawSpec); raw.passthroughViews = false
    let view = try Sandbox(spec: viewSpec)
    let logs = [logEvents(raw, prefix: "[cwr] "), logEvents(view, prefix: "[cwv] ")]
    defer { logs.forEach { $0.cancel() } }
    try? await raw.delete(); try? await view.delete()

    print("cwd-wake: boot (no rule file in either folder)")
    try await raw.start(); try await view.start()
    check(raw.activeViews.isEmpty, "cwr (passthroughViews off): /workspace is the raw share, no view")
    check(view.activeViews.count == 1 && view.activeViews.values.allSatisfy(\.isPassthrough),
          "cwv: /workspace is served through a passthrough view (\(view.activeViews.values.map(\.guestPath)))")
    let mounts = try await view.exec(["sh", "-c", "grep ' /workspace ' /proc/mounts | cut -d' ' -f3"], timeoutSeconds: 15)
    check(mounts.output.trimmingCharacters(in: .whitespacesAndNewlines) == "fuse.dozview", "cwv: /workspace is fuse.dozview (\(mounts.output.trimmingCharacters(in: .whitespacesAndNewlines)))")

    // The passthrough view hides nothing and makes nothing read-only.
    let pass = try await view.exec(["sh", "-c", """
        cat /workspace/secret.env; echo 'version: 2' > /workspace/doz_project.yaml && cat /workspace/doz_project.yaml
        echo '#!/bin/sh' > /workspace/.git/hooks/post-commit && echo hooks-ok
        mkdir -p /workspace/newrepo/.git/hooks && echo x > /workspace/newrepo/.git/hooks/pre-push && echo newrepo-ok
        """], timeoutSeconds: 20)
    check(pass.exitCode == 0 && pass.output.contains("SECRET=1") && pass.output.contains("version: 2") && pass.output.contains("hooks-ok") && pass.output.contains("newrepo-ok"),
          "cwv: the passthrough view hides nothing and makes nothing read-only (\(pass.output.replacingOccurrences(of: "\n", with: " ⏎ "))\(pass.errorOutput))")

    try await cwdStartLoops(raw); try await cwdStartLoops(view)
    let r0 = try await cwdLoops(raw, share: rawShare, marker: "m-boot.txt"), v0 = try await cwdLoops(view, share: viewShare, marker: "m-boot.txt")
    check(cwdHealthy(r0, marker: "m-boot.txt") && cwdHealthy(v0, marker: "m-boot.txt"), "both: the loops run in /workspace and /workspace/sub (\(cwdDescribe(v0)))")
    let pids = (v0["top"]?.pid ?? "", v0["sub"]?.pid ?? "")

    var rawBroken: [String] = []
    for (kind, cycle) in [("sleep", 1), ("sleep", 2), ("hibernate", 1), ("hibernate", 2)] {
        print("cwd-wake: \(kind) → wake (\(cycle))")
        for sb in [raw, view] { if kind == "sleep" { try await sb.sleep() } else { try await sb.hibernate() } }
        for sb in [raw, view] { try await sb.wake() }
        let m = "m-\(kind)\(cycle).txt"
        let v = try await cwdLoops(view, share: viewShare, marker: m), r = try await cwdLoops(raw, share: rawShare, marker: m)
        check(cwdHealthy(v, marker: m) && v["top"]?.pid == pids.0 && v["sub"]?.pid == pids.1,
              "cwv after \(kind) → wake (\(cycle)): the same programs keep their cwd (\(cwdDescribe(v)))")
        if !cwdHealthy(r, marker: m) { rawBroken.append("\(kind)\(cycle)") }
        info("cwr (raw, control) after \(kind) → wake (\(cycle)): \(cwdDescribe(r))")
    }
    check(!rawBroken.contains { $0.hasPrefix("sleep") }, "control: the raw share keeps a cwd across sleep → wake (no re-mount)")
    info("control: the raw share lost the loops' cwd after: \(rawBroken.isEmpty ? "nothing" : rawBroken.joined(separator: ", ")) (the bug)")
    try await raw.shutDown(); try await raw.delete()

    // the cost: the passthrough view against the raw share, as root (the same benchmark as the ignore suite)
    let tag = view.activeViews.first?.key ?? "?"
    let bench = """
    t() { local s=$EPOCHREALTIME; "$@" >/dev/null 2>&1; local e=$EPOCHREALTIME; awk -v s="$s" -v e="$e" 'BEGIN { printf "%.0f", (e - s) * 1000 }'; }
    for round in 1 2 3; do
    for p in /workspace/bench \(WorkspaceView.rawPath(tag))/bench; do
      sync; echo 3 > /proc/sys/vm/drop_caches
      f1=$(t find $p); f2=$(t find $p); c=$(t sh -c "cat $p/* > /dev/null"); s=$(t sh -c "ls $p | head -1000 | sed 's#^#'$p'/#' | xargs stat -c %s")
      pa=$(t sh -c "ls $p | sed 's#^#'$p'/#' | xargs -P 8 -n 100 stat -c %s")
      w=$(t sh -c "for i in \\$(seq 1 300); do echo x > $p/w\\$i.tmp; done; rm -f $p/w*.tmp")
      echo "$round $p find=$f1/$f2 cat-all=$c stat-1000=$s parallel-stat-2000=$pa write+rm-300=$w"
    done; done
    """
    let b = try await view.exec(["bash", "-c", bench], privileged: true, timeoutSeconds: 300)
    info("cost (ms; 2000 files; view = /workspace, raw = the share): " + b.output.replacingOccurrences(of: "\n", with: " | "))
    try await view.shutDown(); try await view.delete()

    // ── a restore by a NEW process ───────────────────────────────────────────────────────────────
    print("cwd-wake: restore by a new process — the child starts it, runs the loops and quits like a host")
    let p = Process(); p.executableURL = exe
    p.arguments = ["cwd-wake-save", "--store", storeRoot.path]
    try p.run(); p.waitUntilExit()
    check(p.terminationStatus == 0, "the child (cwd-wake-save) exited 0 (\(p.terminationStatus))")
    let (cspec, cshare) = cwdSpec("cwc", subnet: "192.168.207.0/24")
    let before = ((try? String(contentsOf: storeRoot.appendingPathComponent("cwc-pids.txt"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let sb = try Sandbox(spec: cspec)
    let log = logEvents(sb, prefix: "[cwc] ")
    defer { log.cancel() }
    try await sb.wake()
    check(await sb.phase == .running && sb.activeViews.count == 1, "the parent restored it, its view found by the re-mount")
    let s = try await cwdLoops(sb, share: cshare, marker: "m-newprocess.txt")
    check(cwdHealthy(s, marker: "m-newprocess.txt") && "\(s["top"]?.pid ?? "") \(s["sub"]?.pid ?? "")" == before,
          "after a restore into a new process the same programs keep their cwd (\(cwdDescribe(s)); before: \(before))")
    try await sb.shutDown(); try await sb.delete()
}

/// The child: start `cwc` with the loops, quit like a host (Hibernate), exit without stopping.
func cwdWakeSave() async throws -> Int32 {
    let (spec, share) = cwdSpec("cwc", subnet: "192.168.207.0/24")
    try cwdPrepareShare(share)
    let sb = try Sandbox(spec: spec)
    try? await sb.delete()
    let log = logEvents(sb, prefix: "[child] ")
    try await sb.start()
    try await cwdStartLoops(sb)
    let s = try await cwdLoops(sb, share: share, marker: "m-child.txt")
    check(cwdHealthy(s, marker: "m-child.txt"), "[child] the loops run (\(cwdDescribe(s)))")
    try "\(s["top"]?.pid ?? "") \(s["sub"]?.pid ?? "")".write(to: storeRoot.appendingPathComponent("cwc-pids.txt"), atomically: true, encoding: .utf8)
    await sb.prepareForExit()
    log.cancel()
    let parked = await sb.phase == .hibernated
    return failures == 0 && parked ? 0 : 1
}
