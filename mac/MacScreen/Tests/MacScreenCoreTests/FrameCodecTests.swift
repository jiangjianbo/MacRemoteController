import XCTest
@testable import MacScreenCore

final class FrameCodecTests: XCTestCase {
    func testEncodeDecodeRoundtrip() throws {
        let payload = Data("{\"op\":\"ping\"}".utf8)
        let frame = ProtocolFrame(kind: .json, payload: payload)
        let encoded = frame.encoded()

        XCTAssertEqual(encoded.prefix(2), Data([0x4D, 0x53]))
        XCTAssertEqual(encoded[encoded.startIndex + 2], 0x01)
        // 长度小端
        XCTAssertEqual(encoded[encoded.startIndex + 4], UInt8(payload.count))
        XCTAssertEqual(encoded[encoded.startIndex + 7], 0)

        var decoder = FrameDecoder()
        let frames = decoder.feed(encoded)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], frame)
    }

    func testMultipleFramesInOneChunk() {
        let f1 = ProtocolFrame(kind: .json, payload: Data("{}".utf8))
        let f2 = ProtocolFrame.jpeg(Data([0xFF, 0xD8, 0xAB, 0xFF, 0xD9]))
        let blob = f1.encoded() + f2.encoded()
        var decoder = FrameDecoder()
        let frames = decoder.feed(blob)
        XCTAssertEqual(frames, [f1, f2])
    }

    func testSplitAcrossChunks() {
        let payload = Data((0..<100).map { _ in UInt8.random(in: 0...255) })
        let frame = ProtocolFrame(kind: .json, payload: payload)
        let encoded = frame.encoded()
        var decoder = FrameDecoder()
        // 逐字节喂入
        var collected: [ProtocolFrame] = []
        for byte in encoded {
            collected += decoder.feed(Data([byte]))
        }
        XCTAssertEqual(collected, [frame])
    }

    func testCorruptMagicResyncs() {
        let good = ProtocolFrame(kind: .json, payload: Data("{\"a\":1}".utf8)).encoded()
        var decoder = FrameDecoder()
        // 前置 3 个垃圾字节
        let garbage = Data([0x00, 0x11, 0x22])
        let frames = decoder.feed(garbage + good)
        XCTAssertEqual(frames.count, 1, "应跳过垃圾字节后解出 1 帧")
        XCTAssertEqual(decoder.droppedBytes, 3)
    }

    func testOversizedLengthDropped() {
        var decoder = FrameDecoder()
        // 声称 100MB payload
        var evil = Data([0x4D, 0x53, 0x01, 0x00])
        var len = UInt32(100 * 1024 * 1024).littleEndian
        withUnsafeBytes(of: &len) { evil.append(contentsOf: $0) }
        let good = ProtocolFrame(kind: .json, payload: Data("{}".utf8)).encoded()
        let frames = decoder.feed(evil + good)
        XCTAssertEqual(frames.count, 1, "超长帧应被丢弃，后续正常帧可解出")
        XCTAssertGreaterThan(decoder.droppedBytes, 0)
    }

    func testJSONAndJPEGHelpers() throws {
        let jsonFrame = ProtocolFrame.json(["op": "ping", "id": 7])
        XCTAssertNotNil(jsonFrame)
        XCTAssertEqual(jsonFrame?.kind, .json)
        let jpegFrame = ProtocolFrame.jpeg(Data([1, 2, 3]))
        XCTAssertEqual(jpegFrame.kind, .jpeg)
    }

    func testDecoderReset() {
        var decoder = FrameDecoder()
        let half = Data([0x4D, 0x53, 0x01, 0x00])
        _ = decoder.feed(half)
        XCTAssertEqual(decoder.bufferedBytes, 4)
        decoder.reset()
        XCTAssertEqual(decoder.bufferedBytes, 0)
    }
}
