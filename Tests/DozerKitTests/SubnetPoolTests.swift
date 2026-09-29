import XCTest
@testable import DozerKit

/// 583: automatic vmnet subnets — never one the Mac already has an interface on, never one this
/// process holds, and an explicit subnet stays an override.
final class SubnetPoolTests: XCTestCase {
    private func ip(_ s: String) -> UInt32 { SubnetPool.network(of: s + "/24")! | (UInt32(s.split(separator: ".").last!)! & 0xFF) }

    func test_candidatesAre192_168_100_to_199() {
        XCTAssertEqual(SubnetPool.candidates.count, 100)
        XCTAssertEqual(SubnetPool.cidr(SubnetPool.candidates.first!), "192.168.100.0/24")
        XCTAssertEqual(SubnetPool.cidr(SubnetPool.candidates.last!), "192.168.199.0/24")
        XCTAssertEqual(SubnetPool.network(of: "192.168.201.0/24"), SubnetPool.network(of: "192.168.201.7/24"))
        XCTAssertNil(SubnetPool.network(of: "nonsense"))
    }

    func test_skipsHostNetworksInEitherDirection() {
        let lan = (address: ip("192.168.150.23"), mask: UInt32(0xFFFF_FF00))           // a /24 LAN inside the pool
        let wide = (address: ip("192.168.160.1"), mask: UInt32(0xFFFF_F000))           // a /20: .160–.175
        let host = ip("192.168.180.5")
        let tiny = (address: host, mask: UInt32(0xFFFF_FFFC))                          // a /30 inside .180
        let free = Set(SubnetPool.free(host: [lan, wide, tiny], taken: [], start: 0).map(SubnetPool.cidr))
        XCTAssertFalse(free.contains("192.168.150.0/24"))
        for n in 160...175 { XCTAssertFalse(free.contains("192.168.\(n).0/24"), "\(n) is inside the /20") }
        XCTAssertFalse(free.contains("192.168.180.0/24"))
        XCTAssertTrue(free.contains("192.168.151.0/24"))
        XCTAssertTrue(free.contains("192.168.176.0/24"))
        XCTAssertEqual(free.count, 100 - 1 - 16 - 1)
        // A 10/8 or 172.16/12 network (a VPN, Docker) is disjoint from the pool.
        let other = [(address: UInt32(10 << 24), mask: UInt32(0xFF00_0000)), (address: UInt32(172 << 24 | 16 << 16), mask: UInt32(0xFFF0_0000))]
        XCTAssertEqual(SubnetPool.free(host: other, taken: [], start: 0).count, 100)
    }

    func test_skipsWhatThisProcessHoldsAndStartsAnywhere() {
        let taken: Set<UInt32> = [SubnetPool.candidates[0], SubnetPool.candidates[5]]
        let order = SubnetPool.free(host: [], taken: taken, start: 3)
        XCTAssertEqual(order.first, SubnetPool.candidates[3], "starts at the given offset")
        XCTAssertEqual(order.count, 98)
        XCTAssertFalse(order.contains(SubnetPool.candidates[5]))
        XCTAssertEqual(Set(order).count, order.count, "each candidate once")
    }

    func test_reserveAndReleaseCount() {
        let s = "192.168.123.0/24", n = SubnetPool.network(of: s)!
        SubnetPool.reserve(s); SubnetPool.reserve(s)
        XCTAssertTrue(SubnetPool.reserved.contains(n))
        SubnetPool.release(s)
        XCTAssertTrue(SubnetPool.reserved.contains(n), "two holders, one released")
        SubnetPool.release(s)
        XCTAssertFalse(SubnetPool.reserved.contains(n))
    }
}
