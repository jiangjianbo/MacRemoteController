import XCTest
@testable import MacScreenCore

final class LANGuardTests: XCTestCase {
    func subnet(_ address: String, _ prefix: Int) -> IPv4Subnet {
        IPv4Subnet(address: address, prefix: prefix)!
    }

    func helper(_ interfaces: LocalInterfaces) -> LANGuard {
        LANGuard(provider: { interfaces })
    }

    // MARK: 回环

    func testLoopbackAllowed() {
        let guarder = helper(LocalInterfaces())
        XCTAssertTrue(guarder.isAllowed("127.0.0.1:52344"))
        XCTAssertTrue(guarder.isAllowed("127.0.0.1"))
        XCTAssertTrue(guarder.isAllowed("::1"))
    }

    // MARK: IPv4 同网段

    func testSameSubnetAllowed() {
        let ifs = LocalInterfaces(v4: [subnet("192.168.1.10", 24)])
        let guarder = helper(ifs)
        XCTAssertTrue(guarder.isAllowed("192.168.1.55:5000"))
        XCTAssertFalse(guarder.isAllowed("192.168.2.55:5000"), "不同 /24 网段应拒绝")
    }

    func testSubnetMaskRespected() {
        let ifs = LocalInterfaces(v4: [subnet("192.168.1.10", 25)])
        let guarder = helper(ifs)
        XCTAssertTrue(guarder.isAllowed("192.168.1.100"))
        XCTAssertFalse(guarder.isAllowed("192.168.1.200"), "/25 上半段应拒绝")
    }

    func testPublicIPAlwaysRejected() {
        let ifs = LocalInterfaces(v4: [subnet("8.8.8.8", 24)])
        let guarder = helper(ifs)
        XCTAssertFalse(guarder.isAllowed("114.114.114.114:80"), "公网地址必须拒绝")
        XCTAssertFalse(guarder.isAllowed("8.8.8.8:53"), "即便与接口同网段，公网也拒绝")
    }

    func testPrivateButDifferentSubnetRejected() {
        let ifs = LocalInterfaces(v4: [subnet("192.168.1.10", 24)])
        let guarder = helper(ifs)
        XCTAssertFalse(guarder.isAllowed("10.0.0.5"))
        XCTAssertFalse(guarder.isAllowed("172.16.5.5"))
    }

    // MARK: IPv6

    func testIPv6LinkLocalAllowed() {
        let guarder = helper(LocalInterfaces())
        XCTAssertTrue(guarder.isAllowed("fe80::1234:5678"))
        XCTAssertTrue(guarder.isAllowed("[fe80::1%en0]:5000"))
    }

    func testIPv6GlobalSamePrefix64Allowed() {
        let local = AddressUtils.parseIPv6("2408:8207:1111:2222:aaaa:bbbb:cccc:dddd")!
        let ifs = LocalInterfaces(v6Prefixes: [[local]])
        let guarder = helper(ifs)
        XCTAssertTrue(guarder.isAllowed("2408:8207:1111:2222:1:2:3:4"), "同 /64 允许")
        XCTAssertFalse(guarder.isAllowed("2408:8207:1111:3333:1:2:3:4"), "不同 /64 拒绝")
    }

    // MARK: 坏输入

    func testGarbageRejected() {
        let guarder = helper(LocalInterfaces())
        XCTAssertFalse(guarder.isAllowed(""))
        XCTAssertFalse(guarder.isAllowed("unknown"))
        XCTAssertFalse(guarder.isAllowed("not-an-address"))
    }

    // MARK: 工具函数

    func testHostOnlyParsing() {
        XCTAssertEqual(AddressUtils.hostOnly("192.168.1.5:8080"), "192.168.1.5")
        XCTAssertEqual(AddressUtils.hostOnly("[fe80::1%en0]:5000"), "fe80::1%en0")
        XCTAssertEqual(AddressUtils.hostOnly("fe80::1%en0"), "fe80::1")
        XCTAssertEqual(AddressUtils.hostOnly("fe80::1"), "fe80::1")
        XCTAssertEqual(AddressUtils.hostOnly("127.0.0.1"), "127.0.0.1")
    }

    func testIPv4ParseFormat() {
        let ip = AddressUtils.parseIPv4("192.168.1.5")
        XCTAssertEqual(ip, 0xC0A80105)
        XCTAssertEqual(AddressUtils.formatIPv4(0xC0A80105), "192.168.1.5")
        XCTAssertNil(AddressUtils.parseIPv4("999.1.1.1"))
        XCTAssertNil(AddressUtils.parseIPv4("1.2.3"))
    }

    func testSubnetContainment() {
        let subnet = IPv4Subnet(address: "192.168.1.10", prefix: 24)!
        XCTAssertTrue(subnet.contains(AddressUtils.parseIPv4("192.168.1.99")!))
        XCTAssertFalse(subnet.contains(AddressUtils.parseIPv4("192.168.9.99")!))
        XCTAssertEqual(IPv4Subnet.mask(0), 0)
        XCTAssertEqual(IPv4Subnet.mask(32), ~UInt32(0))
        XCTAssertEqual(IPv4Subnet.mask(8), 0xFF00_0000)
    }

    func testIsPrivate() {
        XCTAssertTrue(LANGuard.isPrivateIPv4(AddressUtils.parseIPv4("10.1.2.3")!))
        XCTAssertTrue(LANGuard.isPrivateIPv4(AddressUtils.parseIPv4("172.16.0.1")!))
        XCTAssertTrue(LANGuard.isPrivateIPv4(AddressUtils.parseIPv4("172.31.255.255")!))
        XCTAssertTrue(LANGuard.isPrivateIPv4(AddressUtils.parseIPv4("192.168.0.0")!))
        XCTAssertFalse(LANGuard.isPrivateIPv4(AddressUtils.parseIPv4("172.32.0.1")!))
        XCTAssertFalse(LANGuard.isPrivateIPv4(AddressUtils.parseIPv4("8.8.8.8")!))
    }

    func testSystemInterfacesReturnsSomething() {
        // 本机至少应有回环/接口（不假设具体值，只验证不崩溃且类型正确）
        let ifs = LANGuard.systemInterfaces()
        _ = ifs.v4.count
        _ = ifs.v6Prefixes.count
    }
}
