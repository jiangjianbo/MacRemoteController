package com.macscreen.client

import android.animation.ObjectAnimator
import android.app.Activity
import android.app.AlertDialog
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Color
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.TextWatcher
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import com.macscreen.core.GestureClassifier
import com.macscreen.core.MacConnection
import com.macscreen.core.MacConnectionListener
import com.macscreen.core.MouseMapper
import com.macscreen.core.Requests
import com.macscreen.core.ScreenInfo
import com.macscreen.core.ServerResponse
import com.macscreen.core.SocketTransport
import com.macscreen.core.voice.CloudTranscriber
import com.macscreen.core.voice.WavEncoder

/**
 * 投屏与控制界面。
 * 布局（查看模式）：画面（底部透明浮动工具栏：回车开关/多行/语音/窗口/横竖屏/断开 + 动态还原）
 * + 底部单行输入区（>3 行自动转多行模式；长按进语音）。
 * 多行模式：全屏编辑框 + 顶部工具栏（回车开关/返回查看/语音/发送[高亮]）；语音永远插入光标处。
 */
class ScreenActivity : Activity() {

    private lateinit var app: ClientApp
    private lateinit var videoView: VideoView
    private lateinit var statusText: TextView
    private lateinit var screenPane: LinearLayout
    private lateinit var editPane: LinearLayout
    // openViewer 回填长文本时置位，抑制 TextWatcher 立即弹回多行模式
    private var paneSyncing = false
    private lateinit var inputEdit: EditText
    private lateinit var multilineEdit: EditText
    private lateinit var sendBtn: ImageButton
    private lateinit var sendBtn2: ImageButton
    private lateinit var submitBtn: ImageButton
    private lateinit var submitBtn2: ImageButton
    private lateinit var voiceBtn: ImageButton
    private lateinit var voiceBtn2: ImageButton
    private lateinit var resetBtn: ImageButton
    private lateinit var handler: Handler
    private lateinit var gesture: GestureClassifier
    private var screenInfo: ScreenInfo? = null
    private var connected = false
    @Volatile private var connecting = false
    private var resumed = false
    @Volatile private var lastFrameAt = 0L

    // 语音录音（云端模式）
    private var recorder: AudioRecord? = null
    @Volatile private var recording = false
    private var recordThread: Thread? = null
    private var localRecognizer: LocalVoiceRecognizer? = null
    private var pendingVoiceStart = false
    private var voiceStartedAt = 0L

    // 录音中央指示层（大话筒呼吸动画）
    private lateinit var voiceOverlay: LinearLayout
    private lateinit var voiceMicIcon: ImageView
    private var voicePulse: ObjectAnimator? = null
    // 兜底定时器：部分厂商 ROM（小米等）本地识别 stop 后可能既不回调结果也不回调错误
    private var voiceTimeoutTask: Runnable? = null

    // Android 禁止主线程做网络写（NetworkOnMainThreadException 直接杀进程）：
    // 手势/文本/语音等控制指令统一派发到这个后台单线程，单线程同时保证帧序
    private val sendExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()

    // 保活：定时 ping 既是 Mac 端空闲看门狗的活跃信号，也保持 Wi-Fi NAT 映射不老化
    private val pingTask = object : Runnable {
        override fun run() {
            if (!connected) return
            send(Requests.ping())
            handler.postDelayed(this, 15_000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as ClientApp
        handler = Handler(Looper.getMainLooper())
        gesture = GestureClassifier()
        buildUi()
        connect()
    }

    // 沉浸式全屏：隐藏系统状态栏/导航栏。否则手机顶栏会盖住画面顶部——
    // 缩放平移后 Mac 菜单栏落在画面最上沿时，被系统顶栏遮挡的区域点不到。
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            window.decorView.systemUiVisibility =
                (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_FULLSCREEN
                        or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                        or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                        or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION)
        }
    }

    // 熄屏深睡时 Handler 定时 ping 会被系统推迟，超过 Mac 端 45s 空闲看门狗 → 连接被掐断；
    // 解锁后若无此恢复逻辑，画面永远停在「等待画面…」。
    override fun onResume() {
        super.onResume()
        resumed = true
        if (isFinishing) return
        if (!connected) {
            if (!connecting) {
                statusText.text = getString(R.string.reconnecting)
                connect()
            }
        } else if (System.currentTimeMillis() - lastFrameAt > 8_000) {
            // 连接还在但帧停了（订阅丢失/半掐）：重发订阅恢复画面
            send(Requests.subscribe(true))
        }
    }

    override fun onPause() {
        super.onPause()
        resumed = false
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    /**
     * 实际回绕行数：EditText.layout 受 maxLines 截断不可靠（点击路径曾据此漏判），
     * 用同款 paint + 当前可用宽度构建 StaticLayout 精确计算，与控件布局状态无关。
     */
    private fun wrappedLineCount(edit: EditText): Int {
        val w = edit.width - edit.paddingLeft - edit.paddingRight
        if (w <= 0 || edit.text.isEmpty()) return 1
        return android.text.StaticLayout.Builder
            .obtain(edit.text, 0, edit.text.length, edit.paint, w)
            .build().lineCount
    }

    /** 浮动工具栏/图标按钮：矢量图标（白 tint 可动态改色），附 contentDescription（无障碍 + 多语言）。 */
    private fun iconButton(iconRes: Int, cdRes: Int, padX: Int = 8, padY: Int = 6): ImageButton =
        ImageButton(this).apply {
            setImageResource(iconRes)
            setImageTintList(android.content.res.ColorStateList.valueOf(Color.WHITE))
            contentDescription = getString(cdRes)
            setBackgroundColor(Color.TRANSPARENT)
            setPadding(dp(padX), dp(padY), dp(padX), dp(padY))
            minimumWidth = 0
            minimumHeight = 0
        }

    private fun buildUi() {
        val frame = FrameLayout(this)
        frame.addView(buildScreenPane(), FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        frame.addView(buildEditPane(), FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        buildVoiceOverlay()
        frame.addView(voiceOverlay, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        setContentView(frame)
    }

    /** 查看模式：画面（含浮动工具栏）+ 单行输入区。 */
    private fun buildScreenPane(): LinearLayout {
        screenPane = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }

        val videoArea = FrameLayout(this)
        videoView = VideoView(this)
        videoArea.addView(videoView, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        videoArea.addView(buildFloatingToolbar(), FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM))

        screenPane.addView(videoArea, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        // 底部单行输入区：输入框占大部分面积 + 发送图标按钮
        val inputBar = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        inputEdit = EditText(this).apply {
            hint = getString(R.string.hint_input)
            inputType = android.text.InputType.TYPE_CLASS_TEXT or
                        android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE
            maxLines = 3
            addTextChangedListener(object : android.text.TextWatcher {
                override fun afterTextChanged(s: android.text.Editable?) {
                    // 含自动回绕超过 3 行 → 自动切到多行编辑模式
                    // paneSyncing：openViewer 程序化回填长文本时抑制弹回（用户点 ⇲ 回查看后应停留）
                    handler.post {
                        if (paneSyncing) { paneSyncing = false; return@post }
                        if (wrappedLineCount(inputEdit) > 3 && editPane.visibility != View.VISIBLE) openMultiline()
                    }
                }
                override fun beforeTextChanged(s: CharSequence?, st: Int, c: Int, a: Int) {}
                override fun onTextChanged(s: CharSequence?, st: Int, b: Int, e: Int) {}
            })
            // 点击时内容已超 3 行 → 直接进多行模式。
            // 不用 OnClickListener：EditText 的触摸事件被光标放置逻辑吞掉，onClick 不可靠；
            // OnTouchListener 不消费事件（保留系统选择行为），UP 后置检查行数
            setOnTouchListener { _, e ->
                if (e.actionMasked == MotionEvent.ACTION_UP) handler.post {
                    if (editPane.visibility != View.VISIBLE && wrappedLineCount(inputEdit) > 3) openMultiline()
                }
                false
            }
            // 长按文本框 → 进入语音输入
            setOnLongClickListener {
                if (!recording) startVoice()
                true
            }
        }
        inputBar.addView(inputEdit, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))

        // 输入条是亮色背景，发送图标用深色 tint 才可见
        sendBtn = iconButton(R.drawable.ic_send, R.string.cd_send).apply {
            setImageTintList(android.content.res.ColorStateList.valueOf(0xFF333333.toInt()))
        }
        sendBtn.setOnClickListener { sendText() }
        inputBar.addView(sendBtn)
        screenPane.addView(inputBar, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        statusText = TextView(this).apply {
            text = getString(R.string.connecting)
            textSize = 12f
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
        }
        screenPane.addView(statusText, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dp(24)))
        return screenPane
    }

    private lateinit var toolbarRow: LinearLayout

    /** 画面底部透明浮动工具栏：靠左 [回车开关 多行 语音 窗口 横竖屏 断开]，靠右 [还原(动态)]。 */
    private fun buildFloatingToolbar(): LinearLayout {
        toolbarRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(0x40000000)  // 半透明衬底，白图标在浅色画面上也可读
            setPadding(dp(4), dp(2), dp(4), dp(2))
        }

        submitBtn = iconButton(R.drawable.ic_enter, R.string.cd_submit).apply {
            setOnClickListener { app.settings.voiceSubmit = !app.settings.voiceSubmit; syncSubmitButtons() }
        }
        toolbarRow.addView(submitBtn)

        val multilineBtn = iconButton(R.drawable.ic_note, R.string.cd_multiline)
        multilineBtn.setOnClickListener { openMultiline() }
        toolbarRow.addView(multilineBtn)

        voiceBtn = iconButton(R.drawable.ic_mic, R.string.cd_voice)
        voiceBtn.setOnClickListener { toggleVoice() }
        toolbarRow.addView(voiceBtn)

        val windowsBtn = iconButton(R.drawable.ic_win_tile, R.string.cd_windows)
        windowsBtn.setOnClickListener { send(Requests.listWindows()) }  // 结果经 onEvent → showWindowsDialog
        toolbarRow.addView(windowsBtn)

        val rotateBtn = iconButton(R.drawable.ic_rotate, R.string.cd_rotate)
        rotateBtn.setOnClickListener {
            val toLandscape = resources.configuration.orientation != Configuration.ORIENTATION_LANDSCAPE
            requestedOrientation = if (toLandscape) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                                   else ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
        toolbarRow.addView(rotateBtn)

        val disconnectBtn = iconButton(R.drawable.ic_link_off, R.string.cd_disconnect)
        disconnectBtn.setOnClickListener { finish() }
        toolbarRow.addView(disconnectBtn)

        val spacer = View(this)
        toolbarRow.addView(spacer, LinearLayout.LayoutParams(0, 1, 1f))

        // 还原缩放按钮：仅缩放态出现（syncResetButton 控制可见性），靠工具栏右端
        resetBtn = iconButton(R.drawable.ic_reset_zoom, R.string.cd_reset_zoom).apply {
            visibility = View.GONE
            setOnClickListener {
                videoView.resetView()
                syncResetButton()
            }
        }
        toolbarRow.addView(resetBtn)
        return toolbarRow
    }

    /** 多行编辑模式：顶部工具栏（回车开关/返回查看/语音/发送[高亮]）+ 全屏编辑框。 */
    private fun buildEditPane(): LinearLayout {
        editPane = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.BLACK)
            visibility = View.GONE
        }

        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(8), dp(8), dp(8), dp(8))
            gravity = Gravity.CENTER_VERTICAL
        }
        submitBtn2 = iconButton(R.drawable.ic_enter, R.string.cd_submit).apply {
            setImageTintList(android.content.res.ColorStateList.valueOf(Color.LTGRAY))
            setOnClickListener { app.settings.voiceSubmit = !app.settings.voiceSubmit; syncSubmitButtons() }
        }
        bar.addView(submitBtn2)

        val singleLineBtn = iconButton(R.drawable.ic_eye, R.string.cd_singleline)
        singleLineBtn.setOnClickListener { openViewer() }
        bar.addView(singleLineBtn)

        voiceBtn2 = iconButton(R.drawable.ic_mic, R.string.cd_voice).apply {
            setImageTintList(android.content.res.ColorStateList.valueOf(Color.LTGRAY))
        }
        voiceBtn2.setOnClickListener { toggleVoice() }
        bar.addView(voiceBtn2)

        bar.addView(View(this), LinearLayout.LayoutParams(0, 1, 1f))

        // 发送按钮高亮（默认按钮风格）
        sendBtn2 = iconButton(R.drawable.ic_send, R.string.cd_send, padX = 20, padY = 8).apply {
            setBackgroundColor(0xFF1E88E5.toInt())
        }
        sendBtn2.setOnClickListener { sendText() }
        bar.addView(sendBtn2)
        editPane.addView(bar, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        multilineEdit = EditText(this).apply {
            hint = getString(R.string.hint_input)
            inputType = android.text.InputType.TYPE_CLASS_TEXT or
                        android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE
            minLines = 6
            gravity = Gravity.TOP
        }
        editPane.addView(multilineEdit, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        return editPane
    }

    private fun syncSubmitButtons() {
        val on = app.settings.voiceSubmit
        submitBtn.setImageTintList(android.content.res.ColorStateList.valueOf(
            if (on) 0xFF4CAF50.toInt() else Color.WHITE))
        submitBtn2.setImageTintList(android.content.res.ColorStateList.valueOf(
            if (on) 0xFF4CAF50.toInt() else Color.LTGRAY))
    }

    /** 多行编辑模式 ↔ 查看模式切换（文本互通）。 */
    private fun openMultiline() {
        multilineEdit.setText(inputEdit.text)
        multilineEdit.setSelection(multilineEdit.text.length)
        editPane.visibility = View.VISIBLE
        screenPane.visibility = View.GONE
        syncSubmitButtons()
        multilineEdit.requestFocus()
    }

    private fun openViewer() {
        paneSyncing = true
        inputEdit.setText(multilineEdit.text)
        inputEdit.setSelection(inputEdit.text.length)
        screenPane.visibility = View.VISIBLE
        editPane.visibility = View.GONE
        // 回看模式是为了看 Mac 画面：必须收起键盘，否则输入法窗口遮住下半屏
        inputEdit.clearFocus()
        (getSystemService(INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager)
            .hideSoftInputFromWindow(inputEdit.windowToken, 0)
        syncResetButton()
        syncSubmitButtons()
    }

    /** 当前活动编辑框（多行模式优先）。 */
    private fun activeEditor(): EditText =
        if (editPane.visibility == View.VISIBLE) multilineEdit else inputEdit

    /** 在编辑框光标处插入文本（语音输入的唯一入口）。 */
    private fun insertAtCursor(editor: EditText, text: String) {
        if (text.isEmpty()) return
        val pos = (editor.selectionStart.takeIf { it >= 0 } ?: editor.text.length)
            .coerceIn(0, editor.text.length)
        editor.text.insert(pos, text)
        editor.setSelection(pos + text.length)
    }

    /** 缩放态才显示「还原」按钮；每次缩放变化后调用。 */
    private fun syncResetButton() {
        resetBtn.visibility = if (videoView.isZoomed) View.VISIBLE else View.GONE
    }

    /** 录音指示层：大话筒（呼吸动画）+ 状态文字，录音期间显示；点击任意处结束。 */
    private fun buildVoiceOverlay() {
        val micIcon = ImageView(this).apply {
            setImageResource(R.drawable.ic_mic)
            setImageTintList(android.content.res.ColorStateList.valueOf(0xFFFFFFFF.toInt()))
        }
        voiceMicIcon = micIcon
        voiceOverlay = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(0xB3000000.toInt())
            addView(micIcon, LinearLayout.LayoutParams(dp(120), dp(120)))
            addView(TextView(this@ScreenActivity).apply {
                text = getString(R.string.voice_listening)
                textSize = 22f
                setTextColor(0xFFFFFFFF.toInt())
                gravity = Gravity.CENTER
                setPadding(0, dp(12), 0, 0)
            })
            addView(TextView(this@ScreenActivity).apply {
                text = getString(R.string.voice_overlay_hint)
                textSize = 14f
                setTextColor(0xFFBBBBBB.toInt())
                gravity = Gravity.CENTER
                setPadding(dp(24), dp(4), dp(24), 0)
            })
            visibility = View.GONE
            setOnClickListener { if (recording) stopVoice() }
        }
    }

    private fun setVoiceOverlay(show: Boolean) {
        voiceOverlay.visibility = if (show) View.VISIBLE else View.GONE
        voicePulse?.cancel()
        voicePulse = null
        if (show) {
            voicePulse = ObjectAnimator.ofFloat(voiceMicIcon, View.ALPHA, 1f, 0.35f).apply {
                duration = 700
                repeatCount = ObjectAnimator.INFINITE
                repeatMode = ObjectAnimator.REVERSE
                start()
            }
        } else {
            voiceMicIcon.alpha = 1f
        }
    }

    private fun syncVoiceButtons() {
        // 录音中图标转红提示；查看模式白 / 多行模式灰的常态由各自创建时的 tint 决定
        if (recording) {
            val red = android.content.res.ColorStateList.valueOf(0xFFE53935.toInt())
            voiceBtn.setImageTintList(red)
            voiceBtn2.setImageTintList(red)
        } else {
            voiceBtn.setImageTintList(android.content.res.ColorStateList.valueOf(Color.WHITE))
            voiceBtn2.setImageTintList(android.content.res.ColorStateList.valueOf(Color.LTGRAY))
        }
    }

    // MARK: 连接

    private fun connect() {
        if (connecting || connected) return
        connecting = true
        Thread {
            val transport = SocketTransport()
            val connection = MacConnection(transport)
            try {
                app.connection = connection
                val ack = connection.connect(
                    app.settings.host, app.settings.port, app.settings.token,
                    app.settings.deviceName, listener)
                // 订阅必须在连接线程发（Android 禁止主线程做网络写，否则直接崩溃）
                connection.send(Requests.subscribe(true))
                handler.post {
                    connecting = false
                    connected = true
                    statusText.text = getString(R.string.connected_fmt, ack.serverName) +
                        if (ack.mock) getString(R.string.mock_suffix) else ""
                    handler.removeCallbacks(pingTask)
                    handler.postDelayed(pingTask, 15_000)
                    if (ack.mock) {
                        // Mock 画面提示要醒目：重建 Agent 后 ad-hoc 签名变化会让屏幕录制授权失效，容易踩到
                        if (!isFinishing) Toast.makeText(this,
                            getString(R.string.mock_permission_toast), Toast.LENGTH_LONG).show()
                    }
                }
            } catch (e: Exception) {
                try { connection.close() } catch (_: Exception) {}
                if (app.connection === connection) app.connection = null
                handler.post {
                    connecting = false
                    statusText.text = getString(R.string.connect_failed_fmt, e.message)
                    if (!isFinishing) Toast.makeText(this,
                        getString(R.string.connect_failed_fmt, e.message), Toast.LENGTH_LONG).show()
                }
            }
        }.start()
    }

    private val listener = object : MacConnectionListener {
        override fun onHelloAck(ack: ServerResponse.HelloAck) {}
        override fun onScreenInfo(info: ScreenInfo) {
            handler.post {
                screenInfo = info
                statusText.text = statusText.text.toString() +
                    getString(R.string.screen_info_fmt, info.widthPts.toString(), info.heightPts.toString())
            }
        }
        override fun onFrame(jpeg: ByteArray) {
            lastFrameAt = System.currentTimeMillis()
            videoView.onFrame(jpeg)
        }
        override fun onEvent(response: ServerResponse) {
            when (response) {
                is ServerResponse.Windows -> showWindowsDialog(response.list)
                is ServerResponse.CaptureState -> if (!response.permission) handler.post {
                    if (!isFinishing) Toast.makeText(this@ScreenActivity,
                        getString(R.string.capture_denied_toast), Toast.LENGTH_LONG).show()
                }
                is ServerResponse.Error -> handler.post {
                    Toast.makeText(this@ScreenActivity,
                        getString(R.string.connect_failed_fmt, response.message), Toast.LENGTH_SHORT).show()
                }
                else -> {}
            }
        }
        override fun onClosed(reason: String?) {
            handler.post {
                connected = false
                handler.removeCallbacks(pingTask)
                videoView.clear()
                statusText.text = getString(R.string.disconnected_fmt, reason) + getString(R.string.auto_reconnecting)
                // 熄屏期间被 Mac 空闲看门狗掐断（ping 被深睡推迟超 45s）等场景：自动重连一次。
                // 只试一次避免 Mac 端真的下线时无限循环；失败后可手动返回重连或等下次 onResume。
                handler.postDelayed({
                    if (resumed && !connected && !connecting && !isFinishing) {
                        statusText.text = getString(R.string.reconnecting)
                        connect()
                    }
                }, 2_000)
            }
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (editPane.visibility == View.VISIBLE) return super.onTouchEvent(event)
        scaleDetector.onTouchEvent(event)
        val zoomed = videoView.isZoomed
        val (imgW, imgH) = videoView.imageSize()
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                gesture.onDown(event.x, event.y, event.downTime)
                panTracking = true
                panLastX = event.x
                panLastY = event.y
                return true
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                // 双指接管：若 Mac 鼠标已被按下（拖动中），先补一个 up，避免 Mac 按键卡住
                if (gesture.dragging) sendMouseMapped("up", event.getX(0), event.getY(0),
                    zoomed = false, imgW = imgW, imgH = imgH, coerce = true)
                gesture.cancel()
                panTracking = false
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                if (event.pointerCount > 1) return true   // 双指：缩放已由 ScaleGestureDetector 处理
                if (zoomed) {
                    // 缩放态拖动 = 平移画面（本地），不发 Mac；手势序列照常推进（保留长按右键判定）
                    gesture.onMove(event.x, event.y, event.eventTime)
                    if (panTracking) videoView.panBy(event.x - panLastX, event.y - panLastY)
                    panLastX = event.x
                    panLastY = event.y
                    return true
                }
                if (gesture.onMove(event.x, event.y, event.eventTime)) {
                    // 首次进入拖动：发 mouse down
                    sendMouseMapped("down", event.x, event.y, false, imgW, imgH)
                } else if (gesture.dragging) {
                    sendMouseMapped("drag", event.x, event.y, false, imgW, imgH)
                }
                return true
            }
            MotionEvent.ACTION_UP -> {
                panTracking = false
                when (gesture.onUp(event.x, event.y, event.eventTime)) {
                    GestureClassifier.Result.Click ->
                        sendMouseMapped("click", event.x, event.y, zoomed, imgW, imgH)
                    GestureClassifier.Result.DoubleClick ->
                        sendMouseMapped("double", event.x, event.y, zoomed, imgW, imgH)
                    GestureClassifier.Result.RightClick ->
                        sendMouseMapped("right", event.x, event.y, zoomed, imgW, imgH)
                    GestureClassifier.Result.DragEnd ->
                        // 拖动结束必须补发 up（钳制到图像边缘，防止黑边收尾时 Mac 按键卡住）；
                        // 缩放态的"拖动"是本地平移、从未发过 down，无需发
                        if (!zoomed) sendMouseMapped("up", event.x, event.y, false, imgW, imgH, coerce = true)
                    else -> {}
                }
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                panTracking = false
                gesture.cancel()
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    // MARK: 手势 → 鼠标
    // 未缩放：单击/双击/长按右键/拖动 → 直接映射 Mac 鼠标指令；
    // 缩放态（双指捏合后）：双指=缩放画面、单指拖动=平移画面（本地视口变换，不发给 Mac），
    // 点击仍发给 Mac，坐标经缩放逆变换映射。

    // 注意：不能用字段初始化器直接传 this（构造阶段 Context 尚未挂上，会 NPE），用 lazy 首次触摸时创建
    private val scaleDetector by lazy {
        android.view.ScaleGestureDetector(this,
            object : android.view.ScaleGestureDetector.SimpleOnScaleGestureListener() {
                override fun onScale(detector: android.view.ScaleGestureDetector): Boolean {
                    videoView.applyZoom(videoView.zoomFactor * detector.scaleFactor,
                                        detector.focusX, detector.focusY)
                    syncResetButton()
                    return true
                }
            })
    }
    private var panTracking = false
    private var panLastX = 0f
    private var panLastY = 0f

    private fun width(): Int = videoView.width
    private fun height(): Int = videoView.height

    /** 按（是否缩放态）映射坐标并发送鼠标指令；coerce=true 时图外触点钳到图像边缘。 */
    private fun sendMouseMapped(action: String, x: Float, y: Float,
                                zoomed: Boolean, imgW: Int, imgH: Int, coerce: Boolean = false) {
        val mapped = if (zoomed) {
            val (panX, panY) = videoView.panOffset
            MouseMapper.normalizedZoomed(width(), height(), imgW, imgH,
                videoView.zoomFactor.toDouble(), panX.toDouble(), panY.toDouble(),
                x, y, coerce)
        } else {
            MouseMapper.normalized(width(), height(), imgW, imgH, x, y, coerce)
        }
        val (nx, ny) = mapped ?: return
        send(Requests.mouse(action, nx, ny))
    }

    // MARK: 文本发送

    private fun sendText() {
        val editor = activeEditor()
        val text = editor.text.toString()
        if (text.isEmpty()) return
        send(Requests.typeText(text, app.settings.voiceSubmit))
        editor.setText("")
        Toast.makeText(this, getString(R.string.sent_toast), Toast.LENGTH_SHORT).show()
    }

    private fun send(bytes: ByteArray) {
        sendExecutor.execute {
            try {
                app.connection?.send(bytes)
            } catch (e: Exception) {
                handler.post { Toast.makeText(this,
                    getString(R.string.send_failed_fmt, e.message), Toast.LENGTH_SHORT).show() }
            }
        }
    }

    // MARK: 窗口列表

    private fun showWindowsDialog(list: List<com.macscreen.core.WindowInfo>) {
        handler.post {
            if (isFinishing) return@post
            if (list.isEmpty()) {
                Toast.makeText(this, getString(R.string.no_windows), Toast.LENGTH_SHORT).show()
                return@post
            }
            // 只显示窗口标题（无标题回退应用名）；标题可能是长命令行，限 2 行省略
            val items = list.map { w ->
                (if (w.title.isNotBlank()) w.title else w.appName).ifBlank { getString(R.string.untitled) }
            }
            val adapter = object : android.widget.ArrayAdapter<String>(
                this, android.R.layout.simple_list_item_1, items) {
                override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
                    val v = super.getView(position, convertView, parent) as android.widget.TextView
                    v.maxLines = 2
                    v.ellipsize = android.text.TextUtils.TruncateAt.END
                    return v
                }
            }
            AlertDialog.Builder(this)
                .setTitle(getString(R.string.win_dialog_title))
                .setAdapter(adapter) { _, which -> send(Requests.activateWindow(list[which].id)) }
                .show()
        }
    }

    // MARK: 语音

    /** 语音输入开关（工具栏话筒/长按文本框/录音层点击结束）。 */
    private fun toggleVoice() {
        if (recording) stopVoice() else startVoice()
    }

    /** 开始语音识别。返回是否真正开始；失败路径均已给出提示且不显示覆盖层。 */
    private fun startVoice(): Boolean {
        if (recording) {
            toastMsg(getString(R.string.prev_recording))
            return false
        }
        cancelVoiceFailsafe()
        if (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO)
                != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            pendingVoiceStart = true
            requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), 200)
            return false
        }
        if (app.settings.voiceEngine == "local") {
            // 环境诊断：无识别服务/未设默认/组件被禁用都会在此拦截并给出针对性指导
            val env = VoiceDiagnoser.diagnose(this)
            if (!env.usable) {
                showVoiceGuideDialog(env)
                return false
            }
            syncVoiceButtons()
            localRecognizer?.destroy()
            val recognizer = LocalVoiceRecognizer(this, app.settings)
            localRecognizer = recognizer
            recognizer.start { text -> onVoiceResult(text) }
            recording = true
            voiceStartedAt = SystemClock.elapsedRealtime()
            setVoiceOverlay(true)
            return true
        }
        // 云端：转写配置不完整时提前拦截（否则录完才报错，用户以为没反应）
        if (app.settings.cloudUrl.isBlank()) {
            toastMsg(getString(R.string.cloud_not_configured))
            return false
        }
        val minBuf = AudioRecord.getMinBufferSize(WavEncoder.SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minBuf <= 0) {
            toastMsg(getString(R.string.record_fail))
            return false
        }
        val audio = AudioRecord(MediaRecorder.AudioSource.MIC, WavEncoder.SAMPLE_RATE,
                                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                                maxOf(minBuf, 16384))
        if (audio.state != AudioRecord.STATE_INITIALIZED) {
            toastMsg(getString(R.string.record_init_fail))
            audio.release()
            return false
        }
        syncVoiceButtons()
        recorder = audio
        recording = true
        voiceStartedAt = SystemClock.elapsedRealtime()
        setVoiceOverlay(true)
        recordThread = Thread {
            val buffer = ShortArray(3200)   // 100ms
            val collected = mutableListOf<ShortArray>()
            audio.startRecording()
            while (recording) {
                val n = audio.read(buffer, 0, buffer.size)
                if (n > 0) collected.add(buffer.copyOf(n))
                // 上限 60 秒
                if (collected.sumOf { it.size } > WavEncoder.SAMPLE_RATE * 60) break
            }
            audio.stop()
            audio.release()
            recorder = null
            val pcm = ShortArray(collected.sumOf { it.size })
            var offset = 0
            for (chunk in collected) {
                chunk.copyInto(pcm, offset)
                offset += chunk.size
            }
            val wav = WavEncoder.encode(pcm)
            try {
                val transcriber = CloudTranscriber(app.settings.cloudTranscriberConfig(),
                                                   com.macscreen.client.HttpPosterImpl())
                val text = transcriber.transcribe(wav)
                handler.post { onVoiceResult(text) }
            } catch (e: Exception) {
                handler.post {
                    toastMsg(getString(R.string.cloud_fail_fmt, e.message))
                    syncVoiceButtons()
                }
            }
        }.also { it.start() }
        return true
    }

    private fun stopVoice() {
        val heldMs = SystemClock.elapsedRealtime() - voiceStartedAt
        recording = false
        setVoiceOverlay(false)
        syncVoiceButtons()
        // 误触保护：开始后极快结束录不到有效内容
        if (heldMs < 400) toastMsg(getString(R.string.voice_too_short))
        if (app.settings.voiceEngine == "local") {
            localRecognizer?.stop()
            // 厂商 ROM 兜底：8 秒内没有结果/错误回调就销毁 recognizer 并提示，
            // 避免状态卡死导致话筒"按了没反应"
            cancelVoiceFailsafe()
            voiceTimeoutTask = Runnable {
                localRecognizer?.destroy()
                localRecognizer = null
                toastMsg(getString(R.string.voice_no_result_fallback))
            }.also { handler.postDelayed(it, 8000) }
        }
        // 云端录音线程在 recording=false 后自行收尾并回调结果，不在主线程 join
    }

    private fun cancelVoiceFailsafe() {
        voiceTimeoutTask?.let { handler.removeCallbacks(it) }
        voiceTimeoutTask = null
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 200 && pendingVoiceStart) {
            pendingVoiceStart = false
            if (grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED) {
                startVoice()
            } else {
                toastMsg(getString(R.string.mic_permission_needed))
                syncVoiceButtons()
            }
        }
    }

    /** 本地识别环境不可用时的诊断对话框：诊断详情 + 指导 + 「去处理」/「改用云端」。 */
    private fun showVoiceGuideDialog(env: VoiceEnv) {
        val body = "${env.detail}\n\n${env.guidance}"
        val dialog = AlertDialog.Builder(this)
            .setTitle(getString(R.string.local_unavailable_title))
            .setMessage(body)
            .setPositiveButton(getString(R.string.action_ok), null)
        if (env.fixIntent != null && env.fixLabel != null) {
            dialog.setNeutralButton(env.fixLabel) { _, _ ->
                runCatching { startActivity(env.fixIntent) }
                    .onFailure { toastMsg(getString(R.string.open_settings_fail)) }
            }
        }
        dialog.setNegativeButton(getString(R.string.action_use_cloud)) { _, _ ->
            runCatching { startActivity(android.content.Intent(this, SettingsActivity::class.java)) }
                .onFailure { toastMsg(getString(R.string.open_voice_settings_fail)) }
        }
        if (!isFinishing) dialog.show()
    }

    /** 语音识别完成 → 插入当前活动编辑框光标处（多行模式插到多行框），用户可编辑后手动发送。 */
    fun onVoiceResult(text: String) {
        recording = false
        syncVoiceButtons()
        setVoiceOverlay(false)
        cancelVoiceFailsafe()
        localRecognizer?.destroy()
        localRecognizer = null
        if (text.isBlank()) {
            toastMsg(getString(R.string.no_voice_result))
            return
        }
        insertAtCursor(activeEditor(), text)
    }

    private fun toastMsg(msg: String) {
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
    }

    override fun onDestroy() {
        super.onDestroy()
        recording = false
        handler.removeCallbacks(pingTask)
        localRecognizer?.destroy()
        localRecognizer = null
        sendExecutor.shutdownNow()
        try { app.connection?.close() } catch (_: Exception) {}
        app.connection = null
    }
}
