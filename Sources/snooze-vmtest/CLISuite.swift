// `snooze-vmtest cli --snooze PATH` (585, `make test-cli`): the snooze CLI end to end — the REAL signed
// binary, every call a SEPARATE process, against a scratch store. The host is whatever those
// processes start (a detached child of the first), exactly as a user gets it.
//
//   up (attached) → exec → run + attach from a second process → close the first → reattach, same pid
//   pause / resume → deep sleep (hibernate) → wake: the SAME attached client is held and reattached
//   restore point take → revert → cold-boot → the change is gone
//   two sandboxes at once; `ls --json` from another process; key set via stdin (a fake key: the guest
//   sees only a placeholder); net policy / log; metrics; doctor
//   kill -9 the host → the next call starts a new one: the sandbox left asleep is restored (and asleep
//   again), the deep-asleep one wakes with the same pid
//   shutdown / rm; a read-only command starts no host; the host exits by itself when idle.
//
// Inputs: --snooze PATH (default .build/debug/snooze), --store DIR (default $TMPDIR/snooze-clitest-store),
// $SNOOZE_KERNEL_CACHE (default: the vmtest store's cache when it holds the kernel). Sandboxes are
// named clia / clib; nothing outside the store is touched. Never the keychain.
import Darwin
import Foundation
import SnoozeContainerKit
import SnoozeHost

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
        e["SNOOZE_STORE"] = store.path
        e["SNOOZE_HOST_IDLE"] = "30"          // the suite stops the host itself; the idle test sets its own
        let vmtestKernels = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snooze-vmtest-store/kernels")
        if (e["SNOOZE_KERNEL_CACHE"] ?? "").isEmpty,
           FileManager.default.fileExists(atPath: vmtestKernels.appendingPathComponent(KernelArtifact.recommended.fileName).path) {
            e["SNOOZE_KERNEL_CACHE"] = vmtestKernels.path
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

    /// Run `snooze args…` to completion (killed after `timeout`).
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
        if r.code != 0 { info("snooze \(args.joined(separator: " ")) → \(r.code): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))") }
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
    var hostRunning: Bool { SnoozeStore(root: store).hostIsRunning() }

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
        if let i = args.firstIndex(of: "--snooze"), i + 1 < args.count { return args[i + 1] }
        return ".build/debug/snooze"
    }()
    let h = CLIHarness(binary: URL(fileURLWithPath: binary).standardizedFileURL.path, store: storeRoot)
    try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
    let ws = storeRoot.appendingPathComponent("workspace-cli")
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    try tickScript.write(to: ws.appendingPathComponent("tick.sh"), atomically: true, encoding: .utf8)
    info("snooze \(h.binary) · store \(storeRoot.path) · kernel cache \(h.env["SNOOZE_KERNEL_CACHE"] ?? "(under the store)")")

    var clients: [AttachedClient] = []
    func cleanUp() {
        for c in clients { c.close() }
        h.run(["rm", "clia", "--yes"])
        h.run(["rm", "clib", "--yes"])
        h.run(["host", "stop"])
    }
    // A previous run that died part-way.
    if h.hostRunning { h.run(["host", "stop"]) }
    for n in ["clia", "clib"] where FileManager.default.fileExists(atPath: SnoozeStore(root: storeRoot).configFile(n).path) {
        h.run(["rm", n, "--yes"])
    }
    if h.hostRunning { h.run(["host", "stop"]) }

    do {
        // 588: this scratch store's proxied sandboxes follow no account — the suite never reads the Mac's login.
        check(h.run(["account", "default", "none"]).code == 0, "account default none")
        print("cli: doctor")
        let doctor = h.run(["doctor", "--json"])
        check(doctor.out.contains("\"check\" : \"entitlement\"") && !doctor.out.contains("\"status\" : \"fail\""),
              "doctor: the binary carries the virtualization entitlement, nothing fails (exit \(doctor.code))")

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

        print("cli: pause / resume, deep sleep / wake with a client attached")
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
        let deep = h.row("clia")
        check(r.code == 0 && deep?.phase == "deepAsleep" && deep?.ramHeldMiB == 0, "hibernate (deep sleep): deep asleep, RAM held 0")
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
        check(c3.exited(within: 10) == SnoozeCLIExit.failed, "the attached client ends: the sandbox shut down, the session is gone")
        r = h.run(["cold-boot", "clia"])
        check(r.code == 0 && h.row("clia")?.phase == "running", "cold-boot (alias of start) boots the reverted disk")
        r = h.run(["exec", "clia", "--", "test", "-e", "/root/after-p1"])
        check(r.code == 1, "the file written after p1 is gone")

        print("cli: two sandboxes at once")
        r = h.run(["create", "clib", "--image", "lab", "--memory", "512M", "--workspace", ws.path])
        check(r.code == 0, "create clib")
        r = h.run(["start", "clib"])
        let both = h.ls()
        check(r.code == 0 && both.filter { ["clia", "clib"].contains($0.name) && $0.phase == "running" }.count == 2,
              "ls --json (another process): clia and clib both running")
        let ha = h.run(["exec", "clia", "--", "hostname"]).out, hb = h.run(["exec", "clib", "--", "hostname"]).out
        check(ha == "clia\n" && hb == "clib\n", "exec reaches each: \(ha.trimmingCharacters(in: .whitespacesAndNewlines)) / \(hb.trimmingCharacters(in: .whitespacesAndNewlines))")

        print("cli: key (stdin, a fake key), net policy / log")
        let fake = "sk-ant-FAKE-snooze-clitest-0000"
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
        check(h.run(["deep-sleep", "clia"]).code == 0 && h.run(["sleep", "clib"]).code == 0, "clia deep asleep, clib asleep (RAM kept, snapshot on disk)")
        guard let hostPID = h.hostPID() else { throw SandboxError.timedOut("no host pid") }
        kill(hostPID, SIGKILL)
        check(h.waitFor(10) { !h.hostRunning }, "kill -9 \(hostPID): the host is gone")
        let t9 = Date()
        let after = h.ls()
        check(h.hostRunning && h.hostPID() != hostPID, String(format: "the next call (ls) started a new host (pid %@, %.2f s)",
                                                               h.hostPID().map(String.init) ?? "?", Date().timeIntervalSince(t9)))
        check(after.contains { $0.name == "clia" && $0.phase == "deepAsleep" }, "clia is still deep asleep")
        check(h.waitFor(60) { h.row("clib").map { $0.phase == "asleep" && !$0.busy } ?? false },
              "clib, asleep when the host died, was restored and is asleep again")
        r = h.run(["wake", "clia"])
        check(r.code == 0 && h.sessions("clia").first { $0.name == "tick2" }?.pid == p1, "wake clia in the new host: tick2 has the same pid (\(p1.map(String.init) ?? "?"))")
        r = h.run(["wake", "clib"])
        check(r.code == 0 && h.sessions("clib").first { $0.name == "tb" }?.pid == p2, "wake clib: tb has the same pid (\(p2.map(String.init) ?? "?"))")

        print("cli: metrics")
        let rows = h.json(["metrics"], [MetricsSummaryRow].self) ?? []
        for action in ["start", "wake", "deep sleep", "restore after crash"] {
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
        h.run(["host", "stop"])
        check(!h.hostRunning, "host stop: no host")
        _ = h.ls()
        check(!h.hostRunning, "ls with nothing running answers from the store — it starts no host")
        r = h.run(["host", "--idle-timeout", "0.05"])
        check(r.code == 0 && h.hostRunning, "host --idle-timeout 0.05 (3 s)")
        let ti = Date()
        check(h.waitFor(30) { !h.hostRunning }, String(format: "the idle host exited by itself after %.1f s", Date().timeIntervalSince(ti)))
        check(!FileManager.default.fileExists(atPath: SnoozeStore(root: storeRoot).socket.path), "and removed its socket")
        r = h.run(["rm", "clib", "--yes"])
        check(r.code == 0, "rm clib")
    } catch {
        check(false, "aborted: \(error)")
    }
    cleanUp()
    check(!h.hostRunning, "cleanup: no host left running")
}

/// The CLI's own exit codes the suite checks (the CLI target is not linked here).
enum SnoozeCLIExit {
    static let failed: Int32 = 1
}
