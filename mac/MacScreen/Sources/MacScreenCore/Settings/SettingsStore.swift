import Foundation

/// 服务端设置（可注入存储，测试用内存实现）。
public protocol SettingsStore: AnyObject {
    var port: UInt16 { get set }
    var fps: Int { get set }
    var quality: Double { get set }
    var maxWidth: Int { get set }
    var captureEnabled: Bool { get set }
    /// 无屏幕录制权限时是否退回 Mock 视频源（开发/测试方便，生产可关）。
    var mockFallback: Bool { get set }
    var serverName: String { get set }
    var loginItemEnabled: Bool { get set }
}

public final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "macscreen.port": UInt16(9700),
            "macscreen.fps": 12,
            "macscreen.quality": 0.6,
            "macscreen.maxWidth": 1280,
            "macscreen.captureEnabled": true,
            "macscreen.mockFallback": true,
            "macscreen.serverName": Host.current().localizedName ?? "Mac",
            "macscreen.loginItemEnabled": false,
        ])
    }

    private func getInt(_ key: String) -> Int { defaults.integer(forKey: key) }

    public var port: UInt16 {
        get { UInt16(clamping: getInt("macscreen.port")) }
        set { defaults.set(Int(newValue), forKey: "macscreen.port") }
    }
    public var fps: Int {
        get { min(60, max(1, getInt("macscreen.fps"))) }
        set { defaults.set(min(60, max(1, newValue)), forKey: "macscreen.fps") }
    }
    public var quality: Double {
        get { min(1.0, max(0.1, defaults.double(forKey: "macscreen.quality"))) }
        set { defaults.set(min(1.0, max(0.1, newValue)), forKey: "macscreen.quality") }
    }
    public var maxWidth: Int {
        get { min(3840, max(320, getInt("macscreen.maxWidth"))) }
        set { defaults.set(min(3840, max(320, newValue)), forKey: "macscreen.maxWidth") }
    }
    public var captureEnabled: Bool {
        get { defaults.bool(forKey: "macscreen.captureEnabled") }
        set { defaults.set(newValue, forKey: "macscreen.captureEnabled") }
    }
    public var mockFallback: Bool {
        get { defaults.bool(forKey: "macscreen.mockFallback") }
        set { defaults.set(newValue, forKey: "macscreen.mockFallback") }
    }
    public var serverName: String {
        get { defaults.string(forKey: "macscreen.serverName") ?? "Mac" }
        set { defaults.set(newValue, forKey: "macscreen.serverName") }
    }
    public var loginItemEnabled: Bool {
        get { defaults.bool(forKey: "macscreen.loginItemEnabled") }
        set { defaults.set(newValue, forKey: "macscreen.loginItemEnabled") }
    }
}

public final class InMemorySettingsStore: SettingsStore {
    public var port: UInt16 = 9700
    public var fps: Int = 12
    public var quality: Double = 0.6
    public var maxWidth: Int = 1280
    public var captureEnabled: Bool = true
    public var mockFallback: Bool = true
    public var serverName: String = "TestMac"
    public var loginItemEnabled: Bool = false

    public init() {}
}
