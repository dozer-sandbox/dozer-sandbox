import Darwin
import Foundation
import DozerHost
import DozerKit

// 599e: the Access step — `doz onboard` confirms each credential live and NEVER blocks; `doz access` shows
// and confirms again; `doz access set` changes a choice. SEAMS ONLY (never the user's gh, ssh-agent or
// GitHub account, never api.github.com):
//   - a FAKE GitHub API on this Mac (python3, TLS with its own CA — the proxy's upstream seam): `/user` with
//     `X-OAuth-Scopes` for a classic token, without for a fine-grained one, `/user/repos`; 401 otherwise;
//   - a FAKE gh (DOZ_TEST_GH) printing a fake token (or nothing: logged out);
//   - a THROWAWAY ssh-agent with a throwaway key (DOZ_TEST_SSH_AUTH_SOCK; SSH_AUTH_SOCK is removed).
// No VM: onboarding with --no-images. Store /tmp/dzo-PID-a, its own XDG config.

// (`__import__`: a line beginning "import" is read by the audit as a Swift import.)
private let fakeGitHubAPI = #"""
json, ssl, sys = (__import__(m) for m in ("json", "ssl", "sys"))
http = __import__("http.server")
certf, keyf, logf, tokenf, portf = sys.argv[1:6]
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
        self.wfile.write(data)
    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        tok = auth.split(" ", 1)[1].strip() if " " in auth else ""
        known = [l.strip() for l in open(tokenf) if l.strip()]
        with open(logf, "a") as f:
            f.write(json.dumps({"path": self.path, "host": self.headers.get("Host", ""), "known": tok in known}) + "\n")
        if tok not in known: return self.send(401, {"message": "Bad credentials"})
        if self.path == "/user":
            extra = {"X-OAuth-Scopes": "repo, read:org"} if tok.startswith("ghp_") else {}
            return self.send(200, {"login": "fake-user", "id": 1}, extra)
        if self.path.startswith("/user/repos"):
            return self.send(200, [{"full_name": "fake-user/one"}, {"full_name": "fake-user/two"}])
        return self.send(404, {"message": "Not Found"})
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certf, keyf)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
open(portf, "w").write(str(srv.server_address[1]))
srv.serve_forever()
"""#

/// A program on this Mac (never the user's agent), its exit code and stdout+stderr.
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

func cliAccessSuite(binary: String) async {
    let t = onboardingHarness(binary, "a", seed: ["kernels", "content", "state.json", "initfs.ext4"])
    t.env["DOZ_TEST_NPM_REGISTRY"] = "offline"
    t.env["SSH_AUTH_SOCK"] = nil                                   // never the user's agent
    let pid = getpid()
    let w = URL(fileURLWithPath: "/tmp/dzo-\(pid)-aw")
    let fm = FileManager.default
    try? fm.removeItem(at: w)
    try? fm.createDirectory(at: w, withIntermediateDirectories: true)
    let ws = w.path
    let classic = "ghp_FAKE599eACCESS\(pid)aBcDeF0123456789"
    let fine = "github_pat_FAKE599eFINE\(pid)xYz9876543210"
    var server: Process?
    var agentPID: pid_t = 0
    defer {
        t.run(["host", "stop"])
        server?.terminate()
        if agentPID > 0 { kill(agentPID, SIGTERM) }
        try? fm.removeItem(at: t.store)
        try? fm.removeItem(at: w)
    }
    print("cli: the Access step — onboarding confirms GitHub and the SSH agent, skips failures, never blocks (599e)")

    // ── The Mac's side (all scratch) ─────────────────────────────────────────────────────────────
    try? (classic + "\n" + fine + "\n").write(toFile: ws + "/tokens", atomically: true, encoding: .utf8)
    func fakeGH(prints token: String?) {
        let body = token.map { "[ \"$1 $2\" = 'auth token' ] && { echo \($0); exit 0; }\n" } ?? "echo 'not logged in' >&2\n"
        try? ("#!/bin/sh\n" + body + "exit 1\n").write(toFile: ws + "/gh", atomically: true, encoding: .utf8)
        chmod(ws + "/gh", 0o755)
    }
    fakeGH(prints: classic)
    try? fakeGitHubAPI.write(toFile: ws + "/api.py", atomically: true, encoding: .utf8)
    try? "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n".write(toFile: ws + "/ca.ext", atomically: true, encoding: .utf8)
    try? "subjectAltName=DNS:github.com,DNS:api.github.com\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n"
        .write(toFile: ws + "/leaf.ext", atomically: true, encoding: .utf8)
    let ssl = "/usr/bin/openssl"
    let m0 = onMac(["/bin/sh", "-c", """
        set -e
        \(ssl) req -new -newkey rsa:2048 -nodes -keyout ca.key -out ca.csr -subj '/CN=Dozer test GitHub CA' 2>&1
        \(ssl) x509 -req -in ca.csr -signkey ca.key -out ca.pem -days 2 -extfile ca.ext 2>&1
        \(ssl) req -new -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj '/CN=api.github.com' 2>&1
        \(ssl) x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out leaf.pem -days 2 -extfile leaf.ext 2>&1
        """], cwd: ws)
    check(m0.code == 0, "a throwaway CA and an api.github.com certificate (\(m0.code))")
    let srv = Process()
    srv.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    srv.arguments = [ws + "/api.py", ws + "/leaf.pem", ws + "/leaf.key", ws + "/requests.log", ws + "/tokens", ws + "/port"]
    var senv = ProcessInfo.processInfo.environment
    senv["HOME"] = ws; senv["SSH_AUTH_SOCK"] = nil
    srv.environment = senv
    srv.standardOutput = FileHandle.nullDevice
    srv.standardError = FileHandle.nullDevice
    do { try srv.run(); server = srv } catch { check(false, "start the fake GitHub API: \(error)") }
    var port = ""
    for _ in 0..<50 where port.isEmpty { usleep(100_000); port = (try? String(contentsOfFile: ws + "/port", encoding: .utf8)) ?? "" }
    check(!port.isEmpty, "the fake GitHub API listens on 127.0.0.1:\(port) (TLS, its own CA)")
    let agentSock = ws + "/agent.sock"
    let a = onMac(["/usr/bin/ssh-agent", "-a", agentSock])
    if let r = a.out.range(of: #"SSH_AGENT_PID=(\d+)"#, options: .regularExpression) {
        agentPID = pid_t(a.out[r].dropFirst("SSH_AGENT_PID=".count).prefix { $0.isNumber }) ?? 0
    }
    onMac(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "doz-access-test@example.invalid", "-f", ws + "/id_test"])
    let added = onMac(["/usr/bin/ssh-add", ws + "/id_test"], env: ["SSH_AUTH_SOCK": agentSock])
    check(added.code == 0 && agentPID > 0, "a throwaway ssh-agent with one throwaway key")

    t.env["DOZ_TEST_GH"] = ws + "/gh"
    t.env["DOZ_TEST_GITHUB_UPSTREAM"] = "127.0.0.1:\(port)"
    t.env["DOZ_TEST_GITHUB_CA"] = ws + "/ca.pem"
    t.env["DOZ_TEST_SSH_AUTH_SOCK"] = agentSock
    func requests() -> String { (try? String(contentsOfFile: ws + "/requests.log", encoding: .utf8)) ?? "" }
    var everything = ""                                          // every output, for the leak check
    @discardableResult
    func run(_ args: [String], stdin: String? = nil, timeout: TimeInterval = 120) -> CLIRun {
        let r = t.run(args, stdin: stdin.map { Data($0.utf8) }, timeout: timeout)
        everything += r.out + r.err
        return r
    }
    func setting(_ key: String) -> String { run(["config", "get", key]).out.trimmingCharacters(in: .whitespacesAndNewlines) }

    // ── 1. Onboarding: GitHub (the Mac's gh) and the SSH agent both CONFIRMED ─────────────────────
    var r = run(["onboard", "--no-images", "--account", "later", "--github", "read", "--ssh-agent", "on", "--yes"], timeout: 180)
    check(r.code == 0, "onboard --yes --github read --ssh-agent on (exit \(r.code)) \(r.code == 0 ? "" : r.err.suffix(300).description)")
    check(r.out.contains("2. Access"), "the onboarding has ONE Access step")
    check(r.out.contains("✓ GitHub as you") && r.out.contains("signed in as fake-user") && r.out.contains("scopes: repo, read:org"),
          "GitHub confirmed live: signed in as fake-user, with the token's scopes")
    check(r.out.contains("this Mac's gh login"), "… said to come from the Mac's gh login")
    check(r.out.contains("✓ SSH agent forwarding") && r.out.contains("the ssh-agent has 1 key") && r.out.contains("doz-access-test@example.invalid"),
          "SSH confirmed: the agent has 1 key (its comment shown)")
    check(r.out.contains("read-only: the agent can read everything your login can"), "a plain-language consequence line for GitHub read")
    check(!r.out.contains("✓ Claude account") && !r.out.contains("✗ Claude account"), "the Claude account was \"decide later\": not checked")
    check(requests().contains("\"path\": \"/user\"") && requests().contains("\"known\": true"),
          "the check was GET /user, through the proxy's upstream leg, with the real (fake) token")
    check(setting("defaults.github") == "read" && setting("sandbox.ssh_agent") == "on" && setting("github.credentials") == "gh",
          "the choices are the defaults for new sandboxes (defaults.github = read, sandbox.ssh_agent = on, github.credentials = gh)")
    r = run(["access", "--no-check", "--json"])
    let items = ((try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])?["items"] as? [[String: Any]]) ?? []
    func state(_ id: String) -> String? { items.first { $0["id"] as? String == id }?["state"] as? String }
    check(state("github") == "confirmed" && state("ssh") == "confirmed" && state("claude") == "unchecked",
          "doz access --no-check: the record says GitHub and SSH confirmed, the Claude account (decided later) unchecked (\(state("github") ?? "?"), \(state("ssh") ?? "?"), \(state("claude") ?? "?"))")

    // ── 2. A failing GitHub is SKIPPED with a note; the onboarding goes on (exit 0) ───────────────
    t.run(["host", "stop"])
    fakeGH(prints: "ghp_REVOKEDbutWELLformed000000000000000")
    r = run(["onboard", "--no-images", "--account", "later", "--github", "push", "--yes"], timeout: 180)
    check(r.code == 0, "onboard --yes --github push with a token GitHub refuses → exit 0 (never blocked)")
    check(r.out.contains("✗ GitHub as you") && r.out.contains("GitHub refused the token (401"), "the reason is said: GitHub refused the token (401)")
    check(r.out.contains("skipped — kept, not confirmed"), "skipped with a note (kept, not confirmed)")
    check(r.out.contains("Done") || r.out.contains("onboarded"), "… and the onboarding finished")
    check(setting("defaults.github") == "push", "the choice is KEPT (push), not confirmed")
    r = run(["access", "--no-check"])
    check(r.out.contains("✗ GitHub as you") && r.out.contains("not confirmed"), "doz access shows it not confirmed")
    t.run(["host", "stop"])
    fakeGH(prints: nil)
    r = run(["access"])
    check(r.code == 0 && r.out.contains("not logged in to github.com"), "gh logged out → the reason (run gh auth login on the Mac), exit 0")

    // ── 3. SSH with NO agent: skipped with the reason ────────────────────────────────────────────
    t.run(["host", "stop"])
    fakeGH(prints: classic)
    t.env["DOZ_TEST_SSH_AUTH_SOCK"] = ws + "/no-agent.sock"
    r = run(["onboard", "--no-images", "--account", "later", "--github", "off", "--ssh-agent", "on", "--yes"], timeout: 180)
    check(r.code == 0, "onboard --yes --ssh-agent on with no agent → exit 0")
    check(r.out.contains("✗ SSH agent forwarding") && r.out.contains("no ssh-agent"), "the reason: this Mac has no ssh-agent to forward")
    check(r.out.contains("skipped — kept, not confirmed"), "skipped with a note")
    check(r.out.contains("— GitHub as you") && setting("defaults.github") == "off", "GitHub turned off on purpose: shown off, nothing to confirm")

    // ── 4. doz access set: a fine-grained token as the default key ───────────────────────────────
    t.run(["host", "stop"])
    t.env["DOZ_TEST_SSH_AUTH_SOCK"] = agentSock
    r = run(["access", "set", "--github", "read", "--github-key"], stdin: fine + "\n")
    check(r.code == 0 && r.out.contains("signed in as fake-user") && r.out.contains("it can see 2 repositories") && r.out.contains("from your key"),
          "access set --github read --github-key (a fine-grained token): signed in as fake-user — it can see 2 repositories")
    check(setting("github.credentials") == "key", "github.credentials = key (a key was given)")
    r = run(["access", "--json"])
    check(r.out.contains("\"githubKeySet\" : true") || r.out.contains("\"githubKeySet\":true"), "the default key is held (githubKeySet)")
    r = run(["access", "set"])
    check(r.code == 64, "access set with nothing to set → usage (64)")
    r = run(["access", "set", "--github", "maybe"])
    check(r.code == 64, "access set --github maybe → usage (64)")
    r = run(["access", "set", "--ssh-agent", "off", "--no-check"])
    check(r.code == 0 && setting("sandbox.ssh_agent") == "off", "access set --ssh-agent off --no-check")

    // ── 5. No secret anywhere ───────────────────────────────────────────────────────────────────
    check(!everything.contains(classic) && !everything.contains(fine), "no token in any output")
    let grep = onMac(["/usr/bin/grep", "-rlF", "-D", "skip", "-e", classic, "-e", fine, t.store.path])
    check(grep.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "no token in any file of the store or its settings (\(grep.out.prefix(200)))")
}
