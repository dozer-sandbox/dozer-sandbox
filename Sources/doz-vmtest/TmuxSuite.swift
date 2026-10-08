import Darwin
import Foundation
import DozerKit
import DozerHost

// 599 (594.B3, owner: "i think we had tmux running in the sandbox very early on ; bring that back as an
// option"): sessions.tmux runs a session inside tmux, WITHIN deckhold — so what deckhold gives keeps
// working: attach and detach (W13/W16), sleep and wake, saved screens, and the bridges (a copy and an
// xdg-open from inside tmux). A lab shell under tmux, then Claude Code under tmux (prepares the
// claude-code image with tmux: network). A scratch store (`/tmp/dzo-PID-x`).

func cliTmuxSuite(binary: String) async {
    let t = onboardingHarness(binary, "x", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    let board = t.store.appendingPathComponent("pasteboard"), opened = t.store.appendingPathComponent("opened.log")
    t.env["DOZ_TEST_PASTEBOARD"] = board.path
    t.env["DOZ_TEST_OPEN_URL"] = opened.path
    t.env["DOZ_TEST_NPM_REGISTRY"] = "offline"
    defer {
        t.run(["host", "stop"])
        try? FileManager.default.removeItem(at: t.store)
    }
    print("cli: sessions inside tmux (599, 594.B3)")
    check(t.run(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    var r = t.run(["up", "tm", "--image", "lab", "--isolated", "--memory", "512M", "--tmux", "--detach"], timeout: 900)
    check(r.code == 0, "up tm --image lab --tmux --detach (the lab image now has tmux: exit \(r.code))")
    check(t.run(["config", "get", "--sandbox", "tm", "sessions.tmux"]).out.hasPrefix("true"), "tm's own sessions.tmux: true")
    r = t.run(["sessions", "tm"])
    check(r.out.contains("tmux -L doz-shell"), "its shell session runs inside tmux (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(160)))")

    do {
        let c = try PTYClient(t, ["attach", "tm"])
        defer { c.close() }
        check(c.wait(30) { $0.text.contains("[shell]") }, "attach: tmux's status bar ([shell])")
        check(c.text.contains("\u{1B}[?1006h") || c.text.contains("\u{1B}[?1000h"), "tmux asked for the mouse (W14: the web terminal reports it)")
        c.type("echo IN-TMUX=${TMUX%%,*}\r")
        check(c.wait(10) { $0.text.contains("IN-TMUX=/tmp/tmux-0/doz-shell") }, "the shell is inside tmux, on its own server (doz-shell)")
        // The clipboard bridge through tmux (set-clipboard on: tmux passes the copy out).
        c.type("printf '\\033]52;c;%s\\a' \"$(printf 'from tmux' | base64)\"; echo COPY-$((1+1))\r")
        check(c.wait(10) { $0.text.contains("COPY-2") } && c.wait(5) { _ in (try? String(contentsOf: board, encoding: .utf8)) == "from tmux" },
              "a copy inside tmux reaches the Mac clipboard")
        // The browser bridge through tmux (the marker goes to the session's own terminal, $DOZ_TTY).
        c.type("xdg-open https://example.com/from-tmux; echo OPEN-$((2+2))\r")
        check(c.wait(10) { $0.text.contains("OPEN-4") } && c.wait(5) { _ in ((try? String(contentsOf: opened, encoding: .utf8)) ?? "").contains("open https://example.com/from-tmux") },
              "xdg-open inside tmux reaches the Mac's browser")
        c.type("echo BEFORE-SLEEP-$((3+3))\r")
        check(c.wait(10) { $0.text.contains("BEFORE-SLEEP-6") }, "typed before the hibernation")
        // Detach: the client catches Ctrl-] before tmux (a double press detaches with or without the menu).
        usleep(300_000)
        c.type("\u{1D}\u{1D}")
        check(c.exited(within: 10) == 0, "Ctrl-] Ctrl-] detaches from a tmux session")
        check(c.text.contains("[doz] detached"), "…with the detach line")
    } catch { check(false, "pty: \(error)") }

    // Sleep and wake: tmux and its shell are where they were; the saved screen shows tmux.
    check(t.run(["hibernate", "tm"], timeout: 120).code == 0, "hibernate tm")
    r = t.run(["sessions", "tm", "--screen", "shell"])
    check(r.out.contains("BEFORE-SLEEP-6") && r.out.contains("[shell]"), "the saved screen is tmux's (its status bar and the shell's lines)")
    check(t.run(["wake", "tm"], timeout: 120).code == 0, "wake tm")
    do {
        let c = try PTYClient(t, ["attach", "tm"])
        defer { c.close() }
        check(c.wait(30) { $0.text.contains("[shell]") }, "reattached after the wake: tmux's screen")
        c.type("echo AFTER-WAKE-$((5+5))\r")
        check(c.wait(10) { $0.text.contains("AFTER-WAKE-10") }, "the same tmux shell answers after the wake")
        c.type("\u{1D}\u{1D}")
        _ = c.exited(within: 10)
    } catch { check(false, "pty: \(error)") }

    // Off for this sandbox: a new session runs without tmux.
    check(t.run(["config", "set", "--sandbox", "tm", "sessions.tmux", "false"]).code == 0, "doz config set --sandbox tm sessions.tmux false")
    check(t.run(["run", "tm", "--session", "plain", "-d", "--", "sleep", "600"]).code == 0, "run tm --session plain -d")
    check(!t.run(["sessions", "tm"]).out.contains("doz-plain"), "…runs without tmux")
    // tmux asked for but not in the image: the session runs without it, and says so.
    check(t.run(["config", "set", "--sandbox", "tm", "sessions.tmux", "true"]).code == 0, "sessions.tmux true again")
    check(t.run(["exec", "tm", "--", "rm", "-f", "/usr/bin/tmux"]).code == 0, "tmux removed from tm (as an older image would lack it)")
    r = t.run(["run", "tm", "--session", "nt", "-d", "--", "sleep", "600"])
    check(r.code == 0 && r.err.contains("this sandbox's image has no tmux"), "no tmux in the image: said, and the session runs (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)))")
    check(t.run(["create", "tm2", "--image", "lab", "--isolated", "--tmux"], timeout: 120).code == 0
          && t.run(["config", "get", "--sandbox", "tm2", "sessions.tmux"]).out.hasPrefix("true"), "doz create --tmux → its own sessions.tmux")
    t.run(["rm", "tm2", "--yes"], timeout: 120)
    t.run(["shutdown", "tm", "--yes"], timeout: 120)

    // Claude Code under tmux (the claude-code image, prepared with tmux — network).
    print("cli: Claude Code inside tmux (prepares the claude-code image)")
    check(t.run(["config", "set", "images.claude_code_version", AgentImages.claudeCodePinned.version]).code == 0, "claude-code at the pin (no registry)")
    r = t.run(["up", "tc", "--image", "claude-code", "--isolated", "--account", "none", "--memory", "1G", "--tmux", "--detach"], timeout: 1800)
    check(r.code == 0, "up tc --image claude-code --tmux --detach (exit \(r.code))")
    check(t.run(["sessions", "tc"]).out.contains("tmux -L doz-claude"), "the claude session runs inside tmux")
    sleep(4)
    r = t.run(["exec", "tc", "--", "tmux", "-L", "doz-claude", "capture-pane", "-p", "-t", "claude"])
    check(r.code == 0 && (r.out.contains("Claude") || r.out.contains("claude")), "tmux holds Claude Code's screen (\(r.out.split(separator: "\n").prefix(3).joined(separator: " / ").prefix(160)))")
    do {
        let c = try PTYClient(t, ["attach", "tc"])
        defer { c.close() }
        check(c.wait(30) { $0.text.contains("[claude]") }, "attach tc: tmux's status bar ([claude])")
        usleep(500_000)
        c.type("\u{1D}\u{1D}")
        check(c.exited(within: 10) == 0, "Ctrl-] Ctrl-] detaches from Claude Code in tmux")
    } catch { check(false, "pty: \(error)") }
    t.run(["shutdown", "tc", "--yes"], timeout: 120)
}
