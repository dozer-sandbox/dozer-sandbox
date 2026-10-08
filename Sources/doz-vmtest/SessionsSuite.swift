import Foundation
import DozerHost

/// 608 (`make test-cli-sessions`): sessions survive every wake, and End / Restart session — through the real
/// host and CLI, in a lab sandbox with a workspace, in a store of its own (`/tmp/dzo-PID-ss`):
/// the workspace served through the live view (and the setting off → the share directly, and back); a program
/// in /workspace keeps its folder across hibernate → wake and a HOST RESTART (the new host restores it);
/// restart a running session (same name, new pid, the program's screen back, a program that ignores SIGHUP
/// terminated), a tmux session (its old program gone with its tmux server), end a session, a session that is
/// not there, a sleeping sandbox refused (never woken), a restart racing an open of the same session (one
/// session), the record cleared by a shutdown.
func cliSessionsSuite(binary: String) async {
    let t = onboardingHarness(binary, "ss", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    let ws = URL(fileURLWithPath: "/tmp/dzo-\(getpid())-ssw")
    try? FileManager.default.removeItem(at: ws)
    try? FileManager.default.createDirectory(at: ws.appendingPathComponent("sub"), withIntermediateDirectories: true)
    defer {
        t.run(["host", "stop"], timeout: 300)
        try? FileManager.default.removeItem(at: t.store)
        try? FileManager.default.removeItem(at: ws)
    }
    print("cli: sessions survive every wake; End / Restart session (608)")
    check(t.run(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    check(t.run(["create", "s1", "--image", "lab", "--workspace", ws.path, "--memory", "512M", "--start"], timeout: 900).code == 0, "create s1 --workspace --start")
    check(t.row("s1")?.workspaceView == "live", "s1's /workspace is the live view (ls --json workspaceView = \(t.row("s1")?.workspaceView ?? "nil"))")
    func ex(_ script: String) -> String { t.run(["exec", "s1", "--", "sh", "-c", script], timeout: 60).out.trimmingCharacters(in: .whitespacesAndNewlines) }
    check(ex("grep ' /workspace ' /proc/mounts | cut -d' ' -f3") == "fuse.dozview", "the guest mounts /workspace as fuse.dozview")

    // ── a program in /workspace keeps its folder across hibernate → wake and a host restart ──────────────
    check(t.run(["run", "s1", "-d", "--session", "cw", "--workdir", "/workspace/sub", "--", "sh", "-c",
                 "while :; do realpath . > /tmp/cw.now 2>&1; ls . >> /tmp/cw.now 2>&1; sleep 0.5; done"]).code == 0, "a looping program in /workspace/sub")
    for (i, step) in ["hibernate", "host-restart", "hibernate"].enumerated() {
        if step == "hibernate" {
            check(t.run(["hibernate", "s1"], timeout: 180).code == 0, "hibernate s1")
        } else {
            check(t.run(["host", "stop"], timeout: 300).code == 0, "doz host stop (s1 hibernates with it)")
        }
        try? "m\n".write(to: ws.appendingPathComponent("sub/mac-\(i).txt"), atomically: true, encoding: .utf8)
        check(t.run(["wake", "s1"], timeout: 300).code == 0, "wake s1" + (step == "host-restart" ? " (a NEW host restores it)" : ""))
        // The loop ticks every 0.5 s; the Mac's new file shows within virtio-fs's caching (≤ ~1–2 s) — polled ≤ 10 s.
        let t0 = Date()
        var now = ""
        repeat { usleep(500_000); now = ex("cat /tmp/cw.now") } while !(now.hasPrefix("/workspace/sub") && now.contains("mac-\(i).txt")) && Date().timeIntervalSince(t0) < 10
        check(now.hasPrefix("/workspace/sub") && now.contains("mac-\(i).txt"),
              String(format: "after %@: the program still sees its folder, and the Mac's new file (%.1f s) (%@)", step == "host-restart" ? "a host restart" : "hibernate → wake",
                     Date().timeIntervalSince(t0), now.replacingOccurrences(of: "\n", with: " ")))
    }

    // a rule file appearing on the Mac (the view reloads its rules live) never cuts the program's folder either:
    // the view EXPIRES the kernel's cached names, it never drops them (a dropped one is "(deleted)" to a cwd).
    try? "secret.env\n".write(to: ws.appendingPathComponent(".dozignore"), atomically: true, encoding: .utf8)
    try? "s\n".write(to: ws.appendingPathComponent("secret.env"), atomically: true, encoding: .utf8)
    usleep(2_500_000)
    var now = ex("cat /tmp/cw.now; cat /workspace/secret.env 2>&1")
    check(now.hasPrefix("/workspace/sub") && now.contains("Permission denied"),
          "a .dozignore that appears is in force at once, and the program keeps its folder (\(now.replacingOccurrences(of: "\n", with: " ")))")
    try? FileManager.default.removeItem(at: ws.appendingPathComponent(".dozignore"))
    usleep(2_500_000)
    now = ex("cat /tmp/cw.now; cat /workspace/secret.env 2>&1")
    check(now.hasPrefix("/workspace/sub") && now.hasSuffix("s"), "removed again: everything visible, the folder kept (\(now.replacingOccurrences(of: "\n", with: " ")))")

    // ── restart a running session ──────────────────────────────────────────────────────────────────
    check(t.run(["run", "s1", "-d", "--session", "loop", "--", "sh", "-c", "trap '' HUP; echo started-$$; while :; do sleep 1; done"]).code == 0,
          "session loop (it ignores SIGHUP)")
    let p1 = t.sessions("s1").first { $0.name == "loop" }?.pid
    var r = t.run(["sessions", "restart", "s1", "loop", "-d", "--yes", "--json"], timeout: 60)
    let rs = try? HostWire.decoder.decode(SessionRestarted.self, from: r.outData)
    check(r.code == 0 && rs?.ended == "terminate" && rs?.resumed == false, "doz sessions restart s1 loop → ended by SIGTERM (it ignored the hangup), restarted (\(rs.map { "\($0.ended), resumed \($0.resumed)" } ?? r.err))")
    let row = t.sessions("s1").first { $0.name == "loop" }
    check(row?.ended == false && row?.pid != nil && row?.pid != p1 && row?.command == "sh -c trap '' HUP; echo started-$$; while :; do sleep 1; done",
          "the same session, the same program, a new pid (\(p1.map(String.init) ?? "?") → \(row?.pid.map(String.init) ?? "?"))")
    usleep(500_000)
    let screen = ex("/usr/local/bin/deckhold dump -s loop")
    check(screen.contains("started-\(row?.pid ?? -1)"), "its screen is the new program's (\(screen.split(separator: "\n").first ?? ""))")
    check(ex("ps -o args | grep -c '^sh -c trap'") == "1", "the old program is gone (one left: \(ex("ps -o pid,args | grep '^ *[0-9]* sh -c trap' | tr '\\n' ';'")))")

    // 610 (609.B2): from a script — stdin/stdout not a terminal, no -d — a restart restarts and RETURNS (it attached
    // and never returned); --json answers with the result and returns too.
    let t0 = Date()
    r = t.run(["sessions", "restart", "s1", "loop", "--yes"], timeout: 60)
    check(r.code == 0 && r.out.contains("restarted session loop in s1") && Date().timeIntervalSince(t0) < 30,
          String(format: "no terminal, no -d: doz sessions restart s1 loop --yes restarts and returns (exit %d, %.1f s: %@)", r.code,
                 Date().timeIntervalSince(t0), r.out.trimmingCharacters(in: .whitespacesAndNewlines)))
    let p2 = t.sessions("s1").first { $0.name == "loop" }?.pid
    r = t.run(["sessions", "restart", "s1", "loop", "--json"], timeout: 60)
    let rj = try? HostWire.decoder.decode(SessionRestarted.self, from: r.outData)
    let p3 = t.sessions("s1").first { $0.name == "loop" }?.pid
    check(r.code == 0 && rj != nil && p3 != nil && p3 != p2, "--json (no -d): the result as JSON, and it returns (pid \(p2.map(String.init) ?? "?") → \(p3.map(String.init) ?? "?"))")

    // a session inside tmux: the old program goes with its tmux server
    check(t.run(["config", "set", "--sandbox", "s1", "sessions.tmux", "true"]).code == 0, "s1's sessions run inside tmux")
    check(t.run(["run", "s1", "-d", "--session", "tm", "--", "sh", "-c", "echo tm-$$; exec sleep 7777"]).code == 0, "session tm (in tmux)")
    usleep(800_000)
    r = t.run(["sessions", "restart", "s1", "tm", "-d", "--yes"], timeout: 60)
    usleep(1_500_000)
    check(r.code == 0 && ex("ps -o args | grep -c '^sleep 7777'") == "1" && ex("ps -o args | grep -c '[{]tmux: server}'") == "1",
          "restart tm → one program and one tmux server, not the old one re-attached by tmux (\(ex("ps -o pid,args | grep -e '[s]leep 7777' -e '[t]mux: server' | tr '\\n' ';'")))")
    check(t.run(["config", "set", "--sandbox", "s1", "sessions.tmux", "false"]).code == 0, "tmux off again")

    // ── end ───────────────────────────────────────────────────────────────────────────────────────
    r = t.run(["sessions", "end", "s1", "tm", "--yes"], timeout: 60)
    check(r.code == 0 && r.out.contains("ended session tm in s1"), "doz sessions end s1 tm (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    check(t.sessions("s1").first { $0.name == "tm" }?.ended != false, "tm is not running any more")
    r = t.run(["sessions", "end", "s1", "nope", "--yes"], timeout: 60)
    check(r.code != 0 && r.err.contains("no session nope"), "a session that is not there is said (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines).suffix(80)))")
    r = t.run(["sessions", "end", "s1", "loop"], timeout: 30)
    check(r.code != 0 && r.err.contains("pass --yes"), "with no terminal to ask and no --yes it refuses")

    // ── a restart racing an open of the same session: one session ────────────────────────────────────
    check(t.run(["run", "s1", "-d", "--session", "race", "--", "bash", "-l"]).code == 0, "session race")
    let a = t.process(["sessions", "restart", "s1", "race", "-d", "--yes"]), b = t.process(["run", "s1", "-d", "--session", "race", "--", "bash", "-l"])
    for p in [a, b] { p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run() }
    a.waitUntilExit(); b.waitUntilExit()
    check(t.sessions("s1").filter { $0.name == "race" && !$0.ended }.count == 1 && ex("ls /run/deckhold | grep -c '^race.sock$'") == "1",
          "restart + open at once → one running session race (restart \(a.terminationStatus), open \(b.terminationStatus))")

    // ── never a wake ──────────────────────────────────────────────────────────────────────────────
    check(t.run(["sleep", "s1"], timeout: 120).code == 0, "sleep s1")
    r = t.run(["sessions", "restart", "s1", "loop", "-d", "--yes"], timeout: 60)
    check(r.code != 0 && r.err.contains("needs it running"), "a restart of an asleep sandbox is refused (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines).suffix(120)))")
    check(t.row("s1")?.phase == "asleep", "…and it stays asleep")
    check(t.run(["wake", "s1"], timeout: 120).code == 0, "wake s1")

    // ── the record, and the setting off ───────────────────────────────────────────────────────────
    let rec = t.store.appendingPathComponent("sandboxes/s1/sessions.json")
    check(FileManager.default.fileExists(atPath: rec.path), "the host recorded the sessions (sessions.json)")
    check(t.run(["config", "set", "--sandbox", "s1", "workspace.view", "off"]).code == 0, "doz config set --sandbox s1 workspace.view off")
    check(t.row("s1")?.workspaceView == "live", "a running sandbox keeps its view until its next start")
    check(t.run(["shutdown", "s1", "--yes"], timeout: 120).code == 0, "shutdown s1")
    check(!FileManager.default.fileExists(atPath: rec.path), "the shutdown cleared the record with the sessions")
    check(t.run(["start", "s1"], timeout: 300).code == 0, "start s1")
    check(t.row("s1")?.workspaceView == "direct" && ex("grep ' /workspace ' /proc/mounts | cut -d' ' -f3") == "virtiofs",
          "workspace.view off → the share directly (\(t.row("s1")?.workspaceView ?? "nil"))")
    check(t.run(["config", "set", "--sandbox", "s1", "workspace.view", "on"]).code == 0 && t.run(["shutdown", "s1", "--yes"], timeout: 120).code == 0
          && t.run(["start", "s1"], timeout: 300).code == 0 && t.row("s1")?.workspaceView == "live", "on again → the live view at the next start")
    t.run(["rm", "s1", "--yes"], timeout: 120)
}
