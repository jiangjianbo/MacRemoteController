import Foundation

/// PCM16LE 单声道 → WAV 字节封装（供云端转写 API 上传）。移植自 Android WavEncoder。
public enum WavEncoder {
    public static let sampleRate = 16000
    public static let channels = 1

    /// pcm：16bit 单声道采样；返回完整 WAV 文件字节（44 字节头 + data）。
    public static func encode(pcm: [Int16]) -> Data {
        var out = Data(capacity: pcm.count * 2 + 44)
        let dataLen = pcm.count * 2

        out.append(Data("RIFF".utf8))
        appendIntLE(&out, 36 + dataLen)
        out.append(Data("WAVE".utf8))
        out.append(Data("fmt ".utf8))
        appendIntLE(&out, 16)
        appendShortLE(&out, 1)                    // AudioFormat = PCM
        appendShortLE(&out, channels)
        appendIntLE(&out, sampleRate)
        appendIntLE(&out, sampleRate * channels * 2) // ByteRate
        appendShortLE(&out, channels * 2)            // BlockAlign
        appendShortLE(&out, 16)                      // BitsPerSample
        out.append(Data("data".utf8))
        appendIntLE(&out, dataLen)
        for s in pcm {
            let v = UInt16(bitPattern: s)
            out.append(UInt8(v & 0xFF))
            out.append(UInt8(v >> 8))
        }
        return out
    }

    public static func durationSeconds(pcmCount: Int) -> Double {
        Double(pcmCount) / Double(sampleRate)
    }

    static func appendIntLE(_ out: inout Data, _ v: Int) {
        out.append(UInt8(v & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 24) & 0xFF))
    }

    static func appendShortLE(_ out: inout Data, _ v: Int) {
        out.append(UInt8(v & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
    }
}

/// 云端转写配置（OpenAI 兼容 whisper 接口或自定义 raw 接口）。
public struct CloudTranscriberConfig {
    public let url: String
    public let apiKey: String
    public let model: String
    /// "openai"（multipart）或 "raw"（直接 POST WAV 字节）
    public let style: String
    public let language: String?
    public let responseField: String?

    public init(url: String, apiKey: String, model: String, style: String = "openai",
                language: String? = nil, responseField: String? = "text") {
        self.url = url; self.apiKey = apiKey; self.model = model
        self.style = style; self.language = language; self.responseField = responseField
    }
}

public enum TranscribeError: Error, LocalizedError {
    case http(Int, String)
    case emptyResponse
    case missingField(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let detail): return "HTTP \(code): \(detail)"
        case .emptyResponse: return "空响应"
        case .missingField(let f): return "响应缺少字段 \(f)"
        }
    }
}

/// 转写请求构造与响应解析（纯逻辑，可单测）；HTTP 发送由 app 层 URLSession 完成。
public enum CloudCodec {
    /// 固定 boundary：multipart 结构可复现、可精确断言。
    public static let boundary = "MacScreenFormBoundary7d1aC2e9F"

    public static func contentType(_ config: CloudTranscriberConfig) -> String {
        config.style == "raw" ? "audio/wav" : "multipart/form-data; boundary=\(boundary)"
    }

    public static func buildBody(_ config: CloudTranscriberConfig, wav: Data) -> Data {
        if config.style == "raw" { return wav }
        var out = Data()
        func part(name: String, value: String) {
            out.append(Data("--\(boundary)\r\n".utf8))
            out.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            out.append(Data(value.utf8))
            out.append(Data("\r\n".utf8))
        }
        part(name: "model", value: config.model)
        if let language = config.language { part(name: "language", value: language) }
        out.append(Data("--\(boundary)\r\n".utf8))
        out.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
        out.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        out.append(wav)
        out.append(Data("\r\n".utf8))
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }

    public static func authHeader(_ config: CloudTranscriberConfig) -> String? {
        config.apiKey.isEmpty ? nil : "Bearer \(config.apiKey)"
    }

    /// 解析响应：JSON 取 responseField 字段，或整体按文本。
    public static func parseResponse(_ body: Data, responseField: String?) throws -> String {
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw TranscribeError.emptyResponse }
        guard text.hasPrefix("{") else { return text }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return text
        }
        if let field = responseField {
            guard let value = obj[field] as? String else { throw TranscribeError.missingField(field) }
            return value
        }
        return text
    }
}
