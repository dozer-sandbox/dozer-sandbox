import Foundation
import DozerKit
import XCTest
@testable import DozerHost

/// The host protocol: requests and messages round-trip, a message is ONE line, results carry typed
/// structs through JSONValue, and the attach wire's frames and ended notice parse.
final class ProtocolTests: XCTestCase {
    func testRequestRoundTripsAndIsOneLine() throws {
        var r = HostRequest(.exec, name: "box")
        r.argv = ["sh", "-c", "echo 'a\nb'"]
        r.environment = ["K": "v"]
        r.timeoutSeconds = 30
        r.wake = false
        let d = try HostWire.encoder.encode(r)
        XCTAssertFalse(d.contains(10), "a request is a single line")
        let back = try HostWire.decoder.decode(HostRequest.self, from: d)
        XCTAssertEqual(back, r)
        XCTAssertEqual(back.v, HostProtocol.version)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
        XCTAssertEqual(obj["op"] as? String, "exec")
    }

    func testOpNamesAreTheWireNames() {
        XCTAssertEqual(HostOp.hibernate.rawValue, "hibernate")
        XCTAssertEqual(HostOp.pointSaveImage.rawValue, "point-save-image")
        XCTAssertEqual(HostOp.hostStop.rawValue, "host-stop")
        XCTAssertTrue(HostOp.ls.isReadOnly)
        XCTAssertFalse(HostOp.start.isReadOnly)
    }

    func testANewerFieldIsIgnoredByAnOlderReader() throws {
        let line = #"{"v":1,"op":"ls","somethingNew":{"x":1}}"#
        let r = try HostWire.decoder.decode(HostRequest.self, from: Data(line.utf8))
        XCTAssertEqual(r.op, .ls)
    }

    func testMessagesCarryTypedResults() throws {
        let info = SandboxInfo(name: "box", image: "lab", phase: "hibernated", busy: false, cpus: 2, memoryMiB: 1024, ramHeldMiB: 0,
                               memoryReturnedMiB: 0, diskBytes: 123_456_789, sessions: nil, network: "bake", deniedConnections: 3,
                               workspace: "/tmp/ws", createdAt: Date(timeIntervalSince1970: 1_790_000_000.25), diedWithHost: nil)
        let m = HostMessage.success(try JSONValue(encoding: [info]))
        var line = try HostWire.encoder.encode(m)
        XCTAssertFalse(line.contains(10))
        line.append(10)
        let reader = LineReaderFixture(line)
        let back = try HostWire.decoder.decode(HostMessage.self, from: reader)
        XCTAssertEqual(back.ok, true)
        let rows = try XCTUnwrap(back.result).decode([SandboxInfo].self)
        XCTAssertEqual(rows, [info])
        // Whole numbers stay whole on the wire (no 123456789.0 for a byte count).
        XCTAssertTrue(String(decoding: line, as: UTF8.self).contains("\"diskBytes\":123456789"))
    }

    func testErrorsMapFromLibraryErrors() {
        XCTAssertEqual(HostError.from(SandboxError.invalidPhase(operation: "pause", phase: .off)).code, .invalidPhase)
        XCTAssertEqual(HostError.from(SandboxError.notRunning(.hibernated)).code, .invalidPhase)
        XCTAssertEqual(HostError.from(SandboxError.restorePointNotFound("x")).code, .notFound)
        XCTAssertEqual(HostError.from(SandboxError.alreadyExists("x")).code, .exists)
        XCTAssertEqual(HostError.from(SandboxError.invalidSpec("x")).code, .invalid)
        XCTAssertEqual(HostError.from(HostError(.notImplemented, "later")).code, .notImplemented)
        let wire = try? HostWire.encoder.encode(HostMessage.failure(HostError(.notFound, "no sandbox x")))
        XCTAssertEqual(wire.map { String(decoding: $0, as: UTF8.self) }, #"{"error":{"code":"not-found","message":"no sandbox x"},"ok":false,"v":1}"#)
    }

    func testLibraryEventsBecomeHostEvents() throws {
        let e = try XCTUnwrap(HostEvent(.step("saved VM state to disk", milliseconds: 312.4), sandbox: "box"))
        XCTAssertEqual(e.kind, .step)
        XCTAssertEqual(e.line, "box: saved VM state to disk — 312 ms")
        XCTAssertEqual(HostEvent(.phase(.hibernated), sandbox: "box")?.phase, "hibernated")
        XCTAssertEqual(HostEvent(.phase(.hibernated), sandbox: "box")?.text, "hibernated")
        XCTAssertNil(HostEvent(.status(SandboxStatus(phase: .off, busy: false, ramHeldMiB: 0, snapshotBytes: 0)), sandbox: "box"))
        let m = HostMessage(event: e)
        let back = try HostWire.decoder.decode(HostMessage.self, from: HostWire.encoder.encode(m))
        XCTAssertEqual(back.event?.text, "saved VM state to disk")
        XCTAssertNil(back.ok)
    }

    func testJSONValueRoundTrip() throws {
        let v: JSONValue = .object(["a": .array([.number(1), .number(2.5), .null, .bool(true)]), "s": .string("x\ny")])
        XCTAssertEqual(try HostWire.decoder.decode(JSONValue.self, from: HostWire.encoder.encode(v)), v)
        XCTAssertEqual(v["s"]?.stringValue, "x\ny")
    }

    // MARK: the line reader

    func testLineReaderKeepsWhatFollowsTheLine() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        UnixSocket.writeAll(fds[1], Data("{\"ok\":true}\n\u{1B}[Hhello".utf8))
        let r = LineReader(fd: fds[0])
        XCTAssertEqual(r.readLine().map { String(decoding: $0, as: UTF8.self) }, "{\"ok\":true}")
        XCTAssertEqual(String(decoding: r.takeRemainder(), as: UTF8.self), "\u{1B}[Hhello")
        XCTAssertTrue(r.takeRemainder().isEmpty)
    }

    // MARK: the attach wire

    func testClientFramesParseAcrossReads() {
        var p = ClientWire.Parser()
        let bytes: [UInt8] = Array("ab".utf8) + ClientWire.hello(TermSize(cols: 300, rows: 50)) + Array("c".utf8)
            + ClientWire.resize(TermSize(cols: 80, rows: 24))
        var frames: [ClientWire.Frame] = []
        for chunk in stride(from: 0, to: bytes.count, by: 3) { frames += p.feed(Array(bytes[chunk..<min(chunk + 3, bytes.count)])) }
        let inputs = frames.compactMap { if case .input(let d) = $0 { return String(decoding: d, as: UTF8.self) }; return nil }.joined()
        XCTAssertEqual(inputs, "abc")
        XCTAssertTrue(frames.contains(.hello(TermSize(cols: 300, rows: 50))))
        XCTAssertEqual(frames.last, .resize(TermSize(cols: 80, rows: 24)))
    }

    func testEndedNoticeRoundTrips() throws {
        for (ending, _) in [(ClientWire.Ending.exited(42), 0), (.exited(0), 0), (.noSession, 0), (.stopped, 0)] {
            let bytes = Array("screen bytes".utf8) + Array(ClientWire.endedNotice(ending, text: "over"))
            let (found, start) = try XCTUnwrap(ClientWire.findEnding(in: bytes))
            XCTAssertEqual(found, ending)
            XCTAssertEqual(String(decoding: bytes[..<start], as: UTF8.self), "screen bytes", "the notice (and its reset) is cut off the screen")
        }
        XCTAssertNil(ClientWire.findEnding(in: Array("\u{1B}]777;doz;ended;4".utf8)), "an unfinished notice is not found yet")
    }
}

/// Strips the trailing newline the wire adds (the decoder reads one line).
private func LineReaderFixture(_ d: Data) -> Data { d.last == 10 ? d.dropLast() : d }
