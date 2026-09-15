#if os(macOS)
import Cocoa
import CoreGraphics
import LingXiProtocol

public final class DarwinInputBackend: InputBackend, @unchecked Sendable {
    /// 是否开启 Codex 级独立虚拟指针模式：
    /// true 时：move 操作仅驱动独立虚拟发光光标平滑飞舞，绝不广播全局硬件 mouseMoved；
    /// 点击操作完成瞬间立即将物理硬件鼠标复位回原位，彻底实现物理鼠标零劫持、零争抢。
    public let isIndependentVirtualCursor: Bool

    public init(isIndependentVirtualCursor: Bool = true) {
        self.isIndependentVirtualCursor = isIndependentVirtualCursor
    }

    private func checkAccessibilityPermission() throws {
        guard AXIsProcessTrusted() else {
            throw SystemAuthorizationError.denied(
                subsystem: "accessibility",
                guidance: "Grant Accessibility permission in System Settings -> Privacy & Security -> Accessibility"
            )
        }
    }

    public func injectPointer(event: PointerInputEvent) async throws {
        try checkAccessibilityPermission()

        // 1. 同步驱动视觉虚拟发光指针覆盖层（完全鼠标穿透，带平滑跟随与点击扩散波纹）
        await MainActor.run {
            let overlay = DarwinVirtualPointerOverlay.shared
            switch event.kind {
            case .move:
                overlay.move(to: event.position, duration: 0.45, animated: true)
            case .click(let button, _):
                overlay.move(to: event.position, duration: 0.15, animated: false)
                overlay.playClickEffect(at: event.position, button: button, duration: 0.55)
            case .down(let button):
                overlay.move(to: event.position, duration: 0.15, animated: false)
                overlay.playClickEffect(at: event.position, button: button, duration: 0.55)
            default:
                break
            }
        }

        let pt = CGPoint(x: event.position.x, y: event.position.y)

        // 2. 硬件事件注入逻辑
        switch event.kind {
        case .move:
            // 核心关键：在独立虚拟指针模式下，绝不发送全局硬件 mouseMoved，杜绝物理鼠标被强行拖拽劫持！
            if !isIndependentVirtualCursor {
                if let cgEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left) {
                    cgEvent.post(tap: .cghidEventTap)
                }
            }

        case .down(let button):
            let originalPhysicalPos = isIndependentVirtualCursor ? CGEvent(source: nil)?.location : nil
            let type: CGEventType = (button == .right ? .rightMouseDown : (button == .middle ? .otherMouseDown : .leftMouseDown))
            let cgButton: CGMouseButton = (button == .right ? .right : (button == .middle ? .center : .left))
            if let cgEvent = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: cgButton) {
                cgEvent.post(tap: .cghidEventTap)
            }
            if let originalPhysicalPos {
                CGWarpMouseCursorPosition(originalPhysicalPos)
            }

        case .up(let button):
            let originalPhysicalPos = isIndependentVirtualCursor ? CGEvent(source: nil)?.location : nil
            let type: CGEventType = (button == .right ? .rightMouseUp : (button == .middle ? .otherMouseUp : .leftMouseUp))
            let cgButton: CGMouseButton = (button == .right ? .right : (button == .middle ? .center : .left))
            if let cgEvent = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: cgButton) {
                cgEvent.post(tap: .cghidEventTap)
            }
            if let originalPhysicalPos {
                CGWarpMouseCursorPosition(originalPhysicalPos)
            }

        case .click(let button, let count):
            let originalPhysicalPos = isIndependentVirtualCursor ? CGEvent(source: nil)?.location : nil
            let downType: CGEventType = (button == .right ? .rightMouseDown : (button == .middle ? .otherMouseDown : .leftMouseDown))
            let upType: CGEventType = (button == .right ? .rightMouseUp : (button == .middle ? .otherMouseUp : .leftMouseUp))
            let cgButton: CGMouseButton = (button == .right ? .right : (button == .middle ? .center : .left))

            for i in 1...max(1, count) {
                if let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: pt, mouseButton: cgButton) {
                    down.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                    down.post(tap: .cghidEventTap)
                }
                try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
                if let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: pt, mouseButton: cgButton) {
                    up.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                    up.post(tap: .cghidEventTap)
                }
                if i < count {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }

            // 瞬间复原物理鼠标位置
            if let originalPhysicalPos {
                CGWarpMouseCursorPosition(originalPhysicalPos)
            }

        case .scroll(let deltaX, let deltaY):
            if let scrollEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(deltaY),
                wheel2: Int32(deltaX),
                wheel3: 0
            ) {
                scrollEvent.post(tap: .cghidEventTap)
            }
        }
    }

    public func injectKeyboard(event: KeyboardInputEvent) async throws {
        try checkAccessibilityPermission()

        switch event.kind {
        case .keyPress(let keyName):
            let keyCode = resolveKeyCode(for: keyName)
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
                down.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
            if let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                up.post(tap: .cghidEventTap)
            }

        case .text(let string):
            for char in string.utf16 {
                var codeUnit = char
                if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                    down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &codeUnit)
                    down.post(tap: .cghidEventTap)
                }
                if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                    up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &codeUnit)
                    up.post(tap: .cghidEventTap)
                }
            }

        case .modifiersChanged(let modifiers):
            var flags = CGEventFlags()
            if modifiers.contains(.command) { flags.insert(.maskCommand) }
            if modifiers.contains(.shift) { flags.insert(.maskShift) }
            if modifiers.contains(.alt) { flags.insert(.maskAlternate) }
            if modifiers.contains(.control) { flags.insert(.maskControl) }

            if let event = CGEvent(source: nil) {
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }
        }
    }

    /// 强制安全中立化：释放所有鼠标按键并清空修饰键状态，防止物理按键卡滞
    public func neutralize() async {
        let originalPhysicalPos = CGEvent(source: nil)?.location
        let pt = originalPhysicalPos ?? CGPoint.zero

        // 1. 在当前原位安全释放鼠标左键、右键、中键（绝不向 (0,0) 瞬移物理鼠标）
        if let leftUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left) {
            leftUp.post(tap: .cghidEventTap)
        }
        if let rightUp = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: pt, mouseButton: .right) {
            rightUp.post(tap: .cghidEventTap)
        }
        if let otherUp = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: pt, mouseButton: .center) {
            otherUp.post(tap: .cghidEventTap)
        }

        if let originalPhysicalPos {
            CGWarpMouseCursorPosition(originalPhysicalPos)
        }

        // 2. 清空所有键盘修饰键状态 (Command / Shift / Option / Control)
        if let clearFlags = CGEvent(source: nil) {
            clearFlags.flags = CGEventFlags(rawValue: 0)
            clearFlags.post(tap: .cghidEventTap)
        }

        // 3. 隐藏桌面虚拟发光光标
        await MainActor.run {
            DarwinVirtualPointerOverlay.shared.hide()
        }
    }

    private func resolveKeyCode(for key: String) -> CGKeyCode {
        switch key.lowercased() {
        case "return", "enter": return 0x24
        case "tab": return 0x30
        case "space": return 0x31
        case "delete", "backspace": return 0x33
        case "escape", "esc": return 0x35
        case "command", "cmd": return 0x37
        case "shift": return 0x38
        case "capslock": return 0x39
        case "option", "alt": return 0x3A
        case "control", "ctrl": return 0x3B
        case "rightshift": return 0x3C
        case "rightoption": return 0x3D
        case "rightcontrol": return 0x3E
        case "left", "arrowleft": return 0x7B
        case "right", "arrowright": return 0x7C
        case "down", "arrowdown": return 0x7D
        case "up", "arrowup": return 0x7E
        default: return 0x00 // Default to key 'A'
        }
    }
}
#endif
