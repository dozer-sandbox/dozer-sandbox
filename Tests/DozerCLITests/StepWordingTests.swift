import Foundation
import XCTest
@testable import DozerHost

/// 617 polish: every step a person sees has a running label (present tense) and a done label (past tense), in plain
/// words; the base's unpack is ONE line with real progress; the default animated view shows only what matters.
final class StepWordingTests: XCTestCase {
    /// One sample of each label the library emits (`timed(…)` in Sandbox/ImageBaker, the kernel, the host).
    static let samples: [String] = [
        "pulled the base image docker.io/library/node", "base image docker.io/library/node (cached)",
        "base disk flattened (node@83e613bd2957, 83e613bd2957) → 1203 MiB written, a 4096 MiB disk", "base disk ready (cached, 83e613bd2957)",
        "cloned the base disk (APFS clone)", "booted the bake VM", "bake network: no interface, via the Mac's proxy (bake policy)",
        "step: install Grok Build 1.0.50 (linux-arm64, integrity-pinned)", "step: install the developer baseline (procps git)",
        "step: create the agent user", "step: install the doz grok launcher", "verify: grok --version → grok 1.0.50",
        "trimmed the disk (fstrim /)", "stopped the bake VM cleanly", "flattened alpine to one ext4 disk (1024 MiB, 16 MiB journal)",
        "downloaded vmlinux-6.18.15-186 (14 MiB)", "verified and extracted vmlinux-6.18.15-186", "kernel vmlinux-6.18.15-186 ready (cached, sha256 verified)",
        "kernel ready (vmlinux-6.18.15-186: copied)", "guest init image ready (vminit: pulled + built its disk)",
        "VM created and booted (VZ start + Linux kernel + vminitd)", "container process started", "root disk cloned from the baked image grok (APFS clone)",
        "created the empty state disk (512 MiB, sparse, 16 MiB journal)", "installed deckhold (the guest PTY holder)",
        "network: no interface; doznet + the sandbox CA installed, DNS and egress via the Mac's proxy (locked policy)",
        "e2fsck state.ext4 (not cleanly unmounted; state)", "restored VM state from disk", "saved VM state to disk",
        "restored the VM from its snapshot into this process (pinned machine id)", "adopted the restored container",
        "paused the VM (guest CPU 0, memory kept)", "resumed the VM", "resumed", "re-synced the guest clock",
        "re-mounted 1 share(s) (virtio-fs does not survive a VM stop)", "resumed the VM to stop it gracefully", "stopped the container",
        "saving the host's state", "docker.io/library/alpine:3.20 ready (pulled)",
        "prepared the guest (persist dirs bound from the state disk)", "tools: installing git, curl with apk, through the proxy",
        "tools: gh 2.102.0 — for GitHub as you (gh 2.102.0, from Dozer's cache on the Mac)",
    ]

    func testEveryStepHasARunningAndADoneLabelInPlainWords() {
        for l in Self.samples {
            let w = StepWording.of(l)
            XCTAssertNotEqual(w.running, l, "\(l): a running label of its own")
            XCTAssertNotEqual(w.done, l, "\(l): a done label of its own")
            XCTAssertEqual(w.running.first?.isUppercase, true, w.running)
            XCTAssertEqual(w.done.first?.isUppercase, true, w.done)
            XCTAssertTrue(w.running.split(separator: " ").contains { $0.hasSuffix("ing") }, "\(w.running): present tense")
            for jargon in ["flattened", "APFS", "vminitd", "VZ ", "fstrim", "bake VM", "e2fsck", "deckhold", "PTY", "doznet", "guest init"] {
                XCTAssertFalse(w.running.contains(jargon) || w.done.contains(jargon), "\(l): no jargon (\(jargon))")
            }
        }
        let base = StepWording.of("base disk flattened (node@83e613bd2957, 83e613bd2957) → 1203 MiB written, a 4096 MiB disk")
        XCTAssertEqual(base.running, "Unpacking the Node.js base image — first time only for this base; later sandboxes reuse it")
        XCTAssertEqual(base.done, "Unpacked the Node.js base image (1203 MiB written, a 4096 MiB disk)")
        XCTAssertTrue(base.major)
        XCTAssertTrue(StepWording.of("pulled the base image docker.io/library/node").major)
        XCTAssertTrue(StepWording.of("step: install Grok Build 1.0.50 (linux-arm64, integrity-pinned)").major)
        XCTAssertFalse(StepWording.of("verify: grok --version → grok 1.0.50").major)
        XCTAssertFalse(StepWording.of("step: install the doz grok launcher").major)
        XCTAssertEqual(StepWording.of("something new").done, "something new", "an unknown label reads as it is")
        XCTAssertEqual(StepWording.transfer("unpacking node@83e613bd2957"), "Unpacking the Node.js base image")
    }

    func ev(_ k: HostEvent.Kind, _ t: String, ms: Double? = nil, done: Int64? = nil, total: Int64? = nil, items: Int? = nil, totalItems: Int? = nil) -> HostEvent {
        var e = HostEvent(kind: k, sandbox: "x", text: t, milliseconds: ms, completedBytes: done, totalBytes: total)
        e.completedItems = items
        e.totalItems = totalItems
        return e
    }

    /// The base's unpack: real progress while it runs (bytes, files, ETA), then ONE line — never two.
    func testTheUnpackIsOneLineWithRealProgress() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let v = ProgressTerminal(mode: .animated, color: false)
        v.width = 200
        let label = "base disk flattened (node@83e613bd2957, 83e613bd2957)"
        _ = v.apply(ev(.started, label), now: t0)
        _ = v.apply(ev(.progress, "unpacking node@83e613bd2957", done: 0, total: 1_000_000_000, items: 0, totalItems: 7364), now: t0)
        let mid = v.apply(ev(.progress, "unpacking node@83e613bd2957", done: 400_000_000, total: 1_000_000_000, items: 3000, totalItems: 7364), now: t0 + 4)
        XCTAssertTrue(mid.contains("Unpacking the Node.js base image — first time only"), mid)
        XCTAssertTrue(mid.contains("Unpacking the Node.js base image  ████████"), mid)
        XCTAssertTrue(mid.contains("0.4 / 1.0 GB") && mid.contains("(3000/7364 files)") && mid.contains("~"), mid)
        _ = v.apply(ev(.progress, "unpacking node@83e613bd2957", done: 1_000_000_000, total: 1_000_000_000, items: 7364, totalItems: 7364), now: t0 + 9)
        let end = v.apply(ev(.step, label + " → 1203 MiB written, a 4096 MiB disk", ms: 9000), now: t0 + 9)
        let lines = end.components(separatedBy: "\r\n").filter { $0.contains("✓") }
        XCTAssertEqual(lines.count, 1, end)
        XCTAssertTrue(lines[0].contains("✓ Unpacked the Node.js base image (1203 MiB written, a 4096 MiB disk) — 9.0 s"), lines[0])
    }

    /// The default animated view: the few steps a person cares about; -v shows every one; plain shows every one.
    func testTheDefaultViewIsQuietAndVerboseShowsAll() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let steps = ["pulled the base image docker.io/library/node", "cloned the base disk (APFS clone)", "booted the bake VM",
                     "step: install Grok Build 1.0.50 (x)", "verify: grok --version → grok 1.0.50", "trimmed the disk (fstrim /)"]
        func run(_ v: ProgressTerminal) -> String {
            var out = ""
            for s in steps {
                out += v.apply(ev(.started, s.components(separatedBy: " → ")[0]), now: t0)
                out += v.apply(ev(.step, s, ms: 100), now: t0)
            }
            out += v.apply(ev(.note, "fstrim: /: 3.5 GiB trimmed — 89 MiB returned to the Mac"), now: t0)
            out += v.apply(ev(.note, "warning: the base image changed"), now: t0)
            out += v.apply(ev(.failed, "step: create the agent user", ms: 5), now: t0)
            return out
        }
        let quiet = ProgressTerminal(mode: .animated, color: false)
        quiet.verbose = false
        let q = run(quiet)
        XCTAssertTrue(q.contains("✓ Downloaded the Node.js base image"))
        XCTAssertTrue(q.contains("✓ Installed Grok Build 1.0.50 (x)"))
        XCTAssertFalse(q.contains("Copied the base image"), "a detail: only with -v")
        XCTAssertFalse(q.contains("Checked the image"))
        XCTAssertFalse(q.contains("fstrim"))
        XCTAssertTrue(q.contains("warning: the base image changed"), "a real note stays")
        XCTAssertTrue(q.contains("✗ Creating the agent user"), "a failure always shows")
        let all = run(ProgressTerminal(mode: .animated, color: false))
        XCTAssertTrue(all.contains("Copied the base image") && all.contains("Checked the image") && all.contains("fstrim"))
        let plain = ProgressTerminal(mode: .plain, color: false)
        plain.verbose = false
        let p = run(plain)
        XCTAssertTrue(p.contains("Copied the base image") && p.contains("fstrim"), "plain mode: every line, as before")
    }
}
