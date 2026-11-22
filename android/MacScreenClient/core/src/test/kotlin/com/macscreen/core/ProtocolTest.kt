package com.macscreen.core

import kotlin.test.*

class ProtocolTest {
    @Test
    fun encodeMatchesSwiftBytes() {
        // 互操作向量：Swift 端 ProtocolFrame.json(["op":"ping"]).encoded() 的精确字节
        val payload = """{"op":"ping"}""".toByteArray(Charsets.UTF_8)
        val expected = byteArrayOf(
            0x4D, 0x53, 0x01, 0x00,
            payload.size.toByte(), 0x00, 0x00, 0x00,
        ) + payload
        val frame = ProtocolFrame.json(Requests.ping())
        assertEquals(expected.toList(), frame.encoded().toList())
    }

    @Test
    fun roundtrip() {
        val frame = ProtocolFrame.jpeg(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0x01, 0xFF.toByte(), 0xD9.toByte()))
        val decoder = FrameDecoder()
        val frames = decoder.feed(frame.encoded())
        assertEquals(1, frames.size)
        assertEquals(frame, frames[0])
    }

    @Test
    fun multipleFramesInOneChunk() {
        val f1 = ProtocolFrame.json("""{"a":1}""".toByteArray())
        val f2 = ProtocolFrame.jpeg(byteArrayOf(1, 2, 3))
        val decoder = FrameDecoder()
        val frames = decoder.feed(f1.encoded() + f2.encoded())
        assertEquals(listOf(f1, f2), frames)
    }

    @Test
    fun splitAcrossChunks() {
        val payload = ByteArray(200) { (it % 251).toByte() }
        val frame = ProtocolFrame(ProtocolFrame.Kind.JSON, payload)
        val bytes = frame.encoded()
        val decoder = FrameDecoder()
        val collected = mutableListOf<ProtocolFrame>()
        for (b in bytes) {
            collected += decoder.feed(byteArrayOf(b))
        }
        assertEquals(listOf(frame), collected)
    }

    @Test
    fun corruptMagicResyncs() {
        val good = ProtocolFrame.json("""{"a":1}""".toByteArray()).encoded()
        val decoder = FrameDecoder()
        val frames = decoder.feed(byteArrayOf(0x00, 0x11, 0x22) + good)
        assertEquals(1, frames.size)
        assertEquals(3, decoder.droppedBytes)
    }

    @Test
    fun oversizedLengthDropped() {
        val evil = byteArrayOf(0x4D, 0x53, 0x01, 0x00, 0x00, 0x00, 0x00, 0x0A.toByte()) // 100MB
        val good = ProtocolFrame.json("""{"a":1}""".toByteArray()).encoded()
        val decoder = FrameDecoder()
        val frames = decoder.feed(evil + good)
        assertEquals(1, frames.size, "超长帧应被丢弃，后续帧可解出")
        assertTrue(decoder.droppedBytes > 0)
    }

    @Test
    fun jpegFrameHeaderKind() {
        val header = FrameHeader.parse(
            ProtocolFrame.jpeg(ByteArray(3)).encoded(), 0,
            ProtocolFrame.HEADER_SIZE + 3,
        )
        assertNotNull(header)
        assertEquals(ProtocolFrame.Kind.JPEG, header.kind)
        assertEquals(3, header.length)
    }
}
