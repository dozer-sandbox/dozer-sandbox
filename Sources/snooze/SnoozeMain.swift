// snooze — the SnoozeContainerKit command-line tool (585). Everything lives in the SnoozeCLI target
// (so the unit tests can reach it); this only runs it, through ArgumentParser's async entry point
// (a root command in another module needs `AsyncMainProtocol` to run its async subcommands).
import ArgumentParser
import SnoozeCLI

@main
struct SnoozeMain: AsyncMainProtocol {
    typealias Command = SnoozeCommand
}
