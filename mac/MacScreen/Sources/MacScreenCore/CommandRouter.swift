import Foundation
import CoreGraphics

/// 命令路由：把已鉴权会话的请求分发给各服务，产出应答事件。
/// 全部服务均为注入（可 Mock），本类可完整单元测试。
public final class CommandRouter {
    public let windowService: WindowService
    public let injector: InputInjector
    public let capture: CaptureController
    public let settings: SettingsStore
    public let serverName: String
    public let startedAt = Date()
    /// mock 输入模式下把动作回带在 ok.echo 里，供端到端断言。
    public let echoInputs: Bool
    /// 提供当前连接数（由上层注入注册表读取闭包）。
    public var clientsProvider: (() -> Int)?

    public init(windowService: WindowService,
                injector: InputInjector,
                capture: CaptureController,
                settings: SettingsStore,
                serverName: String,
                echoInputs: Bool = false) {
        self.windowService = windowService
        self.injector = injector
        self.capture = capture
        self.settings = settings
        self.serverName = serverName
        self.echoInputs = echoInputs
    }

    public var mockMode: Bool { echoInputs }

    /// 归一化坐标 (0~1) → 屏幕逻辑坐标。
    public func screenPoint(nx: Double, ny: Double) -> (x: Double, y: Double) {
        let size = windowService.mainScreenSize()
        let x = min(max(nx, 0), 1) * size.width
        let y = min(max(ny, 0), 1) * size.height
        return (x.rounded(toPlaces: 1), y.rounded(toPlaces: 1))
    }

    public func handle(_ req: Request, session: Session) -> [ServerEvent] {
        switch req.op {
        case "ping":
            return [.pong(id: req.id)]

        case "get-status":
            return [statusEvent(id: req.id)]

        case "subscribe":
            let want = req.video ?? true
            session.wantsVideo = want
            Log.i("\(session.deviceName) 视频订阅：\(want)")
            var events: [ServerEvent] = [ServerEvent.screenInfo(capture.currentInfo(), id: req.id)]
            if want {
                events.append(ServerEvent.captureState(enabled: capture.isRunning,
                                                       permission: capture.permissionGranted,
                                                       mock: capture.usingMock, id: req.id))
            }
            return events

        case "set-capture":
            let state = capture.update(enabled: req.enabled, fps: req.fps,
                                       quality: req.quality, maxWidth: req.maxWidth)
            return [state]

        case "list-windows":
            let list = windowService.listWindows()
            return [.windows(list, id: req.id)]

        case "activate-window":
            guard let windowId = req.windowId else {
                return [.error(code: "bad-request", message: "缺少 windowId", id: req.id)]
            }
            let ok = windowService.activate(windowId: windowId)
            if ok {
                return [.ok(action: "activate-window", echo: ["windowId": windowId], id: req.id)]
            }
            return [.error(code: "window-not-found", message: "找不到窗口 \(windowId)", id: req.id)]

        case "mouse":
            guard let actionName = req.action, let action = MouseAction(rawValue: actionName),
                  let nx = req.x, let ny = req.y else {
                return [.error(code: "bad-request", message: "mouse 需要 action/x/y", id: req.id)]
            }
            let point = screenPoint(nx: nx, ny: ny)
            let ok = injector.mouse(action: action, x: point.x, y: point.y)
            return ok
                ? [.ok(action: "mouse", echo: echoInputs
                       ? ["raw": actionName, "nx": nx, "ny": ny,
                          "x": point.x, "y": point.y] : ["x": point.x, "y": point.y], id: req.id)]
                : [.error(code: "inject-failed", message: "鼠标注入失败", id: req.id)]

        case "scroll":
            let dx = req.dx ?? 0
            let dy = req.dy ?? 0
            var px: Double?, py: Double?
            if let nx = req.x, let ny = req.y {
                let p = screenPoint(nx: nx, ny: ny)
                px = p.x; py = p.y
            }
            let ok = injector.scroll(dx: dx, dy: dy, x: px, y: py)
            return ok
                ? [.ok(action: "scroll", echo: echoInputs ? ["dx": dx, "dy": dy] : [:], id: req.id)]
                : [.error(code: "inject-failed", message: "滚动注入失败", id: req.id)]

        case "type-text":
            guard let text = req.text else {
                return [.error(code: "bad-request", message: "type-text 需要 text", id: req.id)]
            }
            let ok = injector.typeText(text)
            if ok, req.submit == true {
                _ = injector.pressKey("return", modifiers: [])
            }
            return ok
                ? [.ok(action: "type-text", echo: echoInputs
                       ? ["text": text, "submit": req.submit ?? false] : [:], id: req.id)]
                : [.error(code: "inject-failed", message: "文本注入失败", id: req.id)]

        case "press-key":
            guard let key = req.key else {
                return [.error(code: "bad-request", message: "press-key 需要 key", id: req.id)]
            }
            // 协议层校验按键名（与注入器实现无关）
            guard KeyMap.keyCode(key) != nil else {
                return [.error(code: "bad-key", message: "未知按键 \(key)", id: req.id)]
            }
            let mods = req.modifiers ?? []
            let ok = injector.pressKey(key, modifiers: mods)
            return ok
                ? [.ok(action: "press-key", echo: echoInputs
                       ? ["key": key, "modifiers": mods] : [:], id: req.id)]
                : [.error(code: "bad-key", message: "未知按键 \(key)", id: req.id)]

        default:
            return [.error(code: "unsupported-op", message: "未知操作 \(req.op)", id: req.id)]
        }
    }

    public func statusEvent(id: Any?) -> ServerEvent {
        let uptime = Int(Date().timeIntervalSince(startedAt))
        let fields: [String: Any] = [
            "version": "1.0",
            "serverName": serverName,
            "port": Int(settings.port),
            "clients": clientsProvider?() ?? 0,
            "uptimeSec": uptime,
            "capture": [
                "enabled": capture.isRunning,
                "permission": capture.permissionGranted,
                "mock": capture.usingMock,
            ] as [String: Any],
            "mockInput": echoInputs,
        ]
        return .status(fields, id: id)
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
