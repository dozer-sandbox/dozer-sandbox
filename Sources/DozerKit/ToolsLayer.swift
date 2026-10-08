import Foundation

// 599h — the TOOLS LAYER (owner, 2026-10-02: "Github credentials … worked although claude in VM installed gh
// cli. I think we should have that (and other supporting tools based on chosen settings when creating
// sandbox)" · "a 'tools' layer that we manage"): the tools Dozer puts into a sandbox because of its settings —
// on every base (Debian, Ubuntu, Alpine, a Dockerfile's), with NO image rebuild (the recipes are untouched):
//
//   gh                    "Use GitHub as you" on — a static linux-arm64 binary, downloaded ONCE to the Mac's
//                         store (pinned version, sha256 checked) and COPIED into the guest over the host→guest
//                         copy path (no guest network), at /usr/local/lib/doz/bin/gh (first on every session's
//                         PATH). REMOVED when the setting is off (only Dozer's copy; a gh the user installed
//                         elsewhere is never touched).
//   ssh client            SSH agent forwarding on — openssh-client from apt/apk (through the proxy) when missing.
//   github.com host keys  SSH agent forwarding on — GitHub's published keys, pinned here, in a managed block of
//                         /etc/ssh/ssh_known_hosts (removed when off), so `ssh -T git@github.com` never prompts.
//   tmux                  sessions.tmux on — from apt/apk when missing.
//   git, curl, ca-certificates   always — from apt/apk when missing (every catalogue base bakes them; the
//                         lab and an old image may not).
//
// Applied at every fresh boot (after the network is up) and every wake (`applyGuestFixes`). The FIRST apply in
// a sandbox (no /var/lib/doz/tools yet) is shown as steps; later ones are quiet (a note) unless something
// changed or failed. Never fatal: a failure is a result line and a note.

/// What the tools layer follows: the sandbox's settings.
public struct ToolInputs: Codable, Equatable, Sendable {
    /// "Use GitHub as you" (the permission) is on.
    public var github: Bool
    /// `sandbox.ssh_agent` is on (and the sandbox is proxied).
    public var ssh: Bool
    /// `sessions.tmux` is on.
    public var tmux: Bool
    /// EXPERIMENTAL (604): an audio sandbox — alsa-utils, /etc/asound.conf and the TEMPORARY `doz-sound`. nil (every
    /// other sandbox): nothing, and the inputs encode exactly as before.
    public var audio: Bool?
    /// EXPERIMENTAL (604): the Mac app macOS asks about the microphone for (the host's responsible app), named in
    /// doz-sound's permission hint.
    public var audioApp: String?
    public init(github: Bool = false, ssh: Bool = false, tmux: Bool = false, audio: Bool = false, audioApp: String? = nil) {
        self.github = github; self.ssh = ssh; self.tmux = tmux
        self.audio = audio ? true : nil
        self.audioApp = audio ? audioApp : nil
    }
}

/// One tool of the layer: what, why (the setting), where it comes from.
public struct ToolItem: Codable, Equatable, Sendable {
    /// `gh`, `ssh`, `github-known-hosts`, `tmux`, `git`, `curl`, `ca-certificates`.
    public var id: String
    public var title: String
    /// Why it is there: "for GitHub as you", "for SSH agent forwarding", "for tmux sessions", "always".
    public var reason: String
    /// `binary` (copied from the Mac), `package` (apt/apk), `file` (written by Dozer).
    public var kind: String
    public var version: String?
    public var source: String
    /// The apt/apk package, for a package.
    public var package: String?
    /// The command whose presence proves it (a package), or the file (ca-certificates).
    public var command: String?
}

/// The tools a sandbox should have now, and what Dozer should take away.
public struct ToolPlan: Codable, Equatable, Sendable {
    public var items: [ToolItem]
    /// Dozer's own tools to remove (their setting is off): `gh`, `github-known-hosts`.
    public var removals: [String]
}

/// What one apply did for one tool.
public struct ToolResult: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var reason: String
    /// `ok` (already there), `installed`, `removed`, `failed`, `skipped`.
    public var state: String
    public var detail: String
    public var ok: Bool { state == "ok" || state == "installed" || state == "removed" }
}

/// One apply of the layer.
public struct ToolsReport: Codable, Equatable, Sendable {
    public var results: [ToolResult]
    public var at: Date
    /// The first apply in this sandbox (shown as steps).
    public var first: Bool
    public var changed: Bool { results.contains { $0.state == "installed" || $0.state == "removed" } }
    public var failed: Bool { results.contains { $0.state == "failed" || $0.state == "skipped" } }
    /// One line: "gh 2.102.0 ✓, ssh client ✓, github.com host keys ✓" (failures with why).
    public var summary: String {
        results.isEmpty ? "nothing to set up" : results.map { r in
            r.ok ? "\(r.title) ✓" : "\(r.title) ✗ (\(r.detail))"
        }.joined(separator: ", ")
    }
    public init(results: [ToolResult], at: Date = Date(), first: Bool) { self.results = results; self.at = at; self.first = first }
}

public enum ToolsLayer {
    // MARK: pins

    /// gh — the GitHub CLI: a static Go binary (glibc and musl alike).
    public static let ghVersion = "2.102.0"
    /// sha256 of `gh_2.102.0_linux_arm64.tar.gz` (GitHub's release checksums file).
    public static let ghSHA256 = "7862c86c72f43df3a2d93ddde6f473285b4e2af61b494849846827e513ef6484"
    public static var ghTarball: String { "gh_\(ghVersion)_linux_arm64.tar.gz" }
    /// The member of the tarball that is the program.
    public static var ghMember: String { "gh_\(ghVersion)_linux_arm64/bin/gh" }
    public static let ghDownloadBase = "https://github.com/cli/cli/releases/download"
    /// The release URL (`base`: a test server's, through the seam).
    public static func ghURL(base: String = ghDownloadBase) -> URL {
        URL(string: base + (base == ghDownloadBase ? "/v\(ghVersion)/" : "/") + ghTarball)!
    }

    /// GitHub's published SSH host keys (https://api.github.com/meta `ssh_keys`; docs: "GitHub's SSH key
    /// fingerprints") — public, pinned here so the guest never trusts a key on first use.
    public static let githubHostKeys = [
        "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl",
        "github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=",
        "github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=",
    ]

    // MARK: where, in the guest

    public static let guestGhPath = GuestCommand.openShimDirectory + "/gh"
    /// A link on every PATH (`doz exec`, scripts) — made only where nothing else is.
    public static let ghLink = "/usr/local/bin/gh"
    /// The layer's state in the guest: its existence marks the first apply done; `gh.version` is the copy's.
    public static let guestStateDirectory = "/var/lib/doz/tools"
    public static let knownHostsPath = "/etc/ssh/ssh_known_hosts"
    static let knownHostsBegin = "# doz:github-known-hosts:v1 begin (Dozer: the keys GitHub publishes, for SSH agent forwarding)"
    static let knownHostsEnd = "# doz:github-known-hosts:v1 end"
    public static let guestLog = "/var/log/doz-tools.log"
    /// The CA bundle every distro keeps (Debian, Ubuntu, Alpine).
    static let caBundle = "/etc/ssl/certs/ca-certificates.crt"

    // MARK: the plan

    /// The tools `inputs` call for (always the basics), and what to take away.
    public static func plan(_ inputs: ToolInputs) -> ToolPlan {
        var items: [ToolItem] = []
        var removals: [String] = []
        if inputs.github {
            items.append(ToolItem(id: "gh", title: "gh \(ghVersion)", reason: "for GitHub as you", kind: "binary", version: ghVersion,
                                  source: "Dozer's cache on this Mac (\(ghTarball), sha256 checked), copied in"))
        } else {
            removals.append("gh")
        }
        if inputs.ssh {
            items.append(ToolItem(id: "ssh", title: "ssh client", reason: "for SSH agent forwarding", kind: "package",
                                  source: "apt/apk through the proxy, when missing", package: "openssh-client", command: "ssh"))
            items.append(ToolItem(id: "github-known-hosts", title: "github.com host keys", reason: "for SSH agent forwarding", kind: "file",
                                  source: "pinned in Dozer (GitHub's published keys), in \(knownHostsPath)"))
        } else {
            removals.append("github-known-hosts")
        }
        if inputs.tmux {
            items.append(ToolItem(id: "tmux", title: "tmux", reason: "for tmux sessions", kind: "package",
                                  source: "apt/apk through the proxy, when missing", package: "tmux", command: "tmux"))
        }
        if inputs.audio == true {
            items.append(ToolItem(id: "alsa-utils", title: "alsa-utils", reason: "for audio (experimental)", kind: "package",
                                  source: "apt/apk through the proxy, when missing", package: "alsa-utils", command: "aplay"))
            items.append(ToolItem(id: "asound-conf", title: "the sound card as ALSA's default", reason: "for audio (experimental)", kind: "file",
                                  source: "written by Dozer in \(DozSound.asoundPath)"))
            items.append(ToolItem(id: "doz-sound", title: "doz-sound (temporary)", reason: "for audio (experimental)", kind: "file",
                                  source: "written by Dozer in \(DozSound.path)"))
        }
        for (id, cmd) in [("git", "git"), ("curl", "curl"), ("ca-certificates", caBundle)] {
            items.append(ToolItem(id: id, title: id, reason: "always", kind: "package", source: "apt/apk through the proxy, when missing",
                                  package: id, command: cmd))
        }
        return ToolPlan(items: items, removals: removals)
    }

    // MARK: the guest's side

    /// What the guest has now (cheap; root): `first=0|1`, `gh=VERSION`, `have=ID`…, `pm=apt|apk|none`.
    public static let checkScript = """
        if [ -d '\(guestStateDirectory)' ]; then echo first=0; else echo first=1; fi
        [ -x '\(guestGhPath)' ] && v=$(cat '\(guestStateDirectory)/gh.version' 2>/dev/null) && echo "gh=$v"
        for c in git curl ssh tmux; do command -v "$c" >/dev/null 2>&1 && echo "have=$c"; done
        [ -s '\(caBundle)' ] && echo have=ca-certificates
        command -v aplay >/dev/null 2>&1 && echo have=alsa-utils
        grep -qxF '\(knownHostsBegin)' '\(knownHostsPath)' 2>/dev/null && echo have=github-known-hosts
        if command -v apt-get >/dev/null 2>&1; then echo pm=apt; elif command -v apk >/dev/null 2>&1; then echo pm=apk; else echo pm=none; fi
        exit 0
        """

    /// The check's answer.
    public struct GuestState: Equatable, Sendable {
        public var first = true
        public var gh: String?
        public var have: Set<String> = []
        public var packageManager = "none"

        public static func parse(_ out: String) -> GuestState {
            var s = GuestState()
            for line in out.split(separator: "\n").map(String.init) {
                if line == "first=0" { s.first = false }
                else if line.hasPrefix("gh=") { s.gh = String(line.dropFirst(3)) }
                else if line.hasPrefix("have=") { s.have.insert(String(line.dropFirst(5))) }
                else if line.hasPrefix("pm=") { s.packageManager = String(line.dropFirst(3)) }
            }
            return s
        }
    }

    /// The packages `plan` still needs in a guest in `state`.
    public static func missingPackages(_ plan: ToolPlan, _ state: GuestState) -> [ToolItem] {
        plan.items.filter { $0.kind == "package" && !state.have.contains($0.id) }
    }

    /// Root shell: apply `plan` to a guest in `state` (gh already copied to `<guestGhPath>.tmp` when
    /// `ghCopied`). One `doz-tool ID STATE DETAIL` line per tool. Never fails the caller.
    public static func applyScript(_ plan: ToolPlan, state: GuestState, ghCopied: Bool, ghProblem: String?, audioApp: String? = nil) -> String {
        var s = "log='\(guestLog)'; mkdir -p '\(guestStateDirectory)' 2>/dev/null; "
        func say(_ id: String, _ st: String, _ detail: String) -> String {
            "echo 'doz-tool \(id) \(st) \(detail.replacingOccurrences(of: "'", with: "’"))'; "
        }
        // Packages: one install of everything missing (apt/apk through the proxy), then each one checked.
        let missing = missingPackages(plan, state)
        if !missing.isEmpty {
            let names = missing.compactMap(\.package).joined(separator: " ")
            switch state.packageManager {
            case "apt":
                s += "{ echo \"== $(date) apt-get install \(names)\"; export DEBIAN_FRONTEND=noninteractive; "
                    + "apt-get install -y --no-install-recommends -o Dpkg::Use-Pty=0 \(names) || { apt-get update && apt-get install -y --no-install-recommends -o Dpkg::Use-Pty=0 \(names); }; } >>\"$log\" 2>&1; "
            case "apk":
                s += "{ echo \"== $(date) apk add \(names)\"; apk add --no-progress \(names) || { apk update && apk add --no-progress \(names); }; } >>\"$log\" 2>&1; "
            default: break
            }
        }
        for item in plan.items where item.kind == "package" {
            let check = item.id == "ca-certificates" ? "[ -s '\(caBundle)' ]" : "command -v \(item.command ?? item.id) >/dev/null 2>&1"
            if !missing.contains(item) {
                s += say(item.id, "ok", "already in the image")
            } else if state.packageManager == "none" {
                s += say(item.id, "failed", "missing, and this base has neither apt-get nor apk")
            } else {
                s += "if \(check); then \(say(item.id, "installed", "from \(state.packageManager)"))else \(say(item.id, "failed", "\(state.packageManager) could not install \(item.package ?? item.id) — see \(guestLog)"))fi; "
            }
        }
        // EXPERIMENTAL (604): an audio sandbox's ALSA default and doz-sound (after the packages: they need aplay).
        if plan.items.contains(where: { $0.id == "asound-conf" }) { s += DozSound.asoundScript(say: say) }
        if plan.items.contains(where: { $0.id == "doz-sound" }) { s += DozSound.installScript(app: audioApp, say: say) }
        // gh: Dozer's copy (in place when copied), or nothing to do, or a reason. Also linked as /usr/local/bin/gh
        // (every PATH has it: `doz exec`, scripts) — only when that name is free or already Dozer's link.
        let link = "if [ ! -e '\(ghLink)' ] && [ ! -L '\(ghLink)' ] || [ \"$(readlink '\(ghLink)')\" = '\(guestGhPath)' ]; then ln -sf '\(guestGhPath)' '\(ghLink)'; fi; "
        if plan.items.contains(where: { $0.id == "gh" }) {
            if ghCopied {
                s += "if mv -f '\(guestGhPath).tmp' '\(guestGhPath)' && chmod 0755 '\(guestGhPath)' && '\(guestGhPath)' --version >/dev/null 2>&1; then "
                    + "printf '%s' '\(ghVersion)' > '\(guestStateDirectory)/gh.version'; mkdir -p /usr/local/bin; \(link)\(say("gh", "installed", "gh \(ghVersion), from Dozer's cache on the Mac"))"
                    + "else rm -f '\(guestGhPath)' '\(guestGhPath).tmp'; \(say("gh", "failed", "the copied gh does not run here"))fi; "
            } else if state.gh == ghVersion {
                s += "mkdir -p /usr/local/bin; \(link)" + say("gh", "ok", "gh \(ghVersion)")
            } else {
                s += say("gh", "skipped", ghProblem ?? "not on this Mac yet")
            }
        }
        if plan.removals.contains("gh") {
            s += "if [ -e '\(guestGhPath)' ]; then rm -f '\(guestGhPath)' '\(guestStateDirectory)/gh.version'; "
                + "[ \"$(readlink '\(ghLink)' 2>/dev/null)\" = '\(guestGhPath)' ] && rm -f '\(ghLink)'; \(say("gh", "removed", "GitHub as you is off"))fi; "
        }
        // github.com's host keys: a managed block (replaced as a whole; removed when off).
        let dropBlock = "[ -f '\(knownHostsPath)' ] && sed -i '/^# doz:github-known-hosts:/,/^# doz:github-known-hosts:v[0-9]* end$/d' '\(knownHostsPath)'"
        if plan.items.contains(where: { $0.id == "github-known-hosts" }) {
            if state.have.contains("github-known-hosts") {
                s += say("github-known-hosts", "ok", "github.com's published keys")
            } else {
                let block = ([knownHostsBegin] + githubHostKeys + [knownHostsEnd]).joined(separator: "\n") + "\n"
                s += "mkdir -p /etc/ssh; \(dropBlock); printf '%s' '\(block)' >> '\(knownHostsPath)' && chmod 0644 '\(knownHostsPath)' && "
                    + say("github-known-hosts", "installed", "github.com's published keys in \(knownHostsPath)")
            }
        }
        if plan.removals.contains("github-known-hosts") && state.have.contains("github-known-hosts") {
            s += "\(dropBlock); " + say("github-known-hosts", "removed", "SSH agent forwarding is off")
        }
        return s + "exit 0"
    }

    /// The results in `out` (the apply script's lines), in the plan's order (removals after).
    public static func results(_ out: String, plan: ToolPlan) -> [ToolResult] {
        var byID: [String: (String, String)] = [:]
        var order: [String] = []
        for line in out.split(separator: "\n") where line.hasPrefix("doz-tool ") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            if byID[parts[1]] == nil { order.append(parts[1]) }
            byID[parts[1]] = (parts[2], parts.count > 3 ? parts[3] : "")
        }
        var out: [ToolResult] = []
        for item in plan.items {
            let (st, d) = byID[item.id] ?? ("failed", "no answer from the guest")
            out.append(ToolResult(id: item.id, title: item.title, reason: item.reason, state: st, detail: d))
        }
        for id in order where !plan.items.contains(where: { $0.id == id }) {
            let (st, d) = byID[id]!
            out.append(ToolResult(id: id, title: id == "gh" ? "gh" : "github.com host keys", reason: "its setting is off", state: st, detail: d))
        }
        return out
    }

    /// The step label for one result: "tools: gh 2.102.0 — for GitHub as you".
    public static func label(_ r: ToolResult) -> String { "tools: \(r.title) — \(r.reason)" }
}
