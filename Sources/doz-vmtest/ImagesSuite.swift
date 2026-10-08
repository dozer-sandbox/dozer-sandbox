import DozerHost
import DozerKit
import Foundation

/// 594 W28 (owner ruling: "i dont think we should rebuild images without the user agreeing (and
/// understanding the consequences) … better to warn"): a pi image baked by an OLDER doz's recipe
/// (`DOZ_TEST_OLDER_RECIPE=1`: rc.1's — no sudo, package lists deleted) is named in `image ls`,
/// `doctor`, `create` and `ls`; a create uses it (never rebuilt by itself), and so does a newer release
/// from a stub registry; the facts say "no sudo" in it; `--rebuild` rebuilds; `reset` then moves the old
/// sandbox to the new image. Also W29 (the sandbox's own name resolves locally — no denied DNS) and
/// W30 (/usr/games on the agent's PATH). A store of its own (`/tmp/dzo-PID-i`); pi at its pin.
func cliImagesSuite(binary: String) async {
    let t = onboardingHarness(binary, "i", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    let stubDir = t.store.appendingPathComponent("registry")
    var stub: Process?
    defer {
        stub?.terminate()
        t.run(["host", "stop"])
        try? FileManager.default.removeItem(at: t.store)
    }
    print("cli: out-of-date images are said, never rebuilt by themselves (W28); own hostname (W29); /usr/games (W30)")
    check(t.run(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    check(t.run(["config", "set", "images.pi_version", AgentImages.piPinned.version]).code == 0, "images.pi_version = the pin")

    // 1. An older doz bakes pi (a host of its own: the seam is read when the host starts).
    t.run(["host", "stop"])
    var older = t.env
    older["DOZ_TEST_OLDER_RECIPE"] = "1"
    let saved = t.env
    t.env = older
    var r = t.run(["image", "bake", "pi"], timeout: 1500)
    check(r.code == 0, "an older doz's recipe bakes pi (exit \(r.code))")
    t.run(["host", "stop"])
    t.env = saved

    // 2. This doz names it — and never rebuilds it by itself.
    func piRow() -> ImageRow? { t.json(["image", "ls"], [ImageRow].self)?.first { $0.name == "pi" } }
    var row = piRow()
    // (599: tmux joined the baseline — the older recipe lacks it too.)
    check(row?.status == "older recipe" && row?.olderRecipe == ["sudo", "apt-utils", "tmux", "package lists"],
          "image ls: pi is an older recipe, adds sudo, apt-utils, tmux, package lists (\(row?.status ?? "?"), \(row?.olderRecipe ?? []))")
    r = t.run(["image", "ls"])
    check(r.out.contains("STATUS") && r.out.contains("older recipe") && r.out.contains("pi: prepared by an older doz — this doz's image adds: sudo, apt-utils, tmux, package lists — rebuild when ready: doz image bake pi"),
          "image ls: the STATUS column and the line")
    r = t.run(["doctor"])
    check(r.out.contains("image pi") && r.out.contains("prepared by an older doz"), "doctor warns about pi")
    r = t.run(["create", "p1", "--image", "pi", "--account", "none", "--isolated", "--memory", "1G", "--json"], timeout: 120)
    let p1 = try? HostWire.decoder.decode(SandboxInfo.self, from: r.outData)
    check(r.code == 0 && p1?.olderImage == ["sudo", "apt-utils", "tmux", "package lists"] && (p1?.imageNotice ?? "").contains("used the current pi image (missing: sudo, apt-utils, tmux, package lists)"),
          "create --json (no terminal): the current image, with the notice in the JSON")
    r = t.run(["create", "p0", "--image", "pi", "--account", "none", "--isolated", "--memory", "1G", "--use-current"], timeout: 120)
    check(r.code == 0 && r.err.contains("warning: used the current pi image"), "create --use-current: the warning")
    check(t.run(["ls"]).out.contains("p1: made from an older pi image (it lacks: sudo, apt-utils, tmux, package lists) — after a rebuild (doz image bake pi), doz reset p1 takes the new one"),
          "ls: the sandbox made from an older image, and what reset keeps")
    check(t.run(["start", "p1"], timeout: 600).code == 0, "start p1 — no preparation (the older image is used)")
    usleep(3_000_000)
    row = piRow()
    check(row?.status == "older recipe" && row?.preparing == nil, "nothing was rebuilt by itself")
    check(t.run(["exec", "p1", "--", "test", "-x", "/usr/bin/sudo"]).code != 0, "p1 has no sudo binary (the older image)")
    check(t.run(["run", "p1", "--detach", "--session", "s", "--", "sleep", "60"], timeout: 60).code == 0, "a session in p1 (the facts are written)")
    r = t.run(["exec", "p1", "--", "cat", "/run/dozer/agent-prompt.md"])
    check(r.out.contains("System: no sudo: this sandbox's system disk was made from an older pi image that has no sudo"), "the facts never claim sudo p1 lacks")

    // 3. A newer release (a stub registry): said, never prepared by itself.
    let pkgDir = stubDir.appendingPathComponent(AgentImages.piPackage)
    try? FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
    let integrity = "sha512-" + String(repeating: "A", count: 86) + "=="
    try? #"{"name":"\#(AgentImages.piPackage)","version":"99.0.0","dist":{"integrity":"\#(integrity)"}}"#.write(to: pkgDir.appendingPathComponent("latest"), atomically: true, encoding: .utf8)
    let port = 40000 + Int(getpid() % 20000)
    let s = Process()
    s.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    s.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", stubDir.path]
    s.standardOutput = FileHandle.nullDevice
    s.standardError = FileHandle.nullDevice
    try? s.run()
    stub = s
    usleep(800_000)
    t.run(["host", "stop"])
    t.env["DOZ_TEST_NPM_REGISTRY"] = "http://127.0.0.1:\(port)"
    check(t.run(["config", "set", "images.pi_version", "latest"]).code == 0, "images.pi_version = latest")
    r = t.run(["create", "p9", "--image", "pi", "--account", "none", "--isolated", "--json"], timeout: 120)   // asks the registry
    check(r.code == 0, "create p9 (the registry asked: 99.0.0 is latest)")
    usleep(3_000_000)
    row = piRow()
    check(row?.available == "99.0.0" && row?.preparing == nil && (row?.standing ?? "").contains("pi 99.0.0 is available (image has \(AgentImages.piPinned.version))"),
          "a newer release: said (\(row?.standing ?? "?")), nothing prepared")
    check(t.run(["rm", "p9", "--yes"]).code == 0, "rm p9")
    check(t.run(["config", "set", "images.pi_version", AgentImages.piPinned.version]).code == 0, "images.pi_version = the pin again")

    // 4. --rebuild: this doz's image first; reset moves p1 to it.
    r = t.run(["create", "p2", "--image", "pi", "--account", "none", "--isolated", "--memory", "1G", "--rebuild", "--json"], timeout: 1500)
    let p2 = try? HostWire.decoder.decode(SandboxInfo.self, from: r.outData)
    check(r.code == 0 && p2 != nil && p2?.olderImage == nil && p2?.imageNotice == nil, "create --rebuild: made from this doz's image (exit \(r.code))")
    check(piRow()?.status == "up to date", "image ls: pi up to date after the rebuild")
    check(t.run(["reset", "p1", "--yes"], timeout: 120).code == 0, "reset p1")
    check(!t.run(["ls"]).out.contains("p1: made from an older"), "p1 now takes this doz's image")
    check(t.run(["start", "p1"], timeout: 300).code == 0 && t.run(["exec", "p1", "--", "sudo", "-n", "true"]).code == 0, "p1 after reset: sudo works")

    // W29: the sandbox's own name resolves locally — sudo and hostname -f leave no denied DNS.
    check(t.run(["start", "p2"], timeout: 300).code == 0, "start p2")
    r = t.run(["exec", "p2", "--", "sh", "-c", "sudo -n true && hostname -f && grep -c \"$(hostname)\" /etc/hosts"])
    check(r.code == 0 && r.out.contains("p2"), "sudo and hostname -f in p2: \(r.out.replacingOccurrences(of: "\n", with: " "))")
    usleep(1_000_000)
    r = t.run(["net", "log", "p2", "--denied"])
    let ownDenied = r.out.split(separator: "\n").filter { $0.contains("dns") && $0.split(separator: " ").contains("p2") }
    check(ownDenied.isEmpty, "no denied DNS for the sandbox's own name (\(ownDenied.count))")

    // W30: /usr/games on the agent's PATH.
    r = t.run(["exec", "p2", "--", "sh", "-c", "sudo -n apt-get install -y cowsay >/dev/null 2>&1; cowsay hi"], timeout: 300)
    check(r.code == 0 && r.out.contains("< hi >"), "cowsay by name (/usr/games on the PATH)")
    r = t.run(["exec", "p2", "--", "sh", "-c", "echo $PATH"])
    check(r.out.contains(":/usr/games"), "the agent's PATH: \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))")
}
