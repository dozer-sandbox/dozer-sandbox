import Darwin
import Foundation
import DozerKit
import DozerHost

// 599 (594.B2, owner: "add the browser open and port forward bridge … its use-case is to pass through
// browser based oauth logins that the agent TUI initiates"): xdg-open / $BROWSER / open in a sandbox
// reach the Mac's browser — here the opener seam (`DOZ_TEST_OPEN_URL`: a file; never a real tab), which
// also plays the browser's last step of a sign-in: a GET of the redirect on the Mac's localhost:PORT —
// forwarded by the host into the sandbox, where a fake OAuth callback server (busybox nc) answers it.
// A lab sandbox on a pseudo-terminal, in a scratch store (`/tmp/dzo-PID-b`).

private let esc = "\u{1B}"

func cliBrowserSuite(binary: String) async {
    let t = onboardingHarness(binary, "b", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    let opened = t.store.appendingPathComponent("opened.log")
    t.env["DOZ_TEST_OPEN_URL"] = opened.path
    defer {
        t.run(["host", "stop"])
        try? FileManager.default.removeItem(at: t.store)
    }
    func log() -> String { (try? String(contentsOf: opened, encoding: .utf8)) ?? "" }
    let base = 40000 + Int(getpid() % 2000) * 10          // ports this run uses on the Mac (and in the guest)

    print("cli: the browser bridge and a sign-in's callback (599, 594.B2)")
    check(t.run(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    var r = t.run(["up", "bb", "--image", "lab", "--isolated", "--memory", "512M", "--network", "none", "--detach"], timeout: 600)
    check(r.code == 0, "up bb --image lab --network none --detach (exit \(r.code))")
    r = t.run(["exec", "bb", "--", "sh", "-c", "ls -l /usr/local/lib/doz/bin/ | tr -s ' ' | cut -d' ' -f9-; nc 2>&1 | head -1"])
    check(r.out.contains("xdg-open") && r.out.contains("sensible-browser -> xdg-open"), "the shim and its aliases are in the guest (\(r.out.debugDescription))")
    // A login shell (the lab's own session is `bash -l`): /etc/profile resets PATH; the drop-in puts it back.
    r = t.run(["exec", "bb", "--", "bash", "-lc", "command -v xdg-open"])
    check(r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "/usr/local/lib/doz/bin/xdg-open", "a login shell finds the shim too (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    // A fake OAuth callback server, as a real one behaves: it reads the request, then answers
    // (busybox nc -e runs it on the connection; its first argument is where the request line goes).
    r = t.run(["exec", "bb", "--", "sh", "-c",
               #"printf '#!/bin/sh\nread line\necho "$line" > "$1"\nprintf "HTTP/1.0 200 OK\\r\\nContent-Type: text/plain\\r\\n\\r\\nsigned in to the sandbox\\r\\n"\n' > /tmp/cb.sh && chmod +x /tmp/cb.sh && cat /tmp/cb.sh"#])
    check(r.code == 0 && r.out.contains("read line"), "a fake OAuth callback server in the guest (/tmp/cb.sh)")

    do {
        let c = try PTYClient(t, ["run", "bb", "--session", "web", "--", "bash", "--norc", "-i"])
        defer { c.close() }
        check(c.wait(30) { $0.text.contains("$") || $0.text.contains("#") }, "run bb -- bash: a prompt")
        c.type("echo \"PATH=$PATH BROWSER=$BROWSER\" | tr -d '\\n'; echo; command -v xdg-open\r")
        check(c.wait(10) { $0.text.contains("PATH=/usr/local/lib/doz/bin:") && $0.text.contains("BROWSER=/usr/local/lib/doz/bin/xdg-open") },
              "the session's PATH leads with the shim, and $BROWSER is it")

        // 1. A plain page.
        c.type("xdg-open 'https://example.com/docs?x=1'; echo OPEN-$((1+1))\r")
        check(c.wait(15) { $0.text.contains("OPEN-2") }, "xdg-open ran (OPEN-2)")
        // 609 (owner): the shim prints nothing a person sees — the notice says it; the screen stays the program's.
        check(!c.text.contains("Asking your Mac"), "the session shows nothing of the shim (no line written behind the program)")
        check(c.wait(5) { _ in log().contains("open https://example.com/docs?x=1\n") }, "the Mac opened it (the opener seam: \(log().suffix(120).debugDescription))")
        check(c.wait(5) { $0.text.contains("doz: bb opened https://example.com/docs in your browser") }, "the notice: \"bb opened https://example.com/docs in your browser\"")
        check(!c.text.contains("\(esc)]6340"), "the marker never reached the outer terminal")

        // 2. A sign-in: a fake OAuth callback server in the guest; the Mac's browser (the seam) follows the redirect.
        let port = base + 1
        c.type("nc -l -p \(port) -e /tmp/cb.sh /tmp/got.txt & sleep 0.5; "
               + "xdg-open 'https://auth.example.test/oauth/authorize?client_id=doz&redirect_uri=http%3A%2F%2Flocalhost%3A\(port)%2Fcallback&state=st-123'; echo SIGNIN-$((2+2))\r")
        check(c.wait(15) { $0.text.contains("SIGNIN-4") }, "the sign-in URL was handed over (SIGNIN-4)")
        check(c.wait(5) { $0.text.contains("doz: bb opened https://auth.example.test/oauth/authorize · sign-in callback localhost:\(port)") },
              "the notice says the callback is forwarded")
        check(hostLog(t).contains("bb opened https://auth.example.test/oauth/authorize · sign-in callback localhost:\(port) forwarded (10 min)"), "…as the host log does")
        check(c.wait(15) { _ in log().contains("callback \(port) HTTP/1.0 200 OK") && log().contains("signed in to the sandbox") },
              "the Mac's localhost:\(port) reached the guest's server, and its answer came back (\(log().suffix(200).debugDescription))")
        r = t.run(["exec", "bb", "--", "cat", "/tmp/got.txt"])
        check(r.out.contains("GET /callback?code=doz-test-code&state=st-123"), "the guest's server got the callback (\(r.out.prefix(80).debugDescription))")
        // The forward ends shortly after the callback was answered.
        sleep(UInt32(BrowserBridge.graceSeconds) + 2)
        check(BrowserBridge.get(port: port, path: "/") == "refused", "after the callback, the Mac's localhost:\(port) is closed again")
        check(hostLog(t).contains("the sign-in callback forward localhost:\(port) ended (the sign-in's callback was answered)"), "…and the host log says why")
        check(!hostLog(t).contains("st-123"), "the host log never has the sign-in's query")

        // 3. Claude Code's /login-shaped URL, through $BROWSER, from a setsid'd opener (no controlling terminal: $DOZ_TTY).
        let port2 = base + 2
        let claude = "https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code"
            + "&redirect_uri=http%3A%2F%2Flocalhost%3A\(port2)%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference"
            + "&code_challenge=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG&code_challenge_method=S256&state=claude-state"
        sleep(10)                                                    // the open rate limit's window
        c.type("nc -l -p \(port2) -e /tmp/cb.sh /tmp/got2.txt & sleep 0.5; "
               + "setsid sh -c '\"$BROWSER\" \"$0\"' '\(claude)' </dev/null >/dev/null 2>&1; echo CLAUDE-$((3+3))\r")
        check(c.wait(15) { $0.text.contains("CLAUDE-6") }, "a setsid'd $BROWSER ran (CLAUDE-6)")
        check(c.wait(5) { _ in log().contains("open \(claude)\n") }, "Claude Code's sign-in URL was opened whole (via $DOZ_TTY — no controlling terminal)")
        check(c.wait(15) { _ in log().contains("callback \(port2) HTTP/1.0 200 OK") }, "…and its callback reached the guest")
        r = t.run(["exec", "bb", "--", "cat", "/tmp/got2.txt"])
        check(r.out.contains("state=claude-state"), "the guest's server got Claude's callback")

        // 4. Refused: not http(s); the Mac's own loopback; a marker printed by hand.
        sleep(10)
        c.type("xdg-open file:///etc/passwd; printf '\\033]6340;doz-open;file:///etc/passwd\\a'; xdg-open http://localhost:3000/; echo REFUSED-$((4+4))\r")
        check(c.wait(15) { $0.text.contains("REFUSED-8") }, "three refusals asked for (REFUSED-8)")
        check(c.text.contains("only http and https URLs go to the Mac: file:///etc/passwd"), "the shim itself refuses file:")
        check(c.wait(5) { $0.text.contains("only http and https URLs are opened (not file:)") }, "a hand-made marker for file: is refused by the host")
        check(c.wait(5) { $0.text.contains("localhost is the sandbox's own machine") }, "http://localhost:3000 is refused (the sandbox's localhost is not the Mac's)")
        check(!log().contains("file:") && !log().contains("localhost:3000"), "none of them was opened")

        // 5. The Mac's port is taken: opened, but said that the sign-in cannot return.
        let port3 = base + 3
        let squatter = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                            sin_port: in_port_t(UInt16(port3).bigEndian), sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(squatter, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(squatter, 1)
        c.type("xdg-open 'https://auth.example.test/x?redirect_uri=http://127.0.0.1:\(port3)/cb'; echo BUSY-$((5+5))\r")
        check(c.wait(15) { $0.text.contains("BUSY-10") } && c.wait(5) { _ in hostLog(t).contains("localhost:\(port3) is in use on this Mac — the sign-in cannot return") },
              "a taken Mac port is said")
        check(c.text.contains("doz: bb opened https://auth.example.test/x · localhost:\(port3) is in use"), "…in the notice too")
        close(squatter)

        // 6. The rate limit: at most 3 in 10 s.
        sleep(10)
        c.type("for i in 1 2 3 4; do xdg-open \"https://example.com/burst-$i\"; done; echo BURST-$((6+6))\r")
        check(c.wait(15) { $0.text.contains("BURST-12") } && c.wait(5) { $0.text.contains("asked to open too many URLs") }, "a 4th open within 10 s is refused")
        check(log().contains("burst-3") && !log().contains("burst-4"), "…3 were opened")

        // 7. Off for this sandbox.
        check(t.run(["config", "set", "--sandbox", "bb", "sandbox.browser_bridge", "off"]).code == 0, "doz config set --sandbox bb sandbox.browser_bridge off")
        sleep(10)
        c.type("xdg-open https://example.com/off; echo OFF-$((7+7))\r")
        check(c.wait(15) { $0.text.contains("OFF-14") } && c.wait(5) { $0.text.contains("its browser bridge is off") }, "off: said")
        check(!log().contains("/off"), "off: nothing opened")
        check(t.run(["config", "unset", "--sandbox", "bb", "sandbox.browser_bridge"]).code == 0, "doz config unset --sandbox bb sandbox.browser_bridge")
    } catch { check(false, "pty: \(error)") }

    // 8. doz create --browser-bridge off; a bad value refused.
    check(t.run(["create", "bb2", "--image", "lab", "--isolated", "--browser-bridge", "off"], timeout: 120).code == 0, "create bb2 --browser-bridge off")
    check(t.run(["config", "get", "--sandbox", "bb2", "sandbox.browser_bridge"]).out.hasPrefix("off"), "bb2's own value: off")
    check(t.run(["create", "bb3", "--image", "lab", "--isolated", "--browser-bridge", "maybe"], timeout: 60).code != 0, "--browser-bridge maybe is refused")
    check(t.run(["rm", "bb2", "--yes"], timeout: 120).code == 0, "rm bb2")
}
