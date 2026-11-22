package com.macscreen.client

import android.app.Activity
import android.os.Bundle
import android.view.ViewGroup
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast

/** 设置页：语音引擎（本地/云端大模型）、云端 API 配置、自动发送等。 */
class SettingsActivity : Activity() {

    private lateinit var app: ClientApp
    private lateinit var engineGroup: RadioGroup
    private lateinit var localRadio: RadioButton
    private lateinit var cloudRadio: RadioButton
    private lateinit var cloudForm: LinearLayout
    private lateinit var urlEdit: EditText
    private lateinit var keyEdit: EditText
    private lateinit var modelEdit: EditText
    private lateinit var styleGroup: RadioGroup
    private lateinit var openaiRadio: RadioButton
    private lateinit var rawRadio: RadioButton
    private lateinit var voiceSubmitCheck: CheckBox

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as ClientApp
        buildUi()
        load()
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private fun label(text: String, size: Float = 15f, bold: Boolean = false): TextView =
        TextView(this).apply {
            this.text = text
            textSize = size
            setTextColor(0xFF111111.toInt())
            if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
        }

    private fun buildUi() {
        val scroll = ScrollView(this)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(40), dp(20), dp(20))
        }
        scroll.addView(root, ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))

        root.addView(label(getString(R.string.settings_title), 22f, true))
        root.addView(label(getString(R.string.settings_desc)).apply { setPadding(0, dp(4), 0, dp(8)) })

        engineGroup = RadioGroup(this).apply { orientation = RadioGroup.VERTICAL }
        localRadio = RadioButton(this).apply { text = getString(R.string.engine_local) }
        cloudRadio = RadioButton(this).apply { text = getString(R.string.engine_cloud) }
        engineGroup.addView(localRadio)
        engineGroup.addView(cloudRadio)
        root.addView(engineGroup)
        // 动态诊断：本机识别服务能力发现（有无服务/默认服务/启用状态），替代静态提示
        val env = VoiceDiagnoser.diagnose(this)
        root.addView(label("${env.summary}\n${env.guidance}")
            .apply { textSize = 12f; setTextColor(0xFF888888.toInt()); setPadding(dp(24), dp(2), 0, dp(8)) })

        cloudForm = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(24), 0, 0, 0) }
        urlEdit = EditText(this).apply { hint = getString(R.string.hint_api_url) }
        keyEdit = EditText(this).apply { hint = getString(R.string.hint_api_key); inputType = android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD }
        modelEdit = EditText(this).apply { hint = getString(R.string.hint_model) }
        cloudForm.addView(urlEdit)
        cloudForm.addView(keyEdit)
        cloudForm.addView(modelEdit)
        styleGroup = RadioGroup(this).apply { orientation = RadioGroup.HORIZONTAL }
        openaiRadio = RadioButton(this).apply { text = getString(R.string.style_openai) }
        rawRadio = RadioButton(this).apply { text = getString(R.string.style_raw) }
        styleGroup.addView(openaiRadio)
        styleGroup.addView(rawRadio)
        cloudForm.addView(label(getString(R.string.api_style)))
        cloudForm.addView(styleGroup)
        root.addView(cloudForm)

        engineGroup.setOnCheckedChangeListener { _, _ ->
            cloudForm.visibility =
                if (cloudRadio.isChecked) android.view.View.VISIBLE else android.view.View.GONE
        }

        voiceSubmitCheck = CheckBox(this).apply { text = getString(R.string.submit_auto_return) }
        root.addView(voiceSubmitCheck)

        val saveBtn = Button(this).apply { text = getString(R.string.btn_save) }
        saveBtn.setOnClickListener { save() }
        root.addView(saveBtn, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        setContentView(scroll)
    }

    private fun load() {
        if (app.settings.voiceEngine == "cloud") cloudRadio.isChecked = true else localRadio.isChecked = true
        urlEdit.setText(app.settings.cloudUrl)
        keyEdit.setText(app.settings.cloudApiKey)
        modelEdit.setText(app.settings.cloudModel)
        if (app.settings.cloudStyle == "raw") rawRadio.isChecked = true else openaiRadio.isChecked = true
        voiceSubmitCheck.isChecked = app.settings.voiceSubmit
        cloudForm.visibility = if (app.settings.voiceEngine == "cloud") android.view.View.VISIBLE else android.view.View.GONE
    }

    private fun save() {
        app.settings.voiceEngine = if (cloudRadio.isChecked) "cloud" else "local"
        app.settings.cloudUrl = urlEdit.text.toString().trim()
        app.settings.cloudApiKey = keyEdit.text.toString().trim()
        app.settings.cloudModel = modelEdit.text.toString().trim()
        app.settings.cloudStyle = if (rawRadio.isChecked) "raw" else "openai"
        app.settings.voiceSubmit = voiceSubmitCheck.isChecked
        Toast.makeText(this, getString(R.string.saved), Toast.LENGTH_SHORT).show()
        finish()
    }
}
