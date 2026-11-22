package com.macscreen.core

import org.json.JSONObject
import kotlin.test.*

class MessagesTest {
    @Test
    fun parseHelloAck() {
        val json = """{"op":"hello-ack","ok":true,"protocol":1,"serverName":"TestMac","mock":true,"id":7}"""
        val resp = ServerResponse.parse(json.toByteArray(Charsets.UTF_8))
        assertTrue(resp is ServerResponse.HelloAck)
        assertTrue(resp.ok)
        assertEquals(1, resp.protocolVersion)
        assertEquals("TestMac", resp.serverName)
        // org.json 把无小数点的数字解析为 Integer，统一按数值比较
        assertEquals(7L, (resp.requestId as? Number)?.toLong())
    }

    @Test
    fun parseError() {
        val resp = ServerResponse.parse("""{"op":"error","code":"auth","message":"token 错误"}""".toByteArray())
        assertTrue(resp is ServerResponse.Error)
        assertEquals("auth", resp.code)
        assertEquals("token 错误", resp.message)
    }

    @Test
    fun parseWindows() {
        val json = """{"op":"windows","list":[
            {"id":1,"title":"终端","appName":"Terminal","x":0,"y":0,"w":800,"h":600,"onScreen":true},
            {"id":2,"title":"Notes","appName":"Notes","x":10,"y":20,"w":300,"h":200,"onScreen":false}]}"""
        val resp = ServerResponse.parse(json.toByteArray())
        assertTrue(resp is ServerResponse.Windows)
        assertEquals(2, resp.list.size)
        assertEquals("终端", resp.list[0].title)
        assertEquals(800.0, resp.list[0].w)
        assertFalse(resp.list[1].onScreen)
    }

    @Test
    fun parseScreenInfoAndCaptureState() {
        val si = ServerResponse.parse(
            """{"op":"screen-info","width":1440,"height":900,"pixelWidth":1280,"pixelHeight":800,
                "fps":12,"quality":0.6,"maxWidth":1280,"mock":true}""".toByteArray()
        ) as ServerResponse.ScreenInfoEvent
        assertEquals(1440.0, si.info.widthPts)
        assertEquals(12, si.info.fps)
        assertTrue(si.info.mock)

        val cs = ServerResponse.parse(
            """{"op":"capture-state","enabled":true,"permission":false,"mock":true}""".toByteArray()
        ) as ServerResponse.CaptureState
        assertTrue(cs.enabled)
        assertFalse(cs.permission)
    }

    @Test
    fun parseOkWithEcho() {
        val resp = ServerResponse.parse(
            """{"op":"ok","action":"type-text","echo":{"text":"你好","submit":true}}""".toByteArray()
        ) as ServerResponse.Ok
        assertEquals("type-text", resp.action)
        assertEquals("你好", resp.echo.getString("text"))
        assertTrue(resp.echo.getBoolean("submit"))
    }

    @Test
    fun parseUnknownOp() {
        val resp = ServerResponse.parse("""{"op":"future-op"}""".toByteArray())
        assertTrue(resp is ServerResponse.Unknown)
        assertEquals("future-op", resp.op)
    }

    @Test
    fun requestBuildersProduceExpectedJSON() {
        assertEquals("""{"op":"ping"}""", String(Requests.ping()))
        assertEquals("""{"op":"list-windows"}""", String(Requests.listWindows()))
        val mouse = JSONObject(String(Requests.mouse("click", 0.5, 0.25)))
        assertEquals("mouse", mouse.getString("op"))
        assertEquals("click", mouse.getString("action"))
        assertEquals(0.5, mouse.getDouble("x"), 1e-9)
        val key = JSONObject(String(Requests.pressKey("return", listOf("command", "shift"))))
        assertEquals("return", key.getString("key"))
        assertEquals(2, key.getJSONArray("modifiers").length())
        val text = JSONObject(String(Requests.typeText("你好世界", true)))
        assertEquals("你好世界", text.getString("text"))
        assertTrue(text.getBoolean("submit"))
    }

    @Test
    fun pairingUriParse() {
        val info = PairingUri.parse(
            "macscreen://connect?host=192.168.1.5&port=9700&token=t0k%26en&name=%E5%BC%A0%E4%B8%89%E7%9A%84Mac"
        )
        assertNotNull(info)
        assertEquals("192.168.1.5", info.host)
        assertEquals(9700, info.port)
        assertEquals("t0k&en", info.token)
        assertEquals("张三的Mac", info.name)
    }

    @Test
    fun pairingUriRejectsGarbage() {
        assertNull(PairingUri.parse("https://example.com"))
        assertNull(PairingUri.parse("macscreen://connect?host=1.2.3.4"))
        assertNull(PairingUri.parse("macscreen://connect?host=1.2.3.4&port=abc&token=x"))
    }
}
