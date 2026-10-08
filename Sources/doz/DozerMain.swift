// doz — the DozerKit command-line tool (585). Everything lives in the DozerCLI target (so the unit tests can reach
// it); this only runs it. 611: through `DozerEntry` — ArgumentParser's parse-and-run, then the update check.
import DozerCLI

@main
struct DozerMain {
    static func main() async {
        await DozerEntry.main()
    }
}
