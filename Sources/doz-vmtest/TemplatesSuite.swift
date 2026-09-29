import Darwin
import Foundation
import DozerKit
import DozerHost

// 593 — templates and duplicates on an AGENT image (pi: it has a state disk), with the real signed
// `doz` from separate processes (`make test-vm-templates`). The rules under test:
//   · a template is the ROOT disk only — never the state disk (the agent's logins and history);
//   · a sandbox created from a template has the root disk's files and a fresh state disk;
//   · duplicate: the new workspace at /workspace, the root disk's files, a FRESH state disk — or,
//     with --copy-state, the source's;
//   · a workspace that does not exist is refused, never created.
// Store: --store (default $TMPDIR/doz-templates-store), a scratch store; images are seeded from
// $DOZ_SEED_STORE or the vmtest store when they are there (APFS clones), else pi bakes (network).
// Sandboxes tpa / tpb / tpc / tpd; the template tpl-pi. The scratch store follows no account.

func templatesSuite() async throws {
    let binary: String = {
        if let i = args.firstIndex(of: "--doz"), i + 1 < args.count { return args[i + 1] }
        return ".build/debug/doz"
    }()
    let h = CLIHarness(binary: URL(fileURLWithPath: binary).standardizedFileURL.path, store: storeRoot)
    try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
    seedImages(into: storeRoot)
    info("doz \(h.binary) · store \(storeRoot.path)")
    let names = ["tpa", "tpb", "tpc", "tpd", "tpe"]
    func cleanUp() {
        for n in names { h.run(["rm", n, "--yes"]) }
        h.run(["template", "rm", "tpl-pi", "--yes"])
        h.run(["host", "stop"])
    }
    cleanUp()
    let ws1 = storeRoot.appendingPathComponent("ws-one"), ws2 = storeRoot.appendingPathComponent("ws-two")
    for (d, m) in [(ws1, "one"), (ws2, "two")] {
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try "\(m)\n".write(to: d.appendingPathComponent("which"), atomically: true, encoding: .utf8)
    }
    let state = "/home/agent/.pi/agent"                   // pi's persist dir: on the state disk
    func sh(_ name: String, _ script: String) -> CLIRun { h.run(["exec", name, "--", "sh", "-c", script], timeout: 120) }

    check(h.run(["account", "default", "none"]).code == 0, "account default none (a scratch store never reads the Mac's login)")
    var r = h.run(["create", "tpa", "--image", "pi", "--memory", "1G", "--network", "locked", "--workspace", ws1.path])
    check(r.code == 0, "create tpa --image pi --workspace ws-one")
    r = h.run(["start", "tpa"], timeout: 1200)
    check(r.code == 0, "start tpa (a first start in the store bakes pi: minutes)")
    r = sh("tpa", "echo rootmark > /home/agent/rootmark && echo statemark > \(state)/statemark && sync && cat /workspace/which")
    check(r.code == 0 && r.out == "one\n", "tpa: a root-disk marker, a state-disk marker, ws-one at /workspace (\(r.out.replacingOccurrences(of: "\n", with: " ")) \(r.err.prefix(120)))")

    // The template, while tpa RUNS.
    r = h.run(["template", "create", "tpa", "--as", "tpl-pi", "--note", "templates suite"])
    check(r.code == 0, "template create tpa --as tpl-pi (running)")
    let tpl = DozerStore(root: storeRoot).layout("_").customImages().first { $0.name == "tpl-pi" }
    if let tpl {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: DozerStore(root: storeRoot).layout("_").customImageDirectory(tpl.key).path).sorted()) ?? []
        check(files == ["image.json", "root.ext4"], "the template holds no state disk (\(files.joined(separator: ", ")))")
        check(tpl.imageSpec?.name == "pi", "it keeps the image spec (user, persist dirs) of pi")
    } else { check(false, "tpl-pi is in the store") }
    r = h.run(["create", "tpb", "--image", "tpl-pi", "--memory", "1G", "--network", "locked"])
    check(r.code == 0 && h.run(["start", "tpb"], timeout: 600).code == 0, "a sandbox from the template starts")
    check(sh("tpb", "cat /home/agent/rootmark").out == "rootmark\n", "tpb has the root disk's file")
    r = sh("tpb", "cat \(state)/statemark 2>/dev/null || echo none; test -d \(state) && echo dir")
    check(r.out == "none\ndir\n", "tpb's state disk is fresh: no state marker, the persist dir there (\(r.out.replacingOccurrences(of: "\n", with: " ")))")

    // Duplicate the running tpa with a new workspace: the state disk fresh…
    r = h.run(["duplicate", "tpa", "tpc", "--workspace", ws2.path, "--cpus", "1"])
    check(r.code == 0 && h.row("tpc")?.phase == "off", "duplicate tpa tpc --workspace ws-two (tpa running): tpc is off")
    check(!FileManager.default.fileExists(atPath: DozerStore(root: storeRoot).layout("tpc").stateDisk.path), "tpc has no state disk yet (made empty on its first boot)")
    check(h.run(["start", "tpc"], timeout: 600).code == 0, "start tpc")
    r = sh("tpc", "cat /workspace/which /home/agent/rootmark; cat \(state)/statemark 2>/dev/null || echo none")
    check(r.out == "two\nrootmark\nnone\n", "tpc: ws-two at /workspace, the root disk's file, a FRESH state disk (\(r.out.replacingOccurrences(of: "\n", with: " ")))")
    // …or copied, on request.
    r = h.run(["duplicate", "tpa", "tpd", "--copy-state"])
    check(r.code == 0 && h.run(["start", "tpd"], timeout: 600).code == 0, "duplicate tpa tpd --copy-state; start tpd")
    r = sh("tpd", "cat /workspace/which \(state)/statemark")
    check(r.out == "one\nstatemark\n", "tpd: ws-one kept, the state disk copied (\(r.out.replacingOccurrences(of: "\n", with: " ")))")
    // A workspace that does not exist.
    let missing = storeRoot.appendingPathComponent("ws-missing")
    r = h.run(["duplicate", "tpa", "tpe", "--workspace", missing.path])
    check(r.code == 2 && !FileManager.default.fileExists(atPath: missing.path) && h.row("tpe") == nil, "a missing workspace is refused, and not created")

    cleanUp()
    check(!h.hostRunning, "cleanup: no host left running")
}
