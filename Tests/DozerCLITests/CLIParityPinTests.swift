import ArgumentParser
import Foundation
import XCTest
import DozerKit
@testable import DozerCLI
@testable import DozerHost

/// 617 step 0 — the CLI's spellings as they are BEFORE `ChoiceOptions` replaces `CreateArguments` and `doz init`'s
/// own flags (plan 616.03 D13). Two pins:
/// 1. every flag `new`, `create`, `up` and `init` accept today still parses (old spellings keep working —
///    `--image`, `--allow`, `doz new --name`, `init --permissions +web`);
/// 2. what a fixed set of argv lines MEANS: the `CreateOptions` create/up produce, the fields `new` reads, and the
///    `doz_project.yaml` `init --yes` writes (`Tests/Fixtures/pins/*.txt`).
/// The refactor may ADD flags to each command (that is its point) but must keep every line here meaning the same.
/// Computed at 4b5e9ac + the 617 claim (VERSION 0.34.0), before any 617 change.
final class CLIParityPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-parity-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func parse(_ args: [String]) throws -> ParsableCommand { try DozerCommand.parseAsRoot(args) }

    /// The choice flags `CreateArguments` gives create and up today, each with a value that parses.
    static let createArgumentsFlags: [[String]] = [
        ["--image", "lab"], ["--agent", "codex"], ["--base", "python"], ["--dockerfile", "/tmp/Dockerfile"], ["--cpus", "3"],
        ["--memory", "4G"], ["--workspace", "/tmp/w"], ["--isolated"], ["--network", "locked"], ["--subnet", "10.1.2.0/24"],
        ["--account", "work"], ["--agent-prompt", "/tmp/p.md"], ["--agent-prompt-mode", "replace"], ["--agent-sudo"], ["--no-agent-sudo"],
        ["--clipboard", "off"], ["--browser-bridge", "off"], ["--open-files", "off"], ["--github", "read"], ["--ssh-agent", "on"],
        ["--tmux"], ["--no-tmux"], ["--ignore-mode", "hide"], ["--workspace-view", "off"], ["--rebuild"], ["--allow", "web"],
        ["--allow", "-error-reports"], ["--use-current"], ["--audio"],
    ]

    static let surface: [(command: [String], flags: [[String]])] = [
        (["create", "b"], createArgumentsFlags + [["--start"], ["--prepare"]]),
        (["up", "b"], createArgumentsFlags + [["--session", "s"], ["-d"], ["--detach"], ["--detach-key", "ctrl-a"], ["--", "bash", "-l"]]),
        (["new"], [["--image", "codex"], ["--name", "n"], ["--isolated"], ["-d"], ["--detach"]]),
        (["init"], [["/tmp/dir"], ["--name", "n"], ["--image", "codex"], ["--cpus", "3"], ["--memory", "4G"], ["--network", "locked"],
                    ["--permissions", "+web"], ["--permissions", "-error-reports"], ["--account", "work"], ["--github", "read"],
                    ["--ssh-agent", "on"], ["--clipboard", "off"], ["--browser-bridge", "off"], ["--open-files", "off"], ["--tmux"],
                    ["--no-tmux"], ["--ignore-mode", "hide"], ["--agent-sudo"], ["--no-agent-sudo"], ["--yes"], ["-y"], ["--force"]]),
    ]

    /// 1. Every flag each command accepts today still parses, alone and with --json/--store.
    func test_everyFlagAcceptedToday() throws {
        var lines: [String] = []
        for (command, flags) in Self.surface {
            for f in flags {
                let argv = command + f
                let ok: String
                do { _ = try parse(argv); ok = "ok" } catch { ok = "REFUSED: \(DozerCommand.message(for: error))" }
                lines.append("\(argv.joined(separator: " ")) → \(ok)")
            }
            XCTAssertNoThrow(try parse(command + ["--json", "--store", "/tmp/s"]), command.joined(separator: " "))
        }
        Pins.check(#function, lines.joined(separator: "\n"))
    }

    /// Argv lines whose MEANING is pinned (for create and up; up's default image is the folder project's or the setting's).
    static let optionLines: [[String]] = [
        ["--image", "codex"],
        ["--image", "lab"],
        ["--image", "python-claude-code"],
        ["--agent", "codex", "--base", "python"],
        ["--agent", "claude"],
        ["--agent", "claude-code"],
        ["--agent", "pi", "--base", "alpine"],
        ["--agent", "none", "--base", "debian"],
        ["--agent", "shell"],
        ["--base", "go"],
        ["--image", "lab", "--allow", "web,-error-reports"],
        ["--image", "claude-code", "--allow", "locked", "--allow", "site:api.example.com"],
        ["--image", "claude-code", "--allow", "standard,+web"],
        ["--image", "pi", "--github", "push"],
        ["--image", "pi", "--github", "off"],
        ["--image", "codex", "--network", "locked", "--account", "none", "--cpus", "4", "--memory", "4G", "--workspace", "/tmp/617-pin-w"],
        ["--image", "claude-code", "--isolated", "--no-agent-sudo", "--tmux", "--clipboard", "off", "--browser-bridge", "off",
         "--open-files", "off", "--ssh-agent", "on", "--ignore-mode", "hide", "--workspace-view", "off"],
        ["--image", "claude-code", "--rebuild"],
        ["--image", "claude-code", "--use-current"],
        ["--image", "go-codex", "--network", "nat", "--subnet", "10.9.0.0/24"],
        ["--image", "claude-code", "--memory", "512M", "--account", "work"],
        [],
        // Refusals (their meaning: refused).
        ["--image", "lab", "--agent", "pi"],
        ["--agent", "nosuch"],
        ["--base", "cobol"],
        ["--isolated", "--workspace", "/tmp/w"],
        ["--image", "lab", "--memory", "lots"],
        ["--image", "lab", "--cpus", "0"],
        ["--image", "lab", "--github", "write"],
        ["--image", "lab", "--rebuild", "--use-current"],
        ["--image", "lab", "--clipboard", "maybe"],
    ]

    private static func json(_ o: CreateOptions) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(decoding: (try? enc.encode(o)) ?? Data(), as: UTF8.self)
    }

    /// 2a. `doz create NAME …` and `doz up NAME …` → the `CreateOptions` they send.
    func test_createAndUpOptions() throws {
        var lines: [String] = []
        for l in Self.optionLines {
            let c: String
            do {
                let cmd = try XCTUnwrap(try parse(["create", "b"] + l) as? Create)
                c = Self.json(try cmd.create.options())
            } catch { c = "refused" }
            lines.append("create b \(l.joined(separator: " ")) → \(c)")
            let u: String
            do {
                let cmd = try XCTUnwrap(try parse(["up", "b"] + l) as? Up)
                u = Self.json(try cmd.create.options(defaultImage: "claude-code"))
            } catch { u = "refused" }
            lines.append("up b \(l.joined(separator: " ")) [default claude-code] → \(u)")
        }
        // --dockerfile: the file's folder is the workspace unless one is given (paths are this test's own).
        let df = root.appendingPathComponent("Dockerfile")
        try Data("FROM alpine\n".utf8).write(to: df)
        let d = try XCTUnwrap(try parse(["create", "b", "--dockerfile", df.path, "--agent", "codex"]) as? Create)
        let o = try d.create.options()
        lines.append("create --dockerfile F --agent codex → image \(o.image) dockerfile=F:\(o.dockerfile == df.path) workspace=dir:\(o.workspace == root.path)")
        let di = try XCTUnwrap(try parse(["create", "b", "--dockerfile", df.path, "--isolated"]) as? Create)
        let oi = try di.create.options()
        lines.append("create --dockerfile F --isolated → image \(oi.image) workspace=\(oi.workspace ?? "nil") isolated=\(oi.isolated.map(String.init) ?? "nil")")
        // --agent-prompt FILE → the text.
        let pf = root.appendingPathComponent("prompt.md")
        try Data("Be brief.\n".utf8).write(to: pf)
        let p = try XCTUnwrap(try parse(["create", "b", "--image", "pi", "--agent-prompt", pf.path, "--agent-prompt-mode", "replace"]) as? Create)
        let op = try p.create.options()
        lines.append("create --agent-prompt F --agent-prompt-mode replace → prompt=\(op.agentPrompt.map { $0.debugDescription } ?? "nil") mode=\(op.agentPromptMode ?? "nil")")
        // A relative --workspace is the working folder's.
        let r = try XCTUnwrap(try parse(["create", "b", "--image", "lab", "--workspace", "rel"]) as? Create)
        let or = try r.create.options()
        lines.append("create --workspace rel → absolute under cwd: \(or.workspace == FileManager.default.currentDirectoryPath + "/rel")")
        Pins.check(#function, lines.joined(separator: "\n"))
    }

    /// 2b. `doz new` — what it reads from its flags (the rest — the default image, the name, the folder — comes from
    /// the host's quick-add plan, pinned by the quick-add tests).
    func test_newFlags() throws {
        var lines: [String] = []
        for l in [[], ["--image", "codex"], ["--name", "mine"], ["--image", "python-pi", "--name", "p", "--isolated", "-d"], ["--detach"]] {
            let n = try XCTUnwrap(try parse(["new"] + l) as? New)
            lines.append("new \(l.joined(separator: " ")) → image=\(n.image ?? "nil") name=\(n.name ?? "nil") isolated=\(n.isolated) detach=\(n.detach)")
        }
        // 617 stage C (D13): these three became ok deliberately — `doz new` takes the whole set of choice options and a
        // positional NAME (--name stays as its alias). Nothing else in this file moved.
        for l in [["mine"], ["--agent", "codex"], ["--allow", "web"]] {
            do { _ = try parse(["new"] + l); lines.append("new \(l.joined(separator: " ")) → ok") }
            catch { lines.append("new \(l.joined(separator: " ")) → refused today") }
        }
        Pins.check(#function, lines.joined(separator: "\n"))
    }

    /// 2c. `doz init --yes …` → the `doz_project.yaml` it writes (no terminal: every other answer is its default).
    func test_initProjectFiles() throws {
        let lines: [[String]] = [
            ["--name", "p", "--image", "codex"],
            ["--name", "p", "--image", "claude-code", "--permissions", "+web"],
            ["--name", "p", "--image", "claude-code", "--permissions", "-error-reports,+web"],
            ["--name", "p", "--image", "claude-code", "--permissions", "locked"],
            ["--name", "p", "--image", "python-pi", "--network", "locked", "--account", "none", "--cpus", "4", "--memory", "4G",
             "--github", "read", "--ssh-agent", "on", "--clipboard", "off", "--browser-bridge", "off", "--open-files", "off",
             "--tmux", "--ignore-mode", "hide", "--no-agent-sudo"],
            ["--name", "p", "--image", "lab", "--network", "nat"],
            ["--name", "p", "--image", "lab", "--network", "nat", "--permissions", "+web"],
            ["--name", "p", "--image", "go-codex", "--account", "work"],
            ["--name", "p"],
            ["--name", "Bad_Name"],
            ["--name", "p", "--network", "wide"],
            ["--name", "p", "--github", "write"],
        ]
        var out: [String] = []
        for l in lines {
            out.append("init --yes \(l.joined(separator: " ")):")
            do {
                let cmd = try XCTUnwrap(try parse(["init", "--yes", "--store", root.appendingPathComponent("store").path] + l) as? Init)
                let p = try cmd.ask(folder: root, existing: nil, asker: Asker(yes: true, json: false))
                // The keys it SETS (the commented template around them is DozerProject's own, pinned by its tests).
                let set = p.render().split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                out.append(set.map { "  | " + $0 }.joined(separator: "\n"))
            } catch {
                out.append("  refused")
            }
        }
        Pins.check(#function, out.joined(separator: "\n"))
    }
}
