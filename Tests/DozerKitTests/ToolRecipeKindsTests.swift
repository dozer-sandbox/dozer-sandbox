import Foundation
import XCTest
@testable import DozerKit

/// 617 (other AI tools): the recipe format's additions for tools that are not coding agents — the `pypi` and
/// `release-binary` install kinds, a dotenv first-run file, and `launch.session: shell` — validated, refused with a
/// reason, and turned into the bake steps they describe.
final class ToolRecipeKindsTests: XCTestCase {
    static let sha = String(repeating: "a", count: 64)

    /// Fabric's recipe as model JSON, with `install` changed by `edit`.
    func recipe(_ edit: (inout [String: Any]) -> Void = { _ in }, launch: ((inout [String: Any]) -> Void)? = nil,
                platforms: [String: Any]? = nil) throws -> AgentRecipe {
        var o = try AgentRecipeTests.json("fabric")
        var i = try XCTUnwrap(o["install"] as? [String: Any])
        i.removeValue(forKey: "extras")          // 617.11: Fabric's patterns are Fabric's own
        edit(&i)
        o["install"] = i
        if let launch {
            var l = try XCTUnwrap(o["launch"] as? [String: Any])
            launch(&l)
            o["launch"] = l
        }
        if let platforms { o["platforms"] = platforms }
        return try AgentRecipes.decode(AgentRecipeTests.data(o))
    }

    func pypi(_ reqs: [String], package: String = "llm", version: String = "0.36") -> (inout [String: Any]) -> Void {
        { i in
            i["kind"] = "pypi"; i["package"] = package; i["binary"] = "fabric"; i["requirements"] = reqs
            i["url"] = nil; i["payload"] = nil; i["bake_hosts"] = nil
            i["pinned"] = ["version": version, "integrity": "sha512-AAAA"]
        }
    }

    // MARK: release-binary

    func test_releaseBinaryIsValidatedAndBaked() throws {
        let r = try XCTUnwrap(AgentRecipes.recipe("fabric"))
        XCTAssertEqual(r.install.kind, "release-binary")
        XCTAssertEqual(r.install.archive, "tar.gz")
        XCTAssertTrue(AgentRecipe.pinnedOnlyKinds.contains(r.install.kind))
        let step = AgentImages.releaseBinaryInstall(r, r.pinnedRelease!)
        let s = step.argv.last!
        XCTAssertTrue(s.contains("https://github.com/danielmiessler/Fabric/releases/download/v1.4.518/fabric_Linux_arm64.tar.gz"), s)
        XCTAssertTrue(s.contains(r.install.pinned.integrity!), "the download's sha512 is checked")
        XCTAssertTrue(s.contains("tar -xzf dl -C x"))
        XCTAssertTrue(s.contains("src=x/fabric"))
        XCTAssertTrue(s.contains("ln -sf /opt/fabric/fabric /usr/local/bin/fabric"))
    }

    func test_releaseBinaryRefusals() throws {
        XCTAssertThrowsError(try recipe { $0["url"] = "https://example.com/fabric_Linux_arm64.tar.gz" }, "no {version}")
        XCTAssertThrowsError(try recipe { $0["payload"] = nil }, "an archive names its program")
        XCTAssertThrowsError(try recipe { $0["url"] = "https://example.com/v{version}/tool-linux-arm64" }, "a raw download has no payload")
        XCTAssertNoThrow(try recipe { $0["url"] = "https://example.com/v{version}/tool-linux-arm64"; $0["payload"] = nil })
        XCTAssertThrowsError(try recipe { $0["url"] = "http://example.com/v{version}/x.tar.gz" }, "https only")
        XCTAssertThrowsError(try recipe { $0["package"] = "fabric" }, "nothing of npm's")
        XCTAssertEqual(try recipe { $0["url"] = "https://example.com/v{version}/x.zip" }.install.archive, "zip")
    }

    // MARK: pypi

    func test_pypiIsValidatedAndBaked() throws {
        let reqs = ["llm==0.36 --hash=sha256:\(Self.sha)", "click==8.2.1 --hash=sha256:\(Self.sha)"]
        let r = try recipe(pypi(reqs), platforms: ["glibc": true, "musl": false])
        let s = AgentImages.pypiInstall(r, r.pinnedRelease!).argv.last!
        XCTAssertTrue(s.contains("llm==0.36 --hash=sha256:\(Self.sha)\nclick==8.2.1 --hash=sha256:\(Self.sha)"), "the lock, verbatim")
        XCTAssertTrue(s.contains("download --no-deps --require-hashes -d dist -r requirements.txt"))
        XCTAssertTrue(s.contains("install --no-index --find-links dist --no-deps --require-hashes -r requirements.txt"))
        XCTAssertTrue(s.contains("grep -i '^llm-0.36[-.]'"), "the package's own file is found by its wheel name")
        XCTAssertTrue(s.contains("sha512-AAAA"), "and checked against the integrity")
        XCTAssertTrue(s.contains("/opt/python/bin/python3 -m venv /opt/fabric/venv"))
        let py = AgentImages.pythonRuntime(for: "x").argv.last!
        XCTAssertTrue(py.contains(PythonRuntime.sha256) && py.contains(PythonRuntime.url))
        let steps = AgentImages.recipeInstall(r, r.pinnedRelease!, base: BaseCatalogue.base("debian")!.source())
        XCTAssertEqual(steps.steps.count, 2)
        XCTAssertTrue(steps.bakeHosts.contains("files.pythonhosted.org") && steps.bakeHosts.contains("release-assets.githubusercontent.com"))
        XCTAssertEqual(AgentRecipe.Install.wheelName("Shell-GPT"), "shell_gpt")
        XCTAssertEqual(AgentRecipe.Install.wheelName("google.adk"), "google_adk")
    }

    func test_pypiRefusals() throws {
        let ok = ["llm==0.36 --hash=sha256:\(Self.sha)"]
        let glibc: [String: Any] = ["glibc": true, "musl": false]
        XCTAssertNoThrow(try recipe(pypi(ok), platforms: glibc))
        XCTAssertThrowsError(try recipe(pypi(ok)), "musl: Dozer's Python is glibc")
        XCTAssertThrowsError(try recipe(pypi([]), platforms: glibc), "no requirements")
        XCTAssertThrowsError(try recipe(pypi(["llm==0.36"]), platforms: glibc), "a requirement without its hash")
        XCTAssertThrowsError(try recipe(pypi(["llm>=0.36 --hash=sha256:\(Self.sha)"]), platforms: glibc), "not pinned exactly")
        XCTAssertThrowsError(try recipe(pypi(["llm==0.35 --hash=sha256:\(Self.sha)"]), platforms: glibc), "the package at another version")
        XCTAssertThrowsError(try recipe(pypi(ok + ["LLM==0.36 --hash=sha256:\(Self.sha)"]), platforms: glibc), "a distribution twice")
        XCTAssertThrowsError(try recipe(pypi(["llm==0.36 --hash=sha256:\(Self.sha)'; rm -rf /"]), platforms: glibc), "nothing a script would run")
        XCTAssertThrowsError(try recipe({ i in self.pypi(ok)(&i); i["url"] = "https://example.com/{version}" }, platforms: glibc), "no url")
        XCTAssertThrowsError(try recipe({ i in i["requirements"] = ok }), "requirements are a pypi install's")
    }

    // MARK: Node 24

    /// An npm recipe that needs a newer Node than the bases' gets Dozer's Node 24 under /opt/node on every glibc base —
    /// the Node base included — and a wrapper; never on musl.
    func test_aNewerNodeIsInstalledForTheRecipeThatNeedsIt() throws {
        let r = try XCTUnwrap(AgentRecipes.recipe("openclaw"))
        XCTAssertEqual(r.install.needsNode, "24")
        for base in ["node", "debian", "python"] {
            let steps = AgentImages.recipeInstall(r, r.pinnedRelease!, base: BaseCatalogue.base(base)!.source())
            XCTAssertEqual(steps.steps.map(\.name).first, "install Node \(NodeRuntime.V24.version) for OpenClaw (/opt/node, checksum-verified)", base)
            XCTAssertTrue(steps.steps[0].argv.last!.contains(NodeRuntime.V24.sha256))
            XCTAssertEqual(steps.steps[1].environment["PATH"]?.hasPrefix("/opt/node/bin:"), true)
            XCTAssertEqual(steps.steps.last?.name, "install the openclaw wrapper (/usr/local/bin/openclaw)")
        }
        var o = try AgentRecipeTests.json("openclaw")
        o["platforms"] = ["glibc": true, "musl": true]
        XCTAssertThrowsError(try AgentRecipes.decode(AgentRecipeTests.data(o)), "Node 24 is glibc only")
        o = try AgentRecipeTests.json("openclaw")
        var i = try XCTUnwrap(o["install"] as? [String: Any])
        i["needs_node"] = "26"
        o["install"] = i
        XCTAssertThrowsError(try AgentRecipes.decode(AgentRecipeTests.data(o)), "Node 24 at most")
        // An agent whose needs_node is the bases' own keeps the old steps (Gemini CLI on Node: the npm install alone).
        let g = try XCTUnwrap(AgentRecipes.recipe("gemini"))
        XCTAssertEqual(AgentImages.recipeInstall(g, g.pinnedRelease!, base: BaseCatalogue.base("node")!.source()).steps.count, 1)
    }

    // MARK: env aliases

    /// A recipe's env aliases put the SAME placeholder under more names (ShellGPT reads OPENAI_API_KEY beside a base URL
    /// pointed at xAI); the binding's hosts stay the provider's, so the placeholder works nowhere else.
    func test_envAliasesAddNamesNotHosts() throws {
        let r = try XCTUnwrap(AgentRecipes.recipe("shell-gpt"))
        let p = try XCTUnwrap(KeyProviders.provider("xai"))
        let b = r.keyBinding(p)
        XCTAssertEqual(b.placeholderVariables, ["XAI_API_KEY", "OPENAI_API_KEY"])
        XCTAssertEqual(b.hosts, p.binding.hosts)
        XCTAssertEqual(b.id, p.binding.id, "the same binding: placeholders and stored sources keep working")
        XCTAssertEqual(try XCTUnwrap(AgentRecipes.recipe("fabric")).keyBinding(KeyProviders.provider("google")!).placeholderVariables, ["GEMINI_API_KEY"])
        func with(_ aliases: [String]) throws -> AgentRecipe {
            var o = try AgentRecipeTests.json("shell-gpt")
            var c = try XCTUnwrap((o["credentials"] as? [[String: Any]])?.first)
            c["env_aliases"] = aliases
            o["credentials"] = [c]
            return try AgentRecipes.decode(AgentRecipeTests.data(o))
        }
        XCTAssertNoThrow(try with(["OPENAI_API_KEY", "LLM_XAI_KEY"]))
        XCTAssertThrowsError(try with(["XAI_API_KEY"]), "the provider's own name")
        XCTAssertThrowsError(try with(["API_BASE_URL"]), "not credential-shaped")
        XCTAssertThrowsError(try with(["OPENAI_API_KEY", "OPENAI_API_KEY"]), "twice")
    }

    // MARK: launch

    func test_shellSessionAndDotenvFirstRun() throws {
        let r = try XCTUnwrap(AgentRecipes.recipe("fabric"))
        XCTAssertEqual(r.launch.session, "shell")
        XCTAssertThrowsError(try recipe(launch: { $0["session"] = "tmux" }), "shell only")
        XCTAssertThrowsError(try recipe(launch: { $0["first_run"] = [["file": "~/.config/fabric/.env", "set": ["GEMINI_API_KEY": "x"]]] }),
                             "a dotenv first run never names a credential")
        XCTAssertThrowsError(try recipe(launch: { $0["first_run"] = [["file": "~/.config/fabric/.env", "set": ["A": "$(id)"]]] }))
    }

    /// A TOML first-run key with no table goes above the first table (ZeroClaw's schema_version), only when absent; the
    /// other recipes' helpers are unchanged.
    func test_topLevelTOMLFirstRunKey() throws {
        XCTAssertTrue(AgentImages.recipeSetupPython(AgentRecipes.recipe("zeroclaw")!.launch.firstRun!).contains("merge_toml_top(g, top)"))
        XCTAssertFalse(AgentImages.recipeSetupPython(AgentRecipes.recipe("grok")!.launch.firstRun!).contains("merge_toml_top"))
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("no python3") }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        probe.arguments = ["-c", "import tomllib"]
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { throw XCTSkip("this Mac's python3 has no tomllib (3.11+); the VM proof covers it") }
        let r = try XCTUnwrap(AgentRecipes.recipe("zeroclaw"))
        let py = AgentImages.recipeSetupPython(r.launch.firstRun!)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("toml-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let script = home.appendingPathComponent("setup.py")
        try py.write(to: script, atomically: true, encoding: .utf8)
        func run() throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [script.path]
            p.environment = ["HOME": home.path]
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }
        let f = home.appendingPathComponent(".zeroclaw/config.toml")
        try run()
        let text = try String(contentsOf: f, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("schema_version = 3\n"), text)
        XCTAssertTrue(text.contains("[providers.models.openai.xai]") && text.contains("uri = \"https://api.x.ai/v1\""), text)
        try run()
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), text, "a second run changes nothing")
        XCTAssertFalse(AgentImages.recipeSetupPython(AgentRecipes.recipe("grok")!.launch.firstRun!).contains("merge_toml_top"))
    }

    /// The dotenv helper: absent keys appended, a person's own line (set or commented out) kept, the file made when missing.
    func test_dotenvFirstRunMergesAbsentKeysOnly() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("no python3") }
        let r = try XCTUnwrap(AgentRecipes.recipe("fabric"))
        let py = AgentImages.recipeSetupPython(r.launch.firstRun!)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dotenv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let script = home.appendingPathComponent("setup.py")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try py.write(to: script, atomically: true, encoding: .utf8)
        func run() throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [script.path]
            p.environment = ["HOME": home.path]
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }
        let env = home.appendingPathComponent(".config/fabric/.env")
        try run()
        XCTAssertEqual(try String(contentsOf: env, encoding: .utf8), "DEFAULT_MODEL=gemini-2.5-flash\nDEFAULT_VENDOR=Gemini\n")
        try Data("# DEFAULT_MODEL=mine\nOTHER=1\n".utf8).write(to: env)
        try run()
        XCTAssertEqual(try String(contentsOf: env, encoding: .utf8), "# DEFAULT_MODEL=mine\nOTHER=1\nDEFAULT_VENDOR=Gemini\n")
        // The other recipes' helpers are unchanged by the dotenv support (their bake keys stay).
        XCTAssertFalse(AgentImages.recipeSetupPython(AgentRecipes.recipe("gemini")!.launch.firstRun!).contains("merge_env"))
    }

    /// 617 (the owner's first `doz try goose` opened Goose's setup wizard: it runs whenever its config.yaml is missing,
    /// whatever the environment says): the YAML helper writes the file when absent, adds absent top-level keys only, and
    /// keeps a person's own line, set or commented out.
    func test_yamlFirstRunMakesGoosesConfigAndKeepsAPersonsLines() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("no python3") }
        let r = try XCTUnwrap(AgentRecipes.recipe("goose"))
        let py = AgentImages.recipeSetupPython(r.launch.firstRun!)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("yaml-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let script = home.appendingPathComponent("setup.py")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try py.write(to: script, atomically: true, encoding: .utf8)
        func run() throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [script.path]
            p.environment = ["HOME": home.path]
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }
        let f = home.appendingPathComponent(".config/goose/config.yaml")
        try run()
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8),
                       "GOOSE_MODEL: \"grok-code-fast-1\"\nGOOSE_PROVIDER: \"xai\"\nGOOSE_TELEMETRY_ENABLED: false\n")
        try Data("GOOSE_PROVIDER: openrouter\n# GOOSE_MODEL: mine\nextensions:\n  GOOSE_TELEMETRY_ENABLED: x\n".utf8).write(to: f)
        try run()
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8),
                       "GOOSE_PROVIDER: openrouter\n# GOOSE_MODEL: mine\nextensions:\n  GOOSE_TELEMETRY_ENABLED: x\nGOOSE_TELEMETRY_ENABLED: false\n",
                       "only the top-level key that is absent is added; a nested one is not the top-level key")
        let text = try String(contentsOf: f, encoding: .utf8)
        try run()
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), text, "a second run changes nothing")
        // The other recipes' helpers are unchanged by the YAML support (their bake keys stay).
        for other in ["grok", "gemini", "fabric", "zeroclaw"] {
            XCTAssertFalse(AgentImages.recipeSetupPython(AgentRecipes.recipe(other)!.launch.firstRun!).contains("merge_yaml"), other)
        }
        // A YAML first-run key is top-level and a scalar.
        var bad = r
        bad.launch.firstRun = [.init(file: "~/.config/goose/config.yaml", set: ["a.b": .string("x")])]
        XCTAssertThrowsError(try bad.validate())
        bad.launch.firstRun = [.init(file: "~/.config/goose/config.yaml", set: ["A": .array([.string("x")])])]
        XCTAssertThrowsError(try bad.validate())
    }

    /// Runs a recipe's first-run helper under python3 with HOME = `home` (twice: the second run must change nothing).
    private func runSetup(_ recipe: String, home: URL) throws {
        let py = AgentImages.recipeSetupPython(try XCTUnwrap(AgentRecipes.recipe(recipe)?.launch.firstRun))
        let script = home.appendingPathComponent("setup.py")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try py.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script.path]
        p.environment = ["HOME": home.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, recipe)
    }

    /// 617 (the first-screen survey: seven agents opened on a "trust this folder?" question): the folder is trusted at the
    /// first start the way each agent records it — Kimi Code's extension-less JSON record (`format: json`), Open
    /// Interpreter's quoted TOML table `[projects."/workspace"]` — and a person's own answer is kept.
    func test_trustRecordsAreWrittenTheWayEachAgentKeepsThem() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("no python3") }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("trust-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try runSetup("kimi-code", home: home)
        let kimi = home.appendingPathComponent(".kimi-code/workspace-trust/wd_workspace_c52ddf65534b")
        let record = try JSONSerialization.jsonObject(with: Data(contentsOf: kimi)) as? [String: Any]
        XCTAssertEqual(record?["root"] as? String, "/workspace")
        XCTAssertNotNil(record?["trustedAt"] as? NSNumber)

        // The quoted TOML table: only where this Mac's python3 has tomllib (3.11+); recipe-check's VM run covers it too.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        probe.arguments = ["-c", "import tomllib"]
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        probe.waitUntilExit()
        if probe.terminationStatus == 0 { try checkQuotedTOML(home) }
        try checkHelpersAndRefusals()
    }

    private func checkQuotedTOML(_ home: URL) throws {
        try runSetup("open-interpreter", home: home)
        let toml = home.appendingPathComponent(".openinterpreter/config.toml")
        let text = try String(contentsOf: toml, encoding: .utf8)
        XCTAssertTrue(text.contains("[projects.\"/workspace\"]\ntrust_level = \"trusted\""), text)
        try runSetup("open-interpreter", home: home)
        XCTAssertEqual(try String(contentsOf: toml, encoding: .utf8), text, "a second run changes nothing")
        try Data("[projects.\"/workspace\"]\ntrust_level = \"untrusted\"\n".utf8).write(to: toml)
        try runSetup("open-interpreter", home: home)
        XCTAssertTrue(try String(contentsOf: toml, encoding: .utf8).contains("trust_level = \"untrusted\""), "a person's answer is kept")
        XCTAssertFalse(try String(contentsOf: toml, encoding: .utf8).contains("trust_level = \"trusted\""))
    }

    private func checkHelpersAndRefusals() throws {
        // The quoted-key and format code is only in the helpers that need it (every other bake key unchanged).
        for other in ["zeroclaw", "every-code", "grok", "codewhale"] {
            guard let runs = AgentRecipes.recipe(other)?.launch.firstRun else { continue }
            let py = AgentImages.recipeSetupPython(runs)
            XCTAssertFalse(py.contains("toml_parts"), other)
            XCTAssertFalse(py.contains("m.get('format')"), other)
        }
        // A quoted segment is a TOML thing only, and a format other than json is refused.
        var bad = try XCTUnwrap(AgentRecipes.recipe("kimi-code"))
        bad.launch.firstRun = [.init(file: "~/.x/settings.json", set: ["projects.\"/w\".a": .string("x")])]
        XCTAssertThrowsError(try bad.validate())
        bad.launch.firstRun = [.init(file: "~/.x/record", set: ["a": .string("x")], format: "toml")]
        XCTAssertThrowsError(try bad.validate())
        bad.launch.firstRun = [.init(file: "~/.x/record", set: ["a": .string("x")])]
        XCTAssertThrowsError(try bad.validate(), "a file with no known extension needs format: json")
    }

    /// 617: MiMo Code's --dangerously-skip-permissions asks again on a terminal ("No, exit" first); its variable does not —
    /// set only when the launcher skips prompts (not with mimo-code.permissions = ask, nor as root).
    func test_noPromptsEnvIsSetOnlyWhenPromptsAreSkipped() throws {
        let r = try XCTUnwrap(AgentRecipes.recipe("mimo-code"))
        let sh = AgentImages.recipeLauncherScript(r)
        XCTAssertTrue(sh.contains("[ \"$mode\" = skip ] && export MIMOCODE_DANGEROUSLY_SKIP_PERMISSIONS='1'"), sh)
        XCTAssertFalse(sh.contains("--dangerously-skip-permissions"))
        XCTAssertEqual(r.permissionsSettingKey, "mimo-code.permissions", "it still has a permissions setting")
        XCTAssertFalse(AgentImages.recipeLauncherScript(try XCTUnwrap(AgentRecipes.recipe("grok"))).contains("&& export"))
    }

    /// 617: a recipe's first-screen expectations round-trip through the strict loader (an unknown key is refused).
    func test_theCheckCarriesTheFirstScreen() throws {
        let r = try XCTUnwrap(AgentRecipes.recipe("goose"))
        XCTAssertEqual(r.smoke?.screen?.expect, ["goose is ready"])
    }
}
