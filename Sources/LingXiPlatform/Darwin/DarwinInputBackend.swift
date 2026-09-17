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
            // 确保物理/虚拟指针移至目标坐标再触发滚动
            await MainActor.run {
                DarwinVirtualPointerOverlay.shared.move(to: event.position, duration: 0.15, animated: false)
            }
            if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left) {
                moveEvent.post(tap: .cghidEventTap)
            }
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

    private var currentModifiers: CGEventFlags = CGEventFlags()

    public func injectKeyboard(event: KeyboardInputEvent) async throws {
        try checkAccessibilityPermission()

        switch event.kind {
        case .keyPress(let keyName):
            guard let keyCode = resolveKeyCode(for: keyName) else {
                throw ActionExecutionError.inputInjectionFailed(reason: "Unknown or unsupported key: '\(keyName)'")
            }
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
                down.flags.formUnion(currentModifiers)
                down.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
            if let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                up.flags.formUnion(currentModifiers)
                up.post(tap: .cghidEventTap)
            }

        case .text(let string):
            // 按 Extended Grapheme Cluster 粒度一次性提交 UTF-16 缓冲区，绝不拆分 Emoji/非 BMP 字符的 surrogate pairs
            for character in string {
                var utf16Array = Array(character.utf16)
                if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                    down.flags.formUnion(currentModifiers)
                    down.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: &utf16Array)
                    down.post(tap: .cghidEventTap)
                }
                if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                    up.flags.formUnion(currentModifiers)
                    up.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: &utf16Array)
                    up.post(tap: .cghidEventTap)
                }
            }

        case .modifiersChanged(let modifiers):
            var flags = CGEventFlags()
            if modifiers.contains(.command) { flags.insert(.maskCommand) }
            if modifiers.contains(.shift) { flags.insert(.maskShift) }
            if modifiers.contains(.alt) { flags.insert(.maskAlternate) }
            if modifiers.contains(.control) { flags.insert(.maskControl) }
            self.currentModifiers = flags

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
        self.currentModifiers = CGEventFlags()
        if let clearFlags = CGEvent(source: nil) {
            clearFlags.flags = CGEventFlags(rawValue: 0)
            clearFlags.post(tap: .cghidEventTap)
        }

        // 3. 隐藏桌面虚拟发光光标
        await MainActor.run {
            DarwinVirtualPointerOverlay.shared.hide()
        }
    }

    private func resolveKeyCode(for key: String) -> CGKeyCode? {
        let normalized = key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized {
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
        // 字母键映射 (macOS ANSI Keycodes)
        case "a": return 0x00
        case "b": return 0x0B
        case "c": return 0x08
        case "d": return 0x02
        case "e": return 0x0E
        case "f": return 0x03
        case "g": return 0x05
        case "h": return 0x04
        case "i": return 0x22
        case "j": return 0x26
        case "k": return 0x28
        case "l": return 0x25
        case "m": return 0x2E
        case "n": return 0x2D
        case "o": return 0x1F
        case "p": return 0x23
        case "q": return 0x0C
        case "r": return 0x0F
        case "s": return 0x01
        case "t": return 0x11
        case "u": return 0x20
        case "v": return 0x09
        case "w": return 0x0D
        case "x": return 0x07
        case "y": return 0x10
        case "z": return 0x06
        // 数字键映射
        case "0": return 0x1D
        case "1": return 0x12
        case "2": return 0x13
        case "3": return 0x14
        case "4": return 0x15
        case "5": return 0x17
        case "6": return 0x16
        case "7": return 0x1A
        case "8": return 0x1C
        case "9": return 0x19
        // 功能键
        case "f1": return 0x7A
        case "f2": return 0x78
        case "f3": return 0x63
        case "f4": return 0x76
        case "f5": return 0x60
        case "f6": return 0x61
        case "f7": return 0x62
        case "f8": return 0x64
        case "f9": return 0x65
        case "f10": return 0x6D
        case "f11": return 0x67
        case "f12": return 0x6F
        default:
            return nil
        }
    }
}
#endif
