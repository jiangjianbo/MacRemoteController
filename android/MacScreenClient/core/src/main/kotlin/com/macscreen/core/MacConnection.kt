package com.macscreen.core

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket

/** 传输抽象（测试用管道流注入）。 */
interface Transport {
    fun open(host: String, port: Int, timeoutMs: Int)
    /** 阻塞读；返回字节数，0 表示超时无数据（连接仍存活），-1 表示流结束。 */
    fun read(buf: ByteArray, off: Int, len: Int, timeoutMs: Int): Int
    fun write(bytes: ByteArray)
    fun close()
    val remoteAddress: String?
}

/** 真实 TCP 实现。 */
class SocketTransport : Transport {
    private var socket: Socket? = null
    private var input: InputStream? = null
    private var output: OutputStream? = null

    override val remoteAddress: String?
        get() = socket?.remoteSocketAddress?.toString()

    override fun open(host: String, port: Int, timeoutMs: Int) {
        val s = Socket()
        s.tcpNoDelay = true
        s.connect(InetSocketAddress(host, port), timeoutMs)
        socket = s
        input = s.getInputStream()
        output = s.getOutputStream()
    }

    override fun read(buf: ByteArray, off: Int, len: Int, timeoutMs: Int): Int {
        val s = socket ?: return -1
        return try {
            s.soTimeout = timeoutMs.coerceAtLeast(1)
            input?.read(buf, off, len) ?: -1
        } catch (e: java.net.SocketTimeoutException) {
            0
        } catch (e: IOException) {
            -1
        }
    }

    override fun write(bytes: ByteArray) {
        output?.let {
            it.write(bytes)
            it.flush()
        }
    }

    override fun close() {
        try { socket?.close() } catch (_: IOException) {}
        socket = null
    }
}

/** 连接监听器。 */
interface MacConnectionListener {
    /** 已鉴权握手完成。 */
    fun onHelloAck(ack: ServerResponse.HelloAck)
    /** 收到屏幕信息。 */
    fun onScreenInfo(info: ScreenInfo)
    /** 收到 JPEG 帧。 */
    fun onFrame(jpeg: ByteArray)
    /** 收到其他 JSON 事件。 */
    fun onEvent(response: ServerResponse)
    /** 连接断开。 */
    fun onClosed(reason: String?)
}

/**
 * 手机端连接客户端：读线程 + 帧解码 + 事件分发。
 * 握手（hello/鉴权）为同步阻塞，业务事件回调在 IO 线程。
 */
class MacConnection(private val transport: Transport) {

    @Volatile var connected = false
        private set

    private var reader: Thread? = null
    private val decoder = FrameDecoder()
    private val lock = Object()
    // 发送可能来自多个线程（握手线程、App 的发送线程池），加锁保证整帧原子写出
    private val writeLock = Object()

    /** 阻塞连接并完成 hello 鉴权。失败抛 IOException/SecurityException。 */
    fun connect(host: String, port: Int, token: String, deviceName: String,
                listener: MacConnectionListener, timeoutMs: Int = 5000): ServerResponse.HelloAck {
        synchronized(lock) {
            if (connected) throw IllegalStateException("已连接")
            transport.open(host, port, timeoutMs)
            transport.write(ProtocolFrame.json(Requests.hello(token, deviceName)).encoded())

            // 同步等待 hello-ack / error / 断开（复用同一解码器，多余帧缓存）
            var ack: ServerResponse.HelloAck? = null
            val helloDeadline = System.currentTimeMillis() + timeoutMs
            while (ack == null && System.currentTimeMillis() < helloDeadline) {
                val budget = (helloDeadline - System.currentTimeMillis()).toInt().coerceIn(1, 250)
                val frames = readSomeFrames(budget)
                for (frame in frames) {
                    when (frame.kind) {
                        ProtocolFrame.Kind.JSON -> when (val resp = ServerResponse.parse(frame.payload)) {
                            is ServerResponse.HelloAck -> {
                                if (resp.ok) ack = resp else throw SecurityException("鉴权失败：服务器拒绝 hello")
                            }
                            is ServerResponse.Error -> {
                                transport.close()
                                throw SecurityException("鉴权失败：${resp.code} ${resp.message}")
                            }
                            else -> { /* 握手期间的其他事件，握手完成后交给回调 */ }
                        }
                        ProtocolFrame.Kind.JPEG -> { /* 握手期间不应有帧，忽略 */ }
                    }
                    if (ack != null) break
                }
                if (frames.isEmpty()) Thread.sleep(5)  // 避免忙转
            }
            val helloAck = ack ?: run {
                transport.close()
                throw IOException("握手超时")
            }
            connected = true
            startReader(listener)
            return helloAck
        }
    }

    private fun readSomeFrames(timeoutMs: Int): List<ProtocolFrame> {
        val buf = ByteArray(16 * 1024)
        val n = try {
            transport.read(buf, 0, buf.size, timeoutMs)
        } catch (e: Exception) {
            -1
        }
        return if (n > 0) decoder.feed(buf, 0, n) else emptyList()
    }

    private fun startReader(listener: MacConnectionListener) {
        reader = Thread {
            val buf = ByteArray(32 * 1024)
            var closeReason = "连接关闭"
            while (connected) {
                val n = try {
                    transport.read(buf, 0, buf.size, 15000)
                } catch (e: Exception) {
                    null
                }
                if (n == null) {
                    closeReason = "读异常"
                    break
                }
                if (n < 0) break
                // n == 0：空闲超时，连接仍存活，继续等下一批数据
                // 解析/回调异常不允许杀死进程：转为优雅断开
                try {
                    for (frame in decoder.feed(buf, 0, n)) {
                        when (frame.kind) {
                            ProtocolFrame.Kind.JPEG -> listener.onFrame(frame.payload)
                            ProtocolFrame.Kind.JSON -> {
                                when (val resp = ServerResponse.parse(frame.payload)) {
                                    is ServerResponse.HelloAck -> listener.onHelloAck(resp)
                                    is ServerResponse.ScreenInfoEvent -> listener.onScreenInfo(resp.info)
                                    else -> listener.onEvent(resp)
                                }
                            }
                        }
                    }
                } catch (t: Throwable) {
                    closeReason = "处理数据出错：${t.message}"
                    break
                }
            }
            connected = false
            transport.close()
            try {
                listener.onClosed(closeReason)
            } catch (_: Throwable) {}
        }.also { it.name = "macscreen-reader"; it.isDaemon = true; it.start() }
    }

    /** 发送 JSON 请求（线程安全：加锁保证整帧不被并发写交错）。 */
    fun send(requestBytes: ByteArray) {
        if (!connected) throw IOException("未连接")
        val frame = ProtocolFrame.json(requestBytes).encoded()
        synchronized(writeLock) { transport.write(frame) }
    }

    fun close() {
        connected = false
        transport.close()
    }
}
