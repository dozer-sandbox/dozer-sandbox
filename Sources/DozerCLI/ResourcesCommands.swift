import ArgumentParser
import Foundation
import DozerKit
import DozerHost

// 595 (R6): everything Dozer uses — disk to the byte, memory, CPUs, proxy traffic — and deleting what
// has no other home. `doz image rm`, `doz point rm`, `doz rm` stay where they are.

struct ResourcesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resources",
        abstract: "Everything Dozer uses (disk to the byte, memory, CPUs, network) and deleting what can go.",
        subcommands: [ResourcesList.self, ResourcesRemove.self, ResourcesClean.self, ResourcesKernel.self],
        defaultSubcommand: ResourcesList.self)
}

struct ResourcesList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "The account: every byte of the store on a row (the last row, unattributed, is ~0), then memory, CPUs, traffic and kernels.")
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        let rep = try decode(try await query(HostRequest(.resources), g), ResourceReport.self, g)
        if g.json { Out.json(rep) } else { Out.stdout(renderResources(rep)) }
    }
}

struct ResourcesRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete resources by id (doz resources lists them): shows what goes, what it frees and what each costs later, then asks once.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "Resource ids, as doz resources lists them (e.g. cache:downloads, kernel:6.12.1, point:web/3).") var ids: [String]
    @Flag(name: .long, help: "Show the plan; delete nothing.") var dryRun = false
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false
    func run() async throws {
        try await runResourcesPlan(ids: ids, clean: false, dryRun: dryRun, yes: yes, g)
    }
}

struct ResourcesClean: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clean", abstract: "Delete what is re-creatable AND unused: the download cache, base disks, old kernels, images no sandbox was created from lately, leftovers. Never templates, sandboxes, restore points, settings or keys.")
    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "Show the plan; delete nothing.") var dryRun = false
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false
    func run() async throws {
        try await runResourcesPlan(ids: [], clean: true, dryRun: dryRun, yes: yes, g)
    }
}

struct ResourcesKernel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "kernel", abstract: "The kernel NEW sandboxes boot: a kernel:<version> doz resources lists, or pinned (this build's). Existing sandboxes keep theirs.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "kernel:<version> or pinned.") var kernel: String
    func run() async throws {
        var r = HostRequest(.resourcesKernel)
        r.kernel = kernel
        let c = try decode(try call(r, g), ResourceKernelChoice.self, g)
        if g.json { Out.json(c) } else { Out.stdout("new sandboxes boot \(c.kernel) — \(c.note)\n") }
    }
}

func runResourcesPlan(ids: [String], clean: Bool, dryRun: Bool, yes: Bool, _ g: GlobalOptions) async throws {
    var r = HostRequest(clean ? .resourcesClean : .resourcesRemove)
    r.ids = clean ? nil : ids
    r.dryRun = true
    let plan = try decode(try await query(r, g), ResourcePlan.self, g)
    if dryRun {
        if g.json { Out.json(plan) } else { Out.stdout(renderResourcePlan(plan)) }
        return
    }
    if plan.items.isEmpty {
        if g.json { Out.json(plan) } else { Out.stdout(renderResourcePlan(plan)) }
        if !plan.refused.isEmpty { throw ExitCode(DozerExit.failed) }
        return
    }
    if !g.json { Out.stderr(renderResourcePlan(plan)) }
    try confirm("Delete \(plan.items.count) item\(plan.items.count == 1 ? "" : "s") (frees \(DozerImages.formatBytes(plan.freedBytes)))?", yes: yes, g)
    r.dryRun = false
    // Delete exactly what was shown (clean included): a change since is refused, not widened.
    r.op = .resourcesRemove
    r.ids = plan.items.map(\.id)
    let done = try decode(try call(r, g), ResourcePlan.self, g)
    if g.json { Out.json(done) } else {
        Out.stdout("deleted \(done.deleted.count) item\(done.deleted.count == 1 ? "" : "s") — freed \(DozerImages.formatBytes(done.freedBytes))\n")
        for x in done.refused { Out.stdout("  refused \(x.id): \(x.reason)\n") }
        for x in done.failed { Out.stdout("  failed \(x.id): \(x.reason)\n") }
    }
    if !done.failed.isEmpty || !done.refused.isEmpty { throw ExitCode(DozerExit.failed) }
}

func renderResourcePlan(_ p: ResourcePlan) -> String {
    var s = ""
    if p.items.isEmpty { s += p.clean ? "nothing to clean up\n" : "nothing to delete\n" }
    else {
        var t = [["DELETE", "FREES", "LATER"]]
        for e in p.items {
            t.append([e.id, DozerImages.formatBytes(e.freedBytes), [e.later, e.warning.map { "⚠ " + $0 }].compactMap { $0 }.joined(separator: " · ")])
        }
        s += Out.table(t)
        s += "frees \(DozerImages.formatBytes(p.freedBytes)) in all (blocks shared between them counted once)\(p.dryRun ? " — a dry run: nothing was deleted" : "")\n"
    }
    for x in p.refused { s += "refused \(x.id): \(x.reason)\n" }
    if p.clean { s += "logs and metrics are kept — name them to clear (doz resources rm logs metrics)\n" }
    return s
}

func renderResources(_ r: ResourceReport) -> String {
    let fmt = DozerImages.formatBytes
    var s = "\(r.store)\n"
    s += "Dozer uses \(fmt(r.totalBytes)) of disk (as du counts it; \(fmt(r.occupiedBytes)) with APFS-shared blocks counted once)"
    s += " · Clean up frees \(fmt(r.cleanableBytes))"
    if let free = r.volumeFreeBytes { s += " · \(fmt(free)) free on the volume" }
    s += "\n\n"
    let groups: [(String, String)] = [("sandboxes", "SANDBOXES"), ("images", "IMAGES & TEMPLATES"), ("caches", "CACHES"),
                                      ("logs", "LOGS & METRICS"), ("stray", "STRAY FILES"), ("store", "DOZER'S OWN"), ("outside", "OUTSIDE THE STORE")]
    for (g, title) in groups {
        let rows = r.items.filter { $0.group == g }
        if rows.isEmpty { continue }
        var t = [[title, "SIZE", "FREED", "USED BY", "NOTE"]]
        for it in rows {
            let note: String = {
                if it.id == "unattributed" { return it.detail ?? "" }
                if let ref = it.refusal { return (it.deletable ? "not now: " : "") + ref }
                return [it.detail, it.later.map { "later: " + $0 }, it.cleanable ? "clean-up" : nil].compactMap { $0 }.joined(separator: " · ")
            }()
            t.append([(it.parent == nil ? "" : "  ") + it.id, it.sizeBytes.map(fmt) ?? "—", it.freedBytes.map(fmt) ?? "—",
                      it.usedBy.isEmpty ? "—" : it.usedBy.joined(separator: ", "), note])
        }
        s += Out.table(t) + "\n"
    }
    s += "rows add up to \(fmt(r.attributedBytes)); unattributed \(fmt(r.unattributedBytes))\n\n"
    var m = [["MEMORY", "HELD", "ALLOCATED", "CPUS"]]
    for x in r.memory { m.append(["\(x.kind) \(x.name)\(x.phase.map { " (\($0))" } ?? "")", fmt(x.heldBytes), x.allocationBytes.map(fmt) ?? "—", x.cpus.map(String.init) ?? "—"]) }
    s += Out.table(m)
    s += "CPUs: \(r.allocatedCPUs) given to running sandboxes of this Mac's \(r.machineCPUs)\n\n"
    if !r.network.isEmpty {
        var n = [["TRAFFIC", "UP TODAY", "DOWN TODAY", "UP TOTAL", "DOWN TOTAL", "CONNECTIONS"]]
        for x in r.network { n.append([x.sandbox, fmt(x.upToday), fmt(x.downToday), fmt(x.upTotal), fmt(x.downTotal), String(x.connectionsTotal)]) }
        s += Out.table(n) + "\n"
    }
    if !r.kernels.isEmpty {
        var k = [["KERNEL", "SHA256", "SIZE", "", "NEEDED BY"]]
        for x in r.kernels {
            k.append([x.id, x.sha256 ?? "—", fmt(x.sizeBytes), [x.current ? "current" : nil, x.pinned ? "pinned" : nil, x.inStore ? nil : "outside the store"].compactMap { $0 }.joined(separator: ", "),
                      x.usedBy.isEmpty ? "—" : x.usedBy.joined(separator: ", ")])
        }
        s += Out.table(k)
    }
    s += "measured in \(Int(r.milliseconds)) ms · doz resources rm ID… · doz resources clean (unused = no sandbox created from it in \(r.unusedDays) days)\n"
    return s
}
