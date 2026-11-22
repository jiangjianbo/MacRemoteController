package com.macscreen.client

import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper

/** Mac 端发现（Bonjour/NsdManager，系统内置 `_macscreen._tcp`）。 */
class NsdDiscovery(private val nsdManager: NsdManager, private val handler: Handler = Handler(Looper.getMainLooper())) {

    data class Found(val name: String, val host: String, val port: Int)

    interface Callback {
        fun onFound(service: Found)
        fun onLost(name: String)
        fun onError(message: String)
    }

    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private val found = mutableMapOf<String, Found>()

    fun start(cb: Callback) {
        stop()
        found.clear()
        discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                handler.post { cb.onError("发现启动失败 (err=$errorCode)") }
            }
            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                // 解析地址需要 Resolve，逐个解析
                resolve(serviceInfo, cb)
            }
            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                handler.post { cb.onLost(serviceInfo.serviceName) }
            }
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }
        nsdManager.discoverServices("_macscreen._tcp", NsdManager.PROTOCOL_DNS_SD, discoveryListener)
    }

    private fun resolve(info: NsdServiceInfo, cb: Callback) {
        val resolver = object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {}
            override fun onServiceResolved(info: NsdServiceInfo) {
                val host = info.host?.hostAddress ?: return
                val item = Found(info.serviceName, host, info.port)
                found[info.serviceName] = item
                handler.post { cb.onFound(item) }
            }
        }
        try {
            nsdManager.resolveService(info, resolver)
        } catch (e: Exception) {
            handler.post { cb.onError("解析失败：${e.message}") }
        }
    }

    fun stop() {
        discoveryListener?.let {
            try { nsdManager.stopServiceDiscovery(it) } catch (_: Exception) {}
        }
        discoveryListener = null
    }
}
