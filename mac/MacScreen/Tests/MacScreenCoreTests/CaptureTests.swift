import XCTest
@testable import MacScreenCore

final class CaptureTests: XCTestCase {
    func testMockFrameSourceProducesValidJPEG() throws {
        let source = MockFrameSource(width: 640, height: 400, fps: 30)
        var frames: [Data] = []
        let got = expectation(description: "frame")
        source.onFrame = { data in
            frames.append(data)
            got.fulfill()
        }
        try source.start()
        wait(for: [got], timeout: 3)
        source.stop()

        XCTAssertGreaterThanOrEqual(frames.count, 1)
        XCTAssertTrue(JPEGEncoder.isJPEG(frames[0]), "应为合法 JPEG（FFD8..FFD9）")
        XCTAssertEqual(source.info.pixelWidth, 640)
        XCTAssertFalse(source.running, "stop 后应停止")
    }

    func testMockFrameSourceRejectsDoubleStart() throws {
        let source = MockFrameSource(fps: 30)
        try source.start()
        XCTAssertThrowsError(try source.start()) { error in
            XCTAssertTrue(String(describing: error).contains("运行"), "重复启动应报 alreadyRunning")
        }
        source.stop()
    }

    func testJpegMagicCheck() {
        XCTAssertTrue(JPEGEncoder.isJPEG(Data([0xFF, 0xD8, 0x00, 0xFF, 0xD9])))
        XCTAssertFalse(JPEGEncoder.isJPEG(Data([0x89, 0x50, 0x00, 0x00, 0x01])))
        XCTAssertFalse(JPEGEncoder.isJPEG(Data([0xFF, 0xD8])))
        XCTAssertFalse(JPEGEncoder.isJPEG(Data()))
    }

    func testJpegEncoderScalesDown() throws {
        let source = MockFrameSource(width: 800, height: 500)
        var frame: CGImage?
        let got = expectation(description: "frame")
        source.onFrame = { _ in
            // 直接从 mock 源重新生成一帧拿 CGImage 太绕；改为手工构造大图测试缩放
            got.fulfill()
        }
        try source.start()
        wait(for: [got], timeout: 3)
        source.stop()
        _ = frame

        let big = try XCTUnwrap(CGContext.makeTestImage(width: 2000, height: 1200))
        let small = try XCTUnwrap(JPEGEncoder.encode(big, quality: 0.7, maxWidth: 640))
        // 解码回读尺寸
        let rep = try XCTUnwrap(NSBitmapImageRep(data: small))
        XCTAssertEqual(rep.pixelsWide, 640, "应缩放到 maxWidth")
        XCTAssertEqual(rep.pixelsHigh, 384)
        let full = try XCTUnwrap(JPEGEncoder.encode(big, quality: 0.7, maxWidth: 0))
        let repFull = try XCTUnwrap(NSBitmapImageRep(data: full))
        XCTAssertEqual(repFull.pixelsWide, 2000, "maxWidth=0 不缩放")
    }
}

extension CGContext {
    /// 生成测试图片（纯色渐变矩形）。
    static func makeTestImage(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        return ctx.makeImage()
    }
}

/// CaptureController 状态机测试（全 Mock）。
final class CaptureControllerTests: XCTestCase {
    func testStartWithMockConfig() {
        let settings = InMemorySettingsStore()
        var config = LaunchConfig()
        config.mockCapture = true
        let controller = CaptureController(settings: settings, config: config)
        var stateEvents: [ServerEvent] = []
        controller.onStateChange = { stateEvents.append($0) }

        controller.startIfNeeded()
        XCTAssertTrue(controller.isRunning)
        XCTAssertTrue(controller.usingMock)
        XCTAssertEqual(stateEvents.count, 1)
        XCTAssertEqual(stateEvents[0].dict["enabled"] as? Bool, true)
        controller.stop()
        XCTAssertFalse(controller.isRunning)
    }

    func testDisabledDoesNotStart() {
        let settings = InMemorySettingsStore()
        settings.captureEnabled = false
        var config = LaunchConfig()
        config.mockCapture = true
        let controller = CaptureController(settings: settings, config: config)
        controller.startIfNeeded()
        XCTAssertFalse(controller.isRunning)
    }

    func testUpdateRecreatesWithNewParams() {
        let settings = InMemorySettingsStore()
        var config = LaunchConfig()
        config.mockCapture = true
        let controller = CaptureController(settings: settings, config: config)
        controller.startIfNeeded()

        let event = controller.update(enabled: nil, fps: 25, quality: 0.9, maxWidth: 800)
        XCTAssertEqual(settings.fps, 25)
        XCTAssertEqual(event.dict["op"] as? String, "capture-state")
        XCTAssertEqual(event.dict["mock"] as? Bool, true)
        XCTAssertTrue(controller.isRunning, "参数更新后应继续运行")
        controller.stop()
    }

    func testCurrentInfoReflectsSettings() {
        let settings = InMemorySettingsStore()
        settings.fps = 17
        var config = LaunchConfig()
        config.mockCapture = true
        let controller = CaptureController(settings: settings, config: config)
        controller.startIfNeeded()
        let info = controller.currentInfo()
        XCTAssertEqual(info.fps, 17)
        XCTAssertTrue(info.mock)
        XCTAssertEqual(info.widthPts, Double(CGDisplayBounds(CGMainDisplayID()).width))
        controller.stop()
    }
}
