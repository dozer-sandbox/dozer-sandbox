import ArgumentParser
import Foundation
import DozerKit
import DozerHost

// 593 — templates and duplicates (owner: "a way to turn a disk image into a template and/or to
// create a new Sandbox from an existing one (provide a new workspace dir etc)"). A template is a
// custom image: the sandbox's ROOT disk only — never its state disk (the agent's logins and
// history). Duplicate makes a new sandbox from an existing one's disk with overrides; its state disk
// starts fresh unless --copy-state. Both are APFS clones.

struct TemplateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "template",
        abstract: "Templates: a sandbox's root disk saved as an image other sandboxes are created from (never its state disk).",
        discussion: """
        A template holds everything installed or written on the sandbox's ROOT disk (/root, /etc, /usr, /opt, caches) — \
        never the agent's state disk (logins, history). Create a sandbox from one: doz create NEW --image TEMPLATE.
        """,
        subcommands: [TemplateCreate.self, TemplateList.self, TemplateRemove.self],
        defaultSubcommand: TemplateList.self)
}

struct TemplateCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create",
        abstract: "Save a sandbox's root disk (now, or a restore point's) as a template. A live sandbox pauses for the clone (milliseconds).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox.") var name: String
    @Option(name: .customLong("as"), help: "The template's name (1–40 of a-z 0-9 -).") var template: String
    @Option(name: .customLong("from-point"), help: "A restore point (name or id) instead of the current disk.") var point: String?
    @Option(name: .long) var note: String?
    func run() async throws {
        var r = HostRequest(.templateCreate, name: name)
        r.image = template
        r.point = point
        r.note = note
        let img = try decode(try call(r, g), CustomImage.self, g)
        if g.json { Out.json(img); return }
        Out.stdout("saved \(name)'s root disk\(point.map { " (restore point \($0))" } ?? "") as the template \(img.name) (\(DozerImages.formatBytes(img.allocatedBytes)); no state disk) — doz create NEW --image \(img.name)\n")
    }
}

struct TemplateList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "The templates in this store.")
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        let rows = try decode(try await query(HostRequest(.imageList), g), [ImageRow].self, g).filter { $0.kind == "custom" }
        if g.json { Out.json(rows); return }
        if rows.isEmpty { Out.stdout("no templates — doz template create NAME --as TEMPLATE\n"); return }
        var t = [["TEMPLATE", "SAVED", "SIZE", "FROM", "NOTE"]]
        for r in rows {
            t.append([r.name, r.bakedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—",
                      r.allocatedBytes.map(DozerImages.formatBytes) ?? "—", r.fromSandbox ?? "—", r.note ?? ""])
        }
        Out.stdout(Out.table(t))
    }
}

struct TemplateRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove a template (sandboxes created from it keep working).")
    @OptionGroup var g: GlobalOptions
    @Argument var template: String
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false
    func run() async throws {
        let rows = try decode(try await query(HostRequest(.imageList), g), [ImageRow].self, g)
        guard rows.contains(where: { $0.kind == "custom" && $0.name == template }) else {
            throw fail(HostError(.notFound, "no template \(template) (doz template ls)\(rows.contains { $0.name == template } ? " — \(template) is a built-in image: doz image rm" : "")"), g)
        }
        try confirm("Remove the template \(template)? Sandboxes created from it keep working.", yes: yes, g)
        var r = HostRequest(.imageRm)
        r.image = template
        let left = try decode(try call(r, g), [ImageRow].self, g)
        if g.json { Out.json(left) } else { Out.stdout("removed the template \(template)\n") }
    }
}

struct Duplicate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "duplicate",
        abstract: "A new sandbox from an existing one's disk (or a restore point), with a new workspace, CPUs, memory, network or account.",
        discussion: """
        The root disk is an APFS clone. The state disk (the agent's logins and history) starts FRESH unless --copy-state. \
        Keys are not copied. A live sandbox pauses for the clone (milliseconds). The new sandbox is off: doz start NEW.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox to duplicate.") var name: String
    @Argument(help: "The new sandbox's name.") var newName: String
    @Option(name: .customLong("from-point"), help: "A restore point (name or id) instead of the current disk.") var point: String?
    @Option(name: .long, help: "A folder on this Mac shared at /workspace (made when it does not exist).") var workspace: String?
    @Flag(name: .long, help: "Share no folder (drop the source's workspace): the new sandbox is isolated.") var isolated = false
    @Option(name: .long) var cpus: Int?
    @Option(name: .long, help: "e.g. 2G, 1536M.") var memory: String?
    @Option(name: .long, help: "agent, bake, locked, open (proxied), nat or none (default: the source's, its policy included).") var network: String?
    @Option(name: .long, help: "An account, none or default (proxied networks).") var account: String?
    @Flag(name: .customLong("copy-state"), help: "Copy the agent's state disk too (its logins and history). Default: a fresh one.") var copyState = false

    func run() async throws {
        if isolated && workspace != nil { throw fail(HostError(.invalid, "--isolated or --workspace, not both"), g) }
        let ws = workspace.map { w -> String in
            let e = (w as NSString).expandingTildeInPath
            return e.hasPrefix("/") ? e : URL(fileURLWithPath: e, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path
        }
        var o = DuplicateOptions(workspace: ws, cpus: cpus, network: network, account: account, copyState: copyState ? true : nil)
        o.isolated = isolated ? true : nil
        if let m = memory {
            guard let mib = DozerImages.parseMemory(m) else { throw fail(HostError(.invalid, "--memory: say e.g. 2G or 1536M"), g) }
            o.memoryMiB = mib
        }
        var r = HostRequest(.duplicate, name: name)
        r.newName = newName
        r.point = point
        r.duplicate = o
        let i = try decode(try call(r, g), SandboxInfo.self, g)
        if g.json { Out.json(i); return }
        Out.stdout("duplicated \(name)\(point.map { " (restore point \($0))" } ?? "") as \(i.name) — state disk \(copyState ? "copied" : "fresh")"
                   + (i.workspace == nil ? " — isolated" : "") + " — doz start \(i.name)\n")
        noteWorkspace(i, isolatedAsked: isolated, g)
    }
}
