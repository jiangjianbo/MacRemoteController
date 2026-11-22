import XCTest
@testable import MacScreenCore

/// 记录命令的 Mock 进程执行器。
final class MockProcessRunner: ProcessRunner {
    var commands: [(launchPath: String, arguments: [String])] = []
    var nextExitCode: Int32 = 0

    func run(launchPath: String, arguments: [String]) -> Int32 {
        commands.append((launchPath, arguments))
        return nextExitCode
    }

    func ran(_ substring: String) -> Bool {
        commands.contains { $0.arguments.joined(separator: " ").contains(substring) }
    }
}

final class LoginItemTests: XCTestCase {
    var tempDir: String!
    var runner: MockProcessRunner!
    var manager: LoginItemManager!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "macscreen-loginitem-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        runner = MockProcessRunner()
        manager = LoginItemManager(label: "com.macscreen.test",
                                   plistPath: tempDir + "/com.macscreen.test.plist",
                                   executablePath: "/tmp/fake/MacScreenAgent",
                                   logFilePath: tempDir + "/agent.log",
                                   runner: runner)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    func testPlistXMLContent() {
        let xml = LoginItemManager.plistXML(label: "com.macscreen.agent",
                                            executablePath: "/usr/local/bin/agent",
                                            logFilePath: "/var/log/agent.log")
        XCTAssertTrue(xml.contains("<string>com.macscreen.agent</string>"))
        XCTAssertTrue(xml.contains("<string>/usr/local/bin/agent</string>"))
        XCTAssertTrue(xml.contains("<string>--daemon</string>"))
        XCTAssertTrue(xml.contains("<key>RunAtLoad</key>"))
        XCTAssertTrue(xml.contains("<string>/var/log/agent.log</string>"))
    }

    func testEnableWritesPlistAndLoads() throws {
        try manager.enable()
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.plistPath))
        let content = try String(contentsOfFile: manager.plistPath, encoding: .utf8)
        XCTAssertTrue(content.contains("com.macscreen.test"))
        XCTAssertTrue(content.contains("/tmp/fake/MacScreenAgent"))
        XCTAssertTrue(runner.ran("load \(manager.plistPath)"), "应执行 launchctl load")
    }

    func testIsEnabledRequiresPlistAndLoadedState() {
        XCTAssertFalse(manager.isEnabled(), "无 plist 应为 false")
        try? manager.enable()
        XCTAssertTrue(manager.isEnabled(), "plist 存在且 launchctl list 成功")
        runner.nextExitCode = 1
        XCTAssertFalse(manager.isEnabled(), "launchctl list 失败（未加载）应为 false")
    }

    func testDisableUnloadsAndRemoves() throws {
        try manager.enable()
        manager.disable()
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.plistPath))
        XCTAssertTrue(runner.ran("unload \(manager.plistPath)"))
    }

    func testEnableIsIdempotent() throws {
        try manager.enable()
        try manager.enable()
        let loads = runner.commands.filter { $0.arguments.first == "load" }.count
        XCTAssertEqual(loads, 2, "重复 enable 应先 unload 再 load（幂等）")
        XCTAssertTrue(runner.commands.contains { $0.arguments == ["unload", manager.plistPath] })
    }
}

final class LaunchConfigTests: XCTestCase {
    func testDefaults() {
        let config = LaunchConfig.parse([])
        XCTAssertFalse(config.daemon)
        XCTAssertNil(config.portOverride)
        XCTAssertFalse(config.mockCapture)
        XCTAssertTrue(config.mockFallbackIfDenied)
    }

    func testParseAllFlags() {
        let config = LaunchConfig.parse([
            "--daemon", "--port", "8080", "--mock-capture", "--mock-input",
            "--no-mock-fallback", "--no-bonjour",
            "--info-file", "/tmp/info.json", "--log-file", "/tmp/log.txt",
        ])
        XCTAssertTrue(config.daemon)
        XCTAssertEqual(config.portOverride, 8080)
        XCTAssertTrue(config.mockCapture)
        XCTAssertTrue(config.mockInput)
        XCTAssertFalse(config.mockFallbackIfDenied)
        XCTAssertTrue(config.noBonjour)
        XCTAssertEqual(config.infoFile, "/tmp/info.json")
        XCTAssertEqual(config.logFile, "/tmp/log.txt")
    }

    func testInvalidPortIgnored() {
        let config = LaunchConfig.parse(["--port", "notanumber"])
        XCTAssertNil(config.portOverride)
    }
}

final class SettingsStoreTests: XCTestCase {
    func testInMemoryDefaults() {
        let settings = InMemorySettingsStore()
        XCTAssertEqual(settings.port, 9700)
        XCTAssertEqual(settings.fps, 12)
    }

    func testUserDefaultsClamping() {
        let suite = UserDefaults(suiteName: "settings.tests")!
        suite.removePersistentDomain(forName: "settings.tests")
        let settings = UserDefaultsSettingsStore(defaults: suite)
        settings.fps = 999
        XCTAssertEqual(settings.fps, 60, "fps 上限 60")
        settings.fps = 0
        XCTAssertEqual(settings.fps, 1, "fps 下限 1")
        settings.quality = 5
        XCTAssertEqual(settings.quality, 1.0, accuracy: 0.0001)
        settings.port = 65535
        XCTAssertEqual(settings.port, 65535, "端口赋值")
    }
}
