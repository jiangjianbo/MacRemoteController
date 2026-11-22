import Foundation

// MARK: - 手机 → Mac 请求

/// 手机端发来的 JSON 控制消息。宽松解析：按 op 取所需字段，多余字段忽略。
public struct Request {
    public let op: String
    /// 请求 id（数字或字符串），响应原样带回。
    public let id: Any?
    public let dict: [String: Any]

    init?(dict: [String: Any]) {
        guard let op = dict["op"] as? String, !op.isEmpty else { return nil }
        self.op = op
        self.id = dict["id"]
        self.dict = dict
    }

    public static func parse(_ data: Data) -> Request? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any] else { return nil }
        return Request(dict: dict)
    }

    public func string(_ key: String) -> String? { dict[key] as? String }
    public func bool(_ key: String) -> Bool? { dict[key] as? Bool ?? (dict[key] as? NSNumber)?.boolValue }
    public func int(_ key: String) -> Int? { dict[key] as? Int ?? (dict[key] as? NSNumber)?.intValue }
    public func double(_ key: String) -> Double? { dict[key] as? Double ?? (dict[key] as? NSNumber)?.doubleValue }

    /// token 字段
    public var token: String? { string("token") }
    public var deviceName: String? { string("deviceName") }
    public var text: String? { string("text") }
    public var windowId: Int? { int("windowId") }
    public var action: String? { string("action") }
    public var key: String? { string("key") }
    public var modifiers: [String]? { dict["modifiers"] as? [String] }
    public var x: Double? { double("x") }
    public var y: Double? { double("y") }
    public var dx: Double? { double("dx") }
    public var dy: Double? { double("dy") }
    public var fps: Int? { int("fps") }
    public var quality: Double? { double("quality") }
    public var maxWidth: Int? { int("maxWidth") }
    public var enabled: Bool? { bool("enabled") }
    public var video: Bool? { bool("video") }
    public var submit: Bool? { bool("submit") }
}

// MARK: - 窗口信息

public struct WindowInfo: Equatable {
    public let id: Int
    public let title: String
    public let appName: String
    public let pid: Int
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double
    public let onScreen: Bool

    public init(id: Int, title: String, appName: String, pid: Int,
                x: Double, y: Double, w: Double, h: Double, onScreen: Bool) {
        self.id = id; self.title = title; self.appName = appName; self.pid = pid
        self.x = x; self.y = y; self.w = w; self.h = h; self.onScreen = onScreen
    }

    public var dict: [String: Any] {
        ["id": id, "title": title, "appName": appName, "pid": pid,
         "x": x, "y": y, "w": w, "h": h, "onScreen": onScreen]
    }

    public static func dictionaries(_ list: [WindowInfo]) -> [[String: Any]] {
        list.map { $0.dict }
    }
}

// MARK: - 屏幕信息

public struct ScreenInfo: Equatable {
    public var widthPts: Double
    public var heightPts: Double
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var fps: Int
    public var quality: Double
    public var maxWidth: Int
    public var mock: Bool

    public init(widthPts: Double, heightPts: Double, pixelWidth: Int, pixelHeight: Int,
                fps: Int, quality: Double, maxWidth: Int, mock: Bool) {
        self.widthPts = widthPts; self.heightPts = heightPts
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.fps = fps; self.quality = quality; self.maxWidth = maxWidth; self.mock = mock
    }

    public var dict: [String: Any] {
        ["width": widthPts, "height": heightPts,
         "pixelWidth": pixelWidth, "pixelHeight": pixelHeight,
         "fps": fps, "quality": quality, "maxWidth": maxWidth, "mock": mock]
    }
}

// MARK: - Mac → 手机 事件

public struct ServerEvent {
    public let dict: [String: Any]

    public init(_ dict: [String: Any]) { self.dict = dict }

    /// 构造事件：`op` 必填，可选带回请求 id。
    public static func make(_ op: String, _ extra: [String: Any] = [:], id: Any? = nil) -> ServerEvent {
        var d: [String: Any] = ["op": op]
        if let id = id { d["id"] = id }
        for (k, v) in extra { d[k] = v }
        return ServerEvent(d)
    }

    public static func helloAck(serverName: String, protocolVersion: Int, mock: Bool, id: Any?) -> ServerEvent {
        .make("hello-ack", ["ok": true, "serverName": serverName,
                            "protocol": protocolVersion, "mock": mock], id: id)
    }

    public static func error(code: String, message: String, id: Any?) -> ServerEvent {
        .make("error", ["code": code, "message": message], id: id)
    }

    public static func pong(id: Any?) -> ServerEvent { .make("pong", id: id) }

    public static func status(_ fields: [String: Any], id: Any?) -> ServerEvent {
        .make("status", fields, id: id)
    }

    public static func windows(_ list: [WindowInfo], id: Any?) -> ServerEvent {
        .make("windows", ["list": WindowInfo.dictionaries(list)], id: id)
    }

    public static func screenInfo(_ info: ScreenInfo, id: Any?) -> ServerEvent {
        .make("screen-info", info.dict, id: id)
    }

    public static func captureState(enabled: Bool, permission: Bool, mock: Bool, id: Any?) -> ServerEvent {
        .make("capture-state", ["enabled": enabled, "permission": permission, "mock": mock], id: id)
    }

    /// 通用 ok 应答，可携带 echo 内容（mock 模式下用于端到端断言输入动作）。
    public static func ok(action: String, echo: [String: Any] = [:], id: Any?) -> ServerEvent {
        .make("ok", ["action": action, "echo": echo], id: id)
    }

    public func encoded() -> Data? {
        ProtocolFrame.json(dict)?.encoded()
    }
}
