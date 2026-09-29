import ArgumentParser
import Foundation
import DozerKit
import XCTest
@testable import DozerCLI
@testable import DozerHost

/// The command surface: the owner's vocabulary and its aliases, the arguments, `--json`, and the
/// shapes of what `--json` prints. No host, no VM.
final class CommandTests: XCTestCase {
    private func parse(_ args: [String]) throws -> ParsableCommand { try DozerCommand.parseAsRoot(args) }

    func testTheOwnersAliases() throws {
        XCTAssertTrue(try parse(["hibernate", "box"]) is Hibernate)
        XCTAssertTrue(try parse(["suspend", "box"]) is Pause)
        XCTAssertTrue(try parse(["cold-boot", "box"]) is Start)
        XCTAssertTrue(try parse(["start", "box"]) is Start)
        XCTAssertTrue(try parse(["sleep", "box"]) is SleepCommand)
        XCTAssertTrue(try parse(["wake", "box"]) is Wake)
        XCTAssertTrue(try parse(["rm", "box", "--yes"]) is Remove)
    }

    func testEveryCommandTakesJSONAndStore() throws {
        let lines: [[String]] = [
            ["create", "b", "--image", "lab"], ["up", "b"], ["start", "b"], ["pause", "b"], ["resume", "b"], ["sleep", "b"],
            ["hibernate", "b"], ["wake", "b"], ["shutdown", "b"], ["reset", "b"], ["rm", "b"], ["ls"], ["inspect", "b"],
            ["sessions", "b"], ["attach", "b"], ["run", "b", "--", "top"], ["exec", "b", "--", "ls"], ["image", "ls"],
            ["image", "bake", "lab"], ["image", "rm", "lab"], ["point", "take", "b"], ["point", "ls", "b"],
            ["point", "revert", "b", "p"], ["point", "fork", "b", "p", "c"], ["point", "rm", "b", "p"],
            ["point", "save-image", "b", "--as", "img"], ["net", "policy", "b"], ["net", "log", "b"],
            ["key", "set", "b", "--anthropic"], ["key", "rm", "b", "--anthropic"], ["key", "ls", "b"], ["metrics"], ["doctor"],
            ["host", "stop"], ["host", "status"], ["host", "--foreground"], ["events"],
        ]
        for l in lines {
            XCTAssertNoThrow(try parse(l + ["--json", "--store", "/tmp/s"]), l.joined(separator: " "))
        }
    }

    func testExecAndRunTakeTheProgramAfterTheTerminator() throws {
        let e = try XCTUnwrap(parse(["exec", "box", "--user", "root", "-e", "A=1", "--", "sh", "-c", "echo --json"]) as? Exec)
        XCTAssertEqual(e.name, "box")
        XCTAssertEqual(e.command, ["sh", "-c", "echo --json"], "flags after -- belong to the program")
        XCTAssertEqual(e.user, "root")
        XCTAssertEqual(try parseEnv(e.env), ["A": "1"])
        XCTAssertFalse(e.g.json)
        let r = try XCTUnwrap(parse(["run", "box", "--session", "t", "-d", "--", "top", "-b"]) as? Run)
        XCTAssertEqual(r.command, ["top", "-b"])
        XCTAssertEqual(r.session, "t")
        XCTAssertTrue(r.detach)
        XCTAssertThrowsError(try parse(["run", "box"]), "run needs a program")
        XCTAssertThrowsError(try parse(["exec", "box"]), "exec needs a command")
        XCTAssertThrowsError(try parseEnv(["=x"]))
    }

    func testUpTakesCreateOptionsAndAProgram() throws {
        let u = try XCTUnwrap(parse(["up", "myproj", "--image", "claude-code", "--workspace", "/tmp", "--memory", "4G", "--", "claude", "--continue"]) as? Up)
        let o = try u.create.options(defaultImage: "lab")
        XCTAssertEqual(o, CreateOptions(image: "claude-code", memoryMiB: 4096, workspace: "/tmp"))
        XCTAssertEqual(u.command, ["claude", "--continue"])
        let bare = try XCTUnwrap(parse(["up", "x"]) as? Up)
        XCTAssertEqual(try bare.create.options(defaultImage: "lab").image, "lab")
        XCTAssertFalse(bare.create.givenAny)
        let c = try XCTUnwrap(parse(["create", "x"]) as? Create)
        XCTAssertThrowsError(try c.create.options(), "create needs --image")
        let bad = try XCTUnwrap(parse(["create", "x", "--image", "lab", "--memory", "lots"]) as? Create)
        XCTAssertThrowsError(try bad.create.options())
    }

    func testConfirmationsAndKeys() throws {
        XCTAssertTrue(try XCTUnwrap(parse(["shutdown", "b", "-y"]) as? Shutdown).yes)
        XCTAssertFalse(try XCTUnwrap(parse(["reset", "b"]) as? Reset).yes)
        XCTAssertThrowsError(try parse(["key", "set", "b"]), "which key?")
        XCTAssertThrowsError(try parse(["key", "set", "b", "--anthropic", "sk-ant-secret"]), "a key is never an argument")
        let k = try XCTUnwrap(parse(["key", "set", "b", "--anthropic", "--keychain", "svc"]) as? KeySet)
        XCTAssertEqual(k.keychain, "svc")
    }

    func testNetPolicyAndHostOptions() throws {
        let p = try XCTUnwrap(parse(["net", "policy", "b", "--allow", "a.com", "--allow", "*.b.org", "--deny", "c.net", "--preset", "agent"]) as? NetPolicyCommand)
        XCTAssertEqual(p.allow, ["a.com", "*.b.org"])
        XCTAssertEqual(p.deny, ["c.net"])
        XCTAssertEqual(p.preset, "agent")
        let h = try XCTUnwrap(parse(["host", "--foreground", "--idle-timeout", "0.5"]) as? HostRun)
        XCTAssertTrue(h.foreground)
        XCTAssertEqual(h.idleTimeout, 0.5)
        XCTAssertEqual(idleTimeout(nil) > 0, true)
        XCTAssertEqual(idleTimeout(2), 2)
    }

    func testDetachKeys() throws {
        XCTAssertEqual(try parseDetachKey("ctrl-]"), 0x1D)
        XCTAssertEqual(try parseDetachKey("ctrl-q"), 0x11)
        XCTAssertEqual(try parseDetachKey("CTRL-P"), 0x10)
        XCTAssertNil(try parseDetachKey("none"))
        XCTAssertThrowsError(try parseDetachKey("alt-x"))
        XCTAssertThrowsError(try parseDetachKey("ctrl-1"))
        XCTAssertEqual(describeKey(0x1D), "Ctrl-]")
    }

    func testExitCodes() {
        XCTAssertEqual(DozerExit.code(for: HostError(.notFound, "")), 2)
        XCTAssertEqual(DozerExit.code(for: HostError(.invalidPhase, "")), 3)
        XCTAssertEqual(DozerExit.code(for: HostError(.exists, "")), 4)
        XCTAssertEqual(DozerExit.code(for: HostError(.unavailable, "")), 6)
        XCTAssertEqual(DozerExit.code(for: HostError(.notImplemented, "")), 7)
        XCTAssertEqual(DozerExit.code(for: HostError(.invalid, "")), 64)
    }

    // MARK: --json shapes (what scripts rely on: add fields, never rename)

    private func keys<T: Encodable>(_ v: T) throws -> Set<String> {
        let o = try JSONSerialization.jsonObject(with: HostWire.encoder.encode(v)) as? [String: Any]
        return Set(o?.keys.map { $0 } ?? [])
    }

    func testLsRowShape() throws {
        let i = SandboxInfo(name: "b", image: "lab", phase: "running", busy: false, cpus: 2, memoryMiB: 1024, ramHeldMiB: 700,
                            memoryReturnedMiB: 324, diskBytes: 1, sessions: 2, network: "bake", deniedConnections: 0,
                            workspace: "/w", createdAt: Date(), diedWithHost: true)
        XCTAssertEqual(try keys(i), ["name", "image", "phase", "busy", "cpus", "memoryMiB", "ramHeldMiB", "memoryReturnedMiB", "diskBytes",
                                     "sessions", "network", "deniedConnections", "workspace", "isolated", "createdAt", "diedWithHost"])
        // 594: an isolated sandbox says so — `workspace` null (never left out), `isolated` true.
        var iso = i
        iso.workspace = nil
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: HostWire.encoder.encode(iso)) as? [String: Any])
        XCTAssertTrue(o["workspace"] is NSNull)
        XCTAssertEqual(o["isolated"] as? Bool, true)
        XCTAssertTrue(try HostWire.decoder.decode(SandboxInfo.self, from: HostWire.encoder.encode(iso)).isolated)
    }

    func testLifecycleAndSessionShapes() throws {
        let r = LifecycleResult(name: "b", operation: "hibernate", phaseBefore: "running", phase: "hibernated", changed: true,
                                milliseconds: 351, info: nil)
        XCTAssertEqual(try keys(r), ["name", "operation", "phaseBefore", "phase", "changed", "milliseconds"])
        let s = SessionRow(SessionInfo(name: "tick", pid: 27, size: TermSize(cols: 80, rows: 24), clients: 1, screen: "primary", command: "bash"))
        XCTAssertEqual(try keys(s), ["name", "pid", "cols", "rows", "clients", "screen", "command", "ended"])
        XCTAssertEqual(SessionRow(SessionInfo(name: "x", exitCode: 3)).ended, true)
        let e = ExecOutput(exitCode: 3, stdout: Data("out".utf8), stderr: Data(), milliseconds: 12)
        XCTAssertEqual(try keys(e), ["exitCode", "stdout", "stderr", "milliseconds"])
        let st = HostStatus(version: "0.5.0", protocolVersion: 1, pid: 1, startedAt: Date(), store: "/s", idleTimeoutMinutes: 5,
                            liveSandboxes: [], connections: 0, idleSeconds: nil)
        XCTAssertEqual(try keys(st), ["version", "protocolVersion", "pid", "startedAt", "store", "idleTimeoutMinutes", "liveSandboxes", "connections"])
    }

    func testPhaseNamesOnTheWire() {
        XCTAssertEqual(Phase.allCases.map(\.rawValue), ["off", "booting", "running", "paused", "asleep", "hibernated", "failed"])
        XCTAssertEqual(Out.phaseLabel("hibernated"), "hibernated")
        XCTAssertEqual(Out.mib(0), "—")
        XCTAssertEqual(Out.mib(2048), "2 GiB")
        XCTAssertEqual(Out.mib(585), "585 MiB")
    }

    func testTable() {
        let t = Out.table([["NAME", "RAM"], ["box", "512 MiB"], ["a-much-longer-name", "—"]], rightAligned: [1])
        XCTAssertEqual(t, "NAME                    RAM\nbox                 512 MiB\na-much-longer-name        —\n")
    }
}
