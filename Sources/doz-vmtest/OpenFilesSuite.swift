import Darwin
import Foundation
import DozerKit
import DozerHost

// 599b (owner, 2026-10-01: "the agent can open files in the workspace that will open in the default (or
// specific) app on the mac ; e.g. html page will open in a browser, same with markdown"): `xdg-open FILE`,
// `open FILE`, `doz-open --app NAME FILE` in a sandbox with a SHARED workspace → the Mac file, through the
// opener seam (`DOZ_TEST_OPEN_URL`: a file that records `open-file APP|default MACPATH` — never a real app).
// Every refusal (outside /workspace, `..`, symlinks out made on either side, non-documents, a Mach-O named
// .txt, an unlisted app, the setting off, an isolated sandbox), the rate limit, the notice, and URLs still as
// 599 built them. Lab sandboxes on a pseudo-terminal, a scratch store (`/tmp/dzo-PID-f`), a scratch
// workspace (`/tmp/dzo-PID-fw`) and `defaults.projects_dir` set to a scratch path.

private let esc = "\u{1B}"

func cliOpenFilesSuite(binary: String) async {
    let t = onboardingHarness(binary, "f", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    let pid = getpid()
    let ws = URL(fileURLWithPath: "/tmp/dzo-\(pid)-fw")
    let outside = URL(fileURLWithPath: "/tmp/dzo-\(pid)-fo")
    let opened = t.store.appendingPathComponent("opened.log")
    t.env["DOZ_TEST_OPEN_URL"] = opened.path
    defer {
        t.run(["host", "stop"])
        for u in [t.store, ws, outside, URL(fileURLWithPath: "/tmp/dzo-\(pid)-fp")] { try? FileManager.default.removeItem(at: u) }
    }
    func log() -> String { (try? String(contentsOf: opened, encoding: .utf8)) ?? "" }
    let fm = FileManager.default
    for u in [ws, outside] { try? fm.removeItem(at: u); try? fm.createDirectory(at: u, withIntermediateDirectories: true) }
    try? fm.createDirectory(at: ws.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: ws.appendingPathComponent("Thing.app/Contents"), withIntermediateDirectories: true)
    func put(_ name: String, _ text: String, mode: Int16 = 0o644) {
        let p = ws.appendingPathComponent(name).path
        fm.createFile(atPath: p, contents: Data(text.utf8))
        chmod(p, mode_t(mode))
    }
    for (n, s) in [("report.html", "<h1>report</h1>"), ("notes.md", "# notes"), ("sub/page.htm", "<p>page</p>"), ("x.command", "echo hi"),
                   ("run.webloc", "<plist/>"), ("noext", "text"), ("script.txt", "#!/bin/sh\necho hi\n"),
                   ("a.md", "a"), ("b.md", "b"), ("c.md", "c"), ("d.md", "d"), ("off.md", "off")] { put(n, s) }
    put("exec.txt", "plain", mode: 0o755)
    try? fm.copyItem(atPath: "/bin/ls", toPath: ws.appendingPathComponent("macho.txt").path)       // a Mac program named .txt
    chmod(ws.appendingPathComponent("macho.txt").path, 0o644)
    fm.createFile(atPath: outside.appendingPathComponent("secret.html").path, contents: Data("<p>secret</p>".utf8))
    try? fm.createSymbolicLink(atPath: ws.appendingPathComponent("mac-out.html").path, withDestinationPath: outside.appendingPathComponent("secret.html").path)
    // Folders: a child, a package macOS knows by its type (.rtfd), and a link to a folder outside.
    try? fm.createDirectory(at: ws.appendingPathComponent("docs"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: ws.appendingPathComponent("Notes.rtfd"), withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: ws.appendingPathComponent("mac-dir-out").path, withDestinationPath: outside.path)
    let real = (try? fm.destinationOfSymbolicLink(atPath: "/tmp")).map { "/" + $0 + "/dzo-\(pid)-fw" } ?? ws.path   // /private/tmp/…

    print("cli: open workspace files on the Mac (599b)")
    check(t.run(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    check(t.run(["config", "set", "defaults.projects_dir", "/tmp/dzo-\(pid)-fp"]).code == 0, "defaults.projects_dir is a scratch path")
    var r = t.run(["up", "of", "--image", "lab", "--workspace", ws.path, "--memory", "512M", "--network", "none", "--detach"], timeout: 600)
    check(r.code == 0, "up of --image lab --workspace \(ws.path) --detach (exit \(r.code))")
    r = t.run(["exec", "of", "--", "sh", "-c", "ls -l /usr/local/lib/doz/bin/ | grep -c 'doz-open -> xdg-open'; grep -c 'open-url-shim:v6' /usr/local/lib/doz/bin/xdg-open"])
    check(r.out.split(separator: "\n").map(String.init) == ["1", "1"], "the v6 shim and its doz-open link are in the guest (\(r.out.debugDescription))")

    do {
        let c = try PTYClient(t, ["run", "of", "--session", "files", "--", "bash", "--norc", "-i"])
        defer { c.close() }
        check(c.wait(30) { $0.text.contains("$") || $0.text.contains("#") }, "run of -- bash: a prompt")
        c.type("cd /workspace && ln -s ../../../../../../../../etc/hosts guest-out.html && ln -s /etc/hosts guest-abs.txt; echo READY-$((0+1))\r")
        check(c.wait(15) { $0.text.contains("READY-1") }, "links made in the guest")

        // 1. An html and a markdown file → opened in the Mac's default app; relative and from a sub folder.
        c.type("xdg-open report.html; open notes.md; (cd sub && xdg-open page.htm); echo F1-$((1+1))\r")
        check(c.wait(15) { $0.text.contains("F1-2") }, "xdg-open, open and a relative path ran (F1-2)")
        check(!c.text.contains("Asking your Mac"), "the session shows nothing of the shim (609: the notice says it)")
        check(c.wait(10) { _ in log().contains("open-file default \(real)/report.html\n") }, "report.html opened on the Mac, by its Mac path (\(log().debugDescription))")
        check(c.wait(5) { _ in log().contains("open-file default \(real)/notes.md\n") }, "notes.md opened (open FILE)")
        check(c.wait(5) { _ in log().contains("open-file default \(real)/sub/page.htm\n") }, "sub/page.htm opened (a relative path in a sub folder)")
        check(c.wait(5) { $0.text.contains("doz: of opened report.html in ") }, "the notice: \"of opened report.html in <the default app>\"")
        check(c.wait(5) { $0.text.contains("doz: of opened sub/page.htm in ") }, "…and for the sub folder's page")
        check(!c.text.contains("\(esc)]6340"), "the marker never reached the outer terminal")
        check(hostLog(t).contains("asked for /workspace/report.html: of opened report.html in "), "the host log says what was opened")

        // 2. --app: only an app in bridges.open_apps (the LISTED spelling reaches open -a).
        sleep(10)
        check(t.run(["config", "set", "bridges.open_apps", "Typora, Visual Studio Code"]).code == 0, "bridges.open_apps = \"Typora, Visual Studio Code\"")
        c.type("doz-open --app Typora notes.md; open -a typora report.html; doz-open --app Safari notes.md; echo F2-$((2+2))\r")
        check(c.wait(15) { $0.text.contains("F2-4") }, "doz-open --app ran (F2-4)")
        check(c.wait(10) { _ in log().contains("open-file Typora \(real)/notes.md\n") }, "doz-open --app Typora notes.md → open -a Typora")
        check(c.wait(5) { _ in log().contains("open-file Typora \(real)/report.html\n") }, "open -a typora → the listed spelling, Typora")
        check(c.wait(5) { $0.text.contains("doz: of opened notes.md in Typora") }, "the notice names the app")
        check(c.wait(5) { $0.text.contains("doz: of asked to open notes.md in Safari — Safari is not in bridges.open_apps") }, "an unlisted app is refused, naming the setting")
        check(!log().contains("open-file Safari"), "…and nothing opened in it")

        // 3. Refusals — first the shim's own (the agent hears why), then hand-made markers the host refuses.
        sleep(10)
        c.type("xdg-open x.command; xdg-open ../etc/passwd; xdg-open Thing.app; xdg-open exec.txt; xdg-open script.txt; xdg-open guest-abs.txt; echo F3-$((3+3))\r")
        check(c.wait(15) { $0.text.contains("F3-6") }, "the shim's refusals ran (F3-6)")
        check(c.text.contains("x.command is a program, script or installer type: never opened"), "shim: .command")
        check(c.text.contains("only files and folders in /workspace (the folder shared with your Mac) are opened there, not ../etc/passwd"), "shim: .. out of /workspace")
        check(c.text.contains("Thing.app is an app or package: never opened"), "shim: an app bundle (a package folder)")
        check(c.text.contains("exec.txt is executable"), "shim: an executable")
        check(c.text.contains("script.txt is a script"), "shim: a #! script")
        check(c.text.contains("not guest-abs.txt"), "shim: a guest link out of /workspace")
        func marker(_ path: String, app: String = "") -> String { "printf '\\033]6340;doz-file;\(app);%s\\007' '\(path)'; " }
        c.type(marker("/workspace/../etc/passwd") + marker("/etc/hosts") + marker("/workspace/mac-out.html") + marker("/workspace/guest-out.html")
               + marker("/workspace/run.webloc") + marker("/workspace/Thing.app") + marker("/workspace/exec.txt") + marker("/workspace/script.txt")
               + marker("/workspace/noext") + marker("/workspace/missing.html") + marker("/workspace/notes.md", app: "../Evil") + "echo F4-$((4+4))\r")
        check(c.wait(15) { $0.text.contains("F4-8") }, "hand-made markers sent (F4-8)")
        check(c.wait(5) { $0.text.contains("doz: of asked to open /workspace/../etc/passwd — only files in /workspace") }
              || c.text.contains("doz: of asked to open /etc/passwd — only files in /workspace"), "host: .. out of /workspace")
        check(c.wait(5) { $0.text.contains("doz: of asked to open /etc/hosts — only files in /workspace") }, "host: an absolute path outside")
        check(c.wait(5) { $0.text.contains("doz: of asked to open mac-out.html — it leads outside the shared folder") }, "host: a link made on the Mac leading out (resolved on the Mac)")
        check(c.wait(5) { $0.text.contains("doz: of asked to open guest-out.html — it leads outside the shared folder") }, "host: a relative link made in the guest leading out")
        check(c.wait(5) { $0.text.contains("doz: of asked to open run.webloc — .webloc is never opened") }, "host: .webloc")
        check(c.wait(5) { $0.text.contains("doz: of asked to open Thing.app — Thing.app is an app or package") }, "host: an app bundle")
        check(c.wait(5) { $0.text.contains("doz: of asked to open exec.txt — it is executable") }, "host: the executable bit")
        check(c.wait(5) { $0.text.contains("doz: of asked to open script.txt — it is a script") }, "host: a #! script named .txt")
        check(c.wait(5) { $0.text.contains("doz: of asked to open noext — it has no document type") }, "host: no extension")
        check(c.wait(5) { $0.text.contains("doz: of asked to open missing.html — no such file in the workspace") }, "host: a missing file")
        check(c.wait(5) { $0.text.contains("\"../Evil\" is not an app name") }, "host: an app name that is a path")
        // The shim passes a Mach-O named .txt (not executable, no #!): the host's sniff refuses it.
        c.type("xdg-open macho.txt; echo F5-$((5+5))\r")
        check(c.wait(15) { $0.text.contains("F5-10") } && c.wait(5) { $0.text.contains("doz: of asked to open macho.txt — it is a Mac program (Mach-O)") },
              "host: a Mac program renamed .txt (content sniff)")
        check(!log().contains("secret") && !log().contains("/etc/") && !log().contains("webloc") && !log().contains("macho") && !log().contains("Thing.app")
              && !log().contains("exec.txt") && !log().contains("script.txt") && !log().contains("noext") && !log().contains("guest-out"),
              "none of them was opened (\(log().debugDescription))")

        // 3b. Folders in the Finder, and --reveal (owner: "open the workspace (or child dir of) directory in
        //     the Finder").
        c.type("xdg-open .; open docs; doz-open --reveal notes.md; echo D1-$((1+20))\r")
        check(c.wait(15) { $0.text.contains("D1-21") }, "folders and a reveal asked for (D1-21)")
        check(!c.text.contains("Asking your Mac"), "the shim prints nothing for a folder either (609)")
        check(c.wait(10) { _ in log().contains("open-folder \(real)\n") }, "open . → the workspace in the Finder (\(log().suffix(160).debugDescription))")
        check(c.wait(5) { _ in log().contains("open-folder \(real)/docs\n") }, "open docs → a child folder in the Finder")
        check(c.wait(5) { _ in log().contains("reveal \(real)/notes.md\n") }, "doz-open --reveal notes.md → shown selected in its folder")
        check(c.wait(5) { $0.text.contains("doz: of opened the workspace in the Finder") }, "the notice: \"of opened the workspace in the Finder\"")
        check(c.wait(5) { $0.text.contains("doz: of opened docs/ in the Finder") }, "the notice: \"of opened docs/ in the Finder\"")
        check(c.wait(5) { $0.text.contains("doz: of showed notes.md in the Finder") }, "the notice: \"of showed notes.md in the Finder\"")
        // Refused: a package even for the Finder (shim and host, incl. one macOS knows by type), --app with a
        // folder, .. above the workspace, a link to a folder outside, a reveal outside.
        c.type("open Thing.app; doz-open --app Typora docs; "
               + "printf '\\033]6340;doz-file;;/workspace/..\\007'; printf '\\033]6340;doz-file;;/workspace/mac-dir-out\\007'; "
               + "printf '\\033]6340;doz-file;;/workspace/Notes.rtfd\\007'; printf '\\033]6340;doz-file;Typora;/workspace/docs\\007'; "
               + "printf '\\033]6340;doz-reveal;/workspace/mac-out.html\\007'; echo D2-$((2+20))\r")
        check(c.wait(15) { $0.text.contains("D2-22") }, "folder refusals asked for (D2-22)")
        check(c.text.contains("Thing.app is an app or package: never opened on your Mac (open --reveal shows it in its folder)"), "shim: a package folder")
        check(c.text.contains("--app is for files; a folder opens in the Finder: docs"), "shim: --app with a folder")
        check(c.wait(5) { $0.text.contains("doz: of asked to open /workspace/.. — only files in /workspace") }, "host: .. above the workspace")
        check(c.wait(5) { $0.text.contains("doz: of asked to open mac-dir-out — it leads outside the shared folder") }, "host: a link to a folder outside")
        check(c.wait(5) { $0.text.contains("doz: of asked to open Notes.rtfd — Notes.rtfd is an app or package") }, "host: a package by type (isPackage)")
        check(c.wait(5) { $0.text.contains("doz: of asked to open docs in Typora — --app is for files: a folder opens in the Finder") }, "host: --app with a folder")
        check(c.wait(5) { $0.text.contains("doz: of asked to show mac-out.html — it leads outside the shared folder") }, "host: a reveal outside")
        check(!log().contains("outside") && !log().contains("rtfd") && !log().contains("dzo-\(pid)-fo") && !log().contains("Thing.app"), "none of them shown")
        sleep(10)
        c.type("doz-open --reveal Thing.app; doz-open --reveal sub; echo D3-$((3+20))\r")
        check(c.wait(15) { $0.text.contains("D3-23") }, "reveals asked for (D3-23)")
        check(c.wait(10) { _ in log().contains("reveal \(real)/Thing.app\n") }, "--reveal on a package shows it selected in its folder (never opened)")
        check(c.wait(5) { _ in log().contains("open-folder \(real)/sub\n") }, "--reveal on a folder shows the folder")
        check(c.wait(5) { $0.text.contains("doz: of showed Thing.app in the Finder") }, "the reveal's notice")
        sleep(10)

        // 4. Off for this sandbox.
        check(t.run(["config", "set", "--sandbox", "of", "sandbox.open_files", "off"]).code == 0, "doz config set --sandbox of sandbox.open_files off")
        c.type("xdg-open off.md; echo F6-$((6+6))\r")
        check(c.wait(15) { $0.text.contains("F6-12") } && c.wait(5) { $0.text.contains("doz: of asked to open off.md — opening files is off for it (sandbox.open_files)") },
              "off: said")
        check(!log().contains("off.md"), "off: nothing opened")
        check(t.run(["config", "unset", "--sandbox", "of", "sandbox.open_files"]).code == 0, "doz config unset --sandbox of sandbox.open_files")

        // 5. URLs still behave as 599 built them.
        c.type("xdg-open 'https://example.com/still?q=1'; xdg-open file:///etc/passwd; echo F7-$((7+7))\r")
        check(c.wait(15) { $0.text.contains("F7-14") }, "URLs asked for (F7-14)")
        check(c.wait(5) { _ in log().contains("open https://example.com/still?q=1\n") }, "an https URL opens in the Mac's browser, as before")
        check(c.wait(5) { $0.text.contains("doz: of opened https://example.com/still in your browser") }, "…with its notice, as before")
        check(c.text.contains("only http and https URLs go to the Mac: file:///etc/passwd"), "file: URLs are still refused by the shim")

        // 6. The rate limit: at most 3 files in 10 s.
        sleep(10)
        c.type("for f in a.md b.md c.md d.md; do xdg-open \"$f\"; done; echo F8-$((8+8))\r")
        check(c.wait(15) { $0.text.contains("F8-16") } && c.wait(5) { $0.text.contains("of asked to open too many files — d.md not opened") }, "a 4th file within 10 s is refused")
        check(log().contains("/c.md\n") && !log().contains("/d.md"), "…3 were opened")
    } catch { check(false, "pty: \(error)") }

    // 7. An isolated sandbox: the shim says so, and a hand-made marker is refused by the host.
    r = t.run(["up", "of2", "--image", "lab", "--isolated", "--memory", "512M", "--network", "none", "--detach"], timeout: 600)
    check(r.code == 0, "up of2 --isolated --detach (exit \(r.code))")
    do {
        let c = try PTYClient(t, ["run", "of2", "--session", "iso", "--", "bash", "--norc", "-i"])
        defer { c.close() }
        check(c.wait(30) { $0.text.contains("$") || $0.text.contains("#") }, "run of2 -- bash: a prompt")
        c.type("echo hi > /tmp/n.md; xdg-open /tmp/n.md; printf '\\033]6340;doz-file;;/workspace/notes.md\\007'; "
               + "xdg-open /tmp; printf '\\033]6340;doz-file;;/workspace\\007'; echo F9-$((9+9))\r")
        check(c.wait(15) { $0.text.contains("F9-18") }, "isolated: asked (F9-18)")
        check(c.text.contains("this sandbox is isolated (nothing on your Mac is shared)"), "the shim: isolated")
        check(c.wait(5) { $0.text.contains("doz: of2 asked to open notes.md — it is isolated: nothing on this Mac is shared") }, "the host: isolated")
        check(c.wait(5) { $0.text.contains("doz: of2 asked to open /workspace — it is isolated: nothing on this Mac is shared") }, "the host: a folder in an isolated sandbox")
        check(c.text.contains("no file or folder can be opened there: /tmp"), "the shim: a folder in an isolated sandbox")
        check(!log().contains("n.md") && !log().contains("open-folder /tmp"), "nothing opened")
    } catch { check(false, "pty: \(error)") }
    check(t.run(["rm", "of2", "--yes"], timeout: 120).code == 0, "rm of2")

    // 8. doz create --open-files off; a bad value refused.
    check(t.run(["create", "of3", "--image", "lab", "--isolated", "--open-files", "off"], timeout: 120).code == 0, "create of3 --open-files off")
    check(t.run(["config", "get", "--sandbox", "of3", "sandbox.open_files"]).out.hasPrefix("off"), "of3's own value: off")
    check(t.run(["create", "of4", "--image", "lab", "--isolated", "--open-files", "maybe"], timeout: 60).code != 0, "--open-files maybe is refused")
    check(t.run(["rm", "of3", "--yes"], timeout: 120).code == 0, "rm of3")
    // 9. The settings show both, and a bad app list is refused.
    r = t.run(["config", "show"])
    check(r.out.contains("sandbox.open_files") && r.out.contains("bridges.open_apps"), "doz config show lists sandbox.open_files and bridges.open_apps")
    check(t.run(["config", "set", "bridges.open_apps", "/Applications/Evil.app"]).code != 0, "a path is not an app name")
}
