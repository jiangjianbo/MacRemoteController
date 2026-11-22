import Foundation

/// 手势分类器（纯逻辑）：把 down/move/up 事件序列分类为 click/double/right/drag。
/// UI 层用原生 UIGestureRecognizer 采集事件后喂给它，语义与 Android 版一致。
public final class GestureClassifier {
    public enum Result: Equatable {
        case click
        case doubleClick
        case rightClick
        /// 拖动：已经发过 mouse down；up 结束本次拖动。
        case dragEnd
        /// 序列被取消（如双指接管缩放）。
        case ignored
    }

    let longPressMs: Double
    let doubleTapMs: Double
    let slopPx: Double

    public init(longPressMs: Double = 450, doubleTapMs: Double = 300, slopPx: Double = 12) {
        self.longPressMs = longPressMs
        self.doubleTapMs = doubleTapMs
        self.slopPx = slopPx
    }

    public private(set) var dragging = false

    private var downX = 0.0, downY = 0.0, downTime = 0.0
    private var lastUpTime = 0.0, lastUpX = 0.0, lastUpY = 0.0
    private var longPressFired = false
    private var canceled = false

    public func onDown(x: Double, y: Double, timeMs: Double) {
        downX = x; downY = y; downTime = timeMs
        dragging = false
        longPressFired = false
        canceled = false
    }

    /// 返回 true 表示首次进入拖动（应先发 mouse down）。
    public func onMove(x: Double, y: Double, timeMs: Double) -> Bool {
        if !dragging {
            let dx = x - downX, dy = y - downY
            if dx * dx + dy * dy > slopPx * slopPx {
                dragging = true
                return true
            }
            if !longPressFired && timeMs - downTime >= longPressMs {
                longPressFired = true
            }
        }
        return false
    }

    /// 长按是否已触发（应发右键）。
    public func isLongPress() -> Bool { longPressFired && !dragging }

    /// 中断当前序列（双指接管缩放）：随后的 onUp 返回 ignored。
    public func cancel() {
        dragging = false
        longPressFired = false
        canceled = true
    }

    public func onUp(x: Double, y: Double, timeMs: Double) -> Result {
        if canceled {
            canceled = false
            return .ignored
        }
        if dragging {
            dragging = false
            return .dragEnd
        }
        if longPressFired {
            longPressFired = false
            return .rightClick
        }
        let isDouble = timeMs - lastUpTime <= doubleTapMs &&
            GestureClassifier.distance(x, y, lastUpX, lastUpY) <= slopPx * 2
        lastUpTime = timeMs; lastUpX = x; lastUpY = y
        return isDouble ? .doubleClick : .click
    }

    static func distance(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        hypot(x1 - x2, y1 - y2)
    }
}
