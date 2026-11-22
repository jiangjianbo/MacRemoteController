package com.macscreen.client

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.os.Handler
import android.os.Looper
import java.util.Locale

/**
 * 本地语音识别：Android 内置 SpeechRecognizer（可用离线语言包，免流量）。
 * start 后开始聆听，stop 结束（自动检测说完）；识别语言跟随系统语言。
 */
class LocalVoiceRecognizer(
    private val activity: Activity,
    private val settings: AppSettings,
    private val handler: Handler = Handler(Looper.getMainLooper()),
) : RecognitionListener {

    private var recognizer: SpeechRecognizer? = null
    private var callback: ((String) -> Unit)? = null

    fun start(onResult: (String) -> Unit) {
        callback = onResult
        handler.post {
            if (!SpeechRecognizer.isRecognitionAvailable(activity)) {
                // 无语音服务的 ROM 上直接给指引，不能静默无反应
                android.widget.Toast.makeText(activity,
                    activity.getString(R.string.local_no_service),
                    android.widget.Toast.LENGTH_LONG).show()
                onResult("")
                return@post
            }
            val sr = try {
                SpeechRecognizer.createSpeechRecognizer(activity)
            } catch (e: Exception) {
                // 诊断通过但创建仍失败（个别 ROM 异常）：兜底提示，不静默无反应
                android.widget.Toast.makeText(activity,
                    activity.getString(R.string.recognizer_create_fail_fmt, e.message),
                    android.widget.Toast.LENGTH_LONG).show()
                onResult("")
                return@post
            }
            recognizer = sr
            sr.setRecognitionListener(this)
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                         RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                // 识别语言跟随系统语言（BCP47，如 zh-CN / en-US）
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toLanguageTag())
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            }
            sr.startListening(intent)
        }
    }

    fun stop() {
        handler.post {
            recognizer?.stopListening()
        }
    }

    fun destroy() {
        handler.post {
            recognizer?.destroy()
            recognizer = null
        }
    }

    // RecognitionListener

    override fun onResults(results: Bundle) {
        val text = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: ""
        handler.post { callback?.invoke(text ?: "") }
    }

    override fun onError(error: Int) {
        val msg = when (error) {
            SpeechRecognizer.ERROR_NO_MATCH -> activity.getString(R.string.err_no_match)
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> activity.getString(R.string.err_speech_timeout)
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> activity.getString(R.string.err_mic_permission)
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> activity.getString(R.string.err_network_timeout)
            // 小米等机型：服务在但不可用（常因首次使用需在小爱同学里同意语音服务协议）
            SpeechRecognizer.ERROR_CLIENT -> activity.getString(R.string.err_client)
            SpeechRecognizer.ERROR_SERVER -> activity.getString(R.string.err_server)
            SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> activity.getString(R.string.err_lang_unsupported)
            else -> activity.getString(R.string.err_generic_fmt, error)
        }
        android.widget.Toast.makeText(activity, msg, android.widget.Toast.LENGTH_LONG).show()
        handler.post { callback?.invoke("") }
    }

    override fun onReadyForSpeech(params: Bundle?) {}
    override fun onBeginningOfSpeech() {}
    override fun onRmsChanged(rmsdB: Float) {}
    override fun onBufferReceived(buffer: ByteArray?) {}
    override fun onEndOfSpeech() {}
    override fun onPartialResults(partialResults: Bundle?) {}
    override fun onEvent(eventType: Int, params: Bundle?) {}
}
