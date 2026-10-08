import Darwin
import Foundation
import XCTest
@testable import DozerWeb

/// 606 — invites (one browser each, five minutes, link / code / QR), the attempt limits, and the devices kept until
/// revoked (cookie digests only, 0600).
final class ServeDevicesTests: XCTestCase {
    final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_800_000_000) }
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-serve-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    var file: URL { dir.appendingPathComponent("serve/devices.json") }

    func store(_ c: Clock) -> WebDeviceStore { WebDeviceStore(file: file, now: { c.t }) }

    func testCodesAreCrockfordAndForgiving() {
        let c = WebDeviceStore.randomCode()
        XCTAssertEqual(c.count, 8)
        XCTAssertTrue(c.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) })
        XCTAssertEqual(WebDeviceStore.display("ABCDEFGH"), "ABCD-EFGH")
        XCTAssertEqual(WebDeviceStore.normalize("abcd-efgh"), "ABCDEFGH")
        XCTAssertEqual(WebDeviceStore.normalize("O1IL 2345"), "01112345", "O is 0; I and L are 1")
        XCTAssertNil(WebDeviceStore.normalize("ABCD-EFG"))
        XCTAssertNil(WebDeviceStore.normalize("ABCD-EFGU"), "U is not in the alphabet")
        XCTAssertNil(WebDeviceStore.normalize("<script>"))
    }

    func testAnInviteAdmitsOneBrowserByLinkOrCode() async throws {
        let c = Clock()
        let s = store(c)
        let inv = await s.share(by: "the Mac")
        XCTAssertFalse("\(inv)".contains(inv.testToken), "the invite's description is redacted")
        let (session, dev) = try await s.admit(token: inv.testToken, code: nil, userAgent: "Mozilla/5.0 (iPhone; …) Safari/605.1", address: "192.168.86.48")
        XCTAssertEqual(dev.admittedVia, "link")
        XCTAssertEqual(dev.admittedBy, "the Mac")
        XCTAssertEqual(dev.name, "Safari on iPhone")
        // The link again, and its code: both spent (one invite, one browser).
        await assertRejects(.admissionUsed) { _ = try await s.admit(token: inv.testToken, code: nil, userAgent: nil, address: "192.168.86.49") }
        await assertRejects(.admissionUsed) { _ = try await s.admit(token: nil, code: inv.code, userAgent: nil, address: "192.168.86.49") }
        // The cookie signs in; the CSRF token is the device's.
        let (again, seen) = try await s.authenticate(session.cookieValue)
        XCTAssertEqual(again.csrfToken, session.csrfToken)
        XCTAssertEqual(seen.id, dev.id)
        // By code (typed in lower case with a space), from a second invite.
        let inv2 = await s.share(by: dev.name)
        let (_, dev2) = try await s.admit(token: nil, code: inv2.code.lowercased().replacingOccurrences(of: "-", with: " "), userAgent: "Mozilla/5.0 (Macintosh) Chrome/140", address: "192.168.86.50")
        XCTAssertEqual(dev2.admittedVia, "code")
        XCTAssertEqual(dev2.admittedBy, "Safari on iPhone")
        await assertRejects(.admissionUsed) { _ = try await s.admit(token: inv2.testToken, code: nil, userAgent: nil, address: "192.168.86.50") }
        let n = await s.list().count
        XCTAssertEqual(n, 2)
    }

    func testAnInviteExpiresAfterFiveMinutes() async throws {
        let c = Clock()
        let s = store(c)
        let inv = await s.share(by: "the Mac")
        c.t += WebDeviceStore.inviteLifetime + 1
        await assertRejects(.admissionRejected) { _ = try await s.admit(token: inv.testToken, code: nil, userAgent: nil, address: "a") }
        await assertRejects(.admissionRejected) { _ = try await s.admit(token: nil, code: inv.code, userAgent: nil, address: "a") }
        let open = await s.openInvites
        XCTAssertEqual(open, 0)
    }

    func testAtMostEightOpenInvitesTheOldestGoes() async {
        let s = store(Clock())
        var first: WebServeInvite?
        for i in 0..<9 { let inv = await s.share(by: "x"); if i == 0 { first = inv } }
        let open = await s.openInvites
        XCTAssertEqual(open, WebDeviceStore.maximumInvites)
        await assertRejects(.admissionRejected) { _ = try await s.admit(token: first!.testToken, code: nil, userAgent: nil, address: "a") }
    }

    func testWrongAttemptsAreLimited() async throws {
        let c = Clock()
        let s = store(c)
        let inv = await s.share(by: "the Mac")
        for _ in 0..<WebAttemptLimiter.perAddress {
            await assertRejects(.admissionRejected) { _ = try await s.admit(token: nil, code: "ZZZZ-ZZZZ", userAgent: nil, address: "10.0.0.66") }
        }
        // That address is blocked — even with the right code.
        await assertRejects(.tooManyAttempts) { _ = try await s.admit(token: nil, code: inv.code, userAgent: nil, address: "10.0.0.66") }
        // Another address still can.
        _ = try await s.admit(token: nil, code: inv.code, userAgent: nil, address: "10.0.0.67")
        // Ten minutes later the first one may try again.
        c.t += WebAttemptLimiter.window + 1
        let inv2 = await s.share(by: "the Mac")
        _ = try await s.admit(token: inv2.testToken, code: nil, userAgent: nil, address: "10.0.0.66")
    }

    func testTwentyWrongCodesInAllCancelEveryOpenCodeButNotTheLinks() async throws {
        let s = store(Clock())
        let inv = await s.share(by: "the Mac")
        for i in 0..<WebAttemptLimiter.codesInAll {
            await assertRejects(.admissionRejected) { _ = try await s.admit(token: nil, code: "ZZZZ-ZZZZ", userAgent: nil, address: "10.1.0.\(i)") }
        }
        await assertRejects(.admissionRejected) { _ = try await s.admit(token: nil, code: inv.code, userAgent: nil, address: "10.2.0.1") }
        _ = try await s.admit(token: inv.testToken, code: nil, userAgent: nil, address: "10.2.0.1")
    }

    func testTheFileHoldsDigestsOnlyAndIsPrivate() async throws {
        let s = store(Clock())
        let inv = await s.share(by: "the Mac")
        let (session, dev) = try await s.admit(token: inv.testToken, code: nil, userAgent: "curl/8", address: "192.168.86.48")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains(session.cookieValue), "never the cookie")
        XCTAssertFalse(text.contains(inv.testToken))
        XCTAssertFalse(text.contains(inv.code.replacingOccurrences(of: "-", with: "")))
        XCTAssertTrue(text.contains(WebDeviceStore.digest(session.cookieValue)))
        var st = stat()
        stat(file.path, &st)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        stat(file.deletingLastPathComponent().path, &st)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        // A new process (doz serve restarted) knows the device — no expiry.
        let c2 = Clock()
        c2.t += 400 * 24 * 3600
        let reopened = store(c2)
        let (_, back) = try await reopened.authenticate(session.cookieValue)
        XCTAssertEqual(back.id, dev.id, "kept until revoked — a year later too")
    }

    func testRevokeRenameTouchSignOut() async throws {
        let c = Clock()
        let s = store(c)
        let a = try await s.admit(token: (await s.share(by: "the Mac")).testToken, code: nil, userAgent: "curl/8", address: "a")
        let b = try await s.admit(token: (await s.share(by: "the Mac")).testToken, code: nil, userAgent: "curl/8", address: "b")
        XCTAssertNotEqual(a.1.name, b.1.name, "two of a kind are told apart (curl, curl 2)")
        c.t += 30
        await s.touch(a.0.cookieValue, address: "192.168.86.99", userAgent: "Mozilla/5.0 Firefox/130")
        let listed = await s.list(current: a.0.cookieValue)
        let mine = try XCTUnwrap(listed.first { $0.id == a.1.id })
        XCTAssertEqual(mine.current, true)
        XCTAssertEqual(mine.lastAddress, "192.168.86.99")
        XCTAssertEqual(mine.lastSeen, c.t)
        let renamed = try await s.rename(id: b.1.id, to: "Kitchen\niPad")
        XCTAssertEqual(renamed.name, "KitcheniPad", "no control characters")
        let (digest, gone) = try await s.revoke(id: b.1.id, by: "the Mac")
        XCTAssertEqual(digest, WebDeviceStore.digest(b.0.cookieValue))
        XCTAssertEqual(gone.id, b.1.id)
        await assertRejects(.deviceRevoked) { _ = try await s.authenticate(b.0.cookieValue) }
        let valid = await s.isValid(b.0.cookieValue)
        XCTAssertFalse(valid)
        await assertRejects(.notFound) { _ = try await s.revoke(id: "zzzzzz", by: "x") }
        await s.signOut(a.0.cookieValue)
        await assertRejects(.deviceRevoked) { _ = try await s.authenticate(a.0.cookieValue) }
        await assertRejects(.notAdmitted) { _ = try await s.authenticate("never-a-cookie-of-ours-0123456789") }
        let left = await s.list()
        XCTAssertTrue(left.isEmpty)
    }

    func testCSRFIsRequiredForChanges() async throws {
        let s = store(Clock())
        let (session, _) = try await s.admit(token: (await s.share(by: "x")).testToken, code: nil, userAgent: nil, address: "a")
        await assertRejects(.csrfRejected) { _ = try await s.authenticateMutation(session.cookieValue, csrf: nil) }
        await assertRejects(.csrfRejected) { _ = try await s.authenticateMutation(session.cookieValue, csrf: "wrong") }
        _ = try await s.authenticateMutation(session.cookieValue, csrf: session.csrfToken)
    }

    func testRevokeWithoutARunningServe() async throws {
        let s = store(Clock())
        let (session, dev) = try await s.admit(token: (await s.share(by: "x")).testToken, code: nil, userAgent: nil, address: "a")
        await s.flush()
        XCTAssertEqual(WebDeviceStore.listFile(file).map(\.id), [dev.id])
        XCTAssertEqual(try WebDeviceStore.renameInFile(file, id: dev.id, to: "Desk").name, "Desk")
        XCTAssertEqual(try WebDeviceStore.revokeInFile(file, id: dev.id, by: "the Mac", now: Clock().t).map(\.id), [dev.id])
        XCTAssertTrue(WebDeviceStore.listFile(file).isEmpty)
        // The next doz serve refuses that cookie and says why.
        let next = store(Clock())
        await assertRejects(.deviceRevoked) { _ = try await next.authenticate(session.cookieValue) }
    }

    func testFamilies() {
        XCTAssertEqual(WebDeviceStore.family("Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"), "Safari on iPad")
        XCTAssertEqual(WebDeviceStore.family("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140.0 Safari/537.36"), "Chrome on macOS")
        XCTAssertEqual(WebDeviceStore.family("Mozilla/5.0 (Windows NT 10.0) Chrome/140 Safari/537.36 Edg/140"), "Edge on Windows")
        XCTAssertEqual(WebDeviceStore.family("Mozilla/5.0 (Linux; Android 15) Chrome/140 Mobile"), "Chrome on Android")
        XCTAssertEqual(WebDeviceStore.family(""), "A browser")
    }

    func testTheAuditLogRotatesAndCollapses() throws {
        let f = dir.appendingPathComponent("serve/audit.jsonl")
        final class C: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_800_000_000) }
        let c = C()
        let a = WebServeAudit(file: f, now: { c.t })
        for _ in 0..<50 { a.record(WebAuditEntry(kind: "dropped", address: "192.168.112.2", outcome: "sandbox")) }
        c.t += 61
        a.record(WebAuditEntry(kind: "dropped", address: "192.168.112.2", outcome: "sandbox"))
        a.record(WebAuditEntry(kind: "admit", device: "abc123", deviceName: "iPad", address: "192.168.86.48"))
        let r = WebServeAudit.recent(f)
        XCTAssertEqual(r.count, 3, "50 drops in a minute are one line, then one line standing for them all")
        XCTAssertEqual(r[1].count, 50, "the second drop line counts the 49 suppressed + itself")
        XCTAssertEqual(r[0].kind, "admit")
        var st = stat()
        stat(f.path, &st)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        // Rotation at 1 MiB, three files kept.
        for i in 0..<9000 { a.record(WebAuditEntry(kind: "change", device: "abc123", deviceName: "iPad", address: "192.168.86.48", route: "actions", action: "start", sandbox: "s\(i)", outcome: "ok")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path + ".1"))
        XCTAssertLessThanOrEqual(try FileManager.default.attributesOfItem(atPath: f.path)[.size] as! Int, WebServeAudit.maximumBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path + ".3"))
    }

    func assertRejects(_ r: WebRejection, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected \(r)", file: file, line: line) } catch let e as WebRejection {
            XCTAssertEqual(e, r, file: file, line: line)
        } catch { XCTFail("\(error)", file: file, line: line) }
    }
}
