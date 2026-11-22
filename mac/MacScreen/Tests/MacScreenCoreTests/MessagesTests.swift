import XCTest
@testable import MacScreenCore

final class MessagesTests: XCTestCase {
    /// 辅助：把完整帧字节解码回 JSON 字典。
    func frameJSON(_ data: Data) throws -> [String: Any] {
        var decoder = FrameDecoder()
        let frames = decoder.feed(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.kind, .json)
        let obj = try JSONSerialization.jsonObject(with: XCTUnwrap(frames.first?.payload))
        return try XCTUnwrap(obj as? [String: Any])
    }

    func testRequestParse() throws {
        let json = #"{"op":"type-text","text":"你好","submit":true,"id":9,"x":0.5,"fps":30,"video":false}"#
        let req = Request.parse(Data(json.utf8))
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.op, "type-text")
        XCTAssertEqual(req?.text, "你好")
        XCTAssertEqual(req?.submit, true)
        XCTAssertEqual((req?.id as? NSNumber)?.intValue, 9)
        XCTAssertEqual(req?.x, 0.5)
        XCTAssertEqual(req?.fps, 30)
        XCTAssertEqual(req?.video, false)
    }

    func testRequestParseRejectsGarbage() {
        XCTAssertNil(Request.parse(Data("not json".utf8)))
        XCTAssertNil(Request.parse(Data(#"{"no-op":1}"#.utf8)))
    }

    func testServerEventEncodingCarriesID() throws {
        let event = ServerEvent.error(code: "auth", message: "token 错误", id: 42)
        let data = try XCTUnwrap(event.encoded())
        let back = try frameJSON(data)
        XCTAssertEqual(back["op"] as? String, "error")
        XCTAssertEqual(back["code"] as? String, "auth")
        XCTAssertEqual((back["id"] as? NSNumber)?.intValue, 42)
    }

    func testWindowInfoDictionary() {
        let info = WindowInfo(id: 3, title: "终端", appName: "Terminal", pid: 100,
                              x: 1, y: 2, w: 3, h: 4, onScreen: true)
        let dict = info.dict
        XCTAssertEqual(dict["id"] as? Int, 3)
        XCTAssertEqual(dict["title"] as? String, "终端")
        XCTAssertEqual(dict["w"] as? Double, 3)
        let dicts = WindowInfo.dictionaries([info])
        XCTAssertEqual(dicts.count, 1)
        XCTAssertEqual(dicts[0]["appName"] as? String, "Terminal")
    }

    func testScreenInfoDictionary() {
        let info = ScreenInfo(widthPts: 1440, heightPts: 900, pixelWidth: 1280, pixelHeight: 800,
                              fps: 12, quality: 0.6, maxWidth: 1280, mock: true)
        let dict = info.dict
        XCTAssertEqual(dict["width"] as? Double, 1440)
        XCTAssertEqual(dict["mock"] as? Bool, true)
        XCTAssertEqual(dict["fps"] as? Int, 12)
    }

    func testHelloAckAndOkEvents() throws {
        let ack = ServerEvent.helloAck(serverName: "Mac", protocolVersion: 1, mock: false, id: 1)
        let ackDict = try frameJSON(try XCTUnwrap(ack.encoded()))
        XCTAssertEqual(ackDict["op"] as? String, "hello-ack")
        XCTAssertEqual(ackDict["ok"] as? Bool, true)
        XCTAssertEqual(ackDict["protocol"] as? Int, 1)

        let ok = ServerEvent.ok(action: "mouse", echo: ["x": 720.0], id: 2)
        let okDict = try frameJSON(try XCTUnwrap(ok.encoded()))
        XCTAssertEqual(okDict["action"] as? String, "mouse")
        XCTAssertEqual((okDict["echo"] as? [String: Any])?["x"] as? Double, 720.0)
    }
}
