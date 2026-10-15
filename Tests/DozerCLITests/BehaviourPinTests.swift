import CryptoKit
import Foundation
import XCTest
import DozerKit
@testable import DozerCLI
@testable import DozerHost
@testable import DozerWeb

/// 617 step 0 — the "behaviour pin": what the three existing agents (Claude Code, pi, Codex) and no agent DO today,
/// captured BEFORE the agent-recipe refactor (`AgentKind` becomes a recipe-backed struct; credentials, sessions,
/// permissions, settings and the wizard's choices come from recipe data). Every golden below was computed at the
/// tree of 4b5e9ac + the 617 claim (VERSION 0.34.0) with no 617 change. The refactor must keep every line; a line
/// may only change in a commit that says why (and then the golden changes with it, on purpose).
final class BehaviourPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("behaviour-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    static func sha(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// The image names every pin walks: the old three, Codex's, every catalogue base × agent, and a Dockerfile's.
    static var imageNames: [String] {
        var names = ["lab", "claude-code", "pi", "codex"]
        for b in BaseCatalogue.all {
            for a in AgentKind.allCases { names.append(ImageChoice(base: b.id, agent: a).name) }
        }
        for a in AgentKind.allCases { names.append(ImageChoice(base: "df-0123456789ab", agent: a).name) }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    // MARK: names

    /// `AgentKind`'s cases in order, their titles, and the name ↔ pair rule (incl. the long forms of the old names).
    func test_agentKindsAndImageNames() {
        var lines = AgentKind.allCases.map { "kind \($0.rawValue) \($0.title)" }
        for n in Self.imageNames + ["node-claude-code", "node-pi", "node-codex", "alpine", "cobol-pi", "custom:mine", "python-claude"] {
            let c = ImageChoice.parse(n)
            lines.append("parse \(n) → \(c.map { "\($0.base) \($0.agent.rawValue) \($0.name) \($0.title)" } ?? "nil") base-name \(Workspace.baseName(image: n))")
        }
        let text = lines.joined(separator: "\n")
        Pins.check(#function, text)
    }

    // MARK: credentials, names, packages

    func test_agentImagesTables() {
        var lines: [String] = []
        for n in Self.imageNames {
            let cred = AgentImages.credentials(n).map { $0.map { "\($0.provider):\($0.accountKinds.joined(separator: ","))" }.joined(separator: ";") } ?? "nil"
            lines.append("\(n) credentials=\(cred) agentName=\(AgentImages.agentName(n) ?? "nil") package=\(AgentImages.package(n) ?? "nil") pinned=\(AgentImages.pinned(n).map { "\($0.version) \($0.integrity)" } ?? "nil")")
        }
        let text = lines.joined(separator: "\n")
        Pins.check(#function, text)
    }

    // MARK: sessions

    /// The default session of a sandbox of every image (by its agent), and what a restart appends.
    func test_defaultSessionsAndResume() throws {
        let store = DozerStore(root: root)
        var lines: [String] = []
        for n in ["lab", "claude-code", "pi", "codex", "python-claude-code", "go-pi", "alpine-codex", "debian", "ubuntu-pi", "rust-codex"] {
            let (s, image) = try DozerImages.spec(name: "x", options: CreateOptions(image: n), store: store, environment: [:])
            let d = SandboxConfig(name: "x", image: image, spec: s, workspace: nil).defaultSession
            lines.append("\(n) → image \(image) session \(d.name) argv \(d.argv.joined(separator: " "))")
        }
        for a in AgentKind.allCases {
            lines.append("resume \(a.rawValue) \(SessionResume.arguments(for: a).joined(separator: " ")) check=\(SessionResume.check(for: a) ?? "nil")")
        }
        lines.append("resume nil \(SessionResume.arguments(for: nil).joined(separator: " "))")
        let text = lines.joined(separator: "\n")
        Pins.check(#function, text)
    }

    /// `claude.permissions` / `codex.permissions` → the launcher's variable, per image.
    func test_permissionsSettingsReachTheirLauncherOnly() {
        let ask = DozerSettings(text: "[claude]\npermissions = \"ask\"\n\n[codex]\npermissions = \"ask\"\n")
        var lines: [String] = []
        for n in ["lab", "claude-code", "pi", "codex", "python-claude-code", "alpine-codex", "go-pi", "debian"] {
            let env = HostCore.withClaudePermissions([:], imageSpec: n, settings: ask)
            lines.append("\(n) \(env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))")
        }
        let text = lines.joined(separator: "\n")
        Pins.check(#function, text)
    }

    // MARK: permissions

    /// The catalogue (ids, titles, hosts), each agent's own permissions, and every preset per base (D5: the
    /// existing agents keep exactly these presets — Locked = ["model"]).
    func test_agentPermissionsAndPresets() {
        var lines: [String] = []
        for p in AgentPermissions.all {
            lines.append("perm \(p.id) locked=\(p.locked) hosts=\(p.hosts.map { "\($0.host)\($0.pathPrefixes.map { "[" + $0.joined(separator: ",") + "]" } ?? "")" }.joined(separator: " "))")
        }
        for a in AgentKind.allCases { lines.append("agentPermissions \(a.rawValue) \(AgentPermissions.agentPermissions(a))") }
        lines.append("agentPermissions nil \(AgentPermissions.agentPermissions(nil))")
        for b in [nil] + BaseCatalogue.ids.map(Optional.some) {
            for p in ["locked", "agent", "standard", "open"] {
                let names = AgentPermissions.preset(p, base: b) ?? []
                lines.append("preset \(p) base=\(b ?? "nil") \(names.joined(separator: ",")) name=\(AgentPermissions.presetName(names, base: b) ?? "nil")")
            }
        }
        let text = lines.joined(separator: "\n")
        Pins.check(#function, text)
    }

    /// The policy a NEW sandbox of each image gets (default settings): network, preset, permissions in order —
    /// and with each preset named, so `agentPermissions` and the base's registries show.
    func test_newSandboxPolicies() throws {
        let store = DozerStore(root: root)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var lines: [String] = []
        for n in ["lab", "claude-code", "pi", "codex", "python-codex", "alpine-pi", "go-claude-code", "debian"] {
            for net in [nil, "agent", "locked", "open", "bake"] as [String?] {
                let (s, _) = try DozerImages.spec(name: "x", options: CreateOptions(image: n, network: net), store: store, environment: [:])
                // A rule's id is minted per rule — not behaviour; everything else is.
                let policy = s.network.policy.map { String(decoding: (try? enc.encode($0)) ?? Data(), as: UTF8.self) }?
                    .replacingOccurrences(of: #""id":"[0-9A-Fa-f-]+","#, with: "", options: .regularExpression) ?? "nil"
                lines.append("\(n) net=\(net ?? "default") \(DozerImages.networkName(s.network)) \(policy)")
            }
        }
        let text = lines.joined(separator: "\n")
        Pins.check(#function, text)
    }

    // MARK: settings and the web

    /// The generated `doz.toml` with nothing set (every key, its default and description).
    func test_settingsFileRender() {
        let text = DozerSettings.render(values: [:])
        Pins.check(#function, text)
    }

    /// The wizard's agent choices.
    func test_webAgentChoices() {
        XCTAssertEqual(WebBases.agentChoices, [["claude-code", "Claude Code"], ["pi", "pi"], ["none", "none — a shell only"]])
    }
}
