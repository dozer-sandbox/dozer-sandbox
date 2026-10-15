import XCTest
@testable import DozerKit

/// 618: a tool that takes its model only on its command line (`maki -m PROVIDER/MODEL`) gets the chosen source's
/// model there from `DOZ_MODEL` (models@1 sets it per source) — by its launcher, never per agent.
final class RecipeModelArgsTests: XCTestCase {
    func testMakiPutsTheChosenModelOnItsCommandLine() throws {
        let r = try XCTUnwrap(AgentRecipes.recipe("maki"))
        XCTAssertEqual(r.launch.modelArgs, ["-m", "$DOZ_MODEL"])
        XCTAssertFalse(r.launch.command.contains("-m"), "the session's command names no model of its own")
        XCTAssertEqual(r.selection(source: "openrouter")?.env["DOZ_MODEL"], "openrouter/openai/gpt-5.4-mini")
        XCTAssertEqual(r.selection(source: "xai")?.env["DOZ_MODEL"], "xai/grok-build-0.1")
        let sh = AgentImages.recipeLauncherScript(r)
        XCTAssertTrue(sh.contains("[ \"$doz_own\" = 1 ] || set -- '-m' \"$DOZ_MODEL\" \"$@\""), sh)
        XCTAssertTrue(sh.contains("case \"$a\" in '-m'|'-m'=*) doz_own=1"), "a run that names its own model keeps it")
        XCTAssertTrue(sh.contains("case \"${1:-}\" in help|auth|models|session|mcp|update|trust) doz_own=1"), "a subcommand gets no model")
        // Before the passthrough: `maki -p …` (a flag) gets the model too.
        let args = try XCTUnwrap(sh.range(of: "doz_own=0"))
        let pass = try XCTUnwrap(sh.range(of: "case \"$1\" in"))
        XCTAssertLessThan(args.lowerBound, pass.lowerBound)
    }

    func testTheLauncherRunsWithAndWithoutAChosenModel() throws {
        let r = try XCTUnwrap(AgentRecipes.recipe("maki"))
        let sh = AgentImages.recipeLauncherScript(r)
        let body = try XCTUnwrap(sh.components(separatedBy: "<<'SH'\n").last?.components(separatedBy: "\nSH\n").first)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-model-args-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("maki")
        try body.write(to: script, atomically: true, encoding: .utf8)
        func run(_ args: [String], model: String?) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script.path] + args
            var env = ["PATH": "/usr/bin:/bin", "DOZ_MAKI_LAUNCHER_ECHO": "1", "DOZ_MAKI_PERMISSIONS": "ask"]
            if let model { env["DOZ_MODEL"] = model }
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            try p.run(); p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        // (A passthrough run — `-p` — execs before the echo; the model is put first all the same.)
        XCTAssertEqual(try run(["say ok"], model: "openrouter/openai/gpt-5.4-mini"),
                       "/usr/local/bin/maki\n-m\nopenrouter/openai/gpt-5.4-mini\nsay ok\n")
        XCTAssertEqual(try run(["-m", "xai/other", "say ok"], model: "xai/grok-build-0.1"),
                       "/usr/local/bin/maki\n-m\nxai/other\nsay ok\n", "its own -m wins")
        XCTAssertEqual(try run(["models"], model: "xai/grok-build-0.1"), "", "a subcommand: no model (and it runs as it is)")
        XCTAssertEqual(try run([], model: nil), "/usr/local/bin/maki\n", "no source chosen: nothing added")
    }

    func testTheDeclarationIsChecked() throws {
        let base = try XCTUnwrap(AgentRecipes.recipe("maki"))
        XCTAssertNoThrow(try base.validate())
        func refused(_ args: [String], _ why: String, file: StaticString = #filePath, line: UInt = #line) {
            var r = base
            r.launch.modelArgs = args
            XCTAssertThrowsError(try r.validate(), why, file: file, line: line)
        }
        refused(["$DOZ_MODEL"], "a flag first")
        refused(["-m", "x"], "it names the model")
        refused(["-m", "$DOZ_MODEL", "$DOZ_MODEL"], "once")
        refused(["-m", "$(id)"], "plain words: it is written into a shell script")
        refused(["-m", "'$DOZ_MODEL'"], "no quote")
        refused(["-m", "$DOZ_MODEL", "--key", "$DOZ_API_KEY"], "never a credential on a command line")
        refused(["-m", "$DOZ_MODEL", "-P", "$DOZ_UNSET"], "every models@1 entry sets each variable named")
        var noModel = base
        noModel.models?.native?[0].env = [:]
        XCTAssertThrowsError(try noModel.validate(), "every models@1 entry sets DOZ_MODEL")
        var builtin = try XCTUnwrap(AgentRecipes.recipe("claude-code"))
        builtin.launch.modelArgs = ["-m", "$DOZ_MODEL"]
        XCTAssertThrowsError(try builtin.validate(), "an agent with models@1")
        // 618: pi's are the host's to put on its session (its launcher is Dozer's own, unchanged).
        XCTAssertEqual(AgentRecipes.recipe("pi")?.launch.modelArgs, ["--model", "$DOZ_MODEL"])
    }

    func testOnlyARecipeThatDeclaresThemGetsThem() {
        for r in AgentRecipes.all where r.launch.modelArgs == nil && !r.isBuiltin {
            XCTAssertFalse(AgentImages.recipeLauncherScript(r).contains("doz_own"), r.id)
        }
    }
}
