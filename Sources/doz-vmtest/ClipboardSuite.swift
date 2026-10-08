import Darwin
import Foundation
import DozerKit
import DozerHost

// 599 (594.B1, owner: "lets get a proper bridge working for the clipboard so that claudes copy to clipboard
// just works"): a program's OSC 52 copy reaches the Mac clipboard through the host — here a FILE
// (`DOZ_TEST_PASTEBOARD`), never the real pasteboard — with a notice every time (the bottom row, then a
// repaint; a stderr line off a terminal); a READ is never answered and never reaches the outer terminal;
// the size and rate limits; `sandbox.clipboard` off, per sandbox and for all. The real signed `doz` on a
// pseudo-terminal, a lab sandbox in a scratch store (`/tmp/dzo-PID-c`).

private let esc = "\u{1B}"

func cliClipboardSuite(binary: String) async {
    let t = onboardingHarness(binary, "c", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    let board = t.store.appendingPathComponent("pasteboard")
    t.env["DOZ_TEST_PASTEBOARD"] = board.path
    defer {
        t.run(["host", "stop"])
        try? FileManager.default.removeItem(at: t.store)
    }
    func pasteboard() -> String? { (try? Data(contentsOf: board)).map { String(decoding: $0, as: UTF8.self) } }
    func clearBoard() { try? FileManager.default.removeItem(at: board) }

    print("cli: the clipboard bridge (599, 594.B1)")
    check(t.run(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    var r = t.run(["up", "cb", "--image", "lab", "--isolated", "--memory", "512M", "--detach"], timeout: 600)
    check(r.code == 0, "up cb --image lab --detach (exit \(r.code))")

    // 1. A copy, on a terminal: the Mac clipboard (the file), the notice over the bottom row, then a repaint.
    do {
        let c = try PTYClient(t, ["run", "cb", "--session", "copy", "--", "bash", "--norc", "-i"])
        defer { c.close() }
        check(c.wait(30) { $0.text.contains("$") || $0.text.contains("#") }, "run cb -- bash: a prompt")
        c.type("printf '\\033]52;c;%s\\a' \"$(printf 'hello from the sandbox' | base64)\"; echo COPIED-$((1+1))\r")
        check(c.wait(15) { $0.text.contains("COPIED-2") }, "the session copied (COPIED-2)")
        check(c.wait(5) { _ in pasteboard() == "hello from the sandbox" }, "the Mac clipboard has the text (\(pasteboard()?.debugDescription ?? "nothing"))")
        check(c.wait(5) { $0.text.contains("doz: cb copied 22 chars") }, "the notice: \"cb copied 22 chars\"")
        check(c.text.contains("\(esc)7\(esc)[30;1H"), "…drawn over the bottom row (row 30), the cursor saved and restored")
        check(!c.text.contains("\(esc)]52;"), "the OSC 52 itself never reached the outer terminal")
        let afterNotice = c.bytes.count
        check(c.wait(6) { String(decoding: $0.bytes[afterNotice...], as: UTF8.self).contains("\(esc)c") }, "a repaint (a fresh snapshot) follows within 3 s")

        // A copy cut in two by the program's writes (the host holds the first half).
        clearBoard()
        c.type("printf '\\033]5'; sleep 0.3; printf '2;c;%s\\a' \"$(printf 'split' | base64)\"; echo SPLIT-$((2+2))\r")
        check(c.wait(15) { $0.text.contains("SPLIT-4") } && c.wait(5) { _ in pasteboard() == "split" }, "a copy split across writes still arrives whole (\(pasteboard()?.debugDescription ?? "nothing"))")

        // ST (ESC \) ends it as well as BEL; unpadded base64 is accepted.
        clearBoard()
        c.type("printf '\\033]52;;aGk\\033\\\\'; echo ST-$((3+3))\r")
        check(c.wait(15) { $0.text.contains("ST-6") } && c.wait(5) { _ in pasteboard() == "hi" }, "ST-terminated, unpadded: \"hi\" (\(pasteboard()?.debugDescription ?? "nothing"))")

        // 2. A READ: never answered, never shown; logged once for the session.
        clearBoard()
        c.type("printf '\\033]52;c;?\\a'; printf '\\033]52;c;?\\a'; echo READ-$((4+4))\r")
        check(c.wait(15) { $0.text.contains("READ-8") }, "the session asked to read twice (READ-8)")
        usleep(500_000)
        check(!c.text.contains("\(esc)]52;c;?"), "a read request never reached the outer terminal (so no terminal can answer it)")
        check(pasteboard() == nil, "nothing was written for a read")
        check(occurrences(hostLog(t), "asked to READ the Mac clipboard") == 1, "the refusal is logged once for the session")

        // 3. Too large: over 1 MiB decoded — dropped whole, said.
        c.type("head -c 1100000 /dev/zero | tr '\\0' a > /tmp/big; printf '\\033]52;c;%s\\a' \"$(base64 < /tmp/big | tr -d '\\n')\"; echo BIG-$((5+5))\r")
        check(c.wait(30) { $0.text.contains("BIG-10") }, "a 1.05 MiB copy was sent (BIG-10)")
        check(c.wait(5) { $0.text.contains("over the 1 MiB limit") }, "the notice says it was over the limit")
        check(pasteboard() == nil, "…and nothing reached the Mac clipboard")
        check(!c.text.contains("YWFhYWFhYWFh"), "none of its base64 reached the terminal")

        // 4. Off for this sandbox: dropped, and said.
        check(t.run(["config", "set", "--sandbox", "cb", "sandbox.clipboard", "off"]).code == 0, "doz config set --sandbox cb sandbox.clipboard off")
        check(t.run(["config", "get", "--sandbox", "cb", "sandbox.clipboard"]).out.trimmingCharacters(in: .whitespacesAndNewlines) == "off", "doz config get --sandbox cb: off")
        let shown = t.run(["config", "show", "--sandbox", "cb"]).out
        check(shown.contains("sandbox.clipboard") && shown.contains("cb's own"), "doz config show --sandbox cb: its own value")
        c.type("printf '\\033]52;c;%s\\a' \"$(printf 'nope' | base64)\"; echo OFF-$((6+6))\r")
        check(c.wait(15) { $0.text.contains("OFF-12") } && c.wait(5) { $0.text.contains("its clipboard bridge is off") }, "off: the notice says so")
        check(pasteboard() == nil, "off: nothing reached the Mac clipboard")
        check(t.run(["config", "unset", "--sandbox", "cb", "sandbox.clipboard"]).code == 0, "doz config unset --sandbox cb sandbox.clipboard")
        // The setting for every sandbox.
        check(t.run(["config", "set", "sandbox.clipboard", "off"]).code == 0, "doz config set sandbox.clipboard off")
        c.type("printf '\\033]52;c;%s\\a' \"$(printf 'nope' | base64)\"; echo OFF2-$((7+7))\r")
        check(c.wait(15) { $0.text.contains("OFF2-14") } && c.wait(5) { occurrences($0.text, "its clipboard bridge is off") >= 2 }, "the setting off: said again")
        check(pasteboard() == nil, "the setting off: nothing copied")
        check(t.run(["config", "unset", "sandbox.clipboard"]).code == 0, "doz config unset sandbox.clipboard (write again)")
        check(t.run(["config", "set", "--sandbox", "cb", "ui.theme", "dark"]).code != 0, "a setting that is not per-sandbox is refused with --sandbox")
    } catch { check(false, "pty: \(error)") }

    // 5. Two viewers of ONE session: both are told, the host copies once.
    do {
        let a = try PTYClient(t, ["run", "cb", "--session", "twin", "--", "bash", "--norc", "-i"])
        defer { a.close() }
        check(a.wait(30) { $0.text.contains("$") || $0.text.contains("#") }, "twin: a prompt")
        let b = try PTYClient(t, ["attach", "cb", "twin"])
        defer { b.close() }
        usleep(1_500_000)
        let before = occurrences(hostLog(t), "copied 5 chars to the Mac clipboard")
        a.type("printf '\\033]52;c;%s\\a' \"$(printf 'twins' | base64)\"; echo TWIN-$((8+8))\r")
        check(a.wait(15) { $0.text.contains("TWIN-16") }, "the twin session copied")
        check(a.wait(5) { $0.text.contains("cb copied 5 chars") } && b.wait(5) { $0.text.contains("cb copied 5 chars") }, "both viewers show the notice")
        usleep(500_000)
        let copies = occurrences(hostLog(t), "copied 5 chars to the Mac clipboard") - before
        check(copies == 1, "…and the host copied once (\(copies))")
    } catch { check(false, "pty: \(error)") }

    // 6. Not a terminal: the notice is a line on stderr.
    clearBoard()
    // (A copy is bridged while a viewer is attached — the program waits for `run` to attach first.)
    r = t.run(["run", "cb", "--session", "piped", "--", "sh", "-c", "sleep 2; printf '\\033]52;c;%s\\a' \"$(printf piped | base64)\"; sleep 1"], timeout: 60)
    check(r.err.contains("[doz] cb copied 5 chars") && pasteboard() == "piped", "off a terminal: \"[doz] cb copied 5 chars\" on stderr, and copied (\(r.err.suffix(200).debugDescription))")

    // 7. The rate limit: at most 10 copies in 10 s.
    sleep(10)
    r = t.run(["run", "cb", "--session", "burst", "--", "sh", "-c",
               "sleep 2; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf '\\033]52;c;%s\\a' \"$(printf \"copy-$i\" | base64)\"; done; sleep 1"], timeout: 60)
    check(r.err.contains("copied too often"), "12 copies at once: the 11th is refused (\(occurrences(r.err, "copied too often")) refused)")
    check(pasteboard() == "copy-10", "…the clipboard has the 10th (\(pasteboard()?.debugDescription ?? "nothing"))")

    // 8. doz create --clipboard off; doz_project.yaml clipboard.
    r = t.run(["create", "cb2", "--image", "lab", "--isolated", "--clipboard", "off"], timeout: 120)
    check(r.code == 0, "create cb2 --clipboard off")
    check(t.run(["config", "get", "--sandbox", "cb2", "sandbox.clipboard"]).out.hasPrefix("off"), "cb2's own value: off")
    check(t.run(["create", "cb3", "--image", "lab", "--isolated", "--clipboard", "maybe"], timeout: 60).code != 0, "--clipboard maybe is refused")
    check(t.run(["rm", "cb2", "--yes"], timeout: 120).code == 0, "rm cb2")
}
