package com.macscreen.client

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import com.macscreen.core.MacConnection
import com.macscreen.core.voice.CloudTranscriberConfig

/** 全局状态：连接单例 + 设置。 */
class ClientApp : Application() {

    lateinit var settings: AppSettings
        private set

    /** 当前连接（Activity 之间共享）。 */
    var connection: MacConnection? = null

    override fun onCreate() {
        super.onCreate()
        settings = AppSettings(getSharedPreferences("macscreen", Context.MODE_PRIVATE))
        installCrashLogger()
    }

    /**
     * 全局崩溃捕获：任何线程的未捕获异常先落盘 crash.log（内部 + 应用专属外部目录，
     * 用户无需 adb 用文件管理器即可取到），再交给系统默认处理（保留崩溃对话框/进程终止）。
     */
    private fun installCrashLogger() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val sb = StringBuilder()
                sb.append("==== ").append(java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss", java.util.Locale.US)
                    .format(java.util.Date())).append("  thread=").append(thread.name).append('\n')
                sb.append(android.util.Log.getStackTraceString(throwable)).append('\n')
                val text = sb.toString()
                val dir = getExternalFilesDir(null)
                try { java.io.File(dir, "crash.log").appendText(text) } catch (_: Exception) {}
                try { java.io.File(filesDir, "crash.log").appendText(text) } catch (_: Exception) {}
            } catch (_: Throwable) {}
            previous?.uncaughtException(thread, throwable)
        }
    }
}

/** SharedPreferences 封装。 */
class AppSettings(private val prefs: SharedPreferences) {

    var host: String
        get() = prefs.getString("host", "") ?: ""
        set(v) { prefs.edit().putString("host", v).apply() }

    var port: Int
        get() = prefs.getInt("port", 9700)
        set(v) { prefs.edit().putInt("port", v).apply() }

    var token: String
        get() = prefs.getString("token", "") ?: ""
        set(v) { prefs.edit().putString("token", v).apply() }

    var deviceName: String
        get() = prefs.getString("deviceName", android.os.Build.MODEL ?: "phone") ?: "phone"
        set(v) { prefs.edit().putString("deviceName", v).apply() }

    /** 语音引擎：local（本地 SpeechRecognizer）或 cloud（云端大模型转写）。 */
    var voiceEngine: String
        get() = prefs.getString("voiceEngine", "local") ?: "local"
        set(v) { prefs.edit().putString("voiceEngine", v).apply() }

    var cloudUrl: String
        get() = prefs.getString("cloudUrl", "") ?: ""
        set(v) { prefs.edit().putString("cloudUrl", v).apply() }

    var cloudApiKey: String
        get() = prefs.getString("cloudApiKey", "") ?: ""
        set(v) { prefs.edit().putString("cloudApiKey", v).apply() }

    var cloudModel: String
        get() = prefs.getString("cloudModel", "whisper-1") ?: "whisper-1"
        set(v) { prefs.edit().putString("cloudModel", v).apply() }

    var cloudStyle: String
        get() = prefs.getString("cloudStyle", "openai") ?: "openai"
        set(v) { prefs.edit().putString("cloudStyle", v).apply() }

    /** 语音识别完成后是否追加回车（submit）。 */
    var voiceSubmit: Boolean
        get() = prefs.getBoolean("voiceSubmit", false)
        set(v) { prefs.edit().putBoolean("voiceSubmit", v).apply() }

    fun cloudTranscriberConfig(): CloudTranscriberConfig = CloudTranscriberConfig(
        url = cloudUrl,
        apiKey = cloudApiKey,
        model = cloudModel,
        style = cloudStyle,
        language = "zh",
        responseField = if (cloudStyle == "raw") "text" else "text",
    )
}
