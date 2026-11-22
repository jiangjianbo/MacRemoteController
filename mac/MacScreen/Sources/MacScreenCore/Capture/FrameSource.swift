import Foundation
import CoreGraphics
import AppKit

/// JPEG 编码（NSBitmapImageRep，系统内置），支持按最大宽度缩放。
public enum JPEGEncoder {
    /// CGImage → JPEG Data；maxWidth > 0 且原图更宽时按比例缩小。
    public static func encode(_ image: CGImage, quality: Double, maxWidth: Int) -> Data? {
        var target = image
        if maxWidth > 0, image.width > maxWidth {
            let scale = Double(maxWidth) / Double(image.width)
            let w = maxWidth
            let h = max(1, Int((Double(image.height) * scale).rounded()))
            guard let ctx = CGContext(data: nil, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { return nil }
            target = scaled
        }
        let rep = NSBitmapImageRep(cgImage: target)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// 判断数据是否为 JPEG（FFD8 开头 FFD9 结尾）。
    public static func isJPEG(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let first = [UInt8](data.prefix(2))
        let last = [UInt8](data.suffix(2))
        return first == [0xFF, 0xD8] && last == [0xFF, 0xD9]
    }
}

/// 视频源信息。
public struct FrameSourceInfo {
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(pixelWidth: Int, pixelHeight: Int) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// 帧源协议：产 JPEG 帧的组件（真实捕获 / Mock）。所有实现必须线程安全。
public protocol FrameSource: AnyObject {
    var info: FrameSourceInfo { get }
    /// 收到一帧（JPEG Data）。回调可能在后台线程。
    var onFrame: ((Data) -> Void)? { get set }
    func start() throws
    func stop()
    var running: Bool { get }
}

/// 捕获失败原因。
public enum CaptureError: Error, CustomStringConvertible {
    case screenRecordingPermissionDenied
    case noDisplay
    case alreadyRunning

    public var description: String {
        switch self {
        case .screenRecordingPermissionDenied: return "未授予「屏幕录制」权限"
        case .noDisplay: return "找不到显示器"
        case .alreadyRunning: return "捕获已在运行"
        }
    }
}

// MARK: - Mock 帧源（CGContext 画测试图案，稳定可断言）

public final class MockFrameSource: FrameSource {
    public var onFrame: ((Data) -> Void)?
    public private(set) var running = false
    public let info: FrameSourceInfo

    private let queue = DispatchQueue(label: "macscreen.mockcapture")
    private var timer: DispatchSourceTimer?
    private var frameIndex = 0
    private let fps: Int

    public init(width: Int = 800, height: Int = 500, fps: Int = 12) {
        self.info = FrameSourceInfo(pixelWidth: width, pixelHeight: height)
        self.fps = fps
    }

    public func start() throws {
        guard !running else { throw CaptureError.alreadyRunning }
        running = true
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        t.setEventHandler { [weak self] in self?.produceFrame() }
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        running = false
    }

    /// 生成一帧测试图案（渐变底 + 帧号 + 时间戳文字）。
    func produceFrame() {
        let w = info.pixelWidth, h = info.pixelHeight
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // 深色底
        ctx.setFillColor(CGColor(red: 0.08, green: 0.10, blue: 0.16, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // 渐变条纹（随帧号移动，验证画面在动）
        frameIndex += 1
        let offset = CGFloat(frameIndex % 10) * 20
        ctx.setFillColor(CGColor(red: 0.2, green: 0.55, blue: 0.9, alpha: 1))
        for i in 0..<8 {
            let x = CGFloat(i) * CGFloat(w) / 8 + offset
            ctx.fill(CGRect(x: x.truncatingRemainder(dividingBy: CGFloat(w)), y: CGFloat(h) - 40,
                            width: 14, height: 40))
        }
        // 文字
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let text = "MacScreen Mock 帧 #\(frameIndex)  \(formatter.string(from: Date()))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 28, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        NSAttributedString(string: text, attributes: attrs)
            .draw(in: CGRect(x: 20, y: CGFloat(h) / 2 - 20, width: CGFloat(w) - 40, height: 40))
        guard let image = ctx.makeImage(),
              let jpeg = JPEGEncoder.encode(image, quality: 0.6, maxWidth: 0) else { return }
        onFrame?(jpeg)
    }
}

// MARK: - 真实捕获：CGDisplayCreateImage 定时快照流

public final class CGSnapshotFrameSource: FrameSource {
    public var onFrame: ((Data) -> Void)?
    public private(set) var running = false
    public let info: FrameSourceInfo

    private let queue = DispatchQueue(label: "macscreen.capture")
    private var timer: DispatchSourceTimer?
    private let displayID: CGDirectDisplayID
    private let fps: Int
    private let quality: Double
    private let maxWidth: Int

    public init(fps: Int, quality: Double, maxWidth: Int,
                displayID: CGDirectDisplayID = CGMainDisplayID()) {
        self.displayID = displayID
        self.fps = fps
        self.quality = quality
        self.maxWidth = maxWidth
        let bounds = CGDisplayBounds(displayID)
        let pw = maxWidth > 0 ? maxWidth : Int(bounds.width)
        let ph = max(1, Int((bounds.height * (Double(pw) / max(bounds.width, 1))).rounded()))
        self.info = FrameSourceInfo(pixelWidth: pw, pixelHeight: ph)
    }

    /// 权限预检（10.15+）。无权限时 CGDisplayCreateImage 得不到窗口内容。
    public static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public func start() throws {
        guard !running else { throw CaptureError.alreadyRunning }
        guard CGDisplayIsActive(displayID) != 0 else { throw CaptureError.noDisplay }
        running = true
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        t.setEventHandler { [weak self] in self?.produceFrame() }
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        running = false
    }

    private func produceFrame() {
        guard let image = CGDisplayCreateImage(displayID) else { return }
        guard let jpeg = JPEGEncoder.encode(image, quality: quality, maxWidth: maxWidth) else { return }
        onFrame?(jpeg)
    }
}
