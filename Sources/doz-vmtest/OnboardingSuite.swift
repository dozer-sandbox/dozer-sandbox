// 594 — onboarding end to end, from separate processes of the REAL signed doz (part of `make test-cli`):
//
//   · onboard off a terminal never asks; writes doz.toml and agent-prompt.md only when missing; the
//     store's onboarded.json once its image is ready; a re-run prepares nothing (D7–D10)
//   · a hard check stops it with its reason (the store's socket path too long)
//   · D4: a `start` while `onboard` prepares the lab joins that preparation — one preparation, one bake
//   · D3: SIGINT detaches `onboard` (exit 130) and the host goes on; `--cancel` cancels it
//   · D9: `init` writes doz_project.yaml; `up` with no name, in that folder, creates the sandbox with the
//     folder at /workspace and starts its sessions; again, it uses the same sandbox
//   · D17: create without a workspace says so; `ls` shows it
//   · D15: a pi sandbox gets the facts file, the dozer skill and `--append-system-prompt FILE`; a
//     claude-code one the facts in Claude Code's own argv (via the launcher); agent.prompt = false removes both
//   · D13: `uninstall` of an installed copy: no terminal and no --yes refuses; --yes removes exactly
//     what it listed (--keep-config keeps the settings); never the keychain
//
// Stores: SHORT scratch paths /tmp/dzo-<pid>-{a,c,u} (a socket path must stay under 104 bytes), each
// with its own XDG_CONFIG_HOME; the kernel, the guest init disk and images are APFS-cloned from the
// vmtest store when it has them. Never the owner's store, settings, installed doz or keychain.
import Darwin
import Foundation
import DozerKit
import DozerHost

/// A store for these checks, seeded from the vmtest store (APFS clones), with its own settings.
func onboardingHarness(_ binary: String, _ tag: String, seed items: [String]) -> CLIHarness {
    let root = URL(fileURLWithPath: "/tmp/dzo-\(getpid())-\(tag)")
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let src = NSTemporaryDirectory() + "doz-vmtest-store"
    for item in items where FileManager.default.fileExists(atPath: src + "/" + item) {
        let dest = root.appendingPathComponent(item).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/cp")
        p.arguments = ["-cR", src + "/" + item, dest.path + "/"]
        try? p.run()
        p.waitUntilExit()
    }
    let h = CLIHarness(binary: binary, store: root)
    h.env["DOZ_HOST_IDLE"] = "2"
    // Accounts' secrets live in the host's memory: never the login keychain, never a prompt.
    h.env["DOZ_TEST_CREDENTIALS"] = "memory"
    // The settings live beside the store (the harness put them under it already).
    return h
}

/// 594: the registry's latest version of `package`, asked directly (nil: offline).
func registryLatest(_ package: String) async -> String? {
    try? await NpmRegistry.http(NpmRegistry.npmjs).lookup?(package, "latest").version
}

/// The host's preparations, asked in-process (never starting a host).
func preparations(_ h: CLIHarness) -> [PreparationInfo] {
    guard let m = try? HostClient.request(HostRequest(.prepareStatus), store: DozerStore(root: h.store), autostart: false),
          let st = try? m.result?.decode(PrepareStatus.self) else { return [] }
    return st.preparations
}

func hostLog(_ h: CLIHarness) -> String { (try? String(contentsOf: DozerStore(root: h.store).logFile, encoding: .utf8)) ?? "" }

func occurrences(_ s: String, _ of: String) -> Int { s.components(separatedBy: of).count - 1 }

/// Run `doz args…` in `cwd`.
func runIn(_ h: CLIHarness, _ cwd: URL, _ args: [String], timeout: Double = 300) -> CLIRun {
    let p = h.process(args)
    p.currentDirectoryURL = cwd
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
    return CLIRun(code: p.terminationStatus, out: oc.text, err: ec.text, outData: oc.bytes)
}

func cliOnboardingSuite(binary: String) async {
    cliFirstExecProgressChecks(binary: binary)
    // ── A: the lab, from nothing prepared: onboard + a joining start; init + up; D17 ─────────────
    let a = onboardingHarness(binary, "a", seed: ["kernels", "content", "state.json", "initfs.ext4"])
    let xdg = URL(fileURLWithPath: a.env["XDG_CONFIG_HOME"]!)
    let toml = xdg.appendingPathComponent("dozer-sandbox/doz.toml")
    defer {
        a.run(["host", "stop"])
        try? FileManager.default.removeItem(at: a.store)
    }
    print("cli: onboard — off a terminal it never asks; the settings only when missing")
    var r = a.run(["onboard", "--no-images", "--account", "later"], timeout: 120)
    check(r.code == 0 && r.out.contains("Done — this Mac is onboarded"), "onboard --no-images --account skip, no terminal, no --yes: completes without asking (exit \(r.code))")
    check((try? String(contentsOf: toml, encoding: .utf8))?.contains("\nimage = \"claude-code\"\n") == true, "doz.toml written, with defaults.image set")
    check(FileManager.default.fileExists(atPath: xdg.appendingPathComponent("dozer-sandbox/agent-prompt.md").path), "agent-prompt.md written beside it")
    check(OnboardingRecord.read(DozerStore(root: a.store)) != nil, "onboarded.json recorded")
    check(r.out.contains("3. Workspace rules") && r.out.contains("lock — unchanged"), "the Workspace rules step: said, nothing chosen off a terminal")
    check((try? String(contentsOf: toml, encoding: .utf8))?.contains("\nignore_mode =") == false, "workspace.ignore_mode NOT written (only when chosen)")
    r = a.run(["onboard", "--no-images", "--account", "later", "--ignore-mode", "hide", "--yes"], timeout: 120)
    check(r.code == 0 && r.out.contains("Workspace rules: set workspace.ignore_mode = hide"), "--ignore-mode hide: chosen, so written (exit \(r.code))")
    check((try? String(contentsOf: toml, encoding: .utf8))?.contains("\nignore_mode = \"hide\"\n") == true, "doz.toml says ignore_mode = hide")
    check(a.run(["config", "set", "workspace.ignore_mode", "lock"]).code == 0, "back to lock")
    let tomlBefore = (try? String(contentsOf: toml, encoding: .utf8)) ?? ""

    print("cli: onboard takes a key the doz account add way (owner ruling; the memory keychain)")
    let fakeKey = "sk-ant-api03-DOZFAKE" + String(repeating: "k", count: 40)
    r = a.run(["onboard", "--no-images", "--account", "api-key", "--account-name", "t1"], stdin: Data((fakeKey + "\n").utf8), timeout: 120)
    check(r.code == 0 && r.out.contains("no API key given now") && r.out.contains("doz account add work --api-key"),
          "off a terminal WITHOUT --secret-stdin: stdin is not read, the commands are shown (exit \(r.code))")
    check(!(a.json(["account", "ls"], [AccountRow].self) ?? []).contains { $0.name == "t1" }, "no account t1")
    r = a.run(["onboard", "--no-images", "--account", "api-key", "--account-name", "t1", "--secret-stdin"], stdin: Data((fakeKey + "\n").utf8), timeout: 120)
    let t1 = (a.json(["account", "ls"], [AccountRow].self) ?? []).first { $0.name == "t1" }
    check(r.code == 0 && r.out.contains("account t1 added"), "--secret-stdin: account t1 added (exit \(r.code))")
    check(t1?.isDefault == true && t1?.keychainService == "doz-anthropic:t1" && t1?.kind == "api-key" && t1?.fingerprint != nil,
          "t1: api-key, doz-anthropic:t1, a fingerprint, the store default")
    let stored = try? String(contentsOf: a.store.appendingPathComponent("accounts.json"), encoding: .utf8)
    check(stored?.contains(fakeKey) == false && !r.out.contains(fakeKey) && !r.err.contains(fakeKey) && !hostLog(a).contains(fakeKey),
          "the key is in no output, accounts.json or host.log")
    // The real login keychain: an attribute lookup (no -w: no prompt, no secret) finds no such item.
    let sec = Process()
    sec.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    sec.arguments = ["find-generic-password", "-s", "doz-anthropic:t1"]
    sec.standardOutput = FileHandle.nullDevice
    sec.standardError = FileHandle.nullDevice
    try? sec.run()
    sec.waitUntilExit()
    check(sec.terminationStatus != 0, "the login keychain has no doz-anthropic:t1 (the host's memory keychain held it)")
    check(a.run(["account", "default", "none"]).code == 0, "account default none")

    print("cli: onboard stops on a hard check")
    let longStore = "/tmp/dzo-" + String(repeating: "x", count: 100)
    r = a.run(["onboard", "--no-images", "--account", "later", "--yes", "--store", longStore], timeout: 60)
    check(r.code == 1 && r.err.contains("onboarding stopped: socket"), "a store whose socket path is too long: stopped, with the reason (exit \(r.code))")
    try? FileManager.default.removeItem(atPath: longStore)

    print("cli: a start during onboarding joins its preparation (D4)")
    let onboard = try? AttachedClient(a, ["onboard", "--images", "lab", "--account", "later", "--yes"])
    let running = a.waitFor(120) { preparations(a).contains { $0.image == "lab" && $0.running } }
    check(running, "onboard --images lab: the lab is being prepared in the host")
    let ws = a.store.appendingPathComponent("ws-j1")
    try? FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    check(a.run(["create", "j1", "--image", "lab", "--memory", "384M", "--workspace", ws.path]).code == 0, "create j1 --image lab")
    r = a.run(["start", "j1", "-v"], timeout: 600)
    check(r.code == 0, "start j1 while the lab prepares (exit \(r.code))")
    check(r.err.contains("joining it") || !running, "start j1 said it joins the preparation: \(r.err.split(separator: "\n").first { $0.contains("lab") } ?? "")")
    check(onboard?.exited(within: 600) == 0, "onboard finished (exit \(onboard?.process.terminationStatus ?? -1))")
    let log = hostLog(a)
    check(occurrences(log, "preparing lab (asked by") == 1, "ONE preparation of the lab in the host log (\(occurrences(log, "preparing lab (asked by")))")
    check(occurrences(log, "prepared disk baked and kept") == 1, "ONE bake (\(occurrences(log, "prepared disk baked and kept")))")
    let lab = preparations(a).first { $0.image == "lab" }
    check(lab?.state == "done" && lab?.requestedBy.contains("start j1") == true && lab?.requestedBy.first == "doz onboard",
          "the preparation: done, asked by \(lab?.requestedBy.joined(separator: ", ") ?? "?")")
    check(OnboardingRecord.read(DozerStore(root: a.store))?.images.contains("lab") == true, "onboarded.json records the lab")
    r = a.run(["onboard", "--images", "lab", "--account", "later", "--yes"], timeout: 120)
    check(r.code == 0 && r.out.contains("already prepared") && r.out.contains("left exactly as it is"),
          "re-running: prepares nothing, leaves doz.toml alone (exit \(r.code))")
    check((try? String(contentsOf: toml, encoding: .utf8)) == tomlBefore, "doz.toml unchanged")
    r = a.run(["onboard", "--status"])
    check(r.code == 0 && r.out.contains("onboarded: yes") && r.out.contains("lab          ready"), "onboard --status: onboarded, lab ready")

    print("cli: no workspace is said (D17)")
    r = a.run(["create", "nows", "--image", "lab", "--memory", "384M"])
    check(r.code == 0 && r.err.contains("isolated: nothing on this Mac is shared; /workspace is private to the sandbox"), "create without --workspace says so (isolated)")
    r = a.run(["ls"])
    check(r.out.split(separator: "\n").contains { $0.hasPrefix("nows") && $0.hasSuffix("isolated") }, "ls shows it: isolated")
    a.run(["rm", "nows", "--yes"])

    print("cli: init + up in a project folder (D9)")
    let proj = a.store.appendingPathComponent("my-proj")
    r = a.run(["init", proj.path, "--image", "lab", "--memory", "384M", "--yes"])
    let file = proj.appendingPathComponent("doz_project.yaml")
    check(r.code == 0 && FileManager.default.fileExists(atPath: file.path), "init DIR: made the folder and wrote doz_project.yaml (exit \(r.code))")
    let yaml = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    check(yaml.contains("name: my-proj") && yaml.contains("image: lab"), "named after the folder, image lab")
    check(a.run(["init", proj.path, "--yes"]).code == 4, "init again: exists (4) without --force")
    try? (yaml + "sessions:\n  - shell\n  - name: ticker\n    command: [sleep, \"900\"]\n").write(to: file, atomically: true, encoding: .utf8)
    r = runIn(a, proj, ["up", "--detach"], timeout: 300)
    check(r.code == 0, "up (no name) in the folder (exit \(r.code)): \(r.err.suffix(200))")
    let row = a.row("my-proj")
    check(row?.workspace == proj.path, "my-proj's workspace is the folder (\(row?.workspace ?? "none"))")
    check(a.run(["exec", "my-proj", "--", "ls", "/workspace"]).out.contains("doz_project.yaml"), "/workspace is the project folder")
    let sessions = a.sessions("my-proj").filter { !$0.ended }.map(\.name)
    check(sessions.contains("ticker") && sessions.contains("shell"), "its sessions started: \(sessions.joined(separator: ", "))")
    r = runIn(a, proj, ["up", "--detach"], timeout: 120)
    check(r.code == 0 && a.ls().filter { $0.name == "my-proj" }.count == 1, "up again: the same sandbox")
    check(runIn(a, a.store, ["up"]).err.contains("doz_project.yaml"), "up with no name outside a project says what it needs")
    let bad = a.store.appendingPathComponent("bad-proj")
    try? FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
    try? "name: b\nimage: lab\ncolour: blue\n".write(to: bad.appendingPathComponent("doz_project.yaml"), atomically: true, encoding: .utf8)
    r = runIn(a, bad, ["up", "--detach"])
    check(r.code == 64 && r.err.contains("line 3: unknown key colour"), "an unknown key: refused with its line (exit \(r.code))")
    a.run(["rm", "my-proj", "--yes"])
    a.run(["rm", "j1", "--yes"])
    a.run(["host", "stop"])

    // ── C: the agents' environment prompt; SIGINT detaches, --cancel cancels ──────────────────
    let c = onboardingHarness(binary, "c", seed: ["kernels", "content", "state.json", "initfs.ext4", "images/bases", "images/pi"])
    defer {
        c.run(["host", "stop"])
        try? FileManager.default.removeItem(at: c.store)
    }
    print("cli: the environment prompt — pi (D15)")
    check(c.run(["account", "default", "none"]).code == 0, "account default none (no Mac login is read)")
    let cws = c.store.appendingPathComponent("ws")
    try? FileManager.default.createDirectory(at: cws, withIntermediateDirectories: true)
    let own = c.store.appendingPathComponent("own-prompt.md")
    try? "Project rule: {{sandbox.name}} runs the tests with make test.".write(to: own, atomically: true, encoding: .utf8)
    // 594: pi needs an API-key account — the store's default here is none, so a plain up is refused
    // before anything is made; --account none is the explicit choice (the prompt is all this part checks).
    r = c.run(["up", "pp", "--image", "pi", "--workspace", cws.path, "--detach"], timeout: 120)
    check(r.code != 0 && r.err.contains("pi needs an Anthropic API key") && r.err.contains("doz account add NAME --api-key") && c.row("pp") == nil,
          "up pp --image pi with no API-key account: refused, nothing made, the next step said (\(r.err.split(separator: "\n").last ?? ""))")
    r = c.run(["up", "pp", "--image", "pi", "--account", "none", "--workspace", cws.path, "--agent-prompt", own.path, "--detach"], timeout: 900)
    check(r.code == 0, "up pp --image pi --account none --workspace … --agent-prompt FILE (exit \(r.code))")
    check(c.row("pp")?.credentialProblem == "pi has no credential — pi needs an Anthropic API key; choose an API-key account",
          "ls: pp says pi has no credential (\(c.row("pp")?.credentialProblem ?? "nil"))")
    let facts = c.run(["exec", "pp", "--", "cat", "/run/dozer/agent-prompt.md"]).out
    check(facts.contains("You are in `pp`, a Dozer Sandbox") && facts.contains("user's Mac folder \(cws.path), shared live"),
          "the facts block is in the guest: the sandbox and its workspace")
    check(facts.contains("no credential you can use is attached") && !facts.contains("adds the account's credential"),
          "pi with no account: the facts say no credential is attached — choose one in Dozer, never log in")
    check(facts.hasSuffix("\n\nProject rule: pp runs the tests with make test.\n"), "the sandbox's own prompt is appended")
    check(c.run(["exec", "pp", "--", "cat", "/home/agent/.pi/agent/skills/dozer/SKILL.md"]).out.hasPrefix("---\nname: dozer\n"),
          "the dozer skill: ~/.pi/agent/skills/dozer/SKILL.md")
    let pi = c.sessions("pp").first { $0.name == "pi" }
    check(pi?.command == "pi --append-system-prompt /run/dozer/agent-prompt.md", "pi's session: \(pi?.command ?? "none")")
    r = c.run(["inspect", "pp", "--prompt"])
    check(r.code == 0 && r.out.contains("pi's --append-system-prompt") && r.out.contains("You are in `pp`"), "inspect --prompt shows it")
    let cxdg = URL(fileURLWithPath: c.env["XDG_CONFIG_HOME"]!)
    check(c.run(["config", "set", "agent.prompt", "false"]).code == 0, "config set agent.prompt false")
    c.run(["run", "pp", "--detach", "--session", "later", "--", "sleep", "300"])
    check(c.run(["exec", "pp", "--", "sh", "-c", "test -e /run/dozer/agent-prompt.md || test -e /home/agent/.pi/agent/skills/dozer && echo left || echo gone"]).out == "gone\n",
          "off: the next session start removed both")
    c.run(["config", "unset", "agent.prompt"])
    // Your own template replaces the built-in one, from the next session.
    try? "<!-- mine -->\nCustom: {{sandbox.name}} sees {{workspace.host_path}}".write(to: cxdg.appendingPathComponent("dozer-sandbox/agent-prompt.md"), atomically: true, encoding: .utf8)
    c.run(["run", "pp", "--detach", "--session", "later1", "--", "sleep", "300"])
    check(c.run(["exec", "pp", "--", "cat", "/run/dozer/agent-prompt.md"]).out == "Custom: pp sees \(cws.path)\n\nProject rule: pp runs the tests with make test.\n",
          "agent-prompt.md (the user's template) replaces the built-in one at the next session; the sandbox's own still appended")
    try? "Tests: {{sandbox.nmae}}".write(to: cxdg.appendingPathComponent("dozer-sandbox/agent-prompt.md"), atomically: true, encoding: .utf8)
    r = c.run(["run", "pp", "--detach", "--session", "later2", "--", "sleep", "300"])
    check(r.code != 0 && r.err.contains("{{sandbox.nmae}} is not a variable"), "an unknown variable: the session does not start, and says why")
    try? FileManager.default.removeItem(at: cxdg.appendingPathComponent("dozer-sandbox/agent-prompt.md"))
    c.run(["rm", "pp", "--yes"])

    print("cli: the environment prompt — claude-code, in Claude Code's argv (D15)")
    r = c.run(["up", "cc", "--image", "claude-code", "--workspace", cws.path, "--detach", "-v"], timeout: 1500)
    check(r.code == 0, "up cc --image claude-code (prepares the image when this build has not: exit \(r.code))")
    // Every process's whole argv (the prompt spans lines); the pattern's space is escaped, so this
    // script's own argv does not match it.
    let argv = c.run(["exec", "cc", "--", "sh", "-c",
                      "for p in /proc/[0-9]*; do c=$(tr '\\0' ' ' < $p/cmdline 2>/dev/null); case \"$c\" in *permissions\\ --append-system-prompt*) printf '%s\\n' \"$c\";; esac; done"]).out
    check(argv.contains("/usr/local/bin/claude --dangerously-skip-permissions --append-system-prompt # Where you are running: a Dozer Sandbox")
          && argv.contains("shared live"), "Claude Code runs with the facts block appended: \(argv.prefix(110))…")
    check(c.run(["exec", "cc", "--", "cat", "/home/agent/.claude/skills/dozer/SKILL.md"]).out.hasPrefix("---\nname: dozer\n"),
          "the dozer skill: ~/.claude/skills/dozer/SKILL.md")
    check(c.sessions("cc").first { $0.name == "claude" }?.command == "claude", "the session's command stays `claude` (the launcher adds it)")

    // 594 (owner: "Can we install (optionally) latest claude code (default true)?"): images.claude_code_version
    // is latest by default — the host asked the registry, the bake installed that exact version, and
    // the image and the store record it.
    print("cli: latest Claude Code — resolved when the image was prepared, installed at that exact version")
    let recorded = AgentVersions.all(DozerStore(root: c.store))["claude-code"]?.latest?.version
    let npmNow = await registryLatest(AgentImages.claudeCodePackage)
    print("  the host resolved \(recorded ?? "nothing"); the registry says \(npmNow ?? "?") now")
    check(recorded != nil && (npmNow == nil || recorded == npmNow), "the host asked the registry: latest = \(recorded ?? "—") (<store>/agent-versions.json)")
    check((r.out + r.err).contains("@anthropic-ai/claude-code@\(recorded ?? "?") (latest, resolved now)"),
          "the preparation's step says it: npm install @anthropic-ai/claude-code@\(recorded ?? "?") (latest, resolved now)")
    let ccRow = c.json(["image", "ls"], [ImageRow].self)?.first { $0.name == "claude-code" }
    check(ccRow?.version == recorded && ccRow?.versionSetting == "latest" && ccRow?.versionLine == "claude-code \(recorded ?? "?") (latest)",
          "image ls: \(ccRow?.versionLine ?? "no row")")
    check(c.run(["exec", "cc", "--", "claude", "--version"]).out.contains(recorded ?? "?"), "claude --version in the sandbox: \(recorded ?? "?")")
    check(c.run(["exec", "cc", "--", "sh", "-c", "echo $DISABLE_AUTOUPDATER$DISABLE_UPDATES"]).out == "11\n",
          "Claude Code's updater is off in the sandbox (DISABLE_AUTOUPDATER, DISABLE_UPDATES)")
    c.run(["rm", "cc", "--yes"])

    // 594 (owner: "there are some legit requests that should be allowed"): the agent preset holds what
    // Claude Code reaches on its own — updates, its error reporting, GitHub (plugin marketplace).
    print("cli: a fresh claude-code sandbox's startup — no denied connections (the agent preset)")
    let fk = "sk-ant-api03-DOZFAKE" + String(repeating: "n", count: 40)     // a FAKE key: the API answers 401
    r = c.run(["account", "add", "fk", "--api-key", "--no-verify", "--force"], stdin: Data((fk + "\n").utf8))
    check(r.code == 0, "account add fk --api-key (a fake key, the memory keychain)")
    let upAt = Date()
    r = c.run(["up", "cn", "--image", "claude-code", "--account", "fk", "--detach"], timeout: 900)
    check(r.code == 0, "up cn --image claude-code --account fk: Claude Code starts in its session (exit \(r.code))")
    // And started non-interactively: `claude -p` runs its startup, then fails at the API (a fake key).
    // (stdin from /dev/null: -p off a terminal otherwise waits for stdin to end.)
    r = c.run(["exec", "cn", "--timeout", "60", "--", "sh", "-c", "claude -p 'say ok' </dev/null"], timeout: 90)
    print("  claude -p: exit \(r.code)")
    // Its reporting is batched (flushed every 15–60 s): a minute and a half of both running.
    let waitLeft = 90 - Date().timeIntervalSince(upAt)
    if waitLeft > 0 { try? await Task.sleep(for: .seconds(waitLeft)) }
    let seen = c.json(["net", "log", "cn"], [ConnectionRecord].self) ?? []
    let refused = c.json(["net", "log", "cn", "--denied"], [ConnectionRecord].self)
    print("  connections: " + Set(seen.map { "\($0.target) \($0.verdict.rawValue)" }).sorted().joined(separator: ", "))
    check(seen.contains { $0.host == "api.anthropic.com" }, "Claude Code reached the API (\(seen.count) connection(s) logged)")
    check(refused != nil && refused!.isEmpty,
          "doz net log cn --denied: nothing denied" + ((refused ?? []).isEmpty ? "" : " — " + Set(refused!.map(\.target)).sorted().joined(separator: ", ")))
    check(!c.run(["net", "log", "cn"]).out.contains(fk) && !hostLog(c).contains(fk), "the fake key is in no log")
    // 594: the "Update Claude Code to try it" line the owner saw on a pinned build — the claude session's
    // screen on a latest-baked image (saved when it pauses).
    check(c.run(["pause", "cn"]).code == 0, "pause cn (its screens are saved)")
    let screen = c.run(["sessions", "cn", "--screen", "claude"]).out
    print("  the claude session's screen (latest image):\n" + screen.split(separator: "\n").prefix(24).map { "    │ " + $0 }.joined(separator: "\n"))
    check(!screen.isEmpty && !screen.contains("Update Claude Code"), "no \"Update Claude Code\" line on a latest-baked image")
    c.run(["rm", "cn", "--yes"])

    // 594 (the owner's first pi sandbox: "fd not found. Downloading... Failed to download fd: fetch
    // failed", denied api.github.com and pi.dev): pi's tools are baked and pi's own host is allowed.
    print("cli: a fresh pi sandbox's first session — fd and rg baked, no denied connections")
    let piAt = Date()
    r = c.run(["up", "pn", "--image", "pi", "--account", "fk", "--detach"], timeout: 900)
    check(r.code == 0, "up pn --image pi --account fk: pi starts in its session (exit \(r.code))")
    check(c.row("pn")?.credentialProblem == nil, "an API-key account fits pi: no problem said")
    check(c.run(["exec", "pn", "--", "cat", "/run/dozer/agent-prompt.md"]).out.contains("adds the account's credential (fk)"),
          "pi's facts: the proxy adds fk's credential")
    let piEnv = c.run(["exec", "pn", "--", "sh", "-c", "echo ${ANTHROPIC_API_KEY%%_*}/${CLAUDE_CODE_OAUTH_TOKEN:-none}"]).out
    check(piEnv.hasPrefix("doz/none") || piEnv.hasPrefix("doz_cred/none") || (piEnv.hasPrefix("doz") && piEnv.contains("/none")),
          "pi reads ANTHROPIC_API_KEY = the proxy's placeholder; no Claude subscription token (\(piEnv.trimmingCharacters(in: .whitespacesAndNewlines)))")
    let tools = c.run(["exec", "pn", "--", "sh", "-c", "command -v fd; command -v rg; fd --version"]).out
    check(tools.contains("/usr/local/bin/fd") && tools.contains("/usr/bin/rg") && tools.contains("fd"), "fd and rg are on the PATH: \(tools.replacingOccurrences(of: "\n", with: " "))")
    r = c.run(["exec", "pn", "--timeout", "60", "--", "sh", "-c", "pi -p 'say ok' </dev/null"], timeout: 90)
    print("  pi -p: exit \(r.code)")
    // End to end: pi sent the placeholder, the proxy swapped in fk's (fake) key, Anthropic refused THAT key.
    check((r.out + r.err).contains("authentication_error") && !(r.out + r.err).contains("No API key found"),
          "pi -p reaches Anthropic with the account's key (a fake one: 401 authentication_error), not \"No API key found\"")
    let piWait = 60 - Date().timeIntervalSince(piAt)
    if piWait > 0 { try? await Task.sleep(for: .seconds(piWait)) }
    let piSeen = c.json(["net", "log", "pn"], [ConnectionRecord].self) ?? []
    let piRefused = c.json(["net", "log", "pn", "--denied"], [ConnectionRecord].self)
    print("  connections: " + Set(piSeen.map { "\($0.target) \($0.verdict.rawValue)" }).sorted().joined(separator: ", "))
    check(piRefused != nil && piRefused!.isEmpty,
          "doz net log pn --denied: nothing denied" + ((piRefused ?? []).isEmpty ? "" : " — " + Set(piRefused!.map(\.target)).sorted().joined(separator: ", ")))
    check(c.run(["pause", "pn"]).code == 0, "pause pn (its screens are saved)")
    let piScreen = c.run(["sessions", "pn", "--screen", "pi"]).out
    print("  the pi session's screen:\n" + piScreen.split(separator: "\n").prefix(20).map { "    │ " + $0 }.joined(separator: "\n"))
    check(!piScreen.isEmpty && !piScreen.contains("fd not found") && !piScreen.contains("Failed to download"), "no \"fd not found\", nothing downloaded")
    c.run(["rm", "pn", "--yes"])
    c.run(["account", "rm", "fk", "--force"])

    print("cli: Ctrl-C detaches onboarding; --cancel cancels (D3)")
    try? FileManager.default.removeItem(at: c.store.appendingPathComponent("images/pi"))
    let ob = try? AttachedClient(c, ["onboard", "--images", "pi", "--account", "later", "--yes"])
    check(c.waitFor(180) { preparations(c).contains { $0.image == "pi" && $0.running } }, "onboard --images pi: preparing in the host")
    if let ob { kill(ob.process.processIdentifier, SIGINT) }
    let code = ob?.exited(within: 20)
    check(code == 130 && ob?.err.text.contains("detached") == true, "SIGINT: onboard detached (exit \(code.map(String.init) ?? "still running"))")
    check(preparations(c).contains { $0.image == "pi" && $0.running }, "the preparation goes on in the host")
    r = c.run(["onboard", "--cancel"])
    check(r.code == 0 && r.out.contains("cancelling the preparation of pi"), "onboard --cancel")
    check(c.waitFor(300) { preparations(c).first { $0.image == "pi" }.map { !$0.running } ?? false }, "it stopped")
    let p = preparations(c).first { $0.image == "pi" }
    check(p?.state == "cancelled", "state: \(p?.state ?? "?")")
    check(!(OnboardingRecord.read(DozerStore(root: c.store))?.images.contains("pi") ?? false), "no onboarding recorded for pi")
    check(c.run(["onboard", "--cancel"]).out.contains("nothing is being prepared"), "--cancel again: nothing to cancel")
    c.run(["host", "stop"])

    // ── U: uninstall an installed copy, on throwaway paths ────────────────────────────────────
    print("cli: uninstall (D13)")
    let u = URL(fileURLWithPath: "/tmp/dzo-\(getpid())-u")
    try? FileManager.default.removeItem(at: u)
    let prefix = u.appendingPathComponent("prefix")
    let libexec = prefix.appendingPathComponent("libexec/doz")
    try? FileManager.default.createDirectory(at: libexec, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
    let build = URL(fileURLWithPath: binary).deletingLastPathComponent()
    for item in ["DozerKit_DozerKit.bundle", "DozerKit_DozerWeb.bundle"] {
        try? FileManager.default.copyItem(at: build.appendingPathComponent(item), to: libexec.appendingPathComponent(item))
    }
    try? FileManager.default.copyItem(at: URL(fileURLWithPath: binary), to: libexec.appendingPathComponent("doz"))
    try? FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent("bin/doz").path, withDestinationPath: libexec.appendingPathComponent("doz").path)
    let ustore = u.appendingPathComponent("s")
    let uh = CLIHarness(binary: prefix.appendingPathComponent("bin/doz").path, store: ustore)
    uh.env["XDG_CONFIG_HOME"] = u.appendingPathComponent("xdg").path
    uh.env["DOZ_TEST_CREDENTIALS"] = "memory"
    check(uh.run(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120).code == 0, "an installed copy, onboarded on a throwaway store")
    uh.run(["host", "stop"])
    let config = u.appendingPathComponent("xdg/dozer-sandbox")
    r = uh.run(["uninstall"])
    check(r.code == 5 && r.out.contains(ustore.path) && r.out.contains(config.path) && r.out.contains(libexec.path)
          && r.out.contains("the keychain (never touched)"), "no terminal, no --yes: it lists exactly what goes, and refuses (exit \(r.code))")
    check(FileManager.default.fileExists(atPath: ustore.path) && FileManager.default.fileExists(atPath: libexec.path), "nothing removed")
    r = uh.run(["uninstall", "--yes", "--keep-config"])
    check(r.code == 0, "uninstall --yes --keep-config (exit \(r.code)): \(r.err.suffix(200))")
    check(!FileManager.default.fileExists(atPath: ustore.path), "the store is gone")
    check(!FileManager.default.fileExists(atPath: libexec.path) && (try? FileManager.default.destinationOfSymbolicLink(atPath: prefix.appendingPathComponent("bin/doz").path)) == nil,
          "the installed doz and its link are gone")
    check(FileManager.default.fileExists(atPath: config.appendingPathComponent("doz.toml").path), "--keep-config: the settings stay")
    try? FileManager.default.removeItem(at: u)
}

/// The first `doz exec` on a lab never prepared (only the kernel cached): its progress is SHOWN while
/// it happens — the host's "not prepared" note within about a second, and both pulls (the guest init
/// image, alpine) drawn with their bytes before they end. (It printed nothing for 18 s, then
/// everything at once: the CLI held its lines until an event came after the first second, and both
/// pulls sent none.) On a pseudo-terminal, as a person sees it.
func cliFirstExecProgressChecks(binary: String) {
    print("cli: a first exec on a lab never prepared shows its progress as it happens")
    let h = onboardingHarness(binary, "p", seed: ["kernels"])
    defer {
        h.run(["host", "stop"])
        try? FileManager.default.removeItem(at: h.store)
        try? FileManager.default.removeItem(atPath: h.store.path + "-ws")
    }
    let ws = URL(fileURLWithPath: h.store.path + "-ws")             // never inside the store (refused)
    guard h.run(["create", "q1", "--image", "lab", "--workspace", ws.path]).code == 0 else { check(false, "create q1 (lab)"); return }
    h.run(["host", "stop"])
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
    p.arguments = ["-q", "/dev/null", h.binary, "exec", "q1", "--", "true"]
    p.environment = h.env
    let o = Pipe()
    p.standardOutput = o
    p.standardError = o
    p.standardInput = FileHandle.nullDevice
    let t0 = Date()
    do { try p.run() } catch { check(false, "script(1) runs: \(error)"); return }
    let c = PipeCollector(o.fileHandleForReading)
    var firstNote: Double?, initBar: Double?, initDone: Double?, alpineBar: Double?, alpineDone: Double?
    let deadline = t0.addingTimeInterval(600)
    while p.isRunning && Date() < deadline {
        let t = c.text, now = Date().timeIntervalSince(t0)
        if firstNote == nil, t.contains("is not prepared in this store yet") { firstNote = now }
        if initBar == nil, t.contains("pulling the guest init image") { initBar = now }
        if initDone == nil, t.contains("pulled the guest init image") { initDone = now }
        if alpineBar == nil, t.contains("pulling alpine") { alpineBar = now }
        if alpineDone == nil, t.contains("pulled alpine") { alpineDone = now }
        usleep(50_000)
    }
    if p.isRunning { p.terminate() }
    p.waitUntilExit()
    c.wait(5)
    func s(_ v: Double?) -> String { v.map { String(format: "%.1f s", $0) } ?? "never" }
    check(p.terminationStatus == 0, "doz exec q1 -- true on a pseudo-terminal exits 0 (\(p.terminationStatus))")
    check((firstNote ?? 99) < 3, "the host's note that the lab is not prepared appears within about a second (\(s(firstNote)), the host's own start included)")
    check(initBar != nil && initBar! < (initDone ?? 0), "the guest init image's pull is drawn while it runs (bar \(s(initBar)), done \(s(initDone)))")
    check(alpineBar != nil && alpineBar! < (alpineDone ?? 0), "alpine's pull is drawn while it runs (bar \(s(alpineBar)), done \(s(alpineDone)))")
}
