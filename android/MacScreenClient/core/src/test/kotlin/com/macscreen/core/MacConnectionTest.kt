package com.macscreen.core

import java.io.PipedInputStream
import java.io.PipedOutputStream
import kotlin.test.*

/** 管道 Transport：客户端流与"假服务器"线程直连。 */
class PipeTransport : Transport {
    val clientToServerIn = PipedInputStream(65536)
    val clientToServerOut = PipedOutputStream(clientToServerIn)
    val serverToClientIn = PipedInputStream(1 shl 20)
    val serverToClientOut = PipedOutputStream(serverToClientIn)

    private var input: PipedInputStream? = null
    private var output: PipedOutputStream? = null
    @Volatile private var closed = false

    override val remoteAddress: String? get() = "pipe://test"

    override fun open(host: String, port: Int, timeoutMs: Int) {
        input = serverToClientIn
        output = clientToServerOut
    }

    override fun read(buf: ByteArray, off: Int, len: Int, timeoutMs: Int): Int {
        val stream = input ?: return -1
        // 轮询等待数据（管道流无内建超时）；0=超时连接仍存活，-1=流结束
        val deadline = System.currentTimeMillis() + timeoutMs
        try {
            while (stream.available() <= 0) {
                if (closed) return -1
                if (System.currentTimeMillis() > deadline) return 0
                Thread.sleep(2)
            }
            val first = stream.read()
            if (first < 0) return -1
            buf[off] = first.toByte()
            var total = 1
            while (total < len && stream.available() > 0) {
                val b = stream.read()
                if (b < 0) break
                buf[off + total] = b.toByte()
                total++
            }
            return total
        } catch (e: java.io.IOException) {
            return -1
        }
    }

    override fun write(bytes: ByteArray) {
        output?.write(bytes)
        output?.flush()
    }

    override fun close() {
        closed = true
        try { clientToServerOut.close() } catch (_: Exception) {}
        try { serverToClientOut.close() } catch (_: Exception) {}
    }

    /** 假服务器读取客户端发来的帧（阻塞直到有数据）。 */
    fun serverReadFrames(): List<ProtocolFrame> {
        val decoder = FrameDecoder()
        val buf = ByteArray(16384)
        val deadline = System.currentTimeMillis() + 3000
        while (System.currentTimeMillis() < deadline) {
            if (clientToServerIn.available() > 0) {
                val n = clientToServerIn.read(buf)
                if (n > 0) {
                    val frames = decoder.feed(buf, 0, n)
                    if (frames.isNotEmpty()) return frames
                }
            } else {
                Thread.sleep(5)
            }
        }
        return emptyList()
    }

    /** 假服务器发送帧。 */
    fun serverWrite(frame: ProtocolFrame) {
        serverToClientOut.write(frame.encoded())
        serverToClientOut.flush()
    }
}

class MacConnectionTest {
    private class Listener : MacConnectionListener {
        val frames = mutableListOf<ByteArray>()
        val events = mutableListOf<ServerResponse>()
        var helloAck: ServerResponse.HelloAck? = null
        var screenInfo: ScreenInfo? = null
        var closed: String? = null

        override fun onHelloAck(ack: ServerResponse.HelloAck) { helloAck = ack }
        override fun onScreenInfo(info: ScreenInfo) { screenInfo = info }
        override fun onFrame(jpeg: ByteArray) { frames.add(jpeg) }
        override fun onEvent(response: ServerResponse) { events.add(response) }
        override fun onClosed(reason: String?) { closed = reason ?: "" }
    }

    @Test
    fun handshakeSuccessAndFrameFlow() {
        val transport = PipeTransport()
        val commands = mutableListOf<ProtocolFrame>()

        // 假服务器常驻线程。注意：PipedInputStream 的"读端"线程一旦死亡，
        // 写端再写会抛 "Read end dead"，因此服务器必须存活到测试收尾。
        val server = Thread {
            val decoder = FrameDecoder()
            val buf = ByteArray(16384)
            var helloReplied = false
            val deadline = System.currentTimeMillis() + 5000
            try {
                while (System.currentTimeMillis() < deadline) {
                    if (transport.clientToServerIn.available() > 0) {
                        val n = transport.clientToServerIn.read(buf)
                        if (n > 0) {
                            for (f in decoder.feed(buf, 0, n)) {
                                synchronized(commands) { commands.add(f) }
                                if (!helloReplied &&
                                    String(f.payload, Charsets.UTF_8).contains("\"op\":\"hello\"")) {
                                    helloReplied = true
                                    assertTrue(String(f.payload, Charsets.UTF_8).contains("\"token\":\"good\""))
                                    transport.serverWrite(ProtocolFrame.json(
                                        """{"op":"hello-ack","ok":true,"protocol":1,"serverName":"Mac","mock":false}""".toByteArray()))
                                    transport.serverWrite(ProtocolFrame.json(
                                        """{"op":"screen-info","width":1440,"height":900,"pixelWidth":800,"pixelHeight":500,"fps":10,"quality":0.6,"maxWidth":800,"mock":false}""".toByteArray()))
                                }
                            }
                        }
                    } else {
                        Thread.sleep(5)
                    }
                }
            } catch (_: java.io.IOException) {
                // 管道被关闭（测试收尾），正常退出
            }
        }.also { it.start() }

        val listener = Listener()
        val connection = MacConnection(transport)
        val ack = connection.connect("pipe", 1, "good", "测试手机", listener, timeoutMs = 3000)

        assertTrue(ack.ok)
        assertEquals("Mac", ack.serverName)
        assertTrue(connection.connected)

        // 假服务器发一帧 JPEG → 回调应收到
        transport.serverWrite(ProtocolFrame.jpeg(
            byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0x01, 0x02, 0xFF.toByte(), 0xD9.toByte())))
        val frameDeadline = System.currentTimeMillis() + 2000
        while (listener.frames.isEmpty() && System.currentTimeMillis() < frameDeadline) Thread.sleep(10)
        assertEquals(1, listener.frames.size)
        assertEquals(0xD8, listener.frames[0][1].toInt() and 0xFF)

        // 发送命令 → 假服务器应读到
        connection.send(Requests.ping())
        fun receivedPing(): Boolean = synchronized(commands) {
            commands.any { String(it.payload, Charsets.UTF_8).contains("\"op\":\"ping\"") }
        }
        val pingDeadline = System.currentTimeMillis() + 2000
        while (!receivedPing() && System.currentTimeMillis() < pingDeadline) Thread.sleep(10)
        assertTrue(receivedPing(), "假服务器应收到 ping 命令")

        connection.close()
        assertFalse(connection.connected)
        server.join(5000)
        assertEquals(2, synchronized(commands) { commands.size }, "应收到 hello + ping 两帧命令")
    }

    @Test
    fun wrongTokenRejected() {
        val transport = PipeTransport()
        val server = Thread {
            val frames = transport.serverReadFrames()
            assertTrue(frames.isNotEmpty())
            val helloJson = String(frames[0].payload, Charsets.UTF_8)
            assertTrue(helloJson.contains("\"token\":\"WRONG\""))
            transport.serverWrite(ProtocolFrame.json(
                """{"op":"error","code":"auth","message":"token 错误"}""".toByteArray()))
            try { Thread.sleep(200) } catch (_: Exception) {} // 让客户端读到错误
        }
        server.start()
        val listener = Listener()
        val connection = MacConnection(transport)
        val ex = assertFailsWith<SecurityException> {
            connection.connect("pipe", 1, "WRONG", "手机", listener, timeoutMs = 3000)
        }
        assertTrue(ex.message!!.contains("auth"))
        assertFalse(connection.connected, "鉴权失败不应保持连接")
        server.join(3000)
    }

    @Test
    fun handshakeTimeout() {
        val transport = PipeTransport()   // 服务器不回包
        val listener = Listener()
        val connection = MacConnection(transport)
        val ex = assertFailsWith<Exception> {
            connection.connect("pipe", 1, "good", "手机", listener, timeoutMs = 300)
        }
        assertTrue(ex is java.io.IOException || ex is IllegalStateException)
        assertFalse(connection.connected)
    }
}
