package com.macscreen.core.voice

import kotlin.test.*

class WavEncoderTest {
    @Test
    fun headerIsExact() {
        val samples = shortArrayOf(0, 1000, -1000, 32767, -32768)
        val wav = WavEncoder.encode(samples)
        val expectedLen = 44 + samples.size * 2
        assertEquals(expectedLen, wav.size)

        // RIFF / WAVE / fmt / data 标记
        assertEquals("RIFF", String(wav, 0, 4, Charsets.US_ASCII))
        assertEquals("WAVE", String(wav, 8, 4, Charsets.US_ASCII))
        assertEquals("fmt ", String(wav, 12, 4, Charsets.US_ASCII))
        assertEquals("data", String(wav, 36, 4, Charsets.US_ASCII))

        fun le32(off: Int): Int =
            (wav[off].toInt() and 0xFF) or ((wav[off + 1].toInt() and 0xFF) shl 8) or
            ((wav[off + 2].toInt() and 0xFF) shl 16) or ((wav[off + 3].toInt() and 0xFF) shl 24)

        fun le16(off: Int): Int = (wav[off].toInt() and 0xFF) or ((wav[off + 1].toInt() and 0xFF) shl 8)

        assertEquals(36 + samples.size * 2, le32(4))   // ChunkSize
        assertEquals(16, le32(16))                     // fmt 大小
        assertEquals(1, le16(20))                      // PCM
        assertEquals(1, le16(22))                      // 单声道
        assertEquals(16000, le32(24))                  // 采样率
        assertEquals(32000, le32(28))                  // 字节率 16000*1*2
        assertEquals(2, le16(32))                      // 块对齐
        assertEquals(16, le16(34))                     // 位深
        assertEquals(samples.size * 2, le32(40))       // data 大小
    }

    @Test
    fun sampleBytesAreLittleEndian() {
        val wav = WavEncoder.encode(shortArrayOf(0x1234, -2))
        // 0x1234 → 34 12
        assertEquals(0x34, wav[44])
        assertEquals(0x12, wav[45])
        // -2 → FE FF
        assertEquals(0xFE.toByte(), wav[46])
        assertEquals(0xFF.toByte(), wav[47])
    }

    @Test
    fun duration() {
        assertEquals(1.0, WavEncoder.durationSeconds(ShortArray(16000)), 1e-9)
        assertEquals(0.5, WavEncoder.durationSeconds(ShortArray(8000)), 1e-9)
    }
}

/** 记录请求的 Fake HttpPoster。 */
class FakeHttpPoster : HttpPoster {
    data class Call(val url: String, val headers: Map<String, String>, val contentType: String, val body: ByteArray)

    val calls = mutableListOf<Call>()
    var nextResult: HttpPoster.HttpResult = HttpPoster.HttpResult(200, """{"text":"识别结果"}""".toByteArray())

    override fun post(url: String, headers: Map<String, String>, contentType: String, body: ByteArray): HttpPoster.HttpResult {
        calls.add(Call(url, headers, contentType, body))
        return nextResult
    }
}

class CloudTranscriberTest {
    private fun config(style: String = "openai") = CloudTranscriberConfig(
        url = "https://api.example.com/v1/audio/transcriptions",
        apiKey = "sk-test",
        model = "whisper-1",
        style = style,
        language = "zh",
    )

    @Test
    fun openaiStyleBuildsMultipartAndParsesText() {
        val http = FakeHttpPoster()
        val transcriber = CloudTranscriber(config(), http)
        val wav = WavEncoder.encode(shortArrayOf(1, 2, 3))

        val text = transcriber.transcribe(wav)

        assertEquals("识别结果", text)
        assertEquals(1, http.calls.size)
        val call = http.calls[0]
        assertEquals("https://api.example.com/v1/audio/transcriptions", call.url)
        assertEquals("Bearer sk-test", call.headers["Authorization"])
        assertTrue(call.contentType.startsWith("multipart/form-data; boundary="))

        val body = String(call.body, Charsets.UTF_8)
        assertTrue(body.contains("name=\"model\"\r\n\r\nwhisper-1"), "multipart 应含 model 字段")
        assertTrue(body.contains("name=\"language\"\r\n\r\nzh"), "multipart 应含 language 字段")
        assertTrue(body.contains("filename=\"audio.wav\""))
        assertTrue(body.contains("--${CloudTranscriber.BOUNDARY}--"))
        // wav 字节应原样嵌入
        val wavStr = String(wav, Charsets.ISO_8859_1)
        val bodyIso = String(call.body, Charsets.ISO_8859_1)
        assertTrue(bodyIso.contains(wavStr), "multipart 应包含完整 WAV 字节")
    }

    @Test
    fun rawStylePostsWavDirectly() {
        val http = FakeHttpPoster()
        val transcriber = CloudTranscriber(config(style = "raw"), http)
        val wav = WavEncoder.encode(shortArrayOf(7))
        transcriber.transcribe(wav)
        val call = http.calls[0]
        assertEquals("audio/wav", call.contentType)
        assertTrue(call.body.contentEquals(wav))
    }

    @Test
    fun parsesAlternativeResponseField() {
        val transcriber = CloudTranscriber(
            config().copy(responseField = "result"),
            FakeHttpPoster().apply { nextResult = HttpPoster.HttpResult(200, """{"result":"另一种字段"}""".toByteArray()) },
        )
        assertEquals("另一种字段", transcriber.transcribe(ByteArray(10)))
    }

    @Test
    fun plainTextResponseAccepted() {
        val transcriber = CloudTranscriber(
            config().copy(responseField = null),
            FakeHttpPoster().apply { nextResult = HttpPoster.HttpResult(200, "纯文本结果".toByteArray()) },
        )
        assertEquals("纯文本结果", transcriber.transcribe(ByteArray(10)))
    }

    @Test
    fun httpErrorThrows() {
        val transcriber = CloudTranscriber(
            config(),
            FakeHttpPoster().apply { nextResult = HttpPoster.HttpResult(401, """{"error":"bad key"}""".toByteArray()) },
        )
        val ex = assertFailsWith<TranscribeException> { transcriber.transcribe(ByteArray(10)) }
        assertTrue(ex.message!!.contains("401"))
    }

    @Test
    fun missingFieldThrows() {
        val transcriber = CloudTranscriber(
            config(),
            FakeHttpPoster().apply { nextResult = HttpPoster.HttpResult(200, """{"unexpected":1}""".toByteArray()) },
        )
        assertFailsWith<TranscribeException> { transcriber.transcribe(ByteArray(10)) }
    }
}
