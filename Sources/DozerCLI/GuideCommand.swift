import ArgumentParser
import Foundation
import DozerKit
import DozerHost

// 617.11 (owner: "our companion guide"): `doz guide NAME` — the sandbox page's Guide tab in a terminal: what its agent or
// tool is, this sandbox's facts (version, key and model, network, folder), the first steps and the tips. Looking: it
// never starts a host.

struct GuideCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "guide",
        abstract: "How to use a sandbox's agent or tool: what it is, this sandbox's facts, the first steps (commands to run) and tips.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox.") var name: String

    func run() async throws {
        let d = try decode(try await query(HostRequest(.inspect, name: name), g), SandboxDetail.self, g)
        guard let guide = d.guide else {
            throw fail(HostError(.notFound, "\(name) has no guide — its image runs no agent or tool Dozer has a recipe for"), g)
        }
        if g.json { Out.json(guide); return }
        Out.stdout(guide.plainText())
    }
}
