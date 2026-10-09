import Darwin
import Foundation
import DozerKit
import DozerHost

// 612 (`make test-vm-status`): what the agent is doing (OSC 7501) through the real host and CLI, in a lab
// sandbox in a store of its own (`/tmp/dzo-PID-st`). No real agent and no login: a FAKE agent (a shell script)
// asks the terminal whether it speaks the protocol, waits for deckhold's answer, and only then reports
// working → blocked (permission) → done → working → error, one step each time the test touches a file. Checked:
// the host's status at each step (sessions, ls from memory, the events, doz ls / doz sessions text), with and
// without a viewer, the bytes reaching an attached `doz attach` unchanged, a sleep and a hibernation with their
// wakes (the watcher comes back, nothing stale), the program's exit (error survives it), host.log free of the
// program's text, and a shutdown clearing it all.

private let esc = "\u{1B}"

/// The fake agent. Busybox sh in the lab: raw mode to read the answer (as a real agent does), then reports.
private let fakeAgent = #"""
#!/bin/sh
st() { printf '\033]7501;%s\033\\' "$1"; }
gate() { while [ ! -e "/tmp/go$1" ]; do sleep 0.2; done; }
stty raw -echo
printf '\033]7501;?\033\\'
ans=$(timeout 5 dd bs=1 count=10 2>/dev/null | od -An -c | tr -d ' \n')
stty sane
case "$ans" in *7501*) echo "ANSWERED";; *) echo "NO-ANSWER [$ans]"; sleep 600; exit 1;; esac
st "state=working:app=fake-agent:msg=$(printf 'thinking hard' | base64)"
gate 1
st "state=blocked:app=fake-agent:kind=permission:msg=$(printf 'run the tests?' | base64)"
gate 2
st "state=done:app=fake-agent"
echo STEP-DONE
gate 3
st "state=working:app=fake-agent:progress=40"
gate 4
st "state=error:app=fake-agent:msg=$(printf 'it broke' | base64)"
sleep 1
exit 3
"""#

func cliStatusSuite(binary: String) async {
    let t = onboardingHarness(binary, "st", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    defer {
        t.run(["host", "stop"], timeout: 300)
        try? FileManager.default.removeItem(at: t.store)
    }
    print("cli: what the agent is doing — OSC 7501 (612)")
    check(t.run(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    check(t.run(["create", "st", "--image", "lab", "--isolated", "--memory", "512M", "--start"], timeout: 900).code == 0, "create st --image lab --start")
    func ex(_ script: String) -> String { t.run(["exec", "st", "--", "sh", "-c", script], timeout: 60).out }
    let script = Data(fakeAgent.utf8).base64EncodedString()
    _ = ex("echo \(script) | base64 -d > /tmp/fake-agent.sh; chmod 755 /tmp/fake-agent.sh; rm -f /tmp/go*")
    func row() -> SessionRow? { t.sessions("st").first { $0.name == "agent" } }
    func sandbox() -> SandboxInfo? { t.row("st") }
    func step(_ n: Int) { _ = ex("touch /tmp/go\(n)") }

    // The host's events, as `doz events --json` sees them (the CLI asks for session-status).
    let events = try? AttachedClient(t, ["events", "st", "--json"])
    defer { events?.process.terminate() }
    func statusEvents() -> [HostEvent] {
        (events?.text ?? "").split(separator: "\n").compactMap { try? HostWire.decoder.decode(HostEvent.self, from: Data($0.utf8)) }
            .filter { $0.kind == .sessionStatus && $0.session == "agent" }
    }

    // 1. No viewer: the program asks, deckhold answers at once, the program reports working.
    check(t.run(["run", "st", "-d", "--session", "agent", "--", "/tmp/fake-agent.sh"]).code == 0, "the fake agent runs, detached (no viewer)")
    check(t.waitFor(20) { row()?.status?.state == .working }, "detached: the session is working (\(row()?.status?.label ?? "nothing"))")
    check(ex("deckhold dump -s agent").contains("ANSWERED"), "the program had its answer (deckhold answered the query, no viewer attached)")
    check(row()?.status?.message == "thinking hard" && row()?.status?.app == "fake-agent", "…with its app and message")
    check(sandbox()?.agentStatus?.state == .working && sandbox()?.agentWorking == true, "ls (from the host's memory): working, agentWorking")
    let dump = ex("deckhold dump -s agent")
    check(!dump.contains("7501") && !dump.contains("state="), "nothing of the sequences is on the screen")

    // 2. Blocked, asking for permission — the words everywhere.
    step(1)
    check(t.waitFor(10) { sandbox()?.agentStatus?.state == .blocked }, "blocked: ls says so")
    check(sandbox()?.agentStatus?.kind == .permission && sandbox()?.agentWorking == false, "…needs permission, not working")
    check(t.run(["ls"]).out.contains("blocked: needs permission"), "doz ls: \"blocked: needs permission\"")
    check(t.run(["sessions", "st"]).out.contains("blocked: needs permission"), "doz sessions st: \"blocked: needs permission\"")

    // 3. Done, with a viewer attached: the bytes reach it unchanged, the status is the host's too.
    do {
        let c = try PTYClient(t, ["attach", "st", "agent"])
        defer { c.close() }
        usleep(1_500_000)
        step(2)
        check(c.wait(15) { $0.text.contains("STEP-DONE") }, "attached: the program goes on")
        check(c.text.contains("\(esc)]7501;state=done:app=fake-agent\(esc)\\"), "the report reached the attached terminal byte for byte")
        check(t.waitFor(10) { row()?.status?.state == .done }, "done (with a viewer)")
        c.type("\u{1d}\u{1d}")                         // detach (the menu, then detach)
        _ = c.exited(within: 5)
    } catch { check(false, "pty: \(error)") }

    // 4. Working again with nobody watching; then a sleep and a wake: the watcher comes back, the state holds.
    step(3)
    check(t.waitFor(10) { row()?.status?.state == .working && row()?.status?.progress == 40 }, "detached again: working 40%")
    check(t.run(["sleep", "st"], timeout: 180).code == 0, "sleep st")
    check(sandbox()?.agentStatus?.state == .working, "asleep: the last state is kept (\(sandbox()?.agentStatus?.label ?? "nothing"))")
    check(t.run(["wake", "st"], timeout: 300).code == 0, "wake st")
    step(4)
    check(t.waitFor(20) { sandbox()?.agentStatus?.state == .error }, "after the wake the next report arrives (error) — the watcher came back")
    check(t.waitFor(10) { row()?.ended == true }, "the program exited")
    check(row()?.status?.state == .error && row()?.status?.message == "it broke", "error survives the program's exit")

    // 5. Hibernate and wake, with a new run of the program: the state after the wake is the program's own.
    _ = ex("rm -f /tmp/go*")
    check(t.run(["run", "st", "-d", "--session", "agent", "--", "/tmp/fake-agent.sh"]).code == 0, "the fake agent again (same session name)")
    check(t.waitFor(20) { row()?.status?.state == .working && row()?.status?.message == "thinking hard" }, "a new program: working (the old error is gone)")
    check(t.run(["hibernate", "st"], timeout: 300).code == 0, "hibernate st")
    check(t.run(["wake", "st"], timeout: 300).code == 0, "wake st")
    check(t.waitFor(20) { row()?.status?.state == .working }, "after hibernate → wake: still working (\(row()?.status?.label ?? "nothing"))")
    step(1)
    check(t.waitFor(20) { row()?.status?.state == .blocked }, "…and the next report arrives (blocked)")

    // 6. A session whose program says nothing: no status, nothing broken.
    check(t.run(["run", "st", "-d", "--session", "plain", "--", "sh", "-c", "echo hello; sleep 600"]).code == 0, "a plain program")
    usleep(1_500_000)
    check(t.sessions("st").first { $0.name == "plain" }.map { $0.status == nil } == true, "a program that reports nothing has no status")

    // 7. The events: one per change, in order; host.log has the metadata only.
    let seen = statusEvents().map { $0.sessionStatus?.state }
    let want: [ProgramStatus.State?] = [.working, .blocked, .done, .working, .error, .working, .blocked]
    check(seen.filter { $0 != nil } == want, "the events: one per change (\(seen.map { $0?.rawValue ?? "none" }.joined(separator: " → ")))")
    let log = hostLog(t)
    check(log.contains("session agent: blocked: needs permission (fake-agent)"), "host.log has the status")
    check(!log.contains("run the tests?") && !log.contains("thinking hard") && !log.contains("it broke"), "host.log never has the program's text")

    // 8. Shut down: the programs are gone, and so is what they said.
    check(t.run(["shutdown", "st", "--yes"], timeout: 300).code == 0, "shutdown st")
    check(t.waitFor(10) { sandbox()?.agentStatus == nil }, "shut down: no status (\(sandbox()?.agentStatus?.label ?? "none"))")
}
