import Foundation
import XCTest
import DozerKit
import DozerHost
@testable import DozerWeb

/// 612: the agents' status reaches the page field by field — the words from the server, the program's own text
/// (untrusted) capped, nothing more.
final class WebAgentStatusTests: XCTestCase {
    func testTheProjectionCapsTheProgramsTextAndCarriesTheWords() throws {
        let long = String(repeating: "m", count: 2000), title = String(repeating: "t", count: 192)
        let s = SessionStatus(session: "main", state: .blocked, app: "claude-code", kind: .question, progress: 10, message: long, title: title,
                              updatedAt: Date(timeIntervalSince1970: 5))
        let w = WebAgentStatus(s)
        XCTAssertEqual(w.state, "blocked")
        XCTAssertEqual(w.kind, "question")
        XCTAssertEqual(w.label, "blocked: has a question")
        XCTAssertEqual(w.message?.count, WebAgentStatus.maximumMessage)
        XCTAssertTrue(w.message?.hasSuffix("…") == true)
        XCTAssertEqual(w.title?.count, WebAgentStatus.maximumTitle)
        let keys = Set((try JSONSerialization.jsonObject(with: WebJSON.encoder.encode(w)) as! [String: Any]).keys)
        XCTAssertEqual(keys, ["session", "state", "label", "kind", "progress", "app", "message", "title", "updatedAt"])
    }

    func testRowsCarryTheStatuses() {
        var info = SandboxInfo(name: "box", image: "lab", phase: "running", busy: false, cpus: 1, memoryMiB: 512, ramHeldMiB: 0,
                               memoryReturnedMiB: 0, diskBytes: 0, sessions: nil, network: "nat", deniedConnections: nil,
                               workspace: nil, createdAt: nil, diedWithHost: nil)
        XCTAssertNil(WebSandboxRow(info).agentStatus)
        let st = SessionStatus(session: "main", state: .working, updatedAt: Date())
        info.sessionStatuses = [st]
        info.agentStatus = st
        info.agentWorking = true
        let row = WebSandboxRow(info)
        XCTAssertEqual(row.agentStatus?.label, "working")
        XCTAssertEqual(row.sessionStatuses?.map(\.session), ["main"])
        XCTAssertEqual(row.agentWorking, true)
        var sr = SessionRow(SessionInfo(name: "main", pid: 1))
        sr.status = st
        XCTAssertEqual(WebSessionRow(sr).status?.state, "working")
    }
}
