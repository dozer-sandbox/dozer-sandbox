import ArgumentParser
import Darwin
import Foundation
import SnoozeContainerKit
import SnoozeHost

// MARK: image

struct ImageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "image", abstract: "Images: the built-in lab, claude-code and pi, and custom images saved from restore points.",
                                                    subcommands: [ImageList.self, ImageBake.self, ImageRemove.self, ImagePull.self, ImagePush.self],
                                                    defaultSubcommand: ImageList.self)
}

struct ImageList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List the images and whether each is baked in this store.")
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        let rows = try decode(try await query(HostRequest(.imageList), g), [ImageRow].self, g)
        if g.json { Out.json(rows); return }
        var t = [["IMAGE", "KIND", "BAKED", "SIZE", "NOTE"]]
        for r in rows {
            t.append([r.name, r.kind, r.baked ? (r.bakedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "yes") : "no (bakes on first start)",
                      r.allocatedBytes.map(SnoozeImages.formatBytes) ?? "—", [r.note, r.fromSandbox.map { "from \($0)" }].compactMap { $0 }.joined(separator: " · ")])
        }
        Out.stdout(Out.table(t))
    }
}

struct ImageBake: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "bake", abstract: "Bake a built-in image now (otherwise the first start does it; minutes, needs network).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "lab, claude-code or pi.") var image: String
    func run() async throws {
        var r = HostRequest(.imageBake)
        r.image = image
        let row = try decode(try call(r, g), ImageRow.self, g)
        if g.json { Out.json(row) } else { Out.stdout("\(row.name) baked\(row.allocatedBytes.map { " (\(SnoozeImages.formatBytes($0)))" } ?? "")\n") }
    }
}

struct ImageRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove an image's baked disk (sandboxes cloned from it keep working).")
    @OptionGroup var g: GlobalOptions
    @Argument var image: String
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false
    func run() async throws {
        try confirm("Remove the image \(image)? (It is baked again when next needed.)", yes: yes, g)
        var r = HostRequest(.imageRm)
        r.image = image
        let rows = try decode(try call(r, g), [ImageRow].self, g)
        if g.json { Out.json(rows) } else { Out.stdout("removed \(image)\n") }
    }
}

struct ImagePull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pull", abstract: "Pull an image from a registry (not yet — 584.B2).")
    @OptionGroup var g: GlobalOptions
    @Argument var image: String
    func run() async throws { throw fail(HostError(.notImplemented, "image pull arrives with 584.B2 — for now images bake locally (snooze image bake)"), g) }
}

struct ImagePush: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "push", abstract: "Push an image to a registry (not yet — 584.B2).")
    @OptionGroup var g: GlobalOptions
    @Argument var image: String
    func run() async throws { throw fail(HostError(.notImplemented, "image push arrives with 584.B2"), g) }
}

// MARK: point

struct PointCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "point", abstract: "Restore points: instant disk-only copies (APFS clones) to go back to or fork from.",
                                                    subcommands: [PointTake.self, PointList.self, PointRevert.self, PointFork.self, PointRemove.self, PointSaveImage.self])
}

func printPoint(_ p: RestorePoint) -> String {
    "\(p.name) (\(p.id)) — taken while \(p.takenWhile.rawValue)\(p.note.isEmpty ? "" : ": \(p.note)")"
}

struct PointTake: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "take", abstract: "Take a restore point (a running sandbox pauses for the clone: milliseconds).")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument(help: "The point's name (default point-N).") var point: String?
    @Option(name: .long) var note: String?
    func run() async throws {
        var r = HostRequest(.pointTake, name: name)
        r.pointName = point
        r.note = note
        let p = try decode(try call(r, g), RestorePoint.self, g)
        if g.json { Out.json(p) } else { Out.stdout("took \(printPoint(p))\n") }
    }
}

struct PointList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "The sandbox's restore points, oldest first.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    func run() async throws {
        let ps = try decode(try await query(HostRequest(.pointList, name: name), g), [RestorePoint].self, g)
        if g.json { Out.json(ps); return }
        if ps.isEmpty { Out.stdout("no restore points — snooze point take \(name)\n"); return }
        var t = [["POINT", "ID", "TAKEN", "WHILE", "NOTE"]]
        for p in ps {
            t.append([p.name, p.id, p.createdAt.formatted(date: .abbreviated, time: .standard), p.takenWhile.rawValue + (p.automatic ? " (auto)" : ""), p.note])
        }
        Out.stdout(Out.table(t))
    }
}

struct PointRevert: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "revert", abstract: "Shut down and go back to a restore point (a \"before revert\" point is taken first). Start boots it.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument(help: "The point's name or id.") var point: String
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false
    func run() async throws {
        try confirm("Revert \(name) to \(point)? It shuts down (running programs end); the current disk is kept as a restore point.", yes: yes, g)
        var r = HostRequest(.pointRevert, name: name)
        r.point = point
        let p = try decode(try call(r, g), RestorePoint.self, g)
        if g.json { Out.json(p) } else { Out.stdout("\(name) reverted to \(printPoint(p)) — snooze start \(name) boots it\n") }
    }
}

struct PointFork: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fork", abstract: "A new sandbox whose disks are a restore point's (it cold-boots on start).")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument(help: "The point's name or id.") var point: String
    @Argument(help: "The new sandbox's name.") var newName: String
    func run() async throws {
        var r = HostRequest(.pointFork, name: name)
        r.point = point
        r.newName = newName
        let i = try decode(try call(r, g), SandboxInfo.self, g)
        if g.json { Out.json(i) } else { Out.stdout("forked \(name)@\(point) as \(i.name) — snooze start \(i.name)\n") }
    }
}

struct PointRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete a restore point (any, in any order).")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument var point: String
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false
    func run() async throws {
        try confirm("Delete restore point \(point) of \(name)?", yes: yes, g)
        var r = HostRequest(.pointRm, name: name)
        r.point = point
        let p = try decode(try call(r, g), RestorePoint.self, g)
        if g.json { Out.json(p) } else { Out.stdout("deleted \(printPoint(p))\n") }
    }
}

struct PointSaveImage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "save-image", abstract: "Save a restore point (or the stopped sandbox's disk) as a custom image other sandboxes can start from.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument(help: "The point (default: the current disk; the sandbox must be off).") var point: String?
    @Option(name: .customLong("as"), help: "The image's name: a-z 0-9 -.") var image: String
    @Option(name: .long) var note: String?
    func run() async throws {
        var r = HostRequest(.pointSaveImage, name: name)
        r.point = point
        r.image = image
        r.note = note
        let v = try call(r, g)
        if g.json { Out.json(v) } else { Out.stdout("saved image \(image) (\(v["key"]?.stringValue ?? "")) — snooze create NEW --image \(image)\n") }
    }
}

// MARK: net

struct NetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "net", abstract: "A proxied sandbox's network: its policy and its connection log.",
                                                    subcommands: [NetPolicyCommand.self, NetLog.self])
}

struct NetPolicyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "policy",
        abstract: "Show the policy, or change it live (the next connection is judged by it; it is kept for the next start).")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Option(name: .long, help: "Replace the policy with a preset: locked, bake, agent, open.") var preset: String?
    @Option(name: .long, help: "Allow a host (exact, *.domain, or an IPv4 CIDR); repeatable.") var allow: [String] = []
    @Option(name: .long, help: "Deny a host; repeatable.") var deny: [String] = []
    @Option(name: .long, help: "Remove every rule for a host; repeatable.") var remove: [String] = []

    func run() async throws {
        var r = HostRequest(.netPolicy, name: name)
        r.preset = preset
        r.allow = allow
        r.deny = deny
        r.removeHosts = remove
        let changing = preset != nil || !allow.isEmpty || !deny.isEmpty || !remove.isEmpty
        let v = changing ? try call(r, g) : try await query(r, g)
        let p = try decode(v, NetworkPolicy.self, g)
        if g.json { Out.json(p); return }
        Out.stdout("\(name): \(p.preset.map { "\($0) preset" } ?? "custom policy"), default \(p.defaultAction.rawValue)\n")
        var t = [["#", "RULE", "NOTE"]]
        for (i, rule) in p.rules.enumerated() { t.append(["\(i + 1)", rule.label, rule.note]) }
        if p.rules.isEmpty { Out.stdout("(no rules)\n") } else { Out.stdout(Out.table(t)) }
    }
}

struct NetLog: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "log", abstract: "The connection log (metadata only: host, verdict, rule, bytes — never contents).")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Flag(name: .long, help: "Only denied connections.") var denied = false
    @Flag(name: [.short, .long], help: "Keep printing new connections.") var follow = false

    static func line(_ c: ConnectionRecord) -> String {
        let time = c.time.formatted(date: .omitted, time: .standard)
        var s = "\(time)  \(c.verdict.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(c.kind.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(c.target)"
        if let m = c.method { s += "  \(m) \(c.path ?? "")" }
        s += "  [\(c.rule)]"
        if c.bytesUp + c.bytesDown > 0 { s += "  ↑\(c.bytesUp) ↓\(c.bytesDown)" }
        if let cr = c.credential { s += "  \(cr)" }
        return s
    }

    func run() async throws {
        var r = HostRequest(.netLog, name: name)
        r.deniedOnly = denied
        if !follow {
            let recs = try decode(try await query(r, g), [ConnectionRecord].self, g)
            if g.json { Out.json(recs) } else {
                if recs.isEmpty { Out.stdout("no connections logged (the log lives in the host, from its start)\n") }
                for c in recs { Out.stdout(Self.line(c) + "\n") }
            }
            return
        }
        r.follow = true
        let client: HostClient
        do { client = try HostClient.connect(store: g.snoozeStore, autostart: true) } catch let e as HostError { throw fail(e, g) }
        try client.send(r)
        while let m = try client.next() {
            if let e = m.error { throw fail(e, g) }
            guard let c = m.event?.connection else { continue }
            if g.json { Out.jsonLine(c) } else { Out.stdout(Self.line(c) + "\n") }
        }
    }
}

// MARK: key

struct KeyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "key",
        abstract: "Credentials held by the host's proxy — the sandbox only ever sees a placeholder.",
        subcommands: [KeySet.self, KeyRemove.self, KeyList.self])
}

struct KeySet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set",
        abstract: "Give a proxied sandbox a key: read from stdin (or a prompt) or the keychain — never an argument.",
        discussion: "security add-generic-password -s snooze-anthropic -a $USER -w  then  snooze key set NAME --anthropic --keychain snooze-anthropic. A key from stdin lasts while the host runs; one from the keychain is read again when a new host loads the sandbox.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Flag(name: .long, help: "Anthropic's API key (api.anthropic.com, x-api-key; ANTHROPIC_API_KEY in the guest is a placeholder).") var anthropic = false
    @Option(name: .long, help: "Read it from this keychain item (a generic password's service name).") var keychain: String?

    func validate() throws {
        if !anthropic { throw ValidationError("which key? --anthropic") }
    }

    func run() async throws {
        let secret: String
        let source: String
        if let service = keychain {
            guard let s = Keychain.read(service: service) else {
                throw fail(HostError(.notFound, "no readable keychain item with service \(service)"), g)
            }
            secret = s
            source = "keychain:\(service)"
        } else if isatty(STDIN_FILENO) != 0 {
            var buf = [CChar](repeating: 0, count: 4096)
            guard let p = readpassphrase("Anthropic API key (not echoed): ", &buf, buf.count, 0) else {
                throw fail(HostError(.failed, "no key read"), g)
            }
            secret = String(cString: p)
            memset(&buf, 0, buf.count)
            source = "prompt"
        } else {
            secret = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            source = "stdin"
        }
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw fail(HostError(.invalid, "an empty key (pipe it in: snooze key set \(name) --anthropic < file)"), g) }
        var r = HostRequest(.keySet, name: name)
        r.binding = CredentialBinding.anthropic.id
        r.secret = trimmed
        r.source = source
        let rows = try decode(try call(r, g), [CredentialRow].self, g)
        if g.json { Out.json(rows) } else { Out.stdout("anthropic key set for \(name) (from \(source); held by the host, never in the sandbox)\n") }
    }
}

struct KeyRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Forget a key.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Flag(name: .long) var anthropic = false
    func validate() throws { if !anthropic { throw ValidationError("which key? --anthropic") } }
    func run() async throws {
        var r = HostRequest(.keyRm, name: name)
        r.binding = CredentialBinding.anthropic.id
        let rows = try decode(try call(r, g), [CredentialRow].self, g)
        if g.json { Out.json(rows) } else { Out.stdout("anthropic key removed from \(name)\n") }
    }
}

struct KeyList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "Which keys a sandbox has (never their values).")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    func run() async throws {
        let rows = try decode(try await query(HostRequest(.keyList, name: name), g), [CredentialRow].self, g)
        if g.json { Out.json(rows); return }
        var t = [["KEY", "HOSTS", "SET", "SOURCE"]]
        for c in rows { t.append([c.binding, c.hosts.joined(separator: ","), c.set ? "yes" : "no", c.source ?? "—"]) }
        Out.stdout(Out.table(t))
    }
}

// MARK: metrics

struct MetricsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "metrics",
        abstract: "Lifecycle timings recorded by the host: per action count, median, p90, min, max, failures.")
    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "Every row, as CSV.") var csv = false
    @Option(name: .long, help: "Only this image (lab, claude-code, pi, custom:NAME).") var image: String?
    @Option(name: .long, help: "Only the last N days.") var days: Double?
    @Flag(name: .long, help: "Leave out the library steps inside each action.") var noSteps = false

    func run() async throws {
        let url = g.snoozeStore.metrics
        guard FileManager.default.fileExists(atPath: url.path) else {
            if g.json { Out.json([MetricsSummaryRow]()); return }
            Out.stdout("no metrics yet at \(url.path)\n")
            return
        }
        let store: MetricsStore
        do { store = try MetricsStore(url: url) } catch { throw fail(HostError(.failed, error.localizedDescription), g) }
        let f = MetricsFilter(image: image, since: days.map { Date().addingTimeInterval(-$0 * 86_400) }, includeSteps: !noSteps)
        if csv { Out.stdout(store.csv(f)); return }
        let rows = store.summary(f)
        if g.json { Out.json(rows); return }
        let c = store.counts()
        Out.stdout("snooze metrics — \(url.path)\n\(c.runs) host runs · \(c.events) rows · \(c.sessions) sessions · \(c.networkMinutes) network minutes"
                   + " · image: \(image ?? "all") · since: \(days.map { "\($0.formatted()) days" } ?? "all time")\n\n")
        var t = [["ACTION", "COUNT", "MEDIAN", "P90", "MIN", "MAX", "FAILED"]]
        for r in rows {
            t.append([r.action, "\(r.count)", MetricsMath.format(r.medianMs), MetricsMath.format(r.p90Ms), MetricsMath.format(r.minMs),
                      MetricsMath.format(r.maxMs), r.failed == 0 ? "" : "\(r.failed)"])
        }
        Out.stdout(rows.isEmpty ? "(nothing recorded)\n" : Out.table(t, rightAligned: [1, 2, 3, 4, 5, 6]))
    }
}

// MARK: host

struct HostCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "host",
        abstract: "The per-user host that owns every running sandbox (started for you; exits when idle).",
        subcommands: [HostRun.self, HostStop.self, HostStatusCommand.self],
        defaultSubcommand: HostRun.self)
}

/// The idle timeout: --idle-timeout, else $SNOOZE_HOST_IDLE, else 5 minutes.
func idleTimeout(_ option: Double?) -> Double {
    option ?? ProcessInfo.processInfo.environment["SNOOZE_HOST_IDLE"].flatMap(Double.init) ?? 5
}

struct HostRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start the host (detached, unless --foreground).")
    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "Run in this process (logs on stdout) instead of detached.") var foreground = false
    @Option(name: .long, help: "Minutes with nothing running before the host exits; 0 = never (default 5, or $SNOOZE_HOST_IDLE).") var idleTimeout: Double?

    func run() async throws {
        let store = g.snoozeStore
        let timeout = SnoozeCLI.idleTimeout(idleTimeout)
        if foreground {
            do { try await HostServer.run(store: store, idleTimeoutMinutes: timeout, version: SnoozeCommand.version) } catch {
                throw fail(HostError(.unavailable, error.localizedDescription), g)
            }
        }
        if !store.hostIsRunning() {
            do { try HostLauncher.spawn(store: store, extra: idleTimeout.map { ["--idle-timeout", String($0)] } ?? []) } catch let e as HostError {
                throw fail(e, g)
            }
            guard HostClient.waitForHost(store: store) else {
                throw fail(HostError(.unavailable, "the host did not start — see \(store.logFile.path)"), g)
            }
        }
        let st = try decode(try call(HostRequest(.ping), g, autostart: false), HostStatus.self, g)
        if g.json { Out.json(st) } else { Out.stdout(describe(st)) }
    }
}

func describe(_ st: HostStatus) -> String {
    var s = "host \(st.version) running, pid \(st.pid), since \(st.startedAt.formatted(date: .omitted, time: .standard))\n"
    s += "store \(st.store)\n"
    s += "running sandboxes: \(st.liveSandboxes.isEmpty ? "none" : st.liveSandboxes.joined(separator: ", "))"
    s += st.idleTimeoutMinutes > 0 ? String(format: " · exits after %@ min with nothing running", st.idleTimeoutMinutes.formatted()) : " · never exits by itself"
    if let i = st.idleSeconds { s += String(format: " (idle %.0f s)", i) }
    return s + "\n"
}

struct HostStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop",
        abstract: "Deep-sleep every running sandbox and stop the host (the next command starts a new one; wake brings each back).")
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        let store = g.snoozeStore
        guard store.hostIsRunning() else {
            if g.json { Out.json(["stopped": false]) } else { Out.stdout("no host is running\n") }
            return
        }
        _ = try call(HostRequest(.hostStop), g, autostart: false)
        // It answers before it exits: wait for the lock to go.
        let deadline = Date().addingTimeInterval(30)
        while store.hostIsRunning() && Date() < deadline { usleep(50_000) }
        if g.json { Out.json(["stopped": true]) } else { Out.stdout("host stopped — every sandbox that was running is deep asleep\n") }
    }
}

struct HostStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Is a host running, and what does it hold? (Never starts one.)")
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        guard g.snoozeStore.hostIsRunning() else {
            if g.json { Out.json(["running": false]) } else { Out.stdout("no host is running (nothing is running)\n") }
            return
        }
        let st = try decode(try call(HostRequest(.ping), g, autostart: false), HostStatus.self, g)
        if g.json { Out.json(st) } else { Out.stdout(describe(st)) }
    }
}

struct Events: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Follow what the host does: phases, timed steps, notes (Ctrl-C stops).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "Only this sandbox.") var name: String?
    func run() async throws {
        let client: HostClient
        do { client = try HostClient.connect(store: g.snoozeStore, autostart: true) } catch let e as HostError { throw fail(e, g) }
        var r = HostRequest(.events)
        r.name = name
        try client.send(r)
        while let m = try client.next() {
            if let e = m.error { throw fail(e, g) }
            guard let e = m.event else { continue }
            if g.json { Out.jsonLine(e) } else { Out.stdout("\(e.time.formatted(date: .omitted, time: .standard))  \(e.line)\n") }
        }
    }
}
