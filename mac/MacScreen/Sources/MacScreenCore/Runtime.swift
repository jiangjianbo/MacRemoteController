import Foundation
import CoreGraphics

/// 启动配置（命令行解析，纯逻辑可测）。
public struct LaunchConfig {
    public var daemon = false
    public var portOverride: UInt16? = nil
    public var mockCapture = false
    public var mockInput = false
    public var mockFallbackIfDenied = true
    public var noBonjour = false
    public var noFileShare = false
    public var infoFile: String? = nil
    public var logFile: String? = nil

    public init() {}

    /// 解析命令行参数。支持：--daemon --port N --mock-capture --mock-input
    /// --no-mock-fallback --no-bonjour --no-fileshare --info-file PATH --log-file PATH --help
    public static func parse(_ args: [String]) -> LaunchConfig {
        var config = LaunchConfig()
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--daemon": config.daemon = true
            case "--mock-capture": config.mockCapture = true
            case "--mock-input": config.mockInput = true
            case "--no-mock-fallback": config.mockFallbackIfDenied = false
            case "--no-bonjour": config.noBonjour = true
            case "--no-fileshare": config.noFileShare = true
            case "--port":
                if let value = iterator.next(), let port = UInt16(value) { config.portOverride = port }
            case "--info-file":
                config.infoFile = iterator.next()
            case "--log-file":
                config.logFile = iterator.next()
            case "--help", "-h":
                print("""
                MacScreenAgent 用法:
                  --daemon            后台模式（无 UI，配合 launchd/脚本）
                  --port N            覆盖监听端口
                  --mock-capture      使用 Mock 视频源（测试/无权限）
                  --mock-input        使用 Mock 输入注入（记录动作并在应答中回带 echo）
                  --no-mock-fallback  无权限时不降级 Mock
                  --no-bonjour        不广播 Bonjour
                  --no-fileshare      关闭手机扫码下载（HTTP 文件分享）服务
                  --info-file PATH    启动后写连接信息 JSON
                  --log-file PATH     日志文件
                """)
                exit(0)
            default:
                break
            }
        }
        return config
    }
}

/// 运行时装配与生命周期。
public final class AgentRuntime {
    public let config: LaunchConfig
    public let settings: SettingsStore
    public let tokenStore: TokenStore
    public let registry: SessionRegistry
    public let lanGuard: LANGuard
    public let windowService: WindowService
    public let injector: InputInjector
    public let capture: CaptureController
    public let router: CommandRouter
    public let server: AgentServer
    /// 手机扫码下载服务（HTTP，端口 = 主端口 + 1）；--no-fileshare 时为 nil。
    public let fileShare: FileShareServer?
    public let loginItem: LoginItemManager

    public init(config: LaunchConfig = LaunchConfig(),
                settings: SettingsStore = UserDefaultsSettingsStore(),
                tokenStore: TokenStore = UserDefaultsTokenStore()) {
        self.config = config
        self.settings = settings
        self.tokenStore = tokenStore
        if let port = config.portOverride { settings.port = port }

        self.registry = SessionRegistry()
        self.lanGuard = LANGuard()
        self.windowService = CGWindowService()
        self.injector = config.mockInput ? MockInputInjector() : CGEventInjector()
        self.capture = CaptureController(settings: settings, config: config)
        self.router = CommandRouter(windowService: windowService,
                                    injector: injector,
                                    capture: capture,
                                    settings: settings,
                                    serverName: settings.serverName,
                                    echoInputs: config.mockInput)
        self.server = AgentServer(port: settings.port,
                                  serverName: settings.serverName,
                                  lanGuard: lanGuard,
                                  tokenStore: tokenStore,
                                  router: router,
                                  registry: registry,
                                  enableBonjour: !config.noBonjour)
        if config.noFileShare {
            self.fileShare = nil
        } else {
            // 主端口 +1；主端口已是 65535 时退而用 -1
            let sharePort: UInt16 = settings.port == UInt16.max ? settings.port - 1 : settings.port + 1
            self.fileShare = FileShareServer(port: sharePort, lanGuard: lanGuard)
        }
        self.loginItem = LoginItemManager(executablePath: Bundle.main.executableURL?.path)
        router.clientsProvider = { [weak registry] in registry?.count() ?? 0 }
        capture.onStateChange = { [weak registry] event in registry?.broadcastEvent(event) }
        capture.onFrame = { [weak registry] jpeg in registry?.broadcastVideo(jpeg) }
    }

    public func start() {
        do {
            try server.start()
        } catch {
            Log.e("服务器启动失败：\(error)")
            exit(2)
        }
        if settings.captureEnabled {
            capture.startIfNeeded()
        }
        if let fs = fileShare {
            // 默认分享构建产物 APK（找不到则留空，待菜单栏手动选择文件）
            if fs.currentFile == nil,
               let url = FileShareServer.resolveDefaultShareFile(executablePath: Bundle.main.executableURL?.path),
               fs.setFile(url) != nil {
                Log.i("文件分享默认：\(url.lastPathComponent)")
            }
            // 辅助服务：失败不阻断主服务
            do {
                try fs.start()
            } catch {
                Log.e("文件分享服务启动失败（不影响投屏）：\(error)")
            }
        }
        writeInfoFile()
        Log.i("MacScreen Agent 已启动（pid=\(ProcessInfo.processInfo.processIdentifier)，"
            + "port=\(settings.port)，mockCapture=\(config.mockCapture)，mockInput=\(config.mockInput)）")
    }

    // MARK: - 文件分享辅助（菜单栏用）

    /// 设置分享文件。成功返回大小，失败返回 nil。
    @discardableResult
    public func setShareFile(_ url: URL) -> UInt64? {
        guard let fs = fileShare else { return nil }
        return fs.setFile(url)
    }

    /// 解析并设置默认分享产物（dist APK / Android 构建输出）。找不到返回 nil。
    @discardableResult
    public func resolveAndSetDefaultShareFile() -> URL? {
        guard let fs = fileShare, fs.currentFile == nil,
              let url = FileShareServer.resolveDefaultShareFile(executablePath: Bundle.main.executableURL?.path),
              fs.setFile(url) != nil else { return nil }
        return url
    }

    /// 扫码内容（http://局域网IP:端口/file）；未分享文件或服务不可用时为 nil。
    public var shareURLString: String? {
        guard let fs = fileShare, fs.currentFile != nil else { return nil }
        let host = lanHosts.first ?? "127.0.0.1"
        return "http://\(host):\(fs.boundPort)\(FileShareServer.path)"
    }

    public func stop() {
        capture.stop()
        server.stop()
        fileShare?.stop()
    }

    /// 局域网 IP 列表。
    public var lanHosts: [String] {
        LANGuard.localIPv4Addresses()
    }

    /// 主机名。
    public var hostName: String {
        Host.current().localizedName ?? settings.serverName
    }

    /// 连接信息（选第一个非回环 IPv4；都无则用 127.0.0.1）。
    public func connectionInfo() -> ConnectionInfo {
        let host = lanHosts.first ?? "127.0.0.1"
        return ConnectionInfo(host: host, port: settings.port,
                              token: tokenStore.token, name: hostName)
    }

    /// 写连接信息 JSON（供脚本与 PhoneSimulator / 用户查看）。
    public func writeInfoFile() {
        guard let path = config.infoFile else { return }
        var info: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "port": Int(settings.port),
            "token": tokenStore.token,
            "name": hostName,
            "hosts": lanHosts,
            "mockCapture": config.mockCapture,
            "mockInput": config.mockInput,
        ]
        if let share = shareURLString {
            info["shareUrl"] = share
            info["shareFile"] = fileShare?.currentFile?.lastPathComponent
        }
        guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]) else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
