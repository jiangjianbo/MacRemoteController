package com.macscreen.core

import org.json.JSONObject

/** 窗口信息（Mac 端下发的 windows 事件元素）。 */
data class WindowInfo(
    val id: Long,
    val title: String,
    val appName: String,
    val x: Double, val y: Double, val w: Double, val h: Double,
    val onScreen: Boolean,
) {
    companion object {
        fun fromJson(o: JSONObject): WindowInfo = WindowInfo(
            id = o.optLong("id", -1),
            title = o.optString("title", ""),
            appName = o.optString("appName", ""),
            x = o.optDouble("x", 0.0), y = o.optDouble("y", 0.0),
            w = o.optDouble("w", 0.0), h = o.optDouble("h", 0.0),
            onScreen = o.optBoolean("onScreen", true),
        )
    }
}

/** 屏幕信息（screen-info 事件）。 */
data class ScreenInfo(
    val widthPts: Double, val heightPts: Double,
    val pixelWidth: Int, val pixelHeight: Int,
    val fps: Int, val quality: Double, val maxWidth: Int,
    val mock: Boolean,
) {
    companion object {
        fun fromJson(o: JSONObject): ScreenInfo = ScreenInfo(
            widthPts = o.optDouble("width", 0.0), heightPts = o.optDouble("height", 0.0),
            pixelWidth = o.optInt("pixelWidth", 0), pixelHeight = o.optInt("pixelHeight", 0),
            fps = o.optInt("fps", 0), quality = o.optDouble("quality", 0.0),
            maxWidth = o.optInt("maxWidth", 0), mock = o.optBoolean("mock", false),
        )
    }
}

/** Mac 端响应（JSON 控制事件）。 */
sealed class ServerResponse {
    abstract val op: String
    /** 请求 id 回带。 */
    var requestId: Any? = null

    data class HelloAck(
        val ok: Boolean, val protocolVersion: Int,
        val serverName: String, val mock: Boolean,
    ) : ServerResponse() { override val op get() = "hello-ack" }

    data class Error(val code: String, val message: String) : ServerResponse() { override val op get() = "error" }

    class Pong : ServerResponse() { override val op get() = "pong" }

    data class Status(val fields: JSONObject) : ServerResponse() { override val op get() = "status" }

    data class Windows(val list: List<WindowInfo>) : ServerResponse() { override val op get() = "windows" }

    data class ScreenInfoEvent(val info: ScreenInfo) : ServerResponse() { override val op get() = "screen-info" }

    data class CaptureState(val enabled: Boolean, val permission: Boolean, val mock: Boolean) :
        ServerResponse() { override val op get() = "capture-state" }

    data class Ok(val action: String, val echo: JSONObject) : ServerResponse() { override val op get() = "ok" }

    data class Unknown(override val op: String, val fields: JSONObject) : ServerResponse()

    companion object {
        fun parse(bytes: ByteArray): ServerResponse {
            val obj = JSONObject(String(bytes, Charsets.UTF_8))
            return parse(obj)
        }

        fun parse(obj: JSONObject): ServerResponse {
            val op = obj.optString("op", "")
            val resp = when (op) {
                "hello-ack" -> HelloAck(
                    ok = obj.optBoolean("ok", false),
                    protocolVersion = obj.optInt("protocol", 0),
                    serverName = obj.optString("serverName", ""),
                    mock = obj.optBoolean("mock", false),
                )
                "error" -> Error(obj.optString("code", ""), obj.optString("message", ""))
                "pong" -> Pong()
                "status" -> Status(obj)
                "windows" -> {
                    val arr = obj.optJSONArray("list") ?: org.json.JSONArray()
                    Windows((0 until arr.length()).map { WindowInfo.fromJson(arr.getJSONObject(it)) })
                }
                "screen-info" -> ScreenInfoEvent(ScreenInfo.fromJson(obj))
                "capture-state" -> CaptureState(
                    obj.optBoolean("enabled", false),
                    obj.optBoolean("permission", false),
                    obj.optBoolean("mock", false),
                )
                "ok" -> Ok(obj.optString("action", ""), obj.optJSONObject("echo") ?: JSONObject())
                else -> Unknown(op, obj)
            }
            if (obj.has("id")) resp.requestId = obj.get("id")
            return resp
        }
    }
}

/** 请求构造器（手机 → Mac）。 */
object Requests {
    fun hello(token: String, deviceName: String): ByteArray =
        JSONObject().put("op", "hello").put("token", token).put("deviceName", deviceName)
            .toString().toByteArray()

    fun ping(): ByteArray = JSONObject().put("op", "ping").toString().toByteArray()

    fun getStatus(): ByteArray = JSONObject().put("op", "get-status").toString().toByteArray()

    fun subscribe(video: Boolean): ByteArray =
        JSONObject().put("op", "subscribe").put("video", video).toString().toByteArray()

    fun setCapture(enabled: Boolean? = null, fps: Int? = null, quality: Double? = null, maxWidth: Int? = null): ByteArray {
        val o = JSONObject().put("op", "set-capture")
        enabled?.let { o.put("enabled", it) }
        fps?.let { o.put("fps", it) }
        quality?.let { o.put("quality", it) }
        maxWidth?.let { o.put("maxWidth", it) }
        return o.toString().toByteArray()
    }

    fun listWindows(): ByteArray = JSONObject().put("op", "list-windows").toString().toByteArray()

    fun activateWindow(windowId: Long): ByteArray =
        JSONObject().put("op", "activate-window").put("windowId", windowId).toString().toByteArray()

    fun mouse(action: String, nx: Double, ny: Double): ByteArray =
        JSONObject().put("op", "mouse").put("action", action)
            .put("x", nx).put("y", ny).toString().toByteArray()

    fun scroll(dx: Double, dy: Double): ByteArray =
        JSONObject().put("op", "scroll").put("dx", dx).put("dy", dy).toString().toByteArray()

    fun typeText(text: String, submit: Boolean = false): ByteArray =
        JSONObject().put("op", "type-text").put("text", text).put("submit", submit).toString().toByteArray()

    fun pressKey(key: String, modifiers: List<String> = emptyList()): ByteArray =
        JSONObject().put("op", "press-key").put("key", key)
            .put("modifiers", org.json.JSONArray(modifiers)).toString().toByteArray()
}

/** macscreen://connect 二维码内容解析。 */
object PairingUri {
    data class Info(val host: String, val port: Int, val token: String, val name: String)

    /** 解析 macscreen://connect?host=..&port=..&token=..&name=..；非法返回 null。 */
    fun parse(content: String): Info? {
        if (!content.startsWith("macscreen://connect?")) return null
        val query = content.substringAfter("?")
        val params = query.split("&")
            .mapNotNull {
                val idx = it.indexOf('=')
                if (idx <= 0) null else
                    java.net.URLDecoder.decode(it.substring(0, idx), "UTF-8") to
                    java.net.URLDecoder.decode(it.substring(idx + 1), "UTF-8")
            }
            .toMap()
        val host = params["host"] ?: return null
        val port = params["port"]?.toIntOrNull() ?: return null
        val token = params["token"] ?: return null
        return Info(host, port, token, params["name"] ?: "Mac")
    }
}
