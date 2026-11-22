import Foundation
import CoreGraphics
import AppKit

/// 鼠标动作。
public enum MouseAction: String {
    case click, down, up, move, drag
    case doubleClick = "double"
    case rightClick = "right"
}

/// 输入注入协议（真实实现 CGEventInjector；测试/无权限场景用 MockInputInjector）。
public protocol InputInjector: AnyObject {
    /// 在屏幕逻辑坐标 (x, y) pt 处执行鼠标动作。
    func mouse(action: MouseAction, x: Double, y: Double) -> Bool
    func scroll(dx: Double, dy: Double, x: Double?, y: Double?) -> Bool
    /// 向当前焦点文本框输入 Unicode 文本。
    func typeText(_ text: String) -> Bool
    /// 按下命名按键（return/tab/esc/...），可带修饰键（command/shift/option/control/fn）。
    func pressKey(_ key: String, modifiers: [String]) -> Bool
}

// MARK: - 按键映射（纯逻辑，可测）

public enum KeyMap {
    /// macOS 虚拟键码（系统内置布局）。
    public static let virtualKeyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "esc": 53, "escape": 53,
        "space": 49, "delete": 51, "backspace": 51, "forwarddelete": 117,
        "up": 126, "down": 125, "left": 123, "right": 124,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109,
    ]

    public static func keyCode(_ name: String) -> CGKeyCode? {
        virtualKeyCodes[name.lowercased()]
    }

    public static func flags(_ modifiers: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for m in modifiers {
            switch m.lowercased() {
            case "command", "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "control", "ctrl": flags.insert(.maskControl)
            case "option", "alt": flags.insert(.maskAlternate)
            case "fn": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        return flags
    }
}

// MARK: - CGEvent 实现

public final class CGEventInjector: InputInjector {
    public init() {}

    public func mouse(action: MouseAction, x: Double, y: Double) -> Bool {
        let point = CGPoint(x: x, y: y)
        switch action {
        case .click:
            guard postMove(point) else { return false }
            return postClick(.leftMouseDown, .leftMouseUp, button: .left, clickCount: 1, at: point)
        case .doubleClick:
            guard postMove(point) else { return false }
            var ok = true
            for n in 1...2 {
                ok = postClick(.leftMouseDown, .leftMouseUp, button: .left, clickCount: n, at: point) && ok
            }
            return ok
        case .rightClick:
            guard postMove(point) else { return false }
            return postClick(.rightMouseDown, .rightMouseUp, button: .right, clickCount: 1, at: point)
        case .down:
            return postMouseEvent(.leftMouseDown, at: point, button: .left)
        case .up:
            return postMouseEvent(.leftMouseUp, at: point, button: .left)
        case .move:
            return postMove(point)
        case .drag:
            return postMouseEvent(.leftMouseDragged, at: point, button: .left)
        }
    }

    public func scroll(dx: Double, dy: Double, x: Double?, y: Double?) -> Bool {
        if let x = x, let y = y {
            _ = postMove(CGPoint(x: x, y: y))
        }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                  wheel1: Int32(clamping: Int(-dy)),
                                  wheel2: Int32(clamping: Int(dx)), wheel3: 0) else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }

    public func typeText(_ text: String) -> Bool {
        // 按行拆分：换行用 Return 按键（unicode 直接发 \n 在多数应用不产生换行）
        let lines = text.components(separatedBy: "\n")
        var ok = true
        for (index, line) in lines.enumerated() {
            if index > 0 { ok = pressKey("return", modifiers: []) && ok }
            if !line.isEmpty { ok = typeChunk(line) && ok }
        }
        return ok
    }

    public func pressKey(_ key: String, modifiers: [String]) -> Bool {
        guard let code = KeyMap.keyCode(key) else { return false }
        let flags = KeyMap.flags(modifiers)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return false }
        if !flags.isEmpty {
            down.flags = flags
            up.flags = flags
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// unicode 字符串注入：CGEvent keyboardSetUnicodeString（每事件最多 ~16 个 UTF-16 单元，分块）。
    private func typeChunk(_ text: String) -> Bool {
        let units = Array(text.utf16)
        var ok = true
        var offset = 0
        let chunkSize = 16
        while offset < units.count {
            let end = min(offset + chunkSize, units.count)
            let slice = Array(units[offset..<end])
            ok = postUnicode(slice) && ok
            offset = end
        }
        return ok
    }

    private func postUnicode(_ units: [UniChar]) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return false }
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func postMove(_ point: CGPoint) -> Bool {
        postMouseEvent(.mouseMoved, at: point, button: .left)
    }

    private func postMouseEvent(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) -> Bool {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }

    private func postClick(_ downType: CGEventType, _ upType: CGEventType,
                           button: CGMouseButton, clickCount: Int, at point: CGPoint) -> Bool {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: downType,
                                 mouseCursorPosition: point, mouseButton: button),
              let up = CGEvent(mouseEventSource: nil, mouseType: upType,
                               mouseCursorPosition: point, mouseButton: button) else { return false }
        down.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        up.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

// MARK: - Mock 实现（记录动作，供测试与 E2E 断言）

public final class MockInputInjector: InputInjector {
    public struct RecordedAction: Equatable {
        public var kind: String
        public var payload: [String: String]
    }

    public private(set) var actions: [RecordedAction] = []
    public var mainScreen: (width: Double, height: Double) = (1440, 900)
    /// 每次注入后回调（测试用）。
    public var onAction: ((RecordedAction) -> Void)?

    public init() {}

    public func mouse(action: MouseAction, x: Double, y: Double) -> Bool {
        record("mouse", ["action": action.rawValue, "x": String(x), "y": String(y)])
        return true
    }

    public func scroll(dx: Double, dy: Double, x: Double?, y: Double?) -> Bool {
        record("scroll", ["dx": String(dx), "dy": String(dy)])
        return true
    }

    public func typeText(_ text: String) -> Bool {
        record("type", ["text": text])
        return true
    }

    public func pressKey(_ key: String, modifiers: [String]) -> Bool {
        record("key", ["key": key, "modifiers": modifiers.joined(separator: "+")])
        return true
    }

    private func record(_ kind: String, _ payload: [String: String]) {
        let action = RecordedAction(kind: kind, payload: payload)
        actions.append(action)
        onAction?(action)
    }

    public func reset() { actions.removeAll() }
}
