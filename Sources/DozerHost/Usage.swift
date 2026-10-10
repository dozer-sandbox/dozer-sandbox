import Darwin
import Foundation
import DozerKit

// Anonymous usage statistics and the optional sign-up — the OPEN half.
//
// This file decides WHAT may ever be sent, and WHETHER anything is sent. It sends nothing itself: a build from this
// repository has no sender at all (`Usage.isOfficial` is false), so it records nothing and sends nothing. The official
// builds (Homebrew, the release tarball) link a small closed package that calls `Usage.install(send:flush:signup:)`
// from `doz`'s main — it is handed the finished messages below (JSON) and an email for the sign-up, and nothing else.
//
// The rules, all here and all checked by `UsageTests`:
//   • A CLOSED list of messages: `installed`, `upgraded`, `daily` — every key in `UsageSchema.keys`, every value a
//     count, a range from `UsageSchema.ranges`, a number rounded to 50 ms, or a word of Dozer's own vocabulary
//     (command names, agent ids, base catalogue ids, network presets). Never a name, path, host, argument, email or
//     a hash of anything the user made — the encoder cannot express one.
//   • The off switches, checked BEFORE anything is recorded: the setting `telemetry.send_anonymous_usage_stats`
//     ($DOZ_SEND_ANONYMOUS_USAGE_STATS), `DO_NOT_TRACK`, the flags `--[no-]send-anonymous-usage-stats`; a guarded
//     test run and a development build are always off (`UsageSwitches.decide`).
//   • What is kept on this Mac: `<settings dir>/usage-id` (a random UUID, `doz telemetry reset` replaces it) and
//     `<settings dir>/usage.json` (the current day's command counts, the version last seen, whether the notice was
//     shown). The day's other numbers are read from what the host already records (the metrics database, the store).
//   • At most one `daily` a day, sent on the first command of a LATER day; one `installed`/`upgraded` per version.
//     Sending is the closed package's (queued, retried in the background, dropped after 7 days); `flush` is capped
//     at a second and runs only when something was handed over.

// MARK: - the sign-up (the contract with the closed package)

/// One sign-up: an email and what it is for. Nothing else is ever sent with it — not the install id. Its description
/// is redacted (a log line or an interpolation never shows the address).
public struct SignupRequest: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let interestValues = ["release-news", "early-access", "support"]
    public static let sourceValues = ["cli", "onboarding-web", "onboarding-cli", "website"]

    public var email: String
    public var interests: [String]
    public var source: String

    public var description: String { "SignupRequest(email: <redacted>, interests: \(interests), source: \(source))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["email": "<redacted>", "interests": interests, "source": source]) }

    public init(email: String, interests: [String], source: String) {
        self.email = email
        self.interests = interests
        self.source = source
    }

    /// A checked request: an email of a plain shape, 1–3 known interests (each once, in the list's order), a known
    /// source. The error never repeats the email.
    public static func make(email: String, interests: [String], source: String) throws -> SignupRequest {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if let why = emailProblem(e) { throw UsageError(why) }
        let wanted = Set(interests)
        guard !wanted.isEmpty, wanted.isSubset(of: Set(interestValues)), wanted.count == interests.count else {
            throw UsageError("choose at least one of: \(interestValues.joined(separator: ", ")) (each once)")
        }
        guard sourceValues.contains(source) else { throw UsageError("unknown sign-up source") }
        return SignupRequest(email: e, interests: interestValues.filter(wanted.contains), source: source)
    }

    /// Why `s` is not an email address this form takes (nil: it is). A shape check only — the confirmation email is the
    /// real one.
    public static func emailProblem(_ s: String) -> String? {
        guard (3...254).contains(s.utf8.count) else { return "an email address is 3–254 characters" }
        guard !s.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F || "<>()[]\\,;:\"".unicodeScalars.contains($0) }) else {
            return "that is not an email address (no spaces or special characters)"
        }
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 64, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix("."), !parts[1].contains("..") else {
            return "that is not an email address (name@example.com)"
        }
        return nil
    }
}

/// What the sign-up answered.
public struct SignupResult: Codable, Sendable, Equatable {
    public static let statusValues = ["confirmation-sent", "already-confirmed"]
    public var status: String
    public init(status: String) { self.status = status }
}

public struct UsageError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - the installed sender

public enum Usage {
    public typealias Send = @Sendable (Data) -> Void
    public typealias Flush = @Sendable (TimeInterval) -> Void
    public typealias Signup = @Sendable (SignupRequest) async throws -> SignupResult

    /// Where anyone can sign up, and the policy — said by builds that have no sign-up of their own.
    public static let signupPage = "https://dozersandbox.com/signup"
    public static let privacyPage = "https://dozersandbox.com/privacy"
    /// The longest `flush` is given after a command.
    public static let flushTimeout: TimeInterval = 1

    struct Hooks {
        let send: Send
        let flush: Flush
        let signup: Signup
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var hooks: Hooks?

    /// Installed by the official build's `main`, before any command runs. Never called in a build from the public
    /// repository — there, nothing is ever sent.
    public static func install(send: @escaping Send, flush: @escaping Flush, signup: @escaping Signup) {
        lock.withLock { hooks = Hooks(send: send, flush: flush, signup: signup) }
    }

    /// True once `install` ran: an official build.
    public static var isOfficial: Bool { lock.withLock { hooks != nil } }

    /// Tests only: forget the installed sender.
    static func uninstall() { lock.withLock { hooks = nil } }

    /// Hand one message over (only ever called by `UsageRecorder` with a message of the closed list).
    static func send(_ message: Data) { lock.withLock { hooks }?.send(message) }
    static func flush(_ timeout: TimeInterval) { lock.withLock { hooks }?.flush(timeout) }

    /// The sign-up, through the installed package. An open build has none.
    public static func signup(_ r: SignupRequest) async throws -> SignupResult {
        guard let h = lock.withLock({ hooks }) else {
            throw UsageError("this build does not include the sign-up (it is built from the open-source repository) — sign up at \(signupPage)")
        }
        let checked = try SignupRequest.make(email: r.email, interests: r.interests, source: r.source)
        let result = try await h.signup(checked)
        guard SignupResult.statusValues.contains(result.status) else { throw UsageError("the sign-up gave an answer this doz does not know") }
        return result
    }
}

// MARK: - the switches

/// Whether statistics are sent by this process, and why (the first reason that turns them off).
public struct UsageSwitch: Codable, Equatable, Sendable {
    public var on: Bool
    public var why: String
    /// The official build's package is linked in.
    public var official: Bool
    /// telemetry.send_anonymous_usage_stats as resolved (flag > env > file > default), and where it came from.
    public var setting: Bool
    public var settingSource: SettingSource
    public var doNotTrack: Bool
    public var testRun: Bool
    public var developmentBuild: Bool
}

public enum UsageSwitches {
    /// `DO_NOT_TRACK` (consoledonottrack.com): set to anything but empty, `0` or `false`.
    public static func doNotTrack(_ env: [String: String]) -> Bool {
        guard let v = env["DO_NOT_TRACK"]?.trimmingCharacters(in: .whitespaces).lowercased(), !v.isEmpty else { return false }
        return v != "0" && v != "false"
    }

    /// The decision. `flag`: `--send-anonymous-usage-stats` (true) / `--no-send-anonymous-usage-stats` (false) on this
    /// command line. DO_NOT_TRACK wins over everything — even the flag that turns them on.
    public static func decide(official: Bool, method: InstallMethod, settings: DozerSettings, env: [String: String],
                              flag: Bool?, guarded: Bool) -> UsageSwitch {
        let r = settings.resolve(SettingKey.sendUsageStats, flag: flag.map(TOMLValue.bool))
        let setting: Bool = if case .bool(let b) = r.value { b } else { true }
        let dnt = doNotTrack(env)
        let dev = method == .development
        var s = UsageSwitch(on: false, why: "", official: official, setting: setting, settingSource: r.source,
                            doNotTrack: dnt, testRun: guarded, developmentBuild: dev)
        if !official {
            s.why = "this build sends nothing — it is built from the open-source repository (only official builds include the statistics)"
        } else if guarded {
            s.why = "off in a test run"
        } else if dev {
            s.why = "off in a development build (only a release install — Homebrew or the release download — sends)"
        } else if dnt {
            s.why = "off: DO_NOT_TRACK is set"
        } else if !setting {
            s.why = switch r.source {
            case .flag: "off for this command: --no-send-anonymous-usage-stats"
            case .env: "off: $DOZ_SEND_ANONYMOUS_USAGE_STATS"
            case .file, .default: "off: telemetry.send_anonymous_usage_stats = false"
            }
        } else {
            s.on = true
            s.why = "anonymous counts and ranges, at most once a day; turn off: doz config set telemetry.send_anonymous_usage_stats false"
        }
        return s
    }
}

// MARK: - the closed list

/// Every key a message may carry, and every word a value may be. A message that does not fit is never handed over.
public enum UsageSchema {
    public static let types = ["installed", "upgraded", "daily"]
    public static let common = ["type", "id", "v", "channel", "install"]
    public static let channels = ["stable", "beta", "canary"]
    public static let installs = ["homebrew", "tarball"]

    /// The top-level keys of each message type.
    public static let keys: [String: Set<String>] = [
        "installed": Set(common),
        "upgraded": Set(common + ["from"]),
        "daily": Set(common + [
            "macos", "chip", "ram", "cores",
            "commands", "failed",
            "onboarding", "first_sandbox", "time_to_first_session",
            "created",
            "sandboxes", "running_max", "points", "store_gb",
            "timing_ms",
            "wake_failed", "crash_restores", "host_crashes", "prep_failed",
            "ui", "app", "serve", "serve_devices", "rules", "github", "agent_status", "points_taken", "templates_made",
            "upgrade_mode",
            "time",
        ]),
    ]
    /// The keys inside the daily message's objects.
    public static let nested: [String: Set<String>] = [
        "onboarding": ["via", "step", "completed"],
        "created": ["agent", "base", "account", "network"],
        "timing_ms": ["start", "wake", "hibernate", "pause", "agent"],
        "timing": ["p50", "p90"],
        "time": ["running", "asleep", "removed_age", "running_total", "agent_working", "idle_running_8h"],
    ]

    public static let chips = ["m1", "m2", "m3", "m4", "m5", "other"]
    public static let agents = ["claude-code", "codex", "pi", "none"]
    public static let accounts = ["mac", "api-key", "setup-token", "none"]
    public static let networks = ["standard", "locked", "open", "custom", "nat", "none"]
    public static let onboardingVia = ["cli", "web"]
    public static let onboardingSteps = ["started", "settings", "done"]
    public static let githubModes = ["off", "read", "push"]
    public static let upgradeModes = ["off", "notify", "auto"]

    /// The ranges (ASCII spelling — exactly these strings are sent).
    public enum Ranges {
        public static let ram = ["8", "16", "24", "32", "64+"]
        public static let cores = ["<=8", "9-11", "12-15", "16+"]
        public static let count = ["0", "1", "2-5", "6-10", "11-25", "26+"]
        public static let storeGB = ["<5", "5-20", "20-100", "100+"]
        public static let firstSession = ["<5m", "5-30m", "30m+"]
        public static let serveDevices = ["0", "1", "2-5", "6+"]
        public static let running = ["<5m", "5-30m", "30m-2h", "2-8h", "8h+"]
        public static let asleep = ["<1h", "1-8h", "8-24h", "1-7d", "7d+"]
        public static let removedAge = ["<1h", "1h-1d", "1-7d", "7-30d", "30d+"]
        public static let total = ["<30m", "30m-2h", "2-8h", "8h+"]
    }

    // The buckets.
    public static func ram(bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 64 ? "64+" : gb >= 32 ? "32" : gb >= 24 ? "24" : gb >= 16 ? "16" : "8"
    }
    public static func cores(_ n: Int) -> String { n <= 8 ? "<=8" : n <= 11 ? "9-11" : n <= 15 ? "12-15" : "16+" }
    public static func count(_ n: Int) -> String {
        n <= 0 ? "0" : n == 1 ? "1" : n <= 5 ? "2-5" : n <= 10 ? "6-10" : n <= 25 ? "11-25" : "26+"
    }
    public static func storeGB(bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        return gb < 5 ? "<5" : gb < 20 ? "5-20" : gb < 100 ? "20-100" : "100+"
    }
    public static func serveDevices(_ n: Int) -> String { n <= 0 ? "0" : n == 1 ? "1" : n <= 5 ? "2-5" : "6+" }
    /// "Apple M3 Pro" → m3; anything else → other.
    public static func chip(brand: String) -> String {
        let l = brand.lowercased()
        for c in chips.dropLast() where l.range(of: "apple \(c)(\\b|[^0-9])", options: .regularExpression) != nil || l.hasSuffix("apple \(c)") {
            return c
        }
        return "other"
    }
    /// A duration in ms rounded to the nearest 50 ms, within 0 … 1 h.
    public static func round50(_ ms: Double) -> Int { min(maxTimingMs, max(0, Int((ms / 50).rounded()) * 50)) }

    /// The limits the receiving side holds every message to.
    public static let maxCount = 1_000_000
    public static let maxMapKeys = 100
    public static let maxTimingMs = 3_600_000

    /// A count map within the limits: at most `maxMapKeys` keys (the largest counts kept), each count capped.
    public static func limited(_ m: [String: Int]) -> [String: Int]? {
        let kept = m.filter { $0.value > 0 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(maxMapKeys)
        return kept.isEmpty ? nil : Dictionary(uniqueKeysWithValues: kept.map { ($0.key, min($0.value, maxCount)) })
    }

    /// A created sandbox's network as one of `networks` (a preset name; anything else is custom).
    public static func network(_ name: String) -> String {
        switch name {
        case "agent", "standard": "standard"
        case "locked", "open", "nat", "none": name
        default: "custom"
        }
    }
    /// The base of an image name as the catalogue names it, `dockerfile` for a Dockerfile base (its id is derived from
    /// a path — never sent), nil for a template or anything else of the user's.
    public static func base(image: String) -> String? {
        guard let c = ImageChoice.parse(image) else { return nil }
        if c.isDockerfile { return "dockerfile" }
        return BaseCatalogue.base(c.base) != nil ? c.base : nil
    }
    public static func agent(image: String) -> String? { ImageChoice.parse(image)?.agent.rawValue }

    /// A version as doz stamps it (`0.33.0`, `0.33.0-rc.1`); nil for anything else.
    public static func version(_ s: String) -> String? {
        s.range(of: #"^\d{1,3}\.\d{1,3}\.\d{1,4}(-[0-9A-Za-z][0-9A-Za-z.]{0,19})?$"#, options: .regularExpression) != nil ? s : nil
    }

    /// A command name is words of doz's own (the CLI maps what was typed to its own command tree first).
    public static func isCommandName(_ s: String) -> Bool {
        s.range(of: #"^[a-z][a-z0-9-]{0,23}( [a-z][a-z0-9-]{0,23}){0,2}$"#, options: .regularExpression) != nil
    }

    /// Check an encoded message against the closed list: every key known, every value of its kind. Returns the
    /// problems (empty: it fits). `commandNames`, when given, is the CLI's whole vocabulary.
    public static func problems(_ data: Data, commandNames: Set<String>? = nil) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data), let d = obj as? [String: Any] else { return ["not a JSON object"] }
        var out: [String] = []
        func word(_ v: Any?, _ allowed: [String], _ at: String) {
            guard let s = v as? String, allowed.contains(s) else { out.append("\(at): not one of \(allowed)"); return }
        }
        func int(_ v: Any?, _ at: String) {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue >= 0, n.doubleValue <= Double(maxCount),
                  n.doubleValue == n.doubleValue.rounded() else {
                out.append("\(at): not a count"); return
            }
        }
        func bool(_ v: Any?, _ at: String) {
            guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { out.append("\(at): not true/false"); return }
        }
        func counts(_ v: Any?, _ at: String, key: (String) -> Bool) {
            guard let m = v as? [String: Any] else { out.append("\(at): not an object"); return }
            if m.count > maxMapKeys { out.append("\(at): more than \(maxMapKeys) keys") }
            for (k, x) in m {
                if !key(k) { out.append("\(at): key \(k.count > 40 ? String(k.prefix(40)) + "…" : k) is not allowed") }
                int(x, "\(at).\(k)")
            }
        }
        guard let type = d["type"] as? String, let allowed = keys[type] else { return ["type: not one of \(types)"] }
        for k in d.keys where !allowed.contains(k) { out.append("\(k): not a key of \(type)") }
        guard let id = d["id"] as? String, UUID(uuidString: id) != nil, id == id.lowercased() else { return out + ["id: not a lower-case UUID"] }
        if let v = d["v"] as? String { if UsageSchema.version(v) == nil { out.append("v: not a version") } } else { out.append("v: missing") }
        word(d["channel"], channels, "channel")
        word(d["install"], installs, "install")
        if type == "upgraded" {
            if let f = d["from"] as? String { if UsageSchema.version(f) == nil { out.append("from: not a version") } } else { out.append("from: missing") }
        }
        guard type == "daily" else { return out }
        func opt(_ k: String, _ f: (Any?, String) -> Void) { if d[k] != nil { f(d[k], k) } }
        opt("macos") { v, at in int(v, at); if let n = v as? Int, !(11...99).contains(n) { out.append("\(at): not a macOS major version") } }
        opt("chip") { word($0, chips, $1) }
        opt("ram") { word($0, Ranges.ram, $1) }
        opt("cores") { word($0, Ranges.cores, $1) }
        opt("commands") { counts($0, $1) { k in isCommandName(k) && (commandNames?.contains(k) ?? true) } }
        opt("failed") { counts($0, $1) { k in
            let p = k.split(separator: ":", omittingEmptySubsequences: false)
            guard p.count == 2, let code = Int(p[1]), (0...255).contains(code) else { return false }
            let c = String(p[0])
            return isCommandName(c) && (commandNames?.contains(c) ?? true)
        } }
        opt("onboarding") { v, at in
            guard let o = v as? [String: Any] else { out.append("\(at): not an object"); return }
            for k in o.keys where !(nested["onboarding"]!.contains(k)) { out.append("\(at).\(k): not allowed") }
            word(o["via"], onboardingVia, "\(at).via")
            word(o["step"], onboardingSteps, "\(at).step")
            bool(o["completed"], "\(at).completed")
        }
        opt("first_sandbox") { v, at in if (v as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue }) != true { out.append("\(at): only ever true") } }
        opt("time_to_first_session") { word($0, Ranges.firstSession, $1) }
        opt("created") { v, at in
            guard let o = v as? [String: Any] else { out.append("\(at): not an object"); return }
            for k in o.keys where !(nested["created"]!.contains(k)) { out.append("\(at).\(k): not allowed") }
            if o["agent"] != nil { counts(o["agent"], "\(at).agent") { agents.contains($0) } }
            if o["base"] != nil { counts(o["base"], "\(at).base") { !$0.hasPrefix("df-") && ($0 == "dockerfile" || BaseCatalogue.base($0) != nil) } }
            if o["account"] != nil { counts(o["account"], "\(at).account") { accounts.contains($0) } }
            if o["network"] != nil { counts(o["network"], "\(at).network") { networks.contains($0) } }
        }
        for k in ["sandboxes", "running_max", "points"] { opt(k) { word($0, Ranges.count, $1) } }
        opt("store_gb") { word($0, Ranges.storeGB, $1) }
        opt("timing_ms") { v, at in
            guard let o = v as? [String: Any] else { out.append("\(at): not an object"); return }
            for (k, x) in o {
                guard nested["timing_ms"]!.contains(k) else { out.append("\(at).\(k): not allowed"); continue }
                if k == "agent" { word(x, agents, "\(at).agent"); continue }
                guard let t = x as? [String: Any], Set(t.keys).isSubset(of: nested["timing"]!) else { out.append("\(at).\(k): not {p50, p90}"); continue }
                for q in ["p50", "p90"] {
                    guard let n = t[q] as? Int, n >= 0, n <= maxTimingMs, n % 50 == 0 else { out.append("\(at).\(k).\(q): not ms rounded to 50 (0 … 1 h)"); continue }
                }
                if let a = t["p50"] as? Int, let b = t["p90"] as? Int, a > b { out.append("\(at).\(k): p50 above p90") }
            }
        }
        for k in ["wake_failed", "crash_restores", "host_crashes", "points_taken", "templates_made"] { opt(k) { int($0, $1) } }
        opt("prep_failed") { counts($0, $1) { k in k.range(of: #"^[a-z0-9][a-z0-9._-]{0,47}$"#, options: .regularExpression) != nil } }
        for k in ["ui", "app", "serve", "rules", "agent_status"] { opt(k) { bool($0, $1) } }
        opt("serve_devices") { word($0, Ranges.serveDevices, $1) }
        opt("github") { word($0, githubModes, $1) }
        opt("upgrade_mode") { word($0, upgradeModes, $1) }
        opt("time") { v, at in
            guard let o = v as? [String: Any] else { out.append("\(at): not an object"); return }
            for (k, x) in o {
                switch k {
                case "running": counts(x, "\(at).running") { Ranges.running.contains($0) }
                case "asleep": counts(x, "\(at).asleep") { Ranges.asleep.contains($0) }
                case "removed_age": counts(x, "\(at).removed_age") { Ranges.removedAge.contains($0) }
                case "running_total": word(x, Ranges.total, "\(at).running_total")
                case "agent_working":
                    guard let m = x as? [String: Any] else { out.append("\(at).agent_working: not an object"); continue }
                    for (a, r) in m {
                        if !["claude-code", "pi"].contains(a) { out.append("\(at).agent_working: \(a) is not allowed") }
                        word(r, Ranges.total, "\(at).agent_working.\(a)")
                    }
                case "idle_running_8h": int(x, "\(at).idle_running_8h")
                default: out.append("\(at).\(k): not allowed")
                }
            }
        }
        return out
    }
}

// MARK: - the messages

/// What every message carries.
public struct UsageCommon: Codable, Equatable, Sendable {
    public var id: String
    public var v: String
    public var channel: String
    public var install: String

    public init(id: String, v: String, channel: String, install: String) {
        self.id = id
        self.v = v
        self.channel = channel
        self.install = install
    }
}

/// The `daily` message's own fields (614's schema). A field left nil is not sent.
public struct UsageDaily: Codable, Equatable, Sendable {
    public struct Onboarding: Codable, Equatable, Sendable {
        public var via: String
        public var step: String
        public var completed: Bool
    }
    public struct Created: Codable, Equatable, Sendable {
        public var agent: [String: Int]?
        public var base: [String: Int]?
        public var account: [String: Int]?
        public var network: [String: Int]?
        public var isEmpty: Bool { agent == nil && base == nil && account == nil && network == nil }
    }
    public struct Percentiles: Codable, Equatable, Sendable {
        public var p50: Int
        public var p90: Int
    }
    public struct Timing: Codable, Equatable, Sendable {
        public var start: Percentiles?
        public var wake: Percentiles?
        public var hibernate: Percentiles?
        public var pause: Percentiles?
        public var agent: String?
        public var isEmpty: Bool { start == nil && wake == nil && hibernate == nil && pause == nil }
    }
    public struct Time: Codable, Equatable, Sendable {
        public var running: [String: Int]?
        public var asleep: [String: Int]?
        public var removedAge: [String: Int]?
        public var runningTotal: String?
        public var agentWorking: [String: String]?
        public var idleRunning8h: Int?
        enum CodingKeys: String, CodingKey {
            case running, asleep
            case removedAge = "removed_age", runningTotal = "running_total", agentWorking = "agent_working", idleRunning8h = "idle_running_8h"
        }
    }

    public var macos: Int?
    public var chip: String?
    public var ram: String?
    public var cores: String?
    public var commands: [String: Int]?
    public var failed: [String: Int]?
    public var onboarding: Onboarding?
    public var firstSandbox: Bool?
    public var timeToFirstSession: String?
    public var created: Created?
    public var sandboxes: String?
    public var runningMax: String?
    public var points: String?
    public var storeGB: String?
    public var timingMs: Timing?
    public var wakeFailed: Int?
    public var crashRestores: Int?
    public var hostCrashes: Int?
    public var prepFailed: [String: Int]?
    public var ui: Bool?
    public var app: Bool?
    public var serve: Bool?
    public var serveDevices: String?
    public var rules: Bool?
    public var github: String?
    public var agentStatus: Bool?
    public var pointsTaken: Int?
    public var templatesMade: Int?
    public var upgradeMode: String?
    public var time: Time?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case macos, chip, ram, cores, commands, failed, onboarding
        case firstSandbox = "first_sandbox", timeToFirstSession = "time_to_first_session"
        case created, sandboxes
        case runningMax = "running_max", points, storeGB = "store_gb", timingMs = "timing_ms"
        case wakeFailed = "wake_failed", crashRestores = "crash_restores", hostCrashes = "host_crashes", prepFailed = "prep_failed"
        case ui, app, serve, serveDevices = "serve_devices", rules, github, agentStatus = "agent_status"
        case pointsTaken = "points_taken", templatesMade = "templates_made", upgradeMode = "upgrade_mode", time
    }
}

/// One message of the closed list.
public enum UsageMessage: Equatable, Sendable {
    case installed(UsageCommon)
    case upgraded(UsageCommon, from: String)
    case daily(UsageCommon, UsageDaily)

    public var type: String {
        switch self { case .installed: "installed"; case .upgraded: "upgraded"; case .daily: "daily" }
    }

    /// The bytes handed over: one JSON object, keys sorted, nothing else.
    public func encoded() -> Data {
        struct Head: Encodable { var type: String; var common: UsageCommon; var from: String?
            enum K: String, CodingKey { case type, from }
            func encode(to e: Encoder) throws {
                try common.encode(to: e)
                var c = e.container(keyedBy: K.self)
                try c.encode(type, forKey: .type)
                try c.encodeIfPresent(from, forKey: .from)
            }
        }
        struct Whole: Encodable { var head: Head; var daily: UsageDaily?
            func encode(to e: Encoder) throws {
                try head.encode(to: e)
                try daily?.encode(to: e)
            }
        }
        let whole: Whole = switch self {
        case .installed(let c): Whole(head: Head(type: type, common: c, from: nil), daily: nil)
        case .upgraded(let c, let from): Whole(head: Head(type: type, common: c, from: from), daily: nil)
        case .daily(let c, let d): Whole(head: Head(type: type, common: c, from: nil), daily: d)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(whole)) ?? Data()
    }
}

// MARK: - this Mac

/// The machine block: macOS major, chip family, RAM and cores as ranges.
public struct UsageMachine: Equatable, Sendable {
    public var macos: Int
    public var chip: String
    public var ram: String
    public var cores: String

    public static func current() -> UsageMachine {
        var mem: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &mem, &size, nil, 0)
        return UsageMachine(macos: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                            chip: UsageSchema.chip(brand: sysctlString("machdep.cpu.brand_string")),
                            ram: UsageSchema.ram(bytes: mem), cores: UsageSchema.cores(ProcessInfo.processInfo.processorCount))
    }
}

// MARK: - what is kept on this Mac

/// One day's counts, as recorded by the commands themselves.
public struct UsageDay: Codable, Equatable, Sendable {
    /// The local calendar day (yyyy-MM-dd) — kept here, never sent.
    public var day: String
    public var commands: [String: Int] = [:]
    public var failed: [String: Int] = [:]
    public var onboarding: UsageDaily.Onboarding?

    public init(day: String) { self.day = day }
    public var isEmpty: Bool { commands.isEmpty && failed.isEmpty && onboarding == nil }
}

/// `<settings dir>/usage.json`.
public struct UsageState: Codable, Equatable, Sendable {
    public var current: UsageDay?
    /// A day that ended with its daily not yet built and handed over (the next command does it).
    public var closed: UsageDay?
    /// The last day a daily was handed over for.
    public var lastDaily: String?
    /// The version that last ran (an `installed` or `upgraded` is due when this one differs).
    public var lastVersion: String?
    public var noticeShown: Bool?

    public init() {}
}

/// The files, under one lock (several doz processes may run at once).
public struct UsageFiles: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// Beside doz.toml (nil: no settings directory — then nothing is kept and nothing sent).
    public static func current(_ env: [String: String] = ProcessInfo.processInfo.environment) -> UsageFiles? {
        DozerSettings.fileURL(environment: env).map { UsageFiles(directory: $0.deletingLastPathComponent()) }
    }

    public var idFile: URL { directory.appendingPathComponent("usage-id") }
    public var stateFile: URL { directory.appendingPathComponent("usage.json") }
    var lockFile: URL { directory.appendingPathComponent(".usage.lock") }

    /// The install id, when one was made.
    public func readID() -> String? {
        guard let s = try? String(contentsOf: idFile, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return UUID(uuidString: t) != nil ? t : nil
    }

    /// The install id, made when there is none (a random UUID — nothing of this Mac's).
    public func id() throws -> String {
        if let i = readID() { return i }
        let i = UUID().uuidString.lowercased()
        try write(Data((i + "\n").utf8), to: idFile)
        return i
    }

    /// A new install id, and the day's counts forgotten.
    @discardableResult
    public func reset() throws -> String {
        try withLock {
            var s = load()
            s.current = nil
            s.closed = nil
            try save(s)
        }
        unlink(idFile.path)
        return try id()
    }

    public func load() -> UsageState {
        guard let d = try? Data(contentsOf: stateFile), d.count <= 1 << 20 else { return UsageState() }
        return (try? JSONDecoder().decode(UsageState.self, from: d)) ?? UsageState()
    }

    public func save(_ s: UsageState) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try write(try enc.encode(s), to: stateFile)
    }

    /// Read-modify-write under an exclusive lock.
    public func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw UsageError("cannot open \(lockFile.path)") }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = directory.appendingPathComponent(".\(url.lastPathComponent).\(getpid())")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw UsageError("cannot write \(url.path)")
        }
        guard rename(tmp.path, url.path) == 0 else { unlink(tmp.path); throw UsageError("cannot write \(url.path)") }
    }
}

// MARK: - the day's numbers

/// What the host already recorded about one day, read from the store (nothing new is collected for this).
public struct UsageStoreFacts: Equatable, Sendable {
    /// The metrics rows of that day (actions only).
    public var events: [MetricsEvent] = []
    public var sandboxes: Int?
    public var points: Int?
    /// The store's onboarding record says it finished that day.
    public var onboardedThatDay = false

    public init(events: [MetricsEvent] = [], sandboxes: Int? = nil, points: Int? = nil, onboardedThatDay: Bool = false) {
        self.events = events
        self.sandboxes = sandboxes
        self.points = points
        self.onboardedThatDay = onboardedThatDay
    }

    /// Read from `store` for the local day `day` (yyyy-MM-dd). Never creates anything in the store.
    public static func read(_ store: DozerStore, day: String, calendar: Calendar = .current) -> UsageStoreFacts {
        var f = UsageStoreFacts()
        guard let (start, end) = UsageClock.range(of: day, calendar: calendar) else { return f }
        if FileManager.default.fileExists(atPath: store.metrics.path), let m = try? MetricsStore(url: store.metrics) {
            f.events = m.events(MetricsFilter(since: start, includeSteps: false)).filter { $0.startedAt < end && $0.kind == .action }
        }
        let names = store.sandboxNames()
        f.sandboxes = names.count
        f.points = names.reduce(0) { n, name in
            let dir = store.layout(name).sandboxDirectory.appendingPathComponent("restore-points")
            let ids = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return n + ids.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent("\($0)/meta.json").path) }.count
        }
        if let r = OnboardingRecord.read(store), r.date >= start, r.date < end { f.onboardedThatDay = true }
        return f
    }
}

public enum UsageClock {
    /// The local calendar day of `date` (yyyy-MM-dd).
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The start and end of a local day.
    public static func range(of day: String, calendar: Calendar = .current) -> (Date, Date)? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, let start = calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2])),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start, end)
    }

    /// Whole days from `day` to `today` (negative: `day` is later).
    public static func daysBetween(_ day: String, _ today: String, calendar: Calendar = .current) -> Int? {
        guard let (a, _) = range(of: day, calendar: calendar), let (b, _) = range(of: today, calendar: calendar) else { return nil }
        return calendar.dateComponents([.day], from: a, to: b).day
    }
}

public enum UsageDailyBuilder {
    /// The `daily` fields of one day — a pure function of what was recorded (the day's counts), what the host
    /// recorded (`facts`), this Mac and two settings.
    public static func build(_ day: UsageDay, facts: UsageStoreFacts, machine: UsageMachine, upgradeMode: String) -> UsageDaily {
        var d = UsageDaily()
        d.macos = machine.macos
        d.chip = machine.chip
        d.ram = machine.ram
        d.cores = machine.cores
        d.commands = UsageSchema.limited(day.commands.filter { UsageSchema.isCommandName($0.key) })
        d.failed = UsageSchema.limited(day.failed)
        if var o = day.onboarding {
            if facts.onboardedThatDay { o.step = "done"; o.completed = true }
            d.onboarding = o
        }

        let ev = facts.events
        // Sandboxes created that day: agent, base (catalogue ids; a Dockerfile counted only as such), network preset.
        var created = UsageDaily.Created()
        for e in ev where e.action == "create" && e.ok != false {
            let image = e.image ?? ""
            if let a = UsageSchema.agent(image: image) { created.agent = bump(created.agent, a) }
            if let b = UsageSchema.base(image: image) { created.base = bump(created.base, b) }
            if let n = network(of: e) { created.network = bump(created.network, UsageSchema.network(n)) }
        }
        if !created.isEmpty { d.created = created }

        if let n = facts.sandboxes { d.sandboxes = UsageSchema.count(n) }
        if let n = facts.points { d.points = UsageSchema.count(n) }

        // Lifecycle timings: p50/p90 of the day's successful ones, rounded to 50 ms; with the day's most-used agent.
        var timing = UsageDaily.Timing()
        func pct(_ action: String) -> UsageDaily.Percentiles? {
            let ms = ev.filter { $0.action == action && $0.ok == true }.compactMap(\.durationMs)
            guard let p50 = MetricsMath.percentile(ms, 0.5), let p90 = MetricsMath.percentile(ms, 0.9) else { return nil }
            return UsageDaily.Percentiles(p50: UsageSchema.round50(p50), p90: UsageSchema.round50(p90))
        }
        timing.start = pct("start")
        timing.wake = pct("wake")
        timing.hibernate = pct("hibernate")
        timing.pause = pct("pause")
        if !timing.isEmpty {
            var uses: [String: Int] = [:]
            for e in ev where ["start", "wake", "hibernate", "pause"].contains(e.action) {
                if let a = UsageSchema.agent(image: e.image ?? "") { uses[a, default: 0] += 1 }
            }
            timing.agent = uses.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
            d.timingMs = timing
        }

        // Reliability.
        let wakeFailed = ev.filter { $0.action == "wake" && $0.ok == false }.count
        let restores = ev.filter { $0.action == "restore after crash" }.count
        let crashes = Set(ev.filter { $0.action == "died with host" }.map(\.run)).count
        if wakeFailed > 0 { d.wakeFailed = wakeFailed }
        if restores > 0 { d.crashRestores = restores }
        if crashes > 0 { d.hostCrashes = crashes }

        // Features.
        let names = Set(day.commands.keys)
        if names.contains(where: { $0 == "ui" || $0.hasPrefix("ui ") }) { d.ui = true }
        if names.contains(where: { $0 == "serve" || $0.hasPrefix("serve ") }) { d.serve = true }
        let taken = ev.filter { $0.action == "take restore point" && $0.ok == true }.count
        let templates = ev.filter { $0.action == "save as template" && $0.ok == true }.count
        if taken > 0 { d.pointsTaken = taken }
        if templates > 0 { d.templatesMade = templates }
        if UsageSchema.upgradeModes.contains(upgradeMode) { d.upgradeMode = upgradeMode }
        return d
    }

    static func bump(_ m: [String: Int]?, _ k: String) -> [String: Int] {
        var m = m ?? [:]
        m[k, default: 0] += 1
        return m
    }

    /// The network preset a create row recorded (`detailJSON` {"network": …}).
    static func network(of e: MetricsEvent) -> String? {
        guard let j = e.detailJSON, let d = try? JSONSerialization.jsonObject(with: Data(j.utf8)) as? [String: Any] else { return nil }
        return d["network"] as? String
    }
}

// MARK: - recording and handing over

/// What a command run does with usage statistics: record it (when on), and hand over what is due.
public struct UsageRecorder: Sendable {
    public let files: UsageFiles
    public let now: Date
    public let calendar: Calendar

    public init(files: UsageFiles, now: Date = Date(), calendar: Calendar = .current) {
        self.files = files
        self.now = now
        self.calendar = calendar
    }

    var today: String { UsageClock.day(now, calendar: calendar) }

    /// Count a command (before it runs — a killed one still counted) and, when a new day began, close the last one.
    public func recordCommand(_ name: String) throws {
        guard UsageSchema.isCommandName(name) else { return }
        try update { day in day.commands[name, default: 0] += 1 }
    }

    /// A command that failed, with its exit code.
    public func recordFailure(_ name: String, exitCode: Int32) throws {
        guard UsageSchema.isCommandName(name), (1...255).contains(exitCode) else { return }
        try update { day in day.failed["\(name):\(exitCode)", default: 0] += 1 }
    }

    /// The setup wizard or `doz onboard` reached `step` (a later step, or completion, is never overwritten by an earlier one).
    public func recordOnboarding(via: String, step: String, completed: Bool) throws {
        guard UsageSchema.onboardingVia.contains(via), UsageSchema.onboardingSteps.contains(step) else { return }
        try update { day in
            let order = UsageSchema.onboardingSteps
            if let o = day.onboarding, o.completed || (order.firstIndex(of: o.step) ?? 0) > (order.firstIndex(of: step) ?? 0) { return }
            day.onboarding = UsageDaily.Onboarding(via: via, step: step, completed: completed)
        }
    }

    private func update(_ change: (inout UsageDay) -> Void) throws {
        try files.withLock {
            var s = files.load()
            roll(&s)
            var day = s.current ?? UsageDay(day: today)
            change(&day)
            s.current = day
            try files.save(s)
        }
    }

    /// A new day: the current one becomes the closed one (an older closed one that was never handed over is dropped).
    func roll(_ s: inout UsageState) {
        guard let cur = s.current, cur.day != today else { return }
        s.closed = cur.isEmpty ? s.closed : cur
        s.current = nil
    }

    /// The messages due now: `installed`/`upgraded` when this version is new here, and the daily of a closed day of the
    /// last 7 days. `take`: remove them from the record (each is handed over once); false: only look (`telemetry show`).
    public func due(version: String, channel: String, install: String, id: String, facts: (String) -> UsageStoreFacts,
                    machine: UsageMachine, upgradeMode: String, take: Bool = true) throws -> [UsageMessage] {
        if take { return try files.withLock { try compute(take: true, version: version, channel: channel, install: install, id: id, facts: facts, machine: machine, upgradeMode: upgradeMode) } }
        return try compute(take: false, version: version, channel: channel, install: install, id: id, facts: facts, machine: machine, upgradeMode: upgradeMode)
    }

    private func compute(take: Bool, version: String, channel: String, install: String, id: String, facts: (String) -> UsageStoreFacts,
                         machine: UsageMachine, upgradeMode: String) throws -> [UsageMessage] {
        var s = files.load()
        roll(&s)
        var out: [UsageMessage] = []
        let common = UsageCommon(id: id, v: version, channel: channel, install: install)
        if s.lastVersion != version {
            if let last = s.lastVersion.flatMap(UsageSchema.version), SemVer.compare(version, last) == .orderedDescending {
                out.append(.upgraded(common, from: last))
            } else {
                out.append(.installed(common))
            }
            s.lastVersion = version
        }
        if let closed = s.closed {
            s.closed = nil
            if let age = UsageClock.daysBetween(closed.day, today, calendar: calendar), (1...7).contains(age), s.lastDaily != closed.day {
                out.append(.daily(common, UsageDailyBuilder.build(closed, facts: facts(closed.day), machine: machine, upgradeMode: upgradeMode)))
                s.lastDaily = closed.day
            }
        }
        if take { try files.save(s) }
        return out
    }

    /// What today's daily holds so far (`doz telemetry show`): it is handed over on the first command of a later day.
    public func todaySoFar(_ common: UsageCommon, facts: UsageStoreFacts, machine: UsageMachine, upgradeMode: String) -> UsageMessage {
        var s = files.load()
        roll(&s)
        return .daily(common, UsageDailyBuilder.build(s.current ?? UsageDay(day: today), facts: facts, machine: machine, upgradeMode: upgradeMode))
    }

    /// Statistics were turned off (the setting, its variable, DO_NOT_TRACK): forget the days recorded while they were
    /// on, so nothing recorded before is sent if they are turned on again.
    public func forgetDays() {
        guard FileManager.default.fileExists(atPath: files.stateFile.path) else { return }
        _ = try? files.withLock {
            var s = files.load()
            guard s.current != nil || s.closed != nil else { return }
            s.current = nil
            s.closed = nil
            try files.save(s)
        }
    }

    /// Hand `messages` over — only those that fit the closed list — then flush, capped. Returns how many went.
    @discardableResult
    public static func handOver(_ messages: [UsageMessage]) -> Int {
        var n = 0
        for m in messages {
            let data = m.encoded()
            guard UsageSchema.problems(data).isEmpty else { continue }
            Usage.send(data)
            n += 1
        }
        if n > 0 { Usage.flush(Usage.flushTimeout) }
        return n
    }

    /// The one-time notice: due once per settings directory.
    public func takeNotice() -> Bool {
        (try? files.withLock {
            var s = files.load()
            guard s.noticeShown != true else { return false }
            s.noticeShown = true
            try files.save(s)
            return true
        }) ?? false
    }

    public static let notice = "doz sends anonymous usage statistics (counts and ranges — no names, paths or contents). "
        + "Turn off: doz config set telemetry.send_anonymous_usage_stats false · what is sent: doz telemetry show · \(Usage.privacyPage)"
}

/// This process's view: the flag its command line gave, and the decision made from it and the settings NOW (a running
/// `doz ui` sees the switch change on its Settings page).
public enum UsageRuntime {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var commandLineFlag: Bool?

    /// `--send-anonymous-usage-stats` (true) / `--no-send-anonymous-usage-stats` (false) on this process's command line.
    public static func configure(flag: Bool?) { lock.withLock { commandLineFlag = flag } }
    public static var flag: Bool? { lock.withLock { commandLineFlag } }

    public static func decide(env: [String: String] = ProcessInfo.processInfo.environment,
                              settings: DozerSettings? = nil, flag: Bool? = nil) -> UsageSwitch {
        let official = Usage.isOfficial
        // An open build decides without looking at anything (it has nothing to send).
        let method: InstallMethod = official ? InstallMethod.detect(executable: HostLauncher.executablePath) : .development
        return UsageSwitches.decide(official: official, method: method, settings: settings ?? .load(environment: env), env: env,
                                    flag: flag ?? self.flag, guarded: TestSafety.guarded(env))
    }

    /// The setup wizard (the web) reached a step — recorded only while statistics are on.
    public static func recordOnboarding(via: String, step: String, completed: Bool) {
        guard decide().on, let files = UsageFiles.current() else { return }
        try? UsageRecorder(files: files).recordOnboarding(via: via, step: step, completed: completed)
    }
}
