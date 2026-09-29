// `doz-vmtest claude --doz PATH` (588, `make test-vm-claude`): Claude credentials end to end
// with the REAL signed doz, a claude-code sandbox and its proxy — WITHOUT anyone's login. The
// sandbox uses an api-key ACCOUNT holding a FAKE key (`account add ct --api-key --no-verify` from
// stdin: doz writes its own keychain item `doz-anthropic:ct`, and the suite removes it), so
// every request that reaches api.anthropic.com is answered 401 by Anthropic; what the suite checks
// is the PROXY's verdict (net log, key ls, the status and body the guest gets):
//
//   classifier (allow): a guest bearer token and a guest x-api-key pass and are flagged with a
//     fingerprint — and our key is NOT injected beside them; our placeholder is swapped; an unknown
//     placeholder is refused; a bare request gets ours injected
//   strict: the same two are refused with an explanation (a JSON error Claude Code shows), the
//     sign-in hosts are denied, our placeholder still swaps
//   host restart (D8): a session's placeholder keeps working across `host stop` → wake
//   shutdown revokes (the persisted hashes are gone); no token anywhere in the store beyond a prefix
//
// With DOZ_TEST_CLAUDE_LOGIN=1 it also uses THIS Mac's Claude login read-only (never refreshed):
// the guest gets the plan (CLAUDE_CODE_SUBSCRIPTION_TYPE) and `claude -p` answers on Opus. Without
// it those lines SKIP. Inputs: --doz PATH, --store DIR (default $TMPDIR/doz-claudetest-store;
// the claude-code image is cloned from $DOZ_SEED_STORE or the vmtest store when it has one).
import Darwin
import Foundation
import DozerKit
import DozerHost

/// The guest half: five requests through the proxy with different credentials; one JSON line each.
let guestCredentialProbe = #"""
const http = require('http'), tls = require('tls'), fs = require('fs'), crypto = require('crypto');
const proxy = new URL(process.env.HTTPS_PROXY || 'http://127.0.0.1:3128');
const ca = fs.readFileSync('/etc/dozer/ca.pem');
const rnd = n => crypto.randomBytes(n * 2).toString('base64').replace(/[^A-Za-z0-9]/g, '').slice(0, n);
const body = JSON.stringify({ model: 'claude-haiku-4-5', max_tokens: 1, messages: [{ role: 'user', content: 'hi' }] });
function send(label, host, headers) {
  return new Promise(res => {
    const req = http.request({ host: proxy.hostname, port: proxy.port, method: 'CONNECT', path: host + ':443' });
    req.on('connect', (r, sock) => {
      if (r.statusCode !== 200) { console.log(JSON.stringify({ label, status: r.statusCode, body: 'CONNECT refused' })); sock.destroy(); return res(); }
      const t = tls.connect({ socket: sock, servername: host, ca }, () => {
        const h = Object.entries({ Host: host, 'content-type': 'application/json', 'anthropic-version': '2023-06-01',
          'content-length': Buffer.byteLength(body), connection: 'close', ...headers }).map(([k, v]) => `${k}: ${v}`).join('\r\n');
        t.write(`POST /v1/messages HTTP/1.1\r\n${h}\r\n\r\n${body}`);
      });
      let out = ''; t.on('data', d => out += d);
      t.on('error', e => { console.log(JSON.stringify({ label, status: -1, body: e.message })); res(); });
      t.on('end', () => { const [head, ...rest] = out.split('\r\n\r\n');
        console.log(JSON.stringify({ label, status: +(head.split(' ')[1] || 0), body: rest.join('').replace(/\s+/g, ' ').slice(0, 400) })); res(); });
    });
    req.on('error', e => { console.log(JSON.stringify({ label, status: -2, body: e.message })); res(); });
    req.end();
  });
}
(async () => {
  const only = process.argv[2];
  const cases = [
    ['foreign-oauth', 'api.anthropic.com', { Authorization: 'Bearer sk-ant-oat01-' + rnd(95) + 'AA' }],
    ['foreign-key', 'api.anthropic.com', { 'x-api-key': 'sk-ant-api03-' + rnd(95) + 'AA' }],
    ['ours', 'api.anthropic.com', { 'x-api-key': process.env.ANTHROPIC_API_KEY || '' }],
    ['unknown', 'api.anthropic.com', { 'x-api-key': 'doz_cred_' + crypto.randomBytes(24).toString('hex') }],
    ['bare', 'api.anthropic.com', {}],
    ['signin', 'platform.claude.com', {}],
  ];
  for (const [l, h, hd] of cases) if (!only || only === l) await send(l, h, hd);
})();
"""#

struct ProbeLine: Decodable { var label: String; var status: Int; var body: String }

func claudeSuite() async throws {
    let binary: String = {
        if let i = args.firstIndex(of: "--doz"), i + 1 < args.count { return args[i + 1] }
        return ".build/debug/doz"
    }()
    let h = CLIHarness(binary: URL(fileURLWithPath: binary).standardizedFileURL.path, store: storeRoot)
    try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
    seedImages(into: storeRoot)
    info("doz \(h.binary) · store \(storeRoot.path)")
    let name = "clx"
    func cleanUp() {
        h.run(["rm", name, "--yes"])
        h.run(["account", "rm", "ct", "--force"])
        h.run(["rm", "cly", "--yes"])
        h.run(["host", "stop"])
    }
    if h.hostRunning { h.run(["host", "stop"]) }
    for n in [name, "cly"] where FileManager.default.fileExists(atPath: DozerStore(root: storeRoot).configFile(n).path) { h.run(["rm", n, "--yes"]) }

    func probe(_ only: String? = nil, env: [String] = []) -> [String: ProbeLine] {
        var argv = ["exec", name]
        for e in env { argv += ["--env", e] }
        argv += ["--", "node", "/tmp/doz-credprobe.js"] + (only.map { [$0] } ?? [])
        let r = h.run(argv, timeout: 120)
        var out: [String: ProbeLine] = [:]
        for l in r.out.split(separator: "\n") {
            if let p = try? JSONDecoder().decode(ProbeLine.self, from: Data(l.utf8)) { out[p.label] = p }
        }
        return out
    }
    func log() -> [ConnectionRecord] { h.json(["net", "log", name], [ConnectionRecord].self) ?? [] }
    /// The newest /v1/messages record's credential verdict after `since`.
    func verdicts(since: Date) -> [String] {
        log().filter { $0.time >= since && $0.path == "/v1/messages" }.sorted { $0.time < $1.time }.map { $0.credential ?? "none" }
    }

    do {
        try Task.checkCancellation()
        print("claude: a claude-code sandbox holding a FAKE key (nobody's login)")
        var r = h.run(["account", "default", "none"])
        check(r.code == 0, "account default none (this store never reads the Mac's login unless asked)")
        r = h.run(["create", name, "--image", "claude-code", "--account", "none"])
        check(r.code == 0, "create \(name) --image claude-code --account none")
        let fake = "sk-ant-api03-FAKE-doz-claudetest-" + String(repeating: "0", count: 60)
        r = h.run(["account", "add", "ct", "--api-key", "--no-verify", "--force"], stdin: Data((fake + "\n").utf8))
        check(r.code == 0, "account add ct --api-key --no-verify < stdin (a fake key → the keychain item doz-anthropic:ct)")
        let rows = h.json(["account", "ls"], [AccountRow].self) ?? []
        let accountsText = (try? String(contentsOf: storeRoot.appendingPathComponent("accounts.json"), encoding: .utf8)) ?? ""
        check(rows.first { $0.name == "ct" }?.state == "ok" && !accountsText.isEmpty && !accountsText.contains("FAKE"),
              "account ls: ct ok; accounts.json holds no secret")
        r = h.run(["account", "use", name, "ct"])
        check(r.code == 0, "account use \(name) ct")
        check(h.row(name)?.credentialPolicy == "strict", "an api-key account makes the sandbox strict by default (auto)")
        r = h.run(["key", "policy", name, "allow"])
        check(r.code == 0, "key policy \(name) allow")
        r = h.run(["start", name], timeout: 900)
        check(r.code == 0, "start (exit \(r.code))")
        let b64 = Data(guestCredentialProbe.utf8).base64EncodedString()
        r = h.run(["exec", name, "--", "sh", "-c", "echo \(b64) | base64 -d > /tmp/doz-credprobe.js && echo ok"])
        check(r.out == "ok\n", "the guest probe is in place")

        print("claude: classifier (allow)")
        var t0 = Date()
        var p = probe()
        var v = log().filter { $0.time >= t0 && $0.kind == .http }
        let fo = v.first { $0.credential?.contains("own credential (oauth") == true }
        let fk = v.first { $0.credential?.contains("own credential (api-key") == true }
        check(p["foreign-oauth"]?.status == 401 && fo != nil, "a guest bearer token passes (Anthropic says 401) and is flagged: \(fo?.credential ?? "no record")")
        check(p["foreign-key"]?.status == 401 && fk != nil && !(p["foreign-key"]?.body.contains("doz") ?? true),
              "a guest x-api-key passes and is flagged: \(fk?.credential ?? "no record")")
        check(v.filter { $0.path == "/v1/messages" && $0.credential == "injected anthropic" }.count == 1,
              "our key was injected only into the bare request — never beside the guest's own x-api-key or bearer (acceptance 4)")
        check(v.filter { $0.credential?.hasPrefix("swapped anthropic") == true }.count == 1, "our placeholder is swapped")
        check(p["unknown"]?.status == 403 && p["unknown"]?.body.contains("unknown or revoked") == true, "an unknown placeholder is refused 403")
        check(v.contains { $0.credential == "injected anthropic" }, "a bare request gets our key injected")
        check(p["signin"] != nil && p["signin"]?.body != "CONNECT refused",
              "allow: the sign-in host is reachable (a tunnel, not decrypted: \(p["signin"]?.body.prefix(40) ?? "?"))")
        let keys = h.json(["key", "ls", name], [CredentialRow].self) ?? []
        let foreign = keys.flatMap { $0.foreign ?? [] }
        check(foreign.count == 2 && foreign.allSatisfy { $0.fingerprint.count == 12 && $0.fingerprint.allSatisfy(\.isHexDigit) },
              "key ls: 2 sightings, 12-hex fingerprints (\(foreign.map { "\($0.kind) \($0.prefix)… \($0.fingerprint)" }.joined(separator: ", ")))")
        check(h.row(name)?.foreignCredentials == 2 && h.run(["ls"]).out.contains("own key"), "ls: the sandbox is marked (own key ×2)")
        let ev = h.run(["key", "ls", name]).out
        check(ev.contains("the guest used its own credential"), "key ls lists the sightings")

        print("claude: strict")
        r = h.run(["key", "policy", name, "strict"])
        check(r.code == 0, "key policy \(name) strict")
        t0 = Date()
        p = probe()
        v = log().filter { $0.time >= t0 && $0.kind == .http }
        for c in ["foreign-oauth", "foreign-key"] {
            let body = p[c]?.body ?? ""
            let json = body.range(of: "{").map { String(body[$0.lowerBound...]) } ?? ""
            let msg = ((try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
            check(p[c]?.status == 403 && msg?.hasPrefix("doz: \(name) is pinned to") == true && msg?.contains("doz key policy \(name) allow") == true,
                  "strict: \(c) refused 403 with an explanation (\(msg?.prefix(90) ?? "no JSON message")…)")
        }
        check(v.contains { $0.credential?.hasPrefix("swapped anthropic") == true }, "strict: our placeholder still swaps")
        check(p["signin"]?.status == 403 || p["signin"]?.body == "CONNECT refused", "strict: the sign-in host is denied (\(p["signin"]?.status ?? 0))")
        // Claude Code shows the refusal.
        // (Made in the guest: a real-looking key handed to exec would be moved into the vault.)
        let cc = h.run(["exec", name, "--", "sh", "-c",
                        "cd && ANTHROPIC_API_KEY=sk-ant-api03-$(head -c 90 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 90) timeout 90 /usr/local/bin/claude -p hi --output-format json 2>/dev/null"],
                       timeout: 150)
        check(cc.out.contains("doz: \(name) is pinned to"), "Claude Code in the guest shows the refusal: \(cc.out.range(of: "doz: ").map { String(cc.out[$0.lowerBound...].prefix(80)) } ?? cc.out.suffix(120).description)")
        _ = h.run(["key", "policy", name, "allow"])

        print("claude: a session's placeholder across a host restart (D8)")
        r = h.run(["run", name, "-d", "--session", "loop", "--", "sh", "-c",
                   "while true; do node /tmp/doz-credprobe.js ours >> /tmp/loop.log; sleep 2; done"])
        check(r.code == 0, "a looping session sends its placeholder every 2 s")
        usleep(6_000_000)
        r = h.run(["host", "stop"])
        check(r.code == 0 && !h.hostRunning, "host stop (the sandbox hibernates with the session)")
        r = h.run(["wake", name])
        check(r.code == 0, "wake in a NEW host")
        usleep(9_000_000)
        let lines = h.run(["exec", name, "--", "sh", "-c", "tail -3 /tmp/loop.log"]).out.split(separator: "\n")
            .compactMap { try? JSONDecoder().decode(ProbeLine.self, from: Data($0.utf8)) }
        check(!lines.isEmpty && lines.allSatisfy { $0.status == 401 && !$0.body.contains("sandbox proxy") && !$0.body.contains("doz:") },
              "after the restart the old placeholder is still swapped (upstream 401 for the fake key, not the proxy's 403): \(lines.map { "\($0.status)" }.joined(separator: " "))")
        let cfg = SandboxConfig.read(DozerStore(root: storeRoot).configFile(name))
        check((cfg?.placeholderHashes?.count ?? 0) > 0, "doz.json holds placeholder hashes (\(cfg?.placeholderHashes?.count ?? 0))")
        // The same session, its credential taken away and given back: it recovers without a restart.
        func loopTail() -> [ProbeLine] {
            h.run(["exec", name, "--", "sh", "-c", "tail -2 /tmp/loop.log"]).out.split(separator: "\n")
                .compactMap { try? JSONDecoder().decode(ProbeLine.self, from: Data($0.utf8)) }
        }
        r = h.run(["account", "use", name, "none"])
        usleep(5_000_000)
        let off = loopTail()
        check(r.code == 0 && !off.isEmpty && off.allSatisfy { $0.status == 401 && $0.body.contains("doz: \(name) has no Anthropic account now") },
              "account use none mid-session: the proxy answers 401 with why (\(off.map { "\($0.status)" }.joined(separator: " ")))")
        r = h.run(["account", "use", name, "ct"])
        usleep(5_000_000)
        let back = loopTail()
        check(r.code == 0 && !back.isEmpty && back.allSatisfy { $0.status == 401 && !$0.body.contains("sandbox proxy") && !$0.body.contains("doz:") },
              "account use ct again: the SAME session is swapped again, no restart (\(back.map { "\($0.status)" }.joined(separator: " ")))")
        _ = h.run(["exec", name, "--", "sh", "-c", "for p in /proc/[0-9]*; do case \"$(tr '\\0' ' ' < $p/cmdline 2>/dev/null)\" in *'while'' true; do node'*) ;; *'while true; do node'*) kill ${p#/proc/};; esac; done"])

        print("claude: the Mac login (DOZ_TEST_CLAUDE_LOGIN=1 — read-only, never refreshed)")
        if ProcessInfo.processInfo.environment["DOZ_TEST_CLAUDE_LOGIN"] == "1" {
            r = h.run(["account", "use", name, "mac"])
            check(r.code == 0, "account use \(name) mac")
            let env = h.run(["exec", name, "--", "sh", "-c", "echo $CLAUDE_CODE_SUBSCRIPTION_TYPE/${CLAUDE_CODE_OAUTH_TOKEN%%_*}_/${ANTHROPIC_API_KEY:-none}"]).out
            check(env.hasPrefix("max/doz_") || env.hasPrefix("pro/doz_") || env.hasPrefix("team/doz_") || env.hasPrefix("enterprise/doz_"),
                  "the guest gets the plan and a placeholder, no API key: \(env.trimmingCharacters(in: .whitespacesAndNewlines))")
            let cp = h.run(["exec", name, "--", "sh", "-c", "cd && timeout 120 claude -p 'Reply with exactly OK' --output-format json 2>/dev/null"], timeout: 180)
            check(cp.out.contains("\"result\":\"OK\"") && cp.out.contains("claude-opus"), "claude -p answers on Opus (\(cp.out.range(of: "claude-opus").map { String(cp.out[$0.lowerBound...].prefix(24)) } ?? "no opus"))")
            let st = (h.json(["key", "ls", name], [CredentialRow].self) ?? []).first { $0.account == "mac" }
            check(st?.state == "ok" || st?.state == "expires-soon", "key ls: mac \(st?.state ?? "?")")
            _ = h.run(["account", "use", name, "none"])
        } else {
            print("  SKIP  the guest gets the plan; claude -p on Opus (set DOZ_TEST_CLAUDE_LOGIN=1 to use this Mac's login)")
        }

        print("claude: shutdown revokes; nothing secret on disk")
        r = h.run(["shutdown", name, "--yes"])
        check(r.code == 0, "shutdown")
        let after = SandboxConfig.read(DozerStore(root: storeRoot).configFile(name))
        check(after?.placeholderHashes == nil, "shutdown revoked the placeholders (no hashes left)")
        let leaks = scanForTokens(storeRoot)
        check(leaks.isEmpty, "no token in the store's files, logs or metrics beyond a 13-char prefix\(leaks.isEmpty ? "" : ": \(leaks.prefix(3))")")
    } catch {
        check(false, "aborted: \(error)")
    }
    cleanUp()
    check(!h.hostRunning, "cleanup: no host left running")
    check(SystemKeychain().read(service: "doz-anthropic:ct", account: nil) == .absent, "cleanup: the keychain item doz-anthropic:ct is gone")
}

/// Clone (APFS) the kernel, golden disks and baked images from a store that has them, so this
/// suite does not bake claude-code again. Never touches the source.
func seedImages(into store: URL) {
    let fm = FileManager.default
    let candidates = [ProcessInfo.processInfo.environment["DOZ_SEED_STORE"],
                      NSTemporaryDirectory() + "doz-vmtest-store"].compactMap { $0 }
    guard !fm.fileExists(atPath: store.appendingPathComponent("images/claude-code").path),
          let src = candidates.first(where: { fm.fileExists(atPath: $0 + "/images/claude-code") }) else { return }
    for item in ["kernels", "golden", "images", "content", "initfs.ext4"] where !fm.fileExists(atPath: store.appendingPathComponent(item).path) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/cp")
        p.arguments = ["-cR", src + "/" + item, store.path + "/"]
        try? p.run()
        p.waitUntilExit()
    }
    info("seeded images from \(src) (APFS clones)")
}

/// Every `sk-ant-…` in the store's text files longer than a 13-character prefix (disk images skipped).
func scanForTokens(_ root: URL) -> [String] {
    var out: [String] = []
    let re = try! NSRegularExpression(pattern: "sk-ant-[a-z]{3,5}[0-9]{2}-[A-Za-z0-9_-]{4,}")
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
    for case let u as URL in e {
        let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size < 64 << 20, !u.path.contains("/images/"), !u.path.contains("/golden/"), !u.path.contains("/kernels/"),
              !u.path.contains("/content/"), !u.lastPathComponent.hasSuffix(".ext4"), !u.lastPathComponent.hasSuffix(".img"),
              let d = try? Data(contentsOf: u) else { continue }
        let s = String(decoding: d, as: UTF8.self)
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            out.append("\(u.lastPathComponent): \(String(s[Range(m.range, in: s)!].prefix(16)))…")
        }
    }
    return out
}
