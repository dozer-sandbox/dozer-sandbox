// SPIKE (604) — can a Dozer VM use the Mac's microphone and speakers (virtio-snd) for Codex CLI's voice mode?
//
// Temporary: the gating spike for feature 604 (workspace changes/604-*/604.01-SPIKE.md). It drives the real
// library through its public API plus ONE test-only seam (`SpikeVMDevices.configure`, which PinnedIdentity's
// `configureVZ` calls before it records the VMLayout), so the sound device is a VM input exactly as a
// production device would be. Remove it, or turn it into a suite, when stage 2 decides.
//
//   doz-vmtest spike-audio [--store DIR] [--no-mic] [--sound-first]
//
// What it measures (the pinned kernel has `# CONFIG_SOUND is not set` and `# CONFIG_MODULES is not set`, so
// the guest can bind NO driver to the device — playback/record cannot be tried; this answers everything that
// does not need the guest's driver):
//   1. the guest's view: its kernel config, /proc/asound, the virtio devices and which have a driver, dmesg,
//      `aplay -l` after `apk add alsa-utils` (through the lab's NAT network);
//   2. the same lab VM WITHOUT then WITH a VZVirtioSoundDeviceConfiguration (one input stream from
//      VZHostAudioInputStreamSource unless --no-mic, one output stream to VZHostAudioOutputStreamSink): cold
//      boot, pause→resume, sleep→wake, hibernate→wake (twice each), snapshot size, the VM process's footprint
//      and idle CPU;
//   3. the crash pattern with the device: child 1 starts + quits (hibernate); child 2 tries to restore WITHOUT
//      the device (the VMLayout guard must refuse it and keep the snapshot); child 3 restores WITH it and quits
//      again; the parent restores it (a fourth process) — two restores into a new process.
import Darwin
import DozerKit
import Foundation
import Virtualization

func audSpec(_ name: String) -> SandboxSpec {
    SandboxSpec(name: name, storeRoot: storeRoot, kernelPath: kernelPath, kernelCacheDirectory: kernelCache, cpus: 2, memoryMiB: 512,
                rootfsMiB: 1024, bakePackages: ["bash", "ncurses"], shares: [], subnet: testSubnet)
}

/// Turn the sound device on (or off) for every VM this process configures from now on.
func audSetDevice(_ on: Bool, mic: Bool) {
    guard on else { SpikeVMDevices.configure = nil; return }
    SpikeVMDevices.configure = { config in
        let snd = VZVirtioSoundDeviceConfiguration()
        var streams: [VZVirtioSoundDeviceStreamConfiguration] = []
        if mic {
            let input = VZVirtioSoundDeviceInputStreamConfiguration()
            input.source = VZHostAudioInputStreamSource()
            streams.append(input)
        }
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        streams.append(output)
        snd.streams = streams
        config.audioDevices = [snd]
    }
}

let audMic = !args.contains("--no-mic")

/// The guest's view of sound: kernel config, ALSA, virtio devices (id 25 = sound) and their drivers.
let audGuestScript = """
echo "uname: $(uname -r)"
echo "config: $(zcat /proc/config.gz 2>/dev/null | grep -E '^(# )?CONFIG_(SOUND|SND|SND_VIRTIO|MODULES)[ =]' | tr '\\n' ';')"
echo "proc_asound: $(ls /proc/asound 2>&1 | tr '\\n' ' ')"
echo "dev_snd: $(ls /dev/snd 2>&1 | tr '\\n' ' ')"
for d in /sys/bus/virtio/devices/*; do
  id=$(cat $d/device); drv=$(readlink $d/driver 2>/dev/null | sed 's#.*/##'); echo "virtio: $(basename $d) device=$id driver=${drv:-NONE}"
done
echo "dmesg_snd: $(dmesg 2>/dev/null | grep -iE 'snd|sound|alsa' | head -5 | tr '\\n' ';')"
echo "modules: $(ls /lib/modules 2>&1 | tr '\\n' ' ')"
"""

/// The VZ XPC processes (one per VM) running now: pid → (rss KiB, cpu seconds).
func audVMProcesses() -> [Int32: (rss: Int, cpu: Double)] {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axo", "pid=,rss=,time=,comm="]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    var out: [Int32: (Int, Double)] = [:]
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.contains("Virtualization.VirtualMachine") {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count >= 4, let pid = Int32(f[0]), let rss = Int(f[1]) else { continue }
        // time= is [dd-]hh:mm:ss.cc or mm:ss.cc
        let parts = f[2].split(separator: ":").map { Double($0.replacingOccurrences(of: "-", with: "")) ?? 0 }
        let secs = parts.reversed().enumerated().reduce(0.0) { $0 + $1.element * pow(60, Double($1.offset)) }
        out[pid] = (rss, secs)
    }
    return out
}

struct AudRun { var label: String; var t: [String: [Double]] = [:]; var rssKiB = 0; var idleCPUPercent = 0.0; var snapshotMiB = 0.0 }

/// One sandbox through the whole matrix. Returns its timings.
func audMatrix(_ name: String, sound: Bool) async throws -> AudRun {
    audSetDevice(sound, mic: audMic)
    var run = AudRun(label: sound ? "WITH sound device" : "without sound device")
    let sb = try Sandbox(spec: audSpec(name))
    let log = logEvents(sb)
    defer { log.cancel() }
    if await sb.phase != .off { try? await sb.shutDown() }
    let before = Set(audVMProcesses().keys)
    var t = Date()
    try await sb.start()
    run.t["cold boot", default: []].append(Date().timeIntervalSince(t) * 1000)
    check(await sb.phase == .running, "[\(run.label)] cold boot")
    let mine = audVMProcesses().filter { !before.contains($0.key) }
    info("[\(run.label)] VM process(es) started by this run: \(mine.keys.sorted())")

    let g = try await sb.exec(["sh", "-c", audGuestScript], privileged: true, timeoutSeconds: 60)
    for l in g.output.split(separator: "\n") { info("[\(run.label)] guest \(l)") }
    if sound {
        check(g.output.contains("device=0x0019"), "[\(run.label)] the guest sees a virtio SOUND device (id 0x0019)")
        check(g.output.contains("device=0x0019 driver=NONE"), "[\(run.label)] … and no driver binds it (the kernel has no sound support)")
    } else {
        check(!g.output.contains("device=0x0019"), "[\(run.label)] no virtio sound device in the guest")
    }
    check(g.output.contains("# CONFIG_SOUND is not set"), "[\(run.label)] guest kernel: CONFIG_SOUND is not set")
    check(g.output.contains("# CONFIG_MODULES is not set"), "[\(run.label)] guest kernel: CONFIG_MODULES is not set (no module can add it)")
    check(g.output.contains("proc_asound: ls:") || g.output.contains("No such file"), "[\(run.label)] /proc/asound does not exist")

    // Idle cost of the VM process over 10 s (a guest doing nothing).
    await sleepS(3)
    let p0 = audVMProcesses().filter { mine.keys.contains($0.key) }
    await sleepS(10)
    let p1 = audVMProcesses().filter { mine.keys.contains($0.key) }
    run.rssKiB = p1.values.reduce(0) { $0 + $1.rss }
    run.idleCPUPercent = p1.reduce(0.0) { acc, e in acc + (e.value.cpu - (p0[e.key]?.cpu ?? e.value.cpu)) } / 10 * 100
    info(String(format: "[\(run.label)] VM process RSS %d MiB, idle CPU %.2f %% of one core over 10 s", run.rssKiB / 1024, run.idleCPUPercent))

    func alive(_ what: String) async throws {
        let r = try await sb.exec(["sh", "-c", "echo ok; ls /sys/bus/virtio/devices | wc -l"], timeoutSeconds: 30)
        check(await sb.phase == .running && r.output.hasPrefix("ok"), "[\(run.label)] \(what): running, guest answers (\(r.output.split(separator: "\n").last ?? "?") virtio devices)")
    }
    for cycle in 1...2 {
        try await sb.pause()
        t = Date(); try await sb.resume(); run.t["pause→resume", default: []].append(Date().timeIntervalSince(t) * 1000)
        try await alive("pause → resume \(cycle)")
        try await sb.sleep()
        t = Date(); try await sb.wake(); run.t["sleep→wake", default: []].append(Date().timeIntervalSince(t) * 1000)
        try await alive("sleep → wake \(cycle)")
        t = Date(); try await sb.hibernate(); run.t["hibernate", default: []].append(Date().timeIntervalSince(t) * 1000)
        let snap = storeRoot.appendingPathComponent("sandboxes/\(name)/vm.state")
        if let sz = (try? FileManager.default.attributesOfItem(atPath: snap.path))?[.size] as? NSNumber { run.snapshotMiB = sz.doubleValue / 1_048_576 }
        t = Date(); try await sb.wake(); run.t["hibernate→wake", default: []].append(Date().timeIntervalSince(t) * 1000)
        try await alive("hibernate → wake \(cycle)")
    }
    // Last (it touches guest memory, so it must not skew the cost numbers above): ALSA's own view.
    if sound {
        let a = try await sb.exec(["sh", "-c", "apk add -q alsa-utils >/dev/null 2>&1; echo rc=$?; aplay -l 2>&1; arecord -l 2>&1; aplay -q -d 1 /dev/zero 2>&1 | head -2"],
                                  privileged: true, timeoutSeconds: 180)
        info("[\(run.label)] alsa-utils: " + a.output.replacingOccurrences(of: "\n", with: " ⏎ "))
        check(a.output.contains("no soundcards found"), "[\(run.label)] aplay -l / arecord -l: no soundcards found")
    }
    // A second cold boot (the first one in a fresh store includes the bake).
    try await sb.shutDown()
    t = Date(); try await sb.start(); run.t["cold boot", default: []].append(Date().timeIntervalSince(t) * 1000)
    try await sb.shutDown()
    try await sb.delete()
    return run
}

func audioSpike() async throws {
    info("mic stream: \(audMic ? "yes (VZHostAudioInputStreamSource)" : "no (--no-mic)"); output stream: VZHostAudioOutputStreamSink")
    // --sound-first reverses the order (so a warm-up effect cannot pass for the device's cost).
    let without: AudRun, with: AudRun
    if args.contains("--sound-first") {
        with = try await audMatrix("aud-snd", sound: true)
        without = try await audMatrix("aud-plain", sound: false)
    } else {
        without = try await audMatrix("aud-plain", sound: false)
        with = try await audMatrix("aud-snd", sound: true)
    }
    for r in [without, with] {
        for (k, v) in r.t.sorted(by: { $0.key < $1.key }) { info("[\(r.label)] \(k): " + v.map { String(format: "%.0f ms", $0) }.joined(separator: ", ")) }
        info(String(format: "[\(r.label)] snapshot %.1f MiB · VM RSS %d MiB · idle CPU %.2f %%", r.snapshotMiB, r.rssKiB / 1024, r.idleCPUPercent))
    }

    // The crash pattern WITH the device (four processes).
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let steps: [(String, [String])] = [
        ("1: start with the device, quit (hibernate)", ["spike-audio-crash-save"]),
        ("2: restore WITHOUT the device — must be refused, snapshot kept", ["spike-audio-crash-restore", "--without-device"]),
        ("3: restore WITH the device, quit again", ["spike-audio-crash-restore"]),
    ]
    for (what, a) in steps {
        print("spike: crash pattern — child \(what)")
        let p = Process(); p.executableURL = exe
        p.arguments = a + ["--store", storeRoot.path] + (audMic ? [] : ["--no-mic"])
        try p.run(); p.waitUntilExit()
        check(p.terminationStatus == 0, "child \(what) — exited 0 (\(p.terminationStatus))")
    }
    print("spike: crash pattern — the parent restores (fourth process)")
    audSetDevice(true, mic: audMic)
    try await audCrashRestore(thenQuit: false)
}

func audCrashSave() async throws -> Int32 {
    audSetDevice(true, mic: audMic)
    let sb = try Sandbox(spec: audSpec("aud-crash"))
    let log = logEvents(sb, prefix: "[child] ")
    if await sb.phase != .off { try? await sb.shutDown() }
    try await sb.start()
    _ = try await sb.exec(["sh", "-c", "echo marker-$$ > /root/marker; cat /root/marker"], privileged: true)
    await sb.prepareForExit()
    log.cancel()
    let parked = await sb.phase == .hibernated
    print("        · [child] quit → \(await sb.phase.label)")
    return failures == 0 && parked ? 0 : 1
}

/// Restore in a NEW process. `--without-device`: the VMLayout guard must refuse, keeping the snapshot.
func audCrashRestore(thenQuit: Bool) async throws {
    let without = args.contains("--without-device")
    audSetDevice(!without, mic: audMic)
    let spec = audSpec("aud-crash")
    check(Sandbox.restorableState(for: spec) != nil, "a new process sees the slept sandbox")
    let sb = try Sandbox(spec: spec)
    let log = logEvents(sb)
    defer { log.cancel() }
    let t = Date()
    if without {
        do {
            try await sb.wake()
            check(false, "a restore WITHOUT the sound device was refused (it was not: the layout guard missed the device)")
        } catch {
            let s = "\(error.localizedDescription)"
            check(s.lowercased().contains("audio") || "\(error)".contains("snapshotNeedsOtherBuild"), "a restore WITHOUT the sound device is refused before VZ: \(s.prefix(300))")
            check(Sandbox.restorableState(for: spec) != nil, "… and the snapshot is kept")
        }
        return
    }
    try await sb.wake()
    check(await sb.phase == .running, String(format: "restored WITH the sound device into a new process in %.0f ms", Date().timeIntervalSince(t) * 1000))
    let r = try await sb.exec(["sh", "-c", "cat /root/marker; for d in /sys/bus/virtio/devices/*; do cat $d/device; done | tr '\\n' ' '"], privileged: true)
    check(r.output.hasPrefix("marker-") && r.output.contains("0x0019"), "the restored guest is the same (marker) and still has the sound device: \(r.output.replacingOccurrences(of: "\n", with: " "))")
    if thenQuit {
        await sb.prepareForExit()
        check(await sb.phase == .hibernated, "quit again (hibernated) for the next process")
    } else {
        try await sb.shutDown()
        try await sb.delete()
    }
}
