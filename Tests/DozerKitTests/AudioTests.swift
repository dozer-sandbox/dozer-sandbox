import Foundation
import Virtualization
import XCTest
@testable import DozerKit

/// EXPERIMENTAL (604) — audio sandboxes: nothing changes for a sandbox without audio; an audio one gets the device
/// (recorded in its layout), the tools layer's audio items, and a verified sound kernel.
final class AudioTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func spec() -> SandboxSpec {
        SandboxSpec(name: "a1", storeRoot: dir, cpus: 2, memoryMiB: 512, rootfsMiB: 1024, bakePackages: ["bash"])
    }

    func json<T: Encodable>(_ v: T) throws -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(v), as: UTF8.self)
    }

    func testASpecWithoutAudioEncodesExactlyAsBefore() throws {
        let s = spec()
        XCTAssertNil(s.audio)
        XCTAssertFalse(try json(s).contains("\"audio\":"), "no audio key for a sandbox without audio")
        // A spec written before (no key) decodes as no audio.
        let decoded = try JSONDecoder().decode(SandboxSpec.self, from: Data(try json(s).utf8))
        XCTAssertEqual(decoded, s)
        XCTAssertNil(decoded.audio)
        // The prepared disk's key never sees it.
        var a = s
        a.audio = true
        XCTAssertEqual(StoreLayout.goldenKey(for: a), StoreLayout.goldenKey(for: s))
        XCTAssertTrue(try json(a).contains("\"audio\":true"))
        XCTAssertEqual(try JSONDecoder().decode(SandboxSpec.self, from: Data(try json(a).utf8)).audio, true)
    }

    func testToolInputsWithoutAudioEncodeAsBeforeAndPlanNothingNew() throws {
        let plain = ToolInputs(github: true, ssh: false, tmux: true)
        XCTAssertEqual(try json(plain), #"{"github":true,"ssh":false,"tmux":true}"#)
        XCTAssertNil(ToolInputs(audio: false, audioApp: "Terminal").audioApp, "the app is kept only for audio")
        let ids = ToolsLayer.plan(plain).items.map(\.id)
        XCTAssertFalse(ids.contains("alsa-utils") || ids.contains("asound-conf") || ids.contains("doz-sound"))
        let script = ToolsLayer.applyScript(ToolsLayer.plan(plain), state: .init(), ghCopied: false, ghProblem: nil)
        XCTAssertFalse(script.contains("doz-sound") || script.contains("asound"))
    }

    func testAnAudioSandboxGetsAlsaTheDefaultAndDozSound() throws {
        let inputs = ToolInputs(audio: true, audioApp: "Terminal")
        let plan = ToolsLayer.plan(inputs)
        XCTAssertEqual(plan.items.filter { $0.reason.contains("audio") }.map(\.id), ["alsa-utils", "asound-conf", "doz-sound"])
        XCTAssertEqual(plan.items.first { $0.id == "alsa-utils" }?.package, "alsa-utils")
        var state = ToolsLayer.GuestState()
        state.packageManager = "apk"
        let script = ToolsLayer.applyScript(plan, state: state, ghCopied: false, ghProblem: nil, audioApp: inputs.audioApp)
        XCTAssertTrue(script.contains("apk add --no-progress") && script.contains("alsa-utils"))
        XCTAssertTrue(script.contains(DozSound.asoundStamp) && script.contains("type asym") && !script.contains("dmix ipc_key"))
        XCTAssertTrue(script.contains("MAC_APP='Terminal'"))
        XCTAssertTrue(script.contains(Data(DozSound.script.utf8).base64EncodedString()))
        XCTAssertEqual(DozSound.safeAppName("Evil'; rm -rf /"), "Evil rm -rf ")
        XCTAssertEqual(DozSound.safeAppName(nil), "the app that started doz")
        // Both scripts parse as POSIX sh.
        for (name, text) in [("apply", script), ("doz-sound", DozSound.script)] {
            let f = dir.appendingPathComponent(name + ".sh")
            try text.write(to: f, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-n", f.path]
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "\(name) does not parse")
        }
        XCTAssertTrue(DozSound.script.contains(DozSound.stamp) && DozSound.script.contains("TEMPORARY"))
        XCTAssertTrue(DozSound.script.contains("timeout"), "a recording never hangs")
    }

    func testTheAudioDeviceIsInTheLayoutSoAMismatchedRestoreIsRefused() throws {
        func config(audio: Bool) -> VZVirtualMachineConfiguration {
            let c = VZVirtualMachineConfiguration()
            c.platform = VZGenericPlatformConfiguration()
            if audio { AudioDevice.add(to: c) }
            return c
        }
        let with = VMLayout.of(config(audio: true), kernelSHA256: "k")
        let without = VMLayout.of(config(audio: false), kernelSHA256: "k")
        XCTAssertEqual(with.otherDevices["audio"], 1)
        XCTAssertNil(without.otherDevices["audio"])
        XCTAssertFalse(with.differences(from: without).isEmpty)
        XCTAssertFalse(without.differences(from: with).isEmpty)
        let snd = try XCTUnwrap(config(audio: true).audioDevices.first as? VZVirtioSoundDeviceConfiguration)
        XCTAssertEqual(snd.streams.count, 2)
        XCTAssertTrue(snd.streams.contains { $0 is VZVirtioSoundDeviceInputStreamConfiguration })
        XCTAssertTrue(snd.streams.contains { $0 is VZVirtioSoundDeviceOutputStreamConfiguration })
    }

    func testTheSoundKernelIsVerifiedBeforeUse() throws {
        let fake = dir.appendingPathComponent("vmlinux-fake")
        try Data(repeating: 7, count: 4096).write(to: fake)
        XCTAssertFalse(SoundKernel.isVerified(fake))
        XCTAssertFalse(SoundKernel.isVerified(dir.appendingPathComponent("nothing")))
        let cache = dir.appendingPathComponent("kernels")
        XCTAssertThrowsError(try SoundKernel.install(from: fake, into: cache))
        XCTAssertFalse(FileManager.default.fileExists(atPath: SoundKernel.path(inCache: cache).path), "nothing unverified is put in place")
        XCTAssertEqual(SoundKernel.path(inCache: cache).lastPathComponent, "vmlinux-6.18.15-186-sound")
        XCTAssertEqual(SoundKernel.sha256.count, 64)
    }
}
