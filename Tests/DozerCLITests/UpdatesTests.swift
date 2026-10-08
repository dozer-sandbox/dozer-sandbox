import CryptoKit
import Foundation
import XCTest
@testable import DozerCLI
@testable import DozerHost
import DozerWeb

/// 611 — the updater's model with a THROWAWAY key and a fake fetch: signatures, a tampered entry, channels, never a
/// downgrade, the daily throttle, conditional requests, offline silence, a problem said once, install methods, the
/// lines people read. (`make test-updates` drives the real binary through publish → a local feed → install.)
final class UpdatesTests: XCTestCase {
    private var dir: URL!
    let key = Curve25519.Signing.PrivateKey()
    var pub: Data { key.publicKey.rawRepresentation }

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: "/tmp/d611u-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func entry(_ v: String, build: Int, channel: String, sign: Curve25519.Signing.PrivateKey? = nil) -> UpdateEntry {
        var e = UpdateEntry(version: v, build: build, channel: channel, date: "2026-10-09", notes: "https://updates.dozersandbox.com/v1/notes/\(v).html",
                            archive: "https://github.com/dozer-sandbox/dozer-sandbox/releases/download/v\(v)/doz-\(v)-macos-arm64.tar.gz",
                            size: 1000 + build, sha256: String(repeating: "ab", count: 32), signature: "")
        e.signature = try! (sign ?? key).signature(for: UpdateSignature.message(e)).base64EncodedString()
        return e
    }

    func feed(_ entries: [UpdateEntry]) -> Data {
        try! JSONEncoder().encode(UpdateFeed(schema: 1, product: "doz", entries: entries))
    }

    func ctx(_ current: String = "0.31.0", channel: UpdateChannel = .stable, mode: UpdateMode = .notify,
             method: InstallMethod = .tarball(prefix: URL(fileURLWithPath: "/x"))) -> UpdateContext {
        UpdateContext(mode: mode, channel: channel, current: current, method: method,
                      feedURL: URL(string: "https://updates.dozersandbox.com/v1/feed.json")!, publicKey: pub,
                      stateURL: dir.appendingPathComponent("updates.json"), testWithoutFeed: false)
    }

    /// A fake feed server: answers `body` (200 with an ETag), 304 when the ETag is sent back, or fails (offline).
    final class FakeFeed: @unchecked Sendable {
        let lock = NSLock()
        var body = Data()
        var offline = false
        var requests: [URLRequest] = []
        var fetch: UpdateFetch {
            { req in
                try self.lock.withLock {
                    self.requests.append(req)
                    if self.offline { throw URLError(.notConnectedToInternet) }
                    let tag = "\"\(self.body.count)-\(self.body.hashValue)\""
                    if req.value(forHTTPHeaderField: "If-None-Match") == tag {
                        return (Data(), HTTPURLResponse(url: req.url!, statusCode: 304, httpVersion: nil, headerFields: [:])!)
                    }
                    return (self.body, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["ETag": tag])!)
                }
            }
        }
    }

    // MARK: the feed

    func testTheFeedURLIsFrozenAndVersioned() {
        XCTAssertEqual(Distribution.feedURL, "https://updates.dozersandbox.com/v1/feed.json")
        XCTAssertEqual(UpdateChannel.stable.formula, "doz")
        XCTAssertEqual(UpdateChannel.beta.formula, "doz-beta")
        XCTAssertEqual(UpdateChannel.canary.formula, "doz-canary")
        XCTAssertEqual(UpdateChannel.ofFormula("doz-beta"), .beta)
    }

    func testTheSignedMessageIsExactlyWhatTheScriptSigns() {
        let e = entry("0.31.0", build: 1, channel: "stable")
        XCTAssertEqual(String(decoding: UpdateSignature.message(e), as: UTF8.self),
                       "dozer-sandbox update v1\nversion: 0.31.0\nbuild: 1\narchive: doz-0.31.0-macos-arm64.tar.gz\nsha256: \(String(repeating: "ab", count: 32))\nsize: 1001\n")
        XCTAssertTrue(UpdateSignature.verify(e, publicKey: pub))
        // The channel is not signed (a promotion moves the same bytes); everything else is.
        var promoted = e; promoted.channel = "canary"
        XCTAssertTrue(UpdateSignature.verify(promoted, publicKey: pub))
        for tamper in [{ (x: inout UpdateEntry) in x.version = "0.31.1" }, { $0.build = 2 }, { $0.size += 1 },
                       { $0.sha256 = String(repeating: "cd", count: 32) },
                       { $0.archive = "https://evil.example/doz-0.31.1-macos-arm64.tar.gz" }] {
            var t = e; tamper(&t)
            XCTAssertFalse(UpdateSignature.verify(t, publicKey: pub))
        }
        XCTAssertFalse(UpdateSignature.verify(entry("0.31.0", build: 1, channel: "stable", sign: .init()), publicKey: pub), "another key")
    }

    func testTheCompiledInKeyAndTheTestSeam() {
        XCTAssertNil(UpdateSignature.publicKey([:]) .flatMap { Distribution.updatePublicKey.isEmpty ? $0 : nil },
                     "an empty compiled-in key gives no key")
        XCTAssertEqual(UpdateSignature.publicKey(["DOZ_TEST_UPDATE_KEY": pub.base64EncodedString()]), pub)
        XCTAssertNil(UpdateSignature.publicKey(["DOZ_TEST_UPDATE_KEY": "c2hvcnQ="]), "not 32 bytes")
    }

    func testAnEntryThatDoesNotVerifyIsDroppedAndAFeedThatIsNotOneIsIgnored() {
        var bad = entry("0.32.0", build: 3, channel: "stable")
        bad.sha256 = String(repeating: "00", count: 32)
        let (f, why) = UpdateFeedReader.read(feed([entry("0.31.1", build: 2, channel: "stable"), bad]), publicKey: pub)
        XCTAssertNil(why)
        XCTAssertEqual(f?.entries.map(\.version), ["0.31.1"])
        XCTAssertEqual(f?.rejected.count, 1)
        XCTAssertTrue(f?.rejected.first?.contains("signature does not verify") == true)
        XCTAssertNotNil(UpdateFeedReader.read(Data("not json".utf8), publicKey: pub).1)
        XCTAssertNotNil(UpdateFeedReader.read(try! JSONEncoder().encode(UpdateFeed(schema: 2, product: "doz", entries: [])), publicKey: pub).1)
        // An archive over http is not well-formed — except from 127.0.0.1 in a test's own feed.
        var http = entry("0.31.2", build: 4, channel: "stable")
        http.archive = "http://127.0.0.1:1/doz-0.31.2-macos-arm64.tar.gz"
        http.signature = try! key.signature(for: UpdateSignature.message(http)).base64EncodedString()
        XCTAssertEqual(UpdateFeedReader.read(feed([http]), publicKey: pub).0?.entries.count, 0)
        XCTAssertEqual(UpdateFeedReader.read(feed([http]), publicKey: pub, allowLoopbackHTTP: true).0?.entries.count, 1)
    }

    func testChannelsNestAndNeverADowngrade() {
        let f = VerifiedFeed(entries: [entry("0.31.1", build: 2, channel: "stable"), entry("0.32.0-rc.1", build: 3, channel: "beta"),
                                       entry("0.32.0-rc.2", build: 4, channel: "canary"), entry("0.30.9", build: 1, channel: "stable")],
                             rejected: [])
        XCTAssertEqual(UpdateFeedReader.newest(f, channel: .stable, current: "0.31.0")?.version, "0.31.1")
        XCTAssertEqual(UpdateFeedReader.newest(f, channel: .beta, current: "0.31.0")?.version, "0.32.0-rc.1")
        XCTAssertEqual(UpdateFeedReader.newest(f, channel: .canary, current: "0.31.0")?.version, "0.32.0-rc.2")
        XCTAssertNil(UpdateFeedReader.newest(f, channel: .stable, current: "0.31.1"), "the same version is not an update")
        XCTAssertNil(UpdateFeedReader.newest(f, channel: .stable, current: "0.32.0"), "never a downgrade")
        XCTAssertNil(UpdateFeedReader.newest(f, channel: .canary, current: "1.0.0"))
        XCTAssertEqual(UpdateFeedReader.newest(f, channel: .stable, current: "0.31.1-rc.3")?.version, "0.31.1", "a release follows its rc")
        XCTAssertEqual(SemVer.compare("0.31.0-rc.10", "0.31.0-rc.9"), .orderedDescending)
        XCTAssertEqual(WebVersion.compare("0.31.0", "0.31.0-rc.1"), .orderedDescending, "WebVersion is SemVer")
    }

    // MARK: the check

    func testTheCheckIsDailyConditionalAndOfflineIsSilent() async {
        let server = FakeFeed()
        server.body = feed([entry("0.31.1", build: 2, channel: "stable")])
        let c = ctx()
        let t0 = Date()
        var r = await UpdateChecker.check(c, now: t0, fetch: server.fetch)
        XCTAssertEqual(r.available?.version, "0.31.1")
        XCTAssertTrue(r.fetched)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(server.requests[0].value(forHTTPHeaderField: "User-Agent"), "doz/0.31.0 (stable)")
        XCTAssertNil(server.requests[0].value(forHTTPHeaderField: "If-None-Match"), "the first ask is not conditional")
        // Within a day: the remembered feed, no request.
        r = await UpdateChecker.check(c, now: t0.addingTimeInterval(3600), fetch: server.fetch)
        XCTAssertEqual(r.available?.version, "0.31.1")
        XCTAssertFalse(r.fetched)
        XCTAssertEqual(server.requests.count, 1)
        // A day later: conditional — unchanged is a 304, and the remembered feed still answers.
        r = await UpdateChecker.check(c, now: t0.addingTimeInterval(90_000), fetch: server.fetch)
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertNotNil(server.requests[1].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(r.available?.version, "0.31.1")
        // Forced (doz ui opening): asks again at once.
        _ = await UpdateChecker.check(c, force: true, now: t0.addingTimeInterval(90_100), fetch: server.fetch)
        XCTAssertEqual(server.requests.count, 3)
        // Offline: silent, no problem, retried only after an hour.
        server.offline = true
        r = await UpdateChecker.check(c, now: t0.addingTimeInterval(200_000), fetch: server.fetch)
        XCTAssertTrue(r.offline)
        XCTAssertNil(r.problem)
        XCTAssertEqual(r.available?.version, "0.31.1", "what was learned before still counts")
        _ = await UpdateChecker.check(c, now: t0.addingTimeInterval(200_600), fetch: server.fetch)
        XCTAssertEqual(server.requests.count, 4, "a failed check is retried after an hour, not at every command")
    }

    func testAProblemIsSaidOnceAndAFixedFeedClearsIt() async {
        let server = FakeFeed()
        var bad = entry("0.32.0", build: 3, channel: "stable")
        bad.signature = "AAAA"
        server.body = feed([bad])
        let c = ctx()
        var r = await UpdateChecker.check(c, force: true, fetch: server.fetch)
        XCTAssertNil(r.available)
        XCTAssertTrue(r.reportNow)
        r = await UpdateChecker.check(c, force: true, fetch: server.fetch)
        XCTAssertNotNil(r.problem)
        XCTAssertFalse(r.reportNow, "said once")
        server.body = Data("garbage".utf8)
        r = await UpdateChecker.check(c, force: true, fetch: server.fetch)
        XCTAssertTrue(r.reportNow, "another problem is said again")
        XCTAssertTrue(r.problem?.contains("was ignored") == true)
    }

    func testOffDevelopmentNoKeyAndATestWithoutItsOwnFeedNeverLook() async {
        let server = FakeFeed()
        var c = ctx(mode: .off)
        XCTAssertNotNil(c.disabledReason(manual: false))
        XCTAssertNil(c.disabledReason(manual: true), "doz update works with mode off")
        c = ctx(method: .development)
        XCTAssertTrue(c.disabledReason(manual: true)?.contains("development build") == true)
        c = ctx(); c.publicKey = nil
        XCTAssertNotNil(c.disabledReason(manual: true))
        c = ctx(); c.testWithoutFeed = true
        let r = await UpdateChecker.check(c, force: true, fetch: server.fetch)
        XCTAssertNotNil(r.disabled)
        XCTAssertEqual(server.requests.count, 0, "a guarded test run never asks the real feed")
        // From this process (make test: DOZ_TEST_GUARD=1, no feed of its own).
        let here = UpdateContext.current(version: "0.31.0", executable: "/x/Cellar/doz/0.31.0/libexec/doz/doz",
                                         settings: DozerSettings.load(environment: [:]), env: ["DOZ_TEST_GUARD": "1"])
        XCTAssertTrue(here.testWithoutFeed)
    }

    func testTheChannelFollowsTheFormulaUntilTheSettingIsSet() throws {
        let cellar = "/opt/homebrew/Cellar/doz-beta/0.32.0-rc.1/libexec/doz/doz"
        XCTAssertEqual(InstallMethod.detect(executable: cellar), .homebrew(formula: "doz-beta"))
        let none = UpdateContext.current(version: "0.32.0-rc.1", executable: cellar, settings: DozerSettings.load(environment: [:]), env: [:])
        XCTAssertEqual(none.channel, .beta)
        XCTAssertEqual(none.mode, .notify, "notify is the default")
        let xdg = dir.appendingPathComponent("xdg")
        let s = try DozerSettings.load(environment: ["XDG_CONFIG_HOME": xdg.path]).writing(SettingKey.updatesChannel, .string("stable"))
        let set = UpdateContext.current(version: "0.32.0-rc.1", executable: cellar, settings: s, env: [:])
        XCTAssertEqual(set.channel, .stable)
        XCTAssertEqual(UpdateChecker.noticeLine(entry("0.32.0", build: 9, channel: "stable"), set),
                       "doz 0.32.0 is available — upgrade: doz update --channel stable (notes: https://updates.dozersandbox.com/v1/notes/0.32.0.html)",
                       "another channel's formula: the switch, not brew upgrade")
        XCTAssertEqual(UpdateChecker.noticeLine(entry("0.32.0", build: 9, channel: "stable"), ctx(method: .homebrew(formula: "doz"))),
                       "doz 0.32.0 is available — upgrade: brew upgrade doz (notes: https://updates.dozersandbox.com/v1/notes/0.32.0.html)")
        XCTAssertEqual(UpdateChecker.installedLine("0.32.0"), "Updated to 0.32.0 — restart to apply: doz host restart")
    }

    func testInstallMethods() throws {
        XCTAssertEqual(InstallMethod.detect(executable: "/usr/local/Cellar/doz/0.31.0/libexec/doz/doz"), .homebrew(formula: "doz"))
        XCTAssertEqual(InstallMethod.detect(executable: "/x/.build/debug/doz"), .development)
        // A tarball install has VERSION and the RELEASE marker beside it; make install-cli's has no marker.
        let prefix = dir.appendingPathComponent("p")
        let lib = prefix.appendingPathComponent("libexec/doz")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: lib.appendingPathComponent("doz").path, contents: Data())
        try "0.31.0\n".write(to: lib.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        XCTAssertEqual(InstallMethod.detect(executable: lib.appendingPathComponent("doz").path), .development)
        try "public\n".write(to: lib.appendingPathComponent(UpdateInstaller.releaseMarker), atomically: true, encoding: .utf8)
        guard case .tarball(let p) = InstallMethod.detect(executable: lib.appendingPathComponent("doz").path) else { return XCTFail("a tarball install") }
        XCTAssertEqual(p.standardizedFileURL.path, prefix.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(InstallMethod.homebrew(formula: "doz-canary").upgradeCommand, "brew upgrade doz-canary")
    }

    func testTheNotifyLineIsSaidOncePerVersionADayAndTheBannerReadsNoNetwork() async {
        let c = ctx()
        let e = entry("0.31.1", build: 2, channel: "stable")
        let t = Date()
        XCTAssertTrue(UpdateChecker.shouldNotify(e, c, now: t))
        XCTAssertFalse(UpdateChecker.shouldNotify(e, c, now: t.addingTimeInterval(60)))
        XCTAssertTrue(UpdateChecker.shouldNotify(entry("0.31.2", build: 3, channel: "stable"), c, now: t.addingTimeInterval(120)), "a new version at once")
        XCTAssertTrue(UpdateChecker.shouldNotify(entry("0.31.2", build: 3, channel: "stable"), c, now: t.addingTimeInterval(100_000)), "the same one a day later")
        // The dashboard's banner: what the last check remembered, and an installed version this process is older than.
        let server = FakeFeed()
        server.body = feed([e])
        _ = await UpdateChecker.check(c, force: true, fetch: server.fetch)
        XCTAssertEqual(UpdateChecker.remembered(c).available?.version, "0.31.1")
        XCTAssertNil(UpdateChecker.remembered(c).installed)
        UpdateHook.recordInstalled("0.31.1", c)
        XCTAssertEqual(UpdateChecker.remembered(c).installed, "0.31.1")
        XCTAssertNil(UpdateChecker.remembered(ctx("0.31.1")).installed, "a process of the installed version has nothing to restart")
        XCTAssertEqual(server.requests.count, 1, "remembered() never asks the network")
    }

    func testTheUpdateHookAppliesOnlyToAPersonAtATerminal() {
        let tty = ["DOZ_TEST_UPDATE_TTY": "1"]
        XCTAssertTrue(UpdateHook.applies(["ls"], env: tty))
        XCTAssertTrue(UpdateHook.applies(["attach", "a", "--store", "/tmp/s"], env: tty))
        for args in [["ls", "--json"], ["ls", "-q"], ["--version"], ["update"], ["host", "start"], ["serve"], ["uninstall"], ["ls", "--help"]] {
            XCTAssertFalse(UpdateHook.applies(args, env: tty), "\(args)")
        }
        XCTAssertEqual(UpdateHook.words(["--store", "/tmp/s", "ui", "-v", "start"]), ["ui", "start"])
    }

    func testTheUpdateSettingsAreInTheClosedSchema() {
        XCTAssertEqual(DozerSettings.definition(SettingKey.updatesMode)?.defaultValue, .string("notify"))
        XCTAssertEqual(DozerSettings.definition(SettingKey.updatesChannel)?.defaultValue, .string("stable"))
        XCTAssertThrowsError(try DozerSettings.definition(SettingKey.updatesMode)!.parse("sometimes"))
        XCTAssertEqual(DozerSettings.definition(SettingKey.updatesMode)?.environment, "DOZ_UPDATES")
    }

    func testUpdateCommandParses() throws {
        XCTAssertNoThrow(try DozerCommand.parseAsRoot(["update", "--check"]))
        XCTAssertNoThrow(try DozerCommand.parseAsRoot(["update", "--channel", "beta", "--yes"]))
        XCTAssertThrowsError(try DozerCommand.parseAsRoot(["update", "--channel", "nightly"]))
        XCTAssertThrowsError(try DozerCommand.parseAsRoot(["update", "--check", "--channel", "beta"]))
        XCTAssertNoThrow(try DozerCommand.parseAsRoot(["host", "restart"]))
    }
}
