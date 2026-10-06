import Foundation
import DozerKit
import XCTest
@testable import DozerHost

/// EXPERIMENTAL (604) — audio sandboxes in the host: `--audio` reaches the spec (and only it), the sound kernel is
/// never taken unverified, and the host can name the app macOS asks about the microphone for.
final class AudioHostTests: XCTestCase {
    var root: URL!
    var store: DozerStore { DozerStore(root: root.appendingPathComponent("store")) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("audiohost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("store"), withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testAudioReachesTheSpecAndNothingElseChanges() throws {
        let (plain, _) = try DozerImages.spec(name: "p1", options: CreateOptions(image: "lab"), store: store, environment: [:])
        var o = CreateOptions(image: "lab")
        o.audio = true
        let (audio, _) = try DozerImages.spec(name: "p1", options: o, store: store, environment: [:])
        XCTAssertNil(plain.audio)
        XCTAssertEqual(audio.audio, true)
        var same = audio
        same.audio = nil
        XCTAssertEqual(same, plain, "audio is the only difference (the kernel path stays the pinned one's)")
        XCTAssertNil(audio.kernelPath)
        // An options JSON without the field decodes as before.
        let old = try JSONDecoder().decode(CreateOptions.self, from: Data(#"{"image":"lab"}"#.utf8))
        XCTAssertNil(old.audio)
    }

    func testTheSoundKernelIsRefusedWhenThisDozCarriesNone() throws {
        let cache = root.appendingPathComponent("kernels")
        XCTAssertThrowsError(try MacAudio.installSoundKernel(into: cache, environment: [:])) { e in
            XCTAssertTrue(HostError.from(e).message.contains("does not carry"), HostError.from(e).message)
        }
        let fake = root.appendingPathComponent("fake-kernel")
        try Data(repeating: 1, count: 1024).write(to: fake)
        XCTAssertThrowsError(try MacAudio.installSoundKernel(into: cache, environment: ["DOZ_TEST_SOUND_KERNEL": fake.path])) { e in
            XCTAssertTrue(HostError.from(e).message.contains("not the pinned file"), HostError.from(e).message)
        }
    }

    func testTheResponsibleAppIsNamedWhenMacOSKnowsIt() {
        // Whatever runs the tests (a terminal, an editor) — named, with a path, or nil; never a crash.
        if let app = MacAudio.responsibleApp() {
            XCTAssertFalse(app.name.isEmpty)
            XCTAssertTrue(app.path.hasPrefix("/"))
            XCTAssertGreaterThan(app.pid, 0)
        }
        XCTAssertNil(ToolInputs(github: false).audio)
    }
}
