package com.macscreen.core.voice

import org.json.JSONObject
import java.io.ByteArrayOutputStream

/** HTTP 抽象（测试注入 FakeHttpPoster）。 */
interface HttpPoster {
    data class HttpResult(val statusCode: Int, val body: ByteArray, val errorMessage: String? = null)

    fun post(url: String, headers: Map<String, String>, contentType: String, body: ByteArray): HttpResult
}

/** 云端转写配置。 */
data class CloudTranscriberConfig(
    /** API 地址，如 https://api.openai.com/v1/audio/transcriptions */
    val url: String,
    val apiKey: String,
    /** 模型名，如 whisper-1 */
    val model: String,
    /** openai（multipart，OpenAI 兼容）或 raw（直接 POST wav 字节） */
    val style: String = "openai",
    /** 语言（可选，如 zh） */
    val language: String? = null,
    /** raw 风格响应 JSON 的字段名（可选，默认 text；为 null 则整体按文本处理） */
    val responseField: String? = "text",
)

/**
 * 云端语音转文字：把 WAV 上传到可配置的大模型转写 API（OpenAI 兼容 whisper 接口或自定义 raw 接口）。
 * 请求构造与响应解析为纯逻辑，可单测。
 */
class CloudTranscriber(private val config: CloudTranscriberConfig, private val http: HttpPoster) {

    /** 转写失败抛 TranscribeException。 */
    fun transcribe(wavBytes: ByteArray): String {
        val contentType: String
        val body: ByteArray
        if (config.style == "raw") {
            contentType = "audio/wav"
            body = wavBytes
        } else {
            contentType = "multipart/form-data; boundary=$BOUNDARY"
            body = buildMultipart(wavBytes)
        }
        val headers = if (config.apiKey.isNotEmpty()) {
            mapOf("Authorization" to "Bearer ${config.apiKey}")
        } else {
            emptyMap()
        }
        val result = http.post(config.url, headers, contentType, body)
        if (result.statusCode !in 200..299) {
            val detail = result.errorMessage ?: String(result.body, Charsets.UTF_8).take(300)
            throw TranscribeException("HTTP ${result.statusCode}: $detail")
        }
        return parseResponse(result.body)
    }

    /** 解析响应：JSON 取字段或整体当文本。 */
    fun parseResponse(body: ByteArray): String {
        val text = String(body, Charsets.UTF_8).trim()
        if (text.isEmpty()) throw TranscribeException("空响应")
        return if (text.startsWith("{")) {
            val obj = JSONObject(text)
            val field = config.responseField
            if (field != null) {
                if (!obj.has(field)) throw TranscribeException("响应缺少字段 $field")
                obj.getString(field)
            } else {
                text
            }
        } else {
            text
        }
    }

    /** 构造 OpenAI 兼容 multipart/form-data（确定性 boundary，可精确断言）。 */
    fun buildMultipart(wavBytes: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        fun part(name: String, value: String) {
            out.write("--$BOUNDARY\r\n".toByteArray(Charsets.UTF_8))
            out.write("Content-Disposition: form-data; name=\"$name\"\r\n\r\n".toByteArray(Charsets.UTF_8))
            out.write(value.toByteArray(Charsets.UTF_8))
            out.write("\r\n".toByteArray(Charsets.UTF_8))
        }
        part("model", config.model)
        config.language?.let { part("language", it) }
        out.write("--$BOUNDARY\r\n".toByteArray(Charsets.UTF_8))
        out.write("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".toByteArray(Charsets.UTF_8))
        out.write("Content-Type: audio/wav\r\n\r\n".toByteArray(Charsets.UTF_8))
        out.write(wavBytes)
        out.write("\r\n".toByteArray(Charsets.UTF_8))
        out.write("--$BOUNDARY--\r\n".toByteArray(Charsets.UTF_8))
        return out.toByteArray()
    }

    companion object {
        /** 固定 boundary：保证 multipart 结构可复现（HTTP 边界要求随机性仅为防冲突，这里内容可控）。 */
        const val BOUNDARY = "MacScreenFormBoundary7d1aC2e9F"
    }
}

class TranscribeException(message: String) : Exception(message)
