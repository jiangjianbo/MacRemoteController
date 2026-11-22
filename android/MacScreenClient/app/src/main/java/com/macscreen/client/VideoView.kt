package com.macscreen.client

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.view.View
import com.macscreen.core.MouseMapper

/**
 * MJPEG 视图：后台解码 JPEG → 主线程绘制。
 * 支持本地视口缩放/平移（双指捏合放大画面、缩放态单指拖动平移画面），
 * 仅为视觉变换，不向 Mac 发送任何指令；点击坐标经 [MouseMapper.normalizedZoomed] 逆映射。
 */
class VideoView(context: Context) : View(context) {

    @Volatile private var bitmap: Bitmap? = null
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val hintPaint = Paint().apply {
        color = Color.WHITE
        textSize = 48f
        textAlign = Paint.Align.CENTER
        isAntiAlias = true
    }
    private var frameCount = 0
    private var lastFpsAt = System.currentTimeMillis()
    private var lastFps = 0

    // 视口状态（仅 UI 线程读写）：zoom 为相对 fit 的倍数；pan 为相对居中位置的偏移(px)
    private var zoom = 1f
    private var panX = 0f
    private var panY = 0f

    val zoomFactor: Float get() = synchronized(this) { zoom }
    val panOffset: Pair<Float, Float> get() = synchronized(this) { panX to panY }
    val isZoomed: Boolean get() = synchronized(this) { zoom > 1.01f }

    /** 收到 JPEG 帧（IO 线程调用）。 */
    fun onFrame(jpeg: ByteArray) {
        val bmp = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) ?: return
        val old: Bitmap?
        synchronized(this) {
            old = bitmap
            bitmap = bmp
            frameCount++
            val now = System.currentTimeMillis()
            if (now - lastFpsAt >= 1000) {
                lastFps = frameCount
                frameCount = 0
                lastFpsAt = now
            }
        }
        old?.recycle()
        postInvalidate()
    }

    fun clear() {
        synchronized(this) {
            bitmap?.recycle()
            bitmap = null
        }
        postInvalidate()
    }

    fun stats(): Pair<Int, Int> = lastFps to (synchronized(this) { bitmap?.width ?: 0 })

    /** 当前帧像素尺寸（供坐标映射）。 */
    fun imageSize(): Pair<Int, Int> = synchronized(this) {
        val b = bitmap
        (b?.width ?: 0) to (b?.height ?: 0)
    }

    /** 以 focus 点为锚点设置目标缩放（1..5 倍）：放大/缩小过程中焦点下的画面点保持不动。 */
    fun applyZoom(targetZoom: Float, focusX: Float, focusY: Float) {
        synchronized(this) {
            val b = bitmap
            if (b == null || width == 0 || height == 0) {
                zoom = targetZoom.coerceIn(1f, 5f)
            } else {
                val fit = minOf(width.toFloat() / b.width, height.toFloat() / b.height)
                val oldScale = fit * zoom
                val newZoom = targetZoom.coerceIn(1f, 5f)
                val dxOld = (width - b.width * oldScale) / 2f + panX
                val dyOld = (height - b.height * oldScale) / 2f + panY
                val imgX = (focusX - dxOld) / oldScale
                val imgY = (focusY - dyOld) / oldScale
                zoom = newZoom
                panX = MouseMapper.anchoredPan(
                    width.toDouble(), b.width.toDouble(), (b.width * fit).toDouble(), zoom.toDouble(),
                    focusX.toDouble(), imgX.toDouble()).toFloat()
                panY = MouseMapper.anchoredPan(
                    height.toDouble(), b.height.toDouble(), (b.height * fit).toDouble(), zoom.toDouble(),
                    focusY.toDouble(), imgY.toDouble()).toFloat()
            }
        }
        postInvalidate()
    }

    /** 平移增量（px），越界自动钳制（放大不足/未放大时锁居中）。 */
    fun panBy(dx: Float, dy: Float) {
        synchronized(this) {
            val b = bitmap ?: return
            if (width == 0 || height == 0) return
            val fit = minOf(width.toFloat() / b.width, height.toFloat() / b.height)
            panX = MouseMapper.clampPan(width.toDouble(), (b.width * fit).toDouble(),
                zoom.toDouble(), (panX + dx).toDouble()).toFloat()
            panY = MouseMapper.clampPan(height.toDouble(), (b.height * fit).toDouble(),
                zoom.toDouble(), (panY + dy).toDouble()).toFloat()
        }
        postInvalidate()
    }

    /** 复位到无缩放居中状态（还原按钮）。 */
    fun resetView() {
        synchronized(this) {
            zoom = 1f
            panX = 0f
            panY = 0f
        }
        postInvalidate()
    }

    override fun onDraw(canvas: Canvas) {
        // 绘制全程持锁：防止 onFrame 里 recycle 上一帧时 onDraw 正在绘制该帧（recycled bitmap 崩溃）
        synchronized(this) {
            canvas.drawColor(Color.BLACK)
            val bmp = bitmap ?: run {
                canvas.drawText(context.getString(R.string.waiting_screen), width / 2f, height / 2f, hintPaint)
                return
            }
            val fit = minOf(width.toFloat() / bmp.width, height.toFloat() / bmp.height)
            val scale = fit * zoom
            val drawW = bmp.width * scale
            val drawH = bmp.height * scale
            val dx = (width - drawW) / 2f + panX
            val dy = (height - drawH) / 2f + panY
            canvas.drawBitmap(bmp, null, RectF(dx, dy, dx + drawW, dy + drawH), paint)
        }
    }
}
