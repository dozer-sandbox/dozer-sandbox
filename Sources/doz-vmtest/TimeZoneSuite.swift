import Foundation

/// 594 W10 (the owner's walkthrough: "done 3:23 AM" — UTC — on a Mac in Australia): the sandbox
/// follows the Mac's time zone at boot AND at every wake (a laptop that travels while a sandbox
/// sleeps), or the setting's. The Mac's zone is stubbed (`DOZ_TEST_MAC_TIMEZONE`: a file the host
/// reads at each look). A lab sandbox (Alpine, no tzdata: the zone file is the Mac's) in a store of
/// its own (`/tmp/dzo-PID-z`).
func cliTimeZoneSuite(binary: String) async {
    let t = onboardingHarness(binary, "z", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    let zoneFile = t.store.appendingPathComponent("mac-zone")
    try? "Australia/Sydney\n".write(to: zoneFile, atomically: true, encoding: .utf8)
    t.env["DOZ_TEST_MAC_TIMEZONE"] = zoneFile.path
    defer {
        t.run(["host", "stop"])
        try? FileManager.default.removeItem(at: t.store)
    }
    print("cli: the sandbox follows the Mac's time zone (W10)")
    check(t.run(["onboard", "--no-images", "--account", "later", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    check(t.run(["create", "tz1", "--image", "lab", "--isolated", "--memory", "512M", "--start"], timeout: 600).code == 0, "create tz1 --start")
    func zone() -> String { t.run(["exec", "tz1", "--", "sh", "-c", "echo $(cat /etc/timezone) $(date +%Z)"]).out.trimmingCharacters(in: .whitespacesAndNewlines) }
    var z = zone()
    check(z == "Australia/Sydney AEST" || z == "Australia/Sydney AEDT", "at boot: the Mac's zone (\(z))")

    // The Mac moves to New York while tz1 sleeps; the wake follows it.
    check(t.run(["hibernate", "tz1"], timeout: 120).code == 0, "hibernate tz1")
    try? "America/New_York\n".write(to: zoneFile, atomically: true, encoding: .utf8)
    check(t.run(["wake", "tz1"], timeout: 120).code == 0, "wake tz1")
    z = zone()
    check(z == "America/New_York EDT" || z == "America/New_York EST", "after a wake: the Mac's new zone (\(z))")

    // The setting names a zone: it wins over the Mac's.
    check(t.run(["config", "set", "sandbox.timezone", "Asia/Tokyo"]).code == 0, "doz config set sandbox.timezone Asia/Tokyo")
    check(t.run(["config", "set", "sandbox.timezone", "Mars/Olympus"]).code != 0, "a zone this Mac does not know is refused")
    check(t.run(["hibernate", "tz1"], timeout: 120).code == 0 && t.run(["wake", "tz1"], timeout: 120).code == 0, "hibernate + wake tz1")
    z = zone()
    check(z == "Asia/Tokyo JST", "the setting's zone (\(z))")
    check(t.run(["shutdown", "tz1", "--yes"], timeout: 120).code == 0 && t.run(["start", "tz1"], timeout: 300).code == 0, "shutdown + start tz1")
    z = zone()
    check(z == "Asia/Tokyo JST", "and at the next boot (\(z))")
}
