import Foundation
import SnoozeContainerKit

// The host protocol (585): one Unix socket, `<store>/host.sock` (0600, the store directory is the
// user's own), and on it JSON LINES. A client connects, writes ONE request line, and reads lines:
// zero or more `event` lines (the operation's progress — steps, notes, downloads) and then exactly
// one line with `ok` set — the result, or the error. Then the host closes the connection, except:
//
//   · `attach` — after its `ok` line the connection carries the terminal, raw: the host writes the
//     session's VT bytes (a SNAPSHOT first, then output), the client writes keystrokes and in-band
//     frames `0xFF 'H' cols rows` (HELLO) / `0xFF 'R' cols rows` (RESIZE), sizes big-endian u16 —
//     the SandboxLab attach wire (`ClientWire`). When the session is over the host writes
//     `ClientWire.endedNotice` and closes; any other close means "reattach when it runs again".
//   · `events` and `net-log --follow` — `event` lines until the client hangs up.
//
// `v` is the protocol version. A host answers a request whose `v` it does not speak with
// `error.code = "version"`; fields are only ever added, never repurposed.

public enum HostProtocol {
    public static let version = 1
}

/// Every operation the host serves.
public enum HostOp: String, Codable, Sendable, CaseIterable {
    case ping
    case create, start, wake, pause, resume, sleep
    case deepSleep = "deep-sleep"
    case shutdown, reset, rm
    case ls, inspect, sessions
    case openSession = "open-session"
    case attach, exec
    case pointTake = "point-take", pointList = "point-ls", pointRevert = "point-revert", pointFork = "point-fork"
    case pointRm = "point-rm", pointSaveImage = "point-save-image"
    case imageList = "image-ls", imageBake = "image-bake", imageRm = "image-rm"
    case netPolicy = "net-policy", netLog = "net-log"
    case keySet = "key-set", keyRm = "key-rm", keyList = "key-ls"
    /// 588: what the proxy does with a credential the guest supplied itself (allow | strict).
    case keyPolicy = "key-policy"
    /// 588: named Anthropic credentials (the Mac login, setup tokens, API keys).
    case accountList = "account-ls", accountAdd = "account-add", accountRemove = "account-rm"
    case accountDefault = "account-default", accountUse = "account-use", accountVerify = "account-verify"
    case accountKeepalive = "account-keepalive"
    case events
    case hostStop = "host-stop"

    /// Operations that only read — answered from the store in-process when no host is running.
    public var isReadOnly: Bool {
        switch self {
        case .ping, .ls, .inspect, .pointList, .imageList, .keyList, .accountList: true
        case .netPolicy: false        // decided per request (a change needs the host)
        default: false
        }
    }
}

/// How `create` / `up` describe a new sandbox.
public struct CreateOptions: Codable, Equatable, Sendable {
    /// `lab`, `claude-code`, `pi`, or the name of a custom image (`snooze point save-image`).
    public var image: String
    public var cpus: Int?
    public var memoryMiB: UInt64?
    /// A host directory shared at /workspace.
    public var workspace: String?
    /// `agent`, `bake`, `locked`, `open` (proxied, with that preset), `nat` or `none`.
    public var network: String?
    /// vmnet subnet for `--network nat` (default: a free one, picked by the library).
    public var subnet: String?
    /// 588: the account a proxied sandbox uses — a name, `none`, or nil (follow the store default).
    public var account: String?

    public init(image: String, cpus: Int? = nil, memoryMiB: UInt64? = nil, workspace: String? = nil,
                network: String? = nil, subnet: String? = nil, account: String? = nil) {
        self.account = account
        self.image = image
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.workspace = workspace
        self.network = network
        self.subnet = subnet
    }
}

/// A flat bag of the arguments an operation may take; each op reads the fields it needs. Flat on
/// purpose: a later version adds fields, never nests or renames.
public struct HostRequest: Codable, Equatable, Sendable {
    public var v: Int
    public var op: HostOp
    /// The sandbox.
    public var name: String?
    public var session: String?
    public var argv: [String]?
    public var create: CreateOptions?
    public var cols: UInt16?
    public var rows: UInt16?
    /// attach / exec / run: wake a paused or sleeping sandbox first (default true).
    public var wake: Bool?
    public var environment: [String: String]?
    public var user: String?
    public var workdir: String?
    public var timeoutSeconds: Int64?
    /// Restore point id or name; image name; new sandbox name (fork); a note.
    public var point: String?
    public var pointName: String?
    public var image: String?
    public var newName: String?
    public var note: String?
    /// net-policy.
    public var preset: String?
    public var allow: [String]?
    public var deny: [String]?
    public var removeHosts: [String]?
    /// net-log.
    public var deniedOnly: Bool?
    public var follow: Bool?
    /// key-set / key-rm: the credential binding (`anthropic`), the secret, and where it came from.
    public var binding: String?
    public var secret: String?
    public var source: String?
    /// 588 account-* / key-policy: the account, its kind (`setup-token`, `api-key`, `mac`), plan,
    /// Claude config dir, adopted keychain service; the policy; verify (default true); force; on/off.
    public var account: String?
    public var accountKind: String?
    public var plan: String?
    public var configDir: String?
    public var keychainService: String?
    public var policy: String?
    public var verify: Bool?
    public var force: Bool?
    public var enabled: Bool?

    public init(_ op: HostOp, name: String? = nil) {
        v = HostProtocol.version
        self.op = op
        self.name = name
    }
}

/// One line from the host.
public struct HostMessage: Codable, Equatable, Sendable {
    public var v: Int
    /// Set on the final line of a response: true with `result`, false with `error`.
    public var ok: Bool?
    public var result: JSONValue?
    public var error: HostError?
    /// A progress / stream line.
    public var event: HostEvent?

    public init(ok: Bool? = nil, result: JSONValue? = nil, error: HostError? = nil, event: HostEvent? = nil) {
        v = HostProtocol.version
        self.ok = ok
        self.result = result
        self.error = error
        self.event = event
    }

    public static func success(_ result: JSONValue = .null) -> HostMessage { HostMessage(ok: true, result: result) }
    public static func failure(_ e: HostError) -> HostMessage { HostMessage(ok: false, error: e) }
}

/// What went wrong, with a stable code (the CLI maps it to its exit code).
public struct HostError: Codable, Equatable, Sendable, Error, LocalizedError {
    public enum Code: String, Codable, Sendable {
        case failed, notFound = "not-found", invalidPhase = "invalid-phase", exists, invalid
        case notImplemented = "not-implemented", version, unavailable
    }
    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }

    /// A library (or any) error as a host error.
    public static func from(_ error: Error) -> HostError {
        if let e = error as? HostError { return e }
        if let e = error as? SandboxError {
            switch e {
            case .invalidPhase, .notRunning: return HostError(.invalidPhase, e.localizedDescription)
            case .restorePointNotFound: return HostError(.notFound, e.localizedDescription)
            case .alreadyExists: return HostError(.exists, e.localizedDescription)
            case .invalidSpec, .invalidSessionName: return HostError(.invalid, e.localizedDescription)
            default: return HostError(.failed, e.localizedDescription)
            }
        }
        return HostError(.failed, error.localizedDescription)
    }
}

/// A progress or stream line: a sandbox's phase change, timed step, note or download progress,
/// or (net-log --follow) a connection record.
public struct HostEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case phase, step, note, progress, connection, host }
    public var kind: Kind
    public var time: Date
    public var sandbox: String?
    public var text: String?
    public var phase: String?
    public var milliseconds: Double?
    public var completedBytes: Int64?
    public var totalBytes: Int64?
    public var connection: ConnectionRecord?

    public init(kind: Kind, sandbox: String?, text: String? = nil, phase: String? = nil, milliseconds: Double? = nil,
                completedBytes: Int64? = nil, totalBytes: Int64? = nil, connection: ConnectionRecord? = nil, time: Date = Date()) {
        self.kind = kind
        self.time = time
        self.sandbox = sandbox
        self.text = text
        self.phase = phase
        self.milliseconds = milliseconds
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.connection = connection
    }

    /// A library event as a host event (status events carry nothing a client needs: nil).
    public init?(_ e: SandboxEvent, sandbox: String) {
        switch e {
        case .phase(let p): self.init(kind: .phase, sandbox: sandbox, text: PhaseName.label(p), phase: p.rawValue)
        case .step(let s, let ms): self.init(kind: .step, sandbox: sandbox, text: s, milliseconds: ms)
        case .note(let s): self.init(kind: .note, sandbox: sandbox, text: s)
        case .progress(let s, let done, let total):
            self.init(kind: .progress, sandbox: sandbox, text: s, completedBytes: done, totalBytes: total)
        case .status: return nil
        }
    }

    /// One human line.
    public var line: String {
        let who = sandbox.map { "\($0): " } ?? ""
        switch kind {
        case .step: return who + (text ?? "") + (milliseconds.map { String(format: " — %.0f ms", $0) } ?? "")
        case .progress:
            let done = (completedBytes ?? 0) / 1_048_576
            return who + "\(text ?? ""): \(done) MiB" + (totalBytes.map { " of \($0 / 1_048_576) MiB" } ?? "")
        case .phase: return who + "→ " + (text ?? phase ?? "")
        case .connection:
            guard let c = connection else { return who }
            return who + "\(c.verdict.rawValue) \(c.kind.rawValue) \(c.target)" + (c.method.map { " \($0) \(c.path ?? "")" } ?? "")
        case .note, .host: return who + (text ?? "")
        }
    }
}

/// The owner's names for the phases (2026-09-25), for people; JSON carries `Phase.rawValue`.
public enum PhaseName {
    public static func label(_ p: Phase) -> String {
        switch p {
        case .off: "off"
        case .booting: "booting"
        case .running: "running"
        case .paused: "paused"
        case .asleep: "asleep"
        case .deepAsleep: "deep asleep"
        case .failed: "failed"
        }
    }
}

// MARK: results

/// One row of `ls` (and the head of `inspect`).
public struct SandboxInfo: Codable, Equatable, Sendable {
    public var name: String
    /// `lab`, `claude-code`, `pi`, or `custom:<name>`.
    public var image: String
    /// `Phase.rawValue`: off, booting, running, paused, asleep, deepAsleep, failed.
    public var phase: String
    public var busy: Bool
    public var cpus: Int
    /// The guest's allocation.
    public var memoryMiB: UInt64
    /// Guest RAM the Mac is charged for now: the allocation while a VM exists, less what the
    /// memory balloon handed back; 0 deep asleep or off.
    public var ramHeldMiB: UInt64
    /// What the balloon currently holds for the Mac (583).
    public var memoryReturnedMiB: UInt64
    /// Allocated bytes of everything the sandbox has on disk (disks, snapshot, restore points).
    public var diskBytes: Int64
    /// Live sessions (nil when the sandbox is not running, so none could be asked).
    public var sessions: Int?
    /// `agent` / `bake` / `locked` / `open` / `custom` (proxied), `nat` or `none`.
    public var network: String
    /// Denied connections in the proxy's log since the host started (proxied only).
    public var deniedConnections: Int?
    public var workspace: String?
    public var createdAt: Date?
    /// The sandbox was running when the previous host died: its disk gets e2fsck at the next start.
    public var diedWithHost: Bool?
    /// 588: the Anthropic account it uses (nil: none), the credential's state (`ok`,
    /// `expires-soon`, `expired`, `signed-out`, `held`, `missing`…), the proxy policy for the
    /// guest's own credentials, and how many such credentials it has seen.
    public var account: String?
    public var credentialState: String?
    public var credentialPolicy: String?
    public var foreignCredentials: Int?

    public init(name: String, image: String, phase: String, busy: Bool, cpus: Int, memoryMiB: UInt64, ramHeldMiB: UInt64,
                memoryReturnedMiB: UInt64, diskBytes: Int64, sessions: Int?, network: String, deniedConnections: Int?,
                workspace: String?, createdAt: Date?, diedWithHost: Bool?, account: String? = nil, credentialState: String? = nil,
                credentialPolicy: String? = nil, foreignCredentials: Int? = nil) {
        self.account = account
        self.credentialState = credentialState
        self.credentialPolicy = credentialPolicy
        self.foreignCredentials = foreignCredentials
        self.name = name
        self.image = image
        self.phase = phase
        self.busy = busy
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.ramHeldMiB = ramHeldMiB
        self.memoryReturnedMiB = memoryReturnedMiB
        self.diskBytes = diskBytes
        self.sessions = sessions
        self.network = network
        self.deniedConnections = deniedConnections
        self.workspace = workspace
        self.createdAt = createdAt
        self.diedWithHost = diedWithHost
    }
}

/// `inspect`.
public struct SandboxDetail: Codable, Equatable, Sendable {
    public var info: SandboxInfo
    public var spec: SandboxSpec
    public var policy: NetworkPolicy?
    public var sessions: [SessionRow]?
    public var restorePoints: [RestorePoint]
    public var credentials: [CredentialRow]
    public var directory: String
    public var bootLog: String
    public var snapshotBytes: Int64
    public var hasRootDisk: Bool
    /// The session `up` / `attach` use when none is named.
    public var defaultSession: String
}

/// One guest session (`deckhold ls`).
public struct SessionRow: Codable, Equatable, Sendable {
    public var name: String
    public var pid: Int?
    public var cols: UInt16?
    public var rows: UInt16?
    public var clients: Int
    public var screen: String?
    public var command: String
    public var exitCode: Int32?
    public var ended: Bool

    public init(_ s: SessionInfo) {
        name = s.name
        pid = s.pid
        cols = s.size?.cols
        rows = s.size?.rows
        clients = s.clients
        screen = s.screen
        command = s.command
        exitCode = s.exitCode
        ended = s.isEnded
    }
}

/// A lifecycle operation's outcome.
public struct LifecycleResult: Codable, Equatable, Sendable {
    public var name: String
    public var operation: String
    public var phaseBefore: String
    public var phase: String
    /// False when the sandbox already was where the operation leads (nothing done).
    public var changed: Bool
    public var milliseconds: Double
    public var info: SandboxInfo?
}

/// `exec`.
public struct ExecOutput: Codable, Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var milliseconds: Double
}

/// `open-session`.
public struct SessionOpened: Codable, Equatable, Sendable {
    public var name: String
    public var session: String
    public var created: Bool
}

/// `image ls`.
public struct ImageRow: Codable, Equatable, Sendable {
    public var name: String
    /// `builtin` or `custom`.
    public var kind: String
    public var baked: Bool
    public var key: String?
    public var bakedAt: Date?
    public var allocatedBytes: Int64?
    public var note: String?
    public var fromSandbox: String?
}

/// `key ls` (never the secret).
public struct CredentialRow: Codable, Equatable, Sendable {
    public var binding: String
    public var hosts: [String]
    public var set: Bool
    /// `stdin` or `keychain:<service>`, or (588) `account:<name>`.
    public var source: String?
    /// 588: the account behind it, its state, when it expires, the foreign-credential policy, and
    /// every credential the guest used that snooze never issued (fingerprints, never values).
    public var account: String?
    public var state: String?
    public var expiresAt: Date?
    public var policy: String?
    public var foreign: [ForeignCredential]?

    public init(binding: String, hosts: [String], set: Bool, source: String?, account: String? = nil, state: String? = nil,
                expiresAt: Date? = nil, policy: String? = nil, foreign: [ForeignCredential]? = nil) {
        self.binding = binding
        self.hosts = hosts
        self.set = set
        self.source = source
        self.account = account
        self.state = state
        self.expiresAt = expiresAt
        self.policy = policy
        self.foreign = foreign
    }
}

/// `ping` / `host status`.
public struct HostStatus: Codable, Equatable, Sendable {
    public var version: String
    public var protocolVersion: Int
    public var pid: Int32
    public var startedAt: Date
    public var store: String
    /// Minutes with nothing running before the host exits (0: never).
    public var idleTimeoutMinutes: Double
    /// Sandboxes with a VM in this host (booting, running, paused or asleep).
    public var liveSandboxes: [String]
    public var connections: Int
    /// Seconds the host has been idle, when it is.
    public var idleSeconds: Double?
}
