import Foundation

/// 通信协议帧：
/// ```
/// 偏移 长度 内容
/// 0   2    magic 'M''S'
/// 2   1    kind: 0x01=JSON, 0x02=JPEG
/// 3   1    flags(保留, 0)
/// 4   4    payload 长度 uint32 小端
/// 8   N    payload
/// ```
public struct ProtocolFrame: Equatable {
    public enum Kind: UInt8 {
        case json = 0x01
        case jpeg = 0x02
    }

    public static let magic: [UInt8] = [0x4D, 0x53] // "MS"
    public static let headerSize = 8
    /// 单帧 payload 上限（防恶意长度）。
    public static let maxPayloadSize = 64 * 1024 * 1024

    public let kind: Kind
    public let payload: Data

    public init(kind: Kind, payload: Data) {
        self.kind = kind
        self.payload = payload
    }

    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.append(contentsOf: Self.magic)
        out.append(kind.rawValue)
        out.append(0)
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    public static func json(_ dict: [String: Any]) -> ProtocolFrame? {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else { return nil }
        return ProtocolFrame(kind: .json, payload: data)
    }

    public static func jpeg(_ data: Data) -> ProtocolFrame {
        ProtocolFrame(kind: .jpeg, payload: data)
    }
}

/// 头部解析结果。
struct FrameHeader: Equatable {
    let kind: ProtocolFrame.Kind
    let length: Int

    static func parse(_ data: Data) -> FrameHeader? {
        guard data.count >= ProtocolFrame.headerSize else { return nil }
        let base = data.startIndex
        guard data[base] == ProtocolFrame.magic[0], data[base + 1] == ProtocolFrame.magic[1] else { return nil }
        guard let kind = ProtocolFrame.Kind(rawValue: data[base + 2]) else { return nil }
        let b0 = UInt32(data[base + 4])
        let b1 = UInt32(data[base + 5])
        let b2 = UInt32(data[base + 6])
        let b3 = UInt32(data[base + 7])
        let length = Int(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
        return FrameHeader(kind: kind, length: length)
    }
}

/// 增量解码器：容忍分片（半个头）、粘包（多帧）、坏数据（逐字节滑动重新同步）。
public struct FrameDecoder {
    private var buffer = Data()
    /// 由于无法同步而丢弃的字节数（用于测试坏数据恢复）。
    public private(set) var droppedBytes = 0

    public init() {}

    public var bufferedBytes: Int { buffer.count }

    public mutating func feed(_ data: Data) -> [ProtocolFrame] {
        buffer.append(data)
        var frames: [ProtocolFrame] = []
        while buffer.count >= ProtocolFrame.headerSize {
            guard let header = FrameHeader.parse(buffer) else {
                buffer.removeFirst()
                droppedBytes += 1
                continue
            }
            if header.length > ProtocolFrame.maxPayloadSize {
                buffer.removeFirst()
                droppedBytes += 1
                continue
            }
            let total = ProtocolFrame.headerSize + header.length
            if buffer.count < total { break }
            let payload = buffer.subdata(in: (buffer.startIndex + ProtocolFrame.headerSize) ..< (buffer.startIndex + total))
            buffer.replaceSubrange(buffer.startIndex ..< (buffer.startIndex + total), with: Data())
            frames.append(ProtocolFrame(kind: header.kind, payload: payload))
        }
        return frames
    }

    public mutating func reset() {
        buffer.removeAll()
    }
}
