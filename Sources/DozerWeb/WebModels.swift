import Foundation
import DozerKit
import DozerHost

// 590 — what the UI's API returns. These are PROJECTIONS, field by field, of the host's results —
// never the host's JSON passed through — so a field added to the host protocol later (which may be
// sensitive) reaches the browser only when someone adds it here on purpose. No type in this file
// has a field that can hold a secret: credentials appear as state, source NAMES, and fingerprints
// (`WebModelTests` asserts no encoded key is secret-shaped).

public struct WebHost: Codable, Equatable, Sendable {
    /// A host process owns the store right now.
    public var running: Bool
    public var version: String?
    public var pid: Int32?
    public var startedAt: Date?
    public var idleTimeoutMinutes: Double?
    public var idleSeconds: Double?
    public var liveSandboxes: [String]
    public var connections: Int?
    /// Sandboxes a crashed host left live — the next host recovers them.
    public var recoveryPending: [String]
    public var store: String
    /// This UI's own version (the CLI's).
    public var uiVersion: String
    /// 594 W20: set when the host and this UI are different builds — advice for the OLDER side.
    public var versionNote: WebVersionNote? = nil
}

/// 594 W20: the host and `doz ui` are different builds. The advice is for the OLDER side (the owner saw
/// "restart doz ui" when the UI was the newer one — restarting it changed nothing).
///   · `older == "host"`: stop the host (its sandboxes hibernate); the next action starts this UI's build
///     — the page offers Restart host;
///   · `older == "ui"`: restart doz ui;
///   · `older == nil`: not comparable (a build that is not semver): only that they differ.
public struct WebVersionNote: Codable, Equatable, Sendable {
    public var older: String?
    public var text: String

    public static func make(ui: String, host: String?) -> WebVersionNote? {
        guard let host, host != ui else { return nil }
        switch WebVersion.compare(host, ui) {
        case .orderedAscending?:
            return WebVersionNote(older: "host", text: "The host is still \(host) — doz host stop (sandboxes hibernate) and the next action runs \(ui).")
        case .orderedDescending?:
            return WebVersionNote(older: "ui", text: "doz ui is \(ui), the host is \(host) — restart doz ui (Ctrl-C it, then doz ui) so the page and the host are the same build.")
        case .orderedSame?:
            return nil   // the same release (build metadata differs)
        case nil:
            return WebVersionNote(older: nil, text: "doz ui is \(ui), the host is \(host) — different builds.")
        }
    }
}

/// 594 W22: what Restart host did — the stop (each sandbox) and the host that runs now. Internal: the
/// page only sees the operation's summary and lines.
struct WebHostRestart: Codable {
    var stop: HostStopResult?
    var host: HostStatus?
}

/// 594 W20: semantic-version order (semver.org §11): X.Y.Z numerically; a pre-release sorts BEFORE its
/// release (0.12.0-rc.3 < 0.12.0-rc.5 < 0.12.0); pre-release identifiers dot by dot — numbers
/// numerically, below alphanumerics, which compare as ASCII; a shorter list first when all else is
/// equal. Build metadata (`+…`) is ignored. nil when either is not a version.
public enum WebVersion {
    /// 611: the one implementation is DozerHost's `SemVer` (the updater orders versions with it too).
    public static func compare(_ a: String, _ b: String) -> ComparisonResult? { SemVer.compare(a, b) }
}

/// 594 W18: what the UI's poll can learn about the host WITHOUT starting one — read before the
/// overview, because the overview starts a host to recover a crash (the CLI's rule), and the gap
/// between the old host and that new one is what tells a crash from a clean stop.
public struct WebHostProbe: Equatable, Sendable {
    /// A host holds the store's lock.
    public var running: Bool
    /// `host.pid` names a host that is gone: a clean exit removes it, a kill -9 or a crash does not.
    public var stalePID: Bool
    /// Sandboxes whose VM ran when the host went (they are shut down by the next host; an asleep
    /// one is restored asleep, so it is not among them).
    public var lost: [String]
    /// Anything a gone host left live (`lost` plus the asleep ones): a crash when not empty.
    public var recovering: [String]
    /// Why the last host said it exited (its log): `stop`, `signal`, `idle`, `program changed`.
    public var exitReason: String?

    public init(running: Bool, stalePID: Bool = false, lost: [String] = [], recovering: [String] = [], exitReason: String? = nil) {
        self.running = running
        self.stalePID = stalePID
        self.lost = lost
        self.recovering = recovering
        self.exitReason = exitReason
    }
}

/// 594 W18: why the last host exited, from the end of `host.log` — the line its exit path wrote
/// before `host exiting` (`HostServer`). nil when the last host did not say (it was killed).
enum HostExitReason {
    static func read(_ log: URL, tail: Int = 16_384) -> String? {
        guard let h = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > UInt64(tail) ? end - UInt64(tail) : 0)
        guard let d = try? h.readToEnd() else { return nil }
        return parse(String(decoding: d, as: UTF8.self))
    }

    static func parse(_ text: String) -> String? {
        let lines = text.split(separator: "\n").map(String.init)
        guard let exit = lines.lastIndex(where: { $0.hasSuffix(" host exiting") }) else { return nil }
        // A host started after that exit (and did not say it exited): it was killed.
        if lines[(exit + 1)...].contains(where: { $0.contains(" doz host ") && $0.contains("(pid ") }) { return nil }
        let start = lines[..<exit].lastIndex(where: { $0.contains(" doz host ") && $0.contains("(pid ") }) ?? 0
        for l in lines[start..<exit].reversed() {
            if l.contains("host stop requested") { return "doz host stop" }
            if l.contains(" signal ") && l.contains("hibernating every sandbox") {
                return l.contains("signal 15:") ? "SIGTERM" : l.contains("signal 2:") ? "SIGINT" : "a signal"
            }
            if l.contains("my program changed") { return "its program changed" }
            if l.contains(" idle for ") { return "idle" }
        }
        return nil
    }
}

/// 594 W18: a change of the host, told to every page as the SSE `host` event.
///   · `running` — a host (re)started: `version`, and `previousVersion` when the build differs from
///     the host before it;
///   · `stopped` — it exited cleanly (`doz host stop`, SIGTERM, idle): `sandboxes` were hibernated;
///   · `died` — it was killed or crashed: `sandboxes` were running and are shut down.
public struct WebHostChange: Codable, Equatable, Sendable {
    public var state: String
    public var version: String?
    public var previousVersion: String?
    public var pid: Int32?
    public var sandboxes: [String]
    public var reason: String?
    public var time: Date

    public init(state: String, version: String?, previousVersion: String? = nil, pid: Int32?, sandboxes: [String] = [],
                reason: String? = nil, time: Date = Date()) {
        self.state = state
        self.version = version
        self.previousVersion = previousVersion
        self.pid = pid
        self.sandboxes = sandboxes
        self.reason = reason
        self.time = time
    }

    /// The Activity line.
    public var text: String {
        let n = sandboxes.count
        let list = n == 0 ? "" : ": " + sandboxes.joined(separator: ", ")
        switch state {
        case "running":
            let was = previousVersion.map { " — was doz \($0)" } ?? ""
            return "host started (pid \(pid.map(String.init) ?? "?"), doz \(version ?? "?"))\(was)"
        case "stopped":
            let why = reason.map { " (\($0))" } ?? ""
            return "host stopped\(why)" + (n == 0 ? "" : " — \(n) sandbox\(n == 1 ? "" : "es") hibernated\(list)")
        default:
            return "host died" + (n == 0 ? " — no sandbox was running" : " — \(n) sandbox\(n == 1 ? " was" : "es were") running, now shut down\(list)")
        }
    }
}

/// 594 W18: the host's transitions, from the UI's poll (pure: the monitor feeds it, the tests too).
/// The first look sets the state and tells nothing; after it, every start, clean stop, crash and
/// change of build is told once.
struct WebHostWatch {
    private(set) var running: Bool?
    private var pid: Int32?
    /// The version of the last host seen running (kept across a stop, for "was rc.3").
    private(set) var version: String?
    private var live: [String] = []
    /// Sandboxes shown "died with host" at the last look.
    private var died: Set<String>?
    /// Sandboxes a `died` change already named (so their mark, seen later, is not told again).
    private var told: Set<String> = []

    /// Before the overview: the host is gone. Tells `stopped` or `died` once.
    mutating func probed(_ p: WebHostProbe, now: Date = Date()) -> WebHostChange? {
        guard running == true, !p.running else { return nil }
        running = false
        let crashed = p.stalePID || !p.recovering.isEmpty
        if crashed { told.formUnion(p.lost) }
        return WebHostChange(state: crashed ? "died" : "stopped", version: version, pid: pid,
                             sandboxes: crashed ? p.lost : live, reason: crashed ? nil : p.exitReason, time: now)
    }

    /// After the overview: a start (or a new host between two looks), and crashes whose gap was
    /// missed (a sandbox newly "died with host" that no change named).
    mutating func saw(_ o: WebOverview, now: Date = Date()) -> [WebHostChange] {
        var out: [WebHostChange] = []
        let h = o.host
        let diedNow = Set(o.sandboxes.filter { $0.diedWithHost == true }.map(\.name))
        if let before = died {
            let fresh = diedNow.subtracting(before).subtracting(told)
            if !fresh.isEmpty {
                out.append(WebHostChange(state: "died", version: version, pid: pid, sandboxes: fresh.sorted(), time: now))
            }
        }
        told.subtract(diedNow)
        died = diedNow
        if h.running {
            if let was = running, !was || pid != h.pid {
                // A new host between two looks was a stop the poll never saw: say so first.
                if was && out.isEmpty {
                    out.append(WebHostChange(state: "stopped", version: version, pid: pid, sandboxes: live, time: now))
                }
                let changed = version != nil && h.version != nil && version != h.version
                out.append(WebHostChange(state: "running", version: h.version, previousVersion: changed ? version : nil, pid: h.pid, time: now))
            }
            running = true
            pid = h.pid
            version = h.version ?? version
            live = h.liveSandboxes
        } else {
            if running == true {
                // No probe saw the gap (a source without one): what the overview says.
                let crashed = !h.recoveryPending.isEmpty
                out.append(WebHostChange(state: crashed ? "died" : "stopped", version: version, pid: pid,
                                         sandboxes: crashed ? h.recoveryPending : live, time: now))
            }
            running = false
        }
        return out
    }
}

public struct WebSandboxRow: Codable, Equatable, Sendable {
    public var name: String
    public var image: String
    public var phase: String
    public var phaseLabel: String
    public var busy: Bool
    public var cpus: Int
    public var memoryMiB: UInt64
    public var ramHeldMiB: UInt64
    public var memoryReturnedMiB: UInt64
    public var diskBytes: Int64
    public var sessions: Int?
    public var network: String
    public var deniedConnections: Int?
    public var workspace: String?
    public var createdAt: Date?
    public var diedWithHost: Bool?
    public var account: String?
    public var credentialState: String?
    public var credentialPolicy: String?
    public var foreignCredentials: Int?
    /// Whether the account can matter: only a proxied network whose policy may reach Anthropic's
    /// API uses one (the data source decides from the sandbox's policy; this default is by preset).
    /// bake/locked/nat/none show "n/a" (590 nit).
    public var accountApplies: Bool
    /// 594: the agent it runs (claude-code, pi) and what is wrong with its account for it (the page's banner).
    public var agent: String?
    public var credentialProblem: String?
    /// 594 W28: made from an image an older doz's recipe made — the notice (with what reset keeps).
    public var olderImage: String?
    /// 596: its base (catalogue id or `df-…`), "Python · Claude Code", the Dockerfile it was built
    /// from, and — a Dockerfile's sandbox — "Dockerfile changed — rebuild available".
    public var base: String?
    public var imageTitle: String?
    public var dockerfile: String?
    public var rebuildAvailable: String?
    /// 599g: the workspace's rules in one line (".dozignore: 3 patterns (lock) · .dozreadonly: 1 pattern — in
    /// force"), and whether the guest serves them (`running`, `pending`, `stopped`). nil: no rule file.
    public var workspaceRules: String?
    public var workspaceRulesView: String?
    /// 612: each session's program status (from the host's memory — no guest call), the most urgent one (the
    /// sidebar's dot), and whether any is working. nil: no program reported anything.
    public var sessionStatuses: [WebAgentStatus]?
    public var agentStatus: WebAgentStatus?
    public var agentWorking: Bool?

    public init(_ i: SandboxInfo) {
        sessionStatuses = i.sessionStatuses.map { $0.map(WebAgentStatus.init) }
        agentStatus = i.agentStatus.map(WebAgentStatus.init)
        agentWorking = i.agentWorking
        workspaceRules = i.workspaceRules?.line
        workspaceRulesView = i.workspaceRules?.view
        accountApplies = ["agent", "open", "custom"].contains(i.network)
        // 596: the AGENT (python-claude-code runs claude-code) — the page's account choice follows it.
        agent = i.agent.map { a in ImageChoice.parse(a).map { $0.agent == .none ? a : $0.agent.rawValue } ?? a }
        base = i.base
        imageTitle = i.imageTitle
        dockerfile = i.dockerfile
        rebuildAvailable = i.rebuildAvailable
        credentialProblem = i.credentialProblem
        olderImage = i.olderImageLine
        name = i.name
        image = i.image
        phase = i.phase
        phaseLabel = Phase(rawValue: i.phase).map(PhaseName.label) ?? i.phase
        busy = i.busy
        cpus = i.cpus
        memoryMiB = i.memoryMiB
        ramHeldMiB = i.ramHeldMiB
        memoryReturnedMiB = i.memoryReturnedMiB
        diskBytes = i.diskBytes
        sessions = i.sessions
        network = i.network
        deniedConnections = i.deniedConnections
        workspace = i.workspace
        createdAt = i.createdAt
        diedWithHost = i.diedWithHost
        account = i.account
        credentialState = i.credentialState
        credentialPolicy = i.credentialPolicy
        foreignCredentials = i.foreignCredentials
    }
}

/// 612: what a session's program says it is doing (OSC 7501), for the page. `message` and `title` are the
/// PROGRAM's text — untrusted guest text: capped here, rendered with textContent only.
public struct WebAgentStatus: Codable, Equatable, Sendable {
    public var session: String
    /// idle | working | done | blocked | error
    public var state: String
    /// For people: "working 40%", "blocked: needs permission", "done", …
    public var label: String
    /// permission | question | auth (blocked only)
    public var kind: String?
    public var progress: Int?
    public var app: String?
    public var message: String?
    public var title: String?
    public var updatedAt: Date

    public static let maximumMessage = 300
    public static let maximumTitle = 100

    public init(_ s: SessionStatus) {
        session = s.session
        state = s.state.rawValue
        label = s.label
        kind = s.kind?.rawValue
        progress = s.progress
        app = s.app
        message = s.message.map { Self.cap($0, Self.maximumMessage) }
        title = s.title.map { Self.cap($0, Self.maximumTitle) }
        updatedAt = s.updatedAt
    }

    static func cap(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n - 1)) + "…" }
}

public struct WebTotals: Codable, Equatable, Sendable {
    public var sandboxes: Int
    public var live: Int
    public var ramHeldMiB: UInt64
    public var diskBytes: Int64
    public var sessions: Int
}

public struct WebOverview: Codable, Equatable, Sendable {
    public var host: WebHost
    public var sandboxes: [WebSandboxRow]
    public var totals: WebTotals
    /// `host` (asked the running host) or `store` (read in this process; nothing is running).
    public var source: String
    /// 594 (D8): the store has an onboarding record (the page opens on the wizard until it has).
    public var onboarded: Bool?

    public init(host: WebHost, sandboxes: [WebSandboxRow], source: String) {
        self.host = host
        self.sandboxes = sandboxes
        self.source = source
        totals = WebTotals(sandboxes: sandboxes.count,
                           live: sandboxes.filter { ["booting", "running", "paused", "asleep"].contains($0.phase) }.count,
                           ramHeldMiB: sandboxes.reduce(0) { $0 + $1.ramHeldMiB },
                           diskBytes: sandboxes.reduce(0) { $0 + $1.diskBytes },
                           sessions: sandboxes.reduce(0) { $0 + ($1.sessions ?? 0) })
    }
}

public struct WebSessionRow: Codable, Equatable, Sendable {
    public var name: String
    public var pid: Int?
    public var cols: UInt16?
    public var rows: UInt16?
    public var clients: Int
    public var screen: String?
    public var command: String
    public var exitCode: Int32?
    public var ended: Bool
    /// 593 §9: from the saved screen (the sandbox is not running), and when/why it was saved.
    public var saved: Bool
    public var savedAt: Date?
    public var savedReason: String?
    /// 612: what its program says it is doing.
    public var status: WebAgentStatus?

    public init(_ s: SessionRow) {
        status = s.status.map(WebAgentStatus.init)
        name = s.name
        pid = s.pid
        cols = s.cols
        rows = s.rows
        clients = s.clients
        screen = s.screen
        command = s.command
        exitCode = s.exitCode
        ended = s.ended
        saved = s.saved ?? false
        savedAt = s.savedAt
        savedReason = s.savedReason
    }
}

public struct WebRestorePoint: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var note: String
    public var createdAt: Date
    public var takenWhile: String
    public var automatic: Bool
    public var needsFsck: Bool
    public var sourceImage: String?

    public init(_ p: RestorePoint) {
        id = p.id
        name = p.name
        note = p.note
        createdAt = p.createdAt
        takenWhile = p.takenWhile.rawValue
        automatic = p.automatic
        needsFsck = p.needsFsck
        sourceImage = p.sourceImage
    }
}

public struct WebForeignCredential: Codable, Equatable, Sendable {
    public var kind: String
    /// At most 13 characters (the library's rule) — never enough to use.
    public var prefix: String
    /// 12 hex of sha256.
    public var fingerprint: String
    public var header: String
    public var requests: Int
    public var firstSeen: Date
    public var lastSeen: Date
    public var matches: String?

    public init(_ f: ForeignCredential) {
        kind = f.kind
        prefix = String(f.prefix.prefix(13))
        fingerprint = f.fingerprint
        header = f.header
        requests = f.requests
        firstSeen = f.firstSeen
        lastSeen = f.lastSeen
        matches = f.matches
    }
}

public struct WebCredential: Codable, Equatable, Sendable {
    public var binding: String
    public var hosts: [String]
    public var set: Bool
    /// `stdin`, `prompt`, `keychain:<service>`, `account:<name>` — where it came from, never it.
    public var source: String?
    public var account: String?
    public var state: String?
    public var expiresAt: Date?
    public var policy: String?
    public var foreign: [WebForeignCredential]

    public init(_ c: CredentialRow) {
        binding = c.binding
        hosts = c.hosts
        set = c.set
        source = c.source
        account = c.account
        state = c.state
        expiresAt = c.expiresAt
        policy = c.policy
        foreign = (c.foreign ?? []).map(WebForeignCredential.init)
    }
}

public struct WebRule: Codable, Equatable, Sendable {
    public var action: String
    public var label: String
    public var note: String
}

public struct WebPolicy: Codable, Equatable, Sendable {
    public var preset: String?
    public var defaultAction: String
    public var rules: [WebRule]

    /// 597: its permissions by name (nil: an older policy of rules).
    public var permissions: [String]?

    public init(_ p: NetworkPolicy) {
        preset = p.preset
        defaultAction = p.effectiveDefault.rawValue
        // 597: every rule evaluated — the user's own first, then the permissions' (this build's hosts).
        rules = p.effectiveRules.map { WebRule(action: $0.action.rawValue, label: $0.label, note: $0.note) }
        permissions = p.permissions
    }
}

/// 597: "What the agent can do" — the host's `PermissionReport`, field by field.
public struct WebPermissions: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var summary: String
        public var on: Bool
        public var locked: Bool
        public var warning: String?
        public var group: String?
        public var hosts: [String]
        public var standard: Bool
    }
    public struct Suggestion: Codable, Equatable, Sendable {
        public var permission: String?
        public var what: String
        public var hosts: [String]
        public var count: Int
        public var grant: String
    }
    public var preset: String?
    public var rows: [Row]
    public var sites: [String]
    public var suggestions: [Suggestion]
    public var inferred: Bool

    public init(_ r: PermissionReport) {
        preset = r.preset
        rows = r.permissions.map { Row(id: $0.id, title: $0.title, summary: $0.summary, on: $0.on, locked: $0.locked, warning: $0.warning,
                                       group: $0.group, hosts: $0.hosts, standard: $0.standard) }
        sites = r.sites
        suggestions = r.suggestions.map { Suggestion(permission: $0.permission, what: $0.what, hosts: $0.hosts, count: $0.count, grant: $0.grant) }
        inferred = r.inferred
    }
}

public struct WebShare: Codable, Equatable, Sendable {
    public var hostPath: String
    public var guestPath: String
}

public struct WebSandboxDetail: Codable, Equatable, Sendable {
    public var info: WebSandboxRow
    public var cpus: Int
    public var memoryMiB: UInt64
    public var rootfsMiB: UInt64
    public var stateDiskMiB: UInt64
    public var journalMiB: Int?
    public var networkMode: String
    public var subnet: String?
    public var shares: [WebShare]
    public var policy: WebPolicy?
    public var sessions: [WebSessionRow]?
    public var restorePoints: [WebRestorePoint]
    public var credentials: [WebCredential]
    public var directory: String
    public var snapshotBytes: Int64
    public var hasRootDisk: Bool
    public var defaultSession: String
    /// What to type in a terminal to attach (phase 1's terminal hand-off: copy it).
    public var attachCommand: String
    /// 594 (D15/D16): the environment prompt the agent gets at its next session — on/off, the
    /// rendered facts block, why it does not render, its layers, and where the skill goes.
    public var agentPrompt: WebAgentPrompt?
    /// 594: the doz_project.yaml it was made from.
    public var project: String?

    public init(_ d: SandboxDetail, attachCommand: String) {
        info = WebSandboxRow(d.info)
        cpus = d.spec.cpus
        memoryMiB = d.spec.memoryMiB
        rootfsMiB = d.spec.rootfsMiB
        stateDiskMiB = d.spec.stateDiskMiB
        journalMiB = d.spec.journalMiB
        networkMode = d.info.network
        subnet = d.spec.subnet
        shares = d.spec.shares.map { WebShare(hostPath: $0.hostPath, guestPath: $0.guestPath) }
        policy = d.policy.map(WebPolicy.init)
        sessions = d.sessions?.map(WebSessionRow.init)
        restorePoints = d.restorePoints.map(WebRestorePoint.init)
        credentials = d.credentials.map(WebCredential.init)
        directory = d.directory
        snapshotBytes = d.snapshotBytes
        hasRootDisk = d.hasRootDisk
        defaultSession = d.defaultSession
        self.attachCommand = attachCommand
        agentPrompt = d.agentPrompt.map(WebAgentPrompt.init)
        project = d.project
    }
}

/// 594: a sandbox's environment prompt, field by field.
public struct WebAgentPrompt: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var agent: String
    public var text: String?
    public var error: String?
    public var layers: [String]
    public var promptPath: String
    public var skillPath: String
    public var skillLines: Int

    public init(_ r: AgentPromptReport) {
        enabled = r.enabled
        agent = r.agent
        text = r.text
        error = r.error
        layers = r.layers
        promptPath = r.promptPath
        skillPath = r.skillPath
        skillLines = (r.skill ?? "").split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

/// 594: an image preparation in the host (the wizard's Preparing step, the Operations page).
public struct WebPreparation: Codable, Equatable, Sendable {
    public var id: String
    public var image: String
    public var state: String
    public var requestedBy: [String]
    public var startedAt: Date
    public var finishedAt: Date?
    public var seconds: Double
    public var error: String?
    public var step: String?
    public var stepSeconds: Double?
    public var transferLabel: String?
    public var transferLine: String?
    public var transferFraction: Double?
    public var output: [String]
    public var lines: [String]
    /// 594 (owner: "more progress detail"): step N of M, the finished steps, the estimates.
    public var stepIndex: Int?
    public var plannedSteps: Int?
    public var steps: [WebPreparationStep]
    public var stepUsualSeconds: Double?
    public var remainingSeconds: Double?
    public var estimateBasis: String?

    public struct WebPreparationStep: Codable, Equatable, Sendable {
        public var label: String
        public var kind: String
        public var seconds: Double
        public var usualSeconds: Double?
        public var error: String?
        public var output: [String]?
    }

    public init(_ p: PreparationInfo) {
        id = p.id
        image = p.image
        state = p.state
        requestedBy = p.requestedBy
        startedAt = p.startedAt
        finishedAt = p.finishedAt
        seconds = p.seconds
        error = p.error
        step = p.step
        stepSeconds = p.stepSeconds
        transferLabel = p.transfer?.label
        transferLine = p.transfer?.line
        if let t = p.transfer, let total = t.totalBytes, total > 0 { transferFraction = min(1, Double(t.completedBytes) / Double(total)) }
        output = p.output
        lines = p.lines
        stepIndex = p.stepIndex
        plannedSteps = p.plannedSteps
        steps = (p.steps ?? []).map { WebPreparationStep(label: $0.label, kind: $0.kind, seconds: $0.seconds, usualSeconds: $0.usualSeconds,
                                                         error: $0.error, output: $0.output) }
        stepUsualSeconds = p.stepUsualSeconds
        remainingSeconds = p.remainingSeconds
        estimateBasis = p.estimateBasis
    }
}

/// 594: the onboarding wizard's facts (D11).
public struct WebOnboarding: Codable, Equatable, Sendable {
    public struct Check: Codable, Equatable, Sendable {
        public var check: String
        public var status: String
        public var detail: String
        public var hard: Bool
    }
    public struct Image: Codable, Equatable, Sendable {
        public var name: String
        public var summary: String
        public var download: String
        public var estimate: String
        public var diskBytes: Int64
        public var prepared: Bool
        public var recommended: Bool
    }
    public struct AccountOption: Codable, Equatable, Sendable {
        public var value: String
        public var label: String
        /// What to run in a terminal (a key or a token is never typed in a browser).
        public var commands: [String]
    }
    public struct Record: Codable, Equatable, Sendable {
        public var dozVersion: String
        public var date: Date
        public var images: [String]
    }

    public var onboarded: Record?
    public var hostRunning: Bool
    public var checks: [Check]
    /// A hard check other than the disk failed: onboarding cannot go on.
    public var blocked: Bool
    public var freeBytes: Int64?
    public var commonBytes: Int64
    /// The agent images' shared base, counted once when claude-code or pi is chosen.
    public var nodeBaseBytes: Int64
    public var headroomBytes: Int64
    public var macSignedIn: Bool
    public var accountOptions: [AccountOption]
    public var preferredAccount: String
    /// The store's default account now.
    public var defaultAccount: String
    public var images: [Image]
    public var preparations: [WebPreparation]
    public var settingsPath: String?
    public var settingsExists: Bool
    public var promptTemplatePath: String?
    public var promptTemplateExists: Bool
    /// The settings' defaults.image.
    public var defaultImage: String
    /// 599g: the Workspace rules step's words (the same `doz onboard` prints).
    public var rulesGuide = WebRulesGuide()

    public init(status: PrepareStatus, checks: [OnboardingCheck], freeBytes: Int64?, macSignedIn: Bool, defaultAccount: String,
                versions: [String: String] = [:]) {
        onboarded = status.onboarded.map { Record(dozVersion: $0.dozVersion, date: $0.date, images: $0.images) }
        hostRunning = status.hostRunning
        self.checks = checks.map { Check(check: $0.check, status: $0.status, detail: $0.detail, hard: $0.hard) }
        blocked = checks.contains { $0.blocks && $0.check != "disk" }
        self.freeBytes = freeBytes
        commonBytes = Onboarding.commonBytes
        nodeBaseBytes = Onboarding.nodeBaseBytes
        headroomBytes = Onboarding.headroomBytes
        self.macSignedIn = macSignedIn
        let (options, preferred) = Onboarding.accountOptions(macSignedIn: macSignedIn)
        accountOptions = options.map { AccountOption(value: $0.rawValue, label: $0.label, commands: Onboarding.accountCommands($0)) }
        preferredAccount = preferred.rawValue
        self.defaultAccount = defaultAccount
        images = Onboarding.imageOptions(status.images, versions: versions).map {
            Image(name: $0.name, summary: $0.summary, download: $0.download, estimate: $0.estimate, diskBytes: $0.diskBytes,
                  prepared: $0.prepared, recommended: $0.recommended)
        }
        preparations = status.preparations.map(WebPreparation.init)
        settingsPath = nil
        settingsExists = false
        promptTemplatePath = nil
        promptTemplateExists = false
        defaultImage = "lab"
    }
}

/// 594: `POST /api/v1/onboarding/config` — the settings file and the prompt template, each written
/// only when missing (D7).
public struct WebOnboardingConfigResult: Codable, Equatable, Sendable {
    /// written · kept · unavailable
    public var settings: String
    public var settingsPath: String?
    public var promptTemplate: String
    public var promptTemplatePath: String?
    /// 599e: the Access settings written (`key = value`), when the wizard sent its choices.
    public var accessSet: [String]? = nil
    /// 599g: the Workspace rules step's setting written (`key = value`; empty: the file already said so).
    public var rulesSet: [String]? = nil
}

/// 599g (owner A1/A2): workspace rules explained — `WorkspaceRulesGuide`, the words `doz onboard` and `doz init`
/// print, for the onboarding's and the New Sandbox wizard's step. Static text, no value from anywhere else.
public struct WebRulesGuide: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable { public var term: String?; public var text: String }
    public struct Mode: Codable, Equatable, Sendable { public var value: String; public var label: String; public var detail: String; public var recommended: Bool }
    public var title = WorkspaceRulesGuide.title
    public var intro = WorkspaceRulesGuide.intro
    public var points = WorkspaceRulesGuide.points.map { Point(term: $0.term, text: $0.text) }
    public var question = WorkspaceRulesGuide.question
    public var modes = WorkspaceRulesGuide.modes.map { Mode(value: $0.value, label: $0.label, detail: $0.detail, recommended: $0.recommended) }
    public var defaultScope = WorkspaceRulesGuide.defaultScope
    public var sandboxScope = WorkspaceRulesGuide.sandboxScope
    public var noRules = WorkspaceRulesGuide.noRules
    public var howToAdd = WorkspaceRulesGuide.howToAdd
    public init() {}
}

/// 599g: a rule file found in a project folder — its name, how many usable patterns, the first few (inert), the
/// lines skipped.
public struct WebRuleFile: Codable, Equatable, Sendable {
    public var name: String
    public var patterns: Int
    public var count: String
    public var first: [String]
    public var skipped: Int
    public init(_ f: WorkspaceRulesGuide.FolderFile) {
        name = f.name
        patterns = f.patterns
        count = WorkspaceRulesGuide.count(f)
        first = f.first
        skipped = f.skipped
    }
}

public struct WebConnection: Codable, Equatable, Sendable {
    public var time: Date
    public var kind: String
    public var host: String
    public var port: UInt16?
    public var method: String?
    /// Without its query string (the library never records one).
    public var path: String?
    public var verdict: String
    public var rule: String
    public var decrypted: Bool
    /// What happened to a credential (`injected anthropic`, a fingerprint) — never a value.
    public var credential: String?
    public var bytesUp: Int
    public var bytesDown: Int
    public var latencyMs: Double?
    public var durationMs: Double?

    public init(_ c: ConnectionRecord) {
        time = c.time
        kind = c.kind.rawValue
        host = c.host
        port = c.port
        method = c.method
        path = c.path
        verdict = c.verdict.rawValue
        rule = c.rule
        decrypted = c.decrypted
        credential = c.credential
        bytesUp = c.bytesUp
        bytesDown = c.bytesDown
        latencyMs = c.latencyMs
        durationMs = c.durationMs
    }
}

public struct WebNetwork: Codable, Equatable, Sendable {
    public var name: String
    public var proxied: Bool
    public var mode: String
    public var policy: WebPolicy?
    /// The newest `limit` records, newest last.
    public var log: [WebConnection]
    public var logTotal: Int
    public var denied: Int
    /// The log lives in the host, from its start: false when no host runs (nothing to show).
    public var logAvailable: Bool
    public var note: String?
    /// 597: what the agent can do (nil: not proxied).
    public var permissions: WebPermissions? = nil
}

public struct WebImage: Codable, Equatable, Sendable {
    public var name: String
    public var kind: String
    public var baked: Bool
    public var key: String?
    public var bakedAt: Date?
    public var allocatedBytes: Int64?
    public var note: String?
    public var fromSandbox: String?
    /// 594: prepared for this build (a built-in image).
    public var current: Bool?
    /// 594: an agent image's version (the one a new sandbox gets), its setting, the registry's latest,
    /// a newer version available and whether it is being prepared, and the line saying all that.
    public var version: String?
    public var versionSetting: String?
    public var latest: String?
    public var available: String?
    public var preparing: Bool?
    public var versionLine: String?
    /// 594: the agent a sandbox of this image runs (a template's: the image it was saved from).
    public var agent: String?
    /// 594 W28: `up to date` · `older recipe` · `update available` · `not prepared` · `preparing`, what
    /// an older doz's image lacks, and the line that says it (with the rebuild command).
    public var status: String?
    public var olderRecipe: [String]?
    public var standing: String?
    /// 596: base × agent ("Python · Claude Code"), the Dockerfile, a newer base than it was made from.
    public var base: String?
    public var title: String?
    public var dockerfile: String?
    public var baseUpdate: String?

    public init(_ r: ImageRow) {
        agent = r.agent
        base = r.base
        title = r.title
        dockerfile = r.dockerfile
        baseUpdate = r.baseUpdate
        status = r.status
        olderRecipe = r.olderRecipe
        standing = r.standing
        name = r.name
        kind = r.kind
        baked = r.baked
        key = r.key
        bakedAt = r.bakedAt
        allocatedBytes = r.allocatedBytes
        note = r.note
        fromSandbox = r.fromSandbox
        current = r.current
        version = r.version
        versionSetting = r.versionSetting
        latest = r.latest
        available = r.available
        preparing = r.preparing
        versionLine = r.versionLine
    }
}

/// 593: Images › Lineage — the host's `ImageTree`, field by field (no host path: there is none in it).
public struct WebImageTree: Codable, Equatable, Sendable {
    public struct Node: Codable, Equatable, Sendable {
        public var id: Int
        public var parent: Int?
        public var depth: Int
        public var kind: String
        public var name: String
        public var detail: String?
        public var sandbox: String?
        public var allocatedBytes: Int64
        public var uniqueBytes: Int64
        public var sharedWithParentBytes: Int64?
        public var stateAllocatedBytes: Int64?

        public init(_ n: ImageTreeNode) {
            id = n.id
            parent = n.parent
            depth = n.depth
            kind = n.kind
            name = n.name
            detail = n.detail
            sandbox = n.sandbox
            allocatedBytes = n.allocatedBytes
            uniqueBytes = n.uniqueBytes
            sharedWithParentBytes = n.sharedWithParentBytes
            stateAllocatedBytes = n.stateAllocatedBytes
        }
    }

    public var nodes: [Node]
    public var unionBytes: Int64
    public var milliseconds: Double

    public init(_ t: ImageTree) {
        nodes = t.nodes.map(Node.init)
        unionBytes = t.unionBytes
        milliseconds = t.milliseconds
    }
}

public struct WebAccount: Codable, Equatable, Sendable {
    public var name: String
    public var kind: String
    public var plan: String?
    public var identity: String?
    public var expiresAt: Date?
    public var verification: String?
    public var isDefault: Bool
    public var usedBy: [String]
    public var state: String
    /// The keychain item's NAME (service) — never its contents.
    public var keychainService: String?
    public var fingerprint: String?

    public init(_ a: AccountRow) {
        name = a.name
        kind = a.kind
        plan = a.plan
        identity = a.identity
        expiresAt = a.expiresAt
        verification = a.verification
        isDefault = a.isDefault
        usedBy = a.usedBy
        state = a.state
        keychainService = a.keychainService
        fingerprint = a.fingerprint
    }
}

public struct WebAccounts: Codable, Equatable, Sendable {
    public var accounts: [WebAccount]
    public var defaultAccount: String
    public var keepalive: Bool
    /// 594: the kinds of account each agent can use (`AgentImages.credentials`): claude-code → mac,
    /// setup-token, api-key; pi → api-key. The forms offer only these.
    public var agents: [String: [String]] = [:]
    /// 599i: the OpenAI account Codex sandboxes follow (nil: none).
    public var openaiDefault: String?

    public init(accounts: [WebAccount], defaultAccount: String, keepalive: Bool, openaiDefault: String? = nil) {
        self.accounts = accounts
        self.defaultAccount = defaultAccount
        self.keepalive = keepalive
        self.openaiDefault = openaiDefault
        for image in ["claude-code", "pi", "codex"] {
            if let c = AgentImages.credentials(image) { agents[image] = c.flatMap(\.accountKinds) }
        }
    }
}

public struct WebMetricsRow: Codable, Equatable, Sendable {
    public var action: String
    public var kind: String
    public var count: Int
    public var failed: Int
    public var medianMs: Double?
    public var p90Ms: Double?
    public var minMs: Double?
    public var maxMs: Double?

    public init(_ r: MetricsSummaryRow) {
        action = r.action
        kind = r.kind.rawValue
        count = r.count
        failed = r.failed
        medianMs = r.medianMs
        p90Ms = r.p90Ms
        minMs = r.minMs
        maxMs = r.maxMs
    }
}

public struct WebMetrics: Codable, Equatable, Sendable {
    public var available: Bool
    public var runs: Int
    public var rows: Int
    public var sessions: Int
    public var networkMinutes: Int
    public var summary: [WebMetricsRow]
}

public struct WebDoctorCheck: Codable, Equatable, Sendable {
    public var check: String
    /// `ok`, `warn`, `fail`.
    public var status: String
    public var detail: String

    public init(check: String, status: String, detail: String) {
        self.check = check
        self.status = status
        self.detail = detail
    }
}

/// One line of the activity feed: a host event (phase, timed step, note, progress) or the UI's own
/// note (the host came or went).
public struct WebActivity: Codable, Equatable, Sendable {
    public var seq: Int
    public var time: Date
    public var kind: String
    public var sandbox: String?
    public var text: String
    public var phase: String?
    public var milliseconds: Double?

    public init(seq: Int, _ e: HostEvent) {
        self.seq = seq
        time = e.time
        kind = e.kind.rawValue
        sandbox = e.sandbox
        // The feed shows the sandbox in its own column: drop `line`'s "name: " prefix.
        let line = e.line
        if let s = e.sandbox, line.hasPrefix(s + ": ") { text = String(line.dropFirst(s.count + 2)) } else { text = line }
        phase = e.phase
        milliseconds = e.milliseconds
    }

    public init(seq: Int, time: Date = Date(), kind: String, text: String) {
        self.seq = seq
        self.time = time
        self.kind = kind
        self.text = text
    }
}

/// `GET /api/v1/session`, and the bootstrap's answer.
/// 605: the event stream's first event. `script`/`style`: this build's hashed page files — a page whose
/// own differ was loaded from an older (or newer) doz ui, and offers a reload.
public struct WebHello: Codable, Equatable, Sendable {
    public var serverRun: String
    public var version: String
    public var script: String?
    public var style: String?
}

public struct WebSessionInfo: Codable, Equatable, Sendable {
    public var csrf: String
    public var expiresAt: Date
    public var serverRun: String
    public var store: String
    public var version: String
    /// 606: doz serve — what this browser is and may do (nil on doz ui).
    public var serve: WebServeSessionInfo? = nil
    /// 611: this build has Dozer's own ChatGPT sign-in (a public build does not: the page never offers it).
    public var chatgptSignIn: Bool = true
    /// 611: a newer doz (the banner), or one an automatic update installed that this doz ui is older than.
    public var update: WebUpdateNotice? = nil
}

/// 611: the dashboard's update banner — from the last check doz ui (or a command) made; never a network call per page.
public struct WebUpdateNotice: Codable, Equatable, Sendable {
    /// "available" (a newer doz: `version`, `command`, `notes`) · "installed" (restart to apply: `command`)
    public var kind: String
    public var version: String
    public var command: String
    public var notes: String?
    public var text: String
}

/// 606: a doz serve page's own facts: this device, how it arrived, the Mac it is on.
public struct WebServeSessionInfo: Codable, Equatable, Sendable {
    /// remote (always, on doz serve)
    public var exposure: String
    /// The request arrived over https at a trusted proxy.
    public var secure: Bool
    /// Keys and tokens may be typed here (https through a trusted proxy, and ui.allow_secret_entry).
    public var secretsAllowed: Bool
    /// The Mac's name (`<LocalHostName>`), for the page's title.
    public var mac: String?
    public var device: WebDeviceView
}

/// 606: `GET /api/v1/serve` — the dashboard for the other browsers, as the asking page (or the Mac) sees it.
public struct WebServeStatus: Codable, Equatable, Sendable {
    /// running · stopped (doz ui, when no doz serve runs)
    public var state: String
    /// Where browsers reach it: the Mac's names and addresses, and the configured public origins.
    public var origins: [String]
    public var publicOrigins: [String]
    public var port: Int?
    public var bind: String?
    public var devices: Int
    public var openInvites: Int?
    public var advertised: String?
    /// rc.2: the running doz serve's process, since when, its build, whether it was started detached (`--detach`),
    /// its log (detached), and the app macOS attributes it to (Local Network privacy asks on that app's behalf).
    public var pid: Int? = nil
    public var since: Date? = nil
    public var version: String? = nil
    public var detached: Bool? = nil
    public var log: String? = nil
    public var responsibleApp: String? = nil

    public init(state: String, origins: [String], publicOrigins: [String], port: Int?, bind: String?, devices: Int, openInvites: Int?,
                advertised: String?) {
        self.state = state; self.origins = origins; self.publicOrigins = publicOrigins; self.port = port; self.bind = bind
        self.devices = devices; self.openInvites = openInvites; self.advertised = advertised
    }
}

/// 606: `GET /api/v1/serve/devices` — the devices and the recent remote activity.
public struct WebServeDevices: Codable, Equatable, Sendable {
    public var running: Bool
    public var devices: [WebDeviceView]
    public var activity: [WebAuditEntry]

    public init(running: Bool, devices: [WebDeviceView], activity: [WebAuditEntry]) {
        self.running = running; self.devices = devices; self.activity = activity
    }
}
