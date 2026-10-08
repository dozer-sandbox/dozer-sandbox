import DozerHost
import DozerKit
import Foundation

/// 594 W23 (owner ruling 2026-09-30: "yes, passwordless sudo by default"): the agent in a fresh
/// claude-code sandbox installs a system package with `sudo -n apt-get install` (the image keeps apt's
/// lists; the agent network preset allows deb.debian.org) and the facts say so; `--no-agent-sudo`
/// gives no sudo; the setting follows at the next boot without a rebake; and root inside reaches no more
/// than the agent: no network interface, the policy still denies a host, no other vsock listener on the
/// Mac, no Mac folder but the share. A store of its own (`/tmp/dzo-PID-u`); it prepares the claude-code
/// image (the pinned version: the registry is not asked).
func cliAgentSudoSuite(binary: String) async {
    let t = onboardingHarness(binary, "u", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    t.env["DOZ_TEST_NPM_REGISTRY"] = "offline"
    defer {
        t.run(["host", "stop"])
        try? FileManager.default.removeItem(at: t.store)
    }
    print("cli: the agent's passwordless sudo (W23)")
    check(t.run(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    check(t.run(["config", "set", "images.claude_code_version", AgentImages.claudeCodePinned.version]).code == 0,
          "images.claude_code_version = the pin (\(AgentImages.claudeCodePinned.version)) — the registry is not asked")
    var r = t.run(["up", "su", "--image", "claude-code", "--isolated", "--account", "none", "--memory", "1G", "--detach"], timeout: 1800)
    check(r.code == 0, "up su --image claude-code (prepares the image: exit \(r.code))")

    // 1. The agent installs a package with sudo, and runs it.
    check(t.run(["exec", "su", "--", "id", "-un"]).out == "agent\n", "exec runs as the agent")
    r = t.run(["exec", "su", "--", "sh", "-c", "sudo -n apt-get install -y cowsay >/tmp/apt.log 2>&1 || { tail -5 /tmp/apt.log; exit 1; }; grep -q 'delaying package configuration' /tmp/apt.log && echo DEBCONF-NOISE; /usr/games/cowsay hi"], timeout: 300)
    check(r.code == 0 && r.out.contains("< hi >"), "sudo -n apt-get install -y cowsay && cowsay hi — as the agent (\(r.code)): \(r.out.suffix(200))")
    check(!r.out.contains("DEBCONF-NOISE"), "W24: no \"debconf: delaying package configuration\" (apt-utils is in the image)")
    // W31: a package that asks debconf questions (keyboard-configuration → console-setup: the owner's
    // install stopped at "Keyboard layout:") installs without asking. stdin is /dev/null, so a question
    // would fail the install rather than hang the test; the frontend check proves it was never asked.
    r = t.run(["exec", "su", "--", "sh", "-c", "sudo -n debconf-show debconf 2>/dev/null | grep -i 'frontend' ; sudo -n apt-get install -y keyboard-configuration </dev/null >/tmp/kb.log 2>&1 && echo KB-OK || tail -5 /tmp/kb.log; grep -c 'Keyboard layout:\\|Character set to support:' /tmp/kb.log"], timeout: 600)
    check(r.out.contains("Noninteractive"), "W31: debconf's frontend is Noninteractive in the guest (\(r.out.split(separator: "\n").first ?? ""))")
    check(r.out.contains("KB-OK") && r.out.hasSuffix("0\n"), "W31: sudo apt-get install keyboard-configuration (+ console-setup) completes without a question: \(r.out.suffix(200))")
    r = t.run(["exec", "su", "--", "sh", "-c", "stat -c '%a %U' /etc/sudoers.d/dozer-agent; du -sk /var/lib/apt/lists | cut -f1"])
    let lines = r.out.split(separator: "\n")
    check(lines.first == "440 root", "the drop-in: 0440, root (\(lines.first ?? ""))")
    info("apt lists in the image: \(lines.last.flatMap { Int($0) }.map { "\($0 / 1024) MiB" } ?? "?")")
    r = t.run(["inspect", "su", "--prompt"])
    check(r.out.contains("System: you have passwordless sudo in this sandbox"), "the facts say: passwordless sudo")

    // 2. Root reaches no more than the agent.
    r = t.run(["exec", "su", "--", "sudo", "-n", "ls", "/sys/class/net"])
    check(r.code == 0 && r.out == "lo\n", "root: no network interface but lo (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    r = t.run(["exec", "su", "--", "sudo", "-n", "sh", "-c", "curl -sS --max-time 15 -o /dev/null -w '%{http_code}' https://example.com; echo \" exit=$?\""], timeout: 60)
    check(r.code == 0 && r.out.contains(" exit=") && !r.out.hasPrefix("200") && !r.out.contains(" exit=0"), "root: the policy still denies a host the agent preset does not allow (example.com → \(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    // (`__import__`: a line beginning "import" is read by the audit as a Swift import.)
    let probe = """
    socket = __import__("socket")
    open_ports = []
    for p in (5800, 22, 80, 443, 1024, 2375, 5801, 5802, 8080, 9000):
        s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        s.settimeout(2)
        try:
            s.connect((2, p)); open_ports.append(p)
        except OSError:
            pass
        finally:
            s.close()
    print("open:", open_ports)
    """
    r = t.run(["exec", "su", "--", "sudo", "-n", "python3", "-c", probe], timeout: 60)
    // 5800 is the proxy itself (the positive control: the probe does see a listener); nothing else.
    check(r.out.contains("open: [5800]"), "root: no vsock listener on the Mac but the proxy (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    let hostSock = t.store.appendingPathComponent("host.sock").path
    r = t.run(["exec", "su", "--", "sudo", "-n", "sh", "-c", "test -e '\(hostSock)' && echo SEEN; grep -c virtiofs /proc/mounts || true"])
    check(!r.out.contains("SEEN") && r.out.hasSuffix("0\n"), "root: the host's socket and the store are not in the VM; no Mac folder is mounted (isolated)")

    // 3. --no-agent-sudo: no sudo, and the facts say so.
    r = t.run(["up", "sn", "--image", "claude-code", "--isolated", "--account", "none", "--memory", "1G", "--no-agent-sudo", "--detach"], timeout: 600)
    check(r.code == 0, "up sn --no-agent-sudo (exit \(r.code))")
    r = t.run(["exec", "sn", "--", "sh", "-c", "sudo -n true 2>/dev/null && echo SUDO || echo NOSUDO; test -e /etc/sudoers.d/dozer-agent && echo RULE || echo NORULE"])
    check(r.out == "NOSUDO\nNORULE\n", "--no-agent-sudo: sudo -n true fails, no drop-in (\(r.out.replacingOccurrences(of: "\n", with: " ")))")
    check(t.run(["inspect", "sn", "--prompt"]).out.contains("System: no sudo"), "the facts say: no sudo")

    // 4. The setting, at the next boot — no image is rebuilt.
    check(t.run(["config", "set", "sandbox.agent_sudo", "false"]).code == 0, "doz config set sandbox.agent_sudo false")
    check(t.run(["shutdown", "su", "--yes"], timeout: 120).code == 0 && t.run(["start", "su"], timeout: 300).code == 0, "shutdown + start su")
    r = t.run(["exec", "su", "--", "sh", "-c", "sudo -n true 2>/dev/null && echo SUDO || echo NOSUDO"])
    check(r.out == "NOSUDO\n", "the setting off: su has no sudo after its restart")
    check(t.run(["config", "set", "sandbox.agent_sudo", "true"]).code == 0, "doz config set sandbox.agent_sudo true")
    check(t.run(["shutdown", "su", "--yes"], timeout: 120).code == 0 && t.run(["start", "su"], timeout: 300).code == 0, "shutdown + start su")
    r = t.run(["exec", "su", "--", "sh", "-c", "sudo -n true && echo SUDO"])
    check(r.out == "SUDO\n", "the setting on again: sudo is back — and sn keeps its own choice")
    check(t.run(["exec", "sn", "--", "sh", "-c", "sudo -n true 2>/dev/null || echo NOSUDO"]).out == "NOSUDO\n", "sn: still no sudo (its own choice wins)")
    let images = t.json(["image", "ls"], [ImageRow].self)?.filter { $0.name == "claude-code" }.count ?? 0
    check(images == 1, "one claude-code image — nothing was rebuilt for the toggle (\(images))")

    // 5. W34 (the owner's claude-sandbox-3 asked apt's keyboard question on rc.11: it had only hibernated
    // and woken since W31 landed): a WAKE applies the guest fixes — no cold boot.
    print("cli: a wake applies the guest fixes (W34)")
    let fixed = "sudo -n debconf-show debconf 2>/dev/null | grep -i frontend | sed 's/.*: *//'; grep -c \"\\s$(hostname)\\b\" /etc/hosts; cat /proc/sys/kernel/random/boot_id"
    let breakIt = "echo 'debconf debconf/frontend select Readline' | sudo -n debconf-set-selections && sudo -n sed -i '/^127\\.0\\.1\\.1\\s/d' /etc/hosts"
    func state() -> [String] { t.run(["exec", "su", "--", "sh", "-c", fixed]).out.split(separator: "\n").map(String.init) }
    func timed(_ args: [String]) -> (ok: Bool, ms: Int) {
        let t0 = Date()
        let ok = t.run(args, timeout: 180).code == 0
        return (ok, Int(Date().timeIntervalSince(t0) * 1000))
    }
    let bootID = state().last ?? "?"
    var wakeMs: [Int] = []
    for (i, how) in ["hibernate", "sleep", "hibernate"].enumerated() {
        check(t.run(["exec", "su", "--", "sh", "-c", breakIt]).code == 0, "\(how) #\(i + 1): debconf's frontend set back to Readline, the 127.0.1.1 line removed")
        let broken = state()
        check(broken.first == "Readline" && broken.dropFirst().first == "0", "  broken in the running guest (\(broken.prefix(2).joined(separator: " ")))")
        check(t.run([how, "su"], timeout: 180).code == 0, "  \(how) su")
        let w = timed(["wake", "su"])
        check(w.ok, "  wake su (\(w.ms) ms)")
        if how == "hibernate" { wakeMs.append(w.ms) }
        let s = state()
        check(s.first == "Noninteractive", "  after the wake: debconf's frontend is Noninteractive again (\(s.first ?? "—"))")
        check(s.dropFirst().first == "1", "  after the wake: the guest's own name is back in /etc/hosts (\(s.dropFirst().first ?? "—"))")
        check(s.last == bootID, "  the same boot — no cold boot (boot_id \(s.last ?? "—"))")
    }
    info("hibernate → wake: \(wakeMs.map { "\($0) ms" }.joined(separator: ", ")) (doz wake, wall clock)")
}
