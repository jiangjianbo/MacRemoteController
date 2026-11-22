import XCTest
@testable import MacScreenCore

/// FakeConnection：测试用连接，记录发送数据，允许手动注入接收。
final class FakeConnection: Connection {
    var peerAddress: String = "127.0.0.1:12345"
    var onReceive: ((Data) -> Void)?
    var onReady: (() -> Void)?
    var onClose: ((String?) -> Void)?
    var sendBacklog: Int = 0
    private(set) var sent = Data()
    private(set) var closed = false

    func start() { onReady?() }
    func send(_ data: Data) { sent.append(data) }
    func close() {
        closed = true
        onClose?(nil)
    }
    /// 测试辅助：清空发送记录。
    func clearSent() { sent = Data() }

    /// 测试辅助：模拟服务端收到字节。
    func simulateInbound(_ data: Data) { onReceive?(data) }

    /// 解析已发送的 JSON 事件。
    func sentEvents() -> [[String: Any]] {
        var decoder = FrameDecoder()
        let frames = decoder.feed(sent)
        return frames.compactMap { frame in
            guard frame.kind == .json,
                  let obj = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] else { return nil }
            return obj
        }
    }

    func sentJpegFrames() -> Int {
        var decoder = FrameDecoder()
        return decoder.feed(sent).filter { $0.kind == .jpeg }.count
    }
}

/// 会话级测试：鉴权状态机、订阅、视频分发、错误路径。
final class SessionTests: XCTestCase {
    var settings: InMemorySettingsStore!
    var windows: MockWindowService!
    var injector: MockInputInjector!
    var capture: CaptureController!
    var router: CommandRouter!
    var registry: SessionRegistry!
    var tokenStore: InMemoryTokenStore!
    var lanGuard: LANGuard!

    override func setUp() {
        super.setUp()
        settings = InMemorySettingsStore()
        windows = MockWindowService()
        injector = MockInputInjector()
        var config = LaunchConfig()
        config.mockCapture = true
        capture = CaptureController(settings: settings, config: config)
        router = CommandRouter(windowService: windows, injector: injector, capture: capture,
                               settings: settings, serverName: "TestMac", echoInputs: true)
        registry = SessionRegistry()
        tokenStore = InMemoryTokenStore(token: "goodtoken")
        lanGuard = LANGuard(provider: { LocalInterfaces(
            v4: [IPv4Subnet(address: "192.168.1.10", prefix: 24)!],
            v6Prefixes: []) })
    }

    func makeSession(peer: String = "192.168.1.55:5000") -> (Session, FakeConnection) {
        let conn = FakeConnection()
        conn.peerAddress = peer
        let session = Session(connection: conn, tokenStore: tokenStore,
                              lanGuard: lanGuard, router: router, registry: registry)
        registry.add(session)
        session.start()
        return (session, conn)
    }

    private func runOnSessionQueue(_ session: Session, _ body: @escaping () -> Void) {
        let exp = expectation(description: "queue")
        session.queue.async {
            body()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
    }

    func testHelloSuccessFlow() throws {
        let (session, conn) = makeSession()
        conn.simulateInbound(ProtocolFrame.json(["op": "hello", "token": "goodtoken",
                                                 "deviceName": "测试手机"])!.encoded())
        runOnSessionQueue(session) {}

        let events = conn.sentEvents()
        let ack = events.first { $0["op"] as? String == "hello-ack" }
        XCTAssertNotNil(ack, "应收到 hello-ack")
        XCTAssertEqual(ack?["ok"] as? Bool, true)
        XCTAssertEqual(ack?["serverName"] as? String, "TestMac")
        XCTAssertNotNil(events.first { $0["op"] as? String == "screen-info" })
        XCTAssertNotNil(events.first { $0["op"] as? String == "capture-state" })
        conn.close()
    }

    func testWrongTokenRejectedAndClosed() throws {
        let (session, conn) = makeSession()
        conn.simulateInbound(ProtocolFrame.json(["op": "hello", "token": "WRONG"])!.encoded())
        runOnSessionQueue(session) {}

        let events = conn.sentEvents()
        let error = events.first { $0["op"] as? String == "error" }
        XCTAssertNotNil(error, "应收到 error")
        XCTAssertEqual(error?["code"] as? String, "auth")
        XCTAssertNil(events.first { $0["op"] as? String == "hello-ack" })
        // close 延迟 0.3s，等一拍
        let exp = expectation(description: "closed")
        session.queue.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertTrue(conn.closed, "错误 token 必须断开")
    }

    func testNonLANPeerRejected() throws {
        let (session, conn) = makeSession(peer: "88.88.88.88:1234")
        conn.simulateInbound(ProtocolFrame.json(["op": "hello", "token": "goodtoken"])!.encoded())
        runOnSessionQueue(session) {}

        let events = conn.sentEvents()
        XCTAssertEqual(events.first { $0["op"] as? String == "error" }?["code"] as? String, "forbidden")
    }

    func testRequestBeforeHelloRejected() throws {
        let (session, conn) = makeSession()
        conn.simulateInbound(ProtocolFrame.json(["op": "ping"])!.encoded())
        runOnSessionQueue(session) {}
        let events = conn.sentEvents()
        XCTAssertEqual(events.first { $0["op"] as? String == "error" }?["code"] as? String, "auth")
        conn.close()
    }

    func testVideoSubscriptionAndBroadcast() throws {
        let (session, conn) = makeSession()
        conn.simulateInbound(ProtocolFrame.json(["op": "hello", "token": "goodtoken"])!.encoded())
        runOnSessionQueue(session) {}
        conn.clearSent()

        // 启动 mock 捕获并广播
        capture.onFrame = { [weak self] jpeg in self?.registry.broadcastVideo(jpeg) }
        capture.startIfNeeded()
        XCTAssertTrue(capture.isRunning)

        // 未订阅 → 不收帧
        runOnSessionQueue(session) {}
        XCTAssertEqual(conn.sentJpegFrames(), 0, "未订阅不应收到帧")

        // 订阅
        conn.simulateInbound(ProtocolFrame.json(["op": "subscribe", "video": true])!.encoded())
        runOnSessionQueue(session) {}

        let gotFrames = expectation(description: "frames")
        session.queue.asyncAfter(deadline: .now() + 0.5) { gotFrames.fulfill() }
        wait(for: [gotFrames], timeout: 3)
        XCTAssertGreaterThanOrEqual(conn.sentJpegFrames(), 1, "订阅后应收到视频帧")

        capture.stop()
        conn.close()
    }

    func testUnsubscribedSessionGetsNoFramesAfterUnsubscribe() throws {
        let (session, conn) = makeSession()
        conn.simulateInbound(ProtocolFrame.json(["op": "hello", "token": "goodtoken"])!.encoded())
        conn.simulateInbound(ProtocolFrame.json(["op": "subscribe", "video": true])!.encoded())
        conn.simulateInbound(ProtocolFrame.json(["op": "subscribe", "video": false])!.encoded())
        runOnSessionQueue(session) {}
        XCTAssertFalse(session.wantsVideo)
        capture.onFrame = { [weak self] jpeg in self?.registry.broadcastVideo(jpeg) }
        capture.startIfNeeded()
        runOnSessionQueue(session) {}
        XCTAssertEqual(conn.sentJpegFrames(), 0)
        capture.stop()
        conn.close()
    }

    func testRegistryRemovesClosedSessions() throws {
        let (session, conn) = makeSession()
        runOnSessionQueue(session) { _ = self.registry.count() }
        let countBefore = self.registry.count()
        XCTAssertGreaterThanOrEqual(countBefore, 1)
        conn.close()
        // 等待关闭处理
        let exp = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(registry.count(), 0, "关闭后会话应从注册表移除")
    }
}
