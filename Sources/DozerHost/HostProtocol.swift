import Foundation
import DozerKit

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
    case create, start, wake, pause, resume, sleep, hibernate
    case shutdown, reset, rm
    case ls, inspect, sessions
    case openSession = "open-session"
    case attach, exec
    case pointTake = "point-take", pointList = "point-ls", pointRevert = "point-revert", pointFork = "point-fork"
    case pointRm = "point-rm", pointSaveImage = "point-save-image"
    case imageList = "image-ls", imageBake = "image-bake", imageRm = "image-rm"
    case netPolicy = "net-policy", netLog = "net-log"
    /// 597: a sandbox's permissions as a checklist, its preset, its sites and suggestions from the
    /// connections it was refused (`PermissionReport`). Read-only.
    case netPermissions = "net-permissions"
    case keySet = "key-set", keyRm = "key-rm", keyList = "key-ls"
    /// 588: what the proxy does with a credential the guest supplied itself (allow | strict).
    case keyPolicy = "key-policy"
    /// 588: named Anthropic credentials (the Mac login, setup tokens, API keys).
    case accountList = "account-ls", accountAdd = "account-add", accountRemove = "account-rm"
    case accountDefault = "account-default", accountUse = "account-use", accountVerify = "account-verify"
    case accountKeepalive = "account-keepalive"
    case events
    case hostStop = "host-stop"
    /// 591: a sandbox's boot console (the kernel + vminitd serial log, `Sandbox.bootLogURL`) —
    /// its lines so far as the result, or, with `follow`, `console` event lines as they are
    /// written, until the client hangs up (a stream, like `events`).
    case console
    /// 593: the image lineage — OCI base → baked image → template (custom image) → sandboxes, with
    /// 587's `DiskAccounting` sizes (`ImageTree`).
    case imageTree = "image-tree"
    /// 593: a template (a custom image, never the state disk) from a sandbox's current disk — any
    /// phase: a live one goes through a temporary restore point — or from one of its restore points.
    case templateCreate = "template-create"
    /// 593: a new sandbox from an existing one's disk (or a restore point), with overrides
    /// (`DuplicateOptions`); the state disk starts fresh unless `copyState`.
    case duplicate
    /// 594 (D3, D4): prepare built-in images in the host — kernel, guest init, base pull, bake — one
    /// preparation per image at a time (a second asker joins it). `images` names them; `follow`
    /// (default true) waits, streaming the progress; none named + follow joins what is running.
    case prepare
    /// 594: the preparations (running and recent), the onboarding record and the images.
    case prepareStatus = "prepare-status"
    /// 594: cancel preparations (`images`, or every running one).
    case prepareCancel = "prepare-cancel"
    /// 594 (D8): `prepare`, and the store's onboarding record once every named image is ready —
    /// written by the host, so a detached `doz onboard` or a closed wizard still completes it.
    case onboard
    /// 594 (D15, D16): a sandbox's environment prompt — rendered (read), or its per-sandbox layer set
    /// (`prompt`, `promptMode`) or cleared (`clearPrompt`).
    case agentPrompt = "agent-prompt"
    /// 593 §9 (S5): a session's last SAVED screen (`SavedScreens`: VT + text + what is known) — read
    /// from the sandbox's directory in any phase; nothing in the guest is asked.
    case sessionScreen = "session-screen"
    /// 593 §9 (S1): a sandbox's terminal layout as the web UI last left it (`TerminalLayout`), and its
    /// change. UI state kept beside `doz.json`; never a VM, never a secret.
    case terminalLayout = "terminal-layout"
    case terminalLayoutSet = "terminal-layout-set"
    /// 593 (owner, 2026-09-30): a sandbox's kept BOOTS (`BootLogs`) — `list`, or boot `boot` (1 = the
    /// latest): its events and kernel console. Read-only; from the sandbox's directory (plus, from the
    /// host, a boot under way).
    case bootLog = "boot-log"
    /// 595: everything Dozer uses (`ResourceReport`: every byte of the store attributed, memory, CPUs,
    /// traffic, kernels). Read-only; answered in-process when no host runs.
    case resources
    /// 595: delete resources by id (`ids`), or the safe set (`resources-clean`); `dryRun` plans only.
    /// Run with nothing starting, waking or being prepared (serialised with the lifecycle).
    case resourcesRemove = "resources-rm"
    case resourcesClean = "resources-clean"
    /// 595 (R5): which kernel NEW sandboxes boot — `kernel` = a kernel id (`kernel:<version>`) or `pinned`.
    case resourcesKernel = "resources-kernel"
    /// 596 (B3): the recommended bases (`BaseRow`: the catalogue, each tag's digest as resolved, which
    /// agents' images are prepared). Read-only.
    case bases
    /// 596 (B7): Apple's `container` tool as Dozer sees it (`ContainerToolStatus`) — read-only, never
    /// starts anything.
    case builderStatus = "builder-status"
    /// 596 (B7): start Apple's container services (`container system start --enable-kernel-install`)
    /// — sent only because a person asked (the CLI's question, the UI's button).
    case builderStart = "builder-start"
    /// 596 (B7): install Apple's container tool on demand: its signed package (pinned, sha256-checked)
    /// downloaded and opened in macOS Installer — the person approves it there. Never sudo.
    case builderInstall = "builder-install"
    /// 599: a sandbox's own choices of the per-sandbox settings (`DozerSettings.perSandbox`: the clipboard
    /// and browser bridges, tmux, the agent's sudo) — read (no `setting`), set (`setting` + `settingValue`)
    /// or cleared back to the setting (`setting` + `clearSetting`). `doz config set --sandbox NAME`.
    case sandboxSettings = "sandbox-settings"
    /// 599e: the Access step — every credential choice and its last confirmation (`AccessReport`); with
    /// `check`, each (or `items`) is CONFIRMED live first (needs the host: a key it holds, the Mac's gh).
    case access
    /// 599e: the default GitHub key (`github.credentials = key` without a sandbox's own): `secret` sets it
    /// (the login keychain, `doz-github`), `clearSetting` removes it. Never echoed.
    case accessGithubKey = "access-github-key"
    /// 599h: the tools layer of a sandbox — its plan (each tool, why, from where) and the last apply; with
    /// `apply`: apply it again now, shown as steps (the wizard's Retry, `doz tools NAME --apply`).
    case tools
    case toolsApply = "tools-apply"
    /// 599g: a sandbox's workspace rules (`WorkspaceRulesReport`): `.dozignore` / `.dozreadonly` as the Mac
    /// reads them, the mode, the warnings, and — from a host whose sandbox runs — what the guest's view does;
    /// with `paths`, which rule decides each. Read-only (in-process when no host runs: no VM needed).
    case workspaceRules = "workspace-rules"
    /// 608: end a session's program (`session`) — HUP, then TERM, then KILL of its process group
    /// (`SessionEnded`). A running sandbox only: it never wakes one.
    case sessionEnd = "session-end"
    /// 608: end it and open the SAME session again — the program, folder and user it was opened with
    /// (`sessions.json`); an agent's default session continues its conversation unless `fresh`
    /// (`SessionRestarted`). Serialised with open-session.
    case sessionRestart = "session-restart"

    /// Operations that only read — answered from the store in-process when no host is running.
    public var isReadOnly: Bool {
        switch self {
        case .ping, .ls, .inspect, .pointList, .imageList, .keyList, .accountList, .imageTree, .prepareStatus, .sessionScreen, .terminalLayout, .bootLog, .resources,
             .bases, .builderStatus, .netPermissions, .workspaceRules: true
        case .netPolicy: false        // decided per request (a change needs the host)
        default: false
        }
    }
}

/// How `create` / `up` describe a new sandbox.
public struct CreateOptions: Codable, Equatable, Sendable {
    /// `lab`, `claude-code`, `pi`, or the name of a custom image (`doz point save-image`).
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
    /// 594 (D16): this sandbox's own layer of the environment prompt, and whether it is appended to
    /// the template (`append`, the default) or replaces it (`replace`).
    public var agentPrompt: String?
    public var agentPromptMode: String?
    /// 594 (D9): the project file this sandbox was made from (`doz up` in a folder with `doz_project.yaml`).
    public var project: String?
    /// 594: asked for explicitly — no workspace ("isolated"); an error together with `workspace`.
    public var isolated: Bool?
    /// 594 W23: the agent's passwordless sudo for this sandbox (nil: follow `sandbox.agent_sudo`).
    public var agentSudo: Bool?
    /// 596 (B6): the Dockerfile the image's base is built from (absolute; `image` is then its
    /// `df-<12 hex>[-agent]`). The host registers it; its first start builds it.
    public var dockerfile: String?
    /// 594 W28: rebuild the image first (the user chose it: an out-of-date image is otherwise used as it is).
    public var rebuild: Bool?
    /// 597 (P4): a proxied sandbox's permissions — exactly these ids (the web form's switches), and/or
    /// words on top of the default (`doz create --allow web,site:api.example.com`, `-error-reports`).
    public var permissions: [String]?
    public var allow: [String]?
    /// 599: this sandbox's own values of per-sandbox settings (`DozerSettings.perSandbox` keys only).
    public var settings: [String: TOMLValue]?
    /// `doz create --prepare`: prepare the image the sandbox's first start would wait for, now (started
    /// or joined, its progress on the request's stream) — without booting the sandbox.
    public var prepare: Bool?
    /// EXPERIMENTAL (604): an audio sandbox — the Mac's microphone and speakers (`SandboxSpec.audio`).
    public var audio: Bool?

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
/// 593 `duplicate`: what the new sandbox changes from its source. Everything nil keeps the source's.
public struct DuplicateOptions: Codable, Equatable, Sendable {
    /// A host directory shared at /workspace (594: made when it does not exist).
    public var workspace: String?
    /// 594: drop the source's workspace — the duplicate is isolated.
    public var isolated: Bool?
    public var cpus: Int?
    public var memoryMiB: UInt64?
    /// `agent`, `bake`, `locked`, `open`, `nat` or `none` (nil: the source's, a custom policy included).
    public var network: String?
    /// An account name, `none` or `default` (nil: the source's).
    public var account: String?
    /// Clone the source's state disk (the agent's logins and history) too. Default: a fresh one.
    public var copyState: Bool?

    public init(workspace: String? = nil, cpus: Int? = nil, memoryMiB: UInt64? = nil, network: String? = nil,
                account: String? = nil, copyState: Bool? = nil) {
        self.workspace = workspace
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.network = network
        self.account = account
        self.copyState = copyState
    }
}

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
    /// 594 W27: exec / open-session: cold-start an OFF (or failed) sandbox first (default false — an
    /// older client keeps "`doz start` boots it"; this CLI sends true unless --no-start).
    public var start: Bool?
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
    /// 597 (P6): net-policy by permission — ids to switch on / off, or `site:HOST`.
    public var grant: [String]?
    public var revoke: [String]?
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
    /// 590 `ls`: false leaves out each running sandbox's live-session count (`sessions: nil`). The
    /// count asks every session's holder in the guest (`deckhold ls` connects to each), so a poller
    /// — `doz ui`'s, every 3 s — must not pay it (it grew a guest log by 600 KB in 9 hours).
    /// nil or true: counted, as before.
    public var withSessions: Bool?
    /// 593 `duplicate`: the overrides (the new name is `newName`, a restore point `point`).
    public var duplicate: DuplicateOptions?
    /// 594 `prepare` / `onboard` / `prepare-cancel`: the built-in images; who asked (shown in the
    /// preparation's `requestedBy`).
    public var images: [String]?
    public var requestedBy: String?
    /// 594 `agent-prompt`: the sandbox's own layer (text) and its mode (`append` | `replace`), or clear it.
    public var prompt: String?
    public var promptMode: String?
    public var clearPrompt: Bool?
    /// 594 W23 `agent-prompt`: the sandbox's own choice of the agent's passwordless sudo, or (clear)
    /// follow the setting again. From the next session (and every boot).
    public var agentSudo: Bool?
    public var clearAgentSudo: Bool?
    /// 593 `terminal-layout-set`: the layout (nil clears it).
    public var layout: TerminalLayout?
    /// 593 `boot-log`: which kept boot (1 = the latest), or the list of them.
    public var boot: Int?
    public var list: Bool?
    /// 595 `resources-rm`: the resource ids; `dryRun`: plan only (both resources-rm and -clean);
    /// `resources-kernel`: `kernel`.
    public var ids: [String]?
    public var dryRun: Bool?
    public var kernel: String?
    /// 599 `sandbox-settings`: the setting's key, and its value for this sandbox (or clear it).
    public var setting: String?
    public var settingValue: TOMLValue?
    public var clearSetting: Bool?
    /// 599e `access`: confirm live (true), and which credentials (`claude`, `github`, `ssh`; nil: all).
    public var check: Bool?
    public var items: [String]?
    /// 599e `access`: the choices to confirm instead of the settings' (`github`, `githubSource`, `ssh`) —
    /// the onboarding confirms before it writes them (its settings file is written only when missing).
    public var accessChoices: [String: String]?
    /// 599g `workspace-rules`: the paths to decide (relative to the workspace, `/workspace/…`, or the Mac
    /// path inside it), and whether to compute the warnings (git ls-files on the Mac; a moment on a big tree).
    public var paths: [String]?
    public var warnings: Bool?
    /// 608 `session-restart`: a new conversation instead of continuing the last one.
    public var fresh: Bool?

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
    /// 591: `console` — one line of a sandbox's boot console (guest-written text: display it as data).
    /// 593: `started` — a timed step began (`step` or `failed` ends it, same text); `failed` — it failed
    /// (`error` says why); `output` — a line a bake step printed (guest text, already inert).
    public enum Kind: String, Codable, Sendable { case phase, step, note, progress, connection, host, console, started, failed, output }
    public var kind: Kind
    public var time: Date
    public var sandbox: String?
    public var text: String?
    public var phase: String?
    public var milliseconds: Double?
    public var completedBytes: Int64?
    public var totalBytes: Int64?
    public var connection: ConnectionRecord?
    /// 593: a pull's layers (progress), and a failed step's reason.
    public var completedItems: Int?
    public var totalItems: Int?
    public var error: String?
    /// 594 W22: a `step`/`failed` whose text differs from the `started` it ends ("hibernating X" →
    /// "hibernated X"): the started text, so a progress view ends the right line.
    public var startedAs: String?

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
        case .transfer(let s, let done, let total, let items, let totalItems):
            self.init(kind: .progress, sandbox: sandbox, text: s, completedBytes: done, totalBytes: total)
            completedItems = items
            self.totalItems = totalItems
        case .stepStarted(let s): self.init(kind: .started, sandbox: sandbox, text: s)
        case .stepFailed(let s, let ms, let why):
            self.init(kind: .failed, sandbox: sandbox, text: s, milliseconds: ms)
            error = why
        case .output(let s): self.init(kind: .output, sandbox: sandbox, text: s)
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
                + (totalItems.map { " · \(completedItems ?? 0)/\($0) layers" } ?? "")
        case .started: return who + (text ?? "") + " …"
        case .failed: return who + "FAILED: " + (text ?? "") + (error.map { " — \($0)" } ?? "")
        case .output: return who + "  │ " + (text ?? "")
        case .phase: return who + "→ " + (text ?? phase ?? "")
        case .connection:
            guard let c = connection else { return who }
            return who + "\(c.verdict.rawValue) \(c.kind.rawValue) \(c.target)" + (c.method.map { " \($0) \(c.path ?? "")" } ?? "")
        case .note, .host, .console: return who + (text ?? "")
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
        case .hibernated: "hibernated"
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
    /// `Phase.rawValue`: off, booting, running, paused, asleep, hibernated, failed.
    public var phase: String
    public var busy: Bool
    public var cpus: Int
    /// The guest's allocation.
    public var memoryMiB: UInt64
    /// Guest RAM the Mac is charged for now: the allocation while a VM exists, less what the
    /// memory balloon handed back; 0 hibernated or off.
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
    /// 594: the workspace folder was made by this create (it did not exist).
    public var workspaceCreated: Bool?
    /// 594: the agent the sandbox runs (claude-code, pi — its image spec's name; a template's too), and
    /// what is wrong with its account for that agent ("pi can't use the account mac — choose an
    /// API-key account"); nil: it fits.
    public var agent: String?
    public var credentialProblem: String?
    /// 596: the image's base (a catalogue id, or `df-<12 hex>`), the image as a person reads it
    /// ("Python · Claude Code"), the Dockerfile it was built from, and — a Dockerfile sandbox — why a
    /// rebuild is available ("the Dockerfile changed", "a newer build is prepared — reset to take it").
    public var base: String?
    public var imageTitle: String?
    public var dockerfile: String?
    public var rebuildAvailable: String?
    /// 594 W28: its root disk comes from an image an older doz's recipe made — what that image lacks
    /// ("sudo", "package lists", …), for the notice. nil: this doz's image (or no agent image).
    public var olderImage: [String]? = nil
    /// 599g: the workspace's rules (nil: no .dozignore / .dozreadonly in its folder, or isolated).
    public var workspaceRules: WorkspaceRulesInfo? = nil
    /// 608: how /workspace reaches a RUNNING sandbox — `live` (the live view, no rules), `rules` (the view
    /// with its rules), `direct` (shared directly: workspace.view off), `next-start` (shared directly until
    /// the next start: it started before the view was on), `fallback` (the view could not start — shared
    /// directly; doctor warns). nil: isolated, or not running.
    public var workspaceView: String? = nil
    /// 594 W28: a create that used an out-of-date image says so (the CLI fills it for --json).
    public var imageNotice: String? = nil
    /// `create` with `prepare`: `prepared` (its image's preparation ran, or was joined, to the end) or
    /// `ready` (nothing to prepare: prepared before, a kept disk, a custom image). nil otherwise.
    public var imagePreparation: String? = nil

    /// 594 W28: the notice for `olderImage` (`doz ls`, the sandbox's page, create).
    public var olderImageLine: String? {
        guard let o = olderImage else { return nil }
        let lacks = o == ["its recipe changed"] ? "" : " (it lacks: \(o.joined(separator: ", ")))"
        return "made from an older \(agent ?? image) image\(lacks) — after a rebuild (doz image bake \(agent ?? image)), doz reset \(name) takes the new one: "
            + "it keeps the agent's own state (~/.claude, ~/.pi) and /workspace, and drops everything else installed or changed on its system disk"
    }

    /// 594: "isolated" — no folder of the Mac is shared (`workspace` is null).
    public var isolated: Bool { workspace == nil }

    enum CodingKeys: String, CodingKey {
        case name, image, phase, busy, cpus, memoryMiB, ramHeldMiB, memoryReturnedMiB, diskBytes, sessions, network, deniedConnections
        case workspace, createdAt, diedWithHost, account, credentialState, credentialPolicy, foreignCredentials, workspaceCreated, isolated
        case agent, credentialProblem, base, imageTitle, dockerfile, rebuildAvailable
        case olderImage, olderImageLine, imageNotice      // 594 W28
        case workspaceRules                               // 599g
        case workspaceView                                // 608
        case imagePreparation                             // create --prepare
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        image = try c.decode(String.self, forKey: .image)
        phase = try c.decode(String.self, forKey: .phase)
        busy = try c.decode(Bool.self, forKey: .busy)
        cpus = try c.decode(Int.self, forKey: .cpus)
        memoryMiB = try c.decode(UInt64.self, forKey: .memoryMiB)
        ramHeldMiB = try c.decode(UInt64.self, forKey: .ramHeldMiB)
        memoryReturnedMiB = try c.decode(UInt64.self, forKey: .memoryReturnedMiB)
        diskBytes = try c.decode(Int64.self, forKey: .diskBytes)
        sessions = try c.decodeIfPresent(Int.self, forKey: .sessions)
        network = try c.decode(String.self, forKey: .network)
        deniedConnections = try c.decodeIfPresent(Int.self, forKey: .deniedConnections)
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        diedWithHost = try c.decodeIfPresent(Bool.self, forKey: .diedWithHost)
        account = try c.decodeIfPresent(String.self, forKey: .account)
        credentialState = try c.decodeIfPresent(String.self, forKey: .credentialState)
        credentialPolicy = try c.decodeIfPresent(String.self, forKey: .credentialPolicy)
        foreignCredentials = try c.decodeIfPresent(Int.self, forKey: .foreignCredentials)
        workspaceCreated = try c.decodeIfPresent(Bool.self, forKey: .workspaceCreated)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        credentialProblem = try c.decodeIfPresent(String.self, forKey: .credentialProblem)
        base = try c.decodeIfPresent(String.self, forKey: .base)
        imageTitle = try c.decodeIfPresent(String.self, forKey: .imageTitle)
        dockerfile = try c.decodeIfPresent(String.self, forKey: .dockerfile)
        rebuildAvailable = try c.decodeIfPresent(String.self, forKey: .rebuildAvailable)
        olderImage = try c.decodeIfPresent([String].self, forKey: .olderImage)
        imageNotice = try c.decodeIfPresent(String.self, forKey: .imageNotice)
        workspaceRules = try c.decodeIfPresent(WorkspaceRulesInfo.self, forKey: .workspaceRules)
        workspaceView = try c.decodeIfPresent(String.self, forKey: .workspaceView)
        imagePreparation = try c.decodeIfPresent(String.self, forKey: .imagePreparation)
    }

    /// `workspace` is written even when null (with `isolated: true`), so a reader never has to guess.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(image, forKey: .image)
        try c.encode(phase, forKey: .phase)
        try c.encode(busy, forKey: .busy)
        try c.encode(cpus, forKey: .cpus)
        try c.encode(memoryMiB, forKey: .memoryMiB)
        try c.encode(ramHeldMiB, forKey: .ramHeldMiB)
        try c.encode(memoryReturnedMiB, forKey: .memoryReturnedMiB)
        try c.encode(diskBytes, forKey: .diskBytes)
        try c.encodeIfPresent(sessions, forKey: .sessions)
        try c.encode(network, forKey: .network)
        try c.encodeIfPresent(deniedConnections, forKey: .deniedConnections)
        try c.encode(workspace, forKey: .workspace)
        try c.encode(isolated, forKey: .isolated)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(diedWithHost, forKey: .diedWithHost)
        try c.encodeIfPresent(account, forKey: .account)
        try c.encodeIfPresent(credentialState, forKey: .credentialState)
        try c.encodeIfPresent(credentialPolicy, forKey: .credentialPolicy)
        try c.encodeIfPresent(foreignCredentials, forKey: .foreignCredentials)
        try c.encodeIfPresent(workspaceCreated, forKey: .workspaceCreated)
        try c.encodeIfPresent(agent, forKey: .agent)
        try c.encodeIfPresent(credentialProblem, forKey: .credentialProblem)
        try c.encodeIfPresent(base, forKey: .base)
        try c.encodeIfPresent(imageTitle, forKey: .imageTitle)
        try c.encodeIfPresent(dockerfile, forKey: .dockerfile)
        try c.encodeIfPresent(rebuildAvailable, forKey: .rebuildAvailable)
        try c.encodeIfPresent(workspaceRules, forKey: .workspaceRules)
        try c.encodeIfPresent(workspaceView, forKey: .workspaceView)
        try c.encodeIfPresent(olderImage, forKey: .olderImage)
        try c.encodeIfPresent(olderImageLine, forKey: .olderImageLine)
        try c.encodeIfPresent(imageNotice, forKey: .imageNotice)
        try c.encodeIfPresent(imagePreparation, forKey: .imagePreparation)
    }

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
    /// 594 (D15, D16): the environment prompt the agent gets at its next session (nil: this image
    /// runs no agent).
    public var agentPrompt: AgentPromptReport?
    /// 594: the project file it was made from (`doz_project.yaml`), when it was.
    public var project: String?
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
    /// 593 §9: this row comes from the SAVED screen (the sandbox is paused, asleep or hibernated — S5),
    /// not the guest. A shut-down sandbox has no sessions (owner, 2026-09-30).
    public var saved: Bool?
    /// 593 §9: when the session's screen was last saved, and why (`pause`, `sleep`, `hibernate`,
    /// `periodic`) — nil when it has none.
    public var savedAt: Date?
    public var savedReason: String?

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

    /// A saved screen as a row (the sandbox is not running).
    public init(saved i: SavedScreenInfo) {
        name = i.session
        pid = i.pid
        cols = i.cols
        rows = i.rows
        clients = 0
        screen = i.screen
        command = i.command
        exitCode = nil
        ended = false                  // only live sessions have a saved screen (owner, 2026-09-30)
        saved = true
        savedAt = i.savedAt
        savedReason = i.reason
    }
}

/// 593 §9 (S5): `session-screen` — a session's last saved screen.
public struct SessionScreen: Codable, Equatable, Sendable {
    public var name: String
    public var session: String
    public var savedAt: Date
    public var reason: String
    public var cols: UInt16?
    public var rows: UInt16?
    public var screen: String?
    public var command: String
    public var truncated: Bool
    /// The screen as plain text (control characters removed): safe to print.
    public var text: String
    /// The SNAPSHOT: VT bytes that redraw the screen on a blank terminal (guest bytes — render them in a
    /// terminal engine, never print them to one).
    public var vt: Data

    public init(name: String, _ s: SavedScreen) {
        self.name = name
        session = s.info.session
        savedAt = s.info.savedAt
        reason = s.info.reason
        cols = s.info.cols
        rows = s.info.rows
        screen = s.info.screen
        command = s.info.command
        truncated = s.info.truncated
        text = s.text
        vt = s.vt
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
    /// 594 W27: what had to happen first — a cold start (the sandbox was off) or a wake/resume — and
    /// how long it took (nil: it was already running).
    public var started: Bool? = nil
    public var woke: Bool? = nil
    public var bootMilliseconds: Double? = nil
}

/// `open-session`.
public struct SessionOpened: Codable, Equatable, Sendable {
    public var name: String
    public var session: String
    public var created: Bool
    /// 594 (W17): the sandbox's default session (what `doz attach NAME` attaches to).
    public var defaultSession: String? = nil
    /// 594 W27: as `ExecOutput` — a cold start or a wake before the session opened.
    public var started: Bool? = nil
    public var woke: Bool? = nil
    public var bootMilliseconds: Double? = nil
    /// 599 (594.B3): the session runs inside tmux (`sessions.tmux`).
    public var tmux: Bool? = nil
    /// 599: something the person should know about how it opened (tmux asked for but not in the image).
    public var notice: String? = nil
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
    /// 594: a built-in image is prepared for THIS build (its bake key, the kernel, the guest init
    /// disk) — `baked` also counts an older build's bake. nil for a template.
    public var current: Bool?
    /// 594 (an agent image): the agent version a new sandbox gets now (the newest prepared for this
    /// build, else the newest baked); the setting (`latest` or exact); the registry's latest as last
    /// asked; a newer version the settings want that is not prepared yet, and whether it is being prepared.
    public var version: String?
    public var versionSetting: String?
    public var latest: String?
    public var latestCheckedAt: Date?
    public var available: String?
    public var preparing: Bool?
    /// 594: the agent a sandbox of this image runs (claude-code, pi; a template's: its image's); nil: none.
    public var agent: String?
    /// 596: the image's base (catalogue id or `df-<12 hex>`), "Python · Claude Code", its Dockerfile,
    /// and a newer base than it was made from (offered — never rebuilt by itself).
    public var base: String?
    public var title: String?
    public var dockerfile: String?
    public var baseUpdate: String?
    /// 594 W28: baked by an OLDER doz's recipe — what this doz's adds ("sudo", "package lists", or
    /// "its recipe changed"). nil: this doz's recipe (or not baked). It is used as it is until the user
    /// rebuilds (`doz image bake NAME`) — never rebuilt by itself.
    public var olderRecipe: [String]?

    /// 594 W28: `status` and `standing` filled in (they travel in --json and to the web UI).
    public var status: String?
    public var standing: String?
    public mutating func fillStanding() {
        status = computedStatus
        standing = standingLine
    }

    /// 594 W28: the image's standing in one word — `up to date`, `older recipe`, `update available`,
    /// `not prepared`, `preparing`. W32: never nil — a template (a saved disk, never rebuilt) is `up to date`.
    public var computedStatus: String? {
        guard kind == "builtin" else { return "up to date" }
        if preparing == true { return "preparing" }
        if !baked { return "not prepared" }
        if olderRecipe != nil { return "older recipe" }
        if available != nil { return "update available" }
        return "up to date"
    }

    /// 594 W28: what to say about it — nil when up to date.
    public var standingLine: String? {
        var parts: [String] = []
        if let o = olderRecipe {
            parts.append(o == ["its recipe changed"] ? "prepared by an older doz — its recipe changed"
                                                     : "prepared by an older doz — this doz's image adds: \(o.joined(separator: ", "))")
        }
        if let a = available, let v = version {
            parts.append("\(AgentImages.agentName(name) ?? name) \(a) is available (image has \(v))")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "; ") + " — rebuild when ready: doz image bake \(name) (existing sandboxes keep their disks)"
    }

    /// 594: "claude-code 2.1.227 (2.1.230 available — preparing)", "claude-code 2.1.285 (latest)",
    /// "pi 0.84.1 (pinned: images.pi_version)" — nil for an image with no agent.
    public var versionLine: String? {
        guard versionSetting != nil else { return nil }
        guard let v = version else {
            let what = available ?? (versionSetting == "latest" ? "latest" : versionSetting!)
            return "\(name) \(what) when prepared" + (preparing == true ? " — preparing" : "")
        }
        var s = "\(name) \(v)"
        if let a = available {
            s += " (\(a) available" + (preparing == true ? " — preparing)" : ")")
        } else if versionSetting == "latest" {
            s += v == latest ? " (latest)" : ""
        } else {
            s += " (pinned)"
        }
        return s
    }
}

/// `key ls` (never the secret).
public struct CredentialRow: Codable, Equatable, Sendable {
    public var binding: String
    public var hosts: [String]
    public var set: Bool
    /// `stdin` or `keychain:<service>`, or (588) `account:<name>`.
    public var source: String?
    /// 588: the account behind it, its state, when it expires, the foreign-credential policy, and
    /// every credential the guest used that doz never issued (fingerprints, never values).
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
    /// 591: the program file the host runs from; how it changed since the host started
    /// (`overwritten` | `replaced` | `removed`), and what to do about it. nil: unchanged.
    public var executable: String?
    public var executableChange: String?
    public var executableNote: String?
    /// 593: the host's parent (1 = launchd: fully detached, as every auto-started host must be — never in
    /// a client's process tree), its session id, and whether the launcher started it (false: someone ran
    /// `doz host start --foreground` themselves, on purpose).
    public var parentPid: Int32?
    public var sessionID: Int32?
    public var launchedDetached: Bool?
    /// EXPERIMENTAL (604): the Mac app macOS asks about the microphone for, for this host's audio sandboxes
    /// (its responsible app).
    public var microphoneApp: String?
}
