import DozerHost
import DozerKit
import Foundation

/// 594 W25–W27 (the owner's walkthrough, step 8–9): restore point names are never cut, and a point is
/// found by its name, its id or an unambiguous prefix (W25); a confirming command checks what it is
/// about BEFORE it asks (W26); `doz exec` / `doz run` start a sandbox that is off (W27). Lab
/// sandboxes in a store of their own (`/tmp/dzo-PID-p`).
func cliPointsSuite(binary: String) async {
    let t = onboardingHarness(binary, "p", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    defer {
        t.run(["host", "stop"])
        try? FileManager.default.removeItem(at: t.store)
    }
    print("cli: restore point names and lookups (W25), check before asking (W26), exec starts an off sandbox (W27)")
    check(t.run(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    // W27: `create --start`.
    var r = t.run(["create", "pq", "--image", "lab", "--isolated", "--memory", "512M", "--start", "--json"], timeout: 600)
    let made = try? HostWire.decoder.decode(SandboxInfo.self, from: r.outData)
    check(r.code == 0 && made?.phase == "running", "create --start: pq created and running (\(made?.phase ?? "?"))")

    // W25: a long name, stored as typed; found by it, by the id, by a prefix.
    let long = "before-experiment-with-a-longer-name"
    r = t.run(["point", "take", "pq", long, "--json"], timeout: 60)
    let p1 = try? HostWire.decoder.decode(RestorePoint.self, from: r.outData)
    check(r.code == 0 && p1?.name == long, "point take pq \(long): stored as typed (\(p1?.name ?? "?"))")
    check(t.run(["point", "ls", "pq"]).out.contains(long + "  "), "point ls: the NAME column is not cut")
    r = t.run(["point", "take", "pq", String(repeating: "x", count: 65)])
    check(r.code != 0 && r.err.contains("at most 64 characters (this one has 65)"), "a 65-character name is refused, with the limit: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
    check(t.run(["point", "take", "pq", "before-deploy"], timeout: 60).code == 0, "point take pq before-deploy")
    r = t.run(["point", "fork", "pq", long, "pq-fork", "--json"], timeout: 60)
    check(r.code == 0, "point fork by the exact long name (\(r.code))")
    r = t.run(["point", "revert", "pq", "before-", "--yes"])
    check(r.code != 0 && r.err.contains("could be 2 restore points") && r.err.contains(long) && r.err.contains("before-deploy"),
          "an ambiguous prefix is refused, listing the matches: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))")
    r = t.run(["point", "revert", "pq", "before-exp", "--yes"], timeout: 120)
    check(r.code == 0 && r.out.contains(long), "point revert by a unique prefix (\(r.code))")
    if let id = p1?.id {
        r = t.run(["point", "rm", "pq", id, "--yes"])
        check(r.code == 0 && r.out.contains(long), "point rm by the id")
    }

    // W26: nothing is asked about what is not there (no terminal here: a question would say "pass --yes").
    for (args, want) in [(["point", "revert", "pq", "nope"], "no restore point nope"), (["point", "rm", "pq", "nope"], "no restore point nope"),
                         (["reset", "nosuch"], "no sandbox nosuch"), (["rm", "nosuch"], "no sandbox nosuch"),
                         (["shutdown", "nosuch"], "no sandbox nosuch"), (["image", "rm", "nosuch"], "no image nosuch"),
                         (["template", "rm", "nosuch"], "no template nosuch")] {
        r = t.run(args)
        check(r.code != 0 && r.err.contains(want) && !r.err.contains("pass --yes"), "\(args.joined(separator: " ")): \"\(want)\" before any question")
    }
    do {
        let c = try PTYClient(t, ["point", "revert", "pq", "nope"])
        defer { c.close() }
        let code = c.exited(within: 20)
        check(code != nil && code != 0 && !c.text.contains("[y/N]") && c.text.contains("no restore point nope"),
              "on a pty: revert of a missing point fails without a prompt")
    } catch { check(false, "pty: \(error)") }
    // A point that exists IS asked about (here: the question, then "no terminal to ask"), naming it fully.
    r = t.run(["point", "revert", "pq", "before-deploy"])
    check(r.err.contains("Revert pq to before-deploy (rp-") && r.err.contains(", taken ") && r.err.contains("pass --yes"),
          "a point that exists is asked about, naming its name, id and when it was taken: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))")

    // W27: exec and run start a sandbox that is off; --no-start refuses; the JSON says what happened.
    check(t.run(["shutdown", "pq", "--yes"], timeout: 120).code == 0, "shutdown pq")
    r = t.run(["exec", "pq", "--no-start", "--", "true"])
    check(r.code != 0 && r.err.contains("pq is off — `doz start pq` boots it"), "exec --no-start on an off sandbox: refused, as before")
    r = t.run(["exec", "pq", "--json", "--", "echo", "hi"], timeout: 300)
    let j = (try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any]
    check(r.code == 0 && (j?["stdout"] as? String) == "hi\n", "exec on an off sandbox starts it and runs (\(r.code))")
    check(j?["started"] as? Bool == true && j?["woke"] as? Bool == false && ((j?["bootMilliseconds"] as? Double) ?? 0) > 0,
          "--json: started true, woke false, bootMilliseconds")
    check(t.row("pq")?.phase == "running", "pq runs")
    check(t.run(["hibernate", "pq"], timeout: 120).code == 0, "hibernate pq")
    r = t.run(["exec", "pq", "--json", "--", "true"], timeout: 120)
    let w = (try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any]
    check(w?["woke"] as? Bool == true && w?["started"] as? Bool == false, "--json after a hibernate: woke true, started false")
    check(t.run(["shutdown", "pq", "--yes"], timeout: 120).code == 0, "shutdown pq")
    r = t.run(["run", "pq", "--detach", "--json", "--session", "bg", "--", "sleep", "60"], timeout: 300)
    let o = try? HostWire.decoder.decode(SessionOpened.self, from: r.outData)
    check(r.code == 0 && o?.started == true && o?.session == "bg", "run --detach on an off sandbox starts it (started: \(o?.started.map(String.init) ?? "nil"))")
    check(t.run(["shutdown", "pq", "--yes"], timeout: 120).code == 0, "shutdown pq")
    r = t.run(["run", "pq", "--detach", "--no-start", "--", "sleep", "1"])
    check(r.code != 0 && r.err.contains("`doz start pq` boots it"), "run --no-start on an off sandbox: refused")

    // W12: doz up in a project folder says what differs from the sandbox, and when it applies —
    // and applies a proxied preset now (live).
    let folder = URL(fileURLWithPath: "/tmp/dzo-\(getpid())-pw")
    try? FileManager.default.removeItem(at: folder)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let yaml = folder.appendingPathComponent("doz_project.yaml")
    try? "version: 1\nname: pw\nimage: lab\ncpus: 1\nmemory: 512M\nnetwork: bake\n".write(to: yaml, atomically: true, encoding: .utf8)
    func up() -> CLIRun {
        let p = t.process(["up", "--detach"])
        p.currentDirectoryURL = folder
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        p.standardInput = FileHandle.nullDevice
        let oc = PipeCollector(o.fileHandleForReading), ec = PipeCollector(e.fileHandleForReading)
        try? p.run()
        p.waitUntilExit()
        oc.wait(5); ec.wait(5)
        return CLIRun(code: p.terminationStatus, out: oc.text, err: ec.text, outData: oc.bytes)
    }
    r = up()
    check(r.code == 0, "doz up in a project folder makes pw (\(r.code)): \(r.err.suffix(200))")
    try? "version: 1\nname: pw\nimage: lab\ncpus: 2\nmemory: 1G\nnetwork: locked\n".write(to: yaml, atomically: true, encoding: .utf8)
    r = up()
    check(r.code == 0 && r.err.contains("cpus 1 → 2 in doz_project.yaml: applies only when the sandbox is made — doz rm pw && doz up recreates it"),
          "doz up says cpus changed and when it applies")
    check(r.err.contains("memory 512 MiB → 1 GiB in doz_project.yaml: applies only when the sandbox is made"), "…and memory")
    check(r.err.contains("network bake → locked in doz_project.yaml: applied now (live"), "…and applies the network preset now")
    check(t.run(["net", "policy", "pw"]).out.hasPrefix("pw: locked preset"), "pw's policy is locked")
    r = up()
    check(!r.err.contains("network bake → locked"), "the next doz up has nothing more to say about the network")
}
