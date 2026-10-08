import Darwin
import XCTest
@testable import DozerKit

/// 606 — the egress proxy never connects a sandbox to one of Dozer's own dashboards on this Mac (a proxied sandbox's
/// traffic leaves from the host process itself), whatever the policy says.
final class LocalDashboardsTests: XCTestCase {
    override func tearDown() { LocalDashboards.protect(nil) }

    func testTheMacsOwnAddressesOnADashboardPortAreRefused() throws {
        LocalDashboards.protect { [17443, 7443] }
        XCTAssertTrue(LocalDashboards.refuses(host: "127.0.0.1", port: 17443))
        XCTAssertTrue(LocalDashboards.refuses(host: "localhost", port: 7443))
        XCTAssertTrue(LocalDashboards.refuses(host: "::1", port: 7443))
        XCTAssertTrue(LocalDashboards.refuses(host: "0.0.0.0", port: 7443), "the unspecified address reaches this Mac too")
        // Each of this Mac's own interface addresses.
        var list: UnsafeMutablePointer<ifaddrs>?
        XCTAssertEqual(getifaddrs(&list), 0)
        defer { freeifaddrs(list) }
        var p = list
        var checked = 0
        while let ifa = p {
            if let a = ifa.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) {
                var buf = [CChar](repeating: 0, count: 64)
                var sin = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                inet_ntop(AF_INET, &sin, &buf, 64)
                XCTAssertTrue(LocalDashboards.refuses(host: String(cString: buf), port: 7443), String(cString: buf))
                checked += 1
            }
            p = ifa.pointee.ifa_next
        }
        XCTAssertGreaterThan(checked, 0)
        // Another port of the Mac, or another host's dashboard port: not this rule's business.
        XCTAssertFalse(LocalDashboards.refuses(host: "127.0.0.1", port: 8080))
        XCTAssertFalse(LocalDashboards.refuses(host: "198.51.100.7", port: 7443))
    }

    /// The connect itself refuses (the real wall — after the name is resolved): a listener that IS there.
    func testTheConnectIsRefusedToAListeningDashboard() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        XCTAssertEqual(withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }, 0)
        XCTAssertEqual(Darwin.listen(fd, 4), 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = UInt16(bigEndian: a.sin_port)
        let open = Wire.connectTCP("127.0.0.1", port, timeoutMS: 1000)
        XCTAssertGreaterThanOrEqual(open, 0, "unprotected: it connects")
        if open >= 0 { close(open) }
        LocalDashboards.protect { [port] }
        XCTAssertEqual(Wire.connectTCP("127.0.0.1", port, timeoutMS: 1000), -1, "a dashboard's port: never")
        XCTAssertEqual(Wire.connectTCP("localhost", port, timeoutMS: 1000), -1)
    }

    func testNothingIsProtectedUntilTheHostSaysSo() {
        LocalDashboards.protect(nil)
        XCTAssertFalse(LocalDashboards.refuses(host: "127.0.0.1", port: 7443))
    }
}
