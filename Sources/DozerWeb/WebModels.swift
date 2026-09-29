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

    public init(_ i: SandboxInfo) {
        accountApplies = ["agent", "open", "custom"].contains(i.network)
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

    public init(_ s: SessionRow) {
        name = s.name
        pid = s.pid
        cols = s.cols
        rows = s.rows
        clients = s.clients
        screen = s.screen
        command = s.command
        exitCode = s.exitCode
        ended = s.ended
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

    public init(_ p: NetworkPolicy) {
        preset = p.preset
        defaultAction = p.defaultAction.rawValue
        rules = p.rules.map { WebRule(action: $0.action.rawValue, label: $0.label, note: $0.note) }
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

    public init(_ r: ImageRow) {
        name = r.name
        kind = r.kind
        baked = r.baked
        key = r.key
        bakedAt = r.bakedAt
        allocatedBytes = r.allocatedBytes
        note = r.note
        fromSandbox = r.fromSandbox
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
public struct WebSessionInfo: Codable, Equatable, Sendable {
    public var csrf: String
    public var expiresAt: Date
    public var serverRun: String
    public var store: String
    public var version: String
}
