import XCTest
@testable import CoreLogic

/// 断言值与 Android core MouseMapperTest.kt 对齐。
final class MouseMathTests: XCTestCase {
    func testExactFit() {
        let m = MouseMath.normalized(viewW: 1000, viewH: 500, imgW: 1000, imgH: 500, x: 500, y: 250)
        XCTAssertEqual(m?.nx ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(m?.ny ?? -1, 0.5, accuracy: 1e-9)
    }

    func testLetterboxHorizontal() {
        // 视图 1600x800，图像 800x500 → scale=1.6，绘制区 1280x800，左右黑边各 160
        let m = MouseMath.normalized(viewW: 1600, viewH: 800, imgW: 800, imgH: 500, x: 160, y: 0)
        XCTAssertEqual(m?.nx ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(m?.ny ?? -1, 0.0, accuracy: 1e-9)
        let m2 = MouseMath.normalized(viewW: 1600, viewH: 800, imgW: 800, imgH: 500, x: 1440, y: 800)
        XCTAssertEqual(m2?.nx ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertNil(MouseMath.normalized(viewW: 1600, viewH: 800, imgW: 800, imgH: 500, x: 100, y: 400))
        XCTAssertNil(MouseMath.normalized(viewW: 1600, viewH: 800, imgW: 800, imgH: 500, x: 1500, y: 400))
    }

    func testLetterboxVertical() {
        // 视图 800x800，图像 800x500 → scale=1.0，绘制区 800x500，上下黑边各 150
        let m = MouseMath.normalized(viewW: 800, viewH: 800, imgW: 800, imgH: 500, x: 400, y: 650)
        XCTAssertEqual(m?.nx ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(m?.ny ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertNil(MouseMath.normalized(viewW: 800, viewH: 800, imgW: 800, imgH: 500, x: 400, y: 100))
    }

    func testInvalidInputs() {
        XCTAssertNil(MouseMath.normalized(viewW: 0, viewH: 100, imgW: 100, imgH: 100, x: 0, y: 0))
        XCTAssertNil(MouseMath.normalized(viewW: 100, viewH: 100, imgW: 0, imgH: 100, x: 0, y: 0))
    }

    func testCoercedMappingClampsOutOfBounds() {
        let m = MouseMath.normalized(viewW: 1600, viewH: 800, imgW: 800, imgH: 500,
                                     x: 100, y: 400, coerceToBounds: true)
        XCTAssertEqual(m?.nx ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(m?.ny ?? -1, 0.5, accuracy: 1e-9)
        // zoom=2 时绘制区为 [-400,1200]，-500 在图外 → 钳 0
        let m2 = MouseMath.normalizedZoomed(viewW: 800, viewH: 800, imgW: 800, imgH: 500,
                                            zoom: 2, panX: 0, panY: 0,
                                            x: -500, y: 400, coerceToBounds: true)
        XCTAssertEqual(m2?.nx ?? -1, 0.0, accuracy: 1e-9)
    }

    // zoom=2：绘制区 1600x1000，居中偏移 dx=-400, dy=-100

    func testCenterStaysCenter() {
        let m = MouseMath.normalizedZoomed(viewW: 800, viewH: 800, imgW: 800, imgH: 500,
                                           zoom: 2, panX: 0, panY: 0, x: 400, y: 400)
        XCTAssertEqual(m?.nx ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(m?.ny ?? -1, 0.5, accuracy: 1e-9)
    }

    func testViewOriginMapsIntoImage() {
        let m = MouseMath.normalizedZoomed(viewW: 800, viewH: 800, imgW: 800, imgH: 500,
                                           zoom: 2, panX: 0, panY: 0, x: 0, y: 0)
        XCTAssertEqual(m?.nx ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertEqual(m?.ny ?? -1, 0.1, accuracy: 1e-9)
    }

    func testPanShiftsMapping() {
        let m = MouseMath.normalizedZoomed(viewW: 800, viewH: 800, imgW: 800, imgH: 500,
                                           zoom: 2, panX: 400, panY: 0, x: 100, y: 400)
        XCTAssertEqual(m?.nx ?? -1, 0.0625, accuracy: 1e-9)
        XCTAssertEqual(m?.ny ?? -1, 0.5, accuracy: 1e-9)
    }

    func testOutOfImageReturnsNull() {
        XCTAssertNil(MouseMath.normalizedZoomed(viewW: 800, viewH: 800, imgW: 800, imgH: 500,
                                                zoom: 2, panX: 0, panY: 0, x: -401, y: 400))
        XCTAssertNil(MouseMath.normalizedZoomed(viewW: 800, viewH: 800, imgW: 800, imgH: 500,
                                                zoom: 0, panX: 0, panY: 0, x: 400, y: 400))
    }

    func testClampPanRules() {
        XCTAssertEqual(MouseMath.clampPan(viewSize: 800, fitDrawSize: 800, zoom: 2, pan: -1000), -400, accuracy: 1e-9)
        XCTAssertEqual(MouseMath.clampPan(viewSize: 800, fitDrawSize: 800, zoom: 2, pan: 1000), 400, accuracy: 1e-9)
        XCTAssertEqual(MouseMath.clampPan(viewSize: 800, fitDrawSize: 800, zoom: 2, pan: -123), -123, accuracy: 1e-9)
        XCTAssertEqual(MouseMath.clampPan(viewSize: 800, fitDrawSize: 800, zoom: 2, pan: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(MouseMath.clampPan(viewSize: 800, fitDrawSize: 800, zoom: 1, pan: 100), 0, accuracy: 1e-9)
        // letterbox 方向（内容 < 视图）锁定居中
        XCTAssertEqual(MouseMath.clampPan(viewSize: 800, fitDrawSize: 500, zoom: 1.2, pan: 50), 0, accuracy: 1e-9)
    }

    func testAnchoredPanKeepsFocusPointFixed() {
        XCTAssertEqual(MouseMath.anchoredPan(viewSize: 800, imgSize: 800, fitDrawSize: 800,
                                             zoom: 2, focus: 400, imgCoord: 400), 0, accuracy: 1e-9)
        XCTAssertEqual(MouseMath.anchoredPan(viewSize: 800, imgSize: 500, fitDrawSize: 500,
                                             zoom: 2, focus: 400, imgCoord: 250), 0, accuracy: 1e-9)
    }

    func testAnchoredPanFollowsFocusOffCenter() {
        XCTAssertEqual(MouseMath.anchoredPan(viewSize: 800, imgSize: 800, fitDrawSize: 800,
                                             zoom: 2, focus: 100, imgCoord: 0), 400, accuracy: 1e-9)
        XCTAssertEqual(MouseMath.anchoredPan(viewSize: 800, imgSize: 500, fitDrawSize: 500,
                                             zoom: 2, focus: 100, imgCoord: 0), 100, accuracy: 1e-9)
    }
}

/// 断言值与 Android GestureClassifierTest.kt 对齐。
final class GestureClassifierTests: XCTestCase {
    func testSingleTapIsClick() {
        let g = GestureClassifier()
        g.onDown(x: 100, y: 100, timeMs: 0)
        XCTAssertEqual(g.onUp(x: 102, y: 101, timeMs: 80), .click)
    }

    func testDoubleTap() {
        let g = GestureClassifier()
        g.onDown(x: 100, y: 100, timeMs: 0)
        XCTAssertEqual(g.onUp(x: 101, y: 100, timeMs: 60), .click)
        g.onDown(x: 100, y: 100, timeMs: 150)
        XCTAssertEqual(g.onUp(x: 101, y: 100, timeMs: 220), .doubleClick)
    }

    func testTwoTapsFarApartNotDouble() {
        let g = GestureClassifier()
        g.onDown(x: 100, y: 100, timeMs: 0)
        XCTAssertEqual(g.onUp(x: 101, y: 100, timeMs: 60), .click)
        g.onDown(x: 500, y: 500, timeMs: 150)
        XCTAssertEqual(g.onUp(x: 501, y: 500, timeMs: 220), .click)
    }

    func testLongPressIsRightClick() {
        let g = GestureClassifier()
        g.onDown(x: 100, y: 100, timeMs: 0)
        _ = g.onMove(x: 105, y: 105, timeMs: 500)
        XCTAssertTrue(g.isLongPress())
        XCTAssertEqual(g.onUp(x: 105, y: 105, timeMs: 550), .rightClick)
    }

    func testDragSequence() {
        let g = GestureClassifier()
        g.onDown(x: 100, y: 100, timeMs: 0)
        XCTAssertTrue(g.onMove(x: 140, y: 100, timeMs: 30))
        XCTAssertFalse(g.onMove(x: 180, y: 100, timeMs: 60), "第二次 move 不应再报首次进入")
        XCTAssertFalse(g.isLongPress())
        XCTAssertEqual(g.onUp(x: 200, y: 100, timeMs: 90), .dragEnd)
        g.onDown(x: 200, y: 200, timeMs: 200)
        XCTAssertEqual(g.onUp(x: 201, y: 100, timeMs: 260), .click)
    }

    func testDragSuppressesClickEvenIfBackToStart() {
        let g = GestureClassifier()
        g.onDown(x: 100, y: 100, timeMs: 0)
        XCTAssertTrue(g.onMove(x: 200, y: 100, timeMs: 20))
        _ = g.onMove(x: 101, y: 100, timeMs: 40)
        XCTAssertEqual(g.onUp(x: 100, y: 100, timeMs: 50), .dragEnd)
    }

    func testCancelSuppressesResult() {
        let g = GestureClassifier()
        g.onDown(x: 100, y: 100, timeMs: 0)
        XCTAssertTrue(g.onMove(x: 140, y: 100, timeMs: 30))
        g.cancel()
        XCTAssertEqual(g.onUp(x: 160, y: 100, timeMs: 60), .ignored)
        g.onDown(x: 100, y: 100, timeMs: 100)
        XCTAssertEqual(g.onUp(x: 101, y: 100, timeMs: 150), .click)
    }
}

final class PairingUriTests: XCTestCase {
    func testParseFull() {
        let info = PairingUri.parse("macscreen://connect?host=192.168.1.5&port=9700&token=abc123&name=My%20Mac")
        XCTAssertEqual(info?.host, "192.168.1.5")
        XCTAssertEqual(info?.port, 9700)
        XCTAssertEqual(info?.token, "abc123")
        XCTAssertEqual(info?.name, "My Mac")
    }

    func testNameDefaultsToMac() {
        let info = PairingUri.parse("macscreen://connect?host=10.0.0.2&port=9700&token=t")
        XCTAssertEqual(info?.name, "Mac")
    }

    func testRejectsWrongPrefix() {
        XCTAssertNil(PairingUri.parse("https://example.com?a=b"))
        XCTAssertNil(PairingUri.parse("macscreen://other?host=1&port=2&token=3"))
    }

    func testRequiresHostPortToken() {
        XCTAssertNil(PairingUri.parse("macscreen://connect?host=1.2.3.4&port=9700"))
        XCTAssertNil(PairingUri.parse("macscreen://connect?host=1.2.3.4&token=t"))
        XCTAssertNil(PairingUri.parse("macscreen://connect?port=9700&token=t"))
        XCTAssertNil(PairingUri.parse("macscreen://connect?host=1.2.3.4&port=abc&token=t"))
    }
}

final class RequestsTests: XCTestCase {
    func testFactories() {
        XCTAssertEqual(Requests.hello(token: "tk", deviceName: "iPhone")["op"] as? String, "hello")
        XCTAssertEqual(Requests.hello(token: "tk", deviceName: "iPhone")["token"] as? String, "tk")
        XCTAssertEqual(Requests.ping()["op"] as? String, "ping")
        XCTAssertEqual(Requests.subscribe(video: true)["video"] as? Bool, true)
        XCTAssertEqual(Requests.listWindows()["op"] as? String, "list-windows")
        XCTAssertEqual(Requests.activateWindow(42)["windowId"] as? Int, 42)
        let m = Requests.mouse(action: "click", nx: 0.5, ny: 0.25)
        XCTAssertEqual(m["x"] as? Double ?? -1, 0.5, accuracy: 1e-12)
        XCTAssertEqual(m["y"] as? Double ?? -1, 0.25, accuracy: 1e-12)
        XCTAssertEqual(Requests.scroll(dx: 1, dy: -2)["dy"] as? Double, -2)
        XCTAssertEqual(Requests.typeText("hi", submit: true)["submit"] as? Bool, true)
        XCTAssertNil(Requests.typeText("hi")["submit"])
        XCTAssertEqual((Requests.pressKey("return", modifiers: ["command"])["modifiers"] as? [String]), ["command"])
        let cap = Requests.setCapture(fps: 5, quality: 0.8)
        XCTAssertEqual(cap["fps"] as? Int, 5)
        XCTAssertEqual(cap["quality"] as? Double, 0.8)
        XCTAssertNil(cap["enabled"])
    }

    func testJSONSerializable() {
        // 所有工厂产物必须是合法 JSON 对象（协议层 ProtocolFrame.json 的硬要求）
        let all: [[String: Any]] = [
            Requests.hello(token: "t", deviceName: "d"), Requests.ping(), Requests.getStatus(),
            Requests.subscribe(video: false), Requests.setCapture(enabled: true, fps: 30, quality: 0.5, maxWidth: 1280),
            Requests.listWindows(), Requests.activateWindow(1), Requests.mouse(action: "drag", nx: 0.1, ny: 0.9),
            Requests.scroll(dx: 0, dy: 0), Requests.typeText("你好\nMac", submit: true),
            Requests.pressKey("delete", modifiers: []),
        ]
        for dict in all {
            XCTAssertTrue(JSONSerialization.isValidJSONObject(dict), "\(dict)")
        }
    }
}

final class VoiceCodecTests: XCTestCase {
    func testWavHeader() {
        let pcm: [Int16] = [0, 1, -1, 32767, -32768]
        let wav = WavEncoder.encode(pcm: pcm)
        XCTAssertEqual(wav.count, 44 + pcm.count * 2)
        let bytes = [UInt8](wav)
        XCTAssertEqual(Array(bytes[0...3]), Array("RIFF".utf8))
        // ChunkSize = 36 + dataLen(10)
        XCTAssertEqual(bytes[4], 46); XCTAssertEqual(bytes[5], 0)
        XCTAssertEqual(bytes[6], 0); XCTAssertEqual(bytes[7], 0)
        XCTAssertEqual(Array(bytes[8...11]), Array("WAVE".utf8))
        XCTAssertEqual(Array(bytes[12...15]), Array("fmt ".utf8))
        XCTAssertEqual(bytes[20], 1); XCTAssertEqual(bytes[22], 1)  // PCM / mono
        // SampleRate 16000 = 0x3E80 LE
        XCTAssertEqual(bytes[24], 0x80); XCTAssertEqual(bytes[25], 0x3E)
        // ByteRate = 16000*1*2 = 32000 = 0x7D00 LE
        XCTAssertEqual(bytes[28], 0x00); XCTAssertEqual(bytes[29], 0x7D)
        XCTAssertEqual(bytes[32], 2); XCTAssertEqual(bytes[34], 16)  // BlockAlign / Bits
        XCTAssertEqual(Array(bytes[36...39]), Array("data".utf8))
        XCTAssertEqual(bytes[40], 10); XCTAssertEqual(bytes[41], 0)
        // -32768 → 0x8000 LE
        XCTAssertEqual(bytes[52], 0x00); XCTAssertEqual(bytes[53], 0x80)
        XCTAssertEqual(WavEncoder.durationSeconds(pcmCount: 32000), 2.0, accuracy: 1e-9)
    }

    func testMultipartStructure() {
        let config = CloudTranscriberConfig(url: "https://x/v1", apiKey: "sk", model: "whisper-1",
                                            style: "openai", language: "zh")
        let wav = WavEncoder.encode(pcm: [100, -100])
        let body = CloudCodec.buildBody(config, wav: wav)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("--\(CloudCodec.boundary)\r\n"))
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\nwhisper-1\r\n"))
        XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nzh\r\n"))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"audio.wav\"\r\n"))
        XCTAssertTrue(text.contains("Content-Type: audio/wav\r\n\r\n"))
        XCTAssertTrue(text.hasSuffix("--\(CloudCodec.boundary)--\r\n"))
        XCTAssertEqual(CloudCodec.contentType(config),
                       "multipart/form-data; boundary=\(CloudCodec.boundary)")
    }

    func testRawStyle() {
        let config = CloudTranscriberConfig(url: "https://x/raw", apiKey: "", model: "m", style: "raw")
        let wav = Data([1, 2, 3])
        XCTAssertEqual(CloudCodec.buildBody(config, wav: wav), wav)
        XCTAssertEqual(CloudCodec.contentType(config), "audio/wav")
        XCTAssertNil(CloudCodec.authHeader(config))
    }

    func testParseResponse() throws {
        let config = CloudTranscriberConfig(url: "", apiKey: "", model: "", responseField: "text")
        let json = Data("{\"text\":\"你好 Mac\"}".utf8)
        XCTAssertEqual(try CloudCodec.parseResponse(json, responseField: config.responseField), "你好 Mac")
        XCTAssertEqual(try CloudCodec.parseResponse(Data("纯文本结果".utf8), responseField: nil), "纯文本结果")
        XCTAssertThrowsError(try CloudCodec.parseResponse(Data("{\"other\":1}".utf8), responseField: "text"))
        XCTAssertThrowsError(try CloudCodec.parseResponse(Data("  ".utf8), responseField: "text"))
    }
}
