import ArgumentParser
import Darwin
import Foundation
import DozerKit
import DozerHost

// MARK: image

struct ImageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "image", abstract: "Images: the built-in lab, claude-code and pi, and custom images saved from restore points.",
                                                    subcommands: [ImageList.self, ImageBake.self, ImageRemove.self, ImagePull.self, ImagePush.self],
                                                    defaultSubcommand: ImageList.self)
}

struct ImageList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List the images and whether each is baked in this store (--tree: the lineage, with sizes).")
    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "The lineage: OCI base → image → template → the sandboxes on each, with each disk's size, the bytes it shares with its parent, and its own.")
    var tree = false
    func run() async throws {
        if tree {
            let t = try decode(try await query(HostRequest(.imageTree), g), ImageTree.self, g)
            if g.json { Out.json(t) } else { Out.stdout(renderImageTree(t)) }
            return
        }
        let rows = try decode(try await query(HostRequest(.imageList), g), [ImageRow].self, g)
        if g.json { Out.json(rows); return }
        // 594 W28: a STATUS column; a stale image is named precisely, below the table — and never rebuilt
        // without being asked (doz image bake NAME). 596 (B10): base × agent — "Python · Claude Code".
        var t = [["IMAGE", "BASE · AGENT", "STATUS", "BAKED", "SIZE", "NOTE"]]
        for r in rows {
            let baked = r.baked ? (r.bakedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "yes") : "no (prepared on first start, or doz onboard)"
            // 594: an agent image says its version, and a newer one available.
            t.append([r.name, r.kind == "custom" ? "template" : (r.title ?? r.kind),
                      // W32: in words — an older host's answer has no status; this doz works it out.
                      r.status ?? r.computedStatus ?? "up to date", baked,
                      r.allocatedBytes.map(DozerImages.formatBytes) ?? "—",
                      [r.versionLine ?? r.note, r.fromSandbox.map { "from \($0)" }, r.dockerfile.map { "Dockerfile \(tildePath($0))" }, r.baseUpdate]
                        .compactMap { $0 }.joined(separator: " · ")])
        }
        Out.stdout(Out.table(t))
        for r in rows { if let s = r.standing { Out.stdout("\(r.name): \(s)\n") } }
    }
}

/// 593: the lineage as an indented table (box-drawing branches).
func renderImageTree(_ tree: ImageTree) -> String {
    if tree.nodes.isEmpty { return "no disks in this store yet — doz image bake lab, or create and start a sandbox\n" }
    let children = Dictionary(grouping: tree.nodes.filter { $0.parent != nil }, by: { $0.parent! })
    var lastChild: Set<Int> = []
    for (_, kids) in children { if let l = kids.last { lastChild.insert(l.id) } }
    var t = [["IMAGE / SANDBOX", "KIND", "SIZE", "SHARED", "OWN", ""]]
    let byID = Dictionary(uniqueKeysWithValues: tree.nodes.map { ($0.id, $0) })
    for n in tree.nodes {
        var prefix = ""
        var up = n.parent.flatMap { byID[$0] }
        while let a = up, a.parent != nil {
            prefix = (lastChild.contains(a.id) ? "   " : "│  ") + prefix
            up = a.parent.flatMap { byID[$0] }
        }
        if n.parent != nil { prefix += lastChild.contains(n.id) ? "└─ " : "├─ " }
        let kind = n.kind == "restorePoint" ? "point" : n.kind
        let extra = [n.detail, n.stateAllocatedBytes.map { "+ state \(DozerImages.formatBytes($0))" }].compactMap { $0 }.joined(separator: " · ")
        t.append([prefix + n.name, kind, DozerImages.formatBytes(n.allocatedBytes),
                  n.sharedWithParentBytes.map(DozerImages.formatBytes) ?? "—", DozerImages.formatBytes(n.uniqueBytes), extra])
    }
    return Out.table(t) + "\nall disks together: \(DozerImages.formatBytes(tree.unionBytes)) (shared blocks counted once) · measured in \(Int(tree.milliseconds)) ms\n"
}

struct ImageBake: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "bake", abstract: "Bake (or rebuild) a built-in image now (otherwise the first start does it; minutes, needs network). Existing sandboxes keep their disks; new sandboxes and doz reset use the new image.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "lab, claude-code or pi.") var image: String
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false
    func run() async throws {
        // 594 W28: rebuilding is one explained step — what it does to existing and new sandboxes.
        let rows = (try? decode(try await query(HostRequest(.imageList), g), [ImageRow].self, g)) ?? []
        if let row = rows.first(where: { $0.name == image }), row.baked {
            let what = "Rebuild the \(image) image (~2 min, needs network)? Existing sandboxes keep their disks — nothing in them changes; "
                + "new sandboxes, and `doz reset NAME`, use the new image (a reset keeps the agent's own state and /workspace, and drops other system changes)."
            let asker = Asker(yes: yes, json: g.json)
            if asker.interactive {
                guard asker.yesNo(what, default: true) else { throw fail(HostError(.failed, "not rebuilt — nothing done"), g, code: DozerExit.declined) }
            } else if !g.json && !g.quiet {
                Out.stderr("[doz] rebuilding the \(image) image: existing sandboxes keep their disks; new sandboxes and `doz reset NAME` use the new one\n")
            }
        }
        var r = HostRequest(.imageBake)
        r.image = image
        let row = try decode(try call(r, g), ImageRow.self, g)
        if g.json { Out.json(row) } else { Out.stdout("\(row.name) baked\(row.allocatedBytes.map { " (\(DozerImages.formatBytes($0)))" } ?? "")\n") }
    }
}

struct ImageRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove an image's baked disk (sandboxes cloned from it keep working).")
    @OptionGroup var g: GlobalOptions
    @Argument var image: String
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false
    func run() async throws {
        // 594 W26: an image that is not there fails before the question.
        let known = try decode(try await query(HostRequest(.imageList), g), [ImageRow].self, g)
        guard known.contains(where: { $0.name == image }) else { throw fail(HostError(.notFound, "no image \(image) (doz image ls)"), g) }
        try confirm("Remove the image \(image)? (It is baked again when next needed.)", yes: yes, g)
        var r = HostRequest(.imageRm)
        r.image = image
        let rows = try decode(try call(r, g), [ImageRow].self, g)
        if g.json { Out.json(rows) } else { Out.stdout("removed \(image)\n") }
    }
}

struct ImagePull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pull", abstract: "Pull an image from a registry (not yet).")
    @OptionGroup var g: GlobalOptions
    @Argument var image: String
    func run() async throws { throw fail(HostError(.notImplemented, "image pull is not built yet — for now images are prepared locally (doz image bake)"), g) }
}

struct ImagePush: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "push", abstract: "Push an image to a registry (not yet).")
    @OptionGroup var g: GlobalOptions
    @Argument var image: String
    func run() async throws { throw fail(HostError(.notImplemented, "image push is not built yet"), g) }
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
        if ps.isEmpty { Out.stdout("no restore points — doz point take \(name)\n"); return }
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
        // 594 W26: the sandbox and the point are found BEFORE the question — never "[y/N]" for what fails.
        let p = try await resolvePointFirst(name, point, g)
        try confirm("Revert \(name) to \(describePoint(p))? It shuts down (running programs end); the current disk is kept as a restore point.", yes: yes, g)
        var r = HostRequest(.pointRevert, name: name)
        r.point = p.id
        let done = try decode(try call(r, g), RestorePoint.self, g)
        if g.json { Out.json(done) } else { Out.stdout("\(name) reverted to \(printPoint(done)) — doz start \(name) boots it\n") }
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
        if g.json { Out.json(i) } else { Out.stdout("forked \(name)@\(point) as \(i.name) — doz start \(i.name)\n") }
    }
}

struct PointRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete a restore point (any, in any order).")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument var point: String
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false
    func run() async throws {
        let p = try await resolvePointFirst(name, point, g)
        try confirm("Delete restore point \(describePoint(p)) of \(name)?", yes: yes, g)
        var r = HostRequest(.pointRm, name: name)
        r.point = p.id
        let done = try decode(try call(r, g), RestorePoint.self, g)
        if g.json { Out.json(done) } else { Out.stdout("deleted \(printPoint(done))\n") }
    }
}

/// 594 W25/W26: the point a person typed (its id, its name, or an unambiguous prefix of either —
/// the host's rule), found before anything is asked or done. Looking never starts a host.
func resolvePointFirst(_ sandbox: String, _ ref: String, _ g: GlobalOptions) async throws -> RestorePoint {
    let points = try decode(try await query(HostRequest(.pointList, name: sandbox), g), [RestorePoint].self, g)
    do { return try HostCore.resolvePoint(ref, in: points, sandbox: sandbox) } catch let e as HostError { throw fail(e, g) }
}

/// "before-experiment (rp-20260930-…, taken 30 Sep 2026 at 10:01 pm)".
func describePoint(_ p: RestorePoint) -> String {
    "\(p.name) (\(p.id), taken \(p.createdAt.formatted(date: .abbreviated, time: .shortened)))"
}

/// 594 W26: the sandbox exists — checked before a question is asked about it.
func requireSandbox(_ name: String, _ g: GlobalOptions) async throws {
    var r = HostRequest(.ls)
    r.withSessions = false
    let rows = try decode(try await query(r, g), [SandboxInfo].self, g)
    guard rows.contains(where: { $0.name == name }) else { throw fail(HostError(.notFound, "no sandbox \(name) (doz ls)"), g) }
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
        if g.json { Out.json(v) } else { Out.stdout("saved image \(image) (\(v["key"]?.stringValue ?? "")) — doz create NEW --image \(image)\n") }
    }
}

// MARK: net

struct NetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "net", abstract: "What a sandbox's agent may do (its permissions), its raw policy and its connection log.",
                                                    subcommands: [NetShow.self, NetAllow.self, NetDeny.self, NetPermissionsList.self, NetPolicyCommand.self, NetLog.self],
                                                    defaultSubcommand: NetShow.self)
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
        Out.stdout("\(name): \(p.preset.map { "\($0) preset" } ?? "custom policy"), default \(p.effectiveDefault.rawValue)\n")
        // 597: a policy of permissions — its names, then every rule evaluated (the user's own first).
        if let names = p.permissions { Out.stdout("permissions: \(names.joined(separator: ", ")) (doz net \(name) shows them in words)\n") }
        var t = [["#", "RULE", "NOTE"]]
        for (i, rule) in p.effectiveRules.enumerated() { t.append(["\(i + 1)", rule.label, rule.note]) }
        if p.effectiveRules.isEmpty { Out.stdout("(no rules)\n") } else { Out.stdout(Out.table(t)) }
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
        do { client = try HostClient.connect(store: g.dozerStore, autostart: true) } catch let e as HostError { throw fail(e, g) }
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
        subcommands: [KeySet.self, KeyRemove.self, KeyList.self, KeyPolicy.self])
}

struct KeySet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set",
        abstract: "Give a proxied sandbox a key: read from stdin (or a prompt) or the keychain — never an argument.",
        discussion: "security add-generic-password -s doz-anthropic -a $USER -w  then  doz key set NAME --anthropic --keychain doz-anthropic. A key from stdin lasts while the host runs; one from the keychain is read again when a new host loads the sandbox.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Flag(name: .long, help: "Anthropic's API key (api.anthropic.com, x-api-key; ANTHROPIC_API_KEY in the guest is a placeholder).") var anthropic = false
    @Option(name: .long, help: "Read it from this keychain item (a generic password's service name).") var keychain: String?
    @Flag(name: .long, help: "Use this Mac's own Claude Code login (a Claude subscription) instead of an API key: the host reads its access token from the keychain and keeps it current; the guest's CLAUDE_CODE_OAUTH_TOKEN is a placeholder.") var claudeLogin = false
    @Flag(name: .long, help: "A GitHub token for \"Use GitHub as you\" (instead of this Mac's gh login) — a fine-grained token limited to some repositories is best. The guest's GH_TOKEN and git's login are placeholders; used only while the permission is on.") var github = false

    func validate() throws {
        if [anthropic, claudeLogin, github].filter({ $0 }).count != 1 { throw ValidationError("which key? --anthropic, --claude-login or --github") }
        if claudeLogin && keychain != nil { throw ValidationError("--claude-login reads Claude Code's own keychain item; --keychain is for --anthropic or --github") }
    }

    func run() async throws {
        if github {
            let secret: String, source: String
            if let service = keychain {
                guard let s = Keychain.read(service: service) else { throw fail(HostError(.notFound, "no readable keychain item with service \(service)"), g) }
                secret = s; source = "keychain:\(service)"
            } else if isatty(STDIN_FILENO) != 0 {
                var buf = [CChar](repeating: 0, count: 4096)
                guard let p = readpassphrase("GitHub token (not echoed): ", &buf, buf.count, 0) else { throw fail(HostError(.failed, "no token read"), g) }
                secret = String(cString: p)
                memset(&buf, 0, buf.count)
                source = "prompt"
            } else {
                secret = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                source = "stdin"
            }
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw fail(HostError(.invalid, "an empty token (pipe it in: doz key set \(name) --github < file)"), g) }
            var r = HostRequest.keySet(name: name, secret: trimmed, source: source)
            r.binding = CredentialBinding.github.id
            let rows = try decode(try call(r, g), [CredentialRow].self, g)
            if g.json { Out.json(rows) } else {
                Out.stdout("github token set for \(name) (from \(source); held by the host, never in the sandbox) — used while \"Use GitHub as you\" is on (doz net allow \(name) github:as-you)\n")
            }
            return
        }
        if claudeLogin {
            var r = HostRequest(.keySet, name: name)
            r.binding = CredentialBinding.claudeOAuth.id
            r.source = ClaudeLogin.source
            let rows = try decode(try call(r, g), [CredentialRow].self, g)
            if g.json { Out.json(rows) } else {
                let exp = rows.first { $0.account != nil }?.expiresAt.map { " (access expires \($0.formatted(date: .omitted, time: .shortened)))" } ?? ""
                Out.stdout("\(name) uses this Mac's Claude login — the account mac: held by the host, renewed while Claude Code runs on this Mac\(exp); never in the sandbox\n")
            }
            return
        }
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
        guard !trimmed.isEmpty else { throw fail(HostError(.invalid, "an empty key (pipe it in: doz key set \(name) --anthropic < file)"), g) }
        let rows = try decode(try call(HostRequest.keySet(name: name, secret: trimmed, source: source), g), [CredentialRow].self, g)
        if g.json { Out.json(rows) } else { Out.stdout("anthropic key set for \(name) (from \(source); held by the host, never in the sandbox)\n") }
    }
}

struct KeyRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Forget a key.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Flag(name: .long) var anthropic = false
    @Flag(name: .long) var claudeLogin = false
    @Flag(name: .long) var github = false
    func validate() throws { if [anthropic, claudeLogin, github].filter({ $0 }).count != 1 { throw ValidationError("which key? --anthropic, --claude-login or --github") } }
    func run() async throws {
        var r = HostRequest(.keyRm, name: name)
        r.binding = github ? CredentialBinding.github.id : claudeLogin ? CredentialBinding.claudeOAuth.id : CredentialBinding.anthropic.id
        let rows = try decode(try call(r, g), [CredentialRow].self, g)
        if g.json { Out.json(rows) } else { Out.stdout("\(r.binding!) removed from \(name)\n") }
    }
}

struct KeyList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "Which keys a sandbox has (never their values).")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    func run() async throws {
        let rows = try decode(try await query(HostRequest(.keyList, name: name), g), [CredentialRow].self, g)
        if g.json { Out.json(rows); return }
        Out.stdout(KeyList.render(rows))
    }

    static func render(_ rows: [CredentialRow]) -> String {
        var t = [["KEY", "HOSTS", "SET", "SOURCE", "STATE", "EXPIRES", "POLICY"]]
        for c in rows {
            t.append([c.binding, c.hosts.joined(separator: ","), c.set ? "yes" : "no", c.source ?? "—", c.state ?? "—",
                      c.expiresAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—", c.policy ?? "—"])
        }
        var out = Out.table(t)
        let foreign = rows.flatMap { $0.foreign ?? [] }
        if !foreign.isEmpty {
            out += "\nthe guest used its own credential(s) — fingerprints, never values:\n"
            var f = [["KIND", "PREFIX", "FINGERPRINT", "HEADER", "REQUESTS", "FIRST SEEN", "LAST SEEN"]]
            for x in foreign {
                f.append([x.kind + (x.matches.map { " (= \($0))" } ?? ""), x.prefix + "…", x.fingerprint, x.header, "\(x.requests)",
                          x.firstSeen.formatted(date: .omitted, time: .standard), x.lastSeen.formatted(date: .omitted, time: .standard)])
            }
            out += Out.table(f)
        }
        return out
    }
}

struct KeyPolicy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "policy",
        abstract: "What the proxy does with a credential the guest supplies itself: allow (and flag), strict (refuse), or auto.",
        discussion: "auto (the default): strict when the sandbox uses an account that is not the Mac login, allow otherwise. Strict also denies the Claude sign-in hosts, so a /login inside the sandbox cannot finish.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument(help: "allow, strict or auto.") var policy: String

    func validate() throws { guard ["allow", "strict", "auto"].contains(policy) else { throw ValidationError("allow, strict or auto") } }

    func run() async throws {
        var r = HostRequest(.keyPolicy, name: name)
        r.policy = policy
        let rows = try decode(try call(r, g), [CredentialRow].self, g)
        if g.json { Out.json(rows) } else { Out.stdout("\(name): key policy \(rows.first?.policy ?? policy)\(policy == "auto" ? " (auto)" : "")\n") }
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
        let url = g.dozerStore.metrics
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
        Out.stdout("doz metrics — \(url.path)\n\(c.runs) host runs · \(c.events) rows · \(c.sessions) sessions · \(c.networkMinutes) network minutes"
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
        subcommands: [HostRun.self, HostStop.self, HostRestart.self, HostStatusCommand.self, HostUpgradeCheck.self],
        defaultSubcommand: HostRun.self)
}

/// The idle timeout: --idle-timeout, else $DOZ_HOST_IDLE, else the settings' `host.idle_timeout_minutes`, else 5.
func idleTimeout(_ option: Double?) -> Double {
    DozerSettings.load().idleTimeoutMinutes(flag: option)
}

struct HostRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start the host (detached, unless --foreground).")
    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "Run in this process (logs on stdout) instead of detached.") var foreground = false
    @Option(name: .long, help: "Minutes with nothing running before the host exits; 0 = never (default $DOZ_HOST_IDLE, else the settings' host.idle_timeout_minutes, else 5).") var idleTimeout: Double?
    /// 593: the launcher's intermediate — spawn the host in its own session, print its pid, exit (so the
    /// host's parent is launchd, never a client). Not for people.
    @Flag(name: .long, help: .hidden) var launchDetached = false
    /// 593: this host was started by the launcher (its status says so; `doctor` expects parent launchd).
    @Flag(name: .long, help: .hidden) var launched = false

    func run() async throws {
        let store = g.dozerStore
        let timeout = DozerCLI.idleTimeout(idleTimeout)
        if launchDetached {
            let pid = try HostLauncher.spawnHostProcess(store: store, extra: idleTimeout.map { ["--idle-timeout", String($0)] } ?? [])
            Out.stdout("\(pid)\n")
            return
        }
        if foreground {
            do { try await HostServer.run(store: store, idleTimeoutMinutes: timeout, version: DozerCommand.version, launched: launched) } catch {
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
    s += "\n"
    if let note = st.executableNote { s += (st.executableChange == "overwritten" ? "PROBLEM: " : "note: ") + note + "\n" }
    return s
}

struct HostStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop",
        abstract: "Hibernate every running sandbox and stop the host (the next command starts a new one; wake brings each back).")
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        let store = g.dozerStore
        guard store.hostIsRunning() else {
            if g.json { Out.json(["stopped": false]) } else { Out.stdout("no host is running\n") }
            return
        }
        switch try stopHostShowingProgress(store, g) {
        case .done(let r):
            if g.json { Out.json(r) } else { Out.stdout(HostStopView.summary(r) + "\n") }
        case .older:
            if g.json { Out.json(["stopped": true]) } else { Out.stdout("host stopped — every sandbox that was running is hibernated\n") }
        case .exited(let seen):
            throw fail(HostError(.failed, HostStopView.seen(seen)), g)
        }
    }
}

enum HostStopOutcome {
    /// What the host did (594 W22).
    case done(HostStopResult)
    /// An older host answered only "stopped".
    case older
    /// The host went away before it answered: the events it sent.
    case exited([HostEvent])
}

/// 594 W22: `host stop` with its progress — each sandbox's line as it hibernates (the CLI's progress
/// view: animated on a terminal, plain lines elsewhere), then the host's answer. Waits for the host
/// to let go of its lock (it answers just before it exits). Never hangs on a host that dies mid-stop:
/// the connection ends, and what it said so far is returned.
func stopHostShowingProgress(_ store: DozerStore, _ g: GlobalOptions) throws -> HostStopOutcome {
    let progress = Progress(g, immediate: true)
    let seen = LockedEvents()
    let m: HostMessage
    do {
        m = try HostClient.request(HostRequest(.hostStop), store: store, autostart: false) { e in
            seen.append(e)
            progress.handle(e)
        }
    } catch {
        progress.finish()
        guard !store.hostIsRunning() || !seen.all.isEmpty else {
            throw fail(HostError.from(error), g)
        }
        return .exited(seen.all)
    }
    progress.finish()
    guard m.ok == true else { throw fail(m.error ?? HostError(.failed, "the host gave no reason"), g) }
    let deadline = Date().addingTimeInterval(30)
    while store.hostIsRunning() && Date() < deadline { usleep(50_000) }
    if let v = m.result, let r = try? v.decode(HostStopResult.self) { return .done(r) }
    return .older
}

final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [HostEvent] = []
    func append(_ e: HostEvent) { lock.withLock { events.append(e) } }
    var all: [HostEvent] { lock.withLock { events } }
}

struct HostStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Is a host running, and what does it hold? (Never starts one.)")
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        guard g.dozerStore.hostIsRunning() else {
            if g.json { Out.json(["running": false]) } else { Out.stdout("no host is running (nothing is running)\n") }
            return
        }
        let st = try decode(try call(HostRequest(.ping), g, autostart: false), HostStatus.self, g)
        if g.json { Out.json(st) } else { Out.stdout(describe(st)) }
    }
}

/// 598 (H6) — after an upgrade (Homebrew's `post_install` runs it): is a host of ANOTHER build running
/// for this store? It keeps working (it runs its own copy), but it is not the new build — say how to
/// switch. Never starts a host, never stops one, and always exits 0 (an install must not fail on it).
/// It asks the host itself when it can; otherwise (a sandboxed post-install may not reach the socket)
/// it reads the host's pid and that process's executable path from the kernel.
struct HostUpgradeCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upgrade-check",
        abstract: "After an upgrade: is a host of an older build still running? (Never starts or stops one; always exits 0.)")
    @OptionGroup var g: GlobalOptions

    struct Answer: Encodable {
        var running: Bool
        var hostVersion: String?
        var hostExecutable: String?
        var thisVersion: String
        var thisExecutable: String
        var sameBuild: Bool?
        var note: String?
        /// 594 W28: agent images an older doz prepared ("claude-code: prepared by an older doz — …").
        var olderImages: [String]?
    }

    func run() async throws {
        let store = g.dozerStore
        let mine = HostLauncher.executablePath
        var a = Answer(running: store.hostIsRunning(), thisVersion: DozerCommand.version, thisExecutable: mine)
        if a.running {
            if let m = try? HostClient.request(HostRequest(.ping), store: store, autostart: false), m.ok == true,
               let st = try? (m.result ?? .null).decode(HostStatus.self) {
                a.hostVersion = st.version
                a.hostExecutable = st.executable
            } else if let pid = store.hostPID() {
                a.hostExecutable = Self.executablePath(of: pid)
            }
            let exe = a.hostExecutable.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            let same = (exe == nil || exe == mine) && (a.hostVersion == nil || a.hostVersion == DozerCommand.version)
            a.sameBuild = exe == nil && a.hostVersion == nil ? nil : same
            if a.sameBuild == false {
                a.note = "a doz host from \(a.hostVersion.map { "doz \($0)" } ?? "an older build") is running for \(store.root.path) — it keeps "
                    + "working; `doz host stop` switches to doz \(DozerCommand.version) (running sandboxes hibernate, and wake on the new build)"
            }
        }
        // 594 W28: an upgrade can change what this doz's agent images contain; name the images an older
        // doz prepared — never rebuilt here (owner: "better to warn / nag the user about out-of-date images").
        if store.root.path.isEmpty == false, FileManager.default.fileExists(atPath: store.root.path) {
            let settings = DozerSettings.load()
            let older = ["claude-code", "pi", "codex"].compactMap { image in
                AgentVersions.standing(image, store: store, settings: settings).olderRecipeLine.map { "\(image): \($0)" }
            }
            if !older.isEmpty { a.olderImages = older }
        }
        if g.json { Out.json(a); return }
        // 594 W4 (owner's walkthrough): Homebrew's post-install runs this on EVERY install, first ones
        // included — speak only when an older host is running or an image is out of date; otherwise
        // there is nothing to say.
        if let note = a.note { Out.stdout("note: \(note)\n") }
        if let older = a.olderImages {
            Out.stdout("note: images prepared by an older doz — " + older.joined(separator: "; ")
                + ". Rebuild when ready: " + older.map { "doz image bake \($0.prefix { $0 != ":" })" }.joined(separator: ", ")
                + " (existing sandboxes keep their disks; new sandboxes and doz reset use the new image)\n")
        }
    }

    /// A process's executable path (the kernel's record — `proc_pidpath`), or nil.
    static func executablePath(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// 591 — `doz console NAME [--follow]`: the sandbox's boot console (kernel + vminitd). The web
/// UI's boot view reads the same stream (the UI never gets an operation the CLI lacks).
struct Console: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show a sandbox's boot console (the kernel and init); --follow keeps printing it as it boots (Ctrl-C stops).",
        discussion: """
            The last host.boot_logs_kept (5) boots of each sandbox are kept — each cold boot, wake and restore \
            after a crash: its steps (as the boot view showed them) and its kernel console. --list shows them; \
            --boot N picks one (1 = the latest); --steps puts its steps before its console.
            """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox.") var name: String
    @Flag(name: [.short, .long], help: "Keep printing new lines (across a restart) until Ctrl-C.") var follow = false
    @Flag(name: .long, help: "Show the boot's steps (Dozer's, as the boot view drew them) before its console.") var steps = false
    @Option(name: .long, help: "Which kept boot: 1 = the latest (default), 2 = the one before, …") var boot: Int?
    @Flag(name: .long, help: "List the kept boots: when, what (cold boot, wake, restore after crash), how long, how it went.") var list = false

    /// The console is written by the guest: its control characters never reach this terminal.
    static func printable(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { u in
            (u.value < 0x20 && u.value != 0x09) || (0x7F...0x9F).contains(u.value) ? "?" : u
        }))
    }

    func run() async throws {
        if list || steps || boot != nil {
            guard !follow else { throw fail(HostError(.invalid, "--follow shows the console as it is written: not with --list, --steps or --boot"), g, code: DozerExit.usage) }
            try await showBoots()
            return
        }
        guard follow else {
            var r = HostRequest(.console, name: name)
            r.follow = false
            let c = try decode(try await query(r, g), BootConsoleLines.self, g)
            if g.json { Out.json(c) } else { Out.stdout(c.lines.map { Self.printable($0) + "\n" }.joined()) }
            return
        }
        let client: HostClient
        do { client = try HostClient.connect(store: g.dozerStore, autostart: true) } catch let e as HostError { throw fail(e, g) }
        var r = HostRequest(.console, name: name)
        r.follow = true
        try client.send(r)
        while let m = try client.next() {
            if let e = m.error { throw fail(e, g) }
            guard let e = m.event, e.kind == .console else { continue }
            if g.json { Out.jsonLine(e) } else { Out.stdout(Self.printable(e.text ?? "") + "\n") }
        }
    }

    /// 593: the kept boots — `--list`, or one boot (`--boot N`, 1 = the latest) with `--steps`.
    private func showBoots() async throws {
        var r = HostRequest(.bootLog, name: name)
        if list {
            r.list = true
            let l = try decode(try await query(r, g), BootLogList.self, g)
            if g.json { Out.json(l); return }
            if l.boots.isEmpty { Out.stdout("no boot of \(name) is kept yet — one is recorded each time it starts or wakes\n"); return }
            var t = [["#", "STARTED", "KIND", "TOOK", "RESULT"]]
            for b in l.boots {
                let result = b.result == "failed" ? "✗ failed" + (b.error.map { " — " + String($0.prefix(80)) } ?? "") : b.result == "ok" ? "✓" : "… booting"
                t.append([String(b.number ?? 0), b.startedAt.formatted(date: .abbreviated, time: .standard), b.kind,
                          b.milliseconds.map { ProgressFormat.duration($0 / 1000) } ?? "—", result])
            }
            Out.stdout(Out.table(t))
            return
        }
        r.boot = boot ?? 1
        let rec = try decode(try await query(r, g), BootLogRecord.self, g)
        if g.json { Out.json(rec); return }
        let tty = isatty(STDOUT_FILENO) != 0
        let color = tty && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        let text = BootLogs.render(rec, mode: tty ? .animated : .plain, color: color, steps: steps, console: true)
        Out.stdout(text.replacingOccurrences(of: "\r\n", with: "\n"))
    }
}

struct Events: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Follow what the host does: phases, timed steps, notes (Ctrl-C stops).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "Only this sandbox.") var name: String?
    func run() async throws {
        let client: HostClient
        do { client = try HostClient.connect(store: g.dozerStore, autostart: true) } catch let e as HostError { throw fail(e, g) }
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
