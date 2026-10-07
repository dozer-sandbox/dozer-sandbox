// `doz-vmtest cli --doz PATH` (585, `make test-cli`): the doz CLI end to end — the REAL signed
// binary, every call a SEPARATE process, against a scratch store. The host is whatever those
// processes start (a detached child of the first), exactly as a user gets it.
//
//   up (attached) → exec → run + attach from a second process → close the first → reattach, same pid
//   pause / resume → hibernate → wake: the SAME attached client is held and reattached
//   restore point take → revert → cold-boot → the change is gone
//   two sandboxes at once; `ls --json` from another process; key set via stdin (a fake key: the guest
//   sees only a placeholder); net policy / log; metrics; doctor
//   kill -9 the host → the next call starts a new one: the sandbox left asleep is restored (and asleep
//   again), the hibernated one wakes with the same pid
//   shutdown / rm; a read-only command starts no host; the host exits by itself when idle.
//
// Inputs: --doz PATH (default .build/debug/doz), --store DIR (default $TMPDIR/doz-clitest-store),
// $DOZ_KERNEL_CACHE (default: the vmtest store's cache when it holds the kernel). Sandboxes are
// named clia / clib; nothing outside the store is touched. Never the keychain.
import Darwin
import Foundation
import DozerKit
import DozerHost

struct CLIRun {
    var code: Int32
    var out: String
    var err: String
    var outData: Data
}

/// Collects a pipe on its own thread (a full pipe must never block the child).
final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ h: FileHandle) {
        Thread.detachNewThread { [self] in
            while true {
                let d = h.availableData
                if d.isEmpty { break }
                lock.lock(); data.append(d); lock.unlock()
            }
            done.signal()
        }
    }

    var bytes: Data { lock.lock(); defer { lock.unlock() }; return data }
    var text: String { String(decoding: bytes, as: UTF8.self) }
    func wait(_ seconds: Double) { _ = done.wait(timeout: .now() + seconds) }
}

final class CLIHarness: @unchecked Sendable {
    let binary: String
    let store: URL
    var env: [String: String]

    init(binary: String, store: URL) {
        self.binary = binary
        self.store = store
        var e = ProcessInfo.processInfo.environment
        e["DOZ_STORE"] = store.path
        e["DOZ_HOST_IDLE"] = "30"          // the suite stops the host itself; the idle test sets its own
        // 593 §9: the periodic screen capture every minute (the shortest) — it runs beside everything
        // the suite does, and `cliSessionMemoryChecks` waits for one.
        e["DOZ_SCREEN_CAPTURE"] = "1"
        // 591: the settings file is the suite's own (under the scratch store) — never the owner's ~/.config.
        e["XDG_CONFIG_HOME"] = store.appendingPathComponent("xdg").path
        // 599i rc.3: the Mac's Codex login only ever from a FAKE home (none here unless a suite writes one) —
        // a test never reads the real ~/.codex; and only a fake codex for the keep-alive.
        e["DOZ_TEST_CODEX_HOME"] = store.appendingPathComponent("fake-codex-home").path
        e["DOZ_TEST_CODEX_BIN"] = store.appendingPathComponent("fake-codex-bin/codex").path
        let vmtestKernels = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("doz-vmtest-store/kernels")
        if (e["DOZ_KERNEL_CACHE"] ?? "").isEmpty,
           FileManager.default.fileExists(atPath: vmtestKernels.appendingPathComponent(KernelArtifact.recommended.fileName).path) {
            e["DOZ_KERNEL_CACHE"] = vmtestKernels.path
        }
        env = e
    }

    func process(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        p.environment = env
        return p
    }

    /// Run `doz args…` to completion (killed after `timeout`).
    @discardableResult
    func run(_ args: [String], stdin: Data? = nil, timeout: Double = 180) -> CLIRun {
        let p = process(args)
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        let i = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : i
        do { try p.run() } catch { return CLIRun(code: -1, out: "", err: "\(error)", outData: Data()) }
        let oc = PipeCollector(o.fileHandleForReading), ec = PipeCollector(e.fileHandleForReading)
        if let stdin {
            i.fileHandleForWriting.write(stdin)
            try? i.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(10_000) }
        if p.isRunning { p.terminate(); usleep(300_000); if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        p.waitUntilExit()
        oc.wait(5); ec.wait(5)
        let r = CLIRun(code: p.terminationStatus, out: oc.text, err: ec.text, outData: oc.bytes)
        if r.code != 0 { info("doz \(args.joined(separator: " ")) → \(r.code): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))") }
        return r
    }

    func json<T: Decodable>(_ args: [String], _ t: T.Type) -> T? {
        let r = run(args + ["--json"])
        guard r.code == 0 else { return nil }
        do { return try HostWire.decoder.decode(T.self, from: r.outData) } catch {
            info("could not decode \(args.joined(separator: " ")): \(error) — \(r.out.prefix(300))")
            return nil
        }
    }

    func ls() -> [SandboxInfo] { json(["ls"], [SandboxInfo].self) ?? [] }
    func row(_ name: String) -> SandboxInfo? { ls().first { $0.name == name } }
    func sessions(_ name: String) -> [SessionRow] { json(["sessions", name], [SessionRow].self) ?? [] }
    func hostPID() -> Int32? {
        guard let st = json(["host", "status"], HostStatus.self) else { return nil }
        return st.pid
    }
    var hostRunning: Bool { DozerStore(root: store).hostIsRunning() }

    /// Poll `pred` for up to `seconds`.
    func waitFor(_ seconds: Double, _ pred: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if pred() { return true }
            usleep(200_000)
        }
        return pred()
    }
}

/// An attached client running in the background (`up`, `run`, `attach`), stdin a pipe.
final class AttachedClient: @unchecked Sendable {
    let process: Process
    let input = Pipe()
    let out: PipeCollector
    let err: PipeCollector

    init(_ h: CLIHarness, _ args: [String]) throws {
        process = h.process(args)
        let o = Pipe(), e = Pipe()
        process.standardOutput = o
        process.standardError = e
        process.standardInput = input
        try process.run()
        out = PipeCollector(o.fileHandleForReading)
        err = PipeCollector(e.fileHandleForReading)
    }

    var text: String { out.text }
    var count: Int { out.bytes.count }
    func type(_ s: String) { input.fileHandleForWriting.write(Data(s.utf8)) }

    func wait(_ seconds: Double, _ pred: (AttachedClient) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if pred(self) { return true }
            usleep(50_000)
        }
        return pred(self)
    }

    /// The largest `tick N` seen so far.
    var lastTick: Int {
        text.components(separatedBy: "tick ").dropFirst().compactMap { Int($0.prefix(while: \.isNumber)) }.max() ?? 0
    }

    /// Close it as a user closing the terminal would (SIGTERM), and reap it.
    func close() {
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    func exited(within seconds: Double) -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        return process.isRunning ? nil : process.terminationStatus
    }
}

func cliSuite() async throws {
    let binary: String = {
        if let i = args.firstIndex(of: "--doz"), i + 1 < args.count { return args[i + 1] }
        return ".build/debug/doz"
    }()
    let h = CLIHarness(binary: URL(fileURLWithPath: binary).standardizedFileURL.path, store: storeRoot)
    try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
    let ws = storeRoot.appendingPathComponent("workspace-cli")
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    try tickScript.write(to: ws.appendingPathComponent("tick.sh"), atomically: true, encoding: .utf8)
    info("doz \(h.binary) · store \(storeRoot.path) · kernel cache \(h.env["DOZ_KERNEL_CACHE"] ?? "(under the store)")")

    var clients: [AttachedClient] = []
    func cleanUp() {
        for c in clients { c.close() }
        h.run(["rm", "clia", "--yes"])
        h.run(["rm", "clib", "--yes"])
        h.run(["rm", "clis", "--yes"])
        h.run(["host", "stop"])
    }
    // A previous run that died part-way.
    if h.hostRunning { h.run(["host", "stop"]) }
    for n in ["clia", "clib", "clic", "clid", "clis", "clibt", "clires"] where FileManager.default.fileExists(atPath: DozerStore(root: storeRoot).configFile(n).path) {
        h.run(["rm", n, "--yes"])
    }
    h.run(["template", "rm", "clitpl", "--yes"])
    if h.hostRunning { h.run(["host", "stop"]) }

    do {
        // 588: this scratch store's proxied sandboxes follow no account — the suite never reads the Mac's login.
        check(h.run(["account", "default", "none"]).code == 0, "account default none")
        print("cli: doctor")
        let doctor = h.run(["doctor", "--json"])
        check(doctor.out.contains("\"check\" : \"entitlement\"") && !doctor.out.contains("\"status\" : \"fail\""),
              "doctor: the binary carries the virtualization entitlement, nothing fails (exit \(doctor.code))")

        print("cli: config (591 settings)")
        cliConfigChecks(h)

        print("cli: create + up (attached)")
        let c = h.run(["create", "clia", "--image", "lab", "--memory", "512M", "--workspace", ws.path])
        check(c.code == 0, "create clia --image lab --memory 512M --workspace … (exit \(c.code))")
        let t0 = Date()
        let up = try AttachedClient(h, ["up", "clia"])
        clients.append(up)
        let upOK = up.wait(600) { $0.err.text.contains("attaching to shell") }
        check(upOK, String(format: "up: created → started → attached to the shell session (%.1f s, first start in a store bakes)", Date().timeIntervalSince(t0)))
        // Typed the moment `up` says it is attaching — keys typed ahead of the connection must not be lost.
        up.type("echo $((6*7))-marker\r")
        check(up.wait(10) { $0.text.contains("42-marker") }, "up: keys (typed ahead) reach the shell and its output comes back")
        up.close()
        check(h.sessions("clia").contains { $0.name == "shell" && !$0.ended }, "closing the up client leaves the shell session running")

        print("cli: exec")
        let e = h.run(["exec", "clia", "--", "sh", "-c", "echo out; echo err >&2; exit 3"])
        check(e.code == 3 && e.out == "out\n" && e.err == "err\n", "exec: stdout, stderr and the exit code pass through (\(e.code))")
        let e2 = h.run(["exec", "clia", "--", "sh", "-c", "test -f /workspace/tick.sh && pwd && hostname"])
        check(e2.code == 0 && e2.out == "/workspace\nclia\n", "exec: runs in /workspace, the shared folder is there (\(e2.out.debugDescription))")

        // 594 (owner: "i dont want the user to have to create the path first"; "call it Isolated").
        print("cli: a missing --workspace is made; isolated is said")
        let made = URL(fileURLWithPath: "/private/tmp/dzcli-\(getpid())")
        defer { try? FileManager.default.removeItem(at: made) }
        let deep = made.appendingPathComponent("new/deep")
        var w = h.run(["create", "clin", "--image", "lab", "--memory", "512M", "--workspace", deep.path])
        check(w.code == 0 && w.err.contains("[doz] created ") && w.err.contains("tmp/dzcli-\(getpid())/new/deep") && FileManager.default.fileExists(atPath: deep.path),
              "create --workspace …/new/deep: the folder is made and said (\(w.err.prefix(120)))")
        try? "seen\n".write(to: deep.appendingPathComponent("mark"), atomically: true, encoding: .utf8)
        check(h.run(["start", "clin"], timeout: 300).code == 0 && h.run(["exec", "clin", "--", "cat", "/workspace/mark"]).out == "seen\n",
              "the sandbox sees it at /workspace")
        h.run(["rm", "clin", "--yes"])
        w = h.run(["create", "clii", "--image", "lab", "--memory", "512M"])
        check(w.code == 0 && w.out.contains(", isolated") && w.err.contains("isolated: nothing on this Mac is shared; /workspace is private to the sandbox"),
              "create without --workspace: isolated, and said")
        check(h.run(["ls"]).out.contains("isolated"), "ls: WORKSPACE says isolated")
        let iso = h.json(["ls"], [SandboxInfo].self)?.first { $0.name == "clii" }
        check(iso != nil && iso!.workspace == nil && iso!.isolated, "ls --json: workspace null, isolated true")
        h.run(["rm", "clii", "--yes"])
        w = h.run(["create", "clij", "--image", "lab", "--memory", "512M", "--isolated"])
        check(w.code == 0 && !w.err.contains("isolated:"), "create --isolated: asked for, so no note")
        h.run(["rm", "clij", "--yes"])
        w = h.run(["create", "clik", "--image", "lab", "--isolated", "--workspace", made.path])
        check(w.code != 0 && h.row("clik") == nil, "--isolated and --workspace together are refused")
        w = h.run(["create", "clik", "--image", "lab", "--workspace", h.store.appendingPathComponent("ws-in-store").path])
        check(w.code != 0 && w.err.contains("inside the store") && h.row("clik") == nil
              && !FileManager.default.fileExists(atPath: h.store.appendingPathComponent("ws-in-store").path),
              "a workspace inside the store is refused and not made")

        print("cli: run + attach from a second process, reattach")
        let a = try AttachedClient(h, ["run", "clia", "--session", "tick", "--", "bash", "/workspace/tick.sh"])
        clients.append(a)
        check(a.wait(15) { $0.text.contains("tick ") }, "run: a new session, attached, streams its output")
        let b = try AttachedClient(h, ["attach", "clia", "tick"])
        clients.append(b)
        check(b.wait(10) { $0.text.contains("tick ") }, "attach from a second process: the same session's screen and output")
        let pid = h.sessions("clia").first { $0.name == "tick" }?.pid
        check(pid != nil && (h.sessions("clia").first { $0.name == "tick" }?.clients ?? 0) >= 2, "sessions --json: tick, pid \(pid.map(String.init) ?? "?"), two clients")
        let aLast = a.lastTick
        a.close()
        let bMark = b.count
        check(b.wait(5) { $0.count > bMark }, "closing the first client leaves the second attached")
        b.close()
        let c3 = try AttachedClient(h, ["attach", "clia", "tick"])
        clients.append(c3)
        check(c3.wait(10) { $0.lastTick > aLast }, "reattach: the same session, further along (tick \(aLast) → \(c3.lastTick))")
        check(h.sessions("clia").first { $0.name == "tick" }?.pid == pid, "the session's pid is unchanged")

        print("cli: pause / resume, hibernate / wake with a client attached")
        var r = h.run(["pause", "clia"])
        let paused = h.row("clia")
        check(r.code == 0 && paused?.phase == "paused" && (paused?.ramHeldMiB ?? 0) > 0,
              "pause: ls --json says paused, RAM held \(paused?.ramHeldMiB ?? 0) MiB")
        usleep(300_000)
        var mark = c3.count
        usleep(1_500_000)
        check(c3.count == mark, "paused: the attached client gets nothing")
        r = h.run(["resume", "clia"])
        mark = c3.count
        check(r.code == 0 && c3.wait(5) { $0.count > mark }, "resume: output flows again on the same client")
        r = h.run(["suspend", "clia"])
        check(r.code == 0 && h.row("clia")?.phase == "paused", "suspend (alias of pause)")
        h.run(["resume", "clia"])
        r = h.run(["hibernate", "clia"])
        let hib = h.row("clia")
        check(r.code == 0 && hib?.phase == "hibernated" && hib?.ramHeldMiB == 0, "hibernate: hibernated, RAM held 0")
        check(c3.wait(5) { $0.err.text.contains("reattaching") }, "the attached client is told and waits (held)")
        let beforeWake = c3.lastTick
        let tw = Date()
        r = h.run(["wake", "clia"])
        let woke = h.row("clia")
        check(r.code == 0 && woke?.phase == "running" && (woke?.ramHeldMiB ?? 0) > 0,
              String(format: "wake: running in %.2f s (CLI round trip), RAM held %llu MiB", Date().timeIntervalSince(tw), woke?.ramHeldMiB ?? 0))
        check(c3.wait(10) { $0.lastTick > beforeWake + 1 }, "the held client reattached by itself and the ticks continue")
        check(h.sessions("clia").first { $0.name == "tick" }?.pid == pid, "wake: the same pid (\(pid.map(String.init) ?? "?"))")

        print("cli: restore points")
        r = h.run(["point", "take", "clia", "p1", "--note", "before the file"])
        check(r.code == 0, "point take clia p1")
        _ = h.run(["exec", "clia", "--", "touch", "/root/after-p1"])
        let points = h.json(["point", "ls", "clia"], [RestorePoint].self) ?? []
        check(points.contains { $0.name == "p1" }, "point ls --json lists p1")
        r = h.run(["point", "revert", "clia", "p1", "--yes"])
        check(r.code == 0 && h.row("clia")?.phase == "off", "point revert --yes: shut down onto p1")
        check(c3.exited(within: 10) == DozerCLIExit.failed, "the attached client ends: the sandbox shut down, the session is gone")
        r = h.run(["cold-boot", "clia"])
        check(r.code == 0 && h.row("clia")?.phase == "running", "cold-boot (alias of start) boots the reverted disk")
        r = h.run(["exec", "clia", "--", "test", "-e", "/root/after-p1"])
        check(r.code == 1, "the file written after p1 is gone")

        // 590: the owner clicked "open session" twice while a sandbox booted; two `deckhold serve`s
        // raced and one failed "Address in use". Four processes open the same session at once:
        // all succeed, and there is exactly one session.
        print("cli: concurrent opens of one session")
        let runs = LockedArray<CLIRun>()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            runs.append(h.run(["run", "clia", "--session", "dup", "-d", "--", "sleep", "600"]))
        }
        let dups = h.sessions("clia").filter { $0.name == "dup" }
        check(runs.all.count == 4 && runs.all.allSatisfy { $0.code == 0 },
              "4 concurrent `run --session dup -d` all succeed (exits \(runs.all.map(\.code)))")
        check(dups.count == 1 && dups.first?.ended == false, "exactly one dup session, running (\(dups.count))")
        r = h.run(["run", "clia", "--session", "dup", "-d", "--", "sleep", "601"])
        check(r.code == DozerCLIExit.exists, "a DIFFERENT program under the same name is still refused (exit \(r.code))")

        print("cli: two sandboxes at once")
        r = h.run(["create", "clib", "--image", "lab", "--memory", "512M", "--workspace", ws.path])
        check(r.code == 0, "create clib")
        r = h.run(["start", "clib"])
        let both = h.ls()
        check(r.code == 0 && both.filter { ["clia", "clib"].contains($0.name) && $0.phase == "running" }.count == 2,
              "ls --json (another process): clia and clib both running")
        let ha = h.run(["exec", "clia", "--", "hostname"]).out, hb = h.run(["exec", "clib", "--", "hostname"]).out
        check(ha == "clia\n" && hb == "clib\n", "exec reaches each: \(ha.trimmingCharacters(in: .whitespacesAndNewlines)) / \(hb.trimmingCharacters(in: .whitespacesAndNewlines))")

        print("cli: an auto-started host is never in its client's process tree (593)")
        cliHostDetachChecks(h)

        print("cli: progress — plain off a terminal, animated on one (593)")
        cliProgressChecks(h)

        print("cli: lineage, templates, duplicate (593)")
        cliLineageChecks(h, ws: ws)

        print("cli: saved screens and session memory (593 §9)")
        cliSessionMemoryChecks(h)

        print("cli: boot logs (593)")
        cliBootLogChecks(h)

        print("cli: key (stdin, a fake key), net policy / log")
        let fake = "sk-ant-FAKE-doz-clitest-0000"
        r = h.run(["key", "set", "clib", "--anthropic"], stdin: Data((fake + "\n").utf8))
        check(r.code == 0, "key set clib --anthropic < stdin")
        let keys = h.json(["key", "ls", "clib"], [CredentialRow].self) ?? []
        check(keys.contains { $0.binding == "anthropic" && $0.set && $0.source == "stdin" }, "key ls: anthropic set, from stdin (no value shown)")
        let seen = h.run(["exec", "clib", "--", "sh", "-c", "echo $ANTHROPIC_API_KEY"]).out
        check(seen.hasPrefix(CredentialVault.placeholderPrefix) && !seen.contains(fake), "the guest sees a placeholder, never the key (\(seen.prefix(14))…)")
        let pol = h.json(["net", "policy", "clib", "--allow", "example.com"], NetworkPolicy.self)
        check(pol?.rules.first?.host == "example.com", "net policy --allow example.com: first rule")
        _ = h.run(["exec", "clib", "--", "sh", "-c", "wget -q -T 5 -O /dev/null http://blocked.invalid/ || true"])
        let log = h.json(["net", "log", "clib"], [ConnectionRecord].self)
        check(log != nil, "net log --json (\(log?.count ?? 0) records, \(log?.filter { $0.verdict == .denied }.count ?? 0) denied)")

        print("cli: kill -9 the host")
        a.close()
        r = h.run(["run", "clia", "-d", "--session", "tick2", "--", "bash", "/workspace/tick.sh"])
        let p1 = h.sessions("clia").first { $0.name == "tick2" }?.pid
        r = h.run(["run", "clib", "-d", "--session", "tb", "--", "bash", "/workspace/tick.sh"])
        let p2 = h.sessions("clib").first { $0.name == "tb" }?.pid
        check(p1 != nil && p2 != nil, "sessions tick2 (pid \(p1.map(String.init) ?? "?")) in clia, tb (pid \(p2.map(String.init) ?? "?")) in clib")
        check(h.run(["hibernate", "clia"]).code == 0 && h.run(["sleep", "clib"]).code == 0, "clia hibernated, clib asleep (RAM kept, snapshot on disk)")
        guard let hostPID = h.hostPID() else { throw SandboxError.timedOut("no host pid") }
        kill(hostPID, SIGKILL)
        check(h.waitFor(10) { !h.hostRunning }, "kill -9 \(hostPID): the host is gone")
        let t9 = Date()
        let after = h.ls()
        check(h.hostRunning && h.hostPID() != hostPID, String(format: "the next call (ls) started a new host (pid %@, %.2f s)",
                                                               h.hostPID().map(String.init) ?? "?", Date().timeIntervalSince(t9)))
        check(after.contains { $0.name == "clia" && $0.phase == "hibernated" }, "clia is still hibernated")
        // 593 (owner, 2026-09-30): clis was RUNNING when the host died — it is off: its programs are gone,
        // and so are its saved screens (the periodic one included) and its panes.
        let clisLayout = DozerStore(root: storeRoot).layout("clis")
        check(h.waitFor(30) { h.row("clis")?.phase == "off" && !FileManager.default.fileExists(atPath: clisLayout.screensDirectory.path) },
              "clis died with the host: its saved screens are deleted")
        check(h.sessions("clis").isEmpty && !FileManager.default.fileExists(atPath: DozerStore(root: storeRoot).terminalLayoutFile("clis").path),
              "…no sessions listed, no terminal layout")
        check(h.run(["rm", "clis", "--yes"]).code == 0 && !FileManager.default.fileExists(atPath: clisLayout.sandboxDirectory.path), "rm clis")
        check(h.waitFor(60) { h.row("clib").map { $0.phase == "asleep" && !$0.busy } ?? false },
              "clib, asleep when the host died, was restored and is asleep again")
        print("cli: resources — refusals while snapshots need the guest init (595)")
        cliResourcesRefusals(h)
        r = h.run(["wake", "clia"])
        check(r.code == 0 && h.sessions("clia").first { $0.name == "tick2" }?.pid == p1, "wake clia in the new host: tick2 has the same pid (\(p1.map(String.init) ?? "?"))")
        r = h.run(["wake", "clib"])
        check(r.code == 0 && h.sessions("clib").first { $0.name == "tb" }?.pid == p2, "wake clib: tb has the same pid (\(p2.map(String.init) ?? "?"))")

        print("cli: metrics")
        let rows = h.json(["metrics"], [MetricsSummaryRow].self) ?? []
        for action in ["start", "wake", "hibernate", "restore after crash"] {
            check(rows.contains { $0.action == action && $0.count > 0 }, "metrics --json has \(action) rows")
        }

        print("cli: shutdown, rm, no daemon when idle")
        r = h.run(["shutdown", "clia"])
        check(r.code == 5, "shutdown without a terminal or --yes refuses (exit \(r.code))")
        r = h.run(["shutdown", "clia", "--yes"])
        check(r.code == 0 && h.row("clia")?.phase == "off", "shutdown --yes: off")
        r = h.run(["rm", "clia", "--yes"])
        check(r.code == 0 && h.row("clia") == nil, "rm --yes: clia is gone")
        r = h.run(["shutdown", "clib", "--yes"])
        check(r.code == 0, "shutdown clib")
        print("cli: resources — the account, delete and re-create, clean, logs and metrics, the kernel (595)")
        cliResourcesChecks(h)
        h.run(["host", "stop"])
        check(!h.hostRunning, "host stop: no host")
        _ = h.ls()
        check(!h.hostRunning, "ls with nothing running answers from the store — it starts no host")
        r = h.run(["host", "--idle-timeout", "0.05"])
        check(r.code == 0 && h.hostRunning, "host --idle-timeout 0.05 (3 s)")
        let ti = Date()
        check(h.waitFor(30) { !h.hostRunning }, String(format: "the idle host exited by itself after %.1f s", Date().timeIntervalSince(ti)))
        check(!FileManager.default.fileExists(atPath: DozerStore(root: storeRoot).socket.path), "and removed its socket")
        r = h.run(["rm", "clib", "--yes"])
        check(r.code == 0, "rm clib")
    } catch {
        check(false, "aborted: \(error)")
    }
    cleanUp()
    check(!h.hostRunning, "cleanup: no host left running")
    // 594: onboarding, projects, the environment prompt, uninstall — stores of their own.
    await cliOnboardingSuite(binary: h.binary)
    await cliTerminalRestoreSuite(binary: h.binary)
    await cliHostStopSuite(binary: h.binary)
    await cliAgentSudoSuite(binary: h.binary)
    await cliPointsSuite(binary: h.binary)
    await cliTimeZoneSuite(binary: h.binary)
    await cliImagesSuite(binary: h.binary)
    // 596: base × agent images — the CLI, Dockerfiles through a fake container, the real build when
    // Apple's services run (SKIPs otherwise). The matrix is `make test-cli-bases` alone.
    await cliBasesSuite(binary: h.binary, parts: ["cli", "dockerfile", "real"])
    // 597: agent permissions — the checklist, live changes, suggestions, the facts, stored by name.
    await cliPermissionsSuite(binary: h.binary)
    // 599: the session bridges.
    await cliClipboardSuite(binary: h.binary)
    await cliBrowserSuite(binary: h.binary)
    await cliOpenFilesSuite(binary: h.binary)
    await cliGitHubSuite(binary: h.binary)
    await cliTmuxSuite(binary: h.binary)
}

/// 593: how `doz image bake lab -v` shows its progress — plain (no escape, no \r, no spinner) when
/// stderr is not a terminal; animated (a spinner, ✓ lines) on one (`script` gives it a pty);
/// plain on one too with --progress plain, DOZ_PROGRESS=plain or NO_COLOR.
func cliProgressChecks(_ h: CLIHarness) {
    let r = h.run(["image", "bake", "lab", "-v"], timeout: 600)
    check(r.code == 0 && r.err.contains("  · ") && !r.err.contains("\u{1B}") && !r.err.contains("\r") && !r.err.contains("⠋"),
          "not a terminal: plain lines, no escape, no \\r, no spinner")
    func onPTY(_ extra: [String], env: [String: String] = [:]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null", h.binary, "image", "bake", "lab", "-v"] + extra
        var e = h.env
        for (k, v) in env { e[k] = v }
        p.environment = e
        let o = Pipe()
        p.standardOutput = o
        p.standardError = o
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let c = PipeCollector(o.fileHandleForReading)
        let deadline = Date().addingTimeInterval(600)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        c.wait(5)
        return c.text
    }
    let animated = onPTY(["--progress", "auto"])
    check(animated.contains("✓") && ProgressFormat.spinnerFrames.contains(where: { animated.contains($0) }) && animated.contains("\u{1B}[J"),
          "on a terminal: a spinner redrawn in place, then ✓ lines")
    for (what, extra, env) in [("--progress plain", ["--progress", "plain"], [String: String]()), ("DOZ_PROGRESS=plain", [], ["DOZ_PROGRESS": "plain"]),
                               ("NO_COLOR", ["--progress", "auto"], ["NO_COLOR": "1"])] {
        let out = onPTY(extra, env: env)
        check(out.contains("  · ") && !ProgressFormat.spinnerFrames.contains(where: { out.contains($0) }) && !out.contains("\u{1B}[J"),
              "on a terminal with \(what): plain")
    }
}

/// 593: `doz image ls --tree`, `doz template`, `doz duplicate` — on clia (running, lab, a workspace)
/// and clib. Leaves clia and clib as they were; clic, clid and the template are removed.
func cliLineageChecks(_ h: CLIHarness, ws: URL) {
    let store = DozerStore(root: h.store)
    if let tree = h.json(["image", "ls", "--tree"], ImageTree.self) {
        let root = tree.nodes.first { $0.parent == nil && $0.kind == "prepared" }
        let kids = tree.nodes.filter { $0.parent == root?.id && $0.kind == "sandbox" }.map(\.name)
        check(root != nil && kids.contains("clia") && kids.contains("clib"), "image ls --tree: the lab's prepared disk → clia, clib (\(kids.joined(separator: ", ")))")
        check(tree.nodes.filter { $0.kind == "sandbox" }.allSatisfy { $0.allocatedBytes > 0 && ($0.sharedWithParentBytes ?? 0) > 0 },
              "each sandbox shares bytes with its parent (APFS clones)")
    } else { check(false, "image ls --tree --json") }
    check(h.run(["image", "ls", "--tree"]).out.contains("└─ "), "image ls --tree draws the branches")

    // A template from the RUNNING clia: its root disk (with a marker), never its state disk.
    _ = h.run(["exec", "clia", "--", "sh", "-c", "echo tmark > /root/tmark && sync"])
    let pointsBefore = h.json(["point", "ls", "clia"], [RestorePoint].self)?.count
    var r = h.run(["template", "create", "clia", "--as", "clitpl", "--note", "cli suite"])
    let img = h.json(["template", "ls"], [ImageRow].self)?.first { $0.name == "clitpl" }
    check(r.code == 0 && img != nil, "template create clia --as clitpl (while it runs) → template ls lists it")
    check(h.json(["point", "ls", "clia"], [RestorePoint].self)?.count == pointsBefore, "its temporary restore point is gone")
    if let key = img?.key {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: store.layout("_").customImageDirectory(key).path).sorted()) ?? []
        check(files == ["image.json", "root.ext4"], "the template is the root disk only — no state disk (\(files.joined(separator: ", ")))")
    }
    if let tree = h.json(["image", "ls", "--tree"], ImageTree.self) {
        check(tree.nodes.contains { $0.kind == "template" && $0.name == "clitpl" && $0.parent != nil && $0.detail == "from clia" },
              "the lineage shows clitpl under its source image, from clia")
    }
    r = h.run(["create", "clic", "--image", "clitpl", "--memory", "384M"])
    check(r.code == 0 && h.run(["start", "clic"]).code == 0, "a sandbox from the template starts")
    check(h.run(["exec", "clic", "--", "cat", "/root/tmark"]).out == "tmark\n", "it has what was on clia's root disk")
    check(h.run(["rm", "clic", "--yes"]).code == 0, "rm clic")

    // Duplicate the running clia with a NEW workspace.
    let ws2 = ws.deletingLastPathComponent().appendingPathComponent("workspace-dup")
    try? FileManager.default.createDirectory(at: ws2, withIntermediateDirectories: true)
    try? "w2\n".write(to: ws2.appendingPathComponent("w2marker"), atomically: true, encoding: .utf8)
    r = h.run(["duplicate", "clia", "clid", "--workspace", ws2.path, "--memory", "384M", "--cpus", "1"])
    check(r.code == 0 && h.row("clid")?.phase == "off", "duplicate clia clid --workspace … (clia running): clid is off")
    check(h.run(["start", "clid"]).code == 0, "start clid")
    check(h.run(["exec", "clid", "--", "cat", "/workspace/w2marker", "/root/tmark"]).out == "w2\ntmark\n",
          "clid: the new workspace at /workspace, clia's root disk")
    check(h.run(["exec", "clid", "--", "nproc"]).out == "1\n", "clid: 1 CPU")
    check(h.run(["rm", "clid", "--yes"]).code == 0, "rm clid")
    // 594: a missing workspace is made — but never inside the store (this one is).
    r = h.run(["duplicate", "clia", "clie", "--workspace", ws.deletingLastPathComponent().appendingPathComponent("no-such-dir").path])
    check(r.code == 64 && r.err.contains("inside the store") && h.row("clie") == nil
          && !FileManager.default.fileExists(atPath: ws.deletingLastPathComponent().appendingPathComponent("no-such-dir").path),
          "a missing workspace inside the store is refused (and not made)")
    check(h.run(["template", "rm", "clitpl", "--yes"]).code == 0 && h.json(["template", "ls"], [ImageRow].self)?.isEmpty == true, "template rm clitpl")
    check(h.row("clia")?.phase == "running", "clia still runs")
}

/// 593 (owner, 2026-09-30): boot logs on `clibt` (lab) — six boots, cold boots and wakes mixed; the last
/// five kept; `doz console --list / --boot N --steps / --json`; removed with the sandbox.
func cliBootLogChecks(_ h: CLIHarness) {
    let layout = DozerStore(root: h.store).layout("clibt")
    guard h.run(["create", "clibt", "--image", "lab", "--memory", "384M"]).code == 0 else { check(false, "create clibt"); return }
    // 1 cold · 2 wake (hibernated) · 3 cold · 4 wake (asleep) · 5 wake (hibernated) · 6 cold
    let plan: [[String]] = [["start"], ["hibernate"], ["wake"], ["shutdown", "--yes"], ["start"], ["sleep"], ["wake"],
                            ["hibernate"], ["wake"], ["shutdown", "--yes"], ["start"]]
    for step in plan { check(h.run([step[0], "clibt"] + step.dropFirst()).code == 0, "clibt: \(step[0])") }
    let list = h.json(["console", "clibt", "--list"], BootLogList.self)
    check(list?.boots.count == 5, "six boots: the last five kept (\(list?.boots.count ?? -1))")
    check(list?.boots.map(\.kind) == ["cold boot", "wake", "wake", "cold boot", "wake"],
          "newest first: cold boot, wake, wake, cold boot, wake (\(list?.boots.map(\.kind) ?? []))")
    check(list?.boots.allSatisfy { $0.result == "ok" && ($0.milliseconds ?? 0) > 0 } == true, "each ok, with its duration")
    check(((try? FileManager.default.contentsOfDirectory(atPath: BootLogs.directory(layout).path))?.filter { $0.hasPrefix("b-") }.count) == 5,
          "five boot directories on disk")
    let table = h.run(["console", "clibt", "--list"])
    check(table.code == 0 && table.out.contains("KIND") && table.out.contains("cold boot") && table.out.contains("✓"), "console --list prints a table")
    var r = h.run(["console", "clibt", "--boot", "2", "--steps"])
    check(r.code == 0 && r.out.contains("── wake of clibt") && r.out.contains("restored VM state from disk") && r.out.contains("── kernel console"),
          "--boot 2 --steps: the previous boot (a wake from hibernation): its steps, then its console")
    r = h.run(["console", "clibt", "--boot", "4", "--steps"])
    check(r.code == 0 && r.out.contains("── cold boot of clibt") && r.out.contains("VM created and booted") && r.out.range(of: #"\[ *\d+\.\d+\]"#, options: .regularExpression) != nil,
          "--boot 4 --steps: an older cold boot's steps and its kernel console")
    check(!r.out.contains("\u{1B}"), "…as plain text off a terminal (no escape)")
    let rec = h.json(["console", "clibt", "--boot", "1"], BootLogRecord.self)
    check(rec?.info.number == 1 && rec?.info.kind == "cold boot" && (rec?.console.count ?? 0) > 10 && !(rec?.events.isEmpty ?? true),
          "--boot 1 --json: the latest boot's events and console (\(rec?.console.count ?? 0) lines)")
    check(h.run(["console", "clibt", "--boot", "6"]).code == 2, "--boot 6: only five are kept (not found)")
    check(h.run(["console", "clibt", "--boot", "1", "--follow"]).code == 64, "--follow with --boot: a usage error")
    check(h.run(["console", "clibt"]).out.contains("["), "doz console clibt still shows the latest console")
    check(h.run(["reset", "clibt", "--yes"]).code == 0 && h.json(["console", "clibt", "--list"], BootLogList.self)?.boots.count == 5,
          "reset keeps the boot logs (its next boot is still a boot of clibt)")
    check(h.run(["rm", "clibt", "--yes"]).code == 0 && !FileManager.default.fileExists(atPath: layout.sandboxDirectory.path),
          "rm clibt: its boot logs go with it")
}

/// A process's parent (sysctl; nil when it is gone).
func parentPID(_ pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

/// Every descendant of `root` (from `ps -A -o pid=,ppid=`).
func descendants(of root: pid_t) -> [pid_t] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-A", "-o", "pid=,ppid="]
    let o = Pipe()
    p.standardOutput = o
    guard (try? p.run()) != nil else { return [] }
    let data = o.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    var children: [pid_t: [pid_t]] = [:]
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let f = line.split(separator: " ").compactMap { pid_t($0) }
        if f.count == 2 { children[f[1], default: []].append(f[0]) }
    }
    var out: [pid_t] = [], queue = [root]
    while let x = queue.popLast() { for c in children[x] ?? [] { out.append(c); queue.append(c) } }
    return out
}

/// 593 incident (2026-09-29): a host auto-started by `doz ui` was the UI's CHILD; a tool that stopped
/// the UI's process tree SIGTERMed it mid-hibernate and a sandbox lost its programs. Now: a client in a
/// process group of its own starts the host; its whole group AND every descendant get SIGTERM, then
/// SIGKILL — the host lives on (parent launchd, another session), clia runs, its session answers.
/// Leaves clia and clib running.
func cliHostDetachChecks(_ h: CLIHarness) {
    h.run(["host", "stop"])
    check(!h.hostRunning, "host stopped (clia, clib hibernated)")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    // Its own process group (as a terminal's job, or a UI that a tool stops by group or tree).
    p.arguments = ["-e", "setpgrp(0,0); exec @ARGV", h.binary, "exec", "clia", "--", "sh", "-c", "echo client-up; exec sleep 120"]
    p.environment = h.env
    let o = Pipe()
    p.standardOutput = o
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { check(false, "start a client: \(error)"); return }
    _ = PipeCollector(o.fileHandleForReading)
    let client = p.processIdentifier
    // (exec prints when its command ends: wait for the host and clia, the client still running.)
    check(h.waitFor(120) { h.hostRunning && h.row("clia")?.phase == "running" } && p.isRunning,
          "a client in its own process group (doz exec clia, still running) auto-started the host and woke clia")
    guard let host = h.hostPID() else { check(false, "the host's pid"); p.terminate(); return }
    let tree = descendants(of: client)
    check(parentPID(host) == 1, "the auto-started host's parent is launchd (ppid \(parentPID(host).map(String.init) ?? "?"))")
    check(!tree.contains(host), "the host is not among the client's descendants (\(tree.count) of them)")
    check(getsid(host) != getsid(client) && getsid(host) != getsid(0) && getpgid(host) != client,
          "the host has its own session (sid \(getsid(host)) — the client's \(getsid(client)), the suite's \(getsid(0))) and group")
    if let st = h.json(["host", "status"], HostStatus.self) {
        check(st.parentPid == 1 && st.launchedDetached == true && st.sessionID == getsid(host), "host status --json: parentPid 1, launchedDetached, its session")
    } else { check(false, "host status --json") }
    // Stop the client the way tools stop a process tree: its group, and each descendant — TERM, then KILL.
    kill(-client, SIGTERM)
    for d in tree { kill(d, SIGTERM) }
    usleep(1_000_000)
    kill(-client, SIGKILL)
    for d in tree { kill(d, SIGKILL) }
    let deadline = Date().addingTimeInterval(10)
    while p.isRunning && Date() < deadline { usleep(50_000) }
    check(!p.isRunning, "the client and its tree are gone (TERM, then KILL, to the group and every descendant)")
    usleep(500_000)
    check(kill(host, 0) == 0 && parentPID(host) == 1 && h.hostPID() == host, "the host is still alive, parent launchd (pid \(host))")
    check(h.row("clia")?.phase == "running", "clia is still running")
    let r = h.run(["exec", "clia", "--", "echo", "still-here"])
    check(r.code == 0 && r.out == "still-here\n", "and it answers (exec)")
    check(h.sessions("clia").contains { !$0.ended && $0.pid != nil }, "its sessions answer (sessions --json)")
    let doctor = h.run(["doctor", "--json"])
    check(doctor.out.contains("parent launchd (detached)"), "doctor reports the host's parent: launchd")
    check(h.run(["wake", "clib"]).code == 0, "wake clib (for what follows)")
}

/// 593 §9 (S2, S4, S5, S6 — amended by the owner 2026-09-30): saved screens on `clis` (lab): saved at
/// pause, sleep and hibernate (0600 files in a 0700 directory); `doz sessions` lists them while it is
/// paused/asleep/hibernated and `--screen` prints one (text; `--vt` the bytes, to a pipe); a new program
/// is always a new session; shutdown and reset DELETE them (a shut-down sandbox has no sessions); an
/// exited program's screen is removed; the periodic capture saves only what changed. Leaves `clis`
/// RUNNING with a periodic screen — the kill -9 section checks that the crash deletes it.
func cliSessionMemoryChecks(_ h: CLIHarness) {
    let layout = DozerStore(root: h.store).layout("clis")
    func rows() -> [SessionRow] { h.sessions("clis") }
    func mode(_ url: URL) -> mode_t {
        var st = stat()
        return stat(url.path, &st) == 0 ? st.st_mode & 0o777 : 0
    }
    guard h.run(["create", "clis", "--image", "lab", "--memory", "384M"]).code == 0, h.run(["start", "clis"]).code == 0 else {
        check(false, "create + start clis"); return
    }
    var r = h.run(["run", "clis", "-d", "--session", "memo", "--", "sh", "-c", "printf '\\033[1;31mMEMO-one\\033[0m\\n'; exec sleep 3600"])
    check(r.code == 0, "run -d --session memo (a coloured line)")
    usleep(800_000)

    // Pause: saved first, while the guest can answer.
    r = h.run(["pause", "clis"])
    var saved = rows()
    check(r.code == 0 && saved.first { $0.name == "memo" }.map { $0.saved == true && $0.savedReason == "pause" && !$0.ended } == true,
          "pause: the session's screen is saved (reason pause); sessions lists it without waking (\(saved.map { "\($0.name)/\($0.savedReason ?? "-")" }))")
    check(mode(layout.screensDirectory) == 0o700 && ["vt", "txt", "json"].allSatisfy { mode(layout.screensDirectory.appendingPathComponent("memo.\($0)")) == 0o600 },
          "screens/ is 0700, memo.{vt,txt,json} 0600")
    r = h.run(["sessions", "clis", "--screen", "memo"])
    check(r.code == 0 && r.out.contains("MEMO-one") && !r.out.contains("\u{1B}") && r.err.contains("pause"),
          "sessions --screen memo: the saved screen as text, no escape (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)))")
    r = h.run(["sessions", "clis", "--screen", "memo", "--vt"])
    check(r.code == 0 && r.outData.first == 0x1B && String(decoding: r.outData, as: UTF8.self).contains("\u{1B}[1m") && String(decoding: r.outData, as: UTF8.self).contains("MEMO-one"),
          "--vt writes the VT bytes to a pipe (\(r.outData.count) B, bold/colour kept)")
    check(h.run(["sessions", "clis", "--screen", "nope"]).code == 2, "--screen of a session with no saved screen: not found (2)")
    check(h.run(["sessions", "clis", "--vt"]).code == 64, "--vt without --screen: a usage error")
    h.run(["resume", "clis"])
    check(rows().allSatisfy { $0.saved != true } && rows().first { $0.name == "memo" }?.savedReason == "pause",
          "resumed: the guest's sessions again (each says when its screen was last saved)")

    // A new program is always a NEW session, never the running one.
    let b1 = h.run(["run", "clis", "-d", "--", "sh", "-c", "echo SECOND; exec sleep 3600"]), b2 = h.run(["run", "clis", "-d", "--", "sh", "-c", "echo SECOND; exec sleep 3600"])
    let names = rows().filter { !$0.ended }.map(\.name)
    check(b1.code == 0 && b2.code == 0 && names.contains("sh") && names.contains("sh-2") && names.contains("memo"),
          "two `run -d -- sh …` make two NEW sessions (sh, sh-2) beside memo (\(names.joined(separator: ", ")))")

    // Sleep, then hibernate: saved each time.
    r = h.run(["sleep", "clis"])
    saved = rows()
    check(r.code == 0 && Set(saved.filter { $0.savedReason == "sleep" }.map(\.name)) == ["memo", "sh", "sh-2"], "sleep: every session saved (reason sleep)")
    h.run(["wake", "clis"])
    r = h.run(["hibernate", "clis"])
    saved = rows()
    check(r.code == 0 && saved.count == 3 && saved.allSatisfy { $0.saved == true && $0.savedReason == "hibernate" && !$0.ended },
          "hibernate: saved (reason hibernate); `doz sessions` lists them while hibernated, nothing woken")
    check(h.row("clis")?.phase == "hibernated", "…and it is still hibernated")
    check(h.run(["sessions", "clis", "--screen", "sh-2"]).out.contains("SECOND"), "--screen sh-2 while hibernated")
    h.run(["wake", "clis"])
    check(rows().first { $0.name == "memo" }?.pid != nil && rows().allSatisfy { $0.saved != true }, "wake: the live sessions again")

    // Shutdown (owner, 2026-09-30): no capture, and every saved screen is deleted — a shut-down sandbox
    // shows no session screens.
    r = h.run(["shutdown", "clis", "--yes"])
    check(r.code == 0 && rows().isEmpty && !FileManager.default.fileExists(atPath: layout.screensDirectory.path),
          "shutdown: no saved screens left (no screens/ directory); sessions --json is empty")
    r = h.run(["sessions", "clis"])
    check(r.code == 0 && r.out.contains("no sessions — clis is shut down"), "doz sessions says it is shut down (\(r.out.trimmingCharacters(in: .newlines)))")
    check(h.run(["sessions", "clis", "--screen", "memo"]).code == 2, "--screen of a shut-down sandbox: not found (2)")

    // A session whose program exits has no saved screen: the next capture removes it.
    h.run(["start", "clis"])
    h.run(["run", "clis", "-d", "--session", "fresh", "--", "sh", "-c", "echo FRESH; exec sleep 3600"])
    h.run(["run", "clis", "-d", "--session", "brief", "--", "sh", "-c", "echo BRIEF; sleep 3"])
    h.run(["pause", "clis"])
    check(Set(rows().map(\.name)) == ["fresh", "brief"], "pause: both saved (\(rows().map(\.name)))")
    h.run(["resume", "clis"])
    usleep(4_000_000)
    h.run(["pause", "clis"])
    check(rows().map(\.name) == ["fresh"], "brief exited: the next capture removed its screen (\(rows().map(\.name)))")
    check(!FileManager.default.fileExists(atPath: layout.screensDirectory.appendingPathComponent("brief.vt").path), "…its files are gone")
    h.run(["resume", "clis"])
    r = h.run(["reset", "clis", "--yes"])
    check(r.code == 0 && rows().isEmpty && !FileManager.default.fileExists(atPath: layout.screensDirectory.path),
          "reset: the saved screens are deleted with the disk (S6)")

    // The periodic capture (DOZ_SCREEN_CAPTURE=1): only what changed; the kill -9 section checks it survives a crash.
    h.run(["start", "clis"])
    h.run(["run", "clis", "-d", "--session", "tick", "--", "sh", "-c", "i=0; while true; do i=$((i+1)); echo PERIODIC-$i; sleep 5; done"])
    let t0 = Date()
    let periodic = h.waitFor(150) { h.sessions("clis").first { $0.name == "tick" }?.savedReason == "periodic" }
    check(periodic, String(format: "a periodic capture saved the running session's screen (%.0f s)", Date().timeIntervalSince(t0)))
    check(mode(layout.screensDirectory.appendingPathComponent("tick.vt")) == 0o600, "…0600")
    check(h.row("clis")?.phase == "running", "clis runs on (the kill -9 section checks the crash deletes its saved screens)")
}

/// 591: `doz config` from a separate process, on the harness's scratch XDG_CONFIG_HOME — no VM.
func cliConfigChecks(_ h: CLIHarness) {
    let xdg = URL(fileURLWithPath: h.env["XDG_CONFIG_HOME"] ?? "/nonexistent")
    let file = xdg.appendingPathComponent("dozer-sandbox/doz.toml")
    try? FileManager.default.removeItem(at: xdg)
    var r = h.run(["config", "path"])
    check(r.code == 0 && r.out == file.path + "\n", "config path: \(r.out.trimmingCharacters(in: .newlines))")
    r = h.run(["config", "init"])
    let template = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    check(r.code == 0 && DozerSettings.schema.allSatisfy { template.contains("\n# \($0.name) = \(TOML.render($0.defaultValue))\n") },
          "config init: doz.toml lists all \(DozerSettings.schema.count) settings, each commented at its default")
    var st = stat()
    check(stat(file.path, &st) == 0 && st.st_mode & 0o777 == 0o600, "the file is 0600")
    r = h.run(["config", "set", "ui.boot_view_on_start", "false"])
    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    check(r.code == 0 && text.contains("\nboot_view_on_start = false\n") && text.contains("\n# confirm_shutdown = true\n"),
          "config set ui.boot_view_on_start false: that line uncommented, the rest still at their defaults")
    r = h.run(["config", "get", "ui.boot_view_on_start"])
    check(r.code == 0 && r.out == "false\n", "config get: false")
    let report = h.run(["config", "show", "--json"])
    let rep = try? JSONDecoder().decode(SettingsReport.self, from: report.outData)
    check(rep?.settings.first { $0.key == "ui.boot_view_on_start" }?.source == .file, "config show --json: source file")
    check(rep?.settings.first { $0.key == "host.idle_timeout_minutes" }?.source == .env, "DOZ_HOST_IDLE (the harness's) shows as source env")
    check(rep?.settings.first { $0.key == "store.path" }?.source == .env, "DOZ_STORE shows as source env")
    let flagged = h.run(["config", "get", "store.path", "--store", "/tmp/elsewhere", "--json"])
    check(flagged.out.contains("\"source\" : \"flag\""), "--store shows as source flag")
    r = h.run(["config", "set", "ui.terminal_font_size", "200"])
    check(r.code == 64 && r.err.contains("9–32"), "config set: out of range → usage error (\(r.code))")
    r = h.run(["config", "set", "ui.nope", "1"])
    check(r.code == 64 && r.err.contains("unknown setting"), "config set: unknown key → usage error")
    r = h.run(["config", "unset", "ui.boot_view_on_start"])
    check(r.code == 0 && h.run(["config", "get", "ui.boot_view_on_start"]).out == "true\n", "config unset: back to the default")
    // An unknown key in the file is a warning, never a failure.
    try? ((try? String(contentsOf: file, encoding: .utf8)) ?? "").appending("\n[later]\nthing = 1\n").write(to: file, atomically: true, encoding: .utf8)
    r = h.run(["config", "show"])
    check(r.code == 0 && r.err.contains("unknown setting later.thing"), "an unknown key: a warning on stderr, exit 0")
    try? FileManager.default.removeItem(at: xdg)
}

/// What `du -sk` says a directory holds, in bytes.
func duBytes(_ url: URL) -> Int64 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
    p.arguments = ["-sk", url.path]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return -1 }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return (Int64(out.split(separator: "\t").first ?? "") ?? -1) * 1024
}

/// 595: while clia is hibernated and clib asleep — their snapshots need the guest init (and the kernel):
/// refused, with the reason, and nothing deleted; a sandbox's disks are refused too.
func cliResourcesRefusals(_ h: CLIHarness) {
    let initfs = h.store.appendingPathComponent("initfs.ext4")
    let plan = h.json(["resources", "rm", "initfs", "sandbox:clia", "sandbox:clib/root", "--dry-run"], ResourcePlan.self)
    let reason = plan?.refused.first { $0.id == "initfs" }?.reason ?? ""
    check(plan != nil && plan!.items.isEmpty && Set(plan!.refused.map(\.id)) == ["initfs", "sandbox:clia", "sandbox:clib/root"]
          && (reason.contains("hibernated") || reason.contains("asleep")),
          "resources rm --dry-run: the guest init is refused while a snapshot needs it (\(reason.prefix(90))); a sandbox's disks too")
    let r = h.run(["resources", "rm", "initfs", "--yes"])
    check(r.code != 0 && FileManager.default.fileExists(atPath: initfs.path), "resources rm initfs --yes: refused (exit \(r.code)), nothing deleted")
    let rep = h.json(["resources"], ResourceReport.self)
    check(rep?.memory.contains { $0.name == "clib" && $0.heldBytes > 0 } ?? false, "resources: clib (asleep) holds its memory")
    check(rep?.memory.contains { $0.kind == "host" && $0.heldBytes > 0 } ?? false, "resources: the host's own memory is on the account")
    check(!(rep?.memory.contains { $0.name == "clia" } ?? true), "…and clia (hibernated) holds none")
}

/// 595: with every sandbox off — the account adds up to du, --dry-run deletes nothing, a deletion frees
/// what it said and is re-created on next use, clean is the safe set, logs and metrics clear, the kernel choice.
func cliResourcesChecks(_ h: CLIHarness) {
    let fm = FileManager.default
    let store = h.store
    let off = h.ls().allSatisfy { $0.phase == "off" }
    check(off, "resources: every sandbox is off for these checks (\(h.ls().map { "\($0.name) \($0.phase)" }.joined(separator: ", ")))")
    guard let rep = h.json(["resources"], ResourceReport.self) else { check(false, "resources --json"); return }
    let du = duBytes(store)
    check(rep.unattributedBytes == 0, "resources: every byte of the store is on a row (unattributed \(rep.unattributedBytes) of \(DozerImages.formatBytes(rep.totalBytes)))")
    check(abs(rep.totalBytes - du) <= 2 << 20, "resources: the total is what du counts (\(rep.totalBytes) vs du \(du))")
    let top = rep.items.filter { $0.parent == nil && $0.group != "outside" }.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
    check(top == rep.totalBytes, "resources: the top-level rows add up to the total")
    check(rep.items.first { $0.id == "sandbox:clib" }.map { !$0.deletable && $0.link == "sandbox:clib" } ?? false,
          "resources: a sandbox is not deleted here — it links to its page")
    check(rep.items.first { $0.id == "stray:workspace-cli" }?.refusal?.contains("workspace") ?? false,
          "resources: a folder in the store that is a sandbox's workspace is refused")
    check(rep.items.contains { $0.id == "outside:settings" } && rep.items.contains { $0.id == "outside:keychain" },
          "resources: the settings file and the keychain entries (names) are shown outside the store")
    let text = h.run(["resources"])
    check(text.code == 0 && text.out.contains("unattributed") && text.out.contains("SANDBOXES") && text.out.contains("MEMORY"),
          "resources (text): the groups, the unattributed row, memory")

    // A stale kernel file in the store's own kernels/ (the suite's kernel cache is elsewhere): unused → clean-up.
    let stale = store.appendingPathComponent("kernels/vmlinux-0.0-clitest")
    try? fm.createDirectory(at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(repeating: 7, count: 256 << 10).write(to: stale)
    let dryClean = h.json(["resources", "clean", "--dry-run"], ResourcePlan.self)
    let never = ["template:", "sandbox:", "point:", "screens:", "boots:", "stray:", "outside:"]
    check(dryClean != nil && dryClean!.items.contains { $0.id == "kernel:0.0-clitest" }
          && !dryClean!.items.contains { e in never.contains { e.id.hasPrefix($0) } || ["logs", "metrics", "initfs", "store"].contains(e.id) }
          && fm.fileExists(atPath: stale.path),
          "resources clean --dry-run: the safe set (\(dryClean?.items.map(\.id).joined(separator: " ") ?? "?")), nothing deleted")

    // --dry-run deletes nothing.
    let initfs = store.appendingPathComponent("initfs.ext4"), content = store.appendingPathComponent("content")
    let golden = (try? fm.contentsOfDirectory(atPath: store.appendingPathComponent("golden").path))?.filter { !$0.hasSuffix(".fsck.ext4") && $0.hasSuffix(".ext4") } ?? []
    let ids = ["initfs", "cache:downloads", "image:lab", "kernel:0.0-clitest"]
    let dry = h.json(["resources", "rm"] + ids + ["--dry-run"], ResourcePlan.self)
    check(dry.map { $0.dryRun && Set($0.items.map(\.id)) == Set(ids) && $0.refused.isEmpty } ?? false
          && fm.fileExists(atPath: initfs.path) && fm.fileExists(atPath: content.path) && !golden.isEmpty,
          "resources rm --dry-run: the plan (frees \(DozerImages.formatBytes(dry?.freedBytes ?? 0))), and nothing deleted")
    check(dry?.items.first { $0.id == "image:lab" }?.later?.contains("re-prepared") ?? false, "…with what each costs later")

    // Delete them: one operation; the volume gets back what it said.
    let before = rep.occupiedBytes
    let r = h.run(["resources", "rm"] + ids + ["--yes", "--json"])
    let done = try? HostWire.decoder.decode(ResourcePlan.self, from: r.outData)
    check(r.code == 0 && done.map { !$0.dryRun && Set($0.deleted) == Set(ids) && $0.failed.isEmpty } ?? false,
          "resources rm --yes: deleted \(done?.deleted.joined(separator: ", ") ?? "?")")
    check(!fm.fileExists(atPath: initfs.path) && !fm.fileExists(atPath: content.path) && !fm.fileExists(atPath: stale.path)
          && ((try? fm.contentsOfDirectory(atPath: store.appendingPathComponent("golden").path))?.filter { !$0.hasSuffix(".fsck.ext4") && $0.hasSuffix(".ext4") } ?? []).isEmpty,
          "the guest init, the download cache, the lab's prepared disks and the stale kernel are gone")
    let after = h.json(["resources"], ResourceReport.self)
    let got = before - (after?.occupiedBytes ?? before)
    let said = done?.freedBytes ?? 0
    check(after?.unattributedBytes == 0 && abs(got - said) <= 4 << 20,
          "the volume got back what it said: \(DozerImages.formatBytes(got)) of \(DozerImages.formatBytes(said)) (host.log and metrics grow meanwhile)")

    // Re-created on next use: clib (a clone of the deleted lab disk) still starts — the guest init is
    // rebuilt (the download cache pulled again); a new lab sandbox re-prepares the lab.
    var s = h.run(["start", "clib"], timeout: 600)
    check(s.code == 0 && h.row("clib")?.phase == "running" && fm.fileExists(atPath: initfs.path),
          "start clib: a sandbox cloned from the deleted image still starts; the guest init is re-created")
    check(h.run(["shutdown", "clib", "--yes"]).code == 0, "shutdown clib")
    s = h.run(["create", "clires", "--image", "lab", "--memory", "512M", "--isolated"])
    s = h.run(["start", "clires"], timeout: 900)
    let regolden = (try? fm.contentsOfDirectory(atPath: store.appendingPathComponent("golden").path))?.filter { !$0.hasSuffix(".fsck.ext4") && $0.hasSuffix(".ext4") } ?? []
    check(s.code == 0 && !regolden.isEmpty && fm.fileExists(atPath: content.path), "a new lab sandbox re-prepares the lab (and the download cache)")
    check(h.run(["rm", "clires", "--yes"]).code == 0, "rm clires")

    // Clean up: only re-creatable, unused things — and it says so.
    let c = h.run(["resources", "clean", "--yes", "--json"])
    let cleaned = try? HostWire.decoder.decode(ResourcePlan.self, from: c.outData)
    check(c.code == 0 && (cleaned?.deleted.contains("cache:downloads") ?? false)
          && !(cleaned?.deleted.contains { d in never.contains { d.hasPrefix($0) } || ["logs", "metrics", "initfs", "store"].contains(d) } ?? true),
          "resources clean --yes: \(cleaned?.deleted.joined(separator: " ") ?? "?") — never templates, sandboxes, points, logs, settings")
    check(h.row("clib") != nil && fm.fileExists(atPath: DozerStore(root: store).layout("clib").rootfs.path), "clib and its disk are untouched")

    // Logs and metrics clear.
    let log = store.appendingPathComponent("host.log")
    let logBefore = (try? fm.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
    let runsBefore = (h.json(["metrics"], [MetricsSummaryRow].self) ?? []).reduce(0) { $0 + $1.count }
    let lm = h.run(["resources", "rm", "logs", "metrics", "--yes"])
    let logAfter = (try? fm.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
    let runsAfter = (h.json(["metrics"], [MetricsSummaryRow].self) ?? []).reduce(0) { $0 + $1.count }
    check(lm.code == 0 && logAfter < logBefore && runsAfter < runsBefore,
          "resources rm logs metrics: host.log \(logBefore) → \(logAfter) bytes; metrics rows \(runsBefore) → \(runsAfter)")

    // The kernel new sandboxes boot.
    check(h.run(["resources", "kernel", "kernel:0.0-nope"]).code == 2, "resources kernel kernel:0.0-nope: not found (exit 2)")
    check(h.run(["resources", "kernel", "/tmp/vmlinux"]).code != 0, "resources kernel /tmp/vmlinux: not an id")
    let k = h.run(["resources", "kernel", "pinned"])
    let kp = h.run(["config", "get", "kernel.path"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
    check(k.code == 0 && (kp.isEmpty || kp == "\"\""), "resources kernel pinned: kernel.path is automatic again (\(kp.debugDescription))")
}

/// The CLI's own exit codes the suite checks (the CLI target is not linked here).
enum DozerCLIExit {
    static let failed: Int32 = 1
    static let exists: Int32 = 4
}

/// An array appended to from several threads.
final class LockedArray<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ x: T) { lock.withLock { items.append(x) } }
    var all: [T] { lock.withLock { items } }
}
