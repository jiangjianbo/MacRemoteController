import Foundation

/// 扫码配对 URI 解析：`macscreen://connect?host=<ip>&port=<port>&token=<hex32>&name=<服务器名>`。
/// 与 Mac 端 ConnectionInfo.qrContent / Android PairingUri 兼容（RFC3986 百分号转义）。
public enum PairingUri {
    public static let prefix = "macscreen://connect?"

    public struct Info: Equatable {
        public let host: String
        public let port: Int
        public let token: String
        public let name: String

        public init(host: String, port: Int, token: String, name: String) {
            self.host = host; self.port = port; self.token = token; self.name = name
        }
    }

    public static func parse(_ content: String) -> Info? {
        guard content.hasPrefix(prefix) else { return nil }
        let query = String(content.dropFirst(prefix.count))
        var fields: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            fields[String(kv[0])] = percentDecode(String(kv[1]))
        }
        guard let host = fields["host"], !host.isEmpty,
              let portStr = fields["port"], let port = Int(portStr), port > 0,
              let token = fields["token"], !token.isEmpty else { return nil }
        return Info(host: host, port: port, token: token, name: fields["name"] ?? "Mac")
    }

    /// 百分号解码；`+` 按表单语义解为空格（与 Android URLDecoder 一致）。
    static func percentDecode(_ s: String) -> String {
        var bytes: [UInt8] = []
        let chars = Array(s.utf8)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == UInt8(ascii: "+") {
                bytes.append(UInt8(ascii: " "))
                i += 1
            } else if c == UInt8(ascii: "%"), i + 2 < chars.count,
                      let hi = hexDigit(chars[i + 1]), let lo = hexDigit(chars[i + 2]) {
                bytes.append(hi << 4 | lo)
                i += 3
            } else {
                bytes.append(c)
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func hexDigit(_ b: UInt8) -> UInt8? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}

/// 手机 → Mac 请求构造（与 Android Requests / Mac 端 Request.parse 字段逐一对齐，不带 id）。
public enum Requests {
    public static func hello(token: String, deviceName: String) -> [String: Any] {
        ["op": "hello", "token": token, "deviceName": deviceName]
    }

    public static func ping() -> [String: Any] { ["op": "ping"] }

    public static func getStatus() -> [String: Any] { ["op": "get-status"] }

    public static func subscribe(video: Bool) -> [String: Any] {
        ["op": "subscribe", "video": video]
    }

    public static func setCapture(enabled: Bool? = nil, fps: Int? = nil,
                                  quality: Double? = nil, maxWidth: Int? = nil) -> [String: Any] {
        var dict: [String: Any] = ["op": "set-capture"]
        if let enabled = enabled { dict["enabled"] = enabled }
        if let fps = fps { dict["fps"] = fps }
        if let quality = quality { dict["quality"] = quality }
        if let maxWidth = maxWidth { dict["maxWidth"] = maxWidth }
        return dict
    }

    public static func listWindows() -> [String: Any] { ["op": "list-windows"] }

    public static func activateWindow(_ windowId: Int) -> [String: Any] {
        ["op": "activate-window", "windowId": windowId]
    }

    public static func mouse(action: String, nx: Double, ny: Double) -> [String: Any] {
        ["op": "mouse", "action": action, "x": nx, "y": ny]
    }

    public static func scroll(dx: Double, dy: Double) -> [String: Any] {
        ["op": "scroll", "dx": dx, "dy": dy]
    }

    public static func typeText(_ text: String, submit: Bool = false) -> [String: Any] {
        var dict: [String: Any] = ["op": "type-text", "text": text]
        if submit { dict["submit"] = true }
        return dict
    }

    public static func pressKey(_ key: String, modifiers: [String] = []) -> [String: Any] {
        var dict: [String: Any] = ["op": "press-key", "key": key]
        if !modifiers.isEmpty { dict["modifiers"] = modifiers }
        return dict
    }
}
