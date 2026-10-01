import Darwin
import Foundation
import DozerKit
import DozerHost

// 599c (owner, 2026-10-01: "add a "Quick Add" sandbox that picks defaults for workspace name etc and opens
// it immediately"): `doz new` — every default, created, started and attached. With `--detach`: it says what
// it chose, the sandbox runs a command, its folder `<defaults.projects_dir>/<name>` exists and IS its
// /workspace; again → `-2`; `--isolated`, `--name`, `--json`; a taken name is refused; pi without an API-key
// account (off a terminal) fails before anything is made; and on a terminal it attaches. Lab sandboxes
// (512 MiB), a scratch store (`/tmp/dzo-PID-n`) and `defaults.projects_dir` a scratch path
// (`/tmp/dzo-PID-np`).
func cliQuickAddSuite(binary: String) async {
    let t = onboardingHarness(binary, "n", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    let pid = getpid()
    let projects = "/tmp/dzo-\(pid)-np"
    let real = "/private" + projects
    defer {
        t.run(["host", "stop"])
        for p in [t.store.path, projects] { try? FileManager.default.removeItem(atPath: p) }
    }
    let fm = FileManager.default
    print("cli: doz new — a sandbox with every default (599c)")
    check(t.run(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    check(t.run(["config", "set", "defaults.projects_dir", projects]).code == 0, "defaults.projects_dir is a scratch path (\(projects))")
    check(t.run(["config", "set", "defaults.image", "lab"]).code == 0 && t.run(["config", "set", "images.lab.memory_mib", "512"]).code == 0,
          "defaults.image lab, 512 MiB")

    // 1. --detach: what it chose, created + started, a command runs, the folder is its /workspace.
    var r = t.run(["new", "--detach"], timeout: 600)
    check(r.code == 0, "doz new --detach (exit \(r.code))")
    let first = r.out.split(separator: "\n").first.map(String.init) ?? ""
    check(first == "lab-sandbox · lab · \(projects)/lab-sandbox" || first == "lab-sandbox · lab · \(real)/lab-sandbox",
          "it says what it chose: \(first)")
    check(r.out.contains("lab-sandbox is running; session shell"), "started, its session open: \(r.out.split(separator: "\n").last ?? "")")
    check(t.row("lab-sandbox")?.phase == "running", "lab-sandbox is running")
    var isDir: ObjCBool = false
    check(fm.fileExists(atPath: projects + "/lab-sandbox", isDirectory: &isDir) && isDir.boolValue, "its folder \(projects)/lab-sandbox exists")
    r = t.run(["exec", "lab-sandbox", "--", "sh", "-c", "uname -s; echo from-the-sandbox > /workspace/hello.txt"])
    check(r.code == 0 && r.out == "Linux\n", "doz exec lab-sandbox -- uname -s → Linux (\(r.out.debugDescription))")
    check((try? String(contentsOfFile: projects + "/lab-sandbox/hello.txt", encoding: .utf8)) == "from-the-sandbox\n",
          "what it wrote in /workspace is in the Mac folder")

    // 2. Again: -2 (the default image is the setting's).
    r = t.run(["new", "-d"], timeout: 600)
    check(r.code == 0 && r.out.hasPrefix("lab-sandbox-2 · lab · "), "doz new -d again → lab-sandbox-2 (\(r.out.split(separator: "\n").first ?? ""))")
    check(t.row("lab-sandbox-2")?.phase == "running" && fm.fileExists(atPath: projects + "/lab-sandbox-2"), "lab-sandbox-2 runs, its folder exists")

    // 3. --isolated --name --json: one thing each.
    r = t.run(["new", "--isolated", "--name", "quiet-one", "--json"], timeout: 600)
    let j = (try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any] ?? [:]
    check(r.code == 0 && j["name"] as? String == "quiet-one" && j["image"] as? String == "lab" && j["phase"] as? String == "running"
          && j["session"] as? String == "shell" && j["workspace"] is NSNull,
          "doz new --isolated --name quiet-one --json → {name, image, phase running, session, workspace null}: \(r.out.prefix(200))")
    check(!fm.fileExists(atPath: projects + "/quiet-one"), "isolated: no folder made")
    check(t.row("quiet-one")?.workspace == nil, "quiet-one shares nothing")

    // 4. A taken name: refused (exit 4), nothing changes.
    r = t.run(["new", "--name", "lab-sandbox", "-d"])
    check(r.code == 4 && r.err.contains("already exists"), "doz new --name lab-sandbox → exit 4, already exists (\(r.code))")

    // 5. pi with no API-key account, off a terminal: the next step, before anything is made.
    r = t.run(["new", "--image", "pi", "-d"])
    check(r.code != 0 && r.err.contains("pi needs an Anthropic API key"), "doz new --image pi (no API-key account) → refused with the requirement (\(r.code))")
    check(r.err.contains("doz account default NAME"), "and how doz new would use one (the default account)")
    check(t.row("pi-sandbox") == nil && !fm.fileExists(atPath: projects + "/pi-sandbox"), "nothing made for it")

    // 6. On a terminal: it attaches (Ctrl-] twice detaches; the sandbox keeps running).
    do {
        let c = try PTYClient(t, ["new", "--name", "attached"])
        defer { c.close() }
        // (An out-of-date lab image is asked about on a terminal, as doz create asks: Enter keeps it.)
        _ = c.wait(300) { $0.text.contains("attaching to") || $0.text.contains("Rebuild it first") }
        if c.text.contains("Rebuild it first") { c.type("\r") }
        check(c.wait(300) { $0.text.contains("attaching to shell") }, "doz new --name attached: \"… started in N ms — attaching to shell\"")
        c.type("echo NEW-$((40+2))\r")
        check(c.wait(30) { $0.text.contains("NEW-42") }, "the attached shell answers")
        c.type("\u{1D}\u{1D}")
        check(c.exited(within: 15) == 0, "Ctrl-] twice detaches (exit 0)")
        check(t.row("attached")?.phase == "running", "attached keeps running")
    } catch {
        check(false, "a pseudo-terminal for doz new: \(error)")
    }

    for n in ["lab-sandbox", "lab-sandbox-2", "quiet-one", "attached"] { t.run(["rm", n, "--yes"], timeout: 120) }
}
