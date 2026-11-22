import XCTest
import CoreImage
@testable import MacScreenCore

final class PairingTests: XCTestCase {
    func testTokenFormat() {
        let token = TokenGenerator.newToken()
        XCTAssertEqual(token.count, 32)
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit })
        XCTAssertNotEqual(TokenGenerator.newToken(), token, "随机令牌不应重复")
    }

    func testInMemoryTokenStore() {
        let store = InMemoryTokenStore(token: "abc")
        XCTAssertEqual(store.token, "abc")
    }

    func testUserDefaultsTokenStorePersists() {
        let suite = UserDefaults(suiteName: "pairing.tests")!
        suite.removePersistentDomain(forName: "pairing.tests")
        let first = UserDefaultsTokenStore(defaults: suite)
        let t1 = first.token
        let second = UserDefaultsTokenStore(defaults: suite)
        XCTAssertEqual(second.token, t1, "同一存储应返回相同令牌")
    }

    func testQRGenerationAndDecoding() throws {
        let content = "macscreen://connect?host=192.168.1.5&port=9700&token=abcd1234"
        let png = try XCTUnwrap(QRCodeService.qrPNGData(content: content, sizePx: 300))
        XCTAssertGreaterThan(png.count, 500, "PNG 应有实际内容")
        XCTAssertEqual(png.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]), "应为 PNG 魔数")

        // 用 CIDetector 回读二维码内容，验证可解码
        let image = try XCTUnwrap(NSImage(data: png))
        var rect = CGRect()
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [:]))
        let features = detector.features(in: CIImage(cgImage: cg))
        XCTAssertEqual(features.count, 1)
        let qr = try XCTUnwrap(features.first as? CIQRCodeFeature)
        XCTAssertEqual(qr.messageString, content)
    }

    func testQRContentEncoding() {
        let info = ConnectionInfo(host: "192.168.1.5", port: 9700,
                                  token: "t0k&en", name: "张三的 Mac")
        let content = info.qrContent
        XCTAssertTrue(content.hasPrefix("macscreen://connect?"))
        XCTAssertTrue(content.contains("host=192.168.1.5"))
        XCTAssertTrue(content.contains("port=9700"))
        XCTAssertTrue(content.contains("t0k%26en"), "& 应被转义")
        XCTAssertFalse(content.contains("张三的"), "中文应被百分号编码")
    }

    func testPairingServiceConnectionInfo() {
        let service = PairingService(store: InMemoryTokenStore(token: "tok"), serverName: "Mac")
        let info = service.connectionInfo(host: "10.0.0.2", port: 1234)
        XCTAssertEqual(info.token, "tok")
        XCTAssertEqual(info.host, "10.0.0.2")
        XCTAssertEqual(info.port, 1234)
    }
}
