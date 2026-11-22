package com.macscreen.core

/**
 * 坐标映射：视频视图坐标 → 归一化坐标 (0~1)，letterbox 感知。
 * Mac 端把归一化坐标映射回屏幕点。
 */
object MouseMapper {
    /**
     * @param viewW/viewH 视图尺寸(px)；imgW/imgH 帧图像尺寸(px)；x/y 触点(视图坐标)
     * @param coerceToBounds true 时不做图外判 null，而是把触点钳制到图像边缘再映射
     * @return 归一化坐标；触点落在黑边外返回 null（coerceToBounds=true 时除外）
     */
    fun normalized(viewW: Int, viewH: Int, imgW: Int, imgH: Int, x: Float, y: Float,
                   coerceToBounds: Boolean = false): Pair<Double, Double>? {
        if (viewW <= 0 || viewH <= 0 || imgW <= 0 || imgH <= 0) return null
        val scale = minOf(viewW.toDouble() / imgW, viewH.toDouble() / imgH)
        val drawW = imgW * scale
        val drawH = imgH * scale
        val offsetX = (viewW - drawW) / 2.0
        val offsetY = (viewH - drawH) / 2.0
        val localX = x - offsetX
        val localY = y - offsetY
        if (coerceToBounds) {
            return (localX.coerceIn(0.0, drawW) / drawW) to (localY.coerceIn(0.0, drawH) / drawH)
        }
        // 闭区间 [0, drawW/H]：图像右/下边缘的触点也应映射（边缘 → 1.0）
        if (localX < 0 || localX > drawW || localY < 0 || localY > drawH) return null
        val nx = localX / drawW
        val ny = localY / drawH
        return nx.coerceIn(0.0, 1.0) to ny.coerceIn(0.0, 1.0)
    }

    /**
     * 平移量钳制（zoom>=1，pan 为相对**当前 zoom 居中位置**的偏移，px）：
     * 放大后内容超出视图 → 允许拖到边缘（±(content-viewSize)/2 对称）；
     * 内容小于视图（letterbox 方向）→ 锁定居中（返回 0）。
     * 与绘制/映射公式 offset = (viewSize - fitDrawSize*zoom)/2 + pan 严格一致。
     */
    fun clampPan(viewSize: Double, fitDrawSize: Double, zoom: Double, pan: Double): Double {
        val content = fitDrawSize * zoom
        val centerOffset = (viewSize - content) / 2.0
        val dx = centerOffset + pan
        val clamped = if (content >= viewSize) dx.coerceIn(viewSize - content, 0.0) else centerOffset
        return clamped - centerOffset
    }

    /**
     * 焦点锚定的缩放平移量：缩放到 [zoom] 后，让图像像素坐标 [imgCoord] 的点仍显示在视图坐标 [focus] 处，
     * 并经 [clampPan] 钳制。绘制公式与 [normalizedZoomed] 一致：
     * 画点 = imgCoord*(fitDrawSize*zoom/imgSize) + (viewSize - fitDrawSize*zoom)/2 + pan。
     */
    fun anchoredPan(viewSize: Double, imgSize: Double, fitDrawSize: Double, zoom: Double,
                    focus: Double, imgCoord: Double): Double {
        if (imgSize <= 0.0) return 0.0
        val drawSize = fitDrawSize * zoom
        val scale = drawSize / imgSize
        val pan = focus - imgCoord * scale - (viewSize - drawSize) / 2.0
        return clampPan(viewSize, fitDrawSize, zoom, pan)
    }

    /**
     * 缩放+平移状态下的坐标映射。zoom 为相对 fit 的倍数；pan 为相对居中位置的偏移(px)。
     * 绘制公式与 VideoView 一致：drawSize = imgSize * fit * zoom，offset = (view - drawSize)/2 + pan。
     */
    fun normalizedZoomed(viewW: Int, viewH: Int, imgW: Int, imgH: Int,
                         zoom: Double, panX: Double, panY: Double,
                         x: Float, y: Float, coerceToBounds: Boolean = false): Pair<Double, Double>? {
        if (viewW <= 0 || viewH <= 0 || imgW <= 0 || imgH <= 0 || zoom <= 0.0) return null
        val scale = minOf(viewW.toDouble() / imgW, viewH.toDouble() / imgH) * zoom
        val drawW = imgW * scale
        val drawH = imgH * scale
        val localX = x - ((viewW - drawW) / 2.0 + panX)
        val localY = y - ((viewH - drawH) / 2.0 + panY)
        if (coerceToBounds) {
            return (localX.coerceIn(0.0, drawW) / drawW) to (localY.coerceIn(0.0, drawH) / drawH)
        }
        if (localX < 0 || localX > drawW || localY < 0 || localY > drawH) return null
        return (localX / drawW).coerceIn(0.0, 1.0) to (localY / drawH).coerceIn(0.0, 1.0)
    }
}

/**
 * 手势分类器（纯逻辑）：把 down/move/up 事件序列分类为
 * click（单击）、double（双击）、right（长按右键）、drag（拖动）。
 */
class GestureClassifier(
    private val longPressMs: Long = 450,
    private val doubleTapMs: Long = 300,
    private val slopPx: Float = 12f,
) {
    /** down → move → up 序列的结果。 */
    sealed class Result {
        object Click : Result()
        object DoubleClick : Result()
        object RightClick : Result()
        /** 拖动：已经发过 down；up 结束本次拖动。 */
        object DragEnd : Result()
        /** 触点移出画面（黑边），拖动中按当前位置继续也允许：返回 null 表示忽略该 move。 */
        object Ignored : Result()
    }

    private var downX = 0f
    private var downY = 0f
    private var downTime = 0L
    private var lastUpTime = 0L
    private var lastUpX = 0f
    private var lastUpY = 0f
    private var isDragging = false
    private var longPressFired = false
    private var canceled = false

    /** 当前是否处于拖动中（UI 层判断 move 是否发 drag 用）。 */
    val dragging: Boolean get() = isDragging

    fun onDown(x: Float, y: Float, timeMs: Long) {
        downX = x; downY = y; downTime = timeMs
        isDragging = false
        longPressFired = false
        canceled = false
    }

    /** 每次移动调用；超过 slop 判定进入拖动。返回 true 表示首次进入拖动（应先发 mouse down）。 */
    fun onMove(x: Float, y: Float, timeMs: Long): Boolean {
        if (!isDragging) {
            val dx = x - downX
            val dy = y - downY
            if (dx * dx + dy * dy > slopPx * slopPx) {
                isDragging = true
                return true
            }
            // 长按判定：按住未动超过 longPressMs
            if (!longPressFired && timeMs - downTime >= longPressMs) {
                longPressFired = true
            }
        }
        return false
    }

    /** 长按是否已触发（应发右键）。 */
    fun isLongPress(): Boolean = longPressFired && !isDragging

    /** 中断当前序列（如双指接管缩放）：随后的 onUp 返回 Ignored，不产生任何手势结果。 */
    fun cancel() {
        isDragging = false
        longPressFired = false
        canceled = true
    }

    fun onUp(x: Float, y: Float, timeMs: Long): Result {
        if (canceled) {
            canceled = false
            return Result.Ignored
        }
        return if (isDragging) {
            isDragging = false
            Result.DragEnd
        } else if (longPressFired) {
            longPressFired = false
            Result.RightClick
        } else {
            val isDouble = timeMs - lastUpTime <= doubleTapMs &&
                distance(x, y, lastUpX, lastUpY) <= slopPx * 2
            lastUpTime = timeMs; lastUpX = x; lastUpY = y
            if (isDouble) Result.DoubleClick else Result.Click
        }
    }

    private fun distance(x1: Float, y1: Float, x2: Float, y2: Float): Float {
        val dx = x1 - x2; val dy = y1 - y2
        return kotlin.math.sqrt(dx * dx + dy * dy)
    }
}
