import XCTest
@testable import MacScreenCore

/// CGWindowService.filterWindows 纯函数测试（真实 CGWindowList 依赖系统 + 权限，不可单测）。
final class WindowServiceTests: XCTestCase {
    /// 构造 CGWindowListCopyWindowInfo 风格的窗口条目。
    private func makeEntry(id: Int, pid: Int = 500, layer: Int = 0,
                       owner: String = "Safari", title: String? = nil,
                       w: Double = 800, h: Double = 600,
                       onScreen: Bool? = nil) -> [String: Any] {
        var e: [String: Any] = [
            kCGWindowNumber as String: id,
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowOwnerName as String: owner,
            kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": w, "Height": h] as [String: NSNumber],
        ]
        if let t = title { e[kCGWindowName as String] = t }
        if let s = onScreen { e[kCGWindowIsOnscreen as String] = s }
        return e
    }

    func testOffscreenFullscreenSpaceWindowIsListed() {
        // 全屏应用独占独立 Space，其窗口 isOnscreen=false；窗口列表必须包含它们
        // （此前 optionOnScreenOnly 直接漏掉，手机端看不到，需手动切屏才出现）。
        let entries = [
            makeEntry(id: 1, title: "当前桌面窗口", onScreen: true),
            makeEntry(id: 2, title: "全屏备忘录", onScreen: false),
        ]
        let list = CGWindowService.filterWindows(entries, myPid: 9999)
        XCTAssertEqual(list.map(\.id), [1, 2])
        XCTAssertEqual(list[1].onScreen, false)
    }

    func testFiltersLayerSelfPidInvalidPidSmallPanel() {
        let entries = [
            makeEntry(id: 10, layer: 25),       // 状态栏等非普通层：滤
            makeEntry(id: 11, pid: 7),          // agent 自身进程：滤
            makeEntry(id: 12, pid: -1),         // 非法 pid：滤
            makeEntry(id: 13, w: 50, h: 30),    // 小面板：滤
            makeEntry(id: 14, pid: 42, title: "正常窗口", onScreen: true),
        ]
        let list = CGWindowService.filterWindows(entries, myPid: 7)
        XCTAssertEqual(list.map(\.id), [14])
        XCTAssertEqual(list[0].appName, "Safari")
    }

    func testTitleFallsBackToOwnerWithoutCapturePermission() {
        // 无屏幕录制权限时 kCGWindowName 缺失，标题退化为应用名
        let list = CGWindowService.filterWindows([makeEntry(id: 20, owner: "Finder")], myPid: 1)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].title, "Finder")
    }

    func testOnscreenDefaultsTrueWhenAbsent() {
        let list = CGWindowService.filterWindows([makeEntry(id: 30, title: "无标记窗口")], myPid: 1)
        XCTAssertEqual(list[0].onScreen, true)
    }
}
