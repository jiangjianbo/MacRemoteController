import Foundation
import CoreGraphics
import AppKit

/// 窗口服务：列出窗口 / 激活窗口（协议抽象，便于 Mock）。
public protocol WindowService: AnyObject {
    func listWindows() -> [WindowInfo]
    /// 激活指定窗口（把对应应用带到前台并尽量 AXRaise）。成功/找不到返回 false。
    func activate(windowId: Int) -> Bool
    /// 屏幕逻辑尺寸（pt），用于归一化坐标映射。
    func mainScreenSize() -> (width: Double, height: Double)
}

/// 真实实现：CGWindowListCopyWindowInfo（系统内置）+ NSRunningApplication / AXRaise。
public final class CGWindowService: WindowService {
    public init() {}

    public func listWindows() -> [WindowInfo] {
        // .optionAll 枚举全部 Space 的窗口：全屏应用独占独立 Space，用
        // .optionOnScreenOnly 会把它们整个漏掉（手机窗口列表看不到，必须手动
        // 切屏才能出现）；非当前 Space 的窗口由 onScreen 标记，激活时 AXRaise
        // /app.activate 会自动切过去。
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return Self.filterWindows(list, myPid: Int(ProcessInfo.processInfo.processIdentifier))
    }

    /// 过滤 CGWindowList 原始条目为可展示窗口（纯函数，供单元测试）。
    static func filterWindows(_ entries: [[String: Any]], myPid: Int) -> [WindowInfo] {
        var result: [WindowInfo] = []
        for entry in entries {
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue } // 只看普通窗口层
            let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? -1
            guard pid > 0, pid != myPid else { continue }
            guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue else { continue }
            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            // 窗口标题需要屏幕录制权限；无权限时退化为应用名
            let title = entry[kCGWindowName as String] as? String ?? owner
            guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any] else { continue }
            let x = (boundsDict["X"] as? NSNumber)?.doubleValue ?? 0
            let y = (boundsDict["Y"] as? NSNumber)?.doubleValue ?? 0
            let w = (boundsDict["Width"] as? NSNumber)?.doubleValue ?? 0
            let h = (boundsDict["Height"] as? NSNumber)?.doubleValue ?? 0
            guard w >= 60, h >= 40 else { continue } // 过滤小面板
            let onScreen = ((entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue) ?? true
            result.append(WindowInfo(id: id, title: title, appName: owner, pid: pid,
                                     x: x, y: y, w: w, h: h, onScreen: onScreen))
        }
        return result
    }

    public func activate(windowId: Int) -> Bool {
        guard let win = listWindows().first(where: { $0.id == windowId }) else { return false }
        let pid = pid_t(win.pid)
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        // AXRaise 尽力而为：按标题匹配窗口并 raise（失败不影响应用激活）
        if !win.title.isEmpty {
            DispatchQueue.global().async { [title = win.title] in
                Self.raiseWindow(ofApp: app, title: title)
            }
        }
        return Self.activateApp(app)
    }

    /// NSRunningApplication.activate 需在主线程调用；主线程外采用 fire-and-forget（激活为尽力而为）。
    static func activateApp(_ app: NSRunningApplication) -> Bool {
        let activate: () -> Void = { _ = app.activate(options: [.activateAllWindows]) }
        if Thread.isMainThread {
            activate()
            return true
        }
        DispatchQueue.main.async(execute: activate)
        return true
    }

    /// 用 Accessibility API 按标题找窗口并 raise。
    static func raiseWindow(ofApp app: NSRunningApplication, title: String) {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for window in windows {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
               let t = titleRef as? String, t == title {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return
            }
        }
    }

    public func mainScreenSize() -> (width: Double, height: Double) {
        let b = CGDisplayBounds(CGMainDisplayID())
        return (Double(b.width), Double(b.height))
    }
}

/// Mock 实现：固定窗口列表，记录激活调用。
public final class MockWindowService: WindowService {
    public var windows: [WindowInfo]
    public private(set) var activated: [Int] = []
    public var mainScreen: (width: Double, height: Double) = (1440, 900)

    public init(windows: [WindowInfo] = [
        WindowInfo(id: 1, title: "终端 — zsh", appName: "Terminal", pid: 101,
                   x: 0, y: 0, w: 800, h: 600, onScreen: true),
        WindowInfo(id: 2, title: "备忘录", appName: "Notes", pid: 202,
                   x: 100, y: 100, w: 600, h: 400, onScreen: true),
    ]) {
        self.windows = windows
    }

    public func listWindows() -> [WindowInfo] { windows }

    public func activate(windowId: Int) -> Bool {
        guard windows.contains(where: { $0.id == windowId }) else { return false }
        activated.append(windowId)
        return true
    }

    public func mainScreenSize() -> (width: Double, height: Double) { mainScreen }
}
