package com.macscreen.client

import com.macscreen.core.voice.HttpPoster
import java.net.HttpURLConnection
import java.net.URL

/** HttpPoster 真实实现（HttpURLConnection，平台内置）。 */
class HttpPosterImpl(private val connectTimeoutMs: Int = 10_000,
                     private val readTimeoutMs: Int = 30_000) : HttpPoster {

    override fun post(url: String, headers: Map<String, String>, contentType: String, body: ByteArray): HttpPoster.HttpResult {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            this.connectTimeout = connectTimeoutMs
            this.readTimeout = readTimeoutMs
            doOutput = true
            setRequestProperty("Content-Type", contentType)
            for ((k, v) in headers) setRequestProperty(k, v)
        }
        try {
            conn.outputStream.use { it.write(body) }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val respBody = stream?.readBytes() ?: ByteArray(0)
            return HttpPoster.HttpResult(code, respBody)
        } finally {
            conn.disconnect()
        }
    }
}
