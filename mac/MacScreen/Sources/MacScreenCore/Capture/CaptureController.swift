import Foundation
import CoreGraphics

/// 捕获控制器：管理 FrameSource 生命周期、参数调整、帧广播、权限降级。
public final class CaptureController {
    /// 捕获状态变化时回调（广播 capture-state 事件）。
    public var onStateChange: ((ServerEvent) -> Void)?
    /// 每帧回调（广播视频）。
    public var onFrame: ((Data) -> Void)?

    public private(set) var isRunning = false
    public private(set) var usingMock = false
    public private(set) var lastError: String?

    private let settings: SettingsStore
    private let config: LaunchConfig
    private var source: FrameSource?
    private var hasRequestedPermission = false

    public init(settings: SettingsStore, config: LaunchConfig) {
        self.settings = settings
        self.config = config
    }

    /// 当前屏幕信息（逻辑尺寸来自真实主屏；像素尺寸来自当前源）。
    public func currentInfo() -> ScreenInfo {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let pixel = source?.info
        return ScreenInfo(
            widthPts: Double(bounds.width), heightPts: Double(bounds.height),
            pixelWidth: pixel?.pixelWidth ?? Int(bounds.width),
            pixelHeight: pixel?.pixelHeight ?? Int(bounds.height),
            fps: settings.fps, quality: settings.quality,
            maxWidth: settings.maxWidth, mock: usingMock)
    }

    public var permissionGranted: Bool {
        CGSnapshotFrameSource.hasScreenRecordingPermission()
    }

    /// 启动捕获（若设置允许）。权限不足时按配置降级为 Mock。
    public func startIfNeeded() {
        guard !isRunning, settings.captureEnabled else { return }
        do {
            source = try makeSource()
            source?.onFrame = { [weak self] jpeg in self?.onFrame?(jpeg) }
            try source?.start()
            isRunning = true
            lastError = nil
            emitState()
            Log.i("捕获已启动：\(usingMock ? "Mock" : "真实屏幕") fps=\(settings.fps)")
        } catch {
            source = nil
            isRunning = false
            lastError = String(describing: error)
            Log.e("捕获启动失败：\(error)")
            emitState()
        }
    }

    public func stop() {
        source?.stop()
        source = nil
        if isRunning {
            isRunning = false
            emitState()
        }
    }

    /// 手机端 set-capture：调整参数/开关。返回需要下发的 capture-state 事件。
    @discardableResult
    public func update(enabled: Bool?, fps: Int?, quality: Double?, maxWidth: Int?) -> ServerEvent {
        if let enabled = enabled { settings.captureEnabled = enabled }
        if let fps = fps { settings.fps = min(60, max(1, fps)) }
        if let quality = quality { settings.quality = min(1.0, max(0.1, quality)) }
        if let maxWidth = maxWidth { settings.maxWidth = min(3840, max(320, maxWidth)) }

        let shouldRun = settings.captureEnabled
        if shouldRun && !isRunning {
            startIfNeeded()
        } else if !shouldRun && isRunning {
            stop()
        } else if shouldRun && isRunning {
            // 参数变化：重启源
            restart()
        }
        return ServerEvent.captureState(enabled: isRunning, permission: permissionGranted,
                                        mock: usingMock, id: nil)
    }

    private func restart() {
        stop()
        guard settings.captureEnabled else { return }
        startIfNeeded()
    }

    /// 按配置选择帧源：强制 Mock / 真实 / 无权限降级。
    private func makeSource() throws -> FrameSource {
        if config.mockCapture {
            usingMock = true
            return MockFrameSource(fps: settings.fps)
        }
        if CGSnapshotFrameSource.hasScreenRecordingPermission() {
            usingMock = false
            return CGSnapshotFrameSource(fps: settings.fps, quality: settings.quality,
                                         maxWidth: settings.maxWidth)
        }
        guard config.mockFallbackIfDenied, settings.mockFallback else {
            throw CaptureError.screenRecordingPermissionDenied
        }
        let exePath = CommandLine.arguments.first.map {
            ($0 as NSString).standardizingPath
        } ?? "MacScreenAgent"
        Log.i("""
              未授予屏幕录制权限，降级为 Mock 视频源。启用真实画面：
              1. 系统设置 > 隐私与安全性 > 屏幕录制：
                 - 在终端里启动本程序时，权限归属终端应用本身，请勾选你的终端（Terminal/iTerm 等）；
                 - 用 Finder 双击或 launchd 方式启动时，添加并勾选本程序：\(exePath)
              2. 勾选/添加后必须完全退出并重新启动本程序才会生效。
              """)
        if !config.daemon && !hasRequestedPermission {
            hasRequestedPermission = true
            // 系统内置能力：拉起屏幕录制授权提示/偏好面板（UI 模式才弹，daemon 静默）
            _ = CGRequestScreenCaptureAccess()
        }
        usingMock = true
        return MockFrameSource(fps: settings.fps)
    }

    private func emitState() {
        onStateChange?(ServerEvent.captureState(enabled: isRunning, permission: permissionGranted,
                                                mock: usingMock, id: nil))
    }
}
