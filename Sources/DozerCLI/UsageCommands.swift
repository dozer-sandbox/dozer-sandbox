import ArgumentParser
import Darwin
import DozerHost
import DozerKit
import Foundation

// Anonymous usage statistics (`doz telemetry`), the optional sign-up (`doz signup`), and the hook every command
// passes through (`UsageHook`, called by `DozerEntry`). What may be sent, and the switches, are in
// Sources/DozerHost/Usage.swift; a build from this repository sends nothing (`Usage.isOfficial` is false).

/// The command a person ran, as doz names it — words of doz's own command tree only (aliases to their canonical
/// name), never an argument: `doz start mybox` → `start`, `doz ui start --port 9` → `ui start`.
enum UsageCommandName {
    static func resolve(_ args: [String]) -> String? {
        var type: ParsableCommand.Type = DozerCommand.self
        var path: [String] = []
        for w in UpdateHook.words(args) {
            guard let next = type.configuration.subcommands.first(where: { $0._commandName == w || $0.configuration.aliases.contains(w) }) else { break }
            path.append(next._commandName)
            type = next
        }
        return path.isEmpty ? nil : path.joined(separator: " ")
    }

    /// Every name `resolve` can give (the vocabulary the statistics' `commands` use).
    static var all: Set<String> {
        var out: Set<String> = []
        func walk(_ t: ParsableCommand.Type, _ prefix: [String]) {
            for s in t.configuration.subcommands {
                let p = prefix + [s._commandName]
                out.insert(p.joined(separator: " "))
                walk(s, p)
            }
        }
        walk(DozerCommand.self, [])
        return out
    }
}

/// What a command run does about usage statistics. Never fails a command and never delays it noticeably: the record
/// is a small file under a lock; handing over happens only when something is due (once a day, once a version), and
/// the flush is capped at a second.
struct UsageHook {
    static let onFlag = "--send-anonymous-usage-stats"
    static let offFlag = "--no-send-anonymous-usage-stats"

    let args: [String]
    /// The flag on this command line (the last one wins).
    let flag: Bool?
    /// The command's name (nil: not one of doz's, or one the statistics leave alone).
    let name: String?
    let env: [String: String]

    init(_ args: [String], env: [String: String] = ProcessInfo.processInfo.environment) {
        self.args = args
        self.env = env
        flag = args.last(where: { $0 == Self.onFlag || $0 == Self.offFlag }).map { $0 == Self.onFlag }
        name = Self.counts(args) ? UsageCommandName.resolve(args) : nil
    }

    /// The arguments ArgumentParser parses: the two flags are taken out where they stand before the command (`doz
    /// --no-send-anonymous-usage-stats ls`, dbt's place); after it, every command's options take them.
    static func parserArguments(_ args: [String]) -> [String] {
        var out: [String] = []
        var seenWord = false
        var skip = false
        for a in args {
            if skip { skip = false; out.append(a); continue }
            if ["--store", "--progress"].contains(a) { skip = true; out.append(a); continue }
            if !a.hasPrefix("-") { seenWord = true }
            if !seenWord && (a == onFlag || a == offFlag) { continue }
            out.append(a)
        }
        return out
    }

    /// Runs the statistics leave alone: help and version, `doz telemetry` itself (looking never sends), and doz's
    /// own internal re-launches (a detached host, doz serve or doz ui; Homebrew's post-install check).
    static func counts(_ args: [String]) -> Bool {
        if args.contains(where: { ["--help", "-h", "--version", "--launched", "--launch-detached", "--restarted"].contains($0) }) { return false }
        let w = UpdateHook.words(args)
        guard let first = w.first, !["telemetry", "help"].contains(first) else { return false }
        return !(w.starts(with: ["host", "upgrade-check"]))
    }

    var decision: UsageSwitch { UsageRuntime.decide(env: env, flag: flag) }

    /// Before the command runs: count it.
    func before() {
        UsageRuntime.configure(flag: flag)
        guard let name else { return }
        let d = decision
        guard let files = UsageFiles.current(env) else { return }
        guard d.on else {
            // Turned off for good (not only for this command): what was recorded while on is forgotten.
            if d.official && (d.doNotTrack || (!d.setting && d.settingSource != .flag)) { UsageRecorder(files: files).forgetDays() }
            return
        }
        let r = UsageRecorder(files: files)
        try? r.recordCommand(name)
        if name == "onboard" { try? r.recordOnboarding(via: "cli", step: "started", completed: false) }
    }

    /// After it: a failure's exit code; what is due, handed over; the one-time notice.
    func after(exitCode: Int32) {
        guard let name, decision.on, let files = UsageFiles.current(env) else { return }
        let r = UsageRecorder(files: files)
        if exitCode != 0 { try? r.recordFailure(name, exitCode: exitCode) }
        if name == "onboard" && exitCode == 0 { try? r.recordOnboarding(via: "cli", step: "done", completed: true) }
        let settings = DozerSettings.load(environment: env)
        let ctx = UpdateContext.current(version: DozerCommand.version, executable: HostLauncher.executablePath, settings: settings, env: env)
        let store = UpdateHook.storeOf(args)
        if Self.noticeApplies(args), r.takeNotice() { Out.stderr(UsageRecorder.notice + "\n") }
        guard let id = try? files.id(),
              let due = try? r.due(version: DozerCommand.version, channel: ctx.channel.rawValue, install: Self.install(ctx.method), id: id,
                                   facts: { UsageStoreFacts.read(store, day: $0) }, machine: .current(),
                                   upgradeMode: settings.string(SettingKey.updatesMode) ?? "notify")
        else { return }
        UsageRecorder.handOver(due)
    }

    /// The notice is for a person: a terminal (stderr), never --json or -q.
    static func noticeApplies(_ args: [String], env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if args.contains(where: { ["--json", "-q", "--quiet"].contains($0) }) { return false }
        return env["DOZ_TEST_USAGE_TTY"] == "1" || isatty(STDERR_FILENO) == 1
    }

    static func install(_ m: InstallMethod) -> String {
        if case .homebrew = m { return "homebrew" }
        return "tarball"
    }
}

// MARK: - doz telemetry

struct TelemetryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "telemetry",
        abstract: "Anonymous usage statistics: whether this doz sends them, and exactly what it would send.",
        discussion: """
        Official builds (Homebrew, the release download) send anonymous usage statistics: at most once a day, counts \
        and ranges about how Dozer itself is used, with a random install id — never a name, path, host, command \
        argument, file or anything from inside a sandbox. Builds from the open-source repository send nothing. \
        Turn them off with any one of: doz config set telemetry.send_anonymous_usage_stats false · DO_NOT_TRACK=1 · \
        --no-send-anonymous-usage-stats on one command.
        """,
        subcommands: [TelemetryShow.self, TelemetryReset.self],
        defaultSubcommand: TelemetryShow.self)
}

/// What `doz telemetry show --json` prints.
struct TelemetryReport: Encodable {
    /// The official build's package is in this doz (false: a build from the open-source repository — it sends nothing).
    var official: Bool
    var on: Bool
    var why: String
    var setting: Bool
    var settingSource: String
    var doNotTrack: Bool
    /// The random install id (nil: none made yet — an official build makes it with its first message).
    var installId: String?
    var idFile: String?
    var recordFile: String?
    /// Handed over after the next command, exactly (empty when off).
    var next: [JSONValue]
    /// Today's daily message so far, exactly — sent on the first command of a later day. A build that sends nothing
    /// shows what an official build would send.
    var today: JSONValue
    var privacy: String
}

struct TelemetryShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show",
        abstract: "Whether usage statistics are sent and why, the install id, and exactly what would be sent (--json: the messages as they are sent).")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        let r = Self.report(store: g.dozerStore, flag: g.sendAnonymousUsageStats)
        if g.json { Out.json(r); return }
        var out = "Usage statistics: \(r.on ? "on" : "off") — \(r.why)\n"
        out += "  official build:  \(r.official ? "yes" : "no — built from the open-source repository; it sends nothing")\n"
        out += "  the setting:     telemetry.send_anonymous_usage_stats = \(r.setting) (\(r.settingSource))\n"
        out += "  DO_NOT_TRACK:    \(r.doNotTrack ? "set — nothing is sent" : "not set")\n"
        out += "  install id:      \(r.installId ?? "none yet (an official build makes one with its first message; doz telemetry reset replaces it)")\n"
        if let f = r.recordFile { out += "  kept on this Mac: \(r.idFile ?? "") and \(f)\n" }
        if r.next.isEmpty {
            out += "\nAfter the next command: nothing is sent.\n"
        } else {
            out += "\nAfter the next command, exactly:\n"
            for m in r.next { out += Self.pretty(m) + "\n" }
        }
        out += r.on ? "\nToday so far — sent on the first command of a later day, exactly:\n"
                    : "\nToday so far — what an official build with statistics on would send (this doz sends nothing):\n"
        out += Self.pretty(r.today) + "\n"
        out += "\nWhat each field means, and the switches: \(r.privacy)\n"
        Out.stdout(out)
    }

    static func pretty(_ v: JSONValue) -> String {
        (try? HostWire.prettyEncoder.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The report for this process (pure apart from reading the files and the store; it never sends, never records).
    static func report(store: DozerStore, flag: Bool?, env: [String: String] = ProcessInfo.processInfo.environment,
                       now: Date = Date()) -> TelemetryReport {
        let settings = DozerSettings.load(environment: env)
        let d = UsageRuntime.decide(env: env, settings: settings, flag: flag)
        let files = UsageFiles.current(env)
        let ctx = UpdateContext.current(version: DozerCommand.version, executable: HostLauncher.executablePath, settings: settings, env: env)
        let existing = files?.readID()
        let id = d.on ? ((try? files?.id()) ?? existing) : existing
        let common = UsageCommon(id: id ?? "00000000-0000-0000-0000-000000000000", v: DozerCommand.version,
                                 channel: ctx.channel.rawValue, install: UsageHook.install(ctx.method))
        let upgradeMode = settings.string(SettingKey.updatesMode) ?? "notify"
        let machine = UsageMachine.current()
        let today = UsageClock.day(now)
        var next: [JSONValue] = []
        var todayMessage = UsageMessage.daily(common, UsageDailyBuilder.build(UsageDay(day: today), facts: UsageStoreFacts.read(store, day: today),
                                                                              machine: machine, upgradeMode: upgradeMode))
        if d.on, let files, let id {
            let r = UsageRecorder(files: files, now: now)
            let due = (try? r.due(version: common.v, channel: common.channel, install: common.install, id: id,
                                  facts: { UsageStoreFacts.read(store, day: $0) }, machine: machine, upgradeMode: upgradeMode, take: false)) ?? []
            next = due.compactMap { try? HostWire.decoder.decode(JSONValue.self, from: $0.encoded()) }
            todayMessage = r.todaySoFar(common, facts: UsageStoreFacts.read(store, day: today), machine: machine, upgradeMode: upgradeMode)
        }
        let todayJSON = (try? HostWire.decoder.decode(JSONValue.self, from: todayMessage.encoded())) ?? .null
        return TelemetryReport(official: d.official, on: d.on, why: d.why, setting: d.setting, settingSource: d.settingSource.rawValue,
                               doNotTrack: d.doNotTrack, installId: id, idFile: files?.idFile.path, recordFile: files?.stateFile.path,
                               next: next, today: todayJSON, privacy: Usage.privacyPage)
    }
}

struct TelemetryReset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reset",
        abstract: "Replace the install id with a new random one and forget the day's counts.")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        guard let files = UsageFiles.current() else {
            throw fail(HostError(.failed, "no settings directory (neither XDG_CONFIG_HOME nor HOME is set)"), g)
        }
        let id: String
        do { id = try files.reset() } catch { throw fail(HostError(.failed, "\(error)"), g) }
        if g.json { Out.json(["installId": id]); return }
        Out.stdout("a new install id: \(id) — the day's counts were forgotten\(Usage.isOfficial ? "" : " (this build sends nothing)")\n")
    }
}

// MARK: - doz signup

struct SignupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "signup",
        abstract: "Sign up for news from Dozer — release news, early access, tips and tricks (optional; an email, confirmed before anything is sent).",
        discussion: """
        Asks for your email and what you want on a terminal (or --email and --interest). A confirmation email comes \
        first; nothing else is sent until you confirm, and every email has a one-click unsubscribe. Your email is \
        never linked to the usage statistics. Builds from the open-source repository point to the website instead.
        """)

    @OptionGroup var g: GlobalOptions
    @Option(name: .long, help: "Your email address.") var email: String?
    @Option(name: .customLong("interest"), help: "release-news, early-access or tips (repeat it for more than one).") var interests: [String] = []
    @Flag(name: [.short, .long], help: "Do not ask (needs --email and at least one --interest).") var yes = false

    static let labels = ["release news", "early access to new features", "tips and tricks"]

    func validate() throws {
        for i in interests where !SignupRequest.interestValues.contains(i) {
            throw ValidationError("--interest: release-news, early-access or tips")
        }
    }

    func run() async throws {
        guard Usage.isOfficial else {
            struct Open: Encodable { var included = false; var url = Usage.signupPage }
            if g.json { Out.json(Open()); return }
            Out.stdout("This doz is built from the open-source repository and does not include the sign-up — sign up at \(Usage.signupPage)\n")
            return
        }
        let asker = Asker(yes: yes, json: g.json)
        guard let request = try Self.ask(asker, email: email, interests: interests, source: "cli", g) else {
            throw fail(HostError(.invalid, "off a terminal: doz signup --email ADDRESS --interest release-news|early-access|tips"), g)
        }
        let result = try await Self.send(request, g)
        if g.json { Out.json(result); return }
        Out.stdout(Self.answerLine(result, email: request.email) + "\n")
    }

    /// The questions (on a terminal), or the flags. Nil: something is missing and there is no terminal to ask.
    static func ask(_ asker: Asker, email: String?, interests: [String], source: String, _ g: GlobalOptions) throws -> SignupRequest? {
        var e = email
        if e == nil, asker.interactive {
            e = asker.text("Your email", default: "") { SignupRequest.emailProblem($0.trimmingCharacters(in: .whitespaces)) }
        }
        var wanted = interests
        if wanted.isEmpty, asker.interactive {
            while wanted.isEmpty {
                let ticks = asker.checklist("What would you like?", labels.map { ($0, false) })
                wanted = zip(SignupRequest.interestValues, ticks).filter(\.1).map(\.0)
                if wanted.isEmpty { Out.stdout("  choose at least one (e.g. 1)\n") }
            }
        }
        guard let e, !wanted.isEmpty else { return nil }
        do { return try SignupRequest.make(email: e, interests: wanted, source: source) } catch let err as UsageError {
            throw fail(HostError(.invalid, err.message), g)
        }
    }

    /// Through the official build's package; a failure's message never carries the address.
    static func send(_ r: SignupRequest, _ g: GlobalOptions) async throws -> SignupResult {
        do { return try await Usage.signup(r) } catch {
            let why = "\(error)".replacingOccurrences(of: r.email, with: "…")
            throw fail(HostError(.failed, "the sign-up could not be sent (\(why)) — try again later, or at \(Usage.signupPage)"), g)
        }
    }

    static func answerLine(_ r: SignupResult, email: String) -> String {
        r.status == "already-confirmed"
            ? "\(email) is already signed up — nothing changed"
            : "Check \(email): a confirmation email is on its way. Nothing else is sent until you confirm; every email has a one-click unsubscribe."
    }
}
