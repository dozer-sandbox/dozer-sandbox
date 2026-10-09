import CryptoKit
import Darwin
import Foundation

// 611 — updates. ONE signed JSON feed, compiled in, for every channel:
//
//     https://updates.dozersandbox.com/v1/feed.json        (FROZEN: every doz ever shipped reads it — the /v1/ is the
//                                                          FORMAT; a future format is /v2/ beside it, never a change here)
//
//     { "schema": 1, "product": "doz",
//       "entries": [ { "version": "0.31.1", "build": 3, "channel": "stable", "date": "2026-10-20",
//                      "notes": "https://updates.dozersandbox.com/v1/notes/0.31.1.html",
//                      "archive": "https://github.com/<repository>/releases/download/v0.31.1/doz-0.31.1-macos-arm64.tar.gz",
//                      "size": 28104184, "sha256": "…", "signature": "<base64 Ed25519>" }, … ] }
//
// Each entry is signed with DOZER's own Ed25519 key (never Deckosaurus's; `Scripts/update-key.swift`, `make
// doz-update-keys`): the signature covers version, build, the archive's FILE NAME, sha256 and size
// (`UpdateSignature.message`) — not the channel, so a promotion moves the same signed bytes without the key. An entry
// that does not verify is dropped; a feed that cannot be read is ignored; either is said ONCE. Channels nest:
// stable ⊂ beta ⊂ canary (a canary install is offered every build). Never a downgrade: only a version above this one.
//
// The check (`UpdateChecker`): at most once a day (a failed one retried after an hour), and whenever `doz ui` starts;
// a conditional request (If-None-Match / If-Modified-Since — unchanged = 304); offline = silent. Never in a guarded
// test run unless the test names its own feed (`DOZ_TEST_UPDATE_FEED`); never for a development build.

/// Where Dozer is distributed — the ONE place these names live (the Makefile and the scripts read them from here).
public enum Distribution {
    /// The feed (frozen forever — see above).
    public static let feedURL = "https://updates.dozersandbox.com/v1/feed.json"
    /// The Homebrew tap: `brew install <tap>/doz` (the repository `<org>/homebrew-<name>`).
    public static let tap = "dozer-sandbox/tap"
    /// The public source repository; its GitHub releases carry the tarballs.
    public static let repository = "dozer-sandbox/dozer-sandbox"
    /// The PUBLIC half of Dozer's update-signing key (base64, 32 bytes) — `make doz-update-keys` prints it, once.
    /// Empty: this build cannot verify a feed, so it never offers an update (development builds).
    public static let updatePublicKey = "Istc57eBxex+MaRcSrmIoC2vOroeNdvY+h+N4UCeNxg="
    /// The Developer ID team whose signature a downloaded doz must carry.
    public static let teamID = "KJ8QMLWB97"
}

/// The release channels, narrowest first in what they are offered.
public enum UpdateChannel: String, CaseIterable, Codable, Sendable {
    case stable, beta, canary

    /// How early a channel's builds are: stable 0, beta 1, canary 2.
    var rank: Int { switch self { case .stable: 0; case .beta: 1; case .canary: 2 } }

    /// A build on `entry`'s channel is offered on this one (stable ⊂ beta ⊂ canary).
    public func offers(_ entry: UpdateChannel) -> Bool { entry.rank <= rank }

    /// The Homebrew formula of this channel.
    public var formula: String { self == .stable ? "doz" : "doz-\(rawValue)" }

    public static func ofFormula(_ name: String) -> UpdateChannel? { allCases.first { $0.formula == name } }
}

public enum UpdateMode: String, CaseIterable, Sendable {
    case off, notify, auto
}

/// One build in the feed.
public struct UpdateEntry: Codable, Equatable, Sendable {
    public var version: String
    public var build: Int
    public var channel: String
    public var date: String?
    public var notes: String?
    public var archive: String
    public var size: Int
    public var sha256: String
    public var signature: String

    public init(version: String, build: Int, channel: String, date: String? = nil, notes: String? = nil, archive: String,
                size: Int, sha256: String, signature: String) {
        self.version = version
        self.build = build
        self.channel = channel
        self.date = date
        self.notes = notes
        self.archive = archive
        self.size = size
        self.sha256 = sha256
        self.signature = signature
    }

    /// The tarball's file name (what the signature names).
    public var archiveName: String { URL(string: archive)?.lastPathComponent ?? "" }
}

public struct UpdateFeed: Codable, Equatable, Sendable {
    public var schema: Int
    public var product: String
    public var entries: [UpdateEntry]
}

/// What an entry's signature covers (`Scripts/update-key.swift` signs exactly these bytes).
public enum UpdateSignature {
    public static func message(_ e: UpdateEntry) -> Data {
        Data("dozer-sandbox update v1\nversion: \(e.version)\nbuild: \(e.build)\narchive: \(e.archiveName)\nsha256: \(e.sha256.lowercased())\nsize: \(e.size)\n".utf8)
    }

    public static func verify(_ e: UpdateEntry, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              let sig = Data(base64Encoded: e.signature) else { return false }
        return key.isValidSignature(sig, for: message(e))
    }

    /// The public key a doz trusts: the compiled-in one, or `DOZ_TEST_UPDATE_KEY` (a TEST key) in a test run.
    public static func publicKey(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Data? {
        if let t = env["DOZ_TEST_UPDATE_KEY"], !t.isEmpty { return Data(base64Encoded: t).flatMap { $0.count == 32 ? $0 : nil } }
        return Data(base64Encoded: Distribution.updatePublicKey).flatMap { $0.count == 32 ? $0 : nil }
    }
}

/// A feed read and verified: the entries that verify; why others did not.
public struct VerifiedFeed: Equatable, Sendable {
    public var entries: [UpdateEntry]
    public var rejected: [String]
}

public enum UpdateFeedReader {
    /// Read `data`: nil + why when it is not a feed at all; else the verified entries (an entry that does not verify,
    /// or is not well-formed, is dropped with a reason).
    public static func read(_ data: Data, publicKey: Data, allowLoopbackHTTP: Bool = false) -> (VerifiedFeed?, String?) {
        guard data.count <= 1 << 20 else { return (nil, "the feed is larger than 1 MiB") }
        guard let feed = try? JSONDecoder().decode(UpdateFeed.self, from: data) else { return (nil, "the feed is not the JSON doz expects") }
        guard feed.schema == 1, feed.product == "doz" else { return (nil, "the feed is schema \(feed.schema) of \(feed.product) — this doz reads schema 1 of doz") }
        var ok: [UpdateEntry] = []
        var bad: [String] = []
        for e in feed.entries.prefix(500) {
            guard UpdateChannel(rawValue: e.channel) != nil, SemVer.parse(e.version) != nil,
                  e.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, e.size > 0,
                  Self.archiveURLAllowed(e.archive, allowLoopbackHTTP: allowLoopbackHTTP), !e.archiveName.isEmpty else {
                bad.append("\(e.version) (build \(e.build)): not well-formed")
                continue
            }
            guard UpdateSignature.verify(e, publicKey: publicKey) else {
                bad.append("\(e.version) (build \(e.build)): its signature does not verify")
                continue
            }
            ok.append(e)
        }
        return (VerifiedFeed(entries: ok, rejected: bad), nil)
    }

    /// An archive is downloaded over https only (a test's own feed may serve it from 127.0.0.1 over http).
    static func archiveURLAllowed(_ s: String, allowLoopbackHTTP: Bool) -> Bool {
        guard let u = URL(string: s) else { return false }
        if u.scheme == "https", u.host?.isEmpty == false { return true }
        return allowLoopbackHTTP && u.scheme == "http" && u.host == "127.0.0.1"
    }

    /// The newest build `channel` is offered that is NEWER than `current` (never a downgrade, never the same).
    public static func newest(_ feed: VerifiedFeed, channel: UpdateChannel, current: String) -> UpdateEntry? {
        feed.entries
            .filter { UpdateChannel(rawValue: $0.channel).map(channel.offers) == true }
            .filter { SemVer.compare($0.version, current) == .orderedDescending }
            .max { SemVer.compare($0.version, $1.version) == .orderedAscending }
    }
}

/// How this doz was installed — what an upgrade means for it.
public enum InstallMethod: Equatable, Sendable {
    /// A Homebrew keg of `formula` (doz, doz-beta, doz-canary): `brew upgrade <formula>`.
    case homebrew(formula: String)
    /// The release tarball unpacked by hand: `<prefix>/libexec/doz/doz` beside its VERSION, `<prefix>/bin/doz` a link.
    case tarball(prefix: URL)
    /// A development build (`swift build`, `make cli`, `make install-cli`): no updates.
    case development

    public static func detect(executable: String) -> InstallMethod {
        let exe = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        let parts = exe.pathComponents
        // …/Cellar/<formula>/<version>/libexec/doz/doz
        if let i = parts.lastIndex(of: "Cellar"), parts.count == i + 6, parts[i + 3] == "libexec", parts[i + 4] == "doz", parts[i + 5] == "doz" {
            return .homebrew(formula: parts[i + 1])
        }
        let dir = exe.deletingLastPathComponent()
        guard exe.lastPathComponent == "doz", dir.lastPathComponent == "doz", dir.deletingLastPathComponent().lastPathComponent == "libexec",
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("VERSION").path),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent(UpdateInstaller.releaseMarker).path) else {
            return .development
        }
        return .tarball(prefix: dir.deletingLastPathComponent().deletingLastPathComponent())
    }

    /// The command a person runs to upgrade.
    public var upgradeCommand: String? {
        switch self {
        // Not `brew upgrade FORMULA`: Homebrew refreshes its taps only now and then, so that alone can miss the
        // release the feed names; `doz upgrade -y` refreshes Dozer's tap first.
        case .homebrew: "doz upgrade -y"
        case .tarball: "doz upgrade -y"
        case .development: nil
        }
    }

    public var formulaChannel: UpdateChannel? {
        if case .homebrew(let f) = self { return UpdateChannel.ofFormula(f) }
        return nil
    }
}

/// What the checker remembers between runs (`<settings dir>/updates.json`, beside doz.toml — never a secret).
public struct UpdateState: Codable, Equatable, Sendable {
    public var lastCheck: Date?
    public var lastAttempt: Date?
    public var etag: String?
    public var lastModified: String?
    /// The feed's body as last fetched (re-verified on every use).
    public var feed: String?
    /// The digest of the last problem said (a problem is said ONCE).
    public var reportedProblem: String?
    /// `auto` installed this version; the running host or doz ui may still be the previous one.
    public var installed: String?
    public var installedAt: Date?
    /// The version a terminal was last told about, and when (a new version is said at once; the same one daily).
    public var notified: String?
    public var notifiedAt: Date?

    public init() {}

    public static func url(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        DozerSettings.fileURL(environment: env)?.deletingLastPathComponent().appendingPathComponent("updates.json")
    }

    public static func load(_ url: URL?) -> UpdateState {
        guard let url, let d = try? Data(contentsOf: url) else { return UpdateState() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(UpdateState.self, from: d)) ?? UpdateState()
    }

    public func save(_ url: URL?) {
        guard let url else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let d = try? enc.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".updates.json.\(getpid())")
        guard FileManager.default.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(tmp.path, url.path) != 0 { unlink(tmp.path) }
    }
}

/// What a check found.
public struct UpdateCheck: Equatable, Sendable {
    /// The newest build offered (newer than this doz), when there is one.
    public var available: UpdateEntry?
    /// Why updates are not looked for at all (off, a development build, no key …).
    public var disabled: String?
    /// The feed (or an entry) did not verify — `reportNow` when it has not been said before.
    public var problem: String?
    public var reportNow: Bool = false
    /// The network was asked this time (false: the remembered feed, or not due).
    public var fetched: Bool = false
    /// The feed could not be reached (silent).
    public var offline: Bool = false

    public init(available: UpdateEntry? = nil, disabled: String? = nil) {
        self.available = available
        self.disabled = disabled
    }
}

/// Everything a check depends on, from the environment and the settings — test seams included.
public struct UpdateContext: Sendable {
    public var mode: UpdateMode
    public var channel: UpdateChannel
    public var current: String
    public var method: InstallMethod
    public var feedURL: URL
    public var publicKey: Data?
    public var stateURL: URL?
    /// A guarded test run that named no feed of its own: never the network.
    public var testWithoutFeed: Bool
    /// A test's own feed (`DOZ_TEST_UPDATE_FEED`) may serve archives over http from 127.0.0.1.
    public var allowLoopbackHTTP: Bool = false

    /// From this process: settings (`updates.mode`, `updates.channel` — a Homebrew install's formula decides the channel
    /// while the setting is not set), the executable (`DOZ_TEST_UPDATE_EXECUTABLE` pretends another path), the feed
    /// (`DOZ_TEST_UPDATE_FEED`), the key (`DOZ_TEST_UPDATE_KEY`).
    public static func current(version: String, executable: String, settings: DozerSettings = .load(),
                               env: [String: String] = ProcessInfo.processInfo.environment) -> UpdateContext {
        let mode = settings.string(SettingKey.updatesMode).flatMap(UpdateMode.init(rawValue:)) ?? .notify
        let exe = env["DOZ_TEST_UPDATE_EXECUTABLE"].flatMap { $0.isEmpty ? nil : $0 } ?? executable
        let method = InstallMethod.detect(executable: exe)
        let set = settings.resolve(SettingKey.updatesChannel)
        let channel: UpdateChannel = set.source == .default
            ? (method.formulaChannel ?? .stable)
            : (settings.string(SettingKey.updatesChannel).flatMap(UpdateChannel.init(rawValue:)) ?? .stable)
        let testFeed = env["DOZ_TEST_UPDATE_FEED"].flatMap { $0.isEmpty ? nil : URL(string: $0) }
        return UpdateContext(mode: mode, channel: channel, current: version, method: method,
                             feedURL: testFeed ?? URL(string: Distribution.feedURL)!,
                             publicKey: UpdateSignature.publicKey(env), stateURL: UpdateState.url(env),
                             testWithoutFeed: TestSafety.guarded(env) && testFeed == nil, allowLoopbackHTTP: testFeed != nil)
    }

    /// Why this doz does not look for updates (nil: it does). `manual`: `doz upgrade -y` asked — even with mode off.
    public func disabledReason(manual: Bool) -> String? {
        if testWithoutFeed { return "not in a test run (no DOZ_TEST_UPDATE_FEED)" }
        if mode == .off && !manual { return "updates.mode is off" }
        if case .development = method { return "this doz is a development build (not a release install) — it is not updated" }
        if publicKey == nil { return "this build carries no update key, so it cannot verify a feed" }
        return nil
    }
}

/// Fetches the feed (URLSession, or a test's function).
public typealias UpdateFetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

public enum UpdateChecker {
    public static let interval: TimeInterval = 86_400
    public static let retryAfterFailure: TimeInterval = 3600

    public static let urlSessionFetch: UpdateFetch = { req in
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        cfg.timeoutIntervalForResource = 8
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let (d, r) = try await URLSession(configuration: cfg).data(for: req)
        guard let h = r as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (d, h)
    }

    /// Check: from the remembered feed when the last check is under a day old (unless `force`), else ask the feed
    /// (conditionally). `manual` (`doz upgrade -y`) works even with mode off. Writes the state back.
    public static func check(_ ctx: UpdateContext, force: Bool = false, manual: Bool = false, network: Bool = true, now: Date = Date(),
                             fetch: UpdateFetch = urlSessionFetch) async -> UpdateCheck {
        if let why = ctx.disabledReason(manual: manual) { return UpdateCheck(disabled: why) }
        guard let key = ctx.publicKey else { return UpdateCheck(disabled: "no update key") }
        var state = UpdateState.load(ctx.stateURL)
        var result = UpdateCheck()
        let due = network && force || network && manual
            || network && (state.lastCheck.map { now.timeIntervalSince($0) >= interval } ?? true)
                && (state.lastAttempt.map { now.timeIntervalSince($0) >= retryAfterFailure } ?? true)
            || network && (state.lastAttempt.map { $0 > now } ?? false)           // a clock that went back
        if due {
            // A check a person asked for (doz upgrade, --check, doz ui's start) goes past the CDN's copy: GitHub Pages
            // serves the feed with max-age=600 through its CDN, so a release published minutes ago was invisible to
            // `doz update` (owner, on 0.32.0-rc.3). A unique query is a new cache key; the daily check stays cacheable.
            var url = ctx.feedURL
            if force || manual, var c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https" {
                c.queryItems = [URLQueryItem(name: "t", value: String(Int(now.timeIntervalSince1970)))]
                url = c.url ?? url
            }
            var req = URLRequest(url: url)
            req.setValue("doz/\(ctx.current) (\(ctx.channel.rawValue))", forHTTPHeaderField: "User-Agent")
            if state.feed != nil {
                if let e = state.etag { req.setValue(e, forHTTPHeaderField: "If-None-Match") }
                if let m = state.lastModified { req.setValue(m, forHTTPHeaderField: "If-Modified-Since") }
            }
            state.lastAttempt = now
            do {
                let (data, resp) = try await fetch(req)
                switch resp.statusCode {
                case 200:
                    state.feed = String(decoding: data, as: UTF8.self)
                    state.etag = resp.value(forHTTPHeaderField: "ETag")
                    state.lastModified = resp.value(forHTTPHeaderField: "Last-Modified")
                    state.lastCheck = now
                    result.fetched = true
                case 304:
                    state.lastCheck = now
                    result.fetched = true
                default:
                    result.offline = true            // a server error is not the feed's verdict: silent, retried later
                }
            } catch {
                result.offline = true
            }
        }
        if let body = state.feed {
            let (feed, why) = UpdateFeedReader.read(Data(body.utf8), publicKey: key, allowLoopbackHTTP: ctx.allowLoopbackHTTP)
            if let feed {
                result.available = UpdateFeedReader.newest(feed, channel: ctx.channel, current: ctx.current)
                if !feed.rejected.isEmpty { result.problem = "the update feed has entries that do not verify, ignored: " + feed.rejected.joined(separator: "; ") }
            } else {
                result.problem = "the update feed was ignored: " + (why ?? "it did not verify")
            }
            if let p = result.problem {
                let digest = SHA256.hash(data: Data((p + body).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
                if state.reportedProblem != digest { result.reportNow = true; state.reportedProblem = digest }
            }
        }
        if network || result.reportNow { state.save(ctx.stateURL) }
        return result
    }

    /// What the last check remembered, without asking the network (the dashboard's banner, at every page load):
    /// the newest build offered, and the version an automatic update installed when THIS process is older.
    public static func remembered(_ ctx: UpdateContext) -> (available: UpdateEntry?, installed: String?) {
        guard ctx.disabledReason(manual: false) == nil, let key = ctx.publicKey else { return (nil, nil) }
        let s = UpdateState.load(ctx.stateURL)
        let pending = s.installed.flatMap { SemVer.compare($0, ctx.current) == .orderedDescending ? $0 : nil }
        guard let body = s.feed, let feed = UpdateFeedReader.read(Data(body.utf8), publicKey: key, allowLoopbackHTTP: ctx.allowLoopbackHTTP).0 else {
            return (nil, pending)
        }
        return (UpdateFeedReader.newest(feed, channel: ctx.channel, current: ctx.current), pending)
    }

    /// The one line a terminal shows (stderr): `doz X is available — upgrade: brew upgrade doz (notes: URL)`.
    public static func noticeLine(_ e: UpdateEntry, _ ctx: UpdateContext) -> String {
        var how = ctx.method.upgradeCommand ?? "doz upgrade -y"
        // A Homebrew install of another channel's formula switches formulas to follow the channel setting.
        if let f = ctx.method.formulaChannel, f != ctx.channel { how = "doz upgrade --channel \(ctx.channel.rawValue)" }
        return "doz \(e.version) is available — upgrade: \(how)" + (e.notes.map { " (notes: \($0))" } ?? "")
    }

    /// Whether a terminal should be told about `e` now — a version not said before, or the same one a day later —
    /// and remember that it was.
    public static func shouldNotify(_ e: UpdateEntry, _ ctx: UpdateContext, now: Date = Date()) -> Bool {
        var s = UpdateState.load(ctx.stateURL)
        if s.notified == e.version, let at = s.notifiedAt, now.timeIntervalSince(at) < interval, at <= now { return false }
        s.notified = e.version
        s.notifiedAt = now
        s.save(ctx.stateURL)
        return true
    }

    /// After `auto` installed `version`: what is left to do.
    public static func installedLine(_ version: String) -> String {
        "Updated to \(version) — restart to apply: doz host restart"
    }
}

/// Semantic-version order (semver.org §11): X.Y.Z numerically; a pre-release sorts BEFORE its release; pre-release
/// identifiers dot by dot — numbers numerically, below alphanumerics (ASCII); a shorter list first. Build metadata
/// is ignored. nil when either is not a version. (`WebVersion` in DozerWeb is this.)
public enum SemVer {
    struct Parsed { var core: [Int]; var pre: [String] }

    static func parse(_ s: String) -> Parsed? {
        let noBuild = s.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? s
        let parts = noBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first else { return nil }
        let core = first.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard core.count == 3, core.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        var pre: [String] = []
        if parts.count == 2 {
            pre = parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !pre.isEmpty, pre.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else { return nil }
        }
        return Parsed(core: core.map { $0! }, pre: pre)
    }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult? {
        guard let x = parse(a), let y = parse(b) else { return nil }
        for (p, q) in zip(x.core, y.core) where p != q { return p < q ? .orderedAscending : .orderedDescending }
        switch (x.pre.isEmpty, y.pre.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): break
        }
        for (p, q) in zip(x.pre, y.pre) where p != q {
            switch (Int(p), Int(q)) {
            case let (i?, j?): return i < j ? .orderedAscending : .orderedDescending
            case (_?, nil): return .orderedAscending
            case (nil, _?): return .orderedDescending
            case (nil, nil): return p < q ? .orderedAscending : .orderedDescending
            }
        }
        return x.pre.count == y.pre.count ? .orderedSame : x.pre.count < y.pre.count ? .orderedAscending : .orderedDescending
    }
}
