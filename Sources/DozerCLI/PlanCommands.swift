import ArgumentParser
import Foundation
import DozerKit
import DozerHost

// 617 (616.03 §6 2b, D13) — the plan every making command can show first: `--dry-run` on new, create, up and try asks
// the host's read-only `plan` op (in-process when no host runs — looking never starts one) and prints the three parts:
// the command (only what differs from your defaults), the same choices as doz_project.yaml, and what it can reach.

/// The host's plan of `r`.
func requestPlan(_ r: PlanRequest, _ g: GlobalOptions) async throws -> CreatePlan {
    await ModelNote.check(r.create, g)          // 618: a gateway's model id it does not list
    var q = HostRequest(.plan)
    q.planRequest = r
    return try decode(try await query(q, g), CreatePlan.self, g)
}

/// The plan as a person reads it (`--json`: as data).
func printPlan(_ p: CreatePlan, _ g: GlobalOptions) {
    if g.json { Out.json(p); return }
    Out.stdout(renderPlan(p))
}

func renderPlan(_ p: CreatePlan) -> String {
    var s = "\(p.command)\n"
    let image = (p.imageState.title ?? p.imageState.name) + " — " + [
        "prepared": "ready now", "older": "made by an older Dozer (used as it is)", "unprepared": "prepared on first use (a few minutes, once)",
    ][p.imageState.state, default: p.imageState.state]
    s += "  makes \(p.name)\(p.trial == true ? " (a try)" : ""): \(image)\n"
    // 618: the release it installs; a family's major and how to get the other.
    if let v = p.version {
        s += "  version: " + (v.familyLine(command: p.purpose == "try" ? "doz try" : "--agent") ?? "\(v.title) \(v.version ?? "(at its preparation)")") + "\n"
    }
    if let a = p.account, a.kind == "none", let src = a.provider {
        s += "  account: none — \(ModelSources.title(src)) needs no key\n"
    } else if let a = p.account {
        s += "  account: " + (a.name.map { "\($0)" + (a.kind.map { " (\($0)\(a.provider.map { ", \($0)" } ?? ""))" } ?? "") + (a.sourceLabel.map { " — key from \($0)" } ?? "") } ?? "none") + "\n"
    }
    // 617 (models@1): the model and where it goes; the other providers and gateways it can use, and how.
    if let m = p.model {
        s += "  model: \(m.model) through \(m.title)\n"
        let others = m.offered.filter { $0.id != m.source }
        if !others.isEmpty {
            s += "  can also use: " + others.map { "\($0.gateway ? "--gateway" : "--provider") \($0.id)" }.joined(separator: " · ") + " (and --model)\n"
        }
    }
    s += "What it can reach:\n"
    for r in p.reach {
        let mark = r.text.hasPrefix("No ") ? "✗" : ["denied": "✗", "excluded": "✗", "folder": "·", "key": "·"][r.kind] ?? "✓"
        s += "  \(mark) \(r.text)\n"
    }
    s += "\(DozerProject.fileName) with the same choices (doz init writes it; commented keys take their defaults):\n"
    for l in p.yaml.split(separator: "\n", omittingEmptySubsequences: false) where !l.hasPrefix("#") && !l.trimmingCharacters(in: .whitespaces).isEmpty {
        s += "  | \(l)\n"
    }
    if let n = p.yamlNote { s += "  (\(n))\n" }
    if !p.problems.isEmpty {
        s += "In the way:\n"
        for pr in p.problems { s += "  ✗ \(pr.text)" + (pr.fix.map { pr.text.contains($0) ? "" : " — \($0)" } ?? "") + "\n" }
    }
    return s
}
