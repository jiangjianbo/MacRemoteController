package com.macscreen.client

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.speech.RecognitionService

/**
 * 本地语音识别环境诊断：能力发现 + 分支指导（文案随系统语言）。
 *
 * 覆盖国产 ROM（HyperOS/MIUI、鸿蒙等）上「装了 Google 语音组件仍不能识别」的常见原因：
 *  1) 本机没有任何 RecognitionService 提供者（无谷歌框架也未装组件）；
 *  2) 装了组件但被禁用/冻结（HyperOS 省电策略、纯净模式）；
 *  3) 装了组件但系统「默认语音识别服务」没选中它（装≠自动成为默认）；
 *  4) 默认服务是厂商服务（如小爱）但未同意语音协议 / 是 Google 但大陆网络无法访问其服务端。
 */
data class VoiceEnv(
    /** 已安装的识别服务提供者（应用标签, 包名, 是否启用） */
    val providers: List<Triple<String, String, Boolean>>,
    /** 系统默认语音识别服务的包名（未设置为 null） */
    val defaultPkg: String?,
    /** 本地识别当前是否可直接使用 */
    val usable: Boolean,
    /** 一行摘要（设置页显示） */
    val summary: String,
    /** 多行诊断详情（对话框正文） */
    val detail: String,
    /** 安装/设置指导文案 */
    val guidance: String,
    /** 「去处理」按钮的目标（可空） */
    val fixIntent: Intent?,
    val fixLabel: String?,
)

object VoiceDiagnoser {

    /** Google 官方语音组件（同时提供 TTS 与 RecognitionService） */
    private const val GOOGLE_SPEECH_PKG = "com.google.android.tts"

    fun diagnose(context: Context): VoiceEnv {
        val pm = context.packageManager

        // 1) 能力发现：本机所有 RecognitionService 提供者
        val providers = runCatching {
            pm.queryIntentServices(Intent(RecognitionService.SERVICE_INTERFACE), 0)
        }.getOrNull().orEmpty()
        val seen = LinkedHashMap<String, Pair<String, Boolean>>() // 包名 -> (标签, 启用)
        for (ri in providers) {
            val pkg = ri.serviceInfo?.packageName ?: continue
            if (seen.containsKey(pkg)) continue
            val label = runCatching { ri.loadLabel(pm).toString() }.getOrDefault(pkg)
            val enabled = runCatching { pm.getApplicationInfo(pkg, 0).enabled }.getOrDefault(false)
            seen[pkg] = label to enabled
        }
        val providerList = seen.map { Triple(it.value.first, it.key, it.value.second) }

        // 2) 系统默认语音识别服务（键名为 framework 内部常量 voice_recognition_service）
        val defaultFlat = runCatching {
            Settings.Secure.getString(context.contentResolver, "voice_recognition_service")
        }.getOrNull()
        val defaultPkg = defaultFlat?.substringBefore('/')?.takeIf { it.isNotBlank() }
        val defaultKnown = defaultPkg?.let { seen.containsKey(it) } ?: false
        val defaultEnabled = defaultPkg?.let {
            seen[it]?.second ?: runCatching { pm.getApplicationInfo(it, 0).enabled }.getOrDefault(false)
        } ?: false

        val disabledTag = context.getString(R.string.diag_disabled_tag)
        val providerText = if (providerList.isEmpty()) context.getString(R.string.diag_providers_none)
        else providerList.joinToString("\n") { (label, pkg, on) ->
            "· $label（$pkg）${if (on) "" else disabledTag}"
        }
        val defaultText = when {
            defaultPkg == null -> context.getString(R.string.diag_default_unset)
            defaultKnown -> defaultPkg + if (defaultEnabled) "" else disabledTag
            else -> context.getString(R.string.diag_default_unregistered_fmt, defaultPkg)
        }

        val googleInstalled = isInstalled(pm, GOOGLE_SPEECH_PKG)

        // 3) 分支判定与指导
        val builder = StringBuilder()
        var usable = false
        var guidance: String
        var fixIntent: Intent? = null
        var fixLabel: String? = null
        var summary: String

        when {
            providerList.isEmpty() -> {
                summary = context.getString(R.string.diag_summary_none)
                builder.append(context.getString(R.string.diag_providers_header, providerText, defaultText))
                builder.append('\n')
                guidance = if (googleInstalled) {
                    context.getString(R.string.diag_tts_only)
                } else {
                    context.getString(R.string.diag_install_google, GOOGLE_SPEECH_PKG)
                }
                fixIntent = if (googleInstalled) appDetails(context, GOOGLE_SPEECH_PKG) else storeSearch(context)
                fixLabel = context.getString(
                    if (googleInstalled) R.string.diag_view_app else R.string.diag_install)
            }
            defaultPkg == null -> {
                summary = context.getString(R.string.diag_summary_default_unset)
                builder.append(context.getString(R.string.diag_providers_header, providerText, defaultText))
                builder.append('\n')
                guidance = context.getString(R.string.diag_set_default)
                fixIntent = Intent(Settings.ACTION_VOICE_INPUT_SETTINGS)
                fixLabel = context.getString(R.string.diag_fix_set_default)
            }
            !defaultEnabled -> {
                summary = context.getString(R.string.diag_summary_default_disabled, defaultPkg)
                builder.append(context.getString(R.string.diag_providers_header, providerText, defaultText))
                builder.append('\n')
                guidance = context.getString(R.string.diag_set_default)
                fixIntent = appDetails(context, defaultPkg)
                fixLabel = context.getString(R.string.diag_view_app)
            }
            else -> {
                usable = true
                val isXiaomi = defaultPkg!!.contains("xiaomi") || defaultPkg.contains("miui")
                val isGoogle = defaultPkg.startsWith("com.google")
                summary = context.getString(R.string.diag_summary_ok, defaultPkg)
                builder.append(context.getString(R.string.diag_providers_header, providerText, defaultText))
                builder.append('\n')
                guidance = when {
                    isXiaomi -> context.getString(R.string.diag_hint_xiaomi)
                    isGoogle -> context.getString(R.string.diag_hint_google)
                    else -> context.getString(R.string.diag_hint_vendor)
                }
            }
        }

        return VoiceEnv(providerList, defaultPkg, usable, summary,
            builder.toString().trimEnd(), guidance, fixIntent, fixLabel)
    }

    private fun isInstalled(pm: PackageManager, pkg: String): Boolean =
        runCatching { pm.getApplicationInfo(pkg, 0); true }.getOrDefault(false)

    private fun appDetails(context: Context, pkg: String): Intent? =
        runCatching {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", pkg, null))
        }.getOrNull()

    /** 应用商店/Play 商店搜索；都没有则返回 null（由调用方提示手动安装）。 */
    private fun storeSearch(context: Context): Intent? {
        val market = Intent(Intent.ACTION_VIEW,
            Uri.parse("market://search?q=Speech%20Recognition%20%26%20Synthesis")).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (runCatching {
                context.packageManager.queryIntentActivities(market, 0).isNotEmpty()
            }.getOrDefault(false)) return market
        val web = Intent(Intent.ACTION_VIEW,
            Uri.parse("https://play.google.com/store/search?q=speech%20recognition%20%26%20synthesis&c=apps"))
        return if (runCatching {
                context.packageManager.queryIntentActivities(web, 0).isNotEmpty()
            }.getOrDefault(false)) web else null
    }
}
