package com.macscreen.core

/**
 * 通信协议帧（与 macOS 端一致）：
 * ```
 * 偏移 长度 内容
 * 0   2    magic 'M''S'
 * 2   1    kind: 0x01=JSON, 0x02=JPEG
 * 3   1    flags(保留, 0)
 * 4   4    payload 长度 uint32 小端
 * 8   N    payload
 * ```
 */
data class ProtocolFrame(val kind: Kind, val payload: ByteArray) {
    enum class Kind(val value: Int) {
        JSON(0x01), JPEG(0x02);

        companion object {
            fun from(value: Int): Kind? = entries.firstOrNull { it.value == value }
        }
    }

    companion object {
        const val HEADER_SIZE = 8
        const val MAX_PAYLOAD = 64 * 1024 * 1024

        fun json(jsonBytes: ByteArray): ProtocolFrame = ProtocolFrame(Kind.JSON, jsonBytes)

        fun jpeg(bytes: ByteArray): ProtocolFrame = ProtocolFrame(Kind.JPEG, bytes)
    }

    fun encoded(): ByteArray {
        val out = ByteArray(HEADER_SIZE + payload.size)
        out[0] = 0x4D; out[1] = 0x53
        out[2] = kind.value.toByte()
        out[3] = 0
        val len = payload.size
        out[4] = (len and 0xFF).toByte()
        out[5] = ((len shr 8) and 0xFF).toByte()
        out[6] = ((len shr 16) and 0xFF).toByte()
        out[7] = ((len shr 24) and 0xFF).toByte()
        payload.copyInto(out, HEADER_SIZE)
        return out
    }

    override fun equals(other: Any?): Boolean =
        other is ProtocolFrame && other.kind == kind && other.payload.contentEquals(payload)

    override fun hashCode(): Int = kind.hashCode() * 31 + payload.contentHashCode()
}

/** 头部解析结果。 */
data class FrameHeader(val kind: ProtocolFrame.Kind, val length: Int) {
    companion object {
        fun parse(buf: ByteArray, offset: Int = 0, available: Int): FrameHeader? {
            if (available < ProtocolFrame.HEADER_SIZE) return null
            if (buf[offset] != 0x4D.toByte() || buf[offset + 1] != 0x53.toByte()) return null
            val kind = ProtocolFrame.Kind.from(buf[offset + 2].toInt() and 0xFF) ?: return null
            val len = (buf[offset + 4].toInt() and 0xFF) or
                      ((buf[offset + 5].toInt() and 0xFF) shl 8) or
                      ((buf[offset + 6].toInt() and 0xFF) shl 16) or
                      ((buf[offset + 7].toInt() and 0xFF) shl 24)
            return FrameHeader(kind, len)
        }
    }
}

/** 增量解码器：容忍分片、粘包、坏数据（逐字节滑动重同步）。 */
class FrameDecoder {
    private var buffer = ByteArray(0)
    /** 因无法同步而丢弃的字节数。 */
    var droppedBytes = 0
        private set

    val bufferedBytes: Int get() = buffer.size

    fun feed(data: ByteArray, offset: Int = 0, length: Int = data.size - offset): List<ProtocolFrame> {
        val merged = ByteArray(buffer.size + length)
        buffer.copyInto(merged)
        data.copyInto(merged, buffer.size, offset, offset + length)
        buffer = merged

        val frames = mutableListOf<ProtocolFrame>()
        while (buffer.size >= ProtocolFrame.HEADER_SIZE) {
            val header = FrameHeader.parse(buffer, 0, buffer.size)
            if (header == null) {
                buffer = buffer.copyOfRange(1, buffer.size)
                droppedBytes++
                continue
            }
            if (header.length > ProtocolFrame.MAX_PAYLOAD) {
                buffer = buffer.copyOfRange(1, buffer.size)
                droppedBytes++
                continue
            }
            val total = ProtocolFrame.HEADER_SIZE + header.length
            if (buffer.size < total) break
            val payload = buffer.copyOfRange(ProtocolFrame.HEADER_SIZE, total)
            buffer = buffer.copyOfRange(total, buffer.size)
            frames.add(ProtocolFrame(header.kind, payload))
        }
        return frames
    }

    fun reset() {
        buffer = ByteArray(0)
    }
}
