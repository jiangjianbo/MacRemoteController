package com.macscreen.client

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.nsd.NsdManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast

/** 连接主界面：自动发现 / 扫码配对 / 手动输入。 */
class MainActivity : Activity() {

    private lateinit var app: ClientApp
    private lateinit var discovery: NsdDiscovery
    private lateinit var statusText: TextView
    private lateinit var foundContainer: LinearLayout
    private val handler = Handler(Looper.getMainLooper())
    private val foundItems = mutableListOf<NsdDiscovery.Found>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as ClientApp

        val nsd = getSystemService(NSD_SERVICE) as NsdManager
        discovery = NsdDiscovery(nsd)

        buildUi()
        // 回填上次连接信息
        fillForm()
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private fun buildUi() {
        val scroll = ScrollView(this)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(40), dp(20), dp(20))
        }
        scroll.addView(root, ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))

        fun label(text: String, size: Float = 18f, bold: Boolean = false): TextView =
            TextView(this).apply {
                this.text = text
                textSize = size
                setTextColor(0xFF111111.toInt())
                if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
            }

        root.addView(label(getString(R.string.app_title), 26f, true))
        statusText = label(getString(R.string.main_subtitle), 14f)
        statusText.setPadding(0, dp(8), 0, dp(16))
        root.addView(statusText)

        // 自动发现
        val discoverBtn = Button(this).apply { text = getString(R.string.discover_btn) }
        discoverBtn.setOnClickListener { startDiscovery() }
        root.addView(discoverBtn)
        foundContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(foundContainer)

        root.addView(label(getString(R.string.manual_section), 14f).apply { gravity = Gravity.CENTER; setPadding(0, dp(16), 0, dp(8)) })
        val hostEdit = EditText(this).apply {
            hint = getString(R.string.hint_host)
            inputType = android.text.InputType.TYPE_CLASS_PHONE
            tag = "host"
        }
        val portEdit = EditText(this).apply {
            hint = getString(R.string.hint_port)
            inputType = android.text.InputType.TYPE_CLASS_PHONE
            tag = "port"
        }
        val tokenEdit = EditText(this).apply {
            hint = getString(R.string.hint_token)
            tag = "token"
        }
        root.addView(hostEdit); root.addView(portEdit); root.addView(tokenEdit)

        val connectBtn = Button(this).apply { text = getString(R.string.btn_connect) }
        connectBtn.setOnClickListener {
            val host = hostEdit.text.toString().trim()
            val port = portEdit.text.toString().trim().toIntOrNull() ?: 9700
            val token = tokenEdit.text.toString().trim()
            if (host.isEmpty() || token.isEmpty()) {
                toast(getString(R.string.err_need_host_token))
                return@setOnClickListener
            }
            app.settings.host = host
            app.settings.port = port
            app.settings.token = token
            openScreen()
        }
        root.addView(connectBtn)

        val qrBtn = Button(this).apply { text = getString(R.string.btn_qr_pair) }
        qrBtn.setOnClickListener {
            if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                startActivityForResult(Intent(this, QRScanActivity::class.java), REQ_QR)
            } else {
                requestPermissions(arrayOf(Manifest.permission.CAMERA), REQ_CAMERA)
            }
        }
        root.addView(qrBtn)

        val settingsBtn = Button(this).apply { text = getString(R.string.btn_voice_settings) }
        settingsBtn.setOnClickListener { startActivity(Intent(this, SettingsActivity::class.java)) }
        root.addView(settingsBtn)

        setContentView(scroll)
    }

    private fun fillForm() {
        val host = findViewById<View>(android.R.id.content).findViewWithTag<EditText>("host")
        val port = findViewById<View>(android.R.id.content).findViewWithTag<EditText>("port")
        val token = findViewById<View>(android.R.id.content).findViewWithTag<EditText>("token")
        if (app.settings.host.isNotEmpty()) host.setText(app.settings.host)
        if (app.settings.port != 9700) port.setText(app.settings.port.toString())
        if (app.settings.token.isNotEmpty()) token.setText(app.settings.token)
    }

    private fun startDiscovery() {
        statusText.text = getString(R.string.discovering)
        foundItems.clear()
        foundContainer.removeAllViews()
        discovery.start(object : NsdDiscovery.Callback {
            override fun onFound(service: NsdDiscovery.Found) {
                if (foundItems.any { it.name == service.name }) return
                foundItems.add(service)
                val row = Button(this@MainActivity).apply {
                    text = getString(R.string.found_item, service.name, service.host, service.port.toString())
                    setOnClickListener {
                        app.settings.host = service.host
                        app.settings.port = service.port
                        // token 仍需手动/扫码获取（不随广播下发）
                        fillForm()
                        toast(getString(R.string.found_selected, service.name))
                    }
                }
                foundContainer.addView(row)
                statusText.text = getString(R.string.found_count, foundItems.size)
            }
            override fun onLost(name: String) {
                foundItems.removeAll { it.name == name }
            }
            override fun onError(message: String) {
                statusText.text = message
            }
        })
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_QR && resultCode == RESULT_OK) {
            val content = data?.getStringExtra("content") ?: return
            val info = com.macscreen.core.PairingUri.parse(content)
            if (info == null) {
                toast(getString(R.string.qr_bad_content, content.take(80)))
                return
            }
            app.settings.host = info.host
            app.settings.port = info.port
            app.settings.token = info.token
            fillForm()
            openScreen()
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_CAMERA && grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            startActivityForResult(Intent(this, QRScanActivity::class.java), REQ_QR)
        }
    }

    private fun openScreen() {
        startActivity(Intent(this, ScreenActivity::class.java))
    }

    private fun toast(msg: String) {
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
    }

    companion object {
        private const val REQ_QR = 101
        private const val REQ_CAMERA = 102
    }
}
