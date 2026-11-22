import XCTest
@testable import MacScreenCore

final class CommandRouterTests: XCTestCase {
    var settings: InMemorySettingsStore!
    var windows: MockWindowService!
    var injector: MockInputInjector!
    var capture: CaptureController!
    var router: CommandRouter!

    override func setUp() {
        super.setUp()
        settings = InMemorySettingsStore()
        settings.captureEnabled = false // 测试按需启动
        windows = MockWindowService()
        injector = MockInputInjector()
        var config = LaunchConfig()
        capture = CaptureController(settings: settings, config: config)
        router = CommandRouter(windowService: windows, injector: injector, capture: capture,
                               settings: settings, serverName: "TestMac", echoInputs: true)
    }

    private func req(_ op: String, _ extra: [String: Any] = [:], id: Int = 1) -> Request {
        var dict: [String: Any] = ["op": op, "id": id]
        for (k, v) in extra { dict[k] = v }
        return Request(dict: dict)!
    }

    // MARK: 基础

    func testPing() {
        let events = router.handle(req("ping"), session: makeStubSession())
        XCTAssertEqual(events.first?.dict["op"] as? String, "pong")
        XCTAssertEqual((events.first?.dict["id"] as? NSNumber)?.intValue, 1, "id 应原样带回")
    }

    func testUnknownOp() {
        let events = router.handle(req("fly-to-moon"), session: makeStubSession())
        XCTAssertEqual(events.first?.dict["code"] as? String, "unsupported-op")
    }

    func testStatusEvent() {
        let events = router.handle(req("get-status"), session: makeStubSession())
        let dict = events[0].dict
        XCTAssertEqual(dict["op"] as? String, "status")
        XCTAssertEqual(dict["port"] as? Int, 9700)
        XCTAssertNotNil(dict["capture"])
    }

    // MARK: 鼠标

    func testMouseClickMapping() {
        windows.mainScreen = (1440, 900)
        let events = router.handle(req("mouse", ["action": "click", "x": 0.5, "y": 0.25]),
                                    session: makeStubSession())
        XCTAssertEqual(events.first?.dict["op"] as? String, "ok")
        XCTAssertEqual(injector.actions.count, 1)
        let action = injector.actions[0]
        XCTAssertEqual(action.kind, "mouse")
        XCTAssertEqual(action.payload["action"], "click")
        XCTAssertEqual(Double(action.payload["x"] ?? ""), 720.0)
        XCTAssertEqual(Double(action.payload["y"] ?? ""), 225.0)
        let echo = events[0].dict["echo"] as? [String: Any]
        XCTAssertEqual((echo?["x"] as? NSNumber)?.doubleValue, 720.0)
    }

    func testMouseClampsOutOfRange() {
        windows.mainScreen = (1000, 500)
        _ = router.handle(req("mouse", ["action": "move", "x": 5.0, "y": -3.0]), session: makeStubSession())
        XCTAssertEqual(Double(injector.actions[0].payload["x"] ?? ""), 1000.0, "越界应钳制")
        XCTAssertEqual(Double(injector.actions[0].payload["y"] ?? ""), 0.0)
    }

    func testMouseBadAction() {
        let events = router.handle(req("mouse", ["action": "teleport", "x": 0.1, "y": 0.1]),
                                    session: makeStubSession())
        XCTAssertEqual(events.first?.dict["code"] as? String, "bad-request")
    }

    func testAllMouseActionsMapThrough() {
        for name in ["click", "double", "right", "down", "up", "move", "drag"] {
            injector.reset()
            let events = router.handle(req("mouse", ["action": name, "x": 0, "y": 0]),
                                        session: makeStubSession())
            XCTAssertEqual(events.first?.dict["op"] as? String, "ok", name)
            XCTAssertEqual(injector.actions.count, 1, name)
        }
    }

    // MARK: 文本与按键

    func testTypeTextWithSubmit() {
        let events = router.handle(req("type-text", ["text": "你好世界", "submit": true]),
                                    session: makeStubSession())
        XCTAssertEqual(events.first?.dict["op"] as? String, "ok")
        XCTAssertEqual(injector.actions.count, 2, "文本 + 回车")
        XCTAssertEqual(injector.actions[0].payload["text"], "你好世界")
        XCTAssertEqual(injector.actions[1].payload["key"], "return")
        let echo = events[0].dict["echo"] as? [String: Any]
        XCTAssertEqual(echo?["text"] as? String, "你好世界")
        XCTAssertEqual(echo?["submit"] as? Bool, true)
    }

    func testTypeTextWithoutSubmit() {
        _ = router.handle(req("type-text", ["text": "abc"]), session: makeStubSession())
        XCTAssertEqual(injector.actions.count, 1, "不带 submit 不应回车")
    }

    func testTypeTextMissing() {
        let events = router.handle(req("type-text"), session: makeStubSession())
        XCTAssertEqual(events.first?.dict["code"] as? String, "bad-request")
    }

    func testPressKey() {
        let events = router.handle(req("press-key", ["key": "tab", "modifiers": ["shift", "command"]]),
                                    session: makeStubSession())
        XCTAssertEqual(events.first?.dict["op"] as? String, "ok")
        XCTAssertEqual(injector.actions[0].payload["key"], "tab")
        XCTAssertEqual(injector.actions[0].payload["modifiers"], "shift+command")
    }

    func testPressUnknownKey() {
        let events = router.handle(req("press-key", ["key": "hyper"]), session: makeStubSession())
        XCTAssertEqual(events.first?.dict["code"] as? String, "bad-key")
    }

    func testScroll() {
        _ = router.handle(req("scroll", ["dx": 0, "dy": 3, "x": 0.5, "y": 0.5]), session: makeStubSession())
        XCTAssertEqual(injector.actions[0].kind, "scroll")
    }

    // MARK: 窗口

    func testListWindows() {
        let events = router.handle(req("list-windows"), session: makeStubSession())
        XCTAssertEqual(events.first?.dict["op"] as? String, "windows")
        let list = events.first?.dict["list"] as? [[String: Any]]
        XCTAssertEqual(list?.count, 2)
        XCTAssertEqual(list?.first?["appName"] as? String, "Terminal")
    }

    func testActivateWindow() {
        let events = router.handle(req("activate-window", ["windowId": 2]), session: makeStubSession())
        XCTAssertEqual(events.first?.dict["op"] as? String, "ok")
        XCTAssertEqual(windows.activated, [2])
    }

    func testActivateMissingWindow() {
        let events = router.handle(req("activate-window", ["windowId": 999]), session: makeStubSession())
        XCTAssertEqual(events.first?.dict["code"] as? String, "window-not-found")
    }

    func testActivateWindowMissingParam() {
        let events = router.handle(req("activate-window"), session: makeStubSession())
        XCTAssertEqual(events.first?.dict["code"] as? String, "bad-request")
    }

    // MARK: 捕获

    func testSubscribeSendsScreenInfo() {
        let events = router.handle(req("subscribe", ["video": true]), session: makeStubSession())
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].dict["op"] as? String, "screen-info")
        XCTAssertEqual(events[1].dict["op"] as? String, "capture-state")
    }

    func testUnsubscribeOnlyScreenInfo() {
        let events = router.handle(req("subscribe", ["video": false]), session: makeStubSession())
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].dict["op"] as? String, "screen-info")
    }

    func testSetCaptureUpdatesSettings() {
        settings.captureEnabled = true
        capture.startIfNeeded() // mock
        XCTAssertTrue(capture.isRunning)
        _ = router.handle(req("set-capture", ["fps": 30, "quality": 0.8, "maxWidth": 800]),
                          session: makeStubSession())
        XCTAssertEqual(settings.fps, 30)
        XCTAssertEqual(settings.quality, 0.8, accuracy: 0.0001)
        XCTAssertEqual(settings.maxWidth, 800)
        capture.stop()
    }

    func testSetCaptureDisables() {
        settings.captureEnabled = true
        capture.startIfNeeded()
        _ = router.handle(req("set-capture", ["enabled": false]), session: makeStubSession())
        XCTAssertFalse(settings.captureEnabled)
        XCTAssertFalse(capture.isRunning)
    }

    // MARK: 键位表

    func testKeyMap() {
        XCTAssertEqual(KeyMap.keyCode("return"), 36)
        XCTAssertEqual(KeyMap.keyCode("RETURN"), 36)
        XCTAssertEqual(KeyMap.keyCode("left"), 123)
        XCTAssertNil(KeyMap.keyCode("nope"))
        let flags = KeyMap.flags(["command", "shift"])
        XCTAssertTrue(flags.contains(.maskCommand))
        XCTAssertTrue(flags.contains(.maskShift))
        XCTAssertFalse(flags.contains(.maskAlternate))
    }

    // MARK: 辅助

    /// Session stub：Router 只用 wantsVideo，不需要真实会话。
    private func makeStubSession() -> Session {
        let conn = FakeConnection()
        let s = Session(connection: conn,
                        tokenStore: InMemoryTokenStore(),
                        lanGuard: LANGuard(provider: { LocalInterfaces() }),
                        router: router,
                        registry: SessionRegistry())
        return s
    }
}
