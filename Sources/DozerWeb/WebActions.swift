import Foundation
import DozerKit
import DozerHost

/// 590 phase 2 — everything the UI can DO, as a closed enum. Each case maps to exactly ONE `HostOp`
/// (the same operation the CLI sends; the web layer adds none of its own), with every field
/// validated here before the host sees it. The body of `POST /api/v1/actions` is decoded STRICTLY:
/// an unknown action, an unknown field, a wrong type or a value outside its rule is a 400 — nothing
/// is passed through.
///
/// Not here, on purpose: `exec` and `attach` (a terminal is Terminal.app, `WebTerminal`), `key set`
/// and `account add` (no ACTION carries a secret — 590's D3; since 594 an account's key or token has
/// its own typed route, `POST /api/v1/accounts`, gated by `ui.allow_secret_entry`), `host stop`.
public enum WebAction: Equatable, Sendable {
    case create(name: String, options: CreateOptions)
    /// start, wake, pause, resume, sleep, hibernate, shutdown, reset, rm.
    case lifecycle(HostOp, name: String)
    /// A session: the image's own when `argv` is nil, else a new one running `argv` (detached — no
    /// shell in front, inside the sandbox only).
    case openSession(name: String, session: String?, argv: [String]?)
    case pointTake(name: String, point: String?, note: String?)
    case pointRevert(name: String, point: String)
    case pointFork(name: String, point: String, newName: String)
    case pointRemove(name: String, point: String)
    case pointSaveImage(name: String, point: String?, image: String, note: String?)
    /// 593: a template (root disk only) from the current disk (any phase) or a restore point.
    case templateCreate(name: String, point: String?, image: String, note: String?)
    /// 593: a new sandbox from this one's disk, with overrides; the state disk fresh unless copied.
    case duplicate(name: String, newName: String, point: String?, options: DuplicateOptions)
    case imageBake(String)
    case imageRemove(String)
    case netPolicy(name: String, edit: WebPolicyEdit)
    case keyPolicy(name: String, policy: String)
    case keyRemove(name: String, binding: String)
    case accountUse(name: String, account: String)
    case accountDefault(String)
    case accountKeepalive(Bool)
    case accountVerify(String)
    case accountRemove(String)
    /// 594: onboard — prepare these built-in images in the host (in the background: the action ends
    /// at once; the preparation shows in the wizard and in Operations) and record the onboarding.
    case onboard([String])
    /// 594: cancel the preparation of these images (all running ones when empty).
    case prepareCancel([String])
    /// 595 (R3): delete these resources (ids as the Resources page lists them) — one host operation,
    /// serialised with the lifecycle. A plain confirmation on the page (owner: no typed names).
    case resourcesRemove([String])
    /// 595 (R4): Clean up — the re-creatable, unused set.
    case resourcesClean
    /// 595 (R5): the kernel NEW sandboxes boot (`kernel:<version>` or `pinned`).
    case resourcesKernel(String)
    /// 594 W18: "Start host" — the host's `ping`, sent with autostart as every action is: a host
    /// starts the normal detached way (`HostLauncher`), exactly as the CLI's first command starts one.
    /// Starting is all it does (`host stop` stays out of the browser).
    case hostStart
    /// 594 W20: "Restart host" — the CLI's `host stop`, then a host of this UI's build (`HostLauncher`),
    /// and ONLY while the running host is an OLDER build than the UI (`HostWebData.restartHost`
    /// refuses anything else). The one way `host-stop` is reachable from the browser.
    case hostRestart
    /// 596 (B7): start Apple's container services (`builder-start`) — the page has said what it does
    /// (launchd services, its kernel) and the person pressed the button; that is the consent.
    case builderStart
    /// 596 (B7): install Apple's container tool on demand (`builder-install`: its signed package,
    /// pinned and sha256-checked, opened in macOS Installer — the person approves it there; never sudo).
    case builderInstall
    /// 599h: set the sandbox's tools layer up again now (the New Sandbox wizard's Retry) — `tools-apply`.
    case toolsApply(String)
    /// 608: End session / Restart session (a terminal tab's menu, the inspector's Sessions tab) — the CLI's
    /// `doz sessions end|restart`; lifecycle-class, so a remote (doz serve) browser may use them too.
    case sessionEnd(name: String, session: String)
    case sessionRestart(name: String, session: String, fresh: Bool)

    public static let lifecycleOps: [String: HostOp] = [
        "start": .start, "wake": .wake, "pause": .pause, "resume": .resume, "sleep": .sleep, "hibernate": .hibernate,
        "shutdown": .shutdown, "reset": .reset, "rm": .rm,
    ]

    /// The one host operation this action is.
    public var hostOp: HostOp { hostRequest.op }

    /// The sandbox it acts on (progress is shown in its row).
    public var sandbox: String? {
        switch self {
        case .create(let n, _), .lifecycle(_, let n), .openSession(let n, _, _), .pointTake(let n, _, _), .pointRevert(let n, _),
             .pointFork(let n, _, _), .pointRemove(let n, _), .pointSaveImage(let n, _, _, _), .netPolicy(let n, _), .keyPolicy(let n, _),
             .keyRemove(let n, _), .accountUse(let n, _), .templateCreate(let n, _, _, _), .duplicate(let n, _, _, _), .toolsApply(let n),
             .sessionEnd(let n, _), .sessionRestart(let n, _, _):
            return n
        case .imageBake, .imageRemove, .accountDefault, .accountKeepalive, .accountVerify, .accountRemove, .onboard, .prepareCancel,
             .resourcesRemove, .resourcesClean, .resourcesKernel, .hostStart, .hostRestart, .builderStart, .builderInstall:
            return nil
        }
    }

    /// Destructive actions carry `confirm`, which must equal this (the page fills it only from a
    /// name the person typed).
    public var confirmationTarget: String? {
        switch self {
        // Shut Down keeps the disk (owner, 591: a plain confirmation, not a typed name).
        case .lifecycle(let op, let n) where [.reset, .rm].contains(op): n
        case .pointRevert(let n, _), .pointRemove(let n, _): n
        case .imageRemove(let i): i
        case .accountRemove(let a): a
        default: nil
        }
    }

    /// Two actions with the same key must not run at once: the same operation on the same sandbox
    /// (and session, point, image or account). A double-clicked "open session" is one operation.
    public var dedupeKey: String {
        let r = hostRequest
        return [r.op.rawValue, r.name ?? "", r.session ?? "", r.point ?? r.pointName ?? "", r.image ?? "", r.account ?? "", r.newName ?? "",
                r.ids?.joined(separator: ",") ?? "", r.kernel ?? ""].joined(separator: "|")
    }

    /// A short label for the progress line ("hibernate lab1").
    public var label: String {
        switch self {
        case .resourcesRemove(let ids): return ids.count == 1 ? "delete \(ids[0])" : "delete \(ids.count) resources"
        case .resourcesClean: return "clean up"
        case .resourcesKernel(let k): return "use \(k) for new sandboxes"
        case .hostStart: return "host-start"
        case .hostRestart: return "host-restart"
        case .builderStart: return "start Apple's container services"
        case .builderInstall: return "install Apple's container tool"
        case .toolsApply(let n): return "set up the tools of \(n)"
        case .sessionEnd(let n, let s): return "end session \(s) in \(n)"
        case .sessionRestart(let n, let s, _): return "restart session \(s) in \(n)"
        default: break
        }
        let r = hostRequest
        return [r.op.rawValue, r.name ?? r.image ?? r.account].compactMap { $0 }.joined(separator: " ")
    }

    public var hostRequest: HostRequest {
        switch self {
        case .create(let n, let o):
            var r = HostRequest(.create, name: n)
            r.create = o
            return r
        case .lifecycle(let op, let n):
            return HostRequest(op, name: n)
        case .openSession(let n, let s, let argv):
            var r = HostRequest(.openSession, name: n)
            r.session = s
            r.argv = argv
            r.wake = true
            return r
        case .pointTake(let n, let p, let note):
            var r = HostRequest(.pointTake, name: n)
            r.pointName = p
            r.note = note
            return r
        case .pointRevert(let n, let p):
            var r = HostRequest(.pointRevert, name: n)
            r.point = p
            return r
        case .pointFork(let n, let p, let new):
            var r = HostRequest(.pointFork, name: n)
            r.point = p
            r.newName = new
            return r
        case .pointRemove(let n, let p):
            var r = HostRequest(.pointRm, name: n)
            r.point = p
            return r
        case .pointSaveImage(let n, let p, let image, let note):
            var r = HostRequest(.pointSaveImage, name: n)
            r.point = p
            r.image = image
            r.note = note
            return r
        case .templateCreate(let n, let p, let image, let note):
            var r = HostRequest(.templateCreate, name: n)
            r.point = p
            r.image = image
            r.note = note
            return r
        case .duplicate(let n, let new, let p, let o):
            var r = HostRequest(.duplicate, name: n)
            r.newName = new
            r.point = p
            r.duplicate = o
            return r
        case .imageBake(let i):
            var r = HostRequest(.imageBake)
            r.image = i
            return r
        case .imageRemove(let i):
            var r = HostRequest(.imageRm)
            r.image = i
            return r
        case .netPolicy(let n, let e):
            return e.request(n)
        case .keyPolicy(let n, let p):
            var r = HostRequest(.keyPolicy, name: n)
            r.policy = p
            return r
        case .keyRemove(let n, let b):
            var r = HostRequest(.keyRm, name: n)
            r.binding = b
            return r
        case .accountUse(let n, let a):
            var r = HostRequest(.accountUse, name: n)
            r.account = a
            return r
        case .accountDefault(let a):
            var r = HostRequest(.accountDefault)
            r.account = a
            return r
        case .accountKeepalive(let on):
            var r = HostRequest(.accountKeepalive)
            r.enabled = on
            return r
        case .accountVerify(let a):
            var r = HostRequest(.accountVerify)
            r.account = a
            r.verify = true
            return r
        case .accountRemove(let a):
            var r = HostRequest(.accountRemove)
            r.account = a
            return r
        case .onboard(let images):
            var r = HostRequest(.onboard)
            r.images = images
            r.follow = false
            r.requestedBy = "doz ui"
            return r
        case .prepareCancel(let images):
            var r = HostRequest(.prepareCancel)
            r.images = images.isEmpty ? nil : images
            return r
        case .resourcesRemove(let ids):
            var r = HostRequest(.resourcesRemove)
            r.ids = ids
            return r
        case .resourcesClean:
            return HostRequest(.resourcesClean)
        case .resourcesKernel(let k):
            var r = HostRequest(.resourcesKernel)
            r.kernel = k
            return r
        case .hostStart:
            return HostRequest(.ping)
        case .hostRestart:
            return HostRequest(.hostStop)
        case .builderStart:
            var r = HostRequest(.builderStart)
            r.requestedBy = "doz ui"
            return r
        case .builderInstall:
            var r = HostRequest(.builderInstall)
            r.requestedBy = "doz ui"
            return r
        case .toolsApply(let n):
            return HostRequest(.toolsApply, name: n)
        case .sessionEnd(let n, let s):
            var r = HostRequest(.sessionEnd, name: n)
            r.session = s
            return r
        case .sessionRestart(let n, let s, let fresh):
            var r = HostRequest(.sessionRestart, name: n)
            r.session = s
            r.fresh = fresh ? true : nil
            return r
        }
    }

    // MARK: strict decoding

    public struct Invalid: Error, Equatable, Sendable {
        public let message: String
        init(_ m: String) { message = m }
    }

    /// Fields each action may carry (besides `action`).
    static let fields: [String: Set<String>] = {
        var f: [String: Set<String>] = [
            "create": ["sandbox", "image", "cpus", "memoryMiB", "workspace", "isolated", "network", "subnet", "account", "rebuild", "dockerfile", "permissions", "sites"],
            "open-session": ["sandbox", "session", "argv"],
            "point-take": ["sandbox", "point", "note"],
            "point-revert": ["sandbox", "point", "confirm"],
            "point-fork": ["sandbox", "point", "newName"],
            "point-rm": ["sandbox", "point", "confirm"],
            "point-save-image": ["sandbox", "point", "image", "note"],
            "template-create": ["sandbox", "point", "image", "note"],
            "duplicate": ["sandbox", "newName", "point", "workspace", "isolated", "cpus", "memoryMiB", "network", "account", "copyState"],
            "image-bake": ["image"],
            "image-rm": ["image", "confirm"],
            "net-policy": ["sandbox", "preset", "allow", "deny", "remove", "grant", "revoke"],
            "key-policy": ["sandbox", "policy"],
            "key-rm": ["sandbox", "binding"],
            "account-use": ["sandbox", "account"],
            "account-default": ["account"],
            "account-keepalive": ["enabled"],
            "account-verify": ["account"],
            "account-rm": ["account", "confirm"],
            "onboard": ["images"],
            "prepare-cancel": ["images"],
            "resources-rm": ["ids"],
            "resources-clean": [],
            "resources-kernel": ["kernel"],
            "host-start": [],
            "host-restart": [],
            "builder-start": [],
            "builder-install": [],
            "tools-apply": ["sandbox"],
            "session-end": ["sandbox", "session"],
            "session-restart": ["sandbox", "session", "fresh"],
        ]
        for (verb, op) in lifecycleOps { f[verb] = [.reset, .rm].contains(op) ? ["sandbox", "confirm"] : ["sandbox"] }
        return f
    }()

    public static var actionNames: [String] { fields.keys.sorted() }

    /// Decode a request body. Throws `Invalid` with a fixed message (the value is never echoed).
    public static func decode(_ body: Data) throws -> WebAction {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw Invalid("the body must be a JSON object")
        }
        guard let verb = d["action"] as? String, let allowed = fields[verb] else { throw Invalid("unknown action") }
        let extra = Set(d.keys).subtracting(allowed).subtracting(["action"])
        guard extra.isEmpty else { throw Invalid("unexpected field(s) for \(verb): \(extra.sorted().joined(separator: ", "))") }
        let f = Fields(d)
        let a: WebAction
        switch verb {
        case "create":
            var o = CreateOptions(image: try f.image("image"), cpus: try f.int("cpus", 1...64), memoryMiB: try f.int("memoryMiB", 256...262_144).map(UInt64.init),
                                  workspace: try f.workspace("workspace"), network: try f.oneOf("network", ["agent", "bake", "locked", "open", "nat", "none"]),
                                  subnet: try f.subnet("subnet"), account: try f.accountRef("account", allowDefault: true))
            o.isolated = try f.flag("isolated")
            // 594 W28: the New Sandbox form's "Rebuild first" (an out-of-date image is otherwise used as it is).
            o.rebuild = try f.flag("rebuild")
            // 597 (P4): the form's switches — exactly these permissions; its sites on top.
            if d["permissions"] != nil, !(d["permissions"] is NSNull) {
                let p = try f.permissionWords("permissions")
                guard !p.contains(where: { $0.hasPrefix("site:") || $0 == "install" }) else { throw Invalid("permissions: permission ids (sites go in sites)") }
                o.permissions = p
            }
            let sites = try f.permissionWords("sites")
            guard sites.allSatisfy({ $0.hasPrefix("site:") }) else { throw Invalid("sites: site:HOST each") }
            if !sites.isEmpty { o.allow = sites }
            // 596 (B6): a Dockerfile base — an absolute path (the host checks the file); the image then
            // only carries the agent (claude-code, pi or lab = none).
            if let df = try f.dockerfile("dockerfile") {
                guard ["claude-code", "pi", "codex", "lab"].contains(o.image) else { throw Invalid("dockerfile: goes with image claude-code, pi, codex or lab (the agent)") }
                o.dockerfile = df
            }
            guard !(o.isolated == true && o.workspace != nil) else { throw Invalid("isolated: or a workspace, not both") }
            a = .create(name: try f.sandbox("sandbox"), options: o)
        case "open-session":
            a = .openSession(name: try f.sandbox("sandbox"), session: try f.session("session"), argv: try f.argv("argv"))
        case "point-take":
            a = .pointTake(name: try f.sandbox("sandbox"), point: try f.pointRef("point"), note: try f.note("note"))
        case "point-revert":
            a = .pointRevert(name: try f.sandbox("sandbox"), point: try f.required(f.pointRef("point"), "point"))
        case "point-fork":
            a = .pointFork(name: try f.sandbox("sandbox"), point: try f.required(f.pointRef("point"), "point"), newName: try f.sandbox("newName"))
        case "point-rm":
            a = .pointRemove(name: try f.sandbox("sandbox"), point: try f.required(f.pointRef("point"), "point"))
        case "point-save-image":
            a = .pointSaveImage(name: try f.sandbox("sandbox"), point: try f.pointRef("point"), image: try f.customImage("image"), note: try f.note("note"))
        case "template-create":
            let image = try f.customImage("image")
            guard !DozerImages.builtIn.contains(image) else { throw Invalid("image: a built-in image's name is taken") }
            a = .templateCreate(name: try f.sandbox("sandbox"), point: try f.pointRef("point"), image: image, note: try f.note("note"))
        case "duplicate":
            var copy: Bool?
            if let v = d["copyState"], !(v is NSNull) {
                guard let b = v as? Bool, CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() else { throw Invalid("copyState: true or false") }
                copy = b ? true : nil
            }
            var o = DuplicateOptions(workspace: try f.workspace("workspace"), cpus: try f.int("cpus", 1...64),
                                     memoryMiB: try f.int("memoryMiB", 256...262_144).map(UInt64.init),
                                     network: try f.oneOf("network", ["agent", "bake", "locked", "open", "nat", "none"]),
                                     account: try f.accountRef("account", allowDefault: true), copyState: copy)
            o.isolated = try f.flag("isolated")
            guard !(o.isolated == true && o.workspace != nil) else { throw Invalid("isolated: or a workspace, not both") }
            let name = try f.sandbox("sandbox"), new = try f.sandbox("newName")
            guard name != new else { throw Invalid("newName: a different name") }
            a = .duplicate(name: name, newName: new, point: try f.pointRef("point"), options: o)
        case "image-bake":
            // 596: any base × agent image (python-claude-code, go, df-…-pi) — by its canonical name.
            let i = try f.image("image")
            guard ["lab", "claude-code", "pi", "codex"].contains(i) || ImageChoice.parse(i)?.name == i else {
                throw Invalid("image: lab, claude-code, pi or a base × agent image")
            }
            a = .imageBake(i)
        case "image-rm":
            a = .imageRemove(try f.image("image"))
        case "net-policy":
            var e = WebPolicyEdit(preset: try f.oneOf("preset", ["locked", "bake", "agent", "open"]), allow: try f.hosts("allow"),
                                  deny: try f.hosts("deny"), remove: try f.hosts("remove"))
            e.grant = try f.permissionWords("grant")
            e.revoke = try f.permissionWords("revoke")
            guard !e.isEmpty else { throw Invalid("net-policy: nothing to change") }
            a = .netPolicy(name: try f.sandbox("sandbox"), edit: e)
        case "key-policy":
            a = .keyPolicy(name: try f.sandbox("sandbox"), policy: try f.required(f.oneOf("policy", ["allow", "strict", "auto"]), "policy"))
        case "key-rm":
            a = .keyRemove(name: try f.sandbox("sandbox"),
                           binding: try f.required(f.oneOf("binding", [CredentialBinding.anthropic.id, CredentialBinding.claudeOAuth.id]), "binding"))
        case "account-use":
            a = .accountUse(name: try f.sandbox("sandbox"), account: try f.required(f.accountRef("account", allowDefault: true), "account"))
        case "account-default":
            a = .accountDefault(try f.required(f.accountRef("account", allowDefault: false), "account"))
        case "account-keepalive":
            guard let on = d["enabled"] as? Bool, CFGetTypeID(d["enabled"] as CFTypeRef) == CFBooleanGetTypeID() else { throw Invalid("enabled: true or false") }
            a = .accountKeepalive(on)
        case "account-verify":
            a = .accountVerify(try f.account("account"))
        case "account-rm":
            a = .accountRemove(try f.account("account"))
        case "onboard":
            a = .onboard(try f.builtInImages("images"))
        case "prepare-cancel":
            a = .prepareCancel(try f.builtInImages("images"))
        case "resources-rm":
            a = .resourcesRemove(try f.resourceIDs("ids"))
        case "resources-clean":
            a = .resourcesClean
        case "resources-kernel":
            let k = try f.required(f.string("kernel", max: 120), "kernel")
            guard k == "pinned" || (k.hasPrefix("kernel:") && Resources.isValidID(k)) else { throw Invalid("kernel: kernel:<version> or pinned") }
            a = .resourcesKernel(k)
        case "host-start":
            a = .hostStart
        case "host-restart":
            a = .hostRestart
        case "builder-start":
            a = .builderStart
        case "builder-install":
            a = .builderInstall
        case "tools-apply":
            a = .toolsApply(try f.sandbox("sandbox"))
        case "session-end":
            a = .sessionEnd(name: try f.sandbox("sandbox"), session: try f.required(f.session("session"), "session"))
        case "session-restart":
            a = .sessionRestart(name: try f.sandbox("sandbox"), session: try f.required(f.session("session"), "session"), fresh: try f.flag("fresh") == true)
        default:
            guard let op = lifecycleOps[verb] else { throw Invalid("unknown action") }
            a = .lifecycle(op, name: try f.sandbox("sandbox"))
        }
        if let target = a.confirmationTarget {
            guard let c = d["confirm"] as? String, c == target else { throw Invalid("\(verb) is destructive: type the name to confirm it") }
        }
        return a
    }

    /// Typed field readers — each enforces the rule the CLI or the library would.
    struct Fields {
        let d: [String: Any]
        init(_ d: [String: Any]) { self.d = d }

        func required<T>(_ v: T?, _ key: String) throws -> T {
            guard let v else { throw Invalid("\(key) is required") }
            return v
        }

        func string(_ key: String, max: Int = 256) throws -> String? {
            guard let v = d[key] else { return nil }
            if v is NSNull { return nil }
            guard let s = v as? String else { throw Invalid("\(key) must be a string") }
            guard !s.isEmpty, s.count <= max, !s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                throw Invalid("\(key): 1–\(max) characters, no control characters")
            }
            return s
        }

        func matching(_ key: String, _ pattern: String, _ rule: String) throws -> String? {
            guard let s = try string(key) else { return nil }
            guard s.range(of: pattern, options: .regularExpression) != nil else { throw Invalid("\(key): \(rule)") }
            return s
        }

        func sandbox(_ key: String) throws -> String {
            guard let s = try string(key), WebRoute.isSandboxName(s) else { throw Invalid("\(key): a sandbox name, 1–40 of a-z 0-9 -") }
            return s
        }

        func session(_ key: String) throws -> String? {
            guard let s = try string(key, max: 64) else { return nil }
            do { try GuestCommand.validateSessionName(s) } catch { throw Invalid("\(key): 1–64 of letters, digits . _ - (not starting with .)") }
            return s
        }

        func image(_ key: String) throws -> String {
            try required(matching(key, "^[a-z0-9][a-z0-9-]{0,39}$", "an image name (lab, claude-code, pi or a custom image)"), key)
        }

        func customImage(_ key: String) throws -> String {
            try required(matching(key, "^[a-z0-9][a-z0-9-]{0,39}$", "an image name: 1–40 of a-z 0-9 -"), key)
        }

        func pointRef(_ key: String) throws -> String? {
            try matching(key, "^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$", "a restore point's name or id")
        }

        func note(_ key: String) throws -> String? { try string(key, max: 200) }

        func oneOf(_ key: String, _ values: [String]) throws -> String? {
            guard let s = try string(key) else { return nil }
            guard values.contains(s) else { throw Invalid("\(key): one of \(values.joined(separator: ", "))") }
            return s
        }

        func int(_ key: String, _ range: ClosedRange<Int>) throws -> Int? {
            guard let v = d[key], !(v is NSNull) else { return nil }
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == n.doubleValue.rounded(),
                  range.contains(n.intValue) else { throw Invalid("\(key): a whole number \(range.lowerBound)–\(range.upperBound)") }
            return n.intValue
        }

        func account(_ key: String) throws -> String {
            guard let s = try string(key, max: 40), (try? AccountStore.validateName(s)) != nil || s == "mac" else {
                throw Invalid("\(key): an account name, 1–40 of a-z 0-9 -")
            }
            return s
        }

        func accountRef(_ key: String, allowDefault: Bool) throws -> String? {
            guard let s = try string(key, max: 40) else { return nil }
            if s == "none" || (allowDefault && s == "default") { return s }
            guard s.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil, s != "default" else {
                throw Invalid("\(key): an account name\(allowDefault ? ", default" : "") or none")
            }
            return s
        }

        /// 594: a list of built-in images (lab, claude-code, pi), each at most once; absent = empty.
        func builtInImages(_ key: String) throws -> [String] {
            guard let v = d[key], !(v is NSNull) else { return [] }
            guard let a = v as? [Any], a.count <= 3 else { throw Invalid("\(key): a list of lab, claude-code, pi") }
            var out: [String] = []
            for x in a {
                guard let s = x as? String, DozerImages.builtIn.contains(s), !out.contains(s) else { throw Invalid("\(key): lab, claude-code, pi — each once") }
                out.append(s)
            }
            return out
        }

        /// 595: resource ids (`Resources.isValidID`), 1–500, each once.
        func resourceIDs(_ key: String) throws -> [String] {
            guard let a = d[key] as? [Any], (1...500).contains(a.count) else { throw Invalid("\(key): a list of 1–500 resource ids") }
            var out: [String] = []
            for x in a {
                guard let s = x as? String, Resources.isValidID(s), !out.contains(s) else { throw Invalid("\(key): resource ids as the Resources page lists them, each once") }
                out.append(s)
            }
            return out
        }

        func subnet(_ key: String) throws -> String? {
            try matching(key, #"^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$"#, "an IPv4 CIDR, like 192.168.120.0/24")
        }

        /// A host folder shared at /workspace: an absolute path (or ~/…), one line. 594: it need not
        /// exist — the host makes it (`Workspace.prepare`), and refuses a file, the store, a system
        /// location, / and the home folder itself.
        func workspace(_ key: String) throws -> String? {
            guard let s = try string(key, max: 1024) else { return nil }
            guard !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { throw Invalid("\(key): one line, no control characters") }
            guard s.hasPrefix("/") || s.hasPrefix("~/") else { throw Invalid("\(key): an absolute path (or ~/…)") }
            do { return try Workspace.normalize(s) } catch { throw Invalid("\(key): an absolute path (or ~/…)") }
        }

        /// 596: a Dockerfile — an absolute path (or ~/…) of one line, not a folder's trailing slash.
        func dockerfile(_ key: String) throws -> String? {
            guard let p = try workspace(key) else { return nil }
            guard !p.hasSuffix("/") else { throw Invalid("\(key): a file, not a folder") }
            return p
        }

        /// 594: true, or absent.
        func flag(_ key: String) throws -> Bool? {
            guard let v = d[key], !(v is NSNull) else { return nil }
            guard let b = v as? Bool, CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() else { throw Invalid("\(key): true or false") }
            return b ? true : nil
        }

        /// Hosts for the policy: exact, `*.domain`, `host:port`, or an IPv4 CIDR; ≤ 32.
        func hosts(_ key: String) throws -> [String] {
            guard let v = d[key], !(v is NSNull) else { return [] }
            guard let a = v as? [Any], a.count <= 32 else { throw Invalid("\(key): a list of at most 32 hosts") }
            return try a.map { x in
                guard let s = x as? String, s.count <= 253,
                      s.range(of: #"^(\*\.)?[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:\d{1,5}(,\d{1,5})*)?$|^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$"#,
                              options: .regularExpression) != nil else {
                    throw Invalid("\(key): a host (example.com, *.example.com, host:443) or an IPv4 CIDR")
                }
                return s
            }
        }

        /// 597: permission ids (`install:python`, `web`, `install`) or `site:HOST`; ≤ 32, each once.
        func permissionWords(_ key: String) throws -> [String] {
            guard let v = d[key], !(v is NSNull) else { return [] }
            guard let a = v as? [Any], a.count <= 32 else { throw Invalid("\(key): a list of at most 32 permissions") }
            var out: [String] = []
            for x in a {
                guard let s = x as? String, s.count <= 260 else { throw Invalid("\(key): a permission id or site:HOST") }
                if s.hasPrefix("site:") {
                    guard s.dropFirst(5).range(of: #"^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#, options: .regularExpression) != nil else {
                        throw Invalid("\(key): site:HOST, a host name like api.example.com")
                    }
                } else {
                    guard s == "install" || AgentPermissions.isValid(s) else { throw Invalid("\(key): a permission id (doz net permissions) or site:HOST") }
                }
                guard !out.contains(s) else { throw Invalid("\(key): each once") }
                out.append(s)
            }
            return out
        }

        /// A detached session's program: 1–64 arguments, no NUL, ≤ 4 KiB each, 16 KiB in all.
        func argv(_ key: String) throws -> [String]? {
            guard let v = d[key], !(v is NSNull) else { return nil }
            guard let a = v as? [Any], (1...64).contains(a.count) else { throw Invalid("\(key): 1–64 arguments") }
            let out = try a.map { x -> String in
                guard let s = x as? String, !s.isEmpty, s.utf8.count <= 4096, !s.contains("\0") else {
                    throw Invalid("\(key): each argument a non-empty string of at most 4 KiB")
                }
                return s
            }
            guard out.reduce(0, { $0 + $1.utf8.count }) <= 16_384 else { throw Invalid("\(key): at most 16 KiB in all") }
            return out
        }
    }
}

/// A network-policy change, as `doz net policy` takes it.
public struct WebPolicyEdit: Equatable, Sendable {
    public var preset: String?
    public var allow: [String]
    public var deny: [String]
    public var remove: [String]
    /// 597 (P6): permissions switched on / off, or `site:HOST`.
    public var grant: [String] = []
    public var revoke: [String] = []

    public var isEmpty: Bool { preset == nil && allow.isEmpty && deny.isEmpty && remove.isEmpty && grant.isEmpty && revoke.isEmpty }

    public func request(_ name: String) -> HostRequest {
        var r = HostRequest(.netPolicy, name: name)
        r.preset = preset
        r.allow = allow
        r.deny = deny
        r.removeHosts = remove
        r.grant = grant.isEmpty ? nil : grant
        r.revoke = revoke.isEmpty ? nil : revoke
        return r
    }
}

/// `POST /api/v1/sandboxes/{name}/network/preview` — what the edit would make of the policy.
public struct WebPolicyPreview: Codable, Equatable, Sendable {
    public var before: WebPolicy
    public var after: WebPolicy
    public var added: [String]
    public var removed: [String]
    public var changed: Bool

    public init(before b: NetworkPolicy, after a: NetworkPolicy) {
        before = WebPolicy(b)
        after = WebPolicy(a)
        let bl = before.rules.map(\.label), al = after.rules.map(\.label)
        added = al.filter { !bl.contains($0) }
        removed = bl.filter { !al.contains($0) }
        changed = before != after
    }
}

/// One operation the UI started, as the page sees it (SSE `op`, `GET /api/v1/operations`).
public struct WebOperation: Codable, Equatable, Sendable {
    public var id: String
    public var action: String
    public var label: String
    public var sandbox: String?
    /// running, done, failed — or (605) interrupted: `doz ui` restarted while it ran and its outcome was
    /// not seen (an ended state, never a failure).
    public var state: String
    /// The latest progress line while running; the outcome after.
    public var text: String
    public var startedAt: Date
    public var milliseconds: Double?
    /// 594 W22: finished lines, for an operation that does several things at once (Restart host: each
    /// sandbox's hibernation — "✓ hibernated w1 (snapshot 40 MB) — 0.4 s").
    public var lines: [String]? = nil
    /// 605: started by an earlier `doz ui` that restarted while it ran (loaded from `ui.operations.json`).
    public var interrupted: Bool? = nil
}
