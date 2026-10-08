// `doz-vmtest upgrade --old PATH --doz PATH` (591, `make test-vm-upgrade`): an update of doz
// never costs a sleeping sandbox its sessions.
//
//   A. THE PREVIOUS RELEASE sleeps, THIS BUILD wakes. With the old `doz` (the last release tag's,
//      built once by the Makefile): create a lab sandbox and an agent-image sandbox, start them, run a
//      session in each that prints a marker and keeps running, write a marker file, hibernate both and
//      stop the old host. With this build: wake each — the session is the same process, its screen
//      still shows the marker, the file is there. Then hibernate and wake again with this build: the
//      layout this build recorded is compatible with the VM it rebuilds.
//   B. THE INCIDENT (591, the owner's store): the file a running host executes is overwritten in place
//      (cp + codesign, as the old install did). The host reports "its program was updated underneath
//      it" — on a wake it cannot do, and in `host status` — instead of a raw VZ error; `host stop` keeps
//      the snapshots; a host of this build (the intact file) wakes the sandbox with its session.
//   C. A host whose program was REPLACED by an update (a rename: the new install) exits by itself once
//      nothing runs and nobody is connected, so the next command runs the installed build.
//
// 592: the first DozerKit release is v0.10.0, and a store of a pre-rename release (v0.9.0 or older) is
// NOT expected to wake under doz (owner ruling: no backward compatibility). Until a DozerKit tag exists the Makefile
// passes a COPY of this build as --old: A is then a reinstall of the same version, B and C unchanged.
//
// Inputs: --old PATH (the previous release's signed doz), --doz PATH (this build's), --store DIR
// (a SCRATCH store; the agent image is baked once in it), --entitlements PATH (for the in-place re-sign;
// default Scripts/doz.entitlements). Sandboxes: upl (lab), upa (pi). Nothing outside the store.
import Darwin
import Foundation
import DozerKit
import DozerHost

func upgradeSuite() async throws {
    func arg(_ name: String, _ def: String) -> String {
        if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
        return def
    }
    let oldBin = URL(fileURLWithPath: arg("--old", "")).standardizedFileURL.path
    let newBin = URL(fileURLWithPath: arg("--doz", ".build/debug/doz")).standardizedFileURL.path
    let entitlements = URL(fileURLWithPath: arg("--entitlements", "Scripts/doz.entitlements")).standardizedFileURL.path
    guard FileManager.default.isExecutableFile(atPath: oldBin) else {
        check(false, "the previous release's doz (--old) is missing: \(oldBin)")
        return
    }
    try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
    let old = CLIHarness(binary: oldBin, store: storeRoot)
    let new = CLIHarness(binary: newBin, store: storeRoot)
    let oldVersion = old.run(["--version"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
    let newVersion = new.run(["--version"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
    info("old doz \(oldVersion) (\(oldBin)) · new doz \(newVersion) (\(newBin)) · store \(storeRoot.path)")
    let boxes: [(name: String, image: String)] = [("upl", "lab"), ("upa", "pi")]
    let marker = "UPGRADE-" + String(UInt32.random(in: 100_000...999_999))

    func cleanUp() {
        for b in boxes { new.run(["rm", b.name, "--yes"]) }
        new.run(["host", "stop"])
    }
    cleanUp()

    // ── A. the previous release sleeps them.
    var pids: [String: Int] = [:]
    for b in boxes {
        // 610: `--account none` — nothing here calls a model, and a scratch store must never bind the Mac's Claude login
        // (the store's default, `mac`, made the host read the login keychain's access token for upl); pi also needs it
        // (594: an API-key account, or `none` chosen explicitly).
        let c = old.run(["create", b.name, "--image", b.image, "--account", "none"], timeout: 60)
        check(c.code == 0, "\(oldVersion): create \(b.name) (\(b.image))" + (c.code == 0 ? "" : " — \(c.err.suffix(200))"))
        let s = old.run(["start", b.name], timeout: 1500)            // a first start bakes the image (minutes, network)
        check(s.code == 0, "\(oldVersion): start \(b.name)")
        let r = old.run(["run", b.name, "--session", "keep", "-d", "--", "sh", "-c", "echo SCREEN-\(marker); exec sleep 1000000"], timeout: 60)
        check(r.code == 0, "\(oldVersion): a session in \(b.name) that prints a marker and keeps running")
        check(old.run(["exec", b.name, "--", "sh", "-c", "echo FILE-\(marker) > /tmp/upgrade-marker"], timeout: 60).code == 0, "\(oldVersion): a marker file in \(b.name)")
        _ = old.waitFor(10) { old.sessions(b.name).first { $0.name == "keep" }?.pid != nil }
        pids[b.name] = old.sessions(b.name).first { $0.name == "keep" }?.pid
        check(pids[b.name] != nil, "\(b.name): session keep runs, pid \(pids[b.name].map(String.init) ?? "?")")
        check(old.run(["hibernate", b.name], timeout: 120).code == 0, "\(oldVersion): hibernate \(b.name)")
    }
    check(old.run(["host", "stop"], timeout: 120).code == 0, "\(oldVersion): host stop")
    _ = old.waitFor(30) { !old.hostRunning }

    /// This build wakes `name`: the same session process, its screen, its file.
    func wakeIntact(_ h: CLIHarness, _ name: String, _ who: String) {
        let w = h.run(["wake", name], timeout: 180)
        check(w.code == 0, "\(who): wake \(name)" + (w.code == 0 ? "" : " — \(w.err.suffix(300))"))
        guard w.code == 0 else { return }
        let keep = h.sessions(name).first { $0.name == "keep" }
        check(keep != nil && !(keep?.ended ?? true) && keep?.pid == pids[name],
              "\(name): session keep is the SAME process (pid \(keep?.pid.map(String.init) ?? "?") vs \(pids[name].map(String.init) ?? "?"))")
        let f = h.run(["exec", name, "--", "cat", "/tmp/upgrade-marker"], timeout: 60)
        check(f.out.contains("FILE-\(marker)"), "\(name): the marker file is there")
        if let c = try? AttachedClient(h, ["attach", name, "keep"]) {
            let seen = c.wait(20) { $0.text.contains("SCREEN-\(marker)") }
            c.close()
            check(seen, "\(name): the session's screen still shows its marker")
        } else {
            check(false, "\(name): attach")
        }
    }
    for b in boxes { wakeIntact(new, b.name, "\(newVersion) (slept by \(oldVersion))") }
    // 610: the wake brought THIS build's deckhold to the guest's disk (sessions opened from now on run it); the running
    // session kept its own holder (the same pid, above).
    if let bin = DeckholdBinary.locate(), let want = Sandbox.digest(bin) {
        for b in boxes {
            let have = new.run(["exec", b.name, "--", "sh", "-c", GuestCommand.deckholdDigestScript], timeout: 60).out.trimmingCharacters(in: .whitespacesAndNewlines)
            check(have == want, "\(b.name): the wake put this build's deckhold in the guest (\(have.prefix(12)) vs \(want.prefix(12)))")
        }
    } else {
        check(false, "this build's deckhold resource is found")
    }
    // The layout this build records, on its own next wake.
    for b in boxes {
        check(new.run(["hibernate", b.name], timeout: 120).code == 0, "\(newVersion): hibernate \(b.name)")
        let rec = PersistedSandbox.read(from: DozerStore(root: storeRoot).layout(b.name).persistedState)
        check(rec?.vmLayout != nil && rec?.vmLayout?.recordedBy == "doz \(newVersion)",
              "\(b.name): the snapshot's VM layout is recorded (\(rec?.vmLayout?.recordedBy ?? "none"), \(rec?.vmLayout?.disks.count ?? 0) disks)")
    }
    for b in boxes { wakeIntact(new, b.name, "\(newVersion) (its own layout)") }

    // ── B. the incident: the running host's program overwritten in place.
    let binDir = storeRoot.appendingPathComponent("bin-under-test")
    try? FileManager.default.removeItem(at: binDir)
    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    let newDir = URL(fileURLWithPath: newBin).deletingLastPathComponent()
    for bundle in ["DozerKit_DozerKit.bundle", "DozerKit_DozerWeb.bundle"] {
        try? FileManager.default.copyItem(at: newDir.appendingPathComponent(bundle), to: binDir.appendingPathComponent(bundle))
    }
    let t = binDir.appendingPathComponent("doz").path
    func sh(_ argv: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
    check(sh(["/bin/cp", newBin, t]) == 0 && sh(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", entitlements, t]) == 0,
          "a copy of this build to run a host from")
    let under = CLIHarness(binary: t, store: storeRoot)
    new.run(["host", "stop"])                                          // hibernates both
    _ = new.waitFor(30) { !new.hostRunning }
    check(boxes.allSatisfy { new.row($0.name)?.phase == "hibernated" }, "both are hibernated")
    check(under.run(["host", "start"], timeout: 60).code == 0 && under.waitFor(30) { under.hostRunning }, "a host runs from the copy")
    // A held attach (no wake) keeps a connection open, so the host does not exit by itself (part C).
    let held = try AttachedClient(under, ["attach", "upa", "keep", "--no-wake"])
    _ = held.wait(3) { _ in false }
    // The incident: write the previous release INTO the running host's file, then re-sign it.
    // 592: the incident needs DIFFERENT code written into the running host's file. When --old is a copy
    // of this build (no DozerKit release to build yet), its bytes are identical — the running code then
    // stays valid, and codesign's rewrite reads as a mere "replaced" — so another program of this
    // build is written in instead: this test host's own executable.
    let sameBytes = FileManager.default.contentsEqual(atPath: oldBin, andPath: newBin)
    let intruder = sameBytes ? (Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? oldBin) : oldBin
    info("the program written into the running host's file: \(sameBytes ? "this test host (--old has this build's bytes)" : "the previous release (--old)")")
    check(sh(["/bin/cp", intruder, t]) == 0 && sh(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", entitlements, t]) == 0,
          "the running host's program overwritten in place (cp + codesign, as the old install did)")
    // This build's CLI asks the running host (the file it started from is what changed).
    let st = new.json(["host", "status"], HostStatus.self)
    check(st?.executableChange == "overwritten" && (st?.executableNote ?? "").contains("updated underneath it"),
          "host status says its program was updated underneath it (\(st?.executableChange ?? "no change seen"))")
    let doctor = new.run(["doctor"], timeout: 120)
    check(doctor.out.contains("updated underneath it"), "doctor says so too")
    let w = new.run(["wake", "upl"], timeout: 180)
    info("wake on the overwritten host → \(w.code): \(w.err.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))")
    check(w.code != 0 ? w.err.contains("this host's program was updated underneath it") : true,
          w.code != 0 ? "a wake it cannot do says why (not a raw Virtualization error)"
                      : "the overwritten host still woke upl (macOS did not refuse it this time) — the error mapping was not exercised")
    held.close()
    if w.code == 0 { new.run(["hibernate", "upl"], timeout: 120) }
    let stop = new.run(["host", "stop"], timeout: 120)
    _ = new.waitFor(60) { !new.hostRunning }
    check(stop.code == 0 || !new.hostRunning, "host stop")
    let layoutL = DozerStore(root: storeRoot).layout("upl")
    if w.code != 0 {
        check(FileManager.default.fileExists(atPath: layoutL.snapshot.path), "upl's snapshot is kept after the failed wake and the stop")
    }
    // A host of THIS build (its intact file) wakes it, session and all.
    if new.row("upl")?.phase == "running" { new.run(["hibernate", "upl"], timeout: 120) }
    wakeIntact(new, "upl", "\(newVersion) after the incident")
    wakeIntact(new, "upa", "\(newVersion) after the incident")

    // ── C. replaced by an update (rename): an idle host exits by itself.
    for b in boxes { new.run(["hibernate", b.name], timeout: 120) }
    new.run(["host", "stop"])
    _ = new.waitFor(30) { !new.hostRunning }
    check(sh(["/bin/cp", newBin, t + ".new"]) == 0 && sh(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", entitlements, t + ".new"]) == 0
          && rename(t + ".new", t) == 0, "a copy of this build again")
    check(under.run(["host", "start"], timeout: 60).code == 0 && under.waitFor(30) { under.hostRunning }, "a host runs from it, with nothing running")
    check(sh(["/bin/cp", newBin, t + ".new"]) == 0 && sh(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", entitlements, t + ".new"]) == 0
          && rename(t + ".new", t) == 0, "an update renames a new file over it (the install since e1af862)")
    let exited = under.waitFor(60) { !under.hostRunning }
    check(exited, "the idle host whose program was replaced exits by itself, so the next command runs the installed build")

    cleanUp()
    try? FileManager.default.removeItem(at: binDir)
}
