import Darwin
import Foundation
import DozerHost
import DozerKit

// 599i — Codex as a first-class agent in real VMs, through SEAMS ONLY — never OpenAI, never the owner's
// ~/.codex, keychain or sign-in:
//   - a FAKE OpenAI on this Mac (python3, TLS with its own CA — `probes/599i-*/fake_openai.py` is the same
//     server): auth.openai.com's /oauth/token (code + refresh grants; rotation; a reused refresh token is
//     refused), chatgpt.com's /backend-api/codex/responses (WebSocket → 426, then SSE), api.openai.com
//     with a fake key. The proxy's OpenAI leg, the sign-in's exchange, the host's refresh and the key check
//     go there (DOZ_TEST_OPENAI_UPSTREAM + DOZ_TEST_OPENAI_CA), trusting ONLY that CA;
//   - the browser is the opener seam (DOZ_TEST_OPEN_URL: it records the URL and plays the callback);
//   - the keychain is the host's memory (DOZ_TEST_CREDENTIALS=memory).
// The REAL Codex (the pinned 0.160.1 linux-arm64 build from the npm registry) runs in the VM.
// Store /tmp/dzo-PID-x; CODEX_KEEP=1 keeps it (and the prepared images) for the next run.

private let fakeOpenAIServer = #"""
base64, json, os, ssl, sys, threading, time = (__import__(m) for m in ("base64", "json", "os", "ssl", "sys", "threading", "time"))
http = __import__("http.server")

certf, keyf, statef, logf, portf = sys.argv[1:6]
lock = threading.Lock()
API_KEY = os.environ.get("FAKE_OPENAI_KEY", "sk-proj-FAKE599iKEY0123456789")
ACCESS_TTL = int(os.environ.get("FAKE_ACCESS_TTL", "3600"))
ACCOUNT = "acct-fake-599i"

def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

SIG = "RkFLRS1PUEVOQUktU0lHTkFUVVJF" + "s" * 314           # an RS256 signature's length (342 base64url chars)
REFRESH_LEN = int(os.environ.get("FAKE_REFRESH_LEN", "2100"))  # long enough that Dozer must keep it in parts

def jwt(payload, sig=SIG):
    # Realistic sizes (a real sign-in is ~4 KB: ~2 KB access token, ~1 KB id token).
    return b64u(b'{"alg":"RS256","kid":"fake-key-1","typ":"JWT"}') + "." + b64u(json.dumps(payload, sort_keys=True).encode()) + "." + sig

def load():
    try: return json.load(open(statef))
    except Exception: return {"n": 0, "access": [], "refresh": [], "used_refresh": [], "issued": []}

def save(s):
    tmp = statef + ".tmp"
    json.dump(s, open(tmp, "w"), indent=1)
    os.replace(tmp, statef)

def issue(s):
    s["n"] += 1
    n = s["n"]
    now = int(time.time())
    orgs = [{"id": "org-%d-%s" % (i, "o" * 24), "title": "Organisation %d" % i, "role": "owner", "is_default": i == 0} for i in range(6)]
    idt = jwt({"email": "person@example.invalid", "exp": now + 3600, "iat": now, "aud": ["app_EMoamEEZ73f0CkXaXp7hrann"], "iss": "https://auth.openai.com",
               "https://api.openai.com/auth": {"chatgpt_plan_type": "plus", "chatgpt_account_id": ACCOUNT, "chatgpt_user_id": "user-fake",
                                               "organizations": orgs}})
    at = jwt({"exp": now + ACCESS_TTL, "iat": now, "jti": "ACCESS-%d" % n, "scp": ["openid", "profile", "email", "offline_access"],
              "https://api.openai.com/auth": {"chatgpt_account_id": ACCOUNT}, "pad": "p" * 1300})
    rt = "rt_FAKE599i_%d_%s" % (n, b64u(os.urandom(12)))
    rt += "_" + "r" * max(0, REFRESH_LEN - len(rt) - 1)
    s["access"].append(at); s["refresh"].append(rt); s["issued"] += [idt, at, rt]
    return {"id_token": idt, "access_token": at, "refresh_token": rt, "token_type": "Bearer", "expires_in": ACCESS_TTL}

def sse(text):
    rid = "resp_fake"
    evs = [{"type": "response.created", "response": {"id": rid}},
           {"type": "response.output_item.done", "item": {"type": "message", "role": "assistant", "id": "msg_fake",
                                                          "content": [{"type": "output_text", "text": text}]}},
           {"type": "response.completed", "response": {"id": rid, "usage": {"input_tokens": 1, "input_tokens_details": None,
                                                                          "output_tokens": 1, "output_tokens_details": None, "total_tokens": 2}}}]
    return "".join("event: %s\ndata: %s\n\n" % (e["type"], json.dumps(e)) for e in evs).encode()

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
        host = self.headers.get("Host", "").split(":")[0]
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        auth = self.headers.get("Authorization", "")
        bearer = auth[7:].strip() if auth.lower().startswith("bearer ") else ""
        grant = rt = None
        try:
            j = json.loads(body) if body.startswith(b"{") else dict(p.split("=", 1) for p in body.decode().split("&") if "=" in p)
            grant, rt = j.get("grant_type"), j.get("refresh_token")
        except Exception: pass
        with lock:
            s = load()
            entry = {"t": time.time(), "m": self.command, "host": host, "path": self.path, "auth": auth,
                     "account": self.headers.get("ChatGPT-Account-ID", ""), "upgrade": self.headers.get("Upgrade", ""),
                     "grant": grant, "refresh_token": rt, "body_has_placeholder": b"doz_cred_" in body}
            open(logf, "a").write(json.dumps(entry) + "\n")
            if host == "auth.openai.com" and self.path.startswith("/oauth/token"):
                if grant == "authorization_code":
                    if j.get("code") != "doz-test-code": return self.send(400, b'{"error":"invalid_grant","error_description":"bad code"}')
                    t = issue(s); save(s); return self.send(200, json.dumps(t).encode())
                if grant == "refresh_token":
                    if rt in s["used_refresh"]:
                        return self.send(401, b'{"error":{"code":"refresh_token_reused","message":"already used"}}')
                    if rt not in s["refresh"]:
                        return self.send(401, b'{"error":{"code":"refresh_token_invalidated","message":"unknown refresh token"}}')
                    s["refresh"].remove(rt); s["used_refresh"].append(rt)
                    s["revoke_access"] = False
                    t = issue(s); save(s)
                    t.pop("id_token") if s.get("omit_id_token") else None
                    return self.send(200, json.dumps(t).encode())
                return self.send(400, b'{"error":"unsupported_grant_type"}')
            if host == "chatgpt.com":
                if "/responses" in self.path and self.headers.get("Upgrade", "").lower() == "websocket":
                    return self.send(426, b'{"error":{"message":"use HTTP"}}')
                live = bearer in s["access"] and not s.get("revoke_access")
                if self.path.startswith("/backend-api/wham/accounts/check"):
                    # Codex 0.160.1's workspace routing discovery (backend-client `get_accounts_check`).
                    if not live: return self.send(401, b'{"error":{"message":"invalid token"}}')
                    return self.send(200, json.dumps({"accounts": [{"id": ACCOUNT, "plan_type": "plus", "workspace_backend_origin": "NO_CONSTRAINT",
                                                                     "account_routing_override": "NO_CONSTRAINT"}],
                                                      "account_ordering": [ACCOUNT], "default_account_id": ACCOUNT}).encode())
                if "/models" in self.path:
                    return self.send(200 if live else 401, b'{"models":[]}' if live else b'{"error":{"message":"invalid token"}}')
                if "/responses" in self.path and self.command == "POST":
                    if not live: return self.send(401, b'{"error":{"message":"Your authentication token is not valid.","code":"token_invalid"}}')
                    if self.headers.get("ChatGPT-Account-ID") != ACCOUNT: return self.send(403, b'{"error":{"message":"wrong account"}}')
                    s["answers"] = s.get("answers", 0) + 1; save(s)
                    return self.send(200, sse("PONG-CHATGPT-%d" % s["answers"]), "text/event-stream")
                return self.send(200, b"{}")
            if host == "api.openai.com":
                if bearer != API_KEY: return self.send(401, b'{"error":{"message":"Incorrect API key provided","code":"invalid_api_key"}}')
                if self.path.startswith("/v1/models"): return self.send(200, b'{"object":"list","data":[],"models":[]}')
                if self.path.startswith("/v1/responses") and self.headers.get("Upgrade", "").lower() == "websocket":
                    return self.send(426, b'{"error":{"message":"use HTTP"}}')
                if self.path.startswith("/v1/responses"):
                    s["key_answers"] = s.get("key_answers", 0) + 1; save(s)
                    return self.send(200, sse("PONG-APIKEY-%d" % s["key_answers"]), "text/event-stream")
                return self.send(200, b"{}")
            return self.send(404, b'{"error":{"message":"not here"}}')
    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = any

srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certf, keyf)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
open(portf, "w").write(str(srv.server_address[1]))
srv.serve_forever()
"""#

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

func cliCodexSuite(binary: String) async {
    let pid = getpid()
    let keep = ProcessInfo.processInfo.environment["CODEX_KEEP"] == "1"
    // CODEX_KEEP=1: one fixed store, kept with its prepared images for the next run (the first run makes it).
    let kept = URL(fileURLWithPath: "/tmp/dzo-codex-keep")
    let t: CLIHarness
    if keep, FileManager.default.fileExists(atPath: kept.appendingPathComponent("host.log").path) {
        t = CLIHarness(binary: binary, store: kept)
        t.env["DOZ_HOST_IDLE"] = "2"
        t.env["DOZ_TEST_CREDENTIALS"] = "memory"
    } else if keep {
        t = CLIHarness(binary: binary, store: kept)
        let src = NSTemporaryDirectory() + "doz-vmtest-store"
        try? FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        for item in ["kernels", "content", "state.json", "initfs.ext4", "golden"] where FileManager.default.fileExists(atPath: src + "/" + item) {
            _ = onMac(["/bin/cp", "-cR", src + "/" + item, kept.path + "/"])
        }
        t.env["DOZ_HOST_IDLE"] = "2"
        t.env["DOZ_TEST_CREDENTIALS"] = "memory"
    } else {
        t = onboardingHarness(binary, "x", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    }
    t.env["DOZ_TEST_NPM_REGISTRY"] = "offline"          // the pinned Codex (0.160.1) — no registry lookups
    t.env["DOZ_TEST_BASE_REGISTRY"] = "pinned"
    let w = URL(fileURLWithPath: "/tmp/dzo-\(pid)-xw")          // the fake OpenAI, the opener seam's file
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
    print("cli: Codex — Dozer's own ChatGPT sign-in, the proxy's swap and renewal, an API key, no token in the VM (599i)")
    /// `doz ARGS… --store STORE` (before any `--`): the scratch store on every command line too.
    func d(_ args: [String], stdin: Data? = nil, timeout: Double = 180) -> CLIRun {
        var a = args
        if let i = a.firstIndex(of: "--") { a.insert(contentsOf: ["--store", t.store.path], at: i) } else { a += ["--store", t.store.path] }
        return t.run(a, stdin: stdin, timeout: timeout)
    }

    // ── The fake OpenAI (scratch CA + a leaf for its three hosts) ───────────────────────────────────
    try? fakeOpenAIServer.write(toFile: ws + "/server.py", atomically: true, encoding: .utf8)
    try? "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n".write(toFile: ws + "/ca.ext", atomically: true, encoding: .utf8)
    try? "subjectAltName=DNS:chatgpt.com,DNS:api.openai.com,DNS:auth.openai.com,DNS:ab.chatgpt.com\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n"
        .write(toFile: ws + "/leaf.ext", atomically: true, encoding: .utf8)
    let m0 = onMac(["/bin/sh", "-c", """
        set -e
        /usr/bin/openssl req -new -newkey rsa:2048 -nodes -keyout ca.key -out ca.csr -subj '/CN=Dozer test OpenAI CA' 2>&1
        /usr/bin/openssl x509 -req -in ca.csr -signkey ca.key -out ca.pem -days 2 -extfile ca.ext 2>&1
        /usr/bin/openssl req -new -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj '/CN=chatgpt.com' 2>&1
        /usr/bin/openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out leaf.pem -days 2 -extfile leaf.ext 2>&1
        """], cwd: ws)
    check(m0.code == 0, "a throwaway CA and a certificate for chatgpt.com / api.openai.com / auth.openai.com (\(m0.code))")
    let srv = Process()
    srv.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    srv.arguments = [ws + "/server.py", ws + "/leaf.pem", ws + "/leaf.key", ws + "/state.json", ws + "/requests.log", ws + "/port"]
    var senv = ProcessInfo.processInfo.environment
    senv["HOME"] = ws
    srv.environment = senv
    srv.standardOutput = FileHandle.nullDevice
    srv.standardError = FileHandle.nullDevice
    do { try srv.run(); server = srv } catch { check(false, "start the fake OpenAI: \(error)") }
    var port = ""
    for _ in 0..<50 where port.isEmpty { usleep(100_000); port = (try? String(contentsOfFile: ws + "/port", encoding: .utf8)) ?? "" }
    check(!port.isEmpty, "the fake OpenAI listens on 127.0.0.1:\(port) (TLS, its own CA)")
    func requests() -> [[String: Any]] {
        ((try? String(contentsOfFile: ws + "/requests.log", encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
    func state() -> [String: Any] { ((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: ws + "/state.json")))) as? [String: Any]) ?? [:] }
    func setState(_ f: (inout [String: Any]) -> Void) {
        var s = state()
        f(&s)
        if let d = try? JSONSerialization.data(withJSONObject: s) { try? d.write(to: URL(fileURLWithPath: ws + "/state.json"), options: .atomic) }
    }
    /// Every token the fake ever issued (the "real" ones).
    func realTokens() -> [String] { (state()["issued"] as? [String]) ?? [] }

    t.env["DOZ_TEST_OPENAI_UPSTREAM"] = "127.0.0.1:\(port)"
    t.env["DOZ_TEST_OPENAI_CA"] = ws + "/ca.pem"
    t.env["DOZ_TEST_OPEN_URL"] = ws + "/opened"
    // Never a host without the fake: a host left from an earlier run (or started before the seams were set)
    // would send the test's fake tokens to the real OpenAI. Stop any, then check the new one has the fake.
    _ = d(["host", "stop"], timeout: 300)
    if keep {
        // Sandboxes of an earlier run go; the prepared images stay.
        for n in ["cx", "ax"] { _ = d(["rm", n, "--yes"], timeout: 120) }
    }
    let seamLine = "go to 127.0.0.1:\(port), trusting only its CA"
    func startHostWithFake() -> Bool {
        _ = d(["host", "start"], timeout: 60)
        var seamed = false
        for _ in 0..<50 where !seamed { seamed = hostLog(t).components(separatedBy: "doz host ").last?.contains(seamLine) == true; if !seamed { usleep(100_000) } }
        return seamed
    }
    let seamed = startHostWithFake()
    check(seamed, "the host runs with the fake OpenAI (its log says so) — nothing goes to the real OpenAI")
    guard seamed else { info("aborted: the host has no fake OpenAI"); return }
    check(d(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    check(d(["config", "set", "defaults.projects_dir", "/tmp/dzo-\(pid)-xp"]).code == 0, "defaults.projects_dir is a scratch path")
    check(d(["config", "set", "images.codex_version", AgentImages.codexPinned.version]).code == 0, "the pinned Codex (no registry)")

    // ── 1. Dozer's own ChatGPT sign-in (the browser seam plays the callback) ───────────────────────
    var r = d(["account", "add", "plan", "--chatgpt", "--force"], timeout: 120)
    check(r.code == 0 && r.out.contains("account plan added (chatgpt: person@example.invalid, plus"),
          "doz account add plan --chatgpt → signed in (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines))) \(r.code == 0 ? "" : r.err.suffix(300).description)")
    let opened = (try? String(contentsOfFile: ws + "/opened", encoding: .utf8)) ?? ""
    check(opened.contains("open https://auth.openai.com/oauth/authorize?") && opened.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann")
          && opened.contains("code_challenge_method=S256"), "the browser was sent to OpenAI's sign-in with Codex's client and PKCE")
    check(opened.contains("callback ") && opened.contains("200 OK"), "the browser's callback reached Dozer's loopback listener (\(opened.split(separator: "\n").last ?? ""))")
    check(r.err.contains("your Mac's Codex login is not touched"), "the sign-in says it is Dozer's own")
    check(requests().contains { $0["grant"] as? String == "authorization_code" }, "the code was exchanged with auth.openai.com from the Mac")
    let rows = t.json(["account", "ls", "--store", t.store.path], [AccountRow].self) ?? []
    check(rows.first { $0.name == "plan" }.map { $0.kind == "chatgpt" && $0.plan == "plus" && $0.identity == "person@example.invalid" } == true,
          "doz account ls: plan · chatgpt · plus · person@example.invalid")
    let accountsFile = (try? String(contentsOf: t.store.appendingPathComponent("accounts.json"), encoding: .utf8)) ?? ""
    check(!realTokens().isEmpty && !realTokens().contains { accountsFile.contains($0) }, "accounts.json holds no token")
    let firstThree = realTokens().prefix(3).map(\.utf8.count)
    check(firstThree.reduce(0, +) > 4000, "the fake's sign-in is real-sized: id \(firstThree.first ?? 0) B, access \(firstThree.dropFirst().first ?? 0) B, refresh \(firstThree.last ?? 0) B (kept in parts by Dozer)")
    check(d(["account", "default", "plan"]).out.contains("the default OpenAI account (Codex) is plan"), "doz account default plan → the OpenAI default")

    // ── 2. A Codex sandbox — the real Codex answers through the proxy ────────────────────────────────
    r = d(["create", "cx", "--agent", "codex", "--isolated", "--memory", "2G", "--start"], timeout: 2400)
    check(r.code == 0, "create cx --agent codex --start (prepares the codex image: Node base + Codex \(AgentImages.codexPinned.version)) \(r.code == 0 ? "" : r.err.suffix(400).description)")
    r = d(["exec", "cx", "--", "codex", "--version"])
    check(r.out.contains("codex-cli \(AgentImages.codexPinned.version)"), "codex --version → \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))")
    r = d(["net", "cx", "--json"])
    let perms = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])?["permissions"] as? [[String: Any]] ?? []
    check(perms.contains { $0["id"] as? String == "model:openai" && $0["on"] as? Bool == true && $0["locked"] as? Bool == true },
          "the sandbox's permissions: \"Talk to OpenAI\" on, locked")
    func ask(_ prompt: String, _ name: String = "cx", timeout: Double = 240) -> CLIRun {
        d(["exec", name, "--", "codex", "exec", "--skip-git-repo-check", prompt], timeout: timeout)
    }
    r = ask("Say hello")
    check(r.code == 0 && (r.out + r.err).contains("PONG-CHATGPT-"), "codex exec → answered through chatgpt.com (\((r.out + r.err).suffix(240).debugDescription))")
    let chat = requests().filter { $0["host"] as? String == "chatgpt.com" && ($0["path"] as? String ?? "").contains("/responses") }
    check(chat.contains { $0["upgrade"] as? String == "websocket" }, "Codex tried the WebSocket first (the fake answered 426)")
    let issued = realTokens()
    check(chat.contains { ($0["auth"] as? String).map { a in issued.contains { a == "Bearer " + $0 } } == true && $0["m"] as? String == "POST" },
          "chatgpt.com got the REAL access token, swapped in by the proxy")
    check(!chat.isEmpty && chat.allSatisfy { $0["account"] as? String == "acct-fake-599i" }, "…with the account id from the guest's auth.json (ChatGPT-Account-ID)")
    check(!requests().contains { ($0["auth"] as? String ?? "").contains("doz_cred_") || $0["body_has_placeholder"] as? Bool == true },
          "OpenAI never saw a placeholder")
    r = d(["exec", "cx", "--", "sh", "-c", "cat ~/.codex/auth.json"])
    check(r.out.contains("\"auth_mode\" : \"chatgpt\"") && r.out.contains("\"access_token\" : \"doz_cred_") && r.out.contains("ZG96LXVuc2lnbmVk"),
          "the guest's ~/.codex/auth.json: placeholders and the id_token's claims under a fake signature")
    r = d(["exec", "cx", "--", "sh", "-c", "stat -c '%U %a' ~/.codex/auth.json"])
    check(r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "agent 600", "…the agent's, 0600 (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")

    // ── 3. No real token in the guest: files, every process's environment and command line ──────────
    func noTokenInGuest(_ what: String) {
        // The guest prints everything SHAPED like a token; the Mac looks (nothing real goes into the guest to search for).
        let re = "(eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}|rt_FAKE599i_[A-Za-z0-9_-]+|sk-proj-[A-Za-z0-9_-]+)"
        let g = d(["exec", "cx", "--", "sudo", "-n", "sh", "-c",
                   "grep -rIhoE '\(re)' /etc /home /root /tmp /var/tmp /run /usr/local /opt/codex/package.json 2>/dev/null; "
                   + "for f in /proc/[0-9]*/environ /proc/[0-9]*/cmdline; do tr '\\0' '\\n' < $f 2>/dev/null; done | grep -oE '\(re)'; echo END"], timeout: 120)
        let real = realTokens() + ["sk-proj-FAKE599iKEY0123456789"]
        let leaked = real.filter { g.out.contains($0) }
        check(g.out.hasSuffix("END\n") && leaked.isEmpty, "\(what): no real token in any file, environment or command line in the guest (\(g.out.count) bytes of token-shaped text scanned)")
    }
    noTokenInGuest("after the first answer")

    // ── 4. A renewal on the Mac: the fake refuses the access token → the proxy re-reads → the host refreshes ──
    let rtBefore = (state()["refresh"] as? [String])?.last ?? ""
    setState { $0["revoke_access"] = true }
    r = ask("Say hello again")
    check(r.code == 0 && (r.out + r.err).contains("PONG-CHATGPT-"), "after a 401, Codex is answered again (\((r.out + r.err).suffix(200).debugDescription))")
    let refreshes = requests().filter { $0["grant"] as? String == "refresh_token" }
    check(refreshes.contains { $0["refresh_token"] as? String == rtBefore }, "the HOST renewed the sign-in with the real refresh token (rotation)")
    check(!refreshes.isEmpty && !refreshes.contains { ($0["refresh_token"] as? String ?? "").hasPrefix("doz_cred_") }, "no guest renewal (placeholder) ever reached auth.openai.com")
    check(hostLog(t).contains("the ChatGPT sign-in of account plan was renewed on this Mac"), "the host log says the sign-in was renewed")
    // Codex's own renewal from the guest: answered by the proxy with the same placeholder.
    r = d(["exec", "cx", "--", "sh", "-c", """
        ph=$(python3 -c 'print(__import__("json").load(open("/home/agent/.codex/auth.json"))["tokens"]["refresh_token"])')
        curl -sS --max-time 20 -X POST -H 'Content-Type: application/json' --data "{\\"client_id\\":\\"app_EMoamEEZ73f0CkXaXp7hrann\\",\\"grant_type\\":\\"refresh_token\\",\\"refresh_token\\":\\"$ph\\"}" https://auth.openai.com/oauth/token -w ' HTTP=%{http_code}'; echo; echo "PH=$ph"
        """], timeout: 60)
    let ph = r.out.components(separatedBy: "PH=").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    check(r.out.contains("HTTP=200") && r.out.contains("\"access_token\":\"\(ph)\"") && ph.hasPrefix("doz_cred_"),
          "the guest's own refresh (POST auth.openai.com/oauth/token) is answered by the proxy: the same placeholder (\(r.out.prefix(120).debugDescription))")
    check(!requests().contains { $0["refresh_token"] as? String == ph }, "…and never reached OpenAI")
    r = d(["exec", "cx", "--", "sh", "-c", "curl -sS --max-time 20 https://auth.openai.com/oauth/authorize -o /dev/null -w 'HTTP=%{http_code}'"], timeout: 60)
    check(r.out.contains("HTTP=403"), "any other request to auth.openai.com follows the policy (refused: \(r.out))")
    noTokenInGuest("after the renewal")
    // (A new host renewing from the kept record is a unit test — `CodexHostTests`: this suite's keychain lives in the
    // host's memory, DOZ_TEST_CREDENTIALS=memory, so a restarted host has no sign-in at all.)
    let rotated = requests().filter { $0["grant"] as? String == "refresh_token" }.count

    // ── 5. No silent fallback ─────────────────────────────────────────────────────────────────────────
    check(d(["account", "use", "cx", "none"]).code == 0, "doz account use cx none")
    r = ask("Hello?", timeout: 180)
    check(r.code != 0 && (r.out + r.err).contains("no OpenAI account now"), "with no account, Codex gets Dozer's reason — never another credential (\((r.out + r.err).suffix(200).debugDescription))")
    check(d(["account", "use", "cx", "plan"]).code == 0, "doz account use cx plan")
    r = ask("Back?")
    check(r.code == 0 && (r.out + r.err).contains("PONG-CHATGPT-"), "back on the sign-in: answered again")

    // ── 6. An OpenAI API key (api.openai.com) ─────────────────────────────────────────────────────────
    r = d(["account", "add", "okey", "--openai-key", "--force"], stdin: Data("sk-proj-FAKE599iKEY0123456789\n".utf8))
    check(r.code == 0 && r.out.contains("account okey added (openai-key"), "doz account add okey --openai-key (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    check(d(["account", "use", "cx", "okey"]).code == 0, "doz account use cx okey")
    r = ask("Key?")
    check(r.code == 0 && (r.out + r.err).contains("PONG-APIKEY-"), "codex exec → answered through api.openai.com with the key (\((r.out + r.err).suffix(200).debugDescription))")
    check(requests().contains { $0["host"] as? String == "api.openai.com" && $0["auth"] as? String == "Bearer sk-proj-FAKE599iKEY0123456789" && ($0["path"] as? String ?? "").hasPrefix("/v1/responses") },
          "api.openai.com got the real key, swapped in by the proxy")
    r = d(["exec", "cx", "--", "sh", "-c", "cat ~/.codex/auth.json; echo; echo \"$OPENAI_API_KEY\""])
    check(r.out.contains("\"auth_mode\" : \"apikey\"") && !r.out.contains("sk-proj-FAKE"), "auth.json and OPENAI_API_KEY hold placeholders (\(r.out.prefix(80).debugDescription))")
    noTokenInGuest("with the API key")
    check(requests().filter { $0["grant"] as? String == "refresh_token" }.count == rotated, "no renewal while the key is in use")

    // ── 6b. mac — THIS Mac's own Codex login (a FAKE Codex home), read-only ────────────────────────────
    let codexHome = URL(fileURLWithPath: t.env["DOZ_TEST_CODEX_HOME"]!)
    try? fm.createDirectory(at: codexHome, withIntermediateDirectories: true)
    /// The fake Mac Codex signing in / refreshing: real tokens from the fake OpenAI, written to the fake home's auth.json.
    let fetchTokens = """
        curl -sS --cacert '\(ws)/ca.pem' --resolve auth.openai.com:\(port):127.0.0.1 -d 'grant_type=authorization_code&code=doz-test-code&client_id=x' \\
          https://auth.openai.com:\(port)/oauth/token | /usr/bin/python3 -c 'j=__import__("json"); t=j.load(__import__("sys").stdin); print(j.dumps({"auth_mode":"chatgpt","OPENAI_API_KEY":None,"last_refresh":"2026-10-07T00:00:00Z","tokens":{"id_token":t["id_token"],"access_token":t["access_token"],"refresh_token":t["refresh_token"],"account_id":"acct-fake-599i"}}))' > "$CODEX_HOME/auth.json.new" && mv "$CODEX_HOME/auth.json.new" "$CODEX_HOME/auth.json"
        """
    func macSignsIn() -> Bool {
        onMac(["/bin/sh", "-c", "CODEX_HOME='\(codexHome.path)'; " + fetchTokens]).code == 0
    }
    /// An expired access token in the Mac's file (what a Mac whose Codex has not run for an hour holds).
    func macLoginExpires() {
        func b64(_ s: String) -> String { OpenAIAccess.base64URL(Data(s.utf8)) }
        let at = b64(#"{"alg":"RS256"}"#) + "." + b64("{\"exp\":\(Int(Date().timeIntervalSince1970) - 120)}") + ".c2ln"
        let id = b64(#"{"alg":"RS256"}"#) + "." + b64(#"{"email":"person@example.invalid","https://api.openai.com/auth":{"chatgpt_plan_type":"plus","chatgpt_account_id":"acct-fake-599i"}}"#) + ".c2ln"
        let o: [String: Any] = ["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(), "tokens": ["id_token": id, "access_token": at, "refresh_token": "rt_mac_expired", "account_id": "acct-fake-599i"]]
        try? JSONSerialization.data(withJSONObject: o).write(to: codexHome.appendingPathComponent("auth.json"))
    }
    func homeSnapshot() -> String { onMac(["/bin/sh", "-c", "ls -lT '\(codexHome.path)'"]).out }
    // The fake codex the keep-alive may run: it records its arguments, then refreshes the fake home (as `codex doctor` would).
    let fakeBin = URL(fileURLWithPath: t.env["DOZ_TEST_CODEX_BIN"]!)
    try? fm.createDirectory(at: fakeBin.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? "#!/bin/sh\necho \"$*\" >> '\(ws)/fake-codex.log'\n\(fetchTokens)\n".write(to: fakeBin, atomically: true, encoding: .utf8)
    chmod(fakeBin.path, 0o755)
    macLoginExpires()
    r = d(["account", "ls"])
    check(r.out.contains("codex-mac") && r.out.contains("expired"), "doz account ls: mac · codex-mac · expired (this Mac's Codex login, read)")
    check(d(["account", "use", "cx", "mac"]).code == 0, "doz account use cx mac (this Mac's Codex login)")
    var snap = homeSnapshot()
    r = ask("Mac login, expired?", timeout: 180)
    check(r.code != 0 && (r.out + r.err).contains("your Mac's Codex login has expired"), "an expired Mac login: Dozer's message, never another account (\((r.out + r.err).suffix(200).debugDescription))")
    check(homeSnapshot() == snap, "Dozer did not write the Mac's Codex home")
    check(macSignsIn(), "the Mac's Codex refreshes (the fake home gets fresh tokens)")
    snap = homeSnapshot()
    let macToken = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: codexHome.appendingPathComponent("auth.json")))) as? [String: Any])
        .flatMap { $0["tokens"] as? [String: Any] }?["access_token"] as? String ?? "?"
    r = ask("Mac login, fresh?")
    check(r.code == 0 && (r.out + r.err).contains("PONG-CHATGPT-"), "after the Mac's refresh, Codex is answered at once — no account change, no host restart (\((r.out + r.err).suffix(160).debugDescription))")
    check(requests().contains { $0["auth"] as? String == "Bearer " + macToken }, "chatgpt.com got the Mac's access token, swapped in by the proxy")
    check(!requests().contains { $0["refresh_token"] as? String == "rt_mac_expired" } && requests().filter({ $0["grant"] as? String == "refresh_token" }).count == rotated,
          "Dozer never refreshed the Mac's login (no refresh grant since)")
    check(homeSnapshot() == snap, "Dozer did not write the Mac's Codex home")
    noTokenInGuest("on the Mac's Codex login")
    // The keep-alive: the login expires again; with codex.keep_alive on, the Mac's own (fake) codex doctor runs.
    macLoginExpires()
    check(d(["config", "set", "codex.keep_alive", "true"]).code == 0, "doz config set codex.keep_alive true")
    r = ask("Mac login, kept alive?")
    let fakeCodexRuns = (try? String(contentsOfFile: ws + "/fake-codex.log", encoding: .utf8)) ?? ""
    check(fakeCodexRuns.split(separator: "\n").contains("doctor"), "the keep-alive ran the Mac's codex doctor (no model call): \(fakeCodexRuns.debugDescription)")
    check(r.code == 0 && (r.out + r.err).contains("PONG-CHATGPT-"), "…and Codex is answered with the renewed login (\((r.out + r.err).suffix(160).debugDescription))")
    check(hostLog(t).contains("Codex keep-alive"), "the host log says so")
    check(d(["config", "set", "codex.keep_alive", "false"]).code == 0, "keep-alive off again")
    check(d(["account", "use", "cx", "okey"]).code == 0, "back on the key")

    // ── 7. Codex on a musl base (Alpine) ──────────────────────────────────────────────────────────────
    r = d(["create", "ax", "--agent", "codex", "--base", "alpine", "--isolated", "--account", "okey", "--start"], timeout: 2400)
    check(r.code == 0, "create ax --agent codex --base alpine --start \(r.code == 0 ? "" : r.err.suffix(300).description)")
    r = d(["exec", "ax", "--", "codex", "--version"])
    check(r.out.contains("codex-cli \(AgentImages.codexPinned.version)"), "alpine-codex: codex --version → \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))")
    r = d(["exec", "ax", "--", "sh", "-c", "test -e /opt/codex/vendor/aarch64-unknown-linux-musl/codex-path/rg && echo bundled-rg || echo baseline-rg; command -v rg"])
    check(r.out.hasPrefix("baseline-rg"), "alpine-codex: the bundled glibc rg removed, the baseline's ripgrep used (\(r.out.debugDescription))")
    r = ask("Alpine?", "ax")
    check(r.code == 0 && (r.out + r.err).contains("PONG-APIKEY-"), "alpine-codex: Codex answered through the proxy (\((r.out + r.err).suffix(160).debugDescription))")

    // ── 8. The launcher: the facts reach Codex as developer instructions; a session runs codex ───────────
    r = d(["exec", "cx", "--", "sh", "-c", "cat /home/agent/.local/bin/codex | head -3; ls /home/agent/.agents/skills/dozer 2>&1"])
    check(r.out.contains("doz: Codex with its first-run setup done"), "the launcher is first on the agent's PATH")
    r = d(["run", "cx", "--detach", "--session", "codex", "--", "codex"], timeout: 120)
    usleep(3_000_000)
    r = d(["exec", "cx", "--", "sh", "-c", "ls /home/agent/.agents/skills/dozer; grep -c dozer /run/dozer/agent-prompt.md; ps -eo args | grep -m1 'dangerously-bypass-approvals-and-sandbox' | grep -c developer_instructions; grep -A1 'projects.\"/workspace\"' /home/agent/.codex/config.toml"])
    check(r.out.contains("SKILL.md"), "the dozer skill in ~/.agents/skills/dozer (\(r.out.debugDescription))")
    check(r.out.contains("trust_level = \"trusted\""), "/workspace is trusted in Codex's config (no trust prompt)")
    check(r.out.split(separator: "\n").dropFirst(2).first == "1", "the TUI runs with its approvals off and the facts as developer instructions")
    info("sessions: " + d(["sessions", "cx"]).out.split(separator: "\n").joined(separator: " | ").prefix(300))
    noTokenInGuest("with the TUI running")

    // ── 9. 608: the Codex TUI in /workspace keeps working across hibernate → wake and a host restart; Restart session ──
    // The TUI is driven through `doz attach` on a pseudo-terminal (python3's pty on the Mac): the prompt as a
    // bracketed paste (typed keys arrive in bursts through the relays and Codex takes a burst for a paste, whose
    // Enter only adds a line), then Enter, and read until the fake model's answer — or Codex's "invalid cwd"
    // (the 0.29.0 bug, which the control sandbox — workspace.view off — still shows).
    try? cwdTUIDriver.write(toFile: ws + "/tui.py", atomically: true, encoding: .utf8)
    func tui(_ name: String, _ prompt: String) -> (answered: Bool, invalidCwd: Bool, tail: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [ws + "/tui.py", prompt, "PONG-APIKEY-", "120", t.binary, "attach", name, "codex", "--store", t.store.path]
        p.environment = t.env
        let o = Pipe()
        p.standardOutput = o
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (false, false, "python3 did not start") }
        let c = PipeCollector(o.fileHandleForReading)
        p.waitUntilExit()
        c.wait(5)
        let out = c.text
        return (out.contains("RESULT=FOUND"), out.contains("invalid cwd"), String(out.suffix(300)))
    }
    let key = Data("sk-proj-FAKE599iKEY0123456789\n".utf8)
    for (name, view) in [("cw", "on"), ("cr", "off")] {
        let dir = "/tmp/dzo-\(pid)-x\(name)"
        try? fm.removeItem(atPath: dir)
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        r = d(["create", name, "--agent", "codex", "--workspace", dir, "--account", "okey", "--workspace-view", view, "--start"], timeout: 900)
        check(r.code == 0, "create \(name) --agent codex --workspace … --workspace-view \(view) --start")
        check(d(["run", name, "--detach", "--session", "codex", "--", "codex"], timeout: 120).code == 0, "\(name): the Codex TUI in /workspace")
        usleep(5_000_000)
        let a = tui(name, "first turn")
        check(a.answered, "\(name): a turn in the TUI is answered (\(a.tail.debugDescription))")
    }
    // hibernate → wake
    for name in ["cw", "cr"] { check(d(["hibernate", name], timeout: 180).code == 0 && d(["wake", name], timeout: 300).code == 0, "\(name): hibernate → wake") }
    var a = tui("cw", "after the wake")
    check(a.answered && !a.invalidCwd, "cw (the live view): after hibernate → wake the same Codex is answered — no invalid cwd (\(a.tail.debugDescription))")
    a = tui("cr", "after the wake")
    check(a.invalidCwd && !a.answered, "control cr (workspace.view off): Codex fails with \"invalid cwd\" after the wake — the 0.29.0 bug (\(a.tail.debugDescription))")
    // Restart session — the remedy, and the conversation continues (`codex resume --last`)
    let before = (t.json(["sessions", "cr", "--store", t.store.path], [SessionRow].self) ?? []).first { $0.name == "codex" }?.pid
    r = d(["sessions", "restart", "cr", "codex", "-d", "--yes", "--json"], timeout: 120)
    let rs = try? HostWire.decoder.decode(SessionRestarted.self, from: r.outData)
    check(r.code == 0 && rs?.resumed == true && rs?.command == "codex resume --last", "doz sessions restart cr codex → codex resume --last (\(rs.map { "\($0.command), ended \($0.ended)" } ?? r.err.suffix(200).description))")
    let after = (t.json(["sessions", "cr", "--store", t.store.path], [SessionRow].self) ?? []).first { $0.name == "codex" }
    check(after?.pid != nil && after?.pid != before && after?.command == "codex resume --last", "the same session, a new pid running `codex resume --last` (\(after?.command ?? "?"))")
    usleep(5_000_000)
    a = tui("cr", "after the restart")
    check(a.answered && !a.invalidCwd, "cr after Restart session: answered again (\(a.tail.debugDescription))")
    r = d(["exec", "cr", "--", "sh", "-c", "find /home/agent/.codex/sessions -name 'rollout-*.jsonl' | wc -l"])
    check(r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "1",
          "the conversation CONTINUED: Codex still has one recorded session (a new conversation would be a second) (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    // a host restart (it hibernates every sandbox; a NEW host restores them on wake)
    _ = d(["host", "stop"], timeout: 300)
    check(startHostWithFake(), "a new host, with the fake OpenAI")
    check(d(["account", "add", "okey", "--openai-key", "--force"], stdin: key).code == 0, "the key again (this suite's keys live in the host's memory)")
    check(d(["wake", "cw"], timeout: 300).code == 0, "wake cw in the new host")
    a = tui("cw", "after the host restart")
    check(a.answered && !a.invalidCwd, "cw: after a host restart the same Codex is answered — no invalid cwd (\(a.tail.debugDescription))")
    // End session
    r = d(["sessions", "end", "cw", "codex", "--yes"], timeout: 60)
    check(r.code == 0 && r.out.contains("ended session codex in cw"), "doz sessions end cw codex (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    for name in ["cw", "cr"] { _ = d(["rm", name, "--yes"], timeout: 120) }
}

/// 608: drive a TUI through `doz attach` on a pseudo-terminal: argv[1] the prompt (sent as a bracketed paste, then
/// Enter — again after 8 s with nothing working, at most 3), argv[2] what to wait for, argv[3] seconds, the rest the
/// command. Prints RESULT=FOUND|TIMEOUT and the screen's last text (controls removed).
let cwdTUIDriver = #"""
import os, pty, sys, time, select, re, fcntl, termios, struct, signal
prompt, expect, secs, argv = sys.argv[1], sys.argv[2].encode(), float(sys.argv[3]), sys.argv[4:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
buf = b""; start = time.time(); sent = None; result = "TIMEOUT"; enters = 0
def read(t):
    global buf
    r, _, _ = select.select([fd], [], [], t)
    if r:
        try:
            d = os.read(fd, 65536)
        except OSError:
            return False
        if not d:
            return False
        buf += d
    return True
last_enter = 0
while time.time() - start < secs:
    if not read(0.3):
        break
    if sent is None and time.time() - start > 6:
        os.write(fd, b"\x1b[200~" + prompt.encode() + b"\x1b[201~"); time.sleep(1.5)
        os.write(fd, b"\r"); sent = len(buf); enters = 1; last_enter = time.time()
    if sent is not None and (expect in buf[sent:] or b"invalid cwd" in buf[sent:]):
        if expect in buf[sent:]:
            result = "FOUND"
        time.sleep(1.0); read(0.2)
        break
    if sent is not None and enters < 3 and time.time() - last_enter > 8 and b"orking" not in buf[sent:]:
        os.write(fd, b"\r"); enters += 1; last_enter = time.time()
try:
    os.kill(pid, signal.SIGTERM)
except OSError:
    pass
text = re.sub(rb"\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b.|[\x00-\x08\x0b-\x1f\x7f]", b" ", buf[sent or 0:])
text = re.sub(rb" +", b" ", text).decode("utf-8", "replace")
print(("invalid cwd " if b"invalid cwd" in buf else "") + "enters=%d " % enters + text[-600:])
print("RESULT=" + result)
"""#
