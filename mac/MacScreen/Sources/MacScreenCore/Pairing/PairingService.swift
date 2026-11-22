import Foundation
import CoreImage
import AppKit
import Security

// MARK: - 令牌生成与存储

public enum TokenGenerator {
    /// 生成 32 位 hex 配对令牌（16 字节随机数）。
    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // 极端兜底：系统随机源失败时退回 arc4random
            for i in 0..<bytes.count { bytes[i] = UInt8(arc4random_uniform(256)) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public protocol TokenStore: AnyObject {
    var token: String { get }
}

/// 内存存储（测试 / 一次性会话）。
public final class InMemoryTokenStore: TokenStore {
    public let token: String
    public init(token: String = TokenGenerator.newToken()) { self.token = token }
}

/// UserDefaults 持久化存储：首次运行生成，之后稳定不变（QR 码保持有效）。
public final class UserDefaultsTokenStore: TokenStore {
    private let defaults: UserDefaults
    private let key = "macscreen.pairing.token"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.string(forKey: key) == nil {
            defaults.set(TokenGenerator.newToken(), forKey: key)
        }
    }

    public var token: String {
        defaults.string(forKey: key) ?? TokenGenerator.newToken()
    }
}

// MARK: - QR 生成（CoreImage CIQRCodeGenerator，系统内置）

public enum QRCodeService {
    /// 生成二维码 CGImage。失败返回 nil。
    public static func qrImage(content: String, sizePx: Int = 360) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(content.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = max(CGFloat(1), CGFloat(sizePx) / max(output.extent.width, 1))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: nil)
        return context.createCGImage(scaled, from: scaled.extent)
    }

    /// 生成二维码 PNG 数据（用于保存/剪贴板）。
    public static func qrPNGData(content: String, sizePx: Int = 360) -> Data? {
        guard let cg = qrImage(content: content, sizePx: sizePx) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - 连接信息（QR 内容）

public struct ConnectionInfo {
    public var host: String
    public var port: UInt16
    public var token: String
    public var name: String

    public init(host: String, port: UInt16, token: String, name: String) {
        self.host = host; self.port = port; self.token = token; self.name = name
    }

    /// 手机扫码得到的内容：macscreen://connect?host=..&port=..&token=..&name=..
    public var qrContent: String {
        func esc(_ s: String) -> String {
            // RFC3986 非保留字符之外全部转义（& = ? 等必须转义，否则参数解析错乱）
            let allowed = CharacterSet(charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        }
        return "macscreen://connect?host=\(esc(host))&port=\(port)&token=\(esc(token))&name=\(esc(name))"
    }
}

// MARK: - 配对服务

public final class PairingService {
    public let store: TokenStore
    public var serverName: String

    public init(store: TokenStore, serverName: String) {
        self.store = store
        self.serverName = serverName
    }

    public var token: String { store.token }

    public func connectionInfo(host: String, port: UInt16) -> ConnectionInfo {
        ConnectionInfo(host: host, port: port, token: token, name: serverName)
    }
}
