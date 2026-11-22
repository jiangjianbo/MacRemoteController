package com.macscreen.core

import kotlin.test.*

class MouseMapperTest {
    @Test
    fun exactFit() {
        val (nx, ny) = MouseMapper.normalized(1000, 500, 1000, 500, 500f, 250f)!!
        assertEquals(0.5, nx, 1e-9)
        assertEquals(0.5, ny, 1e-9)
    }

    @Test
    fun letterboxHorizontal() {
        // 视图 1600x800，图像 800x500 → scale=1.6，绘制区 1280x800，左右黑边各 160
        val (nx, ny) = MouseMapper.normalized(1600, 800, 800, 500, 160f, 0f)!!
        assertEquals(0.0, nx, 1e-9)
        assertEquals(0.0, ny, 1e-9)
        val (nx2, _) = MouseMapper.normalized(1600, 800, 800, 500, 1440f, 800f)!!
        assertEquals(1.0, nx2, 1e-9)
        // 黑边内 → null
        assertNull(MouseMapper.normalized(1600, 800, 800, 500, 100f, 400f))
        assertNull(MouseMapper.normalized(1600, 800, 800, 500, 1500f, 400f))
    }

    @Test
    fun letterboxVertical() {
        // 视图 800x800，图像 800x500 → scale=1.0，绘制区 800x500，上下黑边各 150
        val (nx, ny) = MouseMapper.normalized(800, 800, 800, 500, 400f, 650f)!!
        assertEquals(0.5, nx, 1e-9)
        assertEquals(1.0, ny, 1e-9)
        assertNull(MouseMapper.normalized(800, 800, 800, 500, 400f, 100f))
    }

    @Test
    fun invalidInputs() {
        assertNull(MouseMapper.normalized(0, 100, 100, 100, 0f, 0f))
        assertNull(MouseMapper.normalized(100, 100, 0, 100, 0f, 0f))
    }

    @Test
    fun coercedMappingClampsOutOfBounds() {
        // 黑边左 → 0
        val (nx, ny) = MouseMapper.normalized(1600, 800, 800, 500, 100f, 400f, coerceToBounds = true)!!
        assertEquals(0.0, nx, 1e-9)
        assertEquals(0.5, ny, 1e-9)
        // 缩放态图外触点 → 钳到边缘（zoom=2 时绘制区为 [-400,1200]，-500 在图外）
        val (nx2, _) = MouseMapper.normalizedZoomed(800, 800, 800, 500, 2.0, 0.0, 0.0,
            -500f, 400f, coerceToBounds = true)!!
        assertEquals(0.0, nx2, 1e-9)
    }
}

class ZoomedMappingTest {
    // 视图 800x800，图像 800x500：fit=1.0；zoom=2 → 绘制区 1600x1000，居中偏移 dx=-400, dy=-100

    @Test
    fun centerStaysCenter() {
        val (nx, ny) = MouseMapper.normalizedZoomed(800, 800, 800, 500, 2.0, 0.0, 0.0, 400f, 400f)!!
        assertEquals(0.5, nx, 1e-9)
        assertEquals(0.5, ny, 1e-9)
    }

    @Test
    fun viewOriginMapsIntoImage() {
        val (nx, ny) = MouseMapper.normalizedZoomed(800, 800, 800, 500, 2.0, 0.0, 0.0, 0f, 0f)!!
        assertEquals(0.25, nx, 1e-9)
        assertEquals(0.1, ny, 1e-9)
    }

    @Test
    fun panShiftsMapping() {
        // panX=+400（画面右移，视口看图像左半）：dx = -400+400 = 0
        val (nx, ny) = MouseMapper.normalizedZoomed(800, 800, 800, 500, 2.0, 400.0, 0.0, 100f, 400f)!!
        assertEquals(0.0625, nx, 1e-9)
        assertEquals(0.5, ny, 1e-9)
    }

    @Test
    fun outOfImageReturnsNull() {
        // zoom=2 绘制区 [-400,1200]：-401 恰在图外
        assertNull(MouseMapper.normalizedZoomed(800, 800, 800, 500, 2.0, 0.0, 0.0, -401f, 400f))
        assertNull(MouseMapper.normalizedZoomed(800, 800, 800, 500, 0.0, 0.0, 0.0, 400f, 400f))
    }

    @Test
    fun clampPanRules() {
        // 视图 800，fit 内容 800，zoom=2 → 内容 1600，居中偏移 -400：dx ∈ [-800, 0] → pan ∈ [-400, 400]
        assertEquals(-400.0, MouseMapper.clampPan(800.0, 800.0, 2.0, -1000.0))
        assertEquals(400.0, MouseMapper.clampPan(800.0, 800.0, 2.0, 1000.0))
        assertEquals(-123.0, MouseMapper.clampPan(800.0, 800.0, 2.0, -123.0))
        assertEquals(0.0, MouseMapper.clampPan(800.0, 800.0, 2.0, 0.0))
        // zoom=1：内容=视图 → pan 只能为 0
        assertEquals(0.0, MouseMapper.clampPan(800.0, 800.0, 1.0, 100.0))
        // letterbox 方向（内容 < 视图）锁定居中
        assertEquals(0.0, MouseMapper.clampPan(800.0, 500.0, 1.2, 50.0))
    }

    @Test
    fun anchoredPanKeepsFocusPointFixed() {
        // 视图 800x800、图像 800x500、fit 绘制 800x500、zoom=2：
        // 视图中心 (400,400) 锚定图像中心 (400,250) → 画面中心不动 → pan 保持 0
        assertEquals(0.0, MouseMapper.anchoredPan(800.0, 800.0, 800.0, 2.0, 400.0, 400.0))
        assertEquals(0.0, MouseMapper.anchoredPan(800.0, 500.0, 500.0, 2.0, 400.0, 250.0))
    }

    @Test
    fun anchoredPanFollowsFocusOffCenter() {
        // zoom=2 后想让图像左上角 (0,0) 显示在视图 (100,100)：drawSize=(1600,1000)，需 dx=(100,100)
        // dx 允许范围 ([-800,0], [-200,0])：x 越上界 → dx 钳 0 → pan=400；y 越上界 → dx 钳 0 → pan=100
        assertEquals(400.0, MouseMapper.anchoredPan(800.0, 800.0, 800.0, 2.0, 100.0, 0.0))
        assertEquals(100.0, MouseMapper.anchoredPan(800.0, 500.0, 500.0, 2.0, 100.0, 0.0))
        // 缩放后图像中心点仍在视图中心时 pan 恒 0，验证与 normalizedZoomed 绘制公式一致：
        // focus=(400,400) + pan=0 → normalizedZoomed 返回图像中心
        val (nx, ny) = MouseMapper.normalizedZoomed(800, 800, 800, 500, 2.0, 0.0, 0.0, 400f, 400f)!!
        assertEquals(0.5, nx, 1e-9)
        assertEquals(0.5, ny, 1e-9)
    }
}

class GestureClassifierTest {
    @Test
    fun singleTapIsClick() {
        val g = GestureClassifier()
        g.onDown(100f, 100f, 0)
        assertEquals(GestureClassifier.Result.Click, g.onUp(102f, 101f, 80))
    }

    @Test
    fun doubleTap() {
        val g = GestureClassifier()
        g.onDown(100f, 100f, 0)
        assertEquals(GestureClassifier.Result.Click, g.onUp(101f, 100f, 60))
        g.onDown(100f, 100f, 150)
        assertEquals(GestureClassifier.Result.DoubleClick, g.onUp(101f, 100f, 220))
    }

    @Test
    fun twoTapsFarApartNotDouble() {
        val g = GestureClassifier()
        g.onDown(100f, 100f, 0)
        assertEquals(GestureClassifier.Result.Click, g.onUp(101f, 100f, 60))
        g.onDown(500f, 500f, 150)
        assertEquals(GestureClassifier.Result.Click, g.onUp(501f, 500f, 220))
    }

    @Test
    fun longPressIsRightClick() {
        val g = GestureClassifier()
        g.onDown(100f, 100f, 0)
        g.onMove(105f, 105f, 500)   // 未超 slop，但时长超长按阈值
        assertTrue(g.isLongPress())
        assertEquals(GestureClassifier.Result.RightClick, g.onUp(105f, 105f, 550))
    }

    @Test
    fun dragSequence() {
        val g = GestureClassifier()
        g.onDown(100f, 100f, 0)
        // 快速移动超 slop → 首次进入拖动
        assertTrue(g.onMove(140f, 100f, 30))
        assertFalse(g.onMove(180f, 100f, 60), "第二次 move 不应再报首次进入")
        // 拖动中不应判为长按
        assertFalse(g.isLongPress())
        assertEquals(GestureClassifier.Result.DragEnd, g.onUp(200f, 100f, 90))
        // 拖动后重新按下恢复
        g.onDown(200f, 100f, 200)
        assertEquals(GestureClassifier.Result.Click, g.onUp(201f, 100f, 260))
    }

    @Test
    fun dragSuppressesClickEvenIfBackToStart() {
        val g = GestureClassifier()
        g.onDown(100f, 100f, 0)
        assertTrue(g.onMove(200f, 100f, 20))
        g.onMove(101f, 100f, 40)
        assertEquals(GestureClassifier.Result.DragEnd, g.onUp(100f, 100f, 50))
    }

    @Test
    fun cancelSuppressesResult() {
        val g = GestureClassifier()
        g.onDown(100f, 100f, 0)
        assertTrue(g.onMove(140f, 100f, 30))   // 拖动中
        g.cancel()
        assertEquals(GestureClassifier.Result.Ignored, g.onUp(160f, 100f, 60))
        // cancel 后重新按下恢复正常
        g.onDown(100f, 100f, 100)
        assertEquals(GestureClassifier.Result.Click, g.onUp(101f, 100f, 150))
    }
}
