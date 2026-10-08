import Darwin
import Foundation
import DozerKit
import DozerHost

// 599f (owner, 2026-10-02: "a new wizard process for creating a purposeful sandbox that steps the user through
// all the choices, capturing the config in a doz_project.yml in the project / working dir"):
//   1. `doz init DIR --yes` with flags writes the file (every choice in it), and `doz up -d` IN that folder makes
//      exactly that sandbox — memory, network permissions, its own clipboard and tmux, the folder at /workspace;
//   2. doz_project.yml is read too; both spellings in one folder is refused with a message;
//   3. an interactive `doz init` on a pseudo-terminal walks the wizard's steps (Step N of 10), with defaults on
//      Enter, shows the file and writes it on a yes; run again in the same folder it starts from the file and
//      replaces it only after showing the diff and a yes.
// Lab sandboxes (512 MiB), a scratch store (`/tmp/dzo-PID-w`) and scratch project folders (`/tmp/dzo-PID-wp`).
func cliProjectWizardSuite(binary: String) async {
    let t = onboardingHarness(binary, "w", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    let pid = getpid()
    let root = "/tmp/dzo-\(pid)-wp"
    let fm = FileManager.default
    defer {
        t.run(["host", "stop"])
        for p in [t.store.path, root] { try? fm.removeItem(atPath: p) }
    }
    try? fm.removeItem(atPath: root)
    try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    /// `doz args…` with `folder` as its working folder (doz up with no name reads that folder's project file).
    func runIn(_ folder: String, _ args: [String], timeout: Double = 600) -> CLIRun {
        let p = t.process(args)
        p.currentDirectoryURL = URL(fileURLWithPath: folder)
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return CLIRun(code: -1, out: "", err: "\(error)", outData: Data()) }
        let oc = PipeCollector(o.fileHandleForReading), ec = PipeCollector(e.fileHandleForReading)
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        oc.wait(5); ec.wait(5)
        let r = CLIRun(code: p.terminationStatus, out: oc.text, err: ec.text, outData: oc.bytes)
        if r.code != 0 { info("doz \(args.joined(separator: " ")) in \(folder) → \(r.code): \(r.err.suffix(300))") }
        return r
    }
    func file(_ dir: String, _ name: String = "doz_project.yaml") -> String { (try? String(contentsOfFile: dir + "/" + name, encoding: .utf8)) ?? "" }

    print("cli: the project file — doz init's steps, doz up makes what it says (599f)")
    check(t.run(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    check(t.run(["config", "set", "images.lab.memory_mib", "512"]).code == 0 && t.run(["config", "set", "defaults.image", "lab"]).code == 0,
          "defaults.image lab, 512 MiB")

    // 1. doz init --yes with every choice as a flag, then doz up in the folder.
    let alpha = root + "/alpha"
    var r = t.run(["init", alpha, "--yes", "--name", "alpha", "--image", "lab", "--network", "agent", "--permissions", "-error-reports",
                   "--memory", "640M", "--clipboard", "off", "--tmux", "--ssh-agent", "off"])
    check(r.code == 0, "doz init \(alpha) --yes --network agent --permissions -error-reports --memory 640M --clipboard off --tmux (exit \(r.code))")
    let a = file(alpha)
    for line in ["name: alpha\n", "image: lab ", "memory: 640M ", "network: agent\n", "permissions: -error-reports\n", "clipboard: off\n", "tmux: true\n",
                 "ssh_agent: off\n", "# cpus: 2 "] {
        check(a.contains(line), "the file says \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    r = runIn(alpha, ["up", "-d"])
    check(r.code == 0, "doz up -d in \(alpha) (exit \(r.code))")
    let row = t.row("alpha")
    check(row?.phase == "running" && row?.memoryMiB == 640, "alpha runs with 640 MiB (\(row?.phase ?? "—"), \(row?.memoryMiB ?? 0))")
    check(row?.workspace == alpha || row?.workspace == "/private" + alpha, "its /workspace is the folder (\(row?.workspace ?? "—"))")
    let perms = t.json(["net", "show", "alpha"], PermissionReport.self)?.permissions ?? []
    let on = { (id: String) in perms.first { $0.id == id }?.on }
    check(on("error-reports") == false && on("model") == true && on("update") == true, "its permissions: Standard without error reports")
    check(t.run(["config", "get", "sandbox.clipboard", "--sandbox", "alpha"]).out == "off\n", "its own clipboard: off")
    check(t.run(["config", "get", "sessions.tmux", "--sandbox", "alpha"]).out == "true\n", "its own tmux: true")
    r = t.run(["exec", "alpha", "--", "ls", "/workspace"])
    check(r.out.contains("doz_project.yaml"), "the file is in its /workspace")

    // 2. doz_project.yml; both spellings.
    let beta = root + "/beta"
    try? fm.createDirectory(atPath: beta, withIntermediateDirectories: true)
    try? "name: beta\nimage: lab\nmemory: 512M\n".write(toFile: beta + "/doz_project.yml", atomically: true, encoding: .utf8)
    r = runIn(beta, ["up", "-d"])
    check(r.code == 0 && t.row("beta")?.phase == "running", "doz_project.yml: doz up -d makes beta (exit \(r.code))")
    try? "name: beta\nimage: lab\n".write(toFile: beta + "/doz_project.yaml", atomically: true, encoding: .utf8)
    r = runIn(beta, ["up", "-d"], timeout: 60)
    check(r.code != 0 && r.err.contains("both doz_project.yaml and doz_project.yml"), "both spellings: refused, and says so (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines).suffix(120)))")
    r = t.run(["init", beta, "--yes", "--force"])
    check(r.code != 0 && r.err.contains("both doz_project.yaml and doz_project.yml"), "doz init there too")

    // 3. Interactive doz init on a pseudo-terminal (script(1) gives it a controlling terminal).
    let gamma = root + "/gamma"
    let sh = CLIHarness(binary: "/usr/bin/script", store: t.store)
    sh.env = t.env
    do {
        let c = try PTYClient(sh, ["-q", "/dev/null", binary, "init", gamma])
        defer { c.close() }
        func answer(_ prompt: String, _ text: String, _ what: String) {
            check(c.wait(60) { $0.text.components(separatedBy: prompt).count > 1 }, what)
            let n = c.text.components(separatedBy: prompt).count
            c.type(text + "\r")
            _ = c.wait(5) { $0.text.components(separatedBy: prompt).count > n || true }
            usleep(150_000)
        }
        answer("Sandbox name [gamma]", "", "Step 1: the name, from the folder (Enter keeps gamma)")
        answer("Image —", "", "Step 2: the image (Enter keeps the setting's, lab)")
        answer("GitHub as you — should git and gh in this sandbox", "", "Step 4: GitHub as you — onboarding's question, for this sandbox (Enter keeps off)")
        answer("SSH agent", "", "Step 4: the SSH agent")
        answer("What should .dozignore do to the paths it lists?", "2", "Step 5: workspace rules — 2 (hide)")
        answer("Network", "1", "Step 6: the network — 1 (agent)")
        answer("What the agent may do", "+web", "Step 6: the permissions — +web")
        answer("Virtual CPUs", "", "Step 7: CPUs (Enter keeps 2)")
        answer("Memory", "768M", "Step 7: memory — 768M")
        answer("Mac clipboard", "", "Step 8: the clipboard")
        answer("Mac's browser", "", "Step 8: the browser")
        answer("open on the Mac", "", "Step 8: workspace files")
        answer("inside tmux", "", "Step 9: tmux")
        answer("passwordless sudo", "", "Step 9: the agent's sudo")
        answer("Write doz_project.yaml?", "", "Step 10: the file shown, then Write? (Enter: yes)")
        check(c.exited(within: 60) == 0, "doz init exits 0")
        let text = c.text
        for i in 1...10 { check(text.contains("Step \(i) of 10") || (i == 10 && text.contains("— Review")), "it said Step \(i) of 10") }
        check(text.contains("Workspace rules") && text.contains("not a security boundary") && text.contains("This folder's rules: none — the folder is shared as is"),
              "the rules step: what they do, what they are not, and that this folder has none")
        check(text.contains("# doz_project.yaml — a Dozer Sandbox project"), "it showed the file before writing it")
    } catch {
        check(false, "a pseudo-terminal for doz init: \(error)")
    }
    let g = file(gamma)
    check(g.contains("network: agent\n") && g.contains("permissions: \"+web\"\n") && g.contains("memory: 768M "), "the file: network agent, permissions +web, memory 768M")
    check(g.contains("# cpus: 2 ") && g.contains("# clipboard: write"), "what was left at its default stays commented (cpus, clipboard)")
    check(g.contains("ignore_mode: hide\n"), "the rules step's answer is the file's ignore_mode: hide")

    // Again in the same folder: it starts from the file; the replacement is shown and asked.
    do {
        let c = try PTYClient(sh, ["-q", "/dev/null", binary, "init", gamma])
        defer { c.close() }
        func answer(_ prompt: String, _ text: String) {
            _ = c.wait(60) { $0.text.contains(prompt) }
            c.type(text + "\r")
            usleep(200_000)
        }
        for (p, a) in [("Sandbox name [gamma]", ""), ("Image —", ""), ("GitHub as you", ""), ("SSH agent", ""), ("What should .dozignore do", ""),
                       ("Network", ""), ("What the agent may do", ""),
                       ("Virtual CPUs", ""), ("MiB) [768M]", "1G")] { answer(p, a) }
        check(c.text.contains("MiB) [768M]"), "run again: the file's memory is the default (768M)")
        for p in ["Mac clipboard", "Mac's browser", "open on the Mac", "inside tmux", "passwordless sudo"] { answer(p, "") }
        check(c.wait(30) { $0.text.contains("Replace doz_project.yaml with this?") }, "it asks before replacing the file")
        check(c.text.contains("- memory: 768M") && c.text.contains("+ memory: 1G"), "and shows what changes (- memory: 768M, + memory: 1G)")
        c.type("y\r")
        check(c.exited(within: 60) == 0, "doz init exits 0")
    } catch {
        check(false, "a pseudo-terminal for doz init (again): \(error)")
    }
    check(file(gamma).contains("memory: 1G ") && file(gamma).contains("permissions: \"+web\"\n"), "replaced: memory 1G, the rest kept (permissions +web)")
    r = runIn(gamma, ["up", "-d"])
    check(r.code == 0 && t.row("gamma")?.memoryMiB == 1024, "doz up -d in it makes gamma with 1 GiB (exit \(r.code))")

    for n in ["alpha", "beta", "gamma"] { t.run(["rm", n, "--yes"], timeout: 120) }
}
