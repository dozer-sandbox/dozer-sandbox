import Darwin
import Foundation
import DozerHost
import DozerKit

// 599d (owner: "how do we optionally give the agent in the vm git credentials (ie. the same that are on the
// local machine) so it can operate the same way an agent would on the host. Another proxy credential
// insertion ?"): "Use GitHub as you" in a real VM, through SEAMS ONLY — never the user's gh login, ssh-agent,
// git identity or GitHub account, never github.com:
//   - a FAKE GitHub on this Mac: python3 serving `git http-backend` (a bare repo o/r.git) and a few API
//     routes over TLS with its own CA; the proxy's GitHub upstream leg goes there (DOZ_TEST_GITHUB_UPSTREAM)
//     and trusts ONLY that CA (DOZ_TEST_GITHUB_CA); it logs every request's Authorization (decoded);
//   - a FAKE gh (DOZ_TEST_GH) that prints a fake token; a scratch GIT_CONFIG_GLOBAL for the identity;
//   - a THROWAWAY ssh-agent with a throwaway key (DOZ_TEST_SSH_AUTH_SOCK, and SSH_AUTH_SOCK = it).
// A claude-code sandbox (git, curl, ssh in the image; proxied), store /tmp/dzo-PID-g.

// (`__import__`: a line beginning "import" is read by the audit as a Swift import.)
private let fakeGitHubServer = #"""
base64, json, os, ssl, subprocess, sys = (__import__(m) for m in ("base64", "json", "os", "ssl", "subprocess", "sys"))
http = __import__("http.server")
root, certf, keyf, logf, tokenf, portf = sys.argv[1:7]
def tokens():
    return [l.strip() for l in open(tokenf) if l.strip()]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def send(self, code, data, ctype="application/json", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(data)
    def any(self):
        auth = self.headers.get("Authorization", "")
        dec = ""
        if auth.lower().startswith("basic "):
            try: dec = base64.b64decode(auth[6:].strip()).decode()
            except Exception: dec = "?"
        host = self.headers.get("Host", "").split(":")[0]
        n = int(self.headers.get("Content-Length") or 0)
        data = self.rfile.read(n) if n else b""
        with open(logf, "a") as f:
            f.write(json.dumps({"m": self.command, "host": host, "path": self.path, "auth": auth, "basic": dec}) + "\n")
        ok = any(t in auth or t in dec for t in tokens())
        if host == "api.github.com":
            if not ok: return self.send(401, b'{"message":"Bad credentials"}')
            if self.path.startswith("/graphql"):
                return self.send(200, json.dumps({"data": {"viewer": {"login": "fake-user"}}}).encode())
            if self.command in ("GET", "HEAD"):
                return self.send(200, json.dumps({"login": "fake-user", "path": self.path}).encode())
            return self.send(201, json.dumps({"created": self.path, "by": "fake-user"}).encode())
        if not ok:
            return self.send(401, b"authentication required\n", "text/plain", {"WWW-Authenticate": 'Basic realm="GitHub"'})
        path, _, query = self.path.partition("?")
        env = dict(os.environ, GIT_PROJECT_ROOT=root, GIT_HTTP_EXPORT_ALL="1", PATH_INFO=path, QUERY_STRING=query,
                   REQUEST_METHOD=self.command, CONTENT_TYPE=self.headers.get("Content-Type", ""), CONTENT_LENGTH=str(len(data)),
                   REMOTE_USER="fake-user", REMOTE_ADDR="127.0.0.1", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
        if self.headers.get("Content-Encoding"): env["HTTP_CONTENT_ENCODING"] = self.headers["Content-Encoding"]
        if self.headers.get("Git-Protocol"): env["GIT_PROTOCOL"] = self.headers["Git-Protocol"]
        p = subprocess.run(["/usr/bin/git", "http-backend"], input=data, env=env, capture_output=True)
        out = p.stdout
        sep = out.find(b"\r\n\r\n"); skip = 4
        if sep < 0: sep = out.find(b"\n\n"); skip = 2
        head, body = (out[:sep], out[sep + skip:]) if sep >= 0 else (b"", out)
        status, hdrs = 200, {}
        for line in head.decode(errors="replace").splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                if k.strip().lower() == "status": status = int(v.split()[0])
                elif k.strip().lower() not in ("content-length", "content-type"): hdrs[k.strip()] = v.strip()
                elif k.strip().lower() == "content-type": hdrs["__ct"] = v.strip()
        ct = hdrs.pop("__ct", "application/octet-stream")
        self.send(status, body, ct, hdrs)
    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = any
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certf, keyf)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
open(portf, "w").write(str(srv.server_address[1]))
srv.serve_forever()
"""#

/// A command on THIS Mac (no shell for the arguments; `sh -c` when asked), its exit code and stdout+stderr.
@discardableResult
private func mac(_ argv: [String], env: [String: String] = [:], stdin: String? = nil, cwd: String? = nil) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    var e = ProcessInfo.processInfo.environment
    // Never the user's own git config, agent or gh in anything this suite runs on the Mac.
    e["GIT_CONFIG_NOSYSTEM"] = "1"
    e["SSH_AUTH_SOCK"] = nil
    for (k, v) in env { e[k] = v }
    p.environment = e
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let o = Pipe()
    p.standardOutput = o
    p.standardError = o
    let i = Pipe()
    p.standardInput = stdin == nil ? FileHandle.nullDevice : i
    do { try p.run() } catch { return (-1, "\(error)") }
    if let stdin { i.fileHandleForWriting.write(Data(stdin.utf8)); try? i.fileHandleForWriting.close() }
    let data = o.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func cliGitHubSuite(binary: String) async {
    let t = onboardingHarness(binary, "g", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    t.env["DOZ_TEST_NPM_REGISTRY"] = "offline"
    let pid = getpid()
    let w = URL(fileURLWithPath: "/tmp/dzo-\(pid)-gw")            // the fake GitHub, the fake gh, the throwaway agent
    let fm = FileManager.default
    try? fm.removeItem(at: w)
    try? fm.createDirectory(at: w, withIntermediateDirectories: true)
    let token = "ghp_FAKE599dSEAM\(pid)aBcDeF0123456789"           // the "real" token — fake, and never in the guest
    let token2 = "github_pat_FAKE599dKEY\(pid)xYz9876543210"
    let gitEnv = ["GIT_CONFIG_GLOBAL": w.appendingPathComponent("mac-gitconfig").path, "HOME": w.path]
    var server: Process?
    var agentPID: pid_t = 0
    defer {
        t.run(["host", "stop"])
        server?.terminate()
        if agentPID > 0 { kill(agentPID, SIGTERM) }
        try? fm.removeItem(at: t.store)
        try? fm.removeItem(at: w)
    }
    print("cli: GitHub as the user — proxy insertion, read-only, push, identity, SSH agent (599d)")

    // ── The Mac's side (all scratch) ──────────────────────────────────────────────────────────────
    let ws = w.path
    try? "[user]\n\tname = Test Person\n\temail = test@example.invalid\n".write(toFile: ws + "/mac-gitconfig", atomically: true, encoding: .utf8)
    try? (token + "\n").write(toFile: ws + "/tokens", atomically: true, encoding: .utf8)
    try? "#!/bin/sh\n[ \"$1 $2\" = 'auth token' ] && { echo \(token); exit 0; }\nexit 1\n".write(toFile: ws + "/gh", atomically: true, encoding: .utf8)
    chmod(ws + "/gh", 0o755)
    try? fakeGitHubServer.write(toFile: ws + "/server.py", atomically: true, encoding: .utf8)
    try? "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n".write(toFile: ws + "/ca.ext", atomically: true, encoding: .utf8)
    try? "subjectAltName=DNS:github.com,DNS:api.github.com,DNS:uploads.github.com,DNS:codeload.github.com\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n"
        .write(toFile: ws + "/leaf.ext", atomically: true, encoding: .utf8)
    let ssl = "/usr/bin/openssl"
    var m0 = mac(["/bin/sh", "-c", """
        set -e
        \(ssl) req -new -newkey rsa:2048 -nodes -keyout ca.key -out ca.csr -subj '/CN=Dozer test GitHub CA' 2>&1
        \(ssl) x509 -req -in ca.csr -signkey ca.key -out ca.pem -days 2 -extfile ca.ext 2>&1
        \(ssl) req -new -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj '/CN=github.com' 2>&1
        \(ssl) x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out leaf.pem -days 2 -extfile leaf.ext 2>&1
        """], cwd: ws)
    check(m0.code == 0, "a throwaway CA and a github.com certificate for the fake GitHub (\(m0.code)) \(m0.code == 0 ? "" : m0.out.suffix(300).description)")
    m0 = mac(["/bin/sh", "-c", """
        set -e
        mkdir -p repos/o && git init -q --bare -b main repos/o/r.git
        git init -q -b main seed && cd seed && echo 'hello from the fake GitHub' > README.md && git add README.md
        git -c user.name=Seed -c user.email=seed@example.invalid commit -q -m seed && git push -q ../repos/o/r.git main
        """], env: gitEnv, cwd: ws)
    check(m0.code == 0, "a bare repository o/r.git with one commit (\(m0.out.suffix(200)))")
    let srv = Process()
    srv.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    srv.arguments = [ws + "/server.py", ws + "/repos", ws + "/leaf.pem", ws + "/leaf.key", ws + "/requests.log", ws + "/tokens", ws + "/port"]
    var senv = ProcessInfo.processInfo.environment
    senv["HOME"] = ws; senv["SSH_AUTH_SOCK"] = nil
    srv.environment = senv
    srv.standardOutput = FileHandle.nullDevice
    srv.standardError = FileHandle(forWritingAtPath: "/dev/null")
    do { try srv.run(); server = srv } catch { check(false, "start the fake GitHub: \(error)") }
    var port = ""
    for _ in 0..<50 where port.isEmpty { usleep(100_000); port = (try? String(contentsOfFile: ws + "/port", encoding: .utf8)) ?? "" }
    check(!port.isEmpty, "the fake GitHub listens on 127.0.0.1:\(port) (TLS, its own CA)")
    func requests() -> String { (try? String(contentsOfFile: ws + "/requests.log", encoding: .utf8)) ?? "" }
    // The throwaway ssh-agent and key.
    let agentSock = ws + "/agent.sock"
    m0 = mac(["/usr/bin/ssh-agent", "-a", agentSock])
    if let m = m0.out.range(of: #"SSH_AGENT_PID=(\d+)"#, options: .regularExpression) {
        agentPID = pid_t(m0.out[m].dropFirst("SSH_AGENT_PID=".count).prefix { $0.isNumber }) ?? 0
    }
    m0 = mac(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "doz-test@example.invalid", "-f", ws + "/id_test"])
    m0 = mac(["/usr/bin/ssh-add", ws + "/id_test"], env: ["SSH_AUTH_SOCK": agentSock])
    check(m0.code == 0 && agentPID > 0, "a throwaway ssh-agent with a throwaway key (\(m0.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    let fp = mac(["/usr/bin/ssh-keygen", "-lf", ws + "/id_test.pub"]).out.split(separator: " ").dropFirst().first.map(String.init) ?? "?"
    let pub = (try? String(contentsOfFile: ws + "/id_test.pub", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    // The host sees only the seams (set before it starts).
    t.env["DOZ_TEST_GH"] = ws + "/gh"
    t.env["DOZ_TEST_GITHUB_UPSTREAM"] = "127.0.0.1:\(port)"
    t.env["DOZ_TEST_GITHUB_CA"] = ws + "/ca.pem"
    t.env["GIT_CONFIG_GLOBAL"] = ws + "/mac-gitconfig"
    t.env["DOZ_TEST_SSH_AUTH_SOCK"] = agentSock
    t.env["SSH_AUTH_SOCK"] = agentSock

    check(t.run(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    check(t.run(["config", "set", "images.claude_code_version", AgentImages.claudeCodePinned.version]).code == 0, "the pinned Claude Code (no registry)")
    check(t.run(["config", "set", "defaults.projects_dir", "/tmp/dzo-\(pid)-gp"]).code == 0, "defaults.projects_dir is a scratch path")
    var r = t.run(["up", "gh1", "--image", "claude-code", "--isolated", "--account", "none", "--memory", "1G", "--github", "read", "--detach"], timeout: 1800)
    check(r.code == 0, "up gh1 --image claude-code --github read (exit \(r.code)) \(r.code == 0 ? "" : r.err.suffix(300).description)")
    r = t.run(["net", "permissions"])
    check(r.out.contains("github:as-you") && r.out.contains("github:push"), "doz net permissions lists both")
    r = t.run(["net", "gh1", "--json"])
    let perms = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])?["permissions"] as? [[String: Any]] ?? []
    func on(_ id: String) -> Bool? { perms.first { $0["id"] as? String == id }?["on"] as? Bool }
    check(on("github:as-you") == true && on("github:push") == false, "--github read: \"Use GitHub as you\" on, \"Push to GitHub\" off")

    // 1. The placeholder, the helper, the identity — and the notice on first use, in an attached terminal.
    r = t.run(["exec", "gh1", "--", "sh", "-c", "printf '%s|%s' \"$GH_TOKEN\" \"$GITHUB_TOKEN\""])
    let phs = r.out.split(separator: "|").map(String.init)
    check(phs.count == 2 && phs[0].hasPrefix("doz_cred_") && phs[0] == phs[1], "GH_TOKEN = GITHUB_TOKEN = a doz placeholder (\(r.out.prefix(24))…)")
    let ph1 = phs.first ?? ""
    r = t.run(["exec", "gh1", "--", "sh", "-c", "git config --get user.name; git config --get user.email; git config --get-all credential.https://github.com.helper"])
    check(r.out.contains("Test Person\ntest@example.invalid\n/usr/local/lib/doz/bin/git-credential-doz"), "the Mac's identity and Dozer's helper, in the system git config (\(r.out.debugDescription))")
    do {
        let c = try PTYClient(t, ["run", "gh1", "--session", "g", "--", "bash", "--norc", "-i"])
        defer { c.close() }
        check(c.wait(30) { $0.text.contains("$") }, "run gh1 -- bash: a prompt")
        c.type("cd /tmp && git clone -q https://github.com/o/r.git r1 && cat r1/README.md && echo CLONED-$((1+1))\r")
        check(c.wait(60) { $0.text.contains("CLONED-2") }, "git clone https://github.com/o/r.git — through the user's login (\(c.text.suffix(300).debugDescription))")
        check(c.text.contains("hello from the fake GitHub"), "the repository's file is there")
        check(c.wait(10) { $0.text.contains("doz: gh1 used your GitHub login (read-only)") }, "the notice on first use: \"gh1 used your GitHub login (read-only)\"")
    } catch { check(false, "pty: \(error)") }
    check(requests().contains("\"basic\": \"x-access-token:\(token)\""), "GitHub got git's Basic login with the REAL token, swapped in by the proxy")
    check(!requests().contains("doz_cred_"), "GitHub never saw a placeholder")
    check(hostLog(t).contains("gh1 used your GitHub login (read-only)"), "…and the host log says so")

    // 2. gh-style API calls: reads work, changes are refused (read-only).
    func api(_ method: String, _ path: String, _ body: String? = nil, auth: String = "token $GH_TOKEN") -> String {
        let data = body.map { " -H 'Content-Type: application/json' --data '\($0)'" } ?? ""
        return t.run(["exec", "gh1", "--", "sh", "-c", "curl -sS --max-time 20 -X \(method) -H \"Authorization: \(auth)\"\(data) -w ' HTTP=%{http_code}' https://api.github.com\(path) 2>&1"], timeout: 60).out
    }
    var out = api("GET", "/user")
    check(out.contains("fake-user") && out.contains("HTTP=200"), "GET api.github.com/user with GH_TOKEN (gh's way) → the user (\(out.suffix(80)))")
    out = api("POST", "/graphql", #"{"query":"query { viewer { login } }"}"#, auth: "bearer $GH_TOKEN")
    check(out.contains("fake-user") && out.contains("HTTP=200"), "a GraphQL QUERY is read-only: allowed (\(out.suffix(80)))")
    out = api("POST", "/graphql", #"{"query":"mutation { addStar(input: {starrableId: \"x\"}) { clientMutationId } }"}"#, auth: "bearer $GH_TOKEN")
    check(out.contains("HTTP=403") && out.contains("GraphQL mutation refused"), "a GraphQL MUTATION is refused, saying why (\(out.suffix(160)))")
    out = api("POST", "/repos/o/r/issues", #"{"title":"from the sandbox"}"#)
    check(out.contains("HTTP=403") && out.contains("Push to GitHub") && out.contains("doz net allow gh1 github:push"), "POST /repos/o/r/issues is refused with how to allow it (\(out.suffix(160)))")
    out = api("DELETE", "/repos/o/r")
    check(out.contains("HTTP=403"), "DELETE is refused")
    check(!requests().contains("\"m\": \"POST\", \"host\": \"api.github.com\", \"path\": \"/repos/o/r/issues\"") && !requests().contains("\"m\": \"DELETE\""),
          "none of the refused requests reached GitHub")

    // 3. git push is refused while read-only.
    r = t.run(["exec", "gh1", "--", "sh", "-c", "cd /tmp/r1 && echo one > one.txt && git add one.txt && git commit -q -m 'from the sandbox' && git push origin HEAD:main 2>&1; echo \"EXIT=$?\""], timeout: 120)
    check(!r.out.contains("EXIT=0"), "git push fails while read-only (\(r.out.suffix(300).debugDescription))")
    check(r.out.contains("pushing to GitHub is off for gh1"), "…and git shows Dozer's reason (remote: …)")
    check(!requests().contains("\"path\": \"/o/r.git/git-receive-pack\""), "no push reached GitHub")
    r = t.run(["exec", "gh1", "--", "git", "-C", "/tmp/r1", "log", "-1", "--format=%an <%ae>"])
    check(r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "Test Person <test@example.invalid>", "a new commit carries the Mac's identity (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")

    // 4. The real token is nowhere in the guest.
    // Nothing of the token goes into the guest for this check (it would find itself): the guest prints everything
    // SHAPED like a GitHub token — files, every process's environment and command line — and the Mac looks.
    let re = "(gh[opusr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"
    r = t.run(["exec", "gh1", "--", "sudo", "-n", "sh", "-c",
               "grep -rIhoE '\(re)' /etc /home /root /tmp /var/tmp /run /usr/local /opt 2>/dev/null; "
               + "for f in /proc/[0-9]*/environ /proc/[0-9]*/cmdline; do tr '\\0' '\\n' < $f 2>/dev/null; done | grep -oE '\(re)'; echo END"], timeout: 120)
    check(r.out.hasSuffix("END\n") && !r.out.contains(token), "the real token is in no file, environment or command line in the guest (\(r.out.count) bytes of token-shaped text scanned)")
    r = t.run(["exec", "gh1", "--", "sh", "-c", "printf 'protocol=https\\nhost=github.com\\n\\n' | git credential fill 2>/dev/null | grep -E '^(username|password)='"])
    check(r.out.contains("username=x-access-token\npassword=doz_cred_") && !r.out.contains(token), "git's login is the placeholder (\(r.out.prefix(60).debugDescription))")

    // 5. Push on: push and changes work; the network log records them (method + path).
    r = t.run(["net", "allow", "gh1", "github:push", "--yes"])
    check(r.code == 0, "doz net allow gh1 github:push")
    r = t.run(["exec", "gh1", "--", "sh", "-c", "cd /tmp/r1 && git push -q origin HEAD:main 2>&1; echo \"EXIT=$?\""], timeout: 120)
    check(r.out.contains("EXIT=0"), "git push works with push on (\(r.out.suffix(200).debugDescription))")
    m0 = mac(["/usr/bin/git", "--git-dir", ws + "/repos/o/r.git", "log", "-1", "--format=%s|%an <%ae>"], env: gitEnv)
    check(m0.out.trimmingCharacters(in: .whitespacesAndNewlines) == "from the sandbox|Test Person <test@example.invalid>", "GitHub has the commit, by the Mac's identity (\(m0.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    out = api("POST", "/repos/o/r/issues", #"{"title":"from the sandbox"}"#)
    check(out.contains("HTTP=201"), "POST /repos/o/r/issues works with push on (\(out.suffix(80)))")
    out = api("POST", "/graphql", #"{"query":"mutation { addStar(input: {}) { clientMutationId } }"}"#, auth: "bearer $GH_TOKEN")
    check(out.contains("HTTP=200"), "a GraphQL mutation goes through with push on")
    r = t.run(["net", "log", "gh1"])
    check(r.out.contains("POST /repos/o/r/issues") && r.out.contains("swapped github (push)"), "the network log has each change, method and path")
    check(!r.out.contains(token), "…and never the token")
    check(hostLog(t).contains("gh1 used your GitHub login (read and push)"), "a new notice for the new mode")

    // 6. The token source: a sandbox's own key (doz key set --github); github.credentials = key / gh.
    check(t.run(["config", "set", "github.credentials", "key"]).code == 0, "github.credentials = key")
    out = api("GET", "/user")
    check(out.contains("HTTP=401") && out.contains("has no GitHub token"), "key, but none given: refused, saying how (\(out.suffix(160)))")
    try? (token2 + "\n").write(toFile: ws + "/token2", atomically: true, encoding: .utf8)
    try? (token + "\n" + token2 + "\n").write(toFile: ws + "/tokens", atomically: true, encoding: .utf8)
    let ks = t.run(["key", "set", "gh1", "--github"], stdin: Data((token2 + "\n").utf8))
    check(ks.code == 0, "doz key set gh1 --github < a token (\(ks.out.trimmingCharacters(in: .whitespacesAndNewlines))\(ks.err.suffix(200)))")
    out = api("GET", "/user")
    check(out.contains("HTTP=200") && requests().contains("token \(token2)"), "…the sandbox's own token is used")
    r = t.run(["key", "ls", "gh1"])
    check(r.out.contains("github") && !r.out.contains(token2), "doz key ls shows the github key, never its value")
    check(!((try? String(contentsOf: t.store.appendingPathComponent("sandboxes/gh1/doz.json"), encoding: .utf8)) ?? "").contains(token2), "the token is not in the store")
    check(t.run(["key", "rm", "gh1", "--github"]).code == 0, "doz key rm gh1 --github")
    check(t.run(["config", "set", "github.credentials", "gh"]).code == 0, "github.credentials = gh again")

    // 7. Off revokes at once: the old placeholder is refused, and nothing of the user's stays.
    let before = requests().count
    check(t.run(["net", "deny", "gh1", "github:as-you"]).code == 0, "doz net deny gh1 github:as-you")
    out = t.run(["exec", "gh1", "--", "sh", "-c", "curl -sS --max-time 20 -H 'Authorization: token \(ph1)' -w ' HTTP=%{http_code}' https://api.github.com/user 2>&1"], timeout: 60).out
    check(!out.contains("fake-user") && requests().count == before, "the placeholder issued before is refused, and GitHub hears nothing (\(out.suffix(160)))")
    r = t.run(["exec", "gh1", "--", "sh", "-c", "printf '[%s]' \"$GH_TOKEN\"; git config --get user.name; git config --get credential.https://github.com.helper; echo END"])
    check(r.out.hasPrefix("[]") && !r.out.contains("Test Person") && !r.out.contains("git-credential-doz"), "off: no placeholder, no identity, no helper config (\(r.out.debugDescription))")

    // 8. SSH agent forwarding: off by default; on → the guest can ask the Mac's agent to sign, the key stays.
    r = t.run(["exec", "gh1", "--", "sh", "-c", "printf '[%s]' \"$SSH_AUTH_SOCK\"; test -S /run/doz/ssh-agent.sock && echo SOCK || echo NOSOCK"])
    check(r.out.contains("[]") && r.out.contains("NOSOCK"), "off by default: no agent socket")
    check(t.run(["config", "set", "--sandbox", "gh1", "sandbox.ssh_agent", "on"]).code == 0, "doz config set --sandbox gh1 sandbox.ssh_agent on")
    sleep(2)
    r = t.run(["exec", "gh1", "--", "sh", "-c", "echo \"$SSH_AUTH_SOCK\"; ssh-add -l"])
    check(r.out.contains("/run/doz/ssh-agent.sock") && r.out.contains(fp), "the guest lists the Mac agent's key (\(fp)) through the forwarded socket (\(r.out.debugDescription))")
    r = t.run(["exec", "gh1", "--", "sh", "-c", "printf '%s\\n' '\(pub)' > /tmp/k.pub && echo 'signed in the sandbox' > /tmp/m && ssh-keygen -q -Y sign -U -f /tmp/k.pub -n file /tmp/m && cat /tmp/m.sig"], timeout: 60)
    let sig = r.out
    try? sig.write(toFile: ws + "/m.sig", atomically: true, encoding: .utf8)
    try? "doz-test@example.invalid \(pub)\n".write(toFile: ws + "/allowed", atomically: true, encoding: .utf8)
    let v = mac(["/usr/bin/ssh-keygen", "-Y", "verify", "-f", ws + "/allowed", "-I", "doz-test@example.invalid", "-n", "file", "-s", ws + "/m.sig"],
                stdin: "signed in the sandbox\n")
    check(sig.contains("BEGIN SSH SIGNATURE") && v.code == 0, "a signature made in the sandbox by the Mac's agent verifies on the Mac (\(v.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    r = t.run(["exec", "gh1", "--", "sudo", "-n", "sh", "-c", "grep -rIl 'OPENSSH PRIVATE KEY' /etc /home /root /tmp /run 2>/dev/null | head -3; echo END"])
    check(r.out == "END\n", "the private key is nowhere in the guest (\(r.out.debugDescription))")
    // The guest may list and sign — never add, remove or lock: those are refused before the Mac's agent.
    r = t.run(["exec", "gh1", "--", "sh", "-c", "ssh-add -D 2>&1; echo \"D=$?\"; printf 'x\\nx\\n' | ssh-add -x 2>&1; echo \"X=$?\""], timeout: 60)
    check(!r.out.contains("D=0") && !r.out.contains("X=0"), "ssh-add -D (remove all) and -x (lock) are refused (\(r.out.debugDescription))")
    m0 = mac(["/usr/bin/ssh-add", "-l"], env: ["SSH_AUTH_SOCK": agentSock])
    check(m0.out.contains(fp), "…the Mac's agent still has its key, unlocked (\(m0.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    check(hostLog(t).contains("gh1 used your SSH agent"), "the notice on first use (host log)")
    check(t.run(["config", "set", "--sandbox", "gh1", "sandbox.ssh_agent", "off"]).code == 0, "sandbox.ssh_agent off")
    sleep(2)
    // (The guest's connect() always completes — to doznet's local redirect; the proxy then refuses it, so not
    // one byte of an SSH banner comes back.)
    r = t.run(["exec", "gh1", "--", "sh", "-c", "printf '[%s]' \"$SSH_AUTH_SOCK\"; test -S /run/doz/ssh-agent.sock && echo SOCK || echo NOSOCK; timeout 8 bash -c 'exec 3<>/dev/tcp/github.com/22 && head -c 4 <&3' 2>/dev/null | grep -q SSH && echo SSH-BANNER || echo NO-BANNER"], timeout: 60)
    check(r.out.contains("[]") && r.out.contains("NOSOCK") && r.out.contains("NO-BANNER"), "off: no socket, and github.com:22 gives nothing (\(r.out.debugDescription))")
    r = t.run(["net", "log", "gh1", "--json"])
    let recs = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [[String: Any]]) ?? []
    let ssh = recs.filter { $0["host"] as? String == "github.com" && ($0["port"] as? Int) == 22 }
    check(!ssh.isEmpty && ssh.allSatisfy { $0["verdict"] as? String == "denied" }, "the proxy DENIED github.com:22 while off (\(ssh.count) record(s)) — never a connection to the real github.com")

    // 9. Flags and the project file.
    check(t.run(["create", "gh2", "--image", "lab", "--github", "write"], timeout: 60).code != 0, "--github write is refused")
    check(t.run(["config", "show"]).out.contains("github.credentials"), "doz config show lists github.credentials")
}
