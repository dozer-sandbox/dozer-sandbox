import Foundation
import XCTest
@testable import DozerKit

/// 617: the recipe agents in the library — the built-in recipes describe their Swift images truthfully, a recipe agent
/// composes on every base, its launcher, its permissions (D5, excluded hosts, update:<id>), its key binding and the
/// proxy's refusal shapes. No VM, no network.
final class RecipeAgentsTests: XCTestCase {
    let release = AgentRelease(version: "1.2.3", integrity: "sha512-AAAA")

    func script(_ s: ImageSpec) -> String { s.steps.map { $0.argv.joined(separator: " ") }.joined(separator: "\n") }

    // MARK: RecipeTruthTests — the built-in three's recipes against their Swift images

    func test_builtinRecipesDescribeTheirImages() throws {
        let pins: [String: AgentRelease] = ["claude-code": AgentImages.claudeCodePinned, "pi": AgentImages.piPinned, "codex": AgentImages.codexPinned]
        for (id, pin) in pins {
            let r = try XCTUnwrap(AgentRecipes.recipe(id))
            XCTAssertTrue(r.isBuiltin)
            XCTAssertEqual(r.pinnedRelease, pin, "\(id): the recipe's pin is AgentImages'")
            let a = try XCTUnwrap(AgentKind(rawValue: id))
            let native = NativeClaudeBuild(version: pin.version, sha256: ["linux-arm64": String(repeating: "a", count: 64), "linux-arm64-musl": String(repeating: "b", count: 64)])
            for b in BaseCatalogue.all {
                let s = try ImageComposer.spec(name: ImageChoice(base: b.id, agent: a).name, base: b.source(), agent: a, release: pin, native: native)
                XCTAssertEqual(s.persistDirs, r.state.persist, "\(id) on \(b.id): persist")
                for (k, v) in r.state.env { XCTAssertEqual(s.sessionEnvironment[k], v, "\(id) on \(b.id): \(k)") }
                XCTAssertEqual(s.agent?.package, r.install.package, "\(id) on \(b.id): package")
                XCTAssertNil(s.agent?.integrity, "\(id): the built-in images carry no integrity field (bake keys unchanged)")
                let first = try XCTUnwrap(r.verifyChecks(version: pin.version).first)
                XCTAssertTrue(s.verify.contains(first), "\(id) on \(b.id): verify \(first.argv)")
            }
            XCTAssertEqual(AgentKind(rawValue: id)?.title, r.title)
        }
        // Codex's model permission is the recipe's hosts; Claude Code's and pi's update hosts are "Update itself"'s.
        let codexModel = try XCTUnwrap(AgentPermissions.permission(AgentPermissions.openAIModel))
        XCTAssertEqual(codexModel.hosts.map(\.host), AgentRecipes.recipe("codex")?.network.model.hosts?.map(\.host))
        let update = try XCTUnwrap(AgentPermissions.permission("update"))
        for id in ["claude-code", "pi"] {
            for h in AgentRecipes.recipe(id)!.network.update {
                XCTAssertTrue(update.hosts.contains { $0.host == h.host && $0.pathPrefixes.map { Set($0).isSuperset(of: h.paths ?? []) } ?? (h.paths == nil) }, "\(id): \(h.host)")
            }
        }
    }

    // MARK: composing

    func test_geminiComposesOnEveryKindOfBase() throws {
        let g = try XCTUnwrap(AgentKind(rawValue: "gemini"))
        let node = try ImageComposer.spec(name: "gemini", base: BaseCatalogue.base("node")!.source(), agent: g, release: release, native: nil)
        XCTAssertTrue(script(node).contains("npm pack --silent '@google/gemini-cli@1.2.3'"))
        XCTAssertTrue(script(node).contains("npm install -g --no-fund --no-audit --ignore-scripts"))
        XCTAssertFalse(script(node).contains("/opt/node"), "Node's own on the Node base")
        XCTAssertNil(node.bakeHosts)
        XCTAssertEqual(node.agent, AgentPackage(package: "@google/gemini-cli", version: "1.2.3", integrity: "sha512-AAAA"))
        XCTAssertEqual(node.persistDirs, ["~/.gemini"])
        XCTAssertTrue(node.verify.contains(VerifyCheck(["gemini", "--version"], expect: "1.2.3")))
        let debian = try ImageComposer.spec(name: "debian-gemini", base: BaseCatalogue.base("debian")!.source(), agent: g, release: release, native: nil)
        XCTAssertTrue(script(debian).contains(NodeRuntime.sha256), "Node's checksum-verified tarball")
        XCTAssertTrue(script(debian).contains("PATH=/opt/node/bin:$PATH exec /opt/node/bin/gemini"))
        XCTAssertEqual(debian.bakeHosts, ["nodejs.org"])
        XCTAssertFalse(debian.sessionEnvironment["PATH"]!.contains("/opt/node"), "Node is the agent's, not the sessions'")
        let alpine = try ImageComposer.spec(name: "alpine-gemini", base: BaseCatalogue.base("alpine")!.source(), agent: g, release: release, native: nil)
        XCTAssertTrue(script(alpine).contains("apk add nodejs npm"))
        XCTAssertNil(alpine.bakeHosts)
        let df = BaseSource(reference: "dozer.local/df-0123456789ab@sha256:" + String(repeating: "c", count: 64), packageManager: .auto,
                            hasNode: false, musl: nil, rootfsMiB: 4096)
        let d = try ImageComposer.spec(name: "df-0123456789ab-gemini", base: df, agent: g, release: release, native: nil)
        XCTAssertTrue(script(d).contains("if command -v apk"))
        for s in [node, debian, alpine, d] {
            XCTAssertNoThrow(try s.validate())
            XCTAssertEqual(ImageComposer.recompose(s), s, "\(s.name): this build's recipe")
        }
    }

    func test_grokComposesFromThePlatformPackage() throws {
        let k = try XCTUnwrap(AgentKind(rawValue: "grok"))
        XCTAssertEqual(ImageChoice(base: "debian", agent: k).name, "grok", "D9: Grok's default base is Debian")
        let debian = try ImageComposer.spec(name: "grok", base: BaseCatalogue.base("debian")!.source(), agent: k, release: release, native: nil)
        let s = script(debian)
        XCTAssertTrue(s.contains("https://registry.npmjs.org/@xai-official/grok-linux-arm64/-/grok-linux-arm64-1.2.3.tgz"))
        XCTAssertTrue(s.contains("[ \"$got\" = 'sha512-AAAA' ]"), "the integrity is checked in the bake (and so in the key)")
        XCTAssertTrue(s.contains("apt-get install -y --no-install-recommends -o Dpkg::Use-Pty=0 brotli"))
        XCTAssertTrue(s.contains("brotli -d -f -o \"$dst\" \"$src\""))
        XCTAssertTrue(s.contains("src=package/bin/grok.br"))
        XCTAssertTrue(s.contains("ln -sf \"$dst\" /usr/local/bin/grok"))
        XCTAssertEqual(debian.agent, AgentPackage(package: "@xai-official/grok", version: "1.2.3", integrity: "sha512-AAAA"))
        XCTAssertEqual(debian.sessionEnvironment["GROK_HOME"], "/home/agent/.grok")
        XCTAssertNil(debian.bakeHosts, "the npm registry is in the bake preset")
        XCTAssertEqual(AgentImages.spec("grok", release: release), debian)
        let node = try ImageComposer.spec(name: "node-grok", base: BaseCatalogue.base("node")!.source(), agent: k, release: release, native: nil)
        XCTAssertTrue(script(node).contains("brotliDecompressSync"), "Node's zlib where the base has Node")
        let alpine = try ImageComposer.spec(name: "alpine-grok", base: BaseCatalogue.base("alpine")!.source(), agent: k, release: release, native: nil)
        XCTAssertTrue(script(alpine).contains("apk add brotli"), "a static binary: Alpine too (617.01)")
        for x in [debian, node, alpine] { XCTAssertEqual(ImageComposer.recompose(x), x) }
        // A recipe agent's integrity is recorded, so the store reads its release back from the spec.
        XCTAssertEqual(AgentImages.pinned("grok"), AgentRecipes.recipe("grok")?.pinnedRelease)
    }

    func test_aMuslBaseIsRefusedWhenTheRecipeHasNoMuslBuild() throws {
        var r = try XCTUnwrap(AgentRecipes.recipe("gemini"))
        r.id = "nomusl"; r.aliases = nil; r.platforms.musl = false
        r.network.model.id = "model:nomusl"
        r.install.binary = "gemini"
        try AgentRecipes.registerForTests(r)
        defer { AgentRecipes.unregisterForTests("nomusl") }
        let a = try XCTUnwrap(AgentKind(rawValue: "nomusl"))
        XCTAssertThrowsError(try ImageComposer.spec(name: "alpine-nomusl", base: BaseCatalogue.base("alpine")!.source(), agent: a, release: release, native: nil)) {
            XCTAssertTrue("\($0)".contains("has no musl build"), "\($0)")
        }
        let df = BaseSource(reference: "dozer.local/df-0123456789ab@sha256:" + String(repeating: "c", count: 64), packageManager: .auto,
                            hasNode: false, musl: nil, rootfsMiB: 4096)
        let d = try ImageComposer.spec(name: "df-0123456789ab-nomusl", base: df, agent: a, release: release, native: nil)
        XCTAssertTrue(script(d).contains("ld-musl-aarch64.so.1"), "a Dockerfile's base: checked in the bake")
    }

    // MARK: the launcher

    func test_theLaunchersSkipPromptsUnlessAskedAndNameNoCredential() throws {
        for (id, flag) in [("gemini", "'--approval-mode=yolo'"), ("grok", "'--always-approve'")] {
            let r = try XCTUnwrap(AgentRecipes.recipe(id))
            let text = AgentImages.recipeLauncherScript(r)
            XCTAssertTrue(text.contains("[ \"${\(r.permissionsVariable):-skip}\" = ask ] && mode=ask"), id)
            XCTAssertTrue(text.contains("[ \"$(id -u)\" = 0 ] && mode=ask"), "\(id): root keeps the prompts")
            XCTAssertTrue(text.contains("[ \"$mode\" = skip ] && set -- \(flag) \"$@\""), id)
            XCTAssertTrue(text.contains("--version|"), "\(id): --version runs as it is")
            for v in ["API_KEY", "TOKEN", "SECRET", "XAI_", "GEMINI_API"] { XCTAssertFalse(text.contains(v), "\(id): the launcher names no credential (\(v))") }
        }
        XCTAssertTrue(AgentImages.recipeLauncherScript(AgentRecipes.recipe("gemini")!).contains("export GEMINI_CLI_TRUST_WORKSPACE='true'"))
        XCTAssertTrue(AgentImages.recipeLauncherScript(AgentRecipes.recipe("grok")!).contains("export GROK_DISABLE_AUTOUPDATER='1'"))
    }

    /// The launcher, run as a shell script on this Mac (its echo branch): the flag only in skip mode, never for a
    /// passthrough argument.
    func test_theLauncherRuns() throws {
        let r = try XCTUnwrap(AgentRecipes.recipe("grok"))
        let full = AgentImages.recipeLauncherScript(r)
        let start = try XCTUnwrap(full.range(of: "<<'SH'\n")), end = try XCTUnwrap(full.range(of: "\nSH\n", range: start.upperBound..<full.endIndex))
        let launcher = String(full[start.upperBound..<end.lowerBound])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("grok")
        try launcher.write(to: f, atomically: true, encoding: .utf8)
        func run(_ args: [String], _ env: [String: String]) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [f.path] + args
            p.environment = ["PATH": "/usr/bin:/bin", "HOME": dir.path, "DOZ_GROK_LAUNCHER_ECHO": "1"].merging(env) { _, b in b }
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        XCTAssertEqual(try run(["-p", "hi"], [:]), "/usr/local/bin/grok\n--always-approve\n-p\nhi\n")
        XCTAssertEqual(try run(["-p", "hi"], ["DOZ_GROK_PERMISSIONS": "ask"]), "/usr/local/bin/grok\n-p\nhi\n")
    }

    /// The first-run helper sets only absent keys (a person's own value is kept), atomically, 0600.
    func test_firstRunSettingsAreMergedAbsentKeysOnly() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("no python3") }
        let r = try XCTUnwrap(AgentRecipes.recipe("gemini"))
        let py = AgentImages.recipeSetupPython(r.launch.firstRun!)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("firstrun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".gemini/settings.json")
        try Data(#"{"general": {"enableAutoUpdate": true}, "theme": "dark"}"#.utf8).write(to: settings)
        let script = home.appendingPathComponent("setup.py")
        try py.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script.path]
        p.environment = ["HOME": home.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual((o["general"] as? [String: Any])?["enableAutoUpdate"] as? Bool, true, "the person's own value is kept")
        XCTAssertEqual((o["general"] as? [String: Any])?["enableAutoUpdateNotification"] as? Bool, false)
        XCTAssertEqual((o["privacy"] as? [String: Any])?["usageStatisticsEnabled"] as? Bool, false)
        XCTAssertEqual(((o["security"] as? [String: Any])?["auth"] as? [String: Any])?["selectedType"] as? String, "gemini-api-key")
        XCTAssertEqual(o["theme"] as? String, "dark")
        let mode = try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    // MARK: permissions (D5, D4, excluded hosts)

    func test_recipeAgentsReachOnlyTheirOwnModel() throws {
        let grok = try XCTUnwrap(AgentKind(rawValue: "grok")), gemini = try XCTUnwrap(AgentKind(rawValue: "gemini"))
        XCTAssertEqual(AgentPermissions.agentPermissions(grok), ["model:xai"])
        XCTAssertEqual(AgentPermissions.agentPermissions(gemini), ["model:google", "update:gemini"])
        // D5: Locked = only the agent's own model; no Anthropic model in any preset of theirs.
        XCTAssertEqual(AgentPermissions.preset("locked", base: "debian", agent: grok), [])
        XCTAssertEqual(AgentPermissions.preset("locked", base: "node", agent: .claudeCode), ["model"], "the built-in three: unchanged")
        XCTAssertEqual(AgentPermissions.preset("locked", base: "node", agent: .codex), ["model"])
        let locked = AgentPermissions.normalized((AgentPermissions.preset("locked", base: "debian") ?? []) + AgentPermissions.agentPermissions(grok))
        XCTAssertEqual(locked, ["model:xai"])
        XCTAssertEqual(AgentPermissions.presetName(locked, base: "debian"), "locked")
        let standard = AgentPermissions.normalized((AgentPermissions.preset("agent", base: "node") ?? []) + AgentPermissions.agentPermissions(gemini))
        XCTAssertFalse(standard.contains("model"))
        XCTAssertEqual(AgentPermissions.presetName(standard, base: "node"), "agent")
        let open = AgentPermissions.normalized((AgentPermissions.preset("open", base: "debian") ?? []) + AgentPermissions.agentPermissions(grok))
        XCTAssertEqual(AgentPermissions.presetName(open, base: "debian"), "open")
        // Never in another agent's presets, never suggested.
        for p in ["locked", "agent", "open"] { XCTAssertFalse(AgentPermissions.preset(p, base: "node")!.contains { $0.hasPrefix("model:") || $0.hasPrefix("update:") }) }
        XCTAssertNil(AgentPermissions.permission(forHost: "api.x.ai"))
        XCTAssertNil(AgentPermissions.permission(forHost: "generativelanguage.googleapis.com"))
        // The path-conditioned xAI model: the API paths Grok uses, nothing else.
        let policy = NetworkPolicy.permissions(locked)
        XCTAssertEqual(policy.evaluate(host: "api.x.ai", port: 443, method: "POST", path: "/v1/chat/completions").action, .allow)
        XCTAssertEqual(policy.evaluate(host: "api.x.ai", port: 443, method: "GET", path: "/v1/api-key").action, .allow)
        // The VM proof: against the real base Grok Build 1.0.50 sends its turns to the Responses API.
        XCTAssertEqual(policy.evaluate(host: "api.x.ai", port: 443, method: "POST", path: "/v1/responses").action, .allow)
        // 617 (owner: a fresh try shows no refusal): its key-less start-up check — the root EXACTLY, nothing under it by it.
        XCTAssertEqual(policy.evaluate(host: "api.x.ai", port: 443, method: "GET", path: "/").action, .allow, "its start-up check (no key)")
        XCTAssertEqual(policy.evaluate(host: "api.x.ai", port: 443, method: "GET", path: "/v2/anything").action, .deny, "the root, not a prefix")
        XCTAssertEqual(KeyProviders.provider("xai")?.binding.swapOnly, true, "the key only where Grok sent its placeholder — the start-up check stays key-less")
        // xAI's own site: Grok Build reads its release notes there at start-up.
        XCTAssertEqual(policy.evaluateConnection(host: "x.ai", port: 443).kind, .allow)
        XCTAssertEqual(policy.evaluate(host: "api.x.ai", port: 443, method: "POST", path: "/v1/upload").action, .deny)
        XCTAssertEqual(policy.evaluateConnection(host: "api.x.ai", port: 443).kind, .inspect)
        XCTAssertEqual(policy.evaluateConnection(host: "api.anthropic.com", port: 443).kind, .deny, "D5: no way out to Anthropic")
    }

    func test_excludedHostsAreKeptOutWhateverIsChosen() throws {
        let grok = try XCTUnwrap(AgentKind(rawValue: "grok"))
        var open = NetworkPolicy.permissions(AgentPermissions.normalized(AgentPermissions.preset("open", base: "debian")! + AgentPermissions.agentPermissions(grok)))
        XCTAssertEqual(open.effectiveDefault, .allow)
        for h in ["cli-chat-proxy.grok.com", "auth.x.ai", "accounts.x.ai", "console.x.ai"] {
            XCTAssertEqual(open.evaluateConnection(host: h, port: 443).kind, .deny, h)
            XCTAssertFalse(open.allowsName(h), "\(h): not even resolved")
        }
        XCTAssertEqual(open.evaluateConnection(host: "example.com", port: 443).kind, .allow, "Open still opens the rest")
        // A user's own site rule does not let one in (the exclusions come first).
        open.rules.insert(EgressRule(host: "auth.x.ai", note: "site you allowed"), at: 0)
        XCTAssertEqual(open.evaluateConnection(host: "auth.x.ai", port: 443).kind, .deny)
        // An agent's excluded hosts are in no permission its sandbox can hold. (617: another agent's hidden vendor
        // permission may name one — Antigravity CLI's usage log to play.googleapis.com, allowed at the owner's word, is
        // kept out of Gemini CLI's sandboxes; `vendor:antigravity` is only ever added to Antigravity CLI's.)
        for r in AgentRecipes.all {
            let excluded = Set(r.network.excluded)
            for p in AgentPermissions.all where !(p.id.hasPrefix("vendor:") && p.id != "vendor:" + r.id) {
                XCTAssertTrue(Set(p.hosts.map(\.host)).isDisjoint(with: excluded), "\(r.id): \(p.id)")
            }
        }
        // A Claude Code sandbox's rules are exactly as before (no exclusions).
        XCTAssertTrue(AgentPermissions.exclusions(for: AgentPermissions.preset("open", base: "node")!).isEmpty)
    }

    func test_anAgentsOwnUpdateHostsOnlyBesideUpdateItself() throws {
        let gemini = try XCTUnwrap(AgentKind(rawValue: "gemini"))
        let locked = AgentPermissions.normalized(AgentPermissions.agentPermissions(gemini))
        XCTAssertTrue(locked.contains("update:gemini"))
        let p = NetworkPolicy.permissions(locked)
        XCTAssertEqual(p.evaluate(host: "registry.npmjs.org", port: 443, method: "GET", path: "/@google/gemini-cli").action, .deny, "Update itself is off")
        let s = NetworkPolicy.permissions(AgentPermissions.normalized(locked + ["update"]))
        XCTAssertEqual(s.evaluate(host: "registry.npmjs.org", port: 443, method: "GET", path: "/@google/gemini-cli").action, .allow)
        XCTAssertEqual(s.evaluate(host: "registry.npmjs.org", port: 443, method: "GET", path: "/left-pad").action, .deny, "only its own package")
    }

    // MARK: keys, the proxy's refusal shapes

    func head(_ s: String) -> [UInt8] { Array(s.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

    func test_keyBindingsSwapOnTheirOwnHostOnly() throws {
        let xai = try XCTUnwrap(KeyProviders.provider("xai")).binding, google = try XCTUnwrap(KeyProviders.provider("google")).binding
        XCTAssertEqual(xai.id, "key:xai")
        XCTAssertEqual(xai.environmentVariable, "XAI_API_KEY")
        XCTAssertEqual(google.environmentVariable, "GEMINI_API_KEY")
        let v = CredentialVault()
        v.set(xai, secret: "xai-REAL-SECRET")
        v.set(google, secret: "AIza-REAL-SECRET")
        let tx = try XCTUnwrap(v.mint(xai.id)), tg = try XCTUnwrap(v.mint(google.id))
        XCTAssertEqual(v.rewrite(head: head("POST /v1/chat/completions HTTP/1.1\nHost: api.x.ai\nAuthorization: Bearer \(tx)\n\n"), host: "api.x.ai"),
                       .swapped(head("POST /v1/chat/completions HTTP/1.1\nHost: api.x.ai\nAuthorization: Bearer xai-REAL-SECRET\n\n"), binding: "key:xai"))
        XCTAssertEqual(v.rewrite(head: head("POST /v1beta/models/m:generateContent HTTP/1.1\nHost: generativelanguage.googleapis.com\nx-goog-api-key: \(tg)\n\n"),
                                 host: "generativelanguage.googleapis.com"),
                       .swapped(head("POST /v1beta/models/m:generateContent HTTP/1.1\nHost: generativelanguage.googleapis.com\nx-goog-api-key: AIza-REAL-SECRET\n\n"), binding: "key:google"))
        // The leak guard: one provider's placeholder sent to the other's host.
        guard case .reject = v.rewrite(head: head("GET / HTTP/1.1\nHost: generativelanguage.googleapis.com\nx-goog-api-key: \(tx)\n\n"), host: "generativelanguage.googleapis.com") else {
            return XCTFail("a Grok placeholder on Google's host is refused")
        }
        guard case .reject = v.rewrite(head: head("GET / HTTP/1.1\nHost: api.x.ai\nAuthorization: Bearer \(tg)\n\n"), host: "api.x.ai") else {
            return XCTFail("a Gemini placeholder on xAI's host is refused")
        }
        // Never beside the guest's own credential.
        guard case .foreign = v.rewrite(head: head("GET /v1/models HTTP/1.1\nHost: api.x.ai\nAuthorization: Bearer xai-the-users-own\n\n"), host: "api.x.ai") else {
            return XCTFail()
        }
    }

    func test_refusalsAreInEachProvidersShape() throws {
        func body(_ b: [UInt8]) throws -> [String: Any] {
            let s = String(decoding: b, as: UTF8.self)
            let json = try XCTUnwrap(s.range(of: "\r\n\r\n")).upperBound
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(s[json...].utf8)) as? [String: Any])
        }
        let g = try body(EgressProxy.refusal(host: "generativelanguage.googleapis.com", 401, "no key"))
        XCTAssertEqual((g["error"] as? [String: Any])?["status"] as? String, "UNAUTHENTICATED")
        XCTAssertEqual((g["error"] as? [String: Any])?["code"] as? Int, 401)
        XCTAssertEqual((g["error"] as? [String: Any])?["message"] as? String, "doz: no key")
        let x = try body(EgressProxy.refusal(host: "api.x.ai", 401, "no key"))
        XCTAssertEqual((x["error"] as? [String: Any])?["code"] as? String, "doz_credential_unavailable", "xAI's is OpenAI's shape")
        let a = try body(EgressProxy.refusal(host: "api.anthropic.com", 401, "no key"))
        XCTAssertEqual(a["type"] as? String, "error", "Anthropic's, as before")
        XCTAssertEqual(KeyProviders.seamHosts, ["api.x.ai", "openrouter.ai", "ai-gateway.vercel.sh", "generativelanguage.googleapis.com", "stitch.googleapis.com"])
    }
}
