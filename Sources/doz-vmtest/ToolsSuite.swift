import Darwin
import Foundation
import DozerHost
import DozerKit

// 599h: the TOOLS LAYER in real VMs, through SEAMS only — never github.com, never the user's gh, agent or GitHub:
//   - a LOCAL download server for gh's release tarball (DOZ_TEST_TOOLS_URL): the real pinned tarball from the
//     fixture (`make tools-fixture` puts it in the vmtest store once), or a tampered copy (the checksum refusal);
//   - a fake api.github.com (python3, its own CA, the proxy's upstream seam) answering what gh asks: the scopes,
//     the viewer, a repository and its README;
//   - a fake gh on the Mac (DOZ_TEST_GH), a throwaway ssh-agent; SSH_AUTH_SOCK removed.
// Covers: the first start shows the layer as progress lines; a bad checksum is refused and never fails the boot;
// --apply delivers; gh auth status / gh repo view through the placeholder; the ssh client and github.com's host
// keys; off then on across a hibernate + wake (quiet); the lab (Alpine, packages missing), Debian and Alpine
// bases; the image recipe hashes unchanged. Store /tmp/dzo-PID-t.

// (`__import__`: a line beginning "import" is read by the audit as a Swift import.)
private let fakeGitHubForGh = #"""
json, ssl, sys, base64 = (__import__(m) for m in ("json", "ssl", "sys", "base64"))
http = __import__("http.server")
certf, keyf, logf, tokenf, portf = sys.argv[1:6]
REPO = {"id": "R_1", "name": "r", "nameWithOwner": "o/r", "owner": {"id": "U_1", "login": "o"}, "description": "a fake repository",
        "url": "https://github.com/o/r", "homepageUrl": "", "isPrivate": True, "isArchived": False, "isFork": False, "isTemplate": False,
        "visibility": "PRIVATE", "defaultBranchRef": {"name": "main"}, "viewerPermission": "READ", "stargazerCount": 0, "forkCount": 0,
        "watchers": {"totalCount": 0}, "issues": {"totalCount": 0}, "pullRequests": {"totalCount": 0}, "repositoryTopics": {"nodes": []},
        "primaryLanguage": None, "languages": {"nodes": []}, "parent": None, "createdAt": "2026-01-01T00:00:00Z", "pushedAt": "2026-01-01T00:00:00Z",
        "updatedAt": "2026-01-01T00:00:00Z", "hasIssuesEnabled": True, "hasWikiEnabled": False, "licenseInfo": None}
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def send(self, code, obj, extra=None):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(data)
    def any(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode(errors="replace") if n else ""
        auth = self.headers.get("Authorization", "")
        tok = auth.split(" ", 1)[1].strip() if " " in auth else ""
        known = tok in [l.strip() for l in open(tokenf) if l.strip()]
        with open(logf, "a") as f: f.write(json.dumps({"m": self.command, "path": self.path, "known": known, "placeholder": "doz_cred_" in auth}) + "\n")
        if not known: return self.send(401, {"message": "Bad credentials"})
        scopes = {"X-OAuth-Scopes": "repo, read:org, gist"}
        if self.path.startswith("/graphql"):
            if "repository(" in body: return self.send(200, {"data": {"repository": REPO}}, scopes)
            return self.send(200, {"data": {"viewer": {"login": "fake-user"}}}, scopes)
        if self.path.startswith("/repos/o/r/readme"):
            return self.send(200, {"name": "README.md", "path": "README.md", "encoding": "base64",
                                   "content": base64.b64encode(b"hello from the fake GitHub\n").decode()}, scopes)
        if self.path.startswith("/repos/o/r"): return self.send(200, {"full_name": "o/r", "name": "r", "owner": {"login": "o"}, "private": True}, scopes)
        return self.send(200, {"login": "fake-user", "current_user_url": "https://api.github.com/user"}, scopes)
    do_GET = do_POST = do_HEAD = any
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certf, keyf)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
open(portf, "w").write(str(srv.server_address[1]))
srv.serve_forever()
"""#

/// A plain http file server for one directory (the gh tarball), its port written to a file.
private let downloadServer = #"""
sys, functools = (__import__(m) for m in ("sys", "functools"))
http = __import__("http.server")
root, logf, portf = sys.argv[1:4]
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *a):
        with open(logf, "a") as f: f.write(self.path + "\n")
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(H, directory=root))
open(portf, "w").write(str(srv.server_address[1]))
srv.serve_forever()
"""#

@discardableResult
private func onMac(_ argv: [String], env: [String: String] = [:], cwd: String? = nil) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    var e = ProcessInfo.processInfo.environment
    e["SSH_AUTH_SOCK"] = nil
    for (k, v) in env { e[k] = v }
    p.environment = e
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

private func startPython(_ script: String, _ args: [String], ws: String) -> Process? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = [script] + args
    var e = ProcessInfo.processInfo.environment
    e["HOME"] = ws; e["SSH_AUTH_SOCK"] = nil
    p.environment = e
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run(); return p } catch { return nil }
}

private func waitPort(_ file: String) -> String {
    var port = ""
    for _ in 0..<50 where port.isEmpty { usleep(100_000); port = (try? String(contentsOfFile: file, encoding: .utf8)) ?? "" }
    return port
}

/// Where `make tools-fixture` keeps the real pinned gh tarball (downloaded once, outside every test).
func toolsFixture() -> String { NSTemporaryDirectory() + "doz-vmtest-store/fixtures/" + ToolsLayer.ghTarball }

func cliToolsSuite(binary: String) async {
    print("cli: the tools layer — gh, the ssh client + github.com host keys, packages; every base, no rebuild (599h)")
    let fixture = toolsFixture()
    guard let tarball = FileManager.default.contents(atPath: fixture), ToolsCache.sha256(tarball) == ToolsLayer.ghSHA256 else {
        check(false, "the gh fixture \(fixture) is missing or not the pinned one — run `make tools-fixture` once (it downloads the release; tests never do)")
        return
    }
    let t = onboardingHarness(binary, "t", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    t.env["DOZ_TEST_NPM_REGISTRY"] = "offline"
    t.env["SSH_AUTH_SOCK"] = nil
    let pid = getpid()
    let w = URL(fileURLWithPath: "/tmp/dzo-\(pid)-tw")
    let fm = FileManager.default
    try? fm.removeItem(at: w)
    try? fm.createDirectory(at: w.appendingPathComponent("dl"), withIntermediateDirectories: true)
    let ws = w.path
    let token = "ghp_FAKE599hTOOLS\(pid)aBcDeF0123456789"
    var servers: [Process] = []
    var agentPID: pid_t = 0
    defer {
        t.run(["host", "stop"])
        for s in servers { s.terminate() }
        if agentPID > 0 { kill(agentPID, SIGTERM) }
        try? fm.removeItem(at: t.store)
        try? fm.removeItem(at: w)
    }

    // ── The seams ────────────────────────────────────────────────────────────────────────────────
    try? (token + "\n").write(toFile: ws + "/tokens", atomically: true, encoding: .utf8)
    try? "#!/bin/sh\n[ \"$1 $2\" = 'auth token' ] && { echo \(token); exit 0; }\nexit 1\n".write(toFile: ws + "/gh", atomically: true, encoding: .utf8)
    chmod(ws + "/gh", 0o755)
    try? fakeGitHubForGh.write(toFile: ws + "/api.py", atomically: true, encoding: .utf8)
    try? downloadServer.write(toFile: ws + "/dl.py", atomically: true, encoding: .utf8)
    try? "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n".write(toFile: ws + "/ca.ext", atomically: true, encoding: .utf8)
    try? "subjectAltName=DNS:github.com,DNS:api.github.com,DNS:uploads.github.com,DNS:codeload.github.com\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n"
        .write(toFile: ws + "/leaf.ext", atomically: true, encoding: .utf8)
    let m0 = onMac(["/bin/sh", "-c", """
        set -e
        /usr/bin/openssl req -new -newkey rsa:2048 -nodes -keyout ca.key -out ca.csr -subj '/CN=Dozer test GitHub CA' 2>&1
        /usr/bin/openssl x509 -req -in ca.csr -signkey ca.key -out ca.pem -days 2 -extfile ca.ext 2>&1
        /usr/bin/openssl req -new -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj '/CN=api.github.com' 2>&1
        /usr/bin/openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out leaf.pem -days 2 -extfile leaf.ext 2>&1
        """], cwd: ws)
    check(m0.code == 0, "a throwaway CA and a github.com certificate for the fake GitHub")
    if let s = startPython(ws + "/api.py", [ws + "/leaf.pem", ws + "/leaf.key", ws + "/requests.log", ws + "/tokens", ws + "/api.port"], ws: ws) { servers.append(s) }
    if let s = startPython(ws + "/dl.py", [ws + "/dl", ws + "/downloads.log", ws + "/dl.port"], ws: ws) { servers.append(s) }
    let apiPort = waitPort(ws + "/api.port"), dlPort = waitPort(ws + "/dl.port")
    check(!apiPort.isEmpty && !dlPort.isEmpty, "the fake GitHub (:\(apiPort), TLS) and the local download server (:\(dlPort))")
    // First: a TAMPERED tarball at the pinned name — the checksum must refuse it.
    var bad = tarball
    bad.append(contentsOf: [0x0a])
    try? bad.write(to: w.appendingPathComponent("dl/" + ToolsLayer.ghTarball))
    let agentSock = ws + "/agent.sock"
    let a = onMac(["/usr/bin/ssh-agent", "-a", agentSock])
    if let r = a.out.range(of: #"SSH_AGENT_PID=(\d+)"#, options: .regularExpression) {
        agentPID = pid_t(a.out[r].dropFirst("SSH_AGENT_PID=".count).prefix { $0.isNumber }) ?? 0
    }
    onMac(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "doz-tools-test@example.invalid", "-f", ws + "/id_test"])
    onMac(["/usr/bin/ssh-add", ws + "/id_test"], env: ["SSH_AUTH_SOCK": agentSock])
    check(agentPID > 0, "a throwaway ssh-agent")
    t.env["DOZ_TEST_GH"] = ws + "/gh"
    t.env["DOZ_TEST_GITHUB_UPSTREAM"] = "127.0.0.1:\(apiPort)"
    t.env["DOZ_TEST_GITHUB_CA"] = ws + "/ca.pem"
    t.env["DOZ_TEST_TOOLS_URL"] = "http://127.0.0.1:\(dlPort)"
    t.env["DOZ_TEST_SSH_AUTH_SOCK"] = agentSock
    t.env["GIT_CONFIG_GLOBAL"] = ws + "/no-gitconfig"
    func requests() -> String { (try? String(contentsOfFile: ws + "/requests.log", encoding: .utf8)) ?? "" }

    check(t.run(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    check(t.run(["config", "set", "defaults.projects_dir", "/tmp/dzo-\(pid)-tp"]).code == 0, "defaults.projects_dir is a scratch path")

    // ── 1. The lab (Alpine, no git/curl/ssh): the first start shows the layer; a bad checksum is refused ──
    var r = t.run(["create", "t1", "--image", "lab", "--network", "agent", "--github", "read", "--ssh-agent", "on", "--isolated", "--memory", "1G"], timeout: 120)
    check(r.code == 0, "create t1 --image lab --network agent --github read --ssh-agent on (exit \(r.code)) \(r.code == 0 ? "" : r.err.suffix(300).description)")
    r = t.run(["start", "t1", "--verbose"], timeout: 900)
    let startOut = r.out + r.err
    check(r.code == 0, "start t1 — the boot never fails for the layer (exit \(r.code)) \(r.code == 0 ? "" : startOut.suffix(400).description)")
    check(startOut.contains("tools: installing") && startOut.contains("with apk, through the proxy"),
          "the first start: the missing packages installed with apk, through the proxy (a progress line) (\(startOut.components(separatedBy: "\n").filter { $0.contains("tools:") }.joined(separator: " | ").prefix(600)))")
    check(startOut.contains("tools: git — always") && startOut.contains("tools: ssh client — for SSH agent forwarding"), "…each tool a progress line with its reason")
    check(!startOut.contains("lab: tools:"), "the image's preparation VM gets NO tools layer (the baked image never carries it)")
    check(startOut.contains("refused the gh download: its sha256 is"), "a tampered gh tarball is REFUSED by its checksum (said)")
    check(startOut.contains("tools: gh \(ToolsLayer.ghVersion) — for GitHub as you"), "…and gh shown as not set up")
    check(!fm.fileExists(atPath: t.store.appendingPathComponent("tools/gh/\(ToolsLayer.ghVersion)/gh").path), "nothing of the tampered download is kept on the Mac")
    r = t.run(["exec", "t1", "--", "sh", "-c", "for c in git curl ssh; do command -v $c; done; [ -e \(ToolsLayer.guestGhPath) ] && echo HAS-GH || echo NO-GH"])
    check(r.out.contains("/git") && r.out.contains("/curl") && r.out.contains("/ssh") && r.out.contains("NO-GH"), "in the guest: git, curl and ssh installed; no gh (\(r.out.debugDescription))")
    r = t.run(["exec", "t1", "--", "sh", "-c", "grep -c '^github.com ' \(ToolsLayer.knownHostsPath); grep -c '^github.com ' \(ToolsLayer.knownHostsPath) | true"])
    check(r.out.hasPrefix("3"), "github.com's three published host keys in \(ToolsLayer.knownHostsPath)")
    r = t.run(["exec", "t1", "--", "cat", ToolsLayer.knownHostsPath])
    check(ToolsLayer.githubHostKeys.allSatisfy(r.out.contains), "…exactly the pinned ones")
    r = t.run(["exec", "t1", "--", "sh", "-c", "ssh -G github.com | grep -i '^globalknownhostsfile'"])
    check(r.out.contains(ToolsLayer.knownHostsPath), "ssh reads that file (no prompt for github.com)")

    // The good tarball; --apply delivers (a Retry).
    try? tarball.write(to: w.appendingPathComponent("dl/" + ToolsLayer.ghTarball))
    r = t.run(["tools", "t1", "--apply", "--verbose"], timeout: 300)
    check(r.code == 0 && (r.out + r.err).contains("tools: gh \(ToolsLayer.ghVersion) — for GitHub as you"), "tools t1 --apply: gh set up (progress lines) (exit \(r.code))")
    check(fm.isExecutableFile(atPath: t.store.appendingPathComponent("tools/gh/\(ToolsLayer.ghVersion)/gh").path), "gh is cached ONCE on the Mac, in the store's tools/")
    r = t.run(["tools", "t1"])
    check(r.out.contains("✓ gh \(ToolsLayer.ghVersion)") && r.out.contains("for GitHub as you") && r.out.contains("On this Mac: gh \(ToolsLayer.ghVersion)"), "doz tools t1: each tool, why, its state; the Mac's cache (\(r.out.prefix(300)))")
    r = t.run(["exec", "t1", "--", "sh", "-c", "gh --version | head -1"])
    check(r.out.contains("gh version \(ToolsLayer.ghVersion)"), "gh \(ToolsLayer.ghVersion) runs in the lab (musl) (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    r = t.run(["exec", "t1", "--", "sh", "-c", "gh auth status 2>&1"], timeout: 60)
    check(r.out.contains("fake-user") && r.out.contains("GH_TOKEN"), "gh auth status: signed in as fake-user (GH_TOKEN — the placeholder) (\(r.out.prefix(300).debugDescription))")
    r = t.run(["exec", "t1", "--", "sh", "-c", "gh repo view o/r 2>&1"], timeout: 60)
    check(r.out.contains("o/r") && r.out.contains("hello from the fake GitHub"), "gh repo view o/r works (\(r.out.prefix(300).debugDescription))")
    check(requests().contains("\"known\": true") && !requests().contains("\"placeholder\": true"), "the fake GitHub saw the REAL token, never the placeholder")

    // ── 2. Off, then on — across a hibernate + wake (quiet) ──
    check(t.run(["hibernate", "t1"], timeout: 120).code == 0, "hibernate t1")
    check(t.run(["net", "deny", "t1", "github:as-you"]).code == 0, "GitHub as you OFF while it sleeps")
    r = t.run(["wake", "t1", "--verbose"], timeout: 120)
    check(r.code == 0 && !(r.out + r.err).contains("tools: gh"), "wake t1: the layer re-checked QUIETLY (no tools step lines)")
    r = t.run(["exec", "t1", "--", "sh", "-c", "[ -e \(ToolsLayer.guestGhPath) ] && echo HAS-GH || echo NO-GH"])
    check(r.out.contains("NO-GH"), "…and Dozer's gh is REMOVED (its setting is off)")
    check(hostLog(t).contains("tools layer re-checked"), "the host log notes the quiet re-check")
    check(t.run(["hibernate", "t1"], timeout: 120).code == 0, "hibernate t1 again")
    check(t.run(["net", "allow", "t1", "github:as-you", "--yes"]).code == 0, "GitHub as you ON while it sleeps")
    check(t.run(["wake", "t1"], timeout: 120).code == 0, "wake t1")
    r = t.run(["exec", "t1", "--", "sh", "-c", "gh --version | head -1"])
    check(r.out.contains(ToolsLayer.ghVersion), "gh is back after the wake (from the Mac's cache)")
    check(t.run(["config", "set", "--sandbox", "t1", "sandbox.ssh_agent", "off"]).code == 0, "SSH agent forwarding off (live)")
    var gone = false
    for _ in 0..<40 where !gone {
        usleep(250_000)
        gone = !t.run(["exec", "t1", "--", "cat", ToolsLayer.knownHostsPath]).out.contains("doz:github-known-hosts")
    }
    check(gone, "…github.com's host-key block is removed from the guest")
    t.run(["rm", "t1", "--yes"], timeout: 120)

    // `doz up` and `create --start` show the same progress lines (the start's step events).
    r = t.run(["up", "t-up", "--image", "lab", "--isolated", "--memory", "512M", "--detach", "--verbose"], timeout: 600)
    check(r.code == 0 && (r.out + r.err).contains("tools: git — always"), "doz up: the tools layer's progress lines (exit \(r.code))")
    r = t.run(["create", "t-cs", "--image", "lab", "--isolated", "--memory", "512M", "--start", "--verbose"], timeout: 600)
    check(r.code == 0 && (r.out + r.err).contains("tools: curl — always"), "doz create --start: the same lines (exit \(r.code))")
    for n in ["t-up", "t-cs"] { t.run(["rm", n, "--yes"], timeout: 120) }

    // ── 3. Debian and Alpine catalogue bases (prepared here: every base, no rebuild for the tools) ──
    for base in ["debian", "alpine"] {
        let n = "t-\(base)"
        r = t.run(["create", n, "--image", base, "--network", "agent", "--github", "read", "--ssh-agent", "on", "--isolated", "--memory", "1G"], timeout: 120)
        check(r.code == 0, "create \(n) --image \(base) (exit \(r.code)) \(r.code == 0 ? "" : r.err.suffix(200).description)")
        r = t.run(["start", n, "--verbose"], timeout: 1800)
        check(r.code == 0 && (r.out + r.err).contains("tools: gh \(ToolsLayer.ghVersion) — for GitHub as you"), "start \(n): gh set up as a step (exit \(r.code))")
        check(!(r.out + r.err).contains("refused the gh download"), "…from the Mac's cache (no download)")
        r = t.run(["exec", n, "--", "sh", "-c", "gh auth status 2>&1; for c in ssh git curl; do command -v $c; done; grep -c '^github.com ' \(ToolsLayer.knownHostsPath)"], timeout: 60)
        check(r.out.contains("fake-user") && r.out.contains("/ssh") && r.out.contains("/git") && r.out.contains("\n3"), "\(base): gh signed in, ssh, git, curl, the host keys (\(r.out.suffix(200).debugDescription))")
        t.run(["rm", n, "--yes"], timeout: 120)
    }
    // The recipes: the bake keys are pinned by ToolsLayerTests (unchanged since rc.1); here, no image is stale.
    r = t.run(["image", "ls"])
    check(r.code == 0 && !r.out.contains("older recipe"), "no image says \"older recipe\" (the layer changes no recipe)")
}
