import Foundation
import DozerKit

// 580 — the proxied-network suite (`doz-vmtest network`): a claude-code image sandbox with NO
// network interface under the `agent` policy, then a bake under the `bake` policy. Everything the
// guest reaches goes through the library's EgressProxy; the checks read both sides (the guest's
// view and the proxy's log).

func netSpec(_ name: String, policy: NetworkPolicy, imageSpec: ImageSpec = AgentImages.claudeCode) -> SandboxSpec {
    SandboxSpec(name: name, storeRoot: storeRoot, kernelPath: kernelPath, kernelCacheDirectory: kernelCache,
                cpus: 2, memoryMiB: 2048, imageSpec: imageSpec, network: .proxied(policy))
}

/// Records added to `log` since `mark` (records are logged when a connection closes, a moment after
/// the guest command that made it has exited — so wait briefly first).
func since(_ log: ConnectionLog, _ mark: Set<UUID>) async -> [ConnectionRecord] {
    try? await Task.sleep(for: .milliseconds(400))
    return log.records.filter { !mark.contains($0.id) }
}
func mark(_ log: ConnectionLog) -> Set<UUID> { Set(log.records.map(\.id)) }

func networkSuite() async throws {
    let imageSpec = AgentImages.claudeCode
    let name = "net-agent"
    var sb = try Sandbox(spec: netSpec(name, policy: .agent))
    if await sb.phase != .off { try? await sb.shutDown() }
    try? await sb.delete()
    sb = try Sandbox(spec: netSpec(name, policy: .agent))
    guard let proxy = sb.egress else { check(false, "a proxied spec has an EgressProxy"); return }
    let log = proxy.log
    let ev = logEvents(sb, prefix: "[net] ")
    defer { ev.cancel() }

    print("vmtest[network]: image (cache hit or bake) and start, policy agent")
    _ = try await bakeImage(sb, imageSpec)
    let t0 = Date()
    try await sb.start()
    check(await sb.phase == .running, String(format: "proxied sandbox running (%.2f s)", Date().timeIntervalSince(t0)))
    func sh(_ s: String, env: [String: String] = [:], root: Bool = true, timeout: Int64 = 120) async throws -> ExecResult {
        let userEnv = root ? [:] : ["HOME": "/home/agent", "CLAUDE_CONFIG_DIR": "/home/agent/.claude"]
        return try await sb.exec(["sh", "-c", s], environment: userEnv.merging(env) { $1 }, privileged: root, user: root ? nil : "agent", timeoutSeconds: timeout)
    }

    let links = try await sh("ls /sys/class/net | tr '\\n' ' '")
    check(links.output.trimmingCharacters(in: .whitespaces) == "lo", "no network interface: /sys/class/net = \(links.output)")
    let shim = try await sh("\(EgressProxy.guestShimPath) status")
    check(shim.exitCode == 0, "doznet running (pid \(shim.output.trimmingCharacters(in: .whitespacesAndNewlines)))")

    // apt through the proxy (plain-HTTP registry allowed by the agent preset) — and curl for what follows.
    var m = mark(log)
    let apt = try await sh("apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl >/dev/null 2>&1; echo apt=$?; curl --version | head -1", timeout: 300)
    var rows = await since(log, m)
    check(apt.output.contains("apt=0") && apt.output.contains("curl "), "apt-get install curl through the proxy (\(Set(rows.filter { $0.kind != .dns }.map(\.target)).sorted().joined(separator: ", ")))")

    try await networkChecks(sb, log: log, phase: "running")

    // Credentials: a secret on the host, only a placeholder in the guest.
    print("vmtest[network]: credentials")
    let secret = realKey ?? sentinelKey
    sb.setCredential(.anthropic, secret: secret)
    let envOut = try await sh("env | grep -E '^(ANTHROPIC_API_KEY|HTTPS_PROXY|NODE_EXTRA_CA_CERTS)=' | sort", root: false)
    check(envOut.output.contains("ANTHROPIC_API_KEY=doz_cred_") && !envOut.output.contains(secret),
          "the guest environment has a placeholder, never the key (\(envOut.output.replacingOccurrences(of: "\n", with: " ").prefix(160)))")
    m = mark(log)
    let api = try await sh("curl -s -m 30 -o /dev/null -w '%{http_code}' -X POST https://api.anthropic.com/v1/messages -H \"x-api-key: $ANTHROPIC_API_KEY\" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' -d '{}'")
    rows = await since(log, m)
    let swapped = rows.first { $0.kind == .http && $0.host == "api.anthropic.com" }
    check(swapped?.credential == "swapped anthropic" && swapped?.decrypted == true,
          "curl with the placeholder → decrypted, placeholder swapped for the key on the Mac (HTTP \(api.output); \(swapped?.credential ?? "no record"))")
    check(api.output == (realKey == nil ? "401" : "400"), "the API judged the swapped key (\(realKey == nil ? "sentinel → 401" : "real key, empty body → 400"): \(api.output))")
    let noHeader = try await sh("curl -s -m 30 -o /dev/null -w '%{http_code}' https://api.anthropic.com/v1/models -H 'anthropic-version: 2023-06-01'")
    await sleepS(0.4)
    check(log.records.last { $0.path == "/v1/models" }?.credential == "injected anthropic", "no auth header → the proxy injects the key by host (HTTP \(noHeader.output))")

    // A second decrypted host, to prove the leak guard: the anthropic placeholder sent there → 403.
    var pol = proxy.policy
    pol.rules.insert(EgressRule(host: "api.github.com", note: "test"), at: 0)
    sb.setNetworkPolicy(pol)
    sb.setCredential(CredentialBinding(id: "github", hosts: ["api.github.com"], header: .bearer), secret: "ghp_not_a_real_token")
    m = mark(log)
    let wrong = try await sh("curl -s -m 30 -D - -o /dev/null https://api.github.com/user -H \"Authorization: Bearer $ANTHROPIC_API_KEY\" | tr -d '\\r' | grep -iE '^(HTTP/|x-sandbox-policy)' | tail -2")
    rows = await since(log, m)
    check(wrong.output.contains("403") && wrong.output.contains("X-Sandbox-Policy: credential")
          && rows.contains { $0.host == "api.github.com" && $0.credential?.hasPrefix("rejected") == true },
          "the anthropic placeholder sent to api.github.com → 403 from the proxy, logged (\(wrong.output.replacingOccurrences(of: "\n", with: " ")))")
    let own = try await sh("curl -s -m 30 -o /dev/null -w '%{http_code}' https://api.anthropic.com/v1/models -H 'x-api-key: sk-ant-tools-own-credential' -H 'anthropic-version: 2023-06-01'")
    await sleepS(0.4)
    // 588: untouched on the wire, but flagged — its kind and fingerprint, never its value.
    let ownRec = log.records.last { $0.path == "/v1/models" }?.credential
    check(own.output == "401" && ownRec?.hasPrefix("own credential (other") == true && ownRec?.contains("tools-own") == false,
          "a tool's own credential passes through untouched and is flagged (HTTP \(own.output); \(ownRec ?? "no verdict"))")

    // Claude Code with a placeholder-only environment.
    m = mark(log)
    let cc = try await sh("cd /workspace 2>/dev/null || cd /tmp; timeout -s KILL 100 claude -p 'Reply with exactly: pong' 2>&1 | head -c 300",
                          env: ["CLAUDE_CODE_MAX_RETRIES": "0", "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"], root: false, timeout: 130)
    rows = await since(log, m)
    let ccSwapped = rows.contains { $0.host == "api.anthropic.com" && $0.credential == "swapped anthropic" }
    if realKey != nil {
        check(cc.output.lowercased().contains("pong") && ccSwapped, "LIVE: Claude Code answered through the proxy with only a placeholder in its environment")
    } else {
        check(ccSwapped && cc.output.contains("401"), "Claude Code's requests carried the placeholder, swapped on the Mac (sentinel key → \(cc.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)))")
        print("  SKIP  LIVE Claude Code prompt — ANTHROPIC_API_KEY is not set")
    }
    // The key is nowhere in the guest.
    let grep = try await sh("for p in /proc/[0-9]*; do tr '\\0' '\\n' < $p/environ 2>/dev/null; done | grep -c -F '\(secret)'; grep -rIl -F '\(secret)' /etc /root /home /tmp /workspace /state /run /var/tmp 2>/dev/null | head -3; echo done")
    check(grep.output.hasPrefix("0\n") && grep.output.hasSuffix("done\n"), "the key is in no guest process environment and no guest file (\(grep.output.replacingOccurrences(of: "\n", with: " ")))")

    // Method + path rules (decrypted because of them; npm must trust the sandbox CA).
    print("vmtest[network]: method/path rules")
    pol = proxy.policy
    // Read-only registry: the GET/HEAD rule REPLACES the preset's plain allow (first match wins,
    // so an unconditional allow further down would still let DELETE through).
    pol.rules.removeAll { $0.host == "registry.npmjs.org" }
    pol.rules.insert(EgressRule(host: "registry.npmjs.org", methods: ["GET", "HEAD"], note: "read-only registry"), at: 0)
    sb.setNetworkPolicy(pol)
    m = mark(log)
    let npmView = try await sh("npm view is-number@7.0.0 version 2>&1 | tail -1", root: false)
    let del = try await sh("curl -s -m 30 -o /dev/null -w '%{http_code}' -X DELETE https://registry.npmjs.org/-/package/x/dist-tags/y")
    rows = await since(log, m)
    check(npmView.output.trimmingCharacters(in: .whitespacesAndNewlines) == "7.0.0" && rows.contains { $0.host == "registry.npmjs.org" && $0.decrypted && $0.method == "GET" },
          "GET through a decrypted registry works (npm trusts the sandbox CA via NODE_EXTRA_CA_CERTS): \(npmView.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    check(del.output == "403" && rows.contains { $0.method == "DELETE" && $0.verdict == .denied }, "DELETE to the same host → 403 by the method rule (HTTP \(del.output))")

    // Allow this host (the log's one-click action).
    pol = proxy.policy
    pol.allow(host: "example.com")
    sb.setNetworkPolicy(pol)
    let ex = try await sh("curl -s -m 30 -o /dev/null -w '%{http_code}' https://example.com/")
    check(ex.output == "200", "after allow(host: example.com) → HTTP \(ex.output)")
    sb.setNetworkPolicy(.agent)

    // Sleep to disk → wake.
    print("vmtest[network]: sleep to disk → wake")
    try await sb.hibernate()
    try await sb.wake()
    check(proxy.isListening, "the proxy listens again after the wake")
    try await networkChecks(sb, log: log, phase: "after wake")

    // Stop → Start (the kept root disk cold-boots; the shim and CA are set up again, once).
    print("vmtest[network]: stop → start")
    try await sb.shutDown()
    try await sb.start()
    let bundle = try await sh("grep -c -F \"$(sed -n 2p \(EgressProxy.guestCAPath))\" /etc/ssl/certs/ca-certificates.crt")
    check(bundle.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1", "the sandbox CA is in the system bundle exactly once after a cold boot")
    let again = try await sh("curl -s -m 30 -o /dev/null -w '%{http_code}' https://registry.npmjs.org/is-number; ls /sys/class/net | tr '\\n' ' '")
    check(again.output.hasPrefix("200") && again.output.hasSuffix("lo "), "after Stop → Start: still no NIC, still through the proxy (\(again.output))")

    // The log: metadata only, exportable.
    let jsonl = log.exportJSONLines()
    let parsed = ConnectionLog.parseJSONLines(jsonl)
    let text = String(decoding: jsonl, as: UTF8.self)
    check(!parsed.isEmpty && parsed.count == log.records.count && !text.contains(secret) && !text.contains("doz_cred_") && !parsed.contains { $0.path?.contains("?") == true },
          "the log exports as JSON lines (\(parsed.count) records, \(log.deniedCount) denied) with no key, placeholder or query string")
    try await sb.delete()

    try await networkCrashSuite()
    try await bakeSuite()
}

/// The child half: start a proxied sandbox, make sure it works, sleep it to disk, exit without stopping.
func networkCrashSave() async throws -> Int32 {
    let sb = try Sandbox(spec: netSpec("net-crash", policy: .agent))
    try await sb.start()
    let r = try await sb.exec(["sh", "-c", "getent hosts registry.npmjs.org >/dev/null && echo ok"], privileged: true)
    guard r.output.contains("ok") else { return 3 }
    // A session to find again, then QUIT the way an app does (prepareForExit from RUNNING = Hibernate).
    try await sb.openSession("hold", argv: ["sleep", "3600"])
    let pid = try await sb.sessions().first { $0.name == "hold" }?.pid ?? -1
    try "\(pid)".write(to: storeRoot.appendingPathComponent("net-crash-pid.txt"), atomically: true, encoding: .utf8)
    await sb.prepareForExit()
    return await sb.phase == .hibernated ? 0 : 4
}

/// Crash restore of a PROXIED sandbox: a new process adopts it, the proxy listens on the adopted
/// VM, the guest's shim (still running in the restored memory) reaches it, the policy still applies.
func networkCrashSuite() async throws {
    print("vmtest[network]: quit while RUNNING → relaunch: a child quits (prepareForExit = Hibernate), this process wakes it")
    let spec = netSpec("net-crash", policy: .agent)
    if Sandbox.restorableState(for: spec) != nil { Sandbox.discardRestorableState(for: spec) }
    try? await Sandbox(spec: spec).delete()
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    child.arguments = ["net-crash-save", "--store", storeRoot.path]
    try child.run()
    child.waitUntilExit()
    check(child.terminationStatus == 0 && Sandbox.restorableState(for: spec)?.phase == .hibernated,
          "quitting with the proxied sandbox RUNNING left it hibernated, not shut down (\(child.terminationStatus))")
    let sb = try Sandbox(spec: spec)
    let t0 = Date()
    try await sb.wake()
    check(await sb.phase == .running && sb.egress?.isListening == true,
          String(format: "restored into this process in %.2f s; the proxy listens on the adopted VM", Date().timeIntervalSince(t0)))
    let r = try await sb.exec(["sh", "-c", "ls /sys/class/net | tr '\\n' ' '; node -e \"require('https').get('https://registry.npmjs.org/is-number',{agent:new (require('https').Agent)()},r=>{console.log('status',r.statusCode)}).on('error',e=>console.log('err',e.code))\" ; getent hosts example.com || echo example-denied"],
                              privileged: true, timeoutSeconds: 60)
    let rows = sb.egress?.log.records ?? []
    check(r.output.hasPrefix("lo ") && r.output.contains("status 200") && r.output.contains("example-denied")
          && rows.contains { $0.host == "registry.npmjs.org" && $0.kind == .tcp && $0.verdict == .allowed },
          "after the restore: still only lo, redirected TCP to the registry allowed, example.com still denied (\(r.output.replacingOccurrences(of: "\n", with: " ")))")
    let pid = Int((try? String(contentsOf: storeRoot.appendingPathComponent("net-crash-pid.txt"), encoding: .utf8)) ?? "")
    let hold = try await sb.sessions().first { $0.name == "hold" }
    check(hold?.pid == pid && hold?.isEnded == false, "the session is still there with the same pid (\(pid.map(String.init) ?? "?"))")
    try await sb.shutDown()
    try await sb.delete()
}

/// Allowed and denied HTTPS, DNS, redirected TCP, UDP — run while running and again after a wake.
func networkChecks(_ sb: Sandbox, log: ConnectionLog, phase: String) async throws {
    func sh(_ s: String) async throws -> ExecResult { try await sb.exec(["sh", "-c", s], privileged: true, timeoutSeconds: 120) }
    var m = mark(log)
    let ok = try await sh("curl -s -m 30 -o /dev/null -w '%{http_code}' https://registry.npmjs.org/is-number")
    let denied = try await sh("curl -s -m 30 -o /dev/null -w '%{http_connect}' https://example.com/; echo \" exit=$?\"")
    var rows = await since(log, m)
    check(ok.output == "200", "[\(phase)] allowed host through the proxy: registry.npmjs.org → \(ok.output)")
    check(denied.output.hasPrefix("403") && rows.contains { $0.host == "example.com" && $0.kind == .connect && $0.verdict == .denied },
          "[\(phase)] denied host: example.com → CONNECT refused (\(denied.output)), logged as denied")
    m = mark(log)
    let dns = try await sh("getent hosts registry.npmjs.org | head -1; getent hosts example.com; echo \"denied=$?\"")
    rows = await since(log, m)
    check(dns.output.contains("registry.npmjs.org") && dns.output.contains("denied=2")
          && rows.contains { $0.kind == .dns && $0.host == "example.com" && $0.verdict == .denied },
          "[\(phase)] DNS answered on the Mac and gated: registry resolves, example.com does not (\(dns.output.replacingOccurrences(of: "\n", with: " ")))")
    m = mark(log)
    let raw = try await sh("curl -s -m 20 --noproxy '*' -o /dev/null -w '%{http_code}' https://registry.npmjs.org/is-number; echo; curl -s --noproxy '*' -m 5 -o /dev/null -w '%{http_code}' https://1.1.1.1/; echo \" exit=$?\"")
    rows = await since(log, m)
    check(raw.output.hasPrefix("200") && rows.contains { $0.kind == .tcp && $0.host == "registry.npmjs.org" && $0.verdict == .allowed }
          && rows.contains { $0.kind == .tcp && $0.host == "1.1.1.1" && $0.verdict == .denied },
          "[\(phase)] TCP that ignores the proxy is redirected and judged by name: registry allowed, a bare IP denied (\(raw.output.replacingOccurrences(of: "\n", with: " ")))")
    let udp = try await sb.exec(["node", "-e", """
        const d=require('dgram').createSocket('udp4');const t=Date.now();
        d.on('error',e=>{console.log('error '+e.code+' '+(Date.now()-t)+'ms');process.exit(0)});
        d.connect(53,'8.8.8.8',()=>{d.send(Buffer.from('x'),()=>{});d.on('message',()=>{console.log('REPLY');process.exit(0)});setTimeout(()=>{console.log('no reply '+(Date.now()-t)+'ms');process.exit(0)},3000)});
        """], timeoutSeconds: 30)
    check(!udp.output.contains("REPLY"), "[\(phase)] UDP (outside DNS, QUIC) is blocked: \(udp.output.trimmingCharacters(in: .whitespacesAndNewlines))")
}

/// A bake under the `bake` preset: the registry works, anything else is refused and logged.
func bakeSuite() async throws {
    print("vmtest[network]: a bake through the proxy (bake preset)")
    let imageSpec = ImageSpec(
        name: "nettest-bake", base: AgentImages.nodeBase,
        steps: [BakeStep.script("npm install from the registry", "npm install -g --no-audit --no-fund is-number@7.0.0 >/dev/null"),
                BakeStep.script("try to reach a non-registry host", "npm view x --registry https://example.com/ >/dev/null 2>&1 && exit 1 || true")],
        verify: [VerifyCheck(["sh", "-c", "ls /usr/local/lib/node_modules/is-number/package.json"], expect: "package.json")],
        user: "root", home: "/root", persistDirs: [])
    try? FileManager.default.removeItem(at: storeRoot.appendingPathComponent("images/nettest-bake"))
    let sb = try Sandbox(spec: netSpec("net-bake", policy: .agent, imageSpec: imageSpec))
    guard let log = sb.egress?.log else { check(false, "proxied spec"); return }
    let img = try await bakeImage(sb, imageSpec)
    check(FileManager.default.fileExists(atPath: img.root.path), "the bake finished through the proxy (npm install from the registry)")
    let rows = log.records
    check(rows.contains { $0.host == "registry.npmjs.org" && $0.verdict == .allowed }, "bake: registry.npmjs.org allowed")
    check(rows.contains { $0.host == "example.com" && $0.verdict == .denied }, "bake: example.com refused (the bake preset is registries only)")
    try? FileManager.default.removeItem(at: storeRoot.appendingPathComponent("images/nettest-bake"))
    try? await sb.delete()
}
