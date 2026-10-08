import Foundation
import DozerKit

// 594 — onboarding, the parts `doz onboard` and the UI's wizard share: which checks stop it (D5),
// what each image costs (D2), the settings file written only when missing (D7) and the user's
// prompt template beside it (D16). The work itself — preparing images — is the host's (`onboard`).

/// One check as onboarding presents it: the doctor's finding, and whether it stops onboarding.
public struct OnboardingCheck: Codable, Equatable, Sendable {
    public var check: String
    /// ok · warn · fail
    public var status: String
    public var detail: String
    /// A hard check stops onboarding when it is not ok (D5); a soft one only warns.
    public var hard: Bool

    public init(check: String, status: String, detail: String, hard: Bool) {
        self.check = check
        self.status = status
        self.detail = detail
        self.hard = hard
    }

    public var blocks: Bool { hard && status == "fail" }
}

/// A built-in image as the onboarding checklist shows it (D2).
public struct OnboardingImage: Codable, Equatable, Sendable {
    public var name: String
    public var summary: String
    /// What a first preparation downloads, for people.
    public var download: String
    /// About how long a first preparation takes (measured on the owner's network, 2026-09-29).
    public var estimate: String
    /// What it needs on disk (an estimate, with its share of the common parts).
    public var diskBytes: Int64
    public var prepared: Bool
    /// Ticked by default: claude-code (D2).
    public var recommended: Bool
}

public enum Onboarding {
    /// D5: the checks that stop onboarding when they fail. Everything else only warns (Claude Code
    /// missing or signed out: the claude-code image still works with an account added later; vmnet:
    /// only `--network nat` needs it).
    public static let hardChecks: Set<String> = ["macOS", "chip", "virtualization", "entitlement", "guest tools", "socket", "store", "disk"]

    /// The images onboarding offers, in order.
    public static let images: [(name: String, summary: String, download: String, estimate: String, bytes: Int64)] = [
        // 594 W6: {version} is what WILL be installed (`agentVersionText`), never a stale pin.
        ("claude-code", "Claude Code — {version} — on Debian (node), with git, ripgrep, python3 and the usual tools",
         "~80 MB base image + Claude Code + Debian packages", "~4–6 min the first time", 900 << 20),
        ("pi", "the pi coding agent — {version} — on the same Debian base (shared with claude-code)",
         "~80 MB base image (shared) + npm packages", "~10–15 min the first time", 700 << 20),
        // 599i: OpenAI's Codex CLI — the same Debian base; it signs in with your ChatGPT plan (Dozer's own sign-in) or an OpenAI key.
        ("codex", "OpenAI Codex — {version} — on the same Debian base (shared with claude-code); uses your ChatGPT plan or an OpenAI key",
         "~80 MB base image (shared) + Codex (~160 MB)", "~4–6 min the first time", 900 << 20),
        ("lab", "Alpine 3.20 with bash — a plain Linux shell, no agent",
         "~4 MB", "~1 min", 100 << 20),
    ]

    /// What every first preparation needs besides the images: the kernel archive (downloaded, then
    /// only its kernel kept) and the guest init disk.
    public static let commonBytes: Int64 = 700 << 20
    /// The agent images' shared Debian node base (pulled and flattened once, for claude-code and pi).
    public static let nodeBaseBytes: Int64 = 500 << 20
    public static let nodeBaseImages: Set<String> = ["claude-code", "pi", "codex"]
    /// Room left over after the images, so a first sandbox still fits.
    public static let headroomBytes: Int64 = 2 << 30

    /// 594 W6: the agent version a preparation of `image` installs, for people: an exact setting as
    /// it is; `latest` with the registry's answer from the hourly cache ("latest (2.1.285)"); plain
    /// "latest" when it was never asked or is unreachable. nil: not an agent image.
    public static func agentVersionText(_ image: String, store: DozerStore, settings: DozerSettings) -> String? {
        guard AgentImages.package(image) != nil else { return nil }
        let want = AgentVersions.setting(image, settings)
        guard want == "latest" else { return want }
        return AgentVersions.all(store)[image]?.latest.map { "latest (\($0.version))" } ?? "latest"
    }

    /// `versions`: image → what `agentVersionText` says (missing: "latest").
    public static func imageOptions(_ rows: [ImageRow], versions: [String: String] = [:]) -> [OnboardingImage] {
        images.map { i in
            OnboardingImage(name: i.name, summary: i.summary.replacingOccurrences(of: "{version}", with: versions[i.name] ?? "latest"),
                            download: i.download, estimate: i.estimate, diskBytes: i.bytes,
                            prepared: rows.first { $0.name == i.name }.map { $0.current ?? $0.baked } ?? false, recommended: i.name == "claude-code")
        }
    }

    /// The disk the chosen images need (0 when all are prepared).
    public static func requiredBytes(_ chosen: [String], prepared: Set<String>) -> Int64 {
        let todo = chosen.filter { !prepared.contains($0) }
        guard !todo.isEmpty else { return 0 }
        let base = todo.contains(where: nodeBaseImages.contains) ? nodeBaseBytes : 0
        return commonBytes + base + headroomBytes + todo.reduce(0) { sum, n in sum + (images.first { $0.name == n }?.bytes ?? 0) }
    }

    /// The volume a store is (or will be) on: its nearest existing directory's format and free space.
    public static func volume(of store: DozerStore) -> (apfs: Bool, free: Int64, format: String)? {
        var url = store.root
        let fm = FileManager.default
        while !fm.fileExists(atPath: url.path), url.path != "/" { url = url.deletingLastPathComponent() }
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedFormatDescriptionKey]) else { return nil }
        let format = v.volumeLocalizedFormatDescription ?? "?"
        return (format.contains("APFS"), v.volumeAvailableCapacityForImportantUsage ?? 0, format)
    }

    /// The doctor's findings (`check`, `status`, `detail`) as onboarding checks: the store's own
    /// finding is replaced by the two that matter here — APFS, and room for the chosen images.
    public static func checks(doctor: [(check: String, status: String, detail: String)], store: DozerStore,
                              chosen: [String], prepared: Set<String>) -> [OnboardingCheck] {
        var out: [OnboardingCheck] = []
        for d in doctor where d.check != "store" {
            out.append(OnboardingCheck(check: d.check, status: d.status, detail: d.detail, hard: hardChecks.contains(d.check)))
        }
        if let v = volume(of: store) {
            out.append(OnboardingCheck(check: "store", status: v.apfs ? "ok" : "fail",
                                       detail: "\(store.root.path) — \(v.format)" + (v.apfs ? "" : " — the store must be on APFS (disks are APFS clones); pick another with --store"),
                                       hard: true))
            let need = requiredBytes(chosen, prepared: prepared)
            out.append(OnboardingCheck(check: "disk", status: v.free >= need ? "ok" : "fail",
                                       detail: "\(DozerImages.formatBytes(v.free)) free"
                                       + (need == 0 ? "" : ", the chosen images need about \(DozerImages.formatBytes(need)) (with room for a first sandbox)")
                                       + (v.free >= need ? "" : " — free some space, or choose fewer images"),
                                       hard: true))
        }
        return out
    }

    // MARK: D6 — the Claude account

    /// The account step's answers. Onboarding never logs in and never touches Claude Code's refresh
    /// token (588). A key or a setup token is added exactly as `doz account add` adds one (the login
    /// keychain, the one check request): pasted at a no-echo prompt in `doz onboard`, typed in a masked
    /// field in the UI (while `ui.allow_secret_entry`), or — when neither — with the CLI command shown.
    public enum Account: String, Codable, Sendable, CaseIterable {
        /// This Mac's own Claude Code login (the built-in account `mac`) — the store default.
        case mac
        /// An Anthropic API key / a Claude setup token, added now and made the store default.
        case apiKey = "api-key"
        case setupToken = "setup-token"
        /// Change nothing now (owner ruling: "No account for now" and "Skip" are one option).
        case later

        public var label: String {
            switch self {
            case .mac: "Use this Mac's Claude Code login (the account mac)"
            case .apiKey: "Add an Anthropic API key"
            case .setupToken: "Add a Claude setup token (claude setup-token)"
            case .later: "Decide later"
            }
        }
    }

    /// D6: what the step offers on this Mac, and its default — the Mac's login when Claude Code is
    /// signed in on it; otherwise a key, a token, or later.
    public static func accountOptions(macSignedIn: Bool) -> (options: [Account], preferred: Account) {
        macSignedIn ? ([.mac, .apiKey, .setupToken, .later], .mac) : ([.apiKey, .setupToken, .mac, .later], .later)
    }

    /// The commands a choice that needs a secret leaves to run (nothing is run for you).
    public static func accountCommands(_ a: Account) -> [String] {
        switch a {
        case .apiKey: ["doz account add work --api-key       (it asks for the key, not echoed)", "doz account default work"]
        case .setupToken: ["claude setup-token                    (on this Mac: prints a 1-year token)",
                           "doz account add work --setup-token   (paste it; not echoed)", "doz account default work"]
        default: []
        }
    }

    /// The store default a choice sets by itself (a key or a token: the account added, once it is).
    public static func defaultAccount(for a: Account) -> String? {
        a == .mac ? "mac" : nil
    }

    // MARK: D7 — the settings file, only when missing

    public enum ConfigOutcome: String, Codable, Sendable {
        /// Written now, with the onboarding's answers as its only set values.
        case written
        /// There already was one: left exactly as it is.
        case kept
        /// Neither XDG_CONFIG_HOME nor HOME: there is no place for it.
        case unavailable
    }

    /// Write doz.toml (every setting listed with its default, commented) with `defaults.image` and
    /// `defaults.account` set — only when there is no file. An existing one is never touched.
    public static func writeSettingsIfMissing(defaultImage: String?, account: String?,
                                              environment: [String: String] = ProcessInfo.processInfo.environment) throws -> (ConfigOutcome, String?) {
        guard let url = DozerSettings.fileURL(environment: environment) else { return (.unavailable, nil) }
        var st = stat()
        if lstat(url.path, &st) == 0 { return (.kept, url.path) }
        var values: [String: TOMLValue] = [:]
        if let defaultImage, let d = DozerSettings.definition(SettingKey.defaultImage) { values[d.key] = try d.validate(.string(defaultImage)) }
        if let account, let d = DozerSettings.definition(SettingKey.defaultAccount) { values[d.key] = try d.validate(.string(account)) }
        try DozerSettings.writeAtomically(DozerSettings.render(values: values), to: url)
        return (.written, url.path)
    }

    /// Write the user's prompt template starter (all of it inside a comment: it changes nothing until
    /// edited) — only when there is none.
    public static func writePromptTemplateIfMissing(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> (ConfigOutcome, String?) {
        guard let url = AgentPrompt.userTemplateURL(environment: environment) else { return (.unavailable, nil) }
        var st = stat()
        if lstat(url.path, &st) == 0 { return (.kept, url.path) }
        try DozerSettings.writeAtomically(AgentPrompt.userTemplateStarter, to: url)
        return (.written, url.path)
    }
}
