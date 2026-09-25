import Foundation
import XCTest
@testable import SnoozeContainerKit

final class ImageRecipeTests: XCTestCase {
    private let k = String(repeating: "a", count: 64), d = String(repeating: "b", count: 64)

    /// The same recipe always bakes to the same key; ANY input change — a step, the base, the
    /// kernel, deckhold — is a different key (a different disk), and dictionary order is not.
    func test_bakeKeyIsStableAndSensitive() {
        let r = AgentRecipes.claudeCode
        XCTAssertEqual(r.bakeKey(kernelSHA256: k, deckholdSHA256: d), r.bakeKey(kernelSHA256: k, deckholdSHA256: d))
        var step = r; step.steps.append(BakeStep("x", argv: ["true"]))
        var base = r; base.base = "docker.io/library/node@sha256:" + String(repeating: "c", count: 64)
        var env = r; env.sessionEnvironment["EXTRA"] = "1"
        let keys: Set = [r.bakeKey(kernelSHA256: k, deckholdSHA256: d), step.bakeKey(kernelSHA256: k, deckholdSHA256: d),
                         base.bakeKey(kernelSHA256: k, deckholdSHA256: d), env.bakeKey(kernelSHA256: k, deckholdSHA256: d),
                         r.bakeKey(kernelSHA256: d, deckholdSHA256: d), r.bakeKey(kernelSHA256: k, deckholdSHA256: k)]
        XCTAssertEqual(keys.count, 6)
        var reordered = r
        reordered.sessionEnvironment = Dictionary(uniqueKeysWithValues: r.sessionEnvironment.reversed().map { ($0.key, $0.value) })
        XCTAssertEqual(reordered.bakeKey(kernelSHA256: k, deckholdSHA256: d), r.bakeKey(kernelSHA256: k, deckholdSHA256: d))
        XCTAssertNotEqual(AgentRecipes.claudeCode.bakeKey(kernelSHA256: k, deckholdSHA256: d),
                          AgentRecipes.pi.bakeKey(kernelSHA256: k, deckholdSHA256: d))
    }

    /// Values copied from the pinned recipes: digest-pinned Debian node base, exact npm versions
    /// with their integrity, credential-free verification.
    func test_agentRecipesArePinned() throws {
        for r in [AgentRecipes.claudeCode, AgentRecipes.pi] {
            XCTAssertNoThrow(try r.validate(), r.name)
            XCTAssertEqual(r.base, "docker.io/library/node@sha256:d649c27dae7ba0137b3cef5dd75baa422c08dc3d9e3fc0c23dfb172dc3cc6436")
            XCTAssertEqual(r.user, "agent")
        }
        let cc = AgentRecipes.claudeCode.steps.map { $0.argv.joined(separator: " ") }.joined()
        XCTAssertTrue(cc.contains("@anthropic-ai/claude-code@2.1.227"))
        XCTAssertTrue(cc.contains("sha512-D0YP8GFwPaP/9eObEuP5LRO5+9QSD9CLa6K26whNzXxpxz3pFqPS3nn7l1/MLmSWy32wBP2IKQzkRB3mumUKUQ=="))
        let pi = AgentRecipes.pi.steps.map { $0.argv.joined(separator: " ") }.joined()
        XCTAssertTrue(pi.contains("@earendil-works/pi-coding-agent@0.84.1"))
        XCTAssertTrue(pi.contains("--ignore-scripts"))
        XCTAssertTrue(pi.contains("sha512-ncAqFrG+iybuPGOhMiZoEHkEzTpJgz3guYD32pD+M7ucc0WeHmauP6wa7qwP8V/KWvsZDVNa5XGsdZ7fkC7w7A=="))
        XCTAssertEqual(AgentRecipes.claudeCode.verify, [VerifyCheck(["claude", "--version"], expect: "2.1.227")])
        XCTAssertEqual(AgentRecipes.pi.verify, [VerifyCheck(["pi", "--version"], expect: "0.84.1")])
        XCTAssertEqual(AgentRecipes.claudeCode.resolvedPersistDirs, ["/home/agent/.claude"])
        XCTAssertEqual(AgentRecipes.claudeCode.sessionEnvironment["CLAUDE_CONFIG_DIR"], "/home/agent/.claude")
        XCTAssertEqual(AgentRecipes.pi.resolvedPersistDirs, ["/home/agent/.pi/agent"])
    }

    /// A credential never reaches a bake: the bake environment is scrubbed, and a recipe that
    /// names one is rejected outright.
    func test_credentialsNeverReachABake() {
        let env = BakeEnvironment.scrubbed(["ANTHROPIC_API_KEY": "sk", "OPENAI_API_KEY": "x", "GITHUB_TOKEN": "t",
                                            "NPM_CONFIG_UPDATE_NOTIFIER": "false", "HOME": "/home/agent"])
        XCTAssertEqual(Set(env.keys), ["NPM_CONFIG_UPDATE_NOTIFIER", "HOME"])
        var bad = AgentRecipes.claudeCode
        bad.steps[1].environment["ANTHROPIC_API_KEY"] = "sk-ant"
        XCTAssertThrowsError(try bad.validate())
        var bad2 = AgentRecipes.pi
        bad2.sessionEnvironment["ANTHROPIC_API_KEY"] = "sk-ant"
        XCTAssertThrowsError(try bad2.validate())
        for r in [AgentRecipes.claudeCode, AgentRecipes.pi] {
            XCTAssertFalse(String(decoding: r.canonicalJSON, as: UTF8.self).contains("ANTHROPIC_API_KEY"))
        }
    }

    func test_recipeValidation() {
        var r = AgentRecipes.pi
        r.base = "docker.io/library/node:22"
        XCTAssertThrowsError(try r.validate(), "a base must be digest-pinned")
        var r2 = AgentRecipes.pi
        r2.persistDirs = ["relative/dir"]
        XCTAssertThrowsError(try r2.validate())
        var s = SandboxSpec(name: "a", storeRoot: URL(fileURLWithPath: "/tmp"), recipe: AgentRecipes.pi)
        XCTAssertNoThrow(try s.validate())
        s.shares = [Share(hostPath: "/tmp/x", guestPath: "/state")]
        XCTAssertThrowsError(try s.validate(), "/state belongs to the state disk")
    }

    /// Sessions of an image run as its user, in its workdir, with its environment — and the
    /// caller's credential on top; `user: "root"` overrides; a plain sandbox is unchanged.
    func test_sessionContext() {
        let (env, cwd, user) = Sandbox.sessionContext(recipe: AgentRecipes.claudeCode, environment: ["ANTHROPIC_API_KEY": "sk"],
                                                      workingDirectory: nil, user: nil)
        XCTAssertEqual(user, "agent")
        XCTAssertEqual(cwd, "/workspace")
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk")
        XCTAssertEqual(env["HOME"], "/home/agent")
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/home/agent/.claude")
        let asRoot = Sandbox.sessionContext(recipe: AgentRecipes.claudeCode, environment: [:], workingDirectory: "/", user: "root")
        XCTAssertNil(asRoot.user)
        XCTAssertNil(asRoot.environment["HOME"])
        let plain = Sandbox.sessionContext(recipe: nil, environment: ["A": "1"], workingDirectory: nil, user: nil)
        XCTAssertEqual(plain.workingDirectory, "/root")
        XCTAssertNil(plain.user)
        XCTAssertEqual(plain.environment, ["A": "1"])
    }

    /// The state disk: mounted at /state, one directory per persist dir, bind-mounted over it,
    /// owned by the recipe user; the deckhold socket dir is sticky + world-writable.
    func test_stateDiskLayoutScript() {
        XCTAssertEqual(GuestCommand.stateKey("/home/agent/.pi/agent"), "home_agent_.pi_agent")
        let s = GuestCommand.prepareGuest(recipe: AgentRecipes.pi)
        XCTAssertTrue(s.contains("chmod 1777 /run/deckhold"))
        XCTAssertTrue(s.contains("mkdir -p '/state/home_agent_.pi_agent' '/home/agent/.pi/agent'"))
        XCTAssertTrue(s.contains("mount --bind '/state/home_agent_.pi_agent' '/home/agent/.pi/agent'"))
        XCTAssertTrue(s.contains("mountpoint -q '/home/agent/.pi/agent' ||"), "idempotent")
        XCTAssertTrue(s.contains("chown agent:agent '/state/home_agent_.pi_agent'"))
        XCTAssertEqual(GuestCommand.prepareGuest(recipe: nil), "set -e; mkdir -p /run/deckhold; chmod 1777 /run/deckhold")
        let layout = StoreLayout(root: URL(fileURLWithPath: "/tmp/s"), name: "lab")
        XCTAssertEqual(layout.stateDisk.path, "/tmp/s/sandboxes/lab/state.ext4")
        XCTAssertFalse(LifecyclePlanner.plan(.stop, from: .running)!.isEmpty)   // Stop removes the root clone,
        // and removeRuntimeFiles never names the state disk (see Sandbox.run(.removeRuntimeFiles)).
    }
}

final class ImageBakerCacheTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("snooze-baker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func plant(_ recipe: ImageRecipe, key: String, manifestKey: String? = nil, withRoot: Bool = true) throws -> URL {
        let b = ImageBaker(storeRoot: dir)
        let loc = b.location(recipe, key: key)
        try FileManager.default.createDirectory(at: loc, withIntermediateDirectories: true)
        if withRoot { try Data("disk".utf8).write(to: loc.appendingPathComponent("root.ext4")) }
        let m = ImageManifest(key: manifestKey ?? key, recipe: recipe, kernelSHA256: "k", deckholdSHA256: "d", bakedAt: Date(),
                              timings: [.init(step: "bake", milliseconds: 1)], apparentBytes: 4, allocatedBytes: 4, verifyOutput: ["ok"])
        try ImageBaker.encoder.encode(m).write(to: loc.appendingPathComponent("manifest.json"))
        return loc
    }

    func test_cacheHitAndMiss() throws {
        let r = AgentRecipes.pi
        let key = r.bakeKey(kernelSHA256: "k", deckholdSHA256: "d")
        let b = ImageBaker(storeRoot: dir)
        XCTAssertNil(b.cached(r, key: key), "miss before a bake")
        let loc = try plant(r, key: key)
        XCTAssertEqual(loc.path, dir.appendingPathComponent("images/pi/\(key.prefix(12))").path)
        XCTAssertEqual(b.cached(r, key: key)?.root, loc.appendingPathComponent("root.ext4"))
        XCTAssertNil(b.cached(r, key: r.bakeKey(kernelSHA256: "other", deckholdSHA256: "d")), "another key misses")
        XCTAssertEqual(b.all(r).count, 1)
    }

    /// Only a COMPLETE bake is a hit: a directory without its disk, or whose manifest names another
    /// key (a 12-character prefix collision), is not.
    func test_incompleteOrMismatchedBakesAreMisses() throws {
        let r = AgentRecipes.claudeCode
        let key = r.bakeKey(kernelSHA256: "k", deckholdSHA256: "d")
        _ = try plant(r, key: key, withRoot: false)
        XCTAssertNil(ImageBaker(storeRoot: dir).cached(r, key: key))
        _ = try plant(r, key: key, manifestKey: String(key.prefix(12)) + "zzzz")
        XCTAssertNil(ImageBaker(storeRoot: dir).cached(r, key: key))
    }

    func test_bakeLockSerialises() async throws {
        let url = dir.appendingPathComponent("x.lock")
        let a = try await FileLock.acquire(url, waiting: {})
        let waited = Flag()
        let t = Task { let b = try await FileLock.acquire(url, waiting: { waited.set() }); b.release() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(waited.value, "a second baker waits for the first")
        a.release()
        try await t.value
    }

    func test_sizesReportApparentAndAllocated() throws {
        let f = dir.appendingPathComponent("sparse")
        FileManager.default.createFile(atPath: f.path, contents: nil)
        let h = try FileHandle(forWritingTo: f)
        try h.truncate(atOffset: 64 << 20)
        try h.close()
        let (apparent, allocated) = ImageBaker.sizes(f)
        XCTAssertEqual(apparent, 64 << 20)
        XCTAssertLessThan(allocated, 1 << 20, "a hole allocates nothing")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.withLock { v = true } }
    var value: Bool { lock.withLock { v } }
}
