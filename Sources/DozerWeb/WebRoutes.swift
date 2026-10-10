import Foundation

/// The CLOSED route table (590). Every route is a case; a path that does not parse to one is a 404
/// before any session is looked at or any host call is made. Identifiers are allowlisted here (a
/// sandbox name is the library's own rule: 1–40 of [a-z0-9-], not starting with `-`), so no
/// request text reaches the host that the host would not accept from the CLI.
///
/// The unsafe routes are the session's own (bootstrap, renew, sign out) and, since phase 2, the
/// typed actions (`WebAction`: a closed enum, each exactly one `HostOp`), the policy preview and
/// Terminal.app. There is deliberately no generic command, exec, file-read, URL-open, proxy or PTY
/// route — and none may be added: a new capability is a new TYPED case. 591's terminal socket is
/// not a PTY route: it ATTACHES to a session the host already holds (the CLI's `attach`), only with
/// a one-use ticket minted by a CSRF-checked POST, and a new session is still the typed
/// `open-session` action.
public enum WebRoute: Equatable, Sendable {
    // static
    case index
    case asset(String)
    /// 591: GET /terminal-frame — the terminal engine's document, loaded only into a sandboxed,
    /// opaque-origin iframe of the page (its own CSP; `frame-ancestors 'self'`).
    case terminalFrame
    /// 605: GET /offline — the page the service worker shows while doz ui is down (no session, no data).
    case offline
    /// 605: GET /sw.js — the service worker (its own CSP; it caches only the offline page and its files).
    case serviceWorker
    // session
    case sessionBootstrap          // POST   /api/v1/session   (Authorization: Bearer <capability>)
    case sessionInfo               // GET    /api/v1/session
    case sessionRenew              // POST   /api/v1/session/renew
    case sessionEnd                // DELETE /api/v1/session
    // read-only views
    case overview                  // GET /api/v1/overview
    case sandbox(String)           // GET /api/v1/sandboxes/{name}
    case sandboxSessions(String)   // GET /api/v1/sandboxes/{name}/sessions
    case sandboxNetwork(String)    // GET /api/v1/sandboxes/{name}/network
    case sandboxTools(String)      // GET /api/v1/sandboxes/{name}/tools (599h: the tools layer — plan + last apply)
    case images                    // GET /api/v1/images
    case imageTree                 // GET /api/v1/images/tree   (593: the lineage, with sizes)
    case accounts                  // GET /api/v1/accounts
    case metrics(WebMetricsQuery)  // GET /api/v1/metrics?image=&days=&steps=
    case metricsCSV(WebMetricsQuery) // GET /api/v1/metrics.csv?…  (a download)
    case events                    // GET /api/v1/events
    case doctor                    // GET /api/v1/doctor
    case stream                    // GET /api/v1/stream   (server-sent events)
    // phase 2 — actions (every one: exact Origin + X-Doz-CSRF + a JSON body)
    case actions                   // POST /api/v1/actions   ({"action": <closed enum>, …} → one HostOp)
    case operations                // GET  /api/v1/operations (the UI's recent operations)
    case policyPreview(String)     // POST /api/v1/sandboxes/{name}/network/preview (changes nothing)
    case terminal(String)          // POST /api/v1/sandboxes/{name}/terminal (Terminal.app, fixed script)
    // 591 — browser terminals (591.01-DESIGN.md §4): a one-use ticket, then the socket it opens.
    case terminalTicket(String)    // POST /api/v1/sandboxes/{name}/terminal-ticket (CSRF; {mode, session?, cols?, rows?})
    case terminalSocket(String)    // GET  /api/v1/sandboxes/{name}/terminal-socket (WebSocket upgrade + the ticket)
    // 591 settings — doz.toml: the report, and ONE typed change (closed schema, CSRF).
    case settings                  // GET  /api/v1/settings
    case settingsChange            // POST /api/v1/settings  ({key, value} | {key, reset: true})
    // 593 §9 — session memory (WebSessionMemory.swift): a saved screen (read), the terminal layout
    // (read, and ONE typed CSRF-checked change).
    case sessionScreen(String, String)  // GET  /api/v1/sandboxes/{name}/sessions/{session}/screen
    case terminalLayout(String)         // GET  /api/v1/sandboxes/{name}/layout
    case terminalLayoutSet(String)      // POST /api/v1/sandboxes/{name}/layout  ({split, focusedPane, panes})
    // 593 — the Boot log (WebBootLogs.swift): the kept boots, and one of them rendered (read-only).
    case bootLogs(String)               // GET  /api/v1/sandboxes/{name}/boots
    case bootLog(String, Int)           // GET  /api/v1/sandboxes/{name}/boots/{n}   (1 = the latest; 1–99)
    // 594 — onboarding: the wizard's facts; the settings file + prompt template written only when
    // missing (CSRF, strict {defaultImage, account}); the host's image preparations.
    case onboarding                // GET  /api/v1/onboarding
    case onboardingConfig          // POST /api/v1/onboarding/config
    case preparations              // GET  /api/v1/preparations
    // 594 (owner ruling) — an account from a key or a setup token typed in a masked field. NOT an
    // action: an action is an operation (a title, progress, an outcome on every page); this is one
    // synchronous request whose body alone carries the secret, allowed while ui.allow_secret_entry.
    case accountAdd                // POST /api/v1/accounts  ({name, kind, secret, plan?})
    // 594 (owner ruling: "allow sandbox keys in the browser also") — a sandbox's own Anthropic key,
    // what `doz key set NAME --anthropic` does; same setting, same guarantees as accountAdd.
    case sandboxKey(String)        // POST /api/v1/sandboxes/{name}/key  ({secret})
    // 594 (owner: "an easier way to pick a workspace folder"): a new sandbox's defaults and what a
    // typed folder would do (changes nothing); and the MAC's own folder picker (one at a time; the
    // answer is a path string, nothing else).
    case workspaceCheck            // POST /api/v1/workspace/check   ({image?, name?, path?})
    case workspaceChoose           // POST /api/v1/workspace/choose  ({start?})
    // 599c — Quick add: what one click would make (changes nothing; POST + CSRF like the check), and
    // the Settings page's Choose… for defaults.projects_dir: the Mac's folder picker, whose answer the
    // SERVER writes — the browser never names the path (the setting stays read-only to `settings`).
    case quickAdd                  // POST /api/v1/quick-add  ({image?, isolated?})
    case projectsDirChoose         // POST /api/v1/settings/projects-dir/choose  ({})
    // 599f — the New Sandbox wizard's project file (WebProject.swift): read (changes nothing), the exact
    // file it would write and its diff (changes nothing), and the write (an existing file only by its digest).
    case projectOpen               // POST /api/v1/project/open     ({folder})
    case projectPreview            // POST /api/v1/project/preview  ({folder, form, explicit})
    case projectWrite              // POST /api/v1/project/write    ({folder, form, explicit, replace?})
    // 595 — Resources: the account of everything Dozer uses (read), and what a deletion WOULD do
    // (changes nothing; POST + CSRF because it carries ids). Deleting is the typed actions
    // `resources-rm` / `resources-clean`; choosing the kernel is `resources-kernel`.
    case resources                 // GET  /api/v1/resources
    case resourcesPreview          // POST /api/v1/resources/preview  ({ids} | {clean: true})
    // 596 — base images (WebBases.swift): the catalogue + Apple's container tool (read); the Mac's
    // file picker for a Dockerfile (one at a time; the answer is a path and its folder).
    case bases                     // GET  /api/v1/bases
    case dockerfileChoose          // POST /api/v1/dockerfile/choose  ({start?})
    // 599e — Access: each credential's choice and last confirmation (read, never starts a host); a live
    // check (changes no setting; POST + CSRF: it carries choices to confirm before they are written);
    // the default GitHub key (a secret in the body alone, while ui.allow_secret_entry, like accountAdd).
    case access                    // GET  /api/v1/access
    case accessCheck               // POST /api/v1/access/check  ({items?, choices?: {github?, githubSource?, ssh?}})
    case accessGithubKey           // POST /api/v1/access/github-key  ({secret} | {remove: true})
    // 606 — doz serve: this browser and the server (read), the devices and the recent remote activity (read),
    // a new invite (link + code + QR), a device revoked or renamed; and the doctor's probe (no session: a one-use
    // token doz serve issued over serve.sock — answered only by doz serve). In doz ui (the Mac) the device routes
    // are answered through serve.sock.
    // The optional sign-up (the setup wizard's Stay in touch): an email and its interests, handed to the official
    // build's package (`Usage.signup`). Never logged, never echoed; a build from the repository answers 404.
    case signup                    // POST /api/v1/signup  ({email, interests})
    case serveStatus               // GET  /api/v1/serve
    case serveDevices              // GET  /api/v1/serve/devices
    case serveShare                // POST /api/v1/serve/share  ({})
    case serveRevoke(String)       // POST /api/v1/serve/devices/{id}/revoke  ({})
    case serveRename(String)       // POST /api/v1/serve/devices/{id}/name  ({name})
    case serveProbe                // GET  /api/v1/serve/probe  (X-Doz-Probe: <one-use token>)

    public var isStatic: Bool {
        switch self { case .index, .asset, .terminalFrame, .offline, .serviceWorker: true; default: false }
    }

    /// Parse a request target. Only the metrics routes read a query string (three keys, each by its
    /// rule — anything else there is not a route); the others ignore it. Anything unusual in the
    /// path — percent-encoding, dot segments, a trailing slash, a double slash — is not a route.
    public static func parse(method: WebHTTPMethod, target: String) -> WebRoute? {
        var path = target
        var query: String?
        if let q = path.firstIndex(of: "?") {
            query = String(path[path.index(after: q)...])
            path = String(path[..<q])
        }
        guard path.hasPrefix("/"), !path.contains("%"), !path.contains("//"), path.count <= 256 else { return nil }
        if path == "/" { return method.isSafe ? .index : nil }
        if path == WebAssets.frameDocument { return method.isSafe ? .terminalFrame : nil }
        if path == WebAssets.offlineDocument { return method.isSafe ? .offline : nil }
        if path == WebAssets.serviceWorker { return method.isSafe ? .serviceWorker : nil }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        if parts.count == 2, parts[0] == "assets" { return method.isSafe ? .asset(path) : nil }
        // 607: the page script's modules, one directory per layer — /assets/app/<dom|core|components|views>/<file>.
        // (Served only when the manifest lists the exact path, like every asset.)
        if parts.count == 4, parts[0] == "assets", parts[1] == "app", WebAssets.moduleLayers.contains(parts[2]) {
            return method.isSafe ? .asset(path) : nil
        }
        guard parts.count >= 3, parts[0] == "api", parts[1] == "v1" else { return nil }
        let rest = Array(parts.dropFirst(2))
        switch (method, rest.count) {
        case (.post, 1) where rest[0] == "session": return .sessionBootstrap
        case (.get, 1) where rest[0] == "session": return .sessionInfo
        case (.delete, 1) where rest[0] == "session": return .sessionEnd
        case (.post, 2) where rest == ["session", "renew"]: return .sessionRenew
        case (.post, 1) where rest[0] == "actions": return .actions
        case (.post, 1) where rest[0] == "settings": return .settingsChange
        case (.post, 2) where rest == ["onboarding", "config"]: return .onboardingConfig
        case (.post, 1) where rest[0] == "accounts": return .accountAdd
        case (.post, 2) where rest == ["workspace", "check"]: return .workspaceCheck
        case (.post, 2) where rest == ["workspace", "choose"]: return .workspaceChoose
        case (.post, 1) where rest[0] == "quick-add": return .quickAdd
        case (.post, 2) where rest == ["project", "open"]: return .projectOpen
        case (.post, 2) where rest == ["project", "preview"]: return .projectPreview
        case (.post, 2) where rest == ["project", "write"]: return .projectWrite
        case (.post, 3) where rest == ["settings", "projects-dir", "choose"]: return .projectsDirChoose
        case (.post, 2) where rest == ["resources", "preview"]: return .resourcesPreview
        case (.post, 2) where rest == ["dockerfile", "choose"]: return .dockerfileChoose
        case (.post, 2) where rest == ["access", "check"]: return .accessCheck
        case (.post, 2) where rest == ["access", "github-key"]: return .accessGithubKey
        case (.post, 1) where rest[0] == "signup": return .signup
        case (.post, 2) where rest == ["serve", "share"]: return .serveShare
        case (.post, 4) where rest[0] == "serve" && rest[1] == "devices" && isDeviceID(rest[2]) && rest[3] == "revoke": return .serveRevoke(rest[2])
        case (.post, 4) where rest[0] == "serve" && rest[1] == "devices" && isDeviceID(rest[2]) && rest[3] == "name": return .serveRename(rest[2])
        case (.post, 4) where rest[0] == "sandboxes" && isSandboxName(rest[1]) && rest[2] == "network" && rest[3] == "preview":
            return .policyPreview(rest[1])
        case (.post, 3) where rest[0] == "sandboxes" && isSandboxName(rest[1]) && rest[2] == "terminal":
            return .terminal(rest[1])
        case (.post, 3) where rest[0] == "sandboxes" && isSandboxName(rest[1]) && rest[2] == "terminal-ticket":
            return .terminalTicket(rest[1])
        case (.post, 3) where rest[0] == "sandboxes" && isSandboxName(rest[1]) && rest[2] == "key":
            return .sandboxKey(rest[1])
        case (.post, 3) where rest[0] == "sandboxes" && isSandboxName(rest[1]) && rest[2] == "layout":
            return .terminalLayoutSet(rest[1])
        default: break
        }
        guard method == .get else { return nil }
        switch rest.count {
        case 1:
            switch rest[0] {
            case "overview": return .overview
            case "images": return .images
            case "accounts": return .accounts
            case "metrics": return WebMetricsQuery.parse(query).map(WebRoute.metrics)
            case "metrics.csv": return WebMetricsQuery.parse(query).map(WebRoute.metricsCSV)
            case "operations": return .operations
            case "events": return .events
            case "doctor": return .doctor
            case "stream": return .stream
            case "settings": return .settings
            case "onboarding": return .onboarding
            case "preparations": return .preparations
            case "resources": return .resources
            case "bases": return .bases
            case "access": return .access
            case "serve": return .serveStatus
            default: return nil
            }
        case 2 where rest == ["images", "tree"]:
            return .imageTree
        case 2 where rest == ["serve", "devices"]:
            return .serveDevices
        case 2 where rest == ["serve", "probe"]:
            return .serveProbe
        case 2 where rest[0] == "sandboxes" && isSandboxName(rest[1]):
            return .sandbox(rest[1])
        case 3 where rest[0] == "sandboxes" && isSandboxName(rest[1]):
            switch rest[2] {
            case "sessions": return .sandboxSessions(rest[1])
            case "network": return .sandboxNetwork(rest[1])
            case "tools": return .sandboxTools(rest[1])
            case "terminal-socket": return .terminalSocket(rest[1])
            case "layout": return .terminalLayout(rest[1])
            case "boots": return .bootLogs(rest[1])
            default: return nil
            }
        case 4 where rest[0] == "sandboxes" && isSandboxName(rest[1]) && rest[2] == "boots":
            // 1–99, digits only (no sign, no leading zero).
            guard (1...2).contains(rest[3].count), rest[3].first != "0", rest[3].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(rest[3]) else { return nil }
            return .bootLog(rest[1], n)
        case 5 where rest[0] == "sandboxes" && isSandboxName(rest[1]) && rest[2] == "sessions" && isSessionName(rest[3]) && rest[4] == "screen":
            return .sessionScreen(rest[1], rest[3])
        default:
            return nil
        }
    }

    /// The host's session-name rule (`GuestCommand.validateSessionName`): 1–64 of [A-Za-z0-9._-], not
    /// starting with `.` (so never `.` or `..` either).
    public static func isSessionName(_ s: String) -> Bool {
        (1...64).contains(s.count) && s.first != "."
            && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// 606: an action's name as the audit log may write it — 1–40 of [a-z-].
    public static func isActionWord(_ s: String) -> Bool {
        (1...40).contains(s.count) && s.allSatisfy { ("a"..."z").contains($0) || $0 == "-" }
    }

    /// 606: a device's id — 6 of [a-z0-9].
    public static func isDeviceID(_ s: String) -> Bool {
        s.count == 6 && s.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    /// The library's sandbox-name rule (`SandboxSpec.validate`).
    public static func isSandboxName(_ s: String) -> Bool {
        (1...40).contains(s.count) && s.first != "-" && s.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}
