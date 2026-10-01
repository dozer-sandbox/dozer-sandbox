import Darwin
import DozerHost
import Foundation

/// 594 W22 (owner: "doz host stop seems to run with delay but its no doubt hibernating vms. we need some
/// progress"): `doz host stop` shows each sandbox as it hibernates — plain lines off a terminal, the
/// animated view on one — then a summary; `--json` carries the rows; with nothing running it says so;
/// and a host that dies mid-stop never leaves the CLI hanging. A store of its own (`/tmp/dzo-PID-h`).
func cliHostStopSuite(binary: String) async {
    let t = onboardingHarness(binary, "h", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    defer {
        t.run(["host", "stop"])
        try? FileManager.default.removeItem(at: t.store)
    }
    print("cli: doz host stop shows its progress (W22)")
    check(t.run(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    for n in ["hs1", "hs2"] {
        let r = t.run(["up", n, "--image", "lab", "--isolated", "--memory", "512M", "--detach"], timeout: 600)
        check(r.code == 0, "up \(n) --image lab --detach (exit \(r.code))")
    }
    check(t.run(["pause", "hs2"]).code == 0, "pause hs2 (a paused one hibernates too)")

    // 1. Off a terminal (the harness's pipes): plain lines, one per sandbox, then the summary.
    var r = t.run(["host", "stop"], timeout: 180)
    check(r.code == 0, "host stop (exit \(r.code))")
    check(r.err.contains("  · hibernated hs1 (snapshot ") && r.err.contains("  · hibernated hs2 (snapshot "), "plain: a line per sandbox — \(r.err.split(separator: "\n").filter { $0.contains("hibernated") })")
    check(r.err.contains("  · saving the host's state — "), "plain: the host's own last step")
    check(!r.err.contains("\u{1B}["), "plain: no escape sequences off a terminal")
    check(r.out.range(of: #"^host stopped — 2 sandboxes hibernated \(hs1, hs2\) in [0-9.]+ (ms|s); the next command starts a new host\n$"#, options: .regularExpression) != nil,
          "the summary: \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))")
    check(!t.hostRunning, "no host after it")
    check(t.row("hs1")?.phase == "hibernated" && t.row("hs2")?.phase == "hibernated", "both hibernated")

    // 2. --json: the rows.
    for n in ["hs1", "hs2"] { check(t.run(["wake", n], timeout: 120).code == 0, "wake \(n)") }
    r = t.run(["host", "stop", "--json"], timeout: 180)
    if let res = try? HostWire.decoder.decode(HostStopResult.self, from: r.outData) {
        check(res.stopped && res.sandboxes.map(\.name) == ["hs1", "hs2"] && res.sandboxes.allSatisfy { $0.outcome == "hibernated" && $0.phase == "hibernated" },
              "--json: both rows, hibernated")
        check(res.sandboxes.allSatisfy { ($0.snapshotBytes ?? 0) > 0 && $0.milliseconds > 0 }, "--json: each with its time and snapshot size")
    } else {
        check(false, "--json decodes as the stop's result: \(r.out.prefix(300))")
    }

    // 3. On a terminal: the animated view — the spinner line while it works, "✓ hibernated …" after.
    check(t.run(["wake", "hs1"], timeout: 120).code == 0, "wake hs1")
    do {
        let c = try PTYClient(t, ["host", "stop"])
        defer { c.close() }
        let code = c.exited(within: 120)
        check(code == 0, "host stop on a pty (exit \(code.map(String.init) ?? "still running"))")
        let plainText = c.text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        check(plainText.contains("hibernating hs1"), "animated: the line under way (hibernating hs1)")
        let done = plainText.contains("✓ hibernated hs1")
        check(done, "animated: ✓ hibernated hs1" + (done ? "" : " — \(plainText.debugDescription.suffix(400))"))
        check(c.text.contains("host stopped — 1 sandbox hibernated (hs1)"), "animated: the summary")
    } catch { check(false, "pty: \(error)") }

    // 4. Nothing running.
    check(t.run(["host", "start"], timeout: 60).code == 0 && t.hostRunning, "host start (nothing running)")
    r = t.run(["host", "stop"], timeout: 60)
    check(r.code == 0 && r.out == "host stopped (nothing was running)\n", "nothing running: \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))")

    // 5. The host dies mid-stop: the CLI reports what it saw and never hangs.
    check(t.run(["wake", "hs1"], timeout: 120).code == 0, "wake hs1")
    // A session started just now: the stop lets it settle (~3 s) before it hibernates — the window.
    check(t.run(["run", "hs1", "--detach", "--session", "fresh", "--", "sleep", "300"], timeout: 60).code == 0, "a fresh session in hs1")
    let pid = t.hostPID()
    let log = t.store.appendingPathComponent("host.log")
    let logStart = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? NSNumber)?.intValue ?? 0
    let p = t.process(["host", "stop"])
    let e = Pipe()
    p.standardError = e
    p.standardOutput = FileHandle.nullDevice
    let ec = PipeCollector(e.fileHandleForReading)
    do { try p.run() } catch { check(false, "host stop: \(error)") }
    let asked = t.waitFor(10) {
        guard let d = try? Data(contentsOf: log), d.count > logStart else { return false }
        return String(decoding: d.suffix(from: logStart), as: UTF8.self).contains("hibernating hs1")
    }
    check(asked, "the stop began (host.log: hibernating hs1)")
    if let pid { kill(pid, SIGKILL) }
    let deadline = Date().addingTimeInterval(20)
    while p.isRunning && Date() < deadline { usleep(50_000) }
    let hung = p.isRunning
    if hung { p.terminate() }
    p.waitUntilExit()
    ec.wait(5)
    check(!hung, "a host killed mid-stop: the CLI does not hang")
    check(p.terminationStatus != 0 && ec.text.contains("the host exited before it answered"), "…and says the host exited: \(ec.text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(240))")

    // W33 (the owner, after an upgrade: `doz image ls` showed no STATUS — an older host answered): a host
    // of another build is said ONCE on stderr before the answer; never on stdout, never with -q.
    print("cli: a host of another build is said (W33)")
    t.run(["host", "stop"], timeout: 180)
    let this = t.run(["--version"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
    for (stamp, expect) in [("0.0.1", "the doz host is 0.0.1 (this doz is \(this))"), ("99.0.0", "the doz host is 99.0.0, newer than this doz (\(this))")] {
        var stamped = t.env
        stamped["DOZ_TEST_VERSION"] = stamp
        let start = Process()
        start.executableURL = URL(fileURLWithPath: t.binary)
        start.arguments = ["host", "start"]
        start.environment = stamped
        start.standardOutput = FileHandle.nullDevice
        start.standardError = FileHandle.nullDevice
        try? start.run()
        start.waitUntilExit()
        check(t.waitFor(20) { t.hostRunning }, "a host stamped \(stamp) runs")
        let loud = t.run(["ls", "--json"]), quiet = t.run(["ls", "--json", "-q"])
        check(occurrences(loud.err, "note: ") == 1 && loud.err.contains(expect), "\(stamp): one note on stderr — \(loud.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))")
        check(!loud.out.contains("note:") && loud.outData == quiet.outData, "\(stamp): stdout (the JSON) is the same with or without the note")
        check(!quiet.err.contains("note: "), "\(stamp): -q says nothing")
        let plain = t.run(["image", "ls"])
        check(occurrences(plain.err, "note: the doz host is") == 1, "\(stamp): once per command (image ls)")
        t.run(["host", "stop"], timeout: 180)
    }
    t.run(["host", "start"])
    let same = t.run(["ls"])
    check(t.hostRunning && !same.err.contains("note: the doz host"), "a host of the same build: no note")
}
