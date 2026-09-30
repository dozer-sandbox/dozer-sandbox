import ContainerizationEXT4
import CryptoKit
import Foundation

/// How to build a baked root disk: a digest-pinned OCI base (read once, flattened to ext4 — no
/// layers kept, no Dockerfile, no BuildKit), install steps run INSIDE a VM booted from it, and a
/// credential-free verification. The result is a read-only disk every sandbox APFS-clones as its
/// root. Library-native: it knows nothing of any host app's imageSpec format.
public struct ImageSpec: Sendable, Codable, Equatable {
    /// `[a-z0-9-]`, the cache directory name.
    public var name: String
    /// The OCI base, WITH a digest (`repo@sha256:…`), so the flattened disk is reproducible.
    public var base: String
    /// Run in order, as root unless a step says otherwise.
    public var steps: [BakeStep]
    /// Credential-free checks run as `user` after the steps; every one must exit 0, and its output
    /// must contain `expect` when set. The output is recorded in the manifest.
    public var verify: [VerifyCheck]
    /// The account agent sessions run as (created by a step), and its home.
    public var user: String
    public var home: String
    /// Directories (under `home` or absolute) kept on the sandbox's STATE disk, so they survive
    /// Stop → Start and a re-bake of the image.
    public var persistDirs: [String]
    /// Environment every session of this image gets (e.g. PATH, CLAUDE_CONFIG_DIR).
    public var sessionEnvironment: [String: String]
    /// Where sessions start (the workspace share).
    public var workdir: String
    /// Capacity of the baked disk (apparent size; APFS only allocates what is written).
    public var rootfsMiB: UInt64
    /// 587: the ext4 journal of the baked disk (and of every sandbox's state disk), MiB. Default 16
    /// (586: the smallest size, the fastest for `fsync`, and it removes e2fsck from the discard →
    /// cold boot path). nil: no journal — a disk not cleanly unmounted is e2fsck'd before it boots,
    /// as before 587. Part of the base key and the bake key. A record written before 587 has no
    /// value here, and decodes as nil: its disks have no journal.
    public var journalMiB: Int?
    /// 594: the agent this image installs, at the exact version (the npm package and version; its
    /// integrity is in the install step). nil for an image with no agent. Part of the bake key.
    public var agent: AgentPackage?

    public init(name: String, base: String, steps: [BakeStep], verify: [VerifyCheck], user: String, home: String,
                persistDirs: [String], sessionEnvironment: [String: String] = [:], workdir: String = "/workspace",
                rootfsMiB: UInt64 = 4096, journalMiB: Int? = 16) {
        self.name = name
        self.base = base
        self.steps = steps
        self.verify = verify
        self.user = user
        self.home = home
        self.persistDirs = persistDirs
        self.sessionEnvironment = sessionEnvironment
        self.workdir = workdir
        self.rootfsMiB = rootfsMiB
        self.journalMiB = journalMiB
    }

    /// ImageSpec names the store keeps for itself under `<store>/images/`.
    public static let reservedNames: Set<String> = ["bases", "custom"]

    public func validate() throws {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard (1...40).contains(name.count), name.allSatisfy(allowed.contains) else {
            throw SandboxError.invalidSpec("image name must be 1–40 characters of [a-z0-9-], got \"\(name)\"")
        }
        guard !Self.reservedNames.contains(name) else {
            throw SandboxError.invalidSpec("image name \"\(name)\" is reserved (images/\(name)/ is the store's own)")
        }
        if let j = journalMiB {
            guard (4...1024).contains(j) else { throw SandboxError.invalidSpec("journalMiB must be 4–1024 (or nil for none), got \(j)") }
            guard UInt64(j) * 8 <= rootfsMiB else { throw SandboxError.invalidSpec("journalMiB \(j) is too large for a \(rootfsMiB) MiB disk") }
        }
        guard base.contains("@sha256:") else { throw SandboxError.invalidSpec("image base must be digest-pinned (…@sha256:…): \(base)") }
        guard !user.isEmpty, home.hasPrefix("/"), workdir.hasPrefix("/") else { throw SandboxError.invalidSpec("image user/home/workdir") }
        for d in persistDirs where !(d.hasPrefix("/") || d.hasPrefix("~/")) || d.contains("'") {
            throw SandboxError.invalidSpec("persist dir must be absolute or ~/…, quote-free: \(d)")
        }
        if let a = agent {
            guard AgentRelease(version: a.version, integrity: "sha512-A").isWellFormed,
                  a.package.range(of: #"^(@[a-z0-9-]+/)?[a-z0-9._-]+$"#, options: .regularExpression) != nil else {
                throw SandboxError.invalidSpec("agent package/version: \(a.package)@\(a.version)")
            }
        }
        for k in (steps.flatMap { $0.environment.keys }) + Array(sessionEnvironment.keys) where BakeEnvironment.isCredential(k) {
            throw SandboxError.invalidSpec("credential \(k) must never be part of an image spec — pass it to openSession")
        }
    }

    /// `persistDirs` as absolute guest paths.
    public var resolvedPersistDirs: [String] {
        persistDirs.map { $0.hasPrefix("~/") ? home + "/" + $0.dropFirst(2) : $0 }
    }

    /// Canonical JSON (sorted keys) — the bake key's input, so reordering a dictionary never
    /// changes the key but changing any value does.
    public var canonicalJSON: Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)) ?? Data()
    }

    /// sha256(canonical imageSpec + kernel sha256 + deckhold sha256 + the lineage format). The imageSpec
    /// carries `journalMiB`; the lineage format (587: baked on a clone of a base disk, trimmed at
    /// the end) is in every key, so a pre-587 store re-bakes each image once.
    public func bakeKey(kernelSHA256: String, deckholdSHA256: String) -> String {
        var h = SHA256()
        h.update(data: canonicalJSON)
        h.update(data: Data("\nkernel:\(kernelSHA256)\ndeckhold:\(deckholdSHA256)".utf8))
        h.update(data: Data("\nlineage:\(ImageBaker.lineageFormat)".utf8))
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 587: the key of the base disk this imageSpec's bakes clone — the base's OCI digest, the
    /// capacity, the journal size and the formatter version. ImageSpecs that agree on all four share
    /// one base disk (the two agent imageSpecs do).
    public var baseKey: String {
        let digest = base.split(separator: "@").last.map(String.init) ?? base
        let material = "doz-base|\(digest)|capacity:\(rootfsMiB)MiB|journal:\(journalMiB.map { "\($0)MiB" } ?? "none")|formatter:\(ImageBaker.formatterVersion)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The journal as Containerization's formatter takes it.
    var journalConfig: EXT4.JournalConfig? { Self.journalConfig(journalMiB) }

    static func journalConfig(_ mib: Int?) -> EXT4.JournalConfig? {
        mib.map { EXT4.JournalConfig(size: UInt64($0) * 1_048_576, defaultMode: .ordered) }
    }
}

/// One command an image bake runs inside the VM, in order (`ImageSpec.steps`).
public struct BakeStep: Sendable, Codable, Equatable {
    public var name: String
    public var argv: [String]
    public var environment: [String: String]
    /// nil = root.
    public var user: String?
    public var needsNetwork: Bool
    public var timeoutSeconds: Int64

    public init(_ name: String, argv: [String], environment: [String: String] = [:], user: String? = nil,
                needsNetwork: Bool = true, timeoutSeconds: Int64 = 900) {
        self.name = name
        self.argv = argv
        self.environment = environment
        self.user = user
        self.needsNetwork = needsNetwork
        self.timeoutSeconds = timeoutSeconds
    }

    /// A bash script step (bake steps are not sessions, so a shell is fine here).
    public static func script(_ name: String, _ script: String, environment: [String: String] = [:], user: String? = nil,
                              timeoutSeconds: Int64 = 900) -> BakeStep {
        BakeStep(name, argv: ["bash", "-euo", "pipefail", "-c", script], environment: environment, user: user,
                 timeoutSeconds: timeoutSeconds)
    }
}

/// A credential-free command a bake runs after its steps, to confirm the result (`ImageSpec.verify`).
public struct VerifyCheck: Sendable, Codable, Equatable {
    public var argv: [String]
    public var expect: String?
    public init(_ argv: [String], expect: String? = nil) {
        self.argv = argv
        self.expect = expect
    }
}

/// The bake environment is built from the imageSpec alone and SCRUBBED: nothing that looks like a
/// credential ever reaches a bake (and so never a baked disk).
public enum BakeEnvironment {
    public static func isCredential(_ key: String) -> Bool {
        let k = key.uppercased()
        return k.hasSuffix("_API_KEY") || k.hasSuffix("_TOKEN") || k.hasSuffix("_SECRET") || k.contains("PASSWORD")
            || k == "ANTHROPIC_API_KEY" || k == "ANTHROPIC_AUTH_TOKEN"
    }

    public static func scrubbed(_ env: [String: String]) -> [String: String] { env.filter { !isCredential($0.key) } }
}

// MARK: - The two agent imageSpecs

/// 594: one provider's credentials an agent can use: the kinds of account (`mac`, `setup-token`,
/// `api-key` for Anthropic).
public struct AgentCredentialSupport: Sendable, Codable, Equatable, Hashable {
    public var provider: String
    public var accountKinds: [String]
    public init(provider: String, accountKinds: [String]) {
        self.provider = provider
        self.accountKinds = accountKinds
    }
}

/// 594: an agent's npm package at one exact version.
public struct AgentPackage: Sendable, Codable, Equatable, Hashable {
    public var package: String
    public var version: String
    public init(package: String, version: String) {
        self.package = package
        self.version = version
    }
}

/// 594: one published version of an agent: its version and the registry's sha512 integrity for its
/// tarball (`sha512-…`, as npm's `dist.integrity`).
public struct AgentRelease: Sendable, Codable, Equatable, Hashable {
    public var version: String
    public var integrity: String
    public init(version: String, integrity: String) {
        self.version = version
        self.integrity = integrity
    }

    /// Safe to put in a bake script: an exact version (`1.2.3`, `-pre`, `+build`) and a sha512 SRI
    /// integrity — nothing a registry answer could use to break out of the script's quotes.
    public var isWellFormed: Bool {
        version.count <= 64 && integrity.count <= 200
            && version.range(of: #"^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil
            && integrity.range(of: #"^sha512-[A-Za-z0-9+/]+={0,2}$"#, options: .regularExpression) != nil
    }

    /// Numeric `major.minor.patch` order; a pre-release sorts before its release.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> ([Int], String?) {
            let core = v.split(separator: "+").first.map(String.init) ?? v
            let pre = core.split(separator: "-", maxSplits: 1)
            let nums = pre[0].split(separator: ".").map { Int($0) ?? 0 }
            return (nums, pre.count > 1 ? String(pre[1]) : nil)
        }
        let (x, xp) = parts(a), (y, yp) = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        switch (xp, yp) {
        case (nil, .some): return true
        case (.some(let p), .some(let q)): return p > q
        default: return false
        }
    }
}

/// Pinned values copied (by hand, values only) from the DeckStack official imageSpecs
/// `claude-code` 2.1.227 and `pi-coding-agent` 0.84.1 — no code or type is shared with them.
/// 594: these are the DEFAULT pins; `images.claude_code_version` / `images.pi_version` = latest (the
/// default setting) prepares the registry's latest instead, at its exact version and integrity.
public enum AgentImages {
    public static let claudeCodePackage = "@anthropic-ai/claude-code"
    public static let piPackage = "@earendil-works/pi-coding-agent"
    public static let claudeCodePinned = AgentRelease(version: "2.1.227",
        integrity: "sha512-D0YP8GFwPaP/9eObEuP5LRO5+9QSD9CLa6K26whNzXxpxz3pFqPS3nn7l1/MLmSWy32wBP2IKQzkRB3mumUKUQ==")
    public static let piPinned = AgentRelease(version: "0.84.1",
        integrity: "sha512-ncAqFrG+iybuPGOhMiZoEHkEzTpJgz3guYD32pD+M7ucc0WeHmauP6wa7qwP8V/KWvsZDVNa5XGsdZ7fkC7w7A==")

    /// 594 (owner: "creating a Pi sandbox should have pre-requisites for things like API key"): the
    /// credentials each agent can use, per provider — the kinds of Dozer account (`mac` = this Mac's
    /// Claude login, `setup-token`, `api-key`). Claude Code: any Anthropic account. pi: an Anthropic
    /// API key only (it reads ANTHROPIC_API_KEY — the proxy's placeholder); a Claude subscription is
    /// never given to it. Other providers can be added per agent later. nil: no agent (the lab).
    public static func credentials(_ image: String) -> [AgentCredentialSupport]? {
        switch image {
        case "claude-code": [AgentCredentialSupport(provider: "anthropic", accountKinds: ["mac", "setup-token", "api-key"])]
        case "pi": [AgentCredentialSupport(provider: "anthropic", accountKinds: ["api-key"])]
        default: nil
        }
    }

    /// The agent's name as a person reads it.
    public static func agentName(_ image: String) -> String? {
        switch image { case "claude-code": "Claude Code"; case "pi": "pi"; default: nil }
    }

    /// The npm package of an agent image (nil: not an agent image).
    public static func package(_ image: String) -> String? {
        switch image { case "claude-code": claudeCodePackage; case "pi": piPackage; default: nil }
    }
    public static func pinned(_ image: String) -> AgentRelease? {
        switch image { case "claude-code": claudeCodePinned; case "pi": piPinned; default: nil }
    }
    /// The agent image's spec at `release`.
    public static func spec(_ image: String, release: AgentRelease) -> ImageSpec? {
        switch image { case "claude-code": claudeCode(release); case "pi": pi(release); default: nil }
    }

    /// The imageSpecs' digest-pinned Debian `node` base (glibc).
    public static let nodeBase = "docker.io/library/node@sha256:d649c27dae7ba0137b3cef5dd75baa422c08dc3d9e3fc0c23dfb172dc3cc6436"

    /// Create the `agent` account (uid 1001; the base's `node` user keeps 1000) and /workspace.
    static let createAgent = BakeStep.script("create the agent user", """
        id agent >/dev/null 2>&1 || useradd -m -s /bin/bash -u 1001 agent
        mkdir -p /workspace && chown agent:agent /workspace
        """, needsNetworkFalse: ())

    /// `npm pack` the pinned version, check the tarball's sha512 against the pinned integrity,
    /// then install exactly that tarball globally.
    /// Claude Code in a sandbox starts ready to work (owner ruling, 585): `~/.local/bin/claude` (first
    /// on the agent's PATH) marks the first-run setup done for THIS session — onboarding, this
    /// session's API-key placeholder (minted per session, so it is approved per session), trust for
    /// the working folder — then runs the real `/usr/local/bin/claude` with
    /// `--dangerously-skip-permissions`: the VM, the proxy and the vault are the boundary, so its
    /// own prompts only get in the way. `DOZ_CLAUDE_PERMISSIONS=ask` keeps them; root always
    /// keeps them (Claude Code refuses the flag as root). Only the keys named below are written.
    static let claudeLauncher = BakeStep.script("install the doz claude launcher", """
        mkdir -p /usr/local/lib/dozer /home/agent/.local/bin
        cat > /usr/local/lib/dozer/claude-setup.js <<'JS'
        const fs = require('fs'), path = require('path');
        const dir = process.env.CLAUDE_CONFIG_DIR || path.join(process.env.HOME, '.claude');
        const put = (f, obj) => { fs.writeFileSync(f + '.doz-tmp', JSON.stringify(obj, null, 2), { mode: 0o600 }); fs.renameSync(f + '.doz-tmp', f); };
        const read = f => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return {}; } };
        fs.mkdirSync(dir, { recursive: true });
        const file = path.join(dir, '.claude.json'), c = read(file);
        c.hasCompletedOnboarding = true;
        const key = process.env['ANTHROPIC' + '_API_KEY'];   // spelled apart: no image spec names a credential (ImageSpecTests)
        if (key) {
          const r = (c.customApiKeyResponses ??= { approved: [], rejected: [] }), tail = key.slice(-20);
          r.approved = [...(r.approved || []).filter(x => x !== tail), tail].slice(-50);
          r.rejected = (r.rejected || []).filter(x => x !== tail);
        }
        ((c.projects ??= {})[process.cwd()] ??= {}).hasTrustDialogAccepted = true;
        put(file, c);
        if (process.argv[2] === 'skip') {
          const sf = path.join(dir, 'settings.json'), s = read(sf);
          if (s.skipDangerousModePermissionPrompt !== true) { s.skipDangerousModePermissionPrompt = true; put(sf, s); }
        }
        JS
        cat > /home/agent/.local/bin/claude <<'SH'
        #!/bin/sh
        # doz: Claude Code with its first-run setup done and, by default, its permission prompts off.
        mode=skip
        [ "${DOZ_CLAUDE_PERMISSIONS:-skip}" = ask ] && mode=ask
        [ "$(id -u)" = 0 ] && mode=ask
        node /usr/local/lib/dozer/claude-setup.js "$mode" || echo "doz: could not pre-seed Claude Code's setup" >&2
        # 594: the sandbox's facts, which the host writes at every session start, are appended to
        # Claude Code's system prompt — not for a subcommand, nor when the caller gives a prompt.
        p=/run/dozer/agent-prompt.md
        if [ -s "$p" ]; then
          case "$1" in
            mcp|plugin|plugins|setup-token|doctor|update|upgrade|install|config|migrate-installer|auth|agents) ;;
            *) case " $* " in
                 *" --append-system-prompt"*|*" --system-prompt"*) ;;
                 *) set -- --append-system-prompt "$(cat "$p")" "$@" ;;
               esac ;;
          esac
        fi
        [ "$mode" = skip ] && exec /usr/local/bin/claude --dangerously-skip-permissions "$@"
        exec /usr/local/bin/claude "$@"
        SH
        chmod 0755 /home/agent/.local/bin/claude /usr/local/lib/dozer
        chmod 0644 /usr/local/lib/dozer/claude-setup.js
        chown -R agent:agent /home/agent/.local
        """, needsNetworkFalse: ())

    /// The tools an interactive developer shell (and an agent) expects, which Debian's `-slim`
    /// base leaves out (owner, 591: "top/ps: command not found"; git was missing too). Installed
    /// from Debian's signed archive through the bake proxy. The same list for every agent image:
    /// it is the class baseline until base-layer images (one baked "dev base" that agent images
    /// clone) replace it.
    /// 594 (owner: pi printed "fd not found. Downloading... Failed to download fd"): `fd-find` too —
    /// pi (like many agents) wants `fd` and `rg` and downloads them from GitHub when they are missing.
    /// Debian names it `fdfind`; `/usr/local/bin/fd` is linked to it.
    /// 594 W23 (owner ruling 2026-09-30: "yes, passwordless sudo by default"): `sudo` too — the agent
    /// gets passwordless sudo at boot unless the sandbox's `agent_sudo` is off (the drop-in is written
    /// per boot, never baked: `GuestCommand.agentSudoScript`).
    public static let devBaselinePackages = ["procps", "git", "less", "jq", "unzip", "openssh-client",
                                             "ca-certificates", "curl", "vim-tiny", "ripgrep", "fd-find", "python3", "sudo", "apt-utils"]

    /// 594 W23: apt's package lists are KEPT in the image (they were deleted, so even root needed
    /// `apt-get update` before `apt-get install` worked). ~20–50 MB of the root disk, an APFS clone
    /// shared by every sandbox of the image — cheaper than every sandbox fetching them on first boot,
    /// and an install then works offline-first. They age with the image; `apt-get update` refreshes them.
    static let devBaseline = BakeStep.script("install the developer baseline (\(devBaselinePackages.joined(separator: " ")))", """
        export DEBIAN_FRONTEND=noninteractive
        # 594 (owner: "more progress detail"): apt's own lines (Get:, Unpacking, Setting up) are the
        # live tail the preparation card and the CLI show while this step runs — not silenced.
        apt-get update
        # 594 W24: apt-utils FIRST — without it every install (here and the agent's `sudo apt-get
        # install` later) says "debconf: delaying package configuration, since apt-utils is not installed".
        apt-get install -y --no-install-recommends -o Dpkg::Use-Pty=0 apt-utils
        apt-get install -y --no-install-recommends -o Dpkg::Use-Pty=0 \(devBaselinePackages.filter { $0 != "apt-utils" }.joined(separator: " "))
        ln -sf /usr/bin/fdfind /usr/local/bin/fd
        apt-get clean
        """)

    /// What the baseline must provide, checked after every agent bake. 594 W23: sudo, a sudoers
    /// drop-in `visudo -cf` accepts, and package lists apt can install from.
    static let devBaselineVerify: [VerifyCheck] = [
        VerifyCheck(["sh", "-c", "for t in ps top git less jq unzip ssh curl vi rg fd python3 sudo; do command -v $t >/dev/null || { echo missing $t; exit 1; }; done; echo baseline-ok"],
                    expect: "baseline-ok"),
        // The boot writes the rule only after /usr/sbin/visudo accepts it (as root: /etc/sudoers is 0440).
        VerifyCheck(["sh", "-c", "test -x /usr/bin/sudo && test -x /usr/sbin/visudo && test -d /etc/sudoers.d && echo sudoers-ok"],
                    expect: "sudoers-ok"),
        VerifyCheck(["sh", "-c", "apt-cache policy cowsay | grep -q Candidate: && ! apt-cache policy cowsay | grep -q 'Candidate: (none)' && echo apt-lists-ok"],
                    expect: "apt-lists-ok"),
    ]

    static func npmInstall(_ package: String, version: String, integrity: String, extraArgs: [String] = []) -> BakeStep {
        let extra = extraArgs.joined(separator: " ")
        return BakeStep.script("npm install \(package)@\(version) (integrity-pinned)", """
            cd "$(mktemp -d)"
            npm pack --silent '\(package)@\(version)' >/dev/null
            tgz=$(ls *.tgz)
            got="sha512-$(node -e 'process.stdout.write(require("crypto").createHash("sha512").update(require("fs").readFileSync(process.argv[1])).digest("base64"))' "$tgz")"
            [ "$got" = '\(integrity)' ] || { echo "integrity mismatch for \(package)@\(version): $got" >&2; exit 1; }
            npm install -g --no-fund --no-audit \(extra) "./$tgz"
            npm cache clean --force >/dev/null 2>&1 || true
            """, environment: ["NPM_CONFIG_UPDATE_NOTIFIER": "false"])
    }

    /// The claude-code image at the pinned version.
    public static let claudeCode = claudeCode(claudeCodePinned)

    public static func claudeCode(_ r: AgentRelease) -> ImageSpec {
        var s = ImageSpec(
            name: "claude-code",
            base: nodeBase,
            steps: [createAgent, devBaseline,
                    npmInstall(claudeCodePackage, version: r.version, integrity: r.integrity),
                    claudeLauncher],
            verify: [VerifyCheck(["claude", "--version"], expect: r.version),
                     VerifyCheck(["sh", "-c", "test -x /home/agent/.local/bin/claude && echo launcher-ok"], expect: "launcher-ok")]
                + devBaselineVerify,
            user: "agent", home: "/home/agent",
            // CLAUDE_CONFIG_DIR puts .claude.json INSIDE ~/.claude, so one directory holds all state.
            persistDirs: ["~/.claude"],
            // 594: Claude Code never updates itself in a sandbox (it could not write /usr/local, and a
            // sandbox keeps the version it was made with; a new image brings the new one). Its binary
            // honours both: DISABLE_AUTOUPDATER (the background updater) and DISABLE_UPDATES (every
            // update path, `claude update` included).
            sessionEnvironment: ["CLAUDE_CONFIG_DIR": "/home/agent/.claude", "DISABLE_AUTOUPDATER": "1", "DISABLE_UPDATES": "1",
                                 "PATH": "/home/agent/.local/bin:/usr/local/bin:/usr/bin:/bin"],
            rootfsMiB: 4096)
        s.agent = AgentPackage(package: claudeCodePackage, version: r.version)
        return s
    }

    /// The pi image at the pinned version.
    public static let pi = pi(piPinned)

    public static func pi(_ r: AgentRelease) -> ImageSpec {
        var s = ImageSpec(
            name: "pi",
            base: nodeBase,
            steps: [createAgent, devBaseline,
                    npmInstall(piPackage, version: r.version, integrity: r.integrity, extraArgs: ["--ignore-scripts"])],
            verify: [VerifyCheck(["pi", "--version"], expect: r.version)] + devBaselineVerify,
            user: "agent", home: "/home/agent",
            persistDirs: ["~/.pi/agent"],
            sessionEnvironment: ["PI_CODING_AGENT_DIR": "/home/agent/.pi/agent",
                                 "PATH": "/home/agent/.local/bin:/usr/local/bin:/usr/bin:/bin"],
            rootfsMiB: 4096)
        s.agent = AgentPackage(package: piPackage, version: r.version)
        return s
    }
}

extension BakeStep {
    static func script(_ name: String, _ script: String, needsNetworkFalse: Void) -> BakeStep {
        var s = BakeStep.script(name, script)
        s.needsNetwork = false
        return s
    }
}
