// SPIKE (604 stage 1b) — sound for real, with a kernel that has virtio-snd (workspace changes/604-*/604.01-SPIKE.md).
//
//   doz-vmtest spike-build --image REF --script FILE --share DIR [--cpus N] [--mem MiB] [--disk MiB] [--timeout S] [--sound]
//       Start a throwaway sandbox on IMAGE (NAT), share DIR at /out, run FILE as root (its log is the script's
//       own business — write it under /out to follow it from the Mac), shut down, delete. Used to build the
//       sound kernel (workspace probes/604-*/kernel/).
//
//   DOZ_KERNEL=<the sound Image> doz-vmtest spike-audio-live --share DIR [--store DIR]
//       The lab VM WITH the sound device (Mac microphone in, speakers out): the guest's card; one quiet
//       ≤ 2 s tone (its wall-clock time printed); recordings from the Mac's microphone (RMS); three clicks
//       played while recording (round-trip latency); then streams held OPEN (arecord + aplay of silence)
//       across pause/sleep/hibernate twice each and two restores into a new process (four processes). The
//       recordings land in DIR (shared at /out) and are analysed on the Mac.
import Darwin
import DozerKit
import Foundation

// MARK: spike-build

func argValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func spikeBuild() async throws {
    guard let image = argValue("--image"), let script = argValue("--script"), let share = argValue("--share") else {
        print("spike-build needs --image REF --script FILE --share DIR"); exit(2)
    }
    let body = try String(contentsOfFile: script, encoding: .utf8)
    // --sound: the VM gets the virtio-snd device (Mac microphone + speakers) — the Codex helper probe.
    if args.contains("--sound") { audSetDevice(true, mic: !args.contains("--no-mic")) }
    let spec = SandboxSpec(name: "spike-build", storeRoot: storeRoot, image: image, kernelPath: kernelPath, kernelCacheDirectory: kernelCache,
                           cpus: Int(argValue("--cpus") ?? "8") ?? 8, memoryMiB: UInt64(argValue("--mem") ?? "8192") ?? 8192,
                           rootfsMiB: UInt64(argValue("--disk") ?? "16384") ?? 16384,
                           shares: [Share(hostPath: share, guestPath: "/out")], subnet: testSubnet)
    let sb = try Sandbox(spec: spec)
    let log = logEvents(sb)
    defer { log.cancel() }
    if await sb.phase != .off { try? await sb.shutDown() }
    try await sb.start()
    let t = Date()
    let r = try await sb.exec(["bash", "-c", body], privileged: true, timeoutSeconds: Int64(argValue("--timeout") ?? "5400") ?? 5400)
    print(r.output.suffix(4000))
    if !r.errorOutput.isEmpty { print("stderr: " + r.errorOutput.suffix(2000)) }
    check(r.exitCode == 0, String(format: "the build script exited %d after %.0f s", r.exitCode, Date().timeIntervalSince(t)))
    try await sb.shutDown()
    try await sb.delete()
}

// MARK: spike-audio-live

let liveMic = !args.contains("--no-mic")

func liveShare() -> URL {
    guard let s = argValue("--share") else { print("spike-audio-live needs --share DIR"); exit(2) }
    return URL(fileURLWithPath: s)
}

func liveSpec(_ name: String) -> SandboxSpec {
    SandboxSpec(name: name, storeRoot: storeRoot, kernelPath: kernelPath, kernelCacheDirectory: kernelCache, cpus: 2, memoryMiB: 512,
                rootfsMiB: 1024, bakePackages: ["bash", "ncurses"], shares: [Share(hostPath: liveShare().path, guestPath: "/out")], subnet: testSubnet)
}

func stamp() -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f.string(from: Date())
}

/// Samples of a raw S16_LE mono file.
func liveSamples(_ url: URL) -> [Int16] {
    guard let d = try? Data(contentsOf: url) else { return [] }
    return d.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
}

/// RMS (0…1 of full scale), peak, and the count of non-zero samples.
func liveStats(_ s: [Int16]) -> (rms: Double, peak: Int, nonzero: Int) {
    guard !s.isEmpty else { return (0, 0, 0) }
    var sum = 0.0, peak = 0, nz = 0
    for v in s { let x = Double(v) / 32768; sum += x * x; peak = max(peak, abs(Int(v))); if v != 0 { nz += 1 } }
    return ((sum / Double(s.count)).squareRoot(), peak, nz)
}

/// The first 1 ms window after `from` (seconds) whose RMS exceeds `factor` × the noise floor measured
/// over the preceding `from` seconds; nil if none.
func liveOnset(_ s: [Int16], rate: Double = 48000, from: Double) -> (seconds: Double, floor: Double, level: Double)? {
    let w = Int(rate / 1000)
    func rms(_ a: Int, _ b: Int) -> Double { guard b > a else { return 0 }; var t = 0.0; for i in a..<b { let x = Double(s[i]) / 32768; t += x * x }; return (t / Double(b - a)).squareRoot() }
    let start = Int(from * rate)
    guard start < s.count, start > w * 10 else { return nil }
    let floor = max(rms(0, start), 1e-5)
    var i = start
    while i + w <= s.count {
        let r = rms(i, i + w)
        if r > floor * 8 && r > 0.003 { return (Double(i) / rate, floor, r) }
        i += w
    }
    return nil
}

let liveSetup = """
set -e
apk add -q alsa-utils sox coreutils >/dev/null 2>&1 || apk add alsa-utils sox coreutils
# /proc/asound is masked by the container runtime (OCI maskedPaths); the card is seen through /dev/snd.
P=$(aplay -l 2>/dev/null | sed -n 's/^card \\([0-9]*\\):.*device \\([0-9]*\\):.*/\\1,\\2/p' | head -1)
C=$(arecord -l 2>/dev/null | sed -n 's/^card \\([0-9]*\\):.*device \\([0-9]*\\):.*/\\1,\\2/p' | head -1)
echo "devices: playback=hw:${P:-none} capture=hw:${C:-none}"
# ALSA's default is card 0 device 0 — on this card the CAPTURE device; make default an asym of both.
{ echo "pcm.!default { type asym"; [ -n "$P" ] && echo "  playback.pcm \\"plughw:$P\\""; [ -n "$C" ] && echo "  capture.pcm \\"plughw:$C\\""; echo "}"; echo "ctl.!default { type hw card 0 }"; } > /etc/asound.conf
echo "asound.conf: $(tr '\\n' ' ' < /etc/asound.conf)"
echo "aplay-l: $(aplay -l 2>&1 | grep -E '^card' | tr '\\n' ' ')"
echo "arecord-l: $(arecord -l 2>&1 | grep -E '^card' | tr '\\n' ' ')"
echo "dmesg: $(dmesg | grep -iE 'snd|virtio_snd|sound' | head -5 | tr '\\n' ';')"
echo "playback-hw: $(aplay -D hw:$P --dump-hw-params -d 1 /dev/zero 2>&1 | grep -E 'FORMAT|CHANNELS|RATE|PERIOD_TIME|BUFFER_TIME' | tr -s ' ' | tr '\\n' ';')"
[ -n "$C" ] && echo "capture-hw: $(arecord -D hw:$C --dump-hw-params -d 1 /dev/null 2>&1 | grep -E 'FORMAT|CHANNELS|RATE|PERIOD_TIME|BUFFER_TIME' | tr -s ' ' | tr '\\n' ';')"
sox -n -r 48000 -c 1 -b 16 /root/tone.wav synth 1.5 sine 440 fade 0.05 1.5 0.1 vol 0.1
sox -n -r 48000 -c 1 -b 16 /root/click.wav synth 0.01 sine 1000 vol 0.3
echo setup-ok
"""

func liveRecord(_ sb: Sandbox, _ name: String, seconds: Int, label: String) async throws -> (rms: Double, peak: Int, nonzero: Int, n: Int, out: String) {
    let r = try await sb.exec(["sh", "-c", "arecord -q -D default -f S16_LE -r 48000 -c 1 -t raw -d \(seconds) /out/\(name).raw 2>&1; echo rc=$?"],
                              privileged: true, timeoutSeconds: Int64(seconds + 30))
    let s = liveSamples(liveShare().appendingPathComponent("\(name).raw"))
    let st = liveStats(s)
    info(String(format: "[%@] recording %@: %d samples, RMS %.5f (%.1f dBFS), peak %d, non-zero %d — %@", label, name, s.count, st.rms,
                20 * log10(max(st.rms, 1e-9)), st.peak, st.nonzero, r.output.replacingOccurrences(of: "\n", with: " ")))
    return (st.rms, st.peak, st.nonzero, s.count, r.output)
}

/// The latency test: record 3 s; at 1.0 s (guest clock, after arecord has started) play a 10 ms click.
func liveLatency(_ sb: Sandbox, _ i: Int) async throws -> Double? {
    let script = """
    rm -f /out/lat\(i).raw
    t0=$(date +%s%N); arecord -q -D default -f S16_LE -r 48000 -c 1 -t raw -d 3 /out/lat\(i).raw & a=$!
    sleep 1; t1=$(date +%s%N); aplay -q -D default /root/click.wav; t2=$(date +%s%N); wait $a
    echo "t_click_ms=$(( (t1 - t0) / 1000000 )) aplay_ms=$(( (t2 - t1) / 1000000 ))"
    """
    print("        · CLICK \(i) played at \(stamp()) (10 ms, 1 kHz, -10 dBFS)")
    let r = try await sb.exec(["sh", "-c", script], privileged: true, timeoutSeconds: 40)
    let line = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    let tClick = Double(line.split(separator: " ").first { $0.hasPrefix("t_click_ms=") }?.dropFirst(11) ?? "") ?? 1000
    let s = liveSamples(liveShare().appendingPathComponent("lat\(i).raw"))
    guard let on = liveOnset(s, from: tClick / 1000 - 0.05) else {
        info("click \(i): \(line) — no onset found in the recording (\(s.count) samples); the microphone may not hear the speakers")
        return nil
    }
    let lat = on.seconds * 1000 - tClick
    info(String(format: "click %d: %@ · onset at %.1f ms in the recording (floor %.5f → %.5f) → round trip ≈ %.0f ms", i, line, on.seconds * 1000, on.floor, on.level, lat))
    return lat
}

var liveOpenStreams: String { "MIC=\(liveMic ? 1 : 0)\n" + liveOpenStreamsBody }
let liveOpenStreamsBody = """
rm -f /out/live.raw
[ "$MIC" = 1 ] && setsid sh -c 'arecord -q -D default -f S16_LE -r 48000 -c 1 -t raw > /out/live.raw 2>/root/arec.err' </dev/null >/dev/null 2>&1 &
setsid sh -c 'aplay -q -D default -f S16_LE -r 48000 -c 1 -t raw /dev/zero 2>/root/aplay.err' </dev/null >/dev/null 2>&1 &
sleep 1; echo "arecord=$(pidof arecord) aplay=$(pidof aplay)"
"""

/// Streams still open and flowing: both pids alive (the same ones), live.raw growing, a fresh recording works.
func liveStreamCheck(_ sb: Sandbox, _ what: String, pids: String) async throws {
    let share = liveShare().appendingPathComponent("live.raw")
    func size() -> Int { ((try? FileManager.default.attributesOfItem(atPath: share.path))?[.size] as? NSNumber)?.intValue ?? -1 }
    let a = size()
    await sleepS(1.5)
    let b = size()
    let r = try await sb.exec(["sh", "-c", "echo \"arecord=$(pidof arecord) aplay=$(pidof aplay)\"; tail -c 300 /root/arec.err /root/aplay.err 2>/dev/null | tr '\\n' ' '; dmesg | grep -iE 'snd|sound' | tail -3 | tr '\\n' ';'"],
                              privileged: true, timeoutSeconds: 30)
    let first = r.output.split(separator: "\n").first.map(String.init) ?? ""
    check(first == pids, "[\(what)] the open streams survived — same pids (\(first); was \(pids))")
    // The open PLAYBACK stream flows when aplay keeps consuming /dev/zero (rchar) — 96 000 bytes per second of audio.
    let flow = try await sb.exec(["sh", "-c", "p=$(pidof aplay); a=$(awk '/^rchar/{print $2}' /proc/$p/io); sleep 1.5; b=$(awk '/^rchar/{print $2}' /proc/$p/io); echo $((b - a))"],
                                 privileged: true, timeoutSeconds: 30)
    let bytes = Int(flow.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    check(bytes > 48_000, "[\(what)] the open PLAYBACK stream still flows: \(bytes) bytes in 1.5 s (\(bytes > 0 ? String(format: "%.0f", Double(bytes) / 1.5 / 96) : "0") ms of audio per s)")
    let second = try await sb.exec(["sh", "-c", "aplay -q -D default -f S16_LE -r 48000 -c 1 -t raw -d 1 /dev/zero 2>&1; echo rc=$?"], privileged: true, timeoutSeconds: 30)
    info("[\(what)] a second playback beside the open one: \(second.output.replacingOccurrences(of: "\n", with: " ")) (a raw hw PCM is exclusive without dmix — busy is expected)")
    guard liveMic else { return }
    check(b > a, "[\(what)] the open recording still flows: \(a) → \(b) bytes in 1.5 s (\(String(format: "%.0f", Double(b - a) / 1.5 / 96)) ms of audio per s)")
    let tail = r.output.split(separator: "\n").dropFirst().joined(separator: " ")
    if !tail.trimmingCharacters(in: .whitespaces).isEmpty { info("[\(what)] stream errors/dmesg: \(tail.prefix(400))") }
    // the most recent second of the open recording
    let s = liveSamples(share)
    let st = liveStats(Array(s.suffix(48000)))
    info(String(format: "[\(what)] last second of the open recording: RMS %.5f, peak %d, non-zero %d", st.rms, st.peak, st.nonzero))
    let fresh = try await liveRecord(sb, "fresh", seconds: 1, label: what)
    check(fresh.n > 40000, "[\(what)] a NEW recording beside the open one works (\(fresh.n) samples, RMS \(String(format: "%.5f", fresh.rms)))")
}

func liveVerify(_ sb: Sandbox) async throws -> String {
    let r = try await sb.exec(["sh", "-c", "pidof arecord >/dev/null || echo no-arecord; echo \"arecord=$(pidof arecord) aplay=$(pidof aplay)\""], privileged: true)
    return r.output.split(separator: "\n").last.map(String.init) ?? ""
}

func audioLiveSpike() async throws {
    let share = liveShare()
    try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
    info("kernel: \(kernelPath ?? "the pinned one (no sound — set DOZ_KERNEL)")")
    audSetDevice(true, mic: liveMic)
    let sb = try Sandbox(spec: liveSpec("aud-live"))
    let log = logEvents(sb)
    defer { log.cancel() }
    if await sb.phase != .off { try? await sb.shutDown() }
    try await sb.start()

    let s = try await sb.exec(["sh", "-c", liveSetup], privileged: true, timeoutSeconds: 300)
    for l in s.output.split(separator: "\n") { info("guest \(l)") }
    if !s.errorOutput.isEmpty { info("setup stderr: \(s.errorOutput.prefix(500))") }
    check(s.output.contains("setup-ok"), "alsa-utils + sox installed, tone and click generated")
    check(s.output.contains("devices: playback=hw:0,"), "the guest has an ALSA card (virtio-snd bound) with a playback device")
    if liveMic { check(!s.output.contains("capture=hw:none"), "… and a capture device") }

    // --mic-only (the owner's Terminal.app run): no tone, the recordings, two clicks, a clean shutdown —
    // no pause or snapshot (a capture blocked on an unanswered microphone prompt crashed VZ on pause).
    let micOnly = args.contains("--mic-only")
    if !micOnly {
    // 2a: the tone (output).
    print("        · TONE played at \(stamp()) (440 Hz, 1.5 s, -20 dBFS)")
    let tone = try await sb.exec(["sh", "-c", "t0=$(date +%s%N); aplay -D default /root/tone.wav 2>&1; echo rc=$? ms=$(( ($(date +%s%N) - t0) / 1000000 )); cat /proc/asound/card0/pcm0p/sub0/status 2>&1 | head -3 | tr '\\n' ' '"],
                                 privileged: true, timeoutSeconds: 30)
    info("tone: " + tone.output.replacingOccurrences(of: "\n", with: " ⏎ "))
    check(tone.output.contains("rc=0"), "aplay played the tone through the virtio-snd card (exit 0)")
    }

    if liveMic {
    // 2b: recordings from the Mac's microphone (three tries — a permission dialog may be up for the first).
    var heard = false
    for i in 1...6 {
        print("        · RECORD \(i) started at \(stamp())")
        let r = try await liveRecord(sb, "rec\(i)", seconds: 3, label: "mic")
        if r.nonzero > 1000 && r.rms > 1e-5 { heard = true; break }
        info("recording \(i) is silent — waiting 15 s (a permission dialog?) before the next")
        await sleepS(15)
    }
    check(heard, "a recording from the Mac's microphone has non-silent samples")

    // 3: round-trip latency.
    var lats: [Double] = []
    for i in 1...(micOnly ? 2 : 3) { if let l = try await liveLatency(sb, i) { lats.append(l) }; await sleepS(0.5) }
    info("round trip (click played → heard by the Mac's microphone): " + (lats.isEmpty ? "not detected" : lats.map { String(format: "%.0f ms", $0) }.joined(separator: ", ")))
        if micOnly {
            check(heard && !lats.isEmpty, "microphone heard and at least one click detected")
            try await sb.shutDown()
            try await sb.delete()
            return
        }
    } else {
        info("--no-mic: no input stream — the microphone parts are skipped")
    }

    // 5: the lifecycle with streams OPEN.
    let o = try await sb.exec(["sh", "-c", liveOpenStreams], privileged: true, timeoutSeconds: 30)
    let pids = o.output.trimmingCharacters(in: .whitespacesAndNewlines)
    check((!liveMic || !pids.contains("arecord= ")) && !pids.hasSuffix("aplay="), "streams opened: \(pids)")
    try await liveStreamCheck(sb, "open", pids: pids)
    for cycle in 1...2 {
        try await sb.pause(); try await sb.resume()
        try await liveStreamCheck(sb, "pause → resume \(cycle)", pids: pids)
        try await sb.sleep(); try await sb.wake()
        try await liveStreamCheck(sb, "sleep → wake \(cycle)", pids: pids)
        do {
            try await sb.hibernate()
            try await sb.wake()
            try await liveStreamCheck(sb, "hibernate → wake \(cycle)", pids: pids)
        } catch {
            check(false, "hibernate → wake \(cycle) with streams open: \(error.localizedDescription)")
            throw error
        }
    }
    try await sb.shutDown()
    try await sb.delete()

    // Restore into a new process with streams open (twice).
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    for (what, a) in [("1: start, open streams, quit (hibernate)", ["spike-audio-live-save"]),
                      ("2: restore in a new process, check the streams, quit again", ["spike-audio-live-restore"])] {
        print("spike: crash pattern — child \(what)")
        let p = Process(); p.executableURL = exe
        p.arguments = a + ["--store", storeRoot.path, "--share", share.path] + (liveMic ? [] : ["--no-mic"])
        try p.run(); p.waitUntilExit()
        check(p.terminationStatus == 0, "child \(what) — exited 0 (\(p.terminationStatus))")
    }
    print("spike: crash pattern — the parent restores (third process)")
    try await liveCrashRestore(thenQuit: false)
}

func liveCrashSave() async throws -> Int32 {
    audSetDevice(true, mic: liveMic)
    let sb = try Sandbox(spec: liveSpec("aud-live-crash"))
    let log = logEvents(sb, prefix: "[child] ")
    if await sb.phase != .off { try? await sb.shutDown() }
    try await sb.start()
    _ = try await sb.exec(["sh", "-c", "apk add -q alsa-utils coreutils >/dev/null 2>&1; echo ok"], privileged: true, timeoutSeconds: 120)
    let o = try await sb.exec(["sh", "-c", liveOpenStreams], privileged: true, timeoutSeconds: 30)
    let pids = o.output.trimmingCharacters(in: .whitespacesAndNewlines)
    try pids.write(to: liveShare().appendingPathComponent("crash-pids.txt"), atomically: true, encoding: .utf8)
    try await liveStreamCheck(sb, "child before quit", pids: pids)
    await sb.prepareForExit()
    log.cancel()
    let parked = await sb.phase == .hibernated
    return failures == 0 && parked ? 0 : 1
}

func liveCrashRestore(thenQuit: Bool) async throws {
    audSetDevice(true, mic: liveMic)
    let spec = liveSpec("aud-live-crash")
    let pids = ((try? String(contentsOf: liveShare().appendingPathComponent("crash-pids.txt"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let sb = try Sandbox(spec: spec)
    let log = logEvents(sb)
    defer { log.cancel() }
    let t = Date()
    try await sb.wake()
    check(await sb.phase == .running, String(format: "restored into a new process with streams open in %.0f ms", Date().timeIntervalSince(t) * 1000))
    try await liveStreamCheck(sb, thenQuit ? "new process 1" : "new process 2", pids: pids)
    if thenQuit {
        await sb.prepareForExit()
        check(await sb.phase == .hibernated, "quit again (hibernated) for the next process")
    } else {
        try await sb.shutDown()
        try await sb.delete()
    }
}
