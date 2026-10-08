import Foundation
import XCTest
@testable import DozerKit

final class ImageSpecTests: XCTestCase {
    private let k = String(repeating: "a", count: 64), d = String(repeating: "b", count: 64)

    /// The same imageSpec always bakes to the same key; ANY input change — a step, the base, the
    /// kernel, deckhold — is a different key (a different disk), and dictionary order is not.
    func test_bakeKeyIsStableAndSensitive() {
        let r = AgentImages.claudeCode
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
        XCTAssertNotEqual(AgentImages.claudeCode.bakeKey(kernelSHA256: k, deckholdSHA256: d),
                          AgentImages.pi.bakeKey(kernelSHA256: k, deckholdSHA256: d))
    }

    /// Values copied from the pinned imageSpecs: digest-pinned Debian node base, exact npm versions
    /// with their integrity, credential-free verification.
    func test_agentImageSpecsArePinned() throws {
        for r in [AgentImages.claudeCode, AgentImages.pi] {
            XCTAssertNoThrow(try r.validate(), r.name)
            XCTAssertEqual(r.base, "docker.io/library/node@sha256:d649c27dae7ba0137b3cef5dd75baa422c08dc3d9e3fc0c23dfb172dc3cc6436")
            XCTAssertEqual(r.user, "agent")
        }
        let cc = AgentImages.claudeCode.steps.map { $0.argv.joined(separator: " ") }.joined()
        XCTAssertTrue(cc.contains("@anthropic-ai/claude-code@2.1.227"))
        XCTAssertTrue(cc.contains("sha512-D0YP8GFwPaP/9eObEuP5LRO5+9QSD9CLa6K26whNzXxpxz3pFqPS3nn7l1/MLmSWy32wBP2IKQzkRB3mumUKUQ=="))
        let pi = AgentImages.pi.steps.map { $0.argv.joined(separator: " ") }.joined()
        XCTAssertTrue(pi.contains("@earendil-works/pi-coding-agent@0.84.1"))
        XCTAssertTrue(pi.contains("--ignore-scripts"))
        XCTAssertTrue(pi.contains("sha512-ncAqFrG+iybuPGOhMiZoEHkEzTpJgz3guYD32pD+M7ucc0WeHmauP6wa7qwP8V/KWvsZDVNa5XGsdZ7fkC7w7A=="))
        XCTAssertEqual(AgentImages.claudeCode.verify, [VerifyCheck(["claude", "--version"], expect: "2.1.227"),
                                                        VerifyCheck(["sh", "-c", "test -x /home/agent/.local/bin/claude && echo launcher-ok"], expect: "launcher-ok")]
                                                       + AgentImages.devBaselineVerify)
        // 591: every agent image carries the developer baseline (ps/top, git, rg, python3, …).
        for r in [AgentImages.claudeCode, AgentImages.pi] {
            let all = r.steps.map { $0.argv.joined(separator: " ") }.joined()
            for p in ["procps", "git", "ripgrep", "python3", "jq", "less", "openssh-client", "curl"] {
                XCTAssertTrue(all.contains(p), "\(r.name) installs \(p)")
            }
        }
        // 585: the launcher that starts Claude Code set up and without permission prompts.
        XCTAssertTrue(cc.contains("--dangerously-skip-permissions"))
        XCTAssertTrue(cc.contains("DOZ_CLAUDE_PERMISSIONS"))
        XCTAssertTrue(cc.contains("skipDangerousModePermissionPrompt"))
        XCTAssertEqual(AgentImages.pi.verify, [VerifyCheck(["pi", "--version"], expect: "0.84.1")] + AgentImages.devBaselineVerify)
        XCTAssertEqual(AgentImages.claudeCode.resolvedPersistDirs, ["/home/agent/.claude"])
        XCTAssertEqual(AgentImages.claudeCode.sessionEnvironment["CLAUDE_CONFIG_DIR"], "/home/agent/.claude")
        XCTAssertEqual(AgentImages.pi.resolvedPersistDirs, ["/home/agent/.pi/agent"])
    }

    /// A credential never reaches a bake: the bake environment is scrubbed, and a imageSpec that
    /// names one is rejected outright.
    func test_credentialsNeverReachABake() {
        let env = BakeEnvironment.scrubbed(["ANTHROPIC_API_KEY": "sk", "OPENAI_API_KEY": "x", "GITHUB_TOKEN": "t",
                                            "NPM_CONFIG_UPDATE_NOTIFIER": "false", "HOME": "/home/agent"])
        XCTAssertEqual(Set(env.keys), ["NPM_CONFIG_UPDATE_NOTIFIER", "HOME"])
        var bad = AgentImages.claudeCode
        bad.steps[1].environment["ANTHROPIC_API_KEY"] = "sk-ant"
        XCTAssertThrowsError(try bad.validate())
        var bad2 = AgentImages.pi
        bad2.sessionEnvironment["ANTHROPIC_API_KEY"] = "sk-ant"
        XCTAssertThrowsError(try bad2.validate())
        for r in [AgentImages.claudeCode, AgentImages.pi] {
            XCTAssertFalse(String(decoding: r.canonicalJSON, as: UTF8.self).contains("ANTHROPIC_API_KEY"))
        }
    }

    func test_imageSpecValidation() {
        var r = AgentImages.pi
        r.base = "docker.io/library/node:22"
        XCTAssertThrowsError(try r.validate(), "a base must be digest-pinned")
        var r2 = AgentImages.pi
        r2.persistDirs = ["relative/dir"]
        XCTAssertThrowsError(try r2.validate())
        var s = SandboxSpec(name: "a", storeRoot: URL(fileURLWithPath: "/tmp"), imageSpec: AgentImages.pi)
        XCTAssertNoThrow(try s.validate())
        s.shares = [Share(hostPath: "/tmp/x", guestPath: "/state")]
        XCTAssertThrowsError(try s.validate(), "/state belongs to the state disk")
    }

    /// Sessions of an image run as its user, in its workdir, with its environment — and the
    /// caller's credential on top; `user: "root"` overrides; a plain sandbox is unchanged.
    func test_sessionContext() {
        let (env, cwd, user) = Sandbox.sessionContext(imageSpec: AgentImages.claudeCode, environment: ["ANTHROPIC_API_KEY": "sk"],
                                                      workingDirectory: nil, user: nil)
        XCTAssertEqual(user, "agent")
        XCTAssertEqual(cwd, "/workspace")
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk")
        XCTAssertEqual(env["HOME"], "/home/agent")
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/home/agent/.claude")
        let asRoot = Sandbox.sessionContext(imageSpec: AgentImages.claudeCode, environment: [:], workingDirectory: "/", user: "root")
        XCTAssertNil(asRoot.user)
        XCTAssertNil(asRoot.environment["HOME"])
        let plain = Sandbox.sessionContext(imageSpec: nil, environment: ["A": "1"], workingDirectory: nil, user: nil)
        XCTAssertEqual(plain.workingDirectory, "/root")
        XCTAssertNil(plain.user)
        // 599: every session's PATH leads with the browser bridge's xdg-open, which is also $BROWSER.
        XCTAssertEqual(plain.environment, ["A": "1", "PATH": GuestCommand.openShimDirectory + ":" + GuestCommand.path,
                                           "BROWSER": GuestCommand.openShimPath])
    }

    /// The state disk: mounted at /state, one directory per persist dir, bind-mounted over it,
    /// owned by the imageSpec user; the deckhold socket dir is sticky + world-writable.
    /// 594 W23: passwordless sudo for the image's user — a validated drop-in at boot, removed when off;
    /// the agent images carry sudo and keep apt's package lists.
    func test_agentSudo() {
        let on = GuestCommand.agentSudoScript(user: "agent", on: true)
        XCTAssertTrue(on.contains("printf '%s ALL=(ALL) NOPASSWD:ALL\\n' 'agent'"))
        XCTAssertTrue(on.contains("chmod 0440"))
        XCTAssertTrue(on.contains("/usr/sbin/visudo -cf /run/dozer-agent-sudoers >/dev/null && mv -f"), "validated before it is put in place")
        XCTAssertTrue(on.contains("mv -f /run/dozer-agent-sudoers '/etc/sudoers.d/dozer-agent'"))
        XCTAssertTrue(on.hasPrefix("if [ -x /usr/bin/sudo ] && [ -x /usr/sbin/visudo ]"), "an image without sudo (or visudo) gets nothing")
        XCTAssertEqual(GuestCommand.agentSudoScript(user: "agent", on: false), "rm -f '/etc/sudoers.d/dozer-agent'")
        for odd in ["root", "", "a b", "x';rm -rf /;'", "1agent", "-agent", String(repeating: "a", count: 33)] {
            XCTAssertEqual(GuestCommand.agentSudoScript(user: odd, on: true), "rm -f '/etc/sudoers.d/dozer-agent'", odd)
        }
        XCTAssertTrue(GuestCommand.prepareGuest(imageSpec: AgentImages.pi).contains(on), "on by default at boot")
        XCTAssertTrue(GuestCommand.prepareGuest(imageSpec: AgentImages.pi, agentSudo: false).contains("rm -f '/etc/sudoers.d/dozer-agent'"))
        XCTAssertFalse(GuestCommand.prepareGuest(imageSpec: nil).contains("sudoers"), "the lab (root) gets no rule")
        XCTAssertTrue(AgentImages.devBaselinePackages.contains("sudo"))
        // 594 W24: apt-utils, installed before the rest, so no install says "debconf: delaying …".
        let base = "\(AgentImages.devBaseline)"
        let utils = base.range(of: "--no-install-recommends -o Dpkg::Use-Pty=0 apt-utils")
        let rest = base.range(of: "--no-install-recommends -o Dpkg::Use-Pty=0 procps")
        XCTAssertNotNil(utils)
        XCTAssertTrue(utils.flatMap { u in rest.map { u.lowerBound < $0.lowerBound } } == true, "apt-utils first")
        XCTAssertTrue(base.contains("DEBIAN_FRONTEND=noninteractive"))
        for spec in [AgentImages.claudeCode, AgentImages.pi] {
            let scripts = spec.steps.map { "\($0)" }.joined()
            XCTAssertFalse(scripts.contains("rm -rf /var/lib/apt/lists"), "\(spec.name): apt's lists are kept")
            XCTAssertFalse(scripts.contains("sudoers"), "\(spec.name): the rule is applied at boot, never baked")
        }
    }

    /// 594 W10: the guest's time zone — this Mac's TZif file, written at boot (every image) and wake.
    func test_guestTimeZone() throws {
        let tz = try XCTUnwrap(GuestTimeZone(named: "Australia/Sydney"))
        XCTAssertTrue(tz.tzif.starts(with: Data("TZif".utf8)))
        XCTAssertTrue(tz.script.contains(tz.tzif.base64EncodedString()))
        XCTAssertTrue(tz.script.contains("mv -f /etc/.doz-localtime /etc/localtime"))
        XCTAssertTrue(tz.script.contains("printf '%s\\n' 'Australia/Sydney' > /etc/timezone"))
        for bad in ["../../etc/passwd", "Australia/../../x", "a b", "x';rm -rf /;'", "", "Nowhere/Land"] {
            XCTAssertNil(GuestTimeZone(named: bad), bad)
        }
        XCTAssertNil(GuestTimeZone(name: "UTC", tzif: Data("not a zone".utf8)), "only TZif bytes")
        XCTAssertTrue(GuestCommand.prepareGuest(imageSpec: nil, timeZone: tz).contains(tz.script), "the lab too")
        XCTAssertTrue(GuestCommand.prepareGuest(imageSpec: AgentImages.pi, timeZone: tz).contains(tz.script))
        XCTAssertFalse(GuestCommand.prepareGuest(imageSpec: nil).contains("localtime"), "none given: the image's own")
    }

    /// 594 W30: /usr/games on a session's PATH (after /usr/bin, /bin), without a rebuild; W29: the guest's
    /// own name in /etc/hosts at boot.
    func test_gamesOnThePathAndTheOwnHostname() {
        XCTAssertEqual(Sandbox.withGames("/home/agent/.local/bin:/usr/local/bin:/usr/bin:/bin"),
                       "/home/agent/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/games")
        XCTAssertEqual(Sandbox.withGames("/usr/bin:/usr/games:/bin"), "/usr/bin:/usr/games:/bin", "idempotent")
        let ctx = Sandbox.sessionContext(imageSpec: AgentImages.pi, environment: [:], workingDirectory: nil, user: nil)
        XCTAssertTrue(ctx.environment["PATH"]!.hasSuffix(":/usr/bin:/bin:/usr/games"))
        XCTAssertTrue(GuestCommand.prepareGuest(imageSpec: nil).contains("printf '127.0.1.1\\t%s\\n' \"$h\" >> /etc/hosts"))
    }

    /// 594 W34: the live-safe guest fixes run at every wake as well as at boot — and carry nothing that
    /// must not run under live sessions (the deckhold socket reset, the bind mounts).
    func test_guestFixesAreTheLiveSafePartOfTheBoot() throws {
        let tz = try XCTUnwrap(GuestTimeZone(named: "Australia/Sydney"))
        let fixes = GuestCommand.guestFixes(imageSpec: AgentImages.pi, agentSudo: true, timeZone: tz)
        for part in [GuestCommand.ownHostnameScript, GuestCommand.debconfNoninteractiveScript, GuestCommand.openShimInstall,
                     tz.script, GuestCommand.agentSudoScript(user: "agent", on: true)] {
            XCTAssertTrue(fixes.contains(part))
        }
        XCTAssertTrue(GuestCommand.guestFixes(imageSpec: AgentImages.pi, agentSudo: false).contains("rm -f '/etc/sudoers.d/dozer-agent'"), "follows the setting")
        for live in ["/run/deckhold", "mount --bind", "set -e"] {
            XCTAssertFalse(fixes.contains(live), "never at a wake: \(live)")
        }
        XCTAssertTrue(GuestCommand.prepareGuest(imageSpec: AgentImages.pi, timeZone: tz).contains(fixes), "the boot runs the same fixes")
        XCTAssertFalse(GuestCommand.guestFixes(imageSpec: nil).contains("sudoers"), "the lab (root) gets no rule")
    }

    func test_stateDiskLayoutScript() {
        XCTAssertEqual(GuestCommand.stateKey("/home/agent/.pi/agent"), "home_agent_.pi_agent")
        let s = GuestCommand.prepareGuest(imageSpec: AgentImages.pi)
        XCTAssertTrue(s.contains("chmod 1777 /run/deckhold"))
        XCTAssertTrue(s.contains("mkdir -p '/state/home_agent_.pi_agent' '/home/agent/.pi/agent'"))
        XCTAssertTrue(s.contains("mount --bind '/state/home_agent_.pi_agent' '/home/agent/.pi/agent'"))
        XCTAssertTrue(s.contains("mountpoint -q '/home/agent/.pi/agent' ||"), "idempotent")
        XCTAssertTrue(s.contains("chown agent:agent '/state/home_agent_.pi_agent'"))
        XCTAssertEqual(GuestCommand.prepareGuest(imageSpec: nil), "set -e; rm -rf /run/deckhold; mkdir -p /run/deckhold; chmod 1777 /run/deckhold; "
                       // 599g: the last boot's view records go (/run is on the root disk)
                       + "rm -rf '/run/doz/view'; for d in '/run/doz/raw'/*; do [ -d \"$d\" ] && ! mountpoint -q \"$d\" && rmdir \"$d\" 2>/dev/null; done; true; "
                       + GuestCommand.ownHostnameScript + "; " + GuestCommand.debconfNoninteractiveScript + "; " + GuestCommand.openShimInstall
                       // 599d: git's helper, the (empty) Dozer git config, no SSH agent.
                       + "; " + GuestCommand.gitCredentialInstall + "; " + GuestCommand.gitConfigScript(.off) + "; " + GuestCommand.sshAgentScript(on: false),
                       "a kept root disk must not carry the last boot's sessions")
        let layout = StoreLayout(root: URL(fileURLWithPath: "/tmp/s"), name: "lab")
        XCTAssertEqual(layout.stateDisk.path, "/tmp/s/sandboxes/lab/state.ext4")
        // The state disk outlives root disks: Stop and Reset to image never remove the sandbox
        // directory; only Delete does.
        for p in Phase.allCases {
            XCTAssertFalse(LifecyclePlanner.plan(.stop, from: p)?.contains(.removeSandboxFiles) ?? false)
            XCTAssertFalse(LifecyclePlanner.plan(.resetToImage, from: p)!.contains(.removeSandboxFiles))
        }
    }
}

final class ImageBakerCacheTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-baker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func plant(_ imageSpec: ImageSpec, key: String, manifestKey: String? = nil, withRoot: Bool = true) throws -> URL {
        let b = ImageBaker(storeRoot: dir)
        let loc = b.location(imageSpec, key: key)
        try FileManager.default.createDirectory(at: loc, withIntermediateDirectories: true)
        if withRoot { try Data("disk".utf8).write(to: loc.appendingPathComponent("root.ext4")) }
        let m = ImageManifest(key: manifestKey ?? key, imageSpec: imageSpec, kernelSHA256: "k", deckholdSHA256: "d", bakedAt: Date(),
                              timings: [.init(step: "bake", milliseconds: 1)], apparentBytes: 4, allocatedBytes: 4, verifyOutput: ["ok"])
        try ImageBaker.encoder.encode(m).write(to: loc.appendingPathComponent("manifest.json"))
        return loc
    }

    func test_cacheHitAndMiss() throws {
        let r = AgentImages.pi
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
        let r = AgentImages.claudeCode
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

    /// 587: the base key is the digest + capacity + journal + formatter — the two agent imageSpecs
    /// share one base; a journal or capacity change is another base; the lineage format and the
    /// journal are in every bake key.
    func test_baseKeyIsSharedAndSensitive() {
        let cc = AgentImages.claudeCode, pi = AgentImages.pi
        XCTAssertEqual(cc.baseKey, pi.baseKey, "claude-code and pi bake on one base disk")
        var j = cc; j.journalMiB = nil
        var j32 = cc; j32.journalMiB = 32
        var cap = cc; cap.rootfsMiB = 8192
        var other = cc; other.base = "docker.io/library/node@sha256:" + String(repeating: "c", count: 64)
        var renamed = cc; renamed.base = "example.org/mirror/node@" + cc.base.split(separator: "@").last!
        XCTAssertEqual(Set([cc.baseKey, j.baseKey, j32.baseKey, cap.baseKey, other.baseKey]).count, 5)
        XCTAssertEqual(renamed.baseKey, cc.baseKey, "the digest names the base, not the repository")
        var step = cc; step.steps.append(BakeStep("x", argv: ["true"]))
        XCTAssertEqual(step.baseKey, cc.baseKey, "steps are the image's, not the base's")
        XCTAssertNotEqual(j.bakeKey(kernelSHA256: "k", deckholdSHA256: "d"), cc.bakeKey(kernelSHA256: "k", deckholdSHA256: "d"))
    }

    /// 587: an image manifest written before 587 (no parent, trim or journal) still decodes; `images/bases`
    /// and `images/custom` are the store's own names.
    func test_oldManifestsDecodeAndReservedNames() throws {
        let r = AgentImages.pi
        let key = r.bakeKey(kernelSHA256: "k", deckholdSHA256: "d")
        let loc = try plant(r, key: key)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: loc.appendingPathComponent("manifest.json"))) as! [String: Any]
        for k in ["parent", "trimmedBytes", "journalMiB"] { json.removeValue(forKey: k) }
        var imageSpec = json["imageSpec"] as! [String: Any]
        imageSpec.removeValue(forKey: "journalMiB")
        json["imageSpec"] = imageSpec
        try JSONSerialization.data(withJSONObject: json).write(to: loc.appendingPathComponent("manifest.json"))
        let m = try XCTUnwrap(ImageBaker(storeRoot: dir).all(r).first?.manifest)
        XCTAssertNil(m.parent)
        XCTAssertNil(m.imageSpec.journalMiB, "a pre-587 image spec decodes journal-less")
        for n in ["bases", "custom"] {
            var x = r; x.name = n
            XCTAssertThrowsError(try x.validate(), n)
        }
    }

    /// 587: image keys resolve to their disks.
    func test_imageDiskForKey() throws {
        let r = AgentImages.pi
        let key = r.bakeKey(kernelSHA256: "k", deckholdSHA256: "d")
        let loc = try plant(r, key: key)
        let layout = StoreLayout(root: dir, name: "x")
        XCTAssertEqual(layout.imageDisk(forKey: "pi@\(key.prefix(12))"), loc.appendingPathComponent("root.ext4"))
        XCTAssertNil(layout.imageDisk(forKey: "pi@000000000000"))
        let golden = layout.goldenDirectory.appendingPathComponent("alpine-3.20-abcdefabcdef.ext4")
        try FileManager.default.createDirectory(at: layout.goldenDirectory, withIntermediateDirectories: true)
        try Data("d".utf8).write(to: golden)
        XCTAssertEqual(layout.imageDisk(forKey: "alpine-3.20-abcdefabcdef"), golden)
        let custom = layout.customImageDirectory("mine/rp-1")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try Data("d".utf8).write(to: custom.appendingPathComponent("root.ext4"))
        XCTAssertEqual(layout.imageDisk(forKey: "custom:mine/rp-1"), custom.appendingPathComponent("root.ext4"))
        let base = ImageBaker(storeRoot: dir).baseLocation(r.baseKey)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("d".utf8).write(to: base.appendingPathComponent("root.ext4"))
        XCTAssertEqual(layout.imageDisk(forKey: "base:\(r.baseKey)"), base.appendingPathComponent("root.ext4"))
        XCTAssertNil(ImageBaker(storeRoot: dir).cachedBase(r.baseKey), "a base without its manifest is not complete")
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
