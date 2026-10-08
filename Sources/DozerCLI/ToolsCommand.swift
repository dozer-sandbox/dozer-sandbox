import ArgumentParser
import Foundation
import DozerKit
import DozerHost

// 599h — `doz tools NAME`: the sandbox's tools layer — the tools Dozer manages from its settings (gh for GitHub
// as you, the ssh client and github.com's host keys for SSH agent forwarding, tmux, and always git, curl and
// ca-certificates): why each is there, where it comes from, and what the last start or wake did.

struct ToolsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tools",
        abstract: "A sandbox's tools layer: the tools Dozer manages from its settings, why, and their state (--apply: set them up again now).",
        discussion: """
        Dozer puts tools into a sandbox because of its settings — gh for "Use GitHub as you", an ssh client and \
        github.com's host keys for SSH agent forwarding, tmux for sessions.tmux, and always git, curl and \
        ca-certificates — at every start and wake, on every base, without rebuilding an image. gh is \
        downloaded once to this Mac (pinned, sha256 checked) and copied in; packages come from apt or apk \
        through the proxy when missing.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox.") var name: String
    @Flag(name: .long, help: "Set the tools up again now (the sandbox must be running), each shown as a step.") var apply = false

    func run() async throws {
        var r = HostRequest(apply ? .toolsApply : .tools, name: name)
        r.name = name
        let rep = try decode(try call(r, g), ToolsLayerReport.self, g)
        if g.json { Out.json(rep); return }
        Out.stdout("Tools layer of \(rep.sandbox) — from its settings:\n")
        let last = Dictionary((rep.last?.results ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for item in rep.plan.items {
            let mark: String
            let state: String
            if let r = last[item.id] { mark = r.ok ? "✓" : "✗"; state = r.detail } else { mark = "·"; state = "not set up yet (at the next start or wake)" }
            Out.stdout("  \(mark) \(item.title.padding(toLength: 22, withPad: " ", startingAt: 0)) \(item.reason.padding(toLength: 26, withPad: " ", startingAt: 0)) \(state)\n")
        }
        for r in (rep.last?.results ?? []) where !rep.plan.items.contains(where: { $0.id == r.id }) {
            Out.stdout("  – \(r.title.padding(toLength: 22, withPad: " ", startingAt: 0)) \(r.reason.padding(toLength: 26, withPad: " ", startingAt: 0)) \(r.state): \(r.detail)\n")
        }
        if let at = rep.last?.at { Out.stdout("\nLast set up: \(at.formatted(date: .abbreviated, time: .standard))\n") }
        for c in rep.cached { Out.stdout("On this Mac: \(c.id) \(c.version) (\(c.bytes / 1_048_576) MB, sha256 \(c.sha256.prefix(12))…) — \(c.path)\n") }
    }
}
