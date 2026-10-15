import Darwin
import Foundation
import DozerHost
import DozerKit

// 617 — the recipe agents (Grok Build, Gemini CLI, Antigravity CLI) in real VMs, through SEAMS ONLY — never xAI or
// Google, never a real key, never the owner's keychain, op or aws:
//   - a FAKE provider on this Mac (Scripts/fake-provider.py: TLS with its own CA, xAI's and the Gemini API's endpoints,
//     answering DOZ_FAKE_OK and recording which auth header carried what). The proxy's leg and the key check go there
//     (DOZ_TEST_PROVIDER_UPSTREAM + DOZ_TEST_PROVIDER_CA), trusting ONLY that CA;
//   - keys are FAKE and live in the host's memory (DOZ_TEST_CREDENTIALS=memory); 1Password is a fake `op` (DOZ_TEST_OP).
// The REAL agents (their pinned releases) run in the VMs.
// Checks per agent: the pinned version, the launcher's approval flag (and ask), a round trip with the key swapped in
// and the guest holding only a placeholder, no key anywhere in the guest, the leak guard, a fresh try's first run with
// no counted refusal (an unexpected request still counted), a key from 1Password (and its signed-out reason), and `doz
// try` off a terminal. AGENTS_PARTS=grok,gemini,antigravity (default all) picks agents; AGENTS_KEEP=1 keeps the store.

func cliAgentsSuite(binary: String) async {
    let pid = getpid()
    let env = ProcessInfo.processInfo.environment
    let keep = env["AGENTS_KEEP"] == "1"
    let parts = Set((env["AGENTS_PARTS"] ?? "grok,gemini,antigravity,custom").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
    let kept = URL(fileURLWithPath: "/tmp/dzo-agents-keep")
    let t: CLIHarness
    let seed = ["kernels", "content", "state.json", "initfs.ext4", "golden"]
    if keep {
        t = CLIHarness(binary: binary, store: kept)
        if !FileManager.default.fileExists(atPath: kept.appendingPathComponent("host.log").path) {
            let src = NSTemporaryDirectory() + "doz-vmtest-store"
            try? FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
            for item in seed where FileManager.default.fileExists(atPath: src + "/" + item) { _ = onMac(["/bin/cp", "-cR", src + "/" + item, kept.path + "/"]) }
        }
        t.env["DOZ_HOST_IDLE"] = "2"
        t.env["DOZ_TEST_CREDENTIALS"] = "memory"
    } else {
        t = onboardingHarness(binary, "ag", seed: seed)
    }
    t.env["DOZ_TEST_NPM_REGISTRY"] = "offline"          // the pinned releases — no registry lookups
    t.env["DOZ_TEST_BASE_REGISTRY"] = "pinned"
    t.env["DO_NOT_TRACK"] = "1"
    let w = URL(fileURLWithPath: "/tmp/dzo-\(pid)-agw")
    let fm = FileManager.default
    try? fm.removeItem(at: w)
    try? fm.createDirectory(at: w, withIntermediateDirectories: true)
    let ws = w.path
    var server: Process?
    defer {
        t.run(["host", "stop", "--store", t.store.path], timeout: 300)
        server?.terminate()
        if !keep { try? fm.removeItem(at: t.store) }
        try? fm.removeItem(at: w)
    }
    print("cli: recipe agents — Grok Build, Gemini CLI, Antigravity CLI through a fake provider (617)")
    func d(_ args: [String], stdin: Data? = nil, timeout: Double = 600) -> CLIRun {
        var a = args
        if let i = a.firstIndex(of: "--") { a.insert(contentsOf: ["--store", t.store.path], at: i) } else { a += ["--store", t.store.path] }
        return t.run(a, stdin: stdin, timeout: timeout)
    }

    // ── The fake provider (scratch CA + a leaf for api.x.ai and generativelanguage.googleapis.com) ─────────
    let xaiKey = "xai-FAKE-SUITE-0123456789abcdef", googleKey = "AIzaFAKESUITE-0123456789abcdef"
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    try? "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n".write(toFile: ws + "/ca.ext", atomically: true, encoding: .utf8)
    try? "subjectAltName=DNS:api.x.ai,DNS:generativelanguage.googleapis.com,DNS:www.example.com\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n"
        .write(toFile: ws + "/leaf.ext", atomically: true, encoding: .utf8)
    let m0 = onMac(["/bin/sh", "-c", """
        set -e
        /usr/bin/openssl req -new -newkey rsa:2048 -nodes -keyout ca.key -out ca.csr -subj '/CN=Dozer test provider CA' 2>&1
        /usr/bin/openssl x509 -req -in ca.csr -signkey ca.key -out ca.pem -days 2 -extfile ca.ext 2>&1
        /usr/bin/openssl req -new -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj '/CN=api.x.ai' 2>&1
        /usr/bin/openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out leaf.pem -days 2 -extfile leaf.ext 2>&1
        """], cwd: ws)
    check(m0.code == 0, "a throwaway CA and a certificate for api.x.ai / generativelanguage.googleapis.com (\(m0.code))")
    let srv = Process()
    srv.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    srv.arguments = [repo.appendingPathComponent("Scripts/fake-provider.py").path, ws + "/leaf.pem", ws + "/leaf.key", ws + "/requests.log", ws + "/port"]
    var senv = env
    senv["FAKE_XAI_KEY"] = xaiKey
    senv["FAKE_GOOGLE_KEY"] = googleKey
    srv.environment = senv
    srv.standardOutput = FileHandle.nullDevice
    srv.standardError = FileHandle.nullDevice
    do { try srv.run(); server = srv } catch { check(false, "start the fake provider: \(error)") }
    var port = ""
    for _ in 0..<50 where port.isEmpty { usleep(100_000); port = (try? String(contentsOfFile: ws + "/port", encoding: .utf8)) ?? "" }
    check(!port.isEmpty, "the fake provider listens on 127.0.0.1:\(port) (TLS, its own CA)")
    func requests() -> [[String: Any]] {
        ((try? String(contentsOfFile: ws + "/requests.log", encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
    t.env["DOZ_TEST_PROVIDER_UPSTREAM"] = "127.0.0.1:\(port)"
    t.env["DOZ_TEST_PROVIDER_CA"] = ws + "/ca.pem"
    // A custom key's host goes to the fake too (nothing reaches the real www.example.com).
    t.env["DOZ_TEST_PROVIDER_HOSTS"] = "www.example.com"
    // A fake op: prints the key for op://T/xai/k, or plays "signed out" when the file says so.
    let opScript = ws + "/op"
    try? """
        #!/bin/sh
        echo "$@" >> '\(ws)/op.calls'
        if [ -f '\(ws)/op.signedout' ]; then echo "[ERROR] You are not currently signed in. Please run 'op signin --help' for instructions" >&2; exit 1; fi
        for a in "$@"; do [ "$a" = op://T/xai/k ] && { printf '%s\\n' '\(xaiKey)'; exit 0; }; done
        echo "[ERROR] no item" >&2; exit 1
        """.write(toFile: opScript, atomically: true, encoding: .utf8)
    chmod(opScript, 0o755)
    t.env["DOZ_TEST_OP"] = opScript
    _ = d(["host", "stop"], timeout: 300)
    if keep { for n in ["ag-grok", "ag-gemini", "ag-antigravity", "ag-op", "ag-custom", "try-grok", "try-gemini", "try-agy"] { _ = d(["rm", n, "--yes"], timeout: 120) } }

    // Keys: fake, checked against the fake (the provider's check request goes there too).
    let a1 = d(["account", "add", "xai", "--provider", "xai", "--force"], stdin: Data((xaiKey + "\n").utf8))
    check(a1.code == 0, "doz account add xai --provider xai: the key checked against the fake and kept in memory")
    let a2 = d(["account", "add", "google", "--provider", "google", "--force"], stdin: Data((googleKey + "\n").utf8))
    check(a2.code == 0, "doz account add google --provider google")
    let accountsFile = (try? String(contentsOf: t.store.appendingPathComponent("accounts.json"), encoding: .utf8)) ?? ""
    check(!accountsFile.contains(xaiKey) && !accountsFile.contains(googleKey), "accounts.json holds no key")

    struct Cell { var agent: String; var bin: String; var env: String; var other: (host: String, header: String) }
    let cells = [
        Cell(agent: "grok", bin: "grok", env: "XAI_API_KEY", other: ("generativelanguage.googleapis.com", "x-goog-api-key")),
        Cell(agent: "gemini", bin: "gemini", env: "GEMINI_API_KEY", other: ("api.x.ai", "Authorization: Bearer")),
        Cell(agent: "antigravity", bin: "agy", env: "GEMINI_API_KEY", other: ("api.x.ai", "Authorization: Bearer")),
    ].filter { parts.contains($0.agent) }

    for c in cells {
        guard let r = AgentRecipes.recipe(c.agent) else { check(false, "\(c.agent): a recipe"); continue }
        let name = "ag-\(c.agent)"
        print("  \(r.title) on \(r.defaultBase)")
        // The pinned release (the registry is offline for the suite): an exact version setting.
        let set = d(["config", "set", "images.\(c.agent)_version", r.install.pinned.version])
        check(set.code == 0, "\(c.agent): images.\(c.agent)_version = its pin \(r.install.pinned.version)")
        let made = d(["create", name, "--agent", c.agent, "--network", "agent", "--isolated", "--start"], timeout: 1500)
        check(made.code == 0, "\(c.agent): doz create --agent \(c.agent) --start (prepares \(r.title) at its pin, checksum-verified)")
        let pin = String(r.install.pinned.version.split(separator: "+").first!)
        let v = d(["exec", name, "--", c.bin, "--version"])
        check(v.out.contains(pin), "\(c.agent): \(c.bin) --version says \(pin) (\(v.out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(60)))")
        // The launcher: approval prompts off, unless ask.
        let flag = r.launch.noPromptsArgs.first ?? ""
        let echoVar = r.permissionsVariable.replacingOccurrences(of: "_PERMISSIONS", with: "_LAUNCHER_ECHO")
        let e1 = d(["exec", name, "-e", "\(echoVar)=1", "--", c.bin, "-p", "hi"])
        check(e1.out.contains(flag), "\(c.agent): the launcher puts \(flag) first")
        let e2 = d(["exec", name, "-e", "\(echoVar)=1", "-e", "\(r.permissionsVariable)=ask", "--", c.bin, "-p", "hi"])
        check(!e2.out.contains(flag) && e2.code == 0, "\(c.agent): \(r.permissionsVariable)=ask keeps the prompts")
        // The round trip: the fake answers, it saw the REAL (fake) key, the guest held a placeholder.
        let before = requests().count
        let rt = d(["exec", name, "--", c.bin, "-p", "say ok"], timeout: 240)
        check(rt.out.contains("DOZ_FAKE_OK"), "\(c.agent): \(c.bin) -p reaches the fake through the proxy (DOZ_FAKE_OK)")
        let seen = requests().dropFirst(before)
        let wanted = c.agent == "grok" ? "Bearer " + xaiKey : googleKey
        check(seen.contains { (($0["auth"] as? [String: String]) ?? [:]).values.contains(wanted) }, "\(c.agent): the fake saw the key swapped in by the proxy")
        let ph = d(["exec", name, "--", "sh", "-c", "printf %s \"$\(c.env)\""])
        check(ph.out.hasPrefix("doz_cred_"), "\(c.agent): the guest's \(c.env) is a doz placeholder")
        // No key anywhere in the guest.
        let scan = d(["exec", name, "--user", "root", "--", "sh", "-c",
                      "grep -rlsF -e '\(xaiKey)' -e '\(googleKey)' /proc/[0-9]*/environ /home /root /run /tmp /etc 2>/dev/null | head -3; echo scanned"])
        check(scan.out.trimmingCharacters(in: .whitespacesAndNewlines) == "scanned", "\(c.agent): the key is nowhere in the guest (\(scan.out.prefix(120)))")
        // The leak guard: its placeholder sent to the OTHER provider's host is refused (403) and logged.
        let hdr = c.other.header.hasPrefix("Authorization") ? "Authorization: Bearer $\(c.env)" : "\(c.other.header): $\(c.env)"
        _ = d(["net", "allow", name, "site:\(c.other.host)", "--yes"])
        let n0 = requests().count
        let leak = d(["exec", name, "--", "sh", "-c", "curl -s -o /dev/null -w '%{http_code}' -H \"\(hdr)\" https://\(c.other.host)/v1/models"])
        // Refused by the proxy in that provider's own error shape (Google answers a bad key with 400) — and it never
        // reached the provider with this agent's placeholder or key.
        let leaked = requests().dropFirst(n0).contains { (($0["auth"] as? [String: String]) ?? [:]).values.contains { $0.contains("doz_cred_") || $0.contains(xaiKey) || $0.contains(googleKey) } }
        check(["400", "401", "403"].contains(leak.out.trimmingCharacters(in: .whitespaces)) && !leaked,
              "\(c.agent): its placeholder sent to \(c.other.host) is refused by the proxy, nothing reaches the provider (\(leak.out))")
        // Standard: an unexpected host is refused and counted.
        _ = d(["exec", name, "--", "sh", "-c", "curl -s -m 5 -o /dev/null https://example.com/ || true"])
        let denied = t.row(name)?.deniedConnections ?? 0
        check(denied >= 1, "\(c.agent): example.com is refused and counted (\(denied))")
        _ = d(["rm", name, "--yes"], timeout: 300)
    }

    // ── A fresh try: no refusal counted at its first run (owner) — and an unexpected one still is ─────────
    for c in cells {
        let r = d(["try", c.agent, "-d", "-q"], timeout: 1500)
        let tryName = t.ls().first { $0.trial == true }?.name ?? ""
        check(r.code == 0 && !tryName.isEmpty, "\(c.agent): doz try -d makes a try (\(tryName))")
        sleep(20)
        let row = t.row(tryName)
        check(row?.deniedConnections ?? -1 == 0, "\(c.agent): a fresh try's first run shows no counted refusal (\(row?.deniedConnections ?? -1))")
        check(row?.trial == true, "\(c.agent): it is a try")
        _ = d(["exec", tryName, "--", "sh", "-c", "curl -s -m 5 -o /dev/null https://api.anthropic.com/ || true"])
        check((t.row(tryName)?.deniedConnections ?? 0) >= 1, "\(c.agent): an unexpected request (Anthropic, from a \(c.agent) try) is refused and counted")
        _ = d(["rm", tryName, "--yes"], timeout: 300)
    }

    // ── Off a terminal: doz try makes and starts it, never attaches, and says how to ─────────────────────
    if let c = cells.first {
        let r = d(["try", c.agent], timeout: 1500)
        let tryName = t.ls().first { $0.trial == true }?.name ?? ""
        check(r.code == 0 && r.out.contains("doz attach \(tryName)"), "\(c.agent): doz try off a terminal starts it and prints the attach command")
        if !tryName.isEmpty { _ = d(["rm", tryName, "--yes"], timeout: 300) }
    }

    // ── A custom key (a host no provider owns): refused unless its host is allowed, swapped there only ─────
    if parts.contains("custom") && parts.contains("grok") {
        let customKey = "EXAMPLE-FAKE-SUITE-custom-0123456789"
        let ca = d(["account", "add", "ex", "--custom", "--host", "www.example.com", "--env-var", "EXAMPLE_API_KEY", "--bearer", "--force"],
                   stdin: Data((customKey + "\n").utf8))
        check(ca.code == 0, "doz account add ex --custom --host www.example.com --bearer: a custom key, held in memory")
        let refused = d(["create", "ag-custom", "--image", "grok", "--account", "xai", "--key", "ex", "--isolated"], timeout: 300)
        check(refused.code != 0 && t.row("ag-custom") == nil, "a custom key is refused when the policy does not allow its host (\(refused.err.trimmingCharacters(in: .whitespacesAndNewlines).suffix(120)))")
        let mk = d(["create", "ag-custom", "--image", "grok", "--account", "xai", "--key", "ex", "--allow", "site:www.example.com", "--isolated", "--start"], timeout: 1500)
        check(mk.code == 0, "with --allow site:www.example.com it is attached")
        let ph = d(["exec", "ag-custom", "--", "sh", "-c", "printf %s \"$EXAMPLE_API_KEY\""])
        check(ph.out.hasPrefix("doz_cred_"), "the guest's EXAMPLE_API_KEY is a doz placeholder")
        let n0 = requests().count
        let on = d(["exec", "ag-custom", "--", "sh", "-c", "curl -s -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer $EXAMPLE_API_KEY\" https://www.example.com/custom/echo"])
        let seen = requests().dropFirst(n0)
        check(seen.contains { $0["path"] as? String == "/custom/echo" && (($0["auth"] as? [String: String]) ?? [:]).values.contains("Bearer " + customKey) },
              "the custom key is swapped in on its own host (\(on.out))")
        let n1 = requests().count
        let off = d(["exec", "ag-custom", "--", "sh", "-c", "curl -s -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer $EXAMPLE_API_KEY\" https://api.x.ai/v1/models"])
        let leaked = requests().dropFirst(n1).contains { (($0["auth"] as? [String: String]) ?? [:]).values.contains { $0.contains("doz_cred_") || $0.contains(customKey) } }
        check(["400", "401", "403"].contains(off.out.trimmingCharacters(in: .whitespaces)) && !leaked,
              "its placeholder sent to api.x.ai is refused, nothing reaches the provider (\(off.out))")
        let rt = d(["exec", "ag-custom", "--", "grok", "-p", "say ok"], timeout: 240)
        check(rt.out.contains("DOZ_FAKE_OK"), "Grok Build still works beside the custom key")
        let scan = d(["exec", "ag-custom", "--user", "root", "--", "sh", "-c",
                      "grep -rlsF -e '\(customKey)' -e '\(xaiKey)' /proc/[0-9]*/environ /home /root /run /tmp /etc 2>/dev/null | head -3; echo scanned"])
        check(scan.out.trimmingCharacters(in: .whitespacesAndNewlines) == "scanned", "no key in the guest (\(scan.out.prefix(120)))")
        let log = (try? String(contentsOf: t.store.appendingPathComponent("host.log"), encoding: .utf8)) ?? ""
        check(!log.contains(customKey), "host.log holds no custom key")
        _ = d(["rm", "ag-custom", "--yes"], timeout: 300)
    }

    // ── A key from 1Password (a fake op): used, then its signed-out reason — never another key ───────────
    if parts.contains("grok") {
        let add = d(["account", "add", "xop", "--provider", "xai", "--from", "op://T/xai/k", "--force", "--yes"])
        check(add.code == 0, "doz account add xop --from op://T/xai/k: read with op on the Mac (a fake op)")
        let mk = d(["create", "ag-op", "--agent", "grok", "--network", "agent", "--isolated", "--start", "--account", "xop"], timeout: 1500)
        check(mk.code == 0, "a Grok sandbox on the account from 1Password")
        let ok = d(["exec", "ag-op", "--", "grok", "-p", "say ok"], timeout: 240)
        check(ok.out.contains("DOZ_FAKE_OK"), "grok -p works with the key read from op")
        try? Data().write(to: URL(fileURLWithPath: ws + "/op.signedout"))
        _ = d(["account", "refresh", "xop"])
        let no = d(["exec", "ag-op", "--", "sh", "-c", "curl -s -H \"Authorization: Bearer $XAI_API_KEY\" https://api.x.ai/v1/models"], timeout: 120)
        check(no.out.contains("op") && no.out.lowercased().contains("sign"), "op signed out: the proxy's answer names op signin (\(no.out.prefix(160)))")
        check(!requests().suffix(3).contains { (($0["auth"] as? [String: String]) ?? [:]).values.contains { $0.contains("FAKE") && !$0.contains(xaiKey) } },
              "no other key was used instead")
        try? fm.removeItem(atPath: ws + "/op.signedout")
        _ = d(["rm", "ag-op", "--yes"], timeout: 300)
    }
}

/// A command on THIS Mac (no shell for the arguments), its exit code and stdout+stderr.
@discardableResult
private func onMac(_ argv: [String], cwd: String? = nil) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let o = Pipe()
    p.standardOutput = o
    p.standardError = o
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = o.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}
