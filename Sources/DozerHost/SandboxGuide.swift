import Foundation
import DozerKit

// 617.11 (owner: "i tried fabric and it just gave me a terminal … our companion guide"): the guide a recipe agent's
// sandbox shows — the sandbox page's Guide tab (first on a try), `doz guide NAME`, `doz try`'s "Start here". DOZER writes
// the preamble and the facts ("This try") from the sandbox itself — the version, the key and model, the network, the
// folder, where its settings live — never the recipe; the recipe gives only its intro, steps, tips and docs (guide@1).
// No secret, ever: an account's NAME, a source's title.

public struct SandboxGuide: Codable, Equatable, Sendable {
    public struct Fact: Codable, Equatable, Sendable {
        /// `version` | `model` | `network` | `folder` | `settings` — what the page links (network → its tab).
        public var id: String
        public var label: String
        public var value: String
        public init(id: String, label: String, value: String) { self.id = id; self.label = label; self.value = value }
    }
    public struct Step: Codable, Equatable, Sendable {
        public var text: String
        public var command: String?
        public var edit: Bool?
    }

    public var agent: String
    public var title: String
    public var publisher: String
    public var licence: String
    /// "a command-line tool" | "a coding agent" | "an AI tool".
    public var what: String
    /// `shell` (it answers in the shell and exits: steps run in its own session) | `screen` (its session is its own
    /// screen: steps run in a shell beside it).
    public var session: String
    /// The session steps run in: `shell` → the default session; `screen` → a shell session (not the agent's).
    public var agentSession: String
    /// Dozer's line on how to use it here.
    public var howTo: String
    /// The recipe's intro.
    public var intro: String
    public var trial: Bool
    public var facts: [Fact]
    public var steps: [Step]
    public var tips: [String]
    public var docs: String?
    public var homepage: String?
    public var checked: String?

    /// The guide of `recipe` in a sandbox with these facts (pure — the host and the tests call it).
    public static func make(_ r: AgentRecipe, version: String?, source: String?, model: String?, account: String?, accountKind: AccountKind?,
                            network: String, workspace: String?, trial: Bool) -> SandboxGuide? {
        guard let g = r.guide else { return nil }
        let shell = r.launch.session == "shell"
        let what = r.catalogKind == "coding-agent" ? "a coding agent" : shell ? "a command-line tool" : "an AI tool"
        let howTo = shell
            ? "It answers in your shell and exits: type its commands in the terminal, or press Run below."
            : "Its session is its own screen (the terminal): talk to it there. The commands below run in a shell beside it — open one with New shell."
        var facts: [Fact] = []
        let v = (version ?? r.install.pinned.version).split(separator: "+").first.map(String.init) ?? r.install.pinned.version
        var versionLine = "\(r.title) \(v)" + (r.isBuiltin || v != r.install.pinned.version ? "" : " (Dozer's pin)")
        // 618: a family's major — which one, and how to get the others (a sandbox never changes major).
        if let f = r.family {
            if f.isRecommended { versionLine += " · recommended" }
            let others = AgentRef.members(f.family).filter { $0.id != r.id }.map { "\($0.family!.title): doz try \(AgentRef.typed($0))" }
            if !others.isEmpty { versionLine += " — " + others.joined(separator: " · ") }
        }
        facts.append(Fact(id: "version", label: "Version", value: versionLine))
        let keyLine: String = {
            guard let account else { return "no key yet — the sandbox has no account" }
            if accountKind == .mac { return "your Claude Code login on this Mac — the sandbox holds a placeholder" }
            if accountKind == .codexMac { return "this Mac's Codex login — the sandbox holds a placeholder" }
            return "your key \(account) stays on the Mac; the sandbox holds a placeholder"
        }()
        let src = source.map(ModelSources.title)
        facts.append(Fact(id: "model", label: "Model", value: [src, model].compactMap { $0 }.joined(separator: " · ") + (src == nil && model == nil ? "" : " — ") + keyLine))
        facts.append(Fact(id: "network", label: "Reaches", value: network))
        facts.append(Fact(id: "folder", label: "Folder", value: workspace.map { "/workspace = \($0)" }
            ?? "/workspace is the sandbox's own (isolated) — doz get copies files out"))
        if !r.state.persist.isEmpty {
            facts.append(Fact(id: "settings", label: "Settings", value: r.state.persist.joined(separator: ", ") + " (kept on the state disk)"))
        }
        let what2 = [r.publisher.isEmpty ? nil : "by " + r.publisher, r.licence.isEmpty ? nil : r.licence, what].compactMap { $0 }.joined(separator: " · ")
        return SandboxGuide(agent: r.id, title: r.title, publisher: r.publisher, licence: r.licence, what: what2, session: shell ? "shell" : "screen",
                            agentSession: r.shortName, howTo: howTo, intro: g.intro, trial: trial, facts: facts,
                            steps: g.steps.map { Step(text: $0.text, command: $0.command, edit: $0.edit) }, tips: g.tips ?? [], docs: g.docs,
                            homepage: r.homepage, checked: r.checked)
    }

    /// The guide as text (`doz guide`, `doz try`'s "Start here" with `stepsOnly`).
    public func plainText(stepsOnly: Bool = false) -> String {
        var s = ""
        if !stepsOnly {
            s += "\(title) — \(what)\n\(intro)\n\(howTo)\n\n"
            s += (trial ? "This try\n" : "This sandbox\n")
            for f in facts { s += "  \(f.label): \(f.value)\n" }
            s += "\n"
        }
        s += "Start here\n"
        for (i, st) in steps.enumerated() {
            s += "  \(i + 1). \(st.text)\n"
            if let c = st.command { s += "       \(c)" + (st.edit == true ? "    (change it first)" : "") + "\n" }
        }
        if !stepsOnly {
            if !tips.isEmpty {
                s += "\nGood to know\n"
                for t in tips { s += "  · \(t)\n" }
            }
            if let d = docs { s += "\nDocs: \(d)\n" }
            if let c = checked { s += "Recipe checked \(c)\n" }
        }
        return s
    }
}

extension HostCore {
    /// The guide of a recipe agent's sandbox (nil: no agent, or a recipe with no guide).
    func guide(_ m: Managed) -> SandboxGuide? {
        guard let r = m.config.imageChoice?.agent.recipe else { return nil }
        let file = accountStore.load()
        var account: String?, kind: AccountKind?
        if case .record(let a) = resolvedAccount(m, file) { account = a.name; kind = a.kind }
        let sel = modelSelection(m)
        let source = sel?.source ?? (r.isBuiltin ? nil : AgentCredentials.keyProvider(m.config.imageChoice?.name)?.id)
        let policy = m.sandbox.egress?.policy ?? m.config.spec.network.policy
        let network: String = {
            guard let p = policy else { return "network \(m.config.networkName) (not proxied)" }
            switch p.preset {
            case "locked"?: return "its model only (Locked)"
            case "agent"?: return "Standard: its model, package installs, GitHub (Network lists them)"
            case "open"?: return "Open: the web, every host (logged)"
            default: return "its permissions (Network lists them)"
            }
        }()
        return SandboxGuide.make(r, version: m.config.spec.imageSpec?.agent?.version, source: source, model: sel?.model, account: account, accountKind: kind,
                                 network: network, workspace: m.config.workspace, trial: m.config.trial == true)
    }
}

extension HostCore {
    /// 617.11: a tool whose session is a shell (Fabric, llm …): its guide's first steps are shown ONCE, in the first login
    /// shell on a terminal (`/etc/profile.d/doz-guide.sh`, a stamp in the user's state folder) — so a plain terminal
    /// (`doz attach`) is not left at a bare prompt either. Never for an agent with its own screen. Best effort.
    func deliverGuideNote(_ m: Managed) async {
        guard let r = m.config.imageChoice?.agent.recipe, r.launch.session == "shell", let g = guide(m) else { return }
        let text = "\n" + g.intro + "\n" + g.plainText(stepsOnly: true) + "(doz guide " + m.name + " on the Mac, or the Guide tab, has it all)\n\n"
        let b64 = Data(text.utf8).base64EncodedString()
        let script = """
            mkdir -p /etc/dozer /etc/profile.d
            printf '%s' '\(b64)' | base64 -d > /etc/dozer/guide.txt
            cat > /etc/profile.d/doz-guide.sh <<'DOZGUIDE'
            # doz: this tool's first steps, once, in the first login shell on a terminal
            if [ -t 1 ] && [ -r /etc/dozer/guide.txt ]; then
              doz_guide_stamp="/Users/jscott/.local/state/dozer/guide-shown"
              if [ ! -e "" ]; then
                cat /etc/dozer/guide.txt
                mkdir -p "" 2>/dev/null && : > ""
              fi
              unset doz_guide_stamp
            fi
            DOZGUIDE
            chmod 0644 /etc/dozer/guide.txt /etc/profile.d/doz-guide.sh
            """
        do {
            let res = try await m.sandbox.exec(["sh", "-c", script], timeoutSeconds: 20)
            if res.exitCode != 0 { note(m.name, "could not write the guide's note (exit \(res.exitCode))") }
        } catch {
            note(m.name, "could not write the guide's note: \(error.localizedDescription)")
        }
    }
}
