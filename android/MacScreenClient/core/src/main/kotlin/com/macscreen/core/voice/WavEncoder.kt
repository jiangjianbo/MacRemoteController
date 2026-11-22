package com.macscreen.core.voice

import java.io.ByteArrayOutputStream

/** PCM16LE 单声道 → WAV 字节封装（供云端转写 API 上传）。 */
object WavEncoder {
    const val SAMPLE_RATE = 16000
    const val CHANNELS = 1

    /**
     * @param pcmShorts PCM 采样（16bit 小端、单声道）
     * @return 完整 WAV 文件字节（44 字节头 + data）
     */
    fun encode(pcmShorts: ShortArray): ByteArray {
        val out = ByteArrayOutputStream(pcmShorts.size * 2 + 44)
        val dataLen = pcmShorts.size * 2

        // RIFF 头
        out.write("RIFF".toByteArray(Charsets.US_ASCII))
        writeIntLE(out, 36 + dataLen)          // ChunkSize
        out.write("WAVE".toByteArray(Charsets.US_ASCII))
        // fmt 子块
        out.write("fmt ".toByteArray(Charsets.US_ASCII))
        writeIntLE(out, 16)                     // Subchunk1Size (PCM)
        writeShortLE(out, 1)                    // AudioFormat = PCM
        writeShortLE(out, CHANNELS)
        writeIntLE(out, SAMPLE_RATE)            // SampleRate
        writeIntLE(out, SAMPLE_RATE * CHANNELS * 2)  // ByteRate = SR * ch * bytesPerSample
        writeShortLE(out, CHANNELS * 2)         // BlockAlign
        writeShortLE(out, 16)                   // BitsPerSample
        // data 子块
        out.write("data".toByteArray(Charsets.US_ASCII))
        writeIntLE(out, dataLen)
        for (s in pcmShorts) {
            val v = s.toInt() and 0xFFFF
            out.write(v and 0xFF)
            out.write((v shr 8) and 0xFF)
        }
        return out.toByteArray()
    }

    /** 时长（秒）。 */
    fun durationSeconds(pcmShorts: ShortArray): Double = pcmShorts.size.toDouble() / SAMPLE_RATE

    private fun writeIntLE(out: ByteArrayOutputStream, v: Int) {
        out.write(v and 0xFF)
        out.write((v shr 8) and 0xFF)
        out.write((v shr 16) and 0xFF)
        out.write((v shr 24) and 0xFF)
    }

    private fun writeShortLE(out: ByteArrayOutputStream, v: Int) {
        out.write(v and 0xFF)
        out.write((v shr 8) and 0xFF)
    }
}
