import Foundation
import DozerKit
import XCTest
@testable import DozerHost

/// 594 (owner, 2026-09-30: "Can we install (optionally) "latest" claude code (default true)?"): latest
/// resolved at preparation time — a stubbed registry, never the network.
final class AgentVersionsTests: XCTestCase {
    var root: URL!
    var store: DozerStore { DozerStore(root: root) }
    let latest = DozerSettings(text: nil)
    let newer = AgentRelease(version: "2.1.230", integrity: "sha512-" + String(repeating: "A", count: 86) + "==")
    let newest = AgentRelease(version: "2.1.231", integrity: "sha512-" + String(repeating: "B", count: 86) + "==")

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/dzav-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A registry that answers `answers[tag]` (or throws) and counts its lookups.
    final class Stub: @unchecked Sendable {
        let lock = NSLock()
        var answers: [String: AgentRelease] = [:]
        var fail: String?
        var calls: [String] = []
        var registry: NpmRegistry {
            NpmRegistry { [self] package, tag in
                try lock.withLock {
                    calls.append("\(package)@\(tag)")
                    if let f = fail { throw HostError(.unavailable, f) }
                    guard let r = answers[tag] else { throw HostError(.notFound, "no \(package)@\(tag)") }
                    return r
                }
            }
        }
    }

    func testTheRegistrysAnswerIsParsedStrictly() throws {
        let good = #"{"name":"@anthropic-ai/claude-code","version":"2.1.285","dist":{"integrity":"sha512-frr0DLmVHSDN+/x=="}}"#
        XCTAssertEqual(try NpmRegistry.parse(Data(good.utf8), package: "p", tag: "latest").version, "2.1.285")
        for bad in [#"{"version":"2.1.285"}"#,                                                          // no integrity
                    #"{"version":"2.1.285'; rm -rf /","dist":{"integrity":"sha512-abc"}}"#,          // not a version
                    #"{"version":"2.1.285","dist":{"integrity":"sha512-a' || true #"}}"#,            // not an integrity
                    #"{"version":"2.1.285","dist":{"integrity":"sha1-abc"}}"#,                       // not sha512
                    "not json"] {
            XCTAssertThrowsError(try NpmRegistry.parse(Data(bad.utf8), package: "p", tag: "latest"), bad)
        }
        // An exact version must come back as itself.
        XCTAssertThrowsError(try NpmRegistry.parse(Data(good.utf8), package: "p", tag: "2.1.227"))
        XCTAssertEqual(try NpmRegistry.parse(Data(good.utf8), package: "p", tag: "2.1.285").version, "2.1.285")
    }

    func testVersionsOrderNumerically() {
        XCTAssertTrue(AgentRelease.isNewer("2.1.230", than: "2.1.227"))
        XCTAssertTrue(AgentRelease.isNewer("2.10.0", than: "2.9.9"))
        XCTAssertFalse(AgentRelease.isNewer("2.1.227", than: "2.1.227"))
        XCTAssertTrue(AgentRelease.isNewer("2.1.227", than: "2.1.227-beta.1"))
        XCTAssertFalse(AgentRelease.isNewer("0.84.1", than: "0.99.1"))
    }

    /// The version is in the spec, so in the bake key: one image is one exact version.
    func testTheVersionIsInTheSpecAndTheBakeKey() throws {
        let a = AgentImages.claudeCode(newer), b = AgentImages.claudeCode(newest), pin = AgentImages.claudeCode
        XCTAssertEqual(a.agent, AgentPackage(package: "@anthropic-ai/claude-code", version: "2.1.230"))
        XCTAssertEqual(pin.agent?.version, "2.1.227")
        XCTAssertNotEqual(a.bakeKey(kernelSHA256: "k", deckholdSHA256: "d"), b.bakeKey(kernelSHA256: "k", deckholdSHA256: "d"))
        XCTAssertEqual(a.bakeKey(kernelSHA256: "k", deckholdSHA256: "d"), AgentImages.claudeCode(newer).bakeKey(kernelSHA256: "k", deckholdSHA256: "d"))
        let script = a.steps.first { $0.name.hasPrefix("npm install") }!.argv.last!
        XCTAssertTrue(script.contains("'@anthropic-ai/claude-code@2.1.230'") && script.contains(newer.integrity), "installed at that version, integrity-checked")
        XCTAssertEqual(a.verify.first?.expect, "2.1.230")
        XCTAssertEqual(AgentVersions.integrity(in: a), newer.integrity)
        XCTAssertNoThrow(try a.validate())
        XCTAssertEqual(AgentImages.pi(AgentRelease(version: "0.99.1", integrity: newer.integrity)).agent?.version, "0.99.1")
        // pi's (and any agent's) tools are baked, never downloaded: fd (Debian's fdfind, linked) and rg.
        for img in [a, AgentImages.pi] {
            let baseline = img.steps.first { $0.name.hasPrefix("install the developer baseline") }!.argv.last!
            XCTAssertTrue(baseline.contains("fd-find") && baseline.contains("ripgrep") && baseline.contains("ln -sf /usr/bin/fdfind /usr/local/bin/fd"))
            XCTAssertTrue(img.verify.contains { $0.argv.last!.contains(" rg fd ") })
        }
        XCTAssertTrue(DozerImages.labPackages.contains("fd"))
        // Claude Code never updates itself in a sandbox.
        XCTAssertEqual(a.sessionEnvironment["DISABLE_AUTOUPDATER"], "1")
        XCTAssertEqual(a.sessionEnvironment["DISABLE_UPDATES"], "1")
    }

    func testTheSettingsAreLatestByDefaultOrAnExactVersion() throws {
        XCTAssertEqual(AgentVersions.setting("claude-code", latest), "latest")
        XCTAssertEqual(AgentVersions.setting("pi", latest), "latest")
        let d = try XCTUnwrap(DozerSettings.definition(SettingKey.claudeCodeVersion))
        for ok in ["latest", "2.1.227", "3.0.0-beta.2"] { XCTAssertNoThrow(try d.parse(ok), ok) }
        for bad in ["2.1", "^2.1.0", "next", "2.1.227 ; x", "~1.0.0", ""] { XCTAssertThrowsError(try d.parse(bad), bad) }
        let pinned = DozerSettings(text: "[images]\nclaude_code_version = \"2.1.227\"\npi_version = \"latest\"\n")
        XCTAssertEqual(pinned.warnings, [])
        XCTAssertEqual(AgentVersions.setting("claude-code", pinned), "2.1.227")
    }

    /// latest: asked once, trusted for an hour, asked again after; a failure is recorded, never thrown.
    func testLatestIsAskedHourlyAndAFailureIsTolerated() async throws {
        let stub = Stub()
        stub.answers["latest"] = newer
        let t0 = Date()
        var f = await AgentVersions.refresh("claude-code", store: store, settings: latest, registry: stub.registry, now: t0)
        XCTAssertEqual(f.latest, "2.1.230")
        XCTAssertTrue(f.looked)
        f = await AgentVersions.refresh("claude-code", store: store, settings: latest, registry: stub.registry, now: t0.addingTimeInterval(1800))
        XCTAssertFalse(f.looked, "within the hour: the cache")
        XCTAssertEqual(stub.calls.count, 1)
        stub.answers["latest"] = newest
        f = await AgentVersions.refresh("claude-code", store: store, settings: latest, registry: stub.registry, now: t0.addingTimeInterval(3700))
        XCTAssertEqual(f.latest, "2.1.231")
        XCTAssertEqual(stub.calls, ["@anthropic-ai/claude-code@latest", "@anthropic-ai/claude-code@latest"])
        // Offline: recorded, the last answer kept, not asked again for 5 minutes.
        stub.fail = "offline"
        let t1 = t0.addingTimeInterval(8000)
        f = await AgentVersions.refresh("claude-code", store: store, settings: latest, registry: stub.registry, now: t1)
        XCTAssertEqual(f.error, "offline")
        XCTAssertEqual(f.latest, "2.1.231", "the last answer stands")
        XCTAssertEqual(AgentVersions.all(store)["claude-code"]?.latest?.version, "2.1.231")
        _ = await AgentVersions.refresh("claude-code", store: store, settings: latest, registry: stub.registry, now: t1.addingTimeInterval(60))
        XCTAssertEqual(stub.calls.count, 3, "a failed lookup is not retried at once")
        // A disabled registry asks nothing.
        f = await AgentVersions.refresh("claude-code", store: store, settings: latest, registry: .disabled, now: t1.addingTimeInterval(9999))
        XCTAssertFalse(f.looked)
        // The pi image is its own record.
        stub.fail = nil
        stub.answers["latest"] = AgentRelease(version: "0.99.1", integrity: newer.integrity)
        _ = await AgentVersions.refresh("pi", store: store, settings: latest, registry: stub.registry, now: t1)
        XCTAssertEqual(stub.calls.last, "@earendil-works/pi-coding-agent@latest")
        XCTAssertEqual(AgentVersions.all(store)["pi"]?.latest?.version, "0.99.1")
    }

    /// Which spec a preparation makes, and a create gets.
    func testResolution() async throws {
        // Never asked (an in-process host, a test): the built-in pin.
        XCTAssertEqual(try AgentVersions.spec("claude-code", purpose: .prepare, store: store, settings: latest)?.agent?.version, "2.1.227")
        XCTAssertNil(try AgentVersions.spec("lab", purpose: .create, store: store, settings: latest))
        // Resolved: latest, for a preparation and — nothing prepared — for a create.
        let stub = Stub()
        stub.answers["latest"] = newer
        await AgentVersions.refresh("claude-code", store: store, settings: latest, registry: stub.registry)
        XCTAssertEqual(try AgentVersions.spec("claude-code", purpose: .prepare, store: store, settings: latest)?.agent?.version, "2.1.230")
        XCTAssertEqual(try AgentVersions.spec("claude-code", purpose: .create, store: store, settings: latest)?.agent?.version, "2.1.230")
        XCTAssertEqual(try DozerImages.spec(name: "x", options: CreateOptions(image: "claude-code"), store: store, environment: [:], purpose: .prepare).0.imageSpec?.agent?.version,
                       "2.1.230")
        // An exact setting: the pin, or a version this store knows; one it does not know says so.
        let exact = DozerSettings(text: "[images]\nclaude_code_version = \"2.1.230\"\n")
        XCTAssertEqual(try AgentVersions.spec("claude-code", purpose: .prepare, store: store, settings: exact)?.agent?.version, "2.1.230", "known from the lookup")
        let unknown = DozerSettings(text: "[images]\nclaude_code_version = \"2.1.200\"\n")
        XCTAssertThrowsError(try AgentVersions.spec("claude-code", purpose: .prepare, store: store, settings: unknown)) {
            XCTAssertTrue(("\($0)" + ((($0 as? HostError)?.message) ?? "")).contains("2.1.227 is built in"), "\($0)")
        }
        stub.answers["2.1.200"] = AgentRelease(version: "2.1.200", integrity: newer.integrity)
        await AgentVersions.refresh("claude-code", store: store, settings: unknown, registry: stub.registry)
        XCTAssertEqual(try AgentVersions.spec("claude-code", purpose: .prepare, store: store, settings: unknown)?.agent?.version, "2.1.200",
                       "an exact version not known is asked for once, then known")
    }

    /// latest with no network and no image: a clear error naming an exact version.
    func testOfflineWithNothingPreparedSaysWhatToDo() async throws {
        let stub = Stub()
        stub.fail = "the Internet connection appears to be offline"
        await AgentVersions.refresh("claude-code", store: store, settings: latest, registry: stub.registry)
        XCTAssertThrowsError(try AgentVersions.spec("claude-code", purpose: .create, store: store, settings: latest)) {
            let m = ($0 as? HostError)?.message ?? ""
            XCTAssertTrue(m.contains("could not be reached") && m.contains("doz config set images.claude_code_version 2.1.227"), m)
        }
        // An exact pin always works from what the store has.
        let pinned = DozerSettings(text: "[images]\nclaude_code_version = \"2.1.227\"\n")
        XCTAssertEqual(try AgentVersions.spec("claude-code", purpose: .create, store: store, settings: pinned)?.agent?.version, "2.1.227")
    }

    /// Behind: the image prepared for this build is older than latest — a create uses it (no
    /// waiting), a preparation makes the new one; ls says both.
    func testBehindIsDetectedAndACreateDoesNotWait() async throws {
        guard let build = fakeBuild() else { throw XCTSkip("no deckhold binary in this build") }
        try bake(AgentImages.claudeCode, build)                                  // 2.1.227 prepared
        XCTAssertEqual(AgentVersions.prepared("claude-code", store: store, settings: latest).map { $0.agent!.version }, ["2.1.227"])
        XCTAssertNil(AgentVersions.behind("claude-code", store: store, settings: latest), "latest never asked: not behind")
        let stub = Stub()
        stub.answers["latest"] = newer
        await AgentVersions.refresh("claude-code", store: store, settings: latest, registry: stub.registry)
        let b = try XCTUnwrap(AgentVersions.behind("claude-code", store: store, settings: latest))
        XCTAssertEqual(b.current, "2.1.227")
        XCTAssertEqual(b.target, "2.1.230")
        XCTAssertEqual(try AgentVersions.spec("claude-code", purpose: .create, store: store, settings: latest)?.agent?.version, "2.1.227", "a create uses the prepared one")
        XCTAssertEqual(try AgentVersions.spec("claude-code", purpose: .prepare, store: store, settings: latest)?.agent?.version, "2.1.230")

        // The host: a create uses 2.1.227 and — 594 W28 (owner ruling) — starts NO preparation of
        // 2.1.230: a newer release is said (image ls, doctor, create), never built by itself.
        let core = HostCore(store: store, readOnly: false, version: "test", agentRegistry: stub.registry)
        let ran = Stub()
        await core.setPreparationRunner({ image, _, _ in
            ran.lock.withLock { ran.calls.append(image) }
            try await Task.sleep(for: .seconds(30))
        }, prepared: { _, _ in true })
        var r = HostRequest(.create, name: "cc1")
        r.create = CreateOptions(image: "claude-code")
        let m = await core.handle(r)
        let info = try XCTUnwrap(m.result, "\(String(describing: m.error))").decode(SandboxInfo.self)
        XCTAssertEqual(info.name, "cc1")
        XCTAssertEqual(SandboxConfig.read(store.configFile("cc1"))?.spec.imageSpec?.agent?.version, "2.1.227", "the sandbox made now: the prepared image")
        try await Task.sleep(for: .milliseconds(200))
        let preps = await core.preparationInfos()
        XCTAssertTrue(preps.isEmpty, "nothing is prepared by itself: \(preps.map(\.requestedBy))")
        XCTAssertTrue(ran.lock.withLock { ran.calls.isEmpty })
        let rows = try await core.handle(HostRequest(.imageList)).result!.decode([ImageRow].self)
        let cc = try XCTUnwrap(rows.first { $0.name == "claude-code" })
        XCTAssertEqual(cc.version, "2.1.227")
        XCTAssertEqual(cc.available, "2.1.230")
        XCTAssertNil(cc.preparing)
        XCTAssertEqual(cc.versionLine, "claude-code 2.1.227 (2.1.230 available)")
        XCTAssertEqual(cc.status, "update available")
        XCTAssertEqual(cc.standing, "Claude Code 2.1.230 is available (image has 2.1.227) — rebuild when ready: doz image bake claude-code (existing sandboxes keep their disks)")
        await core.cancelAllPreparations(wait: 2)

        // Up to date: 2.1.230 prepared too — nothing available, the newest is what a create gets.
        try bake(AgentImages.claudeCode(newer), build)
        XCTAssertNil(AgentVersions.behind("claude-code", store: store, settings: latest))
        XCTAssertEqual(try AgentVersions.spec("claude-code", purpose: .create, store: store, settings: latest)?.agent?.version, "2.1.230")
        let row = try await core.handle(HostRequest(.imageList)).result!.decode([ImageRow].self).first { $0.name == "claude-code" }
        XCTAssertEqual(row?.versionLine, "claude-code 2.1.230 (latest)")
        // An older build's bake does not count as prepared.
        let other = AgentImages.claudeCode(newest)
        try write(other, key: other.bakeKey(kernelSHA256: "old-kernel", deckholdSHA256: build.1))
        XCTAssertEqual(AgentVersions.prepared("claude-code", store: store, settings: latest).first?.agent?.version, "2.1.230")
    }

    /// 594 W28: an image an OLDER doz's recipe baked (rc.1: no sudo, package lists deleted) is not "this
    /// build's image": named precisely, used as it is by a create (never rebuilt by itself), a create with
    /// `rebuild` prepares first, and a reset after the rebuild moves the sandbox to the new image.
    func testAnOlderDozsImageIsNamedUsedAndNeverRebuiltByItself() async throws {
        guard let build = fakeBuild() else { throw XCTSkip("no deckhold binary in this build") }
        var old = AgentImages.claudeCode
        let oldPackages = AgentImages.devBaselinePackages.filter { $0 != "sudo" && $0 != "apt-utils" }
        old.steps[1] = BakeStep.script("install the developer baseline (\(oldPackages.joined(separator: " ")))",
                                       "apt-get update\napt-get install -y \(oldPackages.joined(separator: " "))\nrm -rf /var/lib/apt/lists/*\n")
        try bake(old, build)
        XCTAssertFalse(AgentVersions.isCurrentRecipe(old))
        XCTAssertTrue(AgentVersions.isCurrentRecipe(AgentImages.claudeCode))
        XCTAssertEqual(AgentVersions.recipeChanges(old), ["sudo", "apt-utils", "package lists"])
        // 599 (594.B3): an image 0.12.0-rc.9 prepared (sudo, apt-utils — no tmux) is named for what it lacks.
        var rc9 = AgentImages.claudeCode
        let rc9Packages = AgentImages.devBaselinePackages.filter { $0 != "tmux" }
        rc9.steps[1] = BakeStep.script("install the developer baseline (\(rc9Packages.joined(separator: " ")))", "apt-get install -y \(rc9Packages.joined(separator: " "))\n")
        XCTAssertEqual(AgentVersions.recipeChanges(rc9), ["tmux"])
        XCTAssertTrue(AgentVersions.prepared("claude-code", store: store, settings: latest).isEmpty, "not this build's image")
        XCTAssertEqual(AgentVersions.usable("claude-code", store: store, settings: latest), [old])
        XCTAssertEqual(try AgentVersions.spec("claude-code", purpose: .create, store: store, settings: latest), old, "a create uses it — no waiting, no rebuild")
        XCTAssertFalse(HostCore.isPrepared("claude-code", store))

        let core = HostCore(store: store, readOnly: false, version: "test")
        let ran = Stub()
        await core.setPreparationRunner({ image, _, _ in ran.lock.withLock { ran.calls.append(image) } }, prepared: { _, _ in false })
        let rows = try await core.handle(HostRequest(.imageList)).result!.decode([ImageRow].self)
        let cc = try XCTUnwrap(rows.first { $0.name == "claude-code" })
        XCTAssertEqual(cc.status, "older recipe")
        XCTAssertEqual(cc.olderRecipe, ["sudo", "apt-utils", "package lists"])
        XCTAssertEqual(cc.standing, "prepared by an older doz — this doz's image adds: sudo, apt-utils, package lists — rebuild when ready: doz image bake claude-code (existing sandboxes keep their disks)")
        let s = AgentVersions.standing("claude-code", store: store, settings: latest)
        XCTAssertEqual(s.olderRecipeLine, "prepared by an older doz — this doz's image adds: sudo, apt-utils, package lists")

        // A create: the older image, said; nothing prepared.
        var r = HostRequest(.create, name: "cc2")
        r.create = CreateOptions(image: "claude-code", account: "none")
        let made = await core.handle(r)
        let info = try XCTUnwrap(made.result, "\(String(describing: made.error))").decode(SandboxInfo.self)
        XCTAssertEqual(info.olderImage, ["sudo", "apt-utils", "package lists"],
                       "spec used: \(String(describing: SandboxConfig.read(store.configFile("cc2"))?.spec.imageSpec?.steps.map(\.name)))")
        XCTAssertTrue((info.olderImageLine ?? "").hasPrefix("made from an older claude-code image (it lacks: sudo, apt-utils, package lists) — after a rebuild (doz image bake claude-code), doz reset cc2 takes the new one"))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(ran.lock.withLock { ran.calls.isEmpty }, "nothing rebuilt by itself")

        // A create that asks for the rebuild: the preparation runs first (here: it "bakes" this doz's recipe).
        let rootURL: URL = root
        let current = AgentImages.claudeCode
        let key = current.bakeKey(kernelSHA256: build.0, deckholdSHA256: build.1)
        await core.setPreparationRunner({ image, _, _ in
            ran.lock.withLock { ran.calls.append(image) }
            try AgentVersionsTests.write(current, key: key, root: rootURL)
        }, prepared: { _, _ in false })
        var rb = HostRequest(.create, name: "cc3")
        var o = CreateOptions(image: "claude-code", account: "none")
        o.rebuild = true
        rb.create = o
        let rebuilt = await core.handle(rb)
        let fresh = try XCTUnwrap(rebuilt.result, "\(String(describing: rebuilt.error))").decode(SandboxInfo.self)
        XCTAssertEqual(ran.lock.withLock { ran.calls }, ["claude-code"])
        XCTAssertNil(fresh.olderImage, "made from this doz's image")
        // The older sandbox, reset: it takes the image a create takes now.
        let reset = await core.handle(HostRequest(.reset, name: "cc2"))
        XCTAssertNil(reset.error)
        XCTAssertEqual(SandboxConfig.read(store.configFile("cc2"))?.spec.imageSpec, AgentImages.claudeCode)
        let inspected = await core.handle(HostRequest(.inspect, name: "cc2"))
        let after = try XCTUnwrap(inspected.result).decode(SandboxDetail.self)
        XCTAssertNil(after.info.olderImage)
    }

    func testTheVersionLine() {
        var r = ImageRow(name: "claude-code", kind: "builtin", baked: false)
        XCTAssertNil(r.versionLine, "not an agent image's row")
        r.versionSetting = "latest"
        XCTAssertEqual(r.versionLine, "claude-code latest when prepared")
        r.available = "2.1.285"
        XCTAssertEqual(r.versionLine, "claude-code 2.1.285 when prepared")
        r.version = "2.1.227"
        r.preparing = true
        XCTAssertEqual(r.versionLine, "claude-code 2.1.227 (2.1.285 available — preparing)")
        r.available = nil
        r.latest = "2.1.227"
        XCTAssertEqual(r.versionLine, "claude-code 2.1.227 (latest)")
        r.versionSetting = "2.1.227"
        XCTAssertEqual(r.versionLine, "claude-code 2.1.227 (pinned)")
    }

    // MARK: helpers

    /// A kernel file in the store's cache (the hashes are all that matter here).
    func fakeBuild() -> (String, String)? {
        let k = KernelProvider(cacheDirectory: store.layout("_").kernels).cachedKernel
        try? FileManager.default.createDirectory(at: k.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("a kernel".utf8).write(to: k)
        return AgentVersions.buildHashes(store, latest).map { ($0.kernel, $0.deckhold) }
    }

    func bake(_ spec: ImageSpec, _ build: (String, String)) throws {
        try write(spec, key: spec.bakeKey(kernelSHA256: build.0, deckholdSHA256: build.1))
    }

    func write(_ spec: ImageSpec, key: String) throws { try Self.write(spec, key: key, root: root) }

    static func write(_ spec: ImageSpec, key: String, root: URL) throws {
        let dir = ImageBaker(storeRoot: root).imageDirectory(spec).appendingPathComponent(String(key.prefix(12)))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("root.ext4"))
        let m = ImageManifest(key: key, imageSpec: spec, kernelSHA256: "k", deckholdSHA256: "d", bakedAt: Date(),
                              timings: [], apparentBytes: 1, allocatedBytes: 1, verifyOutput: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .custom { date, e in
            var c = e.singleValueContainer()
            try c.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
        }
        try enc.encode(m).write(to: dir.appendingPathComponent("manifest.json"))
    }
}
