import Foundation

/// 坐标映射：视频视图坐标 → 归一化坐标 (0~1)，letterbox 感知。
/// Mac 端把归一化坐标映射回屏幕点。移植自 Android core MouseMapper.kt，算法与绘制
/// 公式（画点 = imgCoord*(fit*zoom/imgSize) + (view - drawSize)/2 + pan）三方一致。
public enum MouseMath {
    /// letterbox 下触点 → 归一化坐标；触点落在黑边外返回 nil（coerceToBounds 时钳到边缘）。
    public static func normalized(viewW: Double, viewH: Double, imgW: Double, imgH: Double,
                                  x: Double, y: Double,
                                  coerceToBounds: Bool = false) -> (nx: Double, ny: Double)? {
        if viewW <= 0 || viewH <= 0 || imgW <= 0 || imgH <= 0 { return nil }
        let scale = min(viewW / imgW, viewH / imgH)
        let drawW = imgW * scale
        let drawH = imgH * scale
        let localX = x - (viewW - drawW) / 2.0
        let localY = y - (viewH - drawH) / 2.0
        if coerceToBounds {
            return (localX.clamped(0, drawW) / drawW, localY.clamped(0, drawH) / drawH)
        }
        // 闭区间 [0, drawW/H]：图像右/下边缘的触点也应映射（边缘 → 1.0）
        if localX < 0 || localX > drawW || localY < 0 || localY > drawH { return nil }
        return ((localX / drawW).clamped(0, 1), (localY / drawH).clamped(0, 1))
    }

    /// 平移量钳制（zoom>=1，pan 为相对当前 zoom 居中位置的偏移）：
    /// 放大后内容超出视图 → 允许拖到边缘；内容小于视图（letterbox 方向）→ 锁定居中。
    public static func clampPan(viewSize: Double, fitDrawSize: Double, zoom: Double, pan: Double) -> Double {
        let content = fitDrawSize * zoom
        let centerOffset = (viewSize - content) / 2.0
        let dx = centerOffset + pan
        let clamped = content >= viewSize ? dx.clamped(viewSize - content, 0) : centerOffset
        return clamped - centerOffset
    }

    /// 焦点锚定缩放：缩放到 zoom 后，让图像像素坐标 imgCoord 的点仍显示在视图坐标 focus 处。
    public static func anchoredPan(viewSize: Double, imgSize: Double, fitDrawSize: Double,
                                   zoom: Double, focus: Double, imgCoord: Double) -> Double {
        if imgSize <= 0 { return 0 }
        let drawSize = fitDrawSize * zoom
        let scale = drawSize / imgSize
        let pan = focus - imgCoord * scale - (viewSize - drawSize) / 2.0
        return clampPan(viewSize: viewSize, fitDrawSize: fitDrawSize, zoom: zoom, pan: pan)
    }

    /// 缩放+平移状态下的坐标映射；绘制公式与渲染层一致：drawSize = imgSize*fit*zoom，
    /// offset = (view - drawSize)/2 + pan。
    public static func normalizedZoomed(viewW: Double, viewH: Double, imgW: Double, imgH: Double,
                                        zoom: Double, panX: Double, panY: Double,
                                        x: Double, y: Double,
                                        coerceToBounds: Bool = false) -> (nx: Double, ny: Double)? {
        if viewW <= 0 || viewH <= 0 || imgW <= 0 || imgH <= 0 || zoom <= 0 { return nil }
        let scale = min(viewW / imgW, viewH / imgH) * zoom
        let drawW = imgW * scale
        let drawH = imgH * scale
        let localX = x - ((viewW - drawW) / 2.0 + panX)
        let localY = y - ((viewH - drawH) / 2.0 + panY)
        if coerceToBounds {
            return (localX.clamped(0, drawW) / drawW, localY.clamped(0, drawH) / drawH)
        }
        if localX < 0 || localX > drawW || localY < 0 || localY > drawH { return nil }
        return ((localX / drawW).clamped(0, 1), (localY / drawH).clamped(0, 1))
    }
}

extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}
