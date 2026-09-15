import Foundation
import LingXiTUIComponents
import LingXiPlatform

protocol TerminalBackend: AnyObject, Sendable {
    var size: TUISize { get }
    func start() throws
    func stop()
    func nextInput() -> TUIInputEvent?
    func render(_ frame: TUIFrame)
}

final class POSIXTerminalBackend: TerminalBackend, @unchecked Sendable {
    private var rawToken: Any?
    private var openTUI: OpenTUIRenderer?
    private(set) var size = TUISize(width: 80, height: 24)
    private var lastSize = TUISize(width: 80, height: 24)
    private var renderCount = 0
    private let noAltScreen: Bool

    init(noAltScreen: Bool = false) {
        self.noAltScreen = noAltScreen
    }

    func start() throws {
        debug("start.begin")
        rawToken = try LingXiPlatform.terminal.enableRawMode()
        debug("start.rawMode.done")
        updateSize()
        debug("start.size width=\(size.width) height=\(size.height)")
        debug("start.renderer.create.begin")
        openTUI = try? OpenTUIRenderer(width: size.width, height: size.height)
        debug("start.renderer.create.end (available: \(openTUI != nil))")
        if let bufferSize = openTUI?.nextBufferSize() {
            debug("start.buffer size=\(bufferSize.width)x\(bufferSize.height)")
        }
        if !noAltScreen {
            debug("start.terminal.setup.begin")
            openTUI?.setupTerminal()
            debug("start.terminal.setup.end")
        }
        debug("start.mouse.enable.begin")
        openTUI?.enableMouse()
        debug("start.mouse.enable.end")
        // 启用扩展鼠标坐标与拖拽追踪（1000h+1002h+1006h），禁用自动换行（7l）
        FileHandle.standardOutput.write(Data("\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1006h\u{1B}[?7l".utf8))
    }

    func stop() {
        debug("stop.begin")
        // 恢复终端鼠标模式与自动换行
        FileHandle.standardOutput.write(Data("\u{1B}[?1002l\u{1B}[?1000l\u{1B}[?1006l\u{1B}[?7h".utf8))
        openTUI?.disableMouse()
        if !noAltScreen {
            openTUI?.restoreTerminalModes()
        }
        openTUI = nil
        if let token = rawToken {
            LingXiPlatform.terminal.restoreTerminalMode(token: token)
            rawToken = nil
        }
        debug("stop.end")
    }

    func nextInput() -> TUIInputEvent? {
        updateSize()
        if size != lastSize {
            lastSize = size
            return .resize(size)
        }
        guard let byte = readByte(after: 20) else { return nil }
        switch byte {
        case 3: return .interrupt
        case 4: return .quit
        case 20: return .cycleReasoningEffort
        case 23: return .deleteWordBackward
        case 8, 127: return .backspace
        case 9: return .tab
        case 16: return .commandPalette
        case 10, 13: return .enter
        case 27: return readEscapeSequence()
        default: return readUTF8Character(firstByte: byte).map(TUIInputEvent.character)
        }
    }

    func render(_ frame: TUIFrame) {
        guard let renderer = openTUI else { return }
        renderCount += 1
        if renderCount <= 3 {
            debug("render.begin count=\(renderCount) size=\(frame.size.width)x\(frame.size.height) cells=\(frame.cells.count)")
        }
        renderer.resize(width: frame.size.width, height: frame.size.height)
        renderer.clear()
        for row in 0..<frame.size.height {
            for column in 0..<frame.size.width {
                let cell = frame.cells[row * frame.size.width + column]
                if cell.continuation { continue }
                let style = color(for: cell.style)
                let fg = cell.customForeground.map { OpenTUIColorValue(red: UInt16($0.r) * 257, green: UInt16($0.g) * 257, blue: UInt16($0.b) * 257) } ?? style.foreground
                let bg = cell.customBackground.map { OpenTUIColorValue(red: UInt16($0.r) * 257, green: UInt16($0.g) * 257, blue: UInt16($0.b) * 257) } ?? style.background
                renderer.draw(String(cell.character), x: column, y: row,
                              foreground: fg, background: bg)
            }
        }
        renderer.setCursor(frame.cursor)
        let result = renderer.render(force: renderCount == 1)
        if renderCount <= 3 {
            debug("render.end count=\(renderCount) nativeResult=\(result)")
        }
    }

    private func updateSize() {
        if let dims = LingXiPlatform.terminal.getTerminalDimensions() {
            size = TUISize(width: dims.columns, height: dims.rows)
        }
    }

    private func readByte(after milliseconds: Int32 = 0) -> UInt8? {
        LingXiPlatform.terminal.readByte(timeoutMilliseconds: milliseconds)
    }

    private func readUTF8Character(firstByte: UInt8) -> Character? {
        let length: Int
        switch firstByte {
        case 0..<0x80: length = 1
        case 0xC0..<0xE0: length = 2
        case 0xE0..<0xF0: length = 3
        case 0xF0..<0xF8: length = 4
        default: return nil
        }
        var bytes = [firstByte]
        for _ in 1..<length {
            guard let byte = readByte(after: 40) else { return nil }
            bytes.append(byte)
        }
        return String(data: Data(bytes), encoding: .utf8).flatMap { $0.first }
    }

    private func readEscapeSequence() -> TUIInputEvent {
        guard let second = readByte(after: 40) else { return .escape }
        switch second {
        case 10, 13: return .shiftEnter // Alt+Enter / Option+Enter (\e\r or \e\n)
        case 91: break // CSI '['
        case 79: // SS3 'O' (macOS and application cursor mode: \eOA, \eOB, \eOC, \eOD, \eOH, \eOF)
            guard let third = readByte(after: 40) else { return .escape }
            switch third {
            case 65: return .up
            case 66: return .down
            case 67: return .right
            case 68: return .left
            case 72: return .home
            case 70: return .end
            default: return .tick
            }
        case 93: return readControlString(terminatesWithBell: true) // OSC
        case 80, 88, 94, 95: return readControlString(terminatesWithBell: false) // DCS/SOS/PM/APC
        default: return .escape
        }
        var sequence: [UInt8] = []
        while let byte = readByte(after: 40) {
            sequence.append(byte)
            if byte >= 0x40, byte <= 0x7E { break }
            if sequence.count > 32 { break }
        }
        guard let final = sequence.last else { return .escape }
        let body = String(decoding: sequence.dropLast(), as: UTF8.self)
        if body.first == "<" {
            let parts = body.dropFirst().split(separator: ";")
            if parts.count >= 3,
               let button = Int(parts[0]),
               let x = Int(parts[1]),
               let y = Int(parts[2]) {
                let col = max(0, x - 1)
                let row = max(0, y - 1)
                if final == 77 { // 'M': press or drag
                    if button == 0 {
                        return .mouseDown(x: col, y: row)
                    } else if button == 32 || (button & 32) != 0 {
                        return .mouseDrag(x: col, y: row)
                    } else if button == 64 {
                        return .scrollUp
                    } else if button == 65 {
                        return .scrollDown
                    }
                } else if final == 109 { // 'm': release
                    if (button & 3) == 0 || button == 32 || (button & 32) != 0 {
                        return .mouseUp(x: col, y: row)
                    }
                }
            } else if let button = Int(parts.first ?? "") {
                if final == 77 || final == 109 {
                    if button == 64 { return .scrollUp }
                    if button == 65 { return .scrollDown }
                }
            }
            return .tick
        }
        switch final {
        case 90: return .shiftTab
        case 65: return .up
        case 66: return .down
        case 67: return .right
        case 68: return .left
        case 72: return .home
        case 70: return .end
        case 126:
            switch body {
            case "1": return .home
            case "3": return .delete
            case "4": return .end
            case "5": return .pageUp
            case "6": return .pageDown
            case "200": return readPaste()
            default: return .tick
            }
        case 117 where body.contains("2") && body.contains("13"): return .shiftEnter
        default: return .tick
        }
    }

    private func readControlString(terminatesWithBell: Bool) -> TUIInputEvent {
        var previous: UInt8 = 0
        var count = 0
        while count < 4096, let byte = readByte(after: 40) {
            count += 1
            if terminatesWithBell && byte == 7 { return .tick }
            if previous == 27 && byte == 92 { return .tick }
            previous = byte
        }
        return .tick
    }

    private func readPaste() -> TUIInputEvent {
        var bytes: [UInt8] = []
        let terminator = Array("\u{1B}[201~".utf8)
        while let byte = readByte(after: 40) {
            bytes.append(byte)
            if bytes.count >= terminator.count, bytes.suffix(terminator.count).elementsEqual(terminator) {
                bytes.removeLast(terminator.count)
                break
            }
        }
        return .paste(String(decoding: bytes, as: UTF8.self))
    }

    private struct OpenTUIStyle {
        let foreground: OpenTUIColorValue
        let background: OpenTUIColorValue
    }

    private func color(for style: TUIStyle) -> OpenTUIStyle {
        let pair = ThemeManager.shared.currentTheme.styleColor(for: style)
        return OpenTUIStyle(foreground: pair.foreground, background: pair.background)
    }

    private func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["LINGXI_TUI_DEBUG"] == "1" else { return }
        let timestamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        FileHandle.standardError.write(Data("[\(timestamp)] [POSIXTerminalBackend] \(message)\n".utf8))
    }

}
