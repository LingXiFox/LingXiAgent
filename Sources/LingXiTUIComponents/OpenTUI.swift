import Foundation
import OpenTUIShim

public enum OpenTUIError: Error, CustomStringConvertible {
    case unavailable(String)
    public var description: String {
        switch self { case let .unavailable(message): return message }
    }
}

public struct OpenTUIColorValue: Sendable {
    public let red: UInt16
    public let green: UInt16
    public let blue: UInt16
    public let alpha: UInt16

    public init(red: UInt16, green: UInt16, blue: UInt16, alpha: UInt16 = UInt16.max) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public final class OpenTUIRenderer {
    private var handle: OpenTUIHandle

    public init(width: Int, height: Int, libraryPath: String? = nil) throws {
        let path = libraryPath ?? ProcessInfo.processInfo.environment["OPENTUI_LIB"]
        guard opentui_load(path) else { throw OpenTUIError.unavailable(String(cString: opentui_last_error())) }
        handle = opentui_create_renderer(UInt32(width), UInt32(height))
        guard handle != 0 else { throw OpenTUIError.unavailable("OpenTUI renderer allocation failed") }
    }

    deinit { opentui_destroy_renderer(handle) }

    public func setupTerminal() { opentui_setup_terminal(handle) }

    public func enableMouse() { opentui_enable_mouse(handle) }

    public func disableMouse() { opentui_disable_mouse(handle) }

    public func restoreTerminalModes() { opentui_restore_terminal_modes(handle) }

    public func resize(width: Int, height: Int) {
        opentui_resize_renderer(handle, UInt32(width), UInt32(height))
    }

    public func nextBufferSize() -> TUISize {
        let buffer = opentui_next_buffer(handle)
        return TUISize(width: Int(opentui_buffer_width(buffer)), height: Int(opentui_buffer_height(buffer)))
    }

    public func render(force: Bool = false) -> UInt8 { opentui_render(handle, force) }

    public func clear() {
        let background = OpenTUIColor(red: 0, green: 0, blue: 0, alpha: UInt16.max)
        opentui_clear_buffer(opentui_next_buffer(handle), background)
    }

    public func setCursor(_ point: TUIPoint?) {
        guard let point else {
            opentui_set_cursor(handle, 1, 1, false)
            return
        }
        opentui_set_cursor(handle, Int32(point.x + 1), Int32(point.y + 1), true)
    }

    public func draw(_ text: String, x: Int = 0, y: Int = 0,
                     foreground: OpenTUIColorValue = OpenTUIColorValue(red: UInt16.max, green: UInt16.max, blue: UInt16.max),
                     background: OpenTUIColorValue = OpenTUIColorValue(red: 0, green: 0, blue: 0)) {
        let bytes = Array(text.utf8)
        let cForeground = OpenTUIColor(red: foreground.red, green: foreground.green, blue: foreground.blue, alpha: foreground.alpha)
        let cBackground = OpenTUIColor(red: background.red, green: background.green, blue: background.blue, alpha: background.alpha)
        bytes.withUnsafeBufferPointer { buffer in
            opentui_draw_text(opentui_next_buffer(handle), buffer.baseAddress, UInt32(buffer.count), UInt32(x), UInt32(y), cForeground, cBackground)
        }
    }
}
